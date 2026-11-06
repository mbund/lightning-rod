const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const lighting = @import("lighting.zig");
const geometry = @import("bounds.zig");
const visibility = @import("section_visibility.zig");
const assert = std.debug.assert;
pub const occluder_property: u8 = 1;
const open_property: u8 = 2;
const air_property: u8 = 4;
const stone_property: u8 = 8;

pub const Column = struct { world: u32, x: i32, z: i32, minimum: i32 };
pub const camera_margin = 5;
const source_side = 16 + 2 * camera_margin;
const source_volume = source_side * source_side * source_side;
const source_words = (source_volume + 63) / 64;
const open_section: visibility.Section = .{};
const closed_section: visibility.Section = .{
    .solid = @splat(std.math.maxInt(u64)),
    .connections = @splat(0),
    .faces = 0,
    .components = 0,
    .boundary_components = 0,
    .kind = .solid,
    .boundary_open = false,
};
comptime {
    assert(camera_margin > 0 and camera_margin < 16 and source_side <= 32);
    assert(source_volume <= std.math.maxInt(u16));
}
pub const Source = struct {
    section: chunks.Section,
    component: u12,
    point: [3]i32,
    camera_bounds: visibility.Bounds,
    cells: u32 = 0,
    starts: [27]u6 = @splat(0),
    // Each bit identifies a component by its canonical seed voxel.
    seeds: [27][64]u64 = @splat(@splat(0)),
    membership: [64]u64 = @splat(0),

    pub fn bounds(self: *const Source) geometry.Box {
        return .{ .minimum = .{ self.section.x * 16, self.section.y * 16, self.section.z * 16 }, .maximum = .{ self.section.x * 16 + 16, self.section.y * 16 + 16, self.section.z * 16 + 16 } };
    }

    pub fn supports(self: *const Source, world: u32, point: [3]i32) bool {
        if (world != self.section.world or @divFloor(point[0], 16) != self.section.x or @divFloor(point[1], 16) != self.section.y or @divFloor(point[2], 16) != self.section.z) return false;
        if (std.meta.eql(self.point, point)) return true;
        const index: usize = @intCast(@mod(point[1], 16) * 256 + @mod(point[2], 16) * 16 + @mod(point[0], 16));
        return self.membership[index / 64] & (@as(u64, 1) << @as(u6, @intCast(index % 64))) != 0;
    }
};
pub const Handle = struct { index: usize, generation: u64 };

const Tile = struct {
    column: ?Column = null,
    count: usize = 0,
    known: u32 = 0,
    initialized: u32 = 0,
    air: u32 = 0,
    stone: u32 = 0,
    open: u32 = 0,
    closed: u32 = 0,
    previous: ?usize = null,
    next: ?usize = null,
    sections: [lighting.maximum_sections]visibility.Section = undefined,
};

const Key = struct { section: chunks.Section, component: u12, minimum: i32, count: usize, radius: i32 };
const Query = struct {
    key: ?Key = null,
    masks: []u32,
    generation: u64 = 0,
    revision: u64 = 0,
    stamp: u64 = 0,
    used: u64 = 0,
    ready: bool = false,
    octants: u8 = 0,
    order: [8]u3 = .{ 0, 2, 1, 3, 4, 6, 5, 7 },
    starts: [27]u6 = @splat(0),
    seeds: [27][64]u64 = undefined,
    cells: u32 = 0,
    camera_bounds: visibility.Bounds = undefined,
};

