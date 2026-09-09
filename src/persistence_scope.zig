const std = @import("std");
const persistence = @import("persistence.zig");

const Binding = struct { logical: []const u8, physical: []const u8 };

/// One serial caller owns the adapter scratch. The backing Access retains its
/// own concurrency contract; namespacing does not make a backend thread-safe.
pub const Scope = struct {
    parent: *const persistence.Access,
    bindings: []Binding,
    reads: []persistence.Read,
    writes: []persistence.CheckpointRecord,
    storage: []u8,

    pub fn init(allocator: std.mem.Allocator, parent: *const persistence.Access, identity: []const u8, namespaces: []const []const u8, maximum_namespace_bytes: usize, maximum_batch_records: usize) !*Scope {
        if (identity.len > std.math.maxInt(u16) or maximum_batch_records == 0 or namespaces.len == 0)
            return error.InvalidScopeCapacity;
        var bytes: usize = 0;
        for (namespaces, 0..) |namespace, index| {
            if (namespace.len == 0 or namespace.len > std.math.maxInt(u16)) return error.InvalidNamespace;
            const encoded_length = 8 + identity.len + namespace.len;
            if (encoded_length > maximum_namespace_bytes) return error.NamespaceTooLong;
            bytes = try std.math.add(usize, bytes, encoded_length);
            for (namespaces[0..index]) |previous|
                if (std.mem.eql(u8, previous, namespace)) return error.DuplicateNamespace;
        }
        const self = try allocator.create(Scope);
        errdefer allocator.destroy(self);
        const bindings = try allocator.alloc(Binding, namespaces.len);
        errdefer allocator.free(bindings);
        const reads = try allocator.alloc(persistence.Read, maximum_batch_records);
        errdefer allocator.free(reads);
        const writes = try allocator.alloc(persistence.CheckpointRecord, maximum_batch_records);
        errdefer allocator.free(writes);
        const storage = try allocator.alloc(u8, bytes);
        var offset: usize = 0;
        for (namespaces, bindings) |namespace, *binding| {
            const value = storage[offset..][0 .. 8 + identity.len + namespace.len];
            value[0..4].* = .{ 'L', 'R', 'N', 1 };
            std.mem.writeInt(u16, value[4..6], @intCast(identity.len), .little);
            @memcpy(value[6..][0..identity.len], identity);
            const tail = value[6 + identity.len ..];
            std.mem.writeInt(u16, tail[0..2], @intCast(namespace.len), .little);
            @memcpy(tail[2..], namespace);
            binding.* = .{ .logical = tail[2..], .physical = value };
            offset += value.len;
        }
        self.* = .{ .parent = parent, .bindings = bindings, .reads = reads, .writes = writes, .storage = storage };
        return self;
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        allocator.free(self.writes);
        allocator.free(self.reads);
        allocator.free(self.bindings);
        allocator.destroy(self);
    }

    pub fn access(self: *Scope) persistence.Access {
        return persistence.Access.init(.{
            .interface = self.interface(),
            .loader = .{ .context = self, .read_fn = load },
            .maximum_checkpoint_records = @min(self.parent.maximum_checkpoint_records, self.writes.len),
        });
    }

    pub fn interface(self: *Scope) persistence.Interface {
        return .{ .context = self, .vtable = &vtable };
    }

    fn resolve(self: *const Scope, namespace: []const u8) ?[]const u8 {
        for (self.bindings) |binding|
            if (std.mem.eql(u8, binding.logical, namespace)) return binding.physical;
        return null;
    }

    fn load(raw: *anyopaque, namespace: []const u8, key: []const u8, destination: []u8) persistence.LoadError!persistence.LoadResult {
        const self: *Scope = @ptrCast(@alignCast(raw));
        return self.parent.load(self.resolve(namespace) orelse return error.InvalidKey, key, destination);
    }

    fn length(raw: *const anyopaque, namespace: []const u8, key: []const u8) ?usize {
        const self: *const Scope = @ptrCast(@alignCast(raw));
        return self.parent.interface.length(self.resolve(namespace) orelse return null, key);
    }

    fn readBatch(raw: *anyopaque, batch: persistence.ReadBatch, requests: []persistence.Request) persistence.Status {
        const self: *Scope = @ptrCast(@alignCast(raw));
        if (batch.records.len > self.reads.len) return .backpressured;
        if (batch.namespace) |namespace| {
            const physical = self.resolve(namespace) orelse return .failed;
            var explicit = false;
            for (batch.records) |record| explicit = explicit or record.namespace.len != 0;
            if (!explicit) return self.parent.interface.vtable.read_batch(self.parent.interface.context, .{ .namespace = physical, .records = batch.records }, requests);
        }
        for (batch.records, self.reads[0..batch.records.len]) |record, *mapped| {
            const namespace = batch.namespace orelse record.namespace;
            if (batch.namespace != null and record.namespace.len != 0 and !std.mem.eql(u8, namespace, record.namespace)) return .failed;
            mapped.* = record;
            mapped.namespace = self.resolve(namespace) orelse return .failed;
        }
        return self.parent.interface.readBatch(self.reads[0..batch.records.len], requests);
    }

    fn poll(raw: *anyopaque, request: persistence.Request) persistence.ReadResult {
        const self: *Scope = @ptrCast(@alignCast(raw));
        return self.parent.interface.pollRead(request);
    }

    fn scan(raw: *const anyopaque, namespace: []const u8, after: []const u8, records: []persistence.ScanRecord) persistence.ScanError!persistence.ScanResult {
        const self: *const Scope = @ptrCast(@alignCast(raw));
        return self.parent.interface.scan(self.resolve(namespace) orelse return error.InvalidNamespace, after, records);
    }

    fn reserve(raw: *anyopaque, batch: persistence.WriteBatch) persistence.ReserveError!persistence.WriteReservation {
        const self: *Scope = @ptrCast(@alignCast(raw));
        if (batch.records.len > self.writes.len) return error.Backpressured;
        if (batch.namespace) |namespace| {
            const physical = self.resolve(namespace) orelse return error.InvalidKey;
            var explicit = false;
            for (batch.records) |record| explicit = explicit or record.namespace.len != 0;
            if (!explicit) return self.parent.interface.vtable.reserve(self.parent.interface.context, .{ .namespace = physical, .records = batch.records });
        }
        for (batch.records, self.writes[0..batch.records.len]) |record, *mapped| {
            const namespace = batch.namespace orelse record.namespace;
            if (batch.namespace != null and record.namespace.len != 0 and !std.mem.eql(u8, namespace, record.namespace)) return error.InvalidKey;
            mapped.* = record;
            mapped.namespace = self.resolve(namespace) orelse return error.InvalidKey;
        }
        return self.parent.interface.reserve(self.writes[0..batch.records.len]);
    }

    fn publish(raw: *anyopaque, reservation: persistence.WriteReservation) void {
        const self: *Scope = @ptrCast(@alignCast(raw));
        self.parent.interface.publish(reservation);
    }
    fn cancel(raw: *anyopaque, reservation: persistence.WriteReservation) void {
        const self: *Scope = @ptrCast(@alignCast(raw));
        self.parent.interface.cancel(reservation);
    }
    fn flush(raw: *anyopaque) persistence.Status {
        const self: *Scope = @ptrCast(@alignCast(raw));
        return self.parent.interface.flush();
    }
    fn drain(raw: *anyopaque, io: std.Io) persistence.DrainError!void {
        const self: *Scope = @ptrCast(@alignCast(raw));
        return self.parent.interface.drain(io);
    }
    fn checkpoint(raw: *anyopaque) persistence.Status {
        const self: *Scope = @ptrCast(@alignCast(raw));
        return self.parent.interface.requestCheckpoint();
    }
    fn progress(raw: *anyopaque) persistence.Status {
        const self: *Scope = @ptrCast(@alignCast(raw));
        return self.parent.interface.checkpointProgress();
    }
    fn poisoned(raw: *const anyopaque) bool {
        const self: *const Scope = @ptrCast(@alignCast(raw));
        return self.parent.interface.poisoned();
    }

    const vtable: persistence.Interface.VTable = .{
        .length = length,
        .read_batch = readBatch,
        .poll_read = poll,
        .scan = scan,
        .reserve = reserve,
        .publish = publish,
        .cancel = cancel,
        .flush = flush,
        .drain = drain,
        .request_checkpoint = checkpoint,
        .checkpoint_progress = progress,
        .poisoned = poisoned,
    };
};

