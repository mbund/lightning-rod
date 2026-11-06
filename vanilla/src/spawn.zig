const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const records = @import("records");
const storage = @import("storage");
const Worlds = @import("worlds").Worlds;
const Blocks = @import("blocks.zig").Blocks;
const Dimensions = @import("dimensions.zig").Dimensions;

pub const Spawn = struct {
    pub const id = "minecraft:spawn";
    pub const Configuration = struct {
        seed: u64 = 0,
        /// Generator climate-search origin and spawn height. Imports retain their saved anchor.
        origin: chunks.Position = .{ .x = 0, .y = 65, .z = 0 },
        radius: i32 = 10,
        debug_world: bool = false,
    };
    pub const Dependencies = struct {
        chunks: *chunks.Chunks,
        blocks: *Blocks,
        worlds: *Worlds,
        dimensions: *Dimensions,
        record_workspaces: *records.Workspaces,
        storage: storage.Space,
    };
    pub const Definition = struct {
        position: chunks.Position,
        angle: f32 = 0,
        radius: i32 = 10,
    };
    pub const Result = struct { position: minecraft.Position, rotation: minecraft.Rotation };
    const encoded_size = 29;
    const Entry = struct {
        loaded: bool = false,
        initialized: bool = false,
        definition: Definition = .{ .position = .{ .x = 0, .y = 64, .z = 0 } },
        random: Random = .init(0),
        saved: [encoded_size]u8 = @splat(0),

        fn encode(self: *const Entry) [encoded_size]u8 {
            var bytes: [encoded_size]u8 = undefined;
            bytes[0] = 1;
            std.mem.writeInt(i32, bytes[1..5], self.definition.position.x, .little);
            std.mem.writeInt(i32, bytes[5..9], self.definition.position.y, .little);
            std.mem.writeInt(i32, bytes[9..13], self.definition.position.z, .little);
            std.mem.writeInt(u32, bytes[13..17], @bitCast(self.definition.angle), .little);
            std.mem.writeInt(i32, bytes[17..21], self.definition.radius, .little);
            std.mem.writeInt(u64, bytes[21..29], self.random.state, .little);
            return bytes;
        }
    };
    deps: Dependencies,
    config: Configuration,
    entries: []Entry,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Spawn {
        try validate(.{ .position = configuration.origin, .radius = configuration.radius });
        const self = try allocator.create(Spawn);
        self.* = .{ .deps = deps, .config = configuration, .entries = try allocator.alloc(Entry, deps.worlds.entries.len) };
        @memset(self.entries, .{});
        return self;
    }

    fn entry(self: *Spawn, world: u32) !*Entry {
        const index = for (self.deps.worlds.all(), 0..) |value, index| {
            if (value.id == world) break index;
        } else return error.UnknownWorld;
        const value = &self.entries[index];
        if (value.loaded) return value;
        value.random = .init(self.config.seed ^ world);
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, world, .little);
        const table = records.Table.init(self.deps.storage, self.deps.record_workspaces.resources);
        if (try table.get(&key, &value.saved)) |length| {
            if (length != encoded_size or value.saved[0] != 1) return error.CorruptSpawn;
            value.definition = .{
                .position = .{ .x = std.mem.readInt(i32, value.saved[1..5], .little), .y = std.mem.readInt(i32, value.saved[5..9], .little), .z = std.mem.readInt(i32, value.saved[9..13], .little) },
                .angle = @bitCast(std.mem.readInt(u32, value.saved[13..17], .little)),
                .radius = std.mem.readInt(i32, value.saved[17..21], .little),
            };
            try validate(value.definition);
            value.random.state = std.mem.readInt(u64, value.saved[21..29], .little);
            if (value.random.state >> 48 != 0) return error.CorruptSpawn;
            value.initialized = true;
        }
        value.loaded = true;
        return value;
    }

    pub fn set(self: *Spawn, world: u32, definition: Definition) !void {
        try validate(definition);
        const value = try self.entry(world);
        value.definition = definition;
        value.initialized = true;
    }

    pub fn get(self: *Spawn, world: u32) !Definition {
        const value = try self.entry(world);
        if (!value.initialized) {
            value.definition = try self.initial(world);
            value.initialized = true;
        }
        return value.definition;
    }

    pub fn checkpoint(self: *Spawn, space: storage.Space) !void {
        var begin: usize = 0;
        const worlds = self.deps.worlds.all();
        while (begin < worlds.len) {
            const count = @min(192, worlds.len - begin);
            var keys: [192][4]u8 = undefined;
            var bytes: [192][encoded_size]u8 = undefined;
            var writes: [192]records.Write = undefined;
            var dirty: usize = 0;
            for (self.entries[begin..][0..count], worlds[begin..][0..count]) |*value, world| {
                if (!value.initialized) continue;
                const encoded = value.encode();
                if (std.mem.eql(u8, &encoded, &value.saved)) continue;
                bytes[dirty] = encoded;
                std.mem.writeInt(u32, &keys[dirty], world.id, .little);
                writes[dirty] = .{ .key = &keys[dirty], .value = &bytes[dirty] };
                dirty += 1;
            }
            try records.Table.init(space, self.deps.record_workspaces.resources).putBatch(writes[0..dirty]);
            for (self.entries[begin..][0..count]) |*value| if (value.initialized) {
                value.saved = value.encode();
            };
            begin += count;
        }
    }

    fn initial(self: *Spawn, world: u32) !Definition {
        if (self.config.debug_world) return .{ .position = .{ .x = 0, .y = 80, .z = 0 }, .radius = self.config.radius };
        const cx = @divFloor(self.config.origin.x, 16);
        const cz = @divFloor(self.config.origin.z, 16);
        var fallback = self.config.origin;
        fallback.x = cx * 16 + 8;
        fallback.z = cz * 16 + 8;
        const minimum = self.deps.worlds.get(world).?.dimension.minimum_section * 16;
        if (fallback.y < minimum) fallback.y = (try self.scanColumn(world, fallback.x, fallback.z)).surface + 1;
        var spiral: Spiral = .{};
        for (0..121) |_| {
            const offset = spiral.next();
            for (0..16) |x| for (0..16) |z| {
                if (try self.column(world, (cx + offset[0]) * 16 + @as(i32, @intCast(x)), (cz + offset[1]) * 16 + @as(i32, @intCast(z)))) |position|
                    return .{ .position = position, .radius = self.config.radius };
            };
        }
        return .{ .position = fallback, .radius = self.config.radius };
    }

    pub fn select(self: *Spawn, world: u32, mode: minecraft.GameMode, border: ?f64) !Result {
        if (border) |diameter| if (!std.math.isFinite(diameter) or diameter < 1 or diameter > 60_000_000) return error.InvalidSpawn;
        var anchor = try self.get(world);
        if (border) |diameter| {
            const half = diameter / 2;
            if (@as(f64, @floatFromInt(anchor.position.x)) + 1 <= -half or @as(f64, @floatFromInt(anchor.position.x)) >= half or @as(f64, @floatFromInt(anchor.position.z)) + 1 <= -half or @as(f64, @floatFromInt(anchor.position.z)) >= half) {
                const sample = try self.scanColumn(world, 0, 0);
                anchor.position = .{ .x = 0, .y = sample.motion + 1, .z = 0 };
            }
        }
        const value = try self.entry(world);
        const dimension = (self.deps.worlds.get(world) orelse return error.UnknownWorld).dimension;
        var position = anchor.position;
        if (dimension.skylight and mode != .adventure) {
            var radius: i32 = @max(0, anchor.radius);
            const half = (border orelse 59_999_968) / 2;
            const distance: i32 = @intFromFloat(@floor(@min(half - @abs(@as(f64, @floatFromInt(position.x))), half - @abs(@as(f64, @floatFromInt(position.z))))));
            if (distance < radius) radius = distance;
            if (distance <= 1) radius = 1;
            const width = radius *% 2 +% 1;
            const area: i64 = @as(i64, width) * width;
            const count: i32 = @intCast(@min(area, std.math.maxInt(i32)));
            const start = value.random.bounded(count);
            var candidates: Candidates = .{ .radius = radius, .count = count, .start = start };
            while (candidates.next()) |offset| {
                const candidate = try self.column(world, anchor.position.x +% offset[0], anchor.position.z +% offset[1]) orelse continue;
                if (try self.clear(world, candidate, border)) return result(candidate, anchor.angle);
            }
        }
        const minimum = dimension.minimum_section * 16;
        const maximum = (dimension.minimum_section + @as(i32, dimension.section_count)) * 16 - 1;
        while (!try self.clear(world, position, border) and position.y < maximum) position.y += 1;
        while (try self.clear(world, .{ .x = position.x, .y = position.y - 1, .z = position.z }, border) and position.y > minimum + 1) position.y -= 1;
        return result(position, anchor.angle);
    }

    const Column = struct { motion: i32, surface: i32, floor: i32, minimum: i32, start: i32, position: ?chunks.Position };

    pub fn column(self: *Spawn, world: u32, x: i32, z: i32) !?chunks.Position {
        const sample = try self.scanColumn(world, x, z);
        if (sample.start < sample.minimum or (sample.surface <= sample.motion and sample.surface > sample.floor)) return null;
        return sample.position;
    }

    fn scanColumn(self: *Spawn, world: u32, x: i32, z: i32) !Column {
        const dimension = (self.deps.worlds.get(world) orelse return error.UnknownWorld).dimension;
        const ceiling = if (self.deps.dimensions.get(dimension.name)) |value| value.ceiling else false;
        const minimum = dimension.minimum_section * 16;
        var motion = minimum - 1;
        var surface = minimum - 1;
        var floor = minimum - 1;
        var candidate: ?i32 = null;
        var blocked = false;
        var above: ?u16 = null;
        var window = chunks.ReadWindow(32).init(self.deps.chunks);
        defer window.deinit();
        var top = dimension.minimum_section + @as(i32, dimension.section_count);
        while (top > dimension.minimum_section) {
            const count: usize = @min(32, self.deps.chunks.cache.entries.len, @as(usize, @intCast(top - dimension.minimum_section)));
            var sections: [32]chunks.Section = undefined;
            var views: [32]chunks.View = undefined;
            for (sections[0..count], 0..) |*section, index| section.* = .{ .world = world, .x = @divFloor(x, 16), .z = @divFloor(z, 16), .y = top - 1 - @as(i32, @intCast(index)) };
            try window.readMany(sections[0..count], views[0..count]);
            for (views[0..count], sections[0..count]) |view, section| {
                for (0..16) |down| {
                    const y = section.y * 16 + 15 - @as(i32, @intCast(down));
                    const state = view.get(chunks.localIndex(.{ .x = x, .y = y, .z = z }));
                    const properties = self.deps.blocks.get(state);
                    if (surface < minimum and !properties.air) surface = y;
                    if (motion < minimum and (properties.blocks_motion or properties.fluid != .none)) {
                        motion = y;
                        if (!ceiling) if (above) |previous| {
                            if (self.deps.blocks.get(previous).collision_top_full) candidate = y + 2;
                        };
                    }
                    if (floor < minimum and properties.blocks_motion) floor = y;
                    const start = if (ceiling) self.config.origin.y else motion;
                    if (candidate == null and !blocked and start >= minimum and y <= start + 1) {
                        if (properties.fluid != .none) blocked = true else if (properties.collision_top_full) candidate = y + 1;
                    }
                    above = state;
                }
            }
            top -= @intCast(count);
            if (surface >= minimum and motion >= minimum and floor >= minimum and (candidate != null or blocked)) break;
        }
        return .{ .minimum = minimum, .motion = motion, .surface = surface, .floor = floor, .start = if (ceiling) self.config.origin.y else motion, .position = if (candidate) |y| .{ .x = x, .y = y, .z = z } else null };
    }

    fn clear(self: *Spawn, world: u32, position: chunks.Position, border: ?f64) !bool {
        const dimension = self.deps.worlds.get(world).?.dimension;
        const half_width: f64 = @as(f64, @as(f32, 0.6)) / 2;
        const height: f64 = @as(f32, 1.8);
        const center: [3]f64 = .{ @as(f64, @floatFromInt(position.x)) + 0.5, @floatFromInt(position.y), @as(f64, @floatFromInt(position.z)) + 0.5 };
        const low: [3]f64 = .{ center[0] - half_width, center[1], center[2] - half_width };
        const high: [3]f64 = .{ center[0] + half_width, center[1] + height, center[2] + half_width };
        if (border) |diameter| {
            // The fresh player's collision context is still at the origin.
            if (diameter < 4) {
                const minimum = @floor(-diameter / 2);
                const maximum = @ceil(diameter / 2);
                if (low[0] < minimum or high[0] > maximum or low[2] < minimum or high[2] > maximum) return false;
            }
        }
        var window = chunks.ReadWindow(32).init(self.deps.chunks);
        defer window.deinit();
        var positions: [36]chunks.Position = undefined;
        var sections: [36]chunks.Section = undefined;
        var views: [36]chunks.View = undefined;
        var count: usize = 0;
        for (0..3) |dx| for (0..3) |dz| for (0..4) |dy| {
            const at: chunks.Position = .{ .x = position.x + @as(i32, @intCast(dx)) - 1, .z = position.z + @as(i32, @intCast(dz)) - 1, .y = position.y + @as(i32, @intCast(dy)) - 1 };
            if (at.y < dimension.minimum_section * 16 or at.y >= (dimension.minimum_section + @as(i32, dimension.section_count)) * 16) continue;
            positions[count] = at;
            sections[count] = chunks.sectionAt(world, at);
            count += 1;
        };
        var states: [36]u16 = undefined;
        var begin: usize = 0;
        while (begin < count) {
            const end = @min(begin + @min(32, self.deps.chunks.cache.entries.len), count);
            try window.readMany(sections[begin..end], views[begin..end]);
            for (positions[begin..end], views[begin..end], states[begin..end]) |at, view, *state| state.* = view.get(chunks.localIndex(at));
            begin = end;
        }
        for (positions[0..count], states[0..count], 0..) |at, state, index| {
            const shape = game_data.physics.spawnCollision(state, at.x, at.y, at.z);
            for (0..shape.count) |box_index| {
                const box = shape.get(box_index);
                const block_low: [3]f64 = .{ @as(f64, @floatFromInt(at.x)) + box[0], @as(f64, @floatFromInt(at.y)) + box[1], @as(f64, @floatFromInt(at.z)) + box[2] };
                const block_high: [3]f64 = .{ @as(f64, @floatFromInt(at.x)) + box[3], @as(f64, @floatFromInt(at.y)) + box[4], @as(f64, @floatFromInt(at.z)) + box[5] };
                if (overlaps(low, high, block_low, block_high)) return false;
            }
            const physics = self.deps.blocks.get(state);
            // Vanilla builds the collision context before moving the new player from Y=0.
            if (physics.liquid_block and physics.amount == 8 and !physics.falling and at.y < 0) {
                const above = if (index + 1 < count and positions[index + 1].y == at.y + 1 and positions[index + 1].x == at.x and positions[index + 1].z == at.z) self.deps.blocks.get(states[index + 1]).fluid else .none;
                if (above == physics.fluid) continue;
                const block_low: [3]f64 = .{ @floatFromInt(at.x), @floatFromInt(at.y), @floatFromInt(at.z) };
                const block_high: [3]f64 = .{ block_low[0] + 1, block_low[1] + 0.5, block_low[2] + 1 };
                if (overlaps(low, high, block_low, block_high)) return false;
            }
        }
        return true;
    }
};

