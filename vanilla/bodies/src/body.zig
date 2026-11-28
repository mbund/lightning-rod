//! A mob's body as vanilla's Entity and LivingEntity move it: collisions with stepping up
//! (Entity.collide), Entity.move, LivingEntity.travel on land and in fluids, fluid heights and
//! currents, climbing, falling and the blocks a body stands on. The world is read through a
//! Level, and what happens to the mob as a result (damage, sounds) is reported through Events
//! for the caller to apply, so the body itself stays plain data and arithmetic.

const std = @import("std");
const game_data = @import("game_data");
const chunks = @import("chunks");
const mth = @import("mth.zig");
const mob_blocks = @import("mob_blocks.zig");
const shape_classes = @import("shape_classes.zig");
const JavaRandom = @import("java_random.zig").JavaRandom;
const Bounds = @import("vanilla_content").border.Bounds;

const MobBlocks = mob_blocks.MobBlocks;
const assert = std.debug.assert;
/// Debug builds still do what a shortcut spares and check it found the same.
const verify_skips = @import("builtin").mode == .debug;

pub const Box = struct {
    min: [3]f64,
    max: [3]f64,

    /// The AABB constructor, which takes two corners in either order.
    pub fn corners(a: [3]f64, b: [3]f64) Box {
        return .{ .min = .{ @min(a[0], b[0]), @min(a[1], b[1]), @min(a[2], b[2]) }, .max = .{ @max(a[0], b[0]), @max(a[1], b[1]), @max(a[2], b[2]) } };
    }

    pub fn move(self: Box, by: [3]f64) Box {
        return .{ .min = .{ self.min[0] + by[0], self.min[1] + by[1], self.min[2] + by[2] }, .max = .{ self.max[0] + by[0], self.max[1] + by[1], self.max[2] + by[2] } };
    }

    /// AABB.expandTowards.
    pub fn expandTowards(self: Box, by: [3]f64) Box {
        var result = self;
        for (0..3) |axis| {
            if (by[axis] < 0) result.min[axis] += by[axis] else if (by[axis] > 0) result.max[axis] += by[axis];
        }
        return result;
    }

    pub fn inflate(self: Box, x: f64, y: f64, z: f64) Box {
        return .{ .min = .{ self.min[0] - x, self.min[1] - y, self.min[2] - z }, .max = .{ self.max[0] + x, self.max[1] + y, self.max[2] + z } };
    }

    /// AABB.intersects, strict on every axis.
    pub fn intersects(self: Box, other: Box) bool {
        return self.min[0] < other.max[0] and self.max[0] > other.min[0] and
            self.min[1] < other.max[1] and self.max[1] > other.min[1] and
            self.min[2] < other.max[2] and self.max[2] > other.min[2];
    }
};

/// EntityDimensions.makeBoundingBox, which halves the width as a float.
pub fn makeBox(position: [3]f64, width: f32, height: f32) Box {
    const half: f64 = width / 2.0;
    return .{ .min = .{ position[0] - half, position[1], position[2] - half }, .max = .{ position[0] + half, position[1] + height, position[2] + half } };
}

/// Blocks held in memory, for tests that build a world of their own.
pub const Volume = struct {
    size: [3]i32,
    /// By (y * size z + z) * size x + x.
    states: []const u16,

    pub fn get(self: *const Volume, x: i32, y: i32, z: i32, air: u16) u16 {
        if (x < 0 or y < 0 or z < 0 or x >= self.size[0] or y >= self.size[1] or z >= self.size[2]) return air;
        return self.states[@intCast((y * self.size[2] + z) * self.size[0] + x)];
    }
};

/// Blocks as they stood before edits that came later, laid over the latest state. A path an
/// edit recomputes sees the world as of that edit, as vanilla finds it in the middle of a batch.
pub const Overlay = struct {
    states: std.AutoHashMapUnmanaged(Key, u16) = .empty,

    pub const Key = struct { world: u32, x: i32, y: i32, z: i32 };

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !Overlay {
        var overlay: Overlay = .{};
        try overlay.states.ensureTotalCapacity(allocator, capacity);
        return overlay;
    }

    pub fn get(self: *const Overlay, world: u32, x: i32, y: i32, z: i32) ?u16 {
        return self.states.get(.{ .world = world, .x = x, .y = y, .z = z });
    }

    /// The world right after edit `at`: each block edited later holds the state the first of
    /// those edits replaced.
    pub fn layAfter(self: *Overlay, edits: []const Edit, at: usize) void {
        assert(at < edits.len and edits.len <= self.states.capacity());
        self.states.clearRetainingCapacity();
        // From the last edit back, so the earliest one after `at` at each block wins.
        var later = edits.len;
        while (later > at + 1) {
            later -= 1;
            const edit = edits[later];
            self.states.putAssumeCapacity(.{ .world = edit.world, .x = edit.position[0], .y = edit.position[1], .z = edit.position[2] }, edit.previous);
        }
    }

    /// An edit made after every one laid, taken in their order: the world before it shows
    /// where no earlier edit after `at` did.
    pub fn layLater(self: *Overlay, world: u32, position: [3]i32, previous: u16) void {
        const entry = self.states.getOrPutAssumeCapacity(.{ .world = world, .x = position[0], .y = position[1], .z = position[2] });
        if (!entry.found_existing) entry.value_ptr.* = previous;
    }
};

/// A block edit held for paths to answer.
pub const Edit = struct {
    world: u32,
    position: [3]i32,
    /// The state it replaced.
    previous: u16,
    /// Whether it changed a collision shape, which is what paths answer.
    collision: bool,
    game_time: i64,
};

test "an overlay shows the world right after each edit of a batch" {
    var overlay = try Overlay.init(std.testing.allocator, 8);
    defer overlay.states.deinit(std.testing.allocator);
    // A door's two halves open, then the lower one closes again, all in one batch.
    const edits = [_]Edit{
        .{ .world = 0, .position = .{ 4, 64, 4 }, .previous = 10, .collision = true, .game_time = 7 },
        .{ .world = 0, .position = .{ 4, 65, 4 }, .previous = 20, .collision = true, .game_time = 7 },
        .{ .world = 0, .position = .{ 4, 64, 4 }, .previous = 11, .collision = true, .game_time = 7 },
    };
    overlay.layAfter(&edits, 0);
    try std.testing.expectEqual(@as(?u16, 11), overlay.get(0, 4, 64, 4));
    try std.testing.expectEqual(@as(?u16, 20), overlay.get(0, 4, 65, 4));
    try std.testing.expectEqual(@as(?u16, null), overlay.get(1, 4, 64, 4));
    overlay.layAfter(&edits, 1);
    try std.testing.expectEqual(@as(?u16, 11), overlay.get(0, 4, 64, 4));
    try std.testing.expectEqual(@as(?u16, null), overlay.get(0, 4, 65, 4));
    overlay.layAfter(&edits, 2);
    try std.testing.expectEqual(@as(u32, 0), overlay.states.count());
}

