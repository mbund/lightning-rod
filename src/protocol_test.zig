const protocol = @import("protocol");
const protocol_support = @import("protocol_support");
const std = @import("std");

fn bytes(comptime hex: []const u8) [hex.len / 2]u8 {
    comptime var result = std.mem.zeroes([hex.len / 2]u8);
    _ = comptime std.fmt.hexToBytes(&result, hex) catch @compileError("invalid hex: " ++ hex);
    return result;
}

test "reading integer from random bytes" {
    const buffer = &bytes("00409a44b81e634200409a44");
    const int, const rest = try protocol_support.read_int(buffer, u32);

    try std.testing.expectEqual(0x00409a44, int);
    try std.testing.expectEqualSlices(u8, rest, &bytes("b81e634200409a44"));
}

test "protocol support reads nbt fields as zero-copy slices" {
    const named = &bytes("0a000000ff");
    const named_value, const named_rest = try protocol_support.read_nbt(named);
    try std.testing.expectEqualSlices(u8, &bytes("0a000000"), named_value);
    try std.testing.expectEqualSlices(u8, &bytes("ff"), named_rest);

    const anonymous = &bytes("0a00ff");
    const anonymous_value, const anonymous_rest = try protocol_support.read_anonymousNbt(anonymous);
    try std.testing.expectEqualSlices(u8, &bytes("0a00"), anonymous_value);
    try std.testing.expectEqualSlices(u8, &bytes("ff"), anonymous_rest);

    const absent = &bytes("00ff");
    const absent_value, const absent_rest = try protocol_support.read_optionalNbt(absent);
    try std.testing.expectEqual(null, absent_value);
    try std.testing.expectEqualSlices(u8, &bytes("ff"), absent_rest);

    const present = &bytes("0a00ff");
    const present_value, const present_rest = try protocol_support.read_anonOptionalNbt(present);
    try std.testing.expectEqualSlices(u8, &bytes("0a00"), present_value.?);
    try std.testing.expectEqualSlices(u8, &bytes("ff"), present_rest);
}

test "protocol support writes nbt fields without allocation" {
    var buffer: [16]u8 = undefined;

    const after_nbt = try protocol_support.write_nbt(&buffer, &bytes("0a000000"));
    try std.testing.expectEqualSlices(u8, &bytes("0a000000"), buffer[0..4]);
    try std.testing.expectEqual(buffer[4..].len, after_nbt.len);

    const after_absent = try protocol_support.write_optionalNbt(&buffer, null);
    try std.testing.expectEqualSlices(u8, &bytes("00"), buffer[0..1]);
    try std.testing.expectEqual(buffer[1..].len, after_absent.len);

    const after_present = try protocol_support.write_anonOptionalNbt(&buffer, &bytes("0a00"));
    try std.testing.expectEqualSlices(u8, &bytes("0a00"), buffer[0..2]);
    try std.testing.expectEqual(buffer[2..].len, after_present.len);
}

test "handshaking set_protocol" {
    const buffer = &bytes("008406093132372e302e302e3163dd01");
    const c1 = protocol.handshaking.toServer.read(buffer);
    switch (try c1.name()) {
        .set_protocol => |c2| {
            const protocol_version, const c3 = try c2.protocolVersion();
            const server_host, const c4 = try c3.serverHost();
            const server_port, const c5 = try c4.serverPort();
            const next_state, const c6 = try c5.nextState();

            try std.testing.expectEqual(772, protocol_version);
            try std.testing.expectEqualSlices(u8, "127.0.0.1", server_host);
            try std.testing.expectEqual(25565, server_port);
            try std.testing.expectEqual(1, next_state);
            try c6.finish();
        },
        .legacy_server_list_ping => {
            return error.No;
        },
        .default => {
            return error.No;
        },
    }
}

