const std = @import("std");
const generated = @import("canonical_spec");
const protocol_catalog = @import("protocol_catalog");
const packet_model = @import("packet.zig");

pub fn encode(buffer: []u8, packet: packet_model.Packet) ![]const u8 {
    const Default = protocol_catalog.entries[@intFromEnum(protocol_catalog.default)];
    return encodeWith(Default.Protocol, Default.Registry, buffer, packet, &.{});
}

pub fn encodeWithIdentities(buffer: []u8, packet: packet_model.Packet, identities: []const @import("raw_packet.zig").Identity) ![]const u8 {
    const Default = protocol_catalog.entries[@intFromEnum(protocol_catalog.default)];
    return encodeWith(Default.Protocol, Default.Registry, buffer, packet, identities);
}

pub fn encodeForMinecraft(buffer: []u8, packet: packet_model.Packet, minecraft: []const u8) ![]const u8 {
    return encodeForMinecraftWithIdentities(buffer, packet, &.{}, minecraft);
}

pub fn encodeForMinecraftWithIdentities(
    buffer: []u8,
    packet: packet_model.Packet,
    identities: []const @import("raw_packet.zig").Identity,
    minecraft: []const u8,
) ![]const u8 {
    if (minecraft.len == 0) {
        const Default = protocol_catalog.entries[@intFromEnum(protocol_catalog.default)];
        return encodeWith(Default.Protocol, Default.Registry, buffer, packet, identities);
    }
    const version = protocol_catalog.fromMinecraftName(minecraft) orelse
        return error.UnsupportedMinecraftVersion;
    inline for (protocol_catalog.entries) |Entry| if (version == Entry.version)
        return encodeWith(Entry.Protocol, Entry.Registry, buffer, packet, identities);
    unreachable;
}

fn encodeWith(comptime Protocol: type, comptime Registry: type, buffer: []u8, packet: packet_model.Packet, identities: []const @import("raw_packet.zig").Identity) ![]const u8 {
    if (std.mem.startsWith(u8, packet.name, "wire/")) return encodeGeneratedWirePacket(Protocol, buffer, packet);
    if (std.mem.eql(u8, packet.name, "entity_action")) return encodeEntityAction(Protocol, buffer, packet, identities);
    if (std.mem.eql(u8, packet.name, "player_input")) return encodePlayerInput(Protocol, buffer, packet);
    if (std.mem.eql(u8, packet.name, "interact_entity")) return encodeEntityInteraction(Protocol, buffer, packet, identities);
    if (std.mem.eql(u8, packet.name, "command")) return encodeCommand(Protocol, buffer, packet);
    if (std.mem.eql(u8, packet.name, "creative_slot")) return encodeCreativeSlot(Protocol, Registry, buffer, packet);
    if (std.mem.eql(u8, packet.name, "respawn")) {
        const body = try Protocol.play.toServer.write(buffer).client_command();
        return (try body.actionId(0)).finish();
    }
    inline for (generated.serverbound) |mapping| {
        if (mapping.encode and std.mem.eql(u8, packet.name, mapping.canonical)) {
            if (mapping.handler == .entity_attack) return encodeEntityAttack(Protocol, buffer, packet, identities);
            if (mapping.handler == .container_click) return encodeContainerClick(Protocol, buffer, packet);
            const root = Protocol.play.toServer.write(buffer);
            const body = try @field(@TypeOf(root), mapping.wire)(root);
            return encodeMappedFields(mapping.fields, 0, body, packet);
        }
    }
    return error.UnsupportedInputPacket;
}

fn encodeCommand(comptime Protocol: type, buffer: []u8, packet: packet_model.Packet) ![]const u8 {
    const root = Protocol.play.toServer.write(buffer);
    const body = try root.chat_command();
    return (try body.command(literalField(packet, "text") orelse return error.MissingField)).finish();
}

fn encodeCreativeSlot(comptime Protocol: type, comptime Registry: type, buffer: []u8, packet: packet_model.Packet) ![]const u8 {
    const count = try intField(u8, packet, "count");
    const root = Protocol.play.toServer.write(buffer);
    const body = try root.set_creative_slot();
    const item_field = try body.slot(try intField(i16, packet, "slot"));
    const item = try item_field.item();
    const value = try item.itemCount(count);
    const branch = try value.anon();
    if (count == 0) return (try branch.case_0()).finish();
    const name = literalField(packet, "item") orelse return error.MissingField;
    const wire_item_id = Registry.itemId(name) orelse return error.UnknownItem;
    const present = try branch.case_default();
    const added = try present.itemId(wire_item_id);
    const removed = try added.addedComponentCount(0);
    const components = try removed.removedComponentCount(0);
    const remove_components = try (try components.components(0)).finish();
    return (try (try remove_components.removeComponents(0)).finish()).finish();
}

