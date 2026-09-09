const std = @import("std");

pub const page_size = 4096;
pub const PageId = u64;
pub const Location = struct { pack: u32, offset: u64, length: u32 };
pub const Kind = enum(u8) { leaf = 1, branch = 2 };
const magic = "LRIX";
const version: u16 = 1;
const header = 16;
const check_at = 12;
const leaf_fixed = 20;
const branch_fixed = 12;
pub const Entry = union(Kind) { leaf: struct { namespace: []const u8, key: []const u8, location: Location }, branch: struct { child: PageId, separator_namespace: []const u8, separator_key: []const u8 } };

/// Validated borrowed page. Leaf components are nonempty; branch separator
/// components may be empty, denoting the minimum composite key. Empty branches
/// are invalid. The end directory stores u16 offsets in reverse entry order.
pub const View = struct {
    bytes: []const u8,
    kind: Kind,
    count: u16,
    data_end: u16,
    pub fn init(bytes: []const u8) error{Corrupt}!View {
        if (bytes.len != page_size or !std.mem.eql(u8, bytes[0..4], magic) or read(u16, bytes, 4) != version or bytes[7] != 0 or read(u32, bytes, check_at) != checksum(bytes)) return error.Corrupt;
        const kind: Kind = switch (bytes[6]) {
            1 => .leaf,
            2 => .branch,
            else => return error.Corrupt,
        };
        const self: View = .{ .bytes = bytes, .kind = kind, .count = read(u16, bytes, 8), .data_end = read(u16, bytes, 10) };
        if (kind == .branch and self.count == 0) return error.Corrupt;
        const dir = self.directoryStart() catch return error.Corrupt;
        const data_end: usize = @as(usize, self.data_end);
        if (data_end < header or data_end > dir) return error.Corrupt;
        if (self.count == 0) {
            if (data_end != header) return error.Corrupt;
            for (bytes[header..dir]) |b| if (b != 0) return error.Corrupt;
            return self;
        }
        var prior_end: usize = header;
        var prior_ns: []const u8 = &.{};
        var prior_key: []const u8 = &.{};
        var i: u16 = 0;
        while (i < self.count) : (i += 1) {
            const start = self.offset(i);
            const end = if (i + 1 < self.count) self.offset(i + 1) else data_end;
            if (start != prior_end or end <= start or end > dir) return error.Corrupt;
            const e = self.at(start, end) catch return error.Corrupt;
            const p = switch (e) {
                .leaf => |x| blk: {
                    if (x.namespace.len == 0 or x.key.len == 0) return error.Corrupt;
                    break :blk .{ x.namespace, x.key };
                },
                .branch => |x| blk: {
                    if (x.child == 0) return error.Corrupt;
                    break :blk .{ x.separator_namespace, x.separator_key };
                },
            };
            if (i != 0 and cmp(p[0], p[1], prior_ns, prior_key) <= 0) return error.Corrupt;
            prior_end = end;
            prior_ns = p[0];
            prior_key = p[1];
        }
        for (bytes[data_end..dir]) |b| if (b != 0) return error.Corrupt;
        return self;
    }
    /// O(1) offset lookup, so lowerBound is a genuine binary search.
    pub fn entry(self: View, i: u16) Entry {
        std.debug.assert(i < self.count);
        return self.at(self.offset(i), if (i + 1 < self.count) self.offset(i + 1) else @as(usize, self.data_end)) catch unreachable;
    }
    pub fn lowerBound(self: View, ns: []const u8, key: []const u8) u16 {
        var lo: u16 = 0;
        var hi = self.count;
        while (lo < hi) {
            const m: u16 = lo + (hi - lo) / 2;
            const e = self.entry(m);
            const p = switch (e) {
                .leaf => |x| .{ x.namespace, x.key },
                .branch => |x| .{ x.separator_namespace, x.separator_key },
            };
            if (cmp(p[0], p[1], ns, key) < 0) lo = m + 1 else hi = m;
        }
        return lo;
    }
    fn directoryStart(self: View) error{Corrupt}!usize {
        const n = std.math.mul(usize, self.count, 2) catch return error.Corrupt;
        if (n > page_size - header) return error.Corrupt;
        return page_size - n;
    }
    fn offset(self: View, i: u16) usize {
        return read(u16, self.bytes, page_size - (@as(usize, i) + 1) * 2);
    }
    fn at(self: View, start: usize, end: usize) error{Corrupt}!Entry {
        const fixed: usize = switch (self.kind) {
            .leaf => leaf_fixed,
            .branch => branch_fixed,
        };
        if (start > end or fixed > end - start) return error.Corrupt;
        const nl: usize = switch (self.kind) {
            .leaf => read(u16, self.bytes, start),
            .branch => read(u16, self.bytes, start + 8),
        };
        const kl: usize = switch (self.kind) {
            .leaf => read(u16, self.bytes, start + 2),
            .branch => read(u16, self.bytes, start + 10),
        };
        const data = start + fixed;
        const len = std.math.add(usize, nl, kl) catch return error.Corrupt;
        if (data > end or len != end - data) return error.Corrupt;
        const ns = self.bytes[data .. data + nl];
        const key = self.bytes[data + nl .. end];
        return switch (self.kind) {
            .leaf => .{ .leaf = .{ .namespace = ns, .key = key, .location = .{ .pack = read(u32, self.bytes, start + 4), .offset = read(u64, self.bytes, start + 8), .length = read(u32, self.bytes, start + 16) } } },
            .branch => .{ .branch = .{ .child = read(u64, self.bytes, start), .separator_namespace = ns, .separator_key = key } },
        };
    }
};
pub const Builder = struct {
    page: *[page_size]u8,
    kind: Kind,
    cursor: usize = header,
    count: u16 = 0,
    last_ns: []const u8 = &.{},
    last_key: []const u8 = &.{},
    pub fn init(page: *[page_size]u8, kind: Kind) Builder {
        @memset(page, 0);
        @memcpy(page[0..4], magic);
        write(u16, page, 4, version);
        page[6] = @intFromEnum(kind);
        return .{ .page = page, .kind = kind };
    }
    pub fn appendLeaf(self: *Builder, ns: []const u8, key: []const u8, loc: Location) error{ PageFull, KeyTooLarge, InvalidOrder, InvalidKey }!void {
        if (self.kind != .leaf) return error.InvalidOrder;
        if (ns.len == 0 or key.len == 0) return error.InvalidKey;
        const s = try self.putKey(ns, key, leaf_fixed);
        write(u16, self.page, s, @intCast(ns.len));
        write(u16, self.page, s + 2, @intCast(key.len));
        write(u32, self.page, s + 4, loc.pack);
        write(u64, self.page, s + 8, loc.offset);
        write(u32, self.page, s + 16, loc.length);
    }
    pub fn appendBranch(self: *Builder, child: PageId, ns: []const u8, key: []const u8) error{ PageFull, KeyTooLarge, InvalidOrder }!void {
        if (self.kind != .branch or child == 0) return error.InvalidOrder;
        const s = try self.putKey(ns, key, branch_fixed);
        write(u64, self.page, s, child);
        write(u16, self.page, s + 8, @intCast(ns.len));
        write(u16, self.page, s + 10, @intCast(key.len));
    }
    pub fn finish(self: *Builder) error{InvalidOrder}!void {
        if (self.kind == .branch and self.count == 0) return error.InvalidOrder;
        write(u16, self.page, 8, self.count);
        write(u16, self.page, 10, @intCast(self.cursor));
        write(u32, self.page, check_at, 0);
        write(u32, self.page, check_at, checksum(self.page));
    }
    fn putKey(self: *Builder, ns: []const u8, key: []const u8, fixed: usize) error{ PageFull, KeyTooLarge, InvalidOrder }!usize {
        if (ns.len > std.math.maxInt(u16) or key.len > std.math.maxInt(u16)) return error.KeyTooLarge;
        if (self.count != 0 and cmp(ns, key, self.last_ns, self.last_key) <= 0) return error.InvalidOrder;
        const data = std.math.add(usize, ns.len, key.len) catch return error.KeyTooLarge;
        const n = std.math.add(usize, fixed, data) catch return error.KeyTooLarge;
        if (n > page_size - header - 2) return error.KeyTooLarge;
        const dir = page_size - @as(usize, self.count) * 2;
        if (self.cursor > dir or dir - self.cursor < 2 or n > dir - self.cursor - 2 or self.count == std.math.maxInt(u16)) return error.PageFull;
        const s = self.cursor;
        const d = s + fixed;
        @memcpy(self.page[d .. d + ns.len], ns);
        @memcpy(self.page[d + ns.len .. d + data], key);
        self.cursor += n;
        self.count += 1;
        write(u16, self.page, page_size - @as(usize, self.count) * 2, @intCast(s));
        self.last_ns = self.page[d .. d + ns.len];
        self.last_key = self.page[d + ns.len .. d + data];
        return s;
    }
};
fn cmp(an: []const u8, ak: []const u8, bn: []const u8, bk: []const u8) i2 {
    const n = std.mem.order(u8, an, bn);
    if (n != .eq) return if (n == .lt) -1 else 1;
    return switch (std.mem.order(u8, ak, bk)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}
fn checksum(b: []const u8) u32 {
    var h = std.hash.crc.Crc32.init();
    h.update(b[0..check_at]);
    h.update(&[_]u8{ 0, 0, 0, 0 });
    h.update(b[check_at + 4 ..]);
    return h.final();
}
fn read(comptime T: type, b: []const u8, o: usize) T {
    return std.mem.readInt(T, b[o..][0..@sizeOf(T)], .little);
}
fn write(comptime T: type, b: []u8, o: usize, v: T) void {
    std.mem.writeInt(T, b[o..][0..@sizeOf(T)], v, .little);
}
fn recheck(b: *[page_size]u8) void {
    write(u32, b, check_at, 0);
    write(u32, b, check_at, checksum(b));
}
test "composite component boundaries and binary search" {
    var b: [page_size]u8 = undefined;
    var x = Builder.init(&b, .leaf);
    try x.appendLeaf("a", "bc", .{ .pack = 1, .offset = 2, .length = 3 });
    try x.appendLeaf("ab", "c", .{ .pack = 4, .offset = 5, .length = 6 });
    try x.finish();
    const v = try View.init(&b);
    try std.testing.expectEqual(@as(u16, 0), v.lowerBound("a", "bc"));
    try std.testing.expectEqual(@as(u16, 1), v.lowerBound("ab", "c"));
    try std.testing.expectEqual(@as(u16, 2), v.lowerBound("z", "a"));
    try std.testing.expectEqual(@as(u64, 5), v.entry(1).leaf.location.offset);
    x = Builder.init(&b, .branch);
    try std.testing.expectError(error.InvalidOrder, x.finish());
    try x.appendBranch(1, "", "");
    try x.appendBranch(2, "ab", "c");
    try x.finish();
    const branch = try View.init(&b);
    try std.testing.expectEqual(@as(u64, 2), branch.entry(1).branch.child);
    try std.testing.expectEqual(@as(u16, 1), branch.lowerBound("a", "bc"));
}
test "rechecksummed malformed directory and order reject" {
    var b: [page_size]u8 = undefined;
    var x = Builder.init(&b, .leaf);
    try x.appendLeaf("a", "a", .{ .pack = 1, .offset = 2, .length = 3 });
    try x.appendLeaf("b", "b", .{ .pack = 4, .offset = 5, .length = 6 });
    try x.finish();
    write(u16, &b, page_size - 2, header + 1);
    recheck(&b);
    try std.testing.expectError(error.Corrupt, View.init(&b));
    x = Builder.init(&b, .leaf);
    try x.appendLeaf("a", "z", .{ .pack = 1, .offset = 2, .length = 3 });
    try x.appendLeaf("b", "a", .{ .pack = 4, .offset = 5, .length = 6 });
    try x.finish();
    b[header + leaf_fixed] = 'z';
    recheck(&b);
    try std.testing.expectError(error.Corrupt, View.init(&b));
}
test "page full differs from key too large" {
    var b: [page_size]u8 = undefined;
    var x = Builder.init(&b, .leaf);
    const fit = [_]u8{'x'} ** (page_size - header - leaf_fixed - 2 - 1);
    try x.appendLeaf("a", &fit, .{ .pack = 0, .offset = 0, .length = 0 });
    try std.testing.expectError(error.PageFull, x.appendLeaf("z", "z", .{ .pack = 0, .offset = 0, .length = 0 }));
    try x.finish();
    try std.testing.expectEqual(@as(u16, 1), (try View.init(&b)).count);
    const unfit = [_]u8{'x'} ** (page_size - header - leaf_fixed - 2);
    x = Builder.init(&b, .leaf);
    try std.testing.expectError(error.KeyTooLarge, x.appendLeaf("a", &unfit, .{ .pack = 0, .offset = 0, .length = 0 }));
    try x.finish();
    try std.testing.expectEqual(@as(u16, 0), (try View.init(&b)).count);
}