pub const World = struct {
    pub const Configuration = struct { columns: usize, sources: usize, radius: i32 };
    pub const batch_max = 192;
    pub const traversal_batch_max = 1024;
    pub const Advance = struct { requests: []const chunks.Section, progressed: bool };
    const unbound_column = std.math.maxInt(usize);
    const absent_column = unbound_column - 1;

    tiles: []Tile,
    properties: []const u8,
    lookup: std.AutoHashMapUnmanaged(Column, usize) = .{},
    oldest: ?usize = null,
    newest: ?usize = null,
    queries: []Query,
    query_lookup: std.AutoHashMapUnmanaged(Key, usize) = .{},
    traversal: visibility.Traversal,
    column_slots: []usize,
    workspace: visibility.Workspace = undefined,
    source_seen: [source_words]u64 = undefined,
    source_queue: [source_volume]u16 = undefined,
    source_covered: [27][64]u64 = undefined,
    requested: std.DynamicBitSetUnmanaged,
    missing: [batch_max]chunks.Section = undefined,
    missing_indices: [batch_max]usize = undefined,
    missing_count: usize = 0,
    active: ?usize = null,
    next_query: usize = 0,
    stamp: u64 = 0,
    frame: u64 = 0,
    seeding: usize = 0,
    collecting: usize = 0,
    octant: u3 = 0,
    phase: u3 = 0,
    builds: u64 = 0,
    rebuilds: u64 = 0,
    unchanged: u64 = 0,
    evictions: u64 = 0,
    working_evictions: u64 = 0,
    visits: u64 = 0,
    cache_hits: u64 = 0,
    change_lookups: u64 = 0,
    started: u64 = 0,
    completed: u64 = 0,
    cancelled: u64 = 0,
    radius: i32,

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !World {
        if (config.columns == 0 or config.sources == 0 or config.radius < 0) return error.InvalidVisibilityCapacity;
        const side: usize = @intCast(config.radius * 2 + 1);
        if (config.columns < side * side) return error.VisibilityCacheTooSmall;
        const tiles = try allocator.alloc(Tile, config.columns);
        const properties = try allocator.alloc(u8, game_data.registry.block_state_to_block.len);
        for (properties, 0..) |*value, state| value.* =
            (if (game_data.physics.rendering(@intCast(state)).occluder) occluder_property else open_property) |
            (if (game_data.physics.get(@intCast(state)).air) air_property else 0) |
            (if (state == game_data.registry.block_stone_default_state) stone_property else 0);
        for (tiles) |*tile| tile.* = .{};
        const queries = try allocator.alloc(Query, config.sources);
        const masks = try allocator.alloc(u32, config.sources * side * side);
        @memset(masks, 0);
        for (queries, 0..) |*entry, index| entry.* = .{ .masks = masks[index * side * side ..][0 .. side * side] };
        var world: World = .{
            .tiles = tiles,
            .properties = properties,
            .queries = queries,
            .radius = config.radius,
            .traversal = try .init(allocator, .{ side, lighting.maximum_sections, side }),
            .column_slots = try allocator.alloc(usize, side * side),
            .requested = try .initEmpty(allocator, side * side * lighting.maximum_sections),
        };
        try world.lookup.ensureTotalCapacity(allocator, @intCast(config.columns));
        try world.query_lookup.ensureTotalCapacity(allocator, @intCast(config.sources));
        return world;
    }

    fn touch(self: *World, slot: usize) void {
        if (self.newest == slot) return;
        const tile = &self.tiles[slot];
        if (tile.previous) |previous| self.tiles[previous].next = tile.next else self.oldest = tile.next;
        if (tile.next) |next| self.tiles[next].previous = tile.previous;
        tile.previous = self.newest;
        tile.next = null;
        if (self.newest) |newest| self.tiles[newest].next = slot;
        self.newest = slot;
        if (self.oldest == null) self.oldest = slot;
    }

    fn acquire(self: *World, column: Column, count: usize) *Tile {
        assert(count > 0 and count <= lighting.maximum_sections);
        const slot = self.lookup.get(column) orelse new: {
            const slot = if (self.lookup.count() < self.tiles.len) self.lookup.count() else self.oldest.?;
            if (self.tiles[slot].column) |previous| {
                self.evictions += 1;
                if (self.active) |active| {
                    const key = self.queries[active].key.?;
                    self.working_evictions += @intFromBool(previous.world == key.section.world and previous.minimum == key.minimum and
                        @abs(@as(i64, previous.x) - key.section.x) <= key.radius and @abs(@as(i64, previous.z) - key.section.z) <= key.radius);
                }
                self.bindColumn(previous, absent_column);
                assert(self.lookup.remove(previous));
            } else {
                self.tiles[slot].previous = self.newest;
                if (self.newest) |newest| self.tiles[newest].next = slot;
                self.newest = slot;
                if (self.oldest == null) self.oldest = slot;
            }
            self.lookup.putAssumeCapacityNoClobber(column, slot);
            self.tiles[slot].column = column;
            self.tiles[slot].count = count;
            self.tiles[slot].known = 0;
            self.tiles[slot].initialized = 0;
            self.tiles[slot].air = 0;
            self.tiles[slot].stone = 0;
            self.tiles[slot].open = 0;
            self.tiles[slot].closed = 0;
            break :new slot;
        };
        assert(self.tiles[slot].count == count);
        self.touch(slot);
        self.bindColumn(column, slot);
        return &self.tiles[slot];
    }

    fn bindColumn(self: *World, column: Column, slot: usize) void {
        const active = self.active orelse return;
        const key = self.queries[active].key.?;
        if (column.world != key.section.world or column.minimum != key.minimum) return;
        const side: usize = @intCast(2 * key.radius + 1);
        const x = @as(i64, column.x) - key.section.x + key.radius;
        const z = @as(i64, column.z) - key.section.z + key.radius;
        if (x < 0 or z < 0 or x >= side or z >= side) return;
        self.column_slots[@as(usize, @intCast(z)) * side + @as(usize, @intCast(x))] = slot;
    }

    fn traversalSection(self: *World, key: Key, at: [3]i32) ?*const visibility.Section {
        const grid = self.traversal.grid;
        const column_index = @as(usize, @intCast(at[2] - grid.minimum[2])) * grid.size[0] + @as(usize, @intCast(at[0] - grid.minimum[0]));
        const column: Column = .{ .world = key.section.world, .x = at[0], .z = at[2], .minimum = key.minimum };
        var slot = self.column_slots[column_index];
        if (slot == unbound_column) {
            slot = self.lookup.get(column) orelse absent_column;
            self.column_slots[column_index] = slot;
            if (slot != absent_column) self.touch(slot);
        }
        if (slot == absent_column) return null;
        const tile = &self.tiles[slot];
        assert(std.meta.eql(tile.column.?, column) and tile.count == key.count);
        const offset: usize = @intCast(at[1] - key.minimum);
        assert(offset < key.count);
        const bit = @as(u32, 1) << @as(u5, @intCast(offset));
        if (tile.known & bit == 0) return null;
        if (tile.open & bit != 0) return &open_section;
        if (tile.closed & bit != 0) return &closed_section;
        return &tile.sections[offset];
    }

    pub fn learnSection(self: *World, column: Column, count: usize, offset: usize, view: lighting.Section.View) void {
        assert(offset < count and view != .unavailable);
        const tile = self.acquire(column, count);
        const bit = @as(u32, 1) << @as(u5, @intCast(offset));
        if (tile.known & bit != 0) return;
        if (view == .encoded) {
            const classified = chunks.encoding.classify(view.encoded.bytes, self.properties, occluder_property, .complete) catch unreachable;
            const properties = classified.known.common;
            self.learnClassified(tile, column, offset, &classified.known.selected, properties & stone_property != 0, properties & air_property != 0);
            return;
        }
        var solid: [64]u64 = @splat(0);
        var stone = true;
        var air = true;
        if (view == .uniform) {
            const properties = self.properties[view.uniform];
            if (properties & occluder_property != 0) solid = @splat(std.math.maxInt(u64));
            stone = properties & stone_property != 0;
            air = properties & air_property != 0;
        } else for (0..256) |row| {
            const states = view.row(@intCast(row));
            const lanes: @Vector(16, u16) = states;
            var bits: u16 = 0;
            if (@reduce(.And, lanes == @as(@Vector(16, u16), @splat(states[0])))) {
                const state = states[0];
                const properties = self.properties[state];
                if (properties & occluder_property != 0) bits = 0xffff;
                stone = stone and properties & stone_property != 0;
                air = air and properties & air_property != 0;
            } else for (0..16) |index| {
                const state = states[index];
                const properties = self.properties[state];
                if (properties & occluder_property != 0) bits |= @as(u16, 1) << @intCast(index);
                stone = stone and properties & stone_property != 0;
                air = air and properties & air_property != 0;
            }
            solid[row / 4] |= @as(u64, bits) << @intCast(row % 4 * 16);
        }
        self.learnClassified(tile, column, offset, &solid, stone, air);
    }

    pub fn learnClassification(self: *World, column: Column, count: usize, offset: usize, classification: *const chunks.encoding.Classification) bool {
        if (classification.* == .unavailable) return false;
        assert(classification.known.property == occluder_property);
        const properties = classification.known.common;
        assert(offset < count and properties & (occluder_property | open_property) != (occluder_property | open_property));
        assert(properties & air_property == 0 or properties & open_property != 0);
        assert(properties & stone_property == 0 or properties & occluder_property != 0);
        const tile = self.acquire(column, count);
        if (tile.known & (@as(u32, 1) << @intCast(offset)) != 0) return true;
        self.learnClassified(tile, column, offset, &classification.known.selected, properties & stone_property != 0, properties & air_property != 0);
        return true;
    }

    fn learnClassified(self: *World, tile: *Tile, column: Column, offset: usize, solid: *const [64]u64, stone: bool, air: bool) void {
        const bit = @as(u32, 1) << @as(u5, @intCast(offset));
        assert(tile.known & bit == 0);
        const initialized = tile.initialized & bit != 0;
        const boundary_open = !initialized or tile.sections[offset].boundary_open;
        const occupancy_changed = initialized and !std.mem.eql(u64, &tile.sections[offset].solid, solid);
        if (!initialized or occupancy_changed) {
            tile.sections[offset].build(solid, &self.workspace);
            self.builds += 1;
            self.rebuilds += @intFromBool(initialized);
        } else self.unchanged += 1;
        tile.known |= bit;
        tile.initialized |= bit;
        tile.air = (tile.air & ~bit) | (bit * @intFromBool(air));
        tile.stone = (tile.stone & ~bit) | (bit * @intFromBool(stone));
        tile.open = (tile.open & ~bit) | (bit * @intFromBool(tile.sections[offset].kind == .air));
        tile.closed = (tile.closed & ~bit) | (bit * @intFromBool(tile.sections[offset].kind == .solid));
        assert(tile.open & tile.closed == 0);
        if (occupancy_changed and (!boundary_open or !tile.sections[offset].boundary_open)) {
            self.invalidateQueries(column.world, .{ .minimum = .{ column.x * 16, (column.minimum + @as(i32, @intCast(offset))) * 16, column.z * 16 }, .maximum = .{ column.x * 16 + 16, (column.minimum + @as(i32, @intCast(offset))) * 16 + 16, column.z * 16 + 16 } });
        }
    }

    pub fn learn(self: *World, column: Column, sections: []const lighting.Section) void {
        for (sections, 0..) |data, offset| {
            if (data.view == .unavailable) continue;
            self.learnSection(column, sections.len, offset, data.view);
        }
    }

    pub fn learnNeighborhood(self: *World, column: Column, count: usize, sections: []const lighting.Section) void {
        assert(sections.len == 9 * count);
        for (0..9) |neighbor| self.learn(.{ .world = column.world, .x = column.x + @as(i32, @intCast(neighbor % 3)) - 1, .z = column.z + @as(i32, @intCast(neighbor / 3)) - 1, .minimum = column.minimum }, sections[neighbor * count ..][0..count]);
    }

    fn section(self: *World, key: chunks.Section, minimum: i32, count: usize) ?*const visibility.Section {
        const offset = @as(i64, key.y) - minimum;
        if (offset < 0 or offset >= count) return null;
        const slot = self.lookup.get(.{ .world = key.world, .x = key.x, .z = key.z, .minimum = minimum }) orelse return null;
        const tile = &self.tiles[slot];
        const bit = @as(u32, 1) << @as(u5, @intCast(offset));
        if (tile.known & bit == 0) return null;
        self.touch(slot);
        if (tile.open & bit != 0) return &open_section;
        if (tile.closed & bit != 0) return &closed_section;
        return &tile.sections[@intCast(offset)];
    }

    pub fn sourceRequirements(world: u32, minimum: i32, count: usize, point: [3]i32, output: *[27]chunks.Section) []const chunks.Section {
        const y = @divFloor(point[1], 16);
        if (y < minimum or y >= minimum + @as(i32, @intCast(count))) return &.{};
        var length: usize = 0;
        for (0..27) |index| {
            const at: chunks.Section = .{ .world = world, .x = @divFloor(point[0], 16) + @as(i32, @intCast(index % 3)) - 1, .y = y + @as(i32, @intCast(index / 3 % 3)) - 1, .z = @divFloor(point[2], 16) + @as(i32, @intCast(index / 9)) - 1 };
            if (at.y < minimum or at.y >= minimum + @as(i32, @intCast(count))) continue;
            output[length] = at;
            length += 1;
        }
        return output[0..length];
    }

    pub fn known(self: *World, key: chunks.Section, minimum: i32, count: usize) bool {
        return self.section(key, minimum, count) != null;
    }

    pub fn source(self: *World, world: u32, minimum: i32, count: usize, point: [3]i32, output: *Source) ?*const Source {
        const key: chunks.Section = .{ .world = world, .x = @divFloor(point[0], 16), .y = @divFloor(point[1], 16), .z = @divFloor(point[2], 16) };
        output.* = .{ .section = key, .component = 0, .point = point, .camera_bounds = .{
            .minimum = .{ key.x * 16 - camera_margin, key.y * 16 - camera_margin, key.z * 16 - camera_margin },
            .maximum = .{ key.x * 16 + 16 + camera_margin, key.y * 16 + 16 + camera_margin, key.z * 16 + 16 + camera_margin },
        } };
        const result = output;
        if (key.y < minimum or key.y >= minimum + @as(i32, @intCast(count))) {
            result.membership = @splat(std.math.maxInt(u64));
            return result;
        }
        const center = self.section(key, minimum, count) orelse {
            return null;
        };
        const source_voxel: u12 = @intCast(@mod(point[1], 16) * 256 + @mod(point[2], 16) * 16 + @mod(point[0], 16));
        const source_component = center.component(source_voxel, &self.workspace) orelse return result;
        if (source_component.faces == 0) {
            result.component = source_component.seed;
            result.cells = 1 << 13;
            if (center.components == 1) {
                for (&result.membership, center.solid) |*bits, solid| bits.* = ~solid;
            } else result.membership = self.workspace.component_bits;
            result.seeds[13][source_component.seed / 64] |= @as(u64, 1) << @as(u6, @intCast(source_component.seed % 64));
            result.camera_bounds = visibility.Bounds.fromBits(&result.membership);
            const section_origin: [3]i32 = .{ key.x * 16, key.y * 16, key.z * 16 };
            for (0..3) |axis| {
                result.camera_bounds.minimum[axis] += section_origin[axis];
                result.camera_bounds.maximum[axis] += section_origin[axis];
            }
            return result;
        }
        const air: visibility.Section = .{};
        var materials: [27]*const visibility.Section = undefined;
        var all_air = true;
        for (&materials, 0..) |*data, index| {
            const at: chunks.Section = .{ .world = world, .x = key.x + @as(i32, @intCast(index % 3)) - 1, .y = key.y + @as(i32, @intCast(index / 3 % 3)) - 1, .z = key.z + @as(i32, @intCast(index / 9)) - 1 };
            data.* = if (at.y < minimum or at.y >= minimum + @as(i32, @intCast(count))) &air else self.section(at, minimum, count) orelse {
                return null;
            };
            all_air = all_air and data.*.kind == .air;
        }
        if (all_air) {
            result.cells = (1 << 27) - 1;
            result.starts = @splat(63);
            for (&result.seeds) |*selected| selected[0] = 1;
            result.membership = @splat(std.math.maxInt(u64));
            return result;
        }
        @memset(&self.source_seen, 0);
        @memset(&self.source_covered, @splat(0));
        const origin = [3]i32{ key.x * 16 - camera_margin, key.y * 16 - camera_margin, key.z * 16 - camera_margin };
        for (0..source_side) |y| for (0..source_side) |z| {
            const neighbor_y = (y + 16 - camera_margin) / 16;
            const neighbor_z = (z + 16 - camera_margin) / 16;
            const local_y = (y + 16 - camera_margin) % 16;
            const local_z = (z + 16 - camera_margin) % 16;
            const word = local_y * 4 + local_z / 4;
            const shift: u6 = @intCast(local_z % 4 * 16);
            const first = neighbor_z * 9 + neighbor_y * 3;
            const left: u32 = @as(u16, @truncate(materials[first].solid[word] >> shift));
            const middle: u32 = @as(u16, @truncate(materials[first + 1].solid[word] >> shift));
            const right: u32 = @as(u16, @truncate(materials[first + 2].solid[word] >> shift));
            const row = (left >> (16 - camera_margin)) | (middle << camera_margin) | ((right & ((1 << camera_margin) - 1)) << (16 + camera_margin));
            const index = (y * source_side + z) * source_side;
            const offset: u6 = @intCast(index % 64);
            self.source_seen[index / 64] |= @as(u64, row) << offset;
            if (offset > 64 - source_side) self.source_seen[index / 64 + 1] |= @as(u64, row) >> @intCast(64 - @as(usize, offset));
        };
        var tail: usize = 0;
        const seed: usize = @intCast(((point[1] - origin[1]) * source_side + point[2] - origin[2]) * source_side + point[0] - origin[0]);
        self.sourceVisit(seed, &tail);
        var head: usize = 0;
        if (tail != 0) result.camera_bounds = .{ .minimum = point, .maximum = .{ point[0] + 1, point[1] + 1, point[2] + 1 } };
        while (head < tail) : (head += 1) {
            const index = self.source_queue[head];
            const local = [3]usize{ index % source_side, index / (source_side * source_side), index / source_side % source_side };
            const at = [3]i32{ origin[0] + @as(i32, @intCast(local[0])), origin[1] + @as(i32, @intCast(local[1])), origin[2] + @as(i32, @intCast(local[2])) };
            for (0..3) |axis| {
                result.camera_bounds.minimum[axis] = @min(result.camera_bounds.minimum[axis], at[axis]);
                result.camera_bounds.maximum[axis] = @max(result.camera_bounds.maximum[axis], at[axis] + 1);
            }
            const neighbor: usize = @intCast((@divFloor(at[2], 16) - key.z + 1) * 9 + (@divFloor(at[1], 16) - key.y + 1) * 3 + @divFloor(at[0], 16) - key.x + 1);
            const voxel: u12 = @intCast(@mod(at[1], 16) * 256 + @mod(at[2], 16) * 16 + @mod(at[0], 16));
            const bit = @as(u64, 1) << @as(u6, @intCast(voxel % 64));
            if (self.source_covered[neighbor][voxel / 64] & bit == 0) {
                const data = materials[neighbor];
                const component = data.component(voxel, &self.workspace).?;
                result.seeds[neighbor][component.seed / 64] |= @as(u64, 1) << @as(u6, @intCast(component.seed % 64));
                result.starts[neighbor] |= component.faces;
                result.cells |= @as(u32, 1) << @as(u5, @intCast(neighbor));
                for (&self.source_covered[neighbor], 0..) |*covered, word| covered.* |= if (data.components == 1) ~data.solid[word] else self.workspace.seen[word] & ~data.solid[word];
            }
            for (0..3) |axis| {
                const strides = [_]usize{ 1, source_side * source_side, source_side };
                if (local[axis] != 0) self.sourceVisit(index - strides[axis], &tail);
                if (local[axis] + 1 != source_side) self.sourceVisit(index + strides[axis], &tail);
            }
        }
        result.membership = self.source_covered[13];
        for (result.membership, 0..) |bits, word| if (bits != 0) {
            result.component = @intCast(word * 64 + @ctz(bits));
            break;
        };
        return result;
    }

    fn sourceVisit(self: *World, index: usize, tail: *usize) void {
        assert(index < source_volume);
        const bit = @as(u64, 1) << @as(u6, @intCast(index % 64));
        if (self.source_seen[index / 64] & bit != 0) return;
        self.source_seen[index / 64] |= bit;
        assert(tail.* < self.source_queue.len);
        self.source_queue[tail.*] = @intCast(index);
        tail.* += 1;
    }

    pub fn beginPoll(self: *World) void {
        self.frame += 1;
    }

    pub fn query(self: *World, origin: *const Source, minimum: i32, count: usize, radius: i32) Handle {
        assert(count > 0 and count <= lighting.maximum_sections and radius >= 0 and radius <= self.radius);
        const key: Key = .{ .section = origin.section, .component = origin.component, .minimum = minimum, .count = count, .radius = radius };
        self.stamp += 1;
        if (self.query_lookup.get(key)) |slot| {
            const entry = &self.queries[slot];
            if (entry.cells != origin.cells or !std.meta.eql(entry.camera_bounds, origin.camera_bounds) or !std.mem.eql(u6, &entry.starts, &origin.starts) or !std.mem.eql(u8, std.mem.asBytes(&entry.seeds), std.mem.asBytes(&origin.seeds))) {
                entry.ready = false;
                entry.octants = 0;
                entry.seeds = origin.seeds;
                if (self.active == slot) self.cancel();
            }
            entry.stamp = self.stamp;
            entry.used = self.frame;
            entry.starts = origin.starts;
            entry.cells = origin.cells;
            entry.camera_bounds = origin.camera_bounds;
            self.cache_hits += 1;
            return .{ .index = slot, .generation = entry.generation };
        }
        var slot: usize = 0;
        for (self.queries, 0..) |*entry, index| if (entry.key == null or entry.stamp < self.queries[slot].stamp) {
            slot = index;
            if (entry.key == null) break;
        };
        const entry = &self.queries[slot];
        if (entry.key) |previous| assert(self.query_lookup.remove(previous));
        if (self.active == slot) self.cancel();
        entry.generation += 1;
        entry.key = key;
        entry.stamp = self.stamp;
        entry.used = self.frame;
        entry.starts = origin.starts;
        entry.seeds = origin.seeds;
        entry.cells = origin.cells;
        entry.camera_bounds = origin.camera_bounds;
        entry.ready = false;
        entry.octants = 0;
        self.query_lookup.putAssumeCapacityNoClobber(key, slot);
        return .{ .index = slot, .generation = entry.generation };
    }

    pub fn ready(self: *const World, handle: Handle) bool {
        const entry = &self.queries[handle.index];
        return entry.generation == handle.generation and entry.ready;
    }

    pub fn valid(self: *const World, handle: Handle) bool {
        assert(handle.index < self.queries.len);
        const entry = &self.queries[handle.index];
        return entry.key != null and entry.generation == handle.generation;
    }

    pub fn completedOctants(self: *const World, handle: Handle) u8 {
        assert(self.valid(handle));
        return self.queries[handle.index].octants;
    }

    pub fn prioritize(self: *World, handle: Handle, direction: [2]i32) void {
        assert(self.valid(handle));
        if (self.active == handle.index) return;
        const first: u3 = @as(u3, @intFromBool(direction[0] > 0)) | (@as(u3, @intFromBool(direction[1] > 0)) << 2);
        const primary: u3 = if (@abs(direction[0]) >= @abs(direction[1])) 1 else 4;
        const secondary = primary ^ 5;
        self.queries[handle.index].order = .{ first, first ^ 2, first ^ secondary, first ^ secondary ^ 2, first ^ primary, first ^ primary ^ 2, first ^ 5, first ^ 7 };
    }

    pub fn readyColumn(self: *const World, handle: Handle, x: i32, z: i32) bool {
        if (!self.valid(handle)) return false;
        const entry = &self.queries[handle.index];
        const key = entry.key.?;
        if (@abs(@as(i64, x) - key.section.x) > key.radius or @abs(@as(i64, z) - key.section.z) > key.radius) return false;
        if (entry.ready) return true;
        var required: u8 = 255;
        if (key.section.y >= key.minimum and key.section.y < key.minimum + @as(i32, @intCast(key.count))) {
            // Initial components occupy the source section and its immediate neighbors.
            // Every octant then advances only along its three forward faces.
            if (x < key.section.x - 1) required &= 0x55 else if (x > key.section.x + 1) required &= 0xaa;
            if (z < key.section.z - 1) required &= 0x0f else if (z > key.section.z + 1) required &= 0xf0;
        }
        return entry.octants & required == required;
    }

    pub fn readyColumns(self: *const World, handle: Handle, minimum: [2]i32, maximum: [2]i32) bool {
        assert(minimum[0] <= maximum[0] and minimum[1] <= maximum[1]);
        return self.readyColumn(handle, minimum[0], minimum[1]) and self.readyColumn(handle, minimum[0], maximum[1]) and
            self.readyColumn(handle, maximum[0], minimum[1]) and self.readyColumn(handle, maximum[0], maximum[1]);
    }

    pub fn retain(self: *World, handle: Handle) bool {
        const entry = &self.queries[handle.index];
        if (entry.generation != handle.generation) return false;
        assert(entry.key != null);
        self.stamp += 1;
        entry.stamp = self.stamp;
        entry.used = self.frame;
        return true;
    }

    pub fn activeQuery(self: *const World) ?Handle {
        const index = self.active orelse return null;
        return .{ .index = index, .generation = self.queries[index].generation };
    }

    pub fn revision(self: *const World, handle: Handle) u64 {
        assert(self.ready(handle));
        return self.queries[handle.index].revision;
    }

    pub fn mask(self: *const World, handle: Handle, x: i32, z: i32) u32 {
        assert(self.valid(handle));
        const entry = &self.queries[handle.index];
        const key = entry.key.?;
        const side: usize = @intCast(2 * key.radius + 1);
        const dx = @as(i64, x) - key.section.x + key.radius;
        const dz = @as(i64, z) - key.section.z + key.radius;
        if (dx < 0 or dz < 0 or dx >= side or dz >= side) return 0;
        assert(self.readyColumn(handle, x, z));
        return entry.masks[@as(usize, @intCast(dz)) * side + @as(usize, @intCast(dx))];
    }

    fn request(self: *World, key: Key, index: usize) void {
        if (self.requested.isSet(index) or self.missing_count == batch_max) return;
        const at = self.traversal.grid.position(index);
        self.missing[self.missing_count] = .{ .world = key.section.world, .x = at[0], .y = at[1], .z = at[2] };
        self.missing_indices[self.missing_count] = index;
        self.missing_count += 1;
        self.requested.set(index);
    }

    fn beginTraversal(self: *World, entry: *const Query, key: Key) void {
        const side: usize = @intCast(2 * key.radius + 1);
        const at = key.section;
        self.traversal.beginBounds(.{ .minimum = .{ at.x - key.radius, key.minimum, at.z - key.radius }, .size = .{ side, key.count, side } }, entry.camera_bounds, self.octant);
        self.seeding = 0;
        self.collecting = 0;
        if (at.y >= key.minimum and at.y < key.minimum + @as(i32, @intCast(key.count))) {
            for (0..27) |cell| {
                const position: [3]i32 = .{ at.x + @as(i32, @intCast(cell % 3)) - 1, at.y + @as(i32, @intCast(cell / 3 % 3)) - 1, at.z + @as(i32, @intCast(cell / 9)) - 1 };
                if (self.traversal.grid.index(position) == null) continue;
                if (cell == 13 or entry.cells & (@as(u32, 1) << @as(u5, @intCast(cell))) != 0) self.traversal.seed(position, entry.starts[cell], null, &entry.seeds[cell]);
            }
            self.seeding = side * side;
        }
    }

    /// Requests borrow this workspace. Progress can yield without requesting terrain.
    pub fn advance(self: *World) Advance {
        assert(self.started == self.completed + self.cancelled + @intFromBool(self.active != null));
        const active = self.active;
        const octant = self.octant;
        const seeding = self.seeding;
        const collecting = self.collecting;
        const visits = self.visits;
        const completed = self.completed;
        const requests = self.advanceBatch();
        assert(requests.len <= batch_max);
        assert(self.started == self.completed + self.cancelled + @intFromBool(self.active != null));
        return .{
            .requests = requests,
            .progressed = active != self.active or octant != self.octant or seeding != self.seeding or collecting != self.collecting or visits != self.visits or completed != self.completed,
        };
    }

    fn advanceBatch(self: *World) []const chunks.Section {
        var remaining: usize = traversal_batch_max;
        for (self.missing_indices[0..self.missing_count]) |index| self.requested.unset(index);
        self.missing_count = 0;
        if (self.active) |index| if (self.queries[index].used != self.frame) {
            self.cancel();
        };
        if (self.active == null) {
            var selected: ?usize = null;
            for (0..self.queries.len) |offset| {
                const index = (self.next_query + offset) % self.queries.len;
                const entry = &self.queries[index];
                if (entry.key == null or entry.ready or entry.used != self.frame) continue;
                if (selected) |previous| if (entry.key.?.radius >= self.queries[previous].key.?.radius) continue;
                selected = index;
            }
            if (selected) |index| {
                self.next_query = (index + 1) % self.queries.len;
                const entry = &self.queries[index];
                const key = entry.key.?;
                self.phase = 0;
                self.octant = entry.order[0];
                entry.octants = 0;
                @memset(entry.masks, 0);
                const side: usize = @intCast(2 * key.radius + 1);
                @memset(self.column_slots[0 .. side * side], unbound_column);
                self.active = index;
                self.started += 1;
                self.beginTraversal(entry, key);
            }
        }
        const active = self.active orelse return &.{};
        const entry = &self.queries[active];
        const key = entry.key.?;
        while (true) {
            const grid = self.traversal.grid;
            const column_count = grid.size[0] * grid.size[2];
            var seed_missing: ?usize = null;
            while (self.seeding < column_count) {
                if (remaining == 0) {
                    if (seed_missing) |first| self.seeding = first;
                    return self.missing[0..self.missing_count];
                }
                remaining -= 1;
                const above = key.section.y >= key.minimum + @as(i32, @intCast(key.count));
                const at: [3]i32 = .{ grid.minimum[0] + @as(i32, @intCast(self.seeding % grid.size[0])), if (above) key.minimum + @as(i32, @intCast(key.count)) - 1 else key.minimum, grid.minimum[2] + @as(i32, @intCast(self.seeding / grid.size[0])) };
                const data = self.traversalSection(key, at) orelse {
                    if (seed_missing == null) seed_missing = self.seeding;
                    self.request(key, grid.index(at).?);
                    if (self.missing_count == batch_max) break;
                    self.seeding += 1;
                    continue;
                };
                const face: usize = if (above) 3 else 2;
                var portal: visibility.Bounds = .{ .minimum = .{ at[0] * 16, at[1] * 16, at[2] * 16 }, .maximum = .{ at[0] * 16 + 16, at[1] * 16 + 16, at[2] * 16 + 16 } };
                portal.minimum[1] = if (above) portal.maximum[1] else portal.minimum[1];
                portal.maximum[1] = portal.minimum[1];
                self.traversal.seed(at, data.connections[face], portal, null);
                self.seeding += 1;
            }
            if (self.missing_count != 0) {
                self.seeding = seed_missing.?;
                return self.missing[0..self.missing_count];
            }
            while (self.traversal.pending()) |index| {
                if (remaining == 0) return &.{};
                remaining -= 1;
                const at = grid.position(index);
                const data = self.traversalSection(key, at);
                var neighbors: [6]?*const visibility.Section = @splat(null);
                if (data == null) self.request(key, index);
                const exits = if (data) |value| self.traversal.outgoing(index, value) else @as(u6, 0);
                for (0..6) |face| {
                    if (exits & (@as(u6, 1) << @as(u3, @intCast(face))) == 0) continue;
                    const axis = face / 2;
                    var next = at;
                    next[axis] += if (face % 2 == 0) @as(i32, -1) else 1;
                    const next_index = grid.index(next) orelse continue;
                    neighbors[face] = self.traversalSection(key, next);
                    if (neighbors[face] == null) self.request(key, next_index);
                }
                if (self.missing_count != 0) break;
                self.traversal.advance(data.?, neighbors);
                self.visits += 1;
            }
            if (self.missing_count != 0) {
                var frontier: [batch_max]usize = undefined;
                const count = self.traversal.pendingBatch(&frontier);
                for (frontier[0..count]) |index| {
                    if (self.missing_count == batch_max) break;
                    const at = grid.position(index);
                    const data = self.traversalSection(key, at) orelse {
                        self.request(key, index);
                        continue;
                    };
                    const exits = self.traversal.outgoing(index, data);
                    for (0..6) |face| {
                        if (exits & (@as(u6, 1) << @as(u3, @intCast(face))) == 0) continue;
                        var next = at;
                        next[face / 2] += if (face % 2 == 0) @as(i32, -1) else 1;
                        const other = grid.index(next) orelse continue;
                        if (self.traversalSection(key, next) == null) self.request(key, other);
                    }
                }
            } else if (self.traversal.pending() == null) {
                const side = grid.size[0];
                while (self.collecting < self.traversal.disclosed_count) : (self.collecting += 1) {
                    if (remaining == 0) return &.{};
                    remaining -= 1;
                    const index = self.traversal.disclosed[self.collecting];
                    const at = grid.position(index);
                    const x: usize = @intCast(at[0] - grid.minimum[0]);
                    const z: usize = @intCast(at[2] - grid.minimum[2]);
                    entry.masks[z * side + x] |= @as(u32, 1) << @as(u5, @intCast(at[1] - key.minimum));
                }
                entry.octants |= @as(u8, 1) << self.octant;
                if (self.phase == 7) {
                    assert(entry.octants == 255);
                    entry.ready = true;
                    entry.revision += 1;
                    self.completed += 1;
                    self.active = null;
                } else {
                    self.phase += 1;
                    self.octant = entry.order[self.phase];
                    self.beginTraversal(entry, key);
                }
            }
            if (self.missing_count != 0 or self.active == null) return self.missing[0..self.missing_count];
        }
    }

    pub fn changed(self: *World, world: u32, minimum: i32, box: geometry.Box) void {
        box.validate();
        var unresolved = false;
        var z = @divFloor(box.minimum[2], 16);
        while (z <= @divFloor(box.maximum[2] - 1, 16)) : (z += 1) {
            var x = @divFloor(box.minimum[0], 16);
            while (x <= @divFloor(box.maximum[0] - 1, 16)) : (x += 1) {
                self.change_lookups += 1;
                const slot = self.lookup.get(.{ .world = world, .x = x, .z = z, .minimum = minimum }) orelse {
                    unresolved = true;
                    continue;
                };
                const tile = &self.tiles[slot];
                var y = @max(0, @divFloor(box.minimum[1], 16) - minimum);
                while (y < tile.count and y <= @divFloor(box.maximum[1] - 1, 16) - minimum) : (y += 1) {
                    const bit = @as(u32, 1) << @as(u5, @intCast(y));
                    unresolved = unresolved or tile.initialized & bit == 0;
                    tile.known &= ~bit;
                }
            }
        }
        if (unresolved) self.invalidateQueries(world, box);
    }

    fn invalidateQueries(self: *World, world: u32, box: geometry.Box) void {
        for (self.queries, 0..) |*entry, index| {
            const key = entry.key orelse continue;
            if (key.section.world != world) continue;
            const at = key.section;
            if (@divFloor(box.minimum[0], 16) > at.x + key.radius + 1 or @divFloor(box.maximum[0] - 1, 16) < at.x - key.radius - 1 or
                @divFloor(box.minimum[2], 16) > at.z + key.radius + 1 or @divFloor(box.maximum[2] - 1, 16) < at.z - key.radius - 1) continue;
            entry.ready = false;
            entry.octants = 0;
            if (self.active == index) self.cancel();
        }
    }

    pub fn invalidate(self: *World) void {
        for (self.tiles) |*tile| tile.known = 0;
        self.invalidateResults();
    }

    pub fn invalidateResults(self: *World) void {
        for (self.queries) |*entry| {
            entry.ready = false;
            entry.octants = 0;
        }
        self.cancel();
    }

    fn cancel(self: *World) void {
        self.cancelled += @intFromBool(self.active != null);
        self.active = null;
    }

    pub fn stoneMask(self: *const World, column: Column, count: usize) u32 {
        const slot = self.lookup.get(column) orelse return 0;
        const tile = &self.tiles[slot];
        assert(tile.count == count);
        return tile.stone & tile.known;
    }

    pub fn skyAir(self: *const World, column: Column, count: usize) u32 {
        const slot = self.lookup.get(column) orelse return 0;
        const tile = &self.tiles[slot];
        assert(tile.count == count);
        const all = (@as(u32, 1) << @as(u5, @intCast(count))) - 1;
        const blocked = all & ~(tile.air & tile.known);
        if (blocked == 0) return all;
        return all & ~((@as(u32, 1) << @as(u5, @intCast(32 - @clz(blocked)))) - 1);
    }
};

