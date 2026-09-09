const block_store = @import("blocks.zig");
const std = @import("std");
const registry = @import("registry_data");
const game_data = @import("../game_data.zig");
const collision = @import("../collision.zig");
const player_lifecycle = @import("../player_lifecycle.zig");
const preallocated = @import("preallocated");
const geometry = @import("geometry.zig");
const limits = @import("limits.zig");
const world_random = @import("random.zig");
const world_identity = @import("identity.zig");
const world_store = @import("worlds.zig");

const cache_line_size = 64;

const oak_planks_item_id = registry.item_oak_planks_id;
pub const PlayerState = enum {
    free,
    handshaking,
    status,
    login,
    configuration,
    play,
};

pub const GameMode = enum(u8) {
    survival = 0,
    creative = 1,
    adventure = 2,
    spectator = 3,
};

pub const LoginDisposition = enum { new_player, restored_player };

pub const Session = extern struct {
    slot: u16,
    generation: u64,

    pub fn eql(a: Session, b: Session) bool {
        return a.slot == b.slot and a.generation == b.generation;
    }
};

pub const HotbarStack = extern struct {
    block_state: i32 = registry.block_air_default_state,
    item_id: i32 = 0,
    damage: u16 = 0,
    count: u8 = 0,

    pub fn isEmpty(self: HotbarStack) bool {
        return self.count == 0 or self.item_id == 0;
    }

    pub fn isPlaceable(self: HotbarStack) bool {
        return !self.isEmpty() and self.block_state != registry.block_air_default_state;
    }
};

const InventoryDrag = struct {
    active: bool = false,
    button: u2 = 0,
    window_id: i32 = 0,
    slots: u64 = 0,
};

pub const ContainerKind = enum(u8) { none, crafting_table, chest, furnace };

pub const max_container_slots = 54;

pub const OpenContainer = struct {
    world: world_identity.Handle = world_identity.invalid,
    kind: ContainerKind = .none,
    id: i32 = 0,
    state_id: i32 = 0,
    position: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    secondary_position: ?geometry.BlockPos = null,
    menu_type: i32 = 0,
    top_slot_count: u8 = 0,
    top_slots: [max_container_slots]HotbarStack = [_]HotbarStack{.{}} ** max_container_slots,
    crafting_grid: [9]HotbarStack = [_]HotbarStack{.{}} ** 9,
    crafting_result: HotbarStack = .{},
};

pub const CorePlayer = struct {
    world: world_identity.Handle = world_identity.invalid,
    position: geometry.Vec3 = .{ .x = 8, .y = 64, .z = 8 },
    rotation: geometry.Rotation = .{},
    uuid: u128 = 0,
    entity_id: i32 = 0,
    inventory_state_id: i32 = 0,
    state: PlayerState = .free,
    gamemode: GameMode = .survival,
    health: f32 = 20,
    food: i32 = 20,
    saturation: f32 = 5,
    exhaustion: f32 = 0,
    last_damage_taken: f32 = 0,
    time_until_regen: i32 = 0,
    food_tick_timer: i32 = 0,
    last_attacked_ticks: u32 = 0,
    last_attack_item_id: i32 = 0,
    teleport_epoch: u64 = 0,
    next_teleport_id: i32 = 1,
    pending_teleport_id: i32 = 0,
    client_loaded: bool = false,
    selected_hotbar_slot: u4 = 0,
    on_ground: bool = false,
    sneaking: bool = false,
    sprinting: bool = false,
    hotbar: [9]HotbarStack = [_]HotbarStack{.{}} ** 9,
    main_inventory: [27]HotbarStack = [_]HotbarStack{.{}} ** 27,
    armor: [4]HotbarStack = [_]HotbarStack{.{}} ** 4,
    offhand: HotbarStack = .{},
    crafting_grid: [4]HotbarStack = [_]HotbarStack{.{}} ** 4,
    crafting_result: HotbarStack = .{},
    cursor_stack: HotbarStack = .{},
    name: [maximum_name_bytes]u8 = undefined,
    name_len: usize = 0,

    pub fn name_slice(self: *const CorePlayer) []const u8 {
        std.debug.assert(self.name_len <= self.name.len);
        return self.name[0..self.name_len];
    }
};

