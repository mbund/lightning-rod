const vanilla_definitions = @import("vanilla_content.zig");
const Blocks = @import("blocks.zig").Blocks;
const std = @import("std");
const builtin = @import("builtin");
const lighting = @import("lighting");
const game_data = @import("game_data");
const chunks = @import("chunks");
const worlds = @import("worlds");
const wire_1_21_5 = @import("wire_1_21_5");
const storage = @import("storage");
const metrics = @import("metrics");
const records = @import("records");
const Generation = @import("generation.zig").Generation;
const assert = std.debug.assert;

pub const maximum_sections = 24;
const side = 48;
const height = (maximum_sections + 2) * 16;

pub const Stamp = struct { generation: u64 = 0, revision: u64 = 0, index: usize = 0 };

pub const Section = struct {
    pub const View = union(enum) {
        uniform: u16,
        rows: []const u16,

        pub fn get(self: View, index: u12) u16 {
            return switch (self) {
                .uniform => |state| state,
                .rows => |states| states[@as(usize, index / 256) * side * side + @as(usize, index / 16 % 16) * side + index % 16],
            };
        }
    };
    stamp: Stamp,
    view: View,
};

/// Each owner has a separate workspace. Chunk leases protect the input snapshot.
pub const Workspace = struct {
    const Region = struct { world: u32, x: i32, z: i32, minimum: i32, count: usize, skylight: bool };

    pub const Work = struct {
        acquired_sections: u64 = 0,
        decoded_sections: u64 = 0,
        retained_columns: u64 = 0,
        retained_sections: u64 = 0,
        relights: u64 = 0,
        updates: u64 = 0,
    };

    work: Work = .{},
    engine: lighting.Engine,
    states: []u16,
    region: ?Region = null,
    pending: ?Region = null,
    watch: *chunks.Watch,
    versions: [9 * maximum_sections]u64 = @splat(0),
    copied: [9 * maximum_sections]bool = @splat(false),
    masks: [2]u32 = .{ 0, 0 },
    stamps: [9 * maximum_sections]Stamp = @splat(.{}),
    dirty: [9 * maximum_sections]bool = @splat(false),
    uniforms: [9 * maximum_sections]?u16 = @splat(null),
    section_views: [maximum_sections]Section = undefined,

    pub fn init(allocator: std.mem.Allocator, terrain: *chunks.Chunks, registry: lighting.Registry) !*Workspace {
        const self = try allocator.create(Workspace);
        self.* = .{
            .watch = try chunks.Watch.init(allocator, terrain, 9 * maximum_sections),
            .engine = try lighting.Engine.init(allocator, .{ .x = side, .y = height, .z = side }, registry),
            .states = try allocator.alloc(u16, side * height * side),
        };
        return self;
    }

    pub fn current(self: *const Workspace, terrain: *const chunks.Chunks, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension) bool {
        const region = self.region orelse return false;
        assert(self.watch.owner == terrain);
        for (0..9) |column| for (0..region.count) |section| {
            const at = column * maximum_sections + section;
            if (!self.copied[at] or self.versions[at] != self.watch.revision(column * region.count + section)) return false;
        };
        return self.pending == null and
            region.world == world and region.x == x and region.z == z and region.minimum == dimension.minimumSection() and
            region.count == dimension.sectionCount() and region.skylight == dimension.skylight;
    }

    pub fn prepare(self: *Workspace, terrain: *chunks.Chunks, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, player: usize) !bool {
        return self.prepareMode(terrain, world, x, z, dimension, player, .background);
    }

    const Access = enum { background, required };

    fn prepareMode(self: *Workspace, terrain: *chunks.Chunks, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, player: usize, access: Access) !bool {
        const count = dimension.sectionCount();
        if (count == 0 or count > maximum_sections) return error.UnsupportedLightingHeight;
        const region: Region = .{ .world = world, .x = x, .z = z, .minimum = dimension.minimumSection(), .count = count, .skylight = dimension.skylight };
        assert(self.watch.owner == terrain);
        const same = if (self.region) |previous| std.meta.eql(previous, region) else false;
        if (same and self.current(terrain, world, x, z, dimension)) return true;
        const continuing = if (self.pending) |previous| std.meta.eql(previous, region) else same;
        if (!continuing) {
            const watched: chunks.Watch.Region = .{
                .world = world,
                .minimum = .{ .x = try std.math.sub(i32, x, 1), .y = region.minimum, .z = try std.math.sub(i32, z, 1) },
                .maximum = .{ .x = try std.math.add(i32, x, 1), .y = try std.math.add(i32, region.minimum, @as(i32, @intCast(count)) - 1), .z = try std.math.add(i32, z, 1) },
            };
            var previous: [9 * maximum_sections]u64 = undefined;
            self.watch.configure(watched, &previous);
            self.move(region, previous);
            self.region = null;
        }
        const reuse = self.region != null;
        self.pending = region;
        // Ready sections transfer independently so demand traffic cannot starve a whole column.
        for (0..9) |column| {
            var positions: [maximum_sections]chunks.Section = undefined;
            var leases: [maximum_sections]chunks.Lease = undefined;
            var requests: [maximum_sections]chunks.Chunks.Preparation = undefined;
            var indices: [maximum_sections]usize = undefined;
            var ready: [maximum_sections]bool = undefined;
            const cx = try std.math.add(i32, x, @as(i32, @intCast(column % 3)) - 1);
            const cz = try std.math.add(i32, z, @as(i32, @intCast(column / 3)) - 1);
            var needed: usize = 0;
            for (0..count) |section| {
                const at = column * maximum_sections + section;
                if (self.versions[at] != self.watch.revision(column * count + section)) self.copied[at] = false;
                if (self.copied[at]) continue;
                indices[needed] = section;
                positions[needed] = .{ .world = world, .x = cx, .y = region.minimum + @as(i32, @intCast(section)), .z = cz };
                requests[needed] = .{ .sections = positions[needed..][0..1], .leases = leases[needed..][0..1], .priority = .{ .urgency = .streaming, .player = player } };
                needed += 1;
            }
            if (needed == 0) continue;
            switch (access) {
                .background => try terrain.prepareMany(requests[0..needed], ready[0..needed]),
                .required => {
                    var begin: usize = 0;
                    while (begin < needed) {
                        const end = begin + @min(needed - begin, @max(1, terrain.demand_sections));
                        const held = leases[begin..end];
                        try terrain.acquireMany(positions[begin..end], held);
                        defer terrain.releaseMany(held);
                        self.capture(column, count, reuse, held, indices[begin..end]);
                        begin = end;
                    }
                    continue;
                },
            }
            var held: usize = 0;
            for (ready[0..needed], 0..) |complete, index| if (complete) {
                leases[held] = leases[index];
                indices[held] = indices[index];
                held += 1;
            };
            defer terrain.releaseMany(leases[0..held]);
            self.capture(column, count, reuse, leases[0..held], indices[0..held]);
        }
        var complete = true;
        for (0..9) |column| for (0..count) |section| {
            const at = column * maximum_sections + section;
            if (self.versions[at] != self.watch.revision(column * count + section)) self.copied[at] = false;
            complete = complete and self.copied[at];
        };
        if (!complete) return false;
        if (!reuse) {
            var air = true;
            for (0..9) |column| for (0..count) |section| {
                air = air and self.uniforms[column * maximum_sections + section] == 0;
            };
            try self.engine.load(if (air) .{ .uniform = 0 } else .{ .dense = self.states });
            self.engine.relight(dimension.skylight);
            self.work.relights += 1;
        } else {
            var edits: [lighting.batch_max]lighting.Edit = undefined;
            var used: usize = 0;
            for (0..9) |column| for (0..count) |section| {
                if (!self.dirty[column * maximum_sections + section]) continue;
                for (0..4096) |local| {
                    const index = stateIndex(column, section, local);
                    const state = self.states[index];
                    if (self.engine.blockState(index) == state) continue;
                    edits[used] = .{ .index = index, .state = state };
                    used += 1;
                    if (used == edits.len) {
                        try self.engine.update(&edits);
                        self.work.updates += 1;
                        used = 0;
                    }
                }
            };
            if (used != 0) {
                try self.engine.update(edits[0..used]);
                self.work.updates += 1;
            }
        }
        @memset(&self.dirty, false);
        self.region = region;
        self.pending = null;
        for (self.section_views[0..count], 0..) |*section, y| {
            const at = 4 * maximum_sections + y;
            section.* = .{ .stamp = self.stamps[at], .view = if (self.uniforms[at]) |state| .{ .uniform = state } else .{ .rows = self.states[stateIndex(4, y, 0)..] } };
        }
        self.masks = .{ 0, 0 };
        for (0..region.count + 2) |section| {
            inline for (.{ lighting.Layer.block, lighting.Layer.sky }, 0..) |layer, index| {
                if (self.engine.sectionNonempty(layer, .{ 1, section, 1 })) self.masks[index] |= @as(u32, 1) << @intCast(section);
            }
        }
        return true;
    }

    fn capture(self: *Workspace, column: usize, count: usize, reuse: bool, leases: []const chunks.Lease, indices: []const usize) void {
        assert(leases.len == indices.len);
        self.work.acquired_sections += leases.len;
        for (leases, indices) |lease, section| {
            const at = column * maximum_sections + section;
            self.versions[at] = self.watch.revision(column * count + section);
            const stamp: Stamp = .{ .index = lease.record.index, .generation = lease.record.generation, .revision = lease.record.revision() };
            if (!reuse or !std.meta.eql(stamp, self.stamps[at])) {
                const view = lease.view();
                self.copy(column, section, view);
                self.uniforms[at] = if (view == .uniform) view.uniform else null;
                self.work.decoded_sections += 1;
                self.stamps[at] = stamp;
                self.dirty[at] = true;
            }
            self.copied[at] = true;
        }
    }

    fn move(self: *Workspace, target: Region, revisions: [9 * maximum_sections]u64) void {
        const previous = self.pending orelse self.region;
        const copied = self.copied;
        const versions = self.versions;
        const stamps = self.stamps;
        const uniforms = self.uniforms;
        @memset(&self.copied, false);
        @memset(&self.versions, 0);
        @memset(&self.stamps, .{});
        @memset(&self.dirty, false);
        @memset(&self.uniforms, null);
        const old = previous orelse {
            @memset(self.states, 0);
            return;
        };
        const dx = @as(i64, target.x) - old.x;
        const dz = @as(i64, target.z) - old.z;
        if (old.world != target.world or old.minimum != target.minimum or old.count != target.count or old.skylight != target.skylight or @abs(dx) >= 3 or @abs(dz) >= 3) {
            @memset(self.states, 0);
            return;
        }
        const shift_x: i32 = @intCast(dx * 16);
        const shift_z: i32 = @intCast(dz * 16);
        const source_x: usize = @intCast(@max(shift_x, 0));
        const destination_x: usize = @intCast(@max(-shift_x, 0));
        const width = side - @abs(shift_x);
        for (0..height) |y| for (0..side) |row| {
            const z = if (shift_z < 0) side - 1 - row else row;
            const source_z = @as(i32, @intCast(z)) + shift_z;
            const destination = self.states[(y * side + z) * side ..][0..side];
            if (source_z < 0 or source_z >= side) {
                @memset(destination, 0);
                continue;
            }
            const source = self.states[(y * side + @as(usize, @intCast(source_z))) * side + source_x ..][0..width];
            if (shift_x < 0) std.mem.copyBackwards(u16, destination[destination_x..][0..width], source) else std.mem.copyForwards(u16, destination[destination_x..][0..width], source);
            @memset(destination[0..destination_x], 0);
            @memset(destination[destination_x + width ..], 0);
        };
        for (0..9) |column| {
            const x = @as(i64, @intCast(column % 3)) + dx;
            const z = @as(i64, @intCast(column / 3)) + dz;
            if (x < 0 or x >= 3 or z < 0 or z >= 3) continue;
            const from: usize = @intCast(z * 3 + x);
            var all = true;
            for (0..target.count) |section| {
                const source = from * maximum_sections + section;
                const destination = column * maximum_sections + section;
                if (!copied[source] or versions[source] != revisions[from * old.count + section]) {
                    all = false;
                    continue;
                }
                self.copied[destination] = true;
                self.stamps[destination] = stamps[source];
                self.uniforms[destination] = uniforms[source];
                self.work.retained_sections += 1;
            }
            self.work.retained_columns += @intFromBool(all);
        }
    }

    fn copy(self: *Workspace, column: usize, section: usize, view: chunks.View) void {
        for (0..256) |row| {
            const begin = stateIndex(column, section, row * 16);
            if (view == .uniform) {
                @memset(self.states[begin..][0..16], view.uniform);
            } else if (builtin.cpu.arch.endian() == .little) {
                @memcpy(std.mem.sliceAsBytes(self.states[begin..][0..16]), view.dense[row * 32 ..][0..32]);
            } else {
                for (self.states[begin..][0..16], 0..) |*state, x| state.* = view.get(@intCast(row * 16 + x));
            }
        }
    }

    /// Blocks and light share the same snapshot and remain borrowed until the next prepare.
    pub fn sections(self: *const Workspace) []const Section {
        assert(self.pending == null and self.engine.lit);
        return self.section_views[0..self.region.?.count];
    }

    pub fn data(self: *const Workspace) Data {
        assert(self.pending == null and self.engine.lit);
        const region = self.region.?;
        return .{ .engine = &self.engine, .count = region.count + 2, .masks = self.masks };
    }
};