test "status ping" {
    const buffer = &bytes("01000000000000158b");
    const c1 = protocol.status.toServer.read(buffer);
    switch (try c1.name()) {
        .ping => |c2| {
            const time, const c3 = try c2.time();

            try std.testing.expectEqual(5515, time);
            try c3.finish();
        },
        .ping_start => {
            return error.No;
        },
        .default => {
            return error.No;
        },
    }
}

test "login login_start" {
    const buffer = &bytes("000a77617270636f726530351a13faa879e54c248997b6dd9b14e23d");
    const c1 = protocol.login.toServer.read(buffer);
    switch (try c1.name()) {
        .login_start => |c2| {
            const username, const c3 = try c2.username();
            const player_uuid, const c4 = try c3.playerUUID();

            try std.testing.expectEqualStrings("warpcore05", username);
            try std.testing.expectEqual(34663665481177079509380347836620923453, player_uuid);
            try c4.finish();
        },
        else => return error.No,
    }
}

test "play window_click skips array and option fields zero-copy" {
    const buffer = &bytes("110102000500000100070000");
    const c1 = protocol.play.toServer.read(buffer);
    switch (try c1.name()) {
        .window_click => |c2| {
            const window_id, const c3 = try c2.windowId();
            const state_id, const c4 = try c3.stateId();
            const slot, const c5 = try c4.slot();
            const mouse_button, const c6 = try c5.mouseButton();
            const mode, const c7 = try c6.mode();
            const changed_slots, const c8 = try c7.changedSlots();
            const cursor_item, const c9 = try c8.cursorItem();
            var changed_slots_iter = try changed_slots.iter();
            const changed_slot = (try changed_slots_iter.next()) orelse return error.No;
            const changed_location, const changed_item_cursor = try changed_slot.location();
            const changed_item, _ = try changed_item_cursor.item();
            const changed_item_value = try changed_item.value();
            const cursor_item_value = try cursor_item.value();

            try std.testing.expectEqual(1, window_id);
            try std.testing.expectEqual(2, state_id);
            try std.testing.expectEqual(5, slot);
            try std.testing.expectEqual(0, mouse_button);
            try std.testing.expectEqual(0, mode);
            try std.testing.expectEqualSlices(u8, &bytes("01000700"), changed_slots.payload());
            try std.testing.expectEqual(7, changed_location);
            try std.testing.expectEqual(null, changed_item_value);
            try std.testing.expectEqualSlices(u8, &bytes("00"), cursor_item.payload());
            try std.testing.expectEqual(null, cursor_item_value);
            try c9.finish();
        },
        else => return error.No,
    }
}

test "play window_click decodes nested option container and arrays" {
    const buffer = &bytes("11010200050000000107010000");
    const c1 = protocol.play.toServer.read(buffer);
    switch (try c1.name()) {
        .window_click => |c2| {
            const window_id, const c3 = try c2.windowId();
            const state_id, const c4 = try c3.stateId();
            const slot, const c5 = try c4.slot();
            const mouse_button, const c6 = try c5.mouseButton();
            const mode, const c7 = try c6.mode();
            const changed_slots, const c8 = try c7.changedSlots();
            const cursor_item, const c9 = try c8.cursorItem();

            const cursor_slot = (try cursor_item.value()) orelse return error.No;
            const cursor_item_id, const cursor_count_cursor = try cursor_slot.itemId();
            const cursor_item_count, const cursor_components_cursor = try cursor_count_cursor.itemCount();
            const components, const cursor_remove_components_cursor = try cursor_components_cursor.components();
            const remove_components, _ = try cursor_remove_components_cursor.removeComponents();

            try std.testing.expectEqual(1, window_id);
            try std.testing.expectEqual(2, state_id);
            try std.testing.expectEqual(5, slot);
            try std.testing.expectEqual(0, mouse_button);
            try std.testing.expectEqual(0, mode);
            try std.testing.expectEqual(0, try changed_slots.len());
            try std.testing.expectEqual(7, cursor_item_id);
            try std.testing.expectEqual(1, cursor_item_count);
            try std.testing.expectEqual(0, try components.len());
            try std.testing.expectEqual(0, try remove_components.len());
            try cursor_item.finish();
            try c9.finish();
        },
        else => return error.No,
    }
}

