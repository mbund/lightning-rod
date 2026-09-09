const std = @import("std");
const lr = @import("lightning_rod");
pub const shared = @import("shared_roster.zig");

pub fn Publisher(comptime Tabs: type) type {
    return struct {
        const Self = @This();
        pub const id = "minecraft:tab_roster";
        pub const Configuration = struct { endpoint: *shared.Endpoint };
        pub const Dependencies = struct { players: *lr.players.Players, tabs: *Tabs };
        const Membership = struct { player: ?shared.Player = null, version: ?shared.Version = null, pending: bool = false };
        const Entry = struct { uuid: u128 = 0, revision: u64 = 0, present: bool = false };

        deps: Dependencies,
        config: Configuration,
        members: []Membership,
        snapshot: []Entry,
        requests: []u16,
        read: usize = 0,
        write: usize = 0,
        next_member: usize = 0,

        pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Self {
            if (config.endpoint.closed.load(.acquire) or deps.tabs.entries.len < config.endpoint.seen.len)
                return error.InvalidRosterConfiguration;
            const self = try allocator.create(Self);
            self.* = .{
                .deps = deps,
                .config = config,
                .members = try allocator.alloc(Membership, deps.players.records.len),
                .snapshot = try allocator.alloc(Entry, config.endpoint.seen.len),
                .requests = try allocator.alloc(u16, config.endpoint.commands.len),
            };
            @memset(self.members, .{});
            @memset(self.snapshot, .{});
            return self;
        }

        pub fn tick(self: *Self) lr.plugin_lifecycle.FatalError!void {
            const endpoint = self.config.endpoint;
            while (endpoint.reply()) |reply| {
                const member = &self.members[self.requests[self.read]];
                std.debug.assert(member.pending);
                if (reply) |update| {
                    member.player = update.player;
                    member.version = if (update.player != null) .{ .index = update.index, .revision = update.revision } else null;
                } else |err| switch (err) {
                    error.StaleVersion => {
                        member.player = null;
                        member.version = null;
                    },
                    error.AlreadyPresent, error.PlayerCapacity => {},
                    error.InvalidPlayer, error.Overflow => return error.WorkingMemoryExceeded,
                }
                member.pending = false;
                endpoint.ack();
                self.read = (self.read + 1) % self.requests.len;
            }
            while (endpoint.receive()) |update| {
                std.debug.assert(update.revision > self.snapshot[update.index].revision);
                const previous: ?u128 = if (self.snapshot[update.index].present) self.snapshot[update.index].uuid else null;
                self.snapshot[update.index] = .{ .revision = update.revision, .present = update.player != null, .uuid = if (update.player) |player| player.uuid else 0 };
                var previous_present = false;
                var newer = false;
                for (self.snapshot) |*entry| {
                    if (!entry.present) continue;
                    if (entry.revision < update.revision and
                        ((previous != null and entry.uuid == previous.?) or
                            (update.player != null and entry.uuid == update.player.?.uuid))) entry.present = false;
                    if (!entry.present) continue;
                    if (previous != null and entry.uuid == previous.?) previous_present = true;
                    if (update.player != null and entry.uuid == update.player.?.uuid and entry.revision > update.revision) newer = true;
                }
                if (previous != null and !previous_present) self.deps.tabs.remove(previous.?);
                if (!newer) if (update.player) |player| {
                    self.deps.tabs.put(.{ .uuid = player.uuid, .name = player.name[0..player.name_len], .gamemode = player.gamemode }) catch return error.WorkingMemoryExceeded;
                };
                endpoint.release();
            }
            var checked: usize = 0;
            while (checked < self.members.len) : ({
                checked += 1;
                self.next_member = (self.next_member + 1) % self.members.len;
            }) {
                const slot = self.next_member;
                const member = &self.members[slot];
                const player = &self.deps.players.records[slot];
                if (member.pending) continue;
                const desired: ?shared.Player = if (player.state == .play)
                    shared.Player.init(player.uuid, player.name_slice(), @intFromEnum(player.gamemode)) catch return error.WorkingMemoryExceeded
                else
                    null;
                const command: shared.Command = if (member.player) |known| command: {
                    if (desired == null or desired.?.uuid != known.uuid) break :command .{ .leave = member.version.? };
                    const next = desired.?;
                    if (known.gamemode == next.gamemode and known.name_len == next.name_len and std.mem.eql(u8, known.name[0..known.name_len], next.name[0..next.name_len])) continue;
                    break :command .{ .change = .{ .expected = member.version.?, .player = next } };
                } else if (desired) |next| .{ .join = next } else continue;
                endpoint.submit(command) catch |err| switch (err) {
                    error.Full => break,
                    error.Closed => return error.WorkingMemoryExceeded,
                };
                self.requests[self.write] = @intCast(slot);
                self.write = (self.write + 1) % self.requests.len;
                member.pending = true;
            }
            for (self.deps.players.activeSlots()) |target| self.deps.tabs.project(target);
        }

        pub const Owner = struct {
            pub const id = "skyblock:roster_service";
            pub const Dependencies = struct { publisher: *Self };
            pub const Configuration = struct { service: *shared.Service, maximum_checks_per_tick: usize = 64 };
            deps: @This().Dependencies,
            config: @This().Configuration,

            pub fn init(allocator: std.mem.Allocator, deps: @This().Dependencies, config: @This().Configuration) !*@This() {
                if (config.maximum_checks_per_tick == 0 or config.service.endpoints.len != 1 or deps.publisher.config.endpoint != &config.service.endpoints[0])
                    return error.InvalidRosterOwner;
                const self = try allocator.create(@This());
                self.* = .{ .deps = deps, .config = config };
                return self;
            }

            pub fn tick(self: *@This()) void {
                _ = self.config.service.processCommands(self.config.maximum_checks_per_tick);
                _ = self.config.service.process(self.config.maximum_checks_per_tick);
            }

            pub fn close(self: *@This(), closing: *lr.plugin_lifecycle.Closing) void {
                const done = closing.begin();
                self.config.service.retire(0) catch |err| {
                    std.log.err("event=roster_retirement_failed error={s}", .{@errorName(err)});
                    return;
                };
                done.finish();
            }
        };
    };
}

