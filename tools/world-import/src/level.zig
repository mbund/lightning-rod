const std = @import("std");
const nbt = @import("nbt");
const vanilla = @import("vanilla");
const fields = @import("nbt.zig");
const world_import = @import("import.zig");

fn rule(doc: nbt.Document, data: nbt.Node, name: []const u8) !bool {
    const rules = data.childNamed(doc.nodes, "GameRules") orelse return true;
    const value = rules.childNamed(doc.nodes, name) orelse return true;
    if (value.tag == .byte) return try value.byte() != 0;
    const string = try value.string();
    if (std.mem.eql(u8, string, "true")) return true;
    if (std.mem.eql(u8, string, "false")) return false;
    return error.InvalidGameRule;
}

pub fn read(owner: *world_import.Import, doc: nbt.Document, data: nbt.Node) !void {
    const game_rules = data.childNamed(doc.nodes, "GameRules");
    const radius = if (game_rules) |rules| if (rules.childNamed(doc.nodes, "spawnRadius")) |value| try std.fmt.parseInt(i32, try value.string(), 10) else 10 else 10;
    const angle: f32 = if (data.childNamed(doc.nodes, "SpawnAngle")) |value| @floatCast(try fields.number(value)) else 0;
    try owner.spawn.set(owner.worlds.find("minecraft:overworld").?.id, .{
        .position = .{
            .x = std.math.cast(i32, try fields.optionalInt(doc, data, "SpawnX", 0)) orelse return error.InvalidSpawn,
            .y = std.math.cast(i32, try fields.optionalInt(doc, data, "SpawnY", 64)) orelse return error.InvalidSpawn,
            .z = std.math.cast(i32, try fields.optionalInt(doc, data, "SpawnZ", 0)) orelse return error.InvalidSpawn,
        },
        .angle = angle,
        .radius = radius,
    });
    var clock: vanilla.Time = .{ .game_time = try fields.optionalInt(doc, data, "Time", 0), .day_time = try fields.optionalInt(doc, data, "DayTime", 0), .daylight_cycle = try rule(doc, data, "doDaylightCycle") };
    try clock.checkpoint(try owner.store.openSpace(vanilla.Time.id));
    const clear = try fields.optionalInt(doc, data, "clearWeatherTime", 0);
    const rain = try fields.optionalInt(doc, data, "rainTime", 0);
    const thunder = try fields.optionalInt(doc, data, "thunderTime", 0);
    if (clear < 0 or rain < 0 or thunder < 0) return error.InvalidWeather;
    var weather: vanilla.Weather = .{
        .weather_cycle = try rule(doc, data, "doWeatherCycle"),
        .random = .init(0),
        .clear_ticks = std.math.cast(i32, clear) orelse return error.InvalidWeather,
        .rain_ticks = std.math.cast(i32, rain) orelse return error.InvalidWeather,
        .thunder_ticks = std.math.cast(i32, thunder) orelse return error.InvalidWeather,
        .raining = try fields.optionalInt(doc, data, "raining", 0) != 0,
        .thundering = try fields.optionalInt(doc, data, "thundering", 0) != 0,
    };
    weather.rain_level = if (weather.raining) 1 else 0;
    weather.thunder_level = if (weather.thundering) 1 else 0;
    try weather.checkpoint(try owner.store.openSpace(vanilla.Weather.id));
    try vanilla.WorldBorder.save(try owner.store.openSpace(vanilla.WorldBorder.id), try border(doc, data));
}

/// A number level.dat may hold as any numeric tag, as Dynamic.asDouble reads it.
fn numberOr(doc: nbt.Document, data: nbt.Node, name: []const u8, default: f64) !f64 {
    const value = data.childNamed(doc.nodes, name) orelse return default;
    return switch (value.tag) {
        .float, .double => try fields.number(value),
        else => @floatFromInt(try fields.integer(value)),
    };
}

/// WorldBorder.Settings.read: its center held within the largest radius, and the time a moving
/// border has left, kept in milliseconds, in ticks.
fn border(doc: nbt.Document, data: nbt.Node) !vanilla.WorldBorder.Settings {
    const radius = vanilla.world_border.max_radius;
    const size = try numberOr(doc, data, "BorderSize", vanilla.world_border.max_size);
    const milliseconds = try fields.optionalInt(doc, data, "BorderSizeLerpTime", 0);
    const remaining = @divTrunc(@max(milliseconds, 0), 50);
    const warning_blocks = try numberOr(doc, data, "BorderWarningBlocks", 5);
    const warning_time = try numberOr(doc, data, "BorderWarningTime", 15);
    return .{
        .center_x = std.math.clamp(try numberOr(doc, data, "BorderCenterX", 0), -radius, radius),
        .center_z = std.math.clamp(try numberOr(doc, data, "BorderCenterZ", 0), -radius, radius),
        .size = size,
        .damage_per_block = try numberOr(doc, data, "BorderDamagePerBlock", 0.2),
        .safe_zone = try numberOr(doc, data, "BorderSafeZone", 5),
        .warning_blocks = std.math.lossyCast(i32, warning_blocks),
        .warning_time = std.math.lossyCast(i32, warning_time),
        .target = if (remaining > 0) try numberOr(doc, data, "BorderSizeLerpTarget", size) else size,
        .remaining = remaining,
    };
}
