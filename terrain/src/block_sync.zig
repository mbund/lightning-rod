const bit_sets = @import("lightning_rod").system.bit_sets;
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const chunks = @import("chunks");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const worlds = @import("worlds");
const wire_1_21_5 = @import("wire_1_21_5");
const Players = @import("players").players.Players;
const Streaming = @import("streaming.zig").Streaming;
const game_data = @import("game_data");
const section_hull = @import("occlusion").section_hull;

const assert = std.debug.assert;
const all_blocks: [64]u64 = @splat(std.math.maxInt(u64));

pub const BlockSynchronization = struct {
    pub const id = "minecraft:block_synchronization";

    pub const Configuration = struct {
        delta_sections: usize = 128,
        queued_sections: usize = 256,
        work: lightning_rod.system.work.Limits = .{ .guaranteed = .{ .operations = 1 }, .burst = .{ .operations = 7 } },
    };

    pub const Dependencies = struct {
        metrics: *lightning_rod.metrics.Registry,
        chunks: *chunks.Chunks,
        players: *Players,
        streaming: *Streaming,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        worlds: *worlds.Worlds,
    };

    const Observer = struct {
        generation: u32 = 0,
        life: u32 = 0,
        world: u32 = 0,
        pending: usize = 0,
        sequence: i32 = -1,
        cursor: usize = 0,
        pending_bits: []u64 = &.{},
        full_bits: []u64 = &.{},
        nonempty: std.DynamicBitSetUnmanaged = .{},
        /// With hull replacement, the eye section and, per cell around it, the section whose true
        /// states were requested with the column delivery they correct.
        near_eye: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 },
        near: [27]Near = @splat(.{}),

        const Near = struct { section: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 }, delivery: u32 = 0, valid: bool = false };

        const Selection = struct { bit: ?usize = null, examined: usize = 0 };

        fn select(self: *const Observer, excluded: []const usize) Selection {
            var result: Selection = .{};
            var words = self.nonempty.iterator(.{});
            while (words.next()) |word| {
                var bits = self.pending_bits[word];
                assert(bits != 0);
                result.examined += 1;
                for (excluded) |bit| if (bit / 64 == word) {
                    bits &= ~(@as(u64, 1) << @intCast(bit % 64));
                };
                if (bits == 0) continue;
                if (result.bit == null) result.bit = word * 64 + @ctz(bits);
                if (word < self.cursor / 64) continue;
                if (word == self.cursor / 64) bits &= @as(u64, std.math.maxInt(u64)) << @intCast(self.cursor % 64);
                if (bits != 0) {
                    result.bit = word * 64 + @ctz(bits);
                    break;
                }
            }
            return result;
        }
    };

    const CachedDelta = struct {
        next_free: ?usize = null,
        section: chunks.Section = undefined,
        live: bool = false,
    };

    const Delta = struct {
        section: chunks.Section = undefined,
        live: bool = false,
    };

    const Changes = struct {
        const State = struct { generation: u32 = 0, life: u32 = 0, world: u32 = 0 };
        const Acknowledgment = struct { state: State, sequence: i32 };
        entries: []Delta,
        masks: [][64]u64,
        index: std.AutoHashMapUnmanaged(chunks.Section, usize),
        count: usize = 0,
        full_players: bit_sets.Matrix,
        full_states: []State,
        acknowledgments: []Acknowledgment,
        acknowledging: lightning_rod.system.IndexSet,
        full_bits: []u64,
        dirty_words: std.DynamicBitSetUnmanaged,
        words: usize,

        fn init(allocator: std.mem.Allocator, capacity: usize, players: usize, words: usize) !Changes {
            assert(capacity > 0 and players > 0 and words > 0);
            const entries = try allocator.alloc(Delta, capacity);
            const masks = try allocator.alloc([64]u64, capacity);
            var index: std.AutoHashMapUnmanaged(chunks.Section, usize) = .{};
            try index.ensureTotalCapacity(allocator, @intCast(capacity));
            const full_states = try allocator.alloc(State, players);
            @memset(full_states, .{});
            const full_bits = try allocator.alloc(u64, players * words);
            @memset(full_bits, 0);
            const dirty_words = try std.DynamicBitSetUnmanaged.initEmpty(allocator, full_bits.len);
            return .{ .full_players = try bit_sets.Matrix.init(allocator, 1, players), .acknowledging = try lightning_rod.system.IndexSet.init(allocator, players), .entries = entries, .masks = masks, .index = index, .full_states = full_states, .acknowledgments = try allocator.alloc(Acknowledgment, players), .full_bits = full_bits, .dirty_words = dirty_words, .words = words };
        }

        fn clear(self: *Changes) void {
            if (self.count != 0) self.index.clearRetainingCapacity();
            self.count = 0;
            self.acknowledging.clear();
            if (!self.full_players.row(0).view().any()) return;
            var dirty = self.dirty_words.iterator(.{});
            while (dirty.next()) |word| self.full_bits[word] = 0;
            self.dirty_words.setRangeValue(.{ .start = 0, .end = self.full_bits.len }, false);
            self.full_players.row(0).clear();
        }

        fn append(self: *Changes, section: chunks.Section, mask: *const [64]u64) bool {
            assert(self.count == self.index.count() and self.count <= self.entries.len);
            if (self.index.get(section)) |at| {
                for (&self.masks[at], mask) |*target, source| target.* |= source;
                return true;
            }
            if (self.count == self.entries.len) return false;
            const at = self.count;
            self.entries[at] = .{ .section = section, .live = true };
            self.masks[at] = mask.*;
            self.index.putAssumeCapacity(section, at);
            self.count += 1;
            assert(self.index.count() == self.count);
            return true;
        }

        fn acknowledge(self: *Changes, player: usize, value: Acknowledgment) void {
            assert(player < self.acknowledgments.len and value.state.generation != 0 and value.sequence >= 0);
            const previous = &self.acknowledgments[player];
            if (self.acknowledging.contains(player) and std.meta.eql(previous.state, value.state)) {
                previous.sequence = @max(previous.sequence, value.sequence);
            } else previous.* = value;
            self.acknowledging.insert(player);
        }

        fn row(self: *Changes, player: usize, state: State) void {
            if (!std.meta.eql(self.full_states[player], state)) {
                if (self.full_players.row(0).view().contains(player)) {
                    const start = player * self.words;
                    @memset(self.full_bits[start..][0..self.words], 0);
                    self.dirty_words.setRangeValue(.{ .start = start, .end = start + self.words }, false);
                }
                self.full_states[player] = state;
            }
            self.full_players.row(0).insert(player);
        }

        fn mark(self: *Changes, player: usize, state: State, bit: usize) void {
            assert(player < self.full_states.len and state.generation != 0 and bit < self.words * 64);
            self.row(player, state);
            const word = player * self.words + bit / 64;
            self.full_bits[word] |= @as(u64, 1) << @intCast(bit % 64);
            self.dirty_words.set(word);
        }

        fn overflow(self: *Changes, section: chunks.Section, players: *const Players, side: i32) void {
            if (!sectionTracked(section)) return;
            const radius = @divTrunc(side - 1, 2);
            var nearby = players.nearby(section.world, .{ .x = @as(f64, @floatFromInt(section.x)) * 16, .y = 0, .z = @as(f64, @floatFromInt(section.z)) * 16 }, radius);
            while (nearby.next()) |index| {
                const player = players.records[index];
                const handle = player.handle.?;
                self.mark(index, .{ .generation = handle.generation, .life = player.life, .world = player.world }, sectionBit(side, section));
            }
        }

        fn merge(self: *Changes, other: *const Changes) void {
            assert(self.words == other.words and self.full_states.len == other.full_states.len);
            var players = other.full_players.row(0).view().iterator();
            while (players.next()) |player| {
                self.row(player, other.full_states[player]);
            }
            var dirty = other.dirty_words.iterator(.{});
            while (dirty.next()) |word| {
                self.full_bits[word] |= other.full_bits[word];
                self.dirty_words.set(word);
            }
            for (other.acknowledging.values()) |index| self.acknowledge(index, other.acknowledgments[index]);
        }
    };
    const Published = struct {
        mutex: std.Io.Mutex = .init,
        changes: Changes,
        views: []Streaming.View,
        changed_views: lightning_rod.system.IndexSet,
        epoch: u64 = 0,
    };

    io: std.Io,
    native_io: std.Io,
    published: *Published,
    tracked_views: lightning_rod.system.IndexSet,
    changed_views: lightning_rod.system.IndexSet,
    staged: Changes,
    incoming: Changes,
    views: []Streaming.View,
    epoch: u64 = 0,
    deps: Dependencies,
    /// Reads the changed sections and their neighbours, eight at a time.
    chunk_client: chunks.Chunks.Client,
    observers: []Observer,
    pending: []u64,
    full: []u64,
    words: usize,
    side: i32,
    deltas: []CachedDelta,
    delta_index: std.AutoHashMapUnmanaged(chunks.Section, usize),
    free_delta: ?usize = null,
    masks: [][64]u64,
    recipients: []sessions.Handle,
    /// Terrain is delivered with hidden blocks replaced, see `section_hull`.
    hull: bool,
    /// `section_hull` flags per block state when `hull` is set.
    hull_table: section_hull.Table,
    selections: bit_sets.Matrix,
    remaining: []usize,
    covered: []u8,
    pending_acknowledgments: lightning_rod.system.IndexSet,
    next_acknowledgment: usize = 0,
    next_delta: usize = 0,
    next_player: usize = 0,
    batch_limit: usize = 8,
    packets: std.atomic.Value(u64) = .init(0),
    full_sections: std.atomic.Value(u64) = .init(0),
    blocks: std.atomic.Value(u64) = .init(0),
    evictions: std.atomic.Value(u64) = .init(0),
    backpressured: std.atomic.Value(u64) = .init(0),
    changed_event: *std.Io.Event,
    wake_pending: bool = false,
    batch_duration: lightning_rod.metrics.Timer,
    batch_cpu: lightning_rod.metrics.Timer,
    planning_words: lightning_rod.metrics.Counter,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, deps: Dependencies, config: Configuration) !*BlockSynchronization {
        if (config.delta_sections == 0 or config.queued_sections == 0 or config.queued_sections > std.math.maxInt(u32)) return error.InvalidConfiguration;
        try config.work.validate(1, .{ .operations = 1 });
        const maximum = try config.work.maximum(1);
        if (maximum.operations > 8 or maximum.bytes != 0) return error.InvalidWorkLimits;
        if (deps.sessions.config.page_bytes < 16 + 4096 * 4) return error.PacketPageTooSmall;

        const self = try allocator.create(BlockSynchronization);
        const observers = try allocator.alloc(Observer, deps.players.records.len);
        const side = deps.streaming.deliveryRadius() * 2 + 1;
        const words = (@as(usize, @intCast(side * side)) * section_count + 63) / 64;
        for (observers, deps.players.records) |*observer, player| observer.* = .{ .life = player.life, .nonempty = try .initEmpty(allocator, words) };
        const pending = try allocator.alloc(u64, words * observers.len);
        const full = try allocator.alloc(u64, pending.len);
        const deltas = try allocator.alloc(CachedDelta, config.delta_sections);
        for (deltas, 0..) |*delta, index| delta.* = .{ .next_free = if (index + 1 < deltas.len) index + 1 else null };
        var delta_index: std.AutoHashMapUnmanaged(chunks.Section, usize) = .empty;
        try delta_index.ensureTotalCapacity(allocator, std.math.cast(u32, deltas.len) orelse return error.InvalidConfiguration);
        const published = try allocator.create(Published);
        published.* = .{
            .changes = try Changes.init(allocator, config.queued_sections, observers.len, words),
            .views = try allocator.alloc(Streaming.View, observers.len),
            .changed_views = try lightning_rod.system.IndexSet.init(allocator, observers.len),
        };
        for (deps.players.records, published.views) |player, *view| view.* = Streaming.View.capture(player);
        for (deps.players.activeSlots()) |index| published.changed_views.insert(index);
        self.* = .{
            .io = io,
            .selections = try bit_sets.Matrix.init(allocator, 3, observers.len),
            .pending_acknowledgments = try lightning_rod.system.IndexSet.init(allocator, observers.len),
            .remaining = try allocator.alloc(usize, observers.len),
            .covered = try allocator.alloc(u8, observers.len),
            .native_io = io,
            .changed_event = deps.chunks.ready(),
            .published = published,
            .tracked_views = try lightning_rod.system.IndexSet.init(allocator, deps.players.records.len),
            .changed_views = try lightning_rod.system.IndexSet.init(allocator, deps.players.records.len),
            .staged = try Changes.init(allocator, config.queued_sections, observers.len, words),
            .incoming = try Changes.init(allocator, config.queued_sections, observers.len, words),
            .views = try allocator.dupe(Streaming.View, published.views),
            .batch_duration = try deps.metrics.timer(.{ .name = "blocks.synchronization.batch", .description = "Encode and publish a block update batch" }),
            .batch_cpu = try deps.metrics.timer(.{ .name = "blocks.synchronization.batch.cpu", .description = "Block update batch work on the owning thread", .clock = .thread_cpu, .detailed = true }),
            .planning_words = try deps.metrics.counter(.{ .name = "blocks.synchronization.planning_words", .description = "Nonempty pending section words examined during block delivery planning" }),
            .deps = deps,
            .chunk_client = try deps.chunks.client(.{ .name = "block sync", .sections = 8 }),
            .batch_limit = maximum.operations,
            .observers = observers,
            .pending = pending,
            .full = full,
            .words = words,
            .side = side,
            .deltas = deltas,
            .delta_index = delta_index,
            .free_delta = 0,
            .masks = try allocator.alloc([64]u64, deltas.len),
            .recipients = try allocator.alloc(sessions.Handle, observers.len * 8),
            .hull = deps.streaming.config.hull,
            .hull_table = if (deps.streaming.config.hull) try section_hull.initTable(allocator) else &.{},
        };
        try deps.chunks.observe(chunks.Observer.init(self, changed));

        return self;
    }

    pub fn correct(self: *BlockSynchronization, world: u32, position: chunks.Position) void {
        changed(self, chunks.sectionAt(world, position), &.{.{ .index = chunks.localIndex(position), .state = 0 }}, &.{0});
    }

    pub fn acknowledge(self: *BlockSynchronization, player: *const Players.Player, sequence: i32) void {
        if (sequence < 0) return;
        const handle = player.handle.?;
        self.staged.acknowledge(handle.index, .{ .state = .{ .generation = handle.generation, .life = player.life, .world = player.world }, .sequence = sequence });
    }

    fn changed(self: *BlockSynchronization, section: chunks.Section, edits: []const chunks.BlockEdit, _: []const u16) void {
        const world = self.deps.worlds.get(section.world) orelse return;
        const minimum = world.dimension.minimumSection();
        if (section.y < minimum or section.y >= minimum + @as(i32, @intCast(world.dimension.sectionCount()))) return;
        var mask: [64]u64 = @splat(0);
        for (edits) |edit| mask[edit.index / 64] |= @as(u64, 1) << @intCast(edit.index % 64);
        if (self.hull) self.exposeNeighbors(section, edits, &mask);
        if (!self.staged.append(section, &mask)) self.staged.overflow(section, self.deps.players, self.side);
    }

    /// An edit that leaves a non-occluder exposes its six face neighbours, which clients may
    /// hold as hull filler. Their true states join the delta.
    fn exposeNeighbors(self: *BlockSynchronization, section: chunks.Section, edits: []const chunks.BlockEdit, mask: *[64]u64) void {
        var others: [6]Exposed = undefined;
        exposure(section, edits, mask, &others);
        const world = self.deps.worlds.get(section.world) orelse return;
        const minimum = world.dimension.minimumSection();
        for (&others) |*other| {
            if (!other.used) continue;
            if (other.section.y < minimum or other.section.y >= minimum + @as(i32, @intCast(world.dimension.sectionCount()))) continue;
            if (!self.staged.append(other.section, &other.mask)) self.staged.overflow(other.section, self.deps.players, self.side);
        }
    }

    /// Clients hold hull filler in delivered terrain. The 27 sections around the player's eye
    /// section get every true state once per column delivery, so nearby mining and client
    /// prediction see real blocks. A redelivered column carries filler again and is corrected
    /// again. Only sections the player already holds are corrected, after their column arrived.
    fn requestNearSections(self: *BlockSynchronization) !void {
        assert(self.hull);
        const streaming = self.deps.streaming;
        for (self.views, self.observers, 0..) |view, *observer, index| {
            const handle = view.handle orelse continue;
            if (!view.ready) continue;
            if (observer.generation != handle.generation or observer.life != view.life or observer.world != view.world) self.resetObserver(index, handle.generation, view.life, view.world);
            const eye: chunks.Section = .{ .world = view.world, .x = @divFloor(view.eye_min[0], 16), .y = @divFloor(view.eye_max, 16), .z = @divFloor(view.eye_min[2], 16) };
            if (!std.meta.eql(observer.near_eye, eye)) {
                observer.near = remapNear(&observer.near, eye);
                observer.near_eye = eye;
            }
            for (&observer.near, 0..) |*slot, cell| {
                const section = nearSection(eye, cell);
                if (!sectionTracked(section)) continue;
                const column: Streaming.Position = .{ .x = section.x, .z = section.z };
                if (!streaming.visibleView(index, view, section.world, section.x, section.z)) continue;
                if (!streaming.visibilityReady(index, column) or !streaming.sectionVisible(index, section)) continue;
                const delivery = streaming.columnDelivery(index, column);
                if (slot.valid and slot.delivery == delivery) {
                    assert(std.meta.eql(slot.section, section));
                    continue;
                }
                slot.* = .{ .section = section, .delivery = delivery, .valid = true };
                var cells: [64]u64 = undefined;
                switch (try self.hullCells(index, section, &cells)) {
                    .none => {},
                    .cells => self.requestCells(index, section, &cells),
                    .all => self.requestFull(index, sectionBit(self.side, section)),
                }
            }
        }
    }

    /// The cells of `section` delivered terrain holds filler in, judged like the bake from the
    /// section and its face neighbours as they are now. Only those cells need true states, not
    /// the whole section. Sections not ready to read send every state, so the player still
    /// receives them. An edit since delivery can only make this miss filler that is still hidden,
    /// and exposure sends true states once it is not.
    fn hullCells(self: *BlockSynchronization, player: usize, section: chunks.Section, mask: *[64]u64) !enum { none, cells, all } {
        const world = self.deps.worlds.get(section.world) orelse return .all;
        const minimum = world.dimension.minimumSection();
        const maximum = minimum + @as(i32, @intCast(world.dimension.sectionCount()));
        assert(section.y >= minimum and section.y < maximum);
        // The section, then its neighbours in `section_hull.Faces` order.
        const offsets = [7][3]i32{ .{ 0, 0, 0 }, .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
        var sections: [7]chunks.Section = undefined;
        var faces: [7]?usize = @splat(null);
        var count: usize = 0;
        for (offsets, 0..) |offset, index| {
            const at: chunks.Section = .{ .world = section.world, .x = section.x + offset[0], .y = section.y + offset[1], .z = section.z + offset[2] };
            if (at.y < minimum or at.y >= maximum) continue;
            sections[count] = at;
            faces[index] = count;
            count += 1;
        }
        var leases: [7]chunks.Lease = undefined;
        var ready: [1]bool = undefined;
        try self.chunk_client.prepareMany(&.{.{ .sections = sections[0..count], .leases = leases[0..count], .priority = .{ .urgency = .occupied, .player = player } }}, &ready);
        if (!ready[0]) return .all;
        defer self.deps.chunks.releaseMany(leases[0..count]);
        const center = leases[0].view();
        if (center == .uniform) return .none;
        var states: [section_hull.volume]u16 = undefined;
        for (&states, 0..) |*state, local| state.* = center.get(@intCast(local));
        var planes: section_hull.Faces = @splat(@splat(0));
        inline for (0..6) |side| if (faces[side + 1]) |at| {
            // The neighbour's cells that touch this section: its +x plane for the -x face.
            const plane = if (side % 2 == 0) section_hull.side - 1 else 0;
            planes[side] = section_hull.readPlane(leases[at].view(), self.hull_table, side / 2, plane);
        };
        return if (section_hull.changedCells(&states, &planes, self.hull_table, mask) == 0) .none else .cells;
    }

    /// Keeps corrections of sections that stay within one section of the new eye section.
    fn remapNear(near: *const [27]Observer.Near, eye: chunks.Section) [27]Observer.Near {
        var result: [27]Observer.Near = @splat(.{});
        for (near) |entry| {
            if (!entry.valid or entry.section.world != eye.world) continue;
            const offset = [3]i32{ entry.section.x - eye.x, entry.section.y - eye.y, entry.section.z - eye.z };
            if (@abs(offset[0]) > 1 or @abs(offset[1]) > 1 or @abs(offset[2]) > 1) continue;
            const cell: usize = @intCast((offset[2] + 1) * 9 + (offset[1] + 1) * 3 + offset[0] + 1);
            assert(std.meta.eql(nearSection(eye, cell), entry.section));
            result[cell] = entry;
        }
        return result;
    }

    fn nearSection(eye: chunks.Section, cell: usize) chunks.Section {
        assert(cell < 27);
        return .{
            .world = eye.world,
            .x = eye.x + @as(i32, @intCast(cell % 3)) - 1,
            .y = eye.y + @as(i32, @intCast(cell / 3 % 3)) - 1,
            .z = eye.z + @as(i32, @intCast(cell / 9)) - 1,
        };
    }

    /// Sends every true state of a pending section to one observer.
    /// Sends one player the true states of some cells of a section it holds.
    fn requestCells(self: *BlockSynchronization, index: usize, section: chunks.Section, mask: *const [64]u64) void {
        const observer = &self.observers[index];
        assert(observer.generation != 0);
        self.recordMask(section, mask);
        const bit = sectionBit(self.side, section);
        const word = bit / 64;
        const flag = @as(u64, 1) << @intCast(bit % 64);
        observer.pending += @intFromBool(observer.pending_bits[word] & flag == 0);
        observer.pending_bits[word] |= flag;
        observer.nonempty.set(word);
        self.selections.row(0).insert(index);
    }

    fn requestFull(self: *BlockSynchronization, index: usize, bit: usize) void {
        const observer = &self.observers[index];
        assert(observer.generation != 0 and bit < self.words * 64);
        const word = bit / 64;
        const flag = @as(u64, 1) << @intCast(bit % 64);
        observer.pending += @intFromBool(observer.pending_bits[word] & flag == 0);
        observer.pending_bits[word] |= flag;
        observer.full_bits[word] |= flag;
        observer.nonempty.set(word);
        self.selections.row(0).insert(index);
    }

    fn changedOwned(self: *BlockSynchronization, section: chunks.Section, mask: *const [64]u64) void {
        const world = self.deps.worlds.get(section.world) orelse return;
        const minimum = world.dimension.minimumSection();
        if (section.y < minimum or section.y >= minimum + @as(i32, @intCast(world.dimension.sectionCount()))) return;

        const bit = sectionBit(self.side, section);
        const flag = @as(u64, 1) << @intCast(bit % 64);
        var interested = false;

        var watchers = self.deps.streaming.visibleObservers(self.views, section.world, section.x, section.z);
        while (watchers.next()) |index| {
            const player = self.views[index];
            const observer = &self.observers[index];
            const handle = player.handle.?;

            if (observer.generation != handle.generation or observer.life != player.life or observer.world != player.world) {
                self.resetObserver(index, handle.generation, player.life, player.world);
            }

            assert(player.world == section.world);
            const word = bit / 64;
            observer.pending += @intFromBool(observer.pending_bits[word] & flag == 0);
            observer.pending_bits[word] |= flag;
            observer.nonempty.set(word);
            self.selections.row(0).insert(index);
            interested = true;
        }

        if (!interested) return;
        self.recordMask(section, mask);
    }

    /// Adds cells to the delta of a section, taking a slot for it if it has none.
    fn recordMask(self: *BlockSynchronization, section: chunks.Section, mask: *const [64]u64) void {
        const found = self.delta_index.get(section);
        if (found) |cached| assert(self.deltas[cached].live and std.meta.eql(self.deltas[cached].section, section));
        const slot = found orelse self.free_delta orelse self.next_delta;

        if (found == null) {
            if (self.deltas[slot].live) {
                const previous = self.deltas[slot].section;
                const removed = self.delta_index.fetchRemove(previous).?;
                assert(removed.value == slot);
                const previous_bit = sectionBit(self.side, previous);
                const previous_flag = @as(u64, 1) << @intCast(previous_bit % 64);

                var pending = self.selections.row(0).view().iterator();
                while (pending.next()) |index| {
                    const other = self.observers[index];
                    assert(other.pending != 0);
                    const word = previous_bit / 64;

                    if (other.pending_bits[word] & previous_flag != 0 and self.deps.streaming.visibleView(index, self.views[index], previous.world, previous.x, previous.z))
                        other.full_bits[word] |= previous_flag;
                }

                _ = self.evictions.fetchAdd(1, .monotonic);
            }

            if (!self.deltas[slot].live) {
                assert(self.free_delta == slot);
                self.free_delta = self.deltas[slot].next_free;
            }
            self.next_delta = (slot + 1) % self.deltas.len;
            self.deltas[slot] = .{ .section = section, .live = true };
            assert(!self.delta_index.contains(section));
            self.delta_index.putAssumeCapacityNoClobber(section, slot);
            self.masks[slot] = @splat(0);
        }

        for (&self.masks[slot], mask) |*target, source| target.* |= source;
    }

    pub fn endTick(self: *BlockSynchronization, completed: bool) void {
        if (!completed) {
            self.staged.clear();
            return;
        }
        const published = self.published;
        published.mutex.lockUncancelable(self.native_io);
        defer published.mutex.unlock(self.native_io);
        var updated = self.staged.count != 0 or self.staged.full_players.row(0).view().any() or self.staged.acknowledging.count != 0;
        if (published.changes.count == 0 and !published.changes.full_players.row(0).view().any() and published.changes.acknowledging.count == 0) {
            std.mem.swap(Changes, &self.staged, &published.changes);
        } else {
            for (self.staged.entries[0..self.staged.count], self.staged.masks[0..self.staged.count]) |entry, *mask|
                if (!published.changes.append(entry.section, mask)) published.changes.overflow(entry.section, self.deps.players, self.side);
            published.changes.merge(&self.staged);
        }
        self.staged.clear();
        for (self.deps.players.activeSlots()) |index| self.tracked_views.insert(index);
        var view_index: usize = 0;
        while (view_index < self.tracked_views.count) {
            const index = self.tracked_views.indices[view_index];
            const player = self.deps.players.records[index];
            const view = &published.views[index];
            if (player.handle == null) self.tracked_views.remove(index) else view_index += 1;
            const current = Streaming.View.capture(player);
            if (!std.meta.eql(view.*, current)) {
                view.* = current;
                published.changed_views.insert(index);
                updated = true;
            }
        }
        published.epoch = self.deps.sessions.backgroundEpoch() + 1;
        self.wake_pending = updated;
    }

    pub fn publish(self: *BlockSynchronization) void {
        if (!self.wake_pending) return;
        self.wake_pending = false;
        self.changed_event.set(self.io);
    }

    fn receive(self: *BlockSynchronization) bool {
        const published = self.published;
        assert(self.changed_views.count == 0);
        {
            published.mutex.lockUncancelable(self.native_io);
            defer published.mutex.unlock(self.native_io);
            if (published.epoch != self.deps.sessions.backgroundEpoch() or published.epoch != self.deps.streaming.epoch or published.epoch & 1 != 0) return false;
            if (self.epoch != published.epoch) std.mem.swap([]Streaming.View, &self.views, &published.views);
            self.epoch = published.epoch;
            std.mem.swap(lightning_rod.system.IndexSet, &self.changed_views, &published.changed_views);
            std.mem.swap(Changes, &self.incoming, &published.changes);
            published.changes.clear();
        }
        for (self.changed_views.values()) |index| {
            const view = self.views[index];
            const observer = self.observers[index];
            const generation = if (view.handle) |handle| handle.generation else 0;
            if (observer.generation != generation or observer.life != view.life or observer.world != view.world)
                self.resetObserver(index, generation, view.life, view.world);
        }
        self.changed_views.clear();
        return true;
    }

    pub fn poll(self: *BlockSynchronization, io: std.Io) !bool {
        if (!self.deps.chunks.ownsCurrentThread()) return error.InvalidChunkOwner;
        defer self.deps.sessions.retryBackground(self.epoch);
        const progressed = try self.sendBatch(io, self.batch_limit);
        const acknowledged = try self.sendAcknowledgments();
        self.deps.sessions.flush();
        if (progressed or acknowledged) self.changed_event.set(io);
        return progressed or acknowledged;
    }

    fn sendBatch(self: *BlockSynchronization, _: std.Io, maximum_items: usize) !bool {
        const timing = self.batch_duration.start();
        defer timing.end();
        const cpu = self.batch_cpu.start();
        defer cpu.end();
        if (!self.receive()) return false;
        for (self.incoming.entries[0..self.incoming.count], self.incoming.masks[0..self.incoming.count]) |entry, *mask|
            self.changedOwned(entry.section, mask);
        var dirty = self.incoming.dirty_words.iterator(.{});
        while (dirty.next()) |at| {
            const index = at / self.words;
            const state = self.incoming.full_states[index];
            const view = self.views[index];
            const handle = view.handle orelse continue;
            if (state.generation != handle.generation or state.life != view.life or state.world != view.world) continue;
            const observer = &self.observers[index];
            if (observer.generation != handle.generation or observer.life != view.life or observer.world != view.world) self.resetObserver(index, handle.generation, view.life, view.world);
            const word = at % self.words;
            const bits = self.incoming.full_bits[at];
            observer.pending += @popCount(bits & ~observer.pending_bits[word]);
            observer.pending_bits[word] |= bits;
            if (bits != 0) observer.nonempty.set(word);
            observer.full_bits[word] |= bits;
            if (observer.pending != 0) self.selections.row(0).insert(index);
        }
        if (self.hull) try self.requestNearSections();
        for (self.incoming.acknowledging.values()) |index| {
            const view = self.views[index];
            const handle = view.handle orelse continue;
            const acknowledgment = self.incoming.acknowledgments[index];
            if (acknowledgment.state.generation != handle.generation or acknowledgment.state.life != view.life or acknowledgment.state.world != view.world) continue;
            self.observers[index].sequence = @max(self.observers[index].sequence, acknowledgment.sequence);
            self.pending_acknowledgments.insert(index);
        }
        if (!self.selections.row(0).view().any()) return false;
        const service = self.deps.sessions;
        assert(maximum_items > 0 and maximum_items <= 8);
        var advanced = false;
        var completed: usize = 0;
        const Plan = struct { section: chunks.Section, protocol: i32, full: bool, slot: ?usize, bit: usize, changed: i32, mask: *const [64]u64, recipients: []sessions.Handle, owner: usize };
        var plans: [8]Plan = undefined;
        var capacities: [8]usize = undefined;
        var planned: usize = 0;
        const remaining = self.remaining;
        const covered = self.covered;
        const candidates = self.selections.row(1);
        candidates.copy(self.selections.row(0).view());
        var pending = self.selections.row(0).view().iterator();
        while (pending.next()) |index| {
            const observer = self.observers[index];
            const view = self.views[index];
            assert(observer.pending != 0);
            covered[index] = 0;
            remaining[index] = observer.pending;
            if (view.handle == null or !view.ready) candidates.remove(index);
        }
        var examined: usize = 0;
        defer self.planning_words.add(examined);

        while (candidates.view().any()) {
            if (completed == maximum_items or planned == @min(maximum_items, self.chunk_client.budget())) break;

            const selected = candidates.view().firstFrom(self.next_player) orelse candidates.view().firstFrom(0).?;
            self.next_player = (selected + 1) % self.observers.len;
            const player = self.views[selected];
            const observer = &self.observers[selected];
            const generation = if (player.handle) |handle| handle.generation else 0;

            if (observer.generation != generation or observer.life != player.life or observer.world != player.world) {
                self.resetObserver(selected, generation, player.life, player.world);
            }

            assert(self.selections.row(0).view().contains(selected) == (observer.pending != 0));
            if (observer.pending == 0) {
                candidates.remove(selected);
                continue;
            }
            assert(remaining[selected] > 0);
            var excluded: [8]usize = undefined;
            var excluding: usize = 0;
            for (plans[0..planned], 0..) |plan, index| if (covered[selected] & (@as(u8, 1) << @intCast(index)) != 0) {
                excluded[excluding] = plan.bit;
                excluding += 1;
            };
            const selection = observer.select(excluded[0..excluding]);
            examined += selection.examined;
            const at = selection.bit orelse unreachable;
            observer.cursor = (at + 1) % (@as(usize, @intCast(self.side * self.side)) * section_count);
            const flag = @as(u64, 1) << @intCast(at % 64);
            const center = self.deps.streaming.streams[selected].center;
            const radius = @divTrunc(self.side - 1, 2);
            const x = center.x - radius;
            const z = center.z - radius;
            const cell: i32 = @intCast(at / 24);
            const section: chunks.Section = .{
                .world = player.world,
                .x = x + @mod(@mod(cell, self.side) - @mod(x, self.side), self.side),
                .y = @as(i32, @intCast(at % 24)) - 4,
                .z = z + @mod(@divTrunc(cell, self.side) - @mod(z, self.side), self.side),
            };
            assert(sectionBit(self.side, section) == at);
            const visible = self.deps.streaming.visibleView(selected, player, section.world, section.x, section.z);
            const column: Streaming.Position = .{ .x = section.x, .z = section.z };
            if (visible and !self.deps.streaming.visibilityReady(selected, column)) {
                candidates.remove(selected);
                continue;
            }
            if (!visible or !self.deps.streaming.sectionVisible(selected, section)) {
                if (visible) self.deps.streaming.invalidateSection(selected, section);
                observer.pending_bits[at / 64] &= ~flag;
                if (observer.pending_bits[at / 64] == 0) observer.nonempty.unset(at / 64);
                observer.full_bits[at / 64] &= ~flag;
                observer.pending -= 1;
                if (observer.pending == 0) self.selections.row(0).remove(selected);
                advanced = true;
                completed += 1;
                remaining[selected] -= 1;
                if (remaining[selected] == 0) candidates.remove(selected);
                continue;
            }

            const slot = self.delta_index.get(section);
            if (slot) |cached| assert(self.deltas[cached].live and std.meta.eql(self.deltas[cached].section, section));

            const full = slot == null or observer.full_bits[at / 64] & flag != 0;
            var duplicate = false;
            for (plans[0..planned]) |plan| duplicate = duplicate or (std.meta.eql(plan.section, section) and plan.protocol == player.protocol and plan.full == full);
            assert(!duplicate);
            const recipients = self.recipients[planned * self.views.len ..][0..self.views.len];
            var count: usize = 0;
            const grouped = self.selections.row(2);
            grouped.clear();

            var watchers = self.deps.streaming.visibleObservers(self.views, section.world, section.x, section.z);
            while (watchers.next()) |index| {
                if (!self.deps.streaming.sectionVisible(index, section)) continue;
                if (!self.deps.streaming.visibilityReady(index, column)) continue;
                const recipient = self.views[index];
                const handle = recipient.handle.?;
                assert(recipient.world == section.world);
                if (self.observers[index].pending == 0 or recipient.protocol != player.protocol or !recipient.ready)
                    continue;

                const other = &self.observers[index];
                const word = at / 64;
                if (other.pending_bits[word] & flag == 0) continue;
                if ((slot == null or other.full_bits[word] & flag != 0) != full) continue;
                recipients[count] = handle;
                grouped.insert(index);
                count += 1;
            }

            assert(count > 0);
            const mask: *const [64]u64 = if (full) &all_blocks else &self.masks[slot.?];
            var changed_count: i32 = 0;

            for (mask) |bits| changed_count += @popCount(bits);
            assert(changed_count > 0 and changed_count <= 4096);
            const capacity = 16 + @as(usize, @intCast(changed_count)) * 4;
            var ready: usize = 0;

            for (recipients[0..count]) |handle| if (service.canSend(handle, capacity)) {
                recipients[ready] = handle;
                ready += 1;
            };

            if (ready == 0) {
                _ = self.backpressured.fetchAdd(1, .monotonic);
                candidates.subtract(candidates.view(), grouped.view());
                continue;
            }

            var selected_group = grouped.view().iterator();
            while (selected_group.next()) |index| {
                assert(remaining[index] > 0);
                remaining[index] -= 1;
                covered[index] |= @as(u8, 1) << @intCast(planned);
                if (remaining[index] == 0) candidates.remove(index);
            }

            plans[planned] = .{ .section = section, .protocol = player.protocol, .full = full, .slot = slot, .bit = at, .changed = changed_count, .mask = mask, .recipients = recipients[0..ready], .owner = selected };
            capacities[planned] = capacity;
            planned += 1;
            completed += 1;
        }
        if (planned == 0) return advanced;
        var output: [8]sessions.Service.Packet = undefined;
        var reserved = service.reserveBatch(capacities[0..planned], output[0..planned]) catch |err| switch (err) {
            error.Closed => return advanced,
            else => return err,
        };
        defer for (output[0..reserved]) |*packet| packet.cancel();
        if (reserved == 0) return advanced;
        for (output[0..reserved]) |*packet| {
            packet.epoch = self.epoch;
        }
        planned = reserved;
        var sections: [8]chunks.Section = undefined;
        var leases: [8]chunks.Lease = undefined;
        var preparations: [8]chunks.Chunks.Preparation = undefined;
        var ready: [8]bool = undefined;
        for (plans[0..planned], 0..) |plan, index| {
            sections[index] = plan.section;
            preparations[index] = .{ .sections = sections[index..][0..1], .leases = leases[index..][0..1], .priority = .{ .urgency = .occupied, .player = plan.recipients[0].index } };
        }
        try self.chunk_client.prepareMany(preparations[0..planned], ready[0..planned]);
        var available: usize = 0;
        for (ready[0..planned], 0..) |complete, index| {
            if (!complete) {
                output[index].cancel();
                continue;
            }
            plans[available] = plans[index];
            output[available] = output[index];
            leases[available] = leases[index];
            available += 1;
        }
        defer self.deps.chunks.releaseMany(leases[0..available]);
        reserved = available;
        if (reserved == 0) return advanced;
        var publications: [8]sessions.Service.Publication = undefined;
        var admitted: [8]usize = undefined;
        var filtered: [8][64]u64 = undefined;
        var send: [8]sessions.Service.Publication = undefined;
        var send_indices: [8]usize = undefined;
        var send_count: usize = 0;
        for (plans[0..reserved], leases[0..reserved], output[0..reserved], publications[0..reserved], 0..) |*plan, lease, *packet, *publication, index| {
            admitted[index] = 0;
            publication.* = .{ .packet = packet, .length = 0, .recipients = plan.recipients };
            if (!self.deps.streaming.sectionMaskForChanges(plan.owner, plan.section, &filtered[index])) {
                packet.cancel();
                continue;
            }
            var changed_count: i32 = 0;
            for (&filtered[index], plan.mask) |*visible, changed_bits| {
                visible.* &= changed_bits;
                changed_count += @popCount(visible.*);
            }
            plan.changed = changed_count;
            if (changed_count == 0) {
                packet.cancel();
                admitted[index] = plan.recipients.len;
                continue;
            }
            const bytes = try self.deps.packets.writePacket(writeChanges, plan.protocol, packet.bytes, .{ plan.section, lease.view(), &filtered[index] });
            publication.length = bytes.len;
            send[send_count] = publication.*;
            send_indices[send_count] = index;
            send_count += 1;
        }
        var sent: [8]usize = undefined;
        service.publishManyReady(send[0..send_count], sent[0..send_count]);
        for (send_indices[0..send_count], sent[0..send_count]) |index, count| admitted[index] = count;
        const Retirement = struct { slot: usize, section: chunks.Section, bit: usize, delta_delivered: bool = false };
        var retirements: [8]Retirement = undefined;
        var retiring: usize = 0;
        for (plans[0..reserved], publications[0..reserved], admitted[0..reserved]) |plan, publication, count| {
            const accepted = publication.recipients[0..count];
            const at = plan.bit;
            const flag = @as(u64, 1) << @intCast(at % 64);
            const section = plan.section;
            const full = plan.full;
            const slot = plan.slot;
            const changed_count = plan.changed;
            for (accepted) |handle| {
                const other = &self.observers[handle.index];
                const word = at / 64;
                assert(other.pending_bits[word] & flag != 0);
                other.pending_bits[word] &= ~flag;
                if (other.pending_bits[word] == 0) other.nonempty.unset(word);
                other.full_bits[word] &= ~flag;
                other.pending -= 1;
                if (other.pending == 0) self.selections.row(0).remove(handle.index);
            }

            if (accepted.len > 0) {
                _ = self.packets.fetchAdd(@intFromBool(changed_count != 0), .monotonic);
                _ = self.full_sections.fetchAdd(@intFromBool(full and changed_count != 0), .monotonic);
                _ = self.blocks.fetchAdd(@intCast(changed_count), .monotonic);
                advanced = true;
            }

            if (slot) |cached| {
                assert(self.deltas[cached].live and std.meta.eql(self.deltas[cached].section, section));
                assert(self.delta_index.get(section) == cached);
                const retirement = for (retirements[0..retiring]) |*entry| {
                    if (entry.slot == cached) break entry;
                } else create: {
                    assert(retiring < reserved);
                    const entry = &retirements[retiring];
                    entry.* = .{ .slot = cached, .section = section, .bit = at };
                    retiring += 1;
                    break :create entry;
                };
                assert(std.meta.eql(retirement.section, section) and retirement.bit == at);
                retirement.delta_delivered = retirement.delta_delivered or (!full and accepted.len > 0);
            }
        }

        // Delivery groups borrow the same delta. Retire it after every group's admissions are applied.
        for (retirements[0..retiring]) |retirement| {
            const at = retirement.bit;
            const flag = @as(u64, 1) << @intCast(at % 64);
            var retained = false;
            var pending_observers = self.selections.row(0).view().iterator();
            while (pending_observers.next()) |index| {
                const other = self.observers[index];
                assert(other.pending != 0);
                const word = at / 64;
                if (other.pending_bits[word] & flag == 0 or !self.deps.streaming.visibleView(index, self.views[index], retirement.section.world, retirement.section.x, retirement.section.z)) continue;
                if (retirement.delta_delivered) other.full_bits[word] |= flag;
                retained = retained or other.full_bits[word] & flag == 0;
            }
            if (!retained) {
                const cached = retirement.slot;
                const removed = self.delta_index.fetchRemove(retirement.section).?;
                assert(removed.value == cached and self.deltas[cached].live);
                self.deltas[cached].live = false;
                self.deltas[cached].next_free = self.free_delta;
                self.free_delta = cached;
                assert(!self.delta_index.contains(retirement.section));
            }
        }

        return advanced;
    }

    fn sendAcknowledgments(self: *BlockSynchronization) !bool {
        const service = self.deps.sessions;
        if (self.epoch & 1 != 0 or self.epoch != service.backgroundEpoch()) return false;
        var indices: [8]usize = undefined;
        var recipients: [8][1]sessions.Handle = undefined;
        var count: usize = 0;
        var remaining = self.pending_acknowledgments.count;
        while (remaining != 0) {
            remaining -= 1;
            self.next_acknowledgment %= self.pending_acknowledgments.count;
            const index = self.pending_acknowledgments.indices[self.next_acknowledgment];
            const view = self.views[index];
            const observer = &self.observers[index];
            if (view.handle == null or !view.ready or observer.generation != view.handle.?.generation or observer.life != view.life or observer.world != view.world) {
                self.pending_acknowledgments.remove(index);
                observer.sequence = -1;
                continue;
            }
            self.next_acknowledgment += 1;
            assert(observer.sequence >= 0);
            if (observer.pending != 0) continue;
            indices[count] = index;
            recipients[count] = .{view.handle.?};
            count += 1;
            if (count == indices.len) break;
        }
        if (count == 0) return false;
        var output: [8]sessions.Service.Packet = undefined;
        const capacities: [8]usize = @splat(16);
        const reserved = service.reserveBatch(capacities[0..count], output[0..count]) catch |err| switch (err) {
            error.Closed => return false,
            else => return err,
        };
        defer for (output[0..reserved]) |*packet| packet.cancel();
        var publications: [8]sessions.Service.Publication = undefined;
        var accepted: [8]usize = undefined;
        for (indices[0..reserved], output[0..reserved], 0..) |index, *packet, i| {
            packet.epoch = self.epoch;
            const bytes = try self.deps.packets.writePacket(writeAcknowledgment, self.views[index].protocol, packet.bytes, .{self.observers[index].sequence});
            publications[i] = .{ .packet = packet, .length = bytes.len, .recipients = &recipients[i] };
        }
        service.publishManyReady(publications[0..reserved], accepted[0..reserved]);
        var progressed = false;
        for (indices[0..reserved], accepted[0..reserved]) |index, admitted| {
            assert(admitted <= 1);
            if (admitted == 0) continue;
            assert(self.observers[index].pending == 0);
            self.observers[index].sequence = -1;
            self.pending_acknowledgments.remove(index);
            progressed = true;
        }
        return progressed;
    }

    fn writeAcknowledgment(packet: wire_1_21_5.play.toClient.packet_acknowledge_player_digging.Writer, sequence: i32) ![]u8 {
        assert(sequence >= 0);
        return (try packet.sequenceId(sequence)).finish();
    }

    fn resetObserver(self: *BlockSynchronization, index: usize, generation: u32, life: u32, world: u32) void {
        self.selections.row(0).remove(index);
        self.pending_acknowledgments.remove(index);
        const count = if (generation == 0) 0 else self.words;
        const pending = self.pending[index * self.words ..][0..count];
        const full = self.full[index * self.words ..][0..count];
        @memset(pending, 0);
        @memset(full, 0);
        var nonempty = self.observers[index].nonempty;
        nonempty.unsetAll();
        self.observers[index] = .{ .generation = generation, .life = life, .world = world, .pending_bits = pending, .full_bits = full, .nonempty = nonempty };
    }

    fn writeChanges(packet: wire_1_21_5.play.toClient.packet_multi_block_change.Writer, registry: packets.Registry, section: chunks.Section, view: chunks.View, mask: *const [64]u64) ![]u8 {
        var count: u32 = 0;
        for (mask) |bits| count += @popCount(bits);

        const positioned = try packet.chunkCoordinates(.{ .x = section.x, .z = section.z, .y = section.y });
        var records = try positioned.records(count);

        for (mask, 0..) |word, index| {
            var bits = word;

            while (bits != 0) {
                const at: u12 = @intCast(index * 64 + @ctz(bits));
                bits &= bits - 1;
                const local: u12 = ((at & 15) << 8) | (((at >> 4) & 15) << 4) | (at >> 8);
                const canonical = view.get(at);
                const mapped = registry.blockState(@intCast(canonical)) catch return error.UnsupportedBlock;
                const record = (@as(u64, @intCast(mapped)) << 12) | local;
                if (record > std.math.maxInt(i32)) return error.UnsupportedBlock;
                records = try records.element(@intCast(record));
            }
        }

        return (try records.finish()).finish();
    }
};