fn validate(definition: Spawn.Definition) !void {
    if (!std.math.isFinite(definition.angle) or definition.radius < 0 or @abs(@as(i64, definition.position.x)) > 30_000_000 or @abs(@as(i64, definition.position.y)) > 30_000_000 or @abs(@as(i64, definition.position.z)) > 30_000_000) return error.InvalidSpawn;
}
fn result(position: chunks.Position, angle: f32) Spawn.Result {
    return .{ .position = .{ .x = @as(f64, @floatFromInt(position.x)) + 0.5, .y = @floatFromInt(position.y), .z = @as(f64, @floatFromInt(position.z)) + 0.5 }, .rotation = .{ .yaw = angle, .pitch = 0 } };
}
fn overlaps(a: [3]f64, b: [3]f64, c: [3]f64, d: [3]f64) bool {
    return a[0] < d[0] - 1e-7 and b[0] > c[0] + 1e-7 and a[1] < d[1] - 1e-7 and b[1] > c[1] + 1e-7 and a[2] < d[2] - 1e-7 and b[2] > c[2] + 1e-7;
}
pub const Random = struct {
    state: u64,
    pub fn init(seed: u64) Random {
        return .{ .state = (seed ^ 0x5deece66d) & ((@as(u64, 1) << 48) - 1) };
    }
    pub fn bounded(self: *Random, bound: i32) i32 {
        std.debug.assert(bound > 0);
        while (true) {
            self.state = (self.state *% 0x5deece66d +% 11) & ((@as(u64, 1) << 48) - 1);
            const bits: i32 = @intCast(self.state >> 17);
            if (bound & -bound == bound) return @intCast((@as(i64, bound) * bits) >> 31);
            const value = @rem(bits, bound);
            if (bits -% value +% (bound - 1) >= 0) return value;
        }
    }
};
pub const Candidates = struct {
    radius: i32,
    count: i32,
    start: i32,
    attempt: i32 = 0,
    pub fn next(self: *Candidates) ?[2]i32 {
        if (self.attempt == self.count) return null;
        const stride: i32 = if (self.count <= 16) self.count - 1 else 17;
        // Java wraps the signed intermediate before taking a signed remainder.
        const index = @rem(self.start +% stride *% self.attempt, self.count);
        self.attempt += 1;
        const width = self.radius *% 2 +% 1;
        return .{ @rem(index, width) -% self.radius, @divTrunc(index, width) -% self.radius };
    }
};
pub const Spiral = struct {
    x: i32 = 0,
    z: i32 = 0,
    dx: i32 = 0,
    dz: i32 = -1,
    pub fn next(self: *Spiral) [2]i32 {
        const point: [2]i32 = .{ self.x, self.z };
        if (self.x == self.z or (self.x < 0 and self.x == -self.z) or (self.x > 0 and self.x == 1 - self.z)) {
            const dx = self.dx;
            self.dx = -self.dz;
            self.dz = dx;
        }
        self.x += self.dx;
        self.z += self.dz;
        return point;
    }
};

