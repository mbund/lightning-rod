const persistence = @import("persistence.zig");
const runtime = @import("runtime/contracts.zig");
const std = @import("std");

pub const Checkpoint = struct {
    pub const Writer = struct {
        persistence: persistence.Interface,

        pub fn init(interface: persistence.Interface) Writer {
            return .{ .persistence = interface };
        }

        pub fn bind(self: *Writer, namespace: []const u8) Error!NamespaceWriter {
            if (namespace.len == 0) return error.InvalidKey;
            return .{ .namespace = self.persistence.namespace(namespace) };
        }
    };

    pub const NamespaceWriter = struct {
        namespace: persistence.Namespace,

        pub fn put(self: *NamespaceWriter, key: []const u8, value: []const u8) Error!void {
            if (key.len == 0) return error.InvalidKey;
            try require(self.namespace.stagePut(key, value));
        }

        pub fn delete(self: *NamespaceWriter, key: []const u8) Error!void {
            if (key.len == 0) return error.InvalidKey;
            try require(self.namespace.stageDelete(key));
        }
    };

    pub const Error = error{ CapacityExceeded, InvalidKey, Unavailable };

    fn require(status: persistence.Status) Error!void {
        switch (status) {
            .ready => {},
            .backpressured, .too_small => return error.CapacityExceeded,
            .failed => return error.Unavailable,
            .pending, .missing => unreachable,
        }
    }
};

pub const Closing = struct {
    deadline_ns: i128,
    io: std.Io,
    completed: []std.atomic.Value(u8),
    pending: std.atomic.Value(u32) = .init(0),
    issued: std.atomic.Value(u32) = .init(0),
    completion: std.Io.Event = .is_set,
    wake: ?runtime.Wake = null,

    pub fn init(deadline_ns: i128, io: std.Io, completed: []std.atomic.Value(u8)) Closing {
        std.debug.assert(completed.len != 0);
        for (completed) |*value| value.* = .init(0);
        return .{ .deadline_ns = deadline_ns, .io = io, .completed = completed };
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
        if (previous == 0) self.completion.reset();
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
            const previous = self.closing.pending.fetchSub(1, .release);
            std.debug.assert(previous > 0);
            if (previous != 1) return;
            self.closing.completion.set(self.closing.io);
            if (self.closing.wake) |wake| wake.signal();
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
    }, 1024);
    var writer = Checkpoint.Writer.init(store.interface());
    var plugin = try writer.bind("test:plugin");
    try plugin.put("state", "value");
    try std.testing.expectEqual(persistence.Status.pending, store.beginCheckpoint());
    store.submit();
    _ = store.complete(1);
    var output: [8]u8 = undefined;
    const request = store.read("test:plugin", "state", &output);
    _ = store.complete(1);
    const result = store.pollRead(request);
    try std.testing.expectEqualStrings("value", output[0..result.bytes]);
}

test "closing begins bounded worker cleanup without polling" {
    const Worker = struct {
        fn finish(token: Closing.Token) void {
            token.finish();
        }
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    var completed: [2]std.atomic.Value(u8) = undefined;
    var closing = Closing.init(1, io, &completed);
    const token = closing.begin();
    const worker = try std.Thread.spawn(.{}, Worker.finish, .{token});
    worker.join();
    try std.testing.expect(closing.complete());
}
