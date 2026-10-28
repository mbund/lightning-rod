const std = @import("std");
const chunks = @import("chunks");
const Streaming = @import("streaming.zig").Streaming;
const BlockSynchronization = @import("block_sync.zig").BlockSynchronization;

pub const Terrain = struct {
    chunks: *chunks.Chunks,
    streaming: *Streaming,
    blocks: *BlockSynchronization,
    io: std.Io,

    pub fn start(self: *Terrain) void {
        self.chunks.attach();
        self.chunks.ready().set(self.io);
    }

    pub fn poll(self: *Terrain) !void {
        if (!self.chunks.generation.parallel.load(.acquire)) _ = try self.chunks.generation.processOne(self.io);
        try self.chunks.poll();
        _ = try self.streaming.poll(self.io);
        _ = try self.blocks.poll(self.io);
        _ = try self.streaming.pollLight();
    }

    pub fn stop(self: *Terrain) void {
        self.chunks.stop();
    }
};

pub const ThreadedTerrain = struct {
    terrain: Terrain,
    io: std.Io,
    thread: ?std.Thread = null,
    mode: std.atomic.Value(enum(u8) { active, paused, stopped }) = .init(.active),
    initialized: std.Io.Event = .unset,
    parked: std.Io.Event = .unset,
    resumed: std.Io.Event = .unset,
    failure: ?anyerror = null,

    pub fn start(self: *ThreadedTerrain) !void {
        self.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, execute, .{self});
        self.initialized.waitUncancelable(self.io);
    }

    fn execute(self: *ThreadedTerrain) void {
        self.terrain.start();
        self.initialized.set(self.io);
        while (self.mode.load(.acquire) != .stopped) {
            if (self.mode.load(.acquire) == .paused) {
                self.terrain.stop();
                self.parked.set(self.io);
                self.resumed.waitUncancelable(self.io);
                self.resumed.reset();
                if (self.mode.load(.acquire) == .stopped) return;
                self.terrain.start();
                self.initialized.set(self.io);
            }
            self.terrain.chunks.ready().waitUncancelable(self.io);
            self.terrain.chunks.ready().reset();
            self.terrain.poll() catch |err| {
                std.log.err("event=terrain_failed reason={t}", .{err});
                self.failure = err;
                self.terrain.stop();
                self.parked.set(self.io);
                return;
            };
        }
        self.terrain.stop();
    }

    pub fn check(self: *ThreadedTerrain) !void {
        if (self.parked.isSet()) if (self.failure) |err| return err;
    }

    pub fn pause(self: *ThreadedTerrain, deadline: std.Io.Clock.Timestamp) !void {
        self.mode.store(.paused, .release);
        self.terrain.chunks.ready().set(self.io);
        try self.parked.waitTimeout(self.io, .{ .deadline = deadline });
        try self.check();
    }

    pub fn resumeReload(self: *ThreadedTerrain) void {
        self.initialized.reset();
        self.parked.reset();
        self.mode.store(.active, .release);
        self.resumed.set(self.io);
        self.initialized.waitUncancelable(self.io);
    }

    pub fn stop(self: *ThreadedTerrain) void {
        if (self.thread) |thread| {
            self.mode.store(.stopped, .release);
            self.terrain.chunks.ready().set(self.io);
            self.resumed.set(self.io);
            thread.join();
            self.thread = null;
        }
    }
};
