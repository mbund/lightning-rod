const std = @import("std");

pub fn randomTickRule(report: std.json.Value) ![]const u8 {
    var rules = report;
    for ([_][]const u8{ "children", "gamerule", "children" }) |key| {
        if (rules != .object) return error.InvalidCommandReport;
        rules = rules.object.get(key) orelse return error.InvalidCommandReport;
    }
    if (rules != .object) return error.InvalidCommandReport;
    for (rules.object.keys()) |name| {
        const bare = if (std.mem.lastIndexOfScalar(u8, name, ':')) |index| name[index + 1 ..] else name;
        var normalized: [32]u8 = undefined;
        var count: usize = 0;
        for (bare) |byte| {
            if (byte == '_') continue;
            if (count == normalized.len) break;
            normalized[count] = std.ascii.toLower(byte);
            count += 1;
        }
        if (std.mem.eql(u8, normalized[0..count], "randomtickspeed")) return name;
    }
    return error.MissingRandomTickRule;
}
