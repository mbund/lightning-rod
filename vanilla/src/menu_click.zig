const std = @import("std");
const game_data = @import("game_data");
const inventories = @import("inventories");
const minecraft = @import("minecraft_model");
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;

pub const maximum_slots = 92;
pub const Kind = enum { player, chest, furnace, crafting };
pub const Drag = struct { slots: u128 = 0, button: ?i8 = null };
pub const Result = struct { drops: [10]inventories.Stack = undefined, count: usize = 0 };

pub const Menu = struct {
    inventory: *PlayerInventory,
    kind: Kind,
    container_slots: usize,
    stacks: []?inventories.Stack,
    drag: *Drag,
    creative: bool,

    pub fn visible(self: Menu) usize {
        return if (self.kind == .player) 46 else self.container_slots + 36;
    }

    pub fn cursor(self: Menu) usize {
        return self.visible();
    }

    fn hotbar(self: Menu) usize {
        return if (self.kind == .player) 36 else self.container_slots + 27;
    }

    fn offhand(self: Menu) usize {
        return if (self.kind == .player) 45 else self.visible() + 1;
    }

    fn output(self: Menu) ?usize {
        return switch (self.kind) {
            .player, .crafting => 0,
            .furnace => 2,
            .chest => null,
        };
    }

    fn limit(self: Menu, at: usize, stack: inventories.Stack) !u16 {
        if (self.output() == at) return 0;
        if (self.kind == .player) return self.inventory.slotLimit(at, stack);
        if (self.kind == .furnace and at < 2) {
            const kind = try self.inventory.deps.items.kind(stack);
            if (at == 1 and self.inventory.recipes.fuels[kind].ticks == 0) {
                return if (std.mem.eql(u8, game_data.registry.itemName(@intCast(kind)).?, "minecraft:bucket")) 1 else 0;
            }
        }
        return self.inventory.deps.items.stackLimit(stack);
    }

    fn transfer(self: Menu, source: usize, begin: usize, end: usize, reverse: bool) !void {
        std.debug.assert(source < self.stacks.len and begin <= end and end <= self.visible());
        const held = self.stacks[source] orelse return;
        var remaining = held.count;
        for (0..2) |pass| for (begin..end) |offset| {
            const at = if (reverse) end - 1 - (offset - begin) else offset;
            if (at == source or remaining == 0) continue;
            const previous = if (self.stacks[at]) |stack| stack.count else 0;
            if (pass == 0) {
                if (self.stacks[at] == null or !inventories.Stack.sameItem(held, self.stacks[at].?)) continue;
            } else if (self.stacks[at] != null) continue;
            const amount = @min(remaining, (try self.limit(at, held)) -| previous);
            if (amount == 0) continue;
            self.stacks[at] = .{ .item = held.item, .count = previous + amount };
            remaining -= amount;
        };
        self.stacks[source] = if (remaining == 0) null else .{ .item = held.item, .count = remaining };
    }

    fn grid(self: Menu) []?inventories.Stack {
        return self.stacks[1..if (self.kind == .player) 5 else 10];
    }

    fn recipe(self: Menu) !?*const game_data.recipe_data.Craft {
        var kinds: [9]?u32 = @splat(null);
        const inputs = self.grid();
        for (inputs, 0..) |stack, at| if (stack) |held| {
            kinds[at] = try self.inventory.deps.items.kind(held);
        };
        return self.inventory.recipes.matches(kinds[0..inputs.len], if (self.kind == .player) 2 else 3);
    }

    pub fn refresh(self: Menu) !void {
        if (self.kind != .player and self.kind != .crafting) return;
        self.stacks[0] = if (try self.recipe()) |craft| .{
            .item = try self.inventory.deps.items.defineKind(craft.output),
            .count = craft.amount,
        } else null;
    }

    fn takeCraft(self: Menu, click: minecraft.InventoryClick) !Result {
        var result: Result = .{};
        if (click.mode != 0 and click.mode != 1 and click.mode != 2 and click.mode != 4) return result;
        if ((click.mode == 0 or click.mode == 4) and click.button != 0 and click.button != 1) return result;
        if (click.mode == 2 and (click.button < 0 or (click.button > 8 and click.button != 40))) return result;
        try self.refresh();
        const initial = self.stacks[0] orelse return result;
        var crafts: u16 = 0;
        while (crafts < 99) {
            const output_stack = self.stacks[0] orelse break;
            if (!inventories.Stack.sameItem(initial, output_stack)) break;
            var repeats: u16 = if (click.mode == 1) 99 - crafts else 1;
            var remainders: [9]?u32 = @splat(null);
            for (self.grid(), 0..) |entry, at| if (entry) |stack| {
                const kind = try self.inventory.deps.items.kind(stack);
                remainders[at] = self.inventory.recipes.fuels[kind].remainder;
                repeats = @min(repeats, stack.count);
                if (remainders[at] != null) repeats = 1;
            };
            const maximum = try self.inventory.deps.items.stackLimit(output_stack);
            if (click.mode == 1) {
                var capacity: usize = 0;
                const begin: usize = if (self.kind == .player) 9 else self.container_slots;
                for (self.stacks[begin .. self.hotbar() + 9]) |stack| {
                    if (stack == null) capacity += maximum else if (inventories.Stack.sameItem(stack.?, output_stack)) {
                        capacity += maximum -| stack.?.count;
                    }
                }
                if (capacity == 0) break;
                repeats = @min(repeats, @as(u16, @intCast((capacity + output_stack.count - 1) / output_stack.count)));
                self.stacks[0] = .{ .item = output_stack.item, .count = output_stack.count * repeats };
                try self.transfer(0, begin, self.hotbar() + 9, true);
                if (self.stacks[0]) |overflow| {
                    result.drops[result.count] = overflow;
                    result.count += 1;
                }
            } else if (click.mode == 4) {
                if (self.stacks[self.cursor()] != null or result.count == result.drops.len) break;
                result.drops[result.count] = output_stack;
                result.count += 1;
            } else {
                const destination = if (click.mode == 0) self.cursor() else if (click.button == 40) self.offhand() else self.hotbar() + @as(usize, @intCast(click.button));
                const previous = if (self.stacks[destination]) |stack| stack.count else 0;
                if (self.stacks[destination]) |stack| if (!inventories.Stack.sameItem(stack, output_stack)) break;
                if (output_stack.count > maximum -| previous) break;
                self.stacks[destination] = .{ .item = output_stack.item, .count = previous + output_stack.count };
            }
            var changed = false;
            for (self.grid(), 1..) |*entry, at| {
                const stack = entry.* orelse continue;
                std.debug.assert(stack.count >= repeats and repeats > 0);
                changed = changed or stack.count == repeats;
                entry.* = if (stack.count == repeats) null else .{ .item = stack.item, .count = stack.count - repeats };
                if (remainders[at - 1]) |remainder| {
                    std.debug.assert(repeats == 1);
                    changed = true;
                    const returned: inventories.Stack = .{ .item = try self.inventory.deps.items.defineKind(remainder), .count = 1 };
                    if (entry.* == null) {
                        entry.* = returned;
                    } else {
                        const original = self.stacks[0];
                        self.stacks[0] = returned;
                        try self.transfer(0, if (self.kind == .player) 9 else self.container_slots, self.hotbar() + 9, false);
                        if (self.stacks[0]) |overflow| {
                            std.debug.assert(result.count < result.drops.len);
                            result.drops[result.count] = overflow;
                            result.count += 1;
                        }
                        self.stacks[0] = original;
                    }
                }
                std.debug.assert(at < self.stacks.len);
            }
            crafts += repeats;
            if (changed) try self.refresh() else self.stacks[0] = output_stack;
            if (click.mode != 1 or result.count > result.drops.len - 9) break;
        }
        return result;
    }

    pub fn apply(self: Menu, click: minecraft.InventoryClick) !Result {
        std.debug.assert(self.stacks.len == self.visible() + (if (self.kind == .player) @as(usize, 1) else 2));
        std.debug.assert(self.stacks.len <= maximum_slots);
        std.debug.assert(switch (self.kind) {
            .player => self.container_slots == 0,
            .chest => self.container_slots > 0 and self.container_slots <= 54,
            .furnace => self.container_slots == 3,
            .crafting => self.container_slots == 10,
        });
        var result: Result = .{};
        const carried = self.cursor();
        if (click.mode == 5) {
            if (click.button < 0 or click.button > (if (self.creative) @as(i8, 10) else 6)) return result;
            const button = @divTrunc(click.button, 4);
            const phase = @mod(click.button, 4);
            const held = self.stacks[carried] orelse return result;
            if (phase == 0) {
                self.drag.* = .{ .button = button };
                return result;
            }
            if (self.drag.button == null or self.drag.button.? != button) return result;
            if (phase == 1) {
                if (click.slot < 0 or click.slot >= self.visible()) return result;
                const at: usize = @intCast(click.slot);
                if (button != 2 and @popCount(self.drag.slots) >= held.count) return result;
                const limit_count = try self.limit(at, held);
                if (self.stacks[at]) |target| if (!inventories.Stack.sameItem(held, target) or target.count >= limit_count) return result;
                if (limit_count != 0) self.drag.slots |= @as(u128, 1) << @intCast(at);
                return result;
            }
            const count = @popCount(self.drag.slots);
            if (phase != 2 or count == 0) return result;
            const each = if (button == 0) held.count / count else @as(u16, 1);
            var remaining = held.count;
            for (0..self.visible()) |at| {
                if (self.drag.slots & (@as(u128, 1) << @intCast(at)) == 0) continue;
                if (self.stacks[at]) |target| if (!inventories.Stack.sameItem(held, target)) continue;
                const previous = if (self.stacks[at]) |target| target.count else 0;
                const maximum = try self.limit(at, held);
                const amount = if (button == 2) maximum -| previous else @min(each, maximum -| previous, remaining);
                if (amount == 0) continue;
                self.stacks[at] = .{ .item = held.item, .count = previous + amount };
                if (button != 2) remaining -= amount;
            }
            self.stacks[carried] = if (remaining == 0) null else .{ .item = held.item, .count = remaining };
            self.drag.* = .{};
            return result;
        }
        self.drag.* = .{};
        if (click.slot == -999 and click.mode == 0 and (click.button == 0 or click.button == 1)) {
            const held = self.stacks[carried] orelse return result;
            const amount = if (click.button == 0) held.count else 1;
            result.drops[0] = .{ .item = held.item, .count = amount };
            result.count = 1;
            self.stacks[carried] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
            return result;
        }
        if (click.slot < 0 or click.slot >= self.visible()) return result;
        const at: usize = @intCast(click.slot);
        if ((self.kind == .player or self.kind == .crafting) and at == 0) return self.takeCraft(click);
        switch (click.mode) {
            0 => {
                if (click.button != 0 and click.button != 1) return result;
                if (self.stacks[carried]) |held| {
                    if (self.kind == .furnace and at == 2) {
                        const target = self.stacks[at] orelse return result;
                        if (!inventories.Stack.sameItem(held, target)) return result;
                        const amount = @min(target.count, (try self.inventory.deps.items.stackLimit(held)) -| held.count);
                        self.stacks[carried].?.count += amount;
                        self.stacks[at] = if (amount == target.count) null else .{ .item = target.item, .count = target.count - amount };
                        return result;
                    }
                    const maximum = try self.limit(at, held);
                    if (maximum == 0) return result;
                    if (self.stacks[at]) |target| {
                        if (inventories.Stack.sameItem(held, target)) {
                            const amount = @min(if (click.button == 1) @as(u16, 1) else held.count, maximum -| target.count);
                            self.stacks[at].?.count += amount;
                            self.stacks[carried] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                        } else if (held.count <= maximum) std.mem.swap(?inventories.Stack, &self.stacks[carried], &self.stacks[at]);
                    } else {
                        const amount = @min(maximum, if (click.button == 1) @as(u16, 1) else held.count);
                        self.stacks[at] = .{ .item = held.item, .count = amount };
                        self.stacks[carried] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                    }
                } else if (self.stacks[at]) |target| {
                    const amount = if (click.button == 1) (target.count + 1) / 2 else target.count;
                    self.stacks[carried] = .{ .item = target.item, .count = amount };
                    self.stacks[at] = if (amount == target.count) null else .{ .item = target.item, .count = target.count - amount };
                }
            },
            1 => {
                const source = self.stacks[at] orelse return result;
                if (self.kind == .player) {
                    const equipment = try self.inventory.deps.equipment.slot(source);
                    const armor: ?usize = if (equipment >= 2 and equipment <= 5) 10 - @as(usize, equipment) else if (equipment == 1) 45 else null;
                    if (at >= 9 and armor != null and self.stacks[armor.?] == null) try self.transfer(at, armor.?, armor.? + 1, false);
                    try self.transfer(at, if (at >= 9 and at < 36) 36 else 9, if (at >= 36 and at < 45) 36 else 45, false);
                } else if (at < self.container_slots) {
                    try self.transfer(at, self.container_slots, self.visible(), true);
                } else {
                    if (self.kind == .furnace) {
                        const kind = try self.inventory.deps.items.kind(source);
                        if (self.inventory.recipes.recipes[kind] != null) {
                            try self.transfer(at, 0, 1, false);
                            return result;
                        }
                        if (self.inventory.recipes.fuels[kind].ticks != 0) {
                            try self.transfer(at, 1, 2, false);
                            return result;
                        }
                    } else if (self.kind == .chest) {
                        try self.transfer(at, 0, self.container_slots, false);
                        return result;
                    }
                    try self.transfer(at, if (at < self.hotbar()) self.hotbar() else self.container_slots, if (at < self.hotbar()) self.visible() else self.hotbar(), false);
                }
            },
            2 => {
                if (click.button < 0 or (click.button > 8 and click.button != 40)) return result;
                const to = if (click.button == 40) self.offhand() else self.hotbar() + @as(usize, @intCast(click.button));
                if (to == at) return result;
                if (self.stacks[to]) |held| {
                    const maximum = try self.limit(at, held);
                    if (maximum == 0) return result;
                    if (held.count > maximum) {
                        const displaced = self.stacks[at];
                        self.stacks[at] = .{ .item = held.item, .count = maximum };
                        self.stacks[to].?.count -= maximum;
                        if (displaced) |stack| {
                            const original = self.stacks[carried];
                            self.stacks[carried] = stack;
                            try self.transfer(carried, if (self.kind == .player) 9 else self.container_slots, self.hotbar() + 9, false);
                            if (self.stacks[carried]) |remaining| {
                                result.drops[0] = remaining;
                                result.count = 1;
                            }
                            self.stacks[carried] = original;
                        }
                        return result;
                    }
                }
                std.mem.swap(?inventories.Stack, &self.stacks[to], &self.stacks[at]);
            },
            3 => {
                if (!self.creative or click.button != 2 or self.stacks[carried] != null) return result;
                const stack = self.stacks[at] orelse return result;
                self.stacks[carried] = .{ .item = stack.item, .count = try self.inventory.deps.items.stackLimit(stack) };
            },
            4 => {
                if ((click.button != 0 and click.button != 1) or self.stacks[carried] != null) return result;
                const held = self.stacks[at] orelse return result;
                const amount = if (click.button == 1) held.count else 1;
                result.drops[0] = .{ .item = held.item, .count = amount };
                result.count = 1;
                self.stacks[at] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
            },
            6 => {
                if ((click.button != 0 and click.button != 1) or self.stacks[at] != null) return result;
                const held = self.stacks[carried] orelse return result;
                const maximum = try self.inventory.deps.items.stackLimit(held);
                for (0..2) |pass| for (0..self.visible()) |offset| {
                    const index = if (click.button == 0) offset else self.visible() - 1 - offset;
                    if (index == self.output()) continue;
                    const stack = self.stacks[index] orelse continue;
                    if (!inventories.Stack.sameItem(held, stack) or (pass == 0 and stack.count == maximum)) continue;
                    const amount = @min(stack.count, maximum -| self.stacks[carried].?.count);
                    self.stacks[carried].?.count += amount;
                    self.stacks[index] = if (amount == stack.count) null else .{ .item = stack.item, .count = stack.count - amount };
                };
            },
            else => {},
        }
        return result;
    }
};
