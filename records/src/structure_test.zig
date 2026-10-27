const std = @import("std");
const storage = @import("storage");
const records = @import("records");

pub const Shape = struct {
    pages: usize = 0,
    records: usize = 0,
    height: usize = 0,
    used_bytes: usize = 0,
};

const Key = struct {
    bytes: [64]u8 = undefined,
    length: usize = 0,

    fn slice(self: *const Key) []const u8 {
        return self.bytes[0..self.length];
    }
};

const Inspector = struct {
    space: storage.Space,
    seen: []bool,
    shape: Shape = .{},
    next_leaf: u64 = 0,
    last_key: Key = .{},

    fn claim(self: *Inspector, id: u64) !void {
        if (id == 0 or id >= self.seen.len or self.seen[@intCast(id)]) return error.Corrupt;
        self.seen[@intCast(id)] = true;
    }

    fn data(self: *Inspector, id: u64) !void {
        try self.claim(id);
        var page: storage.Page = undefined;
        try self.space.readPages(&.{.{ .id = @enumFromInt(id), .destination = &page }});
    }

    fn tree(self: *Inspector, id: u64, depth: usize) !Key {
        if (depth >= 16) return error.Corrupt;
        try self.claim(id);
        var page: storage.Page = undefined;
        try self.space.readPages(&.{.{ .id = @enumFromInt(id), .destination = &page }});
        if (!std.mem.eql(u8, page[0..4], "LRBT") or page[4] > 1 or page[5] != 1) return error.Corrupt;
        const branch = page[4] != 0;
        const count = std.mem.readInt(u16, page[6..8], .little);
        const next = std.mem.readInt(u64, page[8..16], .little);
        if (count == 0 or (branch and (count < 2 or next != 0))) return error.Corrupt;
        self.shape.pages += 1;
        if (!branch) {
            if (self.last_key.length != 0 and self.next_leaf != id) return error.Corrupt;
            self.next_leaf = next;
            if (self.shape.height != 0 and self.shape.height != depth + 1) return error.Corrupt;
            self.shape.height = depth + 1;
            self.shape.records += count;
        }
        var at: usize = 16;
        var previous: Key = .{};
        for (0..count) |_| {
            if (at + 8 > page.len) return error.Corrupt;
            const key_len = std.mem.readInt(u16, page[at..][0..2], .little);
            const representation = std.mem.readInt(u16, page[at + 2 ..][0..2], .little);
            const flags = representation & 3;
            const prefix = representation >> 2;
            const length = std.mem.readInt(u32, page[at + 4 ..][0..4], .little);
            if (flags != 3 and prefix != 0) return error.Corrupt;
            at += 8;
            if (key_len == 0 or key_len > 64 or key_len > page.len - at or flags > 3) return error.Corrupt;
            var key: Key = .{ .length = key_len };
            @memcpy(key.bytes[0..key_len], page[at..][0..key_len]);
            at += key_len;
            if (previous.length != 0 and std.mem.order(u8, previous.slice(), key.slice()) != .lt) return error.Corrupt;
            previous = key;
            if (branch) {
                if (flags != 2 or length != 0 or at + 8 > page.len) return error.Corrupt;
                const child = std.mem.readInt(u64, page[at..][0..8], .little);
                const maximum = try self.tree(child, depth + 1);
                if (!std.mem.eql(u8, maximum.slice(), key.slice())) return error.Corrupt;
                at += 8;
                continue;
            }
            if (self.last_key.length != 0 and std.mem.order(u8, self.last_key.slice(), key.slice()) != .lt) return error.Corrupt;
            self.last_key = key;
            switch (flags) {
                0 => {
                    if (length > page.len - at) return error.Corrupt;
                    at += length;
                },
                1 => {
                    if (length == 0 or at + 8 > page.len) return error.Corrupt;
                    var index = std.mem.readInt(u64, page[at..][0..8], .little);
                    var remaining: usize = length;
                    while (remaining != 0) {
                        try self.claim(index);
                        var descriptor: storage.Page = undefined;
                        try self.space.readPages(&.{.{ .id = @enumFromInt(index), .destination = &descriptor }});
                        if (!std.mem.eql(u8, descriptor[0..8], "LRBLOB01")) return error.Corrupt;
                        const pages = std.mem.readInt(u32, descriptor[16..20], .little);
                        if (pages == 0 or pages > storage.batch_size or pages > (remaining + storage.page_size - 1) / storage.page_size) return error.Corrupt;
                        for (0..pages) |i| try self.data(std.mem.readInt(u64, descriptor[24 + i * 8 ..][0..8], .little));
                        remaining -= @min(remaining, @as(usize, pages) * storage.page_size);
                        index = std.mem.readInt(u64, descriptor[8..16], .little);
                    }
                    if (index != 0) return error.Corrupt;
                    at += 8;
                },
                3 => {
                    const limit = storage.page_size - 16 - 8 - 64;
                    if (prefix > length or (prefix != 0 and prefix != length % storage.page_size)) return error.Corrupt;
                    const remaining = length - prefix;
                    const pages = remaining / storage.page_size + @intFromBool(remaining % storage.page_size != 0);
                    if (pages == 0) return error.Corrupt;
                    const bytes = pages * 8 + prefix;
                    if (bytes > limit or bytes > page.len - at) return error.Corrupt;
                    for (0..pages) |i| try self.data(std.mem.readInt(u64, page[at + i * 8 ..][0..8], .little));
                    at += bytes;
                },
                else => return error.Corrupt,
            }
        }
        self.shape.used_bytes += at;
        return previous;
    }
};

