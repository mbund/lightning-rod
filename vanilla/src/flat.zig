const game_data = @import("game_data");
const RegistryIdentity = @import("registry_identity.zig").RegistryIdentity;
const std = @import("std");
const worlds = @import("worlds");
const chunks = @import("chunks");

pub const Flat = struct {
    pub const id = "minecraft:world_source";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        registry_identity: *RegistryIdentity,
        chunks: *chunks.Chunks,
        worlds: *worlds.Worlds,
    };

    deps: Dependencies,
    generated_sections: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Flat {
        const self = try allocator.create(Flat);
        self.* = .{ .deps = deps };
        deps.chunks.setSource(chunks.Source.init(self, read));
        return self;
    }

    fn read(self: *Flat, io: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| request.result = self.readOne(io, request.section, request.output);
    }

    fn readOne(self: *Flat, _: std.Io, section: chunks.Section, output: []u8) !usize {
        const world = self.deps.worlds.get(section.world) orelse return error.UnknownWorld;

        if (self.generated_sections.fetchAdd(1, .monotonic) == 0) std.log.info("event=terrain_generation_started", .{});
        std.debug.assert(output.len >= 8193);
        if (section.y == 4) {
            output[0] = 1;

            for (0..4096) |i| std.mem.writeInt(u16, output[1 + i * 2 ..][0..2], if (i < 256) game_data.registry.block_grass_block_default_state else 0, .little);
            return 8193;
        }

        output[0] = 0;
        std.mem.writeInt(u16, output[1..3], if (section.y >= world.dimension.minimumSection() and section.y < 4) game_data.registry.block_stone_default_state else 0, .little);
        return 3;
    }
};
