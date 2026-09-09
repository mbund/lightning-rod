const std = @import("std");
const minecraft = @import("minecraft_registry");
const nbt = @import("nbt");
const legacy = @import("legacy_noise.zig");
const data = @import("structure_data");

pub const ChunkPos = struct {
    x: i32,
    z: i32,
};

pub const Rotation = enum(u2) {
    none,
    clockwise_90,
    clockwise_180,
    counterclockwise_90,
};

pub const Mirror = enum(u2) {
    none,
    left_right,
    front_back,
};

pub const Position = struct { x: i32, y: i32, z: i32 };

pub const Box = struct {
    minimum: Position,
    maximum: Position,

    pub fn intersects(self: Box, other: Box) bool {
        return self.maximum.x >= other.minimum.x and self.minimum.x <= other.maximum.x and
            self.maximum.y >= other.minimum.y and self.minimum.y <= other.maximum.y and
            self.maximum.z >= other.minimum.z and self.minimum.z <= other.maximum.z;
    }
};

pub fn rotate(position: Position, rotation: Rotation) Position {
    return switch (rotation) {
        .none => position,
        .clockwise_90 => .{ .x = -position.z, .y = position.y, .z = position.x },
        .clockwise_180 => .{ .x = -position.x, .y = position.y, .z = -position.z },
        .counterclockwise_90 => .{ .x = position.z, .y = position.y, .z = -position.x },
    };
}

pub fn templateBox(template: Template, origin: Position, rotation: Rotation) Box {
    const corner = rotate(.{
        .x = template.size[0] - 1,
        .y = template.size[1] - 1,
        .z = template.size[2] - 1,
    }, rotation);
    return .{
        .minimum = .{
            .x = origin.x + @min(0, corner.x),
            .y = origin.y,
            .z = origin.z + @min(0, corner.z),
        },
        .maximum = .{
            .x = origin.x + @max(0, corner.x),
            .y = origin.y + corner.y,
            .z = origin.z + @max(0, corner.z),
        },
    };
}

pub fn rotateState(state: minecraft.State, rotation: Rotation, buffer: []u8) minecraft.State {
    if (rotation == .none) return state;
    const canonical = state.canonicalName();
    const open = std.mem.indexOfScalar(u8, canonical, '[') orelse return state;
    const close = std.mem.lastIndexOfScalar(u8, canonical, ']') orelse unreachable;
    var properties: [32]Property = undefined;
    var count: usize = 0;
    var entries = std.mem.splitScalar(u8, canonical[open + 1 .. close], ',');
    while (entries.next()) |entry| {
        std.debug.assert(count < properties.len);
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse unreachable;
        properties[count] = rotateProperty(entry[0..equals], entry[equals + 1 ..], rotation);
        count += 1;
    }
    std.mem.sort(Property, properties[0..count], {}, lessProperty);
    var writer: std.Io.Writer = .fixed(buffer);
    writer.writeAll(canonical[0..open]) catch unreachable;
    writer.writeByte('[') catch unreachable;
    for (properties[0..count], 0..) |property, index| {
        if (index != 0) writer.writeByte(',') catch unreachable;
        writer.print("{s}={s}", .{ property.name, property.value }) catch unreachable;
    }
    writer.writeByte(']') catch unreachable;
    return minecraft.State.parse(writer.buffered()) orelse unreachable;
}

pub fn mirrorState(state: minecraft.State, mirror: Mirror, buffer: []u8) minecraft.State {
    if (mirror == .none) return state;
    const canonical = state.canonicalName();
    const open = std.mem.indexOfScalar(u8, canonical, '[') orelse return state;
    const close = std.mem.lastIndexOfScalar(u8, canonical, ']') orelse unreachable;
    var properties: [32]Property = undefined;
    var count: usize = 0;
    var entries = std.mem.splitScalar(u8, canonical[open + 1 .. close], ',');
    while (entries.next()) |entry| {
        std.debug.assert(count < properties.len);
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse unreachable;
        properties[count] = mirrorProperty(entry[0..equals], entry[equals + 1 ..], mirror);
        count += 1;
    }
    std.mem.sort(Property, properties[0..count], {}, lessProperty);
    var writer: std.Io.Writer = .fixed(buffer);
    writer.writeAll(canonical[0..open]) catch unreachable;
    writer.writeByte('[') catch unreachable;
    for (properties[0..count], 0..) |property, index| {
        if (index != 0) writer.writeByte(',') catch unreachable;
        writer.print("{s}={s}", .{ property.name, property.value }) catch unreachable;
    }
    writer.writeByte(']') catch unreachable;
    return minecraft.State.parse(writer.buffered()) orelse unreachable;
}

