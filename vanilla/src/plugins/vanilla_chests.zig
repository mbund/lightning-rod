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
const persistence_magic = "LRCHST02";
const persistence_key = "state";
const single_menu_type = 2;
const double_menu_type = 5;
const stack_encoded_bytes = @sizeOf(i32) + @sizeOf(i32) + @sizeOf(u16) + @sizeOf(u8);
const entry_encoded_bytes = @sizeOf(u128) + @sizeOf(i32) + @sizeOf(i16) + @sizeOf(i32) + 27 * stack_encoded_bytes;

fn encodedCapacity(maximum_entries: usize) !usize {
    return std.math.add(usize, persistence_magic.len + @sizeOf(u16), try std.math.mul(usize, maximum_entries, entry_encoded_bytes));
}

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
    observed_mutation_sequence: u64 = 0,
    forced_single_positions: []geometry.BlockPos = &.{},
    forced_single_count: usize = 0,
    drags: []container_clicks.Drag = &.{},
    viewer_counts: []u8 = &.{},
    persistence_buffer: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Chests {
        try configuration.validate();
        const self = try allocator.create(Chests);
        self.* = .{ .deps = deps };
        self.entries = try allocator.alloc(Entry, configuration.maximum_entries);
        self.forced_single_positions = try allocator.alloc(geometry.BlockPos, deps.inputs.block_requests.len);
        self.drags = try allocator.alloc(container_clicks.Drag, deps.players.records.len);
        self.viewer_counts = try allocator.alloc(u8, configuration.maximum_entries);
        self.persistence_buffer = try allocator.alloc(u8, try encodedCapacity(configuration.maximum_entries));
        @memset(self.entries, .{});
        @memset(self.drags, .{});
        @memset(self.viewer_counts, 0);
        try self.restore();
        self.observed_mutation_sequence = self.deps.blocks.block_mutation_sequence;
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
        reconcileMutations(&work);
        synchronizeViewerCounts(&work);
    }

    pub fn checkpoint(self: *Chests, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        if (!self.dirty) return;
        const bytes = try encodeState(self, self.persistence_buffer);
        try writer.put(persistence_key, bytes);
        self.dirty = false;
    }

    fn runtime(self: *Chests, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, items: *entity_store.ItemEntities, inputs: *input_store.Inputs, containers: *player_store.Containers, outputs: *Packets) ChestRuntime {
        return .{
            .deps = .{ .random = random, .world = blocks, .players = players, .items = items, .inputs = inputs, .containers = containers },
            .outputs = outputs,
            .state = self,
            .blocks = block_writer.Writer.init(blocks, outputs),
        };
    }

    fn restore(self: *Chests) !void {
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

    fn spawnItem(self: *ChestWork, world: world_identity.Handle, position: geometry.Vec3, velocity: geometry.Vec3, stack: player_store.HotbarStack) !usize {
        return self.items.spawn(self.random, self.world, world, position, velocity, stack, entity_store.block_drop_pickup_delay_ticks);
    }

    fn spawnPlayerDrop(self: *ChestWork, player: *const player_store.CorePlayer, stack: player_store.HotbarStack) !usize {
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

const ChestRuntime = struct {
    deps: ChestWork,
    outputs: *Packets,
    state: *Chests,
    blocks: block_writer.Writer,
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
        const against_state = simulation.world.blockAtIfResident(request.world, request.against_pos) orelse {
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
            const current = simulation.world.blockAtIfResident(request.world, request.pos) orelse continue;
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
        if (!isChest(simulation.world.blockAtIfResident(world, attached) orelse return) or chestBlocked(simulation, world, attached)) return;
        if (part == .left) {
            second = attached;
        } else {
            first = attached;
            second = position;
        }
    }
    const first_entry = getOrCreateEntry(context.state, world, first) catch return;
    var projected: [player_store.max_container_slots]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** player_store.max_container_slots;
    @memcpy(projected[0..27], &first_entry.items);
    var count: usize = 27;
    if (second) |second_position| {
        const second_entry = getOrCreateEntry(context.state, world, second_position) catch return;
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
        const result = container_clicks.applyWithDrag(
            container_clicks.StorageRules,
            &rules,
            &simulation.players.records[click.slot],
            projected[0..count],
            click.*,
            &context.state.drags[click.slot],
        );
        if (!result.changed) {
            projectAndSend(context, click.slot, false);
            continue;
        }
        @memcpy(first.items[0..], projected[0..27]);
        if (container.secondary_position) |position| if (findEntry(context.state, container.world, position)) |second|
            @memcpy(second.items[0..], projected[27..54]);
        markDirty(context.state, true);
        if (result.dropped) |stack| spawnPlayerDrop(context, click.slot, stack);
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

fn reconcileMutations(context: *ChestRuntime) void {
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
        if (isChest(mutation.previous_state) and !isChest(mutation.block_state))
            removeChest(context, mutation.world, mutation.pos, mutation.previous_state);
        if (!isChest(mutation.previous_state) and isChest(mutation.block_state))
            addChest(context, mutation.world, mutation.pos);
    }
    context.state.observed_mutation_sequence = context.deps.world.block_mutation_sequence;
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

fn addChest(context: *ChestRuntime, world: world_identity.Handle, position: geometry.BlockPos) void {
    _ = getOrCreateEntry(context.state, world, position) catch return;
    markDirty(context.state, true);
    for (context.state.forced_single_positions[0..context.state.forced_single_count]) |forced|
        if (geometry.sameBlock(forced, position)) return;
    const placed_state = context.deps.world.blockAtIfResident(world, position) orelse return;
    const facing = chestFacing(placed_state);
    const clockwise_position = offset(position, clockwise(facing));
    const counter_position = offset(position, counterClockwise(facing));
    const neighbor = if (isSingleFacing(&context.deps, world, clockwise_position, facing))
        clockwise_position
    else if (isSingleFacing(&context.deps, world, counter_position, facing))
        counter_position
    else
        return;
    const new_part: ChestPart = if (geometry.sameBlock(neighbor, clockwise_position)) .left else .right;
    const neighbor_part: ChestPart = if (new_part == .left) .right else .left;
    _ = context.blocks.set(world, position, chestState(facing, new_part)) catch return;
    _ = context.blocks.set(world, neighbor, chestState(facing, neighbor_part)) catch return;
}

fn removeChest(
    context: *ChestRuntime,
    world: world_identity.Handle,
    position: geometry.BlockPos,
    previous_state: i32,
) void {
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
        markDirty(context.state, true);
    }
    const part = chestPart(previous_state) orelse .single;
    if (part != .single) {
        const partner = offset(position, attachedDirection(chestFacing(previous_state), part));
        const partner_state = context.deps.world.blockAtIfResident(world, partner) orelse return;
        if (isChest(partner_state))
            _ = context.blocks.set(world, partner, chestState(chestFacing(partner_state), .single)) catch {};
    }
    for (context.deps.activePlayerSlots()) |slot| {
        const open_container = &context.deps.containers.open[slot];
        if (open_container.kind != .chest) continue;
        if (!geometry.sameBlock(open_container.position, position) and
            !(open_container.secondary_position != null and geometry.sameBlock(open_container.secondary_position.?, position))) continue;
        const window_id = open_container.id;
        container_menu.close(context.deps.players, context.deps.containers, slot);
        context.outputs.container_closed(.{ .slot = slot, .window_id = window_id });
    }
}

fn spawnPlayerDrop(context: *ChestRuntime, slot: u16, stack: player_store.HotbarStack) void {
    const item_index = context.deps.spawnPlayerDrop(&context.deps.players.records[slot], stack) catch return;
    context.outputs.item_spawned(@intCast(item_index));
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

fn getOrCreateEntry(state: *Chests, world: world_identity.Handle, position: geometry.BlockPos) !*Entry {
    if (findEntry(state, world, position)) |entry| return entry;
    for (state.entries) |*entry| {
        if (entry.occupied) continue;
        entry.* = .{ .occupied = true, .world = world, .position = position };
        markDirty(state, true);
        return entry;
    }
    return error.ChestCapacity;
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
    const state = simulation.world.blockAtIfResident(world, position) orelse return false;
    return isChest(state) and chestFacing(state) == facing and chestPart(state).? == .single;
}

fn chestBlocked(simulation: *const ChestWork, world: world_identity.Handle, position: geometry.BlockPos) bool {
    var above = position;
    above.y += 1;
    const state = simulation.world.blockAtIfResident(world, above) orelse return true;
    return collision.shapeBoxes(state).len != 0;
}

fn encodeState(state: *const Chests, buffer: []u8) ![]const u8 {
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
    }
    return writer.buffered();
}

fn decodeState(state: *Chests, bytes: []const u8) !void {
    var reader = std.Io.Reader.fixed(bytes);
    var magic: [persistence_magic.len]u8 = undefined;
    try reader.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, persistence_magic)) return error.InvalidChestData;
    const count = try reader.takeInt(u16, .little);
    if (count > state.entries.len) return error.InvalidChestData;
    for (state.entries[0..count]) |*entry| {
        entry.* = .{ .occupied = true };
        entry.world = state.deps.worlds.find(.{ .value = try reader.takeInt(u128, .little) }) orelse return error.UnknownWorldKey;
        entry.position.x = try reader.takeInt(i32, .little);
        entry.position.y = try reader.takeInt(i16, .little);
        entry.position.z = try reader.takeInt(i32, .little);
        for (&entry.items) |*stack| stack.* = try readStack(&reader);
    }
    if (reader.seek != bytes.len) return error.InvalidChestData;
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

test "chest persistence round trips inventory" {
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
    const worlds = try world_store.Worlds.init(arena.allocator(), .{ .initial = &descriptions });
    const world = worlds.find(.{ .value = 1 }).?;
    var chests: Chests = .{ .deps = undefined };
    chests.deps.worlds = worlds;
    chests.entries = try arena.allocator().alloc(Entry, 8);
    @memset(chests.entries, .{});
    const entry = try getOrCreateEntry(&chests, world, .{ .x = 1, .y = 64, .z = 2 });
    entry.items[4] = player_store.stackForItem(registry.item_oak_log_id, 17);
    var buffer: [encodedCapacity(8) catch unreachable]u8 = undefined;
    const bytes = try encodeState(&chests, &buffer);
    var restored: Chests = .{ .deps = undefined };
    restored.deps.worlds = worlds;
    restored.entries = try arena.allocator().alloc(Entry, 8);
    @memset(restored.entries, .{});
    try decodeState(&restored, bytes);
    try std.testing.expectEqual(@as(u8, 17), findEntry(&restored, world, entry.position).?.items[4].count);
}
