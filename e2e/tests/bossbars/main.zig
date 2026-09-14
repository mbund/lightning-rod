const std = @import("std");
const rod = @import("lightning_rod");
const profile = @import("lightning_rod_linux");
const vanilla = @import("vanilla");
const bossbars = @import("bossbars");
const tps = @import("tps");

pub export const lightning_rod_resume_manifest linksection(profile.Reload.section_name) = profile.Reload.manifest;

pub fn main(init: std.process.Init) !void {
    const address = init.environ_map.get("LIGHTNING_ROD_E2E_ADDRESS") orelse "127.0.0.1:25565";
    const port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..], 10);
    var uuid: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:alice", &uuid, .{});
    uuid[6] = (uuid[6] & 15) | 0x30;
    uuid[8] = (uuid[8] & 63) | 0x80;
    const operators = [_]u128{std.mem.readInt(u128, &uuid, .big)};
    const plugins = rod.plugin.compose(.{
        rod.plugin.replace(vanilla.plugins(), .{
            rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 2, .render_distance = 4 }),
            rod.plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{ .operators = &operators }),
        }),
        rod.plugin.configured(bossbars.Bossbars, bossbars.Bossbars.Configuration{}),
        rod.plugin.configured(tps.Tps, tps.Tps.Configuration{}),
        rod.plugin.configured(Probe, Probe.Configuration{}),
    });
    var protocols = try vanilla.Protocols.init(init.gpa);
    defer protocols.deinit(init.gpa);
    try profile.Profile(@TypeOf(plugins)).run(init, .{
        .plugins = plugins,
        .max_players = 2,
        .protocols = &protocols.values,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .reload = .{ .executable = "/proc/self/exe" },
    });
}

const Probe = struct {
    pub const id = "e2e:bossbars";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *vanilla.Players,
        bars: *bossbars.Bossbars,
    };

    deps: Dependencies,
    ticks: u32 = 0,
    bar: ?bossbars.Handle = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *Probe, io: std.Io) !void {
        for (self.deps.players.records) |player| if (player.handle == null or player.stage != .ready or !player.loaded) return;
        self.ticks += 1;

        if (self.ticks == 1) for (self.deps.players.records) |*player| {
            const alice = std.mem.eql(u8, player.name[0..player.name_len], "alice");
            try self.deps.players.teleport(player, player.world, .{ .x = if (alice) -3.5 else 3.5, .y = 65, .z = 3.5 }, .{ .yaw = if (alice) -90 else 90, .pitch = 0 });
        };

        if (self.ticks == 1 or self.ticks == 81) {
            const name = if (self.ticks == 1) "alice" else "bob";

            for (self.deps.players.records) |player| if (std.mem.eql(u8, player.name[0..player.name_len], name)) {
                self.bar = try self.deps.bars.create(.{
                    .title = if (self.ticks == 1) "Private alice" else "Private bob",
                    .audience = .{ .player = player.uuid },
                });
            };
        }

        if (self.ticks == 61 or self.ticks == 141) {
            try self.deps.bars.remove(self.bar.?);
            self.bar = null;
        }

        if (self.ticks >= 200 and self.ticks < 220) try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
};