fn mirrorProperty(name: []const u8, value: []const u8, mirror: Mirror) Property {
    if (directionIndex(name)) |index| {
        const mirrored = mirrorDirectionIndex(index, mirror);
        return .{ .name = directions[mirrored], .value = value };
    }
    if (std.mem.eql(u8, name, "facing")) {
        const index = directionValueIndex(value) orelse return .{ .name = name, .value = value };
        return .{ .name = name, .value = directions[mirrorDirectionIndex(index, mirror)] };
    }
    if (std.mem.eql(u8, name, "rotation")) {
        const old = std.fmt.parseInt(u8, value, 10) catch return .{ .name = name, .value = value };
        const mirrored = switch (mirror) {
            .none => old,
            .left_right => @mod(8 - @as(i16, old) + 16, 16),
            .front_back => @mod(16 - @as(i16, old), 16),
        };
        return .{ .name = name, .value = rotation_values[@intCast(mirrored)] };
    }
    return .{ .name = name, .value = value };
}

fn mirrorDirectionIndex(index: usize, mirror: Mirror) usize {
    return switch (mirror) {
        .none => index,
        .left_right => if (index == 0) 2 else if (index == 2) 0 else index,
        .front_back => if (index == 1) 3 else if (index == 3) 1 else index,
    };
}

fn directionValueIndex(value: []const u8) ?usize {
    for (directions, 0..) |direction, index|
        if (std.mem.eql(u8, value, direction)) return index;
    return null;
}

fn rotateProperty(name: []const u8, value: []const u8, rotation: Rotation) Property {
    if (directionIndex(name)) |index| return .{
        .name = directions[@mod(index + @intFromEnum(rotation), directions.len)],
        .value = value,
    };
    if (std.mem.eql(u8, name, "facing")) return .{ .name = name, .value = rotateDirectionValue(value, rotation) };
    if (std.mem.eql(u8, name, "axis") and !std.mem.eql(u8, value, "y") and
        (@intFromEnum(rotation) & 1) != 0)
        return .{ .name = name, .value = if (std.mem.eql(u8, value, "x")) "z" else "x" };
    if (std.mem.eql(u8, name, "rotation")) {
        const old = std.fmt.parseInt(u8, value, 10) catch return .{ .name = name, .value = value };
        return .{ .name = name, .value = rotation_values[@mod(old + @as(u8, @intFromEnum(rotation)) * 4, 16)] };
    }
    if (std.mem.eql(u8, name, "shape")) return .{ .name = name, .value = rotateShape(value, rotation) };
    return .{ .name = name, .value = value };
}

const directions = [_][]const u8{ "north", "east", "south", "west" };
const rotation_values = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15" };

fn directionIndex(value: []const u8) ?usize {
    for (directions, 0..) |direction, index| if (std.mem.eql(u8, value, direction)) return index;
    return null;
}

fn rotateDirectionValue(value: []const u8, rotation: Rotation) []const u8 {
    const index = directionIndex(value) orelse return value;
    return directions[@mod(index + @intFromEnum(rotation), directions.len)];
}

fn rotateShape(value: []const u8, rotation: Rotation) []const u8 {
    const shapes = [_][]const u8{
        "north_south",     "east_west",      "south_north",     "west_east",
        "ascending_north", "ascending_east", "ascending_south", "ascending_west",
        "north_east",      "south_east",     "south_west",      "north_west",
    };
    const rotated = [_][]const u8{
        "east_west",      "north_south",     "west_east",      "south_north",
        "ascending_east", "ascending_south", "ascending_west", "ascending_north",
        "south_east",     "south_west",      "north_west",     "north_east",
    };
    var result = value;
    for (0..@intFromEnum(rotation)) |_| {
        for (shapes, 0..) |shape, index| if (std.mem.eql(u8, result, shape)) {
            result = rotated[index];
            break;
        };
    }
    return result;
}

