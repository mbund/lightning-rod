const std = @import("std");
const storage = @import("storage");

const index_bytes = 24 + storage.batch_size * 8;

/// Destinations remain borrowed until flush returns.
pub const ReadBatch = struct {
    const Blob = struct { id: u64, destination: []u8, offset: usize = 0 };

    space: storage.Space,
    reads: [storage.batch_size]storage.Read = undefined,
    count: usize = 0,
    blobs: [storage.batch_size]Blob = undefined,
    blob_count: usize = 0,

    fn flushPages(self: *ReadBatch) storage.Error!void {
        if (self.count == 0) return;
        try self.space.readPages(self.reads[0..self.count]);
        self.count = 0;
    }

    pub fn flush(self: *ReadBatch) storage.Error!void {
        var indices: [storage.batch_size][index_bytes]u8 = undefined;
        var selected: [storage.batch_size]usize = undefined;
        var cursor: usize = 0;
        while (true) {
            var count: usize = 0;
            for (0..self.blob_count) |step| {
                if (self.count == self.reads.len) break;
                const at = (cursor + step) % self.blob_count;
                const value = self.blobs[at];
                if (value.offset == value.destination.len) continue;
                selected[count] = at;
                self.reads[self.count] = .{ .id = @enumFromInt(value.id), .destination = &indices[count] };
                self.count += 1;
                count += 1;
            }
            if (self.count == 0) break;
            try self.flushPages();
            if (count != 0) cursor = (selected[count - 1] + 1) % self.blob_count;
            for (selected[0..count], indices[0..count]) |at, *index| {
                const value = &self.blobs[at];
                if (!std.mem.eql(u8, index[0..8], "LRBLOB01")) return error.Corrupt;
                const pages = std.mem.readInt(u32, index[16..20], .little);
                if (pages == 0 or pages > storage.batch_size or pages > std.math.divCeil(usize, value.destination.len - value.offset, storage.page_size) catch return error.Corrupt) return error.Corrupt;
                for (0..pages) |page| {
                    const length = @min(value.destination.len - value.offset, storage.page_size);
                    try self.append(@enumFromInt(std.mem.readInt(u64, index[24 + page * 8 ..][0..8], .little)), value.destination[value.offset..][0..length]);
                    value.offset += length;
                }
                value.id = std.mem.readInt(u64, index[8..16], .little);
                if ((value.offset == value.destination.len) != (value.id == 0)) return error.Corrupt;
            }
        }
        self.blob_count = 0;
    }

    pub fn append(self: *ReadBatch, id: storage.PageId, destination: []u8) storage.Error!void {
        std.debug.assert(destination.len <= storage.page_size);
        if (self.count == self.reads.len) try self.flushPages();
        self.reads[self.count] = .{ .id = id, .destination = destination };
        self.count += 1;
    }

    pub fn appendBlob(self: *ReadBatch, root: storage.PageId, length: usize, destination: []u8) storage.Error!usize {
        if (destination.len < length) return error.BufferTooSmall;
        if ((length == 0) != (@intFromEnum(root) == 0)) return error.Corrupt;
        if (length == 0) return 0;
        if (self.blob_count == self.blobs.len) try self.flush();
        self.blobs[self.blob_count] = .{ .id = @intFromEnum(root), .destination = destination[0..length] };
        self.blob_count += 1;
        return length;
    }
};

pub fn read(space: storage.Space, root: storage.PageId, length: usize, destination: []u8) storage.Error!usize {
    var batch: ReadBatch = .{ .space = space };
    const size = try batch.appendBlob(root, length, destination);
    try batch.flush();
    return size;
}