/// Pending section bits cover this vertical range in every dimension.
const section_minimum = -4;
const section_count = 24;

fn sectionTracked(section: chunks.Section) bool {
    return section.y >= section_minimum and section.y < section_minimum + section_count;
}

fn sectionBit(side: i32, section: chunks.Section) usize {
    assert(sectionTracked(section));
    return @as(usize, @intCast(@mod(section.z, side) * side + @mod(section.x, side))) * section_count + @as(usize, @intCast(section.y - section_minimum));
}

test "block acknowledgments coalesce within a player lifetime and discard aborted publications" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var changes = try BlockSynchronization.Changes.init(arena.allocator(), 1, 2, 1);
    var following = try BlockSynchronization.Changes.init(arena.allocator(), 1, 2, 1);
    const state: BlockSynchronization.Changes.State = .{ .generation = 1, .life = 2, .world = 3 };
    changes.acknowledge(0, .{ .state = state, .sequence = 4 });
    changes.acknowledge(0, .{ .state = state, .sequence = 2 });
    try std.testing.expectEqual(@as(i32, 4), changes.acknowledgments[0].sequence);
    following.acknowledge(0, .{ .state = state, .sequence = 6 });
    changes.merge(&following);
    try std.testing.expectEqual(@as(i32, 6), changes.acknowledgments[0].sequence);
    try std.testing.expect(!changes.full_players.row(0).view().any());
    following.clear();
    try std.testing.expect(following.acknowledging.count == 0);
    following.acknowledge(0, .{ .state = .{ .generation = 2 }, .sequence = 1 });
    changes.merge(&following);
    try std.testing.expectEqual(@as(i32, 1), changes.acknowledgments[0].sequence);
    try std.testing.expectEqual(@as(u32, 2), changes.acknowledgments[0].state.generation);
    changes.clear();
    try std.testing.expect(changes.acknowledging.count == 0);
}

