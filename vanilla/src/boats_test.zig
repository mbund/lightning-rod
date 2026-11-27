//! Boats against vanilla: BoatOracle.java runs vanilla 1.21.8's AbstractBoat.tick for an oak boat
//! no player steers on random terrain, which the Java and Zig sides build alike from a
//! java.util.Random of the scenario's seed, and prints a hash of the boat's state after each tick.

const std = @import("std");
const game_data = @import("game_data");
const defaults = @import("vanilla_definitions").defaults;
const mobs = @import("vanilla_mobs");
const entities = @import("entities");

const body = mobs.body;
const boat_module = mobs.boat;
const mob_blocks = mobs.mob_blocks;
const JavaRandom = mobs.java_random.JavaRandom;
const clip = @import("vanilla_bodies").clip;

const size_x = 20;
const size_y = 10;
const size_z = 20;
const golden_boats = @embedFile("testdata/boats.txt");
const palette_names = @embedFile("testdata/boat_palette.txt");

/// The terrain BoatOracle.terrain builds: stone under a sea up to three deep, or none, and 48
/// features from the palette, bubble columns and flowing water.
const Terrain = struct {
    states: []u16,
    palette: []u16,
    lily_pad: u16,
    volume: body.Volume,

    fn init(allocator: std.mem.Allocator) !Terrain {
        var count: usize = 0;
        var names = std.mem.tokenizeScalar(u8, palette_names, '\n');
        while (names.next()) |_| count += 1;
        const palette = try allocator.alloc(u16, count);
        names.reset();
        for (palette) |*state| state.* = try stateOf(names.next().?);
        const states = try allocator.alloc(u16, size_x * size_y * size_z);
        return .{ .states = states, .palette = palette, .lily_pad = try stateOf("minecraft:lily_pad"), .volume = .{ .size = .{ size_x, size_y, size_z }, .states = states } };
    }

    fn put(self: *Terrain, x: i32, y: i32, z: i32, state: u16) void {
        self.states[(@as(usize, @intCast(y)) * size_z + @as(usize, @intCast(z))) * size_x + @as(usize, @intCast(x))] = state;
    }

    fn generate(self: *Terrain, random: *JavaRandom) !void {
        @memset(self.states, try stateOf("minecraft:air"));
        const sea = random.nextIntBounded(4);
        for (0..size_z) |z| for (0..size_x) |x| {
            self.put(@intCast(x), 0, @intCast(z), try stateOf("minecraft:stone"));
            var y: i32 = 1;
            while (y <= sea) : (y += 1) self.put(@intCast(x), y, @intCast(z), try stateOf("minecraft:water[level=0]"));
        };
        for (0..48) |_| {
            const x = random.nextIntBounded(size_x);
            const z = random.nextIntBounded(size_z);
            const kind: usize = @intCast(random.nextIntBounded(@intCast(self.palette.len + 2)));
            if (kind == self.palette.len) {
                if (sea == 0) continue;
                const drag = random.nextIntBounded(2) == 0;
                self.put(x, 0, z, try stateOf(if (drag) "minecraft:magma_block" else "minecraft:soul_sand"));
                var y: i32 = 1;
                while (y <= sea) : (y += 1) self.put(x, y, z, try stateOf(if (drag) "minecraft:bubble_column[drag=true]" else "minecraft:bubble_column[drag=false]"));
            } else if (kind == self.palette.len + 1) {
                const amount = 1 + random.nextIntBounded(7);
                var name: [32]u8 = undefined;
                self.put(x, sea + 1, z, try stateOf(try std.fmt.bufPrint(&name, "minecraft:water[level={d}]", .{8 - amount})));
            } else {
                const state = self.palette[kind];
                if (state == self.lily_pad) {
                    if (sea > 0) self.put(x, sea + 1, z, state);
                    continue;
                }
                const top = 1 + random.nextIntBounded(sea + 2);
                var y: i32 = 1;
                while (y <= top) : (y += 1) self.put(x, y, z, state);
            }
        }
    }

    fn level(self: *const Terrain, blocks: *const mob_blocks.MobBlocks, colliders: *body.Colliders) !body.Level {
        return .{ .copies = null, .volume = &self.volume, .colliders = colliders, .blocks = blocks, .world = 0, .minimum_y = 0, .height = 256, .air = try stateOf("minecraft:air") };
    }
};

fn stateOf(name: []const u8) !u16 {
    return @intCast(game_data.registry.blockStateId(name) orelse return error.UnknownState);
}