/// The blocks around one mob, read once as its tick begins, which its body then reads many times
/// over: collisions, the block it stands on, fluids, what it is inside. Reads outside fall
/// through to the world, and edits during the tick change it as they change the world.
pub const Window = struct {
    world: u32 = 0,
    origin: [3]i32 = .{ 0, 0, 0 },
    states: [width * height * width]u16 = undefined,
    /// What the sections it reads from may hold, by mob_blocks' marks.
    marks: u8 = 0xff,
    /// The copies' slots it was filled from, each of the up to eight sections it spans that
    /// `sections` has, with their stamps then: while each is unchanged, so is it. None when it
    /// was read block by block.
    sections: u8 = 0,
    slots: [8]u32 = undefined,
    stamps: [8]u64 = undefined,
    filled_from_copies: bool = false,
    /// By row, (dy * width + dz), a bit by dx for each cell whose state may have a collision shape,
    /// as MobBlocks.mayCollide has it: what a scan for shapes reads, and air it passes by.
    shaped: [height * width]u8 = undefined,
    /// The blocks it classes its cells by, once filled.
    blocks: ?*const MobBlocks = null,

    /// Two blocks either side of the mob's block, and from two below its feet to three above,
    /// which covers a walking body's collision cells.
    const width = 5;
    const height = 6;

    /// Whether every section it was filled from is as it was then, so a fill now would make it
    /// again.
    pub fn unchanged(self: *const Window, copies: *const chunks.Copies) bool {
        if (!self.filled_from_copies) return false;
        const base: [3]i32 = .{ @divFloor(self.origin[0], 16), @divFloor(self.origin[1], 16), @divFloor(self.origin[2], 16) };
        for (0..8) |which| {
            if (self.sections & (@as(u8, 1) << @intCast(which)) == 0) continue;
            const key = sectionKey(base, which);
            if (!copies.unchanged(self.slots[which], self.world, key[0], key[1], key[2], self.stamps[which])) return false;
        }
        return true;
    }

    pub fn fill(self: *Window, level: *const Level, at: [3]i32) !void {
        assert(level.window == null and level.overlay == null);
        self.world = level.world;
        self.origin = .{ at[0] - 2, at[1] - 2, at[2] - 2 };
        self.filled_from_copies = false;
        self.sections = 0;
        // Classed once whole, so an edit to a window a failed fill left classes nothing.
        self.blocks = null;
        const copies = level.copies orelse {
            // Worlds held in memory, for tests, read block by block, marked by what they hold.
            self.marks = 0;
            for (0..height) |dy| for (0..width) |dz| for (0..width) |dx| {
                const state = try level.state(self.origin[0] + @as(i32, @intCast(dx)), self.origin[1] + @as(i32, @intCast(dy)), self.origin[2] + @as(i32, @intCast(dz)));
                self.states[(dy * width + dz) * width + dx] = state;
                self.marks |= level.blocks.marks[state];
            };
            return self.classifyAll(level.blocks);
        };
        // The window spans at most two sections along each axis. Each is fetched, then all are
        // checked still held, as a later fetch may take an earlier one's slot when the copies are
        // full, and fetched again until none was.
        const base: [3]i32 = .{ @divFloor(self.origin[0], 16), @divFloor(self.origin[1], 16), @divFloor(self.origin[2], 16) };
        const top: [3]i32 = .{ @divFloor(self.origin[0] + width - 1, 16), @divFloor(self.origin[1] + height - 1, 16), @divFloor(self.origin[2] + width - 1, 16) };
        const lowest = @divFloor(level.minimum_y, 16);
        const highest = @divFloor(level.minimum_y + level.height - 1, 16);
        var slots: [8]u32 = undefined;
        var rounds: usize = 0;
        while (true) : (rounds += 1) {
            assert(rounds < 3);
            for (0..8) |which| {
                const key = sectionKey(base, which);
                if (key[0] > top[0] or key[1] > top[1] or key[2] > top[2] or key[1] < lowest or key[1] > highest) continue;
                slots[which] = try copies.sectionSlot(level.world, key[0], key[1], key[2]);
            }
            var held = true;
            for (0..8) |which| {
                const key = sectionKey(base, which);
                if (key[0] > top[0] or key[1] > top[1] or key[2] > top[2] or key[1] < lowest or key[1] > highest) continue;
                if (!copies.holds(slots[which], level.world, key[0], key[1], key[2])) held = false;
            }
            if (held) break;
        }
        // The sections it is filled from, each as it stands, for whoever keeps it to tell later.
        for (0..8) |which| {
            const key = sectionKey(base, which);
            if (key[0] > top[0] or key[1] > top[1] or key[2] > top[2] or key[1] < lowest or key[1] > highest) continue;
            self.sections |= @as(u8, 1) << @intCast(which);
            self.slots[which] = slots[which];
            self.stamps[which] = copies.stamps[slots[which]];
        }
        self.filled_from_copies = true;
        self.marks = 0;
        const split = @min(width, @as(usize, @intCast(16 - @mod(self.origin[0], 16))));
        for (0..height) |dy| {
            const y = self.origin[1] + @as(i32, @intCast(dy));
            const ky: usize = @intCast(@divFloor(y, 16) - base[1]);
            for (0..width) |dz| {
                const z = self.origin[2] + @as(i32, @intCast(dz));
                const kz: usize = @intCast(@divFloor(z, 16) - base[2]);
                const row = self.states[(dy * width + dz) * width ..][0..width];
                if (y < level.minimum_y or y >= level.minimum_y + level.height) {
                    @memset(row, level.air);
                    continue;
                }
                const local: usize = @intCast(@mod(y, 16) * 256 + @mod(z, 16) * 16);
                for (0..2) |kx| {
                    const begin: usize = if (kx == 0) 0 else split;
                    const end: usize = if (kx == 0) split else width;
                    if (begin >= end) continue;
                    const section_slot = slots[(ky * 2 + kz) * 2 + kx];
                    self.marks |= copies.marked[section_slot];
                    const section = &copies.states[section_slot];
                    const start: usize = local + @as(usize, @intCast(@mod(self.origin[0] + @as(i32, @intCast(begin)), 16)));
                    for (row[begin..end], section[start..][0 .. end - begin]) |*state, value| state.* = value;
                }
            }
        }
        self.classifyAll(level.blocks);
    }

    fn classifyAll(self: *Window, blocks: *const MobBlocks) void {
        self.blocks = blocks;
        for (0..height * width) |row| self.classify(row);
    }

    /// Sets a row's bits in `shaped` by its states.
    fn classify(self: *Window, row: usize) void {
        const blocks = self.blocks.?;
        var bits: u8 = 0;
        for (self.states[row * width ..][0..width], 0..) |state, dx| {
            if (blocks.mayCollide(state)) bits |= @as(u8, 1) << @intCast(dx);
        }
        self.shaped[row] = bits;
    }

    /// Of the cells from x `from` to `to` of a row it covers, those that may have a collision
    /// shape, a bit each from `from` up.
    pub fn shapedIn(self: *const Window, from: i32, to: i32, y: i32, z: i32) u8 {
        assert(from <= to);
        const row: usize = @intCast((y - self.origin[1]) * width + (z - self.origin[2]));
        const low: u3 = @intCast(from - self.origin[0]);
        const count: u4 = @intCast(to - from + 1);
        return (self.shaped[row] >> low) & @as(u8, @intCast((@as(u16, 1) << count) - 1));
    }

    fn sectionKey(base: [3]i32, which: usize) [3]i32 {
        return .{ base[0] + @as(i32, @intCast(which & 1)), base[1] + @as(i32, @intCast(which >> 2)), base[2] + @as(i32, @intCast((which >> 1) & 1)) };
    }

    fn slot(self: *const Window, world: u32, x: i32, y: i32, z: i32) ?usize {
        if (world != self.world) return null;
        const dx = x -% self.origin[0];
        const dy = y -% self.origin[1];
        const dz = z -% self.origin[2];
        if (@as(u32, @bitCast(dx)) >= width or @as(u32, @bitCast(dy)) >= height or @as(u32, @bitCast(dz)) >= width) return null;
        return @intCast((dy * width + dz) * width + dx);
    }

    /// Whether every cell from first to last, inclusive, lies in the window.
    /// Whether it is the window `fill` makes around a block.
    pub fn around(self: *const Window, world: u32, at: [3]i32) bool {
        return self.world == world and std.meta.eql(self.origin, [3]i32{ at[0] - 2, at[1] - 2, at[2] - 2 });
    }

    /// Debug: whether every cell reads as the level does without it, as one filled now would.
    pub fn matches(self: *const Window, level: *const Level) !bool {
        assert(level.window == null);
        for (0..height) |dy| for (0..width) |dz| for (0..width) |dx| {
            const x = self.origin[0] + @as(i32, @intCast(dx));
            const y = self.origin[1] + @as(i32, @intCast(dy));
            const z = self.origin[2] + @as(i32, @intCast(dz));
            if (self.states[(dy * width + dz) * width + dx] != try level.state(x, y, z)) return false;
        };
        for (0..height * width) |row| {
            var bits: u8 = 0;
            for (self.states[row * width ..][0..width], 0..) |state, dx| {
                if (level.blocks.mayCollide(state)) bits |= @as(u8, 1) << @intCast(dx);
            }
            if (bits != self.shaped[row]) return false;
        }
        return true;
    }

    pub fn covers(self: *const Window, world: u32, first: [3]i32, last: [3]i32) bool {
        if (world != self.world) return false;
        return first[0] >= self.origin[0] and first[1] >= self.origin[1] and first[2] >= self.origin[2] and
            last[0] < self.origin[0] + width and last[1] < self.origin[1] + height and last[2] < self.origin[2] + width;
    }

    /// A cell the window covers.
    pub fn cell(self: *const Window, x: i32, y: i32, z: i32) u16 {
        return self.states[@intCast(((y - self.origin[1]) * height_stride + (z - self.origin[2])) * width + (x - self.origin[0]))];
    }

    const height_stride = width;

    pub fn get(self: *const Window, world: u32, x: i32, y: i32, z: i32) ?u16 {
        return self.states[self.slot(world, x, y, z) orelse return null];
    }

    pub fn edit(self: *Window, world: u32, position: [3]i32, state: u16) void {
        const at = self.slot(world, position[0], position[1], position[2]) orelse return;
        self.states[at] = state;
        if (self.blocks != null) self.classify(at / width);
    }
};