/// Reclaim independent overflow chains together before allocating their replacements.
pub const FreeBatch = struct {
    const Blob = struct { id: storage.PageId, remaining: usize };
    space: storage.Space,
    pages: [storage.batch_size]storage.PageId = undefined,
    count: usize = 0,
    blobs: [storage.batch_size]Blob = undefined,
    blob_count: usize = 0,

    pub fn appendPage(self: *FreeBatch, id: storage.PageId) storage.Error!void {
        if (self.count == self.pages.len) try self.flushPages();
        self.pages[self.count] = id;
        self.count += 1;
    }

    pub fn appendBlob(self: *FreeBatch, root: storage.PageId, length: usize) storage.Error!void {
        if ((length == 0) != (@intFromEnum(root) == 0)) return error.Corrupt;
        if (length == 0) return;
        if (self.blob_count == self.blobs.len) try self.flush();
        self.blobs[self.blob_count] = .{ .id = root, .remaining = length };
        self.blob_count += 1;
    }

    fn flushPages(self: *FreeBatch) storage.Error!void {
        if (self.count == 0) return;
        try self.space.freePages(self.pages[0..self.count]);
        self.count = 0;
    }

    pub fn flush(self: *FreeBatch) storage.Error!void {
        while (true) {
            var indices: [storage.batch_size][index_bytes]u8 = undefined;
            var requests: [storage.batch_size]storage.Read = undefined;
            var selected: [storage.batch_size]usize = undefined;
            var count: usize = 0;
            for (self.blobs[0..self.blob_count], 0..) |value, index| {
                if (value.remaining == 0) continue;
                selected[count] = index;
                requests[count] = .{ .id = value.id, .destination = &indices[count] };
                count += 1;
            }
            if (count == 0) break;
            try self.space.readPages(requests[0..count]);
            for (selected[0..count], indices[0..count]) |at, *index| {
                const value = &self.blobs[at];
                if (!std.mem.eql(u8, index[0..8], "LRBLOB01")) return error.Corrupt;
                const pages = std.mem.readInt(u32, index[16..20], .little);
                if (pages == 0 or pages > storage.batch_size or pages > std.math.divCeil(usize, value.remaining, storage.page_size) catch return error.Corrupt) return error.Corrupt;
                for (0..pages) |page| try self.appendPage(@enumFromInt(std.mem.readInt(u64, index[24 + page * 8 ..][0..8], .little)));
                try self.appendPage(value.id);
                value.remaining -= @min(value.remaining, @as(usize, pages) * storage.page_size);
                value.id = @enumFromInt(std.mem.readInt(u64, index[8..16], .little));
                if ((value.remaining == 0) != (@intFromEnum(value.id) == 0)) return error.Corrupt;
            }
        }
        self.blob_count = 0;
        try self.flushPages();
    }
};

pub fn free(space: storage.Space, root: storage.PageId, length: usize) storage.Error!void {
    var batch: FreeBatch = .{ .space = space };
    try batch.appendBlob(root, length);
    try batch.flush();
}

/// Payloads remain borrowed until flush returns.
pub const WriteBatch = struct {
    space: storage.Space,
    writes: *[storage.batch_size]storage.Write,
    count: usize = 0,
    indices: [storage.batch_size][index_bytes]u8 = undefined,
    index_count: usize = 0,

    pub fn flush(self: *WriteBatch) storage.Error!void {
        if (self.count == 0) return;
        try self.space.writePages(self.writes[0..self.count]);
        self.count = 0;
        self.index_count = 0;
    }

    pub fn append(self: *WriteBatch, id: storage.PageId, value: []const u8) storage.Error!void {
        std.debug.assert(value.len <= storage.page_size);
        if (self.count == self.writes.len) try self.flush();
        self.writes[self.count] = .{ .id = id, .source = value };
        self.count += 1;
    }

    pub fn write(self: *WriteBatch, value: []const u8) storage.Error!storage.PageId {
        if (value.len == 0) return error.InvalidArgument;
        var end = std.math.divCeil(usize, value.len, storage.page_size) catch return error.InvalidArgument;
        var previous: u64 = 0;
        while (end != 0) {
            const count: usize = @min(end, storage.batch_size - 1);
            const begin = end - count;
            var ids: [storage.batch_size]storage.PageId = undefined;
            try self.space.allocatePages(ids[0 .. count + 1]);
            for (ids[0..count], 0..) |id, at| {
                const offset = (begin + at) * storage.page_size;
                const length = @min(value.len - offset, storage.page_size);
                try self.append(id, value[offset..][0..length]);
            }
            if (self.count == self.writes.len) try self.flush();
            std.debug.assert(self.index_count < self.indices.len);
            const index = &self.indices[self.index_count];
            self.index_count += 1;
            @memset(index, 0);
            @memcpy(index[0..8], "LRBLOB01");
            std.mem.writeInt(u64, index[8..16], previous, .little);
            std.mem.writeInt(u32, index[16..20], @intCast(count), .little);
            for (ids[0..count], 0..) |id, at| std.mem.writeInt(u64, index[24 + at * 8 ..][0..8], @intFromEnum(id), .little);
            try self.append(ids[count], index);
            previous = @intFromEnum(ids[count]);
            end = begin;
        }
        return @enumFromInt(previous);
    }
};

pub fn write(space: storage.Space, value: []const u8) storage.Error!storage.PageId {
    var writes: [storage.batch_size]storage.Write = undefined;
    var batch: WriteBatch = .{ .space = space, .writes = &writes };
    const root = try batch.write(value);
    try batch.flush();
    return root;
}
