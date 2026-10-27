const std = @import("std");
const Channel = @import("global_chat.zig").Channel;
const Member = @import("catalog.zig").Member;
const sessions = @import("sessions");

fn delivery(channel: *Channel, players: []const Channel.Recipient, output: *[Channel.maximum_message]u8, recipients: []sessions.Handle, lagged: []sessions.Handle) !?Channel.Delivery {
    var deliveries: [1]Channel.Delivery = undefined;
    var cursor: Channel.Cursor = .{};
    const result = channel.nextBatch(&cursor, players, &deliveries, output, recipients, lagged);
    if (result.lagged.len != 0) return error.Lagged;
    return if (result.count == 0) null else deliveries[0];
}

fn next(channel: *Channel, uuid: u128, output: *[Channel.maximum_message]u8) !?[]const u8 {
    const handle = for (channel.readers) |reader| {
        if (reader.member) |member| if (member.uuid == uuid) break reader.connection;
    } else return null;
    var recipients: [1]sessions.Handle = undefined;
    var lagged: [1]sessions.Handle = undefined;
    const received = (try delivery(channel, &.{.{ .uuid = uuid, .handle = handle }}, output, &recipients, &lagged)) orelse return null;
    return received.text;
}

test "one message advances all eligible local recipients together" {
    var channel: Channel = .{ .io = std.testing.io };
    try join(&channel, Member.named(1, "alice"), false);
    try join(&channel, Member.named(2, "bob"), false);
    channel.post("shared");
    var output: [Channel.maximum_message]u8 = undefined;
    var recipients: [2]sessions.Handle = undefined;
    var lagged: [2]sessions.Handle = undefined;
    const players = [_]Channel.Recipient{ .{ .uuid = 1, .handle = connection(1) }, .{ .uuid = 2, .handle = connection(2) } };
    const received = (try delivery(&channel, &players, &output, &recipients, &lagged)).?;
    try std.testing.expectEqualStrings("shared", received.text);
    try std.testing.expectEqual(@as(usize, 2), received.recipients.len);
    try std.testing.expect(try delivery(&channel, &players, &output, &recipients, &lagged) == null);
}

fn connection(uuid: u128) sessions.Handle {
    return .{ .index = @intCast(uuid), .generation = 1 };
}

fn join(channel: *Channel, member: Member, announce: bool) !void {
    try channel.connect(member, connection(member.uuid));
    try std.testing.expect(channel.join(member.uuid, announce));
}

test "chat follows players across worlds without repeating join announcements" {
    var channel: Channel = .{ .io = std.testing.io };
    var buffer: [Channel.maximum_message]u8 = undefined;
    const alice = Member.named(1, "alice");
    const bob = Member.named(2, "bob");
    try join(&channel, alice, true);
    try std.testing.expectEqualStrings("alice joined the game", (try next(&channel, alice.uuid, &buffer)).?);
    try join(&channel, bob, true);
    try std.testing.expectEqualStrings("bob joined the game", (try next(&channel, alice.uuid, &buffer)).?);
    try std.testing.expectEqualStrings("bob joined the game", (try next(&channel, bob.uuid, &buffer)).?);
    channel.post("<alice> hello from an island");
    try join(&channel, bob, false);
    try std.testing.expectEqualStrings("<alice> hello from an island", (try next(&channel, bob.uuid, &buffer)).?);
    try std.testing.expectEqualStrings("<alice> hello from an island", (try next(&channel, alice.uuid, &buffer)).?);
    try join(&channel, alice, true);
    try std.testing.expect(try next(&channel, alice.uuid, &buffer) == null);
    channel.leave(bob.uuid, connection(bob.uuid));
    channel.leave(bob.uuid, connection(bob.uuid));
    try std.testing.expectEqualStrings("bob left the game", (try next(&channel, alice.uuid, &buffer)).?);
    try std.testing.expect(try next(&channel, alice.uuid, &buffer) == null);
    try join(&channel, bob, true);
    try std.testing.expectEqualStrings("bob joined the game", (try next(&channel, alice.uuid, &buffer)).?);
    try std.testing.expectEqualStrings("bob joined the game", (try next(&channel, bob.uuid, &buffer)).?);
}