/// The world as a body reads it.
pub const Level = struct {
    copies: ?*chunks.Copies,
    volume: ?*const Volume = null,
    overlay: ?*const Overlay = null,
    window: ?*const Window = null,
    /// Room to gather colliders in, which moving bodies need and too large to fill on the stack.
    colliders: ?*Colliders = null,
    blocks: *const MobBlocks,
    world: u32,
    minimum_y: i32,
    height: i32,
    air: u16,
    /// The world border in this world, if bodies collide with one.
    border: ?Bounds = null,
    /// The entities bodies collide with, Level.getEntityCollisions; none, and they collide with
    /// none.
    entities: ?EntitySource = null,
    /// BiomeManager.biomeZoomSeed: the hashed seed clients are sent, which blends biome borders.
    biome_zoom_seed: i64 = 0,

    /// Outside the world's height a level reads void air, which collides with nothing.
    pub fn state(self: *const Level, x: i32, y: i32, z: i32) !u16 {
        if (y < self.minimum_y or y >= self.minimum_y + self.height) return self.air;
        if (self.overlay) |overlay| if (overlay.get(self.world, x, y, z)) |earlier| return earlier;
        if (self.window) |window| if (window.get(self.world, x, y, z)) |near| return near;
        if (self.volume) |volume| return volume.get(x, y, z, self.air);
        return self.copies.?.get(self.world, .{ .x = x, .y = y, .z = z });
    }

    /// Whether none of the cells from first to last is marked with any of the bits, by the marks
    /// of the sections they lie in, so a scan for them there would find nothing. Blocks as they
    /// stood before an edit are not marked, so under an overlay nothing is ruled out.
    pub fn without(self: *const Level, marks: u8, first: [3]i32, last: [3]i32) !bool {
        if (self.overlay != null) return false;
        return (try self.marked(first, last)) & marks == 0;
    }

    /// What the sections holding the cells from first to last may hold, by mob_blocks' marks: the
    /// window's when it covers them, else each section's copy's, else anything.
    pub fn marked(self: *const Level, first: [3]i32, last: [3]i32) !u8 {
        if (self.window) |window| if (window.covers(self.world, first, last)) return window.marks;
        const copies = self.copies orelse return 0xff;
        if (copies.marks == null) return 0xff;
        const bottom = @divFloor(self.minimum_y, 16);
        const top = @divFloor(self.minimum_y + self.height - 1, 16);
        var result: u8 = 0;
        var y = @max(@divFloor(first[1], 16), bottom);
        while (y <= @min(@divFloor(last[1], 16), top)) : (y += 1) {
            var z = @divFloor(first[2], 16);
            while (z <= @divFloor(last[2], 16)) : (z += 1) {
                var x = @divFloor(first[0], 16);
                while (x <= @divFloor(last[0], 16)) : (x += 1) result |= copies.marked[try copies.sectionSlot(self.world, x, y, z)];
            }
        }
        return result;
    }

    /// LevelReader.getBiome, by BiomeManager.getBiome: of the eight biome cells around a block,
    /// the one nearest it once each is moved by a hash of the zoom seed, as vanilla blends biome
    /// borders. Null for a level held in memory, or a section stored without biomes.
    pub fn biome(self: *const Level, position: [3]i32) !?u16 {
        const shifted: [3]i32 = .{ position[0] - 2, position[1] - 2, position[2] - 2 };
        var base: [3]i32 = undefined;
        var fraction: [3]f64 = undefined;
        for (0..3) |axis| {
            base[axis] = shifted[axis] >> 2;
            fraction[axis] = @as(f64, @floatFromInt(shifted[axis] & 3)) / 4.0;
        }
        var nearest: [3]i32 = base;
        var best = std.math.inf(f64);
        for (0..8) |corner| {
            const far = [3]bool{ corner & 4 != 0, corner & 2 != 0, corner & 1 != 0 };
            var cell: [3]i32 = undefined;
            var offset: [3]f64 = undefined;
            for (0..3) |axis| {
                cell[axis] = if (far[axis]) base[axis] + 1 else base[axis];
                offset[axis] = if (far[axis]) fraction[axis] - 1.0 else fraction[axis];
            }
            const distance = fiddledDistance(self.biome_zoom_seed, cell, offset);
            if (best > distance) {
                nearest = cell;
                best = distance;
            }
        }
        return self.noiseBiome(nearest);
    }

    /// ChunkAccess.getNoiseBiome: the biome cell at quart coordinates, its height kept within the
    /// world's.
    fn noiseBiome(self: *const Level, quart: [3]i32) !?u16 {
        const copies = self.copies orelse return null;
        const lowest = self.minimum_y >> 2;
        const highest = lowest + (self.height >> 2) - 1;
        return copies.biome(self.world, .{ quart[0], std.math.clamp(quart[1], lowest, highest), quart[2] });
    }

    pub fn fluid(self: *const Level, x: i32, y: i32, z: i32) !game_data.physics_data.State {
        return game_data.physics.get(try self.state(x, y, z));
    }
};