pub const RandomSpread = struct {
    pub const Spread = enum { linear, triangular };

    spacing: i32,
    separation: i32,
    salt: i32,
    spread: Spread = .linear,

    pub fn candidate(self: RandomSpread, seed: i64, region_x: i32, region_z: i32) ChunkPos {
        std.debug.assert(self.spacing > self.separation);
        std.debug.assert(self.separation >= 0);
        const mixed = @as(i64, region_x) *% 341_873_128_712 +%
            @as(i64, region_z) *% 132_897_987_541 +% seed +% self.salt;
        var random = legacy.Random.init(mixed);
        const bound: u32 = @intCast(self.spacing - self.separation);
        return .{
            .x = region_x *% self.spacing +% self.offset(&random, bound),
            .z = region_z *% self.spacing +% self.offset(&random, bound),
        };
    }

    pub fn candidateForChunk(self: RandomSpread, seed: i64, chunk: ChunkPos) ChunkPos {
        return self.candidate(
            seed,
            @divFloor(chunk.x, self.spacing),
            @divFloor(chunk.z, self.spacing),
        );
    }

    pub fn isStart(self: RandomSpread, seed: i64, chunk: ChunkPos) bool {
        const start = self.candidateForChunk(seed, chunk);
        return start.x == chunk.x and start.z == chunk.z;
    }

    fn offset(self: RandomSpread, source: *legacy.Random, bound: u32) i32 {
        return @intCast(switch (self.spread) {
            .linear => source.nextBounded(bound),
            .triangular => (source.nextBounded(bound) + source.nextBounded(bound)) / 2,
        });
    }
};

pub const swamp_hut = RandomSpread{
    .spacing = 32,
    .separation = 8,
    .salt = 14_357_620,
};

pub const nether_complexes = RandomSpread{
    .spacing = 27,
    .separation = 4,
    .salt = 30_084_232,
};

pub const end_cities = RandomSpread{
    .spacing = 20,
    .separation = 11,
    .salt = 10_387_313,
    .spread = .triangular,
};

pub const nether_fossils = RandomSpread{
    .spacing = 2,
    .separation = 1,
    .salt = 14_357_921,
};

pub const ruined_portals = RandomSpread{
    .spacing = 40,
    .separation = 15,
    .salt = 34_222_645,
};

pub const Quad = struct {
    candidates: [4]ChunkPos,

    pub fn fromNorthWestRegion(seed: i64, region_x: i32, region_z: i32) Quad {
        return .{ .candidates = .{
            swamp_hut.candidate(seed, region_x, region_z),
            swamp_hut.candidate(seed, region_x + 1, region_z),
            swamp_hut.candidate(seed, region_x, region_z + 1),
            swamp_hut.candidate(seed, region_x + 1, region_z + 1),
        } };
    }

    pub fn fitsDiameter(self: Quad, diameter_blocks: u32) bool {
        const diameter_chunks: i64 = @intCast((diameter_blocks + 15) / 16);
        var minimum_x: i64 = self.candidates[0].x;
        var maximum_x = minimum_x;
        var minimum_z: i64 = self.candidates[0].z;
        var maximum_z = minimum_z;
        for (self.candidates[1..]) |candidate| {
            minimum_x = @min(minimum_x, candidate.x);
            maximum_x = @max(maximum_x, candidate.x);
            minimum_z = @min(minimum_z, candidate.z);
            maximum_z = @max(maximum_z, candidate.z);
        }
        return maximum_x - minimum_x <= diameter_chunks and
            maximum_z - minimum_z <= diameter_chunks;
    }
};

pub const Template = struct {
    id: []const u8,
    nbt: []const u8,
    size: [3]i32,
    jigsaws: []const data.Jigsaw,

    pub fn scan(self: Template, nodes: []nbt.Node, stack: []nbt.Frame) nbt.Error!nbt.Document {
        return nbt.scan_named(self.nbt, nodes, stack);
    }
};

pub const TemplateError = nbt.Error || error{
    InvalidStructureTemplate,
    TooManyBlockProperties,
    UnknownBlockState,
    WriteFailed,
};

