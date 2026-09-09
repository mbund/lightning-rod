const std = @import("std");
const lr = @import("lightning_rod");

pub const TabList = struct {
    pub const id = "minecraft:tab_list";
    pub const Configuration = struct { maximum_entries: ?usize = null };
    pub const Dependencies = struct {
        players: *lr.players.Players,
        events: *lr.player_lifecycle.Events,
        output: *lr.Packets,
        join: *@import("vanilla_join.zig").PlayJoin,
    };
    const Entry = struct {
        uuid: u128,
        revision: u64,
        name: [16]u8,
        name_len: u8,
        gamemode: i32,
    };
    const Sent = struct { uuid: u128, revision: u64 };
    const Viewer = struct { session: ?lr.players.Session = null, count: usize = 0 };

    deps: Dependencies,
    entries: []Entry,
    count: usize = 0,
    revision: u64 = 0,
    viewers: []Viewer,
    sent: []Sent,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*TabList {
        const capacity = config.maximum_entries orelse deps.players.records.len;
        if (capacity == 0) return error.InvalidTabCapacity;
        const sent_count = try std.math.mul(usize, capacity, deps.players.records.len);
        const self = try allocator.create(TabList);
        self.* = .{
            .deps = deps,
            .entries = try allocator.alloc(Entry, capacity),
            .viewers = try allocator.alloc(Viewer, deps.players.records.len),
            .sent = try allocator.alloc(Sent, sent_count),
        };
        @memset(self.viewers, .{});
        return self;
    }

    pub fn tick(self: *TabList) void {
        for (self.deps.events.play_started) |event| self.viewers[event.slot] = .{};
    }

    pub fn put(self: *TabList, player: lr.protocol_values.PlayerInfo) !void {
        if (player.name.len == 0 or player.name.len > 16 or player.gamemode < 0 or player.gamemode > 3)
            return error.InvalidTabPlayer;
        const index = lowerBound(Entry, self.entries[0..self.count], player.uuid);
        const exists = index < self.count and self.entries[index].uuid == player.uuid;
        if (exists) {
            const entry = &self.entries[index];
            if (entry.gamemode == player.gamemode and std.mem.eql(u8, entry.name[0..entry.name_len], player.name)) return;
        } else if (self.count == self.entries.len) return error.TabCapacity;
        const revision = try std.math.add(u64, self.revision, 1);
        if (!exists) {
            std.mem.copyBackwards(Entry, self.entries[index + 1 .. self.count + 1], self.entries[index..self.count]);
            self.count += 1;
        }
        self.entries[index] = .{ .uuid = player.uuid, .revision = revision, .name = @splat(0), .name_len = @intCast(player.name.len), .gamemode = player.gamemode };
        @memcpy(self.entries[index].name[0..player.name.len], player.name);
        self.revision = revision;
    }

    pub fn remove(self: *TabList, uuid: u128) void {
        const index = lowerBound(Entry, self.entries[0..self.count], uuid);
        if (index == self.count or self.entries[index].uuid != uuid) return;
        std.mem.copyForwards(Entry, self.entries[index .. self.count - 1], self.entries[index + 1 .. self.count]);
        self.count -= 1;
    }

    pub fn ensure(self: *TabList, target: u16, uuid: u128) bool {
        const viewer = self.getViewer(target) orelse return false;
        const index = lowerBound(Entry, self.entries[0..self.count], uuid);
        if (index == self.count or self.entries[index].uuid != uuid) return false;
        const entry = &self.entries[index];
        const sent = self.sent[target * self.entries.len ..][0..self.entries.len];
        var position = lowerBound(Sent, sent[0..viewer.count], uuid);
        var exists = position < viewer.count and sent[position].uuid == uuid;
        if (exists and sent[position].revision == entry.revision) return true;
        if (!exists and viewer.count == sent.len) {
            if (!self.removeStale(target, viewer, sent)) return false;
            position = lowerBound(Sent, sent[0..viewer.count], uuid);
            exists = position < viewer.count and sent[position].uuid == uuid;
        }
        if (!self.deps.output.tabAdd(target, .{ .uuid = uuid, .name = entry.name[0..entry.name_len], .gamemode = entry.gamemode })) return false;
        if (!exists) {
            std.debug.assert(viewer.count < sent.len);
            std.mem.copyBackwards(Sent, sent[position + 1 .. viewer.count + 1], sent[position..viewer.count]);
            viewer.count += 1;
        }
        sent[position] = .{ .uuid = uuid, .revision = entry.revision };
        return true;
    }

    pub fn project(self: *TabList, target: u16) void {
        const viewer = self.getViewer(target) orelse return;
        const sent = self.sent[target * self.entries.len ..][0..self.entries.len];
        if (!self.removeStale(target, viewer, sent)) return;
        for (self.entries[0..self.count]) |entry| if (!self.ensure(target, entry.uuid)) return;
    }

    fn getViewer(self: *TabList, target: u16) ?*Viewer {
        if (target >= self.viewers.len or self.deps.players.records[target].state != .play) return null;
        if (!self.deps.join.presentationReady(target)) return null;
        const session = self.deps.players.session(target) orelse return null;
        const value = &self.viewers[target];
        if (value.session == null or !value.session.?.eql(session)) value.* = .{ .session = session };
        return value;
    }

    fn removeStale(self: *TabList, target: u16, viewer_value: *Viewer, sent: []Sent) bool {
        var index: usize = 0;
        while (index < viewer_value.count) {
            const desired = lowerBound(Entry, self.entries[0..self.count], sent[index].uuid);
            if (desired < self.count and self.entries[desired].uuid == sent[index].uuid) {
                index += 1;
                continue;
            }
            if (!self.deps.output.tabRemove(target, sent[index].uuid)) return false;
            std.mem.copyForwards(Sent, sent[index .. viewer_value.count - 1], sent[index + 1 .. viewer_value.count]);
            viewer_value.count -= 1;
        }
        return true;
    }
};