test "slow chat readers cannot block other players or read overwritten messages" {
    var channel: Channel = .{ .io = std.testing.io };
    var buffer: [Channel.maximum_message]u8 = undefined;
    try join(&channel, Member.named(1, "slow"), false);
    try join(&channel, Member.named(2, "fast"), false);
    for (0..Channel.capacity + 1) |_| {
        channel.post("message");
        try std.testing.expectEqualStrings("message", (try next(&channel, 2, &buffer)).?);
    }
    try std.testing.expectError(error.Lagged, next(&channel, 1, &buffer));
    try std.testing.expect(try next(&channel, 2, &buffer) == null);
    try join(&channel, Member.named(3, "late"), false);
    try std.testing.expect(try next(&channel, 3, &buffer) == null);
    channel.leave(1, connection(1));
    try std.testing.expectEqualStrings("slow left the game", (try next(&channel, 2, &buffer)).?);
    try std.testing.expectEqualStrings("slow left the game", (try next(&channel, 3, &buffer)).?);
}

test "chat presence is bounded and reload attachment is silent" {
    var channel: Channel = .{ .io = std.testing.io };
    var buffer: [Channel.maximum_message]u8 = undefined;
    for (0..channel.readers.len) |index| try join(&channel, Member.named(index + 1, "player"), false);
    try std.testing.expect(try next(&channel, 1, &buffer) == null);
    try std.testing.expectError(error.PlayerLimit, channel.connect(Member.named(1000, "extra"), connection(1000)));
    channel.leave(1, connection(1));
    try join(&channel, Member.named(1000, "extra"), true);
    try std.testing.expectEqualStrings("extra joined the game", (try next(&channel, 1000, &buffer)).?);
}

test "disconnect wins against delayed simulation readiness and stale session closure" {
    var channel: Channel = .{ .io = std.testing.io };
    var buffer: [Channel.maximum_message]u8 = undefined;
    const alice = Member.named(1, "alice");
    try channel.connect(alice, connection(alice.uuid));
    channel.leave(alice.uuid, connection(alice.uuid));
    try std.testing.expect(!channel.join(alice.uuid, true));
    try std.testing.expectEqual(@as(u64, 0), channel.sequence);
    const reconnected: sessions.Handle = .{ .index = 1, .generation = 2 };
    try channel.connect(alice, reconnected);
    channel.leave(alice.uuid, connection(alice.uuid));
    try std.testing.expect(channel.join(alice.uuid, true));
    try std.testing.expectEqualStrings("alice joined the game", (try next(&channel, alice.uuid, &buffer)).?);
}

test "chat uses island local handles after transfer and keeps native presence identity" {
    var channel: Channel = .{ .io = std.testing.io };
    const alice = Member.named(1, "alice");
    const native: sessions.Handle = .{ .index = 7, .generation = 4 };
    try channel.connect(alice, native);
    try std.testing.expect(channel.join(alice.uuid, false));
    var output: [Channel.maximum_message]u8 = undefined;
    var recipients: [1]sessions.Handle = undefined;
    var lagged: [1]sessions.Handle = undefined;
    const handles = [_]sessions.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 2, .generation = 8 } };
    for (handles) |handle| {
        channel.post("hello");
        channel.leave(alice.uuid, handle);
        const players = [_]Channel.Recipient{.{ .uuid = alice.uuid, .handle = handle }};
        const received = (try delivery(&channel, &players, &output, &recipients, &lagged)).?;
        try std.testing.expectEqualStrings("hello", received.text);
        try std.testing.expectEqualSlices(sessions.Handle, &.{handle}, received.recipients);
        try std.testing.expect(try delivery(&channel, &players, &output, &recipients, &lagged) == null);
    }
    channel.leave(alice.uuid, native);
    try std.testing.expect(!channel.join(alice.uuid, false));
}

