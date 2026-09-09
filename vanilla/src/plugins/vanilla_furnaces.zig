const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const world_random = lightning_rod.random;
const std = @import("std");
const registry = lightning_rod.registry_data;
const game_data = lightning_rod.game_data;
const block_writer = lightning_rod.block_writer;
const packet_args = lightning_rod.packet_args;
const container_menu = lightning_rod.container_menu;
const container_clicks = lightning_rod.container_clicks;
const recipes_plugin = @import("vanilla_recipes.zig");
const active_chunks = @import("../vanilla/active_chunks.zig");
const Packets = lightning_rod.Packets;
const world_identity = lightning_rod.world_identity;
const world_store = lightning_rod.worlds;

const persistence_id = "minecraft:furnaces";
const persistence_magic = "LRFURN02";
const persistence_key = "state";
const test_world = world_identity.Handle{ .index = 0, .generation = 1 };
const menu_type = 14;
const stack_encoded_bytes = @sizeOf(i32) + @sizeOf(i32) + @sizeOf(u16) + @sizeOf(u8);
const entry_encoded_bytes = @sizeOf(u128) + @sizeOf(i32) + @sizeOf(i16) + @sizeOf(i32) + 3 * stack_encoded_bytes + 4 * @sizeOf(u16);

fn encodedCapacity(maximum_entries: usize) !usize {
    return std.math.add(usize, persistence_magic.len + @sizeOf(u16), try std.math.mul(usize, maximum_entries, entry_encoded_bytes));
}

pub const Entry = struct {
    occupied: bool = false,
    world: world_identity.Handle = world_identity.invalid,
    position: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    items: [3]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** 3,
    burn_time: u16 = 0,
    fuel_time: u16 = 0,
    cook_time: u16 = 0,
    cook_total: u16 = 200,
};

pub const Furnaces = struct {
    pub const id = persistence_id;
    pub const Configuration = struct {
        maximum_entries: usize = 256,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_entries == 0 or self.maximum_entries > std.math.maxInt(u16))
                return error.InvalidFurnaceCapacity;
        }
    };
    pub const Dependencies = struct {
        persistence: lightning_rod.persistence.PluginAccess,
        worlds: *world_store.Worlds,
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        active: *active_chunks.ActiveChunks,
        items: *entity_store.ItemEntities,
        inputs: *input_store.Inputs,
        containers: *player_store.Containers,
        recipes: *recipes_plugin.Recipes,
        outputs: *Packets,
    };

    entries: []Entry = &.{},
    deps: Dependencies,
    dirty: bool = false,
    observed_mutation_sequence: u64 = 0,
    drags: []container_clicks.Drag = &.{},
    persistence_buffer: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Furnaces {
        try configuration.validate();
        const self = try allocator.create(Furnaces);
        self.* = .{ .deps = deps };
        self.entries = try allocator.alloc(Entry, configuration.maximum_entries);
        self.drags = try allocator.alloc(container_clicks.Drag, deps.players.records.len);
        self.persistence_buffer = try allocator.alloc(u8, try encodedCapacity(configuration.maximum_entries));
        @memset(self.entries, .{});
        @memset(self.drags, .{});
        try self.restore();
        self.observed_mutation_sequence = self.deps.blocks.block_mutation_sequence;
        return self;
    }

    pub fn tick(self: *Furnaces, _: std.mem.Allocator) void {
        const random = self.deps.random;
        const blocks = self.deps.blocks;
        const players = self.deps.players;
        const items = self.deps.items;
        const inputs = self.deps.inputs;
        const containers = self.deps.containers;
        const recipes = self.deps.recipes;
        const outputs = self.deps.outputs;
        var work = self.runtime(random, blocks, players, items, inputs, containers, recipes, outputs);
        handleBlockInteractions(&work);
        applyClicks(&work);
        reconcileMutations(&work);
        tickFurnaces(&work);
    }

    pub fn checkpoint(self: *Furnaces, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        if (!self.dirty) return;
        const bytes = try encodeState(self, self.persistence_buffer);
        try writer.put(persistence_key, bytes);
        self.dirty = false;
    }

    fn runtime(self: *Furnaces, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, items: *entity_store.ItemEntities, inputs: *input_store.Inputs, containers: *player_store.Containers, recipes: *recipes_plugin.Recipes, outputs: *Packets) FurnaceRuntime {
        return .{
            .deps = .{ .random = random, .world = blocks, .players = players, .active = self.deps.active, .items = items, .inputs = inputs, .containers = containers, .recipes = recipes },
            .outputs = outputs,
            .state = self,
            .blocks = block_writer.Writer.init(blocks, outputs),
        };
    }

    fn markDirty(self: *Furnaces, _: bool) void {
        self.dirty = true;
    }

    fn restore(self: *Furnaces) !void {
        const loaded = self.deps.persistence.load(persistence_key, self.persistence_buffer) catch |err| switch (err) {
            error.ReadFailed => return,
            else => return err,
        };
        switch (loaded) {
            .missing => {},
            .value => |length| try decodeState(self, self.persistence_buffer[0..length]),
        }
    }
};

