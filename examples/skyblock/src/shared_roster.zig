const std = @import("std");

pub const Player = struct {
    uuid: u128,
    name: [16]u8 = @splat(0),
    name_len: u8,
    gamemode: u8,

    pub fn init(uuid: u128, name: []const u8, gamemode: u8) !Player {
        if (name.len == 0 or name.len > 16 or gamemode > 3) return error.InvalidPlayer;
        var value = Player{ .uuid = uuid, .name_len = @intCast(name.len), .gamemode = gamemode };
        @memcpy(value.name[0..name.len], name);
        return value;
    }
};

pub const Update = struct { index: u32, revision: u64, player: ?Player };
pub const Version = struct { index: u32, revision: u64 };
pub const Command = union(enum) {
    join: Player,
    /// A successful change also moves ownership to the submitting Core.
    change: struct { expected: Version, player: Player },
    leave: Version,
};
pub const Failure = error{ InvalidPlayer, PlayerCapacity, AlreadyPresent, StaleVersion, Overflow };
const CommandState = enum(u8) { free, pending, complete };
const CommandSlot = struct {
    state: std.atomic.Value(CommandState) = .init(.free),
    command: Command = undefined,
    result: Failure!Update = undefined,
};
const Entry = struct { revision: u64 = 0, player: ?Player = null, owner: ?usize = null };
const Slot = struct { ready: std.atomic.Value(bool) = .init(false), update: Update = undefined };

