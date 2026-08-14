const std = @import("std");

pub const Position = extern struct { x: f64, y: f64, z: f64 };
pub const Rotation = extern struct { yaw: f32, pitch: f32 };
pub const BlockPosition = extern struct { x: i32, y: i16, z: i32 };

pub const Operation = enum(u32) {
    teleport_confirm,
    keep_alive_response,
    chunk_batch_received,
    movement,
    player_input,
    player_sprint,
    player_loaded,
    chat,
    command,
    block_dig,
    block_place,
    held_item_slot,
    arm_animation,
    attack_entity,
    interact_entity,
    respawn,
    use_item,
    window_click,
    creative_slot,
    close_window,
    ignored,
};

pub const CallbackStatus = enum(u32) {
    ok,
    failed,
};

pub const Arguments = struct {
    pub const Slot = extern struct { slot: u16 };
    pub const TeleportConfirm = extern struct { slot: u16, value: i32 };
    pub const KeepAliveResponse = extern struct { slot: u16, value: i64 };
    pub const ChunkBatchReceived = extern struct { slot: u16, chunks_per_tick: f32 };
    pub const Movement = extern struct {
        slot: u16,
        has_position: u8,
        position: Position,
        has_rotation: u8,
        rotation: Rotation,
        on_ground: u8,
    };
    pub const PlayerInput = extern struct {
        slot: u16,
        shift: u8,
        sprint: u8,
    };
    pub const PlayerSprint = extern struct {
        slot: u16,
        sprinting: u8,
    };
    pub const Bytes = extern struct {
        slot: u16,
        pointer: [*]const u8,
        length: usize,

        pub fn value(self: Bytes) []const u8 {
            return self.pointer[0..self.length];
        }
    };
    pub const BlockDig = extern struct {
        slot: u16,
        status: i32,
        position: BlockPosition,
        face: i32,
        sequence: i32,
    };
    pub const BlockPlace = extern struct {
        slot: u16,
        position: BlockPosition,
        direction: i32,
        cursor_x: f32,
        cursor_y: f32,
        cursor_z: f32,
        sequence: i32,
    };
    pub const HeldItemSlot = extern struct { slot: u16, value: i16 };
    pub const Integer = extern struct { slot: u16, value: i32 };
    pub const EntityInteraction = extern struct { slot: u16, entity_id: i32, hand: i32 };
    pub const WindowClick = extern struct {
        slot: u16,
        window_id: i32,
        state_id: i32,
        protocol_slot: i16,
        mouse_button: i8,
        mode: i32,
    };
    pub const CreativeSlot = extern struct {
        slot: u16,
        inventory_slot: i16,
        item_id: i32,
        count: u8,
    };
};

pub const RawCallback = *const fn (*anyopaque, Operation, *const anyopaque) callconv(.c) CallbackStatus;

/// Included in both module descriptors. A process must never call a handler
/// built against a different argument layout, even when the outer operation
/// table itself happens to have the same size and offsets.
pub const abi_fingerprint = interfaceFingerprint();

fn addTypeFingerprint(seed: u64, comptime T: type) u64 {
    var result = std.hash.Wyhash.hash(seed, @typeName(T));
    result ^= @as(u64, @sizeOf(T)) *% 0x9e37_79b9_7f4a_7c15;
    result ^= @as(u64, @alignOf(T)) *% 0xc2b2_ae3d_27d4_eb4f;
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            result = std.hash.Wyhash.hash(result, field.name);
            result = std.hash.Wyhash.hash(result, @typeName(field.type));
            result ^= @as(u64, @offsetOf(T, field.name)) *% 0x1656_67b1_9e37_79f9;
        },
        .@"enum" => |info| inline for (info.fields) |field| {
            result = std.hash.Wyhash.hash(result, field.name);
            result ^= @as(u64, @intCast(field.value)) *% 0x85eb_ca77_c2b2_ae63;
        },
        else => {},
    }
    return result;
}

