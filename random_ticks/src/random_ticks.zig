//! Random ticks: vanilla picks `speed` random cells of every ticking section each game tick and
//! ticks the ones whose block ticks randomly. A cell is picked with probability speed/4096 each
//! tick, independent of every other cell. This engine draws the same process without visiting
//! idle sections: a section with n tickable cells waits a geometric number of picks, with
//! success n/4096, until its next hit, and a hit ticks one of its tickable cells, chosen
//! uniformly. Counts come from a topology the chunk store keeps in the derived cache, so a
//! column entering the ticking domain costs one summary read, and edits keep them current.

const std = @import("std");
const chunks = @import("chunks");
const Domains = @import("domains").domains.Domains;
const DomainColumn = @import("domains").domains.Column;
const Worlds = @import("worlds").Worlds;

const assert = std.debug.assert;
const Topology = chunks.topology.Topology;

pub const Hit = struct { world: u32, position: chunks.Position, state: u16 };

pub const RandomTicks = struct {
    pub const id = "lightning_rod:random_ticks";

    pub const Configuration = struct {
        /// Whether a block state ticks randomly. Fixed for the life of the server, as the
        /// topology persisted for it is keyed by the states it selects.
        tickable: *const fn (u16) bool = never,
        /// Block states, the length of the tables `tickable` fills.
        states: u16 = 0,
        /// Cells vanilla picks in each section per game tick, its randomTickSpeed.
        speed: u8 = 3,
        /// Ticking columns tracked at once.
        columns: u32 = 1 << 12,
        /// Sections with tickable cells tracked at once.
        sections: u32 = 1 << 15,
        /// Column summaries asked for and not yet answered.
        requests: u32 = 256,
        handlers: u8 = 32,
        seed: u64 = 0x72616e646f6d,

        fn never(_: u16) bool {
            return false;
        }
    };

    pub const Dependencies = struct {
        domains: *Domains,
        chunks: *chunks.Chunks,
        worlds: *Worlds,
    };

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

    const none = std.math.maxInt(u32);
    const no_handler = std.math.maxInt(u8);
    const sections_max = 32;

    const ColumnState = struct {
        world: u32,
        x: i32,
        z: i32,
        minimum: i32 = 0,
        count: u8 = 0,
        /// Sections whose tickable count is known.
        known: u32 = 0,
        counts: [sections_max]u16 = @splat(0),
        /// Tracked section slots with tickable cells, by section.
        slots: [sections_max]u32 = @splat(none),
        /// Waiting for a summary, asked for or about to be.
        summarizing: bool = false,
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
    };

    deps: Dependencies,
    config: Configuration,
    tickable: []u8,
    handlers: []u8,
    handler_list: []Handler,
    handler_count: u8 = 0,
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
    /// Columns that began ticking and still have to be asked for.
    unasked: []u32,
    unasked_count: u32 = 0,
    answers: []chunks.topology.Answer,
    /// The game tick whose picks come next.
    tick_count: u64 = 0,
    /// The next pick not drawn yet. Counts that change draw their next hit from here.
    cursor: u64 = 0,
    overflow: bool = false,
    hits: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*RandomTicks {
        if (config.states == 0 or config.speed == 0 or config.columns == 0 or config.sections == 0 or config.requests == 0 or config.handlers == 0 or config.handlers == no_handler) return error.InvalidConfiguration;
        const states: usize = config.states;
        const self = try allocator.create(RandomTicks);
        const tickable = try allocator.alloc(u8, states);
        for (tickable, 0..) |*flag, state| flag.* = @intFromBool(config.tickable(@intCast(state)));
        const column_states = try allocator.alloc(ColumnState, config.columns);
        for (column_states, 0..) |*state, index| state.* = .{ .world = 0, .x = 0, .z = 0, .next_free = if (index + 1 < column_states.len) @intCast(index + 1) else none };
        const slots = try allocator.alloc(SectionSlot, config.sections);
        for (slots, 0..) |*slot, index| slot.* = .{ .column = none, .offset = 0, .next = 0, .heap = none, .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none };
        const by_column = try allocator.alloc(u32, try std.math.ceilPowerOfTwo(usize, 2 * @as(usize, config.columns)));
        @memset(by_column, none);
        const handlers = try allocator.alloc(u8, states);
        @memset(handlers, no_handler);
        self.* = .{
            .deps = deps,
            .config = config,
            .tickable = tickable,
            .handlers = handlers,
            .handler_list = try allocator.alloc(Handler, config.handlers),
            .topology = try deps.chunks.openTopology(allocator, tickable, 1, .{ .identity = "lightning_rod:random_ticks:count:1", .maximum = 2, .prefix_bytes = 2, .encode = encodeCount }, config.requests),
            .client = try deps.chunks.simulation(1),
            .random = .init(config.seed),
            .column_states = column_states,
            .by_column = by_column,
            .slots = slots,
            .heap = try allocator.alloc(u32, config.sections),
            .unasked = try allocator.alloc(u32, config.columns),
            .answers = try allocator.alloc(chunks.topology.Answer, config.requests),
        };
        try deps.domains.observe(.init(RandomTicks, self, domainChanged));
        try deps.chunks.observe(.init(self, blocksChanged));
        return self;
    }

    /// Each section's tickable cells, as the topology stores them.
    fn encodeCount(known: *const chunks.encoding.Classification.Known, output: []u8) !usize {
        var count: u16 = 0;
        for (known.selected) |word| count += @popCount(word);
        std.mem.writeInt(u16, output[0..2], count, .little);
        return 2;
    }

    /// Runs `handler` when a hit lands on a state `selects` picks. Every such state ticks
    /// randomly. Startup only.
    pub fn register(self: *RandomTicks, selects: *const fn (u16) bool, handler: Handler) !void {
        if (self.handler_count == self.handler_list.len) return error.HandlerCapacity;
        const index = self.handler_count;
        self.handler_list[index] = handler;
        self.handler_count += 1;
        for (self.handlers, self.tickable, 0..) |*slot, flag, state| {
            if (!selects(@intCast(state))) continue;
            if (flag == 0) return error.NotTickable;
            if (slot.* != no_handler) return error.DuplicateHandler;
            slot.* = index;
        }
    }

    /// The source of randomness hits run with.
    pub fn rng(self: *RandomTicks) std.Random {
        return self.random.random();
    }

    fn domainChanged(self: *RandomTicks, entered: []const DomainColumn, left: []const DomainColumn) void {
        for (left) |column| if (self.find(column.world, column.x, column.z)) |at| self.dropColumn(at);
        for (entered) |column| {
            if (self.find(column.world, column.x, column.z) != null) continue;
            const world = self.deps.worlds.get(column.world) orelse continue;
            const count = world.dimension.sectionCount();
            if (count == 0 or count > sections_max) continue;
            const index = self.column_free;
            if (index == none or self.unasked_count == self.unasked.len) {
                self.overflow = true;
                continue;
            }
            self.column_free = self.column_states[index].next_free;
            self.column_states[index] = .{ .world = column.world, .x = column.x, .z = column.z, .minimum = world.dimension.minimumSection(), .count = @intCast(count), .summarizing = true, .live = true };
            var at = self.home(column.world, column.x, column.z);
            while (self.by_column[at] != none) at = (at + 1) & (self.by_column.len - 1);
            self.by_column[at] = index;
            self.unasked[self.unasked_count] = index;
            self.unasked_count += 1;
        }
    }

    fn blocksChanged(self: *RandomTicks, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        const at = self.find(section.world, section.x, section.z) orelse return;
        const index = self.by_column[at];
        const state = &self.column_states[index];
        const offset = @as(i64, section.y) - state.minimum;
        if (offset < 0 or offset >= state.count) return;
        const bit = @as(u32, 1) << @intCast(offset);
        if (state.known & bit == 0) return;
        var count: i32 = state.counts[@intCast(offset)];
        for (edits, previous) |edit, old| count += @as(i32, self.tickable[edit.state]) - self.tickable[old];
        assert(count >= 0 and count <= 4096);
        self.setCount(index, @intCast(offset), @intCast(count), self.cursor);
    }

    pub fn tick(self: *RandomTicks) !void {
        if (self.overflow) return error.RandomTickCapacity;
        try self.collect();
        const start = self.tick_count * self.config.speed;
        const end = start + self.config.speed;
        self.cursor = @max(self.cursor, start);
        while (self.heap_count != 0) {
            const slot_index = self.heap[0];
            const slot = &self.slots[slot_index];
            if (slot.next >= end) break;
            const pick = slot.next;
            self.cursor = pick + 1;
            try self.hitSection(slot_index);
            // The section may have left with its column, or changed its count, in the hit.
            if (self.slots[slot_index].column != none and self.slots[slot_index].next == pick) self.reschedule(slot_index, pick + 1);
        }
        self.tick_count += 1;
        self.cursor = end;
    }

    /// Takes summary answers and asks for columns still unasked.
    fn collect(self: *RandomTicks) !void {
        while (true) {
            const count = self.topology.take(self.answers);
            if (count == 0) break;
            for (self.answers[0..count]) |answer| self.apply(answer);
        }
        if (self.unasked_count != 0) {
            var columns: [64]chunks.topology.Column = undefined;
            var begin: u32 = 0;
            while (begin < self.unasked_count) {
                const batch = @min(columns.len, self.unasked_count - begin);
                for (self.unasked[begin..][0..batch], columns[0..batch]) |index, *column| {
                    const state = self.column_states[index];
                    column.* = .{ .world = state.world, .x = state.x, .z = state.z, .minimum = state.minimum, .count = state.count };
                }
                const accepted = self.topology.request(columns[0..batch]);
                begin += @intCast(accepted);
                if (accepted < batch) break;
            }
            std.mem.copyForwards(u32, self.unasked[0 .. self.unasked_count - begin], self.unasked[begin..self.unasked_count]);
            self.unasked_count -= begin;
        }
    }

    fn apply(self: *RandomTicks, answer: chunks.topology.Answer) void {
        const column = answer.column;
        // The column may have left the domain, and maybe come back, since it was asked for.
        const at = self.find(column.world, column.x, column.z) orelse return;
        const index = self.by_column[at];
        const state = &self.column_states[index];
        if (!state.summarizing) return;
        if (!answer.available) {
            self.unasked[self.unasked_count] = index;
            self.unasked_count += 1;
            return;
        }
        state.summarizing = false;
        const summary = answer.summary;
        const pick = self.cursor;
        for (0..state.count) |offset| {
            const bit = @as(u32, 1) << @intCast(offset);
            const count: ?u16 = if (summary.prefixed & bit != 0)
                std.mem.readInt(u16, summary.prefixes[offset][0..2], .little)
            else if (summary.known & bit != 0 and summary.common[offset] & 1 != 0)
                4096
            else if (summary.missing & bit != 0)
                0
            else
                self.countLive(state.*, @intCast(offset));
            // A section in no record and no memory has nothing to tick until it is written.
            const value = count orelse continue;
            if (value > 4096) continue;
            state.known |= bit;
            self.setCount(index, @intCast(offset), value, pick);
        }
    }

    /// Counts a section whose summary is out of date because it has edits in memory only.
    fn countLive(self: *RandomTicks, state: ColumnState, offset: u8) ?u16 {
        const section: chunks.Section = .{ .world = state.world, .x = state.x, .z = state.z, .y = state.minimum + offset };
        var leases: [1]chunks.Lease = undefined;
        if (!self.client.acquireCached(&.{section}, &leases)) return null;
        defer leases[0].release();
        const bytes = leases[0].record.read() orelse return 0;
        const known = chunks.encoding.classify(bytes, self.tickable, 1) catch return null;
        var count: u16 = 0;
        for (known.selected) |word| count += @popCount(word);
        return count;
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

    fn hitSection(self: *RandomTicks, slot_index: u32) !void {
        const slot = self.slots[slot_index];
        const state = self.column_states[slot.column];
        const section: chunks.Section = .{ .world = state.world, .x = state.x, .z = state.z, .y = state.minimum + slot.offset };
        const hit = hit: {
            const lease = try self.client.acquire(section);
            defer lease.release();
            const bytes = lease.record.read() orelse break :hit null;
            const known = try chunks.encoding.classify(bytes, self.tickable, 1);
            var count: u16 = 0;
            for (known.selected) |word| count += @popCount(word);
            if (count != state.counts[slot.offset]) {
                // The count was out of date. The true one draws the next hit.
                self.setCount(slot.column, slot.offset, count, slot.next + 1);
                if (count == 0) break :hit null;
            }
            var rank = self.random.random().uintLessThan(u16, count);
            const cell: u12 = for (known.selected, 0..) |word, index| {
                const ones: u16 = @popCount(word);
                if (rank < ones) {
                    var bits = word;
                    for (0..rank) |_| bits &= bits - 1;
                    break @intCast(index * 64 + @ctz(bits));
                }
                rank -= ones;
            } else unreachable;
            break :hit Hit{
                .world = state.world,
                .position = .{ .x = state.x * 16 + (cell & 15), .y = section.y * 16 + (cell >> 8), .z = state.z * 16 + ((cell >> 4) & 15) },
                .state = lease.get(cell),
            };
        } orelse return;
        self.hits += 1;
        const handler = self.handlers[hit.state];
        if (handler == no_handler) return;
        try self.handler_list[handler].run(self.handler_list[handler].context, hit);
    }

    fn dropColumn(self: *RandomTicks, at: usize) void {
        const index = self.by_column[at];
        const state = &self.column_states[index];
        for (state.slots) |slot_index| if (slot_index != none) self.freeSlot(slot_index);
        if (state.summarizing) {
            // An answer still coming finds no column and is dropped.
            for (self.unasked[0..self.unasked_count], 0..) |unasked, position| if (unasked == index) {
                self.unasked[position] = self.unasked[self.unasked_count - 1];
                self.unasked_count -= 1;
                break;
            };
        }
        self.removeIndex(at);
        state.live = false;
        state.next_free = self.column_free;
        self.column_free = index;
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
