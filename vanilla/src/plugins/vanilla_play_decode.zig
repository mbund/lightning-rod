const std = @import("std");
const lightning_rod = @import("lightning_rod");

const Input = lightning_rod.core_exchange.Input;
const PacketWriter = lightning_rod.Packets;
const PacketView = lightning_rod.RawPacketView;
const Position = lightning_rod.geometry.Vec3;
const Rotation = lightning_rod.geometry.Rotation;
const BlockPosition = lightning_rod.geometry.BlockPos;

pub const PlayDecode = struct {
    pub const id = "minecraft:play_decode";
    pub const Configuration = struct {};
    pub const Dependencies = struct { packets: *PacketWriter };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayDecode {
        const self = try allocator.create(PlayDecode);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PlayDecode) void {
        for (self.deps.packets.packetViews()) |packet| self.decode(packet);
        self.deps.packets.applyInputs();
    }

    fn decode(self: *PlayDecode, packet: PacketView) void {
        if (packet.phase != .play) return;
        const player = packet.player orelse return;
        var sink = Sink{ .packets = self.deps.packets };
        inline for (lightning_rod.protocol_versions.all) |support| {
            if (packet.protocol == support.protocol_number) {
                const handled = dispatchWith(
                    lightning_rod.protocol_versions.Protocol(support.version),
                    lightning_rod.protocol_versions.Registry(support.version),
                    packet.id,
                    packet.bytes,
                    player,
                    &sink,
                ) catch return;
                if (handled) std.debug.assert(self.deps.packets.claimPacket(packet) == .claimed);
                return;
            }
        }
    }
};

const Sink = struct {
    packets: *PacketWriter,

    fn append(self: *Sink, input: Input) !void {
        if (self.packets.input.append(input) == .full) return error.InputBatchFull;
    }

    fn text(self: *Sink, value: []const u8) !lightning_rod.core_exchange.Text {
        return self.packets.input.copyText(value);
    }

    pub fn teleport_confirm(self: *Sink, player: u16, id: i32) !void {
        try self.append(.{ .teleport_confirm = .{ .player = player, .id = id } });
    }

    pub fn keep_alive_response(self: *Sink, player: u16, id: i64) !void {
        try self.append(.{ .keep_alive_response = .{ .player = player, .id = id } });
    }

    pub fn chunk_batch_received(self: *Sink, player: u16, chunks_per_tick: f32) !void {
        try self.append(.{ .chunk_batch_received = .{ .player = player, .chunks_per_tick = chunks_per_tick } });
    }

    pub fn movement(self: *Sink, player: u16, position: ?Position, rotation: ?Rotation, on_ground: bool) !void {
        if (position) |value| if (!std.math.isFinite(value.x) or !std.math.isFinite(value.y) or !std.math.isFinite(value.z)) return error.InvalidMovement;
        if (rotation) |value| if (!std.math.isFinite(value.yaw) or !std.math.isFinite(value.pitch)) return error.InvalidMovement;
        try self.append(.{ .movement = .{ .player = player, .position = position, .rotation = rotation, .on_ground = on_ground } });
    }

    pub fn player_input(self: *Sink, player: u16, shift: bool, sprint: bool) !void {
        try self.append(.{ .player_input = .{ .player = player, .shift = shift, .sprint = sprint } });
    }

    pub fn player_sprint(self: *Sink, player: u16, sprinting: bool) !void {
        try self.append(.{ .sprint = .{ .player = player, .sprinting = sprinting } });
    }

    pub fn player_loaded(self: *Sink, player: u16) !void {
        try self.append(.{ .player_loaded = .{ .player = player } });
    }

    pub fn chat(self: *Sink, player: u16, value: []const u8) !void {
        try self.append(.{ .chat = .{ .player = player, .text = try self.text(value) } });
    }

    pub fn command(self: *Sink, player: u16, value: []const u8) !void {
        try self.append(.{ .command = .{ .player = player, .text = try self.text(value) } });
    }

    pub fn block_dig(self: *Sink, player: u16, status: i32, position: BlockPosition, face: i32, sequence: i32) !void {
        try self.append(.{ .dig = .{ .player = player, .status = status, .position = position, .face = face, .sequence = sequence } });
    }

    pub fn block_place(self: *Sink, player: u16, position: BlockPosition, face: i32, x: f32, y: f32, z: f32, sequence: i32) !void {
        const world = self.packets.deps.players.records[player].world;
        try self.append(.{ .place = .{ .world = world, .player = player, .kind = .use_item_on, .position = position, .against_position = position, .face = face, .cursor = .{ .x = x, .y = y, .z = z }, .sequence = sequence } });
    }

    pub fn held_item_slot(self: *Sink, player: u16, selected: i16) !void {
        try self.append(.{ .held_item = .{ .player = player, .selected = selected } });
    }

    pub fn arm_animation(self: *Sink, player: u16, hand: i32) !void {
        try self.append(.{ .arm_animation = .{ .player = player, .hand = hand } });
    }

    pub fn attack_entity(self: *Sink, player: u16, entity_id: i32) !void {
        try self.append(.{ .attack_entity = .{ .player = player, .entity_id = entity_id } });
    }

    pub fn interact_entity(self: *Sink, player: u16, entity_id: i32, hand: i32) !void {
        try self.append(.{ .interact_entity = .{ .player = player, .entity_id = entity_id, .hand = hand } });
    }

    pub fn respawn(self: *Sink, player: u16) !void {
        try self.append(.{ .respawn = .{ .player = player } });
    }

    pub fn use_item(self: *Sink, player: u16, hand: i32, sequence: i32, rotation: Rotation) !void {
        try self.append(.{ .use_item = .{ .player = player, .hand = hand, .sequence = sequence, .rotation = rotation } });
    }

    pub fn window_click(self: *Sink, player: u16, window_id: i32, state_id: i32, protocol_slot: i16, mouse_button: i8, mode: i32) !void {
        try self.append(.{ .window_click = .{ .player = player, .window_id = window_id, .state_id = state_id, .protocol_slot = protocol_slot, .mouse_button = mouse_button, .mode = mode } });
    }

    pub fn creative_slot(self: *Sink, player: u16, inventory_slot: i16, item_id: i32, count: u8) !void {
        try self.append(.{ .creative_slot = .{ .player = player, .inventory_slot = inventory_slot, .item_id = item_id, .count = count } });
    }

    pub fn close_window(self: *Sink, player: u16, window_id: i32) !void {
        try self.append(.{ .close_window = .{ .player = player, .window_id = window_id } });
    }

    pub fn ignored(_: *Sink, _: u16) void {}
};

