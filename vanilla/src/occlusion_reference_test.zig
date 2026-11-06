const std = @import("std");
const oracle = @import("oracle");
const production = @import("section_visibility_world.zig");
const lighting = @import("lighting.zig");
const game_data = @import("game_data");

test "production disclosure preserves independent rational ray witnesses through stepped walls and irregular occluders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const states = try arena.allocator().alloc(u16, 64 * 48 * 48);
    var world = try production.World.init(arena.allocator(), .{ .columns = 9, .sources = 1, .radius = 1 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const air: u16 = @intCast(game_data.registry.block_air_default_state);
    const eye: oracle.Eye = .{ .coordinates = .{ 4270, 36630, 4910 } };
    var random = std.Random.DefaultPrng.init(0x16c0a71);
    const rng = random.random();
    var witnesses: usize = 0;
    var hidden: usize = 0;
    for (0..12) |scene| {
        world.invalidate();
        const hole_x = rng.uintLessThan(usize, 44);
        const hole_z = rng.uintLessThan(usize, 44);
        for (0..64) |y| for (0..48) |z| for (0..48) |x| {
            const floor = 16 + x / 8 % 3 * 2;
            const roof = 44 + z / 8 % 3 * 2;
            const hole = scene != 0 and x >= hole_x and x < hole_x + 4 and z >= hole_z and z < hole_z + 4;
            const horizontal = ((y >= floor and y < floor + 6) or (y >= roof and y < roof + 6)) and !hole;
            const vertical = ((x >= 8 and x < 10) or (x >= 32 and x < 34) or (z >= 8 and z < 10) or (z >= 32 and z < 34)) and
                (scene % 3 == 0 or y < 24 or y >= 28 + scene);
            states[(y * 48 + z) * 48 + x] = if (scene != 11 and (horizontal or vertical)) stone else air;
        };
        if (scene >= 6 and scene <= 10) {
            var cubes: [24 * 32 * 24]bool = undefined;
            for (&cubes) |*solid| solid.* = rng.uintLessThan(u8, 100) < (scene - 1) * 10;
            for (0..64) |y| for (0..48) |z| for (0..48) |x| {
                states[(y * 48 + z) * 48 + x] = if (cubes[(y / 2 * 24 + z / 2) * 24 + x / 2]) stone else air;
            };
        }
        for (34..39) |y| for (18..23) |z| for (18..23) |x| {
            states[(y * 48 + z) * 48 + x] = air;
        };
        var sections: [36]lighting.Section = undefined;
        var reference: [36]oracle.Section = undefined;
        var masks: [9]u32 = undefined;
        for (0..9) |column| {
            const cx = @as(i32, @intCast(column % 3)) - 1;
            const cz = @as(i32, @intCast(column / 3)) - 1;
            const views = sections[column * 4 ..][0..4];
            for (views, 0..) |*section, y| {
                section.* = .{ .stamp = .{}, .view = .{ .rows = states[(y * 16 * 48 + column / 3 * 16) * 48 + column % 3 * 16 ..] } };
                const value = &reference[column * 4 + y];
                value.* = .{ .position = .{ cx, @intCast(y), cz } };
                for (0..4096) |local| if (section.view.get(@intCast(local)) == stone) {
                    value.occluders[local / 64] |= @as(u64, 1) << @intCast(local % 64);
                };
            }
            world.learn(.{ .world = 0, .x = cx, .z = cz, .minimum = 0 }, views);
        }
        var origin_storage: production.Source = undefined;
        const origin = world.source(0, 0, 4, eye.block(), &origin_storage).?;
        world.beginPoll();
        const query = world.query(origin, 0, 4, 1);
        while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        for (0..9) |column| {
            const at = reference[column * 4].position;
            masks[column] = world.mask(query, at[0], at[2]);
            if (scene == 9 and at[0] == -1 and at[2] == 1) try std.testing.expect(masks[column] & 1 == 0);
        }
        for (reference, 0..) |section, index| {
            const bit = @as(u32, 1) << @intCast(index % 4);
            const disclosed = masks[index / 4] & bit != 0;
            const selected = world.mask(query, section.position[0], section.position[2]) & bit;
            try std.testing.expectEqual(@as(u32, 0), selected & ~bit);
            hidden += @intFromBool(!disclosed);
            for (0..27) |sample| {
                var target: [3]i64 = undefined;
                var divisor: usize = 1;
                for (&target, 0..) |*coordinate, axis| {
                    coordinate.* = @as(i64, section.position[axis]) * 16 * oracle.Eye.scale + @as(i64, @intCast(sample / divisor % 3)) * 5 * oracle.Eye.scale + oracle.Eye.scale * 5 / 2;
                    divisor *= 3;
                }
                if (!oracle.rayWitness(&reference, eye, target, index)) continue;
                witnesses += 1;
                if (!disclosed or selected == 0) {
                    std.debug.print("scene={d} section={any} visible_target={any}\n", .{ scene, section.position, target });
                    return error.VisibleSectionConcealed;
                }
            }
        }
    }
    try std.testing.expect(witnesses > 100);
    try std.testing.expect(hidden > 0);
}
