const std = @import("std");
const lightning_rod = @import("lightning_rod");
const host = @import("host");
const catalog = @import("catalog.zig");
const game_data = @import("game_data");
const records = @import("records");
const Worlds = @import("worlds.zig").Worlds;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(allocator);
    defer arguments.deinit();
    _ = arguments.skip();
    const executable = arguments.next() orelse return error.MissingExecutable;
    const directory = arguments.next() orelse return error.MissingWorldDirectory;
    const world_arg = try std.fmt.allocPrint(allocator, "--world={s}", .{directory});
    try std.Io.Dir.cwd().deleteTree(init.io, directory);
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    const root_path = try std.fs.path.join(allocator, &.{ directory, "sessions" });
    var ids: [catalog.endpoints]u128 = undefined;
    {
        var store = try lightning_rod.storage.Store.init(allocator, init.io, .{ .path = root_path });
        defer store.deinit();
        var initial = try catalog.Catalog.open(&store);
        ids = initial.ids;
        const alice = catalog.Member.named(1, "alice");
        const bob = catalog.Member.named(2, "bob");
        try initial.arrive(0, alice, .{ .index = 0, .generation = 1 });
        try initial.arrive(0, bob, .{ .index = 1, .generation = 1 });
        const index = try initial.create(alice);
        try initial.invite(alice.uuid, bob.uuid);
        try initial.accept(bob, alice.uuid);
        var worlds = try Worlds.init(&store, init.io);
        var world = try worlds.create(index);
        try records.Value.init(try world.transaction().openSpace("minecraft:registry_identity")).write(&game_data.canonical_identity);
        try initial.snapshot(index).write(try world.transaction().openSpace(catalog.island_namespace));
        try store.waitDurable(try store.commit(0));
    }
    const log = try std.Io.Dir.cwd().createFile(init.io, try std.fs.path.join(allocator, &.{ directory, "server.log" }), .{});
    defer log.close(init.io);
    const argv = &.{ executable, "--port=0", "--workers=2", "--startup-report", world_arg };
    var child = try std.process.spawn(init.io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .{ .file = log } });
    defer child.kill(init.io);
    var buffer: [128]u8 = undefined;
    var output = child.stdout.?.reader(init.io, &buffer);
    _ = try host.Startup.Report.read(&output.interface);
    try std.posix.kill(child.id.?, .USR1);
    _ = try host.Startup.Report.read(&output.interface);
    try std.posix.kill(child.id.?, .KILL);
    const term = try child.wait(init.io);
    if (term != .signal or term.signal != .KILL) return error.UnexpectedTermination;
    var restarted = try std.process.spawn(init.io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .{ .file = log } });
    defer restarted.kill(init.io);
    var resumed_output = restarted.stdout.?.reader(init.io, &buffer);
    _ = try host.Startup.Report.read(&resumed_output.interface);
    try std.posix.kill(restarted.id.?, .TERM);
    const stopped = try restarted.wait(init.io);
    if (stopped != .exited or stopped.exited != 0) return error.GracefulShutdownFailed;
    var store = try lightning_rod.storage.Store.init(allocator, init.io, .{ .path = root_path });
    defer store.deinit();
    const restored = try catalog.Catalog.read(try store.openSpace("skyblock:islands")) orelse return error.MissingIslandCatalog;
    if (!std.mem.eql(u128, &ids, &restored.ids)) return error.IslandIdentitiesChanged;
    var worlds = try Worlds.init(&store, init.io);
    for (0..ids.len) |index| {
        if (index != 1) {
            if (try worlds.open(index) != null) return error.UnoccupiedWorldWasOpened;
            continue;
        }
        var world = (try worlds.open(index)) orelse return error.MissingWorld;
        const state = try catalog.State.read(try world.transaction().openSpace(catalog.island_namespace));
        if (state.count != 2 or state.owner() != 1 or state.members[1].uuid != 2) return error.MembershipChanged;
        if (world.tick != 0) return error.UnoccupiedWorldWasTicked;
    }
}