pub const Players = struct {
    pub const id = "lightning_rod:players";
    pub const Dependencies = struct {
        events: *player_lifecycle.Events,
        worlds: *world_store.Worlds,
    };
    pub const Configuration = struct {
        initial_world: world_identity.Key,
        maximum_connections: usize = 80,
        maximum_players: usize = 64,
        maximum_saved_players: usize = 256,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_connections == 0 or self.maximum_connections > std.math.maxInt(u16))
                return error.InvalidConnectionCapacity;
            if (self.maximum_players == 0 or self.maximum_players > self.maximum_connections)
                return error.InvalidPlayerCapacity;
            if (self.maximum_saved_players == 0 or self.maximum_saved_players > std.math.maxInt(u16))
                return error.InvalidSavedPlayerCapacity;
        }
    };

    deps: Dependencies,
    initial_world: world_identity.Key,
    records: []align(cache_line_size) CorePlayer = &.{},
    session_generations: []u64 = &.{},
    active_slots: []u16 = &.{},
    active_positions: []u16 = &.{},
    active_count: usize = 0,
    saved: []CorePlayer = &.{},
    saved_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Players {
        try configuration.validate();
        if (deps.worlds.find(configuration.initial_world) == null) return error.UnknownInitialWorld;
        const self = try preallocated.create(Players, allocator);
        self.* = .{ .deps = deps, .initial_world = configuration.initial_world };
        self.records = try preallocated.alignedAlloc(CorePlayer, allocator, .@"64", configuration.maximum_connections);
        self.session_generations = try preallocated.alloc(u64, allocator, configuration.maximum_connections);
        self.active_slots = try preallocated.alloc(u16, allocator, configuration.maximum_players);
        self.active_positions = try preallocated.alloc(u16, allocator, configuration.maximum_connections);
        self.saved = try preallocated.alloc(CorePlayer, allocator, configuration.maximum_saved_players);
        @memset(self.records, .{});
        @memset(self.session_generations, 0);
        @memset(self.saved, .{});
        return self;
    }

    pub inline fn activeSlots(self: *const Players) []const u16 {
        return self.active_slots[0..self.active_count];
    }

    pub fn session(self: *const Players, slot: u16) ?Session {
        if (slot >= self.records.len or self.records[slot].state == .free) return null;
        return .{ .slot = slot, .generation = self.session_generations[slot] };
    }

    pub fn validSession(self: *const Players, value: Session) bool {
        const current = self.session(value.slot) orelse return false;
        return current.eql(value);
    }

    pub fn assertSlot(self: *const Players, slot: u16) void {
        std.debug.assert(slot < self.records.len);
    }

    pub fn assertPlayingAndAlive(self: *const Players, slot: u16) error{PlayerNotInPlay}!void {
        self.assertSlot(slot);
        if (self.records[slot].state != .play) return error.PlayerNotInPlay;
        if (self.records[slot].health <= 0) return error.PlayerNotInPlay;
    }

    pub fn setSelectedHotbarSlot(self: *Players, slot: u16, selected: i16) void {
        self.assertSlot(slot);
        if (selected < 0 or selected >= 9) return;
        self.records[slot].selected_hotbar_slot = @intCast(selected);
    }

    pub fn setGameMode(self: *Players, slot: u16, mode: GameMode) void {
        self.assertSlot(slot);
        self.records[slot].gamemode = mode;
    }

    pub fn teleport(
        self: *Players,
        slot: u16,
        world: world_identity.Handle,
        position: geometry.Vec3,
        rotation: geometry.Rotation,
    ) void {
        self.assertSlot(slot);
        const player = &self.records[slot];
        player.world = world;
        player.position = position;
        player.rotation = rotation;
        player.on_ground = false;
        player.teleport_epoch +%= 1;
        if (player.teleport_epoch == 0) player.teleport_epoch = 1;
    }

    pub fn nextInventoryStateId(self: *Players, slot: u16) i32 {
        self.assertSlot(slot);
        const player = &self.records[slot];
        player.inventory_state_id +%= 1;
        return player.inventory_state_id;
    }

    pub fn selectedHotbarStack(self: *const Players, slot: u16) HotbarStack {
        self.assertSlot(slot);
        const player = &self.records[slot];
        return player.hotbar[player.selected_hotbar_slot];
    }

    pub fn selectedPlaceBlock(self: *const Players, slot: u16) ?i32 {
        const stack = self.selectedHotbarStack(slot);
        return if (stack.isPlaceable()) playerPlacedBlockState(stack.block_state) else null;
    }

    pub fn canConsumeSelectedBlock(self: *const Players, slot: u16, block_state: i32) bool {
        const stack = self.selectedHotbarStack(slot);
        return !stack.isEmpty() and sameBlockType(playerPlacedBlockState(stack.block_state), block_state);
    }

    pub fn consumeSelectedBlock(self: *Players, slot: u16, block_state: i32) ?u4 {
        self.assertSlot(slot);
        const player = &self.records[slot];
        const hotbar_slot = player.selected_hotbar_slot;
        const stack = &player.hotbar[hotbar_slot];
        if (stack.isEmpty() or !sameBlockType(playerPlacedBlockState(stack.block_state), block_state)) return null;
        stack.count -= 1;
        if (stack.count == 0) stack.* = .{};
        return hotbar_slot;
    }

    pub fn giveStackToHotbar(self: *Players, slot: u16, stack: HotbarStack) ?u4 {
        var remaining = stack;
        return self.addStackToHotbar(slot, &remaining);
    }

    pub fn addStackToHotbar(self: *Players, slot: u16, incoming: *HotbarStack) ?u4 {
        self.assertSlot(slot);
        if (incoming.isEmpty()) return null;
        const player = &self.records[slot];
        var changed: ?u4 = null;
        for (&player.hotbar, 0..) |*stack, index| {
            if (stack.isEmpty() or !sameStackKind(stack.*, incoming.*) or stack.count == maxStackSize(stack.item_id)) continue;
            const amount = @min(maxStackSize(stack.item_id) - stack.count, incoming.count);
            stack.count += amount;
            incoming.count -= amount;
            changed = @intCast(index);
            if (incoming.count == 0) {
                incoming.* = .{};
                return changed;
            }
        }
        for (&player.hotbar, 0..) |*stack, index| {
            if (!stack.isEmpty()) continue;
            const amount = @min(maxStackSize(incoming.item_id), incoming.count);
            stack.* = incoming.*;
            stack.count = amount;
            incoming.count -= amount;
            changed = @intCast(index);
            if (incoming.count == 0) {
                incoming.* = .{};
                return changed;
            }
        }
        return changed;
    }

    pub fn takeSelectedItem(self: *Players, slot: u16, count: u8) ?HotbarStack {
        self.assertSlot(slot);
        const player = &self.records[slot];
        const stack = &player.hotbar[player.selected_hotbar_slot];
        if (stack.isEmpty()) return null;
        var taken = stack.*;
        taken.count = @min(count, stack.count);
        stack.count -= taken.count;
        if (stack.count == 0) stack.* = .{};
        return taken;
    }

    pub fn damageSelectedItem(self: *Players, slot: u16, amount: u16) ?u4 {
        self.assertSlot(slot);
        const player = &self.records[slot];
        const hotbar_slot = player.selected_hotbar_slot;
        const stack = &player.hotbar[hotbar_slot];
        if (stack.isEmpty()) return null;
        const maximum = game_data.maxDurability(stack.item_id);
        if (maximum == 0) return null;
        stack.damage +|= amount;
        if (stack.damage >= maximum) stack.* = .{};
        return hotbar_slot;
    }

    pub fn reset(self: *Players) void {
        @memset(self.records, .{});
        self.active_count = 0;
        self.saved_count = 0;
    }

    pub fn beginConnection(
        self: *Players,
        random: *world_random.Random,
        slot: u16,
    ) void {
        std.debug.assert(slot < self.records.len);
        std.debug.assert(self.records[slot].state == .free);
        self.session_generations[slot] +%= 1;
        if (self.session_generations[slot] == 0) self.session_generations[slot] = 1;
        self.records[slot] = .{
            .state = .handshaking,
            .uuid = random.random.uuid_for(slot),
            .entity_id = @as(i32, slot) + 1,
        };
    }

    pub fn discardConnection(self: *Players, slot: u16) void {
        self.assertSlot(slot);
        if (self.records[slot].state == .play) self.removeActive(slot);
        self.records[slot] = .{};
    }

    pub fn hasSaved(self: *const Players, uuid: u128, username: []const u8) bool {
        return self.findSaved(uuid, username) != null;
    }

    pub fn transition(self: *Players, slot: u16, state: PlayerState) void {
        std.debug.assert(slot < self.records.len);
        const previous = self.records[slot].state;
        std.debug.assert(validStateTransition(previous, state));
        self.records[slot].state = state;
        if (state == .play) self.addActive(slot);
    }

    pub fn login(
        self: *Players,
        random: *world_random.Random,
        slot: u16,
        username: []const u8,
        client_uuid: u128,
    ) !LoginDisposition {
        std.debug.assert(slot < self.records.len);
        std.debug.assert(self.records[slot].state != .free);
        if (username.len > maximum_name_bytes) return error.UsernameTooLong;
        const player = &self.records[slot];
        const entity_id = player.entity_id;
        const uuid = if (client_uuid != 0) client_uuid else random.random.uuid_for(slot);
        const restored = if (self.findSaved(uuid, username)) |saved_index| restored: {
            player.* = self.saved[saved_index];
            break :restored true;
        } else false;
        if (restored) {
            if (self.deps.worlds.getConst(player.world) == null) return error.StaleWorldHandle;
        } else {
            const world = self.deps.worlds.find(self.initial_world) orelse return error.UnknownInitialWorld;
            const description = self.deps.worlds.getConst(world).?;
            player.world = world;
            player.position = .{
                .x = @floatFromInt(description.spawn_x),
                .y = @floatFromInt(description.spawn_y),
                .z = @floatFromInt(description.spawn_z),
            };
        }
        player.uuid = uuid;
        player.entity_id = entity_id;
        player.last_attacked_ticks = 0;
        player.last_attack_item_id = 0;
        player.sneaking = false;
        player.sprinting = false;
        player.client_loaded = false;
        player.pending_teleport_id = 0;
        if (player.next_teleport_id <= 0) player.next_teleport_id = 1;
        @memcpy(player.name[0..username.len], username);
        player.name_len = username.len;
        player.state = .login;
        try self.savePlayer(slot);
        return if (restored) .restored_player else .new_player;
    }

    pub fn rebuildActive(self: *Players) void {
        self.active_count = 0;
        for (self.records, 0..) |player, slot| {
            if (player.state == .play) self.addActive(@intCast(slot));
        }
    }

    pub fn saveActive(self: *Players) !void {
        for (self.activeSlots()) |slot| try self.savePlayer(slot);
    }

    pub fn saveAll(self: *Players) !void {
        for (self.records, 0..) |player, slot| {
            if (player.state != .free and player.name_len != 0)
                try self.savePlayer(@intCast(slot));
        }
    }

    pub fn savePlayer(self: *Players, slot: u16) !void {
        const player = &self.records[slot];
        if (player.state == .free or player.name_len == 0 or !world_identity.valid(player.world)) return;
        const index = self.findSaved(player.uuid, player.name_slice()) orelse index: {
            if (self.saved_count == self.saved.len) return error.SavedPlayerCapacity;
            defer self.saved_count += 1;
            break :index self.saved_count;
        };
        self.saved[index] = player.*;
        self.saved[index].state = .free;
        self.saved[index].entity_id = 0;
        self.saved[index].sneaking = false;
        self.saved[index].sprinting = false;
    }

    pub fn tick(self: *Players, _: std.mem.Allocator) void {
        self.processLeft();
    }

    fn processLeft(self: *Players) void {
        for (self.deps.events.left.values) |event| {
            const slot: usize = event.slot;
            std.debug.assert(slot < self.records.len);
            self.savePlayer(@intCast(slot)) catch
                @panic("failed to save disconnected player");
            if (self.records[slot].state == .play) self.removeActive(@intCast(slot));
            self.records[slot] = .{};
        }
    }

    fn removeActive(self: *Players, slot: u16) void {
        const position: usize = self.active_positions[slot];
        std.debug.assert(position < self.active_count);
        std.debug.assert(self.active_slots[position] == slot);
        self.active_count -= 1;
        const moved = self.active_slots[self.active_count];
        self.active_slots[position] = moved;
        self.active_positions[moved] = @intCast(position);
    }

    fn addActive(self: *Players, slot: u16) void {
        std.debug.assert(self.active_count < self.active_slots.len);
        self.active_positions[slot] = @intCast(self.active_count);
        self.active_slots[self.active_count] = slot;
        self.active_count += 1;
    }

    fn findSaved(self: *const Players, uuid: u128, name: []const u8) ?usize {
        for (self.saved[0..self.saved_count], 0..) |saved, index| {
            if (uuid != 0 and saved.uuid == uuid) return index;
            if (std.mem.eql(u8, saved.name_slice(), name)) return index;
        }
        return null;
    }
};

