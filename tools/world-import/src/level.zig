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
}
