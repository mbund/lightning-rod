const geometry = @import("geometry.zig");
const identity = @import("identity.zig");
const terrain = @import("../terrain.zig");

pub const Advance = enum { pending, complete };

pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, terrain.ChunkShape) anyerror!void,

    pub fn emit(self: Sink, shape: terrain.ChunkShape) !void {
        try self.emit_fn(self.context, shape);
    }
};

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
        sink: Sink,
    ) anyerror!Advance,

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
        sink: Sink,
    ) !Advance {
        return self.advance_fn(self.context, world, chunk, sink);
    }
};