pub const maximum_name_bytes = limits.username_bytes;

pub const Containers = struct {
    pub const id = "lightning_rod:containers";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        events: *player_lifecycle.Events,
        players: *Players,
    };

    deps: Dependencies,
    drags: []InventoryDrag = &.{},
    open: []OpenContainer = &.{},
    counters: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*Containers {
        const self = try preallocated.create(Containers, allocator);
        self.* = .{ .deps = deps };
        const connections = deps.players.records.len;
        self.drags = try preallocated.alloc(InventoryDrag, allocator, connections);
        self.open = try preallocated.alloc(OpenContainer, allocator, connections);
        self.counters = try preallocated.alloc(u8, allocator, connections);
        @memset(self.drags, .{});
        @memset(self.open, .{});
        @memset(self.counters, 0);
        return self;
    }

    pub fn reset(self: *Containers) void {
        @memset(self.drags, .{});
        @memset(self.open, .{});
        @memset(self.counters, 0);
    }

    pub fn nextStateId(self: *Containers, players: *Players, slot: u16) i32 {
        players.assertSlot(slot);
        const open = &self.open[slot];
        open.state_id +%= 1;
        return open.state_id;
    }

    pub fn tick(self: *Containers, _: std.mem.Allocator) void {
        self.processLeft();
    }

    fn processLeft(self: *Containers) void {
        for (self.deps.events.left.values) |event| {
            self.drags[event.slot] = .{};
            self.open[event.slot] = .{};
            self.counters[event.slot] = 0;
        }
    }
};

