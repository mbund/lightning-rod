const std = @import("std");
const protocol_catalog = @import("protocol_catalog");
const protocol_support = @import("protocol_support");
const command_spec = @import("commands.zig");
const protocol_values = @import("protocol_values.zig");
const light_projection = @import("light_projection.zig");
const world_dimensions = @import("world/dimensions.zig");
const dimension_api = @import("world/dimension_api.zig");

pub const Version = protocol_catalog.Version;

pub const Support = protocol_catalog.Support;

pub fn support(comptime selected: Version) Support {
    return protocol_catalog.support[@intFromEnum(selected)];
}

pub const all = protocol_catalog.support;
pub const minecraft_names = protocol_catalog.minecraft_names;

pub const Release = enum { v1_21_6, v1_21_7, v1_21_8 };
pub const minimum_release: Release = @enumFromInt(protocol_catalog.minimum_release);

pub fn from(comptime minimum: Release) [all.len - releaseStart(minimum)]Support {
    const start = comptime releaseStart(minimum);
    var result: [all.len - start]Support = undefined;
    inline for (&result, start..) |*entry, index| entry.* = all[index];
    return result;
}

fn releaseStart(comptime release: Release) usize {
    const name = switch (release) {
        .v1_21_6 => "1.21.6",
        .v1_21_7 => "1.21.7",
        .v1_21_8 => "1.21.8",
    };
    const version = comptime protocol_catalog.fromMinecraftName(name);
    if (version == null) @compileError("the requested Minecraft baseline was not compiled into this binary");
    return @intFromEnum(version.?);
}

pub fn supportsRelease(comptime selected: anytype, comptime release: Release) bool {
    if (@intFromEnum(release) < protocol_catalog.minimum_release) return false;
    const index: usize = if (release == .v1_21_6) 0 else all.len - 1;
    const required = all[index].version;
    inline for (selected) |entry| if (entry.version == required) return true;
    return false;
}

pub fn selectVersions(comptime requested_names: anytype) [requested_names.len]Support {
    var result: [requested_names.len]Support = undefined;
    inline for (requested_names, 0..) |name, index| {
        const selected = protocol_catalog.fromMinecraftName(name) orelse
            @compileError("unknown Minecraft protocol version '" ++ name ++ "'");
        result[index] = support(selected);
    }
    comptime validateSupport(result);
    return result;
}

pub fn numbers(comptime protocols: anytype) [protocols.len]i32 {
    comptime validateSupport(protocols);
    var result: [protocols.len]i32 = undefined;
    inline for (protocols, 0..) |plugin, index|
        result[index] = plugin.protocol_number;
    return result;
}

pub fn supportsNumber(comptime protocols: anytype, protocol_number: i32) bool {
    comptime validateSupport(protocols);
    inline for (protocols) |plugin|
        if (plugin.protocol_number == protocol_number) return true;
    return false;
}

pub fn defaultNumber(comptime protocols: anytype) i32 {
    comptime validateSupport(protocols);
    inline for (protocols) |plugin| {
        if (plugin.version == default) return plugin.protocol_number;
    }
    return protocols[0].protocol_number;
}

fn validateSupport(comptime protocols: anytype) void {
    const info = @typeInfo(@TypeOf(protocols));
    if (info != .array or info.array.child != Support)
        @compileError("configured protocol support must be an array of protocol_versions.Support");
    if (protocols.len == 0)
        @compileError("configured protocol support must contain at least one protocol plugin");
    inline for (protocols, 0..) |plugin, index| {
        inline for (0..index) |previous_index| {
            const previous = protocols[previous_index];
            if (std.mem.eql(u8, plugin.id, previous.id))
                @compileError("duplicate protocol plugin id '" ++ plugin.id ++ "'");
            if (plugin.protocol_number == previous.protocol_number)
                @compileError("duplicate protocol number in configured protocol support");
        }
    }
}

pub const Descriptor = struct {
    version: Version,
    protocol_number: i32,
    minecraft_name: []const u8,
    status_name: []const u8,
    canonical_registry: []const u8,
};

pub const supported = descriptors();

fn descriptors() [protocol_catalog.entries.len]Descriptor {
    var result: [protocol_catalog.entries.len]Descriptor = undefined;
    inline for (protocol_catalog.entries, 0..) |Entry, index| result[index] = .{
        .version = Entry.version,
        .protocol_number = Entry.protocol_number,
        .minecraft_name = Entry.minecraft_name,
        .status_name = Entry.status_name,
        .canonical_registry = protocol_catalog.entries[@intFromEnum(protocol_catalog.canonical)].minecraft_name,
    };
    return result;
}

pub fn descriptor(version: Version) *const Descriptor {
    return &supported[@intFromEnum(version)];
}

test "compiled protocol range contains exactly its configured releases" {
    try std.testing.expectEqual(
        @as(usize, 2) - @as(usize, protocol_catalog.minimum_release),
        all.len,
    );
    try std.testing.expectEqual(
        protocol_catalog.minimum_release != 0,
        protocol_catalog.fromMinecraftName("1.21.6") == null,
    );
    try std.testing.expect(protocol_catalog.fromMinecraftName("1.21.7") != null);
    try std.testing.expect(protocol_catalog.fromMinecraftName("1.21.8") != null);
    try std.testing.expect(supportsRelease(all, @enumFromInt(protocol_catalog.minimum_release)));
    try std.testing.expect(supportsRelease(all, .v1_21_8));
    try std.testing.expectEqual(@as(usize, 1), from(.v1_21_7).len);
    try std.testing.expectEqual(@as(usize, 1), from(.v1_21_8).len);
}

pub const default = protocol_catalog.default;

pub const Handshake = struct {
    protocol_number: i32,
    intent: i32,
};

pub fn supports(protocol_number: i32) bool {
    for (supported) |entry|
        if (entry.protocol_number == protocol_number) return true;
    return false;
}

pub fn decodeHandshake(payload: []const u8) !Handshake {
    const packet = Protocol(default).handshaking.toServer.read(payload);
    return switch (try packet.name()) {
        .set_protocol => |body| result: {
            const version, const host_cursor = try body.protocolVersion();
            _, const port_cursor = try host_cursor.serverHost();
            _, const intent_cursor = try port_cursor.serverPort();
            const intent, const done = try intent_cursor.nextState();
            try done.finish();
            break :result .{ .protocol_number = version, .intent = intent };
        },
        else => error.UnexpectedPacket,
    };
}

fn writeTextComponent(buffer: []u8, text: []const u8) ![]const u8 {
    if (text.len > std.math.maxInt(u16)) return error.TextComponentTooLong;
    var rest = try protocol_support.write_u8(buffer, 10);
    rest = try protocol_support.write_u8(rest, 8);
    rest = try protocol_support.write_u16(rest, 4);
    rest = try protocol_support.write_bytes(rest, "text");
    rest = try protocol_support.write_u16(rest, @intCast(text.len));
    rest = try protocol_support.write_bytes(rest, text);
    rest = try protocol_support.write_u8(rest, 0);
    return buffer[0 .. buffer.len - rest.len];
}

