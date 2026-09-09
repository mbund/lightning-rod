const std = @import("std");

const Codec = enum {
    float,
    integer,
    boolean,
    flags_on_ground,
    action,
    block_position,
    face,
    entity_ref,
    entity_type,
    arm_hand,
    block_state,
    destroy_stage,
    require_player_screen,
    fixed_zero,
    fixed_main_hand,
    fixed_cursor,
    fixed_false,
    ignore,
    opaque_value,
};

const Handler = enum { mapped, entity_attack, entity_movement, entity_equipment, entity_sound, item_metadata, entity_destroy, player_remove, system_chat, inventory, inventory_slot, screen_slot, container_click, multi_block_change };
const Field = struct { wire: []const u8, canonical: []const u8 = "", codec: Codec };
const Mapping = struct {
    canonical: []const u8,
    wire: []const u8,
    handler: Handler = .mapped,
    encode: bool = false,
    fields: []const Field,
};

const serverbound = [_]Mapping{
    .{ .canonical = "attack_entity", .wire = "use_entity", .handler = .entity_attack, .encode = true, .fields = &.{} },
    .{ .canonical = "move", .wire = "position", .encode = true, .fields = &.{
        .{ .wire = "x", .canonical = "x", .codec = .float },
        .{ .wire = "y", .canonical = "y", .codec = .float },
        .{ .wire = "z", .canonical = "z", .codec = .float },
        .{ .wire = "flags", .canonical = "on_ground", .codec = .flags_on_ground },
    } },
    .{ .canonical = "look", .wire = "look", .encode = true, .fields = &.{
        .{ .wire = "yaw", .canonical = "yaw", .codec = .float },
        .{ .wire = "pitch", .canonical = "pitch", .codec = .float },
        .{ .wire = "flags", .canonical = "on_ground", .codec = .flags_on_ground },
    } },
    .{ .canonical = "move", .wire = "position_look", .fields = &.{
        .{ .wire = "x", .canonical = "x", .codec = .float },
        .{ .wire = "y", .canonical = "y", .codec = .float },
        .{ .wire = "z", .canonical = "z", .codec = .float },
        .{ .wire = "yaw", .codec = .fixed_zero },
        .{ .wire = "pitch", .codec = .fixed_zero },
        .{ .wire = "flags", .canonical = "on_ground", .codec = .flags_on_ground },
    } },
    .{ .canonical = "player_action", .wire = "block_dig", .encode = true, .fields = &.{
        .{ .wire = "status", .canonical = "action", .codec = .action },
        .{ .wire = "location", .canonical = "position", .codec = .block_position },
        .{ .wire = "face", .codec = .fixed_zero },
        .{ .wire = "sequence", .codec = .fixed_zero },
    } },
    .{ .canonical = "use_item_on", .wire = "block_place", .encode = true, .fields = &.{
        .{ .wire = "hand", .codec = .fixed_main_hand },
        .{ .wire = "location", .canonical = "against", .codec = .block_position },
        .{ .wire = "direction", .canonical = "face", .codec = .face },
        .{ .wire = "cursorX", .canonical = "cursor_x", .codec = .float },
        .{ .wire = "cursorY", .canonical = "cursor_y", .codec = .float },
        .{ .wire = "cursorZ", .canonical = "cursor_z", .codec = .float },
        .{ .wire = "insideBlock", .codec = .fixed_false },
        .{ .wire = "worldBorderHit", .codec = .fixed_false },
        .{ .wire = "sequence", .canonical = "sequence", .codec = .integer },
    } },
    .{ .canonical = "select_hotbar_slot", .wire = "held_item_slot", .encode = true, .fields = &.{
        .{ .wire = "slotId", .canonical = "slot", .codec = .integer },
    } },
    .{ .canonical = "container_click", .wire = "window_click", .handler = .container_click, .encode = true, .fields = &.{
        .{ .wire = "windowId", .codec = .require_player_screen },
        .{ .wire = "stateId", .codec = .fixed_zero },
        .{ .wire = "slot", .canonical = "slot", .codec = .integer },
        .{ .wire = "mouseButton", .canonical = "button", .codec = .integer },
        .{ .wire = "mode", .canonical = "mode", .codec = .integer },
        .{ .wire = "changedSlots", .codec = .opaque_value },
        .{ .wire = "cursorItem", .codec = .opaque_value },
    } },
    .{ .canonical = "close_screen", .wire = "close_window", .encode = true, .fields = &.{
        .{ .wire = "windowId", .canonical = "screen", .codec = .require_player_screen },
    } },
};

