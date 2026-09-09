const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const world_random = lightning_rod.random;
const std = @import("std");
const registry = lightning_rod.registry_data;
const collision = lightning_rod.collision;
const block_writer = lightning_rod.block_writer;
const container_menu = lightning_rod.container_menu;
const container_clicks = lightning_rod.container_clicks;
const Packets = lightning_rod.Packets;
const world_identity = lightning_rod.world_identity;
const world_store = lightning_rod.worlds;

const persistence_id = "minecraft:chests";
const persistence_key = "state";
const persistence_root_key = "\x00";
const persistence_record_tag: u8 = 1;
const root_magic = "LRCHST03";
const single_menu_type = 2;
const double_menu_type = 5;
const stack_encoded_bytes = @sizeOf(i32) + @sizeOf(i32) + @sizeOf(u16) + @sizeOf(u8);
const entry_encoded_bytes = @sizeOf(u128) + @sizeOf(i32) + @sizeOf(i16) + @sizeOf(i32) + 27 * stack_encoded_bytes;

const root_bytes = root_magic.len + @sizeOf(u16) + @sizeOf(u32);
const record_bytes = entry_encoded_bytes + @sizeOf(u32);

pub const Entry = struct {
    occupied: bool = false,
    world: world_identity.Handle = world_identity.invalid,
    position: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    items: [27]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** 27,
    viewer_count: u8 = 0,
};

