const std = @import("std");
const registry = @import("registry_data");
const terrain = @import("../terrain.zig");
const blocks = @import("../world/blocks.zig");
const generator_api = @import("../world/generator_api.zig");
const geometry = @import("../world/geometry.zig");
const identity = @import("../world/identity.zig");

pub const Mode = enum { overworld, flat, void };

pub const Generator = struct {
    terrain: terrain.Generator = undefined,
    mode: Mode = .overworld,

    pub fn init(self: *Generator, allocator: std.mem.Allocator, seed: u64) !void {
        self.* = .{ .terrain = try terrain.Generator.init(allocator, seed, 128) };
    }

    pub fn bind(self: *Generator, target: *blocks.Blocks) void {
        target.bindGenerator(self.service());
    }

    pub fn service(self: *Generator) generator_api.Service {
        return .{
            .context = self,
            .generate_fn = generate,
            .advance_fn = advance,
        };
    }

    fn generate(
        context: *anyopaque,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) anyerror!terrain.ChunkShape {
        _ = world;
        const self: *Generator = @ptrCast(@alignCast(context));
        return switch (self.mode) {
            .overworld => self.terrain.generate(chunk.x, chunk.z),
            .flat => self.terrain.generateFlat(
                chunk.x,
                chunk.z,
                64,
                registry.block_grass_block_default_state,
                registry.block_stone_default_state,
            ),
            .void => self.terrain.generateVoid(chunk.x, chunk.z),
        };
    }

    fn advance(
        context: *anyopaque,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) anyerror!?terrain.ChunkShape {
        const self: *Generator = @ptrCast(@alignCast(context));
        return switch (self.mode) {
            .overworld => self.terrain.advance(chunk.x, chunk.z),
            .flat, .void => try generate(context, world, chunk),
        };
    }
};

pub fn createBlocks(
    generator: *Generator,
    allocator: std.mem.Allocator,
    seed: u64,
) !*blocks.Blocks {
    const target = try blocks.Blocks.create(allocator, .{});
    try generator.init(allocator, seed);
    generator.bind(target);
    return target;
}
