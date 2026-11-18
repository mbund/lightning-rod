const std = @import("std");
const network = @import("networking");
const metrics = @import("metrics");
const protocol = @import("protocol.zig");
const Readiness = @import("readiness.zig").Readiness;

/// Work the network owner hands to worker threads: login verification, decryption of input,
/// decompression of input and packets before Play. Play output is framed and encrypted on the
/// network owner itself, side by side across connections, never here.
pub fn Codec(comptime Endpoint: type) type {
    return struct {
        const Self = @This();
        const batch_max = 32;
        pub const Task = struct {
            state: std.atomic.Value(enum(u8) { idle, queued, complete }) = .init(.idle),
            signal: ?Readiness.Signal = null,
            operation: Operation = undefined,
            result: anyerror!Result = undefined,

            pub fn begin(self: *Task, operation: Operation) void {
                std.debug.assert(self.state.load(.acquire) == .idle);
                self.operation = operation;
                self.state.store(.queued, .release);
            }

            pub fn complete(self: *Task, result: anyerror!Result) void {
                std.debug.assert(self.state.load(.acquire) == .queued);
                const signal = self.signal;
                self.result = result;
                self.state.store(.complete, .release);
                if (signal) |ready| ready.notify();
            }
        };
        pub const Result = struct { secret: ?[16]u8 = null, received: usize = 0, bytes: []const u8 = &.{}, consumed: usize = 0, input: ?protocol.Packets = null, needs_output: bool = false };
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
        pub const Decode = struct { connection: *Endpoint.Connection, bytes: []const u8, output: []u8, threshold: ?usize };
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

        pub const Operation = union(enum) {
            verify: protocol.LoginVerification,
            receive: struct { connection: *Endpoint.Connection, bytes: []u8 },
            control_batch: ControlBatch,
            decode: Decode,
            decode_batch: DecodeBatch,
        };

        pub const Worker = struct {
            owner: *Self,
            index: usize,
            workspaces: Endpoint.Workspaces,
            tasks: []*Task,
            read: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
            write: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
            ready: std.Io.Event = .unset,
            stopping: std.atomic.Value(bool) = .init(false),
            thread: ?std.Thread = null,

            fn run(self: *Worker) void {
                const owner = self.owner;
                owner.launched.waitUncancelable(owner.io);
                if (owner.failed_start.load(.acquire)) return;
                while (true) {
                    const read = self.read.load(.monotonic);
                    const write = self.write.load(.acquire);
                    if (read == write) {
                        // Reset before rechecking producers so their wakeups cannot be lost.
                        _ = @atomicRmw(std.Io.Event, &self.ready, .Xchg, .unset, .acq_rel);
                        const stopping = self.stopping.load(.acquire);
                        if (read != self.write.load(.acquire)) continue;
                        if (stopping) return;
                        self.ready.waitUncancelable(owner.io);
                        continue;
                    }
                    const count = @min(batch_max, write - read);
                    std.debug.assert(count > 0 and count <= self.tasks.len);
                    for (0..count) |offset| {
                        const task = self.tasks[(read + offset) % self.tasks.len];
                        std.debug.assert(task.state.load(.acquire) == .queued);
                        self.read.store(read + offset + 1, .release);
                        const timing = switch (task.operation) {
                            .verify, .receive => owner.decryption.start(),
                            .control_batch => owner.control.start(),
                            .decode, .decode_batch => owner.decompression.start(),
                        };
                        execute(&self.workspaces, task);
                        timing.end();
                        owner.transport.notify(owner.io);
                    }
                }
            }
        };

        pub const Configuration = struct {
            tasks: usize,
            workers: usize = 1,
            metrics: ?*metrics.Registry = null,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        transport: network.Transport,
        workers: []Worker,
        tasks: []*Task,
        next_worker: usize = 0,
        launched: std.Io.Event = .unset,
        failed_start: std.atomic.Value(bool) = .init(false),

        decryption: metrics.Timer = .{},
        control: metrics.Timer = .{},
        decompression: metrics.Timer = .{},

        pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: network.Transport, config: Configuration) !*Self {
            if (config.workers == 0 or config.workers > config.tasks) return error.InvalidCodecCapacity;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const tasks = try allocator.alloc(*Task, config.tasks);
            errdefer allocator.free(tasks);
            const workers = try allocator.alloc(Worker, config.workers);
            errdefer allocator.free(workers);
            var initialized: usize = 0;
            errdefer for (workers[0..initialized]) |*worker| Endpoint.deinitWorkspaces(&worker.workspaces);
            var offset: usize = 0;
            for (workers, 0..) |*worker, index| {
                const capacity = config.tasks / config.workers + @intFromBool(index < config.tasks % config.workers);
                worker.* = .{ .owner = self, .index = index, .tasks = tasks[offset..][0..capacity], .workspaces = try Endpoint.initWorkspaces(allocator) };
                initialized += 1;
                offset += capacity;
            }
            std.debug.assert(offset == tasks.len);
            self.* = .{ .allocator = allocator, .io = io, .transport = transport, .tasks = tasks, .workers = workers };
            if (config.metrics) |owner| {
                self.decryption = try owner.timer(.{ .namespace = "session.codec", .name = "decryption", .description = "Decrypt incoming bytes" });
                self.control = try owner.timer(.{ .namespace = "session.codec", .name = "control", .description = "Frame compress and encrypt protocol control packets" });
                self.decompression = try owner.timer(.{ .namespace = "session.codec", .name = "decompression", .description = "Decode incoming compressed packets" });
            }
            return self;
        }

        pub fn start(self: *Self) !void {
            std.debug.assert(self.stopped() and !self.launched.isSet());
            errdefer {
                self.failed_start.store(true, .release);
                self.launched.set(self.io);
                for (self.workers) |*worker| if (worker.thread) |thread| {
                    thread.join();
                    worker.thread = null;
                };
                self.cancelQueued();
            }
            for (self.workers, 0..) |*worker, index| {
                std.debug.assert(!worker.stopping.load(.acquire));
                worker.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, Worker.run, .{worker});
                var name: [std.Thread.max_name_len]u8 = undefined;
                worker.thread.?.setName(self.io, std.fmt.bufPrint(&name, "codec {d}", .{index}) catch "codec") catch {};
            }
            // No work can publish to a worker that failed to start.
            self.launched.set(self.io);
        }

        fn cancelQueued(self: *Self) void {
            std.debug.assert(self.stopped());
            for (self.workers) |*worker| {
                const write = worker.write.load(.acquire);
                var read = worker.read.load(.monotonic);
                while (read != write) : (read += 1) finish(worker.tasks[read % worker.tasks.len], error.Canceled);
                worker.read.store(write, .release);
                worker.stopping.store(true, .release);
            }
        }

        pub fn submit(self: *Self, task: *Task, operation: Operation) void {
            for (0..self.workers.len) |offset| {
                const index = (self.next_worker + offset) % self.workers.len;
                const worker = &self.workers[index];
                std.debug.assert(!worker.stopping.load(.acquire));
                const write = worker.write.load(.monotonic);
                const read = worker.read.load(.acquire);
                std.debug.assert(read <= write and write - read <= worker.tasks.len);
                if (write - read == worker.tasks.len) continue;
                task.begin(operation);
                worker.tasks[write % worker.tasks.len] = task;
                worker.write.store(write + 1, .release);
                worker.ready.set(self.io);
                self.next_worker = (index + 1) % self.workers.len;
                return;
            }
            unreachable;
        }

        pub fn stopped(self: *const Self) bool {
            for (self.workers) |*worker| if (worker.thread != null) return false;
            return true;
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

        pub fn execute(workspaces: *Endpoint.Workspaces, task: *Task) void {
            std.debug.assert(task.state.load(.acquire) == .queued);
            finish(task, process(workspaces, task.operation));
        }

        fn finish(task: *Task, result: anyerror!Result) void {
            task.complete(result);
        }

        fn process(workspaces: *Endpoint.Workspaces, operation: Operation) !Result {
            switch (operation) {
                .verify => |verification| return .{ .secret = try verification.run() },
                .receive => |job| {
                    Endpoint.receive(job.connection, job.bytes);
                    return .{ .received = job.bytes.len };
                },
                .control_batch => |job| {
                    try controlBatch(workspaces, job);
                    return .{};
                },
                .decode => |job| return decode(workspaces, job),
                .decode_batch => |job| return decodeBatch(workspaces, job),
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

        pub fn decode(workspaces: *Endpoint.Workspaces, request: Decode) !Result {
            const bytes = Endpoint.decode(request.connection, workspaces, request.bytes, request.output, request.threshold) catch |err| {
                if (err == error.BufferTooSmall) return .{ .needs_output = true };
                return err;
            };
            return .{ .bytes = bytes };
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
                    if (err == error.BufferTooSmall) {
                        if (count != 0) break;
                        return .{ .received = request.received, .needs_output = true };
                    }
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
            if (self.stopped()) {
                self.cancelQueued();
                return;
            }
            for (self.workers) |*worker| if (worker.thread != null) {
                worker.stopping.store(true, .release);
                worker.ready.set(self.io);
            };
            for (self.workers) |*worker| if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.workers) |*worker| {
                std.debug.assert(worker.thread == null and worker.read.load(.acquire) == worker.write.load(.acquire));
                Endpoint.deinitWorkspaces(&worker.workspaces);
            }
            self.allocator.free(self.workers);
            self.allocator.free(self.tasks);
            self.allocator.destroy(self);
        }
    };
}
