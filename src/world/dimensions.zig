const std = @import("std");
const nbt = @import("nbt");
const api = @import("dimension_api.zig");
const identity = @import("identity.zig");
const world_store = @import("worlds.zig");

pub const max_protocol_nbt_bytes = 1_024;
pub const max_dimensions = 32;

pub const Overworld = struct {
    pub const definition = api.Definition{
        .id = "minecraft:overworld",
        .known_pack = true,
        .fixed_time = null,
        .has_skylight = true,
        .has_ceiling = false,
        .ultrawarm = false,
        .natural = true,
        .coordinate_scale = 1.0,
        .bed_works = true,
        .respawn_anchor_works = false,
        .min_y = -64,
        .height = 384,
        .logical_height = 384,
        .infiniburn = "#minecraft:infiniburn_overworld",
        .effects = "minecraft:overworld",
        .ambient_light = 0.0,
        .cloud_height = 192,
        .monsters = .{
            .piglin_safe = false,
            .has_raids = true,
            .spawn_light = .{ .uniform = .{ .minimum = 0, .maximum = 7 } },
            .spawn_block_light_limit = 0,
        },
    };
};

pub const Nether = struct {
    pub const definition = api.Definition{
        .id = "minecraft:the_nether",
        .known_pack = true,
        .fixed_time = 18_000,
        .has_skylight = false,
        .has_ceiling = true,
        .ultrawarm = true,
        .natural = false,
        .coordinate_scale = 8.0,
        .bed_works = false,
        .respawn_anchor_works = true,
        .min_y = 0,
        .height = 256,
        .logical_height = 128,
        .infiniburn = "#minecraft:infiniburn_nether",
        .effects = "minecraft:the_nether",
        .ambient_light = 0.1,
        .cloud_height = null,
        .monsters = .{
            .piglin_safe = true,
            .has_raids = false,
            .spawn_light = .{ .constant = 7 },
            .spawn_block_light_limit = 15,
        },
    };
};

pub const End = struct {
    pub const definition = api.Definition{
        .id = "minecraft:the_end",
        .known_pack = true,
        .fixed_time = 6_000,
        .has_skylight = false,
        .has_ceiling = false,
        .ultrawarm = false,
        .natural = false,
        .coordinate_scale = 1.0,
        .bed_works = false,
        .respawn_anchor_works = false,
        .min_y = 0,
        .height = 256,
        .logical_height = 256,
        .infiniburn = "#minecraft:infiniburn_end",
        .effects = "minecraft:the_end",
        .ambient_light = 0.0,
        .cloud_height = null,
        .monsters = .{
            .piglin_safe = false,
            .has_raids = true,
            .spawn_light = .{ .uniform = .{ .minimum = 0, .maximum = 7 } },
            .spawn_block_light_limit = 0,
        },
    };
};

pub fn Registry(comptime configured: anytype) type {
    comptime validate(configured);
    const definitions = configuredDefinitions(configured);
    return struct {
        pub const id = "lightning_rod:dimensions";
        pub const Configuration = struct {};
        pub const Dependencies = struct { worlds: *world_store.Worlds };

        deps: Dependencies,

        pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .deps = deps };
            try deps.worlds.bindDimensions(.{ .definitions = &definitions });
            return self;
        }

        pub fn dimensionId(comptime Dimension: type) identity.DimensionId {
            return .{ .index = @intCast(dimensionIndex(@TypeOf(configured), Dimension)) };
        }

        pub fn service() api.Service {
            return .{ .definitions = &definitions };
        }
    };
}

pub const Vanilla = Registry(.{ Overworld{}, Nether{}, End{} });

pub fn writeProtocolNbt(buffer: []u8, definition: api.Definition) ![]const u8 {
    var frames: [4]nbt.WriteFrame = undefined;
    var writer = nbt.Writer.init(buffer, &frames);
    try writer.beginAnonymousCompound();
    if (definition.fixed_time) |value| try writer.putLong("fixed_time", value);
    try putBoolean(&writer, "has_skylight", definition.has_skylight);
    try putBoolean(&writer, "has_ceiling", definition.has_ceiling);
    try putBoolean(&writer, "ultrawarm", definition.ultrawarm);
    try putBoolean(&writer, "natural", definition.natural);
    try writer.putDouble("coordinate_scale", definition.coordinate_scale);
    try putBoolean(&writer, "bed_works", definition.bed_works);
    try putBoolean(&writer, "respawn_anchor_works", definition.respawn_anchor_works);
    try writer.putInt("min_y", definition.min_y);
    try writer.putInt("height", definition.height);
    try writer.putInt("logical_height", definition.logical_height);
    try writer.putString("infiniburn", definition.infiniburn);
    try writer.putString("effects", definition.effects);
    try writer.putFloat("ambient_light", definition.ambient_light);
    if (definition.cloud_height) |value| try writer.putInt("cloud_height", value);
    try putBoolean(&writer, "piglin_safe", definition.monsters.piglin_safe);
    try putBoolean(&writer, "has_raids", definition.monsters.has_raids);
    try writeSpawnLight(&writer, definition.monsters.spawn_light);
    try writer.putInt("monster_spawn_block_light_limit", @intCast(definition.monsters.spawn_block_light_limit));
    try writer.endCompound();
    return writer.finish();
}