pub fn PlayCodec(comptime ProtocolModule: type, comptime _: type) type {
    return struct {
        pub fn decodeStatus(payload: []const u8) !protocol_values.StatusCommand {
            const Packets = ProtocolModule.status.toServer;
            const header = try Packets.readHeader(payload);
            switch (header.id) {
                Packets.packetId(.ping_start) => {
                    const body = try Packets.readBody(.ping_start, header);
                    try body.finish();
                    return .request;
                },
                Packets.packetId(.ping) => {
                    const body = try Packets.readBody(.ping, header);
                    const timestamp, const done = try body.time();
                    try done.finish();
                    return .{ .ping = timestamp };
                },
                else => return error.UnexpectedPacket,
            }
        }

        pub fn decodeLogin(payload: []const u8) !protocol_values.LoginCommand {
            const Packets = ProtocolModule.login.toServer;
            const header = try Packets.readHeader(payload);
            switch (header.id) {
                Packets.packetId(.login_start) => {
                    const body = try Packets.readBody(.login_start, header);
                    const username, const uuid_cursor = try body.username();
                    const uuid, const done = try uuid_cursor.playerUUID();
                    try done.finish();
                    return .{ .start = .{ .username = username, .uuid = uuid } };
                },
                Packets.packetId(.encryption_begin) => {
                    const body = try Packets.readBody(.encryption_begin, header);
                    const secret_view, const token_cursor = try body.sharedSecret();
                    const token_view, const done = try token_cursor.verifyToken();
                    const secret = (try protocol_support.read_buffer_counted(secret_view.payload(), i32))[0];
                    const token = (try protocol_support.read_buffer_counted(token_view.payload(), i32))[0];
                    try done.finish();
                    return .{ .encryption_response = .{ .shared_secret = secret, .verify_token = token } };
                },
                Packets.packetId(.login_acknowledged) => {
                    const body = try Packets.readBody(.login_acknowledged, header);
                    try body.finish();
                    return .acknowledged;
                },
                else => return error.UnexpectedPacket,
            }
        }

        pub fn decodeConfiguration(payload: []const u8) !protocol_values.ConfigurationCommand {
            const Packets = ProtocolModule.configuration.toServer;
            const header = try Packets.readHeader(payload);
            switch (header.id) {
                Packets.packetId(.finish_configuration) => {
                    const body = try Packets.readBody(.finish_configuration, header);
                    try body.finish();
                    return .finish;
                },
                Packets.packetId(.select_known_packs) => {
                    const body = try Packets.readBody(.select_known_packs, header);
                    const packs, const done = try body.packs();
                    _ = try packs.len();
                    try packs.finish();
                    try done.finish();
                    return .select_known_packs;
                },
                else => return .ignore,
            }
        }

        pub fn decodeConfigurationAcknowledged(payload: []const u8) !bool {
            const Packets = ProtocolModule.play.toServer;
            const header = try Packets.readHeader(payload);
            if (header.id != Packets.packetId(.configuration_acknowledged)) return false;
            const body = try Packets.readBody(.configuration_acknowledged, header);
            try body.finish();
            return true;
        }

        pub fn encodeArmSwing(buffer: []u8, entity_id: i32, hand: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const animation = try packet.animation();
            const entity = try animation.entityId(entity_id);
            return (try entity.animation(if (hand == 1) 3 else 0)).finish();
        }

        pub fn encodeBlockBreakAnimation(buffer: []u8, entity_id: i32, x: i32, y: i16, z: i32, stage: i8) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const animation = try packet.block_break_animation();
            const entity = try animation.entityId(entity_id);
            const location = try entity.location(.{ .x = x, .y = y, .z = z });
            return (try location.destroyStage(stage)).finish();
        }

        pub fn encodeBlockChange(buffer: []u8, x: i32, y: i16, z: i32, block_state: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const change = try packet.block_change();
            const location = try change.location(.{ .x = x, .y = y, .z = z });
            return (try location.type(block_state)).finish();
        }

        pub fn encodeSectionBlockChanges(
            buffer: []u8,
            chunk_x: i32,
            section_y: i32,
            chunk_z: i32,
            records: []const i32,
        ) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const change = try packet.multi_block_change();
            const coordinates = try change.chunkCoordinates(.{
                .x = chunk_x,
                .y = section_y,
                .z = chunk_z,
            });
            var values = try coordinates.records(records.len);
            for (records) |record| values = try values.element(record);
            return (try values.finish()).finish();
        }

        pub fn encodeBlockAction(buffer: []u8, x: i32, y: i16, z: i32, action: u8, parameter: u8, block_id: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const block_action = try packet.block_action();
            const location = try block_action.location(.{ .x = x, .y = y, .z = z });
            const byte1 = try location.byte1(action);
            const byte2 = try byte1.byte2(parameter);
            return (try byte2.blockId(block_id)).finish();
        }

        pub fn encodeAcknowledgeSequence(buffer: []u8, sequence: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const ack = try packet.acknowledge_player_digging();
            return (try ack.sequenceId(sequence)).finish();
        }

        pub fn encodeEntityMoveLook(buffer: []u8, entity_id: i32, dx: i16, dy: i16, dz: i16, yaw: i8, pitch: i8, on_ground: bool) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const movement = try packet.entity_move_look();
            const entity = try movement.entityId(entity_id);
            const x = try entity.dX(dx);
            const y = try x.dY(dy);
            const z = try y.dZ(dz);
            const encoded_yaw = try z.yaw(yaw);
            const encoded_pitch = try encoded_yaw.pitch(pitch);
            return (try encoded_pitch.onGround(on_ground)).finish();
        }

        pub fn encodeEntityHeadRotation(buffer: []u8, entity_id: i32, yaw: i8) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const rotation = try packet.entity_head_rotation();
            const entity = try rotation.entityId(entity_id);
            return (try entity.headYaw(yaw)).finish();
        }

        pub fn encodeEntityVelocity(buffer: []u8, entity_id: i32, velocity_x: i16, velocity_y: i16, velocity_z: i16) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const velocity = try packet.entity_velocity();
            const entity = try velocity.entityId(entity_id);
            const x = try entity.velocityX(velocity_x);
            const y = try x.velocityY(velocity_y);
            return (try y.velocityZ(velocity_z)).finish();
        }

        pub fn startEntityEquipment(buffer: []u8, entity_id: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const equipment_packet = try packet.entity_equipment();
            const entity = try equipment_packet.entityId(entity_id);
            return entity.rest;
        }

        pub fn encodeHurtAnimation(buffer: []u8, entity_id: i32, yaw: f32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const animation = try packet.hurt_animation();
            const entity = try animation.entityId(entity_id);
            return (try entity.yaw(yaw)).finish();
        }

        pub fn encodeUpdateHealth(buffer: []u8, health: f32, food: i32, saturation: f32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const update = try packet.update_health();
            const encoded_health = try update.health(health);
            const encoded_food = try encoded_health.food(food);
            return (try encoded_food.foodSaturation(saturation)).finish();
        }

        pub fn encodeDamageEvent(buffer: []u8, entity_id: i32, source_type_id: i32, source_cause_id: i32, source_direct_id: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const damage = try packet.damage_event();
            const entity = try damage.entityId(entity_id);
            const source_type = try entity.sourceTypeId(source_type_id);
            const cause = try source_type.sourceCauseId(source_cause_id);
            const direct = try cause.sourceDirectId(source_direct_id);
            return (try (try direct.sourcePosition()).none()).finish();
        }

        pub fn encodeDeathCombatEvent(buffer: []u8, player_id: i32, message_text: []const u8) ![]u8 {
            var component_buffer: [256]u8 = undefined;
            const component = try writeTextComponent(&component_buffer, message_text);
            const packet = ProtocolModule.play.toClient.write(buffer);
            const death = try packet.death_combat_event();
            const player = try death.playerId(player_id);
            return (try player.message(component)).finish();
        }

        pub fn encodeEntityStatus(buffer: []u8, entity_id: i32, status: i8) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const entity_status = try packet.entity_status();
            const entity = try entity_status.entityId(entity_id);
            return (try entity.entityStatus(status)).finish();
        }

        pub fn encodeSoundEffect(buffer: []u8, sound_id: i32, x: i32, y: i32, z: i32, volume: f32, pitch: f32, seed: i64) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const effect = try packet.sound_effect();
            const sound = try effect.sound();
            const category = try sound.soundId(sound_id);
            const encoded_x = try (try category.soundCategory(6)).x(x);
            const encoded_y = try encoded_x.y(y);
            const encoded_z = try encoded_y.z(z);
            const encoded_volume = try encoded_z.volume(volume);
            const encoded_pitch = try encoded_volume.pitch(pitch);
            return (try encoded_pitch.seed(seed)).finish();
        }

        pub fn encodeSyncEntityPosition(buffer: []u8, entity_id: i32, x: f64, y: f64, z: f64, dx: f64, dy: f64, dz: f64, yaw: f32, pitch: f32, on_ground: bool) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const sync = try packet.sync_entity_position();
            const entity = try sync.entityId(entity_id);
            const encoded_x = try entity.x(x);
            const encoded_y = try encoded_x.y(y);
            const encoded_z = try encoded_y.z(z);
            const encoded_dx = try encoded_z.dx(dx);
            const encoded_dy = try encoded_dx.dy(dy);
            const encoded_dz = try encoded_dy.dz(dz);
            const encoded_yaw = try encoded_dz.yaw(yaw);
            const encoded_pitch = try encoded_yaw.pitch(pitch);
            return (try encoded_pitch.onGround(on_ground)).finish();
        }

        pub fn startEntityMetadata(buffer: []u8, entity_id: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const entity_metadata = try packet.entity_metadata();
            const entity = try entity_metadata.entityId(entity_id);
            return entity.rest;
        }

        pub fn encodeEntityDestroy(buffer: []u8, entity_id: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const destroy = try packet.entity_destroy();
            return (try (try destroy.entityIds(1)).single(entity_id)).finish();
        }

        pub fn encodeSetPassengers(buffer: []u8, vehicle_id: i32, passenger_id: ?i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const passengers = try packet.set_passengers();
            const vehicle = try passengers.entityId(vehicle_id);
            if (passenger_id) |passenger|
                return (try (try vehicle.passengers(1)).single(passenger)).finish();
            return (try (try vehicle.passengers(0)).finish()).finish();
        }

        pub fn encodeCollectItem(buffer: []u8, collected_entity_id: i32, collector_entity_id: i32, count: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const collect = try packet.collect();
            const collected = try collect.collectedEntityId(collected_entity_id);
            const collector = try collected.collectorEntityId(collector_entity_id);
            return (try collector.pickupItemCount(count)).finish();
        }

        pub fn startSystemChat(buffer: []u8) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const chat = try packet.system_chat();
            return chat.rest;
        }

        pub fn appendRaw(buffer: []u8, rest: []u8, payload: []const u8) ![]u8 {
            if (rest.len < payload.len) return error.EndOfStream;
            @memcpy(rest[0..payload.len], payload);
            return buffer[0 .. buffer.len - rest.len + payload.len];
        }

        pub fn startSetSlot(buffer: []u8, window_id: i32, state_id: i32, slot: i16) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const set_slot = try packet.set_slot();
            const window = try set_slot.windowId(window_id);
            const state = try window.stateId(state_id);
            const encoded_slot = try state.slot(slot);
            return encoded_slot.rest;
        }

        pub fn startSetPlayerInventory(buffer: []u8, slot: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const inventory = try packet.set_player_inventory();
            return (try inventory.slotId(slot)).rest;
        }

        pub fn startWindowItems(buffer: []u8, window_id: i32, state_id: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const window_items = try packet.window_items();
            const window = try window_items.windowId(window_id);
            const state = try window.stateId(state_id);
            return state.rest;
        }

        pub fn startOpenWindow(buffer: []u8, window_id: i32, inventory_type: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const open = try packet.open_window();
            const window = try open.windowId(window_id);
            const inventory = try window.inventoryType(inventory_type);
            return inventory.rest;
        }

        pub fn encodeCloseWindow(buffer: []u8, window_id: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const close = try packet.close_window();
            return (try close.windowId(window_id)).finish();
        }

        pub fn encodeContainerProperty(buffer: []u8, window_id: i32, property: i16, value: i16) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const progress = try packet.craft_progress_bar();
            const window = try progress.windowId(window_id);
            const encoded_property = try window.property(property);
            return (try encoded_property.value(value)).finish();
        }

        pub fn encodeUpdateViewPosition(buffer: []u8, chunk_x: i32, chunk_z: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const update = try packet.update_view_position();
            const x = try update.chunkX(chunk_x);
            return (try x.chunkZ(chunk_z)).finish();
        }

        pub fn encodeSpawnPosition(buffer: []u8, x: i32, y: i16, z: i32, angle: f32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const spawn = try packet.spawn_position();
            const location = try spawn.location(.{ .x = x, .y = y, .z = z });
            return (try location.angle(angle)).finish();
        }

        pub fn encodeGameStateChange(buffer: []u8, reason: u8, value: f32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const change = try packet.game_state_change();
            const encoded_reason = try change.reason(reason);
            return (try encoded_reason.gameMode(value)).finish();
        }

        pub fn encodeAbilities(buffer: []u8, flags: i8, flying_speed: f32, walking_speed: f32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const abilities = try packet.abilities();
            const encoded_flags = try abilities.flags(flags);
            const flying = try encoded_flags.flyingSpeed(flying_speed);
            return (try flying.walkingSpeed(walking_speed)).finish();
        }

        pub fn encodeHeldItemSlot(buffer: []u8, slot: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const held = try packet.held_item_slot();
            return (try held.slot(slot)).finish();
        }

        pub fn encodeBrand(buffer: []u8, brand: []const u8) ![]u8 {
            var payload: [256]u8 = undefined;
            const rest = try protocol_support.write_pstring(&payload, brand, i32);
            const used = payload.len - rest.len;
            const packet = ProtocolModule.play.toClient.write(buffer);
            const custom = try packet.custom_payload();
            return (try (try custom.channel("minecraft:brand")).data(payload[0..used])).finish();
        }

        pub fn encodeUpdateTime(buffer: []u8, age: i64, time: i64, tick_day_time: bool) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const update = try packet.update_time();
            const with_age = try update.age(age);
            const with_time = try with_age.time(time);
            return (try with_time.tickDayTime(tick_day_time)).finish();
        }

        pub fn encodeCombatAttributes(buffer: []u8, entity_id: i32, attack_damage: f64, attack_speed: f64) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const attributes = try packet.entity_update_attributes();
            const entity = try attributes.entityId(entity_id);
            var properties = try entity.properties(2);
            const damage = try (try properties.element()).key(2);
            properties = try (try (try damage.value(attack_damage)).modifiers(0)).finish();
            const speed = try (try properties.element()).key(4);
            properties = try (try (try speed.value(attack_speed)).modifiers(0)).finish();
            return (try properties.finish()).finish();
        }

        pub fn encodeChunkBatchStart(buffer: []u8) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const start = try packet.chunk_batch_start();
            return (try start.finish()).finish();
        }

        pub fn encodeChunkBatchFinished(buffer: []u8, batch_size: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const finished = try packet.chunk_batch_finished();
            return (try finished.batchSize(batch_size)).finish();
        }

        pub fn encodePlayerPosition(buffer: []u8, value: protocol_values.PlayerPosition) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const position = try packet.position();
            const teleport = try position.teleportId(value.teleport_id);
            const x = try teleport.x(value.x);
            const y = try x.y(value.y);
            const z = try y.z(value.z);
            const dx = try z.dx(value.velocity_x);
            const dy = try dx.dy(value.velocity_y);
            const dz = try dy.dz(value.velocity_z);
            const yaw = try dz.yaw(value.yaw);
            const pitch = try yaw.pitch(value.pitch);
            return (try pitch.flags(.{})).finish();
        }

        pub fn encodeSpawnEntity(buffer: []u8, value: protocol_values.SpawnEntity) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const spawn = try packet.spawn_entity();
            const entity = try spawn.entityId(value.entity_id);
            const uuid = try entity.objectUUID(value.uuid);
            const entity_type = try uuid.type(value.entity_type);
            const x = try entity_type.x(value.x);
            const y = try x.y(value.y);
            const z = try y.z(value.z);
            const pitch = try z.pitch(value.pitch);
            const yaw = try pitch.yaw(value.yaw);
            const head = try yaw.headPitch(value.head_yaw);
            const data = try head.objectData(value.data);
            const velocity_x = try data.velocityX(value.velocity_x);
            const velocity_y = try velocity_x.velocityY(value.velocity_y);
            return (try velocity_y.velocityZ(value.velocity_z)).finish();
        }

        pub fn encodeKeepAlive(buffer: []u8, id: i64) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const keep_alive = try packet.keep_alive();
            return (try keep_alive.keepAliveId(id)).finish();
        }

        pub fn encodePlayLogin(buffer: []u8, value: protocol_values.PlayLogin) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const login = try packet.login();
            const entity = try login.entityId(value.entity_id);
            const hardcore = try entity.isHardcore(false);
            var worlds = try hardcore.worldNames(value.world_names.len);
            for (value.world_names) |world_name| worlds = try worlds.element(world_name);
            const after_worlds = try worlds.finish();
            const players = try after_worlds.maxPlayers(value.max_players);
            const view = try players.viewDistance(value.view_distance);
            const simulation = try view.simulationDistance(value.simulation_distance);
            const debug = try simulation.reducedDebugInfo(false);
            const respawn_screen = try debug.enableRespawnScreen(true);
            const crafting = try respawn_screen.doLimitedCrafting(false);
            const world = try crafting.worldState();
            const dimension = try world.dimension(value.dimension_type);
            const name = try dimension.name(value.world_name);
            const seed = try name.hashedSeed(value.hashed_seed);
            const gamemode = try seed.gamemode(value.gamemode);
            const previous = try gamemode.previousGamemode(255);
            const is_debug = try previous.isDebug(false);
            const flat = try is_debug.isFlat(false);
            const death = try flat.death();
            const no_death = try death.none();
            const cooldown = try no_death.portalCooldown(0);
            const sea = try cooldown.seaLevel(value.sea_level);
            return (try sea.enforcesSecureChat(false)).finish();
        }

        pub fn encodeRespawn(buffer: []u8, value: protocol_values.Respawn) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const respawn = try packet.respawn();
            const world = try respawn.worldState();
            const dimension = try world.dimension(value.dimension_type);
            const name = try dimension.name(value.world_name);
            const seed = try name.hashedSeed(value.hashed_seed);
            const gamemode = try seed.gamemode(value.gamemode);
            const previous = try gamemode.previousGamemode(255);
            const is_debug = try previous.isDebug(false);
            const flat = try is_debug.isFlat(false);
            const no_death = try (try flat.death()).none();
            const cooldown = try no_death.portalCooldown(0);
            const sea = try cooldown.seaLevel(value.sea_level);
            return (try sea.copyMetadata(0)).finish();
        }

        pub fn encodeDeclareCommands(buffer: []u8, declarations: []const command_spec.Declaration) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const commands = try packet.declare_commands();
            var node_count: usize = 1;
            for (declarations) |declaration| node_count += 1 + declaration.alternatives.len + @intFromBool(declaration.greedy_argument != null);
            var nodes = try commands.nodes(@intCast(node_count));

            const root = try nodes.element();
            const root_flags = try root.flags(.{
                .unused = 0,
                .allows_restricted = false,
                .has_custom_suggestions = false,
                .has_redirect_node = false,
                .has_command = false,
                .command_node_type = 0,
            });
            if (declarations.len == 0) {
                const root_redirect = try root_flags.childrenEmpty();
                const root_extra = try (try root_redirect.redirectNode()).case_default();
                nodes = try (try root_extra.extraNodeData()).case_0();
            } else {
                var root_children = try root_flags.children(@intCast(declarations.len));
                var command_index: usize = 1;
                for (declarations[0 .. declarations.len - 1]) |declaration| {
                    root_children = try root_children.element(@intCast(command_index));
                    command_index += 1 + declaration.alternatives.len + @intFromBool(declaration.greedy_argument != null);
                }
                const root_redirect = try root_children.single(@intCast(command_index));
                const root_extra = try (try root_redirect.redirectNode()).case_default();
                nodes = try (try root_extra.extraNodeData()).case_0();
            }

            var next_node_index: usize = 1;
            for (declarations) |declaration| {
                const command = try nodes.element();
                const command_flags = try command.flags(.{
                    .unused = 0,
                    .allows_restricted = false,
                    .has_custom_suggestions = false,
                    .has_redirect_node = false,
                    .has_command = declaration.executable_without_arguments or
                        (declaration.alternatives.len == 0 and declaration.greedy_argument == null),
                    .command_node_type = 1,
                });
                next_node_index += 1;
                const child_count = declaration.alternatives.len + @intFromBool(declaration.greedy_argument != null);
                if (child_count == 0) {
                    const command_redirect = try command_flags.childrenEmpty();
                    const command_extra = try (try command_redirect.redirectNode()).case_default();
                    const command_literal = try (try command_extra.extraNodeData()).case_1();
                    nodes = try command_literal.name(declaration.name);
                } else {
                    var children = try command_flags.children(@intCast(child_count));
                    for (0..child_count - 1) |offset|
                        children = try children.element(@intCast(next_node_index + offset));
                    const command_redirect = try children.single(@intCast(next_node_index + child_count - 1));
                    const command_extra = try (try command_redirect.redirectNode()).case_default();
                    const command_literal = try (try command_extra.extraNodeData()).case_1();
                    nodes = try command_literal.name(declaration.name);
                }
                for (declaration.alternatives) |alternative| {
                    const literal = try nodes.element();
                    const literal_flags = try literal.flags(.{
                        .unused = 0,
                        .allows_restricted = false,
                        .has_custom_suggestions = false,
                        .has_redirect_node = false,
                        .has_command = true,
                        .command_node_type = 1,
                    });
                    const literal_redirect = try literal_flags.childrenEmpty();
                    const literal_extra = try (try literal_redirect.redirectNode()).case_default();
                    const literal_data = try (try literal_extra.extraNodeData()).case_1();
                    nodes = try literal_data.name(alternative);
                    next_node_index += 1;
                }
                if (declaration.greedy_argument) |argument_name| {
                    const argument = try nodes.element();
                    const argument_flags = try argument.flags(.{
                        .unused = 0,
                        .allows_restricted = false,
                        .has_custom_suggestions = false,
                        .has_redirect_node = false,
                        .has_command = true,
                        .command_node_type = 2,
                    });
                    const argument_children = try argument_flags.childrenEmpty();
                    const argument_redirect = try (try argument_children.redirectNode()).case_default();
                    const argument_data = try (try argument_redirect.extraNodeData()).case_2();
                    const argument_parser = try (try argument_data.name(argument_name)).parser(5);
                    const argument_properties = try argument_parser.properties();
                    const argument_suggestions = try argument_properties.case_brigadier_string(2);
                    nodes = try (try argument_suggestions.suggestionType()).case_default();
                    next_node_index += 1;
                }
            }
            const done = try (try nodes.finish()).rootIndex(0);
            return done.finish();
        }

        pub fn encodePlayerInfoAdd(buffer: []u8, uuid_value: u128, name_value: []const u8, gamemode_value: i32) ![]u8 {
            const entries = [1]protocol_values.PlayerInfo{.{
                .uuid = uuid_value,
                .name = name_value,
                .gamemode = gamemode_value,
            }};
            return encodePlayerInfoAddBatch(buffer, &entries);
        }

        pub fn encodePlayerInfoAddBatch(buffer: []u8, values: []const protocol_values.PlayerInfo) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const info = try packet.player_info();
            const action = try info.action(.{
                .add_player = true,
                .initialize_chat = true,
                .update_game_mode = true,
                .update_listed = true,
                .update_latency = true,
                .update_display_name = true,
                .update_hat = true,
                .update_list_order = true,
            });
            var entries = try action.data(values.len);
            for (values) |value| {
                const entry = try entries.element();
                const profile = try (try entry.uuid(value.uuid)).player();
                const profile_value = try profile.case_true();
                const properties = try (try profile_value.name(value.name)).properties(0);
                const after_profile = try properties.finish();
                const chat_session = try (try after_profile.chatSession()).case_true();
                const after_chat = try chat_session.none();
                const after_gamemode = try (try after_chat.gamemode()).case_true(value.gamemode);
                const after_listed = try (try after_gamemode.listed()).case_true(1);
                const after_latency = try (try after_listed.latency()).case_true(0);
                const after_display = try (try after_latency.displayName()).case_true();
                const priority = try (try after_display.none()).listPriority();
                const after_priority = try priority.case_true(0);
                entries = try (try after_priority.showHat()).case_true(true);
            }
            return (try entries.finish()).finish();
        }

        pub fn encodePlayerInfoGamemode(buffer: []u8, uuid_value: u128, gamemode_value: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const info = try packet.player_info();
            const action = try info.action(.{ .update_game_mode = true });
            var entries = try action.data(1);
            const entry = try entries.element();
            const profile = try (try entry.uuid(uuid_value)).player();
            const after_profile = try profile.case_default();
            const after_chat = try (try after_profile.chatSession()).case_default();
            const after_gamemode = try (try after_chat.gamemode()).case_true(gamemode_value);
            const after_listed = try (try after_gamemode.listed()).case_default();
            const after_latency = try (try after_listed.latency()).case_default();
            const after_display = try (try after_latency.displayName()).case_default();
            const after_priority = try (try after_display.listPriority()).case_default();
            entries = try (try after_priority.showHat()).case_default();
            return (try entries.finish()).finish();
        }

        pub fn encodePlayerInfoLatency(buffer: []u8, uuid_value: u128, latency_value: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const info = try packet.player_info();
            const action = try info.action(.{ .update_latency = true });
            var entries = try action.data(1);
            const entry = try entries.element();
            const profile = try (try entry.uuid(uuid_value)).player();
            const after_profile = try profile.case_default();
            const after_chat = try (try after_profile.chatSession()).case_default();
            const after_gamemode = try (try after_chat.gamemode()).case_default();
            const after_listed = try (try after_gamemode.listed()).case_default();
            const after_latency = try (try after_listed.latency()).case_true(latency_value);
            const after_display = try (try after_latency.displayName()).case_default();
            const after_priority = try (try after_display.listPriority()).case_default();
            entries = try (try after_priority.showHat()).case_default();
            return (try entries.finish()).finish();
        }

        pub fn encodePlayerRemove(buffer: []u8, uuid_value: u128) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const remove = try packet.player_remove();
            return (try (try remove.players(1)).single(uuid_value)).finish();
        }

        pub fn encodeStatusResponse(buffer: []u8, json: []const u8) ![]u8 {
            const packet = ProtocolModule.status.toClient.write(buffer);
            const info = try packet.server_info();
            return (try info.response(json)).finish();
        }

        pub fn encodeStatusPong(buffer: []u8, timestamp: i64) ![]u8 {
            const packet = ProtocolModule.status.toClient.write(buffer);
            const ping = try packet.ping();
            return (try ping.time(timestamp)).finish();
        }

        pub fn encodeLoginSuccess(buffer: []u8, uuid_value: u128, username: []const u8) ![]u8 {
            const packet = ProtocolModule.login.toClient.write(buffer);
            const success = try packet.success();
            const uuid = try success.uuid(uuid_value);
            const name = try uuid.username(username);
            return (try (try name.properties(0)).finish()).finish();
        }

        pub fn encodeLoginDisconnect(buffer: []u8, reason: []const u8) ![]u8 {
            const packet = ProtocolModule.login.toClient.write(buffer);
            const disconnect = try packet.disconnect();
            return (try disconnect.reason(reason)).finish();
        }

        pub fn encodeEncryptionRequest(buffer: []u8, public_key: []const u8, verify_token: []const u8) ![]u8 {
            const packet = ProtocolModule.login.toClient.write(buffer);
            const begin = try packet.encryption_begin();
            const server_id = try begin.serverId("");
            const key = try server_id.publicKey(public_key);
            const token = try key.verifyToken(verify_token);
            return (try token.shouldAuthenticate(false)).finish();
        }

        pub fn encodeSetCompression(buffer: []u8, threshold: i32) ![]u8 {
            const packet = ProtocolModule.login.toClient.write(buffer);
            const compress = try packet.compress();
            return (try compress.threshold(threshold)).finish();
        }

        pub fn encodeFinishConfiguration(buffer: []u8) ![]u8 {
            const packet = ProtocolModule.configuration.toClient.write(buffer);
            const finish = try packet.finish_configuration();
            return (try finish.finish()).finish();
        }

        pub fn encodeStartConfiguration(buffer: []u8) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const start = try packet.start_configuration();
            return (try start.finish()).finish();
        }

        pub fn encodeFeatureFlags(buffer: []u8) ![]u8 {
            return encodeFeatureFlagList(buffer, &.{"minecraft:vanilla"});
        }

        pub fn encodeFeatureFlagList(buffer: []u8, values: []const []const u8) ![]u8 {
            const packet = ProtocolModule.configuration.toClient.write(buffer);
            const flags = try packet.feature_flags();
            var list = try flags.features(values.len);
            for (values) |value| list = try list.element(value);
            return (try list.finish()).finish();
        }

        pub fn encodeConfigurationTags(buffer: []u8, payload: []const u8) ![]u8 {
            const packet = ProtocolModule.configuration.toClient.write(buffer);
            const tags = try packet.tags();
            return appendRaw(buffer, tags.rest, payload);
        }

        pub fn encodeKnownPacks(buffer: []u8, minecraft_name: []const u8) ![]u8 {
            return encodeKnownPackList(buffer, &.{.{ .namespace = "minecraft", .id = "core", .version = minecraft_name }});
        }

        pub fn encodeKnownPackList(buffer: []u8, packs_data: []const @import("configuration_plan.zig").KnownPack) ![]u8 {
            const packet = ProtocolModule.configuration.toClient.write(buffer);
            const select = try packet.select_known_packs();
            var packs = try select.packs(packs_data.len);
            for (packs_data) |data| {
                const pack = try packs.element();
                const pack_id = try (try pack.namespace(data.namespace)).id(data.id);
                packs = try pack_id.version(data.version);
            }
            return (try packs.finish()).finish();
        }

        pub fn encodeRegistryData(buffer: []u8, registry_id: []const u8, entry_ids: []const []const u8) ![]u8 {
            const packet = ProtocolModule.configuration.toClient.write(buffer);
            const registry = try packet.registry_data();
            const id = try registry.id(registry_id);
            var entries = try id.entries(entry_ids.len);
            for (entry_ids) |entry_id| {
                const entry = try entries.element();
                const value = try (try entry.key(entry_id)).value();
                entries = try value.none();
            }
            return (try entries.finish()).finish();
        }

        pub fn encodeRegistryEntries(buffer: []u8, data: @import("configuration_plan.zig").Registry) ![]u8 {
            const packet = ProtocolModule.configuration.toClient.write(buffer);
            const registry = try packet.registry_data();
            const id = try registry.id(data.id);
            var entries = try id.entries(data.entries.len);
            for (data.entries) |data_entry| {
                const entry = try entries.element();
                const value = try (try entry.key(data_entry.id)).value();
                entries = if (data_entry.nbt) |nbt| try value.some(nbt) else try value.none();
            }
            return (try entries.finish()).finish();
        }

        pub fn encodeResourcePack(buffer: []u8, data: @import("configuration_plan.zig").ResourcePack) ![]u8 {
            const packet = ProtocolModule.configuration.toClient.write(buffer);
            const add = try packet.add_resource_pack();
            const url = try (try add.uuid(data.uuid)).url(data.url);
            const hash = try url.hash(data.hash);
            const prompt = try (try hash.forced(data.required)).promptMessage();
            return if (data.prompt_nbt) |nbt| (try prompt.some(nbt)).finish() else (try prompt.none()).finish();
        }

        pub fn encodeDimensionRegistry(buffer: []u8, definitions: []const dimension_api.Definition) ![]u8 {
            const packet = ProtocolModule.configuration.toClient.write(buffer);
            const registry = try packet.registry_data();
            const id = try registry.id("minecraft:dimension_type");
            var entries = try id.entries(definitions.len);
            var nbt_storage: [world_dimensions.max_protocol_nbt_bytes]u8 = undefined;
            for (definitions) |definition| {
                const entry = try entries.element();
                const value = try (try entry.key(definition.id)).value();
                if (definition.known_pack) {
                    entries = try value.none();
                } else {
                    const encoded = try world_dimensions.writeProtocolNbt(&nbt_storage, definition);
                    entries = try value.some(encoded);
                }
            }
            return (try entries.finish()).finish();
        }

        pub fn encodeChunkPrefix(buffer: []u8, chunk_x: i32, chunk_z: i32) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const chunk = try packet.map_chunk();
            const x = try chunk.x(chunk_x);
            const z = try x.z(chunk_z);
            return buffer[0 .. buffer.len - z.rest.len];
        }

        pub fn encodeUpdateLight(buffer: []u8, update: light_projection.Update) ![]u8 {
            const packet = ProtocolModule.play.toClient.write(buffer);
            const body = try packet.update_light();
            var rest = try protocol_support.write_varint(body.rest, update.chunk.chunk_x);
            rest = try protocol_support.write_varint(rest, update.chunk.chunk_z);
            const sky_mask = update.sky_changed_mask & update.chunk.sky_mask;
            const block_mask = update.block_changed_mask & update.chunk.block_mask;
            const empty_sky_mask = update.sky_changed_mask & update.chunk.empty_sky_mask;
            const empty_block_mask = update.block_changed_mask & update.chunk.empty_block_mask;
            rest = try writeLightMask(rest, sky_mask);
            rest = try writeLightMask(rest, block_mask);
            rest = try writeLightMask(rest, empty_sky_mask);
            rest = try writeLightMask(rest, empty_block_mask);
            rest = try writeLightArrays(rest, sky_mask, &update.chunk.sky, 0xff);
            rest = try writeLightArrays(rest, block_mask, &update.chunk.block, 0);
            return buffer[0 .. buffer.len - rest.len];
        }

        fn writeLightMask(buffer: []u8, mask: u32) ![]u8 {
            if (mask == 0) return protocol_support.write_count(buffer, i32, 0);
            const rest = try protocol_support.write_count(buffer, i32, 1);
            return protocol_support.write_i64(rest, @intCast(mask));
        }

        fn writeLightArrays(
            buffer: []u8,
            mask_value: u32,
            sections: *const [light_projection.protocol_section_count]light_projection.Section,
            default_byte: u8,
        ) ![]u8 {
            var rest = try protocol_support.write_count(buffer, i32, @popCount(mask_value));
            var mask = mask_value;
            while (mask != 0) {
                const section: usize = @intCast(@ctz(mask));
                mask &= mask - 1;
                rest = try protocol_support.write_count(rest, i32, light_projection.bytes_per_section);
                if (rest.len < light_projection.bytes_per_section) return error.EndOfStream;
                if (sections[section].bytes()) |bytes|
                    @memcpy(rest[0..light_projection.bytes_per_section], bytes)
                else
                    @memset(rest[0..light_projection.bytes_per_section], default_byte);
                rest = rest[light_projection.bytes_per_section..];
            }
            return rest;
        }
    };
}

