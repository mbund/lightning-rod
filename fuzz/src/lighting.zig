const std = @import("std");
const lighting = @import("lighting");

fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var input: [64]u8 = undefined;
    smith.bytesWithHash(&input, 1);
    const dimensions: lighting.Dimensions = .{
        .x = if (input[0] & 1 == 0) 16 else 32,
        .y = ([_]usize{ 4, 16, 32, 64 })[input[0] >> 1 & 3],
        .z = if (input[0] & 8 == 0) 1 else 16,
    };
    const skylight = input[2] & 1 != 0;
    const state_count: u16 = 8;
    var properties = [state_count]lighting.Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
        .{ .opacity = input[4] & 15, .emission = input[5] & 15, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 0, .faces = undefined },
        .{ .opacity = 0, .emission = 0, .faces = undefined },
        .{ .opacity = 1, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 15, .faces = @splat(0) },
    };
    for (0..6) |direction| {
        properties[4].faces[direction] = input[6 + direction] & 3;
        properties[5].faces[direction] = (input[6 + direction] >> 2) & 3;
    }
    // Face identifiers cover none, either half, or the complete face.
    const faces = [_]u8{ 0, 15, 240, 255 };
    var occlusion: [faces.len * faces.len]u8 = undefined;
    for (faces, 0..) |a, from| for (faces, 0..) |b, to| {
        occlusion[from * faces.len + to] = @intFromBool(a | b == 255);
    };
    const registry: lighting.Registry = .{ .states = &properties, .faces = faces.len, .occlusion = &occlusion };
    const allocator = std.testing.allocator;
    var engine = try lighting.Engine.init(allocator, dimensions, registry);
    defer engine.deinit();
    const blocks = try allocator.alloc(u16, dimensions.volume());
    defer allocator.free(blocks);
    const expected = try allocator.alloc(u8, blocks.len);
    defer allocator.free(expected);
    const nibbles = try allocator.alloc(u8, blocks.len / 2);
    defer allocator.free(nibbles);
    var random = std.Random.DefaultPrng.init(std.mem.readInt(u64, input[12..20], .little));
    const pattern = input[1] & 7;
    const uniform: u16 = if (pattern == 0) 0 else input[20] % state_count;
    for (blocks, 0..) |*state, index| {
        const x = index % dimensions.x;
        const y = index / (dimensions.x * dimensions.z);
        state.* = switch (pattern) {
            0, 1 => uniform,
            2 => if (y == dimensions.y / 2) 1 else 0,
            3 => if (y == dimensions.y / 2 and x != 15) 1 else 0,
            4 => if (random.random().int(u8) & 15 == 0) random.random().int(u16) % state_count else 0,
            5 => random.random().int(u16) % state_count,
            6 => if (index == 0 or index == blocks.len / 2 or index == blocks.len - 1) 2 else 0,
            7 => if (y < dimensions.y / 2) 1 else 0,
            else => unreachable,
        };
    }
    var step: usize = 0;
    errdefer std.debug.print("lighting dimensions={any} pattern={d} skylight={} step={d}\n", .{ dimensions, pattern, skylight, step });
    try engine.load(if (pattern < 2 and input[2] & 2 != 0) .{ .uniform = uniform } else .{ .dense = blocks });
    engine.relight(skylight);
    try verify(&engine, registry, blocks, skylight, expected, nibbles);
    const steps = @min(1 + @as(usize, input[3] & 7), if (blocks.len > 8192) @as(usize, 2) else 8);
    while (step < steps) : (step += 1) {
        const command = input[21 + step];
        const count = ([_]usize{ 0, 1, 2, 16, 32, 64, 255, 256 })[command & 7];
        const boundaries = [_]usize{ 0, 15, dimensions.x - 1, dimensions.x, blocks.len / 2, blocks.len - dimensions.x, blocks.len - 1 };
        var edits: [lighting.batch_max]lighting.Edit = undefined;
        for (edits[0..count], 0..) |*edit, index| {
            const at = if (command & 8 != 0 and index != 0 and index % 2 == 0)
                edits[index - 1].index
            else if (command & 16 != 0)
                boundaries[random.random().int(u8) % boundaries.len]
            else
                random.random().int(u32) % blocks.len;
            edit.* = .{ .index = at, .state = if (command & 32 != 0) 0 else random.random().int(u16) % state_count };
            blocks[at] = edit.state;
        }
        try engine.update(edits[0..count]);
        try verify(&engine, registry, blocks, skylight, expected, nibbles);
        if (command & 64 != 0) {
            try engine.load(.{ .dense = blocks });
            engine.relight(skylight);
            try verify(&engine, registry, blocks, skylight, expected, nibbles);
        }
        if (command & 128 != 0) {
            engine.relight(!skylight);
            try verify(&engine, registry, blocks, !skylight, expected, nibbles);
            engine.relight(skylight);
            try verify(&engine, registry, blocks, skylight, expected, nibbles);
        }
    }
    try std.testing.expectError(error.InvalidEdit, engine.update(&.{.{ .index = blocks.len, .state = 0 }}));
    try verify(&engine, registry, blocks, skylight, expected, nibbles);
}

