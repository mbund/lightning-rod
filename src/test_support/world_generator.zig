const std = @import("std");
const registry = @import("registry_data");
const terrain = @import("../terrain.zig");
const blocks = @import("../world/blocks.zig");
const generator_api = @import("../world/generator_api.zig");
const geometry = @import("../world/geometry.zig");
const identity = @import("../world/identity.zig");

pub const Mode = enum { overworld, flat, staged_flat, early_flat, void };

pub const block_configuration = blocks.Blocks.Configuration{
    .maximum_resident_chunks = 16,
    .maximum_modified_sections = 64,
    .maximum_block_mutations = 256,
};

pub const Generator = struct {
    storage: [terrain.chunk_storage_capacity]u8 = undefined,
    mode: Mode = .overworld,
    staged_chunk: ?geometry.ChunkPos = null,

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
            .overworld, .flat, .staged_flat, .early_flat => terrain.buildFlatChunkShape(
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

    fn advance(
        context: *anyopaque,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
        sink: generator_api.Sink,
    ) anyerror!generator_api.Advance {
        const self: *Generator = @ptrCast(@alignCast(context));
        switch (self.mode) {
            .overworld, .flat, .void => {
                try sink.emit(try generate(context, world, chunk));
                return .complete;
            },
            .staged_flat => {
                if (self.staged_chunk == null) {
                    self.staged_chunk = chunk;
                    return .pending;
                }
                std.debug.assert(std.meta.eql(self.staged_chunk.?, chunk));
                self.staged_chunk = null;
                try sink.emit(try generate(context, world, chunk));
                return .complete;
            },
            .early_flat => {
                if (self.staged_chunk == null) {
                    self.staged_chunk = chunk;
                    try sink.emit(try generate(context, world, chunk));
                    return .pending;
                }
                std.debug.assert(std.meta.eql(self.staged_chunk.?, chunk));
                self.staged_chunk = null;
                return .complete;
            },
        }
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
