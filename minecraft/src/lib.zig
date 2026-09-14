const std = @import("std");
const protocols = @import("protocols");

pub const supported_protocols = [_]i32{ 771, 772 };

pub fn supports(protocol_number: i32) bool {
    for (supported_protocols) |candidate| if (candidate == protocol_number) return true;
    return false;
}

pub const Position = struct {
    x: f64,
    y: f64,
    z: f64,
};

pub const BlockPosition = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const DigAction = enum(i32) { start, cancel, finish, drop_stack, drop_item, release_use, swap_hands };

pub const Dig = struct {
    action: DigAction,
    position: BlockPosition,
    face: i8,
    sequence: i32,
};

pub const Place = struct {
    hand: i32,
    position: BlockPosition,
    face: i32,
    cursor: [3]f32,
    inside: bool,
    border: bool,
    sequence: i32,
};

pub const Rotation = struct {
    yaw: f32,
    pitch: f32,
};

pub const GameMode = enum(i8) { survival, creative, adventure, spectator };

pub const Movement = struct {
    position: ?Position = null,
    rotation: ?Rotation = null,
    on_ground: bool,
    horizontal_collision: bool,
};

pub const EntityFlags = packed struct(u8) {
    burning: bool = false,
    sneaking: bool = false,
    unused: bool = false,
    sprinting: bool = false,
    swimming: bool = false,
    invisible: bool = false,
    glowing: bool = false,
    gliding: bool = false,
};

pub const Action = enum(i32) {
    leave_bed,
    start_sprinting,
    stop_sprinting,
    start_horse_jump,
    stop_horse_jump,
    open_vehicle_inventory,
    start_gliding,
};

pub const EntityAction = struct {
    entity_id: i32,
    action: Action,
    jump_boost: i32,
};

pub const Chat = struct {
    message: []const u8,
    signed_tail: []const u8,
};

pub const InventoryClick = struct {
    window_id: i32,
    state_id: i32,
    slot: i16,
    button: i8,
    mode: i32,
    changed_slots: []const u8,
    cursor: []const u8,
};

pub const CreativeSlot = struct {
    slot: i16,
    item: []const u8,
};

pub const RawPacket = struct {
    packet_id: i32,
    payload: []const u8,
};

pub const Input = union(enum) {
    teleport_confirm: i32,
    dig: Dig,
    place: Place,
    held_slot: i16,
    swing: i32,
    player_loaded,
    respawn,
    movement: Movement,
    chat: Chat,
    command: []const u8,
    completion: struct {
        id: i32,
        text: []const u8,
    },
    entity_action: EntityAction,
    controls: struct {
        forward: bool,
        backward: bool,
        left: bool,
        right: bool,
        jump: bool,
        shift: bool,
        sprint: bool,
    },
    inventory_click: InventoryClick,
    creative_slot: CreativeSlot,
    raw_unknown: RawPacket,
};

pub const Login = struct {
    entity_id: i32,
    world_names: []const []const u8,
    dimension_type: i32,
    world_name: []const u8,
    max_players: i32,
    view_distance: i32,
    simulation_distance: i32,
    hashed_seed: i64,
    gamemode: i8,
    sea_level: i32,
};

pub const Respawn = struct {
    dimension_type: i32,
    world_name: []const u8,
    hashed_seed: i64,
    gamemode: i8,
    sea_level: i32,
    keep_data: u8 = 0,
};

pub const Teleport = struct {
    id: i32,
    position: Position,
    velocity: Position,
    rotation: Rotation,
};

pub const Health = struct {
    health: f32,
    food: i32,
    saturation: f32,
};

pub const PlayerInfo = struct {
    uuid: u128,
    name: []const u8,
    gamemode: i32,
};

pub const Spawn = struct {
    entity_id: i32,
    uuid: u128,
    entity_type: i32,
    position: Position,
    pitch: i8,
    yaw: i8,
    head_yaw: i8,
    data: i32,
    velocity_x: i16,
    velocity_y: i16,
    velocity_z: i16,
};

pub const EntityMove = struct {
    entity_id: i32,
    dx: i16,
    dy: i16,
    dz: i16,
    yaw: i8,
    pitch: i8,
    on_ground: bool,
};

pub const Slot = struct {
    window_id: i32,
    state_id: i32,
    slot: i16,
    item: []const u8,
};