pub fn dispatchWith(comptime Protocol: type, comptime Registry: type, id: i32, body: []const u8, slot: u16, handler: anytype) !bool {
    const Packets = Protocol.play.toServer;
    const header = Packets.Header{ .id = id, .body = body };
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
        else => {
            if (!knownPacket(Packets, id)) return false;
            handler.ignored(slot);
        },
    }
    return true;
}

fn knownPacket(comptime Packets: type, id: i32) bool {
    inline for (@typeInfo(Packets.PacketName).@"enum".fields) |field| {
        const name: Packets.PacketName = @enumFromInt(field.value);
        if (id == Packets.packetId(name)) return true;
    }
    return false;
}

fn decodeTeleport(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.teleport_confirm, header);
    const value, const done = try body.teleportId();
    try done.finish();
    try handler.teleport_confirm(slot, value);
}

fn decodeKeepAlive(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.keep_alive, header);
    const value, const done = try body.keepAliveId();
    try done.finish();
    try handler.keep_alive_response(slot, value);
}

fn decodeChunkBatchReceived(comptime Packets: type, header: anytype, slot: u16, handler: anytype) !void {
    const body = try Packets.readBody(.chunk_batch_received, header);
    const chunks_per_tick, const done = try body.chunksPerTick();
    try done.finish();
    try handler.chunk_batch_received(slot, chunks_per_tick);
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
    try handler.player_loaded(slot);
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
    const hand, const c2 = try body.hand();
    const sequence, const c3 = try c2.sequence();
    const rotation, const done = try c3.rotation();
    const yaw, const rotation_y = try rotation.x();
    const pitch, const rotation_done = try rotation_y.y();
    try rotation_done.finish();
    try done.finish();
    try handler.use_item(slot, hand, sequence, .{ .yaw = yaw, .pitch = pitch });
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
