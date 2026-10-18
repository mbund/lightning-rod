const std = @import("std");
const storage = @import("storage");
const records = @import("records");

pub const References = struct {
    counts: records.Table,
    retired: records.Table,

    pub fn getBatch(self: References, requests: []const records.Get, lengths: []?usize) storage.Error!void {
        try self.counts.getBatch(requests, lengths);
    }
    pub fn putBatch(self: References, writes: []const records.Write) storage.Error!void {
        errdefer self.fail();
        var retired: [192]records.Write = undefined;
        if (writes.len > retired.len) return error.InvalidArgument;
        for (writes, retired[0..writes.len]) |write, *update| {
            const count = if (write.value) |bytes| count: {
                if (bytes.len != 8) return error.InvalidArgument;
                break :count std.mem.readInt(u64, bytes[0..8], .little);
            } else 1;
            update.* = .{ .key = write.key, .value = if (count == 0) "" else null };
        }
        try self.counts.putBatch(writes);
        try self.retired.putBatch(retired[0..writes.len]);
    }
    pub fn fail(self: References) void {
        self.counts.fail();
    }
};