pub const Contents = struct {
    window_id: i32,
    state_id: i32,
    slots: []const u8,
    cursor: []const u8,
};

pub const Output = union(enum) {
    block: struct {
        position: BlockPosition,
        state: i32,
    },
    block_ack: i32,
    block_progress: struct {
        entity: i32,
        position: BlockPosition,
        stage: i8,
    },
    animation: struct {
        entity: i32,
        animation: u8,
    },
    world_event: struct {
        event: i32,
        position: BlockPosition,
        data: i32,
    },
    collect: struct {
        item: i32,
        player: i32,
        count: i32,
    },
    brand: []const u8,
    login: Login,
    respawn: Respawn,
    teleport: Teleport,
    health: Health,
    player_add: PlayerInfo,
    player_remove: u128,
    spawn: Spawn,
    entity_move: EntityMove,
    entity_teleport: struct {
        entity_id: i32,
        position: Position,
        rotation: Rotation,
        velocity: Position = .{ .x = 0, .y = 0, .z = 0 },
        on_ground: bool,
    },
    entity_remove: i32,
    entity_head_rotation: struct {
        entity_id: i32,
        yaw: i8,
    },
    entity_metadata: struct {
        entity_id: i32,
        entries: []const u8,
    },
    chat: []const u8,
    contents: Contents,
    slot: Slot,
    disconnect: []const u8,
};