test "pending section selection wraps and excludes planned work across sparse words" {
    var pending: [1600]u64 = @splat(0);
    var observer: BlockSynchronization.Observer = .{
        .pending_bits = &pending,
        .nonempty = try .initEmpty(std.testing.allocator, pending.len),
    };
    defer observer.nonempty.deinit(std.testing.allocator);
    const sections = [_]usize{ 0, 63, 64, pending.len * 64 - 1 };
    for (sections) |bit| {
        pending[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
        observer.nonempty.set(bit / 64);
    }
    for ([_]usize{ 0, 1, 63, 64, 65, pending.len * 64 - 1 }) |cursor| {
        observer.cursor = cursor;
        for (0..sections.len + 1) |count| {
            const excluded = sections[0..count];
            var expected: ?usize = null;
            for (0..pending.len * 64) |offset| {
                const bit = (cursor + offset) % (pending.len * 64);
                if (pending[bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) == 0) continue;
                if (std.mem.indexOfScalar(usize, excluded, bit) != null) continue;
                expected = bit;
                break;
            }
            const selection = observer.select(excluded);
            try std.testing.expectEqual(expected, selection.bit);
            try std.testing.expect(selection.examined <= 3);
        }
    }
}

test "block change overflow retains only affected section bits and merges generations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var first = try BlockSynchronization.Changes.init(allocator, 2, 2, 4);
    var second = try BlockSynchronization.Changes.init(allocator, 2, 2, 4);
    const a: chunks.Section = .{ .world = 1, .x = 0, .y = -4, .z = 0 };
    const b: chunks.Section = .{ .world = 1, .x = 1, .y = -4, .z = 0 };
    const c: chunks.Section = .{ .world = 1, .x = 2, .y = -4, .z = 0 };
    var mask: [64]u64 = @splat(0);
    mask[0] = 1;
    try std.testing.expect(first.append(a, &mask));
    try std.testing.expect(first.append(b, &mask));
    mask[0] = 2;
    try std.testing.expect(first.append(a, &mask));
    try std.testing.expectEqual(@as(u64, 3), first.masks[first.index.get(a).?][0]);
    try std.testing.expect(!first.append(c, &mask));
    first.mark(0, .{ .generation = 1, .life = 2, .world = 1 }, 65);
    first.mark(1, .{ .generation = 1, .life = 2, .world = 1 }, 130);
    try std.testing.expectEqual(@as(usize, 2), first.dirty_words.count());
    try std.testing.expectEqual(@as(u64, 2), first.full_bits[1]);
    try std.testing.expectEqual(@as(u64, 4), first.full_bits[6]);
    second.mark(0, .{ .generation = 1, .life = 2, .world = 1 }, 70);
    second.merge(&first);
    try std.testing.expectEqual(@as(u64, 66), second.full_bits[1]);
    first.clear();
    try std.testing.expectEqual(@as(usize, 0), first.index.count());
    try std.testing.expectEqual(@as(usize, 0), first.dirty_words.count());
    first.mark(0, .{ .generation = 2, .life = 3, .world = 7 }, 7);
    second.merge(&first);
    try std.testing.expectEqual(@as(u64, 128), second.full_bits[0]);
    try std.testing.expectEqual(@as(u64, 0), second.full_bits[1]);
    try std.testing.expectEqual(@as(u64, 4), second.full_bits[6]);
    second.clear();
    for (second.full_bits) |bits| try std.testing.expectEqual(@as(u64, 0), bits);
}