fn interfaceFingerprint() u64 {
    @setEvalBranchQuota(100_000);
    var result: u64 = 0x4c52_504c_4159_0001;
    inline for (.{
        Operation,
        CallbackStatus,
        Position,
        Rotation,
        BlockPosition,
        Arguments.Slot,
        Arguments.TeleportConfirm,
        Arguments.KeepAliveResponse,
        Arguments.ChunkBatchReceived,
        Arguments.Movement,
        Arguments.PlayerInput,
        Arguments.PlayerSprint,
        Arguments.Bytes,
        Arguments.BlockDig,
        Arguments.BlockPlace,
        Arguments.HeldItemSlot,
        Arguments.Integer,
        Arguments.EntityInteraction,
        Arguments.WindowClick,
        Arguments.CreativeSlot,
        Handler,
    }) |T| result = addTypeFingerprint(result, T);
    return result;
}

/// Type-erased only at the shared-library boundary. Every callback remains a
/// concrete, typed operation and is invoked synchronously while the packet's
/// tick-arena storage is alive; no decoded command object is retained.
pub const Handler = extern struct {
    context: *anyopaque,
    callback: RawCallback,

    fn invoke(self: *const Handler, operation: Operation, arguments: anytype) !void {
        if (self.callback(self.context, operation, &arguments) != .ok)
            return error.PlayInputHandlerFailed;
    }

    pub fn teleport_confirm(self: *const Handler, slot: u16, value: i32) void {
        self.invoke(.teleport_confirm, Arguments.TeleportConfirm{ .slot = slot, .value = value }) catch {};
    }
    pub fn keep_alive_response(self: *const Handler, slot: u16, value: i64) void {
        self.invoke(.keep_alive_response, Arguments.KeepAliveResponse{ .slot = slot, .value = value }) catch {};
    }
    pub fn chunk_batch_received(self: *const Handler, slot: u16, chunks_per_tick: f32) void {
        self.invoke(.chunk_batch_received, Arguments.ChunkBatchReceived{
            .slot = slot,
            .chunks_per_tick = chunks_per_tick,
        }) catch {};
    }
    pub fn movement(self: *const Handler, slot: u16, position: ?Position, rotation: ?Rotation, on_ground: bool) !void {
        return self.invoke(.movement, Arguments.Movement{
            .slot = slot,
            .has_position = @intFromBool(position != null),
            .position = position orelse .{ .x = 0, .y = 0, .z = 0 },
            .has_rotation = @intFromBool(rotation != null),
            .rotation = rotation orelse .{ .yaw = 0, .pitch = 0 },
            .on_ground = @intFromBool(on_ground),
        });
    }
    pub fn player_input(self: *const Handler, slot: u16, shift: bool, sprint: bool) !void {
        return self.invoke(.player_input, Arguments.PlayerInput{
            .slot = slot,
            .shift = @intFromBool(shift),
            .sprint = @intFromBool(sprint),
        });
    }
    pub fn player_sprint(self: *const Handler, slot: u16, sprinting: bool) !void {
        return self.invoke(.player_sprint, Arguments.PlayerSprint{
            .slot = slot,
            .sprinting = @intFromBool(sprinting),
        });
    }
    pub fn player_loaded(self: *const Handler, slot: u16) void {
        self.invoke(.player_loaded, Arguments.Slot{ .slot = slot }) catch {};
    }
    pub fn chat(self: *const Handler, slot: u16, value: []const u8) !void {
        return self.invoke(.chat, Arguments.Bytes{ .slot = slot, .pointer = value.ptr, .length = value.len });
    }
    pub fn command(self: *const Handler, slot: u16, value: []const u8) !void {
        return self.invoke(.command, Arguments.Bytes{ .slot = slot, .pointer = value.ptr, .length = value.len });
    }
    pub fn block_dig(self: *const Handler, slot: u16, status: i32, position: BlockPosition, face: i32, sequence: i32) !void {
        return self.invoke(.block_dig, Arguments.BlockDig{ .slot = slot, .status = status, .position = position, .face = face, .sequence = sequence });
    }
    pub fn block_place(
        self: *const Handler,
        slot: u16,
        position: BlockPosition,
        direction: i32,
        cursor_x: f32,
        cursor_y: f32,
        cursor_z: f32,
        sequence: i32,
    ) !void {
        return self.invoke(.block_place, Arguments.BlockPlace{
            .slot = slot,
            .position = position,
            .direction = direction,
            .cursor_x = cursor_x,
            .cursor_y = cursor_y,
            .cursor_z = cursor_z,
            .sequence = sequence,
        });
    }
    pub fn held_item_slot(self: *const Handler, slot: u16, value: i16) !void {
        return self.invoke(.held_item_slot, Arguments.HeldItemSlot{ .slot = slot, .value = value });
    }
    pub fn arm_animation(self: *const Handler, slot: u16, hand: i32) !void {
        return self.invoke(.arm_animation, Arguments.Integer{ .slot = slot, .value = hand });
    }
    pub fn attack_entity(self: *const Handler, slot: u16, target: i32) !void {
        return self.invoke(.attack_entity, Arguments.Integer{ .slot = slot, .value = target });
    }
    pub fn interact_entity(self: *const Handler, slot: u16, target: i32, hand: i32) !void {
        return self.invoke(.interact_entity, Arguments.EntityInteraction{ .slot = slot, .entity_id = target, .hand = hand });
    }
    pub fn respawn(self: *const Handler, slot: u16) !void {
        return self.invoke(.respawn, Arguments.Slot{ .slot = slot });
    }
    pub fn use_item(self: *const Handler, slot: u16, sequence: i32) !void {
        return self.invoke(.use_item, Arguments.Integer{ .slot = slot, .value = sequence });
    }
    pub fn window_click(self: *const Handler, slot: u16, window_id: i32, state_id: i32, protocol_slot: i16, mouse_button: i8, mode: i32) !void {
        return self.invoke(.window_click, Arguments.WindowClick{ .slot = slot, .window_id = window_id, .state_id = state_id, .protocol_slot = protocol_slot, .mouse_button = mouse_button, .mode = mode });
    }
    pub fn creative_slot(self: *const Handler, slot: u16, inventory_slot: i16, item_id: i32, count: u8) !void {
        return self.invoke(.creative_slot, Arguments.CreativeSlot{
            .slot = slot,
            .inventory_slot = inventory_slot,
            .item_id = item_id,
            .count = count,
        });
    }
    pub fn close_window(self: *const Handler, slot: u16, window_id: i32) !void {
        return self.invoke(.close_window, Arguments.Integer{ .slot = slot, .value = window_id });
    }
    pub fn ignored(self: *const Handler, slot: u16) void {
        self.invoke(.ignored, Arguments.Slot{ .slot = slot }) catch {};
    }
};

