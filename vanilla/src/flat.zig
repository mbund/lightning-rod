const std = @import("std");
const worlds = @import("worlds");
const chunks = @import("chunks");
const registry = @import("protocols").registry;

pub const Flat = struct {
    pub const id = "minecraft:world_source";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        chunks: *chunks.Chunks,
        worlds: *worlds.Worlds,
    };

    deps: Dependencies,
    generated_sections: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Flat {
        const self = try allocator.create(Flat);
        self.* = .{ .deps = deps };
        std.debug.assert(deps.chunks.source == null);
        deps.chunks.source = .{ .context = self, .read = read };
        return self;
    }

    fn read(context: *anyopaque, section: chunks.Section, output: []u8) !usize {
        const self: *Flat = @ptrCast(@alignCast(context));
        const world = self.deps.worlds.get(section.world) orelse return error.UnknownWorld;

        if (self.generated_sections == 0) std.log.info("event=terrain_generation_started", .{});
        self.generated_sections += 1;
        std.debug.assert(output.len >= 8193);
        if (section.y == 4) {
            output[0] = 1;

            for (0..4096) |i| std.mem.writeInt(u16, output[1 + i * 2 ..][0..2], if (i < 256) registry.block_grass_block_default_state else 0, .little);
            return 8193;
        }

        output[0] = 0;
        std.mem.writeInt(u16, output[1..3], if (section.y >= world.dimension.minimumSection() and section.y < 4) registry.block_stone_default_state else 0, .little);
        return 3;
    }
};