fn encodeEntityInteraction(comptime Protocol: type, buffer: []u8, packet: packet_model.Packet, identities: []const @import("raw_packet.zig").Identity) ![]const u8 {
    const target = literalField(packet, "target") orelse return error.MissingField;
    var entity_id: ?i32 = null;
    for (identities) |identity| if (std.mem.eql(u8, identity.alias, target)) {
        entity_id = identity.entity_id;
        break;
    };
    const hand = try intField(i32, packet, "hand");
    const c1 = Protocol.play.toServer.write(buffer);
    const c2 = try c1.use_entity();
    const c3 = try c2.target(entity_id orelse return error.UnknownInputEntity);
    const c4 = try c3.mouse(0);
    const c5 = try (try c4.x()).case_default();
    const c6 = try (try c5.y()).case_default();
    const c7 = try (try c6.z()).case_default();
    const c8 = try (try c7.hand()).case_0(hand);
    return (try c8.sneaking(false)).finish();
}

fn encodePlayerInput(comptime Protocol: type, buffer: []u8, packet: packet_model.Packet) ![]const u8 {
    const root = Protocol.play.toServer.write(buffer);
    const body = try root.player_input();
    return (try body.inputs(.{
        .shift = try boolField(packet, "shift"),
        .sprint = try boolField(packet, "sprint"),
    })).finish();
}

fn encodeEntityAction(comptime Protocol: type, buffer: []u8, packet: packet_model.Packet, identities: []const @import("raw_packet.zig").Identity) ![]const u8 {
    const subject = literalField(packet, "subject") orelse return error.MissingField;
    var entity_id: ?i32 = null;
    for (identities) |identity| if (std.mem.eql(u8, identity.alias, subject)) {
        entity_id = identity.entity_id;
        break;
    };
    const action = literalField(packet, "action") orelse return error.MissingField;
    const action_id: i32 = if (std.mem.eql(u8, action, "start_sprinting"))
        1
    else if (std.mem.eql(u8, action, "stop_sprinting"))
        2
    else
        return error.UnsupportedEntityAction;
    const root = Protocol.play.toServer.write(buffer);
    const body = try root.entity_action();
    const after_entity = try body.entityId(entity_id orelse return error.UnknownInputEntity);
    const after_action = try after_entity.actionId(action_id);
    return (try after_action.jumpBoost(0)).finish();
}

fn encodeEntityAttack(comptime Protocol: type, buffer: []u8, packet: packet_model.Packet, identities: []const @import("raw_packet.zig").Identity) ![]const u8 {
    const target = literalField(packet, "target") orelse return error.MissingField;
    var entity_id: ?i32 = null;
    for (identities) |identity| if (std.mem.eql(u8, identity.alias, target)) {
        entity_id = identity.entity_id;
        break;
    };
    const c1 = Protocol.play.toServer.write(buffer);
    const c2 = try c1.use_entity();
    const c3 = try c2.target(entity_id orelse return error.UnknownInputEntity);
    const c4 = try c3.mouse(1);
    const c5 = try (try c4.x()).case_default();
    const c6 = try (try c5.y()).case_default();
    const c7 = try (try c6.z()).case_default();
    const c8 = try (try c7.hand()).case_default();
    return (try c8.sneaking(false)).finish();
}

fn encodeGeneratedWirePacket(comptime Protocol: type, buffer: []u8, packet: packet_model.Packet) ![]const u8 {
    if (packet.fields.len != 1 or !std.mem.eql(u8, packet.fields[0].name, "data")) return error.InvalidGeneratedWirePacket;
    const text = packet.fields[0].value.literal;
    if (text.len == 0 or text[0] != 'h' or (text.len - 1) % 2 != 0) return error.InvalidGeneratedWirePacket;
    const result_len = (text.len - 1) / 2;
    if (result_len > buffer.len) return error.EndOfStream;
    for (0..result_len) |index| {
        buffer[index] = (try hexNibble(text[1 + index * 2])) << 4 | try hexNibble(text[2 + index * 2]);
    }
    const result = buffer[0..result_len];
    const decoded = try Protocol.play.toServer.read(result).name();
    if (!std.mem.eql(u8, @tagName(std.meta.activeTag(decoded)), packet.name["wire/".len..])) return error.GeneratedWirePacketNameMismatch;
    return result;
}

fn hexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidGeneratedWirePacket,
    };
}

fn encodeMappedFields(comptime mappings: []const generated.Field, comptime index: usize, cursor: anytype, packet: packet_model.Packet) ![]const u8 {
    if (index == mappings.len) return cursor.finish();
    const mapping = mappings[index];
    const method = @field(@TypeOf(cursor), mapping.wire);
    const next = switch (mapping.codec) {
        .float => try method(cursor, try numberField(methodParameter(method), packet, mapping.canonical)),
        .integer => try method(cursor, try integerField(methodParameter(method), packet, mapping.canonical)),
        .flags_on_ground => try method(cursor, .{ .onGround = try boolField(packet, mapping.canonical) }),
        .action => try method(cursor, try actionField(packet, mapping.canonical)),
        .block_position => position: {
            const pos = try blockPosField(packet, mapping.canonical);
            break :position try method(cursor, .{ .x = pos.x, .z = pos.z, .y = pos.y });
        },
        .face => try method(cursor, try faceField(packet, mapping.canonical)),
        .require_player_screen => screen: {
            if (!std.mem.eql(u8, literalField(packet, mapping.canonical) orelse return error.MissingField, "player")) return error.InvalidCloseScreen;
            break :screen try method(cursor, 0);
        },
        .fixed_zero, .fixed_main_hand => try method(cursor, 0),
        .fixed_cursor => try method(cursor, 0.5),
        .fixed_false => try method(cursor, false),
        else => return error.UnsupportedGeneratedInputCodec,
    };
    return encodeMappedFields(mappings, index + 1, next, packet);
}