pub const Sample = packed struct(u8) { block: u4, sky: u4 };

pub const Lighting = struct {
    pub const id = "minecraft:lighting";
    pub const Configuration = struct { cache_columns: usize = 16 };
    pub const Dependencies = struct { blocks: *Blocks, chunks: *chunks.Chunks, worlds: *worlds.Worlds };
    const batch_max = 256;
    const Key = struct { x: i32, z: i32 };
    const Entry = struct {
        region: ?Workspace.Region = null,
        building: bool = false,
        watch: *chunks.Watch,
        levels: [2][maximum_sections][2048]u8 = undefined,
    };

    deps: Dependencies,
    background: *Workspace,
    simulation: *Workspace,
    entries: []Entry,
    mutex: std.Io.Mutex = .init,
    groups: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Lighting {
        if (config.cache_columns == 0) return error.InvalidLightingCapacity;
        const registry = deps.blocks.light;
        const self = try allocator.create(Lighting);
        self.* = .{
            .deps = deps,
            .background = try Workspace.init(allocator, deps.chunks, registry),
            .simulation = try Workspace.init(allocator, deps.chunks, registry),
            .entries = try allocator.alloc(Entry, config.cache_columns),
        };
        for (self.entries) |*entry| entry.* = .{ .watch = try chunks.Watch.init(allocator, deps.chunks, 9 * maximum_sections) };
        try self.groups.ensureTotalCapacity(allocator, batch_max);
        try deps.blocks.registry.onChange(self, definitionsChanged);
        return self;
    }

    fn definitionsChanged(self: *Lighting) !void {
        for ([_]*Workspace{ self.background, self.simulation }) |workspace| {
            workspace.engine.registry = self.deps.blocks.light;
            workspace.region = null;
            workspace.pending = null;
            @memset(&workspace.copied, false);
        }
        for (self.entries) |*entry| {
            entry.region = null;
            entry.building = false;
        }
    }

    pub fn prepare(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, player: usize) !bool {
        if (self.background.current(self.deps.chunks, world, x, z, dimension)) return true;
        if (!try self.background.prepare(self.deps.chunks, world, x, z, dimension, player)) return false;
        self.publish(self.background);
        return true;
    }

    /// Simulation-only. Includes preceding edits and preserves input order.
    /// A cold neighborhood synchronously reads or generates its missing chunks.
    /// Skylight is raw propagation light. Time and weather belong to the caller.
    pub fn sampleMany(self: *Lighting, world: u32, positions: []const chunks.Position, output: []Sample) !void {
        assert(positions.len == output.len);
        const definition = self.deps.worlds.get(world) orelse return error.UnknownWorld;
        const dimension = definition.dimension;
        if (dimension.sectionCount() == 0 or dimension.sectionCount() > maximum_sections) return error.UnsupportedLightingHeight;
        const bottom = @as(i64, dimension.minimumSection()) * 16;
        const top = bottom + @as(i64, dimension.section_count) * 16;
        for (positions) |position| {
            if (position.y < bottom or position.y >= top) return error.InvalidLightingPosition;
        }
        var begin: usize = 0;
        while (begin < positions.len) {
            const end = begin + @min(batch_max, positions.len - begin);
            const points = positions[begin..end];
            const samples = output[begin..end];
            self.groups.clearRetainingCapacity();
            var next: [batch_max]usize = undefined;
            for (points, 0..) |position, index| {
                const found = self.groups.getOrPutAssumeCapacity(.{ .x = @divFloor(position.x, 16), .z = @divFloor(position.z, 16) });
                next[index] = if (found.found_existing) found.value_ptr.* else points.len;
                found.value_ptr.* = index;
            }
            var iterator = self.groups.iterator();
            while (iterator.next()) |group| {
                const region: Workspace.Region = .{ .world = world, .x = group.key_ptr.x, .z = group.key_ptr.z, .minimum = dimension.minimumSection(), .count = dimension.sectionCount(), .skylight = dimension.skylight };
                if (self.read(region, points, samples, &next, group.value_ptr.*)) {
                    self.cache_hits += 1;
                    continue;
                }
                self.cache_misses += 1;
                const complete = try self.simulation.prepareMode(self.deps.chunks, world, region.x, region.z, dimension, 0, .required);
                assert(complete);
                var index = group.value_ptr.*;
                while (index != points.len) : (index = next[index]) {
                    const position = points[index];
                    const local: usize = @intCast((@as(i64, position.y) - bottom) * 256 + @mod(position.z, 16) * 16 + @mod(position.x, 16));
                    const at = stateIndex(4, local / 4096, local % 4096);
                    samples[index] = .{ .block = self.simulation.engine.get(.block, at), .sky = self.simulation.engine.get(.sky, at) };
                }
                self.publish(self.simulation);
            }
            begin = end;
        }
    }

    fn read(self: *Lighting, region: Workspace.Region, positions: []const chunks.Position, output: []Sample, next: *const [batch_max]usize, first: usize) bool {
        self.mutex.lockUncancelable(self.deps.chunks.io);
        defer self.mutex.unlock(self.deps.chunks.io);
        for (self.entries) |*entry| {
            if (entry.building or entry.region == null or !std.meta.eql(entry.region.?, region) or !entry.watch.unchanged()) continue;
            var index = first;
            while (index != positions.len) : (index = next[index]) {
                const position = positions[index];
                const y: usize = @intCast(@as(i64, position.y) - @as(i64, region.minimum) * 16);
                const local: usize = y % 16 * 256 + @as(usize, @intCast(@mod(position.z, 16))) * 16 + @as(usize, @intCast(@mod(position.x, 16)));
                const shift: u3 = @intCast(local % 2 * 4);
                output[index] = .{ .block = @truncate(entry.levels[0][y / 16][local / 2] >> shift), .sky = @truncate(entry.levels[1][y / 16][local / 2] >> shift) };
            }
            return true;
        }
        return false;
    }

    fn publish(self: *Lighting, workspace: *const Workspace) void {
        const region = workspace.region.?;
        self.mutex.lockUncancelable(self.deps.chunks.io);
        var chosen: ?*Entry = null;
        for (self.entries) |*entry| {
            if (entry.building or entry.region == null or !std.meta.eql(entry.region.?, region)) continue;
            if (entry.watch.unchanged()) {
                self.mutex.unlock(self.deps.chunks.io);
                return;
            }
            chosen = entry;
            break;
        }
        if (chosen == null) {
            for (0..self.entries.len) |offset| {
                const at = (self.cursor + offset) % self.entries.len;
                if (!self.entries[at].building) {
                    chosen = &self.entries[at];
                    self.cursor = (at + 1) % self.entries.len;
                    break;
                }
            }
        }
        if (chosen) |entry| entry.building = true;
        self.mutex.unlock(self.deps.chunks.io);
        const entry = chosen orelse return;
        var versions: [9 * maximum_sections]u64 = undefined;
        for (0..9) |column| for (0..region.count) |section| {
            versions[column * region.count + section] = workspace.versions[column * maximum_sections + section];
        };
        const valid = entry.watch.capture(workspace.watch, versions[0 .. 9 * region.count]);
        if (valid) {
            for (0..region.count) |section| {
                workspace.engine.packSection(.block, .{ 1, section + 1, 1 }, &entry.levels[0][section]);
                workspace.engine.packSection(.sky, .{ 1, section + 1, 1 }, &entry.levels[1][section]);
            }
        }
        self.mutex.lockUncancelable(self.deps.chunks.io);
        defer self.mutex.unlock(self.deps.chunks.io);
        entry.region = if (valid) region else null;
        entry.building = false;
    }
};

