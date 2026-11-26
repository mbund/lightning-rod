//! What clients have of entities they step themselves, held to each entity by models of it.
//!
//! A client steps an item or an arrow itself every tick from what it was last sent, and not always
//! as the server does: a client skips what only the side that simulates an entity does, a release
//! can step it by other rules, a protocol rounds the velocity it sends otherwise, and an item at
//! rest moves on the client's own tick count, which begins when that client is sent it. So each
//! viewer is in a class, by its protocol's rounding, the rules of its release and the phase its
//! tick count began in, and each class has a model: the entity as those clients have it. Its kind
//! steps each model beside the entity, as those clients step it, and this judges each against the
//! entity. A model that would look apart from it is owed a correction, which its sync chooses and
//! sends that tick, and then holds what its clients were sent.
//!
//! Classes holding the same model share it, so a body in flight, which every class steps alike,
//! has one.

const std = @import("std");
const entities = @import("entities");
const lightning_rod = @import("lightning_rod");
const Players = @import("players").players.Players;
const Tracking = @import("tracking.zig").Tracking;

const bit_sets = lightning_rod.system.bit_sets;
const IndexSet = lightning_rod.system.IndexSet;
const assert = std.debug.assert;

/// What a client has of an entity it steps: where it is, how it moves, and whether it is on the
/// ground, which its next step reads.
pub const Model = struct {
    position: [3]f64,
    velocity: [3]f64,
    on_ground: bool,

    /// The same to the bit, as a client stepping on from either would step the same.
    pub fn eql(a: Model, b: Model) bool {
        for (a.position ++ a.velocity, b.position ++ b.velocity) |x, y| if (@as(u64, @bitCast(x)) != @as(u64, @bitCast(y))) return false;
        return a.on_ground == b.on_ground;
    }

    /// Whether a client with `self` would look apart from `truth`: in another block, which can
    /// move it otherwise from here on, or further apart on an axis than `tolerance` once their
    /// motions are added. The motion looks a tick ahead: a client draws the tick it computes
    /// before what was sent that tick reaches it, so what would show next has to go now. Only
    /// motion that can show counts: none of one `still`, whose clients will not move it next tick,
    /// and none down of one on the ground, which the ground holds.
    pub fn apart(self: Model, truth: Model, tolerance: f64, still: bool) bool {
        for (self.position, truth.position, 0..) |seen, actual, axis| {
            if (@floor(seen) != @floor(actual)) return true;
            const seen_motion: f64 = if (still) 0 else self.shown(axis);
            if (@abs(seen - actual) + @abs(seen_motion - truth.shown(axis)) > tolerance) return true;
        }
        return false;
    }

    /// Its motion along an axis as far as it can move it.
    fn shown(self: Model, axis: usize) f64 {
        if (axis == 1 and self.on_ground and self.velocity[1] < 0) return 0;
        return self.velocity[axis];
    }
};

/// Classes of viewers, a bit each.
pub const Classes = u16;
pub const max_classes = @bitSizeOf(Classes);

