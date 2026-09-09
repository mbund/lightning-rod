const std = @import("std");
const lightning_rod = @import("lightning_rod");
const chunk_tickets = @import("chunk_tickets.zig");
const persistence = @import("../plugins/vanilla_persistence.zig");

const geometry = lightning_rod.geometry;
const world_identity = lightning_rod.world_identity;

pub const Level = enum(u8) {
    full = 1,
    block_ticking = 2,
    entity_ticking = 3,
};

pub const Transition = struct {
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
    before: ?Level,
    after: ?Level,
};

pub const Active = struct {
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
    level: Level,
};

pub const Iterator = struct {
    entries: []const Entry,
    slots: []const u32,
    index: usize = 0,

    pub fn next(self: *Iterator) ?Active {
        if (self.index == self.slots.len) return null;
        const entry = self.entries[self.slots[self.index]];
        self.index += 1;
        std.debug.assert(entry.state == .occupied and entry.active != 0);
        return .{ .world = entry.world, .chunk = entry.chunk, .level = @enumFromInt(entry.active) };
    }
};

const SlotState = enum(u8) { vacant, tombstone, occupied };

const Entry = struct {
    state: SlotState = .vacant,
    world: world_identity.Handle = world_identity.invalid,
    chunk: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    active: u8 = 0,
    desired: u8 = 0,
    desired_epoch: u32 = 0,
    pending: bool = false,
    active_position: u32 = std.math.maxInt(u32),
};

