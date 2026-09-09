const persistence = @import("persistence.zig");
const runtime = @import("runtime/contracts.zig");
const std = @import("std");

pub const FatalError = error{
    WorkingMemoryExceeded,
    StorageReadFailed,
    StorageWriteFailed,
    StorageCorrupt,
    StorageFull,
    StorageCapacityExceeded,
    StorageDurabilityFailed,
    StorageSchemaUnsupported,
};

pub const Checkpoint = struct {
    pub const Writer = struct {
        persistence: persistence.Interface,
        io: std.Io,

        pub fn init(interface: persistence.Interface, io: std.Io) Writer {
            return .{ .persistence = interface, .io = io };
        }

        pub fn bind(self: *Writer, namespace: []const u8) Error!NamespaceWriter {
            if (namespace.len == 0) return error.InvalidKey;
            return .{ .namespace = self.persistence.namespace(namespace), .io = self.io };
        }
    };

    pub const NamespaceWriter = struct {
        namespace: persistence.Namespace,
        io: std.Io,

        pub fn put(self: *NamespaceWriter, key: []const u8, value: []const u8) Error!void {
            return self.batch(&.{.{ .key = key, .operation = .{ .put = value } }});
        }

        pub fn delete(self: *NamespaceWriter, key: []const u8) Error!void {
            return self.batch(&.{.{ .key = key, .operation = .delete }});
        }

        pub fn batch(self: *NamespaceWriter, records: []const persistence.CheckpointRecord) Error!void {
            const reservation = self.namespace.reserve(records) catch |err| retry: {
                if (err != error.Backpressured) return reservationError(err);
                try self.namespace.persistence.drain(self.io);
                break :retry self.namespace.reserve(records) catch |failure| return reservationError(failure);
            };
            self.namespace.publish(reservation);
        }

        fn reservationError(err: persistence.ReserveError) Error {
            return switch (err) {
                error.InvalidKey => error.InvalidKey,
                error.Backpressured, error.ValueTooLarge, error.IndexCapacityExceeded => error.CapacityExceeded,
                error.StorageFailed => error.Unavailable,
            };
        }
    };

    pub const Error = error{ CapacityExceeded, InvalidKey, Unavailable, Canceled };
};

pub const Closing = struct {
    deadline_ns: i128,
    completed: []std.atomic.Value(u8),
    pending: std.atomic.Value(u32) = .init(0),
    issued: std.atomic.Value(u32) = .init(0),
    wake: ?runtime.Wake = null,

    pub fn init(deadline_ns: i128, completed: []std.atomic.Value(u8)) Closing {
        std.debug.assert(completed.len != 0);
        for (completed) |*value| value.* = .init(0);
        return .{ .deadline_ns = deadline_ns, .completed = completed };
    }

    pub fn deadline(self: *const Closing) i128 {
        return self.deadline_ns;
    }

    pub fn readiness(self: *Closing) runtime.Readiness {
        return .{ .context = self, .bind_fn = bindReadiness };
    }

    pub fn preserveWake(self: *Closing, wake: ?runtime.Wake) void {
        self.wake = wake;
    }

    pub fn begin(self: *Closing) Token {
        const index = self.issued.fetchAdd(1, .monotonic);
        std.debug.assert(index < self.completed.len);
        self.completed[index].store(0, .release);
        const previous = self.pending.fetchAdd(1, .monotonic);
        std.debug.assert(previous < self.completed.len);
        return .{ .closing = self, .index = index };
    }

    pub fn complete(self: *const Closing) bool {
        return self.pending.load(.acquire) == 0;
    }

    fn bindReadiness(raw: *anyopaque, wake: runtime.Wake) runtime.Outcome {
        const self: *Closing = @ptrCast(@alignCast(raw));
        if (self.wake != null) return .failed;
        self.wake = wake;
        return .ok;
    }

    pub const Token = struct {
        closing: *Closing,
        index: u32,

        pub fn finish(self: Token) void {
            std.debug.assert(self.index < self.closing.completed.len);
            const previous_state = self.closing.completed[self.index].cmpxchgStrong(0, 1, .acq_rel, .acquire);
            std.debug.assert(previous_state == null);
            const wake = self.closing.wake;
            const previous = self.closing.pending.fetchSub(1, .release);
            std.debug.assert(previous > 0);
            if (previous != 1) return;
            if (wake) |value| value.signal();
        }
    };
};