const FurnaceWork = struct {
    random: *world_random.Random,
    world: *block_store.Blocks,
    players: *player_store.Players,
    active: *active_chunks.ActiveChunks,
    items: *entity_store.ItemEntities,
    inputs: *input_store.Inputs,
    containers: *player_store.Containers,
    recipes: *recipes_plugin.Recipes,

    inline fn activePlayerSlots(self: *const FurnaceWork) []const u16 {
        return self.players.active_slots[0..self.players.active_count];
    }

    fn spawnItem(self: *FurnaceWork, world: world_identity.Handle, position: geometry.Vec3, velocity: geometry.Vec3, stack: player_store.HotbarStack) !usize {
        return self.items.spawn(self.random, self.world, world, position, velocity, stack, entity_store.block_drop_pickup_delay_ticks);
    }

    fn spawnPlayerDrop(self: *FurnaceWork, player: *const player_store.CorePlayer, stack: player_store.HotbarStack) !usize {
        const yaw = std.math.degreesToRadians(@as(f64, player.rotation.yaw));
        const pitch = std.math.degreesToRadians(@as(f64, player.rotation.pitch));
        const horizontal = std.math.cos(pitch) * 0.3;
        return self.items.spawn(self.random, self.world, player.world, .{
            .x = player.position.x,
            .y = player.position.y + 1.3,
            .z = player.position.z,
        }, .{
            .x = -std.math.sin(yaw) * horizontal,
            .y = -std.math.sin(pitch) * 0.3 + 0.1,
            .z = std.math.cos(yaw) * horizontal,
        }, stack, entity_store.player_drop_pickup_delay_ticks);
    }
};

const FurnaceRuntime = struct {
    deps: FurnaceWork,
    outputs: *Packets,
    state: *Furnaces,
    blocks: block_writer.Writer,
};

fn handleBlockInteractions(context: *FurnaceRuntime) void {
    const simulation = &context.deps;
    for (0..simulation.inputs.block_request_count) |offset_index| {
        const request = &simulation.inputs.block_requests[offset_index];
        if (request.handled or request.kind != .use_item_on) continue;
        const against_state = simulation.world.blockAt(request.world, request.against_pos);
        if (isFurnace(against_state) and !simulation.players.records[request.slot].sneaking) {
            request.handled = true;
            openFurnace(context, request.world, request.slot, request.against_pos);
            continue;
        }
        if (isFurnace(request.block_state))
            request.block_state = furnaceState(facingForYaw(simulation.players.records[request.slot].rotation.yaw), false);
    }
}

fn openFurnace(context: *FurnaceRuntime, world: world_identity.Handle, slot: u16, position: geometry.BlockPos) void {
    if (!player_store.playerCanReachBlock(&context.deps.players.records[slot], position)) return;
    const entry = getOrCreateEntry(context.state, world, position) catch return;
    container_menu.open(
        context.deps.players,
        context.deps.containers,
        slot,
        .furnace,
        position,
        null,
        menu_type,
        &entry.items,
    );
    const properties = furnaceProperties(entry);
    context.outputs.menu_opened(.{ .slot = slot, .title = "Furnace", .properties = &properties });
}

const FurnaceRules = struct {
    recipes: *recipes_plugin.Recipes,

    pub fn canPlace(self: *const FurnaceRules, index: usize, stack: player_store.HotbarStack) bool {
        if (stack.isEmpty()) return true;
        return switch (index) {
            0 => self.recipes.smelt(stack.item_id) != null,
            1 => self.recipes.fuelTicks(stack.item_id) != 0,
            2 => false,
            else => false,
        };
    }

    pub fn moveFromPlayer(self: *const FurnaceRules, top: []player_store.HotbarStack, stack: *player_store.HotbarStack) void {
        if (self.recipes.smelt(stack.item_id) != null) {
            player_store.moveStackInto(top[0..1], stack);
        } else if (self.recipes.fuelTicks(stack.item_id) != 0) {
            player_store.moveStackInto(top[1..2], stack);
        }
    }
};

