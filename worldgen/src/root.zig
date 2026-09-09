const std = @import("std");
const minecraft = @import("minecraft_registry");

pub const minecraft_version = "1.21.8";

pub const random = @import("random.zig");
pub const noise = @import("noise.zig");
pub const legacy_noise = @import("legacy_noise.zig");
pub const climate = @import("climate.zig");
pub const spline = @import("spline.zig");
pub const biome = @import("biome.zig");
pub const density_program = @import("density_program.zig");
pub const density = @import("density.zig");
pub const generated_state = @import("generated_state.zig");
pub const feature = @import("feature.zig");
pub const aquifer = @import("aquifer.zig");
pub const chunk = @import("chunk.zig");
pub const surface_program = @import("surface_program.zig");
pub const biome_access = @import("biome_access.zig");
pub const biome_temperature = @import("biome_temperature.zig");
pub const carver = @import("carver.zig");
pub const surface = @import("surface.zig");
pub const pipeline = @import("pipeline.zig");
pub const structures = @import("structures.zig");
pub const jigsaw = @import("jigsaw.zig");
const base_dimension = @import("base_dimension.zig");
pub const nether_carver = @import("nether_carver.zig");
pub const nether_features = @import("nether_features.zig");
pub const nether_structures = @import("nether_structures.zig");
pub const nether_fortress = @import("nether_fortress.zig");
pub const ruined_portal = @import("ruined_portal.zig");
pub const end_features = @import("end_features.zig");
pub const end_structures = @import("end_structures.zig");
pub const stronghold = @import("stronghold.zig");
pub const dimension_biome = @import("dimension_biome.zig");
const nether_density_data = @import("nether_density_data");
const end_density_data = @import("end_density_data");
const nether_surface_data = @import("nether_surface_data");
const end_surface_data = @import("end_surface_data");
pub const nether_density = density.Engine(nether_density_data);
pub const end_density = density.Engine(end_density_data);
pub const nether_surface = surface.Engine(nether_surface_data, nether_density);
pub const end_surface = surface.Engine(end_surface_data, end_density);
pub const nether = base_dimension.Dimension(
    nether_density,
    nether_density_data,
    nether_surface,
    dimension_biome.Nether(nether_density),
    nether_carver,
    nether_features,
    256,
);
pub const end = base_dimension.Dimension(
    end_density,
    end_density_data,
    end_surface,
    dimension_biome.End(end_density),
    base_dimension.NoCarvers,
    end_features,
    256,
);

test {
    _ = random;
    _ = noise;
    _ = legacy_noise;
    _ = climate;
    _ = spline;
    _ = biome;
    _ = density_program;
    _ = density;
    _ = aquifer;
    _ = chunk;
    _ = surface_program;
    _ = biome_access;
    _ = biome_temperature;
    _ = surface;
    _ = pipeline;
    _ = structures;
    _ = jigsaw;
    _ = nether;
    _ = end;
    _ = stronghold;
    std.testing.refAllDecls(stronghold);
}

test "Nether and End use their Vanilla density settings" {
    try std.testing.expectEqual(@as(i32, 0), nether.minimum_y);
    try std.testing.expectEqual(@as(i32, 128), nether.terrain_height);
    try std.testing.expectEqual(@as(i32, 256), nether.height);
    try std.testing.expectEqualStrings("minecraft:netherrack", nether.default_block);
    try std.testing.expectEqualStrings("minecraft:lava[level=0]", nether.default_fluid);
    try std.testing.expectEqual(@as(i32, 0), end.minimum_y);
    try std.testing.expectEqual(@as(i32, 128), end.terrain_height);
    try std.testing.expectEqual(@as(i32, 256), end.height);
    try std.testing.expectEqualStrings("minecraft:end_stone", end.default_block);
    try std.testing.expectEqualStrings("minecraft:air", end.default_fluid);
}