test "bounded warm queries report progress while traversing and collecting without allocating" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 289, .sources = 1, .radius = 8 });
    const air: [24]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..289) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 17)) - 8, .z = @as(i32, @intCast(index / 17)) - 8, .minimum = -4 }, &air);
    var source_storage: Source = undefined;
    const source = world.source(0, -4, 24, .{ 8, 72, 8 }, &source_storage).?;
    const builds = world.builds;
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var collection_yielded = false;
    var calls: usize = 0;
    world.beginPoll();
    const query = world.query(source, -4, 24, 8);
    while (true) : (calls += 1) {
        try std.testing.expect(calls < 128);
        world.beginPoll();
        try std.testing.expect(world.retain(query));
        const visits = world.visits;
        const advanced = world.advance();
        try std.testing.expectEqual(@as(usize, 0), advanced.requests.len);
        try std.testing.expect(advanced.progressed);
        try std.testing.expect(world.visits - visits <= World.traversal_batch_max);
        collection_yielded = collection_yielded or (world.visits == visits and !world.ready(query));
        if (!world.ready(query)) continue;
        for (0..289) |index| try std.testing.expectEqual(@as(u32, (1 << 24) - 1), world.mask(query, @as(i32, @intCast(index % 17)) - 8, @as(i32, @intCast(index / 17)) - 8));
        break;
    }
    try std.testing.expect(collection_yielded);
    try std.testing.expectEqual(builds, world.builds);
    try std.testing.expect(!bounded.has_induced_failure);
    var other = source.*;
    other.section.x += 1;
    const replacement = world.query(&other, -4, 24, 8);
    try std.testing.expect(!world.retain(query));
    try std.testing.expect(world.retain(replacement));
}

