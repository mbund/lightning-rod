const std = @import("std");
const lightning_rod = @import("lightning_rod");
const catalog = @import("catalog.zig");
const Router = @import("router.zig").Router;

fn join(directory: *catalog.Catalog, uuid: u128, name: []const u8, index: usize) !catalog.Member {
    const member = catalog.Member.named(uuid, name);
    try directory.arrive(index, member, .{ .index = @intCast(uuid), .generation = 1 });
    return member;
}

test "ownership membership invitations and visitor travel remain separate" {
    var directory: catalog.Catalog = .{ .io = std.testing.io };
    for (&directory.ids, 0..) |*id, index| id.* = @as(u128, 0xfedcba98765432100000000000000000) + index;
    const alice = try join(&directory, 1, "alice", 0);
    const bob = try join(&directory, 2, "bob", 0);
    const carol = try join(&directory, 3, "carol", 0);
    try std.testing.expectError(error.NoIsland, directory.requestHome(alice.uuid));
    try std.testing.expectError(error.NoInvitation, directory.accept(bob, alice.uuid));
    const home = try directory.create(alice);
    try std.testing.expectEqual(@as(usize, 1), home);
    try std.testing.expectEqual(alice.uuid, directory.snapshot(home).owner().?);
    try std.testing.expectError(error.AlreadyMember, directory.create(alice));
    directory.moved(alice.uuid, 0, home);
    try directory.kick(bob.uuid, null);
    try std.testing.expectEqual(@as(usize, 0), requested(&directory, bob.uuid, 0).?);
    directory.moved(bob.uuid, 0, 0);
    try std.testing.expectEqual(catalog.Notice.hub, notice(&directory, bob.uuid, 0).?);
    try std.testing.expect(try directory.visit(bob.uuid, alice.uuid));
    try std.testing.expect(requested(&directory, bob.uuid, 0) == null);
    try std.testing.expectEqual(bob.uuid, visitRequest(&directory, alice.uuid).?.uuid);
    try std.testing.expect(visitRequest(&directory, alice.uuid) == null);
    try std.testing.expectError(error.NoIsland, directory.acceptVisit(carol.uuid, bob.uuid));
    try directory.acceptVisit(alice.uuid, bob.uuid);
    try std.testing.expectError(error.NoVisitRequest, directory.acceptVisit(alice.uuid, bob.uuid));
    try std.testing.expectEqual(home, requested(&directory, bob.uuid, 0).?);
    directory.moved(bob.uuid, 0, home);
    try std.testing.expectError(error.NoIsland, directory.requestHome(bob.uuid));
    try directory.kick(alice.uuid, bob.uuid);
    try std.testing.expectEqual(@as(usize, 0), requested(&directory, bob.uuid, home).?);
    directory.moved(bob.uuid, home, 0);
    try directory.invite(alice.uuid, bob.uuid);
    try std.testing.expectEqual(alice.uuid, invitation(&directory, bob.uuid).?.uuid);
    try std.testing.expect(invitation(&directory, bob.uuid) == null);
    try std.testing.expectError(error.NoInvitation, directory.accept(bob, carol.uuid));
    try directory.accept(bob, alice.uuid);
    try std.testing.expectEqual(@as(usize, 2), directory.snapshot(home).count);
    try std.testing.expectEqual(alice.uuid, directory.snapshot(home).owner().?);
    try std.testing.expectError(error.AlreadyMember, directory.create(bob));
    try std.testing.expectError(error.NotOwner, directory.invite(bob.uuid, carol.uuid));
    directory.moved(bob.uuid, 0, home);
    try std.testing.expectError(error.NotOwner, directory.kick(bob.uuid, alice.uuid));
    try std.testing.expectError(error.NotOwner, directory.acceptVisit(bob.uuid, carol.uuid));
    try std.testing.expectError(error.CannotKickMember, directory.kick(alice.uuid, bob.uuid));
    try directory.kick(bob.uuid, null);
    directory.moved(bob.uuid, home, 0);
    try directory.requestHome(bob.uuid);
    try std.testing.expectEqual(home, requested(&directory, bob.uuid, 0).?);
    const other = try directory.create(carol);
    try std.testing.expectEqual(@as(usize, 2), other);
    try std.testing.expectError(error.TargetAlreadyMember, directory.invite(carol.uuid, bob.uuid));
    var router: Router = .{ .catalog = &directory };
    const decision = router.route(.{ .connection = .{ .index = 0, .generation = 1 }, .protocol = 1, .uuid = 100, .name = "guest" });
    try std.testing.expectEqual(directory.ids[0], decision.destination);
    try std.testing.expect(directory.ids[home] != alice.uuid);
}