pub const SimulationAdmission = struct {
    pub const id = "minecraft:simulation_admission";
    pub const Configuration = struct {
        maximum_chunks: usize = 65_536,
        maximum_transitions_per_tick: usize = 512,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_chunks == 0 or !std.math.isPowerOfTwo(self.maximum_chunks) or
                self.maximum_transitions_per_tick == 0)
                return error.InvalidSimulationAdmissionCapacity;
        }
    };
    pub const Dependencies = struct {
        worlds: *lightning_rod.worlds.Worlds,
        tickets: *chunk_tickets.ChunkTickets,
        materializer: *persistence.Materializer,
        runtime_metrics: ?*lightning_rod.metrics.Runtime = null,
    };

    deps: Dependencies,
    entries: []Entry,
    pending: []Transition,
    pending_slots: []u32,
    work_slots: []u32,
    active_slots: []u32,
    pending_count: usize = 0,
    work_count: usize = 0,
    active_slot_count: usize = 0,
    observed_revision: u64 = 0,
    desired_epoch: u32 = 0,
    active_revision: u64 = 1,
    active_count: usize = 0,
    transition_cursor: usize = 0,
    transition_scan_pending: bool = false,
    retry_pending: bool = false,
    overflowed: bool = false,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*SimulationAdmission {
        try configuration.validate();
        const self = try allocator.create(SimulationAdmission);
        self.* = .{
            .deps = deps,
            .entries = try allocator.alloc(Entry, configuration.maximum_chunks * 2),
            .pending = try allocator.alloc(Transition, configuration.maximum_transitions_per_tick),
            .pending_slots = try allocator.alloc(u32, configuration.maximum_transitions_per_tick),
            .work_slots = try allocator.alloc(u32, configuration.maximum_chunks * 2),
            .active_slots = try allocator.alloc(u32, configuration.maximum_chunks * 2),
        };
        @memset(self.entries, .{});
        return self;
    }

    pub fn tick(self: *SimulationAdmission, _: std.mem.Allocator) lightning_rod.plugin_lifecycle.FatalError!void {
        if (self.observed_revision != self.deps.tickets.revision()) self.rebuildDesired();
        try self.advanceTransitions();
        if (self.deps.runtime_metrics) |runtime| {
            runtime.setSimulationAdmission(self.active_count, self.entries.len / 2, self.pending_count, self.overflowed);
        }
    }

    fn advanceTransitions(self: *SimulationAdmission) lightning_rod.plugin_lifecycle.FatalError!void {
        self.pending_count = 0;
        while (self.transition_scan_pending and self.transition_cursor < self.work_count and self.pending_count < self.pending.len) {
            const slot: usize = self.work_slots[self.transition_cursor];
            self.transition_cursor += 1;
            const entry = &self.entries[slot];
            if (entry.state != .occupied or entry.pending) continue;
            if (entry.desired_epoch != self.desired_epoch) entry.desired = 0;
            if (entry.active == entry.desired) continue;
            if (entry.desired > entry.active and !try self.canonicalReady(entry.world, entry.chunk)) {
                self.retry_pending = true;
                continue;
            }
            if (self.pending_count == self.pending.len) break;

            const transition = Transition{
                .world = entry.world,
                .chunk = entry.chunk,
                .before = if (entry.active == 0) null else @enumFromInt(entry.active),
                .after = if (entry.desired == 0) null else @enumFromInt(entry.desired),
            };
            self.pending[self.pending_count] = transition;
            self.pending_slots[self.pending_count] = @intCast(slot);
            self.pending_count += 1;
            entry.pending = true;
        }
        if (self.transition_cursor == self.work_count) {
            self.transition_cursor = if (self.retry_pending) 0 else self.work_count;
            self.transition_scan_pending = self.retry_pending;
            self.retry_pending = false;
        }
    }

    pub fn transitions(self: *const SimulationAdmission) []const Transition {
        return self.pending[0..self.pending_count];
    }

    pub fn level(self: *const SimulationAdmission, world: world_identity.Handle, chunk: geometry.ChunkPos) ?Level {
        const slot = self.find(world, chunk) orelse return null;
        const active = self.entries[slot].active;
        return if (active == 0) null else @enumFromInt(active);
    }

    pub fn full(self: *const SimulationAdmission, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        return self.level(world, chunk) != null;
    }

    pub fn blockTicking(self: *const SimulationAdmission, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        const value = self.level(world, chunk) orelse return false;
        return @intFromEnum(value) >= @intFromEnum(Level.block_ticking);
    }

    pub fn entityTicking(self: *const SimulationAdmission, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        return self.level(world, chunk) == .entity_ticking;
    }

    pub fn overflow(self: *const SimulationAdmission) bool {
        return self.overflowed;
    }

    pub fn revision(self: *const SimulationAdmission) u64 {
        return self.active_revision;
    }

    pub fn iterator(self: *const SimulationAdmission) Iterator {
        return .{ .entries = self.entries, .slots = self.active_slots[0..self.active_slot_count] };
    }

    pub fn commit(self: *SimulationAdmission) void {
        if (self.pending_count != 0) {
            self.active_revision +%= 1;
            if (self.active_revision == 0) self.active_revision = 1;
        }
        for (self.pending_slots[0..self.pending_count]) |slot| {
            const entry = &self.entries[slot];
            if (entry.active == 0 and entry.desired != 0) {
                self.active_count += 1;
                entry.active_position = @intCast(self.active_slot_count);
                self.active_slots[self.active_slot_count] = slot;
                self.active_slot_count += 1;
            }
            if (entry.active != 0 and entry.desired == 0) {
                self.active_count -= 1;
                const position: usize = entry.active_position;
                self.active_slot_count -= 1;
                const moved_slot = self.active_slots[self.active_slot_count];
                self.active_slots[position] = moved_slot;
                self.entries[moved_slot].active_position = @intCast(position);
                entry.active_position = std.math.maxInt(u32);
            }
            entry.active = entry.desired;
            entry.pending = false;
            if (entry.active == 0 and entry.desired == 0) entry.state = .tombstone;
        }
        self.pending_count = 0;
    }

    fn rebuildDesired(self: *SimulationAdmission) void {
        self.desired_epoch +%= 1;
        if (self.desired_epoch == 0) {
            for (self.entries) |*entry| entry.desired_epoch = 0;
            self.desired_epoch = 1;
        }
        self.overflowed = false;
        // Desired-but-unadmitted entries from the previous ticket epoch have
        // no externally published handle. Recycle them before rebuilding so a
        // moving ticket source cannot leave inert hash slots occupied forever.
        self.recycleInactiveWork();
        self.work_count = 0;
        for (self.active_slots[0..self.active_slot_count]) |slot| {
            const entry = &self.entries[slot];
            entry.desired_epoch = self.desired_epoch;
            entry.desired = 0;
            self.appendWork(slot);
        }
        for (self.deps.worlds.active()) |world| {
            self.addLevel(world, chunk_tickets.full_level, .full);
            self.addLevel(world, chunk_tickets.block_ticking_level, .block_ticking);
            self.addLevel(world, chunk_tickets.entity_ticking_level, .entity_ticking);
        }
        self.observed_revision = self.deps.tickets.revision();
        self.transition_cursor = 0;
        self.transition_scan_pending = true;
        self.retry_pending = false;
    }

    fn canonicalReady(self: *SimulationAdmission, world: world_identity.Handle, chunk: geometry.ChunkPos) lightning_rod.plugin_lifecycle.FatalError!bool {
        var ready = true;
        const radius: i32 = 1;
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (!try self.deps.materializer.canonicalAvailable(world, .{ .x = chunk.x + dx, .z = chunk.z + dz }))
                    ready = false;
            }
        }
        return ready;
    }

    fn addLevel(self: *SimulationAdmission, world: world_identity.Handle, maximum_level: u8, level_value: Level) void {
        const bounds = self.deps.tickets.tickingRowBounds(world, maximum_level) orelse return;
        var z = bounds.first;
        while (z <= bounds.last) : (z += 1) {
            for (self.deps.tickets.tickingRowIntervals(world, z, maximum_level)) |interval| {
                var x = interval.first;
                while (x <= interval.last) : (x += 1)
                    self.touch(world, .{ .x = x, .z = z }, level_value);
            }
        }
    }

    fn touch(self: *SimulationAdmission, world: world_identity.Handle, chunk: geometry.ChunkPos, level_value: Level) void {
        var probe = hash(world, chunk);
        var tombstone: ?usize = null;
        for (0..self.entries.len) |_| {
            const slot = probe & (self.entries.len - 1);
            const entry = &self.entries[slot];
            switch (entry.state) {
                .vacant => {
                    const target = tombstone orelse slot;
                    self.entries[target] = .{
                        .state = .occupied,
                        .world = world,
                        .chunk = chunk,
                        .desired = @intFromEnum(level_value),
                        .desired_epoch = self.desired_epoch,
                    };
                    self.appendWork(@intCast(target));
                    return;
                },
                .tombstone => if (tombstone == null) {
                    tombstone = slot;
                },
                .occupied => if (entry.world.eql(world) and geometry.sameChunk(entry.chunk, chunk)) {
                    if (entry.desired_epoch != self.desired_epoch) {
                        entry.desired_epoch = self.desired_epoch;
                        entry.desired = 0;
                        self.appendWork(@intCast(slot));
                    }
                    entry.desired = @max(entry.desired, @intFromEnum(level_value));
                    return;
                },
            }
            probe += 1;
        }
        if (tombstone) |target| {
            self.entries[target] = .{
                .state = .occupied,
                .world = world,
                .chunk = chunk,
                .desired = @intFromEnum(level_value),
                .desired_epoch = self.desired_epoch,
            };
            self.appendWork(@intCast(target));
            return;
        }
        self.overflowed = true;
    }

    fn appendWork(self: *SimulationAdmission, slot: u32) void {
        if (self.work_count == self.work_slots.len) {
            self.overflowed = true;
            return;
        }
        self.work_slots[self.work_count] = slot;
        self.work_count += 1;
    }

    fn recycleInactiveWork(self: *SimulationAdmission) void {
        for (self.work_slots[0..self.work_count]) |slot| {
            const entry = &self.entries[slot];
            if (entry.state == .occupied and entry.active == 0 and !entry.pending) {
                entry.state = .tombstone;
                entry.desired = 0;
                entry.desired_epoch = 0;
            }
        }
    }

    fn find(self: *const SimulationAdmission, world: world_identity.Handle, chunk: geometry.ChunkPos) ?usize {
        var probe = hash(world, chunk);
        for (0..self.entries.len) |_| {
            const slot = probe & (self.entries.len - 1);
            const entry = &self.entries[slot];
            if (entry.state == .vacant) return null;
            if (entry.state == .occupied and entry.world.eql(world) and geometry.sameChunk(entry.chunk, chunk)) return slot;
            probe += 1;
        }
        return null;
    }
};