/// One service producer and one Core consumer. Updates replace indexed roster
/// state, not wire packets; consumers reconcile UUID membership before encoding.
pub const Endpoint = struct {
    slots: []Slot,
    seen: []u64,
    write: usize = 0,
    read: usize = 0,
    closed: std.atomic.Value(bool) = .init(true),
    active_position: usize = 0,
    commands: []CommandSlot,
    command_write: usize = 0,
    command_process: usize = 0,
    command_read: usize = 0,

    pub fn submit(self: *Endpoint, command: Command) error{ Closed, Full }!void {
        if (self.closed.load(.acquire)) return error.Closed;
        const slot = &self.commands[self.command_write];
        if (slot.state.load(.acquire) != .free) return error.Full;
        slot.command = command;
        slot.state.store(.pending, .release);
        self.command_write = (self.command_write + 1) % self.commands.len;
    }

    pub fn reply(self: *Endpoint) ?Failure!Update {
        const slot = &self.commands[self.command_read];
        return if (slot.state.load(.acquire) == .complete) slot.result else null;
    }

    pub fn ack(self: *Endpoint) void {
        const slot = &self.commands[self.command_read];
        std.debug.assert(slot.state.load(.acquire) == .complete);
        slot.state.store(.free, .release);
        self.command_read = (self.command_read + 1) % self.commands.len;
    }

    pub fn receive(self: *Endpoint) ?*const Update {
        const slot = &self.slots[self.read];
        return if (slot.ready.load(.acquire)) &slot.update else null;
    }

    pub fn release(self: *Endpoint) void {
        const slot = &self.slots[self.read];
        std.debug.assert(slot.ready.load(.acquire));
        slot.ready.store(false, .release);
        self.read = (self.read + 1) % self.slots.len;
    }

    pub fn retired(self: *const Endpoint) bool {
        if (!self.closed.load(.acquire)) return false;
        for (self.commands) |*slot| if (slot.state.load(.acquire) != .free) return false;
        for (self.slots) |*slot| if (slot.ready.load(.acquire)) return false;
        return true;
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    endpoints: []Endpoint,
    slots: []Slot,
    commands: []CommandSlot,
    revisions: []u64,
    active: []usize,
    active_count: usize = 0,
    next: usize = 0,
    next_command: usize = 0,
    revision: u64 = 0,

    pub fn requiredMemory(maximum_players: u32, maximum_cores: usize, updates_per_core: usize) error{InvalidCapacity}!usize {
        if (maximum_players == 0 or maximum_cores == 0 or updates_per_core == 0) return error.InvalidCapacity;
        const revisions = std.math.mul(usize, maximum_players, maximum_cores) catch return error.InvalidCapacity;
        const slots = std.math.mul(usize, updates_per_core, maximum_cores) catch return error.InvalidCapacity;
        const counts = [_]usize{ maximum_players, maximum_cores, slots, slots, revisions, maximum_cores };
        var bytes: usize = @sizeOf(Service);
        inline for (.{ Entry, Endpoint, Slot, CommandSlot, u64, usize }, counts) |T, count| {
            const size = std.math.mul(usize, @sizeOf(T), count) catch return error.InvalidCapacity;
            bytes = std.math.add(usize, bytes, size) catch return error.InvalidCapacity;
        }
        return bytes;
    }

    pub fn init(allocator: std.mem.Allocator, maximum_players: u32, maximum_cores: usize, updates_per_core: usize) !Service {
        _ = try requiredMemory(maximum_players, maximum_cores, updates_per_core);
        const revision_count = try std.math.mul(usize, maximum_players, maximum_cores);
        const slot_count = try std.math.mul(usize, updates_per_core, maximum_cores);
        const entries = try allocator.alloc(Entry, maximum_players);
        errdefer allocator.free(entries);
        const endpoints = try allocator.alloc(Endpoint, maximum_cores);
        errdefer allocator.free(endpoints);
        const slots = try allocator.alloc(Slot, slot_count);
        errdefer allocator.free(slots);
        const revisions = try allocator.alloc(u64, revision_count);
        errdefer allocator.free(revisions);
        const commands = try allocator.alloc(CommandSlot, slot_count);
        errdefer allocator.free(commands);
        const active = try allocator.alloc(usize, maximum_cores);
        @memset(entries, .{});
        for (slots) |*slot| slot.* = .{};
        for (commands) |*slot| slot.* = .{};
        @memset(revisions, 0);
        for (endpoints, 0..) |*endpoint, index| endpoint.* = .{
            .slots = slots[index * updates_per_core ..][0..updates_per_core],
            .seen = revisions[index * maximum_players ..][0..maximum_players],
            .commands = commands[index * updates_per_core ..][0..updates_per_core],
        };
        return .{ .allocator = allocator, .entries = entries, .endpoints = endpoints, .slots = slots, .commands = commands, .revisions = revisions, .active = active };
    }

    pub fn deinit(self: *Service) void {
        self.allocator.free(self.active);
        self.allocator.free(self.commands);
        self.allocator.free(self.revisions);
        self.allocator.free(self.slots);
        self.allocator.free(self.endpoints);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Service) usize {
        return @sizeOf(Service) + self.entries.len * @sizeOf(Entry) + self.endpoints.len * @sizeOf(Endpoint) + self.slots.len * @sizeOf(Slot) + self.commands.len * @sizeOf(CommandSlot) + self.revisions.len * @sizeOf(u64) + self.active.len * @sizeOf(usize);
    }

    /// Owner-only; the previous Core must have stopped and drained this endpoint.
    /// A new consumer starts with an empty indexed view.
    pub fn activate(self: *Service, index: usize) !*Endpoint {
        if (index >= self.endpoints.len) return error.InvalidEndpoint;
        const endpoint = &self.endpoints[index];
        if (!endpoint.retired()) return error.Busy;
        @memset(endpoint.seen, 0);
        endpoint.active_position = self.active_count;
        self.active[self.active_count] = index;
        self.active_count += 1;
        endpoint.closed.store(false, .release);
        return endpoint;
    }

    /// The producer must be stopped and all command replies acknowledged first.
    pub fn deactivate(self: *Service, index: usize) !void {
        if (index >= self.endpoints.len) return error.InvalidEndpoint;
        const endpoint = &self.endpoints[index];
        if (endpoint.closed.load(.acquire)) return;
        for (endpoint.commands) |*slot| if (slot.state.load(.acquire) != .free) return error.Busy;
        for (self.entries) |entry| if (entry.owner == index) return error.Busy;
        endpoint.closed.store(true, .release);
        self.active_count -= 1;
        const moved = self.active[self.active_count];
        self.active[endpoint.active_position] = moved;
        self.endpoints[moved].active_position = endpoint.active_position;
        self.next = if (self.active_count == 0) 0 else self.next % (self.active_count * self.entries.len);
        self.next_command = if (self.active_count == 0) 0 else self.next_command % self.active_count;
    }

    /// Coordinator-only, after the Core has stopped using both queue ends.
    /// Pending membership requests are canceled; accepted memberships owned by
    /// this Core are removed. A newer Core's transferred membership is retained.
    pub fn retire(self: *Service, index: usize) !void {
        if (index >= self.endpoints.len) return error.InvalidEndpoint;
        var removed: u64 = 0;
        for (self.entries) |entry| if (entry.owner == index) {
            removed += 1;
        };
        const final_revision = try std.math.add(u64, self.revision, removed);
        for (self.entries) |*entry| {
            if (entry.owner != index) continue;
            self.revision += 1;
            entry.* = .{ .revision = self.revision };
        }
        std.debug.assert(self.revision == final_revision);
        const endpoint = &self.endpoints[index];
        for (endpoint.commands) |*slot| slot.state.store(.free, .release);
        endpoint.command_write = 0;
        endpoint.command_process = 0;
        endpoint.command_read = 0;
        for (endpoint.slots) |*slot| slot.ready.store(false, .release);
        endpoint.write = 0;
        endpoint.read = 0;
        try self.deactivate(index);
    }

    /// Only the service owner mutates canonical membership.
    pub fn put(self: *Service, player: Player) !u32 {
        if (player.name_len == 0 or player.name_len > player.name.len or player.gamemode > 3) return error.InvalidPlayer;
        var free: ?usize = null;
        for (self.entries, 0..) |*entry, index| {
            if (entry.player) |existing| {
                if (existing.uuid != player.uuid) continue;
                if (existing.gamemode == player.gamemode and existing.name_len == player.name_len and std.mem.eql(u8, existing.name[0..existing.name_len], player.name[0..player.name_len])) return @intCast(index);
                self.revision = try std.math.add(u64, self.revision, 1);
                entry.revision = self.revision;
                entry.player = player;
                return @intCast(index);
            } else if (free == null) free = index;
        }
        const index = free orelse return error.PlayerCapacity;
        const entry = &self.entries[index];
        self.revision = try std.math.add(u64, self.revision, 1);
        entry.revision = self.revision;
        entry.player = player;
        return @intCast(index);
    }

    pub fn remove(self: *Service, uuid: u128) !void {
        for (self.entries) |*entry| {
            const player = entry.player orelse continue;
            if (player.uuid != uuid) continue;
            self.revision = try std.math.add(u64, self.revision, 1);
            entry.revision = self.revision;
            entry.player = null;
            entry.owner = null;
            return;
        }
    }

    pub fn processCommands(self: *Service, maximum_checks: usize) usize {
        if (self.active_count == 0) return 0;
        var processed: usize = 0;
        for (0..maximum_checks) |_| {
            const endpoint_index = self.active[self.next_command];
            const endpoint = &self.endpoints[endpoint_index];
            self.next_command = (self.next_command + 1) % self.active_count;
            const slot = &endpoint.commands[endpoint.command_process];
            if (slot.state.load(.acquire) != .pending) continue;
            slot.result = result: {
                const index: usize = switch (slot.command) {
                    .join => |player| join: {
                        for (self.entries) |entry| {
                            if (entry.player) |existing| if (existing.uuid == player.uuid) break :result error.AlreadyPresent;
                        }
                        const index = self.put(player) catch |err| break :result err;
                        self.entries[index].owner = endpoint_index;
                        break :join index;
                    },
                    .change, .leave => update: {
                        const expected = switch (slot.command) {
                            .change => |change| change.expected,
                            .leave => |version| version,
                            .join => unreachable,
                        };
                        if (expected.index >= self.entries.len) break :result error.StaleVersion;
                        const entry = &self.entries[expected.index];
                        const existing = entry.player orelse break :result error.StaleVersion;
                        if (entry.revision != expected.revision) break :result error.StaleVersion;
                        const replacement: ?Player = switch (slot.command) {
                            .change => |change| replacement: {
                                const player = change.player;
                                if (player.uuid != existing.uuid or player.name_len == 0 or player.name_len > player.name.len or player.gamemode > 3) break :result error.InvalidPlayer;
                                break :replacement player;
                            },
                            .leave => null,
                            .join => unreachable,
                        };
                        const revision = std.math.add(u64, self.revision, 1) catch break :result error.Overflow;
                        self.revision = revision;
                        entry.* = .{ .revision = revision, .player = replacement, .owner = if (replacement != null) endpoint_index else null };
                        break :update expected.index;
                    },
                };
                const entry = self.entries[index];
                break :result Update{ .index = @intCast(index), .revision = entry.revision, .player = entry.player };
            };
            slot.state.store(.complete, .release);
            endpoint.command_process = (endpoint.command_process + 1) % endpoint.commands.len;
            processed += 1;
        }
        return processed;
    }

    pub fn process(self: *Service, maximum_checks: usize) usize {
        if (self.active_count == 0) return 0;
        const checks = self.active_count * self.entries.len;
        var published: usize = 0;
        for (0..@min(maximum_checks, checks)) |_| {
            const index = self.next % self.entries.len;
            const endpoint = &self.endpoints[self.active[self.next / self.entries.len]];
            self.next = (self.next + 1) % checks;
            const entry = &self.entries[index];
            if (endpoint.seen[index] == entry.revision) continue;
            const slot = &endpoint.slots[endpoint.write];
            if (slot.ready.load(.acquire)) continue;
            slot.update = .{ .index = @intCast(index), .revision = entry.revision, .player = entry.player };
            slot.ready.store(true, .release);
            endpoint.write = (endpoint.write + 1) % endpoint.slots.len;
            endpoint.seen[index] = entry.revision;
            published += 1;
        }
        return published;
    }
};

test "slow roster consumers catch up without blocking other Cores or losing removals" {
    var service = try Service.init(std.testing.allocator, 2, 2, 1);
    defer service.deinit();
    _ = try service.activate(0);
    _ = try service.activate(1);
    const alice = try Player.init(1, "alice", 0);
    const index = try service.put(alice);
    try std.testing.expectEqual(@as(usize, 2), service.process(4));
    service.endpoints[1].release();
    _ = try service.put(try Player.init(1, "alice", 3));
    try std.testing.expectEqual(@as(usize, 1), service.process(4));
    try std.testing.expectEqual(@as(u8, 3), service.endpoints[1].receive().?.player.?.gamemode);
    service.endpoints[1].release();
    try service.remove(1);
    try std.testing.expectEqual(@as(usize, 1), service.process(4));
    try std.testing.expectEqual(@as(?Player, null), service.endpoints[1].receive().?.player);
    service.endpoints[1].release();
    try std.testing.expectEqual(@as(u8, 0), service.endpoints[0].receive().?.player.?.gamemode);
    service.endpoints[0].release();
    try std.testing.expectEqual(@as(usize, 1), service.process(4));
    try std.testing.expectEqual(index, service.endpoints[0].receive().?.index);
    try std.testing.expectEqual(@as(?Player, null), service.endpoints[0].receive().?.player);
    service.endpoints[0].release();
    _ = try service.put(alice);
    _ = try service.put(try Player.init(2, "bob", 0));
    try std.testing.expectError(error.PlayerCapacity, service.put(try Player.init(3, "carol", 0)));
    try std.testing.expectEqual(@as(usize, 1), service.process(1));
}

test "roster retirement drains old updates and reactivation publishes current state" {
    var service = try Service.init(std.testing.allocator, 1, 3, 2);
    defer service.deinit();
    _ = try service.put(try Player.init(1, "alice", 0));
    try std.testing.expectEqual(@as(usize, 0), service.process(100));
    const endpoint = try service.activate(2);
    try std.testing.expectError(error.Busy, service.activate(2));
    try std.testing.expectEqual(@as(usize, 1), service.process(1));
    try service.deactivate(2);
    try service.deactivate(2);
    try std.testing.expectError(error.Busy, service.activate(2));
    _ = try service.put(try Player.init(1, "alice", 3));
    try std.testing.expectEqual(@as(usize, 0), service.process(100));
    try std.testing.expectEqual(@as(u8, 0), endpoint.receive().?.player.?.gamemode);
    endpoint.release();
    try std.testing.expect(endpoint.retired());
    _ = try service.activate(2);
    try std.testing.expectEqual(@as(usize, 1), service.process(1));
    try std.testing.expectEqual(@as(u8, 3), endpoint.receive().?.player.?.gamemode);
    endpoint.release();
    const other = try service.activate(0);
    try std.testing.expectEqual(@as(usize, 1), service.process(2));
    other.release();
    try service.deactivate(2);
    try std.testing.expectEqual(@as(usize, 1), service.active_count);
    try service.remove(1);
    try std.testing.expectEqual(@as(usize, 1), service.process(1));
    try std.testing.expectEqual(@as(?Player, null), other.receive().?.player);
    other.release();
    try std.testing.expectEqual(@as(?*const Update, null), endpoint.receive());
    try std.testing.expectError(error.InvalidEndpoint, service.activate(3));
    try std.testing.expectError(error.InvalidEndpoint, service.deactivate(3));
}

test "queued roster changes acknowledge capacity and reject stale cross-Core removals" {
    var service = try Service.init(std.testing.allocator, 1, 2, 1);
    defer service.deinit();
    const first = try service.activate(0);
    const second = try service.activate(1);
    const alice = try Player.init(1, "alice", 0);
    try first.submit(.{ .join = alice });
    try std.testing.expectError(error.Full, first.submit(.{ .join = alice }));
    try std.testing.expectEqual(@as(usize, 0), service.processCommands(0));
    try std.testing.expect(first.reply() == null);
    try std.testing.expectError(error.Busy, service.deactivate(0));
    try std.testing.expectEqual(@as(usize, 1), service.processCommands(2));
    const joined = try first.reply().?;
    const old = Version{ .index = joined.index, .revision = joined.revision };
    try std.testing.expectError(error.Busy, service.deactivate(0));
    try std.testing.expectError(error.Full, first.submit(.{ .leave = old }));
    first.ack();

    try second.submit(.{ .change = .{ .expected = old, .player = try Player.init(1, "alice", 3) } });
    try std.testing.expectEqual(@as(usize, 1), service.processCommands(2));
    const changed = try second.reply().?;
    second.ack();
    try first.submit(.{ .leave = old });
    try second.submit(.{ .join = try Player.init(2, "bob", 0) });
    try std.testing.expectEqual(@as(usize, 2), service.processCommands(2));
    try std.testing.expectError(error.StaleVersion, first.reply().?);
    try std.testing.expectError(error.PlayerCapacity, second.reply().?);
    first.ack();
    second.ack();
    try std.testing.expectEqual(@as(u8, 3), service.entries[joined.index].player.?.gamemode);

    try second.submit(.{ .leave = .{ .index = changed.index, .revision = changed.revision } });
    try std.testing.expectEqual(@as(usize, 1), service.processCommands(2));
    try std.testing.expectEqual(@as(?Player, null), (try second.reply().?).player);
    second.ack();
    try first.submit(.{ .join = alice });
    try std.testing.expectEqual(@as(usize, 1), service.processCommands(2));
    const rejoined = try first.reply().?;
    first.ack();
    try std.testing.expect(rejoined.revision > changed.revision);
    try second.submit(.{ .leave = .{ .index = changed.index, .revision = changed.revision } });
    try std.testing.expectEqual(@as(usize, 1), service.processCommands(2));
    try std.testing.expectError(error.StaleVersion, second.reply().?);
    second.ack();
    try service.deactivate(1);
    try std.testing.expectError(error.Closed, second.submit(.{ .join = alice }));
    try std.testing.expectEqual(@as(u128, 1), service.entries[joined.index].player.?.uuid);
}

test "retiring roster owners preserve transferred memberships and cancel unobserved requests" {
    var service = try Service.init(std.testing.allocator, 3, 2, 3);
    defer service.deinit();
    const first = try service.activate(0);
    const second = try service.activate(1);
    try first.submit(.{ .join = try Player.init(1, "alice", 0) });
    try first.submit(.{ .join = try Player.init(2, "bob", 0) });
    try std.testing.expectEqual(@as(usize, 2), service.processCommands(4));
    const alice = try first.reply().?;
    first.ack();
    try std.testing.expectError(error.Busy, service.deactivate(0));
    const bob = try first.reply().?;
    first.ack();
    try std.testing.expectError(error.Busy, service.deactivate(0));
    _ = service.process(6);
    while (second.receive() != null) second.release();
    try second.submit(.{ .change = .{
        .expected = .{ .index = alice.index, .revision = alice.revision },
        .player = try Player.init(1, "alice", 3),
    } });
    try std.testing.expectEqual(@as(usize, 1), service.processCommands(2));
    const moved = try second.reply().?;
    second.ack();
    try first.submit(.{ .leave = .{ .index = alice.index, .revision = alice.revision } });
    try first.submit(.{ .join = try Player.init(3, "carol", 0) });
    try service.retire(0);
    try std.testing.expect(first.retired());
    try std.testing.expect(first.reply() == null);
    try std.testing.expectEqual(@as(usize, 1), service.active_count);
    try std.testing.expect(service.entries[moved.index].player != null);
    try std.testing.expectEqual(@as(u128, 1), service.entries[moved.index].player.?.uuid);
    try std.testing.expectEqual(@as(?usize, 1), service.entries[moved.index].owner);
    try std.testing.expect(service.entries[bob.index].player == null);
    for (service.entries) |entry| if (entry.player) |player| try std.testing.expect(player.uuid != 3);
    try std.testing.expectEqual(@as(usize, 2), service.process(3));
    var removed_bob = false;
    while (second.receive()) |update| {
        if (update.index == bob.index) {
            try std.testing.expect(update.player == null);
            removed_bob = true;
        }
        second.release();
    }
    try std.testing.expect(removed_bob);
    _ = try service.activate(0);
    try first.submit(.{ .join = try Player.init(4, "dave", 0) });
    try std.testing.expectEqual(@as(usize, 1), service.processCommands(2));
    const dave = try first.reply().?;
    first.ack();
    const revision = service.revision;
    service.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, service.retire(0));
    try std.testing.expect(!first.closed.load(.acquire));
    try std.testing.expectEqual(@as(u128, 4), service.entries[dave.index].player.?.uuid);
    service.revision = revision;
    try service.retire(0);
    try service.retire(1);
    try std.testing.expectEqual(@as(usize, 0), service.active_count);
}

