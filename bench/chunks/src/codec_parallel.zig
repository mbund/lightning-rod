const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const network = @import("networking");
const Endpoint = protocols.Endpoint;
const Codec = sessions.Engine(Endpoint, struct {}).Codec;
const assert = std.debug.assert;

const Completion = struct {
    ready: std.Io.Event = .unset,

    pub fn notify(self: *Completion, io: std.Io) void {
        self.ready.set(io);
    }

    pub fn queueReceive(_: *Completion, _: std.Io, _: network.Handle, _: []u8) network.QueueError!void {
        unreachable;
    }
    pub fn queueSend(_: *Completion, _: std.Io, _: network.Handle, _: []const std.posix.iovec_const) network.QueueError!void {
        unreachable;
    }
    pub fn close(_: *Completion, _: std.Io, _: network.Handle, _: network.CloseReason) void {
        unreachable;
    }
    pub fn releaseConnection(_: *Completion, _: std.Io, _: network.Handle) void {
        unreachable;
    }
    pub fn submit(_: *Completion, _: std.Io) !void {
        unreachable;
    }
    pub fn poll(_: *Completion, _: std.Io, _: ?std.Io.Timeout, _: []network.Event) !usize {
        unreachable;
    }
};

const Packet = struct {
    storage: []u8,
    length: usize,
    expected: []u8,
    output: []u8,
    recipients: []usize,
    ciphertexts: [][]u8,
    task: Codec.Task = .{},
    frame: Codec.Frame = undefined,
};