test "handshaking set_protocol encodes with cursor style" {
    var buffer: [64]u8 = undefined;
    const c1 = protocol.handshaking.toServer.write(&buffer);
    const c2 = try c1.set_protocol();
    const c3 = try c2.protocolVersion(772);
    const c4 = try c3.serverHost("127.0.0.1");
    const c5 = try c4.serverPort(25565);
    const c6 = try c5.nextState(1);
    const written = c6.finish();

    try std.testing.expectEqualSlices(u8, &bytes("008406093132372e302e302e3163dd01"), written);
}

test "status ping encodes with cursor style" {
    var buffer: [16]u8 = undefined;
    const c1 = protocol.status.toServer.write(&buffer);
    const c2 = try c1.ping();
    const c3 = try c2.time(5515);
    const written = c3.finish();

    try std.testing.expectEqualSlices(u8, &bytes("01000000000000158b"), written);
}

test "play window_click encodes complex fields without allocation" {
    var buffer: [32]u8 = undefined;
    const c1 = protocol.play.toServer.write(&buffer);
    const c2 = try c1.window_click();
    const c3 = try c2.windowId(1);
    const c4 = try c3.stateId(2);
    const c5 = try c4.slot(5);
    const c6 = try c5.mouseButton(0);
    const c7 = try c6.mode(0);
    const changed_slots = try c7.changedSlots(1);
    const changed_slot = try changed_slots.element();
    const after_location = try changed_slot.location(7);
    const after_changed_slots = try (try after_location.item()).none();
    const c8 = try after_changed_slots.finish();
    const c9 = try (try c8.cursorItem()).none();
    const written = c9.finish();

    try std.testing.expectEqualSlices(u8, &bytes("110102000500000100070000"), written);
}

test "play window_click encodes nested option container switch and arrays" {
    var buffer: [64]u8 = undefined;
    const c1 = protocol.play.toServer.write(&buffer);
    const c2 = try c1.window_click();
    const c3 = try c2.windowId(1);
    const c4 = try c3.stateId(2);
    const c5 = try c4.slot(5);
    const c6 = try c5.mouseButton(0);
    const c7 = try c6.mode(0);
    const c8 = try (try c7.changedSlots(0)).finish();
    const slot = try (try c8.cursorItem()).some();
    const after_item_id = try slot.itemId(7);
    const after_item_count = try after_item_id.itemCount(1);
    const after_components = try (try after_item_count.components(0)).finish();
    const c9 = try (try after_components.removeComponents(0)).finish();
    const written = c9.finish();

    try std.testing.expectEqualSlices(u8, &bytes("11010200050000000107010000"), written);
}

test "play block_place decodes packed position as typed fields" {
    const buffer = &bytes("3f00000000400000200301000000000000000000000000000105");
    const c1 = protocol.play.toServer.read(buffer);
    switch (try c1.name()) {
        .block_place => |c2| {
            const hand, const c3 = try c2.hand();
            const location, const c4 = try c3.location();
            const direction, const c5 = try c4.direction();
            const cursor_x, const c6 = try c5.cursorX();
            const cursor_y, const c7 = try c6.cursorY();
            const cursor_z, const c8 = try c7.cursorZ();
            const inside_block, const c9 = try c8.insideBlock();
            const world_border_hit, const c10 = try c9.worldBorderHit();
            const sequence, const c11 = try c10.sequence();

            try std.testing.expectEqual(0, hand);
            try std.testing.expectEqual(1, location.x);
            try std.testing.expectEqual(2, location.z);
            try std.testing.expectEqual(3, location.y);
            try std.testing.expectEqual(1, direction);
            try std.testing.expectEqual(@as(f32, 0), cursor_x);
            try std.testing.expectEqual(@as(f32, 0), cursor_y);
            try std.testing.expectEqual(@as(f32, 0), cursor_z);
            try std.testing.expectEqual(false, inside_block);
            try std.testing.expectEqual(true, world_border_hit);
            try std.testing.expectEqual(5, sequence);
            try c11.finish();
        },
        else => return error.No,
    }
}