fn stateIndex(column: usize, section: usize, local: usize) usize {
    const x = column % 3 * 16 + local % 16;
    const z = column / 3 * 16 + local / 16 % 16;
    const y = (section + 1) * 16 + local / 256;
    return (y * side + z) * side + x;
}

/// Borrowed until the next Workspace.prepare call. Encode before preparing more terrain.
pub const Data = struct {
    engine: *const lighting.Engine,
    count: usize,
    masks: [2]u32,

    pub const capacity = 64 + 2 * (maximum_sections + 2) * 2051;

    pub fn write(self: Data, writer: *std.Io.Writer) !void {
        assert(self.count > 2 and self.count <= maximum_sections + 2);
        const mask = (@as(u64, 1) << @intCast(self.count)) - 1;
        assert((@as(u64, self.masks[0] | self.masks[1]) & ~mask) == 0);
        assert(self.engine.dimensions.x >= 32 and self.engine.dimensions.z >= 32 and self.engine.dimensions.y >= self.count * 16);
        for ([_]u32{ self.masks[1], self.masks[0] }) |bits| {
            try varint(writer, 1);
            try writer.writeInt(u64, bits, .big);
        }
        for ([_]u32{ self.masks[1], self.masks[0] }) |bits| {
            try varint(writer, 1);
            try writer.writeInt(u64, mask & ~@as(u64, bits), .big);
        }
        inline for (.{ lighting.Layer.sky, lighting.Layer.block }, .{ 1, 0 }) |layer, index| {
            const bits = self.masks[index];
            try varint(writer, @popCount(bits));
            for (0..self.count) |section| {
                if (bits & (@as(u32, 1) << @intCast(section)) == 0) continue;
                try varint(writer, 2048);
                const bytes = try writer.writableSlice(2048);
                self.engine.packSection(layer, .{ 1, section, 1 }, bytes[0..2048]);
            }
        }
    }
};