fn lowerBound(comptime T: type, values: []const T, uuid: u128) usize {
    var low: usize = 0;
    var high = values.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (values[middle].uuid < uuid) low = middle + 1 else high = middle;
    }
    return low;
}

pub const LocalRoster = struct {
    pub const id = "minecraft:tab_roster";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *lr.players.Players,
        tabs: *TabList,
    };
    deps: Dependencies,
    previous: []?u128,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LocalRoster {
        if (deps.tabs.entries.len < deps.players.records.len) return error.InvalidTabCapacity;
        const self = try allocator.create(LocalRoster);
        self.* = .{ .deps = deps, .previous = try allocator.alloc(?u128, deps.players.records.len) };
        @memset(self.previous, null);
        return self;
    }

    pub fn tick(self: *LocalRoster) lr.plugin_lifecycle.FatalError!void {
        for (self.previous, self.deps.players.records) |*previous, player| {
            if (previous.*) |uuid| {
                if (player.state == .play and player.uuid == uuid) continue;
                self.deps.tabs.remove(uuid);
                previous.* = null;
            }
        }
        for (self.deps.players.records, 0..) |*player, slot| {
            if (player.state != .play) continue;
            self.deps.tabs.put(.{ .uuid = player.uuid, .name = player.name_slice(), .gamemode = @intFromEnum(player.gamemode) }) catch return error.WorkingMemoryExceeded;
            self.previous[slot] = player.uuid;
        }
        for (self.deps.players.activeSlots()) |target| self.deps.tabs.project(target);
    }
};

