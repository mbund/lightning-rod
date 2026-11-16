pub const queue = @import("queue.zig");
pub const ticks = @import("ticks.zig");

test {
    _ = queue;
    _ = ticks;
    _ = @import("ticks_test.zig");
}