pub fn writeUpdate(packet: wire_1_21_5.play.toClient.packet_update_light.Writer, x: i32, z: i32, data: Data) ![]u8 {
    const cursor = packet._cursor;
    var writer: std.Io.Writer = .fixed(cursor.buffer);
    writer.end = cursor.buffer.len - cursor.rest.len;
    try varint(&writer, x);
    try varint(&writer, z);
    try data.write(&writer);
    return cursor.buffer[0..writer.end];
}

fn varint(writer: *std.Io.Writer, value: i32) !void {
    var remaining: u32 = @bitCast(value);
    while (remaining >= 128) : (remaining >>= 7) try writer.writeByte(@as(u8, @truncate(remaining & 127)) | 128);
    try writer.writeByte(@intCast(remaining));
}

test "terrain lighting crosses chunk boundaries and reconstructs after persistence" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/lighting", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{});
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 4, .demand_sections = 1 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = resources });
    const workspace = try Workspace.init(allocator, terrain, try game_data.lighting.init(allocator));
    const dimension: worlds.Worlds.Dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 1 };
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    const position: chunks.Position = .{ .x = -1, .y = 8, .z = 8 };
    try terrain.setBlock(0, position, glowstone);
    try settle(workspace, terrain, dimension);
    const center = stateIndex(4, 0, 8 * 256 + 8 * 16);
    try std.testing.expectEqual(@as(u8, 14), workspace.engine.get(.block, center));
    try std.testing.expectEqual(@as(u8, 0), workspace.engine.get(.sky, center));
    var before: [2048]u8 = undefined;
    workspace.engine.packSection(.block, .{ 1, 1, 1 }, &before);
    try terrain.setBlock(0, .{ .x = 0, .y = 8, .z = 8 }, stone);
    try settle(workspace, terrain, dimension);
    try std.testing.expectEqual(@as(u8, 0), workspace.engine.get(.block, center));
    try terrain.setBlock(0, .{ .x = 0, .y = 8, .z = 8 }, 0);
    try settle(workspace, terrain, dimension);
    var after: [2048]u8 = undefined;
    workspace.engine.packSection(.block, .{ 1, 1, 1 }, &after);
    try std.testing.expectEqualSlices(u8, &before, &after);
    try terrain.checkpoint(try store.openSpace("chunks"));
    try store.waitDurable(try store.commit(1));
    const restored = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 4, .demand_sections = 1 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = resources });
    const reloaded = try Workspace.init(allocator, restored, try game_data.lighting.init(allocator));
    try settle(reloaded, restored, dimension);
    reloaded.engine.packSection(.block, .{ 1, 1, 1 }, &after);
    try std.testing.expectEqualSlices(u8, &before, &after);
    try restored.setBlock(0, position, 0);
    try settle(reloaded, restored, dimension);
    try std.testing.expectEqual(@as(u8, 0), reloaded.engine.get(.block, center));
    var sky_dimension = dimension;
    sky_dimension.skylight = true;
    try settle(reloaded, restored, sky_dimension);
    try std.testing.expectEqual(@as(u8, 15), reloaded.engine.get(.sky, center));

    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(0, request.output);
        }
    };
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const bounded = failing.allocator();
    const asynchronous = try chunks.Chunks.init(bounded, io, .{ .cache_sections = 4, .demand_sections = 1 }, .{ .metrics = &registry, .storage = try store.openSpace("asynchronous"), .record_workspaces = resources });
    const pending = try Workspace.init(bounded, asynchronous, try game_data.lighting.init(bounded));
    var source: Source = .{};
    asynchronous.setSource(chunks.Source.init(&source, Source.read));
    failing.fail_index = failing.alloc_index;
    try std.testing.expect(!try pending.prepare(asynchronous, 0, 0, 0, dimension, 0));
    try std.testing.expectEqual(@as(usize, 0), asynchronous.borrowed_count);
    try settle(pending, asynchronous, dimension);
    try asynchronous.setBlock(0, position, glowstone);
    _ = try pending.prepare(asynchronous, 0, 0, 0, dimension, 0);
    try asynchronous.setBlock(0, position, 0);
    try settle(pending, asynchronous, dimension);
    try std.testing.expectEqual(@as(u8, 0), pending.engine.get(.block, center));
    try std.testing.expect(pending.current(asynchronous, 0, 0, 0, dimension));
    try std.testing.expectEqual(@as(usize, 0), asynchronous.borrowed_count);
}