pub const Chests = struct {
    pub const id = persistence_id;
    pub const Configuration = struct {
        maximum_entries: usize = 128,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_entries == 0 or self.maximum_entries > std.math.maxInt(u16))
                return error.InvalidChestCapacity;
        }
    };
    pub const Dependencies = struct {
        persistence: lightning_rod.persistence.PluginAccess,
        worlds: *world_store.Worlds,
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        items: *entity_store.ItemEntities,
        inputs: *input_store.Inputs,
        containers: *player_store.Containers,
        outputs: *Packets,
    };

    entries: []Entry = &.{},
    deps: Dependencies,
    dirty: bool = false,
    forced_single_positions: []geometry.BlockPos = &.{},
    forced_single_count: usize = 0,
    drags: []container_clicks.Drag = &.{},
    viewer_counts: []u8 = &.{},
    persistence_root: [root_bytes]u8 = undefined,
    persistence_record: [record_bytes]u8 = undefined,

    pub const Removal = struct {
        world: world_identity.Handle,
        position: geometry.BlockPos,
        entry: ?u16 = null,
        items: [27]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** 27,
        partner_position: ?geometry.BlockPos = null,
        partner_state: i32 = registry.block_air_default_state,
    };

    pub const Placement = struct {
        entry: u16,
        world: world_identity.Handle,
        position: geometry.BlockPos,
    };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Chests {
        try configuration.validate();
        const self = try allocator.create(Chests);
        self.* = .{ .deps = deps };
        self.entries = try allocator.alloc(Entry, configuration.maximum_entries);
        self.forced_single_positions = try allocator.alloc(geometry.BlockPos, deps.inputs.block_requests.len);
        self.drags = try allocator.alloc(container_clicks.Drag, deps.players.records.len);
        self.viewer_counts = try allocator.alloc(u8, configuration.maximum_entries);
        @memset(self.entries, .{});
        @memset(self.drags, .{});
        @memset(self.viewer_counts, 0);
        try self.restore();
        return self;
    }

    pub fn tick(self: *Chests, _: std.mem.Allocator) void {
        const random = self.deps.random;
        const blocks = self.deps.blocks;
        const players = self.deps.players;
        const items = self.deps.items;
        const inputs = self.deps.inputs;
        const containers = self.deps.containers;
        const outputs = self.deps.outputs;
        var work = self.runtime(random, blocks, players, items, inputs, containers, outputs);
        handleBlockInteractions(&work);
        applyClicks(&work);
        synchronizeViewerCounts(&work);
    }

    pub fn checkpoint(self: *Chests, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        if (!self.dirty) return;
        var count: u16 = 0;
        for (self.entries) |entry| {
            if (!entry.occupied) continue;
            const key = recordKey(count) orelse return error.ChestCapacity;
            try writer.put(&key, try encodeEntry(self, &self.persistence_record, entry));
            count += 1;
        }
        try writer.put(persistence_root_key, try encodeRoot(&self.persistence_root, count));
        self.dirty = false;
    }

    pub fn prepareRemoval(self: *const Chests, world: world_identity.Handle, position: geometry.BlockPos, previous_state: i32) Removal {
        var removal = Removal{ .world = world, .position = position };
        if (entryIndex(self, world, position)) |index| {
            removal.entry = @intCast(index);
            removal.items = self.entries[index].items;
        }
        const part = chestPart(previous_state) orelse .single;
        if (part == .single) return removal;
        const partner = offset(position, attachedDirection(chestFacing(previous_state), part));
        const partner_state = self.deps.blocks.blockAtIfMaterialized(world, partner) orelse return removal;
        if (!isChest(partner_state)) return removal;
        removal.partner_position = partner;
        removal.partner_state = chestState(chestFacing(partner_state), .single);
        return removal;
    }

    pub fn commitRemoval(self: *Chests, removal: Removal) void {
        if (removal.entry) |raw_index| {
            const index: usize = raw_index;
            const entry = &self.entries[index];
            std.debug.assert(entry.occupied);
            std.debug.assert(entry.world.eql(removal.world));
            std.debug.assert(geometry.sameBlock(entry.position, removal.position));
            entry.* = .{};
            markDirty(self, true);
        }
        for (self.deps.players.activeSlots()) |slot| {
            const container = &self.deps.containers.open[slot];
            if (container.kind != .chest) continue;
            if (!geometry.sameBlock(container.position, removal.position) and
                !(container.secondary_position != null and geometry.sameBlock(container.secondary_position.?, removal.position))) continue;
            const window_id = container.id;
            container_menu.close(self.deps.players, self.deps.containers, slot);
            self.deps.outputs.container_closed(.{ .slot = slot, .window_id = window_id });
        }
    }

    pub fn reservePlacement(self: *const Chests, world: world_identity.Handle, position: geometry.BlockPos) !Placement {
        if (entryIndex(self, world, position) != null) return error.ChestAlreadyExists;
        for (self.entries, 0..) |entry, index| {
            if (entry.occupied) continue;
            return .{ .entry = @intCast(index), .world = world, .position = position };
        }
        return error.ChestCapacity;
    }

    pub fn commitPlacement(self: *Chests, placement: Placement) void {
        const entry = &self.entries[placement.entry];
        std.debug.assert(!entry.occupied);
        entry.* = .{ .occupied = true, .world = placement.world, .position = placement.position };
        markDirty(self, true);
        linkPlacement(self, placement.world, placement.position);
    }

    fn runtime(self: *Chests, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, items: *entity_store.ItemEntities, inputs: *input_store.Inputs, containers: *player_store.Containers, outputs: *Packets) ChestRuntime {
        return .{
            .deps = .{ .random = random, .world = blocks, .players = players, .items = items, .inputs = inputs, .containers = containers },
            .outputs = outputs,
            .state = self,
        };
    }

    fn restore(self: *Chests) !void {
        self.rejectLegacy() catch |err| switch (err) {
            error.DestinationTooSmall => return error.StorageSchemaUnsupported,
            else => return err,
        };
        const loaded = try self.deps.persistence.load(persistence_root_key, &self.persistence_root);
        switch (loaded) {
            .missing => {},
            .value => |length| {
                const count = try decodeRoot(self.persistence_root[0..length]);
                if (count > self.entries.len) return error.InvalidChestData;
                for (0..count) |index| {
                    const key = recordKey(index) orelse return error.InvalidChestData;
                    const record = try self.deps.persistence.load(&key, &self.persistence_record);
                    const bytes = switch (record) {
                        .missing => return error.InvalidChestData,
                        .value => |value_length| self.persistence_record[0..value_length],
                    };
                    try decodeEntry(self, &self.entries[index], bytes);
                }
            },
        }
    }

    fn rejectLegacy(self: *Chests) !void {
        const loaded = try self.deps.persistence.load(persistence_key, &.{});
        if (loaded != .missing) return error.StorageSchemaUnsupported;
    }
};