fn encodeContainerClick(comptime Protocol: type, buffer: []u8, packet: packet_model.Packet) ![]const u8 {
    if (packet.fields.len != 4 and packet.fields.len != 7) return error.InvalidContainerClick;
    const c1 = Protocol.play.toServer.write(buffer);
    const c2 = try c1.window_click();
    const c3 = try c2.windowId(try intField(i32, packet, "window"));
    const c4 = try c3.stateId(0);
    const c5 = try c4.slot(try intField(i16, packet, "slot"));
    const c6 = try c5.mouseButton(try intField(i8, packet, "button"));
    const c7 = try c6.mode(try intField(i32, packet, "mode"));
    const c8 = if (packet.fields.len == 4)
        try c7.changedSlotsEmpty()
    else claimed: {
        var entries = try c7.changedSlots(1);
        const entry = try entries.element();
        const location = try entry.location(try intField(i16, packet, "claimed_slot"));
        const item = try location.item();
        const value = try item.some();
        const item_count = try value.itemId(try intField(i32, packet, "claimed_item_id"));
        const components = try item_count.itemCount(try intField(i32, packet, "claimed_count"));
        const removals = try components.componentsEmpty();
        entries = try removals.removeComponentsEmpty();
        break :claimed try entries.finish();
    };
    return (try (try c8.cursorItem()).none()).finish();
}

fn floatField(packet: packet_model.Packet, name: []const u8) !f64 {
    return std.fmt.parseFloat(f64, literalField(packet, name) orelse return error.MissingField) catch error.InvalidField;
}

fn boolField(packet: packet_model.Packet, name: []const u8) !bool {
    const text = literalField(packet, name) orelse return error.MissingField;
    if (std.mem.eql(u8, text, "1")) return true;
    if (std.mem.eql(u8, text, "0")) return false;
    return error.InvalidField;
}

fn intField(comptime T: type, packet: packet_model.Packet, name: []const u8) !T {
    return std.fmt.parseInt(T, literalField(packet, name) orelse return error.MissingField, 10) catch error.InvalidField;
}

fn methodParameter(comptime method: anytype) type {
    return @typeInfo(@TypeOf(method)).@"fn".params[1].type.?;
}

fn numberField(comptime T: type, packet: packet_model.Packet, name: []const u8) !T {
    return std.fmt.parseFloat(T, literalField(packet, name) orelse return error.MissingField) catch error.InvalidField;
}

fn integerField(comptime T: type, packet: packet_model.Packet, name: []const u8) !T {
    return std.fmt.parseInt(T, literalField(packet, name) orelse return error.MissingField, 10) catch error.InvalidField;
}

fn actionField(packet: packet_model.Packet, name: []const u8) !i32 {
    const action = literalField(packet, name) orelse return error.MissingField;
    if (std.mem.eql(u8, action, "start_destroy_block")) return 0;
    if (std.mem.eql(u8, action, "abort_destroy_block")) return 1;
    if (std.mem.eql(u8, action, "stop_destroy_block")) return 2;
    return error.UnsupportedPlayerAction;
}

fn faceField(packet: packet_model.Packet, name: []const u8) !i32 {
    const face = literalField(packet, name) orelse return error.MissingField;
    const names = [_][]const u8{ "down", "up", "north", "south", "west", "east" };
    for (names, 0..) |candidate, value| {
        if (std.mem.eql(u8, face, candidate)) return @intCast(value);
    }
    return error.InvalidBlockFace;
}

fn literalField(packet: packet_model.Packet, name: []const u8) ?[]const u8 {
    for (packet.fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return field.value.literal;
    }
    return null;
}

fn blockPosField(packet: packet_model.Packet, name: []const u8) !struct { x: i32, y: i16, z: i32 } {
    var values = std.mem.splitScalar(u8, literalField(packet, name) orelse return error.MissingField, ',');
    const x = std.fmt.parseInt(i32, values.next() orelse return error.InvalidBlockPos, 10) catch return error.InvalidBlockPos;
    const y = std.fmt.parseInt(i16, values.next() orelse return error.InvalidBlockPos, 10) catch return error.InvalidBlockPos;
    const z = std.fmt.parseInt(i32, values.next() orelse return error.InvalidBlockPos, 10) catch return error.InvalidBlockPos;
    if (values.next() != null) return error.InvalidBlockPos;
    return .{ .x = x, .y = y, .z = z };
}
