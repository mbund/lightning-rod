const std = @import("std");
const inventories = @import("inventories");
const item_data = @import("item_data.zig");
const containers = @import("containers.zig");
const chunks = @import("chunks");

pub const encoded_bytes = 85;
pub const State = struct {
    burn_left: u32 = 0,
    burn_total: u32 = 0,
    cook: u32 = 0,
    duration: u32 = 0,
    input: i32 = -1,
    active: bool = false,
    source: [32]u8 = @splat(0),
    recipe: [32]u8 = @splat(0),

    pub fn decode(raw: ?[]const u8) !State {
        const bytes = raw orelse return .{};
        if (bytes.len != encoded_bytes or bytes[0] != 2) return error.CorruptFurnace;
        const self: State = .{
            .burn_left = std.mem.readInt(u32, bytes[1..5], .little),
            .burn_total = std.mem.readInt(u32, bytes[5..9], .little),
            .cook = std.mem.readInt(u32, bytes[9..13], .little),
            .duration = std.mem.readInt(u32, bytes[13..17], .little),
            .input = std.mem.readInt(i32, bytes[17..21], .little),
            .active = true,
            .source = bytes[21..53].*,
            .recipe = bytes[53..85].*,
        };
        if (self.burn_left > self.burn_total or self.cook > self.duration) return error.CorruptFurnace;
        return self;
    }

    pub fn encode(self: State, bytes: []u8) void {
        std.debug.assert(bytes.len >= encoded_bytes and self.burn_left <= self.burn_total and self.cook <= self.duration);
        std.debug.assert(self.active);
        bytes[0] = 2;
        std.mem.writeInt(u32, bytes[1..5], self.burn_left, .little);
        std.mem.writeInt(u32, bytes[5..9], self.burn_total, .little);
        std.mem.writeInt(u32, bytes[9..13], self.cook, .little);
        std.mem.writeInt(u32, bytes[13..17], self.duration, .little);
        std.mem.writeInt(i32, bytes[17..21], self.input, .little);
        @memcpy(bytes[21..53], &self.source);
        @memcpy(bytes[53..85], &self.recipe);
    }
};

const batch_size = 32;

pub fn tick(self: *containers.Containers) !void {
    const capacity = @min(batch_size, self.active.len, self.deps.inventories.cache.entries.len / 3, self.deps.chunks.cache.entries.len);
    std.debug.assert(capacity > 0);
    var end = self.active_count;
    while (end > 0) {
        const begin = end - @min(end, capacity);
        var keys: [batch_size]containers.Key = undefined;
        var sections: [batch_size]chunks.Section = undefined;
        var count: usize = 0;
        for (self.active[begin..end]) |resident| {
            const key = resident.key;
            var nearby = self.deps.players.nearby(key.world, .{ .x = @floatFromInt(key.position.x), .y = @floatFromInt(key.position.y), .z = @floatFromInt(key.position.z) }, self.deps.players.config.simulation_distance);
            var loaded = false;
            while (nearby.next()) |player| if (self.deps.players.records[player].inWorld()) {
                loaded = true;
                break;
            };
            if (!loaded) continue;
            keys[count] = key;
            sections[count] = chunks.sectionAt(key.world, key.position);
            count += 1;
        }
        end = begin;
        if (count == 0) continue;
        var block_states: [batch_size]u16 = undefined;
        {
            var window = chunks.ReadWindow(batch_size).init(self.deps.chunks);
            defer window.deinit();
            var views: [batch_size]chunks.View = undefined;
            try window.readMany(sections[0..count], views[0..count]);
            for (keys[0..count], views[0..count], block_states[0..count]) |key, view, *state| state.* = view.get(chunks.localIndex(key.position));
        }
        var slots: [batch_size * 3]inventories.Slot = undefined;
        var contents: [batch_size * 3]inventories.Contents = undefined;
        for (keys[0..count], 0..) |key, index| {
            const owner = key.owner();
            for (slots[index * 3 ..][0..3], 0..) |*slot, at| slot.* = .{ .owner = owner, .index = @intCast(at) };
        }
        try self.deps.inventories.getMany(slots[0 .. count * 3], contents[0 .. count * 3]);
        var edits: [batch_size * 3]inventories.Edit = undefined;
        var edited: usize = 0;
        var changes: [batch_size]chunks.SectionEdits = undefined;
        var block_edits: [batch_size][batch_size]chunks.BlockEdit = undefined;
        var change_count: usize = 0;
        errdefer self.deps.storage.fail();
        for (0..count) |offset| {
            const index = count - 1 - offset;
            const key = keys[index];
            const block = block_states[index];
            if (self.states.kind(block) != .furnace) {
                self.deactivate(key);
                continue;
            }
            var state = self.active[self.active_index.get(key).?].state;
            const old = contents[index * 3 ..][0..3];
            const next = try advance(self, key, &state, old.*);
            for (slots[index * 3 ..][0..3], old, next) |slot, previous, stack| {
                if (std.meta.eql(previous.stack, stack)) continue;
                edits[edited] = .{ .slot = slot, .revision = previous.revision, .stack = stack };
                edited += 1;
            }
            const lit = state.burn_left > 0;
            const block_info = self.states.furnaceInfo(block);
            if (block_info.lit != lit) {
                const updated = self.states.furnaces[@intFromEnum(block_info.facing)][@intFromBool(lit)];
                const section = sections[index];
                const at = for (changes[0..change_count], 0..) |change, position| {
                    if (std.meta.eql(change.section, section)) break position;
                } else added: {
                    changes[change_count] = .{ .section = section, .edits = block_edits[change_count][0..0] };
                    change_count += 1;
                    break :added change_count - 1;
                };
                const length = changes[at].edits.len;
                block_edits[at][length] = .{ .index = chunks.localIndex(key.position), .state = updated };
                changes[at].edits = block_edits[at][0 .. length + 1];
            }
            state.active = lit or state.cook != 0;
            if (state.active) self.active[self.active_index.get(key).?].state = state else self.deactivate(key);
        }
        if (edited != 0) {
            const committed = try self.deps.inventories.editMany(edits[0..edited]);
            std.debug.assert(committed);
        }
        if (change_count != 0) try self.deps.chunks.setSections(changes[0..change_count]);
    }
}