test "leading columns finish before the complete horizon without publishing partial masks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 289, .sources = 1, .radius = 8 });
    const sections: [24]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..289) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 17)) - 8, .z = @as(i32, @intCast(index / 17)) - 8, .minimum = -4 }, &sections);
    var source_storage: Source = undefined;
    const source = world.source(0, -4, 24, .{ 8, 72, 8 }, &source_storage).?;
    world.beginPoll();
    const query = world.query(source, -4, 24, 8);
    world.prioritize(query, .{ 1, 0 });
    try std.testing.expect(!world.readyColumn(query, 8, 0));
    for (0..128) |_| {
        try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        if (!world.readyColumns(query, .{ 7, -1 }, .{ 8, 1 })) continue;
        try std.testing.expect(!world.ready(query));
        try std.testing.expect(!world.readyColumn(query, -8, 0));
        try std.testing.expectEqual(@as(u32, (1 << 24) - 1), world.mask(query, 8, 0));
        break;
    } else return error.ColumnCompletionStalled;
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    for (0..289) |index| try std.testing.expectEqual(@as(u32, (1 << 24) - 1), world.mask(query, @as(i32, @intCast(index % 17)) - 8, @as(i32, @intCast(index / 17)) - 8));
    world.invalidateResults();
    try std.testing.expect(!world.readyColumn(query, 8, 0));
    try std.testing.expectEqual(@as(u8, 0), world.completedOctants(query));
}

