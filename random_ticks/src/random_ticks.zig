//! Random ticks: vanilla picks `speed` random cells of every ticking section each game tick and
//! ticks the ones whose block ticks randomly. A cell is picked with probability speed/4096 each
//! tick, independent of every other cell. This engine draws the same process without visiting
//! idle sections: a section with n acting cells waits a geometric number of picks, with success
//! n/4096, until its next hit, and a hit ticks one of its acting cells, chosen uniformly.
//!
//! A cell acts when a rule of the layer plugins registered says a hit on it could change
//! something. A hit on any other cell would do nothing in vanilla, so leaving those out keeps
//! every acting cell's rate. Counts come from a topology the chunk store keeps in the derived
//! cache, so a column entering the ticking domain costs one record read, and edits ask again for
//! the columns they reach. The terrain thread does every block read counting takes.

const std = @import("std");
const chunks = @import("chunks");
const Domains = @import("domains").domains.Domains;
const DomainColumn = @import("domains").domains.Column;
const Worlds = @import("worlds").Worlds;

const assert = std.debug.assert;
const layer = chunks.layer;
const Topology = chunks.topology.Topology;

pub const Set = layer.Set;
pub const Node = layer.Node;
pub const Rule = layer.Rule;

pub const Hit = struct {
    world: u32,
    position: chunks.Position,
    state: u16,
    /// The sections around the hit, read once for every hit on its section.
    blocks: *const Blocks,
};

/// The sections around a hit section, leased for its hits. A read is null outside them. Writes
/// wait until the hit ends and then apply together, as an edit cannot change a section while
/// it is leased. Reads see the hit's own writes.
pub const Blocks = struct {
    owner: *RandomTicks,
    center: chunks.Section,

    pub fn get(self: *const Blocks, position: chunks.Position) ?u16 {
        var index = self.owner.writes_count;
        while (index > 0) {
            index -= 1;
            const write = self.owner.writes[index];
            if (std.meta.eql(write.position, position)) return write.state;
        }
        // Another plugin may have edited blocks during the hit, behind the leased copies.
        if (self.owner.edited) return null;
        const x = @divFloor(position.x, 16) - self.center.x;
        const y = @divFloor(position.y, 16) - self.center.y;
        const z = @divFloor(position.z, 16) - self.center.z;
        if (@abs(x) > 1 or @abs(y) > 1 or @abs(z) > 1) return null;
        const lease = self.owner.around[layer.neighbour(@intCast(x), @intCast(y), @intCast(z))] orelse return null;
        return lease.get(chunks.localIndex(position));
    }

    pub fn set(self: *const Blocks, position: chunks.Position, state: u16) !void {
        const owner = self.owner;
        if (owner.writes_count == owner.writes.len) return error.HitWriteCapacity;
        owner.writes[owner.writes_count] = .{ .position = position, .state = state };
        owner.writes_count += 1;
    }
};

const Write = struct { position: chunks.Position, state: u16 };

pub const Handler = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, Hit) anyerror!void,

    pub fn init(comptime Context: type, context: *Context, comptime run: fn (*Context, Hit) anyerror!void) Handler {
        const Adapter = struct {
            fn call(raw: *anyopaque, hit: Hit) anyerror!void {
                return run(@ptrCast(@alignCast(raw)), hit);
            }
        };
        return .{ .context = context, .run = Adapter.call };
    }
};

