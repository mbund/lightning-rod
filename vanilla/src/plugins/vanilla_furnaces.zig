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
const simulation_admission = @import("../vanilla/simulation_admission.zig");
const persistence_plugin = @import("vanilla_persistence.zig");
const Packets = lightning_rod.Packets;
const world_identity = lightning_rod.world_identity;
const world_store = lightning_rod.worlds;

const persistence_id = "minecraft:furnaces";
const persistence_key = "state";
const persistence_root_key = "\x00";
const persistence_record_tag: u8 = 1;
const root_magic = "LRFURN04";
const test_world = world_identity.Handle{ .index = 0, .generation = 1 };
const menu_type = 14;
const stack_encoded_bytes = @sizeOf(i32) + @sizeOf(i32) + @sizeOf(u16) + @sizeOf(u8);
const entry_encoded_bytes = @sizeOf(u128) + 2 * @sizeOf(i32) + @sizeOf(i16) + @sizeOf(i32) + 3 * stack_encoded_bytes + 4 * @sizeOf(u16);
const root_bytes = root_magic.len + @sizeOf(u16) + @sizeOf(u32);
const record_bytes = entry_encoded_bytes + @sizeOf(u32);

pub const Entry = struct {
    occupied: bool = false,
    world: world_identity.Handle = world_identity.invalid,
    position: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    block_state: i32 = registry.block_furnace_default_state,
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
        active: *simulation_admission.SimulationAdmission,
        items: *entity_store.ItemEntities,
        inputs: *input_store.Inputs,
        containers: *player_store.Containers,
        recipes: *recipes_plugin.Recipes,
        outputs: *Packets,
        chunk_io: *persistence_plugin.Materializer,
    };

    entries: []Entry = &.{},
    deps: Dependencies,
    dirty: bool = false,
    drags: []container_clicks.Drag = &.{},
    persistence_root: [root_bytes]u8 = undefined,
    persistence_record: [record_bytes]u8 = undefined,

    pub const Removal = struct {
        world: world_identity.Handle,
        position: geometry.BlockPos,
        entry: ?u16 = null,
        items: [3]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** 3,
    };

    pub const Placement = struct {
        entry: u16,
        world: world_identity.Handle,
        position: geometry.BlockPos,
        block_state: i32,
    };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Furnaces {
        try configuration.validate();
        const self = try allocator.create(Furnaces);
        self.* = .{ .deps = deps };
        self.entries = try allocator.alloc(Entry, configuration.maximum_entries);
        self.drags = try allocator.alloc(container_clicks.Drag, deps.players.records.len);
        @memset(self.entries, .{});
        @memset(self.drags, .{});
        try self.restore();
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
        tickFurnaces(&work);
    }

    pub fn checkpoint(self: *Furnaces, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        if (!self.dirty) return;
        var count: u16 = 0;
        for (self.entries) |entry| {
            if (!entry.occupied) continue;
            const key = recordKey(count) orelse return error.FurnaceCapacity;
            try writer.put(&key, try encodeEntry(self, &self.persistence_record, entry));
            count += 1;
        }
        try writer.put(persistence_root_key, try encodeRoot(&self.persistence_root, count));
        self.dirty = false;
    }

    pub fn prepareRemoval(self: *const Furnaces, world: world_identity.Handle, position: geometry.BlockPos) Removal {
        var removal = Removal{ .world = world, .position = position };
        for (self.entries, 0..) |entry, index| {
            if (!entry.occupied or !entry.world.eql(world) or !geometry.sameBlock(entry.position, position)) continue;
            removal.entry = @intCast(index);
            removal.items = entry.items;
            break;
        }
        return removal;
    }

    pub fn commitRemoval(self: *Furnaces, removal: Removal) void {
        if (removal.entry) |raw_index| {
            const index: usize = raw_index;
            const entry = &self.entries[index];
            std.debug.assert(entry.occupied);
            std.debug.assert(entry.world.eql(removal.world));
            std.debug.assert(geometry.sameBlock(entry.position, removal.position));
            entry.* = .{};
            self.markDirty(true);
        }
        for (self.deps.players.activeSlots()) |slot| {
            const container = &self.deps.containers.open[slot];
            if (container.kind != .furnace or !geometry.sameBlock(container.position, removal.position)) continue;
            const window_id = container.id;
            container_menu.close(self.deps.players, self.deps.containers, slot);
            self.deps.outputs.container_closed(.{ .slot = slot, .window_id = window_id });
        }
    }

    pub fn reservePlacement(self: *const Furnaces, world: world_identity.Handle, position: geometry.BlockPos, block_state: i32) !Placement {
        if (!isFurnace(block_state)) return error.InvalidFurnaceState;
        if (entryIndex(self, world, position) != null) return error.FurnaceAlreadyExists;
        for (self.entries, 0..) |entry, index| {
            if (entry.occupied) continue;
            return .{ .entry = @intCast(index), .world = world, .position = position, .block_state = block_state };
        }
        return error.FurnaceCapacity;
    }

    pub fn commitPlacement(self: *Furnaces, placement: Placement) void {
        const entry = &self.entries[placement.entry];
        std.debug.assert(!entry.occupied);
        entry.* = .{ .occupied = true, .world = placement.world, .position = placement.position, .block_state = placement.block_state };
        self.markDirty(true);
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
        self.rejectLegacy() catch |err| switch (err) {
            error.DestinationTooSmall => return error.StorageSchemaUnsupported,
            else => return err,
        };
        const loaded = try self.deps.persistence.load(persistence_root_key, &self.persistence_root);
        switch (loaded) {
            .missing => {},
            .value => |length| {
                const count = try decodeRoot(self.persistence_root[0..length]);
                if (count > self.entries.len) return error.InvalidFurnaceData;
                for (0..count) |index| {
                    const key = recordKey(index) orelse return error.InvalidFurnaceData;
                    const record = try self.deps.persistence.load(&key, &self.persistence_record);
                    const bytes = switch (record) {
                        .missing => return error.InvalidFurnaceData,
                        .value => |value_length| self.persistence_record[0..value_length],
                    };
                    try decodeEntry(self, &self.entries[index], bytes);
                }
            },
        }
    }

    fn rejectLegacy(self: *Furnaces) !void {
        const loaded = try self.deps.persistence.load(persistence_key, &.{});
        if (loaded != .missing) return error.StorageSchemaUnsupported;
    }
};