const clientbound = [_]Mapping{
    .{ .canonical = "time_update", .wire = "update_time", .fields = &.{
        .{ .wire = "age", .canonical = "game_time", .codec = .integer },
        .{ .wire = "time", .canonical = "day_time", .codec = .integer },
        .{ .wire = "tickDayTime", .canonical = "daylight_cycle", .codec = .boolean },
    } },
    .{ .canonical = "health_update", .wire = "update_health", .fields = &.{
        .{ .wire = "health", .canonical = "health", .codec = .float },
        .{ .wire = "food", .canonical = "food", .codec = .integer },
        .{ .wire = "foodSaturation", .canonical = "saturation", .codec = .float },
    } },
    .{ .canonical = "entity_damaged", .wire = "damage_event", .fields = &.{
        .{ .wire = "entityId", .canonical = "subject", .codec = .entity_ref },
        .{ .wire = "sourceTypeId", .canonical = "damage_type", .codec = .integer },
        .{ .wire = "sourceCauseId", .codec = .ignore },
        .{ .wire = "sourceDirectId", .codec = .ignore },
        .{ .wire = "sourcePosition", .codec = .ignore },
    } },
    .{ .canonical = "hurt_animation", .wire = "hurt_animation", .fields = &.{
        .{ .wire = "entityId", .canonical = "subject", .codec = .entity_ref },
        .{ .wire = "yaw", .canonical = "yaw", .codec = .float },
    } },
    .{ .canonical = "entity_status", .wire = "entity_status", .fields = &.{
        .{ .wire = "entityId", .canonical = "subject", .codec = .entity_ref },
        .{ .wire = "entityStatus", .canonical = "status", .codec = .integer },
    } },
    .{ .canonical = "sound", .wire = "sound_effect", .handler = .entity_sound, .fields = &.{} },
    .{ .canonical = "entity_spawned", .wire = "spawn_entity", .fields = &.{
        .{ .wire = "entityId", .codec = .ignore },
        .{ .wire = "objectUUID", .codec = .ignore },
        .{ .wire = "type", .canonical = "type", .codec = .entity_type },
        .{ .wire = "x", .canonical = "x", .codec = .float },
        .{ .wire = "y", .canonical = "y", .codec = .float },
        .{ .wire = "z", .canonical = "z", .codec = .float },
        .{ .wire = "pitch", .codec = .ignore },
        .{ .wire = "yaw", .codec = .ignore },
        .{ .wire = "headPitch", .codec = .ignore },
        .{ .wire = "objectData", .codec = .ignore },
        .{ .wire = "velocityX", .codec = .ignore },
        .{ .wire = "velocityY", .codec = .ignore },
        .{ .wire = "velocityZ", .codec = .ignore },
    } },
    .{ .canonical = "player_position", .wire = "position", .fields = &.{
        .{ .wire = "teleportId", .codec = .ignore },
        .{ .wire = "x", .canonical = "x", .codec = .float },
        .{ .wire = "y", .canonical = "y", .codec = .float },
        .{ .wire = "z", .canonical = "z", .codec = .float },
        .{ .wire = "dx", .codec = .ignore },
        .{ .wire = "dy", .codec = .ignore },
        .{ .wire = "dz", .codec = .ignore },
        .{ .wire = "yaw", .codec = .ignore },
        .{ .wire = "pitch", .codec = .ignore },
        .{ .wire = "flags", .codec = .ignore },
    } },
    .{ .canonical = "arm_swing", .wire = "animation", .fields = &.{
        .{ .wire = "entityId", .canonical = "subject", .codec = .entity_ref },
        .{ .wire = "animation", .canonical = "hand", .codec = .arm_hand },
    } },
    .{ .canonical = "block_break_animation", .wire = "block_break_animation", .fields = &.{
        .{ .wire = "entityId", .canonical = "subject", .codec = .entity_ref },
        .{ .wire = "location", .canonical = "position", .codec = .block_position },
        .{ .wire = "destroyStage", .canonical = "stage", .codec = .destroy_stage },
    } },
    .{ .canonical = "block_changed", .wire = "block_change", .fields = &.{
        .{ .wire = "location", .canonical = "position", .codec = .block_position },
        .{ .wire = "type", .canonical = "state", .codec = .block_state },
    } },
    .{ .canonical = "blocks_changed", .wire = "multi_block_change", .handler = .multi_block_change, .fields = &.{} },
    .{ .canonical = "entity_equipment", .wire = "entity_equipment", .handler = .entity_equipment, .fields = &.{
        .{ .wire = "entityId", .canonical = "subject", .codec = .entity_ref },
        .{ .wire = "equipments", .codec = .opaque_value },
    } },
    .{ .canonical = "item_spawned", .wire = "entity_metadata", .handler = .item_metadata, .fields = &.{} },
    .{ .canonical = "entity_destroy", .wire = "entity_destroy", .handler = .entity_destroy, .fields = &.{} },
    .{ .canonical = "entity_velocity", .wire = "entity_velocity", .fields = &.{
        .{ .wire = "entityId", .canonical = "subject", .codec = .entity_ref },
        .{ .wire = "velocityX", .canonical = "x", .codec = .integer },
        .{ .wire = "velocityY", .canonical = "y", .codec = .integer },
        .{ .wire = "velocityZ", .canonical = "z", .codec = .integer },
    } },
    .{ .canonical = "player_remove", .wire = "player_remove", .handler = .player_remove, .fields = &.{} },
    .{ .canonical = "system_chat", .wire = "system_chat", .handler = .system_chat, .fields = &.{} },
    .{ .canonical = "entity_moved", .wire = "entity_teleport", .handler = .entity_movement, .fields = &.{} },
    .{ .canonical = "entity_moved", .wire = "sync_entity_position", .handler = .entity_movement, .fields = &.{} },
    .{ .canonical = "entity_moved", .wire = "entity_move_look", .handler = .entity_movement, .fields = &.{} },
    .{ .canonical = "entity_moved", .wire = "rel_entity_move", .handler = .entity_movement, .fields = &.{} },
    .{ .canonical = "inventory", .wire = "window_items", .handler = .inventory, .fields = &.{} },
    .{ .canonical = "inventory_slot", .wire = "set_player_inventory", .handler = .inventory_slot, .fields = &.{} },
    .{ .canonical = "inventory_slot", .wire = "set_slot", .handler = .screen_slot, .fields = &.{} },
    .{ .canonical = "selected_hotbar_slot", .wire = "held_item_slot", .fields = &.{
        .{ .wire = "slot", .canonical = "slot", .codec = .integer },
    } },
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const output_path = args.next() orelse return error.MissingOutputPath;

    var output = std.array_list.Managed(u8).init(allocator);
    try output.appendSlice(
        "pub const Codec = enum { float, integer, boolean, flags_on_ground, action, block_position, face, entity_ref, entity_type, arm_hand, block_state, destroy_stage, require_player_screen, fixed_zero, fixed_main_hand, fixed_cursor, fixed_false, ignore, opaque_value };\n" ++
            "pub const Handler = enum { mapped, entity_attack, entity_movement, entity_equipment, entity_sound, item_metadata, entity_destroy, player_remove, system_chat, inventory, inventory_slot, screen_slot, container_click, multi_block_change };\n" ++
            "pub const Field = struct { wire: []const u8, canonical: []const u8 = \"\", codec: Codec };\n" ++
            "pub const Mapping = struct { canonical: []const u8, wire: []const u8, handler: Handler = .mapped, encode: bool = false, fields: []const Field };\n" ++
            "\n",
    );
    try writeMappings(&output, "serverbound", &serverbound);
    try writeMappings(&output, "clientbound", &clientbound);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = output.items });
}

fn writeMappings(output: *std.array_list.Managed(u8), name: []const u8, mappings: []const Mapping) !void {
    try output.print("pub const {s} = [_]Mapping{{\n", .{name});
    for (mappings) |mapping| {
        try output.print("    .{{ .canonical = \"{s}\", .wire = \"{s}\", .handler = .{s}, .encode = {}, .fields = &.{{\n", .{ mapping.canonical, mapping.wire, @tagName(mapping.handler), mapping.encode });
        for (mapping.fields) |field| try output.print("        .{{ .wire = \"{s}\", .canonical = \"{s}\", .codec = .{s} }},\n", .{ field.wire, field.canonical, @tagName(field.codec) });
        try output.appendSlice("    } },\n");
    }
    try output.appendSlice("};\n\n");
}
