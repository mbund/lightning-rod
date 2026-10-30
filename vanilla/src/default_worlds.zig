const RegistryIdentity = @import("registry_identity.zig").RegistryIdentity;
const std = @import("std");
const Worlds = @import("worlds").Worlds;
const Dimensions = @import("dimensions.zig").Dimensions;

pub const VanillaWorlds = struct {
    pub const id = "minecraft:vanilla_worlds";

    pub const Configuration = struct {};

    pub const Dependencies = struct { registry_identity: *RegistryIdentity, worlds: *Worlds, dimensions: *Dimensions };

    deps: Dependencies,
    overworld: u32,
    nether: u32,
    end: u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*VanillaWorlds {
        const self = try allocator.create(VanillaWorlds);
        self.* = .{
            .deps = deps,
            .overworld = try findOrCreate(deps, "minecraft:overworld"),
            .nether = try findOrCreate(deps, "minecraft:the_nether"),
            .end = try findOrCreate(deps, "minecraft:the_end"),
        };
        try deps.dimensions.registry.onChange(self, definitionsChanged);
        try deps.dimensions.registry.checkWith(self, validate);
        return self;
    }

    fn findOrCreate(deps: Dependencies, name: []const u8) !u32 {
        if (deps.worlds.find(name)) |world| return world.id;
        return deps.worlds.create(.{ .name = name, .dimension = try deps.dimensions.dimension(name) });
    }

    fn definitionsChanged(self: *VanillaWorlds) !void {
        const worlds = self.deps.worlds;
        const dimensions = self.deps.dimensions;
        for (worlds.entries[worlds.checkpointed..worlds.count]) |*world| {
            const dimension = dimensions.dimension(world.dimension.name) catch |err| switch (err) {
                error.UnknownDimension => continue,
            };
            world.dimension.minimum_section = dimension.minimum_section;
            world.dimension.section_count = dimension.section_count;
            world.dimension.skylight = dimension.skylight;
        }
    }

    fn validate(self: *VanillaWorlds) !void {
        const worlds = self.deps.worlds;
        const dimensions = self.deps.dimensions;
        for (worlds.all()) |world| {
            const dimension = dimensions.dimension(world.dimension.name) catch |err| switch (err) {
                error.UnknownDimension => continue,
            };
            if (!world.dimension.eql(dimension)) return error.DimensionIdentityChanged;
        }
    }
};