test "Nether and End density generators fill complete chunks" {
    inline for (.{ nether, end }) |dimension| {
        var generator = try dimension.Generator.init(std.testing.allocator, 0);
        defer generator.deinit();
        const blocks = try std.testing.allocator.alloc(base_dimension.Block, dimension.block_count);
        defer std.testing.allocator.free(blocks);
        try generator.generate(0, 0, blocks);
        var terrain_count: usize = 0;
        for (blocks) |block| switch (block) {
            .solid, .surface, .feature => terrain_count += 1,
            .air, .cave_air, .fluid => {},
        };
        try std.testing.expect(terrain_count != 0);
    }
}

test "End density preserves Vanilla far-coordinate integer overflow" {
    var generator = try end.Generator.init(std.testing.allocator, @bitCast(@as(i64, -9144226586197258779)));
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(end.Generator.BlockType, end.block_count);
    defer std.testing.allocator.free(blocks);
    try generator.generateFeatures(666189, 288281, blocks);
    for (blocks) |block| try std.testing.expectEqualStrings("minecraft:air", end.canonicalName(block));
}

test "End feature biome filters use Vanilla's jittered block lookup" {
    const seed: i64 = -3957255068762882502;
    var generator = try end.Generator.init(std.testing.allocator, @bitCast(seed));
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(end.Generator.BlockType, end.block_count);
    defer std.testing.allocator.free(blocks);
    try generator.generateFeatures(216346, -861818, blocks);
    const state = blocks[end.blockIndex(12, 58, 14)];
    try std.testing.expectEqualStrings(
        "minecraft:chorus_plant[down=true,east=false,north=false,south=false,up=true,west=false]",
        end.canonicalName(state),
    );
}

test "End city candidate validity includes Vanilla terrain rejection" {
    var generator = try end.Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const scratch = try std.testing.allocator.create(end_structures.Scratch);
    defer std.testing.allocator.destroy(scratch);
    try std.testing.expect(!end_structures.validStart(&generator, 0, .{ .x = 103, .z = -139 }, scratch));
    var found: ?structures.ChunkPos = null;
    var region_z: i32 = -10;
    while (region_z <= 10 and found == null) : (region_z += 1) {
        var region_x: i32 = -10;
        while (region_x <= 10) : (region_x += 1) {
            const candidate = structures.end_cities.candidate(0, region_x, region_z);
            if (end_structures.validStart(&generator, 0, candidate, scratch)) {
                found = candidate;
                break;
            }
        }
    }
    try std.testing.expectEqual(structures.ChunkPos{ .x = -179, .z = -198 }, found.?);
}

test "dimension surface rules emit canonical Vanilla blocks" {
    var nether_generator = try nether.Generator.init(std.testing.allocator, 0);
    defer nether_generator.deinit();
    const nether_blocks = try std.testing.allocator.alloc(base_dimension.Block, nether.block_count);
    defer std.testing.allocator.free(nether_blocks);
    try nether_generator.generate(0, 0, nether_blocks);
    var has_bedrock = false;
    var has_netherrack = false;
    for (nether_blocks) |block| {
        const name = nether.canonicalName(block);
        has_bedrock = has_bedrock or std.mem.eql(u8, name, "minecraft:bedrock");
        has_netherrack = has_netherrack or std.mem.eql(u8, name, "minecraft:netherrack");
    }
    try std.testing.expect(has_bedrock);
    try std.testing.expect(has_netherrack);

    var end_generator = try end.Generator.init(std.testing.allocator, 0);
    defer end_generator.deinit();
    const end_blocks = try std.testing.allocator.alloc(base_dimension.Block, end.block_count);
    defer std.testing.allocator.free(end_blocks);
    try end_generator.generate(0, 0, end_blocks);
    for (end_blocks) |block| switch (block) {
        .solid, .surface, .feature => try std.testing.expectEqualStrings(
            "minecraft:end_stone",
            end.canonicalName(block),
        ),
        .air, .cave_air, .fluid => {},
    };
}