/// Decode one version-specialized packet directly into the tick's concrete
/// input handler. No tagged command value or retained decoded packet exists;
/// borrowed fields continue to point into the tick input arena.
pub fn dispatchWith(comptime Protocol: type, comptime Registry: type, payload: []const u8, slot: u16, handler: anytype) !void {
    const Packets = Protocol.play.toServer;
    const header = try Packets.readHeader(payload);
    switch (header.id) {
        Packets.packetId(.teleport_confirm) => try decodeTeleport(Packets, header, slot, handler),
        Packets.packetId(.keep_alive) => try decodeKeepAlive(Packets, header, slot, handler),
        Packets.packetId(.chunk_batch_received) => try decodeChunkBatchReceived(Packets, header, slot, handler),
        Packets.packetId(.position) => try decodePosition(Packets, header, slot, handler),
        Packets.packetId(.position_look) => try decodePositionLook(Packets, header, slot, handler),
        Packets.packetId(.look) => try decodeLook(Packets, header, slot, handler),
        Packets.packetId(.flying) => try decodeFlying(Packets, header, slot, handler),
        Packets.packetId(.player_input) => try decodePlayerInput(Packets, header, slot, handler),
        Packets.packetId(.entity_action) => try decodeEntityAction(Packets, header, slot, handler),
        Packets.packetId(.player_loaded) => try decodePlayerLoaded(Packets, header, slot, handler),
        Packets.packetId(.chat_message) => try decodeChat(Packets, header, slot, handler),
        Packets.packetId(.chat_command) => try decodeCommand(Packets, header, slot, handler),
        Packets.packetId(.chat_command_signed) => try decodeSignedCommand(Packets, header, slot, handler),
        Packets.packetId(.block_dig) => try decodeBlockDig(Packets, header, slot, handler),
        Packets.packetId(.block_place) => try decodeBlockPlace(Packets, header, slot, handler),
        Packets.packetId(.held_item_slot) => try decodeHeldItem(Packets, header, slot, handler),
        Packets.packetId(.arm_animation) => try decodeArmAnimation(Packets, header, slot, handler),
        Packets.packetId(.use_entity) => try decodeUseEntity(Packets, header, slot, handler),
        Packets.packetId(.client_command) => try decodeClientCommand(Packets, header, slot, handler),
        Packets.packetId(.use_item) => try decodeUseItem(Packets, header, slot, handler),
        Packets.packetId(.window_click) => try decodeWindowClick(Packets, header, slot, handler),
        Packets.packetId(.set_creative_slot) => try decodeCreativeSlot(Packets, Registry, header, slot, handler),
        Packets.packetId(.close_window) => try decodeCloseWindow(Packets, header, slot, handler),
        else => handler.ignored(slot),
    }
}

