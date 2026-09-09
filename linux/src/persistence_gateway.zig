const std = @import("std");
const lr = @import("lightning_rod");
const persistence = lr.persistence;
const runtime = lr.runtime;

/// Serializes bounded Core persistence RPCs.  Only this owner calls `store` or
/// its disk backend; clients borrow request bytes until their synchronous reply.
pub fn Gateway(comptime clients: usize, comptime maximum_scan_records: usize, comptime maximum_scan_key_bytes: usize) type {
    if (clients == 0 or clients > std.math.maxInt(u16) or maximum_scan_records == 0 or maximum_scan_key_bytes == 0)
        @compileError("invalid persistence gateway limits");
    return struct {
        const Self = @This();
        const State = enum(u8) { idle, pending, complete, stopped };
        const Call = union(enum) {
            length: struct { namespace: []const u8, key: []const u8 },
            read: struct { batch: persistence.ReadBatch, requests: []persistence.Request },
            poll: persistence.Request,
            scan: struct { namespace: []const u8, after: []const u8, output: []persistence.ScanRecord },
            reserve: persistence.WriteBatch,
            publish: persistence.WriteReservation,
            cancel: persistence.WriteReservation,
            flush,
            drain,
            checkpoint,
            progress,
            poisoned,
        };
        const Result = union(enum) {
            length: ?usize,
            status: persistence.Status,
            read: persistence.ReadResult,
            scan: persistence.ScanError!persistence.ScanResult,
            reserve: persistence.ReserveError!persistence.WriteReservation,
            drain: persistence.DrainError!void,
            poisoned: bool,
            done,
        };
        const Slot = struct {
            owner: ?*Self = null,
            state: std.atomic.Value(State) = .init(.idle),
            reply: std.Io.Event = .unset,
            call: Call = undefined,
            result: Result = undefined,
            scan_keys: [maximum_scan_records][maximum_scan_key_bytes]u8 = undefined,
            reservation_generation: u32 = 1,
        };

        store: persistence.Interface,
        backend: runtime.Backend,
        io: std.Io,
        slots: [clients]Slot = @splat(.{}),
        cursor: usize = 0,
        reservation: ?struct { owner: u16, generation: u32, token: persistence.WriteReservation } = null,
        wake: ?runtime.Wake = null,

        pub fn init(self: *Self, store: persistence.Interface, backend: runtime.Backend, io: std.Io) void {
            self.* = .{ .store = store, .backend = backend, .io = io };
            for (&self.slots) |*entry| entry.owner = self;
        }

        pub fn client(self: *Self, index: usize) persistence.Interface {
            std.debug.assert(index < clients);
            return .{ .context = &self.slots[index], .vtable = &client_vtable };
        }

        /// Owner thread only.  Bounded round-robin dispatch plus the disk driver.
        pub fn backendInterface(self: *Self) runtime.Backend {
            return .{ .context = self, .vtable = &backend_vtable, .readiness = .{ .context = self, .bind_fn = bind } };
        }
        pub fn advance(self: *Self, io: std.Io, limit: usize) runtime.Completion {
            return complete(self, io, limit);
        }

        fn bind(raw: *anyopaque, wake: runtime.Wake) runtime.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.wake != null) return .failed;
            self.wake = wake;
            return .ok;
        }
        fn complete(raw: *anyopaque, io: std.Io, limit: usize) runtime.Completion {
            const self: *Self = @ptrCast(@alignCast(raw));
            const driver = self.backend.complete(io, limit);
            if (driver.outcome == .failed) return driver;
            var count = driver.count;
            var checked: usize = 0;
            while (count < limit and checked < clients) : (checked += 1) {
                const index = self.cursor;
                self.cursor = (self.cursor + 1) % clients;
                const slot = &self.slots[index];
                if (slot.state.load(.acquire) != .pending) continue;
                self.dispatch(index, slot);
                count += 1;
            }
            return .{ .count = count };
        }
        fn submit(raw: *anyopaque, io: std.Io) runtime.Outcome {
            return (@as(*Self, @ptrCast(@alignCast(raw))).backend.submit(io));
        }
        fn shutdown(raw: *anyopaque, io: std.Io) runtime.Outcome {
            return (@as(*Self, @ptrCast(@alignCast(raw))).backend.beginShutdown(io));
        }
        fn progress(raw: *anyopaque) runtime.Progress {
            return (@as(*Self, @ptrCast(@alignCast(raw))).backend.shutdownProgress());
        }
        const backend_vtable: runtime.Backend.VTable = .{ .complete = complete, .submit = submit, .begin_shutdown = shutdown, .shutdown_progress = progress };

        fn dispatch(self: *Self, index: usize, slot: *Slot) void {
            slot.result = switch (slot.call) {
                .length => |v| .{ .length = self.store.length(v.namespace, v.key) },
                .read => |v| .{ .status = self.store.vtable.read_batch(self.store.context, v.batch, v.requests) },
                .poll => |v| .{ .read = self.store.pollRead(v) },
                .scan => |v| scan: {
                    const result = self.store.scan(v.namespace, v.after, v.output) catch |err| break :scan .{ .scan = err };
                    if (result.count > maximum_scan_records) break :scan .{ .scan = error.StorageFailed };
                    for (v.output[0..result.count], 0..) |*record, key_index| {
                        if (record.key.len > maximum_scan_key_bytes) break :scan .{ .scan = error.StorageFailed };
                        @memcpy(slot.scan_keys[key_index][0..record.key.len], record.key);
                        record.key = slot.scan_keys[key_index][0..record.key.len];
                    }
                    break :scan .{ .scan = result };
                },
                .reserve => |v| reserve: {
                    if (self.reservation != null) break :reserve .{ .reserve = error.Backpressured };
                    const token = self.store.reserve(v.records) catch |err| break :reserve .{ .reserve = err };
                    self.reservation = .{ .owner = @intCast(index), .generation = slot.reservation_generation, .token = token };
                    break :reserve .{ .reserve = @enumFromInt((@as(u64, @intCast(index)) << 32) | slot.reservation_generation) };
                },
                .publish => |token| blk: {
                    self.finishReservation(index, slot, token, true);
                    break :blk .done;
                },
                .cancel => |token| blk: {
                    self.finishReservation(index, slot, token, false);
                    break :blk .done;
                },
                .flush => .{ .status = self.store.flush() },
                .drain => .{ .drain = self.store.drain(self.io) },
                .checkpoint => .{ .status = self.store.requestCheckpoint() },
                .progress => .{ .status = self.store.checkpointProgress() },
                .poisoned => .{ .poisoned = self.store.poisoned() },
            };
            slot.state.store(.complete, .release);
            slot.reply.set(self.io);
        }
        fn finishReservation(self: *Self, index: usize, slot: *Slot, proxy: persistence.WriteReservation, commit: bool) void {
            const value = @intFromEnum(proxy);
            const reservation = self.reservation orelse @panic("missing gateway reservation");
            std.debug.assert(reservation.owner == index and reservation.generation == @as(u32, @truncate(value)) and value >> 32 == index);
            if (commit) self.store.publish(reservation.token) else self.store.cancel(reservation.token);
            self.reservation = null;
            slot.reservation_generation +%= 1;
            if (slot.reservation_generation == 0) slot.reservation_generation = 1;
        }

        fn invoke(slot: *Slot, call: Call) Result {
            std.debug.assert(slot.state.load(.acquire) == .idle);
            const owner = slot.owner orelse @panic("uninitialized persistence gateway client");
            slot.reply.reset();
            slot.call = call;
            slot.state.store(.pending, .release);
            if (owner.wake) |wake| wake.signal();
            while (slot.state.load(.acquire) != .complete)
                slot.reply.waitUncancelable(owner.io);
            const result = slot.result;
            slot.state.store(.idle, .release);
            return result;
        }
        fn clientSlot(raw: *anyopaque) *Slot {
            return @ptrCast(@alignCast(raw));
        }
        fn clientSlotConst(raw: *const anyopaque) *Slot {
            return @ptrCast(@alignCast(@constCast(raw)));
        }
        fn length(raw: *const anyopaque, n: []const u8, k: []const u8) ?usize {
            return switch (invoke(clientSlotConst(raw), .{ .length = .{ .namespace = n, .key = k } })) {
                .length => |v| v,
                else => unreachable,
            };
        }
        fn read(raw: *anyopaque, batch: persistence.ReadBatch, out: []persistence.Request) persistence.Status {
            return switch (invoke(clientSlot(raw), .{ .read = .{ .batch = batch, .requests = out } })) {
                .status => |v| v,
                else => unreachable,
            };
        }
        fn poll(raw: *anyopaque, token: persistence.Request) persistence.ReadResult {
            return switch (invoke(clientSlot(raw), .{ .poll = token })) {
                .read => |v| v,
                else => unreachable,
            };
        }
        fn scan(raw: *const anyopaque, n: []const u8, a: []const u8, o: []persistence.ScanRecord) persistence.ScanError!persistence.ScanResult {
            return switch (invoke(clientSlotConst(raw), .{ .scan = .{ .namespace = n, .after = a, .output = o } })) {
                .scan => |v| v,
                else => unreachable,
            };
        }
        fn reserve(raw: *anyopaque, batch: persistence.WriteBatch) persistence.ReserveError!persistence.WriteReservation {
            return switch (invoke(clientSlot(raw), .{ .reserve = batch })) {
                .reserve => |v| v,
                else => unreachable,
            };
        }
        fn publish(raw: *anyopaque, t: persistence.WriteReservation) void {
            _ = invoke(clientSlot(raw), .{ .publish = t });
        }
        fn cancel(raw: *anyopaque, t: persistence.WriteReservation) void {
            _ = invoke(clientSlot(raw), .{ .cancel = t });
        }
        fn status(raw: *anyopaque, call: Call) persistence.Status {
            return switch (invoke(clientSlot(raw), call)) {
                .status => |v| v,
                else => unreachable,
            };
        }
        fn flush(raw: *anyopaque) persistence.Status {
            return status(raw, .flush);
        }
        fn drain(raw: *anyopaque, _: std.Io) persistence.DrainError!void {
            return switch (invoke(clientSlot(raw), .drain)) {
                .drain => |v| v,
                else => unreachable,
            };
        }
        fn checkpoint(raw: *anyopaque) persistence.Status {
            return status(raw, .checkpoint);
        }
        fn checkpointProgress(raw: *anyopaque) persistence.Status {
            return status(raw, .progress);
        }
        fn poisoned(raw: *const anyopaque) bool {
            return switch (invoke(clientSlotConst(raw), .poisoned)) {
                .poisoned => |v| v,
                else => unreachable,
            };
        }
        const client_vtable: persistence.Interface.VTable = .{ .length = length, .read_batch = read, .poll_read = poll, .scan = scan, .reserve = reserve, .publish = publish, .cancel = cancel, .flush = flush, .drain = drain, .request_checkpoint = checkpoint, .checkpoint_progress = checkpointProgress, .poisoned = poisoned };
    };
}

