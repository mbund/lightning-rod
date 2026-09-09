const std = @import("std");
const connection = @import("lightning_rod").connection;

pub const magic = "LRRSUME1";
pub const version: u16 = 2;
pub const header_bytes = magic.len + 2 + 2 + 4 + 4 + 8 + 4;
pub const record_bytes = 4 + 4 + 4 + 4 + 4 + 4 + 2 + 4;

pub const Error = error{
    BufferTooSmall,
    TooManyRecords,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    InvalidChecksum,
    InvalidRecord,
    TrailingBytes,
};

pub const Record = struct {
    fd: std.posix.fd_t,
    connection: connection.Handle,
    unread: []const u8,
    output: []const u8,
    session_id: u32,
    session_version: u16,
    continuation: []const u8,
};

pub const Encoder = struct {
    bytes: []u8,
    cursor: usize = header_bytes,
    count: u32 = 0,
    listener_fd: std.posix.fd_t,

    pub fn init(bytes: []u8, listener_fd: std.posix.fd_t) Error!Encoder {
        if (bytes.len < header_bytes) return error.BufferTooSmall;
        if (listener_fd < 0) return error.InvalidRecord;
        @memset(bytes, 0);
        return .{ .bytes = bytes, .listener_fd = listener_fd };
    }

    pub fn append(self: *Encoder, record: Record) Error!void {
        if (self.count == std.math.maxInt(u32)) return error.TooManyRecords;
        if (record.fd < 0 or record.unread.len > std.math.maxInt(u32) or
            record.output.len > std.math.maxInt(u32) or
            record.continuation.len > std.math.maxInt(u32)) return error.InvalidRecord;
        try self.putU32(@bitCast(record.fd));
        try self.putU32(record.connection.index);
        try self.putU32(record.connection.generation);
        try self.putU32(@intCast(record.unread.len));
        try self.putU32(@intCast(record.output.len));
        try self.putU32(record.session_id);
        try self.putU16(record.session_version);
        try self.putU32(@intCast(record.continuation.len));
        try self.put(record.unread);
        try self.put(record.output);
        try self.put(record.continuation);
        self.count += 1;
    }

    pub fn finish(self: *Encoder) Error![]const u8 {
        const total = self.cursor - header_bytes;
        if (total > std.math.maxInt(u32)) return error.BufferTooSmall;
        @memcpy(self.bytes[0..magic.len], magic);
        writeU16(self.bytes[magic.len..][0..2], version);
        writeU16(self.bytes[magic.len + 2 ..][0..2], header_bytes);
        writeU32(self.bytes[magic.len + 4 ..][0..4], self.count);
        writeU32(self.bytes[magic.len + 8 ..][0..4], @intCast(total));
        writeU64(self.bytes[magic.len + 12 ..][0..8], checksum(self.bytes[header_bytes..self.cursor]));
        writeU32(self.bytes[magic.len + 20 ..][0..4], @bitCast(self.listener_fd));
        return self.bytes[0..self.cursor];
    }

    fn put(self: *Encoder, source: []const u8) Error!void {
        if (source.len > self.bytes.len -| self.cursor) return error.BufferTooSmall;
        @memcpy(self.bytes[self.cursor..][0..source.len], source);
        self.cursor += source.len;
    }

    fn putU16(self: *Encoder, value: u16) Error!void {
        var bytes: [2]u8 = undefined;
        writeU16(&bytes, value);
        try self.put(&bytes);
    }

    fn putU32(self: *Encoder, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        writeU32(&bytes, value);
        try self.put(&bytes);
    }
};