const Batch = struct { first: usize, count: usize, targets: []Codec.SendTarget };

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingCorpus;
    const repetitions = if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else 20;
    const batch_size = if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else 8;
    const worker_counts = args.next() orelse "0,1,2,4,8";
    if (repetitions == 0 or batch_size == 0 or batch_size > 32 or args.next() != null) return error.InvalidArguments;
    const io = init.io;
    const allocator = init.arena.allocator();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var input = file.reader(io, &read_buffer);
    const reader = &input.interface;
    if (!std.mem.eql(u8, try reader.take(8), "LRSTRM01")) return error.InvalidCorpus;
    const players = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidCorpus;
    if (players == 0) return error.InvalidCorpus;
    const packets = try allocator.alloc(Packet, 512);
    const connections = try allocator.alloc(Endpoint.Connection, players);
    const tasks = try allocator.alloc(Codec.Task, players);
    const corpus_bytes = (try file.stat(io)).size;
    const stride = @max(1, (corpus_bytes -| 16) / packets.len);
    var next_sample: u64 = 16 + stride / 2;
    var count: usize = 0;
    var raw_bytes: usize = 0;
    var wire_bytes: usize = 0;
    var recipients: usize = 0;
    while (count < packets.len) {
        const position = input.logicalPos();
        const length = try reader.takeInt(u32, .little);
        if (length == 0) break;
        const frame_length = try reader.takeInt(u32, .little);
        const targets = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidCorpus;
        if (length > 1 << 21 or frame_length > 1 << 21 or targets == 0 or targets > players) return error.InvalidCorpus;
        if (position < next_sample) {
            try input.seekBy(@intCast(targets * 8 + length + frame_length));
            continue;
        }
        next_sample += stride;
        const packet = &packets[count];
        packet.* = .{
            .storage = try allocator.alloc(u8, sessions.shared_headroom + length),
            .length = length,
            .expected = try allocator.alloc(u8, frame_length),
            .output = try allocator.alloc(u8, frame_length + sessions.shared_headroom),
            .recipients = try allocator.alloc(usize, targets),
            .ciphertexts = try allocator.alloc([]u8, targets),
        };
        for (packet.recipients, 0..) |*recipient, ordinal| {
            const index = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse return error.InvalidCorpus;
            if (index >= players or std.mem.indexOfScalar(usize, packet.recipients[0..ordinal], index) != null) return error.InvalidCorpus;
            recipient.* = index;
        }
        try reader.readSliceAll(packet.storage[sessions.shared_headroom..]);
        try reader.readSliceAll(packet.expected);
        raw_bytes += length;
        wire_bytes += frame_length * targets;
        recipients += targets;
        count += 1;
    }
    if (count == 0) return error.EmptyCorpus;
    const number = protocols.implementations[0].protocol_number;
    const batches = try allocator.alloc(Batch, try std.math.divCeil(usize, count, batch_size));
    const sizes = try allocator.alloc(usize, players);
    const masks = try allocator.alloc(u32, players);
    const destinations = try allocator.alloc([]u8, players);
    for (batches, 0..) |*batch, batch_index| {
        const first = batch_index * batch_size;
        const length = @min(batch_size, count - first);
        const window = packets[first..][0..length];
        @memset(sizes, 0);
        @memset(masks, 0);
        for (window, 0..) |*packet, index| {
            packet.frame = .{ .task = &packet.task, .protocol = number, .storage = packet.storage, .length = packet.length, .threshold = 256, .output = packet.output, .next = if (index + 1 < length) &window[index + 1].frame else null };
            for (packet.recipients) |recipient| {
                sizes[recipient] += packet.expected.len;
                masks[recipient] |= @as(u32, 1) << @intCast(index);
            }
        }
        var targets: usize = 0;
        for (sizes) |size| targets += @intFromBool(size != 0);
        batch.* = .{ .first = first, .count = length, .targets = try allocator.alloc(Codec.SendTarget, targets) };
        targets = 0;
        for (sizes, masks, 0..) |size, mask, index| {
            if (size == 0) continue;
            const target = &batch.targets[targets];
            target.* = .{ .task = &tasks[index], .connection = &connections[index], .recipient = index, .packets = mask, .bytes = try allocator.alloc(u8, size), .used = 0, .offset = 0, .next = if (targets + 1 < batch.targets.len) &batch.targets[targets + 1] else null };
            destinations[index] = target.bytes;
            targets += 1;
        }
        @memset(sizes, 0);
        for (window) |*packet| for (packet.recipients, packet.ciphertexts) |recipient, *bytes| {
            bytes.* = destinations[recipient][sizes[recipient]..][0..packet.expected.len];
            sizes[recipient] += packet.expected.len;
        };
    }
    var text_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &text_buffer);
    try output.interface.print("Fixed workload sampled across the capture: packets={d} recipients={d} players={d} repeats={d} batch_size={d} cipher_lanes={d} raw_MiB={d:.2} wire_MiB={d:.2}\nworkers wall_ms process_CPU_ms speedup ciphertext_hash\n", .{ count, recipients, players, repetitions, batch_size, Endpoint.encryptionBatchSize(number), @as(f64, @floatFromInt(raw_bytes * repetitions)) / 1048576, @as(f64, @floatFromInt(wire_bytes * repetitions)) / 1048576 });
    var reference_hash: ?u64 = null;
    var reference_wall: i96 = 0;
    var counts = std.mem.splitScalar(u8, worker_counts, ',');
    while (counts.next()) |text| {
        const workers = try std.fmt.parseInt(usize, text, 10);
        var completion: Completion = .{};
        const codec = if (workers != 0) try Codec.init(allocator, io, .{ .context = &completion, .vtable = network.Transport.adapter(Completion) }, .{ .tasks = batch_size + players, .frames = batch_size, .workers = workers }) else null;
        defer if (codec) |owner| owner.deinit();
        var workspace = if (codec == null) try Endpoint.initWorkspaces(allocator) else null;
        defer if (workspace) |*value| Endpoint.deinitWorkspaces(value);
        for (connections, tasks, 0..) |*connection, *task, index| {
            connection.* = try Endpoint.init(number, .login);
            task.* = .{};
            switch (connection.*) {
                inline else => |*state| {
                    var secret: [16]u8 = @splat(0x37);
                    std.mem.writeInt(u64, secret[0..8], index, .little);
                    state.wire.install(secret);
                },
            }
        }
        if (codec) |owner| try owner.start();
        defer if (codec) |owner| owner.stop();
        const wall = std.Io.Clock.now(.awake, io).nanoseconds;
        const cpu = std.Io.Clock.now(.cpu_process, io).nanoseconds;
        for (0..repetitions) |_| for (batches) |batch| {
            const window = packets[batch.first..][0..batch.count];
            for (batch.targets) |*target| {
                assert(target.task.state.load(.acquire) == .idle);
                target.task.state.store(.queued, .release);
                target.sent = false;
                target.used = 0;
                target.offset = 0;
                target.consumed = 0;
            }
            for (window[1..]) |*packet| packet.task.begin(.{ .frame = .{ .protocol = number, .storage = packet.storage, .length = packet.length, .threshold = 256, .output = packet.output } });
            const operation: Codec.Operation = .{ .frame_sequence = .{ .first = &window[0].frame, .targets = &batch.targets[0] } };
            if (codec) |owner| owner.submit(&window[0].task, operation) else {
                window[0].task.begin(operation);
                Codec.execute(&workspace.?, &window[0].task);
            }
            const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
            while (true) {
                _ = @atomicRmw(std.Io.Event, &completion.ready, .Xchg, .unset, .acq_rel);
                var complete = true;
                for (window) |*packet| complete = complete and packet.task.state.load(.acquire) == .complete;
                if (complete) break;
                completion.ready.waitTimeout(io, .{ .deadline = deadline }) catch |err| {
                    if (err == error.Timeout and std.Io.Clock.now(.awake, io).nanoseconds < deadline.raw.nanoseconds) continue;
                    std.debug.print("codec stalled workers={d} batch={d}\n", .{ workers, batch.first });
                    return err;
                };
            }
            for (window) |*packet| {
                const frame = try Codec.take(&packet.task).?;
                if (!std.mem.eql(u8, frame.bytes, packet.expected)) return error.FrameMismatch;
            }
            for (batch.targets) |*target| {
                const result = try Codec.take(target.task).?;
                assert(result.consumed == target.bytes.len and target.sent);
            }
        };

        const elapsed_cpu = std.Io.Clock.now(.cpu_process, io).nanoseconds - cpu;
        const elapsed_wall = std.Io.Clock.now(.awake, io).nanoseconds - wall;
        var hash = std.hash.Wyhash.init(0);
        for (packets[0..count]) |packet| for (packet.ciphertexts) |bytes| hash.update(bytes);
        const digest = hash.final();
        if (reference_hash) |expected| {
            if (digest != expected) return error.CiphertextMismatch;
        } else {
            reference_hash = digest;
            reference_wall = elapsed_wall;
        }
        try output.interface.print("{d:>7} {d:>7.2} {d:>14.2} {d:>7.2} {x}\n", .{ workers, @as(f64, @floatFromInt(elapsed_wall)) / 1000000, @as(f64, @floatFromInt(elapsed_cpu)) / 1000000, @as(f64, @floatFromInt(reference_wall)) / @as(f64, @floatFromInt(elapsed_wall)), digest });
        try output.interface.flush();
    }
}
