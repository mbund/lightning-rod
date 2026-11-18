//! How fast connections' output encrypts, AES-CFB8 as Minecraft runs it: each stream on its own,
//! as a server encrypting one connection at a time does, against streams side by side in lanes.
//! Every stream is a connection's new bytes since its last send, so the sizes span a tick of
//! movement for a crowd up to a run of chunk columns.

const std = @import("std");
const Cipher = @import("java").Cipher;

const connections = 256;
const sizes = [_]usize{ 64, 512, 4096, 65536 };
const minimum_ns = 300 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const buffer = try allocator.alloc(u8, connections * sizes[sizes.len - 1]);
    defer allocator.free(buffer);
    var random = std.Random.DefaultPrng.init(1);
    random.random().bytes(buffer);
    var ciphers: [connections]Cipher = undefined;
    for (&ciphers, 0..) |*cipher, index| {
        var secret: [16]u8 = undefined;
        std.mem.writeInt(u128, &secret, index *% 0x9e3779b97f4a7c15, .little);
        cipher.* = .init(secret);
    }
    var streams: [connections]Cipher.Stream = undefined;
    std.debug.print("{s:>8} {s:>10} {s:>12} {s:>10}\n", .{ "bytes", "lanes", "MB/s", "ns/byte" });
    inline for (sizes) |size| {
        for (&streams, &ciphers, 0..) |*stream, *cipher, index| stream.* = .{ .cipher = cipher, .bytes = buffer[index * size ..][0..size] };
        const total = connections * size;
        // One stream after another.
        {
            const ns = try measure(io, struct {
                fn run(all: []const Cipher.Stream) void {
                    for (all) |stream| stream.cipher.transform(.encrypt, stream.bytes, stream.bytes);
                }
            }.run, &streams, total);
            report(size, "alone", total, ns);
        }
        inline for ([_]usize{ 4, 8, 16, 32 }) |lanes| {
            const ns = try measure(io, struct {
                fn run(all: []const Cipher.Stream) void {
                    Cipher.encryptStreamsWith(lanes, all);
                }
            }.run, &streams, total);
            report(size, std.fmt.comptimePrint("{d}", .{lanes}), total, ns);
        }
    }
}

/// Nanoseconds a pass over every stream takes, the best of passes over at least `minimum_ns`.
fn measure(io: std.Io, comptime run: fn ([]const Cipher.Stream) void, streams: []const Cipher.Stream, total: usize) !u64 {
    _ = total;
    run(streams);
    var best: u64 = std.math.maxInt(u64);
    var spent: u64 = 0;
    while (spent < minimum_ns) {
        const start = std.Io.Clock.now(.awake, io).nanoseconds;
        run(streams);
        const elapsed: u64 = @intCast(std.Io.Clock.now(.awake, io).nanoseconds - start);
        best = @min(best, elapsed);
        spent += elapsed;
    }
    return best;
}

fn report(size: usize, lanes: []const u8, total: usize, ns: u64) void {
    const seconds = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    const megabytes = @as(f64, @floatFromInt(total)) / (1024 * 1024);
    std.debug.print("{d:>8} {s:>10} {d:>12.1} {d:>10.2}\n", .{ size, lanes, megabytes / seconds, @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total)) });
}