test "message batches preserve each reader cursor across bounded drains" {
    var channel: Channel = .{ .io = std.testing.io };
    try join(&channel, Member.named(1, "alice"), false);
    try join(&channel, Member.named(2, "bob"), false);
    channel.post("first");
    channel.post("second");
    channel.post("third");
    const players = [_]Channel.Recipient{ .{ .uuid = 1, .handle = connection(1) }, .{ .uuid = 2, .handle = connection(2) } };
    var deliveries: [2]Channel.Delivery = undefined;
    var bytes: [2 * Channel.maximum_message]u8 = undefined;
    var recipients: [4]sessions.Handle = undefined;
    var lagged: [2]sessions.Handle = undefined;
    var cursor: Channel.Cursor = .{};
    var result = channel.nextBatch(&cursor, players[0..1], &deliveries, &bytes, &recipients, &lagged);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("first", deliveries[0].text);
    try std.testing.expectEqualStrings("second", deliveries[1].text);
    result = channel.nextBatch(&cursor, &players, &deliveries, &bytes, &recipients, &lagged);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    for (deliveries) |message| try std.testing.expectEqualSlices(sessions.Handle, &.{connection(2)}, message.recipients);
    result = channel.nextBatch(&cursor, &players, &deliveries, &bytes, &recipients, &lagged);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqualStrings("third", deliveries[0].text);
    try std.testing.expectEqual(@as(usize, 2), deliveries[0].recipients.len);
    result = channel.nextBatch(&cursor, &players, &deliveries, &bytes, &recipients, &lagged);
    try std.testing.expectEqual(@as(usize, 0), result.count);
}

test "idle chat does not acquire its shared lock and roster changes catch up" {
    var channel: Channel = .{ .io = std.testing.io };
    try join(&channel, Member.named(1, "alice"), false);
    try join(&channel, Member.named(2, "bob"), false);
    var cursor: Channel.Cursor = .{};
    var deliveries: [1]Channel.Delivery = undefined;
    var bytes: [Channel.maximum_message]u8 = undefined;
    var targets: [2]sessions.Handle = undefined;
    var lagged: [2]sessions.Handle = undefined;
    const players = [_]Channel.Recipient{ .{ .uuid = 1, .handle = connection(1) }, .{ .uuid = 2, .handle = connection(2) } };
    _ = channel.nextBatch(&cursor, players[0..1], &deliveries, &bytes, &targets, &lagged);
    const NoWait = struct {
        fn wait(_: ?*anyopaque, _: *const u32, _: u32) void {
            @panic("idle polling attempted to acquire the shared lock");
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.futexWaitUncancelable = NoWait.wait;
    channel.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    channel.mutex.lockUncancelable(std.testing.io);
    for (0..1000) |_| {
        const batch = channel.nextBatch(&cursor, players[0..1], &deliveries, &bytes, &targets, &lagged);
        try std.testing.expectEqual(@as(usize, 0), batch.count);
    }
    channel.mutex.unlock(std.testing.io);
    channel.post("first");
    channel.post("second");
    _ = channel.nextBatch(&cursor, players[0..1], &deliveries, &bytes, &targets, &lagged);
    _ = channel.nextBatch(&cursor, players[0..1], &deliveries, &bytes, &targets, &lagged);
    var batch = channel.nextBatch(&cursor, &players, &deliveries, &bytes, &targets, &lagged);
    try std.testing.expectEqual(@as(usize, 1), batch.count);
    try std.testing.expectEqualStrings("first", deliveries[0].text);
    batch = channel.nextBatch(&cursor, &players, &deliveries, &bytes, &targets, &lagged);
    try std.testing.expectEqual(@as(usize, 1), batch.count);
    try std.testing.expectEqualStrings("second", deliveries[0].text);
    try std.testing.expectEqualSlices(sessions.Handle, &.{connection(2)}, deliveries[0].recipients);
    batch = channel.nextBatch(&cursor, &players, &deliveries, &bytes, &targets, &lagged);
    try std.testing.expectEqual(@as(usize, 0), batch.count);
}