pub const TemplateView = struct {
    document: nbt.Document,

    pub fn init(template: Template, nodes: []nbt.Node, stack: []nbt.Frame) TemplateError!TemplateView {
        const document = try template.scan(nodes, stack);
        _ = try required(document, "size", .list);
        _ = try required(document, "palette", .list);
        _ = try required(document, "blocks", .list);
        return .{ .document = document };
    }

    pub fn size(self: TemplateView) TemplateError![3]i32 {
        const node = try required(self.document, "size", .list);
        const info = try node.listInfo();
        if (info.child_tag != .int or info.len != 3) return error.InvalidStructureTemplate;
        var result: [3]i32 = undefined;
        var children = node.childIterator(self.document.nodes);
        for (&result) |*value| value.* = try (children.next() orelse
            return error.InvalidStructureTemplate).int();
        if (children.next() != null) return error.InvalidStructureTemplate;
        return result;
    }

    pub fn palette(self: TemplateView) TemplateError!PaletteIterator {
        const node = try required(self.document, "palette", .list);
        const info = try node.listInfo();
        if (info.child_tag != .compound) return error.InvalidStructureTemplate;
        return .{ .nodes = self.document.nodes, .children = node.childIterator(self.document.nodes) };
    }

    pub fn blocks(self: TemplateView) TemplateError!BlockIterator {
        const node = try required(self.document, "blocks", .list);
        const info = try node.listInfo();
        if (info.child_tag != .compound) return error.InvalidStructureTemplate;
        return .{ .nodes = self.document.nodes, .children = node.childIterator(self.document.nodes) };
    }
};

pub const PaletteIterator = struct {
    nodes: []const nbt.Node,
    children: nbt.ChildIterator,

    pub fn next(self: *PaletteIterator, buffer: []u8) TemplateError!?@import("minecraft_registry").State {
        const entry = self.children.next() orelse return null;
        const name = entry.childNamed(self.nodes, "Name") orelse return error.InvalidStructureTemplate;
        const block_name = try name.string();
        const properties = entry.childNamed(self.nodes, "Properties");
        const canonical = if (properties) |node|
            try canonicalState(block_name, node, self.nodes, buffer)
        else
            block_name;
        return @import("minecraft_registry").State.parse(canonical) orelse error.UnknownBlockState;
    }
};

pub const TemplateBlock = struct {
    position: [3]i32,
    state: u32,
    data: ?nbt.Node,
};

pub const BlockIterator = struct {
    nodes: []const nbt.Node,
    children: nbt.ChildIterator,

    pub fn next(self: *BlockIterator) TemplateError!?TemplateBlock {
        const entry = self.children.next() orelse return null;
        const position_node = entry.childNamed(self.nodes, "pos") orelse
            return error.InvalidStructureTemplate;
        const state_node = entry.childNamed(self.nodes, "state") orelse
            return error.InvalidStructureTemplate;
        const info = try position_node.listInfo();
        if (info.child_tag != .int or info.len != 3) return error.InvalidStructureTemplate;
        var position: [3]i32 = undefined;
        var values = position_node.childIterator(self.nodes);
        for (&position) |*value| value.* = try (values.next() orelse
            return error.InvalidStructureTemplate).int();
        const state = try state_node.int();
        if (state < 0) return error.InvalidStructureTemplate;
        return .{
            .position = position,
            .state = @intCast(state),
            .data = entry.childNamed(self.nodes, "nbt"),
        };
    }
};

const Property = struct { name: []const u8, value: []const u8 };

fn required(document: nbt.Document, name: []const u8, tag: nbt.Tag) TemplateError!nbt.Node {
    const node = document.childNamed(name) orelse return error.InvalidStructureTemplate;
    return node.expectTag(tag);
}

fn canonicalState(
    block_name: []const u8,
    properties_node: nbt.Node,
    nodes: []const nbt.Node,
    buffer: []u8,
) TemplateError![]const u8 {
    _ = try properties_node.expectTag(.compound);
    var properties: [32]Property = undefined;
    if (properties_node.child_count > properties.len) return error.TooManyBlockProperties;
    var iterator = properties_node.childIterator(nodes);
    var count: usize = 0;
    while (iterator.next()) |child| : (count += 1)
        properties[count] = .{ .name = child.name, .value = try child.string() };
    std.mem.sort(Property, properties[0..count], {}, lessProperty);
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeAll(block_name);
    if (count == 0) return writer.buffered();
    try writer.writeByte('[');
    for (properties[0..count], 0..) |property, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{s}={s}", .{ property.name, property.value });
    }
    try writer.writeByte(']');
    return writer.buffered();
}

