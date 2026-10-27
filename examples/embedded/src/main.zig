const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");
const protocols = @import("protocols");
const sessions = @import("sessions");
const vanilla = @import("vanilla");

comptime {
    std.debug.assert(builtin.single_threaded);
}

pub fn main(init: std.process.Init) !void {
    const startup = profile.Startup.capture(init.io);
    var memory = lightning_rod.Memory.init(std.heap.page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    var port: u16 = 25565;
    var storage_path: []const u8 = "lightning-rod-data/world";
    _ = args.skip();
    while (args.next()) |argument| {
        if (std.mem.startsWith(u8, argument, "--port=")) {
            port = try std.fmt.parseInt(u16, argument["--port=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--world=")) {
            storage_path = argument["--world=".len..];
            if (storage_path.len == 0) return error.InvalidWorldPath;
        } else return error.UnknownArgument;
    }
    var selected = try protocols.Default.init(allocator);
    defer selected.deinit(allocator);
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocols.Handshake, .{}),
        vanilla.session_plugins(&selected),
    });
    const plugins = lightning_rod.plugin.replace(vanilla.plugins(), .{
        lightning_rod.plugin.configured(vanilla.RecordWorkspaces, .{ .readers = 1, .writers = 1 }),
        lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 4, .render_distance = 4 }),
    });
    try profile.Server(@TypeOf(plugins), protocols.Endpoint, @TypeOf(session_plugins), sessions.SingleSimulation).run(&memory, init, .{
        .plugins = plugins,
        .network = .{
            .plugins = session_plugins,
            .protocols = &selected,
            .router = .{},
            .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
            .max_players = 4,
            .endpoints = &.{.{ .id = 0, .connections = 4 }},
        },
        .startup = startup,
        .storage_path = storage_path,
        .reload = null,
    }, .{});
}
