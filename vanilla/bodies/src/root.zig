//! Bodies: what any entity's body meets in the world, as vanilla's Entity has it: boxes and
//! collision, the block classes bodies read, vanilla's math and random, and the effects blocks
//! and fluids have on what is inside them.
const std = @import("std");

pub const mth = @import("mth.zig");
pub const java_random = @import("java_random.zig");
pub const mob_blocks = @import("mob_blocks.zig");
pub const shape_classes = @import("shape_classes.zig");
pub const body = @import("body.zig");
pub const block_effects = @import("block_effects.zig");

test {
    std.testing.refAllDecls(@This());
}
