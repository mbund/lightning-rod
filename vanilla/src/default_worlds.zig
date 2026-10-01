const std = @import("std");
const Worlds = @import("worlds").Worlds;

pub const VanillaWorlds = struct {
    pub const id = "minecraft:vanilla_worlds";

    pub const Configuration = struct {};

    pub const Dependencies = struct { worlds: *Worlds };

    pub const dimensions = struct {
        pub const overworld: Worlds.Dimension = .{ .name = "minecraft:overworld", .minimum_section = -4, .section_count = 24, .skylight = true };
        pub const nether: Worlds.Dimension = .{ .name = "minecraft:the_nether", .minimum_section = 0, .section_count = 16 };
        pub const end: Worlds.Dimension = .{ .name = "minecraft:the_end", .minimum_section = 0, .section_count = 16 };
    };

    overworld: u32,
    nether: u32,
    end: u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*VanillaWorlds {
        const self = try allocator.create(VanillaWorlds);
        self.* = .{
            .overworld = try deps.worlds.create(.{ .name = "minecraft:overworld", .dimension = dimensions.overworld }),
            .nether = try deps.worlds.create(.{ .name = "minecraft:the_nether", .dimension = dimensions.nether }),
            .end = try deps.worlds.create(.{ .name = "minecraft:the_end", .dimension = dimensions.end }),
        };
        return self;
    }
};