fn settle(workspace: *Workspace, terrain: *chunks.Chunks, dimension: worlds.Worlds.Dimension) !void {
    for (0..128) |_| {
        if (try workspace.prepare(terrain, 0, 0, 0, dimension, 0)) return;
        while (try terrain.generation.processOne(std.testing.io)) {}
        try terrain.poll();
    }
    return error.LightingDidNotSettle;
}

test "simulation light queries share worker results and observe same tick edits" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/queries", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{});
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 4, .demand_sections = 1 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = resources });
    const dimensions = try worlds.Worlds.allocate(allocator, .{});
    const world = try dimensions.create(.{ .name = "test:light", .dimension = .{ .name = "test:dimension", .minimum_section = -1, .section_count = 2, .skylight = true } });
    const world_id = world;
    const service = try Lighting.init(allocator, .{ .cache_columns = 1 }, .{ .blocks = try vanilla_definitions.blocks(allocator), .chunks = terrain, .worlds = dimensions });
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(0, request.output);
        }
    };
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    failing.fail_index = failing.alloc_index;
    try terrain.setBlock(world_id, .{ .x = -1, .y = 8, .z = 8 }, glowstone);
    const positions = [_]chunks.Position{
        .{ .x = 0, .y = 8, .z = 8 },
        .{ .x = -1, .y = 8, .z = 8 },
        .{ .x = 0, .y = 8, .z = 8 },
        .{ .x = 1, .y = 8, .z = 8 },
        .{ .x = 64, .y = -8, .z = -64 },
    };
    var samples: [positions.len]Sample = undefined;
    try service.sampleMany(world_id, &positions, &samples);
    try std.testing.expectEqualSlices(Sample, &.{ .{ .block = 14, .sky = 15 }, .{ .block = 15, .sky = 0 }, .{ .block = 14, .sky = 15 }, .{ .block = 13, .sky = 15 }, .{ .block = 0, .sky = 15 } }, &samples);
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    // A completed worker snapshot serves queries without touching the simulation workspace.
    const dimension = dimensions.get(world_id).?.dimension;
    for (0..128) |_| {
        if (try service.prepare(world_id, 0, 0, dimension, 0)) break;
        while (try terrain.generation.processOne(io)) {}
        try terrain.poll();
    } else return error.LightingDidNotSettle;
    const relights = service.simulation.work.relights;
    const hits = service.cache_hits;
    try service.sampleMany(world_id, positions[0..1], samples[0..1]);
    try std.testing.expectEqual(hits + 1, service.cache_hits);
    try std.testing.expectEqual(relights, service.simulation.work.relights);
    try terrain.setBlock(world_id, positions[0], stone);
    try service.sampleMany(world_id, positions[0..1], samples[0..1]);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 0 }, samples[0]);
    try terrain.setBlock(world_id, positions[0], 0);
    try terrain.setBlock(world_id, positions[1], 0);
    try service.sampleMany(world_id, positions[0..1], samples[0..1]);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[0]);
    service.entries[0].building = true;
    try service.sampleMany(world_id, positions[4..5], samples[4..5]);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[4]);
    service.entries[0].building = false;
    var many: [Lighting.batch_max + 3]chunks.Position = @splat(positions[0]);
    many[1] = positions[3];
    var results: [many.len]Sample = undefined;
    try service.sampleMany(world_id, &many, &results);
    for (results) |sample| try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, sample);
    try service.sampleMany(world_id, &.{}, &.{});
    try std.testing.expectError(error.UnknownWorld, service.sampleMany(std.math.maxInt(u32), positions[0..1], samples[0..1]));
    try std.testing.expectError(error.InvalidLightingPosition, service.sampleMany(world_id, &.{.{ .x = 0, .y = 16, .z = 0 }}, samples[0..1]));
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
}

