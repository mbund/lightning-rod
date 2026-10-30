const std = @import("std");

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024) return false;
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return false;
    if (colon == 0 or colon + 1 == name.len) return false;
    for (name[0..colon]) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-' and c != '.') return false;
    for (name[colon + 1 ..]) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-' and c != '.' and c != '/') return false;
    var segments = std.mem.splitScalar(u8, name[colon + 1 ..], '/');
    while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return true;
}

pub fn identifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const result = if (std.mem.indexOfScalar(u8, name, ':') == null) try std.fmt.allocPrint(allocator, "minecraft:{s}", .{name}) else name;
    if (!validName(result)) return error.InvalidResourceName;
    return result;
}

pub fn index(allocator: std.mem.Allocator, names: []const []const u8) !std.StringHashMapUnmanaged(u32) {
    var result: std.StringHashMapUnmanaged(u32) = .empty;
    try result.ensureTotalCapacity(allocator, @intCast(names.len));
    for (names, 0..) |name, value| result.putAssumeCapacityNoClobber(name, @intCast(value));
    return result;
}
