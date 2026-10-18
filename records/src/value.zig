const std = @import("std");
const storage = @import("storage");
const blob = @import("blob.zig");

const inline_bytes = storage.page_size - 24;

pub const Value = struct {
    space: storage.Space,

    pub fn init(space: storage.Space) Value {
        return .{ .space = space };
    }

    pub fn read(self: Value, destination: []u8) storage.Error!?usize {
        const id = try self.space.getRoot() orelse return null;
        var page: storage.Page = undefined;
        try self.space.readPages(&.{.{ .id = id, .destination = &page }});
        if (!std.mem.eql(u8, page[0..8], "LRVALUE1")) return error.Corrupt;
        const length = std.mem.readInt(u32, page[12..16], .little);
        const reference = std.mem.readInt(u64, page[16..24], .little);
        if (length > destination.len) return error.BufferTooSmall;
        if (length <= inline_bytes) {
            if (reference != 0) return error.Corrupt;
            @memcpy(destination[0..length], page[24..][0..length]);
            return length;
        }
        if (reference == 0) return error.Corrupt;
        return try blob.read(self.space, @enumFromInt(reference), length, destination);
    }

    pub fn write(self: Value, bytes: []const u8) storage.Error!void {
        errdefer self.space.fail();
        if (bytes.len > std.math.maxInt(u32)) return error.InvalidArgument;
        const previous = try self.space.getRoot();
        var page: storage.Page = @splat(0);
        if (previous) |id| {
            try self.space.readPages(&.{.{ .id = id, .destination = &page }});
            if (!std.mem.eql(u8, page[0..8], "LRVALUE1")) return error.Corrupt;
            const length = std.mem.readInt(u32, page[12..16], .little);
            const reference = std.mem.readInt(u64, page[16..24], .little);
            if (length > inline_bytes) {
                if (reference == 0) return error.Corrupt;
                try blob.free(self.space, @enumFromInt(reference), length);
            } else if (reference != 0) return error.Corrupt;
        }
        @memset(&page, 0);
        @memcpy(page[0..8], "LRVALUE1");
        std.mem.writeInt(u32, page[12..16], @intCast(bytes.len), .little);
        if (bytes.len <= inline_bytes) @memcpy(page[24..][0..bytes.len], bytes) else {
            const id = try blob.write(self.space, bytes);
            std.mem.writeInt(u64, page[16..24], @intFromEnum(id), .little);
        }
        const id = previous orelse blk: {
            var ids: [1]storage.PageId = undefined;
            try self.space.allocatePages(&ids);
            break :blk ids[0];
        };
        try self.space.writePages(&.{.{ .id = id, .source = &page }});
        if (previous == null) try self.space.setRoot(id);
    }
};