test "checkpoint writers bind plugin namespaces in the persistence backend" {
    var memory: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try persistence.Store.initForTest(fixed.allocator(), .{
        .maximum_keys = 4,
        .maximum_checkpoint_records = 4,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 32,
        .maximum_key_bytes = 16,
        .maximum_value_bytes = 32,
        .maximum_checkpoint_bytes = 256,
    }, 1024);
    var writer = Checkpoint.Writer.init(store.interface(), std.testing.io);
    var plugin = try writer.bind("test:plugin");
    try plugin.put("state", "value");
    try std.testing.expectError(error.InvalidKey, plugin.batch(&.{
        .{ .key = "state", .operation = .{ .put = "invalid" } },
        .{ .namespace = "foreign", .key = "state", .operation = .delete },
    }));
    try std.testing.expectError(error.CapacityExceeded, plugin.batch(&.{
        .{ .key = "state", .operation = .{ .put = "invalid" } },
        .{ .key = "a", .operation = .delete },
        .{ .key = "b", .operation = .delete },
        .{ .key = "c", .operation = .delete },
        .{ .key = "d", .operation = .delete },
    }));
    try std.testing.expectEqual(@as(usize, 0), store.stagedRecords());
    var output: [8]u8 = undefined;
    const request = store.read("test:plugin", "state", &output);
    _ = store.complete(1);
    const result = store.pollRead(request);
    try std.testing.expectEqualStrings("value", output[0..result.bytes]);

    const empty = try persistence.Store.initIndex(fixed.allocator(), store.configuration);
    var empty_writer = Checkpoint.Writer.init(empty.interface(), std.testing.io);
    var empty_plugin = try empty_writer.bind("test:plugin");
    try empty.interface().drain(std.testing.io);
    try std.testing.expectError(error.CapacityExceeded, empty_plugin.batch(&.{
        .{ .key = "a", .operation = .delete },
        .{ .key = "b", .operation = .delete },
        .{ .key = "c", .operation = .delete },
        .{ .key = "d", .operation = .delete },
        .{ .key = "e", .operation = .delete },
    }));
    try std.testing.expectEqual(@as(usize, 0), empty.stagedRecords());
}

test "closing begins bounded worker cleanup without polling" {
    const Host = struct {
        signals: std.atomic.Value(u32) = .init(0),
        fn signal(raw: *anyopaque, _: std.Io) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.signals.fetchAdd(1, .monotonic);
        }
    };
    const Worker = struct {
        fn finish(token: Closing.Token) void {
            token.finish();
        }
    };
    var completed: [2]std.atomic.Value(u8) = undefined;
    var closing = Closing.init(1, &completed);
    var host = Host{};
    try std.testing.expectEqual(runtime.Outcome.ok, closing.readiness().bind(.{ .context = &host, .io = std.testing.io, .signal_fn = Host.signal }));
    const token = closing.begin();
    const last = closing.begin();
    const worker = try std.Thread.spawn(.{}, Worker.finish, .{token});
    worker.join();
    try std.testing.expect(!closing.complete());
    try std.testing.expectEqual(@as(u32, 0), host.signals.load(.acquire));
    const final_worker = try std.Thread.spawn(.{}, Worker.finish, .{last});
    final_worker.join();
    try std.testing.expect(closing.complete());
    try std.testing.expectEqual(@as(u32, 1), host.signals.load(.acquire));
}