test "vanilla candidate stride deliberately revisits columns at radius eight" {
    var candidates: Candidates = .{ .radius = 8, .count = 289, .start = 0 };
    var visited: [289]bool = @splat(false);
    var attempts: usize = 0;
    while (candidates.next()) |at| {
        const index: usize = @intCast((at[1] + 8) * 17 + at[0] + 8);
        visited[index] = true;
        attempts += 1;
    }
    try std.testing.expectEqual(@as(usize, 289), attempts);
    var unique: usize = 0;
    for (visited) |present| unique += @intFromBool(present);
    try std.testing.expectEqual(@as(usize, 17), unique);
    var center: Candidates = .{ .radius = 0, .count = 1, .start = 0 };
    try std.testing.expectEqual(@as(?[2]i32, .{ 0, 0 }), center.next());
    try std.testing.expect(center.next() == null);
}

test "initial spawn searches a clockwise eleven by eleven chunk spiral" {
    var spiral: Spiral = .{};
    const first = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ -1, 1 }, .{ -1, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 } };
    for (first) |point| try std.testing.expectEqual(point, spiral.next());
    var visited: [121]bool = @splat(false);
    spiral = .{};
    for (0..121) |_| {
        const point = spiral.next();
        try std.testing.expect(point[0] >= -5 and point[0] <= 5 and point[1] >= -5 and point[1] <= 5);
        const index: usize = @intCast((point[0] + 5) * 11 + point[1] + 5);
        try std.testing.expect(!visited[index]);
        visited[index] = true;
    }
    for (visited) |present| try std.testing.expect(present);
}

test "spawn bounded random matches Java Random including rejection sampling" {
    var random: Random = .init(42);
    const bounds = [_]i32{ 1, 9, 289, 441, 1073741825, 2147483647, 441 };
    const expected = [_]i32{ 0, 3, 153, 80, 662969970, 2023087525, 50 };
    for (bounds, expected) |bound, value| try std.testing.expectEqual(value, random.bounded(bound));
}
