const std = @import("std");
const Pattern = @import("pattern.zig").Pattern;

pub const Version = struct {
    major: u32,
    minor: u32 = 0,

    pub fn order(self: Version, other: Version) std.math.Order {
        const major = std.math.order(self.major, other.major);
        return if (major == .eq) std.math.order(self.minor, other.minor) else major;
    }
};
const Range = struct {
    minimum: Version,
    maximum: Version,
    fn contains(self: Range, version: Version) bool {
        return version.order(self.minimum) != .lt and version.order(self.maximum) != .gt;
    }
};
pub const Filter = struct {
    namespace: ?Pattern,
    path: ?Pattern,
    pub fn matches(self: *Filter, name: []const u8) bool {
        const colon = std.mem.indexOfScalar(u8, name, ':').?;
        if (self.namespace) |*pattern| if (!pattern.matches(name[0..colon])) return false;
        if (self.path) |*pattern| if (!pattern.matches(name[colon + 1 ..])) return false;
        return true;
    }
};
pub const Metadata = struct {
    formats: Range,
    preferred: Version,
    filters: []Filter,
    overlays: []const struct { directory: []const u8, formats: Range },

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Metadata {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
        if (root != .object) return error.InvalidPackMetadata;
        const pack = root.object.get("pack") orelse return error.InvalidPackMetadata;
        if (pack != .object) return error.InvalidPackMetadata;
        const description = pack.object.get("description") orelse return error.InvalidPackMetadata;
        if (description == .null) return error.InvalidPackMetadata;
        const formats = try formatRange(pack, "supported_formats", "pack_format");
        const preferred = if (pack.object.get("pack_format")) |value| try parseVersion(value) else formats.minimum;
        if (!formats.contains(preferred)) return error.InvalidPackFormat;
        var result: Metadata = .{ .formats = formats, .preferred = preferred, .filters = &.{}, .overlays = &.{} };
        if (root.object.get("filter")) |filter| {
            if (filter != .object) return error.InvalidPackMetadata;
            const block = filter.object.get("block") orelse return error.InvalidPackMetadata;
            if (block != .array) return error.InvalidPackMetadata;
            result.filters = try allocator.alloc(Filter, block.array.items.len);
            for (block.array.items, result.filters) |entry, *compiled| {
                if (entry != .object) return error.InvalidPackMetadata;
                compiled.* = .{ .namespace = null, .path = null };
                if (entry.object.get("namespace")) |pattern| {
                    if (pattern != .string) return error.InvalidPackMetadata;
                    compiled.namespace = try Pattern.compile(allocator, pattern.string);
                }
                if (entry.object.get("path")) |pattern| {
                    if (pattern != .string) return error.InvalidPackMetadata;
                    compiled.path = try Pattern.compile(allocator, pattern.string);
                }
            }
        }
        if (root.object.get("overlays")) |overlays| {
            if (overlays != .object) return error.InvalidPackMetadata;
            const entries = overlays.object.get("entries") orelse return error.InvalidPackMetadata;
            if (entries != .array) return error.InvalidPackMetadata;
            const compiled = try allocator.alloc(@typeInfo(@FieldType(Metadata, "overlays")).pointer.child, entries.array.items.len);
            for (entries.array.items, compiled) |entry, *overlay| {
                if (entry != .object) return error.InvalidPackMetadata;
                const directory = entry.object.get("directory") orelse return error.InvalidPackMetadata;
                if (directory != .string or !validDirectory(directory.string)) return error.InvalidOverlayDirectory;
                overlay.* = .{ .directory = directory.string, .formats = try formatRange(entry, "formats", "formats") };
            }
            result.overlays = compiled;
        }
        return result;
    }

    pub fn roots(self: Metadata, allocator: std.mem.Allocator, version: Version) ![]const []const u8 {
        if (!self.formats.contains(version)) return error.IncompatiblePackFormat;
        var result: std.ArrayList([]const u8) = .empty;
        try result.append(allocator, "data/");
        for (self.overlays) |overlay| {
            if (overlay.formats.contains(version)) try result.append(allocator, try std.fmt.allocPrint(allocator, "{s}/data/", .{overlay.directory}));
        }
        return result.items;
    }

    pub fn select(self: Metadata, supported: []const Version) !Version {
        var selected: ?Version = null;
        for (supported) |version| {
            if (!self.formats.contains(version)) continue;
            if (selected == null or version.order(selected.?) == .gt) selected = version;
        }
        return selected orelse error.IncompatiblePackFormat;
    }

    pub fn defaultVersion(self: Metadata) Version {
        return self.preferred;
    }
};