pub fn inspect(table: records.Table) !Shape {
    if (table.directory != null) return error.InvalidArgument;
    const store = table.space.store;
    const seen = try std.testing.allocator.alloc(bool, @intCast(store.metadata.pages));
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    var inspector: Inspector = .{ .space = table.space, .seen = seen };
    if (try table.space.getRoot()) |root| _ = try inspector.tree(@intFromEnum(root), 0);
    if (inspector.next_leaf != 0) return error.Corrupt;
    var free = store.metadata.free;
    var free_count = store.metadata.free_count;
    var free_pages: u64 = 0;
    while (free != 0) {
        try inspector.claim(free);
        const block = try readBlock(store, free);
        if (std.mem.readInt(u32, block[4..8], .little) != std.math.maxInt(u32)) return error.Corrupt;
        if (free_count == 0 or free_count > 32 or free_count > std.mem.readInt(u16, block[42..44], .little)) return error.Corrupt;
        free_pages += free_count;
        for (0..free_count - 1) |index| {
            const id = std.mem.readInt(u64, block[44 + index * 8 ..][0..8], .little);
            try inspector.claim(id);
            const member = try readBlock(store, id);
            if (std.mem.readInt(u32, member[4..8], .little) != std.math.maxInt(u32)) return error.Corrupt;
        }
        free = std.mem.readInt(u64, block[32..40], .little);
        free_count = std.mem.readInt(u16, block[40..42], .little);
    }
    if (free_pages != store.metadata.free_pages) return error.Corrupt;
    for (1..seen.len) |id| {
        const block = try readBlock(store, id);
        const owner = std.mem.readInt(u32, block[4..8], .little);
        if ((owner == @intFromEnum(table.space.id) or owner == std.math.maxInt(u32)) and !seen[id]) return error.Corrupt;
    }
    return inspector.shape;
}

fn readBlock(store: *storage.Store, id: u64) ![4096]u8 {
    var block: [4096]u8 = undefined;
    const location = store.locations.get(id);
    const offset = if (location) |entry| entry.current + 32 else id * block.len;
    const file = if (location != null) store.wal else store.database;
    if (try file.readPositionalAll(store.io, &block, offset) != block.len) return error.Corrupt;
    if (!std.mem.eql(u8, block[0..4], "LRPG") or std.mem.readInt(u64, block[8..16], .little) != id) return error.Corrupt;
    const saved = std.mem.readInt(u64, block[24..32], .little);
    std.mem.writeInt(u64, block[24..32], 0, .little);
    const checksum = std.hash.XxHash64.hash(0x4c52504147455231, &block);
    std.mem.writeInt(u64, block[24..32], saved, .little);
    if (saved != checksum) return error.Corrupt;
    return block;
}