fn decodeTeleport(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.teleport_confirm, header);
    const value, const done = try body.teleportId();
    try done.finish();
    handler.teleport_confirm(slot, value);
}

fn decodeKeepAlive(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.keep_alive, header);
    const value, const done = try body.keepAliveId();
    try done.finish();
    handler.keep_alive_response(slot, value);
}

fn decodeChunkBatchReceived(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.chunk_batch_received, header);
    const chunks_per_tick, const done = try body.chunksPerTick();
    try done.finish();
    handler.chunk_batch_received(slot, chunks_per_tick);
}

fn decodePosition(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.position, header);
    const x, const c2 = try body.x();
    const y, const c3 = try c2.y();
    const z, const c4 = try c3.z();
    const flags, const done = try c4.flags();
    try done.finish();
    try handler.movement(slot, .{ .x = x, .y = y, .z = z }, null, flags.onGround);
}

fn decodePositionLook(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.position_look, header);
    const x, const c2 = try body.x();
    const y, const c3 = try c2.y();
    const z, const c4 = try c3.z();
    const yaw, const c5 = try c4.yaw();
    const pitch, const c6 = try c5.pitch();
    const flags, const done = try c6.flags();
    try done.finish();
    try handler.movement(slot, .{ .x = x, .y = y, .z = z }, .{ .yaw = yaw, .pitch = pitch }, flags.onGround);
}

fn decodeLook(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.look, header);
    const yaw, const c2 = try body.yaw();
    const pitch, const c3 = try c2.pitch();
    const flags, const done = try c3.flags();
    try done.finish();
    try handler.movement(slot, null, .{ .yaw = yaw, .pitch = pitch }, flags.onGround);
}

fn decodeFlying(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.flying, header);
    const flags, const done = try body.flags();
    try done.finish();
    try handler.movement(slot, null, null, flags.onGround);
}

fn decodePlayerInput(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.player_input, header);
    const inputs, const done = try body.inputs();
    try done.finish();
    try handler.player_input(slot, inputs.shift, inputs.sprint);
}

fn decodeEntityAction(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.entity_action, header);
    _, const c2 = try body.entityId();
    const action, const c3 = try c2.actionId();
    _, const done = try c3.jumpBoost();
    try done.finish();
    switch (action) {
        1 => try handler.player_sprint(slot, true),
        2 => try handler.player_sprint(slot, false),
        else => handler.ignored(slot),
    }
}

fn decodePlayerLoaded(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.player_loaded, header);
    try body.finish();
    handler.player_loaded(slot);
}

fn decodeChat(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.chat_message, header);
    const message, const c2 = try body.message();
    _, const c3 = try c2.timestamp();
    _, const c4 = try c3.salt();
    _, const c5 = try c4.signature();
    _, const c6 = try c5.offset();
    _, const c7 = try c6.acknowledged();
    _, const done = try c7.checksum();
    try done.finish();
    try handler.chat(slot, message);
}

fn decodeCommand(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.chat_command, header);
    const command, const done = try body.command();
    try done.finish();
    try handler.command(slot, command);
}

fn decodeSignedCommand(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.chat_command_signed, header);
    const command, const c2 = try body.command();
    _, const c3 = try c2.timestamp();
    _, const c4 = try c3.salt();
    _, const c5 = try c4.argumentSignatures();
    _, const c6 = try c5.messageCount();
    _, const c7 = try c6.acknowledged();
    _, const done = try c7.checksum();
    try done.finish();
    try handler.command(slot, command);
}