fn EntryFor(comptime version: Version) type {
    inline for (protocol_catalog.entries) |Entry| {
        if (version == Entry.version) return Entry;
    }
    unreachable;
}

fn Codec(comptime version: Version) type {
    const Entry = EntryFor(version);
    return PlayCodec(Entry.Protocol, Entry.Registry);
}

pub inline fn staticCall(
    comptime operation: []const u8,
    protocol_number: i32,
    arguments: anytype,
) @TypeOf(@call(.auto, @field(Codec(default), operation), arguments)) {
    inline for (protocol_catalog.entries) |Entry| {
        if (protocol_number == Entry.protocol_number)
            return @call(.auto, @field(Codec(Entry.version), operation), arguments);
    }
    unreachable;
}

pub fn staticWireBlockState(protocol_number: i32, canonical_id: i32) !i32 {
    inline for (protocol_catalog.entries) |Entry| if (protocol_number == Entry.protocol_number)
        return translateStaticRegistryId(Entry.Registry.canonical_block_state_to_wire, canonical_id);
    unreachable;
}

pub fn staticWireItem(protocol_number: i32, canonical_id: i32) !i32 {
    inline for (protocol_catalog.entries) |Entry| if (protocol_number == Entry.protocol_number)
        return translateStaticRegistryId(Entry.Registry.canonical_item_to_wire, canonical_id);
    unreachable;
}

