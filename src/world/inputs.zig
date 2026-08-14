const player_store = @import("players.zig");
const block_store = @import("blocks.zig");
const std = @import("std");
const registry = @import("registry_data");
const config = @import("../config.zig").value;
const diagnostics = @import("../diagnostics.zig");
const player_lifecycle = @import("../player_lifecycle.zig");
const preallocated = @import("preallocated");
const geometry = @import("geometry.zig");
const world_identity = @import("identity.zig");

pub const BlockRequestKind = enum {
    break_block,
    use_item_on,
};

pub const BlockRequest = struct {
    world: world_identity.Handle,
    slot: u16,
    kind: BlockRequestKind,
    pos: geometry.BlockPos,
    against_pos: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    face: i32 = 1,
    cursor: struct { x: f32 = 0.5, y: f32 = 0.5, z: f32 = 0.5 } = .{},
    sequence: i32,
    block_state: i32 = registry.block_air_default_state,
    handled: bool = false,
};

pub const InventoryClick = struct {
    slot: u16,
    window_id: i32,
    state_id: i32,
    protocol_slot: i16,
    mouse_button: i8,
    mode: i32,
    handled: bool = false,
};

pub const CreativeSlotChange = struct {
    slot: u16,
    inventory_slot: i16 = 0,
    stack: player_store.HotbarStack = .{},
};

pub const PreviousMovement = struct {
    position: geometry.Vec3,
    rotation: geometry.Rotation,
    on_ground: bool,
};

pub const PendingMovement = struct {
    dirty: bool = false,
    has_position: bool = false,
    has_rotation: bool = false,
    position: geometry.Vec3 = .{},
    rotation: geometry.Rotation = .{},
    on_ground: bool = false,
};

pub const PendingPlayerInput = struct {
    dirty: bool = false,
    shift: bool = false,
    sprint: bool = false,
};

pub const PendingSprintAction = struct {
    dirty: bool = false,
    sprinting: bool = false,
};

pub const BlockDigProgress = struct {
    active: bool = false,
    world: world_identity.Handle = world_identity.invalid,
    failed_to_mine: bool = false,
    pos: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    face: i32 = 1,
    sequence: i32 = 0,
    start_tick: u64 = 0,
    damage_q32: u64 = 0,
    last_stage: i8 = -1,
};

const PendingDigStart = struct { pos: geometry.BlockPos, face: i32, sequence: i32 };

const PendingLivingAttack = struct {
    active: bool = false,
    entity_id: i32 = 0,
};

const PendingPlayerAttack = struct {
    active: bool = false,
    target_slot: u16 = 0,
    target_entity_id: i32 = 0,
};

pub const PendingLivingInteraction = struct {
    active: bool = false,
    entity_id: i32 = 0,
    hand: i32 = 0,
};

const PendingArmSwing = struct {
    active: bool = false,
    hand: i32 = 0,
};

pub const PendingItemDrop = struct {
    count: u8 = 0,
};

const PendingDigAction = union(enum) {
    none,
    start: PendingDigStart,
    start_and_cancel: PendingDigStart,
    start_and_finish: PendingDigStart,
    finish: struct { pos: geometry.BlockPos, sequence: i32 },
    cancel,
};

pub const BlockDigIntent = struct {
    slot: u16,
    pos: geometry.BlockPos,
};

