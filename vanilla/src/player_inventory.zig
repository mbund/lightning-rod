const fuel = @import("fuel.zig");
const recipes = @import("recipes.zig");
const crafting = @import("crafting.zig");
const std = @import("std");
const menu_click = @import("menu_click.zig");
const item_data = @import("item_data.zig");
const entities = @import("entities");
const wire_1_21_5 = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const item_entities = @import("item_entities.zig");
const inventories = @import("inventories");
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const Players = @import("players.zig").Players;
const Items = @import("items.zig").Items;
const Crafting = @import("crafting_registry.zig").Crafting;
const Furnaces = @import("furnaces.zig").Furnaces;
const EquipmentSlots = @import("item_properties.zig").EquipmentSlots;
const sessions = @import("sessions");
const item_packets = @import("item_packets.zig");

const assert = std.debug.assert;

pub const PlayerInventory = struct {
    pub const id = "minecraft:player_inventory";

    pub const Configuration = struct { scratch_bytes: usize = 64 * 1024 };

    pub const Dependencies = struct {
        crafting: *Crafting,
        furnaces: *Furnaces,
        players: *Players,
        inventories: *inventories.Inventories,
        items: *Items,
        equipment: *EquipmentSlots,
        dropped: *item_entities.ItemEntities,
    };

    pub const State = struct {
        generation: u32 = 0,
        life: u32 = 0,
        revision: i32 = 0,
        presentation: u64 = 0,
        dirty: u64 = all_slots,
        drag: menu_click.Drag = .{},
        selected: u4 = 0,
        close: bool = true,
        synchronized: bool = false,
        external: bool = false,
        gamemode: minecraft.GameMode = .survival,
    };

    pub const cursor = 46;
    // Table inputs belong to the player so close and restart use the same recovery path.
    pub const table_grid_first: u16 = 100;
    pub const table_grid_count = 9;
    pub const all_slots = (@as(u64, 1) << 47) - 1;

    pub fn writeInventory(packet: wire_1_21_5.play.toClient.packet_window_items.Writer, registry: packets.Registry, store: *Items, revision: i32, contents: []const inventories.Contents, recipient: u128) ![]u8 {
        assert(contents.len == 47);
        return writeContents(packet, registry, store, 0, revision, contents[0..46], contents[46], recipient);
    }

    pub fn writeContents(packet: wire_1_21_5.play.toClient.packet_window_items.Writer, registry: packets.Registry, store: *Items, window: i32, revision: i32, contents: []const inventories.Contents, carried_stack: inventories.Contents, recipient: u128) ![]u8 {
        const body = try (try packet.windowId(window)).stateId(revision);
        var items = try body.items(@intCast(contents.len));
        var base: usize = 0;
        while (base < contents.len) {
            const count = @min(16, store.views.len, contents.len - base);
            var stacks: [16]inventories.Stack = undefined;
            var prepared: [16]Items.Prepared = undefined;
            var occupied: usize = 0;
            for (contents[base..][0..count]) |entry| if (entry.stack) |stack| {
                stacks[occupied] = stack;
                occupied += 1;
            };
            try store.acquireMany(stacks[0..occupied], prepared[0..occupied]);
            defer for (prepared[0..occupied]) |held| held.release();
            var index: usize = 0;
            for (contents[base..][0..count]) |entry| {
                const view = if (entry.stack != null) prepared[index].view else null;
                index += @intFromBool(entry.stack != null);
                const item = (try items.next()).?;
                try items.advance(try item_packets.writeSlot(item, .{
                    .registry = registry,
                    .items = store,
                    .stack = entry.stack,
                    .recipient = recipient,
                    .view = view,
                }));
            }
            base += count;
        }
        const prepared_cursor = if (carried_stack.stack) |stack| try store.acquire(stack) else null;
        defer if (prepared_cursor) |prepared| prepared.release();
        const carried = try items.finish();
        var item = try carried.carriedItem();
        const done = try item_packets.writeSlot(try item.begin(), .{
            .registry = registry,
            .items = store,
            .stack = carried_stack.stack,
            .view = if (prepared_cursor) |prepared| prepared.view else null,
            .recipient = recipient,
        });
        return (try item.advance(done)).finish();
    }

    deps: Dependencies,
    states: []State,
    recipes: *const recipes.CraftingTable,
    scratch: std.heap.FixedBufferAllocator,
    crafting_completions: []crafting.Completion,
    crafting_groups: std.AutoHashMapUnmanaged(crafting.Group, u8) = .empty,
    crafting_count: usize = 0,
    crafting_epoch: u64 = 0,
    crafting_committed: bool = false,
    crafting_planning: bool = false,
    crafting_validated: bool = false,
    const maximum_drops = 128;

    pub fn fail(self: *PlayerInventory) void {
        self.deps.inventories.deps.storage.fail();
    }

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*PlayerInventory {
        if (deps.inventories.cache.entries.len < 47) return error.InventoryCacheTooSmall;
        if (configuration.scratch_bytes == 0) return error.InvalidConfiguration;

        const self = try allocator.create(PlayerInventory);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        self.* = .{
            .deps = deps,
            .states = states,
            .recipes = &deps.crafting.table,
            .scratch = .init(try allocator.alloc(u8, configuration.scratch_bytes)),
            .crafting_completions = try allocator.alloc(crafting.Completion, crafting.maximum_crafts),
        };
        try self.crafting_groups.ensureTotalCapacity(allocator, crafting.maximum_crafts);
        try self.definitionsChanged();
        try deps.crafting.registry.onChange(self, definitionsChanged);
        try deps.furnaces.registry.onChange(self, definitionsChanged);
        return self;
    }

    fn definitionsChanged(self: *PlayerInventory) !void {
        for (self.deps.furnaces.table.fuels) |properties| {
            if (properties.callback != null and self.deps.inventories.items.entries.len < fuel.minimum_cache_items) return error.InventoryCacheTooSmall;
        }
        for (self.deps.crafting.table.crafting) |recipe| try validateResult(self.deps.items, self.deps.inventories, .{ .kind = recipe.output, .count = recipe.amount, .components = recipe.components });
        for (self.deps.furnaces.table.recipes) |entry| if (entry) |recipe| try validateResult(self.deps.items, self.deps.inventories, .{ .kind = recipe.output, .count = recipe.count, .components = recipe.components });
        for (self.deps.crafting.table.algorithms) |algorithm| {
            if (algorithm.binding.maximum_inputs > 9 or algorithm.binding.minimum_inputs > algorithm.binding.maximum_inputs) return error.InvalidRecipeInputs;
            if (self.deps.inventories.items.entries.len <= algorithm.binding.maximum_inputs) return error.InventoryCacheTooSmall;
        }
    }

    fn validateResult(items: *Items, store: *const inventories.Inventories, draft: crafting.Draft) !void {
        if (draft.count == 0 or draft.components.len > item_data.maximum_components) return error.InvalidRecipeResult;
        if (draft.count > try items.maximumDefinition(draft.kind, draft.components)) return error.InvalidRecipeResult;
        for (draft.components, 0..) |component, index| {
            for (draft.components[0..index]) |previous| if (component.key == previous.key) return error.DuplicateComponent;
        }
        if (try item_data.encodedSize(draft.components) > store.config.max_item_bytes) return error.ItemTooLarge;
    }

    pub const allocate = init;

    pub const CraftBatch = struct { epoch: u64, count: usize };
    pub const PreparedCraft = struct {
        result: inventories.Stack,
        consume: [9]u16,
        remainders: [9]?inventories.Stack,
        repeatable: bool,
        completion: ?crafting.Completion,
    };

    pub fn beginCraft(self: *PlayerInventory) void {
        std.debug.assert(!self.crafting_planning);
        self.crafting_planning = true;
        self.crafting_count = 0;
        self.crafting_epoch +%= 1;
        self.crafting_committed = false;
        self.crafting_validated = false;
        self.crafting_groups.clearRetainingCapacity();
    }

    pub fn endCraft(self: *PlayerInventory) void {
        std.debug.assert(self.crafting_planning);
        self.crafting_planning = false;
    }

    pub fn craftBatch(self: *PlayerInventory) CraftBatch {
        std.mem.sort(crafting.Completion, self.crafting_completions[0..self.crafting_count], {}, struct {
            fn less(_: void, a: crafting.Completion, b: crafting.Completion) bool {
                return a.group < b.group or (a.group == b.group and a.ordinal < b.ordinal);
            }
        }.less);
        return .{ .epoch = self.crafting_epoch, .count = self.crafting_count };
    }

    pub fn recordCraft(self: *PlayerInventory, completion: ?crafting.Completion) void {
        std.debug.assert(self.crafting_planning and !self.crafting_committed);
        if (completion) |value| {
            std.debug.assert(self.crafting_count < self.crafting_completions.len);
            self.crafting_completions[self.crafting_count] = value;
            const key: crafting.Group = .{ .owner = value.binding.owner, .vtable = value.binding.vtable };
            const group = self.crafting_groups.getOrPutAssumeCapacity(key);
            if (!group.found_existing) group.value_ptr.* = @intCast(self.crafting_groups.count() - 1);
            self.crafting_completions[self.crafting_count].group = group.value_ptr.*;
            self.crafting_completions[self.crafting_count].ordinal = @intCast(self.crafting_count);
            self.crafting_count += 1;
        }
    }

    pub fn validateCraft(self: *PlayerInventory, batch: CraftBatch) bool {
        std.debug.assert(!self.crafting_planning and batch.epoch == self.crafting_epoch and batch.count == self.crafting_count and !self.crafting_committed);
        self.crafting_validated = crafting.validate(self.crafting_completions[0..batch.count]);
        return self.crafting_validated;
    }

    pub fn completeCraft(self: *PlayerInventory, batch: CraftBatch) void {
        std.debug.assert(!self.crafting_planning and batch.epoch == self.crafting_epoch and batch.count == self.crafting_count and !self.crafting_committed);
        std.debug.assert(self.crafting_validated);
        self.crafting_committed = true;
        crafting.complete(self.crafting_completions[0..batch.count]);
    }

    pub fn prepareCraft(self: *PlayerInventory, player: u128, location: crafting.Location, grid: []const ?inventories.Stack, width: usize) !?PreparedCraft {
        std.debug.assert((width == 2 or width == 3) and grid.len == width * width);
        self.scratch.reset();
        var stacks: [9]inventories.Stack = undefined;
        var positions: [9]usize = undefined;
        var count: usize = 0;
        for (grid, 0..) |stack, index| if (stack) |value| {
            stacks[count] = value;
            positions[count] = index;
            count += 1;
        };
        const algorithmic = for (self.recipes.algorithms) |algorithm| {
            if (count >= algorithm.binding.minimum_inputs and count <= algorithm.binding.maximum_inputs) break true;
        } else false;
        var prepared: [9]Items.Prepared = undefined;
        if (algorithmic) try self.deps.items.acquireMany(stacks[0..count], prepared[0..count]);
        defer if (algorithmic) for (prepared[0..count]) |item| item.release();
        var kinds: [9]?u32 = @splat(null);
        var input: [9]?crafting.Input = @splat(null);
        for (stacks[0..count], positions[0..count], 0..) |stack, at, index| {
            kinds[at] = if (algorithmic) prepared[index].view.kind else try self.deps.items.kind(stack);
            if (algorithmic) input[at] = .{ .stack = stack, .view = prepared[index].view };
        }
        const ordinary = self.recipes.matches(kinds[0..grid.len], width);
        var plan: ?crafting.Plan = null;
        if (algorithmic) {
            var context: crafting.Context = .{ .player = player, .location = location, .input = input[0..grid.len], .width = width, .tags = &self.deps.items.deps.definitions.tags, .scratch = &self.scratch, .pending = if (self.crafting_planning) self.crafting_completions[0..self.crafting_count] else &.{} };
            for (self.recipes.algorithms) |algorithm| {
                if (ordinary) |recipe| if (std.mem.lessThan(u8, recipe.name, algorithm.name)) break;
                plan = try algorithm.binding.prepare(&context);
                if (plan != null) break;
            }
        }
        if (plan == null) {
            const recipe = ordinary orelse return null;
            var value: crafting.Plan = .{ .result = .{ .kind = recipe.output, .count = recipe.amount, .components = recipe.components }, .repeatable = true };
            for (kinds[0..grid.len], 0..) |kind, index| if (kind) |source| {
                value.consume[index] = 1;
                if (self.recipes.remainders[source]) |remainder| value.remainders[index] = .{ .kind = remainder, .count = 1 };
            };
            plan = value;
        }
        const value = plan.?;
        var output: PreparedCraft = .{ .result = try self.materialize(value.result), .consume = value.consume, .remainders = @splat(null), .repeatable = value.repeatable, .completion = value.completion };
        for (value.remainders, &output.remainders) |draft, *remainder| if (draft) |item| {
            remainder.* = try self.materialize(item);
        };
        return output;
    }

    fn materialize(self: *PlayerInventory, draft: crafting.Draft) !inventories.Stack {
        if (draft.kind >= game_data.registry.items.len or draft.count == 0 or draft.count > 99) return error.InvalidRecipeResult;
        const stack: inventories.Stack = .{ .item = try item_data.define(self.deps.inventories, draft.kind, draft.components), .count = draft.count };
        if (stack.count > try self.deps.items.stackLimit(stack)) return error.InvalidRecipeResult;
        return stack;
    }

    pub fn load(self: *PlayerInventory, index: usize, slots: *[47]inventories.Slot, contents: *[47]inventories.Contents) !void {
        const player = &self.deps.players.records[index];
        const handle = player.handle.?;
        const state = &self.states[index];
        if (state.generation != handle.generation or state.life != player.life or state.gamemode != player.gamemode) {
            state.* = .{ .generation = handle.generation, .life = player.life, .selected = player.selected_slot, .gamemode = player.gamemode };
        }
        for (slots, 0..) |*slot, at| slot.* = .{
            .owner = player.uuid,
            .index = if (at == cursor) std.math.maxInt(u16) else @intCast(at),
        };
        try self.deps.inventories.getMany(slots, contents);
        assert(contents[0].stack == null);
        if (!state.close) {
            try self.refreshOutput(player, contents);
            return;
        }
        var next: [47]?inventories.Stack = undefined;
        for (&next, contents) |*stack, entry| stack.* = entry.stack;
        var drops: [14]inventories.Stack = undefined;
        var count: usize = 0;
        for ([_]usize{ cursor, 1, 2, 3, 4 }) |source| {
            if (try self.returnStack(state.selected, source, &next)) |overflow| {
                drops[count] = overflow;
                count += 1;
            }
        }
        var table_slots: [table_grid_count]inventories.Slot = undefined;
        var table_contents: [table_grid_count]inventories.Contents = undefined;
        var table_edits: [table_grid_count]inventories.Edit = undefined;
        var edited: usize = 0;
        for (&table_slots, 0..) |*slot, at| slot.* = .{ .owner = player.uuid, .index = @intCast(table_grid_first + at) };
        try self.deps.inventories.getMany(&table_slots, &table_contents);
        for (table_slots, table_contents) |slot, value| if (value.stack) |stack| {
            std.debug.assert(next[cursor] == null);
            next[cursor] = stack;
            if (try self.returnStack(state.selected, cursor, &next)) |overflow| {
                drops[count] = overflow;
                count += 1;
            }
            table_edits[edited] = .{ .slot = slot, .revision = value.revision, .stack = null };
            edited += 1;
        };
        if (try self.applyWithExtras(index, slots, contents, &next, drops[0..count], table_edits[0..edited])) state.close = false;
        try self.refreshOutput(player, contents);
    }

    fn refreshOutput(self: *PlayerInventory, player: *const Players.Player, contents: *[47]inventories.Contents) !void {
        var grid: [4]?inventories.Stack = undefined;
        for (contents[1..5], &grid) |value, *stack| stack.* = value.stack;
        contents[0].stack = if (try self.prepareCraft(player.uuid, .{ .player = .{ .world = player.world, .position = player.position } }, &grid, 2)) |craft| craft.result else null;
    }

    pub fn closeMenu(self: *PlayerInventory, index: usize) !void {
        const state = &self.states[index];
        state.close = true;
        state.external = false;
        state.selected = self.deps.players.records[index].selected_slot;
        state.drag = .{};
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        try self.load(index, &slots, &contents);
    }

    pub fn synchronize(self: *PlayerInventory, index: usize, encoding: *packets.Packets, service: *sessions.Service) !void {
        const player = self.deps.players.records[index];
        const handle = player.handle.?;
        const state = &self.states[index];
        assert(player.stage == .ready and player.loaded);
        if (service.outputCredit(handle) == 0) return error.Backpressured;
        const full = if (player.gamemode == .creative) all_slots & ~(@as(u64, 1) << cursor) else all_slots;
        const initial = !state.synchronized or state.generation != handle.generation or state.life != player.life or state.gamemode != player.gamemode;
        if (initial or (player.gamemode != .creative and (state.dirty & full == full or state.dirty & 1 != 0))) {
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try self.load(index, &slots, &contents);
            try encoding.sendPacket(writeInventory, player.protocol, handle, .{
                self.deps.items, state.revision, &contents, player.uuid,
            }, service.config.page_bytes);
            state.dirty = 0;
            state.synchronized = true;
            return;
        }
        // A creative inventory refresh must not overwrite the client's unreported cursor.
        if (player.gamemode == .creative) state.dirty &= ~(@as(u64, 1) << cursor);
        assert(state.dirty & ~all_slots == 0);
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        var indices: [47]u6 = undefined;
        var count: usize = 0;
        var dirty = state.dirty;
        while (dirty != 0) {
            const slot = @ctz(dirty);
            indices[count] = @intCast(slot);
            slots[count] = .{ .owner = player.uuid, .index = if (slot == cursor) std.math.maxInt(u16) else @intCast(slot) };
            count += 1;
            dirty &= dirty - 1;
        }
        if (count == 0) return;
        try self.deps.inventories.getMany(slots[0..count], contents[0..count]);
        var base: usize = 0;
        while (base < count) {
            if (service.outputCredit(handle) == 0) return error.Backpressured;
            const length = @min(16, self.deps.items.views.len, count - base);
            assert(length > 0);
            var stacks: [16]inventories.Stack = undefined;
            var prepared: [16]Items.Prepared = undefined;
            var occupied: usize = 0;
            for (contents[base..][0..length]) |entry| if (entry.stack) |stack| {
                stacks[occupied] = stack;
                occupied += 1;
            };
            try self.deps.items.acquireMany(stacks[0..occupied], prepared[0..occupied]);
            defer for (prepared[0..occupied]) |held| held.release();
            var at: usize = 0;
            for (contents[base..][0..length], indices[base..][0..length]) |entry, slot| {
                const view = if (entry.stack != null) prepared[at].view else null;
                at += @intFromBool(entry.stack != null);
                if (slot == cursor) {
                    try encoding.sendPacketRetrying(writeCursor, player.protocol, handle, .{
                        self.deps.items, entry.stack, player.uuid, view,
                    }, service.config.page_bytes);
                } else {
                    try encoding.sendPacketRetrying(writeSlot, player.protocol, handle, .{
                        self.deps.items, state.revision, @as(i16, slot), entry.stack, player.uuid, view,
                    }, service.config.page_bytes);
                }
                state.dirty &= ~(@as(u64, 1) << slot);
            }
            base += length;
        }
        assert(state.dirty == 0);
    }

    pub fn writeSlot(packet: wire_1_21_5.play.toClient.packet_set_slot.Writer, registry: packets.Registry, store: *Items, revision: i32, slot: i16, stack: ?inventories.Stack, recipient: u128, view: ?Items.View) ![]u8 {
        assert(slot >= 0 and slot < 46);
        return writeWindowSlot(packet, registry, store, 0, revision, slot, stack, recipient, view);
    }

    pub fn writeWindowSlot(packet: wire_1_21_5.play.toClient.packet_set_slot.Writer, registry: packets.Registry, store: *Items, window_id: i32, revision: i32, slot: i16, stack: ?inventories.Stack, recipient: u128, view: ?Items.View) ![]u8 {
        assert(slot >= 0 and slot < 90);
        assert((stack == null) == (view == null));
        const window = try packet.windowId(window_id);
        const state = try window.stateId(revision);
        const position = try state.slot(slot);
        var item = try position.item();
        const done = try item_packets.writeSlot(try item.begin(), .{
            .registry = registry,
            .items = store,
            .stack = stack,
            .recipient = recipient,
            .view = view,
        });
        return (try item.advance(done)).finish();
    }

    pub fn writeCursor(packet: wire_1_21_5.play.toClient.packet_set_cursor_item.Writer, registry: packets.Registry, store: *Items, stack: ?inventories.Stack, recipient: u128, view: ?Items.View) ![]u8 {
        assert((stack == null) == (view == null));
        var item = try packet.contents();
        const done = try item_packets.writeSlot(try item.begin(), .{
            .registry = registry,
            .items = store,
            .stack = stack,
            .recipient = recipient,
            .view = view,
        });
        return (try item.advance(done)).finish();
    }

    pub fn apply(self: *PlayerInventory, index: usize, slots: *const [47]inventories.Slot, contents: *[47]inventories.Contents, next: *const [47]?inventories.Stack, drops: []const inventories.Stack) !bool {
        return self.applyWithExtras(index, slots, contents, next, drops, &.{});
    }

    fn applyWithExtras(self: *PlayerInventory, index: usize, slots: *const [47]inventories.Slot, contents: *[47]inventories.Contents, next: *const [47]?inventories.Stack, drops: []const inventories.Stack, extras: []const inventories.Edit) !bool {
        assert(extras.len <= table_grid_count);
        const state = &self.states[index];
        assert(state.generation == self.deps.players.records[index].handle.?.generation);
        assert(slots[cursor].index == std.math.maxInt(u16));
        if (self.deps.players.records[index].gamemode != .creative) {
            for (5..9) |at| {
                if (std.meta.eql(contents[at].stack, next[at])) continue;
                const stack = contents[at].stack orelse continue;
                if (!try self.deps.equipment.removable(stack, @intCast(at - 3))) return false;
            }
        }
        if (drops.len > maximum_drops) return false;
        if (drops.len != 0 and !self.deps.dropped.canCreate(drops.len)) return false;
        errdefer self.fail();
        if (!try self.dropMany(self.deps.players.records[index], drops)) return false;
        if (!std.meta.eql(contents[0].stack, next[0])) state.dirty |= 1;
        var edits: [56]inventories.Edit = undefined;
        @memcpy(edits[0..extras.len], extras);
        var count: usize = extras.len;
        for (next, contents, slots, 0..) |stack, old, slot, at| {
            // Result previews do not own persisted items.
            if (at == 0) continue;
            if (std.meta.eql(stack, old.stack)) continue;
            edits[count] = .{ .slot = slot, .revision = old.revision, .stack = stack };
            count += 1;
            state.dirty |= @as(u64, 1) << @intCast(at);
        }
        const committed = try self.deps.inventories.editMany(edits[0..count]);
        assert(committed);
        for (contents, next) |*old, stack| {
            old.revision += @intFromBool(!std.meta.eql(old.stack, stack));
            old.stack = stack;
        }
        state.revision = (state.revision + 1) & 32767;
        return true;
    }

    pub fn returnStack(self: *PlayerInventory, selected: u4, source: usize, next: *[47]?inventories.Stack) !?inventories.Stack {
        assert(selected <= 8);
        assert(source == cursor or (source >= 1 and source <= 4));
        const held = next[source] orelse return null;
        const maximum = try self.deps.items.stackLimit(held);
        var remaining = held.count;
        for (0..2) |pass| for (0..38) |offset| {
            const target: usize = if (offset == 0) 36 + @as(usize, selected) else if (offset == 1) 45 else if (offset < 11) offset + 34 else offset - 2;
            if (remaining == 0) break;
            const previous = if (next[target]) |stack| stack.count else 0;
            if (pass == 0) {
                if (next[target] == null or !inventories.Stack.sameItem(held, next[target].?)) continue;
            } else if (next[target] != null or offset < 2) continue;
            const amount = @min(remaining, maximum -| previous);
            if (amount == 0) continue;
            next[target] = .{ .item = held.item, .count = previous + amount };
            remaining -= amount;
        };
        next[source] = null;
        return if (remaining == 0) null else .{ .item = held.item, .count = remaining };
    }

    pub fn slotLimit(self: *PlayerInventory, slot: usize, stack: inventories.Stack) !u16 {
        return if (slot == 0) 0 else if (slot >= 5 and slot < 9) @intFromBool(try self.deps.equipment.slot(stack) == 10 - slot) else self.deps.items.stackLimit(stack);
    }

    /// All drops in an action are admitted together. No other producer interleaves on this owner.
    pub fn dropMany(self: *PlayerInventory, player: Players.Player, stacks: []const inventories.Stack) !bool {
        if (stacks.len == 0) return true;
        if (stacks.len > maximum_drops) return error.WorkingSetTooLarge;
        if (!self.deps.dropped.canCreate(stacks.len)) return false;
        const yaw = @as(f64, player.rotation.yaw) * std.math.pi / 180;
        const pitch = @as(f64, player.rotation.pitch) * std.math.pi / 180;
        const velocity: [3]f64 = .{ -@sin(yaw) * @cos(pitch) * 0.3, -@sin(pitch) * 0.3 + 0.1, @cos(yaw) * @cos(pitch) * 0.3 };
        var requests: [maximum_drops]item_entities.ItemEntities.Spawn = undefined;
        var ids: [maximum_drops]entities.Id = undefined;
        for (stacks, requests[0..stacks.len]) |stack, *request| request.* = .{ .world = player.world, .position = .{ player.position.x, player.position.y + 1.32, player.position.z }, .velocity = velocity, .stack = stack, .metadata = .{ .pickup_delay = 40 } };
        try self.deps.dropped.createMany(requests[0..stacks.len], ids[0..stacks.len]);
        return true;
    }

    pub fn give(self: *PlayerInventory, player: usize, name: []const u8, count: u16) !bool {
        return self.trade(player, name, count, true);
    }

    /// Plans the complete ownership change before mutating any slot.
    pub fn trade(self: *PlayerInventory, player: usize, name: []const u8, count: u16, buying: bool) !bool {
        const item = game_data.registry.itemId(name) orelse return error.UnknownItem;
        if (count == 0) return error.InvalidCount;

        const maximum = self.deps.items.deps.definitions.properties[@intCast(item)].stack_size;
        const owner = self.deps.players.records[player].uuid;
        const definition_id = try self.deps.items.define(name);
        var slots: [36]inventories.Slot = undefined;

        for (&slots, 0..) |*slot, index| slot.* = .{ .owner = owner, .index = @intCast(if (index < 9) index + 36 else index) };

        var contents: [36]inventories.Contents = undefined;
        try self.deps.inventories.getMany(&slots, &contents);
        var edits: [36]inventories.Edit = undefined;
        var edited: usize = 0;
        var remaining = count;

        for (0..if (buying) @as(usize, 2) else 1) |pass| for (slots, contents) |slot, value| {
            if (remaining == 0) break;

            const previous = if (value.stack) |stack| stack.count else 0;

            if (value.stack) |stack| {
                if (pass != 0 or !std.mem.eql(u8, &stack.item, &definition_id)) continue;
            } else if (!buying or pass == 0) continue;
            const amount = @min(remaining, if (buying) maximum -| previous else previous);
            if (amount == 0) continue;

            const after = if (buying) previous + amount else previous - amount;
            edits[edited] = .{
                .slot = slot,
                .revision = value.revision,
                .stack = if (after == 0) null else .{ .item = definition_id, .count = after },
            };
            edited += 1;
            remaining -= amount;
        };

        if (remaining != 0) return false;

        const committed = try self.deps.inventories.editMany(edits[0..edited]);
        assert(committed);
        self.changed(player);
        return true;
    }

    pub fn changed(self: *PlayerInventory, player: usize) void {
        self.changedSlots(player, all_slots);
    }

    pub fn changedSlots(self: *PlayerInventory, player: usize, mask: u64) void {
        assert(player < self.states.len);
        assert(mask & ~all_slots == 0);
        if (mask == 0) return;
        self.states[player].dirty |= mask;
        self.states[player].revision = (self.states[player].revision + 1) & 32767;
    }
};