pub fn staticWireEntity(protocol_number: i32, canonical_id: i32) !i32 {
    inline for (protocol_catalog.entries) |Entry| if (protocol_number == Entry.protocol_number)
        return translateStaticRegistryId(Entry.Registry.canonical_entity_to_wire, canonical_id);
    unreachable;
}

pub fn staticWireSound(protocol_number: i32, sound: protocol_values.Sound) i32 {
    inline for (protocol_catalog.entries) |Entry| if (protocol_number == Entry.protocol_number) return switch (sound) {
        .cow_ambient => Entry.Registry.sound_entity_cow_ambient_id,
        .cow_death => Entry.Registry.sound_entity_cow_death_id,
        .cow_hurt => Entry.Registry.sound_entity_cow_hurt_id,
        .cow_milk => Entry.Registry.sound_entity_cow_milk_id,
        .cow_step => Entry.Registry.sound_entity_cow_step_id,
    };
    unreachable;
}

pub fn staticItemMapping(protocol_number: i32) []const i32 {
    inline for (protocol_catalog.entries) |Entry| if (protocol_number == Entry.protocol_number)
        return Entry.Registry.canonical_item_to_wire;
    unreachable;
}

pub fn staticDamageComponentId(protocol_number: i32) i32 {
    inline for (protocol_catalog.entries) |Entry| if (protocol_number == Entry.protocol_number)
        return Entry.Registry.dataComponentId("minecraft:damage").?;
    unreachable;
}