/// BiomeManager.getFiddledDistance: how far a cell's corner, moved by its hash, is from the block.
fn fiddledDistance(seed: i64, cell: [3]i32, offset: [3]f64) f64 {
    var hash = nextLcg(seed, cell[0]);
    hash = nextLcg(hash, cell[1]);
    hash = nextLcg(hash, cell[2]);
    hash = nextLcg(hash, cell[0]);
    hash = nextLcg(hash, cell[1]);
    hash = nextLcg(hash, cell[2]);
    const x = fiddle(hash);
    hash = nextLcg(hash, seed);
    const y = fiddle(hash);
    hash = nextLcg(hash, seed);
    const z = fiddle(hash);
    return square(offset[2] + z) + square(offset[1] + y) + square(offset[0] + x);
}

/// LinearCongruentialGenerator.next.
fn nextLcg(state: i64, add: i64) i64 {
    return state *% (state *% 6364136223846793005 +% 1442695040888963407) +% add;
}

/// BiomeManager.getFiddle.
fn fiddle(hash: i64) f64 {
    return (@as(f64, @floatFromInt(@mod(hash >> 24, 1024))) / 1024.0 - 0.5) * 0.9;
}

fn square(value: f64) f64 {
    return value * value;
}

/// What a collision query knows about the entity, EntityCollisionContext: for the few blocks whose
/// collision shape depends on it, and for the entities it collides with.
pub const Context = struct {
    bottom: f64 = 0,
    fall_distance: f64 = 0,
    /// CollisionContext.empty, for queries with no entity: only solid entities count, as
    /// EntitySelector.CAN_BE_COLLIDED_WITH, and the border not at all.
    empty: bool = false,
    /// The entity's slot, which it does not collide with, nor with what rides with it.
    slot: u32 = no_slot,
    /// AbstractBoat.canCollideWith, canVehicleCollide: it collides with pushable entities too.
    vehicle: bool = false,
};

pub const no_slot = std.math.maxInt(u32);

/// Level.getEntityCollisions, answered by whoever keeps the entities: the boxes of those the mover
/// collides with that meet `query`, in the level's order, into `output`.
pub const EntitySource = struct {
    context: *anyopaque,
    gather: *const fn (context: *anyopaque, world: u32, query: Box, mover: Context, output: []Box) anyerror![]Box,
};

/// AABB.getSize: the mean of its sides.
pub fn sizeOf(value: Box) f64 {
    return (value.max[0] - value.min[0] + (value.max[1] - value.min[1]) + (value.max[2] - value.min[2])) / 3.0;
}

/// Level.getEntityCollisions: none for a box of no size, else the source's, a little wider.
pub fn entityCollisions(level: *const Level, query: Box, context: Context, output: []Box) ![]Box {
    const source = level.entities orelse return output[0..0];
    if (sizeOf(query) < 1.0e-7) return output[0..0];
    return source.gather(source.context, level.world, query.inflate(1.0e-7, 1.0e-7, 1.0e-7), context, output);
}

/// The collision boxes of a block state at a position, for an entity.
pub fn collisionBoxes(level: *const Level, state: u16, x: i32, y: i32, z: i32, context: Context) game_data.physics.Boxes {
    if (context.empty) return contextFreeBoxes(state, x, z);
    const kind = level.blocks.get(state).kind;
    const at_y: f64 = @floatFromInt(y);
    const epsilon: f64 = @as(f32, 1.0e-5);
    switch (kind) {
        // ScaffoldingBlock.getCollisionShape. The snapshot holds the stable shape for a block
        // below the entity and the unstable bottom (or none) for a block at its feet.
        .scaffolding => {
            if (context.bottom > at_y + 1.0 - epsilon) return game_data.physics.spawnCollision(state, x, -1, z);
            if (context.bottom > at_y - epsilon) return game_data.physics.spawnCollision(state, x, 0, z);
            return .{ .offset = 0, .count = 0, .translation = @splat(0) };
        },
        // PowderSnowBlock.getCollisionShape. Mobs that cannot walk on powder snow sink in
        // unless they fall into it from high enough.
        .powder_snow => return if (context.fall_distance > 2.5) powder_snow_falling else .{ .offset = 0, .count = 0, .translation = @splat(0) },
        else => return game_data.physics.spawnCollision(state, x, 0, z),
    }
}

// PowderSnowBlock.FALLING_COLLISION_SHAPE, a box 0.9 high, is no shape the snapshot names, so
// the caller treats this marker specially.
const powder_snow_falling: game_data.physics.Boxes = .{ .offset = std.math.maxInt(u32), .count = 1, .translation = @splat(0) };
// A whole block, marked as powder snow's shape is, for states whose shape is the whole block.
const full_cube: game_data.physics.Boxes = .{ .offset = std.math.maxInt(u32) - 1, .count = 1, .translation = @splat(0) };

fn box(boxes: game_data.physics.Boxes, index: usize, x: i32, y: i32, z: i32) Box {
    const origin: [3]f64 = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
    if (boxes.offset == std.math.maxInt(u32)) {
        return .{ .min = origin, .max = .{ origin[0] + 1, origin[1] + @as(f64, @as(f32, 0.9)), origin[2] + 1 } };
    }
    if (boxes.offset == full_cube.offset) return .{ .min = origin, .max = .{ origin[0] + 1, origin[1] + 1, origin[2] + 1 } };
    const value = boxes.get(index);
    return .{ .min = .{ origin[0] + value[0], origin[1] + value[1], origin[2] + value[2] }, .max = .{ origin[0] + value[3], origin[1] + value[4], origin[2] + value[5] } };
}

/// A block shape BlockCollisions yields: all its boxes, at the block's position.
pub const Shape = struct {
    boxes: game_data.physics.Boxes,
    x: i32,
    y: i32,
    z: i32,

    pub fn get(self: Shape, index: usize) Box {
        return box(self.boxes, index, self.x, self.y, self.z);
    }
};