const ConcurrentLighting = struct {
    directory: std.testing.TmpDir = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    bounded: std.testing.FailingAllocator = undefined,
    registry: metrics.Registry = undefined,
    store: storage.Store = undefined,
    terrain: *chunks.Chunks = undefined,
    dimensions: *worlds.Worlds = undefined,
    service: *Lighting = undefined,
    generation: *Generation = undefined,
    source: Source = .{},
    path: [256]u8 = undefined,

    const Source = struct {
        reads: std.atomic.Value(usize) = .init(0),

        fn read(self: *Source, _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                _ = self.reads.fetchAdd(1, .monotonic);
                request.result = chunks.uniform(0, request.output);
            }
        }
    };

    fn init(self: *ConcurrentLighting) !void {
        const io = std.testing.io;
        self.directory = std.testing.tmpDir(.{});
        errdefer self.directory.cleanup();
        self.arena = .init(std.testing.allocator);
        errdefer self.arena.deinit();
        self.bounded = .init(self.arena.allocator(), .{});
        const allocator = self.bounded.allocator();
        self.registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        errdefer self.registry.deinit();
        self.store = try storage.Store.init(std.testing.allocator, io, .{ .path = try std.fmt.bufPrint(&self.path, ".zig-cache/tmp/{s}/concurrent-lighting", .{self.directory.sub_path}) });
        errdefer self.store.deinit();
        self.terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 8, .demand_sections = 2, .cache_tiles = 2 }, .{
            .metrics = &self.registry,
            .storage = try self.store.openSpace("chunks"),
            .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
        });
        self.dimensions = try worlds.Worlds.allocate(allocator, .{ .maximum = 2 });
        for ([_][]const u8{ "test:sky", "test:dark" }, 0..) |name, index| {
            const world = try self.dimensions.create(.{ .name = name, .dimension = .{ .name = name, .minimum_section = 0, .section_count = 1, .skylight = index == 0 } });
            assert(world == index);
        }
        self.service = try Lighting.init(allocator, .{ .cache_columns = 1 }, .{ .blocks = try vanilla_definitions.blocks(allocator), .chunks = self.terrain, .worlds = self.dimensions });
        self.terrain.setSource(chunks.Source.init(&self.source, Source.read));
        self.generation = try Generation.init(allocator, io, self.terrain.generation, 1);
        self.bounded.fail_index = self.bounded.alloc_index;
        try self.generation.start();
    }

    fn deinit(self: *ConcurrentLighting) void {
        self.generation.stop();
        self.store.deinit();
        self.registry.deinit();
        self.arena.deinit();
        self.directory.cleanup();
    }
};