test "two worker clients serialize real Store calls and retain copied scan keys" {
    const G = Gateway(2, 2, 16);
    const Backend = struct {
        fn complete(_: *anyopaque, _: std.Io, _: usize) runtime.Completion {
            return .{ .count = 0 };
        }
        fn submit(_: *anyopaque, _: std.Io) runtime.Outcome {
            return .ok;
        }
        fn shutdown(_: *anyopaque, _: std.Io) runtime.Outcome {
            return .ok;
        }
        fn progress(_: *anyopaque) runtime.Progress {
            return .complete;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try persistence.Store.initForTest(arena.allocator(), .{
        .maximum_keys = 4,
        .maximum_checkpoint_records = 4,
        .maximum_requests = 2,
        .maximum_namespace_bytes = 16,
        .maximum_key_bytes = 16,
        .maximum_value_bytes = 16,
        .maximum_checkpoint_bytes = 256,
    }, 1024);
    try std.testing.expectEqual(persistence.Status.ready, store.interface().stage(.{ .namespace = "n", .key = "key", .operation = .{ .put = "value" } }));
    var backend = Backend{};
    var gateway: G = undefined;
    gateway.init(store.interface(), .{ .context = &backend, .vtable = &.{ .complete = Backend.complete, .submit = Backend.submit, .begin_shutdown = Backend.shutdown, .shutdown_progress = Backend.progress } }, std.testing.io);
    const Context = struct {
        gateway: *G,
        index: usize,
        done: std.atomic.Value(bool) = .init(false),
        length: ?usize = null,
        key: [16]u8 = undefined,
        key_len: usize = 0,
        fn run(self: *@This()) void {
            const client = self.gateway.client(self.index);
            self.length = client.length("n", "key");
            var records: [2]persistence.ScanRecord = undefined;
            const scan = client.scan("n", "", &records) catch unreachable;
            if (scan.count != 0) {
                self.key_len = records[0].key.len;
                @memcpy(self.key[0..self.key_len], records[0].key);
            }
            self.done.store(true, .release);
        }
    };
    var first = Context{ .gateway = &gateway, .index = 0 };
    var second = Context{ .gateway = &gateway, .index = 1 };
    const a = try std.Thread.spawn(.{}, Context.run, .{&first});
    const b = try std.Thread.spawn(.{}, Context.run, .{&second});
    while (!first.done.load(.acquire) or !second.done.load(.acquire)) _ = gateway.advance(std.testing.io, 2);
    a.join();
    b.join();
    try std.testing.expectEqual(@as(?usize, 5), first.length);
    try std.testing.expectEqual(@as(?usize, 5), second.length);
    try std.testing.expectEqualStrings("key", first.key[0..first.key_len]);
    try std.testing.expectEqualStrings("key", second.key[0..second.key_len]);
}