/// BlockCollisions: the shapes of blocks a query box touches, plus blocks one layer out whose
/// shapes reach in. A shape is yielded when one of its boxes overlaps the query.
pub const Shapes = struct {
    level: *const Level,
    query: Box,
    context: Context,
    first: [3]i32,
    last: [3]i32,
    at: [3]i32,
    /// The window holding every cell scanned, read directly.
    inside: ?*const Window = null,
    /// No shape around reaches past its block, so only the cells inside the outer layer matter.
    inner: bool = false,
    /// Whether its cells may hold scaffolding or powder snow, by their sections' marks, whose shapes
    /// depend on the entity's bottom and fall: then what it yields holds only for its context.
    contextual: bool = true,

    pub fn init(level: *const Level, query: Box, context: Context) !Shapes {
        const first: [3]i32 = .{ mth.floor(query.min[0] - 1.0e-7) - 1, mth.floor(query.min[1] - 1.0e-7) - 1, mth.floor(query.min[2] - 1.0e-7) - 1 };
        const last: [3]i32 = .{ mth.floor(query.max[0] + 1.0e-7) + 1, mth.floor(query.max[1] + 1.0e-7) + 1, mth.floor(query.max[2] + 1.0e-7) + 1 };
        var shapes: Shapes = .{ .level = level, .query = query, .context = context, .first = first, .last = last, .at = first };
        if (level.window) |window| if (level.overlay == null and window.covers(level.world, first, last)) {
            shapes.inside = window;
        };
        // What its cells may hold, by their sections' marks, and anything under an overlay.
        const marks: u8 = if (level.overlay != null) 0xff else try level.marked(first, last);
        shapes.contextual = marks & mob_blocks.mark_contextual != 0;
        // SteelMC's trick: cells on the outer layer yield only shapes that reach in, and none do.
        if (marks & mob_blocks.mark_large == 0) {
            shapes.inner = true;
            shapes.first = .{ first[0] + 1, first[1] + 1, first[2] + 1 };
            shapes.last = .{ last[0] - 1, last[1] - 1, last[2] - 1 };
            shapes.at = shapes.first;
        }
        return shapes;
    }

    pub fn next(self: *Shapes) !?Shape {
        if (self.inside) |window| return self.nextInside(window);
        while (self.at[1] <= self.last[1]) {
            const x = self.at[0];
            const y = self.at[1];
            const z = self.at[2];
            self.step();
            const edges = self.edgesOf(x, y, z) orelse continue;
            // Air, the most common cell, has no shape, and neither has a state whose shape is empty
            // for any entity, which all but scaffolding and powder snow show with no entity.
            const state = try self.level.state(x, y, z);
            if (state == self.level.air) continue;
            const entry = self.level.blocks.get(state);
            if (entry.collision == shape_classes.empty and entry.kind != .scaffolding and entry.kind != .powder_snow) continue;
            if (edges == 1 and !entry.flags.large_shape) continue;
            if (edges == 2 and entry.kind != .moving_piston) continue;
            // A full block, as most floors are, needs no decoding.
            const boxes = if (entry.collision == self.level.blocks.full_cube) full_cube else collisionBoxes(self.level, state, x, y, z, self.context);
            if (boxes.count == 0) continue;
            const shape: Shape = .{ .boxes = boxes, .x = x, .y = y, .z = z };
            for (0..boxes.count) |index| {
                if (shape.get(index).intersects(self.query)) return shape;
            }
        }
        return null;
    }

    /// `next` within a window, which knows the cells that may have a shape: the rest, air
    /// mostly, are passed by a row at a time.
    fn nextInside(self: *Shapes, window: *const Window) ?Shape {
        while (self.at[1] <= self.last[1]) {
            const bits = window.shapedIn(self.at[0], self.last[0], self.at[1], self.at[2]);
            if (bits == 0) {
                self.nextRow();
                continue;
            }
            const x = self.at[0] + @ctz(bits);
            const y = self.at[1];
            const z = self.at[2];
            self.at[0] = x;
            self.step();
            const edges = self.edgesOf(x, y, z) orelse continue;
            if (self.shapeAt(window.cell(x, y, z), edges, x, y, z)) |shape| return shape;
        }
        return null;
    }

    /// Past the cell `at` is on, in Cursor3D's order: x, then z, then y.
    inline fn step(self: *Shapes) void {
        self.at[0] += 1;
        if (self.at[0] > self.last[0]) self.nextRow();
    }

    inline fn nextRow(self: *Shapes) void {
        self.at[0] = self.first[0];
        self.at[2] += 1;
        if (self.at[2] > self.last[2]) {
            self.at[2] = self.first[2];
            self.at[1] += 1;
        }
    }

    /// Cursor3D's type: how many coordinates of a cell lie on the outer layer, null for a corner,
    /// which no shape reaches in from.
    inline fn edgesOf(self: *const Shapes, x: i32, y: i32, z: i32) ?u2 {
        if (self.inner) return 0;
        var edges: u2 = 0;
        if (x == self.first[0] or x == self.last[0]) edges += 1;
        if (y == self.first[1] or y == self.last[1]) edges += 1;
        if (z == self.first[2] or z == self.last[2]) edges += 1;
        return if (edges == 3) null else edges;
    }

    /// The shape of a cell's state, when one of its boxes meets the query and its cell is not on
    /// an outer layer it cannot reach in from.
    inline fn shapeAt(self: *Shapes, state: u16, edges: u2, x: i32, y: i32, z: i32) ?Shape {
        const entry = self.level.blocks.get(state);
        // What MobBlocks.mayCollide says, which a window's bits already did for its cells.
        if (entry.collision == shape_classes.empty and entry.kind != .scaffolding and entry.kind != .powder_snow) return null;
        if (edges == 1 and !entry.flags.large_shape) return null;
        if (edges == 2 and entry.kind != .moving_piston) return null;
        // A full block, as most floors are, needs no decoding.
        const boxes = if (entry.collision == self.level.blocks.full_cube) full_cube else collisionBoxes(self.level, state, x, y, z, self.context);
        if (boxes.count == 0) return null;
        const shape: Shape = .{ .boxes = boxes, .x = x, .y = y, .z = z };
        for (0..boxes.count) |index| {
            if (shape.get(index).intersects(self.query)) return shape;
        }
        return null;
    }
};

/// Shapes.collide along one axis, against every shape the query yields, the border's first.
fn collideAxis(level: *const Level, query: Box, context: Context, others: []const Box, border: ?[4]Box, moving: Box, axis: usize, distance: f64) !f64 {
    var result = distance;
    for (others) |other| {
        if (@abs(result) < 1.0e-7) return 0;
        result = collideBox(other, moving, axis, result);
    }
    if (border) |outside| {
        if (@abs(result) < 1.0e-7) return 0;
        for (outside) |side| result = collideBox(side, moving, axis, result);
    }
    var shapes: Shapes = try .init(level, query, context);
    while (try shapes.next()) |shape| {
        if (@abs(result) < 1.0e-7) return 0;
        for (0..shape.boxes.count) |index| result = collideBox(shape.get(index), moving, axis, result);
    }
    return result;
}