pub fn maxStackSize(item_id: i32) u8 {
    return game_data.stackSize(item_id);
}

pub fn inventoryStack(player: *CorePlayer, protocol_slot: i16) ?*HotbarStack {
    return if (protocol_slot >= 1 and protocol_slot <= 4)
        &player.crafting_grid[@intCast(protocol_slot - 1)]
    else if (protocol_slot >= 5 and protocol_slot <= 8)
        &player.armor[@intCast(protocol_slot - 5)]
    else if (protocol_slot >= 9 and protocol_slot <= 35)
        &player.main_inventory[@intCast(protocol_slot - 9)]
    else if (protocol_slot >= 36 and protocol_slot <= 44)
        &player.hotbar[@intCast(protocol_slot - 36)]
    else if (protocol_slot == 45)
        &player.offhand
    else
        null;
}

pub fn sameStackKind(a: HotbarStack, b: HotbarStack) bool {
    return !a.isEmpty() and !b.isEmpty() and a.item_id == b.item_id and a.damage == b.damage;
}

pub fn moveStackInto(slots: anytype, incoming: *HotbarStack) void {
    if (incoming.isEmpty()) return;
    for (slots) |*stack| {
        if (stack.isEmpty() or stack.item_id != incoming.item_id or stack.damage != incoming.damage) continue;
        const moved = @min(maxStackSize(stack.item_id) - stack.count, incoming.count);
        stack.count += moved;
        incoming.count -= moved;
        if (incoming.count == 0) {
            incoming.* = .{};
            return;
        }
    }
    for (slots) |*stack| {
        if (!stack.isEmpty()) continue;
        const moved = @min(maxStackSize(incoming.item_id), incoming.count);
        stack.* = incoming.*;
        stack.count = moved;
        incoming.count -= moved;
        if (incoming.count == 0) {
            incoming.* = .{};
            return;
        }
    }
}