fn translateStaticRegistryId(comptime mapping: []const i32, canonical_id: i32) !i32 {
    if (canonical_id < 0) return error.UnknownCanonicalRegistryId;
    const index: usize = @intCast(canonical_id);
    if (index >= mapping.len) return error.UnknownCanonicalRegistryId;
    const wire_id = mapping[index];
    if (wire_id < 0) return error.RegistryEntryUnsupportedByProtocol;
    return wire_id;
}

pub fn fromProtocolNumber(value: i32) ?Version {
    inline for (supported) |entry| {
        if (value == entry.protocol_number) return entry.version;
    }
    return null;
}

pub fn Protocol(comptime version: Version) type {
    return EntryFor(version).Protocol;
}

pub fn Registry(comptime version: Version) type {
    return EntryFor(version).Registry;
}

test "supported protocol versions have unique wire numbers" {
    const versions = std.enums.values(Version);
    try std.testing.expectEqual(versions.len, supported.len);
    for (versions, 0..) |left, index| {
        try std.testing.expectEqual(left, supported[index].version);
        try std.testing.expect(left.minecraftName().len != 0);
        for (versions[index + 1 ..]) |right| {
            try std.testing.expect(left.protocolNumber() != right.protocolNumber());
        }
        try std.testing.expectEqual(left, fromProtocolNumber(left.protocolNumber()).?);
        try std.testing.expectEqualStrings(supported[index].minecraft_name, left.minecraftName());
    }
    try std.testing.expect(fromProtocolNumber(0) == null);
}