/// Nothing but blocks: no entities, and nothing that hurts a boat. Lily pads a boat breaks go,
/// as the oracle's level lets them, their drops with nowhere to go.
const Quiet = struct {
    level_random: JavaRandom = JavaRandom.init(0),
    terrain: *Terrain,

    fn around(self: *Quiet) boat_module.Around {
        return .{ .context = self, .collisions = collisions, .hurt = hurt, .sound = sound, .destroy_block = change, .break_block = breakBlock, .lower_cauldron = change, .eject = eject, .level_random = &self.level_random };
    }
    fn breakBlock(context: *anyopaque, _: u32, position: [3]i32) anyerror!void {
        const self: *Quiet = @ptrCast(@alignCast(context));
        self.terrain.put(position[0], position[1], position[2], try stateOf("minecraft:air"));
    }
    fn collisions(_: *anyopaque, _: body.Box, output: []body.Box) anyerror![]body.Box {
        return output[0..0];
    }
    fn hurt(_: *anyopaque, _: f32) anyerror!bool {
        return error.UnexpectedHurt;
    }
    fn sound(_: *anyopaque, _: boat_module.Sound, _: f32, _: f32) void {}
    fn eject(_: *anyopaque) anyerror!void {}
    fn change(_: *anyopaque, _: u32, _: [3]i32) anyerror!void {
        return error.UnexpectedEdit;
    }
};

/// BoatOracle.state: FNV-1a over the position's and velocity's bits, the status and whether the
/// boat is on the ground.
fn hash(state: entities.State, boat: *const boat_module.Boat) u64 {
    var value: u64 = 0xcbf29ce484222325;
    for (state.position ++ state.velocity) |component| {
        const bits: u64 = @bitCast(component);
        for (0..8) |at| {
            value ^= (bits >> @intCast(at * 8)) & 0xff;
            value *%= 0x100000001b3;
        }
    }
    value ^= if (boat.status) |status| @backingInt(status) else 0xff;
    value *%= 0x100000001b3;
    value ^= @intFromBool(boat.on_ground);
    value *%= 0x100000001b3;
    return value;
}

test "boats float, drift and slide as vanilla's on random terrain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const deps = try defaults.prepare(allocator);
    const blocks = try mob_blocks.MobBlocks.init(allocator, deps.blocks);
    var terrain = try Terrain.init(allocator);
    var colliders: body.Colliders = .{};
    const scratch = try allocator.create(boat_module.Scratch);
    scratch.* = .{};
    var quiet: Quiet = .{ .terrain = &terrain };
    var lines = std.mem.tokenizeScalar(u8, golden_boats, '\n');
    var scenarios: usize = 0;
    var line = lines.next();
    while (line) |header| {
        try std.testing.expect(std.mem.startsWith(u8, header, "seed "));
        const seed = try std.fmt.parseInt(i64, header["seed ".len..], 10);
        var random = JavaRandom.init(seed);
        try terrain.generate(&random);
        const level = try terrain.level(blocks, &colliders);
        const x = 3 + @as(f64, @floatFromInt(random.nextIntBounded(14000))) / 1000.0;
        const y = 1 + @as(f64, @floatFromInt(random.nextIntBounded(6000))) / 1000.0;
        const z = 3 + @as(f64, @floatFromInt(random.nextIntBounded(14000))) / 1000.0;
        var velocity: [3]f64 = undefined;
        velocity[0] = @as(f64, @floatFromInt(random.nextIntBounded(2001) - 1000)) / 2000.0;
        velocity[1] = @as(f64, @floatFromInt(random.nextIntBounded(1001) - 500)) / 1000.0;
        velocity[2] = @as(f64, @floatFromInt(random.nextIntBounded(2001) - 1000)) / 2000.0;
        // Placed where it is clear, raised a block at a time, as the oracle places it.
        var start_y = y;
        while (!try body.noCollision(&level, boat_module.boxAt(.{ x, start_y, z }), .{ .bottom = start_y })) start_y += 1;
        var state: entities.State = .{ .uuid = 1, .kind = 0, .world = 0, .position = .{ x, start_y, z }, .velocity = velocity };
        var boat: boat_module.Boat = .{ .random = JavaRandom.init(seed) };
        var tick: usize = 0;
        line = lines.next();
        while (line) |expected| : (line = lines.next()) {
            if (std.mem.startsWith(u8, expected, "seed ")) break;
            try boat_module.tick(&level, quiet.around(), &state, &boat, scratch, &.{});
            const want = try std.fmt.parseInt(u64, expected, 16);
            const got = hash(state, &boat);
            if (want != got) {
                std.debug.print("seed {d} tick {d}: vanilla {x}, port {x} falling {d}: {x} {x} {x} {x} {x} {x} {d} {d}\n", .{ seed, tick, want, got, boat.fall_distance, @as(u64, @bitCast(state.position[0])), @as(u64, @bitCast(state.position[1])), @as(u64, @bitCast(state.position[2])), @as(u64, @bitCast(state.velocity[0])), @as(u64, @bitCast(state.velocity[1])), @as(u64, @bitCast(state.velocity[2])), if (boat.status) |status| @as(i32, @backingInt(status)) else -1, @intFromBool(boat.on_ground) });
                const box = boat_module.boxAt(state.position);
                var bx = @as(i32, @intFromFloat(@floor(box.min[0]))) - 1;
                while (bx <= @as(i32, @intFromFloat(@floor(box.max[0]))) + 1) : (bx += 1) {
                    var bz = @as(i32, @intFromFloat(@floor(box.min[2]))) - 1;
                    while (bz <= @as(i32, @intFromFloat(@floor(box.max[2]))) + 1) : (bz += 1) {
                        var by: i32 = 0;
                        while (by < 7) : (by += 1) {
                            const s = try level.state(bx, by, bz);
                            if (!game_data.physics.get(s).air) std.debug.print("  {d} {d} {d} {s}\n", .{ bx, by, bz, game_data.registry.blockStateName(s).? });
                        }
                    }
                }
                return error.BoatStrayed;
            }
            tick += 1;
            if (boat.removed) {
                line = lines.next();
                break;
            }
        }
        scenarios += 1;
    }
    try std.testing.expect(scenarios > 0);
}