/// VoxelShape.collideX for one box: how far the moving box goes along the axis before the
/// obstacle stops it, within vanilla's 1e-7 tolerance.
fn collideBox(obstacle: Box, moving: Box, axis: usize, distance: f64) f64 {
    const a = (axis + 1) % 3;
    const b = (axis + 2) % 3;
    if (obstacle.max[a] <= moving.min[a] + 1.0e-7 or obstacle.min[a] >= moving.max[a] - 1.0e-7) return distance;
    if (obstacle.max[b] <= moving.min[b] + 1.0e-7 or obstacle.min[b] >= moving.max[b] - 1.0e-7) return distance;
    if (distance > 0 and obstacle.min[axis] > moving.max[axis] - 1.0e-7) {
        const gap = obstacle.min[axis] - moving.max[axis];
        if (gap >= -1.0e-7) return @min(distance, gap);
    } else if (distance < 0 and obstacle.max[axis] < moving.min[axis] + 1.0e-7) {
        const gap = obstacle.max[axis] - moving.min[axis];
        if (gap <= 1.0e-7) return @max(distance, gap);
    }
    return distance;
}

fn anyShape(level: *const Level, query: Box, context: Context) !bool {
    var shapes: Shapes = try .init(level, query, context);
    return try shapes.next() != null;
}

/// The shapes BlockCollisions yields for a query, gathered once as Entity.collectColliders does,
/// so every axis and every step height after reads them from here and not the world.
pub const Colliders = struct {
    boxes: [box_capacity]Box = undefined,
    /// The entities' boxes one move collides with, found once for all its tries.
    entity_boxes: [entity_capacity]Box = undefined,
    /// Where each shape's boxes end, as Shapes.collide checks its tolerance between shapes.
    ends: [box_capacity]u16 = undefined,
    box_count: usize = 0,
    shape_count: usize = 0,
    /// False when a long move met more boxes than fit, and callers walk the world instead.
    complete: bool = true,
    /// What the last gather asked, for a question after the move it gathered for: its query and
    /// world, where its block shapes begin, the cell of each, and whether its scan was of inner
    /// cells only and met no state whose shape depends on the entity.
    query: Box = undefined,
    world: u32 = 0,
    blocks_from: usize = 0,
    cells: [box_capacity][3]i32 = undefined,
    inner: bool = false,
    contextual: bool = true,
    /// Whether the last gather finished, its shapes all kept: until the next move's starts.
    fresh: bool = false,

    const box_capacity = 256;
    pub const entity_capacity = 1024;

    /// Fills in place, as the boxes are too many to copy around. The other entities' boxes come
    /// first, a shape each, as Entity.collectColliders puts them.
    pub fn gather(self: *Colliders, level: *const Level, query: Box, context: Context, others: []const Box, border: ?[4]Box) !void {
        self.box_count = 0;
        self.shape_count = 0;
        self.complete = true;
        self.fresh = false;
        self.query = query;
        self.world = level.world;
        if (others.len > box_capacity) {
            self.complete = false;
            return;
        }
        for (others) |other| {
            self.boxes[self.box_count] = other;
            self.box_count += 1;
            self.ends[self.shape_count] = @intCast(self.box_count);
            self.shape_count += 1;
        }
        // Entity.findCollisionsForMovement: the border's shape before the blocks'.
        if (border) |outside| {
            for (outside) |side| {
                self.boxes[self.box_count] = side;
                self.box_count += 1;
            }
            self.ends[self.shape_count] = @intCast(self.box_count);
            self.shape_count += 1;
        }
        self.blocks_from = self.shape_count;
        var shapes: Shapes = try .init(level, query, context);
        while (try shapes.next()) |shape| {
            if (self.box_count + shape.boxes.count > box_capacity) {
                self.complete = false;
                return;
            }
            for (0..shape.boxes.count) |index| {
                self.boxes[self.box_count] = shape.get(index);
                self.box_count += 1;
            }
            self.cells[self.shape_count] = .{ shape.x, shape.y, shape.z };
            self.ends[self.shape_count] = @intCast(self.box_count);
            self.shape_count += 1;
        }
        self.inner = shapes.inner;
        self.contextual = shapes.contextual;
        self.fresh = true;
    }

    /// Level.findSupportingBlock for a query within the last gather's, from the block shapes it
    /// kept: those its scan of inner cells met are every shape the query's would meet, none
    /// reaching past its block, and none depending on the entity, which may have moved since.
    /// Null when they may not be, and the world must be asked.
    pub fn supportingWithin(self: *const Colliders, level: *const Level, query: Box, position: [3]f64) ?(?[3]i32) {
        if (!self.fresh or !self.inner or self.contextual or self.world != level.world or level.overlay != null) return null;
        for (0..3) |axis| if (query.min[axis] < self.query.min[axis] or query.max[axis] > self.query.max[axis]) return null;
        var best: ?[3]i32 = null;
        var best_distance = std.math.floatMax(f64);
        var begin: usize = if (self.blocks_from == 0) 0 else self.ends[self.blocks_from - 1];
        for (self.blocks_from..self.shape_count) |shape| {
            const end = self.ends[shape];
            defer begin = end;
            const meets = for (self.boxes[begin..end]) |value| {
                if (value.intersects(query)) break true;
            } else false;
            if (!meets) continue;
            const candidate = self.cells[shape];
            const distance = centerDistance(candidate, position);
            if (distance < best_distance or (distance == best_distance and (best == null or lessBlock(best.?, candidate)))) {
                best = candidate;
                best_distance = distance;
            }
        }
        return best;
    }

    /// Shapes.collide along one axis.
    fn collideAxis(self: *const Colliders, moving: Box, axis: usize, distance: f64) f64 {
        var result = distance;
        var begin: usize = 0;
        for (self.ends[0..self.shape_count]) |end| {
            if (@abs(result) < 1.0e-7) return 0;
            for (self.boxes[begin..end]) |obstacle| result = collideBox(obstacle, moving, axis, result);
            begin = end;
        }
        return result;
    }

    /// Entity.collideWithShapes: Y first, then the larger of X and Z last.
    fn collideWith(self: *const Colliders, movement: [3]f64, start: Box) [3]f64 {
        if (self.shape_count == 0) return movement;
        var result: [3]f64 = .{ 0, 0, 0 };
        const order: [3]usize = if (@abs(movement[0]) < @abs(movement[2])) .{ 1, 2, 0 } else .{ 1, 0, 2 };
        for (order) |axis| {
            if (movement[axis] == 0) continue;
            result[axis] = self.collideAxis(start.move(result), axis, movement[axis]);
        }
        return result;
    }

    /// Entity.collectCandidateStepUpHeights: the heights above the box's bottom of shape edges
    /// no higher than the step, sorted. Shape edges are box bottoms and tops here.
    fn stepHeights(self: *const Colliders, base: Box, max_up_step: f32, skip: f32, output: *[64]f32) usize {
        var count: usize = 0;
        for (self.boxes[0..self.box_count]) |value| count = stepEdges(value, base, max_up_step, skip, output, count);
        std.sort.insertion(f32, output[0..count], {}, std.sort.asc(f32));
        return count;
    }
};