test "near queries complete first and every published column matches the final horizon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 289, .sources = 2, .radius = 8 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var states: [4096]u16 = undefined;
    for (0..289) |index| {
        const x = @as(i32, @intCast(index % 17)) - 8;
        const z = @as(i32, @intCast(index / 17)) - 8;
        const column: Column = .{ .world = 0, .x = x, .z = z, .minimum = 0 };
        world.learnSection(column, 4, 0, .{ .uniform = stone });
        for (&states, 0..) |*state, local| {
            const y = local / 256;
            const wall = (local % 16 == 8 and @mod(x, 3) == 2) or (local / 16 % 16 == 8 and @mod(z, 3) == 2);
            state.* = if (wall and (y < 5 or y >= 9)) stone else 0;
        }
        world.learnSection(column, 4, 1, .{ .dense = &states });
        world.learnSection(column, 4, 2, .{ .uniform = 0 });
        world.learnSection(column, 4, 3, .{ .uniform = 0 });
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    world.beginPoll();
    const far = world.query(source, 0, 4, 8);
    const near = world.query(source, 0, 4, 3);
    var published: [289]?u32 = @splat(null);
    for (0..128) |_| {
        try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        if (!world.ready(near)) continue;
        try std.testing.expect(!world.ready(far));
        break;
    } else return error.NearQueryStalled;
    for (0..128) |_| {
        try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        for (&published, 0..) |*mask, index| {
            const x = @as(i32, @intCast(index % 17)) - 8;
            const z = @as(i32, @intCast(index / 17)) - 8;
            if (!world.readyColumn(far, x, z)) continue;
            const current = world.mask(far, x, z);
            if (mask.*) |previous| try std.testing.expectEqual(previous, current);
            mask.* = current;
        }
        if (world.ready(far)) break;
    } else return error.HorizonStalled;
    for (0..49) |index| {
        const x = @as(i32, @intCast(index % 7)) - 3;
        const z = @as(i32, @intCast(index / 7)) - 3;
        try std.testing.expectEqual(world.mask(far, x, z), world.mask(near, x, z));
    }
    for (published) |mask| try std.testing.expect(mask != null);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "homogeneous topology is shared and material-only edits retain connectivity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .sources = 1, .radius = 1 });
    const a: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    const b: Column = .{ .world = 0, .x = 1, .z = 0, .minimum = 0 };
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const dirt: u16 = @intCast(game_data.registry.block_dirt_default_state);
    world.learnSection(a, 1, 0, .{ .uniform = stone });
    world.learnSection(b, 1, 0, .{ .uniform = stone });
    const at: chunks.Section = .{ .world = 0, .x = 0, .z = 0, .y = 0 };
    try std.testing.expectEqual(world.section(at, 0, 1).?, world.section(.{ .world = 0, .x = 1, .z = 0, .y = 0 }, 0, 1).?);
    const builds = world.builds;
    const bounds: geometry.Box = .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 16, 16, 16 } };
    world.changed(0, 0, bounds);
    try std.testing.expect(world.section(at, 0, 1) == null);
    world.learnSection(a, 1, 0, .{ .uniform = dirt });
    try std.testing.expectEqual(builds, world.builds);
    try std.testing.expectEqual(@as(u64, 1), world.unchanged);
    try std.testing.expectEqual(@as(u32, 0), world.stoneMask(a, 1));
    world.changed(0, 0, bounds);
    world.learnSection(a, 1, 0, .{ .uniform = 0 });
    try std.testing.expectEqual(builds + 1, world.builds);
    try std.testing.expectEqual(@as(u64, 1), world.rebuilds);
    try std.testing.expectEqual(&open_section, world.section(at, 0, 1).?);
    try std.testing.expectEqual(@as(u32, 1), world.skyAir(a, 1));
}

test "bounded outside-world seeding retains sparse missing metadata at a yield" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const radius = 16;
    const side_length = 2 * radius + 1;
    const columns = side_length * side_length;
    var world = try World.init(arena.allocator(), .{ .columns = columns, .sources = 1, .radius = radius });
    const absent = 42;
    for (0..columns) |index| {
        if (index == absent) continue;
        world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % side_length)) - radius, .z = @as(i32, @intCast(index / side_length)) - radius, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 1, .{ 8, 40, 8 }, &source_storage).?;
    world.beginPoll();
    const query = world.query(source, 0, 1, radius);
    const first = world.advance();
    try std.testing.expect(first.progressed);
    try std.testing.expectEqual(@as(usize, 1), first.requests.len);
    try std.testing.expectEqual(chunks.Section{ .world = 0, .x = absent % side_length - radius, .y = 0, .z = absent / side_length - radius }, first.requests[0]);
    for (first.requests) |position| world.learnSection(.{ .world = 0, .x = position.x, .z = position.z, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
    var attempts: usize = 0;
    while (!world.ready(query)) : (attempts += 1) {
        try std.testing.expect(attempts < 128);
        try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    }
    for (0..columns) |index| try std.testing.expectEqual(@as(u32, 1), world.mask(query, @as(i32, @intCast(index % side_length)) - radius, @as(i32, @intCast(index / side_length)) - radius));
}

test "a seeded neighboring component cannot start a disconnected tunnel inside the camera bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 49, .sources = 1, .radius = 3 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var states: [4096]u16 = undefined;
    for (0..49) |column| {
        const cx = @as(i32, @intCast(column % 7)) - 3;
        const cz = @as(i32, @intCast(column / 7)) - 3;
        for (0..4) |sy| {
            for (&states, 0..) |*state, local| {
                const x = cx * 16 + @as(i32, @intCast(local % 16));
                const y = @as(i32, @intCast(sy * 16 + local / 256));
                const z = cz * 16 + @as(i32, @intCast(local / 16 % 16));
                const chamber = x >= 0 and x < 15 and y >= 20 and y < 31 and z >= 4 and z < 13;
                const opening = x >= 0 and x < 32 and y >= 20 and y < 23 and z >= 4 and z < 7;
                const hidden = x >= 16 and x < 64 and y >= 27 and y < 29 and z >= 10 and z < 12;
                state.* = if (chamber or opening or hidden) 0 else stone;
            }
            world.learnSection(.{ .world = 0, .x = cx, .z = cz, .minimum = 0 }, 4, sy, .{ .dense = &states });
        }
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 21, 5 }, &source_storage).?;
    try std.testing.expect(source.cells & (1 << 14) != 0);
    var selected: usize = 0;
    for (source.seeds[14]) |bits| selected += @popCount(bits);
    try std.testing.expectEqual(@as(usize, 1), selected);
    world.beginPoll();
    const query = world.query(source, 0, 4, 3);
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expect(world.mask(query, 2, 0) & 2 != 0);
    try std.testing.expect(world.mask(query, 3, 0) & 2 == 0);
}

