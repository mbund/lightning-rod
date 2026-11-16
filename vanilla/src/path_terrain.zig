//! The random terrain PathOracle.java builds for each path scenario, made alike from
//! java.util.Random of the scenario's seed: stone under grass three to five blocks deep, a block
//! from the palette over one column in five, and a cow, calf or grown, that wants to go somewhere.

const std = @import("std");
const game_data = @import("game_data");
const mobs = @import("vanilla_mobs");

const body = mobs.body;
const pathfinding = mobs.pathfinding;
const mob_blocks = mobs.mob_blocks;
const JavaRandom = mobs.java_random.JavaRandom;

pub const size_x = 24;
pub const size_y = 12;
pub const size_z = 24;

pub const palette_names = @embedFile("testdata/path_palette.txt");

pub const Terrain = struct {
    states: []u16,
    palette: []u16,
    heights: [size_z][size_x]i32 = undefined,
    volume: body.Volume,
    air: u16,
    stone: u16,
    grass: u16,

    pub fn init(allocator: std.mem.Allocator) !Terrain {
        var count: usize = 0;
        var names = std.mem.tokenizeScalar(u8, palette_names, '\n');
        while (names.next()) |_| count += 1;
        const palette = try allocator.alloc(u16, count);
        names.reset();
        for (palette) |*state| state.* = @intCast(game_data.registry.blockStateId(names.next().?) orelse return error.UnknownState);
        const states = try allocator.alloc(u16, size_x * size_y * size_z);
        return .{
            .states = states,
            .palette = palette,
            .volume = .{ .size = .{ size_x, size_y, size_z }, .states = states },
            .air = @intCast(game_data.registry.blockStateId("minecraft:air").?),
            .stone = @intCast(game_data.registry.blockStateId("minecraft:stone").?),
            .grass = @intCast(game_data.registry.blockStateId("minecraft:grass_block[snowy=false]").?),
        };
    }

    pub const Scenario = struct {
        mob: pathfinding.Mob,
        request: pathfinding.Search.Request,
    };

    /// Builds a scenario's terrain and returns its cow and where the cow wants to go.
    pub fn generate(self: *Terrain, seed: i64) Scenario {
        var random = JavaRandom.init(seed);
        @memset(self.states, self.air);
        for (0..size_z) |z| for (0..size_x) |x| {
            const height = 3 + random.nextIntBounded(3);
            self.heights[z][x] = height;
            var y: i32 = 0;
            while (y < height) : (y += 1) self.states[index(x, y, z)] = if (y == height - 1) self.grass else self.stone;
            while (y < height + 2) : (y += 1) {
                if (random.nextIntBounded(5) == 0) self.states[index(x, y, z)] = self.palette[@intCast(random.nextIntBounded(@intCast(self.palette.len)))];
            }
        };
        const start_x = 6 + random.nextIntBounded(12);
        const start_z = 6 + random.nextIntBounded(12);
        const target_x = random.nextIntBounded(size_x);
        const target_z = random.nextIntBounded(size_z);
        const baby = random.nextIntBounded(2) == 0;
        var mob: pathfinding.Mob = .{
            .width = if (baby) 0.45 else 0.9,
            .height = if (baby) 0.7 else 1.4,
            .max_up_step = 0.6,
            .position = .{ @as(f64, @floatFromInt(start_x)) + 0.5, @floatFromInt(self.heights[@intCast(start_z)][@intCast(start_x)]), @as(f64, @floatFromInt(start_z)) + 0.5 },
            .on_ground = true,
            .in_water = false,
            .can_float = true,
        };
        mob.malus[@backingInt(mob_blocks.PathType.danger_fire)] = 16.0;
        mob.malus[@backingInt(mob_blocks.PathType.damage_fire)] = -1.0;
        return .{ .mob = mob, .request = .{
            .target = .{ target_x, self.heights[@intCast(target_z)][@intCast(target_x)], target_z },
            .max_range = 16.0,
            .accuracy = 1,
            .max_visited_nodes = 256,
        } };
    }

    pub fn level(self: *const Terrain, blocks: *const mob_blocks.MobBlocks) body.Level {
        return .{ .copies = null, .volume = &self.volume, .blocks = blocks, .world = 0, .minimum_y = 0, .height = 256, .air = self.air };
    }

    fn index(x: usize, y: i32, z: usize) usize {
        return (@as(usize, @intCast(y)) * size_z + z) * size_x + x;
    }
};