/// Entity.collideWithShapes against what a query gathers, or the world itself past what fits.
fn collideWithShapes(level: *const Level, query: Box, context: Context, others: []const Box, movement: [3]f64, start: Box) ![3]f64 {
    const colliders = level.colliders.?;
    const border = borderFor(level, start, query);
    try colliders.gather(level, query, context, others, border);
    if (colliders.complete) return colliders.collideWith(movement, start);
    var result: [3]f64 = .{ 0, 0, 0 };
    const order: [3]usize = if (@abs(movement[0]) < @abs(movement[2])) .{ 1, 2, 0 } else .{ 1, 0, 2 };
    for (order) |axis| {
        if (movement[axis] == 0) continue;
        result[axis] = try collideAxis(level, query, context, others, border, start.move(result), axis, movement[axis]);
    }
    return result;
}

/// WorldBorder.canCollide for a body whose box is `start`, moving through `query`: near the border
/// and inside it, by the query's longer side, the border's outside as four boxes.
pub fn borderFor(level: *const Level, start: Box, query: Box) ?[4]Box {
    const bounds = level.border orelse return null;
    const x = (start.min[0] + start.max[0]) / 2;
    const z = (start.min[2] + start.max[2]) / 2;
    if (!bounds.canCollide(x, z, query.max[0] - query.min[0], query.max[2] - query.min[2])) return null;
    var boxes: [4]Box = undefined;
    for (&boxes, bounds.outside()) |*side, corners| side.* = .{ .min = corners[0], .max = corners[1] };
    return boxes;
}

/// Entity.collide, with stepping up onto blocks no higher than max_up_step: against the entities
/// Level.getEntityCollisions finds around the box expanded by the movement, every step tried
/// against the same, and the blocks and border each try finds.
pub fn collide(level: *const Level, start: Box, movement: [3]f64, context: Context, on_ground: bool, max_up_step: f32) ![3]f64 {
    // What an earlier move gathered answers nothing about this one.
    level.colliders.?.fresh = false;
    const others: []const Box = try entityCollisions(level, start.expandTowards(movement), context, &level.colliders.?.entity_boxes);
    if (others.len == Colliders.entity_capacity) return error.TooManyEntityColliders;
    const length_squared = movement[0] * movement[0] + movement[1] * movement[1] + movement[2] * movement[2];
    const collided = if (length_squared == 0) movement else try collideWithShapes(level, start.expandTowards(movement), context, others, movement, start);
    const blocked_x = movement[0] != collided[0];
    const blocked_y = movement[1] != collided[1];
    const blocked_z = movement[2] != collided[2];
    const landed = blocked_y and movement[1] < 0;
    if (max_up_step > 0 and (landed or on_ground) and (blocked_x or blocked_z)) {
        const base = if (landed) start.move(.{ 0, collided[1], 0 }) else start;
        var query = base.expandTowards(.{ movement[0], max_up_step, movement[2] });
        if (!landed) query = query.expandTowards(.{ 0, -@as(f64, @as(f32, 1.0e-5)), 0 });
        const colliders = level.colliders.?;
        try colliders.gather(level, query, context, others, borderFor(level, start, query));
        var heights: [64]f32 = undefined;
        const count = if (colliders.complete) colliders.stepHeights(base, max_up_step, @floatCast(collided[1]), &heights) else try stepHeights(level, query, context, others, base, max_up_step, @floatCast(collided[1]), &heights);
        for (heights[0..count]) |height| {
            const stepped = if (colliders.complete) colliders.collideWith(.{ movement[0], height, movement[2] }, base) else try collideWithShapes(level, query, context, others, .{ movement[0], height, movement[2] }, base);
            if (stepped[0] * stepped[0] + stepped[2] * stepped[2] > collided[0] * collided[0] + collided[2] * collided[2]) {
                const lowered = start.min[1] - base.min[1];
                return .{ stepped[0], stepped[1] - lowered, stepped[2] };
            }
        }
    }
    return collided;
}

/// Entity.collectCandidateStepUpHeights: the heights above the box's bottom of shape edges no
/// higher than the step, sorted. Shape edges are box bottoms and tops here.
fn stepHeights(level: *const Level, query: Box, context: Context, others: []const Box, base: Box, max_up_step: f32, skip: f32, output: *[64]f32) !usize {
    var count: usize = 0;
    for (others) |value| count = stepEdges(value, base, max_up_step, skip, output, count);
    var shapes: Shapes = try .init(level, query, context);
    while (try shapes.next()) |shape| {
        for (0..shape.boxes.count) |index| count = stepEdges(shape.get(index), base, max_up_step, skip, output, count);
    }
    std.sort.insertion(f32, output[0..count], {}, std.sort.asc(f32));
    return count;
}

/// The bottom and top of a box as heights above the base, those no higher than the step and new
/// added after the `count` already held: how many are held then.
fn stepEdges(value: Box, base: Box, max_up_step: f32, skip: f32, output: *[64]f32, held: usize) usize {
    var count = held;
    for ([2]f64{ value.min[1], value.max[1] }) |coordinate| {
        const height: f32 = @floatCast(coordinate - base.min[1]);
        if (height < 0 or height == skip or height > max_up_step) continue;
        if (std.mem.indexOfScalar(f32, output[0..count], height) != null) continue;
        // Distinct edges below one step cannot run out in any block vanilla has.
        assert(count < output.len);
        output[count] = height;
        count += 1;
    }
    return count;
}

/// Entity.push(Entity)'s step apart: how far the entity at `there` moves from the one at `here`,
/// x and z, the one at `here` the opposite, or none when they stand too close to tell a way.
pub fn pushApart(here: [3]f64, there: [3]f64) ?[2]f64 {
    var dx = there[0] - here[0];
    var dz = there[2] - here[2];
    var farthest = @max(@abs(dx), @abs(dz));
    if (farthest < @as(f64, @as(f32, 0.01))) return null;
    farthest = @sqrt(farthest);
    dx /= farthest;
    dz /= farthest;
    const scale = @min(1.0, 1.0 / farthest);
    dx *= scale * @as(f64, @as(f32, 0.05));
    dz *= scale * @as(f64, @as(f32, 0.05));
    return .{ dx, dz };
}

/// LivingEntity.onClimbable's blocks: a climbable block at the body's block, or an open trapdoor
/// over a ladder facing its way.
pub fn climbableAt(level: *const Level, at: [3]i32) !bool {
    const entry = level.blocks.get(try level.state(at[0], at[1], at[2]));
    if (entry.flags.climbable) return true;
    if (!entry.flags.trapdoor or !entry.flags.open) return false;
    const below = level.blocks.get(try level.state(at[0], at[1] - 1, at[2]));
    return below.kind == .ladder and below.facing == entry.facing;
}

