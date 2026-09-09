const std = @import("std");

pub const Declaration = struct {
    name: []const u8,
    alternatives: []const []const u8 = &.{},
    greedy_argument: ?[]const u8 = null,
    executable_without_arguments: bool = false,
};

pub const Entry = struct {
    sender: u16,
    text: []const u8,
    handled: bool = false,
};

pub const Batch = struct {
    entries: []Entry = &.{},
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Batch {
        if (capacity == 0) return error.InvalidCommandCapacity;
        return .{ .entries = try allocator.alloc(Entry, capacity) };
    }

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