test "tab reconciliation retains rejected removals and handles UUID and session reuse" {
    const Admission = struct {
        blocked: ?u16 = null,
        accepted: [2]usize = @splat(0),
        bytes: [2][128]u8 = undefined,
        lengths: [2]usize = @splat(0),
        fn send(raw: *anyopaque, target: lr.players.Session, encoder: lr.sessions.PacketEncoder, _: lr.sessions.DeliveryClass, _: lr.sessions.DeliveryPolicy) lr.sessions.PacketAdmission {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.blocked == target.slot) return .backpressured;
            const encoded = encoder.encode(encoder.context, .{ .value = 772 }, &self.bytes[target.slot]) orelse return .wrong_protocol;
            self.lengths[target.slot] = encoded.payload.len;
            self.accepted[target.slot] += 1;
            return .accepted;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var records: [2]lr.players.CorePlayer align(64) = @splat(.{});
    for (&records) |*record| {
        record.state = .play;
        record.presentation_ready = true;
    }
    var generations = [_]u64{ 1, 1 };
    var players: lr.players.Players = .{ .deps = undefined, .initial_world = .{ .value = 1 }, .records = &records, .session_generations = &generations };
    var admission = Admission{};
    var vtable: lr.sessions.Runtime.VTable = undefined;
    vtable.send_one = Admission.send;
    var sessions = lr.sessions.Sessions.init(772);
    sessions.runtime = .{ .context = &admission, .vtable = &vtable };
    var output: lr.Packets = undefined;
    output.deps.players = &players;
    output.deps.sessions = &sessions;
    var events: lr.player_lifecycle.Events = undefined;
    events.play_started = &.{};
    var ready = [_]bool{ true, true };
    var join: @import("vanilla_join.zig").PlayJoin = undefined;
    join.ready = &ready;
    const tabs = try TabList.init(arena.allocator(), .{ .players = &players, .events = &events, .output = &output, .join = &join }, .{ .maximum_entries = 1 });
    try tabs.put(.{ .uuid = 10, .name = "alice", .gamemode = 0 });
    tabs.project(0);
    ready[1] = false;
    tabs.project(1);
    try std.testing.expectEqual(@as(usize, 0), admission.accepted[1]);
    ready[1] = true;
    tabs.project(1);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1 }, &admission.accepted);
    tabs.project(0);
    try std.testing.expectEqual(@as(usize, 1), admission.accepted[0]);
    try std.testing.expectError(error.TabCapacity, tabs.put(.{ .uuid = 20, .name = "bob", .gamemode = 0 }));
    admission.blocked = 0;
    tabs.remove(10);
    try tabs.put(.{ .uuid = 20, .name = "bob", .gamemode = 3 });
    tabs.project(0);
    tabs.project(1);
    try std.testing.expectEqualSlices(usize, &.{ 1, 3 }, &admission.accepted);
    try std.testing.expectEqual(@as(u128, 10), tabs.sent[0].uuid);
    try std.testing.expectEqual(@as(u128, 20), tabs.sent[1].uuid);
    admission.blocked = null;
    tabs.project(0);
    try std.testing.expectEqual(@as(usize, 3), admission.accepted[0]);
    try std.testing.expectEqualSlices(u8, admission.bytes[0][0..admission.lengths[0]], admission.bytes[1][0..admission.lengths[1]]);
    tabs.remove(20);
    try tabs.put(.{ .uuid = 20, .name = "bob", .gamemode = 1 });
    tabs.project(0);
    try std.testing.expectEqual(@as(usize, 4), admission.accepted[0]);
    generations[0] += 1;
    tabs.project(0);
    try std.testing.expectEqual(@as(usize, 5), admission.accepted[0]);
    events.play_started = &.{.{ .slot = 0, .connection = .{ .index = 0, .generation = 2 }, .reason = .reconfigured }};
    tabs.tick();
    tabs.project(0);
    try std.testing.expectEqual(@as(usize, 6), admission.accepted[0]);
    tabs.remove(20);
    tabs.project(0);
    try std.testing.expectEqual(@as(usize, 0), tabs.viewers[0].count);
}
