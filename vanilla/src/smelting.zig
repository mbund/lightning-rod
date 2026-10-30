const std = @import("std");
const behavior = @import("behavior.zig");
const crafting = @import("crafting.zig");
const inventories = @import("inventories");
const Items = @import("items.zig").Items;
const minecraft = @import("minecraft_model");

pub const Plan = struct {
    result: crafting.Draft,
    ticks: u32,
    experience: f32 = 0,
    consume: u16 = 1,
    input_replacement: union(enum) { normal, clear, stack: crafting.Draft } = .normal,
};
pub const Context = struct {
    world: u32,
    position: minecraft.BlockPosition,
    input: crafting.Input,
    fuel: ?crafting.Input,
    output: ?crafting.Input,
    standard: Plan,
    scratch: *std.heap.FixedBufferAllocator,
};
pub const Binding = behavior.Binding(Context, ?Plan);
pub const Handler = Binding.Handler;
pub const Prepared = struct {
    plan: Plan,
    result: inventories.Stack,
    maximum: u16,
    index: u32,
    dynamic: bool,
    pins: [3]Items.Prepared = undefined,
    count: usize = 0,

    pub fn release(self: *const Prepared) void {
        for (self.pins[0..self.count]) |pin| pin.release();
    }
};

pub const Selection = struct {
    input_kind: ?u32 = null,
    recipe: ?Prepared = null,

    pub fn release(self: *const Selection) void {
        if (self.recipe) |*recipe| recipe.release();
    }
};

pub fn validate(plan: Plan) !void {
    if (plan.ticks == 0 or plan.ticks > std.math.maxInt(i32) or !std.math.isFinite(plan.experience) or plan.experience < 0 or plan.experience >= 2147483648) return error.InvalidSmeltingPlan;
    if (plan.result.count == 0 or plan.result.count > 99) return error.InvalidSmeltingPlan;
    if (plan.input_replacement == .stack) {
        const stack = plan.input_replacement.stack;
        if (stack.count == 0 or stack.count > 99) return error.InvalidSmeltingPlan;
    }
}
