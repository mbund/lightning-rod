const std = @import("std");
const Worlds = @import("worlds").Worlds;

pub const VanillaWorlds = struct {
    pub const id = "minecraft:vanilla_worlds";

    pub const Configuration = struct {};

    pub const Dependencies = struct { worlds: *Worlds };

    overworld: u32,
    nether: u32,
    end: u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*VanillaWorlds {
        const self = try allocator.create(VanillaWorlds);
        self.* = .{
            .overworld = try deps.worlds.create(.{ .name = "minecraft:overworld", .dimension = .overworld }),
            .nether = try deps.worlds.create(.{ .name = "minecraft:the_nether", .dimension = .nether }),
            .end = try deps.worlds.create(.{ .name = "minecraft:the_end", .dimension = .end }),
        };
        return self;
    }
};