pub const Commit = struct {
    pub const id = "minecraft:commit_simulation_admission";
    pub const Configuration = struct {};
    pub const Dependencies = struct { admission: *SimulationAdmission };

    admission: *SimulationAdmission,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*Commit {
        const self = try allocator.create(Commit);
        self.* = .{ .admission = deps.admission };
        return self;
    }

    pub fn tick(self: *Commit, _: std.mem.Allocator) void {
        self.admission.commit();
    }
};

fn hash(world: world_identity.Handle, chunk: geometry.ChunkPos) usize {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&world));
    hasher.update(std.mem.asBytes(&chunk));
    return @intCast(hasher.final());
}

test "compact work processes a sparse far slot without probing empty hash entries" {
    var entries = [_]Entry{.{}} ** 16;
    var pending: [1]Transition = undefined;
    var pending_slots: [1]u32 = undefined;
    var work_slots: [16]u32 = undefined;
    var active_slots: [16]u32 = undefined;
    const far_slot = entries.len - 1;
    entries[far_slot] = .{
        .state = .occupied,
        .active = @intFromEnum(Level.full),
        .desired_epoch = 1,
        .active_position = 0,
    };
    work_slots[0] = @intCast(far_slot);
    active_slots[0] = @intCast(far_slot);
    var admission = SimulationAdmission{
        .deps = undefined,
        .entries = &entries,
        .pending = &pending,
        .pending_slots = &pending_slots,
        .work_slots = &work_slots,
        .active_slots = &active_slots,
        .work_count = 1,
        .active_slot_count = 1,
        .desired_epoch = 1,
        .active_count = 1,
        .transition_scan_pending = true,
    };
    try admission.advanceTransitions();
    try std.testing.expectEqual(@as(usize, 1), admission.pending_count);
    try std.testing.expectEqual(@as(u32, @intCast(far_slot)), admission.pending_slots[0]);
    var before = admission.iterator();
    try std.testing.expectEqual(Level.full, before.next().?.level);
    try std.testing.expectEqual(@as(?Active, null), before.next());
    admission.commit();
    try std.testing.expectEqual(@as(usize, 0), admission.active_count);
    try std.testing.expectEqual(SlotState.tombstone, entries[far_slot].state);
    var after = admission.iterator();
    try std.testing.expectEqual(@as(?Active, null), after.next());
}