pub const Decoder = struct {
    bytes: []const u8,
    cursor: usize = header_bytes,
    remaining: u32,
    listener_fd: std.posix.fd_t,

    pub fn init(bytes: []const u8) Error!Decoder {
        if (bytes.len < header_bytes) return error.InvalidHeader;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidMagic;
        if (readU16(bytes[magic.len..][0..2]) != version) return error.UnsupportedVersion;
        if (readU16(bytes[magic.len + 2 ..][0..2]) != header_bytes) return error.InvalidHeader;
        const count = readU32(bytes[magic.len + 4 ..][0..4]);
        const records_len: usize = readU32(bytes[magic.len + 8 ..][0..4]);
        if (records_len != bytes.len - header_bytes) return error.InvalidHeader;
        if (@as(usize, count) > records_len / record_bytes) return error.InvalidHeader;
        if (readU64(bytes[magic.len + 12 ..][0..8]) != checksum(bytes[header_bytes..])) return error.InvalidChecksum;
        const listener_fd: std.posix.fd_t = @bitCast(readU32(bytes[magic.len + 20 ..][0..4]));
        if (listener_fd < 0) return error.InvalidHeader;
        return .{ .bytes = bytes, .remaining = count, .listener_fd = listener_fd };
    }

    pub fn listenerFd(self: *const Decoder) std.posix.fd_t {
        return self.listener_fd;
    }

    pub fn next(self: *Decoder) Error!?Record {
        if (self.remaining == 0) {
            if (self.cursor != self.bytes.len) return error.TrailingBytes;
            return null;
        }
        const fd_bits = try self.takeU32();
        const index = try self.takeU32();
        const generation = try self.takeU32();
        const unread_len = try self.takeU32();
        const output_len = try self.takeU32();
        const session_id = try self.takeU32();
        const session_version = try self.takeU16();
        const continuation_len = try self.takeU32();
        const result = Record{
            .fd = @bitCast(fd_bits),
            .connection = .{ .index = index, .generation = generation },
            .unread = try self.take(unread_len),
            .output = try self.take(output_len),
            .session_id = session_id,
            .session_version = session_version,
            .continuation = try self.take(continuation_len),
        };
        if (result.fd < 0 or result.connection.generation == 0) return error.InvalidRecord;
        self.remaining -= 1;
        return result;
    }

    fn take(self: *Decoder, count: u32) Error![]const u8 {
        const len: usize = count;
        if (len > self.bytes.len -| self.cursor) return error.InvalidRecord;
        const result = self.bytes[self.cursor..][0..len];
        self.cursor += len;
        return result;
    }

    fn takeU16(self: *Decoder) Error!u16 {
        return readU16(try self.take(2));
    }
    fn takeU32(self: *Decoder) Error!u32 {
        return readU32(try self.take(4));
    }
};

fn writeU16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
}
fn writeU32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}
fn writeU64(bytes: []u8, value: u64) void {
    std.mem.writeInt(u64, bytes[0..8], value, .little);
}
fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}
fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn checksum(bytes: []const u8) u64 {
    var value: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |byte| {
        value ^= byte;
        value *%= 0x0000_0100_0000_01b3;
    }
    return value;
}

test "resume envelope preserves exact raw transport and opaque session bytes" {
    var storage: [256]u8 = undefined;
    var encoder = try Encoder.init(&storage, 5);
    try encoder.append(.{ .fd = 7, .connection = .{ .index = 4, .generation = 9 }, .unread = "unread", .output = "queued", .session_id = 17, .session_version = 3, .continuation = "opaque" });
    var decoder = try Decoder.init(try encoder.finish());
    try std.testing.expectEqual(@as(std.posix.fd_t, 5), decoder.listenerFd());
    const record = (try decoder.next()).?;
    try std.testing.expectEqual(@as(std.posix.fd_t, 7), record.fd);
    try std.testing.expect(record.connection.eql(.{ .index = 4, .generation = 9 }));
    try std.testing.expectEqualStrings("unread", record.unread);
    try std.testing.expectEqualStrings("queued", record.output);
    try std.testing.expectEqual(@as(u32, 17), record.session_id);
    try std.testing.expectEqual(@as(u16, 3), record.session_version);
    try std.testing.expectEqualStrings("opaque", record.continuation);
    try std.testing.expect((try decoder.next()) == null);
}

test "resume envelope rejects corruption before exposing a record" {
    var storage: [128]u8 = undefined;
    var encoder = try Encoder.init(&storage, 5);
    try encoder.append(.{ .fd = 3, .connection = .{ .index = 0, .generation = 1 }, .unread = "", .output = "", .session_id = 1, .session_version = 1, .continuation = "x" });
    const bytes = try encoder.finish();
    storage[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidChecksum, Decoder.init(bytes));
}

test "resume envelope rejects an impossible record count before iteration" {
    var storage: [header_bytes]u8 = undefined;
    var encoder = try Encoder.init(&storage, 5);
    const bytes = try encoder.finish();
    writeU32(storage[magic.len + 4 ..][0..4], 1);
    try std.testing.expectError(error.InvalidHeader, Decoder.init(bytes));
}