test "roster requests and publications cross independent Core threads" {
    const Worker = struct {
        endpoint: *Endpoint,
        uuid: u128,
        stop: *std.atomic.Value(bool),
        done: std.atomic.Value(bool) = .init(false),
        valid: bool = true,
        completed: usize = 0,

        fn run(self: *@This()) void {
            var expected: Version = undefined;
            var pending = false;
            var seen: [2]u64 = @splat(0);
            while (!self.stop.load(.acquire)) {
                while (self.endpoint.receive()) |update| {
                    self.valid = self.valid and update.index < seen.len;
                    if (update.index < seen.len) {
                        self.valid = self.valid and update.revision > seen[update.index];
                        seen[update.index] = update.revision;
                    }
                    self.endpoint.release();
                }
                if (pending) {
                    if (self.endpoint.reply()) |result| {
                        if (result) |update| {
                            expected = .{ .index = update.index, .revision = update.revision };
                            if (update.player) |player| self.valid = self.valid and player.uuid == self.uuid;
                        } else |_| self.valid = false;
                        self.endpoint.ack();
                        self.completed += 1;
                        pending = false;
                    }
                }
                if (self.completed == 300) {
                    self.done.store(true, .release);
                    return;
                }
                if (!pending) {
                    const command: Command = switch (self.completed % 3) {
                        0 => .{ .join = Player.init(self.uuid, "player", 0) catch unreachable },
                        1 => .{ .change = .{ .expected = expected, .player = Player.init(self.uuid, "player", 3) catch unreachable } },
                        2 => .{ .leave = expected },
                        else => unreachable,
                    };
                    if (self.endpoint.submit(command)) {
                        pending = true;
                    } else |_| self.valid = false;
                }
                std.Thread.yield() catch {};
            }
        }
    };
    var service = try Service.init(std.testing.allocator, 2, 2, 2);
    defer service.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var workers = [_]Worker{
        .{ .endpoint = try service.activate(0), .uuid = 1, .stop = &stop },
        .{ .endpoint = try service.activate(1), .uuid = 2, .stop = &stop },
    };
    var threads: [2]?std.Thread = @splat(null);
    defer {
        stop.store(true, .release);
        for (threads) |thread| if (thread) |value| value.join();
    }
    for (&workers, &threads) |*worker, *thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    const started = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
    while (std.Io.Clock.awake.now(std.testing.io).toNanoseconds() - started < 5 * std.time.ns_per_s) {
        _ = service.processCommands(2);
        _ = service.process(4);
        if (workers[0].done.load(.acquire) and workers[1].done.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    stop.store(true, .release);
    for (&threads) |*thread| {
        thread.*.?.join();
        thread.* = null;
    }
    for (&workers, 0..) |*worker, index| {
        try std.testing.expect(worker.done.load(.acquire));
        try std.testing.expect(worker.valid);
        try std.testing.expectEqual(@as(usize, 300), worker.completed);
        try service.deactivate(index);
        while (worker.endpoint.receive() != null) worker.endpoint.release();
        try std.testing.expect(worker.endpoint.retired());
    }
    for (service.entries) |entry| try std.testing.expect(entry.player == null);
}