fn moveStackIntoReverse(slots: anytype, incoming: *HotbarStack) void {
    if (incoming.isEmpty()) return;
    var index = slots.len;
    while (index != 0) {
        index -= 1;
        const stack = &slots[index];
        if (stack.isEmpty() or stack.item_id != incoming.item_id or stack.damage != incoming.damage) continue;
        const moved = @min(maxStackSize(stack.item_id) - stack.count, incoming.count);
        stack.count += moved;
        incoming.count -= moved;
        if (incoming.count == 0) {
            incoming.* = .{};
            return;
        }
    }
    index = slots.len;
    while (index != 0) {
        index -= 1;
        const stack = &slots[index];
        if (!stack.isEmpty()) continue;
        const moved = @min(maxStackSize(incoming.item_id), incoming.count);
        stack.* = incoming.*;
        stack.count = moved;
        incoming.count -= moved;
        if (incoming.count == 0) {
            incoming.* = .{};
            return;
        }
    }
}

pub fn storeCraftingResult(player: *CorePlayer, result: HotbarStack) bool {
    var hotbar = player.hotbar;
    var main_inventory = player.main_inventory;
    var remaining = result;
    moveStackIntoReverse(&hotbar, &remaining);
    moveStackIntoReverse(&main_inventory, &remaining);
    if (!remaining.isEmpty()) return false;
    player.hotbar = hotbar;
    player.main_inventory = main_inventory;
    return true;
}

