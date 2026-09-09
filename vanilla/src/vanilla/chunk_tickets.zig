const std = @import("std");
const lightning_rod = @import("lightning_rod");

const geometry = lightning_rod.geometry;
const player_store = lightning_rod.players;
const world_identity = lightning_rod.world_identity;
const world_clock = lightning_rod.clock;
const metrics = lightning_rod.metrics;

pub const Interval = struct { first: i32, last: i32 };
pub const RowBounds = struct { first: i32, last: i32 };
pub const entity_ticking_level: u8 = 31;
pub const block_ticking_level: u8 = 32;
pub const full_level: u8 = 33;

pub const TicketDescription = struct {
    world: world_identity.Handle,
    center: geometry.ChunkPos,
    level: u8,
    expires_at: ?u64 = null,
};

const TicketHandle = packed struct(u32) { index: u16, generation: u16 };

const TicketRecord = struct {
    active: bool = false,
    generation: u16 = 0,
    source: u64 = 0,
    description: TicketDescription = undefined,
};

const PlayerObservation = struct {
    eligible: bool = false,
    world: world_identity.Handle = world_identity.invalid,
    chunk: geometry.ChunkPos = .{ .x = 0, .z = 0 },
};

pub const Iterator = struct {
    records: []const TicketRecord,
    index: usize = 0,

    pub fn next(self: *Iterator) ?TicketDescription {
        while (self.index < self.records.len) {
            const record = self.records[self.index];
            self.index += 1;
            if (record.active) return record.description;
        }
        return null;
    }
};

pub fn Source(comptime id: []const u8) type {
    if (id.len == 0) @compileError("chunk ticket source id cannot be empty");
    return struct {
        pub const Handle = packed struct(u32) { index: u16, generation: u16 };

        pub fn acquire(tickets: *ChunkTickets, description: TicketDescription) !Handle {
            return @bitCast(try tickets.acquireTicket(std.hash.Wyhash.hash(0, id), description));
        }

        pub fn update(tickets: *ChunkTickets, handle: Handle, description: TicketDescription) !void {
            try tickets.updateTicket(std.hash.Wyhash.hash(0, id), @bitCast(handle), description);
        }

        pub fn move(tickets: *ChunkTickets, handle: Handle, center: geometry.ChunkPos) !void {
            const internal: TicketHandle = @bitCast(handle);
            const record = tickets.ticket(internal) orelse return error.StaleChunkTicket;
            if (record.source != std.hash.Wyhash.hash(0, id)) return error.StaleChunkTicket;
            var description = record.description;
            description.center = center;
            try tickets.updateTicket(record.source, internal, description);
        }

        pub fn release(tickets: *ChunkTickets, handle: Handle) void {
            tickets.releaseTicket(std.hash.Wyhash.hash(0, id), @bitCast(handle));
        }
    };
}