test "section queries remain pending on missing metadata and sealed sources cannot disclose distant loaded sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .sources = 3, .radius = 2 });
    var unavailable: Source = undefined;
    try std.testing.expect(world.source(0, 0, 4, .{ 8, 24, 8 }, &unavailable) == null);
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const states = try arena.allocator().alloc(u16, 48 * 48 * 48);
    @memset(states, stone);
    for (4..12) |y| for (4..12) |z| for (4..12) |x| {
        states[y * 48 * 48 + z * 48 + x] = 0;
    };
    var sections: [4]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = stone } });
    for (0..25) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 5)) - 2, .z = @as(i32, @intCast(index / 5)) - 2, .minimum = 0 }, &sections);
    world.changed(0, 0, .{ .minimum = .{ 0, 16, 0 }, .maximum = .{ 16, 32, 16 } });
    sections[1].view = .{ .rows = states };
    world.learn(.{ .world = 0, .x = 0, .z = 0, .minimum = 0 }, &sections);
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    try std.testing.expectEqual(visibility.Bounds{ .minimum = .{ 4, 20, 4 }, .maximum = .{ 12, 28, 12 } }, source.camera_bounds);
    world.beginPoll();
    const handle = world.query(source, 0, 4, 2);
    try std.testing.expect(!world.ready(handle));
    try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expect(world.ready(handle));
    try std.testing.expectEqual(@as(u32, 2), world.mask(handle, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), world.visits);
    const air: [4]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    world.changed(0, 0, .{ .minimum = .{ -32, 0, 32 }, .maximum = .{ -16, 64, 48 } });
    world.learn(.{ .world = 0, .x = -2, .z = 2, .minimum = 0 }, &air);
    world.beginPoll();
    try std.testing.expectEqual(handle, world.query(source, 0, 4, 2));
    try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expect(world.ready(handle));
    try std.testing.expectEqual(@as(u32, 0), world.mask(handle, -2, 2));
}

test "pending section metadata is batched and warmup cannot change a completed visibility set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .sources = 2, .radius = 2 });
    const sections: [4]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..9) |index| world.learn(.{ .world = 7, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &sections);
    var source_storage: Source = undefined;
    const source = world.source(7, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    try std.testing.expect(source.cells & 1 != 0);
    try std.testing.expect(source.supports(7, .{ 14, 20, 1 }));
    world.beginPoll();
    const query = world.query(source, 0, 4, 2);
    const missing = world.advance().requests;
    try std.testing.expect(missing.len > 1);
    try std.testing.expect(!world.ready(query));
    var attempts: usize = 0;
    while (!world.ready(query)) : (attempts += 1) {
        try std.testing.expect(attempts < 64);
        for (world.missing[0..world.missing_count]) |position| world.learnSection(.{ .world = 7, .x = position.x, .z = position.z, .minimum = 0 }, 4, @intCast(position.y), .{ .uniform = 0 });
        _ = world.advance();
    }
    for (0..25) |index| try std.testing.expectEqual(@as(u32, 15), world.mask(query, @as(i32, @intCast(index % 5)) - 2, @as(i32, @intCast(index / 5)) - 2));
    const builds = world.builds;
    const first_revision = world.revision(query);
    world.invalidateResults();
    world.beginPoll();
    try std.testing.expectEqual(query, world.query(source, 0, 4, 2));
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expectEqual(builds, world.builds);
    try std.testing.expectEqual(first_revision + 1, world.revision(query));
    const revision = world.revision(query);
    for (0..25) |index| world.learn(.{ .world = 7, .x = 100 + @as(i32, @intCast(index)), .z = 100, .minimum = 0 }, &sections);
    try std.testing.expect(world.ready(query));
    try std.testing.expectEqual(revision, world.revision(query));
    try std.testing.expectEqual(@as(u32, 15), world.mask(query, 2, 2));
}

test "row classification preserves scalar opacity air and stone flags for every input layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 1, .sources = 1, .radius = 0 });
    var states: [4096]u16 = undefined;
    var bytes: [8193]u8 = undefined;
    const side = 3 * 16;
    const strided = try arena.allocator().alloc(u16, side * side * 16);
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const air: u16 = @intCast(game_data.registry.block_cave_air_default_state);
    const glass: u16 = @intCast(game_data.registry.block_glass_default_state);
    const water: u16 = @intCast(game_data.registry.block_water_default_state);
    for (0..5) |pattern| {
        var expected_solid: [64]u64 = @splat(0);
        var expected_stone = true;
        var expected_air = true;
        for (&states, 0..) |*state, index| {
            state.* = switch (pattern) {
                0 => stone,
                1 => air,
                2 => if (index < 2048) stone else air,
                3 => ([_]u16{ stone, air, glass, water })[index % 4],
                4 => glass,
                else => unreachable,
            };
            if (game_data.physics.rendering(state.*).occluder) expected_solid[index / 64] |= @as(u64, 1) << @intCast(index % 64);
            expected_stone = expected_stone and state.* == stone;
            expected_air = expected_air and game_data.physics.get(state.*).air;
            std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], state.*, .little);
            strided[index / 256 * side * side + index / 16 % 16 * side + index % 16] = state.*;
        }
        const views = [_]lighting.Section.View{ .{ .dense = &states }, .{ .rows = strided }, .{ .chunk = .{ .dense = bytes[1..] } } };
        const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
        for (views) |view| {
            world.changed(0, 0, .{ .minimum = @splat(0), .maximum = @splat(16) });
            world.learnSection(column, 1, 0, view);
            try std.testing.expectEqualSlices(u64, &expected_solid, &world.section(.{ .world = 0, .x = 0, .y = 0, .z = 0 }, 0, 1).?.solid);
            try std.testing.expectEqual(@as(u32, @intFromBool(expected_stone)), world.stoneMask(column, 1));
            try std.testing.expectEqual(@as(u32, @intFromBool(expected_air)), world.skyAir(column, 1));
        }
    }
}

test "palette properties preserve opacity without treating transparent blocks as air" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var projected = try World.init(arena.allocator(), .{ .columns = 1, .sources = 1, .radius = 0 });
    var decoded = try World.init(arena.allocator(), .{ .columns = 1, .sources = 1, .radius = 0 });
    const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    const pairs = [_][2]u16{
        .{ game_data.registry.block_air_default_state, game_data.registry.block_cave_air_default_state },
        .{ game_data.registry.block_water_default_state, game_data.registry.block_glass_default_state },
        .{ game_data.registry.block_stone_default_state, game_data.registry.block_bedrock_default_state },
        .{ game_data.registry.block_stone_default_state, game_data.registry.block_stone_default_state },
        .{ game_data.registry.block_void_air_default_state, game_data.registry.block_void_air_default_state },
    };
    var raw: [chunks.encoding.dense_block_bytes]u8 = undefined;
    var encoded: [raw.len]u8 = undefined;
    raw[0] = 1;
    for (pairs, 0..) |pair, offset| {
        for (0..4096) |index| std.mem.writeInt(u16, raw[1 + index * 2 ..][0..2], pair[index % pair.len], .little);
        const bytes = try chunks.encoding.encode(&raw, &encoded);
        const classification = try chunks.encoding.classify(bytes, projected.properties, occluder_property, .complete);
        try std.testing.expect(projected.learnClassification(column, pairs.len, offset, &classification));
        decoded.learnSection(column, pairs.len, offset, .{ .chunk = .{ .dense = raw[1..] } });
        try std.testing.expectEqualSlices(u64, &decoded.tiles[0].sections[offset].solid, &projected.tiles[0].sections[offset].solid);
        try std.testing.expectEqual(decoded.tiles[0].sections[offset].kind, projected.tiles[0].sections[offset].kind);
    }
    try std.testing.expectEqual(decoded.tiles[0].air, projected.tiles[0].air);
    try std.testing.expectEqual(decoded.tiles[0].stone, projected.tiles[0].stone);
    try std.testing.expectEqual(@as(u32, 17), projected.tiles[0].air);
    try std.testing.expectEqual(@as(u32, 8), projected.tiles[0].stone);
}