fn expectRegistryTranslation(comptime canonical_names: []const []const u8, comptime wire_names: []const []const u8, mapping: []const i32) !void {
    try std.testing.expectEqual(canonical_names.len, mapping.len);
    for (canonical_names, mapping) |canonical_name, wire_id| {
        if (wire_id < 0) continue;
        try std.testing.expect(@as(usize, @intCast(wire_id)) < wire_names.len);
        try std.testing.expectEqualStrings(canonical_name, wire_names[@intCast(wire_id)]);
    }
}

test "generated registry translations preserve names" {
    const Canonical = EntryFor(protocol_catalog.canonical).Registry;
    inline for (protocol_catalog.entries) |Entry| {
        try std.testing.expectEqual(Entry.version == protocol_catalog.canonical, Entry.Registry.canonical_registries_identity);
        try expectRegistryTranslation(Canonical.block_state_names, Entry.Registry.block_state_names, Entry.Registry.canonical_block_state_to_wire);
        try expectRegistryTranslation(Canonical.item_names, Entry.Registry.item_names, Entry.Registry.canonical_item_to_wire);
        try expectRegistryTranslation(Canonical.entity_names, Entry.Registry.entity_names, Entry.Registry.canonical_entity_to_wire);
    }
}

fn testOutputCodec(comptime ProtocolModule: type, comptime WireCodec: type) !void {
    var bytes: [2048]u8 = undefined;
    try testEntityOutputCodec(ProtocolModule, WireCodec, &bytes);
    try testPlayerInfoOutputCodec(ProtocolModule, WireCodec, &bytes);
    try testPlayOutputCodec(ProtocolModule, WireCodec, &bytes);
    try testNonPlayOutputCodec(ProtocolModule, WireCodec, &bytes);
}