pub const ChunkTickets = struct {
    pub const id = "minecraft:chunk_tickets";
    pub const Dependencies = struct {
        players: *player_store.Players,
        clock: *world_clock.Clock,
        runtime_metrics: ?*metrics.Runtime,
    };
    pub const Configuration = struct {
        simulation_distance_chunks: i32 = 12,
        maximum_plugin_tickets: usize = 4_096,
    };

    deps: Dependencies,
    simulation_distance_chunks: i32,
    intervals: []Interval = &.{},
    tickets: []TicketRecord = &.{},
    free_tickets: []u16 = &.{},
    free_ticket_count: usize = 0,
    ticket_pool_initialized: bool = false,
    ticket_revision: u64 = 1,
    player_observations: []PlayerObservation = &.{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, settings: Configuration) !*ChunkTickets {
        if (settings.simulation_distance_chunks < 0 or settings.simulation_distance_chunks > 32)
            return error.InvalidSimulationDistance;
        if (settings.maximum_plugin_tickets == 0 or settings.maximum_plugin_tickets > std.math.maxInt(u16))
            return error.InvalidChunkTicketCapacity;
        const self = try allocator.create(ChunkTickets);
        self.* = .{
            .deps = deps,
            .simulation_distance_chunks = settings.simulation_distance_chunks,
            .intervals = try allocator.alloc(Interval, deps.players.records.len + settings.maximum_plugin_tickets),
            .tickets = try allocator.alloc(TicketRecord, settings.maximum_plugin_tickets),
            .free_tickets = try allocator.alloc(u16, settings.maximum_plugin_tickets),
            .player_observations = try allocator.alloc(PlayerObservation, deps.players.records.len),
        };
        @memset(self.tickets, .{});
        @memset(self.player_observations, .{});
        for (self.free_tickets, 0..) |*slot, index| slot.* = @intCast(self.free_tickets.len - index - 1);
        self.free_ticket_count = self.free_tickets.len;
        self.ticket_pool_initialized = true;
        return self;
    }

    pub fn tick(self: *ChunkTickets, _: std.mem.Allocator) void {
        for (self.deps.players.records, self.player_observations) |*player, *observation| {
            const current = PlayerObservation{
                .eligible = player.state == .play and player.gamemode != .spectator,
                .world = player.world,
                .chunk = .{
                    .x = chunkCoordinate(player.position.x),
                    .z = chunkCoordinate(player.position.z),
                },
            };
            if (current.eligible != observation.eligible or
                !current.world.eql(observation.world) or
                !geometry.sameChunk(current.chunk, observation.chunk))
            {
                observation.* = current;
                self.bumpRevision();
            }
        }
        for (self.tickets, 0..) |record, index| {
            if (!record.active) continue;
            const expires = record.description.expires_at orelse continue;
            if (expires <= self.deps.clock.tick) self.releaseIndex(index);
        }
        if (self.deps.runtime_metrics) |runtime|
            runtime.setGameplayTickets(self.pluginTicketCount(), self.tickets.len);
    }

    pub fn simulationDistance(self: *const ChunkTickets) i32 {
        return self.simulation_distance_chunks;
    }

    pub fn revision(self: *const ChunkTickets) u64 {
        return self.ticket_revision;
    }

    pub fn pluginTicketCount(self: *const ChunkTickets) usize {
        return self.tickets.len - self.free_ticket_count;
    }

    pub fn pluginTicketCapacity(self: *const ChunkTickets) usize {
        return self.tickets.len;
    }

    pub fn iterator(self: *const ChunkTickets) Iterator {
        return .{ .records = self.tickets };
    }

    pub fn entityTicking(self: *const ChunkTickets, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        return self.withinPlayerDistance(world, chunk, @min(self.simulation_distance_chunks, entity_ticking_level)) or
            self.withinTicketLevel(world, chunk, entity_ticking_level);
    }

    pub fn blockTicking(self: *const ChunkTickets, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        return self.withinPlayerDistance(world, chunk, @min(self.simulation_distance_chunks + 1, block_ticking_level)) or
            self.withinTicketLevel(world, chunk, block_ticking_level);
    }

    pub fn full(self: *const ChunkTickets, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        return self.withinPlayerDistance(world, chunk, @min(self.simulation_distance_chunks + 2, full_level)) or
            self.withinTicketLevel(world, chunk, full_level);
    }

    pub fn playerRowBounds(self: *const ChunkTickets, world: world_identity.Handle, radius: i32) ?RowBounds {
        var result: ?RowBounds = null;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!eligible(player, world)) continue;
            const chunk_z = chunkCoordinate(player.position.z);
            if (result) |*bounds| {
                bounds.first = @min(bounds.first, chunk_z - radius);
                bounds.last = @max(bounds.last, chunk_z + radius);
            } else result = .{ .first = chunk_z - radius, .last = chunk_z + radius };
        }
        return result;
    }

    pub fn playerRowIntervals(self: *ChunkTickets, world: world_identity.Handle, chunk_z: i32, radius: i32) []const Interval {
        var count: usize = 0;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!eligible(player, world) or @abs(chunkCoordinate(player.position.z) - chunk_z) > radius) continue;
            const center_x = chunkCoordinate(player.position.x);
            const value = Interval{ .first = center_x - radius, .last = center_x + radius };
            var insert_at = count;
            for (0..count) |_| {
                if (insert_at == 0 or self.intervals[insert_at - 1].first <= value.first) break;
                self.intervals[insert_at] = self.intervals[insert_at - 1];
                insert_at -= 1;
            }
            self.intervals[insert_at] = value;
            count += 1;
        }
        if (count == 0) return self.intervals[0..0];
        var output: usize = 1;
        for (self.intervals[1..count]) |interval| {
            const previous = &self.intervals[output - 1];
            if (interval.first <= previous.last +| 1) {
                previous.last = @max(previous.last, interval.last);
                continue;
            }
            self.intervals[output] = interval;
            output += 1;
        }
        return self.intervals[0..output];
    }

    pub fn countPlayerUnion(self: *ChunkTickets, world: world_identity.Handle, bounds: RowBounds, radius: i32) usize {
        var result: usize = 0;
        const rows: usize = @intCast(bounds.last - bounds.first + 1);
        for (0..rows) |offset| {
            const chunk_z = bounds.first + @as(i32, @intCast(offset));
            for (self.playerRowIntervals(world, chunk_z, radius)) |interval|
                result += @intCast(interval.last - interval.first + 1);
        }
        return result;
    }

    pub fn tickingRowBounds(self: *const ChunkTickets, world: world_identity.Handle, maximum_level: u8) ?RowBounds {
        var result = self.playerRowBounds(world, self.playerRadius(maximum_level));
        for (self.tickets) |record| {
            const radius = ticketRadius(record, world, maximum_level) orelse continue;
            if (result) |*bounds| {
                bounds.first = @min(bounds.first, record.description.center.z - radius);
                bounds.last = @max(bounds.last, record.description.center.z + radius);
            } else result = .{
                .first = record.description.center.z - radius,
                .last = record.description.center.z + radius,
            };
        }
        return result;
    }

    pub fn tickingRowIntervals(self: *ChunkTickets, world: world_identity.Handle, chunk_z: i32, maximum_level: u8) []const Interval {
        var count: usize = 0;
        const player_radius = self.playerRadius(maximum_level);
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!eligible(player, world) or @abs(chunkCoordinate(player.position.z) - chunk_z) > player_radius) continue;
            count = insertInterval(self.intervals, count, .{
                .first = chunkCoordinate(player.position.x) - player_radius,
                .last = chunkCoordinate(player.position.x) + player_radius,
            });
        }
        for (self.tickets) |record| {
            const radius = ticketRadius(record, world, maximum_level) orelse continue;
            if (@abs(record.description.center.z - chunk_z) > radius) continue;
            count = insertInterval(self.intervals, count, .{
                .first = record.description.center.x - radius,
                .last = record.description.center.x + radius,
            });
        }
        return mergeIntervals(self.intervals, count);
    }

    pub fn countTickingUnion(self: *ChunkTickets, world: world_identity.Handle, bounds: RowBounds, maximum_level: u8) usize {
        var result: usize = 0;
        const rows: usize = @intCast(bounds.last - bounds.first + 1);
        for (0..rows) |offset| {
            const chunk_z = bounds.first + @as(i32, @intCast(offset));
            for (self.tickingRowIntervals(world, chunk_z, maximum_level)) |interval|
                result += @intCast(interval.last - interval.first + 1);
        }
        return result;
    }

    fn withinPlayerDistance(self: *const ChunkTickets, world: world_identity.Handle, chunk: geometry.ChunkPos, radius: i32) bool {
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!eligible(player, world)) continue;
            if (@max(@abs(chunkCoordinate(player.position.x) - chunk.x), @abs(chunkCoordinate(player.position.z) - chunk.z)) <= radius)
                return true;
        }
        return false;
    }

    fn playerRadius(self: *const ChunkTickets, maximum_level: u8) i32 {
        return @max(0, self.simulation_distance_chunks + @as(i32, maximum_level) - entity_ticking_level);
    }

    fn acquireTicket(self: *ChunkTickets, source: u64, description: TicketDescription) !TicketHandle {
        if (!self.ticket_pool_initialized or self.free_ticket_count == 0) return error.ChunkTicketCapacity;
        if (description.level > full_level) return error.InvalidChunkTicketLevel;
        self.free_ticket_count -= 1;
        const index = self.free_tickets[self.free_ticket_count];
        const record = &self.tickets[index];
        var generation = record.generation +% 1;
        if (generation == 0) generation = 1;
        record.* = .{
            .active = true,
            .generation = generation,
            .source = source,
            .description = description,
        };
        self.bumpRevision();
        return .{ .index = index, .generation = generation };
    }

    fn updateTicket(self: *ChunkTickets, source: u64, handle: TicketHandle, description: TicketDescription) !void {
        if (description.level > full_level) return error.InvalidChunkTicketLevel;
        const record = self.ticket(handle) orelse return error.StaleChunkTicket;
        if (record.source != source) return error.StaleChunkTicket;
        record.description = description;
        self.bumpRevision();
    }

    fn ticket(self: *ChunkTickets, handle: TicketHandle) ?*TicketRecord {
        if (handle.index >= self.tickets.len) return null;
        const record = &self.tickets[handle.index];
        if (!record.active or record.generation != handle.generation) return null;
        return record;
    }

    fn releaseTicket(self: *ChunkTickets, source: u64, handle: TicketHandle) void {
        const record = self.ticket(handle) orelse return;
        if (record.source != source) return;
        self.releaseIndex(handle.index);
    }

    fn releaseIndex(self: *ChunkTickets, index: usize) void {
        const record = &self.tickets[index];
        if (!record.active) return;
        record.active = false;
        self.free_tickets[self.free_ticket_count] = @intCast(index);
        self.free_ticket_count += 1;
        self.bumpRevision();
    }

    fn withinTicketLevel(self: *const ChunkTickets, world: world_identity.Handle, chunk: geometry.ChunkPos, maximum_level: u8) bool {
        for (self.tickets) |record| {
            if (!record.active or !record.description.world.eql(world)) continue;
            const distance: u32 = @intCast(@max(
                @abs(record.description.center.x - chunk.x),
                @abs(record.description.center.z - chunk.z),
            ));
            if (@as(u32, record.description.level) + distance <= maximum_level) return true;
        }
        return false;
    }

    fn bumpRevision(self: *ChunkTickets) void {
        self.ticket_revision +%= 1;
        if (self.ticket_revision == 0) self.ticket_revision = 1;
    }
};

