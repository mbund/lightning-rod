const std = @import("std");
const PluginAllocator = @import("plugin_allocator.zig").PluginAllocator;

test "plugin allocations preserve alignment ownership and the reservation limit" {
    var permanent = PluginAllocator.init(std.testing.allocator, 1024);
    defer permanent.deinit();
    var assigned: [2]u64 = undefined;
    permanent.trackPlugins(&assigned);
    permanent.beginPlugin(0);
    const first = try permanent.allocator().alignedAlloc(u8, .fromByteUnits(128), 128);
    @memset(first, 11);
    try std.testing.expect(@intFromPtr(first.ptr) % 128 == 0);
    try std.testing.expect(permanent.ownsCurrentPluginAllocation(first.ptr));
    try std.testing.expectError(error.OutOfMemory, permanent.allocator().alloc(u8, 1024));
    permanent.endPlugin();
    permanent.beginPlugin(1);
    const second = try permanent.allocator().create(u64);
    second.* = 22;
    try std.testing.expect(!permanent.ownsCurrentPluginAllocation(first.ptr));
    try std.testing.expect(permanent.ownsCurrentPluginAllocation(second));
    var foreign: u64 = 0;
    try std.testing.expect(!permanent.ownsCurrentPluginAllocation(&foreign));
    permanent.endPlugin();
    try std.testing.expectEqual(permanent.used(), assigned[0] + assigned[1]);
    permanent.seal();
    try std.testing.expectEqual(@as(u8, 11), first[0]);
    try std.testing.expectEqual(@as(u64, 22), second.*);
}

test "initialization frees and resizes retain their reservation until teardown" {
    var permanent = PluginAllocator.init(std.testing.allocator, 1024);
    defer permanent.deinit();
    const allocator = permanent.allocator();
    const bytes = try allocator.alloc(u8, 128);
    const reserved = permanent.used();
    try std.testing.expect(allocator.resize(bytes, 64));
    const smaller: []u8 = bytes[0..64];
    try std.testing.expect(allocator.resize(smaller, 128));
    allocator.free(bytes);
    try std.testing.expect(!permanent.owns(bytes.ptr));
    try std.testing.expectEqual(reserved, permanent.used());
    const next = try allocator.alloc(u8, 128);
    try std.testing.expect(next.ptr != bytes.ptr);
}

test "partial plugin initialization releases every backing allocation" {
    const Initialization = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var permanent = PluginAllocator.init(allocator, 2048);
            defer permanent.deinit();
            for (0..4) |_| _ = try permanent.allocator().alloc(u8, 128);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Initialization.run, .{});
}
