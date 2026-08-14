const connection = @import("lightning_rod").connection;
const std = @import("std");

pub const Capacity = struct {
    pub const id = "minecraft:capacity_admission";

    pub fn create(allocator: std.mem.Allocator) !*Capacity {
        const self = try allocator.create(Capacity);
        self.* = .{};
        return self;
    }

    pub fn loginStart(_: *Capacity, draft: *connection.LoginDraft) void {
        if (draft.current_players >= draft.maximum_players)
            draft.reject("Server is full");
    }
};
