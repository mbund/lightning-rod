const std = @import("std");
const config = @import("config.zig").value;

pub const max_prefixes = 8;

/// Compile-time capability owned by the single plugin which turns a chat
/// batch into packets. Any number of modifier plugins may run before it.
pub const OutputCapability = struct {};

pub const Audience = union(enum) {
    broadcast,
    player: u16,
};

/// All slices borrow either the tick input arena or longer-lived plugin/world
/// storage. They are never retained after the tick finishes.
pub const Draft = struct {
    sender: u16,
    text: []const u8,
    display_name: []const u8 = "",
    prefixes: [max_prefixes][]const u8 = [_][]const u8{""} ** max_prefixes,
    prefix_count: u8 = 0,
    audience: Audience = .broadcast,
    cancelled: bool = false,

    pub fn addPrefix(self: *Draft, prefix: []const u8) error{TooManyChatPrefixes}!void {
        if (self.prefix_count == self.prefixes.len) return error.TooManyChatPrefixes;
        self.prefixes[self.prefix_count] = prefix;
        self.prefix_count += 1;
    }

    pub fn cancel(self: *Draft) void {
        self.cancelled = true;
    }

    pub fn sendOnlyTo(self: *Draft, player: u16) void {
        self.audience = .{ .player = player };
    }
};

/// Formats a fully modified draft without first materializing the line. This
/// can be passed through normal Zig formatting into a final packet buffer.
pub const Line = struct {
    draft: *const Draft,

    pub fn format(self: Line, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.draft.prefixes[0..self.draft.prefix_count]) |prefix|
            try writer.writeAll(prefix);
        try writer.print("<{s}> {s}", .{ self.draft.display_name, self.draft.text });
    }
};

pub const Batch = struct {
    drafts: [config.max_tick_player_messages]Draft = undefined,
    len: usize = 0,

    pub fn append(self: *Batch, sender: u16, text: []const u8) error{ChatBatchFull}!*Draft {
        if (self.len == self.drafts.len) return error.ChatBatchFull;
        const draft = &self.drafts[self.len];
        draft.* = .{ .sender = sender, .text = text };
        self.len += 1;
        return draft;
    }

    pub fn items(self: *Batch) []Draft {
        return self.drafts[0..self.len];
    }

    pub fn clear(self: *Batch) void {
        self.len = 0;
    }
};

test "chat modifiers compose over one borrowed draft" {
    var batch: Batch = .{};
    const borrowed = "hello";
    const draft = try batch.append(3, borrowed);
    try draft.addPrefix("[Admin] ");
    try draft.addPrefix("[Blue] ");
    draft.display_name = "Alex";

    try std.testing.expectEqual(@as(usize, 1), batch.items().len);
    try std.testing.expectEqualStrings(borrowed, batch.items()[0].text);
    try std.testing.expectEqualStrings("[Admin] ", batch.items()[0].prefixes[0]);
    try std.testing.expectEqualStrings("[Blue] ", batch.items()[0].prefixes[1]);
}
