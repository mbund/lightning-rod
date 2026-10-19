const std = @import("std");
const storage = @import("storage");

pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > limit) return error.FileTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.TruncatedFile;
    return bytes;
}

pub fn removeDatabase(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    for ([_][]const u8{ "", ".wal", ".wal.next" }) |suffix| {
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, suffix });
        defer allocator.free(name);
        std.Io.Dir.cwd().deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

pub fn drain(store: *storage.Store) !void {
    const threshold = store.limits.checkpoint_bytes;
    store.limits.checkpoint_bytes = 64;
    defer store.limits.checkpoint_bytes = threshold;
    try store.waitDurable(store.lastCommit());
    while (store.end != 64 or store.phase != .idle) {
        _ = try store.maintain(storage.batch_size);
        if (store.checkpoint_io.pending) try store.checkpoint_io.wait(null);
        if (store.filesystem.pending) try store.filesystem.wait(null);
    }
}

pub const IoCounts = struct {
    process_wchar: u64 = 0,
    kernel_write_bytes: u64 = 0,

    pub fn read(io: std.Io) !IoCounts {
        const file = try std.Io.Dir.cwd().openFile(io, "/proc/self/io", .{});
        defer file.close(io);
        var bytes: [4096]u8 = undefined;
        const length = try file.readPositionalAll(io, &bytes, 0);
        var counts: IoCounts = .{};
        var found: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes[0..length], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "wchar: ")) {
                counts.process_wchar = try std.fmt.parseInt(u64, line[7..], 10);
                found += 1;
            }
            if (std.mem.startsWith(u8, line, "write_bytes: ")) {
                counts.kernel_write_bytes = try std.fmt.parseInt(u64, line[13..], 10);
                found += 1;
            }
        }
        if (found != 2) return error.MissingIoCounters;
        return counts;
    }

    pub fn subtract(self: IoCounts, before: IoCounts) IoCounts {
        return .{ .process_wchar = self.process_wchar - before.process_wchar, .kernel_write_bytes = self.kernel_write_bytes - before.kernel_write_bytes };
    }
};

pub const Stamp = struct {
    wall: i96,
    cpu: i96,

    pub fn now(io: std.Io) Stamp {
        return .{ .wall = std.Io.Clock.now(.awake, io).nanoseconds, .cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds };
    }

    pub fn since(self: Stamp, start: Stamp) Duration {
        return .{ .wall_ns = @intCast(self.wall - start.wall), .cpu_ns = @intCast(self.cpu - start.cpu) };
    }
};

pub const Duration = struct { wall_ns: u64, cpu_ns: u64 };
pub const Distribution = struct {
    count: usize,
    total_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    maximum_ns: u64,

    pub fn summarize(samples: []u64) Distribution {
        std.debug.assert(samples.len > 0);
        var total: u64 = 0;
        for (samples) |sample| total += sample;
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        return .{ .count = samples.len, .total_ns = total, .p50_ns = samples[(samples.len * 50 + 99) / 100 - 1], .p95_ns = samples[(samples.len * 95 + 99) / 100 - 1], .p99_ns = samples[(samples.len * 99 + 99) / 100 - 1], .maximum_ns = samples[samples.len - 1] };
    }
};
