const std = @import("std");
const minecraft_java = @import("minecraft_java");
const sessions = @import("sessions");

const capacity = (1 << 21) + sessions.shared_headroom;

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const path = arguments.next() orelse return error.MissingCorpus;
    const repetitions = if (arguments.next()) |value| try std.fmt.parseInt(usize, value, 10) else 3;
    if (repetitions == 0 or arguments.next() != null) return error.InvalidArguments;
    const io = init.io;
    const allocator = init.arena.allocator();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const input_buffer = try allocator.alloc(u8, 64 * 1024);
    var input = file.reader(io, input_buffer);
    const reader = &input.interface;
    if (!std.mem.eql(u8, try reader.take(8), "LRSTRM01")) return error.InvalidCorpus;
    const players = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidCorpus;
    if (players == 0) return error.InvalidCorpus;
    const targets = try allocator.alloc(usize, players);
    const ciphers = try allocator.alloc(minecraft_java.Wire, players);
    const raw = try allocator.alloc(u8, capacity);
    const encoded = try allocator.alloc(u8, capacity);
    const expected = try allocator.alloc(u8, capacity);
    const encrypted = try allocator.alloc(u8, capacity * minecraft_java.Wire.encryption_batch_size);
    var codec = try minecraft_java.Wire.Workspace.init(allocator);
    defer codec.deinit();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    try output.interface.writeAll("Captured packet replay. File reads, validation and hashing are outside stage timings.\nrun batched packets recipients raw_MiB wire_MiB compression_CPU_ms encryption_CPU_ms codec_CPU_ms\n");
    for (0..repetitions * 2) |repetition| {
        const batched = repetition % 2 != 0;
        const width: usize = if (batched) minecraft_java.Wire.encryption_batch_size else 1;
        try input.seekTo(0);
        try reader.discardAll(16);
        for (ciphers, 0..) |*cipher, index| {
            cipher.* = .{};
            var secret: [16]u8 = @splat(0x37);
            std.mem.writeInt(u64, secret[0..8], index, .little);
            cipher.install(secret);
        }
        var raw_digest = std.hash.Wyhash.init(0);
        var encrypted_digest = std.hash.Wyhash.init(0);
        var packets: u64 = 0;
        var recipients: u64 = 0;
        var raw_bytes: u64 = 0;
        var wire_bytes: u64 = 0;
        var compression_ns: i96 = 0;
        var encryption_ns: i96 = 0;
        while (true) {
            const length = try reader.takeInt(u32, .little);
            if (length == 0) break;
            const frame_length = try reader.takeInt(u32, .little);
            const count = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidCorpus;
            if (length > raw.len - sessions.shared_headroom or frame_length > expected.len or count == 0 or count > targets.len) return error.InvalidCorpus;
            for (targets[0..count]) |*target| {
                target.* = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidCorpus;
                if (target.* >= ciphers.len) return error.InvalidCorpus;
            }
            try reader.readSliceAll(raw[sessions.shared_headroom..][0..length]);
            try reader.readSliceAll(expected[0..frame_length]);
            const begin = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
            const frame = try codec.encode(raw, length, 256, encoded);
            const compressed = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
            compression_ns += compressed - begin;
            if (!std.mem.eql(u8, frame, expected[0..frame_length])) return error.FrameMismatch;
            var target_at: usize = 0;
            while (target_at < count) {
                const batch_count = @min(width, count - target_at);
                var jobs: [minecraft_java.Wire.encryption_batch_size]minecraft_java.Wire.Encryption = undefined;
                for (targets[target_at..][0..batch_count], jobs[0..batch_count], 0..) |target, *job, index| job.* = ciphers[target].encryption(encrypted[index * capacity ..][0..frame.len], &.{});
                const started = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
                if (batched) minecraft_java.Wire.encryptBatch(frame, jobs[0..batch_count]) else ciphers[targets[target_at]].encrypt(frame, jobs[0].first);
                encryption_ns += std.Io.Clock.now(.cpu_thread, io).nanoseconds - started;
                for (jobs[0..batch_count]) |job| encrypted_digest.update(job.first);
                target_at += batch_count;
            }
            raw_digest.update(raw[sessions.shared_headroom..][0..length]);
            raw_bytes += length;
            wire_bytes += frame.len * count;
            recipients += count;
            packets += 1;
        }
        if (raw_digest.final() != try reader.takeInt(u64, .little)) return error.PacketHashMismatch;
        if (encrypted_digest.final() != try reader.takeInt(u64, .little)) return error.CipherHashMismatch;
        try output.interface.print("{d} {} {d} {d} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2}\n", .{ repetition / 2, batched, packets, recipients, @as(f64, @floatFromInt(raw_bytes)) / (1024 * 1024), @as(f64, @floatFromInt(wire_bytes)) / (1024 * 1024), @as(f64, @floatFromInt(compression_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(encryption_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(compression_ns + encryption_ns)) / std.time.ns_per_ms });
        try output.interface.flush();
    }
}