test "a saturated block queue marks only the changed section for matching viewers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const side = 65;
    const words = (side * side * section_count + 63) / 64;
    var changes = try BlockSynchronization.Changes.init(arena.allocator(), 2, 2, words);
    var records = [_]Players.Player{
        .{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = 1, .stage = .ready },
        .{ .handle = .{ .index = 1, .generation = 1 }, .uuid = 2, .world = 2, .stage = .ready },
    };
    var players: Players = .{ .deps = undefined, .records = &records, .spawn_world = 1, .config = .{ .render_distance = 32 }, .dig_handlers = &.{} };
    try players.initIndexes(arena.allocator());
    players.rebuildIndexes();
    var mask: [64]u64 = @splat(0);
    mask[0] = 1;
    for (0..3) |index| {
        const section: chunks.Section = .{ .world = 1, .x = @intCast(index), .y = -4, .z = 0 };
        if (!changes.append(section, &mask)) changes.overflow(section, &players, side);
    }
    var marked: usize = 0;
    for (changes.full_bits) |bits| marked += @popCount(bits);
    try std.testing.expectEqual(@as(usize, 1), marked);
    try std.testing.expectEqual(@as(usize, 1), changes.full_players.row(0).view().count());
    try std.testing.expect(changes.full_players.row(0).view().contains(0));
    try std.testing.expectEqual(@as(usize, 2), changes.count);
}