/// What twenty rays through each scenario's terrain hit, by BoatOracle.clips: vanilla's
/// Level.clip through outlines and any fluid, which BoatItem.use places a boat by.
const golden_clips = @embedFile("testdata/clips.txt");

test "clips through outlines and fluids hit what vanilla's do, to the bit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const deps = try defaults.prepare(allocator);
    const blocks = try mob_blocks.MobBlocks.init(allocator, deps.blocks);
    var terrain = try Terrain.init(allocator);
    var colliders: body.Colliders = .{};
    var lines = std.mem.tokenizeScalar(u8, golden_clips, '\n');
    var rays: usize = 0;
    var hits: usize = 0;
    while (lines.next()) |header| {
        try std.testing.expect(std.mem.startsWith(u8, header, "seed "));
        const seed = try std.fmt.parseInt(i64, header["seed ".len..], 10);
        var terrain_random = JavaRandom.init(seed);
        try terrain.generate(&terrain_random);
        const level = try terrain.level(blocks, &colliders);
        var random = JavaRandom.init(seed ^ 0x636c6970);
        for (0..20) |ray| {
            var from: [3]f64 = undefined;
            from[0] = @as(f64, @floatFromInt(random.nextIntBounded(20000))) / 1000.0;
            from[1] = 1 + @as(f64, @floatFromInt(random.nextIntBounded(9000))) / 1000.0;
            from[2] = @as(f64, @floatFromInt(random.nextIntBounded(20000))) / 1000.0;
            var to: [3]f64 = undefined;
            to[0] = @as(f64, @floatFromInt(random.nextIntBounded(20000))) / 1000.0;
            to[1] = @as(f64, @floatFromInt(random.nextIntBounded(9000))) / 1000.0;
            to[2] = @as(f64, @floatFromInt(random.nextIntBounded(20000))) / 1000.0;
            const expected = lines.next().?;
            const hit = try clip.clip(&level, from, to, .any);
            errdefer std.debug.print("seed {d} ray {d}: vanilla {s}, port {any}, from {any} at {s}\n", .{ seed, ray, expected, hit, from, if (hit) |h| game_data.registry.blockStateName(level.state(h.cell[0], h.cell[1], h.cell[2]) catch 0).? else "-" });
            rays += 1;
            if (std.mem.eql(u8, expected, "miss")) {
                try std.testing.expect(hit == null);
                continue;
            }
            const found = hit orelse return error.MissedAHit;
            var fields = std.mem.tokenizeScalar(u8, expected, ' ');
            for (found.location) |component| try std.testing.expectEqual(try std.fmt.parseInt(u64, fields.next().?, 16), @as(u64, @bitCast(component)));
            for (found.cell) |component| try std.testing.expectEqual(try std.fmt.parseInt(i32, fields.next().?, 10), component);
            try std.testing.expectEqual(try std.fmt.parseInt(u8, fields.next().?, 10), @backingInt(found.face));
            try std.testing.expectEqual(try std.fmt.parseInt(u8, fields.next().?, 10), @intFromBool(found.inside));
            hits += 1;
        }
    }
    try std.testing.expect(rays == 3000 and hits > 1000);
}