fn testEntityOutputCodec(comptime ProtocolModule: type, comptime WireCodec: type, bytes: []u8) !void {
    const health = try WireCodec.encodeUpdateHealth(bytes, 18.5, 19, 4.0);
    _ = try ProtocolModule.play.toClient.read(health).name();

    const damage = try WireCodec.encodeDamageEvent(bytes, 7, 1, 3, 3);
    _ = try ProtocolModule.play.toClient.read(damage).name();

    const position = try WireCodec.encodeSyncEntityPosition(bytes, 7, -31.5, 96.56, 82.5, 0, 0.06, 0, 90, 10, true);
    try expectSyncEntityPosition(ProtocolModule, position);

    var rest = try WireCodec.startEntityMetadata(bytes, 7);
    rest = try protocol_support.write_u8(rest, 0xff);
    _ = try ProtocolModule.play.toClient.read(bytes[0 .. bytes.len - rest.len]).name();

    const destroyed = try WireCodec.encodeEntityDestroy(bytes, 7);
    _ = try ProtocolModule.play.toClient.read(destroyed).name();

    try expectPassengersPacket(ProtocolModule, try WireCodec.encodeSetPassengers(bytes, 7, 8));
    try expectPassengersPacket(ProtocolModule, try WireCodec.encodeSetPassengers(bytes, 7, null));
}

fn expectSyncEntityPosition(comptime ProtocolModule: type, position: []const u8) !void {
    switch (try ProtocolModule.play.toClient.read(position).name()) {
        .sync_entity_position => |body| {
            const entity_id, const c1 = try body.entityId();
            const x, const c2 = try c1.x();
            const y, const c3 = try c2.y();
            const z, const c4 = try c3.z();
            const dx, const c5 = try c4.dx();
            const dy, const c6 = try c5.dy();
            const dz, const c7 = try c6.dz();
            const yaw, const c8 = try c7.yaw();
            const pitch, const c9 = try c8.pitch();
            const on_ground, const done = try c9.onGround();
            try done.finish();
            try std.testing.expectEqual(@as(i32, 7), entity_id);
            try std.testing.expectEqual(@as(f64, -31.5), x);
            try std.testing.expectEqual(@as(f64, 96.56), y);
            try std.testing.expectEqual(@as(f64, 82.5), z);
            try std.testing.expectEqual(@as(f64, 0), dx);
            try std.testing.expectEqual(@as(f64, 0.06), dy);
            try std.testing.expectEqual(@as(f64, 0), dz);
            try std.testing.expectEqual(@as(f32, 90), yaw);
            try std.testing.expectEqual(@as(f32, 10), pitch);
            try std.testing.expect(on_ground);
        },
        else => return error.UnexpectedPacket,
    }
}

fn expectPassengersPacket(comptime ProtocolModule: type, packet: []const u8) !void {
    switch (try ProtocolModule.play.toClient.read(packet).name()) {
        .set_passengers => {},
        else => return error.UnexpectedPacket,
    }
}