test "block publication waits for visibility from the same completed tick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var service: sessions.Service = undefined;
    service.epoch = .init(2);
    var streaming: Streaming = undefined;
    streaming.epoch = 0;
    var published: BlockSynchronization.Published = .{
        .changes = try BlockSynchronization.Changes.init(allocator, 1, 1, 1),
        .views = &.{},
        .changed_views = try lightning_rod.system.IndexSet.init(allocator, 1),
        .epoch = 2,
    };
    const changed: chunks.Section = .{ .world = 0, .x = 1, .y = 3, .z = 1 };
    try std.testing.expect(published.changes.append(changed, &all_blocks));
    var blocks: BlockSynchronization = undefined;
    blocks.native_io = std.testing.io;
    blocks.published = &published;
    blocks.changed_views = try lightning_rod.system.IndexSet.init(allocator, 1);
    blocks.incoming = try BlockSynchronization.Changes.init(allocator, 1, 1, 1);
    blocks.views = &.{};
    blocks.epoch = 0;
    blocks.deps = .{ .metrics = undefined, .chunks = undefined, .players = undefined, .streaming = &streaming, .sessions = &service, .packets = undefined, .worlds = undefined };
    try std.testing.expect(!blocks.receive());
    try std.testing.expectEqual(@as(usize, 1), published.changes.count);
    try std.testing.expectEqual(@as(usize, 0), blocks.incoming.count);
    streaming.epoch = 2;
    try std.testing.expect(blocks.receive());
    try std.testing.expectEqual(@as(usize, 0), published.changes.count);
    try std.testing.expectEqual(@as(usize, 1), blocks.incoming.count);
    try std.testing.expectEqual(changed, blocks.incoming.entries[0].section);
}