test "play block_place encodes typed packed position" {
    var buffer: [32]u8 = undefined;
    const c1 = protocol.play.toServer.write(&buffer);
    const c2 = try c1.block_place();
    const c3 = try c2.hand(0);
    const c4 = try c3.location(.{ .x = 1, .z = 2, .y = 3 });
    const c5 = try c4.direction(1);
    const c6 = try c5.cursorX(0);
    const c7 = try c6.cursorY(0);
    const c8 = try c7.cursorZ(0);
    const c9 = try c8.insideBlock(false);
    const c10 = try c9.worldBorderHit(true);
    const c11 = try c10.sequence(5);
    const written = c11.finish();

    try std.testing.expectEqualSlices(u8, &bytes("3f00000000400000200301000000000000000000000000000105"), written);
}

test "nested array writer validates element count" {
    var buffer: [16]u8 = undefined;
    const c1 = protocol.play.toServer.write(&buffer);
    const c2 = try c1.window_click();
    const c3 = try c2.windowId(1);
    const c4 = try c3.stateId(2);
    const c5 = try c4.slot(5);
    const c6 = try c5.mouseButton(0);
    const c7 = try c6.mode(0);
    const changed_slots = try c7.changedSlots(1);

    try std.testing.expectError(error.MissingItems, changed_slots.finish());
}

test "toServer encode reports short output buffer" {
    var buffer: [2]u8 = undefined;
    const c1 = protocol.status.toServer.write(&buffer);
    const c2 = try c1.ping();

    try std.testing.expectError(error.EndOfStream, c2.time(5515));
}

test "status toClient server_info encodes with cursor style" {
    var buffer: [16]u8 = undefined;
    const c1 = protocol.status.toClient.write(&buffer);
    const c2 = try c1.server_info();
    const c3 = try c2.response("Hello");
    const written = c3.finish();

    try std.testing.expectEqualSlices(u8, &bytes("000548656c6c6f"), written);
}

test "status toClient ping encodes with cursor style" {
    var buffer: [16]u8 = undefined;
    const c1 = protocol.status.toClient.write(&buffer);
    const c2 = try c1.ping();
    const c3 = try c2.time(5515);
    const written = c3.finish();

    try std.testing.expectEqualSlices(u8, &bytes("01000000000000158b"), written);
}

test "login toClient encryption_begin encodes counted buffers" {
    var buffer: [16]u8 = undefined;
    const c1 = protocol.login.toClient.write(&buffer);
    const c2 = try c1.encryption_begin();
    const c3 = try c2.serverId("");
    const c4 = try c3.publicKey(&bytes("aabb"));
    const c5 = try c4.verifyToken(&bytes("cc"));
    const c6 = try c5.shouldAuthenticate(true);
    const written = c6.finish();

    try std.testing.expectEqualSlices(u8, &bytes("010002aabb01cc01"), written);
}

test "play toClient explosion encodes deep typed vibration position" {
    var buffer: [64]u8 = undefined;
    const c1 = protocol.play.toClient.write(&buffer);
    const c2 = try c1.explosion();
    const c3 = try c2.x(0);
    const c4 = try c3.y(0);
    const c5 = try c4.z(0);
    const c6 = try (try c5.playerKnockback()).none();
    const particle = try c6.explosionParticle();
    const particle_data = try (try particle.type(47)).data();
    const vibration = try particle_data.case_vibration();
    const position = try (try vibration.positionType(0)).position();
    const after_position = try position.case_block(.{ .x = 1, .z = 2, .y = 3 });
    const c7 = try after_position.ticks(5);
    const c8 = try (try c7.sound()).soundId(1);
    const written = c8.finish();

    try std.testing.expectEqualSlices(u8, &bytes("20000000000000000000000000000000000000000000000000002f0000000040000020030501"), written);
}

