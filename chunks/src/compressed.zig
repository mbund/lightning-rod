const std = @import("std");
const records = @import("records");
const zstandard = @import("zstandard");
const metrics = @import("metrics");

pub const Backend = struct {
    pub const Configuration = struct { maximum: usize, batch_groups: usize, read_bytes: usize, write_bytes: ?usize = null, patch_bytes: usize = 0, metrics: ?*metrics.Registry = null };
    pub const write_batch_size = records.Table.write_batch_size;
    const Reader = struct { busy: bool = false, codec: zstandard.Decompressor, bytes: []u8, reads: []records.Get, frames: []?[]const u8, complete: []bool };
    table: records.Table,
    io: std.Io,
    readers: []Reader,
    compressor: zstandard.Compressor,
    staging: []u8,
    frame_bytes: usize,
    patch_bytes: usize,
    writes: []records.Write,
    writer_phase: std.atomic.Value(WritePhase) = .init(.idle),
    stride: usize,
    maximum: usize,
    capacity: usize,
    decoding: metrics.Timer,
    decoded_bytes: metrics.Counter,
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, table: records.Table, config: Configuration) !Backend {
        const maximum = config.maximum;
        const count = @min(config.batch_groups, 192);
        if (maximum == 0 or count == 0) return error.InvalidArgument;
        const stride = zstandard.bound(maximum);
        // Tail room for a maximum frame lets short frames share a batch without recompression.
        const write_bytes = config.write_bytes orelse try std.math.mul(usize, @min(count, 2), stride);
        if (write_bytes < stride) return error.InvalidArgument;
        const staging = try allocator.alloc(u8, @max(write_bytes, config.patch_bytes));
        errdefer allocator.free(staging);
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
            allocator.free(reader.frames);
            allocator.free(reader.complete);
        };
        for (readers) |*reader| {
            var codec = try zstandard.Decompressor.init(allocator);
            errdefer codec.deinit();
            const bytes = try allocator.alloc(u8, @max(stride, config.read_bytes));
            errdefer allocator.free(bytes);
            const reads = try allocator.alloc(records.Get, count);
            errdefer allocator.free(reads);
            const frames = try allocator.alloc(?[]const u8, count);
            errdefer allocator.free(frames);
            const complete = try allocator.alloc(bool, count);
            reader.* = .{ .codec = codec, .bytes = bytes, .reads = reads, .frames = frames, .complete = complete };
            initialized += 1;
        }
        return .{
            .table = table,
            .io = io,
            .readers = readers,
            .compressor = compressor,
            .staging = staging,
            .frame_bytes = write_bytes,
            .patch_bytes = config.patch_bytes,
            .writes = writes,
            .stride = stride,
            .maximum = maximum,
            .capacity = count,
            .decoding = if (config.metrics) |registry| try registry.timer(.{ .name = "chunks.bases.decode.cpu", .description = "Decompress stored chunk groups after batched reads", .clock = .thread_cpu, .detailed = true }) else .{},
            .decoded_bytes = if (config.metrics) |registry| try registry.counter(.{ .name = "chunks.bases.decoded_bytes", .description = "Decoded chunk group bytes including repeated cache fills", .unit = .bytes }) else .{},
        };
    }

    pub const WritePhase = enum(u8) { idle, frames, patches };
    pub const Staging = struct {
        owner: *Backend,
        phase: WritePhase,
        bytes: []u8,

        pub fn end(self: Staging) void {
            const previous = self.owner.writer_phase.swap(.idle, .release);
            std.debug.assert(previous == self.phase);
        }
    };

    /// Frame compression and patch publication share one serialized writer reservation.
    pub fn beginStaging(self: *Backend, phase: WritePhase) Staging {
        std.debug.assert(phase != .idle);
        const previous = self.writer_phase.swap(phase, .acq_rel);
        std.debug.assert(previous == .idle);
        const length = if (phase == .frames) self.frame_bytes else self.patch_bytes;
        std.debug.assert(length > 0 and length <= self.staging.len);
        return .{ .owner = self, .phase = phase, .bytes = self.staging[0..length] };
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

        pub fn readFrames(self: ReadLease, keys: []const []const u8, lengths: []?usize) !void {
            const owner = self.owner;
            const reader = &owner.readers[self.index];
            std.debug.assert(reader.busy and keys.len == lengths.len and keys.len <= owner.capacity);
            var output: records.PackedRead = .{ .bytes = reader.bytes, .values = reader.frames[0..keys.len], .complete = reader.complete[0..keys.len] };
            try owner.table.getPacked(keys, &output);
            for (reader.frames[0..keys.len], lengths) |frame_bytes, *length| {
                length.* = if (frame_bytes) |value| value.len else null;
                if (length.*) |size| if (size > owner.stride) return error.Corrupt;
            }
        }

        pub fn completed(self: ReadLease, index: usize) bool {
            std.debug.assert(self.owner.readers[self.index].busy and index < self.owner.capacity);
            return self.owner.readers[self.index].complete[index];
        }

        pub fn frame(self: ReadLease, index: usize, length: usize) []const u8 {
            std.debug.assert(self.owner.readers[self.index].busy);
            std.debug.assert(index < self.owner.capacity and length <= self.owner.stride);
            const value = self.owner.readers[self.index].frames[index].?;
            std.debug.assert(value.len == length);
            return value;
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
        std.debug.assert(requests.len == lengths.len);
        if (requests.len == 0) return;
        const lease = self.borrowRead();
        defer lease.end();
        const reader = &self.readers[lease.index];
        const reads = reader.reads;
        var begin: usize = 0;
        while (begin < requests.len) {
            const end = begin + @min(self.capacity, requests.len - begin);
            const batch = requests[begin..end];
            for (batch, reads[0..batch.len]) |request, *read| {
                std.debug.assert(request.destination.len >= self.stride and request.placement == .start);
                read.* = .{ .key = request.key, .destination = request.destination, .placement = .end };
            }
            try self.table.getBatch(reads[0..batch.len], lengths[begin..end]);
            const decoding = self.decoding.start();
            defer decoding.end();
            var decoded_bytes: usize = 0;
            for (batch, lengths[begin..end]) |request, *length| {
                const size = length.* orelse continue;
                const decoded = try reader.codec.decodeSuffix(request.destination, size, self.maximum, reader.bytes);
                length.* = decoded.len;
                decoded_bytes += decoded.len;
            }
            self.decoded_bytes.add(decoded_bytes);
            begin = end;
        }
    }

    pub fn putBatch(self: *Backend, writes: []const records.Write) !void {
        const staging = self.beginStaging(.frames);
        defer staging.end();
        var begin: usize = 0;
        while (begin < writes.len) {
            const encoded = self.writes;
            var count: usize = 0;
            var used: usize = 0;
            for (writes[begin..][0..@min(self.capacity, writes.len - begin)]) |write| {
                if (write.value) |value| {
                    if (value.len > self.maximum) return error.InvalidArgument;
                    const bound = zstandard.bound(value.len);
                    if (bound > staging.bytes.len - used) break;
                    const frame = try self.compressor.encode(value, staging.bytes[used..][0..bound]);
                    encoded[count] = .{ .key = write.key, .value = frame };
                    used += frame.len;
                } else encoded[count] = write;
                count += 1;
            }
            std.debug.assert(count > 0 and used <= staging.bytes.len);
            try self.table.putBatch(encoded[0..count]);
            begin += count;
        }
    }

    pub fn fail(self: *Backend) void {
        self.table.fail();
    }
};