const Exposed = struct { section: chunks.Section, mask: [64]u64, used: bool };

/// Adds the face neighbours of every edit that leaves a non-occluder: inside `section` to
/// `mask`, across a face to the matching entry of `others`.
fn exposure(section: chunks.Section, edits: []const chunks.BlockEdit, mask: *[64]u64, others: *[6]Exposed) void {
    for (others) |*other| other.used = false;
    for (edits) |edit| {
        if (game_data.physics.rendering(edit.state).occluder) continue;
        const at = [3]i32{ edit.index % 16, edit.index / 256, edit.index / 16 % 16 };
        inline for (0..6) |side| {
            var next = at;
            next[side / 2] += if (side % 2 == 0) -1 else 1;
            const local: u12 = @intCast(@mod(next[1], 16) * 256 + @mod(next[2], 16) * 16 + @mod(next[0], 16));
            const bit = @as(u64, 1) << @intCast(local % 64);
            if (next[side / 2] >= 0 and next[side / 2] < 16) {
                mask[local / 64] |= bit;
            } else {
                const other = &others[side];
                if (!other.used) {
                    other.* = .{ .section = section, .mask = @splat(0), .used = true };
                    const offsets = [3]*i32{ &other.section.x, &other.section.y, &other.section.z };
                    offsets[side / 2].* += if (side % 2 == 0) -1 else 1;
                }
                other.mask[local / 64] |= bit;
            }
        }
    }
}

