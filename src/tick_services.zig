const std = @import("std");
const commands = @import("commands.zig");
const config = @import("config.zig").value;
const hot_reload_abi = @import("hot_reload_abi.zig");
const packet_writer = @import("packet_writer.zig");
const player_lifecycle = @import("player_lifecycle.zig");
const plugin_profiler = @import("plugin_profiler.zig");
const preallocated = @import("preallocated");
const tick_host = @import("tick_host.zig");
const tick_io = @import("tick_io.zig");

pub const Services = struct {
    packets: *packet_writer.Packets,
    io: *tick_io.TickIo,
    lifecycle: *player_lifecycle.Events,

    pub fn create(
        allocator: std.mem.Allocator,
        storage_mode: hot_reload_abi.StorageMode,
        io_configuration: tick_io.Configuration,
    ) !*Services {
        const self = try preallocated.create(Services, allocator);
        const packets = try preallocated.create(packet_writer.Packets, allocator);
        const io = switch (storage_mode) {
            .disk => try tick_io.TickIo.create(allocator, io_configuration),
            .memory => try tick_io.TickIo.createMemory(allocator, io_configuration),
        };
        const lifecycle = try preallocated.create(player_lifecycle.Events, allocator);
        packets.* = undefined;
        lifecycle.* = .{};
        self.* = .{
            .packets = packets,
            .io = io,
            .lifecycle = lifecycle,
        };
        return self;
    }

    pub fn begin(
        self: *Services,
        host: *tick_host.Host,
        declarations: []const commands.Declaration,
        joined: player_lifecycle.JoinedBatch,
        left: player_lifecycle.LeftBatch,
        play_started: []const player_lifecycle.PlayStarted,
    ) !void {
        self.packets.* = packet_writer.Packets.initWithCommands(host, declarations);
        try self.io.begin();
        self.lifecycle.begin(joined, left, play_started);
    }

    pub fn finish(self: *Services) !void {
        try self.io.finish();
    }

    pub fn deinit(self: *Services) void {
        self.io.deinit();
    }
};

pub const Arena = struct {
    bytes: []u8,
    fixed: std.heap.FixedBufferAllocator,
    accounted_end: usize = 0,

    pub fn create(allocator: std.mem.Allocator) !*Arena {
        const self = try preallocated.create(Arena, allocator);
        const bytes = try preallocated.alloc(u8, allocator, config.tick_input_arena_bytes);
        self.* = .{ .bytes = bytes, .fixed = std.heap.FixedBufferAllocator.init(bytes) };
        return self;
    }

    pub fn begin(self: *Arena) std.mem.Allocator {
        self.fixed.reset();
        self.accounted_end = 0;
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn finish(self: *Arena) void {
        self.fixed.reset();
        self.accounted_end = 0;
    }

    fn account(self: *Arena) void {
        if (self.fixed.end_index <= self.accounted_end) return;
        plugin_profiler.recordTickMemory(self.fixed.end_index - self.accounted_end);
        self.accounted_end = self.fixed.end_index;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.alloc(&self.fixed, len, alignment, return_address);
        if (result != null) self.account();
        return result;
    }

    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) bool {
        const self: *Arena = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.resize(&self.fixed, bytes, alignment, len, return_address);
        if (result) self.account();
        return result;
    }

    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.remap(&self.fixed, bytes, alignment, len, return_address);
        if (result != null) self.account();
        return result;
    }

    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Arena = @ptrCast(@alignCast(context));
        std.heap.FixedBufferAllocator.free(&self.fixed, bytes, alignment, return_address);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};