fn validDirectory(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024) return false;
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return false;
    }
    return true;
}
fn integer(json: std.json.Value) !u32 {
    if (json != .integer or json.integer < 0 or json.integer > std.math.maxInt(u32)) return error.InvalidPackFormat;
    return @intCast(json.integer);
}
fn parseVersion(json: std.json.Value) !Version {
    if (json == .integer) return .{ .major = try integer(json) };
    if (json != .array or json.array.items.len != 2) return error.InvalidPackFormat;
    return .{ .major = try integer(json.array.items[0]), .minor = try integer(json.array.items[1]) };
}
fn formatRange(json: std.json.Value, key: []const u8, fallback: []const u8) !Range {
    if (json.object.get("min_format")) |minimum| {
        const maximum = json.object.get("max_format") orelse return error.InvalidPackFormat;
        const range: Range = .{ .minimum = try parseVersion(minimum), .maximum = try parseVersion(maximum) };
        if (range.minimum.order(range.maximum) == .gt) return error.InvalidPackFormat;
        return range;
    }
    const value = json.object.get(key) orelse json.object.get(fallback) orelse return error.InvalidPackFormat;
    const range: Range = switch (value) {
        .integer => .{ .minimum = .{ .major = try integer(value) }, .maximum = .{ .major = try integer(value), .minor = std.math.maxInt(u32) } },
        .array => blk: {
            if (value.array.items.len != 2) return error.InvalidPackFormat;
            break :blk .{ .minimum = .{ .major = try integer(value.array.items[0]) }, .maximum = .{ .major = try integer(value.array.items[1]), .minor = std.math.maxInt(u32) } };
        },
        .object => .{ .minimum = .{ .major = try integer(value.object.get("min_inclusive") orelse return error.InvalidPackFormat) }, .maximum = .{ .major = try integer(value.object.get("max_inclusive") orelse return error.InvalidPackFormat), .minor = std.math.maxInt(u32) } },
        else => return error.InvalidPackFormat,
    };
    if (range.minimum.order(range.maximum) == .gt) return error.InvalidPackFormat;
    return range;
}

test "minor format ranges select overlays and reject unsafe directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const descriptor = try Metadata.parse(allocator,
        \\{"pack":{"description":"test","min_format":[107,0],"max_format":[107,2]},"overlays":{"entries":[{"min_format":[107,1],"max_format":[107,1],"directory":"minor"}]}}
    );
    try std.testing.expectEqual(@as(usize, 2), (try descriptor.roots(allocator, .{ .major = 107, .minor = 1 })).len);
    try std.testing.expectEqual(@as(usize, 1), (try descriptor.roots(allocator, .{ .major = 107, .minor = 2 })).len);
    try std.testing.expectError(error.IncompatiblePackFormat, descriptor.roots(allocator, .{ .major = 107, .minor = 3 }));
    try std.testing.expectError(error.InvalidOverlayDirectory, Metadata.parse(allocator,
        \\{"pack":{"pack_format":81,"description":"test"},"overlays":{"entries":[{"formats":81,"directory":"../escape"}]}}
    ));
}

test "format negotiation chooses a supported overlay target without depending on pack order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const descriptor = try Metadata.parse(allocator,
        \\{"pack":{"description":"test","pack_format":71,"supported_formats":[48,81]},"overlays":{"entries":[{"formats":81,"directory":"modern"}]}}
    );
    try std.testing.expectEqual(@as(u32, 71), descriptor.defaultVersion().major);
    try std.testing.expectEqual(@as(u32, 81), (try descriptor.select(&.{ .{ .major = 71 }, .{ .major = 48 }, .{ .major = 81 } })).major);
    try std.testing.expectEqual(@as(u32, 48), (try descriptor.select(&.{.{ .major = 48 }})).major);
    try std.testing.expectError(error.IncompatiblePackFormat, descriptor.select(&.{.{ .major = 82 }}));
    try std.testing.expectError(error.InvalidPackFormat, Metadata.parse(allocator,
        \\{"pack":{"description":"test","pack_format":90,"supported_formats":[48,81]}}
    ));
}