fn verify(engine: *const lighting.Engine, registry: lighting.Registry, blocks: []const u16, skylight: bool, expected: []u8, nibbles: []u8) !void {
    const dimensions = engine.dimensions;
    for ([_]lighting.Layer{ .block, .sky }) |layer| {
        lighting.testing.reference(dimensions, registry, blocks, layer, skylight, expected);
        engine.pack(layer, nibbles);
        for (expected, 0..) |value, index| {
            const actual = engine.get(layer, index);
            const encoded = nibbles[index / 2] >> @as(u3, @intCast(index % 2 * 4)) & 15;
            if (value != actual or value != encoded or blocks[index] != engine.blockState(index)) {
                std.debug.print("layer={t} index={d} expected={d} actual={d} packed={d}\n", .{ layer, index, value, actual, encoded });
                return error.LightingMismatch;
            }
        }
        if (dimensions.y % 16 != 0 or dimensions.z % 16 != 0) continue;
        for (0..dimensions.y / 16) |y| for (0..dimensions.z / 16) |z| for (0..dimensions.x / 16) |x| {
            var section: [2048]u8 = undefined;
            engine.packSection(layer, .{ x, y, z }, &section);
            var nonempty = false;
            for (0..4096) |local| {
                const index = (((y * 16 + local / 256) * dimensions.z + z * 16 + local / 16 % 16) * dimensions.x + x * 16 + local % 16);
                const actual = section[local / 2] >> @as(u3, @intCast(local % 2 * 4)) & 15;
                try std.testing.expectEqual(expected[index], actual);
                nonempty = nonempty or actual != 0;
            }
            try std.testing.expectEqual(nonempty, engine.sectionNonempty(layer, .{ x, y, z }));
        };
    }
}

test "fuzz incremental lighting against scalar propagation" {
    const edits = [_]u8{ 31, 47, 15, 193, 255, 23, 129, 64 };
    const seeds = [_][64]u8{
        seed(0, 0, 3, edits),
        seed(0, 0, 1, edits),
        seed(15, 2, 1, @splat(1)),
        seed(15, 3, 1, @splat(1)),
        seed(2, 6, 1, edits),
        seed(0, 5, 0, edits),
        seed(2, 1, 3, edits),
    };
    try std.testing.fuzz({}, fuzz, .{ .corpus = &.{
        &seeds[0], &seeds[1], &seeds[2], &seeds[3], &seeds[4], &seeds[5], &seeds[6],
    } });
}

fn seed(dimensions: u8, pattern: u8, flags: u8, commands: [8]u8) [64]u8 {
    var input: [64]u8 = @splat(0);
    input[0..6].* = .{ dimensions, pattern, flags, 7, 5, 12 };
    input[6..12].* = .{ 1, 2, 3, 4, 9, 14 };
    input[12] = 17;
    input[20] = 3;
    input[21..29].* = commands;
    return input;
}
