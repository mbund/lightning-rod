const std = @import("std");
const unlocks = @import("recipe_unlocks.zig");

pub const Progress = struct {
    pub const learned: u8 = 1;
    pub const highlighted: u8 = 2;

    settings: u8,
    flags: []const u8,
    identities: []const [32]u8,
    criteria: []const bool,
    criterion_definitions: []const unlocks.Criterion,
    awards: []const bool,
    rule_definitions: []const unlocks.Rule,

    pub fn write(self: Progress, writer: *std.Io.Writer) !void {
        std.debug.assert(self.flags.len == self.identities.len);
        std.debug.assert(self.criteria.len == self.criterion_definitions.len);
        std.debug.assert(self.awards.len == self.rule_definitions.len);
        try writer.writeAll("LRBOOK01");
        try writer.writeByte(self.settings);
        var count: u32 = 0;
        for (self.flags) |flags| count += @intFromBool(flags & learned != 0);
        try writer.writeInt(u32, count, .big);
        for (self.flags, self.identities) |flags, *identity| if (flags & learned != 0) {
            try writer.writeAll(identity);
            try writer.writeByte(flags & (learned | highlighted));
        };
        count = 0;
        for (self.criteria) |value| count += @intFromBool(value);
        try writer.writeInt(u32, count, .big);
        for (self.criteria, self.criterion_definitions) |value, criterion| if (value) try writer.writeAll(&criterion.identity);
        count = 0;
        for (self.awards) |value| count += @intFromBool(value);
        try writer.writeInt(u32, count, .big);
        for (self.awards, self.rule_definitions) |value, rule| if (value) try writer.writeAll(&rule.identity);
    }
};
