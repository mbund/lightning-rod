const std = @import("std");
const records = @import("records");
const zstandard = @import("zstandard");

pub const Backend = struct {
    pub const write_batch_size = records.Table.write_batch_size;
    const Reader = struct { busy: bool = false, codec: zstandard.Decompressor, bytes: []u8, reads: []records.Get };
    table: records.Table,
    io: std.Io,
    readers: []Reader,
    compressor: zstandard.Compressor,
    encoded: []u8,
    writes: []records.Write,
    writer_active: std.atomic.Value(bool) = .init(false),
    stride: usize,
    capacity: usize,
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, table: records.Table, maximum: usize, capacity: usize) !Backend {
        const count = @min(capacity, 192);
        const stride = zstandard.bound(maximum);
        const encoded = try allocator.alloc(u8, try std.math.mul(usize, count, stride));
        errdefer allocator.free(encoded);
        const writes = try allocator.alloc(records.Write, count);
        errdefer allocator.free(writes);
        var compressor = try zstandard.Compressor.init(allocator, 6, maximum);
        errdefer compressor.deinit();
        const readers = try allocator.alloc(Reader, table.resources.readers.slots.len);
        errdefer allocator.free(readers);
        var initialized: usize = 0;
        errdefer for (readers[0..initialized]) |*reader| {
            reader.codec.deinit();
            allocator.free(reader.bytes);
            allocator.free(reader.reads);
        };
        for (readers) |*reader| {
            var codec = try zstandard.Decompressor.init(allocator);
            errdefer codec.deinit();
            const bytes = try allocator.alloc(u8, encoded.len);
            errdefer allocator.free(bytes);
            const reads = try allocator.alloc(records.Get, count);
            reader.* = .{ .codec = codec, .bytes = bytes, .reads = reads };
            initialized += 1;
        }
        return .{ .table = table, .io = io, .readers = readers, .compressor = compressor, .encoded = encoded, .writes = writes, .stride = stride, .capacity = count };
    }

    pub const ReadLease = struct {
        owner: *Backend,
        index: usize,

        pub fn bytes(self: ReadLease) []u8 {
            std.debug.assert(self.owner.readers[self.index].busy);
            return self.owner.readers[self.index].bytes;
        }

        pub fn decode(self: ReadLease, input: []const u8, output: []u8) ![]const u8 {
            std.debug.assert(self.owner.readers[self.index].busy);
            return self.owner.readers[self.index].codec.decode(input, output);
        }

        pub fn end(self: ReadLease) void {
            const owner = self.owner;
            owner.mutex.lockUncancelable(owner.io);
            std.debug.assert(owner.readers[self.index].busy);
            owner.readers[self.index].busy = false;
            owner.available.signal(owner.io);
            owner.mutex.unlock(owner.io);
        }
    };

    pub fn borrowRead(self: *Backend) ReadLease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            for (self.readers, 0..) |*reader, index| if (!reader.busy) {
                reader.busy = true;
                return .{ .owner = self, .index = index };
            };
            self.available.waitUncancelable(self.io, &self.mutex);
        }
    }

    pub fn getBatch(self: *Backend, requests: []const records.Get, lengths: []?usize) !void {
        std.debug.assert(requests.len == lengths.len and requests.len <= self.capacity);
        const lease = self.borrowRead();
        defer lease.end();
        const reader = &self.readers[lease.index];
        const reads = reader.reads;
        for (requests, reads[0..requests.len], 0..) |request, *read, index| read.* = .{ .key = request.key, .destination = reader.bytes[index * self.stride ..][0..self.stride] };
        try self.table.getBatch(reads[0..requests.len], lengths);
        for (requests, lengths, 0..) |request, *length, index| {
            const size = length.* orelse continue;
            const decoded = try reader.codec.decode(reader.bytes[index * self.stride ..][0..size], request.destination);
            length.* = decoded.len;
        }
    }

    pub fn putBatch(self: *Backend, writes: []const records.Write) !void {
        const already_active = self.writer_active.swap(true, .acq_rel);
        std.debug.assert(!already_active);
        defer {
            const was_active = self.writer_active.swap(false, .release);
            std.debug.assert(was_active);
        }
        var begin: usize = 0;
        while (begin < writes.len) {
            const count = @min(self.capacity, writes.len - begin);
            const encoded = self.writes;
            for (writes[begin..][0..count], encoded[0..count], 0..) |write, *target, index| {
                target.* = write;
                if (write.value) |value| target.value = try self.compressor.encode(value, self.encoded[index * self.stride ..][0..self.stride]);
            }
            try self.table.putBatch(encoded[0..count]);
            begin += count;
        }
    }

    pub fn fail(self: *Backend) void {
        self.table.fail();
    }
};
