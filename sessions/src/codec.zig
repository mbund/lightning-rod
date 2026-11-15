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
            batch: ?*Batch = null,

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
        pub const Result = struct { secret: ?[16]u8 = null, received: usize = 0, burst: ?Buffers.Lease = null, bytes: []const u8 = &.{}, consumed: usize = 0, input: ?protocol.Packets = null, needs_output: bool = false };
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
            encoding: Step = undefined,
            delivery: Step = undefined,
            encoded: std.atomic.Value(bool) = .init(false),
            task: *Task,
            protocol: i32,
            storage: []u8,
            length: usize,
            decoded_length: usize = 0,
            threshold: ?usize,
            output: []u8,
            bytes: []const u8 = &.{},
        };
        pub const Operation = union(enum) {
            frame_sequence: struct { first: *Frame, targets: *SendTarget },
            verify: protocol.LoginVerification,
            frame: struct { protocol: i32, storage: []u8, length: usize, decoded_length: usize = 0, threshold: ?usize, output: []u8, targets: ?*SendTarget = null },
            send: struct { connection: *Endpoint.Connection, prefix: []const u8 = &.{}, source: []const u8, first: []u8, second: []u8 },
            receive: struct { connection: *Endpoint.Connection, bytes: []u8 },
            control_batch: ControlBatch,
            decode: Decode,
            decode_batch: DecodeBatch,
        };

        fn encodeFrame(number: i32, workspaces: *Endpoint.Workspaces, storage: []u8, length: usize, decoded_length: usize, threshold: ?usize, output: []u8) ![]const u8 {
            if (decoded_length == 0) return Endpoint.sharedFrame(number, workspaces, storage, length, threshold, output);
            if (comptime @hasDecl(Endpoint, "preparedFrame")) return Endpoint.preparedFrame(number, workspaces, storage, length, decoded_length, threshold, output);
            return error.UnsupportedEncoding;
        }

        const Batch = struct {
            owner: *Self,
            task: ?*Task = null,
            next: ?*Batch = null,
            frames: [@bitSizeOf(u32)]*Frame = undefined,
            count: usize = 0,
            targets: *SendTarget = undefined,
            remaining: std.atomic.Value(usize) = .init(0),
            delivered: std.atomic.Value(u32) = .init(0),
            failure: std.atomic.Value(u16) = .init(0),
            packets: u32 = 0,
        };
        const Step = struct {
            batch: *Batch,
            worker: *Worker,
            frame: *Frame,
            next: ?*Step = null,
            position: u5,
            dependencies: u32 = 0,
            successors: u32 = 0,
            compression: bool,
            waiting: std.atomic.Value(bool) = .init(false),
        };

        pub const Worker = struct {
            owner: *Self,
            index: usize,
            ready_steps: std.atomic.Value(?*Step) = .init(null),
            workspaces: Endpoint.Workspaces,
            tasks: []*Task,
            read: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
            write: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
            ready: std.Io.Event = .unset,
            stopping: std.atomic.Value(bool) = .init(false),
            thread: ?std.Thread = null,
            waiting: ?*Step = null,

            fn run(self: *Worker) void {
                const owner = self.owner;
                owner.launched.waitUncancelable(owner.io);
                if (owner.failed_start.load(.acquire)) return;
                while (true) {
                    self.runSteps();
                    const read = self.read.load(.monotonic);
                    const write = self.write.load(.acquire);
                    if (read == write) {
                        // Reset before rechecking producers so their wakeups cannot be lost.
                        _ = @atomicRmw(std.Io.Event, &self.ready, .Xchg, .unset, .acq_rel);
                        const stopping = self.stopping.load(.acquire);
                        if (read != self.write.load(.acquire) or self.ready_steps.load(.acquire) != null or self.waitingReady()) continue;
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
                            .frame, .frame_sequence => owner.framing.start(),
                            .send => owner.encryption.start(),
                            .control_batch => owner.control.start(),
                            .decode, .decode_batch => owner.decompression.start(),
                        };
                        if (task.batch != null) self.prepareBatch(task) else execute(&self.workspaces, task);
                        timing.end();
                        owner.transport.notify(owner.io);
                        self.runSteps();
                    }
                }
            }

            fn prepareBatch(self: *Worker, task: *Task) void {
                const batch = task.batch.?;
                std.debug.assert(batch.task == task and batch.owner == self.owner);
                const sequence = task.operation.frame_sequence;
                batch.targets = sequence.targets;
                batch.failure.store(0, .monotonic);
                batch.delivered.store(0, .monotonic);
                var count: usize = 0;
                var next: ?*Frame = sequence.first;
                while (next) |frame| {
                    next = frame.next;
                    std.debug.assert(count < batch.frames.len);
                    const worker = &self.owner.workers[(self.index + count) % self.owner.workers.len];
                    frame.encoded.store(false, .monotonic);
                    frame.encoding = .{ .batch = batch, .worker = worker, .frame = frame, .position = @intCast(count), .compression = true };
                    frame.delivery = .{ .batch = batch, .worker = worker, .frame = frame, .position = @intCast(count), .compression = false };
                    batch.frames[count] = frame;
                    count += 1;
                }
                std.debug.assert(count > 1 and count <= batch.frames.len);
                batch.count = count;
                batch.packets = @truncate((@as(u64, 1) << @intCast(count)) - 1);
                var target: ?*SendTarget = sequence.targets;
                while (target) |destination| {
                    target = destination.next;
                    var selected = destination.packets & batch.packets;
                    std.debug.assert(selected != 0);
                    var previous: u5 = @intCast(@ctz(selected));
                    selected &= selected - 1;
                    while (selected != 0) : (selected &= selected - 1) {
                        const position: u5 = @intCast(@ctz(selected));
                        batch.frames[position].delivery.dependencies |= @as(u32, 1) << previous;
                        batch.frames[previous].delivery.successors |= @as(u32, 1) << position;
                        previous = position;
                    }
                }
                batch.remaining.store(2 * count, .release);
                while (count != 0) {
                    count -= 1;
                    const frame = batch.frames[count];
                    frame.delivery.worker.enqueue(&frame.delivery);
                    frame.encoding.worker.enqueue(&frame.encoding);
                }
            }

            fn enqueue(self: *Worker, step: *Step) void {
                var previous = self.ready_steps.load(.acquire);
                while (true) {
                    step.next = previous;
                    previous = self.ready_steps.cmpxchgWeak(previous, step, .release, .acquire) orelse break;
                }
                self.ready.set(self.owner.io);
            }

            fn waitingReady(self: *const Worker) bool {
                var next = self.waiting;
                while (next) |step| {
                    next = step.next;
                    std.debug.assert(!step.compression);
                    if (step.batch.failure.load(.seq_cst) != 0 or (step.frame.encoded.load(.seq_cst) and step.batch.delivered.load(.seq_cst) & step.dependencies == step.dependencies)) return true;
                }
                return false;
            }

            fn runSteps(self: *Worker) void {
                var next = self.ready_steps.swap(null, .acquire);
                var previous = self.waiting;
                self.waiting = null;
                while (next != null or previous != null) {
                    const step = next orelse previous.?;
                    if (next != null) next = step.next else previous = step.next;
                    if (!self.processStep(step)) {
                        step.next = self.waiting;
                        self.waiting = step;
                    }
                }
            }

            fn processStep(self: *Worker, step: *Step) bool {
                const batch = step.batch;
                const task = batch.task.?;
                const owner = self.owner;
                const frame = step.frame;
                var notify = false;
                if (step.compression) {
                    const timing = owner.framing.start();
                    if (batch.failure.load(.acquire) == 0) {
                        if (encodeFrame(frame.protocol, &self.workspaces, frame.storage, frame.length, frame.decoded_length, frame.threshold, frame.output)) |bytes| {
                            frame.bytes = bytes;
                            frame.encoded.store(true, .seq_cst);
                            if (frame.delivery.waiting.load(.seq_cst)) frame.delivery.worker.ready.set(owner.io);
                        } else |err| {
                            _ = batch.failure.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                            for (batch.frames[0..batch.count]) |pending| if (pending.delivery.waiting.load(.seq_cst)) pending.delivery.worker.ready.set(owner.io);
                        }
                    }
                    timing.end();
                } else {
                    // Registration and readiness share an ordering so neither side can miss a wakeup.
                    step.waiting.store(true, .seq_cst);
                    const failure = batch.failure.load(.seq_cst);
                    if (failure == 0 and (!frame.encoded.load(.seq_cst) or batch.delivered.load(.seq_cst) & step.dependencies != step.dependencies)) return false;
                    step.waiting.store(false, .seq_cst);
                    if (failure == 0) {
                        const timing = owner.encryption.start();
                        notify = sendSequenceFrame(frame, batch.targets, step.position, true, batch.packets);
                        timing.end();
                        _ = batch.delivered.fetchOr(@as(u32, 1) << step.position, .seq_cst);
                        var successors = step.successors;
                        while (successors != 0) : (successors &= successors - 1) {
                            const pending = &batch.frames[@ctz(successors)].delivery;
                            if (pending.waiting.load(.seq_cst)) pending.worker.ready.set(owner.io);
                        }
                    }
                }
                const before = batch.remaining.fetchSub(1, .acq_rel);
                std.debug.assert(before > 0);
                if (before == 1) {
                    const failure = batch.failure.load(.acquire);
                    if (failure != 0) failTargets(batch.targets, @errorFromInt(failure));
                    const result: anyerror!Result = if (failure != 0) @errorFromInt(failure) else .{ .bytes = batch.frames[0].bytes };
                    finish(task, result);
                    owner.completed.set(owner.io);
                    notify = true;
                }
                if (notify) owner.transport.notify(owner.io);
                return true;
            }
        };

        pub const Configuration = struct {
            tasks: usize,
            frames: usize,
            workers: usize = 1,
            metrics: ?*metrics.Registry = null,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        transport: network.Transport,
        workers: []Worker,
        tasks: []*Task,
        next_worker: usize = 0,
        batches: []Batch,
        free_batch: ?*Batch,
        completed: std.Io.Event = .unset,
        launched: std.Io.Event = .unset,
        failed_start: std.atomic.Value(bool) = .init(false),

        framing: metrics.Timer = .{},
        encryption: metrics.Timer = .{},
        decryption: metrics.Timer = .{},
        control: metrics.Timer = .{},
        decompression: metrics.Timer = .{},

        pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: network.Transport, config: Configuration) !*Self {
            if (config.workers == 0 or config.workers > config.tasks or config.frames == 0 or config.frames > config.tasks) return error.InvalidCodecCapacity;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const tasks = try allocator.alloc(*Task, config.tasks);
            errdefer allocator.free(tasks);
            const workers = try allocator.alloc(Worker, config.workers);
            errdefer allocator.free(workers);
            const batches = try allocator.alloc(Batch, if (config.workers > 1) config.frames else 0);
            errdefer allocator.free(batches);
            for (batches, 0..) |*batch, index| batch.* = .{ .owner = self, .next = if (index + 1 < batches.len) &batches[index + 1] else null };
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
            self.* = .{ .allocator = allocator, .io = io, .transport = transport, .tasks = tasks, .workers = workers, .batches = batches, .free_batch = if (batches.len != 0) &batches[0] else null };
            if (config.metrics) |owner| {
                self.framing = try owner.timer(.{ .namespace = "session.codec", .name = "framing", .description = "Frame and compress shared packets" });
                self.encryption = try owner.timer(.{ .namespace = "session.codec", .name = "encryption", .description = "Encrypt outgoing bytes" });
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
            for (self.workers) |*worker| {
                std.debug.assert(!worker.stopping.load(.acquire));
                worker.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, Worker.run, .{worker});
            }
            // No work can publish to a worker that failed to start.
            self.launched.set(self.io);
        }

        fn cancelQueued(self: *Self) void {
            std.debug.assert(self.stopped());
            for (self.workers) |*worker| {
                const write = worker.write.load(.acquire);
                var read = worker.read.load(.monotonic);
                while (read != write) : (read += 1) {
                    const task = worker.tasks[read % worker.tasks.len];
                    switch (task.operation) {
                        .frame => |frame| failTargets(frame.targets, error.Canceled),
                        .frame_sequence => |sequence| failTargets(sequence.targets, error.Canceled),
                        else => {},
                    }
                    finish(task, error.Canceled);
                }
                worker.read.store(write, .release);
                worker.stopping.store(true, .release);
            }
        }

        // The network owner publishes tasks and returns completed frame reservations.
        pub fn submit(self: *Self, task: *Task, operation: Operation) void {
            for (0..self.workers.len) |offset| {
                const index = (self.next_worker + offset) % self.workers.len;
                const worker = &self.workers[index];
                std.debug.assert(!worker.stopping.load(.acquire));
                const write = worker.write.load(.monotonic);
                const read = worker.read.load(.acquire);
                std.debug.assert(read <= write and write - read <= worker.tasks.len);
                if (write - read == worker.tasks.len) continue;
                if (self.workers.len > 1 and operation == .frame_sequence and operation.frame_sequence.first.next != null) {
                    std.debug.assert(task.batch == null);
                    const batch = self.free_batch orelse unreachable;
                    self.free_batch = batch.next;
                    batch.task = task;
                    task.batch = batch;
                }
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
            if (task.batch) |batch| {
                const owner = batch.owner;
                batch.task = null;
                batch.next = owner.free_batch;
                owner.free_batch = batch;
                task.batch = null;
            }
            task.state.store(.idle, .release);
            return result;
        }

        pub fn execute(workspaces: *Endpoint.Workspaces, task: *Task) void {
            std.debug.assert(task.state.load(.acquire) == .queued);
            const operation = task.operation;
            const result = process(workspaces, operation);
            finish(task, result);
        }

        fn finish(task: *Task, result: anyerror!Result) void {
            var next = if (task.operation == .frame_sequence) task.operation.frame_sequence.first.next else null;
            while (next) |frame| {
                next = frame.next;
                frame.task.complete(if (result) |_| .{ .bytes = frame.bytes } else |err| err);
            }
            // The parent returns ownership of the entire sequence.
            task.complete(result);
        }

        fn process(workspaces: *Endpoint.Workspaces, operation: Operation) !Result {
            switch (operation) {
                .frame_sequence => |sequence| {
                    frameSequence(workspaces, sequence.first, sequence.targets) catch |err| {
                        failTargets(sequence.targets, err);
                        return err;
                    };
                    finishTargets(sequence.targets);
                    return .{ .bytes = sequence.first.bytes };
                },
                .verify => |verification| return .{ .secret = try verification.run() },
                .frame => |job| {
                    const bytes = encodeFrame(job.protocol, workspaces, job.storage, job.length, job.decoded_length, job.threshold, job.output) catch |err| {
                        failTargets(job.targets, err);
                        return err;
                    };
                    sendFrame(bytes, job.protocol, job.targets);
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
                    try controlBatch(workspaces, job);
                    return .{};
                },
                .decode => |job| return decode(workspaces, job),
                .decode_batch => |job| return decodeBatch(workspaces, job),
            }
        }

        fn sendFrame(bytes: []const u8, number: i32, head: ?*SendTarget) void {
            var next = head;
            var jobs: [Endpoint.maximum_encryption_batch_size]Endpoint.Encryption = undefined;
            var targets: [Endpoint.maximum_encryption_batch_size]*SendTarget = undefined;
            var bursts: [Endpoint.maximum_encryption_batch_size]?Buffers.Lease = undefined;
            const maximum = Endpoint.encryptionBatchSize(number);
            std.debug.assert(maximum > 0 and maximum <= jobs.len);
            while (next != null) {
                var count: usize = 0;
                for (0..maximum) |_| {
                    const target = next orelse break;
                    next = target.next;
                    std.debug.assert(target.task.state.load(.acquire) == .queued);
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
                    jobs[count] = .{ .connection = target.connection, .first = destination, .second = wrapped };
                    targets[count] = target;
                    bursts[count] = burst;
                    count += 1;
                }
                Endpoint.encryptBatch(number, bytes, jobs[0..count]);
                for (targets[0..count], bursts[0..count]) |completed, lease| {
                    completed.sent = true;
                    completed.task.complete(.{ .consumed = bytes.len, .burst = lease });
                }
            }
        }

        fn failTargets(first: ?*SendTarget, failure: anyerror) void {
            var next = first;
            while (next) |target| {
                next = target.next;
                if (target.sent) continue;
                target.task.operation = .{ .send = .{ .connection = target.connection, .source = &.{}, .first = &.{}, .second = &.{} } };
                target.task.complete(failure);
            }
        }

        fn finishTargets(first: ?*SendTarget) void {
            var next = first;
            while (next) |target| {
                next = target.next;
                finishTarget(target);
            }
        }

        fn finishTarget(target: *SendTarget) void {
            target.task.operation = .{ .send = .{ .connection = target.connection, .source = &.{}, .first = &.{}, .second = &.{} } };
            std.debug.assert(target.consumed > 0);
            target.sent = true;
            target.task.complete(.{ .consumed = target.consumed });
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

        fn frameSequence(workspaces: *Endpoint.Workspaces, first: *Frame, targets: *SendTarget) !void {
            var next: ?*Frame = first;
            var position: usize = 0;
            while (next) |frame| : (position += 1) {
                std.debug.assert(position < @bitSizeOf(u32));
                next = frame.next;
                std.debug.assert(frame.task.state.load(.acquire) == .queued);
                frame.bytes = try encodeFrame(frame.protocol, workspaces, frame.storage, frame.length, frame.decoded_length, frame.threshold, frame.output);
                _ = sendSequenceFrame(frame, targets, position, false, 0);
            }
        }

        fn sendSequenceFrame(frame: *Frame, targets: *SendTarget, position: usize, comptime complete: bool, packets: u32) bool {
            std.debug.assert(position < @bitSizeOf(u32));
            var jobs: [Endpoint.maximum_encryption_batch_size]Endpoint.Encryption = undefined;
            const maximum = Endpoint.encryptionBatchSize(frame.protocol);
            std.debug.assert(maximum > 0 and maximum <= jobs.len);
            var count: usize = 0;
            var destinations: [if (complete) Endpoint.maximum_encryption_batch_size else 0]*SendTarget = undefined;
            var finished = false;
            var target: ?*SendTarget = targets;
            while (target) |destination| {
                target = destination.next;
                if (destination.packets & (@as(u32, 1) << @intCast(position)) == 0) continue;
                std.debug.assert(destination.task.state.load(.acquire) == .queued);
                const bytes = frame.bytes;
                std.debug.assert(destination.used <= destination.bytes.len and bytes.len <= destination.bytes.len - destination.used);
                const first_count = @min(bytes.len, destination.bytes.len - destination.offset);
                jobs[count] = .{ .connection = destination.connection, .first = destination.bytes[destination.offset..][0..first_count], .second = destination.bytes[0 .. bytes.len - first_count] };
                if (complete) destinations[count] = destination;
                count += 1;
                destination.offset = (destination.offset + bytes.len) % destination.bytes.len;
                destination.used += bytes.len;
                destination.consumed += bytes.len;
                if (count == maximum) {
                    Endpoint.encryptBatch(frame.protocol, bytes, jobs[0..count]);
                    if (complete) finished = finishSequenceTargets(destinations[0..count], position, packets) or finished;
                    count = 0;
                }
            }
            if (count != 0) {
                Endpoint.encryptBatch(frame.protocol, frame.bytes, jobs[0..count]);
                if (complete) finished = finishSequenceTargets(destinations[0..count], position, packets) or finished;
            }
            return finished;
        }

        fn finishSequenceTargets(targets: []const *SendTarget, position: usize, packets: u32) bool {
            var finished = false;
            for (targets) |target| {
                if (@as(u64, target.packets & packets) >> @intCast(position + 1) != 0) continue;
                finishTarget(target);
                finished = true;
            }
            return finished;
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
            while (true) {
                _ = @atomicRmw(std.Io.Event, &self.completed, .Xchg, .unset, .acq_rel);
                var pending = false;
                for (self.batches) |*batch| {
                    if (batch.task) |task| pending = pending or task.state.load(.acquire) == .queued;
                }
                if (!pending) break;
                self.completed.waitUncancelable(self.io);
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
                std.debug.assert(worker.thread == null and worker.read.load(.acquire) == worker.write.load(.acquire) and worker.waiting == null and worker.ready_steps.load(.acquire) == null);
                Endpoint.deinitWorkspaces(&worker.workspaces);
            }
            self.allocator.free(self.batches);
            self.allocator.free(self.workers);
            self.allocator.free(self.tasks);
            self.allocator.destroy(self);
        }
    };
}