pub fn returnCraftingGridToInventory(player: *CorePlayer) void {
    for (&player.crafting_grid) |*stack| {
        moveStackInto(&player.hotbar, stack);
        moveStackInto(&player.main_inventory, stack);
    }
    player.crafting_result = .{};
}

pub fn stackForItem(item_id: i32, count: u8) HotbarStack {
    return .{ .item_id = item_id, .block_state = blockStateForItem(item_id), .count = count };
}

pub fn blockStateForItem(item_id: i32) i32 {
    return game_data.blockStateForItem(item_id);
}

pub fn playerPlacedBlockState(block_state: i32) i32 {
    if (block_state < 0 or block_state >= registry.block_state_to_block.len) return block_state;
    if (registry.block_state_to_block[@intCast(block_state)] != registry.block_oak_leaves_id) return block_state;
    const leaf = registry.blocks[@intCast(registry.block_oak_leaves_id)];
    const property_index = block_state - leaf.min_state;
    return if (@mod(property_index, 4) >= 2) block_state - 2 else block_state;
}

pub fn sameBlockType(a: i32, b: i32) bool {
    if (a < 0 or b < 0) return false;
    const a_index: usize = @intCast(a);
    const b_index: usize = @intCast(b);
    if (a_index >= registry.block_state_to_block.len or b_index >= registry.block_state_to_block.len) return false;
    return registry.block_state_to_block[a_index] == registry.block_state_to_block[b_index];
}

