const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const e2e = @import("e2e");
const minecraft = @import("minecraft_model");

pub fn main(init: std.process.Init) !void {
    const operators = e2e.profile.aliceOperator();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 2, .render_distance = 2, .spawn_for_player = spawn }),
            lightning_rod.plugin.configured(vanilla.Operators, .{ .operators = &operators }),
        }),
        lightning_rod.plugin.configured(vanilla.RegionDebug, .{}),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

fn spawn(player: *const vanilla.Players.Player) minecraft.Position {
    return .{ .x = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) 0.5 else 12.5, .y = 65, .z = 0.5 };
}

const Probe = struct {
    pub const id = "e2e:region_debug";
    pub const Configuration = struct {};
    pub const Dependencies = struct { control: *e2e.Control, players: *vanilla.Players };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "move")) {
            const player = &self.deps.players.records[handle.index];
            var position = player.position;
            position.x += 32;
            try self.deps.players.teleport(player, player.world, position, player.rotation);
            return .handled;
        }
        if (!std.mem.eql(u8, text, "complete")) return .unhandled;
        for (self.deps.players.records) |player| if (player.handle) |recipient| try self.deps.control.send(recipient, "complete");
        return .handled;
    }
};