const FurnaceWork = struct {
    random: *world_random.Random,
    world: *block_store.Blocks,
    players: *player_store.Players,
    active: *simulation_admission.SimulationAdmission,
    items: *entity_store.ItemEntities,
    inputs: *input_store.Inputs,
    containers: *player_store.Containers,
    recipes: *recipes_plugin.Recipes,

    inline fn activePlayerSlots(self: *const FurnaceWork) []const u16 {
        return self.players.active_slots[0..self.players.active_count];
    }

    const PreparedDrop = struct {
        reservation: entity_store.ItemEntities.Reservation,
        specification: entity_store.ItemEntities.Spawn,
    };

    fn preparePlayerDrop(self: *FurnaceWork, player: *const player_store.CorePlayer, stack: player_store.HotbarStack) !PreparedDrop {
        const yaw = std.math.degreesToRadians(@as(f64, player.rotation.yaw));
        const pitch = std.math.degreesToRadians(@as(f64, player.rotation.pitch));
        const horizontal = std.math.cos(pitch) * 0.3;
        const specification = entity_store.ItemEntities.Spawn{
            .world = player.world,
            .position = .{ .x = player.position.x, .y = player.position.y + 1.3, .z = player.position.z },
            .velocity = .{
                .x = -std.math.sin(yaw) * horizontal,
                .y = -std.math.sin(pitch) * 0.3 + 0.1,
                .z = std.math.cos(yaw) * horizontal,
            },
            .stack = stack,
            .pickup_delay_ticks = entity_store.player_drop_pickup_delay_ticks,
        };
        try self.items.validateSpawn(self.world, specification);
        return .{ .reservation = try self.items.reserve(1), .specification = specification };
    }

    fn commitPlayerDrop(self: *FurnaceWork, prepared: *PreparedDrop) usize {
        var output: [1]usize = undefined;
        self.items.commitReserved(&prepared.reservation, self.random, &.{prepared.specification}, &output);
        return output[0];
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
    const entry = findEntry(context.state, world, position) orelse return;
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
        var staged_player = simulation.players.records[click.slot];
        var staged_entry = entry.*;
        var staged_drag = context.state.drags[click.slot];
        const result = container_clicks.applyWithDrag(
            FurnaceRules,
            &rules,
            &staged_player,
            &staged_entry.items,
            click.*,
            &staged_drag,
        );
        context.state.drags[click.slot] = staged_drag;
        if (result.changed) {
            var prepared_drop: ?FurnaceWork.PreparedDrop = null;
            if (result.dropped) |stack|
                prepared_drop = simulation.preparePlayerDrop(&staged_player, stack) catch {
                    synchronizeViewer(context, click.slot, entry, true, false);
                    continue;
                };
            simulation.players.records[click.slot] = staged_player;
            entry.* = staged_entry;
            context.state.markDirty(true);
            if (prepared_drop) |*prepared| {
                const index = simulation.commitPlayerDrop(prepared);
                context.outputs.item_spawned(@intCast(index));
            }
        }
        synchronizeViewer(context, click.slot, entry, true, result.changed);
    }
}