fn testPlayerInfoOutputCodec(comptime ProtocolModule: type, comptime WireCodec: type, bytes: []u8) !void {
    const player_info = try WireCodec.encodePlayerInfoAdd(bytes, 9, "player", 1);
    try expectPlayerInfoAdd(ProtocolModule, player_info);

    const player_info_batch = try WireCodec.encodePlayerInfoAddBatch(bytes, &.{
        .{ .uuid = 9, .name = "alice", .gamemode = 0 },
        .{ .uuid = 10, .name = "bob", .gamemode = 1 },
    });
    try expectPlayerInfoEntries(ProtocolModule, player_info_batch, 2);

    const player_latency = try WireCodec.encodePlayerInfoLatency(bytes, 9, 150);
    try expectPlayerInfoLatency(ProtocolModule, player_latency);
}

fn expectPlayerInfoAdd(comptime ProtocolModule: type, packet: []const u8) !void {
    switch (try ProtocolModule.play.toClient.read(packet).name()) {
        .player_info => |body| {
            try std.testing.expectEqual(@as(usize, 33), body.buffer.len);
            try std.testing.expectEqualSlices(
                u8,
                &.{ 0, 1, 1, 0, 0, 0, 1 },
                body.buffer[body.buffer.len - 7 ..],
            );
            const actions, const data_cursor = try body.action();
            try std.testing.expect(actions.add_player);
            try std.testing.expect(actions.initialize_chat);
            try std.testing.expect(actions.update_game_mode);
            try std.testing.expect(actions.update_listed);
            try std.testing.expect(actions.update_latency);
            try std.testing.expect(actions.update_display_name);
            try std.testing.expect(actions.update_hat);
            try std.testing.expect(actions.update_list_order);
            const entries, const done = try data_cursor.data();
            try std.testing.expectEqual(@as(usize, 1), try entries.len());
            try done.finish();
        },
        else => return error.UnexpectedPacket,
    }
}

fn expectPlayerInfoEntries(comptime ProtocolModule: type, packet: []const u8, expected: usize) !void {
    switch (try ProtocolModule.play.toClient.read(packet).name()) {
        .player_info => |body| {
            _, const data_cursor = try body.action();
            const entries, const done = try data_cursor.data();
            try std.testing.expectEqual(expected, try entries.len());
            try done.finish();
        },
        else => return error.UnexpectedPacket,
    }
}

fn expectPlayerInfoLatency(comptime ProtocolModule: type, packet: []const u8) !void {
    switch (try ProtocolModule.play.toClient.read(packet).name()) {
        .player_info => |body| {
            const actions, const data_cursor = try body.action();
            try std.testing.expect(actions.update_latency);
            try std.testing.expect(!actions.add_player);
            const entries, const done = try data_cursor.data();
            try std.testing.expectEqual(@as(usize, 1), try entries.len());
            try done.finish();
        },
        else => return error.UnexpectedPacket,
    }
}

fn testPlayOutputCodec(comptime ProtocolModule: type, comptime WireCodec: type, bytes: []u8) !void {
    const collected = try WireCodec.encodeCollectItem(bytes, 7, 8, 1);
    _ = try ProtocolModule.play.toClient.read(collected).name();

    var rest = try WireCodec.startSystemChat(bytes);
    rest = try protocol_support.write_u8(rest, 0);
    rest = try protocol_support.write_bool(rest, false);
    const chat = bytes[0 .. bytes.len - rest.len];
    _ = try ProtocolModule.play.toClient.read(chat).name();

    const spawned = try WireCodec.encodeSpawnEntity(bytes, .{
        .entity_id = 7,
        .uuid = 9,
        .entity_type = 1,
        .x = 1,
        .y = 64,
        .z = 2,
        .pitch = 0,
        .yaw = 0,
        .head_yaw = 0,
        .data = 0,
        .velocity_x = 0,
        .velocity_y = 0,
        .velocity_z = 0,
    });
    _ = try ProtocolModule.play.toClient.read(spawned).name();

    const time_packet = try WireCodec.encodeUpdateTime(bytes, 77, 13_000, true);
    try expectUpdateTime(ProtocolModule, time_packet);

    rest = try WireCodec.startWindowItems(bytes, 0, 1);
    rest = try protocol_support.write_u8(rest, 0);
    rest = try protocol_support.write_u8(rest, 0);
    _ = try ProtocolModule.play.toClient.read(bytes[0 .. bytes.len - rest.len]).name();

    const commands = try WireCodec.encodeDeclareCommands(bytes, &.{
        .{ .name = "gamemode", .alternatives = &.{ "survival", "creative", "adventure", "spectator" } },
        .{ .name = "summon", .alternatives = &.{"zombie"} },
        .{ .name = "time", .greedy_argument = "operation" },
    });
    _ = try ProtocolModule.play.toClient.read(commands).name();
}

fn expectUpdateTime(comptime ProtocolModule: type, packet: []const u8) !void {
    switch (try ProtocolModule.play.toClient.read(packet).name()) {
        .update_time => |body| {
            const age, const time_cursor = try body.age();
            const time, const ticking_cursor = try time_cursor.time();
            const ticking, const done = try ticking_cursor.tickDayTime();
            try done.finish();
            try std.testing.expectEqual(@as(i64, 77), age);
            try std.testing.expectEqual(@as(i64, 13_000), time);
            try std.testing.expect(ticking);
        },
        else => return error.UnexpectedPacket,
    }
}

fn testNonPlayOutputCodec(comptime ProtocolModule: type, comptime WireCodec: type, bytes: []u8) !void {
    const status = try WireCodec.encodeStatusResponse(bytes, "{}");
    _ = try ProtocolModule.status.toClient.read(status).name();

    const login = try WireCodec.encodeLoginSuccess(bytes, 9, "player");
    _ = try ProtocolModule.login.toClient.read(login).name();

    const compression = try WireCodec.encodeSetCompression(bytes, 256);
    _ = try ProtocolModule.login.toClient.read(compression).name();

    const flags = try WireCodec.encodeFeatureFlags(bytes);
    _ = try ProtocolModule.configuration.toClient.read(flags).name();

    const tags = try WireCodec.encodeConfigurationTags(bytes, &.{0});
    _ = try ProtocolModule.configuration.toClient.read(tags).name();
}

test "each generated codec encodes tick packets with its wire protocol" {
    inline for (protocol_catalog.entries) |Entry|
        try testOutputCodec(Entry.Protocol, Codec(Entry.version));
}

fn testConnectionStateDecode(comptime ProtocolModule: type, comptime WireCodec: type) !void {
    var bytes: [128]u8 = undefined;

    const status_writer = ProtocolModule.status.toServer.write(&bytes);
    const request = try status_writer.ping_start();
    const request_body = (try request.finish()).finish();
    try std.testing.expectEqual(protocol_values.StatusCommand.request, try WireCodec.decodeStatus(request_body));

    const login_writer = ProtocolModule.login.toServer.write(&bytes);
    const start = try login_writer.login_start();
    const username = try start.username("player");
    const start_body = (try username.playerUUID(9)).finish();
    switch (try WireCodec.decodeLogin(start_body)) {
        .start => |decoded| {
            try std.testing.expectEqualStrings("player", decoded.username);
            try std.testing.expectEqual(@as(u128, 9), decoded.uuid);
        },
        else => return error.UnexpectedCommand,
    }

    const configuration_writer = ProtocolModule.configuration.toServer.write(&bytes);
    const finish = try configuration_writer.finish_configuration();
    const finish_body = (try finish.finish()).finish();
    try std.testing.expectEqual(protocol_values.ConfigurationCommand.finish, try WireCodec.decodeConfiguration(finish_body));
}

test "each generated codec decodes every post-handshake state" {
    inline for (protocol_catalog.entries) |Entry|
        try testConnectionStateDecode(Entry.Protocol, Codec(Entry.version));
}
