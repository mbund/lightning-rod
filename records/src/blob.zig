const std = @import("std");
const storage = @import("storage");

pub const ReadBatch = struct {
    space: storage.Space,
    reads: [storage.batch_size]storage.Read = undefined,
    count: usize = 0,

    pub fn flush(self: *ReadBatch) storage.Error!void {
        if (self.count == 0) return;
        try self.space.readPages(self.reads[0..self.count]);
        self.count = 0;
    }

    pub fn append(self: *ReadBatch, id: storage.PageId, destination: []u8) storage.Error!void {
        std.debug.assert(destination.len <= storage.page_size);
        if (self.count == self.reads.len) try self.flush();
        self.reads[self.count] = .{ .id = id, .destination = destination };
        self.count += 1;
    }

    pub fn appendBlob(self: *ReadBatch, root: storage.PageId, length: usize, destination: []u8) storage.Error!usize {
        if (destination.len < length) return error.BufferTooSmall;
        var id = @intFromEnum(root);
        var offset: usize = 0;
        while (offset < length) {
            if (id == 0) return error.Corrupt;
            var index: storage.Page = undefined;
            try self.space.readPages(&.{.{ .id = @enumFromInt(id), .destination = &index }});
            if (!std.mem.eql(u8, index[0..8], "LRBLOB01")) return error.Corrupt;
            const count = std.mem.readInt(u32, index[16..20], .little);
            if (count == 0 or count > storage.batch_size or count > std.math.divCeil(usize, length - offset, storage.page_size) catch return error.Corrupt) return error.Corrupt;
            for (0..count) |at| {
                const size = @min(length - offset, storage.page_size);
                try self.append(@enumFromInt(std.mem.readInt(u64, index[24 + at * 8 ..][0..8], .little)), destination[offset..][0..size]);
                offset += size;
            }
            id = std.mem.readInt(u64, index[8..16], .little);
        }
        if (id != 0) return error.Corrupt;
        return length;
    }
};

pub fn read(space: storage.Space, root: storage.PageId, length: usize, destination: []u8) storage.Error!usize {
    var batch: ReadBatch = .{ .space = space };
    const size = try batch.appendBlob(root, length, destination);
    try batch.flush();
    return size;
}

pub fn free(space: storage.Space, root: storage.PageId, length: usize) storage.Error!void {
    var id = @intFromEnum(root);
    var left: usize = length;
    while (left != 0) {
        if (id == 0) return error.Corrupt;
        var index: storage.Page = undefined;
        try space.readPages(&.{.{ .id = @enumFromInt(id), .destination = &index }});
        if (!std.mem.eql(u8, index[0..8], "LRBLOB01")) return error.Corrupt;
        const count = std.mem.readInt(u32, index[16..20], .little);
        if (count == 0 or count > storage.batch_size or count > std.math.divCeil(usize, left, storage.page_size) catch return error.Corrupt) return error.Corrupt;
        var ids: [storage.batch_size + 1]storage.PageId = undefined;
        for (ids[0..count], 0..) |*page, at| page.* = @enumFromInt(std.mem.readInt(u64, index[24 + at * 8 ..][0..8], .little));
        ids[count] = @enumFromInt(id);
        try space.freePages(ids[0 .. count + 1]);
        left -= @min(left, @as(usize, count) * storage.page_size);
        id = std.mem.readInt(u64, index[8..16], .little);
    }
    if (id != 0) return error.Corrupt;
}

pub fn write(space: storage.Space, value: []const u8) storage.Error!storage.PageId {
    if (value.len == 0) return error.InvalidArgument;
    var end = std.math.divCeil(usize, value.len, storage.page_size) catch return error.InvalidArgument;
    var previous: u64 = 0;
    var pages: [storage.batch_size]storage.Page = undefined;
    var writes: [storage.batch_size]storage.Write = undefined;
    while (end != 0) {
        const count = @min(end, storage.batch_size);
        const begin = end - count;
        var ids: [storage.batch_size + 1]storage.PageId = undefined;
        try space.allocatePages(ids[0 .. count + 1]);
        for (ids[0..count], pages[0..count], writes[0..count], 0..) |id, *page, *request, at| {
            const offset = (begin + at) * storage.page_size;
            const length = @min(value.len - offset, page.len);
            @memcpy(page[0..length], value[offset..][0..length]);
            @memset(page[length..], 0);
            request.* = .{ .id = id, .source = page };
        }
        try space.writePages(writes[0..count]);
        var index: storage.Page = @splat(0);
        @memcpy(index[0..8], "LRBLOB01");
        std.mem.writeInt(u64, index[8..16], previous, .little);
        std.mem.writeInt(u32, index[16..20], @intCast(count), .little);
        for (ids[0..count], 0..) |id, at| std.mem.writeInt(u64, index[24 + at * 8 ..][0..8], @intFromEnum(id), .little);
        try space.writePages(&.{.{ .id = ids[count], .source = &index }});
        previous = @intFromEnum(ids[count]);
        end = begin;
    }
    return @enumFromInt(previous);
}
