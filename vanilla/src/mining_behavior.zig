const std = @import("std");
const behavior = @import("behavior.zig");
const crafting = @import("crafting.zig");
const inventories = @import("inventories");
const minecraft = @import("minecraft_model");
const game_data = @import("game_data");
const Player = @import("player_state.zig").Player;

pub const Plan = struct {
    hardness: f32 = -1,
    diggable: bool = false,
    speed: f32 = 1,
    harvest: bool = false,
    experience: game_data.physics_data.Experience = .{},
    tool_damage: u32 = 1,
    replacement: u16 = 0,
};
pub const Request = struct {
    actor: ?*const Player = null,
    world: u32,
    position: minecraft.BlockPosition,
    state: u16,
    tool: ?inventories.Stack = null,
    tick: u64 = 0,
};
pub const Context = struct {
    player: ?u128,
    actor: ?*const Player,
    world: u32,
    position: minecraft.BlockPosition,
    state: u16,
    tool: ?crafting.Input,
    tick: u64,
    standard: Plan,
    scratch: *std.heap.FixedBufferAllocator,
};
pub const Binding = behavior.Binding(Context, ?Plan);
pub const Handler = Binding.Handler;

pub fn validate(plan: Plan) !void {
    if (!std.math.isFinite(plan.hardness) or !std.math.isFinite(plan.speed) or plan.speed < 0 or plan.tool_damage > std.math.maxInt(i32)) return error.InvalidMiningPlan;
    if (plan.replacement >= game_data.registry.block_state_names.len) return error.InvalidMiningPlan;
    if (plan.experience.rolls != 0 and plan.experience.bound == 0) return error.InvalidMiningPlan;
}