pub fn dropStackForBlockState(block_state: i32, count: u8) ?HotbarStack {
    const item_id = game_data.dropItemForBlock(block_state);
    return if (item_id == 0) null else stackForItem(item_id, count);
}

pub fn validBuildY(y: i16) bool {
    return y >= limits.min_y and y <= block_store.world_top_y;
}

pub fn playerCanReachBlock(player: *const CorePlayer, pos: geometry.BlockPos) bool {
    const min_x: f64 = @floatFromInt(pos.x);
    const min_y: f64 = @floatFromInt(pos.y);
    const min_z: f64 = @floatFromInt(pos.z);
    const eye_x = player.position.x;
    const eye_y = player.position.y + 1.62;
    const eye_z = player.position.z;
    const nearest_x = std.math.clamp(eye_x, min_x, min_x + 1.0);
    const nearest_y = std.math.clamp(eye_y, min_y, min_y + 1.0);
    const nearest_z = std.math.clamp(eye_z, min_z, min_z + 1.0);
    const dx = nearest_x - eye_x;
    const dy = nearest_y - eye_y;
    const dz = nearest_z - eye_z;
    return dx * dx + dy * dy + dz * dz < 5.5 * 5.5;
}

pub fn playerIntersectsBlock(player: *const CorePlayer, pos: geometry.BlockPos) bool {
    const block_x = @as(f64, @floatFromInt(pos.x));
    const block_y = @as(f64, @floatFromInt(pos.y));
    const block_z = @as(f64, @floatFromInt(pos.z));
    return block_x < player.position.x + 0.3 and block_x + 1.0 > player.position.x - 0.3 and
        block_y < player.position.y + 1.8 and block_y + 1.0 > player.position.y and
        block_z < player.position.z + 0.3 and block_z + 1.0 > player.position.z - 0.3;
}

pub fn playerIntersectsBlockState(player: *const CorePlayer, pos: geometry.BlockPos, block_state: i32) bool {
    const player_box = collision.entityBox(player.position.x, player.position.y, player.position.z, 0.6, 1.8);
    for (collision.shapeBoxes(block_state)) |local_box| {
        if (player_box.intersects(collision.worldBox(local_box, pos.x, pos.y, pos.z))) return true;
    }
    return false;
}

fn validStateTransition(previous: PlayerState, next: PlayerState) bool {
    if (previous == next) return true;
    return switch (previous) {
        .free => next == .handshaking,
        .handshaking => next == .status or next == .login,
        .status => false,
        .login => next == .configuration,
        .configuration => next == .play,
        .play => false,
    };
}

const test_world_key = world_identity.Key{ .value = 1 };
const test_world_description = world_store.Description{
    .key = test_world_key,
    .name = "test:overworld",
    .dimension = .{ .index = 0 },
    .generator = @enumFromInt(0),
    .seed = 1,
    .spawn_x = 8,
    .spawn_y = 64,
    .spawn_z = 8,
};

fn createTestPlayers(allocator: std.mem.Allocator, lifecycle: *player_lifecycle.Events) !*Players {
    const worlds = try world_store.Worlds.init(allocator, .{ .initial = &.{test_world_description} });
    return Players.init(allocator, .{ .events = lifecycle, .worlds = worlds }, .{ .initial_world = test_world_key });
}