test "active column bindings follow metadata eviction and refilling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .sources = 1, .radius = 2 });
    const air: [24]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..24) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 5)) - 2, .z = @as(i32, @intCast(index / 5)) - 2, .minimum = 0 }, &air);
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 24, .{ 8, 24, 8 }, &source_storage).?;
    world.beginPoll();
    const query = world.query(source, 0, 24, 2);
    for (0..16) |_| {
        const advanced = world.advance();
        if (advanced.requests.len != 0) break;
        try std.testing.expect(advanced.progressed and !world.ready(query));
    }
    try std.testing.expect(world.missing_count != 0);
    try std.testing.expect(!world.ready(query));
    const stone: [24]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = @intCast(game_data.registry.block_stone_default_state) } });
    for (0..25) |index| world.learn(.{ .world = 0, .x = 100 + @as(i32, @intCast(index)), .z = 100, .minimum = 0 }, &stone);
    for (0..16) |_| {
        const advanced = world.advance();
        if (advanced.requests.len != 0) break;
        try std.testing.expect(advanced.progressed and !world.ready(query));
    }
    try std.testing.expect(world.missing_count != 0);
    try std.testing.expect(!world.ready(query));
    var attempts: usize = 0;
    while (!world.ready(query)) : (attempts += 1) {
        try std.testing.expect(attempts < 128);
        for (world.missing[0..world.missing_count]) |at| world.learnSection(.{ .world = 0, .x = at.x, .z = at.z, .minimum = 0 }, 24, @intCast(at.y), .{ .uniform = 0 });
        _ = world.advance();
    }
    for (0..25) |index| try std.testing.expectEqual(@as(u32, (1 << 24) - 1), world.mask(query, @as(i32, @intCast(index % 5)) - 2, @as(i32, @intCast(index / 5)) - 2));
}

test "packed source rows preserve a winding path across section and word boundaries" {
    const Reference = struct {
        blocked: [source_volume]bool = @splat(false),
        visited: [source_volume]bool = @splat(false),
        queue: [source_volume]u16 = undefined,
        count: usize = 0,

        fn visit(self: *@This(), index: usize) void {
            if (self.blocked[index] or self.visited[index]) return;
            self.visited[index] = true;
            self.queue[self.count] = @intCast(index);
            self.count += 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .sources = 1, .radius = 1 });
    const states = try arena.allocator().alloc([4096]u16, 27);
    for (states) |*section_states| @memset(section_states, @intCast(game_data.registry.block_stone_default_state));
    const point: [3]i32 = .{ -8, 24, -8 };
    const origin: [3]i32 = .{ -21, 11, -21 };
    var reference: Reference = .{};
    @memset(&reference.blocked, true);
    const path = [_][3]i32{ .{ 13, 13, 13 }, .{ 0, 13, 13 }, .{ 0, 25, 13 }, .{ 0, 25, 25 }, .{ 25, 25, 25 }, .{ 25, 0, 25 }, .{ 25, 0, 0 }, .{ 0, 0, 0 } };
    for (path[1..], 0..) |target, segment| {
        var at = path[segment];
        while (true) {
            const index: usize = @intCast((at[1] * source_side + at[2]) * source_side + at[0]);
            reference.blocked[index] = false;
            const position = [3]i32{ at[0] + origin[0], at[1] + origin[1], at[2] + origin[2] };
            const section: usize = @intCast((@divFloor(position[2], 16) + 2) * 9 + @divFloor(position[1], 16) * 3 + @divFloor(position[0], 16) + 2);
            const voxel: usize = @intCast(@mod(position[1], 16) * 256 + @mod(position[2], 16) * 16 + @mod(position[0], 16));
            states[section][voxel] = 0;
            if (std.meta.eql(at, target)) break;
            for (0..3) |axis| if (at[axis] != target[axis]) {
                at[axis] += if (at[axis] < target[axis]) @as(i32, 1) else -1;
            };
        }
    }
    for (states, 0..) |*section_states, index| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 2, .z = @as(i32, @intCast(index / 9)) - 2, .minimum = 0 }, 3, index / 3 % 3, .{ .dense = section_states });
    reference.visit((13 * source_side + 13) * source_side + 13);
    var head: usize = 0;
    while (head < reference.count) : (head += 1) {
        const index = reference.queue[head];
        const local: [3]usize = .{ index % source_side, index / (source_side * source_side), index / source_side % source_side };
        for (0..3) |axis| {
            const stride = [_]usize{ 1, source_side * source_side, source_side };
            if (local[axis] != 0) reference.visit(index - stride[axis]);
            if (local[axis] + 1 < source_side) reference.visit(index + stride[axis]);
        }
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 3, point, &source_storage).?;
    var expected_bounds: visibility.Bounds = .{ .minimum = point, .maximum = point };
    var expected_cells: u32 = 0;
    var expected_membership: [64]u64 = @splat(0);
    for (reference.visited, 0..) |visited, index| {
        if (!visited) continue;
        const position: [3]i32 = .{ origin[0] + @as(i32, @intCast(index % source_side)), origin[1] + @as(i32, @intCast(index / (source_side * source_side))), origin[2] + @as(i32, @intCast(index / source_side % source_side)) };
        for (0..3) |axis| {
            expected_bounds.minimum[axis] = @min(expected_bounds.minimum[axis], position[axis]);
            expected_bounds.maximum[axis] = @max(expected_bounds.maximum[axis], position[axis] + 1);
        }
        const cell: usize = @intCast((@divFloor(position[2], 16) + 2) * 9 + @divFloor(position[1], 16) * 3 + @divFloor(position[0], 16) + 2);
        expected_cells |= @as(u32, 1) << @intCast(cell);
        if (cell != 13) continue;
        const voxel: usize = @intCast(@mod(position[1], 16) * 256 + @mod(position[2], 16) * 16 + @mod(position[0], 16));
        expected_membership[voxel / 64] |= @as(u64, 1) << @intCast(voxel % 64);
    }
    try std.testing.expectEqualDeep(expected_bounds, source.camera_bounds);
    try std.testing.expectEqual(expected_cells, source.cells);
    try std.testing.expectEqualSlices(u64, &expected_membership, &source.membership);
}

test "observers outside the world see its boundary without exposing buried sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .sources = 3, .radius = 1 });
    const sections: [2]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = @intCast(game_data.registry.block_stone_default_state) } });
    for (0..9) |index| world.learn(.{ .world = 7, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &sections);
    for ([_]i32{ -32, 64 }) |y| {
        var source_storage: Source = undefined;
        const source = world.source(7, 0, 2, .{ 8, y, 8 }, &source_storage).?;
        world.beginPoll();
        const query = world.query(source, 0, 2, 1);
        while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        for (0..9) |index| try std.testing.expectEqual(@as(u32, if (y < 0) 1 else 2), world.mask(query, @as(i32, @intCast(index % 3)) - 1, @as(i32, @intCast(index / 3)) - 1));
    }
}

test "a diagonal tunnel can cross a source-aligned column beyond the camera margin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -2, -6, -2 }, .size = .{ 5, 8, 5 } };
    const states = try arena.allocator().alloc([4096]u16, grid.count());
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    for (states) |*section_states| @memset(section_states, stone);
    var y: i32 = -80;
    while (y <= 8) : (y += 1) {
        const x = 8 + @divFloor((8 - y) * 16, 88);
        for ([_]i32{ x, x + 1 }) |column| {
            const index = grid.index(.{ @divFloor(column, 16), @divFloor(y, 16), 0 }).?;
            states[index][@intCast(@mod(y, 16) * 256 + 8 * 16 + @mod(column, 16))] = 0;
        }
    }
    var world = try World.init(arena.allocator(), .{ .columns = 25, .sources = 1, .radius = 2 });
    for (states, 0..) |*section_states, index| {
        const at = grid.position(index);
        world.learnSection(.{ .world = 0, .x = at[0], .z = at[2], .minimum = -6 }, 8, @intCast(at[1] + 6), .{ .dense = section_states });
    }
    var source_storage: Source = undefined;
    const source = world.source(0, -6, 8, .{ 8, 8, 8 }, &source_storage).?;
    world.beginPoll();
    const query = world.query(source, -6, 8, 2);
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expect(world.mask(query, 1, 0) & 2 != 0);
}

test "interior edits retain cached visibility and boundary edits invalidate it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .sources = 2, .radius = 1 });
    const sections: [4]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..9) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &sections);
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    world.beginPoll();
    const query = world.query(source, 0, 4, 1);
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    const revision = world.revision(query);
    const visits = world.visits;
    var states: [4096]u16 = @splat(0);
    const column: Column = .{ .world = 0, .x = 1, .z = 1, .minimum = 0 };
    for ([_]u16{ @intCast(game_data.registry.block_stone_default_state), 0 }) |state| {
        world.changed(0, 0, .{ .minimum = .{ 30, 56, 30 }, .maximum = .{ 31, 57, 31 } });
        states[8 * 256 + 14 * 16 + 14] = state;
        world.learnSection(column, 4, 3, .{ .dense = &states });
        try std.testing.expect(world.ready(query));
        try std.testing.expectEqual(revision, world.revision(query));
        try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        try std.testing.expectEqual(visits, world.visits);
    }
    world.changed(0, 0, .{ .minimum = .{ 31, 56, 30 }, .maximum = .{ 32, 57, 31 } });
    states[8 * 256 + 14 * 16 + 15] = @intCast(game_data.registry.block_stone_default_state);
    world.learnSection(column, 4, 3, .{ .dense = &states });
    try std.testing.expect(!world.ready(query));
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expectEqual(revision + 1, world.revision(query));
}