fn tickFurnaces(context: *FurnaceRuntime) void {
    for (context.state.entries) |*entry| {
        if (!entry.occupied) continue;
        const chunk = geometry.chunkForBlock(entry.position);
        if (!context.deps.active.blockTicking(entry.world, chunk)) continue;
        const current_state = entry.block_state;
        const was_lit = entry.burn_time != 0;
        const before_items = entry.items;
        const before_burn = entry.burn_time;
        const before_fuel = entry.fuel_time;
        const before_cook = entry.cook_time;
        const before_cook_total = entry.cook_total;
        var staged = entry.*;
        if (staged.burn_time != 0) staged.burn_time -= 1;
        const recipe = smeltableResult(context.deps.recipes, &staged);
        if (staged.burn_time == 0 and recipe != null) ignite(context.deps.recipes, &staged);
        if (staged.burn_time != 0 and recipe != null) {
            staged.cook_total = recipe.?.cooking_ticks;
            staged.cook_time += 1;
            if (staged.cook_time >= staged.cook_total) {
                completeSmelt(&staged, recipe.?);
                staged.cook_time = 0;
            }
        } else if (staged.cook_time != 0) {
            staged.cook_time -|= @min(staged.cook_time, 2);
        }
        const is_lit = staged.burn_time != 0;
        if (was_lit != is_lit or furnaceLit(current_state) != is_lit) {
            const desired_state = furnaceState(furnaceFacing(current_state), is_lit);
            if (context.blocks.set(staged.world, staged.position, desired_state)) |changed| {
                _ = changed;
                staged.block_state = desired_state;
            } else |err| switch (err) {
                error.ChunkNotMaterialized => _ = context.state.deps.chunk_io.requestCold(staged.world, chunk),
                else => {},
            }
        }
        entry.* = staged;
        const items_changed = !std.meta.eql(before_items, staged.items);
        const progress_changed = before_burn != staged.burn_time or before_cook != staged.cook_time;
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

fn findEntry(state: *Furnaces, world: world_identity.Handle, position: geometry.BlockPos) ?*Entry {
    for (state.entries) |*entry|
        if (entry.occupied and entry.world.eql(world) and geometry.sameBlock(entry.position, position)) return entry;
    return null;
}

fn entryIndex(state: *const Furnaces, world: world_identity.Handle, position: geometry.BlockPos) ?usize {
    for (state.entries, 0..) |entry, index|
        if (entry.occupied and entry.world.eql(world) and geometry.sameBlock(entry.position, position)) return index;
    return null;
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

fn recordKey(index: usize) ?[3]u8 {
    const value = std.math.cast(u16, index) orelse return null;
    var key: [3]u8 = undefined;
    key[0] = persistence_record_tag;
    std.mem.writeInt(u16, key[1..], value, .little);
    return key;
}

fn encodeRoot(buffer: []u8, count: u16) ![]const u8 {
    if (buffer.len < root_bytes) return error.EndOfStream;
    @memcpy(buffer[0..root_magic.len], root_magic);
    std.mem.writeInt(u16, buffer[root_magic.len..][0..2], count, .little);
    std.mem.writeInt(u32, buffer[root_magic.len + 2 ..][0..4], std.hash.crc.Crc32.hash(buffer[0 .. root_magic.len + 2]), .little);
    return buffer[0..root_bytes];
}

fn decodeRoot(bytes: []const u8) !usize {
    if (bytes.len != root_bytes or !std.mem.eql(u8, bytes[0..root_magic.len], root_magic)) return error.InvalidFurnaceData;
    if (std.mem.readInt(u32, bytes[root_magic.len + 2 ..][0..4], .little) != std.hash.crc.Crc32.hash(bytes[0 .. root_magic.len + 2])) return error.InvalidFurnaceData;
    return std.mem.readInt(u16, bytes[root_magic.len..][0..2], .little);
}

fn encodeEntry(state: *const Furnaces, buffer: []u8, entry: Entry) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0..entry_encoded_bytes]);
    const world = state.deps.worlds.getConst(entry.world) orelse return error.StaleWorldHandle;
    try writer.writeInt(u128, world.key.value, .little);
    try writer.writeInt(i32, entry.position.x, .little);
    try writer.writeInt(i16, entry.position.y, .little);
    try writer.writeInt(i32, entry.position.z, .little);
    try writer.writeInt(i32, entry.block_state, .little);
    for (entry.items) |stack| try writeStack(&writer, stack);
    try writer.writeInt(u16, entry.burn_time, .little);
    try writer.writeInt(u16, entry.fuel_time, .little);
    try writer.writeInt(u16, entry.cook_time, .little);
    try writer.writeInt(u16, entry.cook_total, .little);
    std.mem.writeInt(u32, buffer[entry_encoded_bytes..][0..4], std.hash.crc.Crc32.hash(buffer[0..entry_encoded_bytes]), .little);
    return buffer[0..record_bytes];
}