test "play toClient explosion item particle encodes empty slot with typed switch" {
    var buffer: [64]u8 = undefined;
    const c1 = protocol.play.toClient.write(&buffer);
    const c2 = try c1.explosion();
    const c3 = try c2.x(0);
    const c4 = try c3.y(0);
    const c5 = try c4.z(0);
    const c6 = try (try c5.playerKnockback()).none();
    const particle = try c6.explosionParticle();
    const particle_data = try (try particle.type(46)).data();
    const item = try particle_data.case_item();
    const item_switch = try (try item.itemCount(0)).anon();
    const after_item = try item_switch.case_0();
    const c7 = try (try after_item.sound()).soundId(1);
    const written = c7.finish();

    try std.testing.expectEqualSlices(u8, &bytes("20000000000000000000000000000000000000000000000000002e0001"), written);
}

test "play toClient explosion decodes registry holder sound" {
    const buffer = &bytes("20000000000000000000000000000000000000000000000000002f0000000040000020030501");
    const c1 = protocol.play.toClient.read(buffer);

    switch (try c1.name()) {
        .explosion => |packet| {
            _, const c2 = try packet.x();
            _, const c3 = try c2.y();
            _, const c4 = try c3.z();
            const player_knockback, const c5 = try c4.playerKnockback();
            const particle, const c6 = try c5.explosionParticle();
            const particle_type, const particle_data_cursor = try particle.type();
            try std.testing.expectEqual(@as(i32, 47), particle_type);
            const particle_data, _ = try particle_data_cursor.data();
            const vibration = try particle_data.case_vibration();
            const position_type, const vibration_position_cursor = try vibration.positionType();
            try std.testing.expectEqual(@as(i32, 0), position_type);
            const position, const vibration_ticks_cursor = try vibration_position_cursor.position();
            const block_pos = try position.case_block();
            try std.testing.expectEqual(@as(i32, 1), block_pos.x);
            try std.testing.expectEqual(@as(i32, 2), block_pos.z);
            try std.testing.expectEqual(@as(i16, 3), block_pos.y);
            const vibration_ticks, _ = try vibration_ticks_cursor.ticks();
            try std.testing.expectEqual(@as(i32, 5), vibration_ticks);

            const sound, const done = try c6.sound();
            switch (try sound.value()) {
                .soundId => |id| try std.testing.expectEqual(@as(i32, 1), id),
                .data => return error.UnexpectedSoundData,
            }
            try player_knockback.finish();
            try particle.finish();
            try sound.finish();
            try done.finish();
        },
        else => return error.UnexpectedPacket,
    }
}

test "toClient encode reports short output buffer" {
    var buffer: [2]u8 = undefined;
    const c1 = protocol.status.toClient.write(&buffer);
    const c2 = try c1.server_info();

    try std.testing.expectError(error.EndOfStream, c2.response("Hello"));
}

test "status toClient envelope exposes raw payload" {
    const buffer = &bytes("000548656c6c6f");
    const c1 = protocol.status.toClient.read(buffer);
    switch (try c1.name()) {
        .server_info => |packet| {
            const response, const done = try packet.response();

            try std.testing.expectEqualStrings("Hello", response);
            try done.finish();
        },
        else => return error.No,
    }
}

test "status toClient ping decodes inner typed field" {
    const buffer = &bytes("01000000000000158b");
    const c1 = protocol.status.toClient.read(buffer);
    switch (try c1.name()) {
        .ping => |packet| {
            const time, const done = try packet.time();

            try std.testing.expectEqual(5515, time);
            try done.finish();
        },
        else => return error.No,
    }
}

