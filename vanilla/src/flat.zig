const game_data = @import("game_data");
const RegistryIdentity = @import("registry_identity.zig").RegistryIdentity;
const std = @import("std");
const worlds = @import("worlds");
const chunks = @import("chunks");
const Spawn = @import("spawn.zig").Spawn;

pub const Flat = struct {
    pub const id = "minecraft:world_source";

    pub const Configuration = struct {
        biomes: ?*const fn (chunks.Section, *[64]u16) void = null,
    };

    pub const Dependencies = struct {
        registry_identity: *RegistryIdentity,
        chunks: *chunks.Chunks,
        worlds: *worlds.Worlds,
        spawn: ?*Spawn = null,
    };

    deps: Dependencies,
    config: Configuration,
    generated_sections: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Flat {
        const self = try allocator.create(Flat);
        self.* = .{ .deps = deps, .config = config };
        deps.chunks.setSource(chunks.Source.init(self, read));
        if (deps.spawn) |spawn| if (deps.worlds.find("minecraft:overworld")) |world| {
            _ = try spawn.get(world.id);
        };
        return self;
    }

    fn read(self: *Flat, io: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| request.result = self.readOne(io, request.section, request.output);
    }

    fn readOne(self: *Flat, _: std.Io, section: chunks.Section, output: []u8) !usize {
        const world = self.deps.worlds.get(section.world) orelse return error.UnknownWorld;

        if (self.generated_sections.fetchAdd(1, .monotonic) == 0) std.log.info("event=terrain_generation_started", .{});
        std.debug.assert(output.len >= chunks.encoding.maximum_decoded_bytes);
        output[0] = 3;
        var biomes: [64]u16 = @splat(@intCast(game_data.registry.biomeId("minecraft:plains").?));
        if (self.config.biomes) |fill| fill(section, &biomes);
        for (biomes, 0..) |biome, index| std.mem.writeInt(u16, output[1 + index * 2 ..][0..2], biome, .little);
        const blocks = output[chunks.encoding.biome_header_bytes..];
        if (section.y == 4) {
            blocks[0] = 1;

            for (0..4096) |i| std.mem.writeInt(u16, blocks[1 + i * 2 ..][0..2], if (i < 256) game_data.registry.block_grass_block_default_state else 0, .little);
            return chunks.encoding.maximum_decoded_bytes;
        }

        blocks[0] = 0;
        std.mem.writeInt(u16, blocks[1..3], if (section.y >= world.dimension.minimumSection() and section.y < 4) game_data.registry.block_stone_default_state else 0, .little);
        return chunks.encoding.biome_header_bytes + 3;
    }
};
