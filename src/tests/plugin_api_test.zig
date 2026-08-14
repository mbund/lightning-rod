const std = @import("std");
const api = @import("../plugin_api.zig");

const Order = struct {
    values: [8]u8 = undefined,
    len: usize = 0,

    fn append(self: *Order, value: u8) void {
        self.values[self.len] = value;
        self.len += 1;
    }
};

const First = struct {
    pub const id = "test:first";
    order: *Order,

    pub fn tick(self: *First, _: std.mem.Allocator) void {
        self.order.append(1);
    }

    pub fn joined(self: *First) void {
        self.order.append(3);
    }

    pub fn left(self: *First) void {
        self.order.append(6);
    }

    pub fn deinit(self: *First) void {
        self.order.append(8);
    }
};

const Second = struct {
    pub const id = "test:second";
    order: *Order,

    pub fn tick(self: *Second, _: std.mem.Allocator) void {
        self.order.append(2);
    }

    pub fn joined(self: *Second) void {
        self.order.append(4);
    }

    pub fn left(self: *Second) void {
        self.order.append(5);
    }

    pub fn deinit(self: *Second) void {
        self.order.append(7);
    }
};

test "composition order is declaration order and teardown is reverse order" {
    var order: Order = .{};
    var first = First{ .order = &order };
    var second = Second{ .order = &order };
    var composition = struct {
        foundation: struct { first: *First },
        gameplay: struct { second: *Second },
    }{
        .foundation = .{ .first = &first },
        .gameplay = .{ .second = &second },
    };

    api.tick(&composition, std.testing.allocator);
    api.joined(&composition);
    api.left(&composition);
    api.deinit(&composition);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, order.values[0..order.len]);
    try std.testing.expectEqual(@as(usize, 2), api.count(@TypeOf(composition)));
}

const CompleteSave = struct {
    pub const id = "test:complete_save";
    calls: u8 = 0,

    pub fn save(self: *CompleteSave) void {
        self.calls += 1;
    }
};

test "save visits each plugin exactly once" {
    var first: CompleteSave = .{};
    var second: CompleteSave = .{};
    var composition = struct {
        first: *CompleteSave,
        second: *CompleteSave,
    }{ .first = &first, .second = &second };

    try api.save(&composition);
    try std.testing.expectEqual(@as(u8, 1), first.calls);
    try std.testing.expectEqual(@as(u8, 1), second.calls);
}