fn applyClicks(context: *FurnaceRuntime) void {
    const simulation = &context.deps;
    for (0..simulation.inputs.inventory_click_count) |offset_index| {
        const click = &simulation.inputs.inventory_clicks[offset_index];
        if (click.handled) continue;
        const container = &simulation.containers.open[click.slot];
        if (container.kind != .furnace or container.id != click.window_id) continue;
        click.handled = true;
        const entry = findEntry(context.state, container.world, container.position) orelse continue;
        const rules: FurnaceRules = .{ .recipes = simulation.recipes };
        const result = container_clicks.applyWithDrag(
            FurnaceRules,
            &rules,
            &simulation.players.records[click.slot],
            &entry.items,
            click.*,
            &context.state.drags[click.slot],
        );
        if (result.changed) {
            context.state.markDirty(true);
            if (result.dropped) |stack| spawnPlayerDrop(context, click.slot, stack);
        }
        synchronizeViewer(context, click.slot, entry, true, result.changed);
    }
}

fn tickFurnaces(context: *FurnaceRuntime) void {
    for (context.state.entries) |*entry| {
        if (!entry.occupied) continue;
        const chunk = geometry.chunkForBlock(entry.position);
        if (!context.deps.active.blockTicking(entry.world, chunk)) continue;
        const resident = context.deps.world.residentChunk(entry.world, chunk) orelse continue;
        const current_state = context.deps.world.blockAtResident(resident, entry.position);
        if (!isFurnace(current_state)) continue;
        const was_lit = entry.burn_time != 0;
        const before_items = entry.items;
        const before_burn = entry.burn_time;
        const before_fuel = entry.fuel_time;
        const before_cook = entry.cook_time;
        const before_cook_total = entry.cook_total;
        if (entry.burn_time != 0) entry.burn_time -= 1;
        const recipe = smeltableResult(context.deps.recipes, entry);
        if (entry.burn_time == 0 and recipe != null) ignite(context.deps.recipes, entry);
        if (entry.burn_time != 0 and recipe != null) {
            entry.cook_total = recipe.?.cooking_ticks;
            entry.cook_time += 1;
            if (entry.cook_time >= entry.cook_total) {
                completeSmelt(entry, recipe.?);
                entry.cook_time = 0;
            }
        } else if (entry.cook_time != 0) {
            entry.cook_time -|= @min(entry.cook_time, 2);
        }
        const is_lit = entry.burn_time != 0;
        if (was_lit != is_lit or furnaceLit(current_state) != is_lit)
            _ = context.blocks.set(entry.world, entry.position, furnaceState(furnaceFacing(current_state), is_lit)) catch {};
        const items_changed = !std.meta.eql(before_items, entry.items);
        const progress_changed = before_burn != entry.burn_time or before_cook != entry.cook_time;
        if (!items_changed and !progress_changed) continue;
        context.state.markDirty(items_changed);
        var properties: [4]packet_args.ContainerProperty = undefined;
        var property_count: usize = 0;
        appendChangedProperty(&properties, &property_count, 0, before_burn, entry.burn_time);
        appendChangedProperty(&properties, &property_count, 1, before_fuel, entry.fuel_time);
        appendChangedProperty(&properties, &property_count, 2, before_cook, entry.cook_time);
        appendChangedProperty(&properties, &property_count, 3, before_cook_total, entry.cook_total);
        synchronizeFurnaceViewers(context, entry, items_changed, properties[0..property_count]);
    }
}

fn appendChangedProperty(
    properties: *[4]packet_args.ContainerProperty,
    count: *usize,
    id: i16,
    before: u16,
    after: u16,
) void {
    if (before == after) return;
    properties[count.*] = .{
        .id = id,
        .value = @intCast(@min(after, std.math.maxInt(i16))),
    };
    count.* += 1;
}