test "ticket rebuild recycling releases abandoned unready work" {
    var entries = [_]Entry{.{}} ** 4;
    var work_slots: [4]u32 = undefined;
    entries[3] = .{ .state = .occupied, .desired = @intFromEnum(Level.entity_ticking), .desired_epoch = 7 };
    work_slots[0] = 3;
    var admission = SimulationAdmission{
        .deps = undefined,
        .entries = &entries,
        .pending = &.{},
        .pending_slots = &.{},
        .work_slots = &work_slots,
        .active_slots = &.{},
        .work_count = 1,
    };
    admission.recycleInactiveWork();
    try std.testing.expectEqual(SlotState.tombstone, entries[3].state);
    try std.testing.expectEqual(@as(u8, 0), entries[3].desired);
}

test "retry restarts only the compact work list" {
    var entries = [_]Entry{.{}} ** 8;
    var work_slots: [8]u32 = undefined;
    work_slots[0] = 7;
    var admission = SimulationAdmission{
        .deps = undefined,
        .entries = &entries,
        .pending = &.{},
        .pending_slots = &.{},
        .work_slots = &work_slots,
        .active_slots = &.{},
        .work_count = 1,
        .transition_cursor = 1,
        .transition_scan_pending = true,
        .retry_pending = true,
    };
    try admission.advanceTransitions();
    try std.testing.expect(admission.transition_scan_pending);
    try std.testing.expectEqual(@as(usize, 0), admission.transition_cursor);
    try std.testing.expect(!admission.retry_pending);
}

test "ticket touch reuses a tombstone when the table has no vacant slot" {
    var entries = [_]Entry{.{ .state = .tombstone }} ** 4;
    var work_slots: [4]u32 = undefined;
    var admission = SimulationAdmission{
        .deps = undefined,
        .entries = &entries,
        .pending = &.{},
        .pending_slots = &.{},
        .work_slots = &work_slots,
        .active_slots = &.{},
        .desired_epoch = 1,
    };
    admission.touch(.{ .index = 0, .generation = 1 }, .{ .x = 17, .z = -9 }, .full);
    try std.testing.expectEqual(@as(usize, 1), admission.work_count);
    try std.testing.expect(!admission.overflowed);
    try std.testing.expectEqual(SlotState.occupied, entries[admission.work_slots[0]].state);
}
