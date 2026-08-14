const geometry = @import("geometry.zig");
const identity = @import("identity.zig");
const terrain = @import("../terrain.zig");

pub const Service = struct {
    context: *anyopaque,
    generate_fn: *const fn (
        context: *anyopaque,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) anyerror!terrain.ChunkShape,
    advance_fn: *const fn (
        context: *anyopaque,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) anyerror!?terrain.ChunkShape,

    pub fn generate(
        self: Service,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) !terrain.ChunkShape {
        return self.generate_fn(self.context, world, chunk);
    }

    pub fn advance(
        self: Service,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) !?terrain.ChunkShape {
        return self.advance_fn(self.context, world, chunk);
    }
};