test "login toClient encryption_begin exposes typed buffer views" {
    const buffer = &bytes("010002aabb01cc01");
    const c1 = protocol.login.toClient.read(buffer);
    switch (try c1.name()) {
        .encryption_begin => |packet| {
            const server_id, const c2 = try packet.serverId();
            const public_key, const c3 = try c2.publicKey();
            const verify_token, const c4 = try c3.verifyToken();
            const should_authenticate, const c5 = try c4.shouldAuthenticate();

            try std.testing.expectEqualStrings("", server_id);
            try std.testing.expectEqualSlices(u8, &bytes("02aabb"), public_key.payload());
            try std.testing.expectEqualSlices(u8, &bytes("01cc"), verify_token.payload());
            try std.testing.expectEqual(true, should_authenticate);
            try public_key.finish();
            try verify_token.finish();
            try c5.finish();
        },
        else => return error.No,
    }
}

test "play toClient window_items exposes typed array view" {
    const buffer = &bytes("1201020000");
    const c1 = protocol.play.toClient.read(buffer);
    switch (try c1.name()) {
        .window_items => |packet| {
            const window_id, const c2 = try packet.windowId();
            const state_id, const c3 = try c2.stateId();
            const items, const c4 = try c3.items();
            var iter = try items.iter();
            const carried, const done = try c4.carriedItem();

            try std.testing.expectEqual(1, window_id);
            try std.testing.expectEqual(2, state_id);
            try std.testing.expectEqual(0, try items.len());
            try std.testing.expectEqual(null, try iter.next());
            const carried_item_count, _ = try carried.itemCount();
            try std.testing.expectEqual(0, carried_item_count);
            try items.finish();
            try carried.finish();
            try done.finish();
        },
        else => return error.No,
    }
}

test "play toClient window_items decodes field-counted slot component arrays" {
    const buffer = &bytes("120102000107000110");
    const c1 = protocol.play.toClient.read(buffer);
    switch (try c1.name()) {
        .window_items => |packet| {
            _, const c2 = try packet.windowId();
            _, const c3 = try c2.stateId();
            const items, const c4 = try c3.items();
            const carried, const done = try c4.carriedItem();
            const carried_item_count, const carried_anon_cursor = try carried.itemCount();
            const carried_anon, _ = try carried_anon_cursor.anon();
            const carried_slot = try carried_anon.case_default();
            const carried_item_id, const carried_added_count_cursor = try carried_slot.itemId();
            _, const carried_removed_count_cursor = try carried_added_count_cursor.addedComponentCount();
            const carried_removed_count, const carried_components_cursor = try carried_removed_count_cursor.removedComponentCount();
            _, const carried_remove_components_cursor = try carried_components_cursor.components();
            const remove_components, _ = try carried_remove_components_cursor.removeComponents();
            var iter = try remove_components.iter();
            const removed = (try iter.next()) orelse return error.NoRemovedComponent;

            try std.testing.expectEqual(0, try items.len());
            try std.testing.expectEqual(1, carried_item_count);
            try std.testing.expectEqual(7, carried_item_id);
            try std.testing.expectEqual(1, carried_removed_count);
            try std.testing.expectEqual(1, try remove_components.len());
            const removed_type, _ = try removed.type();
            try std.testing.expectEqual(16, removed_type);
            try std.testing.expectEqual(@as(?@TypeOf(removed), null), try iter.next());

            try remove_components.finish();
            try carried_slot.finish();
            try carried.finish();
            try done.finish();
        },
        else => return error.No,
    }
}

test "play toClient window_items encodes non-empty slot without raw payload" {
    var buffer: [32]u8 = undefined;
    const c1 = protocol.play.toClient.write(&buffer);
    const c2 = try c1.window_items();
    const c3 = try c2.windowId(1);
    const c4 = try c3.stateId(2);
    const items = try c4.items(1);
    const item = try items.element();
    const item_switch = try (try item.itemCount(1)).anon();
    const present = try item_switch.case_default();
    const after_item_id = try present.itemId(7);
    const after_added = try after_item_id.addedComponentCount(0);
    const after_removed = try after_added.removedComponentCount(0);
    const after_components = try (try after_removed.components(0)).finish();
    const after_items = try (try after_components.removeComponents(0)).finish();
    const carried = try after_items.finish();
    const carried_switch = try (try (try carried.carriedItem()).itemCount(0)).anon();
    const written = (try carried_switch.case_0()).finish();

    try std.testing.expectEqualSlices(u8, &bytes("120102010107000000"), written);
}