pub const Models = struct {
    /// How a kind's clients step it otherwise than the server: the kind says.
    pub const Configuration = struct {
        /// The phases a client's own tick count can put its step in, counted from when it was sent
        /// the entity: items at rest move on (tickCount + id) % 4. One where the step reads none.
        phases: u8 = 1,
        /// How many sets of rules releases step the entity by, and which a protocol's is. The
        /// server's own are the first.
        rule_sets: u8 = 1,
        rules: ?*const fn (protocol: i32) u8 = null,
        /// How far apart a model may be from the entity on an axis, its motion added, before its
        /// viewers are owed a correction.
        tolerance: f64 = 1.0 / 16.0,
    };
    /// What the sync knows of protocols: how many ways they round a velocity, and which a
    /// protocol's is.
    pub const Roundings = struct { count: u8, of: *const fn (protocol: i32) u8 };
    pub const Dependencies = struct { players: *const Players, tracking: *const Tracking, pool: *entities.Pool, slots: usize, roundings: Roundings };

    /// A model, the classes whose clients have it, and whether none of them will move it next
    /// tick, as an item at rest moves only on some.
    pub const Entry = struct { model: Model, classes: Classes, still: bool = false };
    const max_models = 4;

    /// What is held of the entity in a slot.
    const Held = struct {
        /// The entity, as a slot comes to hold another.
        id: u64 = 0,
        /// The tick its models are as of: what clients have once they stepped it on each tick since.
        tick: u64 = 0,
        count: u8 = 0,
        /// Classes owed a correction this tick, and whether to bring them as near the entity as a
        /// packet can, what they hold not to be trusted.
        owed: Classes = 0,
        forced: bool = false,
        entries: [max_models]Entry = undefined,
    };

    deps: Dependencies,
    config: Configuration,
    /// Every way a protocol rounds and a release steps: a class's protocol rounding and rules.
    sets: u8,
    /// Words of player bits a row is kept in, a power of two so a slot's rows share a page, and
    /// words of them in use.
    words: usize,
    row_words: usize,
    held: entities.Array(Held),
    /// By slot, the phase each viewer's tick count began in: its low bit's row, then its high bit's.
    phase_rows: entities.Array(usize),
    /// By rounding and rules, the players whose clients go by them.
    rule_rows: []usize,
    /// Rows to work in.
    scratch: []usize,
    /// Slots owed a correction this tick, for their sync to visit.
    owing: IndexSet,
    /// The server tick under way: the sync's count of the ticks it sent.
    now: u64 = 0,
    /// The slot being stepped, and what its models were before.
    stepping: ?u32 = null,
    before: [max_models]Entry = undefined,
    /// Classes a step found no room for, which are then owed a correction.
    unplaced: Classes = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !Models {
        if (config.phases == 0 or config.rule_sets == 0 or deps.roundings.count == 0) return error.InvalidConfiguration;
        const sets = @as(usize, deps.roundings.count) * config.rule_sets;
        if (sets * config.phases > max_classes) return error.InvalidConfiguration;
        if (config.phases & (config.phases - 1) != 0 or config.phases > 4) return error.InvalidConfiguration;
        if ((config.rule_sets > 1) != (config.rules != null)) return error.InvalidConfiguration;
        if (!(config.tolerance > 0)) return error.InvalidConfiguration;
        const words = deps.tracking.words;
        return .{
            .deps = deps,
            .config = config,
            .sets = @intCast(sets),
            .words = words,
            .row_words = deps.tracking.row_words,
            .held = try .init(allocator, deps.pool),
            .phase_rows = try .init(allocator, deps.pool),
            .rule_rows = try allocator.alloc(usize, sets * words),
            .scratch = try allocator.alloc(usize, words),
            .owing = try .init(allocator, @max(1, deps.slots)),
        };
    }

    /// How many classes there are.
    pub fn classCount(self: *const Models) u8 {
        return self.sets * self.config.phases;
    }

    /// Every class there is.
    pub fn all(self: *const Models) Classes {
        return @truncate((@as(u32, 1) << @intCast(self.classCount())) - 1);
    }

    /// The set of rules a class's release steps by.
    pub fn rulesOf(self: *const Models, class: u8) u8 {
        return class / self.config.phases % self.config.rule_sets;
    }

    /// How a class's protocol rounds a velocity.
    pub fn roundingOf(self: *const Models, class: u8) u8 {
        return class / self.config.phases / self.config.rule_sets;
    }

    /// The phase a class's tick count began in.
    pub fn phaseOf(self: *const Models, class: u8) u8 {
        return class % self.config.phases;
    }

    /// The classes of a rounding and rules whose tick counts begin now.
    pub fn startingClass(self: *const Models, set: u8) u8 {
        return set * self.config.phases + @as(u8, @intCast(self.now % self.config.phases));
    }

    /// What the tick count of a class's clients is now, but for whole turns of its phases: their
    /// count began at one on the tick after they were sent it.
    pub fn ticksOf(self: *const Models, class: u8) u32 {
        const phases: u64 = self.config.phases;
        return @intCast((self.now % phases + phases - self.phaseOf(class)) % phases);
    }

    fn ruleRow(self: *const Models, set: u8) []usize {
        return self.rule_rows[@as(usize, set) * self.words ..][0..self.words];
    }

    /// The rounding and rules a protocol's clients go by.
    fn setOf(self: *const Models, protocol: i32) u8 {
        const rules: u8 = if (self.config.rules) |of| of(protocol) else 0;
        const rounding = self.deps.roundings.of(protocol);
        assert(rules < self.config.rule_sets and rounding < self.deps.roundings.count);
        return rounding * self.config.rule_sets + rules;
    }

    /// The tick is over: the next begins.
    pub fn advance(self: *Models) void {
        self.now += 1;
        self.refresh();
    }

    /// Each player's rounding and rules, read again: a slot comes to hold another player.
    pub fn refresh(self: *Models) void {
        @memset(self.rule_rows, 0);
        for (self.deps.players.activeSlots()) |player| mark(self.ruleRow(self.setOf(self.deps.players.records[player].protocol)), player);
    }

    fn mark(words: []usize, player: usize) void {
        words[player / 64] |= @as(usize, 1) << @intCast(player % 64);
    }

    fn phaseRows(self: *const Models, slot: u32) []usize {
        const stride = 2 * self.words;
        return self.phase_rows.run(@as(usize, slot) * stride, @as(usize, slot) * stride + stride).?;
    }

    /// The players among `among` in a class, into `out`.
    pub fn viewersOf(self: *const Models, slot: u32, class: u8, among: bit_sets.Set, out: []usize) bit_sets.Set {
        const set_row = self.ruleRow(class / self.config.phases);
        const phase = self.phaseOf(class);
        const phased = self.config.phases > 1 and slot < self.phase_rows.len / (2 * self.words);
        const rows: []const usize = if (phased) self.phaseRows(slot) else &.{};
        for (out[0..self.row_words], 0..) |*word, at| {
            var value = among.wordAt(at) & set_row[at];
            if (self.config.phases > 1) {
                const low: usize = if (phased) rows[at] else 0;
                const high: usize = if (phased) rows[self.words + at] else 0;
                value &= if (phase & 1 != 0) low else ~low;
                if (self.config.phases > 2) value &= if (phase & 2 != 0) high else ~high;
            }
            word.* = value;
        }
        return .{ .words = out[0..self.row_words], .capacity = self.deps.players.records.len };
    }

    /// The class a player is in for the entity in a slot.
    pub fn classOf(self: *const Models, slot: u32, player: usize) u8 {
        var phase: u8 = 0;
        if (self.config.phases > 1 and slot < self.phase_rows.len / (2 * self.words)) {
            const rows = self.phaseRows(slot);
            const bit = @as(usize, 1) << @intCast(player % 64);
            if (rows[player / 64] & bit != 0) phase |= 1;
            if (rows[self.words + player / 64] & bit != 0) phase |= 2;
        }
        return self.setOf(self.deps.players.records[player].protocol) * self.config.phases + phase;
    }

    /// The classes with a viewer among `among`.
    pub fn present(self: *const Models, slot: u32, among: bit_sets.Set) Classes {
        var classes: Classes = 0;
        var anyone = false;
        for (0..self.row_words) |at| anyone = anyone or among.wordAt(at) != 0;
        if (!anyone) return 0;
        for (0..self.classCount()) |class| {
            const viewers = self.viewersOf(slot, @intCast(class), among, self.scratch);
            if (viewers.any()) classes |= @as(Classes, 1) << @intCast(class);
        }
        return classes;
    }

    /// Players sent the entity this tick: their tick counts begin now, which puts them in this
    /// tick's phase.
    pub fn began(self: *Models, slot: u32, players: bit_sets.Set) !void {
        if (self.config.phases == 1) return;
        try self.phase_rows.ensureFilled((@as(usize, slot) + 1) * 2 * self.words, 0);
        const rows = self.phaseRows(slot);
        const phase = self.now % self.config.phases;
        for (0..self.row_words) |at| {
            const word = players.wordAt(at);
            rows[at] = if (phase & 1 != 0) rows[at] | word else rows[at] & ~word;
            rows[self.words + at] = if (phase & 2 != 0) rows[self.words + at] | word else rows[self.words + at] & ~word;
        }
    }

    fn heldOf(self: *Models, slot: u32, id: u64) !*Held {
        try self.held.ensureFilled(@as(usize, slot) + 1, .{});
        const held = self.held.at(slot);
        if (held.id != id) held.* = .{ .id = id, .tick = self.now };
        return held;
    }

    // Stepping, by the kind.

    /// A step of the entity in a slot begins: the models to step, as of the last tick, each with
    /// the classes holding it. The kind steps each for each class as those clients step it, gives
    /// what it computed to `put`, and then `judge`s them against the entity. Models not stepped on
    /// the last tick are not what clients have now, and are let go: their viewers are owed one.
    /// Null where there is nothing to judge, no model and no viewer.
    pub fn begin(self: *Models, slot: u32, id: u64) !?[]const Entry {
        assert(self.stepping == null);
        if (slot >= self.held.len and !self.deps.tracking.known(slot).any()) return null;
        const held = try self.heldOf(slot, id);
        const current = held.tick + 1 == self.now;
        const count: usize = if (current) held.count else 0;
        @memcpy(self.before[0..count], held.entries[0..count]);
        held.count = 0;
        held.tick = self.now;
        self.stepping = slot;
        self.unplaced = 0;
        return self.before[0..count];
    }

    /// What the clients of some classes computed this tick, and whether they will not move it next.
    pub fn put(self: *Models, model: Model, classes: Classes, still: bool) void {
        const held = self.held.at(self.stepping.?);
        if (!place(held, model, classes, still)) self.unplaced |= classes;
    }

    /// Adds classes to the entry holding a model, or to a new one: whether there was room.
    fn place(held: *Held, model: Model, classes: Classes, still: bool) bool {
        if (classes == 0) return true;
        for (held.entries[0..held.count]) |*entry| if (entry.model.eql(model)) {
            entry.classes |= classes;
            entry.still = entry.still and still;
            return true;
        };
        if (held.count == max_models) return false;
        held.entries[held.count] = .{ .model = model, .classes = classes, .still = still };
        held.count += 1;
        return true;
    }

    /// Takes classes from every entry, and the entries left with none.
    fn take(held: *Held, classes: Classes) void {
        var kept: u8 = 0;
        for (held.entries[0..held.count]) |entry| {
            const left = entry.classes & ~classes;
            if (left == 0) continue;
            held.entries[kept] = .{ .model = entry.model, .classes = left, .still = entry.still };
            kept += 1;
        }
        held.count = kept;
    }

    /// The step is over: each model is held to the entity as it now is. Those that would look
    /// apart from it, and the classes with a viewer and no model, are owed a correction; what they
    /// hold stays, for the sync to correct from. Models no viewer holds go.
    pub fn judge(self: *Models, truth: Model) void {
        const slot = self.stepping.?;
        self.stepping = null;
        const held = self.held.at(slot);
        const viewing = self.present(slot, self.deps.tracking.known(slot));
        var owed: Classes = self.unplaced & viewing;
        var covered: Classes = 0;
        var kept: u8 = 0;
        for (held.entries[0..held.count]) |entry| {
            const classes = entry.classes & viewing;
            if (classes == 0) continue;
            covered |= classes;
            if (entry.model.apart(truth, self.config.tolerance, entry.still)) owed |= classes;
            held.entries[kept] = .{ .model = entry.model, .classes = classes, .still = entry.still };
            kept += 1;
        }
        held.count = kept;
        owed |= viewing & ~covered;
        held.owed |= owed;
        if (held.owed != 0) self.owing.insert(slot);
    }

    // Sending, by the sync.

    pub const Owed = struct { classes: Classes = 0, forced: bool = false };

    /// The classes owed a correction for the entity in a slot this tick, now no longer owed.
    pub fn takeOwed(self: *Models, slot: u32) Owed {
        if (slot >= self.held.len) return .{};
        const held = self.held.at(slot);
        const owed: Owed = .{ .classes = held.owed, .forced = held.forced };
        held.owed = 0;
        held.forced = false;
        self.owing.remove(slot);
        return owed;
    }

    /// Some classes were sent the entity so that their clients have `model` now.
    pub fn assign(self: *Models, slot: u32, id: u64, classes: Classes, model: Model) !void {
        const held = try self.heldOf(slot, id);
        // Models not stepped this tick are not what clients have now.
        if (held.tick != self.now) {
            held.count = 0;
            held.tick = self.now;
        }
        if (classes == 0) return;
        take(held, classes);
        // What was sent is not known to stand still. Past room, the classes held longest go, and
        // their viewers are owed a correction when it is next judged.
        if (place(held, model, classes, false)) return;
        held.count -= 1;
        assert(place(held, model, classes, false));
    }

    /// What a class's clients have of the entity in a slot now, if it is known.
    pub fn modelOf(self: *const Models, slot: u32, id: u64, class: u8) ?Model {
        if (slot >= self.held.len) return null;
        const held = self.held.at(slot);
        if (held.id != id or held.tick != self.now) return null;
        return entryOf(held, class);
    }

    /// What a class's clients had of the entity in a slot when the last tick was over, if it is
    /// known: for traces, which read between ticks.
    pub fn lastModelOf(self: *const Models, slot: u32, id: u64, class: u8) ?Model {
        if (slot >= self.held.len) return null;
        const held = self.held.at(slot);
        if (held.id != id or held.tick + 1 != self.now) return null;
        return entryOf(held, class);
    }

    fn entryOf(held: *const Held, class: u8) ?Model {
        for (held.entries[0..held.count]) |entry| if (entry.classes & (@as(Classes, 1) << @intCast(class)) != 0) return entry.model;
        return null;
    }

    /// What clients have of the entity in a slot may be wrong, as when blocks it moves among
    /// changed this tick, which clients learn only after their step: every viewer is owed one.
    pub fn disturb(self: *Models, slot: u32) void {
        if (slot >= self.held.len or self.held.at(slot).id == 0) return;
        self.held.at(slot).owed = self.all();
        self.held.at(slot).forced = true;
        self.owing.insert(slot);
    }

    /// A player's client stepped `ticks` fewer than the server (more, negative): its tick count
    /// for every entity it has is that far from what its phase said, so it is in another phase.
    pub fn shift(self: *Models, player: usize, ticks: i64) void {
        if (self.config.phases == 1) return;
        const phases: i64 = self.config.phases;
        const bit = @as(usize, 1) << @intCast(player % 64);
        const at = player / 64;
        for (0..self.phase_rows.len / (2 * self.words)) |slot| {
            const rows = self.phaseRows(@intCast(slot));
            var phase: i64 = 0;
            if (rows[at] & bit != 0) phase |= 1;
            if (rows[self.words + at] & bit != 0) phase |= 2;
            const moved: u8 = @intCast(@mod(phase + ticks, phases));
            rows[at] = if (moved & 1 != 0) rows[at] | bit else rows[at] & ~bit;
            rows[self.words + at] = if (moved & 2 != 0) rows[self.words + at] | bit else rows[self.words + at] & ~bit;
        }
    }

    /// The entity in a slot is let go.
    pub fn forget(self: *Models, slot: u32) void {
        if (slot < self.held.len) self.held.at(slot).* = .{};
        if (slot < self.owing.positions.len) self.owing.remove(slot);
    }
};

