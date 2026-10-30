const std = @import("std");

pub fn id(bytes: []const u8, registry: []const u8, entry_name: []const u8) !?u32 {
    const entry = try find(bytes, registry, .{ .name = entry_name }) orelse return null;
    return entry.id;
}

pub fn name(bytes: []const u8, registry: []const u8, entry_id: u32) !?[]const u8 {
    const entry = try find(bytes, registry, .{ .id = entry_id }) orelse return null;
    return entry.name;
}

const Search = union(enum) { name: []const u8, id: u32 };
const Entry = struct { id: u32, name: []const u8 };

fn find(bytes: []const u8, registry: []const u8, search: Search) !?Entry {
    var reader = std.Io.Reader.fixed(bytes);
    if (!std.mem.eql(u8, try reader.take(8), "LRREG002")) return error.InvalidRegistrySnapshot;
    try reader.discardAll(try reader.takeInt(u16, .big));
    const count = try reader.takeInt(u32, .big);
    for (0..count) |_| {
        const current = try reader.take(try reader.takeInt(u16, .big));
        _ = try reader.takeByte();
        const entries = try reader.takeInt(u32, .big);
        for (0..entries) |index| {
            const entry_name = try reader.take(try reader.takeInt(u16, .big));
            try reader.discardAll(try reader.takeInt(u32, .big));
            if (!std.mem.eql(u8, registry, current)) continue;
            const matches = switch (search) {
                .name => |wanted| std.mem.eql(u8, wanted, entry_name),
                .id => |wanted| index == wanted,
            };
            if (matches) return .{ .id = @intCast(index), .name = entry_name };
        }
    }
    return null;
}

pub const Registry = struct {
    name: []const u8,
    synchronized: bool,
    count: u32,
    bytes: []const u8,

    pub fn entries(self: Registry) EntryIterator {
        return .{ .reader = .fixed(self.bytes), .remaining = self.count };
    }
};

pub const RegistryEntry = struct { name: []const u8, nbt: []const u8 };
pub const EntryIterator = struct {
    reader: std.Io.Reader,
    remaining: u32,

    pub fn next(self: *EntryIterator) !?RegistryEntry {
        if (self.remaining == 0) return null;
        const entry_name = try self.reader.take(try self.reader.takeInt(u16, .big));
        const nbt = try self.reader.take(try self.reader.takeInt(u32, .big));
        self.remaining -= 1;
        return .{ .name = entry_name, .nbt = nbt };
    }
};

pub const Iterator = struct {
    reader: std.Io.Reader,
    remaining: u32,

    pub fn init(bytes: []const u8) !Iterator {
        var reader = std.Io.Reader.fixed(bytes);
        if (!std.mem.eql(u8, try reader.take(8), "LRREG002")) return error.InvalidRegistrySnapshot;
        try reader.discardAll(try reader.takeInt(u16, .big));
        return .{ .remaining = try reader.takeInt(u32, .big), .reader = reader };
    }

    pub fn next(self: *Iterator) !?Registry {
        if (self.remaining == 0) return null;
        const registry_name = try self.reader.take(try self.reader.takeInt(u16, .big));
        const synchronized = try self.reader.takeByte();
        if (synchronized > 1) return error.InvalidRegistrySnapshot;
        const count = try self.reader.takeInt(u32, .big);
        const start = self.reader.seek;
        for (0..count) |_| {
            try self.reader.discardAll(try self.reader.takeInt(u16, .big));
            try self.reader.discardAll(try self.reader.takeInt(u32, .big));
        }
        self.remaining -= 1;
        return .{ .name = registry_name, .synchronized = synchronized != 0, .count = count, .bytes = self.reader.buffer[start..self.reader.seek] };
    }
};