fn ignite(recipes: *recipes_plugin.Recipes, entry: *Entry) void {
    if (entry.items[1].isEmpty()) return;
    const ticks = recipes.fuelTicks(entry.items[1].item_id);
    if (ticks == 0) return;
    const fuel_item = entry.items[1].item_id;
    entry.burn_time = ticks;
    entry.fuel_time = ticks;
    entry.items[1].count -= 1;
    if (entry.items[1].count == 0)
        entry.items[1] = if (fuel_item == registry.item_lava_bucket_id)
            player_store.stackForItem(registry.item_bucket_id, 1)
        else
            .{};
}

fn smeltableResult(recipes: *recipes_plugin.Recipes, entry: *const Entry) ?game_data.SmeltResult {
    if (entry.items[0].isEmpty()) return null;
    const recipe = recipes.smelt(entry.items[0].item_id) orelse return null;
    const output = entry.items[2];
    if (output.isEmpty()) return recipe;
    if (output.item_id != recipe.item_id or output.count > player_store.maxStackSize(output.item_id) - recipe.count) return null;
    return recipe;
}

fn completeSmelt(entry: *Entry, recipe: game_data.SmeltResult) void {
    entry.items[0].count -= 1;
    if (entry.items[0].count == 0) entry.items[0] = .{};
    if (entry.items[2].isEmpty())
        entry.items[2] = player_store.stackForItem(recipe.item_id, recipe.count)
    else
        entry.items[2].count += recipe.count;
}

fn synchronizeFurnaceViewers(
    context: *FurnaceRuntime,
    entry: *Entry,
    items_changed: bool,
    properties: []const packet_args.ContainerProperty,
) void {
    for (context.deps.activePlayerSlots()) |slot| {
        const container = &context.deps.containers.open[slot];
        if (container.kind != .furnace or !geometry.sameBlock(container.position, entry.position)) continue;
        synchronizeViewerWithProperties(context, slot, entry, items_changed, false, properties);
    }
}

fn synchronizeViewer(
    context: *FurnaceRuntime,
    slot: u16,
    entry: *Entry,
    items_changed: bool,
    player_inventory_changed: bool,
) void {
    const properties = furnaceProperties(entry);
    synchronizeViewerWithProperties(context, slot, entry, items_changed, player_inventory_changed, &properties);
}

fn synchronizeViewerWithProperties(
    context: *FurnaceRuntime,
    slot: u16,
    entry: *Entry,
    items_changed: bool,
    player_inventory_changed: bool,
    properties: []const packet_args.ContainerProperty,
) void {
    container_menu.project(context.deps.containers, slot, &entry.items);
    if (player_inventory_changed)
        context.outputs.menu_player_inventory_changed(slot, properties)
    else if (items_changed)
        context.outputs.menu_changed(slot, properties)
    else
        context.outputs.menu_properties_changed(slot, properties);
}

fn furnaceProperties(entry: *const Entry) [4]packet_args.ContainerProperty {
    return .{
        .{ .id = 0, .value = @intCast(@min(entry.burn_time, std.math.maxInt(i16))) },
        .{ .id = 1, .value = @intCast(@min(entry.fuel_time, std.math.maxInt(i16))) },
        .{ .id = 2, .value = @intCast(@min(entry.cook_time, std.math.maxInt(i16))) },
        .{ .id = 3, .value = @intCast(@min(entry.cook_total, std.math.maxInt(i16))) },
    };
}

fn reconcileMutations(context: *FurnaceRuntime) void {
    const latest = context.deps.world.block_mutation_sequence;
    const pending = latest -% context.state.observed_mutation_sequence;
    if (pending > context.deps.world.block_mutations.len) {
        context.state.observed_mutation_sequence = latest;
        return;
    }
    var sequence = context.state.observed_mutation_sequence;
    for (0..@as(usize, @intCast(pending))) |_| {
        sequence +%= 1;
        if (sequence == 0) sequence = 1;
        const mutation = context.deps.world.blockMutation(sequence);
        if (isFurnace(mutation.previous_state) and !isFurnace(mutation.block_state))
            removeFurnace(context, mutation.world, mutation.pos);
        if (!isFurnace(mutation.previous_state) and isFurnace(mutation.block_state)) {
            _ = getOrCreateEntry(context.state, mutation.world, mutation.pos) catch {};
        }
    }
    context.state.observed_mutation_sequence = context.deps.world.block_mutation_sequence;
}

