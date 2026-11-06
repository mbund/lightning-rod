const std = @import("std");
const assert = std.debug.assert;

pub const Grid = struct {
    minimum: [3]i32,
    side: usize,
    height: usize,

    pub fn count(self: Grid) usize {
        return self.side * self.side * self.height;
    }

    pub fn position(self: Grid, entry: usize) [3]i32 {
        assert(entry < self.count());
        return .{ self.minimum[0] + @as(i32, @intCast(entry / self.height % self.side)), self.minimum[1] + @as(i32, @intCast(entry % self.height)), self.minimum[2] + @as(i32, @intCast(entry / self.height / self.side)) };
    }

    pub fn index(self: Grid, at: [3]i32) ?usize {
        const x = @as(i64, at[0]) - self.minimum[0];
        const y = @as(i64, at[1]) - self.minimum[1];
        const z = @as(i64, at[2]) - self.minimum[2];
        if (x < 0 or y < 0 or z < 0 or x >= self.side or y >= self.height or z >= self.side) return null;
        return (@as(usize, @intCast(z)) * self.side + @as(usize, @intCast(x))) * self.height + @as(usize, @intCast(y));
    }

    pub fn neighbor(self: Grid, entry: usize, direction: usize) ?usize {
        assert(direction < 6);
        var at = self.position(entry);
        at[direction / 2] += if (direction % 2 == 0) @as(i32, 1) else -1;
        return self.index(at);
    }
};

pub const Component = struct { first: usize, count: usize, contains_observer: bool };

pub const Analysis = struct {
    allocator: std.mem.Allocator,
    seen: []bool,
    queue: []usize,
    isolated: std.ArrayList(usize) = .empty,
    components: std.ArrayList(Component) = .empty,

    pub fn init(allocator: std.mem.Allocator, maximum: usize) !Analysis {
        const seen = try allocator.alloc(bool, maximum);
        errdefer allocator.free(seen);
        const queue = try allocator.alloc(usize, maximum);
        errdefer allocator.free(queue);
        var result: Analysis = .{ .allocator = allocator, .seen = seen, .queue = queue };
        try result.isolated.ensureTotalCapacity(allocator, maximum);
        errdefer result.isolated.deinit(allocator);
        try result.components.ensureTotalCapacity(allocator, maximum);
        return result;
    }

    pub fn deinit(self: *Analysis) void {
        self.allocator.free(self.seen);
        self.allocator.free(self.queue);
        self.isolated.deinit(self.allocator);
        self.components.deinit(self.allocator);
    }

    pub fn run(self: *Analysis, grid: Grid, disclosed: []const bool, observer: usize) void {
        assert(disclosed.len == grid.count() and self.seen.len >= disclosed.len and observer < disclosed.len);
        @memset(self.seen[0..disclosed.len], false);
        self.isolated.clearRetainingCapacity();
        self.components.clearRetainingCapacity();
        for (disclosed, 0..) |visible, index| {
            if (!visible) continue;
            var surrounded = index != observer;
            for (0..6) |direction| {
                const neighbor = grid.neighbor(index, direction) orelse {
                    surrounded = false;
                    continue;
                };
                surrounded = surrounded and !disclosed[neighbor];
            }
            if (surrounded) self.isolated.appendAssumeCapacity(index);
            if (self.seen[index]) continue;
            self.seen[index] = true;
            self.queue[0] = index;
            var head: usize = 0;
            var tail: usize = 1;
            var contains_observer = index == observer;
            while (head < tail) : (head += 1) {
                const current = self.queue[head];
                contains_observer = contains_observer or current == observer;
                for (0..6) |direction| {
                    const neighbor = grid.neighbor(current, direction) orelse continue;
                    if (!disclosed[neighbor] or self.seen[neighbor]) continue;
                    self.seen[neighbor] = true;
                    self.queue[tail] = neighbor;
                    tail += 1;
                }
            }
            self.components.appendAssumeCapacity(.{ .first = index, .count = tail, .contains_observer = contains_observer });
        }
    }
};

test "isolated sections exclude the observer and unknown boundary neighbors" {
    const grid: Grid = .{ .minimum = .{ -2, -2, -2 }, .side = 5, .height = 5 };
    var analysis = try Analysis.init(std.testing.allocator, grid.count());
    defer analysis.deinit();
    var visible: [125]bool = @splat(false);
    const observer = grid.index(.{ -1, -1, -1 }).?;
    const island = grid.index(.{ 1, 1, 1 }).?;
    visible[observer] = true;
    visible[island] = true;
    visible[grid.index(.{ 2, 2, 2 }).?] = true;
    analysis.run(grid, &visible, observer);
    try std.testing.expectEqualSlices(usize, &.{island}, analysis.isolated.items);
    try std.testing.expectEqual(@as(usize, 3), analysis.components.items.len);
    visible[grid.index(.{ 1, 0, 1 }).?] = true;
    analysis.run(grid, &visible, observer);
    try std.testing.expectEqual(@as(usize, 0), analysis.isolated.items.len);
    var found = false;
    for (analysis.components.items) |component| found = found or (!component.contains_observer and component.count == 2);
    try std.testing.expect(found);
}
