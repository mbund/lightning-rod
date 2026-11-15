const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const vanilla = @import("vanilla");
const BlockEdit = @import("chunks").BlockEdit;
const ChunkSource = @import("chunks").Source;
const Chunks = @import("chunks").Chunks;
const Players = @import("players").players.Players;
const Section = @import("chunks").Section;
const e2e = @import("e2e");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");

const spawn_offset = 4096;

pub fn main(init: std.process.Init) !void {
    const args = try e2e.profile.arguments(init);
    // Isolation matches the smaller radius its fixture asks for.
    const distance: i32 = if (std.mem.eql(u8, args.fixture, "registry")) 2 else if (std.mem.eql(u8, args.fixture, "isolation")) 12 else 32;
    const terrain_plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(Players, Players.Configuration{ .render_distance = distance, .spawn_for_player = spawn }),
        lightning_rod.plugin.configured(vanilla.Flat, .{ .biomes = biomePattern }),
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

fn spawn(player: *const Players.Player) minecraft.Position {
    const coordinate: f64 = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) -spawn_offset + 0.5 else spawn_offset + 0.5;
    return .{ .x = coordinate, .y = 65, .z = coordinate };
}

fn biomePattern(_: Section, values: *[64]u16) void {
    const names = [_][]const u8{ "minecraft:plains", "minecraft:desert", "minecraft:forest" };
    for (values, 0..) |*biome, index| biome.* = @intCast(protocols.registry.biomeId(names[index % names.len]).?);
}

// Disk scenarios must resolve every section from storage, including unchanged air sections.
const NoGeneration = struct {
    pub const id = vanilla.Flat.id;
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *Chunks };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*NoGeneration {
        const self = try allocator.create(NoGeneration);
        self.* = .{};
        deps.chunks.setSource(ChunkSource.init(self, read));
        return self;
    }

    fn read(self: *NoGeneration, io: std.Io, batch: ChunkSource.Batch) void {
        for (batch.requests) |*request| request.result = self.readOne(io, request.section, request.output);
    }

    fn readOne(_: *NoGeneration, _: std.Io, _: Section, _: []u8) !usize {
        return error.E2eUnexpectedTerrainGeneration;
    }
};

const Probe = struct {
    pub const id = "e2e:chunks";
    pub const Configuration = struct { disk: bool = false };
    pub const Dependencies = struct {
        control: *e2e.Control,
        players: *Players,
        chunks: *Chunks,
        vanilla_worlds: *vanilla.VanillaWorlds,
    };
    disk: bool,
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .disk = config.disk, .deps = deps };
        deps.control.on(self, message);
        if (!config.disk) {
            const name = if (protocols.registry.itemId("minecraft:chain") != null) "minecraft:chain" else "minecraft:iron_chain";
            for ([_]i32{ -spawn_offset, spawn_offset }) |coordinate| {
                var edits: [6]BlockEdit = undefined;
                for (&edits, 0..) |*edit, index| {
                    var buffer: [128]u8 = undefined;
                    const state_name = try std.fmt.bufPrint(&buffer, "{s}[axis={s},waterlogged={s}]", .{ name, ([_][]const u8{ "x", "y", "z" })[index / 2], if (index % 2 == 0) "true" else "false" });
                    edit.* = .{ .index = @intCast(256 + 3 * 16 + 2 + index), .state = @intCast(protocols.registry.blockStateId(state_name).?) };
                }
                try deps.chunks.setBlocks(.{ .world = deps.vanilla_worlds.overworld, .x = @divExact(coordinate, 16), .z = @divExact(coordinate, 16), .y = 4 }, &edits);
            }
        }
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