fn writeSpawnLight(writer: *nbt.Writer, value: api.SpawnLight) !void {
    switch (value) {
        .constant => |level| try writer.putInt("monster_spawn_light_level", @intCast(level)),
        .uniform => |range| {
            try writer.beginNamedCompound("monster_spawn_light_level");
            try writer.putString("type", "minecraft:uniform");
            try writer.beginNamedCompound("value");
            try writer.putInt("min_inclusive", @intCast(range.minimum));
            try writer.putInt("max_inclusive", @intCast(range.maximum));
            try writer.endCompound();
            try writer.endCompound();
        },
    }
}

fn putBoolean(writer: *nbt.Writer, name: []const u8, value: bool) !void {
    try writer.putByte(name, @intFromBool(value));
}

fn configuredDefinitions(comptime configured: anytype) [configured.len]api.Definition {
    var result: [configured.len]api.Definition = undefined;
    inline for (configured, 0..) |dimension, index|
        result[index] = @TypeOf(dimension).definition;
    return result;
}

fn dimensionIndex(comptime Dimensions: type, comptime Dimension: type) usize {
    inline for (@typeInfo(Dimensions).@"struct".fields, 0..) |field, index|
        if (field.type == Dimension) return index;
    @compileError("dimension is absent from the configured registry: " ++ @typeName(Dimension));
}

fn validate(comptime configured: anytype) void {
    if (configured.len == 0) @compileError("a dimension registry cannot be empty");
    if (configured.len > max_dimensions) @compileError("dimension registry exceeds its fixed bound");
    inline for (configured, 0..) |dimension, index| {
        const Dimension = @TypeOf(dimension);
        if (!@hasDecl(Dimension, "definition"))
            @compileError("dimension must declare `pub const definition`");
        validateDefinition(Dimension.definition);
        inline for (0..index) |previous_index| {
            const previous = @TypeOf(configured[previous_index]).definition;
            if (std.mem.eql(u8, Dimension.definition.id, previous.id))
                @compileError("duplicate dimension id: " ++ Dimension.definition.id);
        }
    }
}

fn validateDefinition(comptime definition: api.Definition) void {
    if (definition.id.len == 0) @compileError("dimension id must not be empty");
    if (definition.height < 16 or @mod(definition.height, 16) != 0)
        @compileError("dimension height must be a positive multiple of 16");
    if (@mod(definition.min_y, 16) != 0)
        @compileError("dimension min_y must be a multiple of 16");
    if (definition.logical_height < 0 or definition.logical_height > definition.height)
        @compileError("dimension logical_height must fit within height");
    if (definition.coordinate_scale < 0.00001 or definition.coordinate_scale > 30_000_000)
        @compileError("dimension coordinate_scale is outside the protocol range");
    if (definition.monsters.spawn_block_light_limit > 15)
        @compileError("dimension monster block-light limit exceeds 15");
    switch (definition.monsters.spawn_light) {
        .constant => |level| if (level > 15)
            @compileError("dimension monster spawn light exceeds 15"),
        .uniform => |range| if (range.minimum > range.maximum or range.maximum > 15)
            @compileError("dimension monster spawn light range is invalid"),
    }
}

test "Vanilla dimension ids follow registry order" {
    try std.testing.expectEqual(@as(u16, 0), Vanilla.dimensionId(Overworld).index);
    try std.testing.expectEqual(@as(u16, 1), Vanilla.dimensionId(Nether).index);
    try std.testing.expectEqualStrings("minecraft:the_end", Vanilla.service().definition(Vanilla.dimensionId(End)).?.id);
}

test "custom dimension properties encode as anonymous NBT" {
    const Custom = struct {
        pub const definition = Overworld.definition;
    };
    var buffer: [max_protocol_nbt_bytes]u8 = undefined;
    const value = try writeProtocolNbt(&buffer, Custom.definition);
    var nodes: [32]nbt.Node = undefined;
    var stack: [4]nbt.Frame = undefined;
    const document = try nbt.Scanner.init(&nodes, &stack).scanAnonymous(value);
    try std.testing.expectEqual(@as(i32, 384), try document.root_node().childNamed(document.nodes, "height").?.int());
}
