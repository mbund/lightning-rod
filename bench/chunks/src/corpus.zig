const std = @import("std");
const chunks = @import("chunks");

pub const section_count = 24;
pub const minimum_y = -4;
pub const section_bytes = 8193;
pub const origin_stride = 128;
pub const origins = [4][2]i32{ .{ 0, 0 }, .{ origin_stride, 0 }, .{ 0, origin_stride }, .{ origin_stride, origin_stride } };
pub const Column = struct {
    x: i32,
    z: i32,
    surface_y: i32,
    sections: [section_count][]const u8,
};

pub const Corpus = struct {
    bytes: []const u8,
    columns: []Column,
    hash: [64]u8,
    generated: u64 = 0,
    copies: usize = 1,
    mapping: ?std.Io.File.MemoryMap = null,

    pub fn deinit(self: *Corpus, allocator: std.mem.Allocator, io: std.Io) void {
        allocator.free(self.columns);
        if (self.mapping) |*mapping| {
            const file = mapping.file;
            mapping.destroy(io);
            file.close(io);
        }
        self.* = undefined;
    }

    pub fn replicate(self: *Corpus, allocator: std.mem.Allocator, copies: usize) !void {
        if (self.copies != 1 or copies == 0 or copies > 16 or self.columns.len * copies > 65536) return error.InvalidCopies;
        if (copies == 1) return;
        const width = @as(i64, self.columns[self.columns.len - 1].x) - self.columns[0].x;
        if (width >= 1024 or self.columns[self.columns.len - 1].x > std.math.maxInt(i32) - 15 * 1024) return error.CorpusTooWide;
        const columns = try allocator.alloc(Column, self.columns.len * copies);
        for (0..copies) |copy| for (self.columns, columns[copy * self.columns.len ..][0..self.columns.len]) |original, *column| {
            column.* = original;
            column.x += @as(i32, @intCast(copy)) * 1024;
        };
        allocator.free(self.columns);
        self.columns = columns;
        self.copies = copies;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Corpus {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const size = (try file.stat(io)).size;
        const maximum_bytes = 16 + @as(u64, 65536) * (24 + section_count * (2 + section_bytes));
        if (size < 16 or size > maximum_bytes) return error.InvalidCorpus;
        var mapping = try file.createMemoryMap(io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = false });
        errdefer mapping.destroy(io);
        var result = try parse(allocator, mapping.memory);
        result.mapping = mapping;
        return result;
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Corpus {
        if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..8], "LRWORLD2")) return error.InvalidCorpus;
        const count = std.mem.readInt(u32, bytes[8..12], .little);
        if (count == 0 or count > 65536 or std.mem.readInt(i16, bytes[12..14], .little) != minimum_y or std.mem.readInt(i16, bytes[14..16], .little) != section_count) return error.InvalidCorpus;
        if (bytes.len < 16 + @as(usize, count) * 24) return error.TruncatedCorpus;
        const columns = try allocator.alloc(Column, count);
        errdefer allocator.free(columns);
        var next: usize = 16 + @as(usize, count) * 24;
        for (columns, 0..) |*column, index| {
            const entry = bytes[16 + index * 24 ..][0..24];
            column.x = std.mem.readInt(i32, entry[0..4], .little);
            column.z = std.mem.readInt(i32, entry[4..8], .little);
            column.surface_y = std.mem.readInt(i32, entry[8..12], .little);
            if (std.mem.readInt(u32, entry[12..16], .little) != 0 or std.mem.readInt(u64, entry[16..24], .little) != next or column.surface_y < -64 or column.surface_y > 319) return error.InvalidCorpus;
            if (index != 0 and !less({}, columns[index - 1], column.*)) return error.UnsortedCorpus;
            for (&column.sections) |*section| {
                if (bytes.len - next < 2) return error.TruncatedCorpus;
                const length = std.mem.readInt(u16, bytes[next..][0..2], .little);
                next += 2;
                if ((length != 3 and length != section_bytes) or length > bytes.len - next) return error.InvalidCorpus;
                section.* = bytes[next..][0..length];
                if (section.*[0] != @intFromBool(length == section_bytes)) return error.InvalidCorpus;
                next += length;
            }
        }
        if (next != bytes.len) return error.TrailingCorpusData;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        return .{ .bytes = bytes, .columns = columns, .hash = std.fmt.bytesToHex(hash, .lower) };
    }

    fn less(_: void, a: Column, b: Column) bool {
        return a.x < b.x or (a.x == b.x and a.z < b.z);
    }

    pub fn find(self: *const Corpus, x: i32, z: i32) ?u32 {
        var left: usize = 0;
        var right = self.columns.len;
        while (left < right) {
            const at = left + (right - left) / 2;
            const column = self.columns[at];
            if (column.x == x and column.z == z) return @intCast(at);
            if (column.x < x or (column.x == x and column.z < z)) left = at + 1 else right = at;
        }
        return null;
    }

    pub fn read(self: *Corpus, section: chunks.Section, output: []u8) !usize {
        if (section.world != 0 or section.y < minimum_y or section.y >= minimum_y + section_count) return error.SectionOutsideCorpus;
        const id = self.find(section.x, section.z) orelse return error.SectionOutsideCorpus;
        const bytes = self.columns[id].sections[@intCast(section.y - minimum_y)];
        if (output.len < bytes.len) return error.BufferTooSmall;
        @memcpy(output[0..bytes.len], bytes);
        self.generated += 1;
        return bytes.len;
    }
};
