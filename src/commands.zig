const config = @import("config.zig").value;

/// Command-tree contribution supplied by a compile-time plugin. Alternatives
/// are executable literal children. A greedy argument accepts the remaining
/// command text and leaves semantic validation to the owning plugin.
pub const Declaration = struct {
    name: []const u8,
    alternatives: []const []const u8 = &.{},
    greedy_argument: ?[]const u8 = null,
    executable_without_arguments: bool = false,
};

/// A decoded command borrows its text from the tick packet arena. Command
/// plugins claim entries in deterministic profile order.
pub const Entry = struct {
    sender: u16,
    text: []const u8,
    handled: bool = false,
};

pub const Batch = struct {
    entries: [config.max_tick_player_messages]Entry = undefined,
    len: usize = 0,

    pub fn append(self: *Batch, sender: u16, text: []const u8) error{CommandBatchFull}!*Entry {
        if (self.len == self.entries.len) return error.CommandBatchFull;
        const entry = &self.entries[self.len];
        entry.* = .{ .sender = sender, .text = text };
        self.len += 1;
        return entry;
    }

    pub fn items(self: *Batch) []Entry {
        return self.entries[0..self.len];
    }

    pub fn clear(self: *Batch) void {
        self.len = 0;
    }
};