test "Nether ruined portal reference generates through the feature pipeline" {
    var generator = try nether.Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    var column: [128]base_dimension.Block = undefined;
    const portal = ruined_portal.plan(&generator, 0, .{ .x = 20, .z = 9 }, &column) orelse unreachable;
    try std.testing.expectEqualStrings("minecraft:ruined_portal/portal_8", portal.template.id);
    try std.testing.expectEqual(@as(i32, 27), portal.origin.y);
    try std.testing.expectEqual(structures.Rotation.clockwise_180, portal.rotation);
    try std.testing.expectEqual(structures.Mirror.front_back, portal.mirror);
    try std.testing.expect(!portal.air_pocket);
    var warmed_generator = try nether.Generator.init(std.testing.allocator, 0);
    defer warmed_generator.deinit();
    const blocks = try std.testing.allocator.alloc(base_dimension.Block, nether.block_count);
    defer std.testing.allocator.free(blocks);
    var chunk_z: i32 = 8;
    while (chunk_z <= 10) : (chunk_z += 1) {
        var chunk_x: i32 = 20;
        while (chunk_x <= 22) : (chunk_x += 1) try warmed_generator.generate(chunk_x, chunk_z, blocks);
    }
    const warmed_portal = ruined_portal.plan(&warmed_generator, 0, .{ .x = 20, .z = 9 }, &column) orelse unreachable;
    try std.testing.expectEqual(portal.origin.y, warmed_portal.origin.y);
    try warmed_generator.generateFeatures(21, 9, blocks);
    var obsidian: usize = 0;
    var minimum_obsidian_y: usize = nether.height;
    for (blocks, 0..) |block, index| if (std.mem.startsWith(u8, nether.canonicalName(block), "minecraft:obsidian")) {
        obsidian += 1;
        minimum_obsidian_y = @min(minimum_obsidian_y, index / (16 * 16));
    };
    try std.testing.expectEqual(@as(usize, 15), obsidian);
    try std.testing.expectEqual(@as(usize, 28), minimum_obsidian_y);

    var direct_generator = try nether.Generator.init(std.testing.allocator, 0);
    defer direct_generator.deinit();
    try direct_generator.generateFeatures(21, 9, blocks);
    minimum_obsidian_y = nether.height;
    for (blocks, 0..) |block, index| {
        if (std.mem.startsWith(u8, nether.canonicalName(block), "minecraft:obsidian"))
            minimum_obsidian_y = @min(minimum_obsidian_y, index / (16 * 16));
    }
    try std.testing.expectEqual(@as(usize, 28), minimum_obsidian_y);

    var area = try nether.Area.init(std.testing.allocator, 0, 1);
    defer area.deinit();
    try area.generate(21, 9, 1, blocks);
    minimum_obsidian_y = nether.height;
    for (blocks, 0..) |block, index| {
        if (std.mem.startsWith(u8, nether.canonicalName(block), "minecraft:obsidian"))
            minimum_obsidian_y = @min(minimum_obsidian_y, index / (16 * 16));
    }
    try std.testing.expectEqual(@as(usize, 28), minimum_obsidian_y);
}

test "End biome source keeps the central island in the End biome" {
    var router = try end_density.Router.init(std.testing.allocator, 0);
    defer router.deinit();
    try std.testing.expectEqual(
        dimension_biome.Biome.the_end,
        dimension_biome.End(end_density).at(&router, 0, 64, 0),
    );
}

test "End biome source is bounded at the Vanilla world border" {
    var router = try end_density.Router.init(std.testing.allocator, 0);
    defer router.deinit();
    const source = dimension_biome.End(end_density);
    _ = source.at(&router, 29_999_984, 64, 29_999_984);
    _ = source.at(&router, -29_999_984, 64, -29_999_984);
}

test "End surface generation supports world-border chunks" {
    var generator = try end.Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(base_dimension.Block, end.block_count);
    defer std.testing.allocator.free(blocks);
    try generator.generateSurface(1_874_999, -1_874_999, blocks);
}

test "Nether and End density volumes match Vanilla references" {
    try expectDensityHash(
        nether,
        0,
        0,
        "a7ba50cd30e1ae41d68a8bc88d1a644d9d0fcc6675787a19cf24e8478ecb3d55",
    );
    try expectDensityHash(
        nether,
        7,
        4,
        "5c5269d1157f917e55036301c82787268d7460490e64a1e7dc2e1858cbc79171",
    );
    try expectDensityHash(
        end,
        0,
        0,
        "978acb6e69d9349e52d810ae6ca94eadce4da5659f2a4768aae7acdd70c14850",
    );
    try expectDensityHash(
        end,
        7,
        4,
        "5ff074ddad88b7fcb4339cb7a3e68341061792869e43673b2de8525a75476bd8",
    );
}