/// What ticks randomly and what runs when it does. Plugins define sets of block states and
/// register rules over them while the server starts: the cells a rule selects tick where its
/// expression holds. Compose it before them and RandomTicks after them. RandomTicks seals it,
/// as the counts it persists are keyed by the layer the rules make.
const RandomTickRegistry = struct {
    pub const id = "lightning_rod:random_tick_registry";

    pub const Configuration = struct {
        /// Block states, the length of the set table.
        states: u16 = 0,
    };

    pub const none = std.math.maxInt(u8);

    /// The sets each block state is in, one bit per set.
    properties: []u8,
    sets: u8 = 0,
    layer: layer.Layer,
    handlers: [layer.rules_max]Handler = undefined,
    /// The rule of each block state, or none for states that do not tick. Filled when sealed.
    by_state: []u8,
    sealed: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !*RandomTickRegistry {
        if (config.states == 0) return error.InvalidConfiguration;
        const self = try allocator.create(RandomTickRegistry);
        const properties = try allocator.alloc(u8, config.states);
        @memset(properties, 0);
        self.* = .{ .properties = properties, .layer = .init(properties), .by_state = try allocator.alloc(u8, config.states) };
        @memset(self.by_state, none);
        return self;
    }

    pub fn addSet(self: *RandomTickRegistry) !Set {
        if (self.sealed) return error.RandomTicksStarted;
        if (self.sets == layer.sets_max) return error.SetCapacity;
        defer self.sets += 1;
        return @intCast(self.sets);
    }

    pub fn include(self: *RandomTickRegistry, set: Set, state: u16) void {
        assert(!self.sealed and set < self.sets);
        self.properties[state] |= @as(u8, 1) << set;
    }

    /// Runs `handler` when a hit lands on a cell `rule` says acts.
    pub fn register(self: *RandomTickRegistry, rule: Rule, handler: Handler) !void {
        if (self.sealed) return error.RandomTicksStarted;
        if (rule.selected >= self.sets) return error.UnknownSet;
        for (rule.nodes) |node| switch (node) {
            .set => |set| if (set >= self.sets) return error.UnknownSet,
            else => {},
        };
        const index = self.layer.count;
        try self.layer.add(rule);
        self.handlers[index] = handler;
    }

    fn seal(self: *RandomTickRegistry) !void {
        assert(!self.sealed);
        self.sealed = true;
        var selected: [layer.rules_max]usize = @splat(0);
        for (self.properties, self.by_state) |sets, *rule_index| {
            for (self.layer.selected[0..self.layer.count], 0..) |selected_set, index| {
                if (sets & (@as(u8, 1) << selected_set) == 0) continue;
                if (rule_index.* != none) return error.DuplicateHandler;
                rule_index.* = @intCast(index);
                selected[index] += 1;
            }
        }
        for (selected[0..self.layer.count]) |count| if (count == 0) return error.NoStates;
    }
};

