const std = @import("std");
const behavior = @import("behavior.zig");
const crafting = @import("crafting.zig");
const minecraft = @import("minecraft_model");
const game_data = @import("game_data");
const Player = @import("player_state.zig").Player;

pub const Plan = struct {
    state: u16,
    consume: u16 = 1,
    replacement: union(enum) { normal, clear, stack: crafting.Draft } = .normal,
};
pub const Context = struct {
    player: u128,
    actor: *const Player,
    world: u32,
    position: minecraft.BlockPosition,
    previous: u16,
    hit: minecraft.Place,
    item: crafting.Input,
    standard: Plan,
    scratch: *std.heap.FixedBufferAllocator,
};
pub const Binding = behavior.Binding(Context, ?Plan);
pub const Handler = Binding.Handler;

pub fn validate(plan: Plan, count: u16) !void {
    if (plan.state >= game_data.registry.block_state_names.len or plan.consume > count) return error.InvalidPlacementPlan;
    if (plan.replacement == .stack and (plan.replacement.stack.count == 0 or plan.replacement.stack.count > 99)) return error.InvalidPlacementPlan;
}