test "edits that open a block expose their face neighbours across section borders" {
    const section: chunks.Section = .{ .world = 0, .x = 2, .y = 1, .z = -1 };
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var mask: [64]u64 = @splat(0);
    var others: [6]Exposed = undefined;
    // A placed occluder exposes nothing.
    exposure(section, &.{.{ .index = 5 * 256 + 5 * 16 + 5, .state = stone }}, &mask, &others);
    for (mask) |word| try std.testing.expectEqual(@as(u64, 0), word);
    for (others) |other| try std.testing.expect(!other.used);
    // Mining the corner block at x 15, y 0, z 0 exposes three neighbours inside and three across.
    const corner: u12 = 0 * 256 + 0 * 16 + 15;
    exposure(section, &.{.{ .index = corner, .state = 0 }}, &mask, &others);
    var inside: usize = 0;
    for (mask) |word| inside += @popCount(word);
    try std.testing.expectEqual(@as(usize, 3), inside);
    for ([_]u12{ 14, 256 + 15, 16 + 15 }) |cell| try std.testing.expect(mask[cell / 64] & (@as(u64, 1) << @intCast(cell % 64)) != 0);
    try std.testing.expect(!others[0].used and !others[3].used and !others[5].used);
    try std.testing.expectEqual(chunks.Section{ .world = 0, .x = 3, .y = 1, .z = -1 }, others[1].section);
    try std.testing.expect(others[1].mask[0] & 1 != 0);
    try std.testing.expectEqual(chunks.Section{ .world = 0, .x = 2, .y = 0, .z = -1 }, others[2].section);
    const below: u12 = 15 * 256 + 0 * 16 + 15;
    try std.testing.expect(others[2].mask[below / 64] & (@as(u64, 1) << @intCast(below % 64)) != 0);
    try std.testing.expectEqual(chunks.Section{ .world = 0, .x = 2, .y = 1, .z = -2 }, others[4].section);
    const north: u12 = 0 * 256 + 15 * 16 + 15;
    try std.testing.expect(others[4].mask[north / 64] & (@as(u64, 1) << @intCast(north % 64)) != 0);
}