fn ticketRadius(record: TicketRecord, world: world_identity.Handle, maximum_level: u8) ?i32 {
    if (!record.active or !record.description.world.eql(world) or record.description.level > maximum_level) return null;
    return @as(i32, maximum_level - record.description.level);
}

fn insertInterval(intervals: []Interval, count: usize, value: Interval) usize {
    var insert_at = count;
    while (insert_at > 0 and intervals[insert_at - 1].first > value.first) : (insert_at -= 1)
        intervals[insert_at] = intervals[insert_at - 1];
    intervals[insert_at] = value;
    return count + 1;
}

fn mergeIntervals(intervals: []Interval, count: usize) []const Interval {
    if (count == 0) return intervals[0..0];
    var output: usize = 1;
    for (intervals[1..count]) |interval| {
        const previous = &intervals[output - 1];
        if (interval.first <= previous.last +| 1) {
            previous.last = @max(previous.last, interval.last);
            continue;
        }
        intervals[output] = interval;
        output += 1;
    }
    return intervals[0..output];
}

fn eligible(player: *const player_store.CorePlayer, world: world_identity.Handle) bool {
    return player.state == .play and player.gamemode != .spectator and player.world.eql(world);
}

fn chunkCoordinate(value: f64) i32 {
    return @divFloor(geometry.blockCoord(value), 16);
}
