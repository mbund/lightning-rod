pub const random_ticks = @import("random_ticks.zig");

test {
    _ = random_ticks;
    _ = @import("random_ticks_test.zig");
}