const LightingWorker = struct {
    const Mode = enum { prepare, snapshot, publish, settle };
    const Command = struct { mode: Mode, world: u32 = 0, x: i32 = 0 };

    fixture: *ConcurrentLighting,
    thread: ?std.Thread = null,
    ready: std.Io.Event = .unset,
    request: std.Io.Event = .unset,
    entered: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
    command: Command = undefined,
    result: anyerror!void = {},

    fn start(self: *LightingWorker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        self.ready.waitUncancelable(std.testing.io);
    }

    fn run(self: *LightingWorker) void {
        const io = std.testing.io;
        self.fixture.terrain.attach();
        defer self.fixture.terrain.stop();
        self.ready.set(io);
        while (true) {
            self.request.waitUncancelable(io);
            self.request.reset();
            if (self.stopping.load(.acquire)) return;
            self.entered.set(io);
            self.result = self.execute();
            self.done.set(io);
        }
    }

    fn execute(self: *LightingWorker) !void {
        const fixture = self.fixture;
        const command = self.command;
        const dimension = fixture.dimensions.get(command.world).?.dimension;
        switch (command.mode) {
            .prepare => _ = try fixture.service.prepare(command.world, command.x, 0, dimension, 0),
            .publish => fixture.service.publish(fixture.service.background),
            .snapshot, .settle => {
                for (0..128) |_| {
                    fixture.terrain.ready().reset();
                    const complete = if (command.mode == .snapshot)
                        try fixture.service.background.prepare(fixture.terrain, command.world, command.x, 0, dimension, 0)
                    else
                        try fixture.service.prepare(command.world, command.x, 0, dimension, 0);
                    if (complete) return;
                    try fixture.terrain.ready().waitTimeout(std.testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } });
                    try fixture.terrain.poll();
                }
                return error.LightingDidNotSettle;
            },
        }
    }

    fn begin(self: *LightingWorker, command: Command) !void {
        self.done.reset();
        self.entered.reset();
        self.command = command;
        self.request.set(std.testing.io);
        try self.entered.waitTimeout(std.testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } });
    }

    fn finish(self: *LightingWorker) !void {
        try self.done.waitTimeout(std.testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } });
        try self.result;
    }

    fn stop(self: *LightingWorker) void {
        self.stopping.store(true, .release);
        self.request.set(std.testing.io);
        self.thread.?.join();
        self.thread = null;
    }
};