test "Nether surface volume matches Vanilla references" {
    try expectNetherSurfaceHash(
        0,
        0,
        "9b95451a15c005c0ee93f889ed2b04ad68c565cf24c455de0a4b352a7347d0c1",
    );
    try expectNetherSurfaceHash(
        7,
        4,
        "9c331daca32750dab41cf874f51e7a3322ce7f044af5b478e65e76e845d5f724",
    );
}

test "Nether carvers match Vanilla block counts" {
    var generator = try nether.Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(base_dimension.Block, nether.block_count);
    defer std.testing.allocator.free(blocks);
    try generator.generate(7, 4, blocks);
    var bedrock: usize = 0;
    var netherrack: usize = 0;
    var lava: usize = 0;
    var cave_air: usize = 0;
    var crimson_nylium: usize = 0;
    for (blocks) |block| {
        const name = nether.canonicalName(block);
        if (std.mem.eql(u8, name, "minecraft:bedrock")) bedrock += 1;
        if (std.mem.eql(u8, name, "minecraft:netherrack")) netherrack += 1;
        if (std.mem.eql(u8, name, "minecraft:lava[level=0]")) lava += 1;
        if (std.mem.eql(u8, name, "minecraft:cave_air")) cave_air += 1;
        if (std.mem.eql(u8, name, "minecraft:crimson_nylium")) crimson_nylium += 1;
    }
    try std.testing.expectEqual(@as(usize, 1_523), bedrock);
    try std.testing.expectEqual(@as(usize, 21_766), netherrack);
    try std.testing.expectEqual(@as(usize, 5_954), lava);
    try std.testing.expectEqual(@as(usize, 2_472), cave_air);
    try std.testing.expectEqual(@as(usize, 3), crimson_nylium);
}

fn expectNetherSurfaceHash(
    chunk_x: i32,
    chunk_z: i32,
    comptime expected_hex: []const u8,
) !void {
    var generator = try nether.Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(base_dimension.Block, nether.block_count);
    defer std.testing.allocator.free(blocks);
    try generator.generateSurface(chunk_x, chunk_z, blocks);
    var categories: [16 * 16 * nether.terrain_height]u8 = undefined;
    var cursor: usize = 0;
    for (0..16) |x| for (0..nether.terrain_height) |y| for (0..16) |z| {
        const block = blocks[nether.blockIndex(x, y, z)];
        const name = nether.canonicalName(block);
        categories[cursor] = if (std.mem.eql(u8, name, "minecraft:netherrack"))
            'N'
        else if (std.mem.eql(u8, name, "minecraft:bedrock"))
            'B'
        else if (std.mem.eql(u8, name, "minecraft:crimson_nylium"))
            'C'
        else if (std.mem.eql(u8, name, "minecraft:lava[level=0]"))
            'F'
        else
            'A';
        cursor += 1;
    };
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&categories, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch unreachable;
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

fn expectDensityHash(
    comptime dimension: type,
    chunk_x: i32,
    chunk_z: i32,
    comptime expected_hex: []const u8,
) !void {
    var generator = try dimension.Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(base_dimension.Block, dimension.block_count);
    defer std.testing.allocator.free(blocks);
    try generator.generateDensity(chunk_x, chunk_z, blocks);
    var categories: [16 * 16 * dimension.terrain_height]u8 = undefined;
    var cursor: usize = 0;
    for (0..16) |x| for (0..dimension.terrain_height) |y| for (0..16) |z| {
        categories[cursor] = switch (blocks[dimension.blockIndex(x, y, z)]) {
            .solid => 'S',
            .fluid => 'F',
            .air, .cave_air => 'A',
            .surface => unreachable,
            .feature => unreachable,
        };
        cursor += 1;
    };
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&categories, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch unreachable;
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

comptime {
    std.debug.assert(std.mem.eql(u8, minecraft_version, minecraft.minecraft_version));
}