/// Level.findSupportingBlock: of the blocks under the box, the one whose center is nearest the
/// position, ties broken toward the larger position in vanilla's order (y, then z, then x).
pub fn findSupportingBlock(level: *const Level, query: Box, context: Context, position: [3]f64) !?[3]i32 {
    var best: ?[3]i32 = null;
    var best_distance = std.math.floatMax(f64);
    var shapes: Shapes = try .init(level, query, context);
    while (try shapes.next()) |shape| {
        const candidate: [3]i32 = .{ shape.x, shape.y, shape.z };
        const distance = centerDistance(candidate, position);
        if (distance < best_distance or (distance == best_distance and (best == null or lessBlock(best.?, candidate)))) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

/// Entity.checkSupportingBlock's search for a body on the ground: of the blocks under a sliver
/// below its box, findSupportingBlock's nearest; none there, and none found the tick before either,
/// the same back along the move it just made.
pub fn supportingBlock(level: *const Level, current: Box, context: Context, position: [3]f64, moved: ?[3]f64, none_before: bool) !?[3]i32 {
    const below: Box = .{ .min = .{ current.min[0], current.min[1] - 1.0e-6, current.min[2] }, .max = .{ current.max[0], current.min[1], current.max[2] } };
    if (try findSupportingBlock(level, below, context, position)) |found| return found;
    if (none_before) return null;
    const back = moved orelse return null;
    return findSupportingBlock(level, below.move(.{ -back[0], 0, -back[2] }), context, position);
}

/// supportingBlock for a body whose move just gathered its colliders, which answer it when they
/// hold every shape its searches would meet.
pub fn supportingAfterMove(level: *const Level, current: Box, context: Context, position: [3]f64, moved: ?[3]f64, none_before: bool) !?[3]i32 {
    const below: Box = .{ .min = .{ current.min[0], current.min[1] - 1.0e-6, current.min[2] }, .max = .{ current.max[0], current.min[1], current.max[2] } };
    if (try nearestGathered(level, below, context, position)) |found| return found;
    if (none_before) return null;
    const back = moved orelse return null;
    return nearestGathered(level, below.move(.{ -back[0], 0, -back[2] }), context, position);
}

/// findSupportingBlock from the colliders the move gathered, or the world past what they hold.
fn nearestGathered(level: *const Level, query: Box, context: Context, position: [3]f64) !?[3]i32 {
    const colliders = level.colliders orelse return findSupportingBlock(level, query, context, position);
    const kept = colliders.supportingWithin(level, query, position) orelse return findSupportingBlock(level, query, context, position);
    if (verify_skips) assert(std.meta.eql(kept, try findSupportingBlock(level, query, context, position)));
    return kept;
}

/// How far a block's center is from a position, squared, as Level.findSupportingBlock measures.
fn centerDistance(cell: [3]i32, position: [3]f64) f64 {
    const dx = @as(f64, @floatFromInt(cell[0])) + 0.5 - position[0];
    const dy = @as(f64, @floatFromInt(cell[1])) + 0.5 - position[1];
    const dz = @as(f64, @floatFromInt(cell[2])) + 0.5 - position[2];
    return dx * dx + dy * dy + dz * dz;
}

/// Entity.getOnPos: the block a body stands on, looked for `depth` below its feet. The block it
/// rests on, but at that depth, unless a fence there, at half a block or less, or a wall or fence
/// gate keeps the body on its own block.
pub fn onPos(level: *const Level, supporting: ?[3]i32, position: [3]f64, depth: f32) ![3]i32 {
    if (supporting) |at| {
        if (!(depth > 1.0e-5)) return at;
        const entry = level.blocks.get(try level.state(at[0], at[1], at[2]));
        if ((depth <= 0.5 and entry.flags.fence) or entry.flags.wall or entry.flags.fence_gate) return at;
        return .{ at[0], mth.floor(position[1] - depth), at[2] };
    }
    return .{ mth.floor(position[0]), mth.floor(position[1] - depth), mth.floor(position[2]) };
}

/// Vec3i.compareTo(a, b) < 0.
fn lessBlock(a: [3]i32, b: [3]i32) bool {
    if (a[1] != b[1]) return a[1] < b[1];
    if (a[2] != b[2]) return a[2] < b[2];
    return a[0] < b[0];
}

/// DismountHelper.canDismountTo: no block shape within the box, as CollisionGetter.getBlockCollisions
/// finds none, and the box within the world border.
pub fn canDismountTo(level: *const Level, query: Box, context: Context) !bool {
    if (try anyShape(level, query, context)) return false;
    const bounds = level.border orelse return true;
    return bounds.containsBox(query.min[0], query.min[2], query.max[0], query.max[2]);
}

/// CollisionGetter.noCollision: no block shape, entity the body collides with, or, for a body, the
/// world border's outside within the box.
pub fn noCollision(level: *const Level, query: Box, context: Context) !bool {
    if (try anyShape(level, query, context)) return false;
    var found: [1]Box = undefined;
    if ((try entityCollisions(level, query, context, &found)).len > 0) return false;
    if (context.empty) return true;
    const border = borderFor(level, query, query) orelse return true;
    for (border) |side| if (side.intersects(query)) return false;
    return true;
}

test "a box stops at a block and steps up a slab" {
    // Pure arithmetic of one obstacle, which the world tests cover end to end.
    const obstacle: Box = .{ .min = .{ 1, 0, 0 }, .max = .{ 2, 0.5, 1 } };
    const moving: Box = .{ .min = .{ 0.1, 0, 0.1 }, .max = .{ 0.9, 1.4, 0.9 } };
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), collideBox(obstacle, moving, 0, 0.3), 1e-12);
    try std.testing.expectEqual(@as(f64, -0.3), collideBox(obstacle, moving, 0, -0.3));
    try std.testing.expectEqual(@as(f64, 0.3), collideBox(obstacle, moving.move(.{ 0, 0.5, 0 }), 0, 0.3));
}

/// BlockState.getCollisionShape with no entity (CollisionContext.empty): scaffolding is stable,
/// since the empty context counts as above every block, and powder snow has no shape.
pub fn contextFreeBoxes(state: u16, x: i32, z: i32) game_data.physics.Boxes {
    const registry = game_data.registry;
    const scaffolding = registry.block_state_to_block[registry.block_scaffolding_default_state];
    if (registry.block_state_to_block[state] == scaffolding) return game_data.physics.spawnCollision(state, x, -1, z);
    return game_data.physics.spawnCollision(state, x, 0, z);
}

/// Shapes.collide along Y against the shapes a query yields, as EntityType.getYOffset asks.
pub fn collideVertical(level: *const Level, query: Box, context: Context, moving: Box, distance: f64) !f64 {
    return collideAxis(level, query, context, &.{}, null, moving, 1, distance);
}

test "the world border stops a body near it and leaves the far ones alone" {
    var level: Level = undefined;
    level.border = .around(0, 0, 16);
    const moving: Box = .{ .min = .{ 7.2, 64, 0.2 }, .max = .{ 7.8, 65.4, 0.8 } };
    const query = moving.expandTowards(.{ 1, 0, 0 });
    const outside = borderFor(&level, moving, query).?;
    var distance: f64 = 1;
    for (outside) |side| distance = collideBox(side, moving, 0, distance);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), distance, 1e-12);
    // Far inside, it is not in the way at all; with none, never.
    const far: Box = .{ .min = .{ 0.2, 64, 0.2 }, .max = .{ 0.8, 65.4, 0.8 } };
    try std.testing.expectEqual(@as(?[4]Box, null), borderFor(&level, far, far.expandTowards(.{ 1, 0, 0 })));
    level.border = null;
    try std.testing.expectEqual(@as(?[4]Box, null), borderFor(&level, moving, query));
}