fn removeFurnace(context: *FurnaceRuntime, world: world_identity.Handle, position: geometry.BlockPos) void {
    if (findEntry(context.state, world, position)) |entry| {
        for (&entry.items) |*stack| {
            if (stack.isEmpty()) continue;
            const item_index = context.deps.spawnItem(
                world,
                entity_store.blockDropPosition(position),
                .{ .x = 0, .y = 0.1, .z = 0 },
                stack.*,
            ) catch break;
            stack.* = .{};
            context.outputs.item_spawned(@intCast(item_index));
        }
        entry.* = .{};
        context.state.markDirty(true);
    }
    for (context.deps.activePlayerSlots()) |slot| {
        const container = &context.deps.containers.open[slot];
        if (container.kind != .furnace or !geometry.sameBlock(container.position, position)) continue;
        const window_id = container.id;
        container_menu.close(context.deps.players, context.deps.containers, slot);
        context.outputs.container_closed(.{ .slot = slot, .window_id = window_id });
    }
}

fn spawnPlayerDrop(context: *FurnaceRuntime, slot: u16, stack: player_store.HotbarStack) void {
    const item_index = context.deps.spawnPlayerDrop(&context.deps.players.records[slot], stack) catch return;
    context.outputs.item_spawned(@intCast(item_index));
}

fn findEntry(state: *Furnaces, world: world_identity.Handle, position: geometry.BlockPos) ?*Entry {
    for (state.entries) |*entry|
        if (entry.occupied and entry.world.eql(world) and geometry.sameBlock(entry.position, position)) return entry;
    return null;
}

fn getOrCreateEntry(state: *Furnaces, world: world_identity.Handle, position: geometry.BlockPos) !*Entry {
    if (findEntry(state, world, position)) |entry| return entry;
    for (state.entries) |*entry| {
        if (entry.occupied) continue;
        entry.* = .{ .occupied = true, .world = world, .position = position };
        state.markDirty(true);
        return entry;
    }
    return error.FurnaceCapacity;
}

const Facing = enum(u2) { north, south, west, east };

fn isFurnace(block_state: i32) bool {
    return block_state >= 0 and block_state < registry.block_state_to_block.len and
        registry.block_state_to_block[@intCast(block_state)] == registry.block_furnace_id;
}

fn furnaceFacing(block_state: i32) Facing {
    const info = registry.blocks[@intCast(registry.block_furnace_id)];
    return @enumFromInt(@as(u2, @intCast(@divTrunc(block_state - info.min_state, 2))));
}

fn furnaceState(facing: Facing, lit: bool) i32 {
    const info = registry.blocks[@intCast(registry.block_furnace_id)];
    return info.min_state + @as(i32, @intFromEnum(facing)) * 2 + @intFromBool(!lit);
}

fn furnaceLit(block_state: i32) bool {
    const info = registry.blocks[@intCast(registry.block_furnace_id)];
    return @mod(block_state - info.min_state, 2) == 0;
}

fn facingForYaw(yaw: f32) Facing {
    const quadrant: i32 = @mod(@as(i32, @intFromFloat(@floor(yaw / 90.0 + 0.5))), 4);
    return switch (quadrant) {
        0 => .north,
        1 => .east,
        2 => .south,
        3 => .west,
        else => unreachable,
    };
}

fn encodeState(state: *const Furnaces, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll(persistence_magic);
    var count: u16 = 0;
    for (state.entries) |entry| count += @intFromBool(entry.occupied);
    try writer.writeInt(u16, count, .little);
    for (state.entries) |entry| {
        if (!entry.occupied) continue;
        const world = state.deps.worlds.getConst(entry.world) orelse return error.StaleWorldHandle;
        try writer.writeInt(u128, world.key.value, .little);
        try writer.writeInt(i32, entry.position.x, .little);
        try writer.writeInt(i16, entry.position.y, .little);
        try writer.writeInt(i32, entry.position.z, .little);
        for (entry.items) |stack| try writeStack(&writer, stack);
        try writer.writeInt(u16, entry.burn_time, .little);
        try writer.writeInt(u16, entry.fuel_time, .little);
        try writer.writeInt(u16, entry.cook_time, .little);
        try writer.writeInt(u16, entry.cook_total, .little);
    }
    return writer.buffered();
}