fn decodeEntry(state: *Furnaces, entry: *Entry, bytes: []const u8) !void {
    if (bytes.len != record_bytes or std.mem.readInt(u32, bytes[entry_encoded_bytes..][0..4], .little) != std.hash.crc.Crc32.hash(bytes[0..entry_encoded_bytes])) return error.InvalidFurnaceData;
    var reader = std.Io.Reader.fixed(bytes[0..entry_encoded_bytes]);
    entry.* = .{ .occupied = true };
    entry.world = state.deps.worlds.find(.{ .value = try reader.takeInt(u128, .little) }) orelse return error.UnknownWorldKey;
    entry.position.x = try reader.takeInt(i32, .little);
    entry.position.y = try reader.takeInt(i16, .little);
    entry.position.z = try reader.takeInt(i32, .little);
    entry.block_state = try reader.takeInt(i32, .little);
    if (!isFurnace(entry.block_state)) return error.InvalidFurnaceData;
    for (&entry.items) |*stack| stack.* = try readStack(&reader);
    entry.burn_time = try reader.takeInt(u16, .little);
    entry.fuel_time = try reader.takeInt(u16, .little);
    entry.cook_time = try reader.takeInt(u16, .little);
    entry.cook_total = try reader.takeInt(u16, .little);
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

test "furnace persistence records retain two inventories and timers in ordinal order" {
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
    const worlds = try world_store.Worlds.init(arena.allocator(), .{ .initial = &descriptions, .maximum_worlds = 1 });
    const world = worlds.find(.{ .value = 1 }).?;
    var furnaces: Furnaces = .{ .deps = undefined };
    furnaces.deps.worlds = worlds;
    furnaces.entries = try arena.allocator().alloc(Entry, 8);
    @memset(furnaces.entries, .{});
    furnaces.entries[3] = .{ .occupied = true, .world = world, .position = .{ .x = -4, .y = 70, .z = 9 } };
    furnaces.entries[3].items[0] = player_store.stackForItem(registry.item_raw_gold_id, 3);
    furnaces.entries[3].burn_time = 1200;
    furnaces.entries[3].fuel_time = 1600;
    furnaces.entries[3].cook_time = 41;
    furnaces.entries[7] = .{ .occupied = true, .world = world, .position = .{ .x = 3, .y = 63, .z = -2 } };
    furnaces.entries[7].items[1] = player_store.stackForItem(registry.item_coal_id, 7);
    furnaces.entries[7].burn_time = 800;
    furnaces.entries[7].fuel_time = 1600;
    furnaces.entries[7].cook_time = 99;
    furnaces.entries[7].cook_total = 200;
    var restored: Furnaces = .{ .deps = undefined };
    restored.deps.worlds = worlds;
    restored.entries = try arena.allocator().alloc(Entry, 8);
    @memset(restored.entries, .{});
    var root: [root_bytes]u8 = undefined;
    const root_data = try encodeRoot(&root, 2);
    const count = try decodeRoot(root_data);
    for ([_]Entry{ furnaces.entries[3], furnaces.entries[7] }, 0..) |source, ordinal| {
        var record: [record_bytes]u8 = undefined;
        const bytes = try encodeEntry(&furnaces, &record, source);
        try decodeEntry(&restored, &restored.entries[ordinal], bytes);
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(registry.item_raw_gold_id, restored.entries[0].items[0].item_id);
    try std.testing.expectEqual(@as(u8, 3), restored.entries[0].items[0].count);
    try std.testing.expectEqual(@as(u16, 1200), restored.entries[0].burn_time);
    try std.testing.expectEqual(@as(u16, 41), restored.entries[0].cook_time);
    try std.testing.expectEqual(registry.item_coal_id, restored.entries[1].items[1].item_id);
    try std.testing.expectEqual(@as(u16, 800), restored.entries[1].burn_time);
    try std.testing.expectEqual(@as(u16, 99), restored.entries[1].cook_time);
}