test "new player admission resolves the current initial world generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lifecycle: player_lifecycle.Events = .{};
    const worlds = try world_store.Worlds.init(arena.allocator(), .{ .initial = &.{test_world_description} });
    const first = worlds.find(test_world_key).?;
    try worlds.destroy(first);
    const current = try worlds.add(test_world_description);
    try std.testing.expect(current.generation != first.generation);
    const players = try Players.init(
        arena.allocator(),
        .{ .events = &lifecycle, .worlds = worlds },
        .{ .initial_world = test_world_key },
    );
    var random: world_random.Random = .{};
    random.random = world_random.DeterministicRng.init(11);
    players.beginConnection(&random, 0);
    try std.testing.expectEqual(LoginDisposition.new_player, try players.login(&random, 0, "new-player", 44));
    try std.testing.expect(players.records[0].world.eql(current));
    try std.testing.expectEqual(@as(f64, test_world_description.spawn_y), players.records[0].position.y);
}

test "player session generation changes when a connection slot is reused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lifecycle: player_lifecycle.Events = .{};
    const players = try createTestPlayers(arena.allocator(), &lifecycle);
    var random: world_random.Random = .{};
    random.random = world_random.DeterministicRng.init(17);
    players.beginConnection(&random, 0);
    const first = players.session(0).?;
    try std.testing.expect(first.generation != 0);
    const event = player_lifecycle.PlayerLeft{
        .slot = 0,
        .connection = .{ .index = 0, .generation = 1 },
        .reason = .peer_closed,
    };
    lifecycle.left = .{ .values = &.{event} };
    players.tick(std.testing.allocator);
    players.beginConnection(&random, 0);
    try std.testing.expect(!players.validSession(first));
    try std.testing.expect(!players.session(0).?.eql(first));
}

test "player disconnect saves normalized state before releasing the slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lifecycle: player_lifecycle.Events = .{};
    const players = try createTestPlayers(arena.allocator(), &lifecycle);
    var random: world_random.Random = .{};
    random.random = world_random.DeterministicRng.init(23);
    players.beginConnection(&random, 0);
    _ = try players.login(&random, 0, "saved-player", 99);
    players.transition(0, .configuration);
    players.transition(0, .play);
    players.records[0].world = .{ .index = 0, .generation = 1 };
    players.records[0].hotbar[4] = stackForItem(oak_planks_item_id, 7);
    const event = player_lifecycle.PlayerLeft{
        .slot = 0,
        .connection = .{ .index = 0, .generation = 1 },
        .reason = .peer_closed,
    };
    lifecycle.left = .{ .values = &.{event} };
    players.tick(std.testing.allocator);
    try std.testing.expectEqual(PlayerState.free, players.records[0].state);
    try std.testing.expectEqual(@as(usize, 1), players.saved_count);
    try std.testing.expectEqual(@as(u8, 7), players.saved[0].hotbar[4].count);
}

test "replacement connection restores the persisted player by UUID and name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lifecycle: player_lifecycle.Events = .{};
    const players = try createTestPlayers(arena.allocator(), &lifecycle);
    var random: world_random.Random = .{};
    random.random = world_random.DeterministicRng.init(29);
    players.beginConnection(&random, 0);
    _ = try players.login(&random, 0, "restore", 77);
    players.transition(0, .configuration);
    players.transition(0, .play);
    players.records[0].world = .{ .index = 0, .generation = 1 };
    players.records[0].position = .{ .x = 9, .y = 72, .z = -4 };
    try players.savePlayer(0);
    players.discardConnection(0);
    try std.testing.expect(players.hasSaved(77, "restore"));
    players.beginConnection(&random, 1);
    try std.testing.expectEqual(LoginDisposition.restored_player, try players.login(&random, 1, "restore", 77));
    try std.testing.expectEqual(@as(f64, 9), players.records[1].position.x);
}
