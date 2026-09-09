const std = @import("std");
const lightning_rod = @import("lightning_rod");
const local_packs = @import("local_packs.zig");

const persistence = lightning_rod.persistence;
const record_count = 256;
const value_bytes = 64 * 1024;
const Driver = local_packs.Driver(.{
    .maximum_in_flight_reads = record_count,
    .maximum_packs = 8,
    .maximum_path_bytes = 256,
});
const configuration: persistence.Configuration = .{
    .maximum_keys = record_count,
    .maximum_checkpoint_records = record_count,
    .maximum_requests = record_count,
    .maximum_namespace_bytes = 8,
    .maximum_key_bytes = 8,
    .maximum_value_bytes = value_bytes,
    .maximum_checkpoint_bytes = record_count * (value_bytes + 64),
};

pub fn main(_: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    const store = try persistence.Store.initIndex(allocator, configuration);
    const reservation = try Driver.reservation(configuration);
    const recovery = try allocator.alloc(u8, reservation.recovery_bytes);
    var path_storage: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/lightning-rod-persistence-{d}.root", .{std.os.linux.getpid()});
    cleanup(io, path);
    defer cleanup(io, path);
    var driver: Driver = undefined;
    try driver.init(io, path, store, recovery);
    defer driver.deinit();
    const backend = driver.interface();
    const value = try allocator.alloc(u8, value_bytes);
    for (value, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% index / 17);
    var keys: [record_count][8]u8 = undefined;
    for (&keys, 0..) |*key, index| {
        _ = try std.fmt.bufPrint(key, "{d:0>8}", .{index});
        if (store.stage(.{ .namespace = "chunks", .key = key, .operation = .{ .put = value } }) != .ready)
            return error.StageFailed;
    }
    if (store.requestCheckpoint() != .pending) return error.CheckpointFailed;
    while (store.checkpointProgress() != .ready) {
        if (backend.submit(io) == .failed) return error.PersistenceFailed;
        const completion = backend.complete(io, record_count + 16);
        if (completion.outcome == .failed) return error.PersistenceFailed;
        if (completion.count == 0) std.Thread.yield() catch {};
    }
    const destinations = try allocator.alloc([value_bytes]u8, record_count);
    var requests: [record_count]persistence.Request = undefined;
    for (&keys, destinations, &requests) |*key, *destination, *request| {
        request.* = store.read("chunks", key, destination);
        if (request.* == persistence.no_request) return error.ReadAdmissionFailed;
    }
    const started = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    var completed: usize = 0;
    while (completed != record_count) {
        if (backend.submit(io) == .failed) return error.PersistenceFailed;
        const completion = backend.complete(io, record_count + 16);
        if (completion.outcome == .failed) return error.PersistenceFailed;
        completed = 0;
        for (requests) |request| switch (store.pollRead(request).status) {
            .ready => completed += 1,
            .pending => {},
            else => return error.ReadFailed,
        };
        if (completion.count == 0) std.Thread.yield() catch {};
    }
    const elapsed: u64 = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - started);
    const bytes = record_count * value_bytes;
    std.debug.print(
        "local persistence records={d} bytes={d} elapsed_ms={d:.3} throughput_mib_s={d:.1}\n",
        .{ record_count, bytes, @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms, @as(f64, @floatFromInt(bytes)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed)) / (1024 * 1024) },
    );
}

fn cleanup(io: std.Io, root: []const u8) void {
    var storage: [320]u8 = undefined;
    for ([_][]const u8{ "", ".lock", ".next", ".pack.1", ".pack.1.next" }) |suffix| {
        const path = std.fmt.bufPrint(&storage, "{s}{s}", .{ root, suffix }) catch continue;
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }
}