/// Bind this adapter to one generated wire module. Both protocol 771 and 772 use this shared Play
/// packet catalogue. Callers select their registry before constructing game values.
pub fn Adapter(comptime Wire: type) type {
    return struct {
        const Packets = Wire.play.toServer;

        pub fn decode(protocol_number: i32, payload: []const u8) !Input {
            if (!supports(protocol_number)) return error.UnsupportedProtocol;

            const header = try Packets.readHeader(payload);
            if (header.id == Packets.packetId(.teleport_confirm)) {
                const id, const done = try (try Packets.readBody(.teleport_confirm, header)).teleportId();
                try done.finish();
                return .{ .teleport_confirm = id };
            }

            if (header.id == Packets.packetId(.block_dig)) {
                const action, const a = try (try Packets.readBody(.block_dig, header)).status();
                const position, const b = try a.location();
                const face, const c = try b.face();
                const sequence, const done = try c.sequence();
                try done.finish();
                return .{ .dig = .{
                    .action = std.enums.fromInt(DigAction, action) orelse return error.InvalidDigAction,
                    .position = .{ .x = position.x, .y = position.y, .z = position.z },
                    .face = face,
                    .sequence = sequence,
                } };
            }

            if (header.id == Packets.packetId(.block_place)) {
                const hand, const a = try (try Packets.readBody(.block_place, header)).hand();
                const position, const b = try a.location();
                const face, const c = try b.direction();
                const x, const d = try c.cursorX();
                const y, const e = try d.cursorY();
                const z, const f = try e.cursorZ();
                const inside, const g = try f.insideBlock();
                const border, const h = try g.worldBorderHit();
                const sequence, const done = try h.sequence();
                try done.finish();
                return .{ .place = .{
                    .hand = hand,
                    .position = .{ .x = position.x, .y = position.y, .z = position.z },
                    .face = face,
                    .cursor = .{ x, y, z },
                    .inside = inside,
                    .border = border,
                    .sequence = sequence,
                } };
            }

            if (header.id == Packets.packetId(.held_item_slot)) {
                const slot, const done = try (try Packets.readBody(.held_item_slot, header)).slotId();
                try done.finish();
                return .{ .held_slot = slot };
            }

            if (header.id == Packets.packetId(.arm_animation)) {
                const hand, const done = try (try Packets.readBody(.arm_animation, header)).hand();
                try done.finish();
                return .{ .swing = hand };
            }

            if (header.id == Packets.packetId(.client_command)) {
                const action, const done = try (try Packets.readBody(.client_command, header)).actionId();
                try done.finish();
                if (action == 0) return .respawn;
                return .{ .raw_unknown = .{ .packet_id = header.id, .payload = header.body } };
            }

            if (header.id == Packets.packetId(.player_loaded)) {
                try (try Packets.readBody(.player_loaded, header)).finish();
                return .player_loaded;
            }

            if (header.id == Packets.packetId(.position)) return .{ .movement = try movementPosition(try Packets.readBody(.position, header)) };

            if (header.id == Packets.packetId(.position_look))
                return .{ .movement = try movementPositionLook(try Packets.readBody(.position_look, header)) };

            if (header.id == Packets.packetId(.look)) return .{ .movement = try movementLook(try Packets.readBody(.look, header)) };

            if (header.id == Packets.packetId(.flying)) return .{ .movement = try movementGround(try Packets.readBody(.flying, header)) };

            if (header.id == Packets.packetId(.chat_message)) return .{ .chat = try chat(try Packets.readBody(.chat_message, header)) };

            if (header.id == Packets.packetId(.chat_command)) return .{ .command = try command(try Packets.readBody(.chat_command, header)) };

            if (header.id == Packets.packetId(.tab_complete)) {
                const id, const a = try (try Packets.readBody(.tab_complete, header)).transactionId();
                const text, const done = try a.text();
                try done.finish();
                if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidCommand;
                return .{ .completion = .{ .id = id, .text = text } };
            }

            if (header.id == Packets.packetId(.entity_action))
                return .{ .entity_action = try entityAction(try Packets.readBody(.entity_action, header)) };

            if (header.id == Packets.packetId(.player_input)) {
                const inputs, const done = try (try Packets.readBody(.player_input, header)).inputs();
                try done.finish();
                return .{ .controls = .{
                    .forward = inputs.forward,
                    .backward = inputs.backward,
                    .left = inputs.left,
                    .right = inputs.right,
                    .jump = inputs.jump,
                    .shift = inputs.shift,
                    .sprint = inputs.sprint,
                } };
            }

            if (header.id == Packets.packetId(.window_click)) return .{ .inventory_click = try click(try Packets.readBody(.window_click, header)) };

            if (header.id == Packets.packetId(.set_creative_slot))
                return .{ .creative_slot = try creative(try Packets.readBody(.set_creative_slot, header)) };

            return .{ .raw_unknown = .{ .packet_id = header.id, .payload = header.body } };
        }

        fn movementPosition(body: Packets.PacketBody(.position)) !Movement {
            const x, const after_x = try body.x();
            const y, const after_y = try after_x.y();
            const z, const after_z = try after_y.z();
            const flags, const done = try after_z.flags();
            try done.finish();
            return .{
                .position = .{ .x = x, .y = y, .z = z },
                .on_ground = flags.onGround,
                .horizontal_collision = flags.hasHorizontalCollision,
            };
        }

        fn movementPositionLook(body: Packets.PacketBody(.position_look)) !Movement {
            const x, const after_x = try body.x();
            const y, const after_y = try after_x.y();
            const z, const after_z = try after_y.z();
            const yaw, const after_yaw = try after_z.yaw();
            const pitch, const after_pitch = try after_yaw.pitch();
            const flags, const done = try after_pitch.flags();
            try done.finish();
            return .{
                .position = .{ .x = x, .y = y, .z = z },
                .rotation = .{ .yaw = yaw, .pitch = pitch },
                .on_ground = flags.onGround,
                .horizontal_collision = flags.hasHorizontalCollision,
            };
        }

        fn movementLook(body: Packets.PacketBody(.look)) !Movement {
            const yaw, const after_yaw = try body.yaw();
            const pitch, const after_pitch = try after_yaw.pitch();
            const flags, const done = try after_pitch.flags();
            try done.finish();
            return .{
                .rotation = .{ .yaw = yaw, .pitch = pitch },
                .on_ground = flags.onGround,
                .horizontal_collision = flags.hasHorizontalCollision,
            };
        }

        fn movementGround(body: Packets.PacketBody(.flying)) !Movement {
            const flags, const done = try body.flags();
            try done.finish();
            return .{ .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision };
        }

        fn chat(body: Packets.PacketBody(.chat_message)) !Chat {
            const message, const next = try body.message();
            return .{ .message = message, .signed_tail = next._cursor.rest };
        }

        fn command(body: Packets.PacketBody(.chat_command)) ![]const u8 {
            const value, const next = try body.command();
            try next.finish();
            return value;
        }

        fn entityAction(body: Packets.PacketBody(.entity_action)) !EntityAction {
            const id, const a = try body.entityId();
            const action, const b = try a.actionId();
            const boost, const done = try b.jumpBoost();
            try done.finish();
            return .{ .entity_id = id, .action = std.enums.fromInt(Action, action) orelse return error.InvalidAction, .jump_boost = boost };
        }

        fn click(body: Packets.PacketBody(.window_click)) !InventoryClick {
            const window, const a = try body.windowId();
            const state, const b = try a.stateId();
            const slot, const c = try b.slot();
            const button, const d = try c.mouseButton();
            const mode, const e = try d.mode();
            var changed_slots = try e.changedSlots();
            const changed, const f = try changed_slots.encoded();
            var cursor_item = try f.cursorItem();
            const cursor, const done = try cursor_item.encoded();
            try done.finish();
            return .{
                .window_id = window,
                .state_id = state,
                .slot = slot,
                .button = button,
                .mode = mode,
                .changed_slots = changed,
                .cursor = cursor,
            };
        }

        fn creative(body: Packets.PacketBody(.set_creative_slot)) !CreativeSlot {
            const slot, const next = try body.slot();
            var field = try next.item();
            const item, const done = try field.encoded();
            try done.finish();
            return .{ .slot = slot, .item = item };
        }
    };
}

