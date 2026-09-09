const geometry = @import("geometry.zig");
const identity = @import("identity.zig");
const terrain = @import("../terrain.zig");

pub const Priority = enum { simulation, streaming };

pub const Metrics = struct {
    calls: u64,
    nanoseconds: u64,
    maximum_nanoseconds: u64,
    emitted: u64,
    installed: u64,
    materialization_nanoseconds: u64,
};

pub const Service = struct {
    context: *anyopaque,
    generate_fn: *const fn (
        context: *anyopaque,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) anyerror!terrain.ChunkShape,
    request_fn: *const fn (*anyopaque, identity.Handle, geometry.ChunkPos, Priority) bool,
    pending_fn: *const fn (*const anyopaque) usize,
    capacity_fn: *const fn (*const anyopaque) usize,
    metrics_fn: *const fn (*const anyopaque) Metrics,

    pub fn generate(
        self: Service,
        world: identity.Handle,
        chunk: geometry.ChunkPos,
    ) !terrain.ChunkShape {
        return self.generate_fn(self.context, world, chunk);
    }

    pub fn request(self: Service, world: identity.Handle, chunk: geometry.ChunkPos, priority: Priority) bool {
        return self.request_fn(self.context, world, chunk, priority);
    }

    pub fn pending(self: Service) usize {
        return self.pending_fn(self.context);
    }

    pub fn capacity(self: Service) usize {
        return self.capacity_fn(self.context);
    }

    pub fn metrics(self: Service) Metrics {
        return self.metrics_fn(self.context);
    }
};