const ChestWork = struct {
    random: *world_random.Random,
    world: *block_store.Blocks,
    players: *player_store.Players,
    items: *entity_store.ItemEntities,
    inputs: *input_store.Inputs,
    containers: *player_store.Containers,

    inline fn activePlayerSlots(self: *const ChestWork) []const u16 {
        return self.players.active_slots[0..self.players.active_count];
    }

    const PreparedDrop = struct {
        reservation: entity_store.ItemEntities.Reservation,
        specification: entity_store.ItemEntities.Spawn,
    };

    fn preparePlayerDrop(self: *ChestWork, player: *const player_store.CorePlayer, stack: player_store.HotbarStack) !PreparedDrop {
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

    fn commitPlayerDrop(self: *ChestWork, prepared: *PreparedDrop) usize {
        var output: [1]usize = undefined;
        self.items.commitReserved(&prepared.reservation, self.random, &.{prepared.specification}, &output);
        return output[0];
    }
};

const ChestRuntime = struct {
    deps: ChestWork,
    outputs: *Packets,
    state: *Chests,
};

fn markDirty(state: *Chests, _: bool) void {
    state.dirty = true;
}

fn handleBlockInteractions(context: *ChestRuntime) void {
    const simulation = &context.deps;
    context.state.forced_single_count = 0;
    for (0..simulation.inputs.block_request_count) |request_offset| {
        const request = &simulation.inputs.block_requests[request_offset];
        if (request.handled or request.kind != .use_item_on) continue;
        const against_state = simulation.world.blockAtIfMaterialized(request.world, request.against_pos) orelse {
            if (findEntry(context.state, request.world, request.against_pos) != null) request.handled = true;
            continue;
        };
        if (isChest(against_state) and !simulation.players.records[request.slot].sneaking) {
            request.handled = true;
            openChest(context, request.slot, request.against_pos, against_state);
            continue;
        }
        if (!isChest(request.block_state)) continue;
        const facing = facingForYaw(simulation.players.records[request.slot].rotation.yaw);
        request.block_state = chestState(facing, .single);
        if (simulation.players.records[request.slot].sneaking) {
            if (context.state.forced_single_count < context.state.forced_single_positions.len) {
                context.state.forced_single_positions[context.state.forced_single_count] = request.pos;
                context.state.forced_single_count += 1;
            }
            continue;
        }
        const clockwise_single = isSingleFacing(simulation, request.world, offset(request.pos, clockwise(facing)), facing);
        const counter_single = isSingleFacing(simulation, request.world, offset(request.pos, counterClockwise(facing)), facing);
        if (clockwise_single and counter_single) {
            request.handled = true;
            const current = simulation.world.blockAtIfMaterialized(request.world, request.pos) orelse continue;
            context.outputs.block_changed(.{ .world = request.world, .pos = request.pos, .block_state = current });
            context.outputs.inventory_changed(request.slot);
        }
    }
}

fn openChest(
    context: *ChestRuntime,
    slot: u16,
    position: geometry.BlockPos,
    state_id: i32,
) void {
    const simulation = &context.deps;
    const part = chestPart(state_id) orelse return;
    const world = simulation.players.records[slot].world;
    if (!player_store.playerCanReachBlock(&simulation.players.records[slot], position) or chestBlocked(simulation, world, position)) return;
    var first = position;
    var second: ?geometry.BlockPos = null;
    if (part != .single) {
        const attached = offset(position, attachedDirection(chestFacing(state_id), part));
        if (!isChest(simulation.world.blockAtIfMaterialized(world, attached) orelse return) or chestBlocked(simulation, world, attached)) return;
        if (part == .left) {
            second = attached;
        } else {
            first = attached;
            second = position;
        }
    }
    const first_entry = findEntry(context.state, world, first) orelse return;
    var projected: [player_store.max_container_slots]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** player_store.max_container_slots;
    @memcpy(projected[0..27], &first_entry.items);
    var count: usize = 27;
    if (second) |second_position| {
        const second_entry = findEntry(context.state, world, second_position) orelse return;
        @memcpy(projected[27..54], &second_entry.items);
        count = 54;
    }
    container_menu.open(
        simulation.players,
        simulation.containers,
        slot,
        .chest,
        first,
        second,
        if (second == null) single_menu_type else double_menu_type,
        projected[0..count],
    );
    context.outputs.menu_opened(.{ .slot = slot, .title = if (second == null) "Chest" else "Large Chest" });
}

fn applyClicks(context: *ChestRuntime) void {
    const simulation = &context.deps;
    for (0..simulation.inputs.inventory_click_count) |offset_index| {
        const click = &simulation.inputs.inventory_clicks[offset_index];
        if (click.handled) continue;
        const container = &simulation.containers.open[click.slot];
        if (container.kind != .chest or container.id != click.window_id) continue;
        click.handled = true;

        const first = findEntry(context.state, container.world, container.position) orelse continue;
        var projected: [player_store.max_container_slots]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** player_store.max_container_slots;
        @memcpy(projected[0..27], &first.items);
        const count: usize = if (container.secondary_position) |position| blk: {
            const second = findEntry(context.state, container.world, position) orelse break :blk 27;
            @memcpy(projected[27..54], &second.items);
            break :blk 54;
        } else 27;
        const rules: container_clicks.StorageRules = .{};
        var staged_player = simulation.players.records[click.slot];
        var staged_drag = context.state.drags[click.slot];
        const result = container_clicks.applyWithDrag(
            container_clicks.StorageRules,
            &rules,
            &staged_player,
            projected[0..count],
            click.*,
            &staged_drag,
        );
        context.state.drags[click.slot] = staged_drag;
        if (!result.changed) {
            projectAndSend(context, click.slot, false);
            continue;
        }
        var prepared_drop: ?ChestWork.PreparedDrop = null;
        if (result.dropped) |stack|
            prepared_drop = simulation.preparePlayerDrop(&staged_player, stack) catch {
                projectAndSend(context, click.slot, false);
                continue;
            };
        simulation.players.records[click.slot] = staged_player;
        @memcpy(first.items[0..], projected[0..27]);
        if (container.secondary_position) |position| if (findEntry(context.state, container.world, position)) |second|
            @memcpy(second.items[0..], projected[27..54]);
        markDirty(context.state, true);
        if (prepared_drop) |*prepared| {
            const index = simulation.commitPlayerDrop(prepared);
            context.outputs.item_spawned(@intCast(index));
        }
        projectAndSend(context, click.slot, true);
        synchronizeOtherViewers(context, click.slot, container.position, container.secondary_position);
    }
}

fn projectAndSend(context: *ChestRuntime, slot: u16, player_inventory_changed: bool) void {
    const container = &context.deps.containers.open[slot];
    if (container.kind != .chest) return;
    const first = findEntry(context.state, container.world, container.position) orelse return;
    var projected: [player_store.max_container_slots]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** player_store.max_container_slots;
    @memcpy(projected[0..27], &first.items);
    var count: usize = 27;
    if (container.secondary_position) |position| if (findEntry(context.state, container.world, position)) |second| {
        @memcpy(projected[27..54], &second.items);
        count = 54;
    };
    container_menu.project(context.deps.containers, slot, projected[0..count]);
    if (player_inventory_changed)
        context.outputs.menu_player_inventory_changed(slot, &.{})
    else
        context.outputs.menu_changed(slot, &.{});
}

fn synchronizeOtherViewers(
    context: *ChestRuntime,
    source_slot: u16,
    first: geometry.BlockPos,
    second: ?geometry.BlockPos,
) void {
    for (context.deps.activePlayerSlots()) |slot| {
        if (slot == source_slot) continue;
        const open_container = &context.deps.containers.open[slot];
        if (open_container.kind != .chest) continue;
        const same_first = geometry.sameBlock(open_container.position, first) or
            (second != null and geometry.sameBlock(open_container.position, second.?));
        if (!same_first) continue;
        projectAndSend(context, slot, false);
    }
}

fn synchronizeViewerCounts(context: *ChestRuntime) void {
    const counts = context.state.viewer_counts;
    @memset(counts, 0);
    for (context.deps.activePlayerSlots()) |slot| {
        const container = &context.deps.containers.open[slot];
        if (container.kind != .chest) continue;
        if (entryIndex(context.state, container.world, container.position)) |index| {
            counts[index] +|= 1;
        }
        if (container.secondary_position) |position| {
            if (entryIndex(context.state, container.world, position)) |index| {
                counts[index] +|= 1;
            }
        }
    }
    for (context.state.entries, counts) |*entry, count| {
        if (!entry.occupied or entry.viewer_count == count) continue;
        entry.viewer_count = count;
        context.outputs.chest_viewers_changed(.{ .world = entry.world, .position = entry.position, .viewers = count });
    }
}

fn linkPlacement(state: *Chests, world: world_identity.Handle, position: geometry.BlockPos) void {
    for (state.forced_single_positions[0..state.forced_single_count]) |forced|
        if (geometry.sameBlock(forced, position)) return;
    const placed_state = state.deps.blocks.blockAtIfMaterialized(world, position) orelse return;
    const facing = chestFacing(placed_state);
    const clockwise_position = offset(position, clockwise(facing));
    const counter_position = offset(position, counterClockwise(facing));
    const work = ChestWork{ .random = state.deps.random, .world = state.deps.blocks, .players = state.deps.players, .items = state.deps.items, .inputs = state.deps.inputs, .containers = state.deps.containers };
    const neighbor = if (isSingleFacing(&work, world, clockwise_position, facing))
        clockwise_position
    else if (isSingleFacing(&work, world, counter_position, facing))
        counter_position
    else
        return;
    const new_part: ChestPart = if (geometry.sameBlock(neighbor, clockwise_position)) .left else .right;
    const neighbor_part: ChestPart = if (new_part == .left) .right else .left;
    const blocks = block_writer.Writer.init(state.deps.blocks, state.deps.outputs);
    var batch = blocks.beginBatch();
    batch.set(world, position, chestState(facing, new_part)) catch return;
    batch.set(world, neighbor, chestState(facing, neighbor_part)) catch return;
    _ = batch.finish() catch return;
}

fn findEntry(state: *Chests, world: world_identity.Handle, position: geometry.BlockPos) ?*Entry {
    for (state.entries) |*entry|
        if (entry.occupied and entry.world.eql(world) and geometry.sameBlock(entry.position, position)) return entry;
    return null;
}

fn entryIndex(state: *const Chests, world: world_identity.Handle, position: geometry.BlockPos) ?usize {
    for (state.entries, 0..) |entry, index|
        if (entry.occupied and entry.world.eql(world) and geometry.sameBlock(entry.position, position)) return index;
    return null;
}

const ChestPart = enum { single, left, right };
const Facing = enum(u2) { north, south, west, east };

fn isChest(block_state: i32) bool {
    return block_state >= 0 and block_state < registry.block_state_to_block.len and
        registry.block_state_to_block[@intCast(block_state)] == registry.block_chest_id;
}

fn chestFacing(block_state: i32) Facing {
    const info = registry.blocks[@intCast(registry.block_chest_id)];
    return @enumFromInt(@as(u2, @intCast(@divTrunc(block_state - info.min_state, 6))));
}

fn chestPart(block_state: i32) ?ChestPart {
    if (!isChest(block_state)) return null;
    const info = registry.blocks[@intCast(registry.block_chest_id)];
    return @enumFromInt(@divTrunc(@mod(block_state - info.min_state, 6), 2));
}

fn chestState(facing: Facing, part: ChestPart) i32 {
    const info = registry.blocks[@intCast(registry.block_chest_id)];
    return info.min_state + @as(i32, @intFromEnum(facing)) * 6 + @as(i32, @intFromEnum(part)) * 2 + 1;
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

fn clockwise(facing: Facing) Facing {
    return switch (facing) {
        .north => .east,
        .east => .south,
        .south => .west,
        .west => .north,
    };
}

fn counterClockwise(facing: Facing) Facing {
    return clockwise(clockwise(clockwise(facing)));
}

fn attachedDirection(facing: Facing, part: ChestPart) Facing {
    return if (part == .left) clockwise(facing) else counterClockwise(facing);
}

fn offset(position: geometry.BlockPos, direction: Facing) geometry.BlockPos {
    var result = position;
    switch (direction) {
        .north => result.z -= 1,
        .south => result.z += 1,
        .west => result.x -= 1,
        .east => result.x += 1,
    }
    return result;
}

fn isSingleFacing(simulation: *const ChestWork, world: world_identity.Handle, position: geometry.BlockPos, facing: Facing) bool {
    const state = simulation.world.blockAtIfMaterialized(world, position) orelse return false;
    return isChest(state) and chestFacing(state) == facing and chestPart(state).? == .single;
}

fn chestBlocked(simulation: *const ChestWork, world: world_identity.Handle, position: geometry.BlockPos) bool {
    var above = position;
    above.y += 1;
    const state = simulation.world.blockAtIfMaterialized(world, above) orelse return true;
    return collision.shapeBoxes(state).len != 0;
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
    if (bytes.len != root_bytes or !std.mem.eql(u8, bytes[0..root_magic.len], root_magic)) return error.InvalidChestData;
    if (std.mem.readInt(u32, bytes[root_magic.len + 2 ..][0..4], .little) != std.hash.crc.Crc32.hash(bytes[0 .. root_magic.len + 2])) return error.InvalidChestData;
    return std.mem.readInt(u16, bytes[root_magic.len..][0..2], .little);
}

fn encodeEntry(state: *const Chests, buffer: []u8, entry: Entry) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0..entry_encoded_bytes]);
    const world = state.deps.worlds.getConst(entry.world) orelse return error.StaleWorldHandle;
    try writer.writeInt(u128, world.key.value, .little);
    try writer.writeInt(i32, entry.position.x, .little);
    try writer.writeInt(i16, entry.position.y, .little);
    try writer.writeInt(i32, entry.position.z, .little);
    for (entry.items) |stack| try writeStack(&writer, stack);
    std.mem.writeInt(u32, buffer[entry_encoded_bytes..][0..4], std.hash.crc.Crc32.hash(buffer[0..entry_encoded_bytes]), .little);
    return buffer[0..record_bytes];
}

