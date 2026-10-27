const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const vanilla = @import("vanilla");
const skyblock = @import("skyblock");
const e2e = @import("e2e");
const minecraft = @import("minecraft_model");

pub fn main(init: std.process.Init) !void {
    var directory: skyblock.catalog.Catalog = .{ .io = init.io };
    var chat: skyblock.ChatChannel = .{ .io = init.io };
    for (&directory.ids, 0..) |*id, index| id.* = @as(u128, 0xfedcba98765432100000000000000000) + index;
    var endpoints: [3]*sessions.Service = undefined;
    var routing: sessions.Routing = .{ .endpoints = &endpoints };
    const hub = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(lightning_rod.plugin.remove(lightning_rod.plugin.remove(e2e.profile.plugins(), vanilla.ChatInput), vanilla.JoinLeaveMessages), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .spawn_for_player = spawn, .world_border = 512 }),
            lightning_rod.plugin.configured(skyblock.Terrain, .{ .kind = .hub }),
        }),
        lightning_rod.plugin.configured(skyblock.IslandCommands, .{ .catalog = &directory, .routing = &routing, .index = 0 }),
        lightning_rod.plugin.configured(skyblock.GlobalChat, .{ .channel = &chat }),
        lightning_rod.plugin.configured(Probe, .{ .catalog = &directory, .index = 0 }),
    });
    const home = lightning_rod.plugin.replace(hub, .{
        lightning_rod.plugin.configured(skyblock.Terrain, .{ .kind = .island }),
        lightning_rod.plugin.configured(skyblock.IslandCommands, .{ .catalog = &directory, .routing = &routing, .index = 1 }),
        lightning_rod.plugin.configured(Probe, .{ .catalog = &directory, .index = 1 }),
    });
    const other = lightning_rod.plugin.replace(hub, .{
        lightning_rod.plugin.configured(skyblock.Terrain, .{ .kind = .island }),
        lightning_rod.plugin.configured(skyblock.IslandCommands, .{ .catalog = &directory, .routing = &routing, .index = 2 }),
        lightning_rod.plugin.configured(Probe, .{ .catalog = &directory, .index = 2 }),
    });
    try e2e.simulations.run(init, .{ hub, home, other }, &endpoints, .{lightning_rod.plugin.configured(skyblock.Presence, .{ .catalog = &directory, .chat = &chat })}, .{
        .connections = 2,
        .routes = &.{ .{ .player = "alice", .destination = 0 }, .{ .player = "bob", .destination = 0 } },
    });
}

fn spawn(player: *const vanilla.Players.Player) minecraft.Position {
    return .{ .x = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) 0.5 else 1.5, .y = 65, .z = 0.5 };
}

const Probe = struct {
    pub const id = "e2e:skyblock";
    pub const Configuration = struct { catalog: *skyblock.catalog.Catalog, index: usize };
    pub const Dependencies = struct { control: *e2e.Control, players: *vanilla.Players };
    deps: Dependencies,
    config: Configuration,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps, .config = config };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "skyblock_member")) return .unhandled;
        const player = self.deps.players.records[handle.index];
        if (player.stage != .ready or !player.loaded or self.config.index != 1) return error.WrongHomeIsland;
        const alice = self.config.catalog.find("alice") orelse return error.MissingOwner;
        const bob = self.config.catalog.find("bob") orelse return error.MissingMember;
        const state = self.config.catalog.snapshot(1);
        if (state.owner() != alice.uuid or state.count != 2 or state.members[1].uuid != bob.uuid) return error.InvalidMembership;
        if (self.config.catalog.snapshot(2).count != 0) return error.CreatedSecondHome;
        return .handled;
    }
};
