const std = @import("std");
const builtin = @import("builtin");

pub const Allocator = struct {
    storage: std.heap.FixedBufferAllocator,
    sealed: bool = false,
    owner: ?usize = null,
    owner_start: usize = 0,
    plugin_bytes: []u64 = &.{},

    pub fn init(bytes: []u8) Allocator {
        return .{ .storage = std.heap.FixedBufferAllocator.init(bytes) };
    }

    pub fn allocator(self: *Allocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn seal(self: *Allocator) void {
        std.debug.assert(!self.sealed);
        self.sealed = true;
    }

    pub fn used(self: *const Allocator) usize {
        return self.storage.end_index;
    }

    pub fn trackPlugins(self: *Allocator, plugin_bytes: []u64) void {
        self.requireOpen();
        std.debug.assert(self.owner == null);
        self.plugin_bytes = plugin_bytes;
        @memset(plugin_bytes, 0);
    }

    pub fn beginPlugin(self: *Allocator, index: usize) void {
        self.requireOpen();
        std.debug.assert(self.owner == null);
        std.debug.assert(index < self.plugin_bytes.len);
        self.owner = index;
        self.owner_start = self.storage.end_index;
    }

    pub fn endPlugin(self: *Allocator) void {
        const index = self.owner orelse unreachable;
        std.debug.assert(self.storage.end_index >= self.owner_start);
        self.plugin_bytes[index] = @intCast(self.storage.end_index - self.owner_start);
        self.owner = null;
        self.owner_start = 0;
    }

    fn requireOpen(self: *const Allocator) void {
        if (self.sealed)
            @panic("plugin used its generation allocator after initialization completed");
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(context));
        self.requireOpen();
        return std.heap.FixedBufferAllocator.alloc(&self.storage, len, alignment, return_address);
    }

    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) bool {
        const self: *Allocator = @ptrCast(@alignCast(context));
        self.requireOpen();
        return std.heap.FixedBufferAllocator.resize(&self.storage, bytes, alignment, len, return_address);
    }

    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(context));
        self.requireOpen();
        return std.heap.FixedBufferAllocator.remap(&self.storage, bytes, alignment, len, return_address);
    }

    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Allocator = @ptrCast(@alignCast(context));
        self.requireOpen();
        std.heap.FixedBufferAllocator.free(&self.storage, bytes, alignment, return_address);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "generation allocator rejects retained use after initialization" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bytes: [64]u8 = undefined;
    var generation = Allocator.init(&bytes);
    const allocator = generation.allocator();
    _ = try allocator.alloc(u8, 1);
    generation.seal();

    const fork_result = std.posix.system.fork();
    switch (std.posix.errno(fork_result)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    if (fork_result == 0) {
        _ = allocator.alloc(u8, 1) catch std.posix.system.exit(1);
        std.posix.system.exit(0);
    }

    var status: c_int = undefined;
    var waited = false;
    for (0..1024) |_| switch (std.posix.errno(
        std.posix.system.waitpid(@intCast(fork_result), &status, 0),
    )) {
        .SUCCESS => {
            waited = true;
            break;
        },
        .INTR => continue,
        else => |err| return std.posix.unexpectedErrno(err),
    };
    try std.testing.expect(waited);
    try std.testing.expect(std.posix.W.IFSIGNALED(@bitCast(status)));
}

test "generation allocator attributes aligned reservations to their plugin" {
    var bytes: [256]u8 = undefined;
    var plugin_bytes = [_]u64{ 0, 0 };
    var generation = Allocator.init(&bytes);
    generation.trackPlugins(&plugin_bytes);
    generation.beginPlugin(1);
    _ = try generation.allocator().alignedAlloc(u8, .@"64", 65);
    generation.endPlugin();
    try std.testing.expectEqual(@as(u64, generation.used()), plugin_bytes[1]);
    try std.testing.expectEqual(@as(u64, 0), plugin_bytes[0]);
}