test "queued roster publisher drains late join replies and includes remote Core players" {
    const Tabs = struct {
        entries: [3]?shared.Player = @splat(null),
        pub fn put(self: *@This(), player: lr.protocol_values.PlayerInfo) !void {
            var free: ?usize = null;
            for (self.entries, 0..) |entry, index| {
                if (entry) |existing| {
                    if (existing.uuid != player.uuid) continue;
                    self.entries[index] = try shared.Player.init(player.uuid, player.name, @intCast(player.gamemode));
                    return;
                } else if (free == null) free = index;
            }
            self.entries[free orelse return error.Full] = try shared.Player.init(player.uuid, player.name, @intCast(player.gamemode));
        }
        pub fn remove(self: *@This(), uuid: u128) void {
            for (&self.entries) |*entry| if (entry.* != null and entry.*.?.uuid == uuid) {
                entry.* = null;
            };
        }
        pub fn project(_: *@This(), _: u16) void {}
        fn contains(self: *const @This(), uuid: u128) bool {
            for (self.entries) |entry| if (entry != null and entry.?.uuid == uuid) return true;
            return false;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var service = try shared.Service.init(std.testing.allocator, 3, 2, 1);
    defer service.deinit();
    try std.testing.expectEqual(service.memoryBytes(), try shared.Service.requiredMemory(3, 2, 1));
    const local = try service.activate(0);
    const remote = try service.activate(1);
    try remote.submit(.{ .join = try shared.Player.init(2, "bob", 0) });
    var records: [1]lr.players.CorePlayer align(64) = @splat(.{});
    records[0].state = .play;
    records[0].uuid = 1;
    records[0].name_len = 5;
    @memcpy(records[0].name[0..5], "alice");
    var players = lr.players.Players{ .deps = undefined, .initial_world = .{ .value = 1 }, .records = &records };
    var tabs = Tabs{};
    const Roster = Publisher(Tabs);
    const roster = try Roster.init(arena.allocator(), .{ .players = &players, .tabs = &tabs }, .{ .endpoint = local });
    try roster.tick();
    records[0].uuid = 3;
    @memcpy(records[0].name[0..5], "carol");
    for (0..12) |_| {
        _ = service.processCommands(4);
        _ = service.process(6);
        try roster.tick();
    }
    try std.testing.expect(!tabs.contains(1));
    try std.testing.expect(tabs.contains(2));
    try std.testing.expect(tabs.contains(3));
    try std.testing.expectEqual(@as(u128, 3), roster.members[0].player.?.uuid);
    for (service.entries) |entry| if (entry.player) |player| try std.testing.expect(player.uuid != 1);
    try std.testing.expect(remote.reply() != null);
    try std.testing.expect(remote.receive() != null);
    try service.remove(3);
    _ = try service.put(try shared.Player.init(4, "dave", 0));
    _ = try service.put(try shared.Player.init(3, "carol", 3));
    service.next = 2;
    try std.testing.expectEqual(@as(usize, 1), service.process(1));
    try roster.tick();
    for (tabs.entries) |entry| if (entry) |player| {
        if (player.uuid == 3) try std.testing.expectEqual(@as(u8, 3), player.gamemode);
    };
    try service.remove(3);
    service.next = 2;
    try std.testing.expectEqual(@as(usize, 1), service.process(1));
    try roster.tick();
    try std.testing.expect(!tabs.contains(3));
    service.next = 0;
    try std.testing.expectEqual(@as(usize, 1), service.process(1));
    try roster.tick();
    try std.testing.expect(!tabs.contains(3));
    try std.testing.expect(tabs.contains(4));
    try service.retire(0);
    try service.retire(1);

    var busy_service = try shared.Service.init(std.testing.allocator, 3, 1, 1);
    defer busy_service.deinit();
    const busy_endpoint = try busy_service.activate(0);
    var busy_records: [2]lr.players.CorePlayer align(64) = @splat(.{});
    for (&busy_records, 11..) |*record, uuid| {
        record.state = .play;
        record.uuid = uuid;
        record.name_len = 4;
        @memcpy(record.name[0..4], "test");
    }
    var busy_players = lr.players.Players{ .deps = undefined, .initial_world = .{ .value = 1 }, .records = &busy_records };
    var busy_tabs = Tabs{};
    const busy = try Roster.init(arena.allocator(), .{ .players = &busy_players, .tabs = &busy_tabs }, .{ .endpoint = busy_endpoint });
    for (0..4) |round| {
        busy_records[0].gamemode = if (round % 2 == 0) .survival else .creative;
        try busy.tick();
        _ = busy_service.processCommands(1);
        _ = busy_service.process(3);
    }
    try std.testing.expect(busy.members[1].player != null);
    try std.testing.expectEqual(@as(u128, 12), busy.members[1].player.?.uuid);
    try busy_service.retire(0);
}