test "near corrections follow the eye section and drop sections that leave its neighbourhood" {
    const eye: chunks.Section = .{ .world = 1, .x = 4, .y = 2, .z = -3 };
    var near: [27]BlockSynchronization.Observer.Near = undefined;
    for (&near, 0..) |*entry, cell| entry.* = .{ .section = BlockSynchronization.nearSection(eye, cell), .delivery = @intCast(cell), .valid = true };
    const moved: chunks.Section = .{ .world = 1, .x = 5, .y = 2, .z = -3 };
    const result = BlockSynchronization.remapNear(&near, moved);
    var kept: usize = 0;
    for (result, 0..) |entry, cell| {
        if (!entry.valid) {
            // Cells on the leading side were never corrected.
            try std.testing.expectEqual(@as(usize, 2), cell % 3);
            continue;
        }
        kept += 1;
        try std.testing.expectEqual(BlockSynchronization.nearSection(moved, cell), entry.section);
        // The entry came from the cell one step further along x around the old eye.
        try std.testing.expectEqual(@as(u32, @intCast(cell + 1)), entry.delivery);
    }
    try std.testing.expectEqual(@as(usize, 18), kept);
    const other_world = BlockSynchronization.remapNear(&near, .{ .world = 2, .x = 4, .y = 2, .z = -3 });
    for (other_world) |entry| try std.testing.expect(!entry.valid);
}
