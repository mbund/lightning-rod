const std = @import("std");
const minecraft = @import("minecraft_model");
const inventories = @import("inventories");
const item_data = @import("item_data.zig");
const crafting = @import("crafting.zig");
const behavior = @import("behavior.zig");
const Tags = @import("content_tags.zig").Tags;

pub const minimum_cache_items = 5;

pub const Phase = enum { admission, insertion, burn };
pub const Properties = struct { ticks: u32 = 0, slot_limit: ?u16 = null };
pub const Location = struct { world: u32, position: minecraft.BlockPosition };
pub const Request = struct {
    phase: Phase,
    player: ?u128 = null,
    location: Location,
    stacks: [3]?inventories.Stack,
    previous: ?inventories.Stack = null,
};
pub const Plan = struct {
    properties: Properties,
    replacement: union(enum) { normal, clear, stack: crafting.Draft } = .normal,
};
pub const Prepared = struct { properties: Properties = .{}, remaining: ?inventories.Stack };
pub const Context = struct {
    phase: Phase,
    player: ?u128,
    location: Location,
    fuel: crafting.Input,
    previous: ?crafting.Input,
    input: ?crafting.Input,
    output: ?crafting.Input,
    standard: Properties,
    tags: *const Tags,
    scratch: *std.heap.FixedBufferAllocator,

    pub fn result(self: *const Context, kind: u32, count: u16) !crafting.DraftBuilder {
        if (count == 0 or count > 99) return error.InvalidFuelReplacement;
        return .{ .kind = kind, .count = count, .components = try self.scratch.allocator().alloc(item_data.Component, item_data.maximum_components) };
    }
};

pub const Binding = behavior.Binding(Context, ?Plan);
pub const Handler = Binding.Handler;

pub fn prepare(binding: Binding, context: *const Context) !?Plan {
    std.debug.assert(context.phase != .burn or context.player == null);
    const plan = try binding.call(context) orelse return null;
    if (plan.properties.ticks > std.math.maxInt(i32)) return error.InvalidFuelDuration;
    if (plan.properties.slot_limit) |limit| if (limit > 99) return error.InvalidFuelSlotLimit;
    if (plan.replacement == .stack) {
        const stack = plan.replacement.stack;
        if (stack.count == 0 or stack.count > 99) return error.InvalidFuelReplacement;
    }
    return plan;
}
