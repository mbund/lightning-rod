const std = @import("std");
const registry = @import("registry_data");
const terrain = @import("../terrain.zig");
const blocks = @import("../world/blocks.zig");
const generator_api = @import("../world/generator_api.zig");
const geometry = @import("../world/geometry.zig");
const identity = @import("../world/identity.zig");

pub const Mode = enum { overworld, flat, void };

pub const block_configuration = blocks.Blocks.Configuration{
    .maximum_transient_chunks = 16,
    .maximum_modified_sections = 64,
    .maximum_block_mutations = 256,
};

pub const Generator = struct {
    storage: [terrain.chunk_storage_capacity]u8 = undefined,
    mode: Mode = .overworld,

    pub fn init(self: *Generator, allocator: std.mem.Allocator, seed: u64) !void {
        _ = allocator;
        _ = seed;
        self.* = .{};
    }

    pub fn bind(self: *Generator, target: *blocks.Blocks) void {
        target.bindGenerator(self.service());
    }

    pub fn service(self: *Generator) generator_api.Service {
        return .{
            .context = self,
            .generate_fn = generate,
            .request_fn = request,
            .pending_fn = pending,
            .capacity_fn = pending,
            .metrics_fn = metrics,
        };
    }

    fn request(_: *anyopaque, _: identity.Handle, _: geometry.ChunkPos, _: generator_api.Priority) bool {
        return false;
    }

    fn pending(_: *const anyopaque) usize {
        return 0;
    }

    fn metrics(_: *const anyopaque) generator_api.Metrics {
        return .{ .calls = 0, .nanoseconds = 0, .maximum_nanoseconds = 0, .emitted = 0, .installed = 0, .materialization_nanoseconds = 0 };
    }

    fn generate(
        context: *anyopaque,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) anyerror!terrain.ChunkShape {
        _ = world;
        const self: *Generator = @ptrCast(@alignCast(context));
        return switch (self.mode) {
            .overworld, .flat => terrain.buildFlatChunkShape(
                &self.storage,
                chunk.x,
                chunk.z,
                64,
                registry.block_grass_block_default_state,
                registry.block_stone_default_state,
            ),
            .void => terrain.buildVoidChunkShape(&self.storage, chunk.x, chunk.z),
        };
    }
};

pub fn createBlocks(
    generator: *Generator,
    allocator: std.mem.Allocator,
    seed: u64,
) !*blocks.Blocks {
    const target = try blocks.Blocks.init(allocator, block_configuration);
    try generator.init(allocator, seed);
    generator.bind(target);
    return target;
}
