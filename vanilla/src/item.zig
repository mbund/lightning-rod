const std = @import("std");
const inventories = @import("inventories");

pub const State = struct {
    stack: inventories.Stack,
    maximum_stack: u16,
    owner: ?u128 = null,
    age: i32 = 0,
    pickup_delay: u16 = 10,

    pub fn valid(self: State) bool {
        return self.maximum_stack > 0 and self.stack.count > 0 and
            self.stack.count <= self.maximum_stack and self.pickup_delay <= 32767;
    }
};

pub const Merge = struct {
    destination: State,
    source: ?State,
    destination_is_first: bool,
    transferred: u16,

    pub fn check(self: Merge, first: State, second: State) void {
        std.debug.assert(first.valid());
        std.debug.assert(second.valid());
        std.debug.assert(self.destination.valid());

        if (self.source) |source| std.debug.assert(source.valid());
        std.debug.assert(self.transferred > 0);
        std.debug.assert(@as(u32, first.stack.count) + second.stack.count ==
            @as(u32, self.destination.stack.count) + if (self.source) |source| @as(u32, source.stack.count) else 0);
    }
};