pub const RandomTicks = struct {
    pub const id = "lightning_rod:random_ticks";
    pub const Registry = RandomTickRegistry;

    pub const Configuration = struct {
        /// Cells vanilla picks in each section per game tick, its randomTickSpeed.
        speed: u8 = 3,
        /// Sections with acting cells tracked at once, each with its 512 byte mask.
        sections: u32 = 1 << 13,
        /// Columns asked for and not yet answered.
        requests: u32 = 64,
        /// Masks answers may carry at once. Each request holds one per section.
        masks: u32 = 2048,
        seed: u64 = 0x72616e646f6d,
    };

    pub const Dependencies = struct {
        domains: *Domains,
        chunks: *chunks.Chunks,
        worlds: *Worlds,
        registry: *Registry,
    };

    const none = std.math.maxInt(u32);
    const sections_max = chunks.topology.sections_max;

    const ColumnState = struct {
        world: u32,
        x: i32,
        z: i32,
        minimum: i32 = 0,
        count: u8 = 0,
        counts: [sections_max]u16 = @splat(0),
        /// Tracked section slots with acting cells, by section.
        slots: [sections_max]u32 = @splat(none),
        /// Asked for, or about to be.
        asking: bool = false,
        /// In the list of columns to ask for.
        queued: bool = false,
        /// An edit reached the column after it was asked for, so the answer is out of date.
        answer_stale: bool = false,
        /// Sections an edit may have changed what acts in, counted again on this thread before
        /// the next hit.
        recount: u32 = 0,
        live: bool = false,
        next_free: u32 = none,
    };

    const SectionSlot = struct {
        column: u32,
        offset: u8,
        /// The pick that hits next, counting `speed` picks per game tick.
        next: u64,
        heap: u32,
        next_free: u32,
        /// The acting cells, as the topology found them.
        mask: chunks.topology.Mask = undefined,
    };

    deps: Dependencies,
    config: Configuration,
    topology: *Topology,
    client: chunks.Chunks.Client,
    random: std.Random.DefaultPrng,
    column_states: []ColumnState,
    column_free: u32 = 0,
    by_column: []u32,
    slots: []SectionSlot,
    slot_free: u32 = 0,
    heap: []u32,
    heap_count: u32 = 0,
    /// Columns to ask for, each at most once.
    unasked: []u32,
    unasked_count: u32 = 0,
    /// Columns with sections to count again, each at most once.
    recounting: []u32,
    recounting_count: u32 = 0,
    /// Counts a section's acting cells here, as terrain does for a whole column.
    workspace: *layer.Workspace,
    recount_mask: chunks.topology.Mask = undefined,
    /// The masks of the answer being taken.
    answer_masks: *[sections_max]chunks.topology.Mask,
    /// The sections around the section being hit, by `layer.neighbour`. The section itself is
    /// always leased. The others only when memory holds them already.
    around: [27]?chunks.Lease = @splat(null),
    held: [27]chunks.Lease = undefined,
    held_count: usize = 0,
    /// Writes of the hit being run, applied when it ends.
    writes: [64]Write = undefined,
    writes_count: usize = 0,
    /// Set by every edit, so a hit knows its leased copies may be out of date.
    edited: bool = false,
    /// The game tick whose picks come next.
    tick_count: u64 = 0,
    /// The next pick not drawn yet. Counts that change draw their next hit from here.
    cursor: u64 = 0,
    overflow: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*RandomTicks {
        if (config.speed == 0 or config.sections == 0 or config.requests == 0) return error.InvalidConfiguration;
        // Every column Domains may tick, as players spread out can bring all of them at once.
        const columns = deps.domains.capacity();
        if (columns >= none) return error.InvalidConfiguration;
        try deps.registry.seal();
        const self = try allocator.create(RandomTicks);
        const column_states = try allocator.alloc(ColumnState, columns);
        for (column_states, 0..) |*state, index| state.* = .{ .world = 0, .x = 0, .z = 0, .next_free = if (index + 1 < column_states.len) @intCast(index + 1) else none };
        const slots = try allocator.alloc(SectionSlot, config.sections);
        for (slots, 0..) |*slot, index| slot.* = .{ .column = none, .offset = 0, .next = 0, .heap = none, .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none };
        const by_column = try allocator.alloc(u32, try std.math.ceilPowerOfTwo(usize, 2 * columns));
        @memset(by_column, none);
        self.* = .{
            .deps = deps,
            .config = config,
            .topology = try deps.chunks.openTopology(allocator, &deps.registry.layer, id, config.requests, config.masks),
            .client = try deps.chunks.simulation(27),
            .random = .init(config.seed),
            .column_states = column_states,
            .by_column = by_column,
            .slots = slots,
            .heap = try allocator.alloc(u32, config.sections),
            .unasked = try allocator.alloc(u32, columns),
            .recounting = try allocator.alloc(u32, columns),
            .workspace = try allocator.create(layer.Workspace),
            .answer_masks = try allocator.create([sections_max]chunks.topology.Mask),
        };
        try deps.domains.observe(.init(RandomTicks, self, domainChanged));
        try deps.chunks.observe(.init(self, blocksChanged));
        return self;
    }

    fn domainChanged(self: *RandomTicks, entered: []const DomainColumn, left: []const DomainColumn) void {
        for (left) |column| if (self.find(column.world, column.x, column.z)) |at| self.dropColumn(at);
        for (entered) |column| {
            if (self.find(column.world, column.x, column.z) != null) continue;
            const world = self.deps.worlds.get(column.world) orelse continue;
            const count = world.dimension.sectionCount();
            if (count == 0 or count > sections_max) continue;
            const index = self.column_free;
            if (index == none) {
                self.overflow = true;
                continue;
            }
            self.column_free = self.column_states[index].next_free;
            self.column_states[index] = .{ .world = column.world, .x = column.x, .z = column.z, .minimum = world.dimension.minimumSection(), .count = @intCast(count), .asking = true, .live = true };
            var at = self.home(column.world, column.x, column.z);
            while (self.by_column[at] != none) at = (at + 1) & (self.by_column.len - 1);
            self.by_column[at] = index;
            self.pushUnasked(index);
        }
    }

    fn pushUnasked(self: *RandomTicks, index: u32) void {
        const state = &self.column_states[index];
        if (state.queued) return;
        // Every column is queued at most once, and there are no more columns.
        assert(self.unasked_count < self.unasked.len);
        state.queued = true;
        self.unasked[self.unasked_count] = index;
        self.unasked_count += 1;
    }

    /// Asks again for the columns the edits can change what acts in. Only cells whose sets
    /// changed matter, and only as far as the layer reaches.
    fn blocksChanged(self: *RandomTicks, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        self.edited = true;
        const properties = self.deps.registry.properties;
        var low: [3]i32 = @splat(16);
        var high: [3]i32 = @splat(-1);
        for (edits, previous) |edit, old| {
            if (properties[edit.state] == properties[old]) continue;
            const cell = [3]i32{ edit.index & 15, edit.index >> 8, (edit.index >> 4) & 15 };
            for (0..3) |axis| {
                low[axis] = @min(low[axis], cell[axis]);
                high[axis] = @max(high[axis], cell[axis]);
            }
        }
        if (high[0] < 0) return;
        const influence = self.deps.registry.layer.influence;
        // A cell reads cells up to `influence` away, so an edit reaches cells that far back.
        const from_x = @divFloor(low[0] - influence.high[0], 16);
        const to_x = @divFloor(high[0] - influence.low[0], 16);
        const from_y = @divFloor(low[1] - influence.high[1], 16);
        const to_y = @divFloor(high[1] - influence.low[1], 16);
        const from_z = @divFloor(low[2] - influence.high[2], 16);
        const to_z = @divFloor(high[2] - influence.low[2], 16);
        var z = from_z;
        while (z <= to_z) : (z += 1) {
            var x = from_x;
            while (x <= to_x) : (x += 1) {
                // Columns past the edge of the coordinate range do not exist.
                const column_x = std.math.add(i32, section.x, x) catch continue;
                const column_z = std.math.add(i32, section.z, z) catch continue;
                self.markRecount(section.world, column_x, column_z, section.y + from_y, section.y + to_y);
            }
        }
    }

    /// Marks the sections from `from` to `to` of a column to count again here. A column still
    /// waiting for its first count is asked for again instead, as that answer may miss the edit.
    fn markRecount(self: *RandomTicks, world: u32, x: i32, z: i32, from: i32, to: i32) void {
        const at = self.find(world, x, z) orelse return;
        const index = self.by_column[at];
        const state = &self.column_states[index];
        if (state.asking) {
            state.answer_stale = true;
            return;
        }
        const bottom = @max(from, state.minimum);
        const top = @min(to, state.minimum + @as(i32, state.count) - 1);
        if (bottom > top) return;
        const was = state.recount;
        var y = bottom;
        while (y <= top) : (y += 1) state.recount |= @as(u32, 1) << @intCast(y - state.minimum);
        if (was != 0) return;
        // Every column is listed at most once, and there are no more columns.
        assert(self.recounting_count < self.recounting.len);
        self.recounting[self.recounting_count] = index;
        self.recounting_count += 1;
    }

    /// Counts again the sections edits marked, on this thread, so a hit never waits for terrain.
    /// A section with a neighbour memory does not hold, which may be on disk, has its column
    /// counted by terrain instead.
    fn recount(self: *RandomTicks) !void {
        while (self.recounting_count != 0) {
            self.recounting_count -= 1;
            const index = self.recounting[self.recounting_count];
            const state = &self.column_states[index];
            var pending = state.recount;
            state.recount = 0;
            if (!state.live or state.asking) continue;
            while (pending != 0) : (pending &= pending - 1) {
                if (try self.recountSection(index, @intCast(@ctz(pending)))) continue;
                state.asking = true;
                self.pushUnasked(index);
                break;
            }
        }
    }

    fn recountSection(self: *RandomTicks, index: u32, offset: u8) !bool {
        const state = self.column_states[index];
        const center: chunks.Section = .{ .world = state.world, .x = state.x, .z = state.z, .y = state.minimum + offset };
        try self.leaseAround(center, state.minimum, state.count);
        defer self.releaseAround();
        const middle = layer.neighbour(0, 0, 0);
        var sections: layer.Neighbourhood = @splat(null);
        // A section with no stored record holds air, as terrain reads it.
        sections[middle] = self.around[middle].?.record.bytes;
        const registry_layer = &self.deps.registry.layer;
        const wanted = try registry_layer.candidates(sections[middle]);
        if (wanted.neighbours) for (0..27) |at| {
            if (at == middle) continue;
            const y = center.y + @as(i32, @intCast(at / 9)) - 1;
            // Past the world's height and the coordinate range there is only air.
            if (y < state.minimum or y >= state.minimum + @as(i32, state.count)) continue;
            _ = std.math.add(i32, center.x, @as(i32, @intCast(at % 3)) - 1) catch continue;
            _ = std.math.add(i32, center.z, @as(i32, @intCast(at / 3 % 3)) - 1) catch continue;
            const lease = self.around[at] orelse return false;
            sections[at] = lease.record.bytes;
        };
        const count = try registry_layer.evaluate(self.workspace, &sections, &self.recount_mask);
        self.setCount(index, offset, count, self.cursor);
        if (count != 0) {
            const slot = self.column_states[index].slots[offset];
            if (slot != none) self.slots[slot].mask = self.recount_mask;
        }
        return true;
    }

    pub fn tick(self: *RandomTicks) !void {
        if (self.overflow) return error.RandomTickCapacity;
        self.collect();
        // Edits since the last tick, by anyone, before the first hit.
        try self.recount();
        const start = self.tick_count * self.config.speed;
        const end = start + self.config.speed;
        self.cursor = @max(self.cursor, start);
        while (self.heap_count != 0) {
            const slot_index = self.heap[0];
            if (self.slots[slot_index].next >= end) break;
            try self.hitSection(slot_index, end);
        }
        self.tick_count += 1;
        self.cursor = end;
    }

    /// Takes answers and asks for columns still unasked.
    fn collect(self: *RandomTicks) void {
        while (self.topology.take(self.answer_masks)) |answer| self.apply(answer);
        if (self.unasked_count == 0) return;
        var columns: [64]chunks.topology.Column = undefined;
        var begin: u32 = 0;
        while (begin < self.unasked_count) {
            const batch = @min(columns.len, self.unasked_count - begin);
            for (self.unasked[begin..][0..batch], columns[0..batch]) |index, *column| {
                const state = &self.column_states[index];
                column.* = .{ .world = state.world, .x = state.x, .z = state.z, .minimum = state.minimum, .count = state.count };
            }
            const accepted = self.topology.request(columns[0..batch]);
            // What is asked for now is read after every edit made so far.
            for (self.unasked[begin..][0..accepted]) |index| {
                self.column_states[index].answer_stale = false;
                self.column_states[index].queued = false;
            }
            begin += @intCast(accepted);
            if (accepted < batch) break;
        }
        std.mem.copyForwards(u32, self.unasked[0 .. self.unasked_count - begin], self.unasked[begin..self.unasked_count]);
        self.unasked_count -= begin;
    }

    fn apply(self: *RandomTicks, answer: chunks.topology.Answer) void {
        const column = answer.column;
        // The column may have left the domain, and maybe come back, since it was asked for.
        const at = self.find(column.world, column.x, column.z) orelse return;
        const index = self.by_column[at];
        const state = &self.column_states[index];
        if (!state.asking) return;
        if (state.answer_stale or answer.result == .unavailable) {
            self.pushUnasked(index);
            return;
        }
        state.asking = false;
        var mask: usize = 0;
        for (0..state.count) |offset| {
            const count = answer.counts[offset];
            self.setCount(index, @intCast(offset), count, self.cursor);
            if (count == 0) continue;
            const slot_index = state.slots[offset];
            if (slot_index != none) self.slots[slot_index].mask = self.answer_masks[mask];
            mask += 1;
        }
        assert(mask == answer.masks);
    }

    /// Leases the section, and the sections around it that memory holds already.
    fn leaseAround(self: *RandomTicks, center: chunks.Section, minimum: i32, count: u8) !void {
        assert(self.held_count == 0);
        self.held[0] = try self.client.acquire(center);
        self.held_count = 1;
        self.around[layer.neighbour(0, 0, 0)] = self.held[0];
        for (0..27) |at| {
            if (at == layer.neighbour(0, 0, 0)) continue;
            const y = center.y + @as(i32, @intCast(at / 9)) - 1;
            if (y < minimum or y >= minimum + @as(i32, count)) continue;
            const x = std.math.add(i32, center.x, @as(i32, @intCast(at % 3)) - 1) catch continue;
            const z = std.math.add(i32, center.z, @as(i32, @intCast(at / 3 % 3)) - 1) catch continue;
            const section: chunks.Section = .{ .world = center.world, .x = x, .y = y, .z = z };
            if (!self.client.acquireCached(&.{section}, self.held[self.held_count..][0..1])) continue;
            self.around[at] = self.held[self.held_count];
            self.held_count += 1;
        }
    }

    fn releaseAround(self: *RandomTicks) void {
        self.deps.chunks.releaseMany(self.held[0..self.held_count]);
        self.held_count = 0;
        self.around = @splat(null);
    }

    /// Runs every hit due this tick on one section, reading its sections once.
    fn hitSection(self: *RandomTicks, slot_index: u32, end: u64) !void {
        const column = self.slots[slot_index].column;
        const offset = self.slots[slot_index].offset;
        const state = self.column_states[column];
        const center: chunks.Section = .{ .world = state.world, .x = state.x, .z = state.z, .y = state.minimum + offset };
        var leased = false;
        defer if (leased) self.releaseAround();
        while (true) {
            const slot = &self.slots[slot_index];
            // A hit may have left the section without acting cells, which frees its slot.
            if (slot.column != column or slot.offset != offset or slot.heap == none) return;
            const pick = slot.next;
            if (pick >= end) return;
            self.cursor = pick + 1;
            if (!leased) {
                try self.leaseAround(center, state.minimum, state.count);
                leased = true;
            }
            const cell = self.pickCell(&slot.mask, self.column_states[column].counts[offset]);
            const blocks: Blocks = .{ .owner = self, .center = center };
            const hit: Hit = .{
                .world = state.world,
                .position = .{ .x = state.x * 16 + (cell & 15), .y = center.y * 16 + (cell >> 8), .z = state.z * 16 + ((cell >> 4) & 15) },
                .state = self.around[layer.neighbour(0, 0, 0)].?.get(cell),
                .blocks = &blocks,
            };
            self.edited = false;
            // An edit the answer has not caught up with yet may have left the cell idle.
            const rule = self.deps.registry.by_state[hit.state];
            if (rule != Registry.none) {
                const handler = self.deps.registry.handlers[rule];
                try handler.run(handler.context, hit);
            }
            const after = self.slots[slot_index];
            if (after.column == column and after.offset == offset and after.heap != none and after.next == pick) self.reschedule(slot_index, pick + 1);
            if (self.writes_count != 0 or self.edited) {
                // Edits wait for the leases to go, and the hits left read the blocks again.
                self.releaseAround();
                leased = false;
                try self.applyWrites(state.world);
                self.edited = false;
                // What the writes changed acts, or stops, from the next hit on.
                try self.recount();
            }
        }
    }

    fn applyWrites(self: *RandomTicks, world: u32) !void {
        assert(self.held_count == 0);
        defer self.writes_count = 0;
        for (self.writes[0..self.writes_count]) |write| try self.deps.chunks.setBlock(world, write.position, write.state);
    }

    /// One acting cell of `mask`, uniformly.
    fn pickCell(self: *RandomTicks, mask: *const chunks.topology.Mask, count: u16) u12 {
        assert(count > 0);
        var rank = self.random.random().uintLessThan(u16, count);
        for (mask, 0..) |word, index| {
            const ones: u16 = @popCount(word);
            if (rank < ones) {
                var bits = word;
                for (0..rank) |_| bits &= bits - 1;
                return @intCast(index * 64 + @ctz(bits));
            }
            rank -= ones;
        }
        unreachable;
    }

    fn dropColumn(self: *RandomTicks, at: usize) void {
        const index = self.by_column[at];
        const state = &self.column_states[index];
        for (state.slots) |slot_index| if (slot_index != none) self.freeSlot(slot_index);
        // An answer still coming finds no column and is dropped.
        for (self.unasked[0..self.unasked_count], 0..) |unasked, position| if (unasked == index) {
            self.unasked[position] = self.unasked[self.unasked_count - 1];
            self.unasked_count -= 1;
            break;
        };
        if (state.recount != 0) for (self.recounting[0..self.recounting_count], 0..) |listed, position| if (listed == index) {
            self.recounting[position] = self.recounting[self.recounting_count - 1];
            self.recounting_count -= 1;
            break;
        };
        state.recount = 0;
        self.removeIndex(at);
        state.live = false;
        state.next_free = self.column_free;
        self.column_free = index;
    }

    fn setCount(self: *RandomTicks, column: u32, offset: u8, count: u16, pick: u64) void {
        const state = &self.column_states[column];
        state.counts[offset] = count;
        const slot_index = state.slots[offset];
        if (count == 0) {
            if (slot_index != none) self.freeSlot(slot_index);
            return;
        }
        if (slot_index == none) {
            const index = self.slot_free;
            if (index == none) {
                self.overflow = true;
                return;
            }
            self.slot_free = self.slots[index].next_free;
            self.slots[index] = .{ .column = column, .offset = offset, .next = 0, .heap = none, .next_free = none };
            state.slots[offset] = index;
            self.reschedule(index, pick);
            return;
        }
        // Picks are memoryless, so a new count draws the next hit afresh.
        self.reschedule(slot_index, pick);
    }

    fn reschedule(self: *RandomTicks, slot_index: u32, from: u64) void {
        const slot = &self.slots[slot_index];
        const count = self.column_states[slot.column].counts[slot.offset];
        assert(count > 0);
        slot.next = from + self.gap(count) - 1;
        if (slot.heap == none) self.push(slot_index) else {
            self.siftUp(slot.heap);
            self.siftDown(self.slots[slot_index].heap);
        }
    }

    /// Picks until the next hit, at least one, with success count/4096 per pick.
    fn gap(self: *RandomTicks, count: u16) u64 {
        if (count >= 4096) return 1;
        const p = @as(f64, @floatFromInt(count)) / 4096;
        const u = 1 - self.random.random().float(f64);
        const g = @floor(@log(u) / std.math.log1p(-p));
        return 1 + @as(u64, @intFromFloat(@min(g, 1e15)));
    }

    fn freeSlot(self: *RandomTicks, slot_index: u32) void {
        const slot = &self.slots[slot_index];
        if (slot.heap != none) self.heapRemove(slot.heap);
        self.column_states[slot.column].slots[slot.offset] = none;
        slot.column = none;
        slot.next_free = self.slot_free;
        self.slot_free = slot_index;
    }

    fn home(self: *const RandomTicks, world: u32, x: i32, z: i32) usize {
        var bytes: [12]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], world, .little);
        std.mem.writeInt(i32, bytes[4..8], x, .little);
        std.mem.writeInt(i32, bytes[8..12], z, .little);
        return @intCast(std.hash.Wyhash.hash(0x726e64, &bytes) & (self.by_column.len - 1));
    }

    fn find(self: *const RandomTicks, world: u32, x: i32, z: i32) ?usize {
        var at = self.home(world, x, z);
        while (self.by_column[at] != none) : (at = (at + 1) & (self.by_column.len - 1)) {
            const state = self.column_states[self.by_column[at]];
            if (state.world == world and state.x == x and state.z == z) return at;
        }
        return null;
    }

    fn removeIndex(self: *RandomTicks, start: usize) void {
        const mask = self.by_column.len - 1;
        var hole = start;
        var at = (start + 1) & mask;
        while (self.by_column[at] != none) : (at = (at + 1) & mask) {
            const state = self.column_states[self.by_column[at]];
            const origin = self.home(state.world, state.x, state.z);
            if ((at -% origin) & mask >= (at -% hole) & mask) {
                self.by_column[hole] = self.by_column[at];
                hole = at;
            }
        }
        self.by_column[hole] = none;
    }

    fn place(self: *RandomTicks, at: u32, index: u32) void {
        self.heap[at] = index;
        self.slots[index].heap = at;
    }

    fn push(self: *RandomTicks, index: u32) void {
        assert(self.heap_count < self.heap.len);
        self.heap_count += 1;
        self.place(self.heap_count - 1, index);
        self.siftUp(self.heap_count - 1);
    }

    fn heapRemove(self: *RandomTicks, at: u32) void {
        const removed = self.heap[at];
        self.slots[removed].heap = none;
        self.heap_count -= 1;
        if (at == self.heap_count) return;
        self.place(at, self.heap[self.heap_count]);
        self.siftDown(at);
        self.siftUp(self.slots[self.heap[at]].heap);
    }

    fn siftUp(self: *RandomTicks, start: u32) void {
        var at = start;
        while (at > 0) {
            const parent = (at - 1) / 2;
            if (self.slots[self.heap[at]].next >= self.slots[self.heap[parent]].next) break;
            const moved = self.heap[parent];
            self.place(parent, self.heap[at]);
            self.place(at, moved);
            at = parent;
        }
    }

    fn siftDown(self: *RandomTicks, start: u32) void {
        var at = start;
        while (true) {
            var best = at;
            for ([_]u32{ 2 * at + 1, 2 * at + 2 }) |child| {
                if (child < self.heap_count and self.slots[self.heap[child]].next < self.slots[self.heap[best]].next) best = child;
            }
            if (best == at) return;
            const moved = self.heap[best];
            self.place(best, self.heap[at]);
            self.place(at, moved);
            at = best;
        }
    }
};
