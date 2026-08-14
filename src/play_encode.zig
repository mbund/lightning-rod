const player_store = @import("world/players.zig");
const std = @import("std");
const protocol_support = @import("protocol_support");

pub inline fn relativeMoveDelta(previous: f64, current: f64) i16 {
    const scaled = @round((current - previous) * 4096.0);
    return @intFromFloat(std.math.clamp(scaled, @as(f64, std.math.minInt(i16)), @as(f64, std.math.maxInt(i16))));
}

pub inline fn angleByte(degrees: f32) i8 {
    if (!std.math.isFinite(degrees)) return 0;
    var normalized = @rem(degrees, 360.0);
    if (normalized < 0) normalized += 360.0;
    const scaled: u16 = @intFromFloat(@floor(normalized * 256.0 / 360.0));
    return @bitCast(@as(u8, @intCast(scaled & 0xff)));
}

pub inline fn entityVelocity(value: f64) i16 {
    const scaled = std.math.clamp(value * 8000.0, @as(f64, std.math.minInt(i16)), @as(f64, std.math.maxInt(i16)));
    return @intFromFloat(@round(scaled));
}

pub inline fn entityAngle(value: f32) i8 {
    return @truncate(@as(i32, @intFromFloat(value * (256.0 / 360.0))));
}

pub fn playerFlagsMetadata(buffer: []u8, sneaking: bool, sprinting: bool) ![]u8 {
    var rest = try protocol_support.write_u8(buffer, 0);
    rest = try protocol_support.write_varint(rest, 0);
    const flags: u8 = @as(u8, @intFromBool(sneaking)) * 0x02 |
        @as(u8, @intFromBool(sprinting)) * 0x08;
    rest = try protocol_support.write_i8(rest, @bitCast(flags));
    return protocol_support.write_u8(rest, 0xff);
}

pub fn playerPoseMetadata(buffer: []u8, sneaking: bool) ![]u8 {
    var rest = try protocol_support.write_u8(buffer, 6);
    rest = try protocol_support.write_varint(rest, 21);
    rest = try protocol_support.write_varint(rest, if (sneaking) 5 else 0);
    return protocol_support.write_u8(rest, 0xff);
}

test "angle byte wraps protocol rotation boundaries" {
    try std.testing.expectEqual(@as(i8, @bitCast(@as(u8, 0))), angleByte(0));
    try std.testing.expectEqual(@as(i8, @bitCast(@as(u8, 0))), angleByte(360));
    try std.testing.expectEqual(@as(i8, @bitCast(@as(u8, 0))), angleByte(-360));
    try std.testing.expectEqual(@as(i8, @bitCast(@as(u8, 64))), angleByte(90));
    try std.testing.expectEqual(@as(i8, @bitCast(@as(u8, 192))), angleByte(-90));
    try std.testing.expectEqual(@as(i8, @bitCast(@as(u8, 255))), angleByte(@as(f32, 360.0) - 0.001));
}

/// Encodes only the version-neutral items/count tail of a window-items packet.
/// The recipient's protocol operation writes the packet id and leading fields.
pub fn playerInventoryTail(buffer: []u8, player: *const player_store.CorePlayer, crafting_result: player_store.HotbarStack, item_to_wire: []const i32, damage_component_id: i32) ![]u8 {
    var rest = try protocol_support.write_count(buffer, i32, 46);
    for (0..46) |inventory_slot| {
        const stack = switch (inventory_slot) {
            0 => crafting_result,
            1...4 => player.crafting_grid[inventory_slot - 1],
            5...8 => player.armor[inventory_slot - 5],
            9...35 => player.main_inventory[inventory_slot - 9],
            36...44 => player.hotbar[inventory_slot - 36],
            45 => player.offhand,
            else => unreachable,
        };
        const encoded = try writeSlotPayload(rest, stack, item_to_wire, damage_component_id);
        rest = rest[encoded.len..];
    }
    const carried = try writeSlotPayload(rest, player.cursor_stack, item_to_wire, damage_component_id);
    rest = rest[carried.len..];
    return buffer[0 .. buffer.len - rest.len];
}

fn writeSlotPayload(buffer: []u8, stack: player_store.HotbarStack, item_to_wire: []const i32, damage_component_id: i32) ![]u8 {
    var rest = try protocol_support.write_varint(buffer, if (stack.isEmpty()) 0 else @as(i32, stack.count));
    if (!stack.isEmpty()) {
        const item_index: usize = @intCast(stack.item_id);
        if (item_index >= item_to_wire.len or item_to_wire[item_index] < 0) return error.RegistryEntryUnsupportedByProtocol;
        rest = try protocol_support.write_varint(rest, item_to_wire[item_index]);
        rest = try protocol_support.write_varint(rest, @intFromBool(stack.damage != 0));
        rest = try protocol_support.write_varint(rest, 0);
        if (stack.damage != 0) {
            rest = try protocol_support.write_varint(rest, damage_component_id);
            rest = try protocol_support.write_varint(rest, stack.damage);
        }
    }
    return buffer[0 .. buffer.len - rest.len];
}