pub const Inputs = struct {
    pub const id = "lightning_rod:tick_inputs";

    lifecycle: *player_lifecycle.Events,
    block_requests: []BlockRequest = &.{},
    block_request_count: usize = 0,
    inventory_clicks: []InventoryClick = &.{},
    inventory_click_count: usize = 0,
    creative_slot_changes: []CreativeSlotChange = &.{},
    creative_slot_change_count: usize = 0,
    container_closes: []i32 = &.{},
    dig_actions: []PendingDigAction = &.{},
    movements: []PendingMovement = &.{},
    player_inputs: []PendingPlayerInput = &.{},
    sprint_actions: []PendingSprintAction = &.{},
    living_attacks: []PendingLivingAttack = &.{},
    player_attacks: []PendingPlayerAttack = &.{},
    living_interactions: []PendingLivingInteraction = &.{},
    arm_swings: []PendingArmSwing = &.{},
    item_drops: []PendingItemDrop = &.{},
    respawns: []bool = &.{},

    pub fn create(allocator: std.mem.Allocator, lifecycle: *player_lifecycle.Events) !*Inputs {
        const self = try preallocated.create(Inputs, allocator);
        self.* = .{ .lifecycle = lifecycle };
        self.block_requests = try preallocated.alloc(BlockRequest, allocator, config.tick_block_request_capacity);
        self.inventory_clicks = try preallocated.alloc(InventoryClick, allocator, config.tick_inventory_click_capacity);
        self.creative_slot_changes = try preallocated.alloc(CreativeSlotChange, allocator, config.tick_creative_slot_capacity);
        self.container_closes = try preallocated.alloc(i32, allocator, config.connectionCapacity());
        self.dig_actions = try preallocated.alloc(PendingDigAction, allocator, config.connectionCapacity());
        self.movements = try preallocated.alloc(PendingMovement, allocator, config.connectionCapacity());
        self.player_inputs = try preallocated.alloc(PendingPlayerInput, allocator, config.connectionCapacity());
        self.sprint_actions = try preallocated.alloc(PendingSprintAction, allocator, config.connectionCapacity());
        self.living_attacks = try preallocated.alloc(PendingLivingAttack, allocator, config.connectionCapacity());
        self.player_attacks = try preallocated.alloc(PendingPlayerAttack, allocator, config.connectionCapacity());
        self.living_interactions = try preallocated.alloc(PendingLivingInteraction, allocator, config.connectionCapacity());
        self.arm_swings = try preallocated.alloc(PendingArmSwing, allocator, config.connectionCapacity());
        self.item_drops = try preallocated.alloc(PendingItemDrop, allocator, config.connectionCapacity());
        self.respawns = try preallocated.alloc(bool, allocator, config.connectionCapacity());
        @memset(self.container_closes, -1);
        @memset(self.dig_actions, .none);
        @memset(self.movements, .{});
        @memset(self.player_inputs, .{});
        @memset(self.sprint_actions, .{});
        @memset(self.living_attacks, .{});
        @memset(self.player_attacks, .{});
        @memset(self.living_interactions, .{});
        @memset(self.arm_swings, .{});
        @memset(self.item_drops, .{});
        @memset(self.respawns, false);
        return self;
    }

    pub fn reset(self: *Inputs) void {
        self.block_request_count = 0;
        self.inventory_click_count = 0;
        self.creative_slot_change_count = 0;
        @memset(self.container_closes, -1);
        @memset(self.dig_actions, .none);
        @memset(self.movements, .{});
        @memset(self.player_inputs, .{});
        @memset(self.sprint_actions, .{});
        @memset(self.living_attacks, .{});
        @memset(self.player_attacks, .{});
        @memset(self.living_interactions, .{});
        @memset(self.arm_swings, .{});
        @memset(self.item_drops, .{});
        @memset(self.respawns, false);
    }

    pub fn resetPlayerTransfer(self: *Inputs, slot: u16) void {
        std.debug.assert(slot < self.movements.len);
        self.container_closes[slot] = -1;
        self.dig_actions[slot] = .none;
        self.movements[slot] = .{};
        self.player_inputs[slot] = .{};
        self.sprint_actions[slot] = .{};
        self.living_attacks[slot] = .{};
        self.player_attacks[slot] = .{};
        self.living_interactions[slot] = .{};
        self.arm_swings[slot] = .{};
        self.item_drops[slot] = .{};
        self.respawns[slot] = false;
    }

    pub fn stageBlockRequest(
        self: *Inputs,
        players: *const player_store.Players,
        original: BlockRequest,
    ) !void {
        players.assertSlot(original.slot);
        const player = &players.records[original.slot];
        if (player.state != .play) return error.PlayerNotInPlay;
        if (player.health <= 0) return;
        var request = original;
        request.world = player.world;
        if (request.kind == .use_item_on)
            request.block_state = players.selectedPlaceBlock(request.slot) orelse registry.block_air_default_state;
        try self.enqueueBlockRequest(request);
    }

    pub fn requestEntityAttack(
        self: *Inputs,
        players: *const player_store.Players,
        slot: u16,
        entity_id: i32,
    ) !void {
        players.assertPlayingAndAlive(slot) catch |err| return err;
        self.living_attacks[slot] = .{};
        self.player_attacks[slot] = .{};
        if (entity_id > 0) {
            const target_slot: usize = @intCast(entity_id - 1);
            if (target_slot < players.records.len) {
                const target = &players.records[target_slot];
                if (target.state == .play and target.world.eql(players.records[slot].world) and target.entity_id == entity_id) {
                    self.player_attacks[slot] = .{
                        .active = true,
                        .target_slot = @intCast(target_slot),
                        .target_entity_id = entity_id,
                    };
                    return;
                }
            }
        }
        self.living_attacks[slot] = .{ .active = true, .entity_id = entity_id };
    }

    pub fn requestLivingInteraction(
        self: *Inputs,
        players: *const player_store.Players,
        slot: u16,
        entity_id: i32,
        hand: i32,
    ) !void {
        try players.assertPlayingAndAlive(slot);
        self.living_interactions[slot] = .{ .active = true, .entity_id = entity_id, .hand = hand };
    }

    pub fn requestArmSwing(self: *Inputs, players: *const player_store.Players, slot: u16, hand: i32) !void {
        try players.assertPlayingAndAlive(slot);
        self.arm_swings[slot] = .{ .active = true, .hand = hand };
    }

    pub fn requestRespawn(self: *Inputs, players: *const player_store.Players, slot: u16) !void {
        players.assertSlot(slot);
        if (players.records[slot].state != .play) return error.PlayerNotInPlay;
        self.respawns[slot] = true;
    }

    pub fn stageDigStart(self: *Inputs, slot: u16, pos: geometry.BlockPos, face: i32, sequence: i32) void {
        self.dig_actions[slot] = switch (self.dig_actions[slot]) {
            .none, .cancel, .finish => .{ .start = .{ .pos = pos, .face = face, .sequence = sequence } },
            .start, .start_and_cancel, .start_and_finish => .{ .start = .{ .pos = pos, .face = face, .sequence = sequence } },
        };
    }

    pub fn stageDigFinish(self: *Inputs, slot: u16, pos: geometry.BlockPos, sequence: i32) void {
        self.dig_actions[slot] = switch (self.dig_actions[slot]) {
            .start => |start| .{ .start_and_finish = start },
            else => .{ .finish = .{ .pos = pos, .sequence = sequence } },
        };
    }

    pub fn stageDigCancel(self: *Inputs, slot: u16) void {
        self.dig_actions[slot] = switch (self.dig_actions[slot]) {
            .start => |start| .{ .start_and_cancel = start },
            else => .cancel,
        };
    }

    pub fn requestContainerClose(self: *Inputs, slot: u16, window_id: i32) void {
        self.container_closes[slot] = window_id;
    }

    pub fn requestItemDrop(self: *Inputs, slot: u16, count: u8) void {
        self.item_drops[slot].count +|= count;
    }

    pub fn queueMovement(self: *Inputs, slot: u16, position: ?geometry.Vec3, rotation: ?geometry.Rotation, on_ground: bool) void {
        const movement = &self.movements[slot];
        movement.dirty = true;
        if (position) |value| {
            movement.has_position = true;
            movement.position = value;
        }
        if (rotation) |value| {
            movement.has_rotation = true;
            movement.rotation = value;
        }
        movement.on_ground = on_ground;
    }

    pub fn queuePlayerInput(self: *Inputs, slot: u16, shift: bool, sprint: bool) void {
        self.player_inputs[slot] = .{ .dirty = true, .shift = shift, .sprint = sprint };
    }

    pub fn queueSprintAction(self: *Inputs, slot: u16, sprinting: bool) void {
        self.sprint_actions[slot] = .{ .dirty = true, .sprinting = sprinting };
    }

    pub fn enqueueBlockRequest(self: *Inputs, request: BlockRequest) !void {
        if (self.block_request_count == self.block_requests.len) return error.BlockRequestBatchFull;
        self.block_requests[self.block_request_count] = request;
        self.block_request_count += 1;
    }

    pub fn blockDigIntent(self: *const Inputs, slot: u16) ?BlockDigIntent {
        std.debug.assert(slot < self.dig_actions.len);
        const pos = switch (self.dig_actions[slot]) {
            .none, .cancel => return null,
            .start => |intent| intent.pos,
            .start_and_cancel => |intent| intent.pos,
            .start_and_finish => |intent| intent.pos,
            .finish => |intent| intent.pos,
        };
        return .{ .slot = slot, .pos = pos };
    }

    pub fn rejectBlockDig(self: *Inputs, slot: u16) void {
        std.debug.assert(slot < self.dig_actions.len);
        std.debug.assert(self.blockDigIntent(slot) != null);
        self.dig_actions[slot] = .none;
    }

    pub fn enqueueInventoryClick(self: *Inputs, players: *const player_store.Players, click: InventoryClick) !void {
        try players.assertPlayingAndAlive(click.slot);
        if (self.inventory_click_count == self.inventory_clicks.len) return error.InventoryClickBatchFull;
        self.inventory_clicks[self.inventory_click_count] = click;
        self.inventory_click_count += 1;
    }

    pub fn requestCreativeSlot(self: *Inputs, players: *const player_store.Players, slot: u16, inventory_slot: i16, item_id: i32, count: u8) !void {
        players.assertSlot(slot);
        const player = &players.records[slot];
        if (player.state != .play) return error.PlayerNotInPlay;
        if (player.gamemode != .creative) return;
        if (inventory_slot < 1 or inventory_slot > 45) return;
        if (count != 0 and (item_id <= 0 or item_id >= registry.items.len or count > player_store.maxStackSize(item_id)))
            return error.InvalidCreativeItem;
        if (self.creative_slot_change_count == self.creative_slot_changes.len)
            return error.CreativeSlotChangeBatchFull;
        self.creative_slot_changes[self.creative_slot_change_count] = .{
            .slot = slot,
            .inventory_slot = inventory_slot,
            .stack = if (count == 0) .{} else player_store.stackForItem(item_id, count),
        };
        self.creative_slot_change_count += 1;
    }

    pub fn assertConsumed(self: *const Inputs, tick: u64) void {
        if (self.block_request_count != 0)
            diagnostics.panic("tick completed with unconsumed block requests (tick, count)", &.{ diagnostics.integer(tick), diagnostics.integer(self.block_request_count) });
        if (self.inventory_click_count != 0)
            diagnostics.panic("tick completed with unconsumed inventory clicks (tick, count)", &.{ diagnostics.integer(tick), diagnostics.integer(self.inventory_click_count) });
        if (self.creative_slot_change_count != 0)
            diagnostics.panic("tick completed with unconsumed creative slot changes (tick, count)", &.{ diagnostics.integer(tick), diagnostics.integer(self.creative_slot_change_count) });
    }

    pub fn left(
        self: *Inputs,
    ) void {
        var slots = [_]u64{0} ** ((config.connectionCapacity() + 63) / 64);
        for (self.lifecycle.left.values) |event| {
            const slot: usize = event.slot;
            std.debug.assert(slot < config.connectionCapacity());
            slots[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
            self.container_closes[slot] = -1;
            self.dig_actions[slot] = .none;
            self.movements[slot] = .{};
            self.player_inputs[slot] = .{};
            self.sprint_actions[slot] = .{};
            self.item_drops[slot] = .{};
            self.living_attacks[slot] = .{};
            self.player_attacks[slot] = .{};
            self.living_interactions[slot] = .{};
            self.arm_swings[slot] = .{};
            self.respawns[slot] = false;
        }
        self.block_request_count = retainConnected(
            BlockRequest,
            self.block_requests[0..self.block_request_count],
            &slots,
        );
        self.inventory_click_count = retainConnected(
            InventoryClick,
            self.inventory_clicks[0..self.inventory_click_count],
            &slots,
        );
        self.creative_slot_change_count = retainConnected(
            CreativeSlotChange,
            self.creative_slot_changes[0..self.creative_slot_change_count],
            &slots,
        );
    }

    fn retainConnected(
        comptime T: type,
        values: []T,
        disconnected: []const u64,
    ) usize {
        var retained: usize = 0;
        for (values) |value| {
            const slot: usize = value.slot;
            if (disconnected[slot / 64] & (@as(u64, 1) << @intCast(slot % 64)) != 0)
                continue;
            values[retained] = value;
            retained += 1;
        }
        return retained;
    }
};