fn lessProperty(_: void, left: Property, right: Property) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

pub const Registry = struct {
    templates: []const Template,

    pub fn find(self: Registry, id: []const u8) ?Template {
        for (self.templates) |template|
            if (std.mem.eql(u8, id, template.id)) return template;
        return null;
    }
};

pub const vanilla = struct {
    pub fn find(id: []const u8) ?Template {
        var low: usize = 0;
        var high: usize = data.entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = data.entries[middle];
            switch (std.mem.order(u8, id, entry.id)) {
                .lt => high = middle,
                .gt => low = middle + 1,
                .eq => return .{
                    .id = entry.id,
                    .nbt = data.bytes[entry.offset..][0..entry.length],
                    .size = entry.size,
                    .jigsaws = data.jigsaws[entry.jigsaw_first..][0..entry.jigsaw_count],
                },
            }
        }
        return null;
    }
};

test "swamp hut candidates use Vanilla random-spread placement" {
    const candidate = swamp_hut.candidate(0, 0, 0);
    try std.testing.expect(candidate.x >= 0 and candidate.x < 24);
    try std.testing.expect(candidate.z >= 0 and candidate.z < 24);
    try std.testing.expectEqual(candidate, swamp_hut.candidateForChunk(0, candidate));
}

test "quad candidate geometry is bounded without terrain generation" {
    const quad = Quad.fromNorthWestRegion(1, -1, -1);
    try std.testing.expect(quad.fitsDiameter(2_048));
}

test "Nether and End structure starts match Vanilla spread placement" {
    try std.testing.expectEqual(ChunkPos{ .x = 20, .z = 9 }, ruined_portals.candidate(0, 0, 0));
    try std.testing.expectEqual(
        ChunkPos{ .x = -663566, .z = -933861 },
        nether_complexes.candidateForChunk(4414944358358260217, .{ .x = -663559, .z = -933861 }),
    );
    try std.testing.expectEqual(
        ChunkPos{ .x = 103, .z = -139 },
        end_cities.candidate(0, 5, -7),
    );
}

test "Vanilla structure templates come from the pinned server jar" {
    const entrance = vanilla.find("minecraft:ancient_city/city/entrance/entrance_connector") orelse
        return error.MissingAncientCityEntrance;
    try std.testing.expect(entrance.nbt.len > 0);
}

test "Vanilla structure templates are embedded as directly readable NBT" {
    const template = vanilla.find("minecraft:end_city/base_floor") orelse
        return error.MissingEndCityBaseFloor;
    var nodes: [4_096]nbt.Node = undefined;
    var stack: [64]nbt.Frame = undefined;
    const view = try TemplateView.init(template, &nodes, &stack);
    try std.testing.expectEqual(template.size, try view.size());
    try std.testing.expectEqual([3]i32{ 10, 4, 10 }, try view.size());
    var palette = try view.palette();
    var state_buffer: [256]u8 = undefined;
    var palette_count: usize = 0;
    while (try palette.next(&state_buffer)) |_| palette_count += 1;
    try std.testing.expect(palette_count > 1);
    var blocks = try view.blocks();
    var block_count: usize = 0;
    while (try blocks.next()) |block| {
        try std.testing.expect(block.state < palette_count);
        block_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 400), block_count);
}

test "structure state rotation preserves canonical property ordering" {
    var buffer: [256]u8 = undefined;
    const stair = minecraft.State.parse(
        "minecraft:purpur_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]",
    ).?;
    try std.testing.expectEqualStrings(
        "minecraft:purpur_stairs[facing=east,half=bottom,shape=straight,waterlogged=false]",
        rotateState(stair, .clockwise_90, &buffer).canonicalName(),
    );
    const fence = minecraft.State.parse(
        "minecraft:nether_brick_fence[east=false,north=true,south=false,waterlogged=false,west=true]",
    ).?;
    try std.testing.expectEqualStrings(
        "minecraft:nether_brick_fence[east=true,north=true,south=false,waterlogged=false,west=false]",
        rotateState(fence, .clockwise_90, &buffer).canonicalName(),
    );
}
