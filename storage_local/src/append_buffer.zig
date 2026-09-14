const std = @import("std");
const storage = @import("storage");

const assert = std.debug.assert;

const Buffer = @This();
bytes: []u8,
offset: u64 = 0,
used: usize = 0,
writes: u64 = 0,
written_bytes: u64 = 0,

pub fn reset(self: *Buffer, offset: u64) void {
    self.offset = offset;
    self.used = 0;
}

pub fn flush(self: *Buffer, file: std.Io.File, io: std.Io) storage.Error!void {
    if (self.used == 0) return;
    file.writePositionalAll(io, self.bytes[0..self.used], self.offset) catch return error.IoFailure;
    self.writes += 1;
    self.written_bytes += self.used;
    self.offset += self.used;
    self.used = 0;
}

pub fn append(self: *Buffer, file: std.Io.File, io: std.Io, bytes: []const u8) storage.Error!void {
    assert(self.used <= self.bytes.len);

    if (bytes.len > self.bytes.len - self.used) try self.flush(file, io);

    if (bytes.len > self.bytes.len) {
        assert(self.used == 0);
        file.writePositionalAll(io, bytes, self.offset) catch return error.IoFailure;
        self.writes += 1;
        self.written_bytes += bytes.len;
        self.offset += bytes.len;
    } else {
        // Caller storage may be reused immediately. This buffer owns staged bytes.
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }
}

pub fn read(self: *const Buffer, file: std.Io.File, io: std.Io, out: []u8, offset: u64) storage.Error!void {
    const end = std.math.add(u64, offset, out.len) catch return error.Corrupt;
    if (end > self.offset + self.used) return error.Corrupt;

    const disk_bytes: usize = if (offset < self.offset) @intCast(@min(out.len, self.offset - offset)) else 0;
    if (disk_bytes != 0 and (file.readPositionalAll(io, out[0..disk_bytes], offset) catch return error.IoFailure) != disk_bytes)
        return error.Corrupt;

    const staged_bytes = out.len - disk_bytes;

    if (staged_bytes != 0) {
        const start: usize = @intCast(offset + disk_bytes - self.offset);
        @memcpy(out[disk_bytes..], self.bytes[start..][0..staged_bytes]);
    }
}