fn advance(self: *containers.Containers, key: containers.Key, state: *State, contents: [3]inventories.Contents) ![3]?inventories.Stack {
    var next: [3]?inventories.Stack = undefined;
    for (contents, &next) |value, *stack| stack.* = value.stack;
    self.deps.inventory.scratch.reset();
    const selected = try self.deps.furnaces.prepareSmelting(self.deps.inventory.deps.items, .{
        .world = key.world,
        .position = .{ .x = key.position.x, .y = key.position.y, .z = key.position.z },
    }, next, &self.deps.inventory.scratch);
    defer selected.release();
    const kind = selected.input_kind;
    const recipe = selected.recipe;
    const input_kind: i32 = if (kind) |value| @intCast(value) else -1;
    const recipe_id: [32]u8 = if (recipe) |value| self.reward_ids[value.index] else @splat(0);
    const source_id: [32]u8 = if (recipe != null and recipe.?.dynamic) next[0].?.item else @splat(0);
    const duration = if (recipe) |value| value.plan.ticks else 0;
    if (state.input != input_kind or !std.mem.eql(u8, &state.recipe, &recipe_id) or !std.mem.eql(u8, &state.source, &source_id) or state.duration != duration) state.cook = 0;
    state.input = input_kind;
    state.recipe = recipe_id;
    state.source = source_id;
    state.duration = duration;
    const result: ?inventories.Stack = if (recipe) |value| value.result else null;
    var can_cook = result != null;
    if (result) |output| {
        const maximum = recipe.?.maximum;
        std.debug.assert(output.count > 0 and output.count <= maximum);
        if (next[2]) |present| {
            can_cook = inventories.Stack.sameItem(output, present) and output.count <= maximum -| present.count;
        } else can_cook = output.count <= maximum;
    }
    const burning = state.burn_left > 0;
    if (burning) state.burn_left -= 1;
    if (state.burn_left == 0 and can_cook) if (next[1] != null) {
        const prepared = try self.deps.furnaces.burnFuel(self.deps.inventory.deps.items, .{
            .phase = .burn,
            .location = .{ .world = key.world, .position = .{ .x = key.position.x, .y = key.position.y, .z = key.position.z } },
            .stacks = next,
        }, &self.deps.inventory.scratch);
        if (prepared.properties.ticks != 0) {
            state.burn_left = prepared.properties.ticks;
            state.burn_total = prepared.properties.ticks;
            next[1] = prepared.remaining;
        }
    };
    if (state.burn_left > 0 and can_cook) {
        state.cook += 1;
        if (state.cook == state.duration) {
            state.cook = 0;
            try self.recordCooking(key, recipe.?.index, if (recipe.?.dynamic) recipe.?.plan.experience else null);
            const input = next[0].?;
            const output = result.?;
            const draft = recipe.?.plan.result;
            const materialized = try item_data.define(self.deps.inventories, draft.kind, draft.components);
            std.debug.assert(std.mem.eql(u8, &materialized, &output.item));
            switch (recipe.?.plan.input_replacement) {
                .normal => next[0] = if (input.count == recipe.?.plan.consume) null else .{ .item = input.item, .count = input.count - recipe.?.plan.consume },
                .clear => next[0] = null,
                .stack => |replacement| {
                    if (replacement.count > try self.deps.inventory.deps.items.maximumDefinition(replacement.kind, replacement.components)) return error.InvalidSmeltingPlan;
                    next[0] = .{ .item = try item_data.define(self.deps.inventories, replacement.kind, replacement.components), .count = replacement.count };
                },
            }
            const previous_count = if (next[2]) |present| present.count else @as(u16, 0);
            next[2] = .{ .item = output.item, .count = output.count + previous_count };
            if (next[1]) |fuel| for (0..self.deps.furnaces.table.fuel_conversions.len) |offset| {
                const rules = self.deps.furnaces.table.fuel_conversions;
                const rule = rules[rules.len - offset - 1];
                if (rule.input != kind.?) continue;
                if (rule.fuel != try self.deps.inventory.deps.items.kind(fuel)) continue;
                if (rule.result) |replacement| next[1] = .{ .item = try self.deps.inventory.deps.items.defineKind(replacement), .count = 1 };
                break;
            };
        }
    } else if (state.burn_left > 0) state.cook = 0 else state.cook -|= 2;
    return next;
}

test "furnace persistence preserves every counter and rejects invalid state" {
    const original: State = .{ .burn_left = 123, .burn_total = 1600, .cook = 87, .duration = 200, .input = 45, .active = true };
    var bytes: [encoded_bytes]u8 = undefined;
    original.encode(&bytes);
    try std.testing.expectEqualDeep(original, try State.decode(&bytes));
    bytes[0] = 0xff;
    try std.testing.expectError(error.CorruptFurnace, State.decode(&bytes));
}