test "play toClient declare_commands encodes typed command properties" {
    var buffer: [64]u8 = undefined;
    const c1 = protocol.play.toClient.write(&buffer);
    const c2 = try c1.declare_commands();
    const nodes = try c2.nodes(1);
    const node = try nodes.element();
    const after_flags = try node.flags(.{
        .unused = 0,
        .allows_restricted = false,
        .has_custom_suggestions = true,
        .has_redirect_node = false,
        .has_command = false,
        .command_node_type = 2,
    });
    const after_children = try (try after_flags.children(0)).finish();
    const after_redirect = try (try after_children.redirectNode()).case_default();
    const command = try (try after_redirect.extraNodeData()).case_2();
    const after_name = try command.name("x");
    const after_parser = try after_name.parser(1);
    const float_props = try (try after_parser.properties()).case_brigadier_float();
    const after_prop_flags = try float_props.flags(.{ .unused = 0, .max_present = true, .min_present = true });
    const after_min = try (try after_prop_flags.min()).case_1(1);
    const after_max = try (try after_min.max()).case_1(2);
    const after_node = try (try after_max.suggestionType()).case_1("a");
    const after_nodes = try after_node.finish();
    const written = (try after_nodes.rootIndex(0)).finish();

    try std.testing.expectEqualSlices(u8, &bytes("10011200017801033f80000040000000016100"), written);
}

test "play toClient craft_recipe_response encodes empty slot displays without encoded payloads" {
    var buffer: [32]u8 = undefined;
    const c1 = protocol.play.toClient.write(&buffer);
    const c2 = try c1.craft_recipe_response();
    const c3 = try c2.windowId(1);
    const display = try c3.recipeDisplay();
    const display_data = try (try display.type(0)).data();
    const shapeless = try display_data.case_crafting_shapeless();
    const after_ingredients = try (try shapeless.ingredients(0)).finish();
    const result_display = try after_ingredients.result();
    const after_result = try (try (try result_display.type(0)).data()).case_empty();
    const station_display = try after_result.craftingStation();
    const written = (try (try (try station_display.type(0)).data()).case_empty()).finish();

    try std.testing.expectEqualSlices(u8, &bytes("380100000000"), written);
}

test "play toClient recipe_book_add encodes typed requirements holder set" {
    var buffer: [64]u8 = undefined;
    const c1 = protocol.play.toClient.write(&buffer);
    const c2 = try c1.recipe_book_add();
    const entries = try c2.entries(1);
    const entry = try entries.element();
    const recipe = try entry.recipe();
    const after_display_id = try recipe.displayId(5);
    const display = try after_display_id.display();
    const shapeless = try (try (try display.type(0)).data()).case_crafting_shapeless();
    const after_ingredients = try (try shapeless.ingredients(0)).finish();
    const result_display = try after_ingredients.result();
    const after_result = try (try (try result_display.type(0)).data()).case_empty();
    const station_display = try after_result.craftingStation();
    const after_display = try (try (try station_display.type(0)).data()).case_empty();
    const after_group = try after_display.group(0);
    const after_category = try after_group.category(0);
    const requirements = try (try after_category.craftingRequirements()).some(1);
    const requirement = try requirements.element();
    const after_id_set = try (try requirement.ids(1)).element(9);
    const after_requirement = try after_id_set.finish();
    const after_requirements = try after_requirement.finish();
    const after_flags = try after_requirements.flags(.{});
    const written = (try (try after_flags.finish()).replace(false)).finish();

    try std.testing.expectEqualSlices(u8, &bytes("430105000000000000010102090000"), written);
}