test "island and membership limits do not partially mutate state" {
    var directory: catalog.Catalog = .{ .io = std.testing.io };
    const owner = try join(&directory, 1, "owner", 0);
    const index = try directory.create(owner);
    for (2..catalog.maximum_members + 1) |uuid| {
        const member = try join(&directory, uuid, "member", 0);
        try directory.invite(owner.uuid, member.uuid);
        try directory.accept(member, owner.uuid);
    }
    const extra = try join(&directory, 10, "extra", 0);
    try std.testing.expectError(error.IslandFull, directory.invite(owner.uuid, extra.uuid));
    try std.testing.expectEqual(@as(usize, catalog.maximum_members), directory.snapshot(index).count);
    for (1..catalog.maximum) |slot| {
        const member = try join(&directory, 100 + slot, "owner", 0);
        _ = try directory.create(member);
    }
    try std.testing.expectError(error.IslandLimit, directory.create(extra));
    try std.testing.expectEqual(@as(usize, 0), directory.destination(extra.uuid));
}

test "travel confirmation survives rebinding and preserves a newer destination" {
    var directory: catalog.Catalog = .{ .io = std.testing.io };
    const alice = try join(&directory, 1, "alice", 0);
    const home = try directory.create(alice);
    try std.testing.expect(notice(&directory, alice.uuid, 0) == null);
    directory.moved(alice.uuid, 0, home);
    directory.depart(0, .{ .index = 1, .generation = 1 });
    try directory.arrive(home, alice, .{ .index = 0, .generation = 2 });
    try std.testing.expectEqual(catalog.Notice.created, notice(&directory, alice.uuid, home).?);
    try std.testing.expect(notice(&directory, alice.uuid, home) == null);

    try directory.kick(alice.uuid, null);
    directory.moved(alice.uuid, home, 0);
    try directory.requestHome(alice.uuid);
    try directory.arrive(0, alice, .{ .index = 1, .generation = 3 });
    try std.testing.expectEqual(home, requested(&directory, alice.uuid, 0).?);
    try std.testing.expect(notice(&directory, alice.uuid, 0) == null);
    try std.testing.expect(directory.cancelMove(alice.uuid, 0) == null);
    try std.testing.expectEqual(catalog.Notice.home, directory.cancelMove(alice.uuid, home).?);
    try std.testing.expect(requested(&directory, alice.uuid, 0) == null);
}

test "membership is atomically saved with its world and restored after reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    var directory: catalog.Catalog = .{ .io = std.testing.io };
    const alice = try join(&directory, 1, "alice", 0);
    const bob = try join(&directory, 2, "bob", 0);
    const index = try directory.create(alice);
    try directory.invite(alice.uuid, bob.uuid);
    try directory.accept(bob, alice.uuid);
    const state = directory.snapshot(index);
    {
        var store = try lightning_rod.storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        try state.write(try store.openSpace(catalog.island_namespace));
        try store.waitDurable(try store.commit(7));
        var uncommitted = state;
        uncommitted.count = 1;
        try uncommitted.write(try store.openSpace(catalog.island_namespace));
    }
    var store = try lightning_rod.storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    const restored = try catalog.State.read(try store.openSpace(catalog.island_namespace));
    try std.testing.expectEqualDeep(state, restored);
    var restarted: catalog.Catalog = .{ .io = std.testing.io };
    try restarted.load(index, restored);
    try std.testing.expectEqual(index, restarted.destination(bob.uuid));
    try std.testing.expectError(error.DuplicateIslandMembership, restarted.load(index + 1, restored));
    try std.testing.expectEqual(@as(usize, 0), restarted.snapshot(index + 1).count);
}

fn requested(directory: *catalog.Catalog, uuid: u128, index: usize) ?usize {
    for (directory.profiles) |profile| if (profile.member) |member| {
        if (member.uuid == uuid and profile.location == index) return profile.requested;
    };
    return null;
}
fn pollOne(directory: *catalog.Catalog, uuid: u128, index: usize) catalog.Update {
    const handle = for (directory.profiles) |profile| {
        if (profile.member) |member| if (member.uuid == uuid) break profile.handle.?;
    } else unreachable;
    var cursor: catalog.Cursor = .{};
    var updates: [1]catalog.Update = undefined;
    _ = directory.poll(index, &.{.{ .uuid = uuid, .handle = handle }}, &updates, &cursor);
    return updates[0];
}
fn notice(directory: *catalog.Catalog, uuid: u128, index: usize) ?catalog.Notice {
    return pollOne(directory, uuid, index).notice;
}
fn invitation(directory: *catalog.Catalog, uuid: u128) ?catalog.Member {
    const index = for (directory.profiles) |profile| {
        if (profile.member) |member| if (member.uuid == uuid) break profile.location;
    } else unreachable;
    return pollOne(directory, uuid, index).invitation;
}
fn visitRequest(directory: *catalog.Catalog, uuid: u128) ?catalog.Member {
    const index = for (directory.profiles) |profile| {
        if (profile.member) |member| if (member.uuid == uuid) break profile.location;
    } else unreachable;
    return pollOne(directory, uuid, index).visitor;
}