fn decodeState(state: *Furnaces, bytes: []const u8) !void {
    var reader = std.Io.Reader.fixed(bytes);
    var magic: [persistence_magic.len]u8 = undefined;
    try reader.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, persistence_magic)) return error.InvalidFurnaceData;
    const count = try reader.takeInt(u16, .little);
    if (count > state.entries.len) return error.InvalidFurnaceData;
    for (state.entries[0..count]) |*entry| {
        entry.* = .{ .occupied = true };
        entry.world = state.deps.worlds.find(.{ .value = try reader.takeInt(u128, .little) }) orelse return error.UnknownWorldKey;
        entry.position.x = try reader.takeInt(i32, .little);
        entry.position.y = try reader.takeInt(i16, .little);
        entry.position.z = try reader.takeInt(i32, .little);
        for (&entry.items) |*stack| stack.* = try readStack(&reader);
        entry.burn_time = try reader.takeInt(u16, .little);
        entry.fuel_time = try reader.takeInt(u16, .little);
        entry.cook_time = try reader.takeInt(u16, .little);
        entry.cook_total = try reader.takeInt(u16, .little);
    }
    if (reader.seek != bytes.len) return error.InvalidFurnaceData;
}

fn writeStack(writer: *std.Io.Writer, stack: player_store.HotbarStack) !void {
    try writer.writeInt(i32, stack.block_state, .little);
    try writer.writeInt(i32, stack.item_id, .little);
    try writer.writeInt(u16, stack.damage, .little);
    try writer.writeByte(stack.count);
}

fn readStack(reader: *std.Io.Reader) !player_store.HotbarStack {
    return .{
        .block_state = try reader.takeInt(i32, .little),
        .item_id = try reader.takeInt(i32, .little),
        .damage = try reader.takeInt(u16, .little),
        .count = try reader.takeByte(),
    };
}

test "furnace consumes fuel and completes a Vanilla 200 tick smelt" {
    var recipes: recipes_plugin.Recipes = .{};
    var entry: Entry = .{ .occupied = true };
    entry.items[0] = player_store.stackForItem(registry.item_raw_iron_id, 1);
    entry.items[1] = player_store.stackForItem(registry.item_coal_id, 1);
    ignite(&recipes, &entry);
    try std.testing.expectEqual(@as(u16, 1600), entry.burn_time);
    const recipe = smeltableResult(&recipes, &entry).?;
    for (0..200) |_| {
        entry.cook_time += 1;
        if (entry.cook_time == recipe.cooking_ticks) completeSmelt(&entry, recipe);
    }
    try std.testing.expectEqual(registry.item_iron_ingot_id, entry.items[2].item_id);
    try std.testing.expectEqual(@as(u8, 1), entry.items[2].count);
}

test "furnace block states preserve facing and lit state" {
    for (std.enums.values(Facing)) |facing| {
        try std.testing.expectEqual(facing, furnaceFacing(furnaceState(facing, false)));
        try std.testing.expectEqual(facing, furnaceFacing(furnaceState(facing, true)));
    }
}

test "furnace persistence retains inventory and progress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const descriptions = [_]world_store.Description{.{
        .key = .{ .value = 1 },
        .name = "test:furnace",
        .dimension = .{ .index = 0 },
        .generator = @enumFromInt(0),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }};
    const worlds = try world_store.Worlds.init(arena.allocator(), .{ .initial = &descriptions });
    const world = worlds.find(.{ .value = 1 }).?;
    var furnaces: Furnaces = .{ .deps = undefined };
    furnaces.deps.worlds = worlds;
    furnaces.entries = try arena.allocator().alloc(Entry, 8);
    @memset(furnaces.entries, .{});
    const entry = try getOrCreateEntry(&furnaces, world, .{ .x = -4, .y = 70, .z = 9 });
    entry.items[0] = player_store.stackForItem(registry.item_raw_gold_id, 3);
    entry.burn_time = 1200;
    entry.fuel_time = 1600;
    entry.cook_time = 41;
    var buffer: [encodedCapacity(8) catch unreachable]u8 = undefined;
    const bytes = try encodeState(&furnaces, &buffer);
    var restored: Furnaces = .{ .deps = undefined };
    restored.deps.worlds = worlds;
    restored.entries = try arena.allocator().alloc(Entry, 8);
    @memset(restored.entries, .{});
    try decodeState(&restored, bytes);
    const actual = findEntry(&restored, world, entry.position).?;
    try std.testing.expectEqual(registry.item_raw_gold_id, actual.items[0].item_id);
    try std.testing.expectEqual(@as(u8, 3), actual.items[0].count);
    try std.testing.expectEqual(@as(u16, 1200), actual.burn_time);
    try std.testing.expectEqual(@as(u16, 41), actual.cook_time);
}