test "lighting worker rejects a snapshot edited before publication" {
    var fixture: ConcurrentLighting = .{};
    try fixture.init();
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const source: chunks.Position = .{ .x = -1, .y = 8, .z = 8 };
    const target: chunks.Position = .{ .x = 0, .y = 8, .z = 8 };
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    try fixture.terrain.setBlock(0, source, glowstone);
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
    try std.testing.expectEqual(@as(u4, 14), fixture.service.background.engine.get(.block, stateIndex(4, 0, 8 * 256 + 8 * 16)));
    try fixture.terrain.setBlock(0, source, 0);
    try worker.begin(.{ .mode = .publish });
    try worker.finish();
    try std.testing.expect(fixture.service.entries[0].region == null);
    var samples: [1]Sample = undefined;
    try fixture.service.sampleMany(0, &.{target}, &samples);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[0]);
    try worker.begin(.{ .mode = .settle });
    try worker.finish();
    const hits = fixture.service.cache_hits;
    try fixture.service.sampleMany(0, &.{target}, &samples);
    try std.testing.expectEqual(hits + 1, fixture.service.cache_hits);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[0]);
    try fixture.terrain.setBlock(0, source, glowstone);
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    try fixture.terrain.setBlock(0, source, 0);
    try fixture.service.sampleMany(0, &.{target}, &samples);
    try worker.begin(.{ .mode = .publish });
    try worker.finish();
    const fresh_hits = fixture.service.cache_hits;
    try fixture.service.sampleMany(0, &.{target}, &samples);
    try std.testing.expectEqual(fresh_hits + 1, fixture.service.cache_hits);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[0]);
}

test "lighting worker and simulation race edits queries and cache eviction" {
    var fixture: ConcurrentLighting = .{};
    try fixture.init();
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    const positions = [_]chunks.Position{ .{ .x = 0, .y = 8, .z = 8 }, .{ .x = 64, .y = 8, .z = 8 } };
    var expected = [_][2]Sample{ @splat(.{ .block = 0, .sky = 15 }), @splat(.{ .block = 0, .sky = 0 }) };
    try worker.begin(.{ .mode = .settle });
    try worker.finish();
    for (0..48) |step| {
        const world: u32 = @intCast(step % 2);
        const column = step / 2 % 2;
        const x: i32 = @intCast(column * 4);
        const phase = step / 4 % 6;
        const emitter = phase < 3 or phase == 5;
        const blocked = phase == 1;
        const roof = phase == 2 or phase == 3;
        try worker.begin(.{ .mode = .prepare, .world = world, .x = x });
        const edits = [_]chunks.SectionEdits{
            .{ .section = .{ .world = world, .x = x - 1, .y = 0, .z = 0 }, .edits = &.{.{ .index = 8 * 256 + 8 * 16 + 15, .state = if (emitter) glowstone else 0 }} },
            .{ .section = .{ .world = world, .x = x, .y = 0, .z = 0 }, .edits = &.{
                .{ .index = 8 * 256 + 8 * 16, .state = if (blocked) stone else 0 },
                .{ .index = 9 * 256 + 8 * 16, .state = if (roof) stone else 0 },
            } },
        };
        try fixture.terrain.setSections(&edits);
        expected[world][column] = .{ .block = if (blocked or !emitter) 0 else 14, .sky = if (world != 0 or blocked) 0 else if (roof) 14 else 15 };
        var samples: [positions.len]Sample = undefined;
        try fixture.service.sampleMany(world, &positions, &samples);
        try std.testing.expectEqualSlices(Sample, &expected[world], &samples);
        try worker.finish();
    }
    for (0..2) |world| {
        try worker.begin(.{ .mode = .settle, .world = @intCast(world) });
        try worker.finish();
        var samples: [positions.len]Sample = undefined;
        try fixture.service.sampleMany(@intCast(world), &positions, &samples);
        try std.testing.expectEqualSlices(Sample, &expected[world], &samples);
    }
    try std.testing.expect(fixture.source.reads.load(.acquire) > fixture.terrain.cache.entries.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}