fn decodeEntry(state: *Chests, entry: *Entry, bytes: []const u8) !void {
    if (bytes.len != record_bytes or std.mem.readInt(u32, bytes[entry_encoded_bytes..][0..4], .little) != std.hash.crc.Crc32.hash(bytes[0..entry_encoded_bytes])) return error.InvalidChestData;
    var reader = std.Io.Reader.fixed(bytes[0..entry_encoded_bytes]);
    entry.* = .{ .occupied = true };
    entry.world = state.deps.worlds.find(.{ .value = try reader.takeInt(u128, .little) }) orelse return error.UnknownWorldKey;
    entry.position.x = try reader.takeInt(i32, .little);
    entry.position.y = try reader.takeInt(i16, .little);
    entry.position.z = try reader.takeInt(i32, .little);
    for (&entry.items) |*stack| stack.* = try readStack(&reader);
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

test "chest state encoding preserves facing and half" {
    for (std.enums.values(Facing)) |facing| {
        for (std.enums.values(ChestPart)) |part| {
            const state = chestState(facing, part);
            try std.testing.expectEqual(facing, chestFacing(state));
            try std.testing.expectEqual(part, chestPart(state).?);
        }
    }
}

test "double chest halves point at one another" {
    const origin: geometry.BlockPos = .{ .x = 10, .y = 64, .z = 10 };
    for (std.enums.values(Facing)) |facing| {
        const left_partner = offset(origin, attachedDirection(facing, .left));
        const right_partner = offset(left_partner, attachedDirection(facing, .right));
        try std.testing.expect(geometry.sameBlock(origin, right_partner));
    }
}

test "chest persistence records round trip two inventories in ordinal order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const descriptions = [_]world_store.Description{.{
        .key = .{ .value = 1 },
        .name = "test:chest",
        .dimension = .{ .index = 0 },
        .generator = @enumFromInt(0),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }};
    const worlds = try world_store.Worlds.init(arena.allocator(), .{ .initial = &descriptions, .maximum_worlds = 1 });
    const world = worlds.find(.{ .value = 1 }).?;
    var chests: Chests = .{ .deps = undefined };
    chests.deps.worlds = worlds;
    chests.entries = try arena.allocator().alloc(Entry, 8);
    @memset(chests.entries, .{});
    chests.entries[2] = .{ .occupied = true, .world = world, .position = .{ .x = 1, .y = 64, .z = 2 } };
    chests.entries[2].items[4] = player_store.stackForItem(registry.item_oak_log_id, 17);
    chests.entries[6] = .{ .occupied = true, .world = world, .position = .{ .x = -5, .y = 70, .z = 9 } };
    chests.entries[6].items[19] = player_store.stackForItem(registry.item_coal_id, 11);
    var restored: Chests = .{ .deps = undefined };
    restored.deps.worlds = worlds;
    restored.entries = try arena.allocator().alloc(Entry, 8);
    @memset(restored.entries, .{});
    var root: [root_bytes]u8 = undefined;
    const root_data = try encodeRoot(&root, 2);
    const count = try decodeRoot(root_data);
    for ([_]Entry{ chests.entries[2], chests.entries[6] }, 0..) |source, ordinal| {
        var record: [record_bytes]u8 = undefined;
        const bytes = try encodeEntry(&chests, &record, source);
        try decodeEntry(&restored, &restored.entries[ordinal], bytes);
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u8, 17), restored.entries[0].items[4].count);
    try std.testing.expectEqual(@as(u8, 11), restored.entries[1].items[19].count);
}