test "catalog batches retain busy moves and observe changing ready players" {
    var directory: catalog.Catalog = .{ .io = std.testing.io };
    const alice = try join(&directory, 1, "alice", 0);
    const bob = try join(&directory, 2, "bob", 0);
    const home = try directory.create(alice);
    const players = [_]catalog.Player{ .{ .uuid = alice.uuid, .handle = .{ .index = 1, .generation = 1 } }, .{ .uuid = bob.uuid, .handle = .{ .index = 2, .generation = 1 } } };
    var cursor: catalog.Cursor = .{};
    var updates: [2]catalog.Update = undefined;
    try std.testing.expect(directory.poll(0, &players, &updates, &cursor));
    try std.testing.expectEqual(home, updates[0].destination.?);
    try std.testing.expect(directory.poll(0, &players, &updates, &cursor));
    try std.testing.expectEqual(home, updates[0].destination.?);
    directory.moved(alice.uuid, 0, home);
    try std.testing.expect(directory.poll(0, players[1..], updates[1..], &cursor));
    const NoWait = struct {
        fn wait(_: ?*anyopaque, _: *const u32, _: u32) void {
            @panic("idle polling attempted to acquire the shared lock");
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.futexWaitUncancelable = NoWait.wait;
    directory.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    directory.mutex.lockUncancelable(std.testing.io);
    for (0..1000) |_| try std.testing.expect(!directory.poll(0, players[1..], updates[1..], &cursor));
    directory.mutex.unlock(std.testing.io);
    try directory.invite(alice.uuid, bob.uuid);
    try std.testing.expect(directory.poll(0, players[1..], updates[1..], &cursor));
    try std.testing.expectEqual(alice.uuid, updates[1].invitation.?.uuid);
    try std.testing.expect(!directory.poll(0, players[1..], updates[1..], &cursor));
    try std.testing.expect(directory.poll(home, players[0..1], updates[0..1], &cursor));
    try std.testing.expectEqual(catalog.Notice.created, updates[0].notice.?);
}

test "bounded catalog polls drain every visitor and reject stale connections" {
    var directory: catalog.Catalog = .{ .io = std.testing.io };
    const alice = try join(&directory, 1, "alice", 0);
    const bob = try join(&directory, 2, "bob", 0);
    const carol = try join(&directory, 3, "carol", 0);
    const home = try directory.create(alice);
    directory.moved(alice.uuid, 0, home);
    try std.testing.expect(try directory.visit(bob.uuid, alice.uuid));
    try std.testing.expect(try directory.visit(carol.uuid, alice.uuid));
    const player: catalog.Player = .{ .uuid = alice.uuid, .handle = .{ .index = 1, .generation = 1 } };
    var cursor: catalog.Cursor = .{};
    var updates: [1]catalog.Update = undefined;
    try std.testing.expect(directory.poll(home, &.{player}, &updates, &cursor));
    try std.testing.expectEqual(bob.uuid, updates[0].visitor.?.uuid);
    try std.testing.expect(directory.poll(home, &.{player}, &updates, &cursor));
    try std.testing.expectEqual(carol.uuid, updates[0].visitor.?.uuid);
    try std.testing.expect(directory.poll(home, &.{player}, &updates, &cursor));
    try std.testing.expect(updates[0].visitor == null);
    try std.testing.expect(!directory.poll(home, &.{player}, &updates, &cursor));
    try directory.arrive(home, alice, .{ .index = 1, .generation = 2 });
    try directory.requestHome(alice.uuid);
    try std.testing.expect(directory.poll(home, &.{player}, &updates, &cursor));
    try std.testing.expect(updates[0].destination == null);
    var replacement = player;
    replacement.handle.generation = 2;
    try std.testing.expect(directory.poll(home, &.{replacement}, &updates, &cursor));
    try std.testing.expectEqual(home, updates[0].destination.?);
}