pub fn Generated(comptime Wire: type) type {
    return struct {
        const Client = Wire.play.toClient;

        pub fn write(protocol_number: i32, buffer: []u8, output: Output) ![]u8 {
            if (!supports(protocol_number)) return error.UnsupportedProtocol;
            return switch (output) {
                .block => |value| blk: {
                    const a = try Client.write(buffer).block_change();
                    const b = try a.location(.{
                        .x = @intCast(value.position.x),
                        .y = @intCast(value.position.y),
                        .z = @intCast(value.position.z),
                    });
                    break :blk (try b.type(value.state)).finish();
                },
                .block_ack => |sequence| (try (try Client.write(buffer).acknowledge_player_digging()).sequenceId(sequence)).finish(),
                .block_progress => |value| blk: {
                    const a = try (try Client.write(buffer).block_break_animation()).entityId(value.entity);
                    const b = try a.location(.{
                        .x = @intCast(value.position.x),
                        .y = @intCast(value.position.y),
                        .z = @intCast(value.position.z),
                    });
                    break :blk (try b.destroyStage(value.stage)).finish();
                },
                .animation => |value| (try (try (try Client.write(buffer).animation()).entityId(value.entity)).animation(value.animation)).finish(),
                .world_event => |value| blk: {
                    const a = try (try Client.write(buffer).world_event()).effectId(value.event);
                    const b = try a.location(.{
                        .x = @intCast(value.position.x),
                        .y = @intCast(value.position.y),
                        .z = @intCast(value.position.z),
                    });
                    break :blk (try (try b.data(value.data)).global(false)).finish();
                },
                .collect => |value| (try (try (try (try Client.write(buffer).collect()).collectedEntityId(value.item)).collectorEntityId(value.player)).pickupItemCount(value.count)).finish(),
                .brand => |name| blk: {
                    const a = try protocols.support.write_varint(buffer, Client.packetId(.custom_payload));
                    const b = try protocols.support.write_pstring(a, "minecraft:brand", i32);
                    const rest = try protocols.support.write_pstring(b, name, i32);
                    break :blk buffer[0 .. buffer.len - rest.len];
                },
                .login => |value| login(buffer, value),
                .respawn => |value| respawn(buffer, value),
                .player_add => |value| playerAdd(buffer, value),
                .player_remove => |value| playerRemove(buffer, value),
                .spawn => |value| spawn(buffer, value),
                .health => |value| health(buffer, value),
                .teleport => |value| teleport(buffer, value),
                .entity_move => |value| entityMove(buffer, value),
                .entity_teleport => |value| blk: {
                    const a = try Client.write(buffer).sync_entity_position();
                    const b = try a.entityId(value.entity_id);
                    const c = try b.x(value.position.x);
                    const d = try c.y(value.position.y);
                    const e = try d.z(value.position.z);
                    const f = try e.dx(value.velocity.x);
                    const g = try f.dy(value.velocity.y);
                    const h = try g.dz(value.velocity.z);
                    const i = try h.yaw(value.rotation.yaw);
                    const j = try i.pitch(value.rotation.pitch);
                    break :blk (try j.onGround(value.on_ground)).finish();
                },
                .entity_remove => |id| blk: {
                    const a = try Client.write(buffer).entity_destroy();
                    const b = try a.entityIds(1);
                    const c = try b.element(id);
                    break :blk (try c.finish()).finish();
                },
                .entity_head_rotation => |value| headRotation(buffer, value.entity_id, value.yaw),
                .entity_metadata => |value| metadata(buffer, value.entity_id, value.entries),
                .chat => |value| chat(buffer, value),
                .contents => |value| contents(buffer, value),
                .slot => |value| slot(buffer, value),
                .disconnect => |value| disconnect(buffer, value),
            };
        }

        pub fn login(buffer: []u8, value: Login) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.login();
            const b = try a.entityId(value.entity_id);
            const c = try b.isHardcore(false);
            var worlds = try c.worldNames(value.world_names.len);

            for (value.world_names) |name| worlds = try worlds.element(name);
            const d = try worlds.finish();
            const e = try d.maxPlayers(value.max_players);
            const f = try e.viewDistance(value.view_distance);
            const g = try f.simulationDistance(value.simulation_distance);
            const h = try g.reducedDebugInfo(false);
            const i = try h.enableRespawnScreen(true);
            const j = try i.doLimitedCrafting(false);
            var world_state = try j.worldState();
            const k = try world_state.begin();
            const l = try k.dimension(value.dimension_type);
            const m = try l.name(value.world_name);
            const n = try m.hashedSeed(value.hashed_seed);
            const o = try n.gamemode(value.gamemode);
            const p = try o.previousGamemode(255);
            const q = try p.isDebug(false);
            const r = try q.isFlat(false);
            var death = try r.death();
            const s = try death.begin();
            const t = try death.advance(try s.none());
            const u = try t.portalCooldown(0);
            const v = try u.seaLevel(value.sea_level);
            const world_done = try world_state.advance(v);
            return (try world_done.enforcesSecureChat(false)).finish();
        }

        pub fn respawn(buffer: []u8, value: Respawn) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.respawn();
            var world_state = try a.worldState();
            const b = try world_state.begin();
            const c = try b.dimension(value.dimension_type);
            const d = try c.name(value.world_name);
            const e = try d.hashedSeed(value.hashed_seed);
            const f = try e.gamemode(value.gamemode);
            const g = try f.previousGamemode(255);
            const h = try g.isDebug(false);
            const i = try h.isFlat(false);
            var death = try i.death();
            const j = try death.advance(try (try death.begin()).none());
            const k = try j.portalCooldown(0);
            const l = try k.seaLevel(value.sea_level);
            const world_done = try world_state.advance(l);
            return (try world_done.copyMetadata(value.keep_data)).finish();
        }

        pub fn playerAdd(buffer: []u8, value: PlayerInfo) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.player_info();
            const b = try a.action(.{
                .add_player = true,
                .initialize_chat = true,
                .update_game_mode = true,
                .update_listed = true,
                .update_latency = true,
                .update_display_name = true,
                .update_hat = true,
                .update_list_order = true,
            });
            var entries = try b.data(1);
            const c = (try entries.next()).?;
            var player = try (try c.uuid(value.uuid)).player();
            var player_present = try (try player.begin()).case_true();
            const e = try player_present.begin();
            const f = try (try e.name(value.name)).properties(0);
            const g = try player.advance(try player_present.advance(try f.finish()));
            var chat_session = try g.chatSession();
            var chat_present = try (try chat_session.begin()).case_true();
            const i = try chat_session.advance(try chat_present.advance(try (try chat_present.begin()).none()));
            var gamemode = try i.gamemode();
            const j = try gamemode.advance(try (try gamemode.begin()).case_true(value.gamemode));
            var listed = try j.listed();
            const k = try listed.advance(try (try listed.begin()).case_true(1));
            var latency = try k.latency();
            const l = try latency.advance(try (try latency.begin()).case_true(0));
            var display = try l.displayName();
            var display_present = try (try display.begin()).case_true();
            const m = try display.advance(try display_present.advance(try (try display_present.begin()).none()));
            var priority = try m.listPriority();
            const o = try priority.advance(try (try priority.begin()).case_true(0));
            var hat = try o.showHat();
            try entries.advance(try hat.advance(try (try hat.begin()).case_true(true)));
            return (try entries.finish()).finish();
        }

        pub fn playerRemove(buffer: []u8, uuid: u128) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.player_remove();
            return (try (try (try a.players(1)).element(uuid)).finish()).finish();
        }

        pub fn spawn(buffer: []u8, value: Spawn) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.spawn_entity();
            const b = try a.entityId(value.entity_id);
            const c = try b.objectUUID(value.uuid);
            const d = try c.type(value.entity_type);
            const e = try d.x(value.position.x);
            const f = try e.y(value.position.y);
            const g = try f.z(value.position.z);
            const h = try g.pitch(value.pitch);
            const i = try h.yaw(value.yaw);
            const j = try i.headPitch(value.head_yaw);
            const k = try j.objectData(value.data);
            const l = try k.velocityX(value.velocity_x);
            const m = try l.velocityY(value.velocity_y);
            return (try m.velocityZ(value.velocity_z)).finish();
        }

        pub fn health(buffer: []u8, value: Health) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.update_health();
            const b = try a.health(value.health);
            const c = try b.food(value.food);
            return (try c.foodSaturation(value.saturation)).finish();
        }

        pub fn teleport(buffer: []u8, value: Teleport) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.position();
            const b = try a.teleportId(value.id);
            const c = try b.x(value.position.x);
            const d = try c.y(value.position.y);
            const e = try d.z(value.position.z);
            const f = try e.dx(value.velocity.x);
            const g = try f.dy(value.velocity.y);
            const h = try g.dz(value.velocity.z);
            const i = try h.yaw(value.rotation.yaw);
            const j = try i.pitch(value.rotation.pitch);
            return (try j.flags(.{})).finish();
        }

        pub fn entityMove(buffer: []u8, value: EntityMove) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.entity_move_look();
            const b = try a.entityId(value.entity_id);
            const c = try b.dX(value.dx);
            const d = try c.dY(value.dy);
            const e = try d.dZ(value.dz);
            const f = try e.yaw(value.yaw);
            const g = try f.pitch(value.pitch);
            return (try g.onGround(value.on_ground)).finish();
        }

        pub fn headRotation(buffer: []u8, entity_id: i32, yaw: i8) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.entity_head_rotation();
            const b = try a.entityId(entity_id);
            return (try b.headYaw(yaw)).finish();
        }

        pub fn metadata(buffer: []u8, entity_id: i32, entries: []const u8) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.entity_metadata();
            const b = try a.entityId(entity_id);
            return append(buffer, b._cursor.rest, entries);
        }

        pub fn chat(buffer: []u8, payload: []const u8) ![]u8 {
            const packet = Client.write(buffer);
            const body = try packet.system_chat();
            return append(buffer, body._cursor.rest, payload);
        }

        pub fn contents(buffer: []u8, value: Contents) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.window_items();
            const b = try a.windowId(value.window_id);
            const c = try b.stateId(value.state_id);
            const rest = c._cursor.rest;
            if (rest.len < value.slots.len + value.cursor.len) return error.EndOfStream;
            @memcpy(rest[0..value.slots.len], value.slots);
            @memcpy(rest[value.slots.len .. value.slots.len + value.cursor.len], value.cursor);
            return buffer[0 .. buffer.len - rest.len + value.slots.len + value.cursor.len];
        }

        pub fn slot(buffer: []u8, value: Slot) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.set_slot();
            const b = try a.windowId(value.window_id);
            const c = try b.stateId(value.state_id);
            const d = try c.slot(value.slot);
            return append(buffer, d._cursor.rest, value.item);
        }

        pub fn disconnect(buffer: []u8, component: []const u8) ![]u8 {
            const packet = Client.write(buffer);
            const a = try packet.kick_disconnect();
            return (try a.reason(component)).finish();
        }

        fn append(buffer: []u8, rest: []u8, bytes: []const u8) ![]u8 {
            if (rest.len < bytes.len) return error.EndOfStream;
            @memcpy(rest[0..bytes.len], bytes);
            return buffer[0 .. buffer.len - rest.len + bytes.len];
        }
    };
}

comptime {
    _ = protocols.wire;
}
