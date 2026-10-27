const std = @import("std");
const network = @import("networking");
const metrics = @import("metrics");
const protocol = @import("protocol.zig");
const Readiness = @import("readiness.zig").Readiness;
const Buffers = @import("buffers.zig").Buffers;

pub fn Codec(comptime Endpoint: type) type {
    return struct {
        const Self = @This();
        const batch_max = 32;
        pub const Task = struct {
            state: std.atomic.Value(enum(u8) { idle, queued, complete }) = .init(.idle),
            signal: ?Readiness.Signal = null,
            operation: Operation = undefined,
            result: anyerror!Result = undefined,

            pub fn complete(self: *Task, result: anyerror!Result) void {
                std.debug.assert(self.state.load(.acquire) == .queued);
                const signal = self.signal;
                self.result = result;
                self.state.store(.complete, .release);
                if (signal) |ready| ready.notify();
            }
        };
        pub const Result = struct { secret: ?[16]u8 = null, received: usize = 0, burst: ?Buffers.Lease = null, bytes: []const u8 = &.{}, consumed: usize = 0, input: ?protocol.Packets = null };
        pub const control_batch_max = 128;
        pub const Control = struct {
            packet: protocol.Packet,
            threshold: ?usize,
            bound: usize,
            fragments: protocol.Fragments = undefined,
        };
        pub const ControlBatch = struct {
            connection: *Endpoint.Connection,
            packets: []Control,
            output: []u8,
        };
        pub const DecodeBatch = struct {
            connection: *Endpoint.Connection,
            encrypted_tail: []u8 = &.{},
            received: usize = 0,
            bytes: []const u8,
            output: []u8,
            packets: [][]const u8,
            threshold: ?usize,
            maximum: usize,
        };
        pub const SendTarget = struct {
            next: ?*SendTarget = null,
            index: usize = 0,
            recipient: usize = 0,
            packets: u32 = std.math.maxInt(u32),
            task: *Task,
            connection: *Endpoint.Connection,
            bytes: []u8,
            used: usize,
            offset: usize,
            overflow: ?*Buffers = null,
            sent: bool = false,
            consumed: usize = 0,
        };
        pub const Frame = struct {
            next: ?*Frame = null,
            task: *Task,
            protocol: i32,
            storage: []u8,
            length: usize,
            threshold: ?usize,
            output: []u8,
            bytes: []const u8 = &.{},
        };
        pub const Operation = union(enum) {
            frame_sequence: struct { first: *Frame, targets: *SendTarget },
            verify: protocol.LoginVerification,
            frame: struct { protocol: i32, storage: []u8, length: usize, threshold: ?usize, output: []u8, targets: ?*SendTarget = null },
            send: struct { connection: *Endpoint.Connection, prefix: []const u8 = &.{}, source: []const u8, first: []u8, second: []u8 },
            receive: struct { connection: *Endpoint.Connection, bytes: []u8 },
            control_batch: ControlBatch,
            decode: struct { connection: *Endpoint.Connection, bytes: []const u8, output: []u8, threshold: ?usize },
            decode_batch: DecodeBatch,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        transport: network.Transport,
        workspaces: Endpoint.Workspaces,
        // The networking thread publishes tasks. The packet thread consumes them.
        tasks: []*Task,
        read: std.atomic.Value(u64) = .init(0),
        write: std.atomic.Value(u64) = .init(0),
        ready: std.Io.Event = .unset,
        stopping: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,
        framing: metrics.Timer = .{},
        encryption: metrics.Timer = .{},
        decryption: metrics.Timer = .{},
        control: metrics.Timer = .{},
        decompression: metrics.Timer = .{},

        pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: network.Transport, queue_capacity: usize, registry: ?*metrics.Registry) !*Self {
            if (queue_capacity == 0) return error.InvalidCodecCapacity;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const tasks = try allocator.alloc(*Task, queue_capacity);
            errdefer allocator.free(tasks);
            var workspaces = try Endpoint.initWorkspaces(allocator);
            errdefer Endpoint.deinitWorkspaces(&workspaces);
            self.* = .{ .allocator = allocator, .io = io, .transport = transport, .tasks = tasks, .workspaces = workspaces };
            if (registry) |owner| {
                self.framing = try owner.timer(.{ .namespace = "session.codec", .name = "framing", .description = "Frame and compress shared packets" });
                self.encryption = try owner.timer(.{ .namespace = "session.codec", .name = "encryption", .description = "Encrypt outgoing bytes" });
                self.decryption = try owner.timer(.{ .namespace = "session.codec", .name = "decryption", .description = "Decrypt incoming bytes" });
                self.control = try owner.timer(.{ .namespace = "session.codec", .name = "control", .description = "Frame compress and encrypt protocol control packets" });
                self.decompression = try owner.timer(.{ .namespace = "session.codec", .name = "decompression", .description = "Decode incoming compressed packets" });
            }
            return self;
        }

        pub fn start(self: *Self) !void {
            std.debug.assert(self.thread == null);
            self.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        }

        pub fn submit(self: *Self, task: *Task, operation: Operation) void {
            std.debug.assert(task.state.load(.acquire) == .idle);
            std.debug.assert(!self.stopping.load(.acquire));
            task.operation = operation;
            task.state.store(.queued, .release);
            const write = self.write.load(.monotonic);
            std.debug.assert(write - self.read.load(.acquire) < self.tasks.len);
            self.tasks[write % self.tasks.len] = task;
            self.write.store(write + 1, .release);
            self.ready.set(self.io);
        }

        pub fn take(task: *Task) ?anyerror!Result {
            if (task.state.load(.acquire) != .complete) return null;
            const result = task.result;
            if (task.result) |*value| {
                if (value.secret) |*secret| std.crypto.secureZero(u8, secret);
            } else |_| {}
            task.state.store(.idle, .release);
            return result;
        }

        fn run(self: *Self) void {
            while (true) {
                const read = self.read.load(.monotonic);
                if (read == self.write.load(.acquire)) {
                    self.ready.reset();
                    const stopping = self.stopping.load(.acquire);
                    if (read != self.write.load(.acquire)) continue;
                    if (stopping) return;
                    self.ready.waitUncancelable(self.io);
                    continue;
                }
                const count = @min(batch_max, self.write.load(.acquire) - read);
                std.debug.assert(count > 0 and count <= self.tasks.len);
                for (0..count) |offset| {
                    const task = self.tasks[(read + offset) % self.tasks.len];
                    std.debug.assert(task.state.load(.acquire) == .queued);
                    self.read.store(read + offset + 1, .release);
                    const operation = task.operation;
                    const result = self.process(operation);
                    var next = if (operation == .frame_sequence) operation.frame_sequence.first.next else null;
                    task.complete(result);
                    while (next) |frame| {
                        next = frame.next;
                        frame.task.complete(if (result) |_| .{ .bytes = frame.bytes } else |err| err);
                    }
                    self.transport.notify(self.io);
                }
            }
        }

        fn process(self: *Self, operation: Operation) !Result {
            const timing = switch (operation) {
                .verify => self.decryption.start(),
                .frame, .frame_sequence => self.framing.start(),
                .send => self.encryption.start(),
                .receive => self.decryption.start(),
                .control_batch => self.control.start(),
                .decode, .decode_batch => self.decompression.start(),
            };
            defer timing.end();
            switch (operation) {
                .frame_sequence => |sequence| {
                    self.frameSequence(sequence.first, sequence.targets) catch |err| {
                        var target: ?*SendTarget = sequence.targets;
                        while (target) |destination| {
                            target = destination.next;
                            destination.task.complete(err);
                        }
                        return err;
                    };
                    var target: ?*SendTarget = sequence.targets;
                    while (target) |destination| {
                        target = destination.next;
                        destination.task.operation = .{ .send = .{ .connection = destination.connection, .source = &.{}, .first = &.{}, .second = &.{} } };
                        std.debug.assert(destination.consumed > 0);
                        destination.sent = true;
                        destination.task.complete(.{ .consumed = destination.consumed });
                    }
                    return .{ .bytes = sequence.first.bytes };
                },
                .verify => |verification| return .{ .secret = try verification.run() },
                .frame => |job| {
                    const bytes = Endpoint.sharedFrame(job.protocol, &self.workspaces, job.storage, job.length, job.threshold, job.output) catch |err| {
                        var next = job.targets;
                        while (next) |target| {
                            next = target.next;
                            target.task.operation = .{ .send = .{ .connection = target.connection, .source = &.{}, .first = &.{}, .second = &.{} } };
                            target.task.complete(err);
                        }
                        return err;
                    };
                    var next = job.targets;
                    while (next) |target| {
                        next = target.next;
                        var buffer = target.bytes;
                        var offset = target.offset;
                        std.debug.assert(target.used <= buffer.len and offset < buffer.len);
                        std.debug.assert(target.overflow == null or target.used == 0);
                        var burst: ?Buffers.Lease = null;
                        if (bytes.len > buffer.len - target.used) {
                            if (target.overflow) |pool| burst = pool.acquire();
                            if (burst) |lease| {
                                std.debug.assert(bytes.len <= lease.bytes.len);
                                buffer = lease.bytes;
                                offset = 0;
                            } else {
                                target.task.operation = .{ .send = .{ .connection = target.connection, .source = &.{}, .first = &.{}, .second = &.{} } };
                                target.task.complete(.{});
                                continue;
                            }
                        }
                        const first = @min(bytes.len, buffer.len - offset);
                        const destination = buffer[offset..][0..first];
                        const wrapped = buffer[0 .. bytes.len - first];
                        target.task.operation = .{ .send = .{ .connection = target.connection, .source = bytes, .first = destination, .second = wrapped } };
                        Endpoint.encrypt(target.connection, bytes[0..first], destination);
                        Endpoint.encrypt(target.connection, bytes[first..], wrapped);
                        target.sent = true;
                        target.task.complete(.{ .consumed = bytes.len, .burst = burst });
                    }
                    return .{ .bytes = bytes };
                },
                .send => |job| {
                    encrypt(job.connection, job.prefix, job.source, job.first, job.second);
                    return .{ .consumed = job.prefix.len + job.source.len };
                },
                .receive => |job| {
                    Endpoint.receive(job.connection, job.bytes);
                    return .{ .received = job.bytes.len };
                },
                .control_batch => |job| {
                    try controlBatch(&self.workspaces, job);
                    return .{};
                },
                .decode => |job| return .{ .bytes = try Endpoint.decode(job.connection, &self.workspaces, job.bytes, job.output, job.threshold) },
                .decode_batch => |job| return decodeBatch(&self.workspaces, job),
            }
        }

        pub fn controlBatch(workspaces: *Endpoint.Workspaces, job: ControlBatch) !void {
            std.debug.assert(job.packets.len > 0 and job.packets.len <= control_batch_max);
            var output = job.output;
            for (job.packets) |*packet| {
                if (packet.bound > output.len) return error.ConfigurationTooLarge;
                packet.fragments = try Endpoint.control(job.connection, workspaces, packet.packet, output[0..packet.bound], packet.threshold);
                std.debug.assert(packet.fragments.first.len + packet.fragments.second.len > 0);
                std.debug.assert(packet.fragments.first.len + packet.fragments.second.len <= packet.bound);
                var used: usize = 0;
                for ([_][]const u8{ packet.fragments.first, packet.fragments.second }) |bytes| {
                    if (bytes.len == 0) continue;
                    const address = @intFromPtr(bytes.ptr);
                    const base = @intFromPtr(output.ptr);
                    if (address >= base and address < base + output.len) {
                        std.debug.assert(address - base < packet.bound and bytes.len <= packet.bound - (address - base));
                        used = @max(used, address - base + bytes.len);
                    }
                }
                output = output[used..];
            }
        }

        fn frameSequence(self: *Self, first: *Frame, targets: *SendTarget) !void {
            var next: ?*Frame = first;
            var position: usize = 0;
            while (next) |frame| : (position += 1) {
                std.debug.assert(position < @bitSizeOf(u32));
                next = frame.next;
                std.debug.assert(frame.task.state.load(.acquire) == .queued);
                frame.bytes = try Endpoint.sharedFrame(frame.protocol, &self.workspaces, frame.storage, frame.length, frame.threshold, frame.output);
                var target: ?*SendTarget = targets;
                while (target) |destination| {
                    target = destination.next;
                    if (destination.packets & (@as(u32, 1) << @intCast(position)) == 0) continue;
                    const bytes = frame.bytes;
                    std.debug.assert(destination.used <= destination.bytes.len and bytes.len <= destination.bytes.len - destination.used);
                    const count = @min(bytes.len, destination.bytes.len - destination.offset);
                    Endpoint.encrypt(destination.connection, bytes[0..count], destination.bytes[destination.offset..][0..count]);
                    Endpoint.encrypt(destination.connection, bytes[count..], destination.bytes[0 .. bytes.len - count]);
                    destination.offset = (destination.offset + bytes.len) % destination.bytes.len;
                    destination.used += bytes.len;
                    destination.consumed += bytes.len;
                }
            }
        }

        pub fn encrypt(connection: *Endpoint.Connection, prefix: []const u8, source: []const u8, first: []u8, second: []u8) void {
            std.debug.assert(prefix.len + source.len == first.len + second.len);
            var written: usize = 0;
            for ([_][]const u8{ prefix, source }) |part| {
                var offset: usize = 0;
                while (offset < part.len) {
                    const destination = if (written < first.len) first[written..] else second[written - first.len ..];
                    const count = @min(destination.len, part.len - offset);
                    std.debug.assert(count > 0);
                    Endpoint.encrypt(connection, part[offset..][0..count], destination[0..count]);
                    offset += count;
                    written += count;
                }
            }
            std.debug.assert(written == first.len + second.len);
        }

        pub fn decodeBatch(workspaces: *Endpoint.Workspaces, request: DecodeBatch) !Result {
            if (request.encrypted_tail.len != 0) Endpoint.receive(request.connection, request.encrypted_tail);
            var consumed: usize = 0;
            var written: usize = 0;
            var count: usize = 0;
            while (consumed < request.bytes.len and count < request.packets.len) {
                const frame = Endpoint.frame(request.connection, request.bytes[consumed..], request.maximum) catch |err| {
                    if (err == error.Incomplete) break;
                    return err;
                };
                if (frame.body.len == 0) return error.InvalidPacket;
                const destination = request.output[written..];
                const payload = Endpoint.decode(request.connection, workspaces, frame.body, destination, request.threshold) catch |err| {
                    if (err == error.BufferTooSmall and count != 0) break;
                    return err;
                };
                if (payload.len == 0 or payload.len > request.maximum) return error.InvalidPacket;
                if (payload.ptr == destination.ptr) {
                    std.debug.assert(payload.len <= destination.len);
                    written += payload.len;
                }
                request.packets[count] = payload;
                count += 1;
                consumed += frame.length;
            }
            return .{ .received = request.received, .consumed = consumed, .input = .{ .packets = request.packets[0..count] } };
        }

        pub fn stop(self: *Self) void {
            if (self.thread) |thread| {
                self.stopping.store(true, .release);
                self.ready.set(self.io);
                thread.join();
                self.thread = null;
            }
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.thread == null and self.read.load(.acquire) == self.write.load(.acquire));
            Endpoint.deinitWorkspaces(&self.workspaces);
            self.allocator.free(self.tasks);
            self.allocator.destroy(self);
        }
    };
}
