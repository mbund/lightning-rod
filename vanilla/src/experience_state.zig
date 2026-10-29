const std = @import("std");

pub const State = struct {
    pub const encoded_size = 16;
    progress: f32 = 0,
    level: i32 = 0,
    total: i32 = 0,
    score: i32 = 0,

    pub fn encode(self: State) [encoded_size]u8 {
        var bytes: [encoded_size]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], @bitCast(self.progress), .little);
        std.mem.writeInt(i32, bytes[4..8], self.level, .little);
        std.mem.writeInt(i32, bytes[8..12], self.total, .little);
        std.mem.writeInt(i32, bytes[12..16], self.score, .little);
        return bytes;
    }

    pub fn decode(bytes: []const u8) !State {
        if (bytes.len != encoded_size) return error.CorruptExperience;
        const state: State = .{ .progress = @bitCast(std.mem.readInt(u32, bytes[0..4], .little)), .level = std.mem.readInt(i32, bytes[4..8], .little), .total = std.mem.readInt(i32, bytes[8..12], .little), .score = std.mem.readInt(i32, bytes[12..16], .little) };
        if (!std.math.isFinite(state.progress) or state.progress < 0 or state.progress >= 1 or state.level < 0 or state.total < 0) return error.CorruptExperience;
        return state;
    }

    pub fn needed(self: State) i32 {
        if (self.level >= 30) return 112 +% (self.level -% 30) *% 9;
        if (self.level >= 15) return 37 +% (self.level -% 15) *% 5;
        return 7 +% self.level *% 2;
    }

    pub fn points(self: *State, amount: i32) void {
        _ = self.pointsWithSound(amount);
    }

    pub fn pointsWithSound(self: *State, amount: i32) ?i32 {
        var sound: ?i32 = null;
        self.score +%= amount;
        self.progress += @as(f32, @floatFromInt(amount)) / @as(f32, @floatFromInt(self.needed()));
        self.total = @max(0, self.total +% amount);
        while (self.progress < 0) {
            const remainder = self.progress * @as(f32, @floatFromInt(self.needed()));
            if (self.level > 0) {
                self.levels(-1);
                self.progress = 1 + remainder / @as(f32, @floatFromInt(self.needed()));
            } else {
                self.levels(-1);
                self.progress = 0;
            }
        }
        while (self.progress >= 1) {
            self.progress = (self.progress - 1) * @as(f32, @floatFromInt(self.needed()));
            self.levels(1);
            if (sound == null and @mod(self.level, 5) == 0) sound = self.level;
            self.progress /= @as(f32, @floatFromInt(self.needed()));
        }
        return sound;
    }

    pub fn levels(self: *State, amount: i32) void {
        self.level = self.level +| amount;
        if (self.level < 0) self.* = .{ .score = self.score };
    }

    pub fn deathReward(self: State) i32 {
        return @min(self.level *% 7, 100);
    }
};

pub const denominations = [_]i32{ 2477, 1237, 617, 307, 149, 73, 37, 17, 7, 3, 1 };

pub fn denomination(amount: i32) i32 {
    std.debug.assert(amount > 0);
    for (denominations) |value| if (amount >= value) return value;
    unreachable;
}

test "experience transitions preserve vanilla float arithmetic and level boundaries" {
    var state: State = .{};
    state.points(7);
    try std.testing.expectEqual(@as(i32, 1), state.level);
    try std.testing.expectEqual(@as(f32, 0), state.progress);
    state.points(-1);
    try std.testing.expectEqual(@as(i32, 0), state.level);
    try std.testing.expectEqual(@as(f32, 1) - @as(f32, 1) / 7, state.progress);
    state.points(-100);
    try std.testing.expectEqual(@as(i32, 0), state.level);
    try std.testing.expectEqual(@as(f32, 0), state.progress);
    for ([_]i32{ 0, 14, 15, 29, 30, 31 }, [_]i32{ 7, 35, 37, 107, 112, 121 }) |level, expected| {
        state = .{ .level = level };
        try std.testing.expectEqual(expected, state.needed());
        state.points(expected);
        try std.testing.expectEqual(level + 1, state.level);
        try std.testing.expectEqual(@as(f32, 0), state.progress);
    }
    state.levels(-100);
    try std.testing.expectEqual(@as(i32, 0), state.total);
}

test "experience denominations and cumulative level thresholds match vanilla" {
    for ([_]i32{ 1, 7, 315, 352, 1395, 1507, 1000000 }) |amount| {
        var left = amount;
        var total: i32 = 0;
        while (left > 0) {
            const value = denomination(left);
            std.debug.assert(value <= left);
            total += value;
            left -= value;
        }
        try std.testing.expectEqual(amount, total);
    }
    for ([_]i32{ 7, 315, 352, 1395, 1507 }, [_]i32{ 1, 15, 16, 30, 31 }) |amount, level| {
        var state: State = .{};
        state.points(amount);
        try std.testing.expectEqual(level, state.level);
        try std.testing.expect(@abs(state.progress) < 0.0001);
        try std.testing.expectEqual(@min(level * 7, 100), state.deathReward());
    }
}

test "experience storage rejects invalid progress and negative levels" {
    const state: State = .{ .progress = 0.5, .level = 30, .total = 1451, .score = -7 };
    var bytes = state.encode();
    try std.testing.expectEqualDeep(state, try State.decode(&bytes));
    try std.testing.expectError(error.CorruptExperience, State.decode(bytes[0..15]));
    std.mem.writeInt(u32, bytes[0..4], @bitCast(std.math.nan(f32)), .little);
    try std.testing.expectError(error.CorruptExperience, State.decode(&bytes));
    bytes = state.encode();
    std.mem.writeInt(i32, bytes[4..8], -1, .little);
    try std.testing.expectError(error.CorruptExperience, State.decode(&bytes));
}