test "Core persistence scopes isolate namespace bytes across batches scans and startup loads" {
    const Loader = struct {
        fn read(raw: *anyopaque, namespace: []const u8, key: []const u8, destination: []u8) persistence.LoadError!persistence.LoadResult {
            const store: *persistence.Store = @ptrCast(@alignCast(raw));
            const request = store.read(namespace, key, destination);
            _ = store.complete(1);
            const result = store.pollRead(request);
            return switch (result.status) {
                .ready => .{ .value = result.bytes },
                .missing => .missing,
                .too_small => error.DestinationTooSmall,
                else => error.ReadFailed,
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const store = try persistence.Store.initForTest(arena.allocator(), .{
        .maximum_keys = 8,
        .maximum_checkpoint_records = 8,
        .maximum_requests = 8,
        .maximum_namespace_bytes = 32,
        .maximum_key_bytes = 16,
        .maximum_value_bytes = 16,
        .maximum_checkpoint_bytes = 1024,
    }, 4096);
    const parent = persistence.Access.init(.{ .interface = store.interface(), .loader = .{ .context = store, .read_fn = Loader.read }, .maximum_checkpoint_records = 8 });
    const a = try Scope.init(std.testing.allocator, &parent, "a", &.{ "bc", "same" }, 32, 2);
    defer a.deinit(std.testing.allocator);
    const b = try Scope.init(std.testing.allocator, &parent, "ab", &.{ "c", "same" }, 32, 2);
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, a.resolve("bc").?, b.resolve("c").?));
    const one = a.interface();
    const two = b.interface();
    try std.testing.expectEqual(persistence.Status.ready, one.stageBatch(&.{
        .{ .namespace = "bc", .key = "key", .operation = .{ .put = "alpha" } },
        .{ .namespace = "same", .key = "state", .operation = .{ .put = "one" } },
    }));
    try std.testing.expectEqual(persistence.Status.ready, two.namespace("c").stagePut("key", "beta"));
    const reservation = try two.namespace("same").reserve(&.{.{ .namespace = "same", .key = "state", .operation = .{ .put = "two" } }});
    two.publish(reservation);
    const cancelled = try one.namespace("same").reserve(&.{.{ .key = "state", .operation = .{ .put = "cancelled" } }});
    one.cancel(cancelled);
    try std.testing.expectError(error.InvalidKey, one.namespace("same").reserve(&.{.{ .namespace = "bc", .key = "state", .operation = .delete }}));
    try std.testing.expectError(error.InvalidKey, one.reserve(&.{.{ .namespace = "unknown", .key = "state", .operation = .delete }}));
    var first: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    var requests: [2]persistence.Request = undefined;
    try std.testing.expectEqual(persistence.Status.ready, one.readBatch(&.{
        .{ .namespace = "bc", .key = "key", .destination = &first },
        .{ .namespace = "same", .key = "state", .destination = &second },
    }, &requests));
    _ = store.complete(2);
    try std.testing.expectEqualStrings("alpha", first[0..one.pollRead(requests[0]).bytes]);
    try std.testing.expectEqualStrings("one", second[0..one.pollRead(requests[1]).bytes]);
    const access = b.access();
    const loaded = try access.plugin("same").load("state", &first);
    try std.testing.expectEqualStrings("two", first[0..loaded.value]);
    var records: [2]persistence.ScanRecord = undefined;
    const scan = try two.namespace("c").scan("", &records);
    try std.testing.expectEqual(@as(usize, 1), scan.count);
    try std.testing.expectEqualStrings("key", records[0].key);
    try std.testing.expectEqual(@as(usize, 4), records[0].value_bytes);
    try std.testing.expectError(error.InvalidNamespace, one.scan("unknown", "", &records));
    try std.testing.expectEqual(@as(?usize, 3), one.namespace("same").length("state"));
    try std.testing.expectError(error.DuplicateNamespace, Scope.init(std.testing.allocator, &parent, "a", &.{ "same", "same" }, 32, 2));
    try std.testing.expectError(error.NamespaceTooLong, Scope.init(std.testing.allocator, &parent, "a", &.{"same"}, 8, 2));
    store.markFailed();
    try std.testing.expectError(error.ReadFailed, access.plugin("same").load("state", &first));
}
