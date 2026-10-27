const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const vanilla = @import("vanilla");
const e2e = @import("e2e");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");

pub fn main(init: std.process.Init) !void {
    const args = try e2e.profile.arguments(init);
    const terrain_plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 32, .spawn_for_player = spawn }),
    });
    if (std.mem.eql(u8, args.fixture, "simulations")) {
        var endpoints: [2]*sessions.Service = undefined;
        const plugins = lightning_rod.plugin.compose(.{
            terrain_plugins,
            lightning_rod.plugin.configured(e2e.Inventory, .{}),
        });
        const alice = lightning_rod.plugin.replace(plugins, .{
            lightning_rod.plugin.configured(e2e.Inventory, .{ .starting_bread = 17 }),
        });
        return e2e.simulations.run(init, .{ alice, plugins }, &endpoints, .{}, .{ .plaintext = true, .render_distance = 32 });
    }
    const disk = std.mem.eql(u8, args.fixture, "disk");
    const plugins = lightning_rod.plugin.compose(.{
        terrain_plugins,
        lightning_rod.plugin.configured(Probe, .{ .disk = disk }),
    });
    if (disk) return e2e.profile.run(init, lightning_rod.plugin.replace(plugins, .{lightning_rod.plugin.configured(NoGeneration, .{})}), .{ .plaintext = true });
    try e2e.profile.run(init, plugins, .{ .plaintext = !std.mem.eql(u8, args.fixture, "encryption"), .compression_threshold = if (std.mem.eql(u8, args.fixture, "isolation")) null else 256, .generation_workers = if (std.mem.eql(u8, args.fixture, "parallel")) 4 else 0 });
}

fn spawn(player: *const vanilla.Players.Player) minecraft.Position {
    const coordinate: f64 = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) -4095.5 else 4096.5;
    return .{ .x = coordinate, .y = 65, .z = coordinate };
}

// Disk scenarios must resolve every section from storage, including unchanged air sections.
const NoGeneration = struct {
    pub const id = vanilla.Flat.id;
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *vanilla.Chunks };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*NoGeneration {
        const self = try allocator.create(NoGeneration);
        self.* = .{};
        deps.chunks.setSource(vanilla.ChunkSource.init(self, read));
        return self;
    }

    fn read(self: *NoGeneration, io: std.Io, batch: vanilla.ChunkSource.Batch) void {
        for (batch.requests) |*request| request.result = self.readOne(io, request.section, request.output);
    }

    fn readOne(_: *NoGeneration, _: std.Io, _: vanilla.Section, _: []u8) !usize {
        return error.E2eUnexpectedTerrainGeneration;
    }
};

const Probe = struct {
    pub const id = "e2e:chunks";
    pub const Configuration = struct { disk: bool = false };
    pub const Dependencies = struct {
        control: *e2e.Control,
        players: *vanilla.Players,
        chunks: *vanilla.Chunks,
    };
    disk: bool,
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .disk = config.disk, .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "chunks_stamp")) return .unhandled;
        if (self.disk) return error.E2eStampDuringDiskRead;
        const player = self.deps.players.records[handle.index];
        const x: i32 = @intFromFloat(@floor(player.position.x));
        const z: i32 = @intFromFloat(@floor(player.position.z));
        for ([_][]const u8{ "minecraft:gold_block", "minecraft:diamond_block", "minecraft:emerald_block" }, 0..) |name, i|
            try self.deps.chunks.setBlock(player.world, .{ .x = x + 2 + @as(i32, @intCast(i)), .y = 65, .z = z + 2 }, @intCast(protocols.registry.blockStateId(name).?));
        return .handled;
    }
};