test "camera apertures reject a backtracking passage and interior edits invalidate its result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .sources = 1, .radius = 2 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var states: [4096]u16 = undefined;
    const Shape = struct {
        fn open(x: i32, y: i32, z: i32) bool {
            const room = ((x >= 0 and x < 16) or (x >= 32 and x < 48)) and y >= 4 and y < 12 and z >= 0 and z < 16;
            const local = x - 16;
            const first = local >= 0 and local < 13 and z >= 3 and z < 5;
            const turn = local >= 11 and local < 13 and z >= 3 and z < 11;
            const returning = local >= 7 and local < 13 and z >= 9 and z < 11;
            const bend = local >= 7 and local < 9 and z >= 9 and z < 15;
            const exit = local >= 7 and local < 16 and z >= 13 and z < 15;
            const passage = y >= 8 and y < 10 and (first or turn or returning or bend or exit);
            const straight = local >= 0 and local < 16 and y >= 12 and y < 14 and z >= 3 and z < 5;
            const bridge = local >= 7 and local < 9 and y >= 12 and y < 14 and z >= 3 and z < 11;
            const connector = local >= 7 and local < 9 and y >= 10 and y < 14 and z >= 9 and z < 11;
            return room or passage or straight or bridge or connector;
        }
    };
    for (0..25) |column| for (0..3) |section| {
        const cx = @as(i32, @intCast(column % 5)) - 2;
        const cz = @as(i32, @intCast(column / 5)) - 2;
        const cy = @as(i32, @intCast(section)) - 1;
        for (&states, 0..) |*state, local| {
            state.* = if (Shape.open(cx * 16 + @as(i32, @intCast(local % 16)), cy * 16 + @as(i32, @intCast(local / 256)), cz * 16 + @as(i32, @intCast(local / 16 % 16)))) 0 else stone;
        }
        world.learnSection(.{ .world = 0, .x = cx, .z = cz, .minimum = -1 }, 3, section, .{ .dense = &states });
    };
    var source_storage: Source = undefined;
    const source = world.source(0, -1, 3, .{ 8, 8, 4 }, &source_storage).?;
    world.beginPoll();
    const query = world.query(source, -1, 3, 2);
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expectEqual(@as(u32, 0), world.mask(query, 2, 0) & 2);
    for ([_]bool{ true, false }) |shortcut| {
        const before = world.section(.{ .world = 0, .x = 1, .y = 0, .z = 0 }, -1, 3).?;
        const connections = before.connections;
        const blocked_pairs = before.blocked_pairs;
        const solid = before.solid;
        const revision = world.revision(query);
        for (&states, 0..) |*state, local| {
            const x = @as(i32, @intCast(local % 16));
            const y = @as(i32, @intCast(local / 256));
            const z = @as(i32, @intCast(local / 16 % 16));
            const opened = shortcut and x >= 5 and x < 15 and y >= 8 and y < 10 and z >= 3 and z < 15;
            state.* = if (opened or Shape.open(16 + x, y, z)) 0 else stone;
        }
        world.changed(0, -1, .{ .minimum = .{ 21, 8, 3 }, .maximum = .{ 31, 10, 15 } });
        world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = -1 }, 3, 1, .{ .dense = &states });
        const after = world.section(.{ .world = 0, .x = 1, .y = 0, .z = 0 }, -1, 3).?;
        try std.testing.expectEqual(@as(u16, 1), after.components);
        try std.testing.expectEqual(connections, after.connections);
        try std.testing.expectEqual(blocked_pairs, after.blocked_pairs);
        try std.testing.expect(!after.boundaryChanged(&solid));
        try std.testing.expect(!world.ready(query));
        while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        try std.testing.expectEqual(revision + 1, world.revision(query));
        try std.testing.expectEqual(shortcut, world.mask(query, 2, 0) & 2 != 0);
    }
}

test "interior sightline changes invalidate disclosure while boundary openings stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 49, .sources = 1, .radius = 3 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var states: [4096]u16 = undefined;
    for (0..49) |column| for (0..4) |section| {
        const cx = @as(i32, @intCast(column % 7)) - 4;
        const cz = @as(i32, @intCast(column / 7)) - 3;
        for (&states, 0..) |*state, index| {
            const x = cx * 16 + @as(i32, @intCast(index % 16));
            const y = @as(i32, @intCast(section * 16 + index / 256));
            const z = cz * 16 + @as(i32, @intCast(index / 16 % 16));
            const room = ((x >= -16 and x < 0) or (x >= 32 and x < 48)) and y >= 16 and y < 32 and z >= 0 and z < 16;
            const passage = x >= 0 and x < 32 and y >= 24 and y < 26;
            const tunnel = if (x < 19 or x >= 29) z >= 7 and z < 9 else if (x < 22 or x >= 26) z >= 7 and z < 15 else z >= 13 and z < 15;
            state.* = if (room or (passage and tunnel)) 0 else stone;
        }
        world.learnSection(.{ .world = 0, .x = cx, .z = cz, .minimum = 0 }, 4, section, .{ .dense = &states });
    };
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ -8, 24, 8 }, &source_storage).?;
    world.beginPoll();
    const query = world.query(source, 0, 4, 3);
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expectEqual(@as(u32, 0), world.mask(query, 2, 0) & 2);
    const tunnel_section: chunks.Section = .{ .world = 0, .x = 1, .y = 1, .z = 0 };
    for ([_]bool{ true, false }) |straight| {
        const previous = world.section(tunnel_section, 0, 4).?.*;
        const revision = world.revision(query);
        var solid: [64]u64 = @splat(0);
        for (&states, 0..) |*state, index| {
            const x = index % 16;
            const y = index / 256;
            const z = index / 16 % 16;
            const tunnel = if (straight or x < 3 or x >= 13) z >= 7 and z < 9 else if (x < 6 or x >= 10) z >= 7 and z < 15 else z >= 13 and z < 15;
            const air = y >= 8 and y < 10 and tunnel;
            state.* = if (air) 0 else stone;
            if (!air) solid[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        }
        try std.testing.expect(!previous.boundaryChanged(&solid));
        world.changed(0, 0, .{ .minimum = .{ 16, 16, 0 }, .maximum = .{ 32, 32, 16 } });
        world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, 4, 1, .{ .dense = &states });
        try std.testing.expectEqual(previous.connections, world.section(tunnel_section, 0, 4).?.connections);
        try std.testing.expect(!world.ready(query));
        while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        try std.testing.expectEqual(revision + 1, world.revision(query));
        try std.testing.expectEqual(if (straight) @as(u32, 2) else 0, world.mask(query, 2, 0) & 2);
    }
}

test "disconnected openings inside one portal tile cannot disclose the tunnel behind their gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 49, .sources = 1, .radius = 3 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const sections: [4]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = stone } });
    for (0..49) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 7)) - 3, .z = @as(i32, @intCast(index / 7)) - 3, .minimum = 0 }, &sections);
    var states: [4096]u16 = undefined;
    for (0..3) |column| {
        for (&states, 0..) |*state, local| {
            const x = local % 16;
            const y = local / 256;
            const z = local / 16 % 16;
            const openings = (y == 4 and z == 4) or (y == 7 and z == 7);
            const concealed = y == 7 and z == 4;
            const air = switch (column) {
                0 => x < 15 or openings,
                1 => (x < 4 and openings) or concealed,
                2 => concealed,
                else => unreachable,
            };
            state.* = if (air) 0 else stone;
        }
        const x: i32 = @intCast(column);
        world.changed(0, 0, .{ .minimum = .{ x * 16, 16, 0 }, .maximum = .{ x * 16 + 16, 32, 16 } });
        world.learnSection(.{ .world = 0, .x = x, .z = 0, .minimum = 0 }, 4, 1, .{ .dense = &states });
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    world.beginPoll();
    const query = world.query(source, 0, 4, 3);
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expect(world.mask(query, 1, 0) & 2 != 0);
    try std.testing.expectEqual(@as(u32, 0), world.mask(query, 2, 0) & 2);
}

test "disconnected tunnels sharing section faces cannot disclose each other's surface exits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -4, 0, -4 }, .size = .{ 9, 4, 9 } };
    var world = try World.init(arena.allocator(), .{ .columns = 81, .sources = 1, .radius = 4 });
    var states: [4096]u16 = undefined;
    for (0..grid.count()) |index| {
        const at = grid.position(index);
        for (&states, 0..) |*state, local| {
            const x = at[0] * 16 + @as(i32, @intCast(local % 16));
            const y = at[1] * 16 + @as(i32, @intCast(local / 256));
            const z = at[2] * 16 + @as(i32, @intCast(local / 16 % 16));
            const tunnel = x >= 4 and z >= 4 and z < 12 and ((y >= 20 and y < 24) or (y >= 28 and y < 32) or (x >= 48 and x < 56 and y >= 28));
            state.* = if (y >= 40 or tunnel) 0 else @intCast(game_data.registry.block_stone_default_state);
        }
        world.learnSection(.{ .world = 0, .x = at[0], .z = at[2], .minimum = 0 }, 4, @intCast(at[1]), .{ .dense = &states });
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 21, 8 }, &source_storage).?;
    try std.testing.expectEqual(@as(i32, 24), source.camera_bounds.maximum[1]);
    world.beginPoll();
    const query = world.query(source, 0, 4, 4);
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expect(world.mask(query, 3, 0) & 2 != 0);
    for (0..81) |column| try std.testing.expectEqual(@as(u32, 0), world.mask(query, @as(i32, @intCast(column % 9)) - 4, @as(i32, @intCast(column / 9)) - 4) & 12);
    const connections = world.section(.{ .world = 0, .x = 3, .y = 1, .z = 0 }, 0, 4).?.connections;
    const revision = world.revision(query);
    for (&states, 0..) |*state, local| {
        const x = local % 16;
        const y = local / 256 + 16;
        const z = local / 16 % 16;
        const tunnel = z >= 4 and z < 12 and ((y >= 20 and y < 24) or y >= 28);
        const opening = x == 4 and z == 8 and y >= 24 and y < 28;
        state.* = if (tunnel or opening) 0 else @intCast(game_data.registry.block_stone_default_state);
    }
    world.changed(0, 0, .{ .minimum = .{ 52, 24, 8 }, .maximum = .{ 53, 28, 9 } });
    world.learnSection(.{ .world = 0, .x = 3, .z = 0, .minimum = 0 }, 4, 1, .{ .dense = &states });
    try std.testing.expectEqual(connections, world.section(.{ .world = 0, .x = 3, .y = 1, .z = 0 }, 0, 4).?.connections);
    try std.testing.expect(!world.ready(query));
    while (!world.ready(query)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expectEqual(revision + 1, world.revision(query));
}