fn decodeBlockDig(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.block_dig, header);
    const status, const c2 = try body.status();
    const location, const c3 = try c2.location();
    const face, const c4 = try c3.face();
    const sequence, const done = try c4.sequence();
    try done.finish();
    try handler.block_dig(slot, status, .{ .x = location.x, .y = @intCast(location.y), .z = location.z }, face, sequence);
}

fn decodeBlockPlace(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.block_place, header);
    _, const c2 = try body.hand();
    const location, const c3 = try c2.location();
    const direction, const c4 = try c3.direction();
    const cursor_x, const c5 = try c4.cursorX();
    const cursor_y, const c6 = try c5.cursorY();
    const cursor_z, const c7 = try c6.cursorZ();
    _, const c8 = try c7.insideBlock();
    _, const c9 = try c8.worldBorderHit();
    const sequence, const done = try c9.sequence();
    try done.finish();
    try handler.block_place(slot, .{ .x = location.x, .y = @intCast(location.y), .z = location.z }, direction, cursor_x, cursor_y, cursor_z, sequence);
}

fn decodeHeldItem(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.held_item_slot, header);
    const selected, const done = try body.slotId();
    try done.finish();
    try handler.held_item_slot(slot, selected);
}

fn decodeArmAnimation(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.arm_animation, header);
    const hand, const done = try body.hand();
    try done.finish();
    try handler.arm_animation(slot, hand);
}

fn decodeUseEntity(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.use_entity, header);
    const target, const c2 = try body.target();
    const mouse, const c3 = try c2.mouse();
    _, const c4 = try c3.x();
    _, const c5 = try c4.y();
    _, const c6 = try c5.z();
    const hand_view, const c7 = try c6.hand();
    _, const done = try c7.sneaking();
    try done.finish();
    if (mouse == 1) try handler.attack_entity(slot, target);
    if (mouse == 0) try handler.interact_entity(slot, target, try hand_view.case_0());
    if (mouse == 2) try handler.interact_entity(slot, target, try hand_view.case_2());
}

fn decodeClientCommand(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.client_command, header);
    const action_id, const done = try body.actionId();
    try done.finish();
    if (action_id == 0) try handler.respawn(slot);
}

fn decodeUseItem(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.use_item, header);
    _, const c2 = try body.hand();
    const sequence, const c3 = try c2.sequence();
    _, const done = try c3.rotation();
    try done.finish();
    try handler.use_item(slot, sequence);
}

fn decodeWindowClick(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.window_click, header);
    const window_id, const c2 = try body.windowId();
    const state_id, const c3 = try c2.stateId();
    const protocol_slot, const c4 = try c3.slot();
    const mouse_button, const c5 = try c4.mouseButton();
    const mode, const c6 = try c5.mode();
    _, const c7 = try c6.changedSlots();
    _, const done = try c7.cursorItem();
    try done.finish();
    try handler.window_click(slot, window_id, state_id, protocol_slot, mouse_button, mode);
}

fn decodeCreativeSlot(comptime Packets: type, comptime Registry: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.set_creative_slot, header);
    const inventory_slot, const item_cursor = try body.slot();
    const item, const done = try item_cursor.item();
    try done.finish();
    const count, const value_cursor = try item.itemCount();
    if (count == 0) return handler.creative_slot(slot, inventory_slot, 0, 0);
    if (count < 0 or count > std.math.maxInt(u8)) return error.InvalidCreativeItemCount;
    const value, _ = try value_cursor.anon();
    const present = try value.case_default();
    const wire_item_id, const added_cursor = try present.itemId();
    const added_count, const removed_cursor = try added_cursor.addedComponentCount();
    const removed_count, _ = try removed_cursor.removedComponentCount();
    if (added_count != 0 or removed_count != 0) return error.UnsupportedCreativeItemComponents;
    const canonical_item_id = canonicalItemId(Registry.canonical_item_to_wire, wire_item_id) orelse return error.UnknownCreativeItem;
    try handler.creative_slot(slot, inventory_slot, canonical_item_id, @intCast(count));
}

fn decodeCloseWindow(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.close_window, header);
    const window_id, const done = try body.windowId();
    try done.finish();
    try handler.close_window(slot, window_id);
}

fn canonicalItemId(canonical_to_wire: []const i32, wire_id: i32) ?i32 {
    for (canonical_to_wire, 0..) |candidate, canonical_id|
        if (candidate == wire_id) return @intCast(canonical_id);
    return null;
}