/// Whether each viewer's client stepped as many ticks as the server since it was last held to
/// it. A client frozen past what it catches up loses ticks for good, and one whose server lags
/// steps more: its entities are then ahead or behind of what it was sent, and its tick counts in
/// another phase. Each client says when it ends a tick; the server ticks less the client ticks
/// heard is steady but for the jitter of their way here, so only a shift past `margin`, held for
/// a window, counts.
pub const Drift = struct {
    pub const Shift = struct { player: usize, ticks: i64 };
    const window = 40;
    const margin = 3;

    /// By player: its server ticks less client ticks as last settled, the lowest of them in the
    /// window under way, and the session it is of.
    base: []i64,
    low: []i64,
    generation: []u32,
    known: []bool,
    /// Ticks since it was first heard, as a client's tick ends settle once it has loaded.
    settling: []u32,
    shifts: []Shift,

    pub fn init(allocator: std.mem.Allocator, players: usize) !Drift {
        const self: Drift = .{
            .base = try allocator.alloc(i64, players),
            .low = try allocator.alloc(i64, players),
            .generation = try allocator.alloc(u32, players),
            .known = try allocator.alloc(bool, players),
            .settling = try allocator.alloc(u32, players),
            .shifts = try allocator.alloc(Shift, players),
        };
        @memset(self.known, false);
        return self;
    }

    /// The players whose clients drifted this tick, each by how many ticks it fell behind the
    /// server (or, negative, ran ahead). Good until the next check.
    pub fn check(self: *Drift, players: *const Players, now: u64) []const Shift {
        var count: usize = 0;
        const turn = now % window == 0;
        for (players.activeSlots()) |player| {
            const record = &players.records[player];
            const handle = record.handle orelse continue;
            // One whose client never said it ended a tick, as a bot or a bench's, is not measured.
            if (record.stage != .ready or !record.loaded or record.client_ticks == 0) {
                self.known[player] = false;
                continue;
            }
            const lag = @as(i64, @intCast(now)) - @as(i64, @intCast(record.client_ticks));
            if (!self.known[player] or self.generation[player] != handle.generation) {
                self.known[player] = true;
                self.generation[player] = handle.generation;
                self.base[player] = lag;
                self.low[player] = lag;
                self.settling[player] = 0;
                continue;
            }
            // While its client catches up on loading, what it is held to follows it.
            if (self.settling[player] < window) {
                self.settling[player] += 1;
                self.base[player] = lag;
                self.low[player] = lag;
                continue;
            }
            // Ahead: its ticks come faster than the server's, which no jitter does for long.
            if (lag <= self.base[player] - margin) {
                self.shifts[count] = .{ .player = player, .ticks = lag - self.base[player] };
                count += 1;
                self.base[player] = lag;
                self.low[player] = lag;
                continue;
            }
            self.low[player] = @min(self.low[player], lag);
            if (!turn) continue;
            // Behind the whole window through: ticks it lost.
            if (self.low[player] >= self.base[player] + margin) {
                self.shifts[count] = .{ .player = player, .ticks = self.low[player] - self.base[player] };
                count += 1;
                self.base[player] = self.low[player];
            }
            self.low[player] = lag;
        }
        return self.shifts[0..count];
    }
};
