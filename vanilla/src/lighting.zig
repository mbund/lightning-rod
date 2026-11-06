const vanilla_definitions = @import("vanilla_content.zig");
const Blocks = @import("blocks.zig").Blocks;
const std = @import("std");
const builtin = @import("builtin");
const lighting = @import("lighting");
const game_data = @import("game_data");
const chunks = @import("chunks");
const sessions = @import("sessions");
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

pub const Stamp = struct { generation: u64 = 0, revision: u64 = 0, index: usize = 0, constant: ?u16 = null, storage: enum { decoded, encoded } = .decoded };

pub const Section = struct {
    pub const View = union(enum) {
        unavailable,
        uniform: u16,
        dense: *const [4096]u16,
        rows: []const u16,
        chunk: chunks.View,
        encoded: chunks.encoding.Packed,

        pub fn get(self: View, index: u12) u16 {
            return switch (self) {
                .unavailable => unreachable,
                .uniform => |state| state,
                .dense => |states| states[index],
                .rows => |states| states[@as(usize, index / 256) * side * side + @as(usize, index / 16 % 16) * side + index % 16],
                .chunk => |view| view.get(index),
                .encoded => |view| view.get(index),
            };
        }

        pub inline fn row(self: View, index: u8) [16]u16 {
            const start = @as(usize, index) * 16;
            return switch (self) {
                .unavailable => unreachable,
                .uniform => |state| @splat(state),
                .dense => |states| states[start..][0..16].*,
                .rows => |states| states[@as(usize, index / 16) * side * side + @as(usize, index % 16) * side ..][0..16].*,
                .chunk => |view| switch (view) {
                    .uniform => |state| @splat(state),
                    .dense => |bytes| decode: {
                        const values = std.mem.bytesAsValue([16]u16, bytes[start * 2 ..][0..32]).*;
                        break :decode if (builtin.cpu.arch.endian() == .little) values else @as([16]u16, @byteSwap(@as(@Vector(16, u16), values)));
                    },
                },
                .encoded => |view| view.row(index),
            };
        }
    };
    stamp: Stamp,
    view: View,
    biomes: ?*const [64]u16 = null,
};

/// Each owner has a separate workspace. Chunk leases protect the input snapshot.
pub const Workspace = struct {
    const Region = struct { world: u32, x: i32, z: i32, minimum: i32, count: usize, skylight: bool };

    pub const Work = struct {
        acquired_sections: u64 = 0,
        acquisition_batches: u64 = 0,
        decoded_sections: u64 = 0,
        retained_columns: u64 = 0,
        retained_sections: u64 = 0,
        relights: u64 = 0,
        updates: u64 = 0,
        scrolls: u64 = 0,
        loaded_rows: u64 = 0,
        retained_rows: u64 = 0,
        propagated_rows: u64 = 0,
        candidate_rows: u64 = 0,
        source_rows: u64 = 0,
        reset_rows: u64 = 0,
    };

    const Timings = struct {
        acquire: metrics.Timer = .{},
        snapshot: metrics.Timer = .{},
        materials: metrics.Timer = .{},
        propagate: metrics.Timer = .{},
        scroll: metrics.Timer = .{},
    };

    const Preparation = struct {
        previous: [9 * maximum_sections]u64 = undefined,
        positions: [9 * maximum_sections]chunks.Section = undefined,
        indices: [9 * maximum_sections]usize = undefined,
        leases: []chunks.Lease,
        requests: []chunks.Chunks.Preparation,
        ready: []bool,
        edits: [lighting.batch_max]lighting.Edit = undefined,
    };
    preparation: Preparation,
    work: Work = .{},
    timings: Timings = .{},
    solved: ?Region = null,
    solved_stamps: [9 * maximum_sections]Stamp = undefined,
    engine: lighting.Engine,
    states: []u16,
    origin: [2]usize = .{ 0, 0 },
    region: ?Region = null,
    pending: ?Region = null,
    watch: *chunks.Watch,
    versions: [9 * maximum_sections]u64 = @splat(0),
    copied: [9 * maximum_sections]bool = @splat(false),
    masks: [2]u32 = .{ 0, 0 },
    coverage: u32 = 0,
    input_ready: bool = false,
    stamps: [9 * maximum_sections]Stamp = @splat(.{}),
    dirty: [9 * maximum_sections]bool = @splat(false),
    uniforms: [9 * maximum_sections]?u16 = @splat(null),
    section_views: [maximum_sections]Section = undefined,
    biome_values: [9 * maximum_sections][64]u16 = undefined,
    biome_present: [9 * maximum_sections]bool = @splat(false),

    pub fn init(allocator: std.mem.Allocator, terrain: *chunks.Chunks, registry: lighting.Registry) !*Workspace {
        const self = try allocator.create(Workspace);
        const capacity = @min(192, terrain.cache.entries.len);
        self.* = .{
            .watch = try chunks.Watch.init(allocator, terrain, 9 * maximum_sections),
            .engine = try lighting.Engine.init(allocator, .{ .x = side, .y = height, .z = side }, registry),
            .states = try allocator.alloc(u16, side * height * side),
            .preparation = .{
                .leases = try allocator.alloc(chunks.Lease, capacity),
                .requests = try allocator.alloc(chunks.Chunks.Preparation, capacity),
                .ready = try allocator.alloc(bool, capacity),
            },
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
        if (!try self.prepareInputsMode(terrain, world, x, z, dimension, .{ .player = player }, access)) return false;
        try self.solve(std.math.maxInt(u32));
        return true;
    }

    /// Snapshots are borrowed until the next prepare. Lighting is not computed here.
    pub fn prepareInputs(self: *Workspace, terrain: *chunks.Chunks, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, player: usize) !bool {
        return self.prepareInputsMode(terrain, world, x, z, dimension, .{ .player = player }, .background);
    }

    fn prepareInputsMode(self: *Workspace, terrain: *chunks.Chunks, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, priority: chunks.GenerationPriority, access: Access) !bool {
        const count = dimension.sectionCount();
        if (count == 0 or count > maximum_sections) return error.UnsupportedLightingHeight;
        const region: Region = .{ .world = world, .x = x, .z = z, .minimum = dimension.minimumSection(), .count = count, .skylight = dimension.skylight };
        assert(self.watch.owner == terrain);
        const same = if (self.region) |previous| std.meta.eql(previous, region) else false;
        if (same and self.current(terrain, world, x, z, dimension)) return true;
        const continuing = if (self.pending) |previous| std.meta.eql(previous, region) else same;
        if (!continuing) {
            self.input_ready = false;
            const watched: chunks.Watch.Region = .{
                .world = world,
                .minimum = .{ .x = try std.math.sub(i32, x, 1), .y = region.minimum, .z = try std.math.sub(i32, z, 1) },
                .maximum = .{ .x = try std.math.add(i32, x, 1), .y = try std.math.add(i32, region.minimum, @as(i32, @intCast(count)) - 1), .z = try std.math.add(i32, z, 1) },
            };
            const previous = &self.preparation.previous;
            self.watch.configure(watched, previous);
            self.move(region, previous);
            self.region = null;
        }
        const reuse = self.region != null;
        self.input_ready = false;
        self.pending = region;
        const positions = &self.preparation.positions;
        const indices = &self.preparation.indices;
        var needed: usize = 0;
        for (0..9) |column| {
            const cx = try std.math.add(i32, x, @as(i32, @intCast(column % 3)) - 1);
            const cz = try std.math.add(i32, z, @as(i32, @intCast(column / 3)) - 1);
            for (0..count) |section| {
                const at = column * maximum_sections + section;
                if (self.versions[at] != self.watch.revision(column * count + section)) self.copied[at] = false;
                if (self.copied[at]) continue;
                indices[needed] = at;
                positions[needed] = .{ .world = world, .x = cx, .y = region.minimum + @as(i32, @intCast(section)), .z = cz };
                needed += 1;
            }
        }
        const capacity = @min(192, switch (access) {
            .background => terrain.backgroundCapacity(),
            .required => @max(1, terrain.demand_sections),
        });
        if (needed != 0 and capacity == 0) return error.WorkingSetTooLarge;
        var begin: usize = 0;
        while (begin < needed) {
            const end = begin + @min(needed - begin, capacity);
            const leases = self.preparation.leases;
            var held: usize = 0;
            defer terrain.releaseMany(leases[0..held]);
            self.work.acquisition_batches += 1;
            {
                const timing = self.timings.acquire.start();
                defer timing.end();
                switch (access) {
                    .background => {
                        const requests = self.preparation.requests;
                        const ready = self.preparation.ready;
                        for (requests[0 .. end - begin], 0..) |*request, index| request.* = .{
                            .sections = positions[begin + index ..][0..1],
                            .leases = leases[index..][0..1],
                            .priority = priority,
                        };
                        try terrain.prepareMany(requests[0 .. end - begin], ready[0 .. end - begin]);
                        for (ready[0 .. end - begin], 0..) |complete, index| if (complete) {
                            leases[held] = leases[index];
                            indices[begin + held] = indices[begin + index];
                            held += 1;
                        };
                    },
                    .required => {
                        try terrain.acquireMany(positions[begin..end], leases[0 .. end - begin]);
                        held = end - begin;
                    },
                }
            }
            self.capture(count, reuse, leases[0..held], indices[begin..][0..held]);
            begin = end;
        }
        var complete = true;
        for (0..9) |column| for (0..count) |section| {
            const at = column * maximum_sections + section;
            if (self.versions[at] != self.watch.revision(column * count + section)) self.copied[at] = false;
            complete = complete and self.copied[at];
        };
        if (!complete) return false;
        self.input_ready = true;
        for (self.section_views[0..count], 0..) |*section, y| {
            const at = 4 * maximum_sections + y;
            section.* = .{ .stamp = self.stamps[at], .biomes = if (self.biome_present[at]) &self.biome_values[at] else null, .view = if (self.uniforms[at]) |state| .{ .uniform = state } else .{ .rows = self.states[self.snapshotIndex(4, y, 0)..] } };
        }
        return true;
    }

    fn solve(self: *Workspace, selection: u32) !void {
        assert(self.input_ready);
        const region = (self.pending orelse self.region.?);
        const all = (@as(u32, 1) << @intCast(region.count)) - 1;
        const requested = selection & all;
        if (self.pending == null and self.coverage & requested == requested) return;
        const delta = self.scrollOffset(region);
        var first: usize = if (requested == 0) region.count + 1 else @ctz(requested);
        if (self.solved != null and self.region != null) {
            assert(std.meta.eql(self.region.?, region));
            assert(self.engine.minimum % (side * side) == 0);
            first = @min(first, self.engine.minimum / (side * side));
        }
        const minimum_y = first * 16;
        const reuse = self.region != null and self.engine.minimum == minimum_y * (side * side / 16);
        const input: lighting.Blocks.Ring = .{ .states = self.states, .origin = self.origin, .minimum_y = minimum_y, .sections = .{ .uniforms = &self.uniforms, .first = 1, .count = region.count, .stride = maximum_sections } };
        if (!reuse and delta != null and self.engine.minimum == minimum_y * (side * side / 16)) {
            const timing = self.timings.scroll.start();
            defer timing.end();
            try self.engine.scroll(delta.?, input);
            self.work.scrolls += 1;
            self.accountWork();
        } else if (!reuse) {
            var air = true;
            for (0..9) |column| for (0..region.count) |section| {
                air = air and self.uniforms[column * maximum_sections + section] == 0;
            };
            {
                const timing = self.timings.materials.start();
                defer timing.end();
                try self.engine.load(if (air and minimum_y == 0) .{ .uniform = 0 } else .{ .ring = input });
            }
            {
                const timing = self.timings.propagate.start();
                defer timing.end();
                self.engine.relight(region.skylight);
            }
            self.work.relights += 1;
            self.accountWork();
        } else {
            const edits = &self.preparation.edits;
            var used: usize = 0;
            for (0..9) |column| for (0..region.count) |section| {
                if (!self.dirty[column * maximum_sections + section]) continue;
                if ((section + 2) * 16 <= minimum_y) continue;
                for (0..4096) |local| {
                    const index = stateIndex(column, section, local);
                    const state = self.uniforms[column * maximum_sections + section] orelse self.states[self.snapshotIndex(column, section, local)];
                    if (self.engine.blockState(index) == state) continue;
                    edits[used] = .{ .index = index, .state = state };
                    used += 1;
                    if (used == edits.len) {
                        try self.engine.update(edits);
                        self.accountWork();
                        self.work.updates += 1;
                        used = 0;
                    }
                }
            };
            if (used != 0) {
                try self.engine.update(edits[0..used]);
                self.accountWork();
                self.work.updates += 1;
            }
        }
        @memset(&self.dirty, false);
        self.region = region;
        self.solved = region;
        self.solved_stamps = self.stamps;
        self.coverage = if (requested == 0) 0 else all & (@as(u32, std.math.maxInt(u32)) << @intCast(first));
        self.pending = null;
        self.masks = .{ 0, 0 };
        for (0..region.count + 2) |section| {
            inline for (.{ lighting.Layer.block, lighting.Layer.sky }, 0..) |layer, index| {
                if (self.engine.sectionNonempty(layer, .{ 1, section, 1 })) self.masks[index] |= @as(u32, 1) << @intCast(section);
            }
        }
    }

    fn capture(self: *Workspace, count: usize, reuse: bool, leases: []const chunks.Lease, indices: []const usize) void {
        const timing = self.timings.snapshot.start();
        defer timing.end();
        assert(leases.len == indices.len);
        self.work.acquired_sections += leases.len;
        for (leases, indices) |lease, at| {
            const column = at / maximum_sections;
            const section = at % maximum_sections;
            self.versions[at] = self.watch.revision(column * count + section);
            const stamp: Stamp = .{ .index = lease.record.index, .generation = lease.record.generation, .revision = lease.record.revision() };
            if (!reuse or !std.meta.eql(stamp, self.stamps[at])) {
                const view = lease.view();
                self.uniforms[at] = self.copy(column, section, view);
                self.biome_present[at] = lease.biomes() != null;
                if (lease.biomes()) |biomes| for (&self.biome_values[at], 0..) |*biome, index| {
                    biome.* = biomes.get(@intCast(index));
                };
                self.work.decoded_sections += 1;
                self.stamps[at] = stamp;
                self.dirty[at] = true;
            }
            self.copied[at] = true;
        }
    }

    fn move(self: *Workspace, target: Region, revisions: *const [9 * maximum_sections]u64) void {
        const timing = self.timings.snapshot.start();
        defer timing.end();
        const previous = self.pending orelse self.region;
        const copied = self.copied;
        const versions = self.versions;
        const stamps = self.stamps;
        const uniforms = self.uniforms;
        const biome_values = self.biome_values;
        const biome_present = self.biome_present;
        @memset(&self.copied, false);
        @memset(&self.versions, 0);
        @memset(&self.stamps, .{});
        @memset(&self.dirty, false);
        @memset(&self.uniforms, null);
        @memset(&self.biome_present, false);
        const old = previous orelse {
            self.origin = .{ 0, 0 };
            return;
        };
        const dx = @as(i64, target.x) - old.x;
        const dz = @as(i64, target.z) - old.z;
        if (old.world != target.world or old.minimum != target.minimum or old.count != target.count or old.skylight != target.skylight or @abs(dx) >= 3 or @abs(dz) >= 3) {
            self.origin = .{ 0, 0 };
            return;
        }
        self.origin = .{
            @intCast(@mod(@as(i64, @intCast(self.origin[0])) + dx, 3)),
            @intCast(@mod(@as(i64, @intCast(self.origin[1])) + dz * 16, side)),
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
                self.biome_present[destination] = biome_present[source];
                if (biome_present[source]) self.biome_values[destination] = biome_values[source];
                self.work.retained_sections += 1;
            }
            self.work.retained_columns += @intFromBool(all);
        }
    }

    fn scrollOffset(self: *const Workspace, target: Region) ?[2]i32 {
        const old = self.solved orelse return null;
        const dx = @as(i64, target.x) - old.x;
        const dz = @as(i64, target.z) - old.z;
        if (old.world != target.world or old.minimum != target.minimum or old.count != target.count or old.skylight != target.skylight or @abs(dx) >= 3 or @abs(dz) >= 3 or (dx == 0 and dz == 0)) return null;
        for (0..9) |column| {
            const x = @as(i64, @intCast(column % 3)) + dx;
            const z = @as(i64, @intCast(column / 3)) + dz;
            if (x < 0 or x >= 3 or z < 0 or z >= 3) continue;
            const from: usize = @intCast(z * 3 + x);
            for (0..target.count) |section| {
                if (!std.meta.eql(self.solved_stamps[from * maximum_sections + section], self.stamps[column * maximum_sections + section])) return null;
            }
        }
        return .{ @intCast(dx * 16), @intCast(dz * 16) };
    }

    fn accountWork(self: *Workspace) void {
        self.work.loaded_rows += self.engine.work.loaded_rows;
        self.work.retained_rows += self.engine.work.retained_rows;
        self.work.propagated_rows += self.engine.work.propagated_rows;
        self.work.candidate_rows += self.engine.work.candidate_rows;
        self.work.source_rows += self.engine.work.source_rows;
        self.work.reset_rows += self.engine.work.reset_rows;
    }

    fn copy(self: *Workspace, column: usize, section: usize, view: chunks.View) ?u16 {
        if (view == .uniform) return view.uniform;
        const first = view.get(0);
        var uniform = true;
        const base = self.snapshotIndex(column, section, 0);
        for (0..256) |row| {
            const begin = base + row / 16 * side * side + row % 16 * side;
            if (builtin.cpu.arch.endian() == .little) {
                @memcpy(std.mem.sliceAsBytes(self.states[begin..][0..16]), view.dense[row * 32 ..][0..32]);
            } else {
                for (self.states[begin..][0..16], 0..) |*state, x| state.* = view.get(@intCast(row * 16 + x));
            }
            if (uniform) {
                const values: @Vector(16, u16) = self.states[begin..][0..16].*;
                uniform = @reduce(.And, values == @as(@Vector(16, u16), @splat(first)));
            }
        }
        return if (uniform) first else null;
    }

    fn snapshotIndex(self: *const Workspace, column: usize, section: usize, local: usize) usize {
        const x = (column % 3 + self.origin[0]) % 3 * 16 + local % 16;
        const z = (column / 3 * 16 + self.origin[1]) % side + local / 16 % 16;
        const y = (section + 1) * 16 + local / 256;
        return (y * side + z) * side + x;
    }

    /// Block snapshots are available before lighting is solved and borrowed until the next prepare.
    pub fn sections(self: *const Workspace) []const Section {
        assert(self.input_ready);
        return self.section_views[0..(self.pending orelse self.region.?).count];
    }

    pub fn columnSections(self: *const Workspace, column: usize, output: []Section) void {
        assert(self.input_ready and column < 9);
        assert(output.len == (self.pending orelse self.region.?).count);
        for (output, 0..) |*section, y| {
            const at = column * maximum_sections + y;
            section.* = .{
                .stamp = self.stamps[at],
                .biomes = if (self.biome_present[at]) &self.biome_values[at] else null,
                .view = if (self.uniforms[at]) |state| .{ .uniform = state } else .{ .rows = self.states[self.snapshotIndex(column, y, 0)..] },
            };
        }
    }

    pub fn data(self: *const Workspace) Data {
        assert(self.pending == null and self.engine.lit);
        const region = self.region.?;
        return .{ .source = .{ .computed = &self.engine }, .count = region.count + 2, .masks = self.masks, .coverage = self.coverage };
    }
};

pub const Sample = packed struct(u8) { block: u4, sky: u4 };

pub const Lighting = struct {
    pub const id = "minecraft:lighting";
    pub const Configuration = struct { cache_columns: usize = 16, stored: bool = true };
    pub const Dependencies = struct { metrics: *metrics.Registry, blocks: *Blocks, chunks: *chunks.Chunks, worlds: *worlds.Worlds };
    const batch_max = 256;
    const Key = struct { x: i32, z: i32 };
    const Entry = struct {
        region: ?Workspace.Region = null,
        building: bool = false,
        coverage: u32 = 0,
        watch: *chunks.Watch,
        levels: [2][maximum_sections][2048]u8 = undefined,
    };
    pub const Delivery = struct { world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension };
    const Prepared = struct {
        region: ?Workspace.Region = null,
        snapshot: chunks.Light.Snapshot = undefined,
        frame: []u8,
        watch: *chunks.Watch,
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
    config: Configuration,
    rules: [32]u8,
    stored_workspace: chunks.Light.Workspace,
    stored_view: ?chunks.Light.View = null,
    stored_region: ?Workspace.Region = null,
    stored_watch: *chunks.Watch,
    prepared: [chunks.Light.batch_max]Prepared,
    delivery_saved: bool = false,
    delivery_active: bool = false,
    delivery_present: u32 = 0,
    delivery_leases: [maximum_sections]chunks.Lease = undefined,
    delivery_held: usize = 0,
    delivery_packed: ?chunks.Chunks.PackedWindow = null,
    delivery_sections: [maximum_sections]Section = undefined,
    delivery_biomes: [9 * maximum_sections][64]u16 = undefined,
    stored_hits: metrics.Counter,
    stored_misses: metrics.Counter,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Lighting {
        if (config.cache_columns == 0) return error.InvalidLightingCapacity;
        const registry = deps.blocks.light;
        const self = try allocator.create(Lighting);
        self.* = .{
            .deps = deps,
            .background = try Workspace.init(allocator, deps.chunks, registry),
            .simulation = try Workspace.init(allocator, deps.chunks, registry),
            .entries = try allocator.alloc(Entry, config.cache_columns),
            .config = config,
            .rules = rulesHash(registry),
            .stored_workspace = try .init(allocator),
            .stored_watch = try chunks.Watch.init(allocator, deps.chunks, 9 * maximum_sections),
            .prepared = undefined,
            .stored_hits = try deps.metrics.counter(.{ .name = "lighting.stored.hits", .description = "Chunk deliveries using persisted lighting" }),
            .stored_misses = try deps.metrics.counter(.{ .name = "lighting.stored.misses", .description = "Chunk deliveries requiring lighting reconstruction" }),
        };
        for (&self.prepared) |*entry| entry.* = .{
            .frame = try allocator.alloc(u8, self.stored_workspace.frame.len),
            .watch = try chunks.Watch.init(allocator, deps.chunks, 9 * maximum_sections),
        };
        const timings: Workspace.Timings = .{
            .acquire = try deps.metrics.timer(.{ .name = "lighting.acquire.cpu", .description = "Acquire lighting input sections", .clock = .thread_cpu }),
            .snapshot = try deps.metrics.timer(.{ .name = "lighting.snapshot.cpu", .description = "Copy and retain lighting input snapshots", .clock = .thread_cpu }),
            .materials = try deps.metrics.timer(.{ .name = "lighting.materials.cpu", .description = "Prepare lighting material rows", .clock = .thread_cpu }),
            .propagate = try deps.metrics.timer(.{ .name = "lighting.propagate.cpu", .description = "Propagate a fresh lighting field", .clock = .thread_cpu }),
            .scroll = try deps.metrics.timer(.{ .name = "lighting.scroll.cpu", .description = "Retain settled light and propagate incoming boundaries", .clock = .thread_cpu }),
        };
        self.background.timings = timings;
        self.simulation.timings = timings;
        for (self.entries) |*entry| entry.* = .{ .watch = try chunks.Watch.init(allocator, deps.chunks, 9 * maximum_sections) };
        try self.groups.ensureTotalCapacity(allocator, batch_max);
        try deps.blocks.registry.onChange(self, definitionsChanged);
        return self;
    }

    fn definitionsChanged(self: *Lighting) !void {
        self.rules = rulesHash(self.deps.blocks.light);
        self.stored_region = null;
        self.stored_view = null;
        for (&self.prepared) |*entry| entry.region = null;
        for ([_]*Workspace{ self.background, self.simulation }) |workspace| {
            workspace.engine.registry = self.deps.blocks.light;
            workspace.region = null;
            workspace.pending = null;
            workspace.solved = null;
            workspace.input_ready = false;
            workspace.coverage = 0;
            @memset(&workspace.copied, false);
        }
        for (self.entries) |*entry| {
            entry.region = null;
            entry.building = false;
        }
    }

    fn rulesHash(registry: lighting.Registry) [32]u8 {
        var hash = std.crypto.hash.Blake3.init(.{});
        var version: [20]u8 = undefined;
        std.mem.writeInt(u32, version[0..4], chunks.Light.algorithm_version, .little);
        std.mem.writeInt(u64, version[4..12], @intCast(registry.states.len), .little);
        std.mem.writeInt(u64, version[12..20], @intCast(registry.faces), .little);
        hash.update(&version);
        for (registry.states) |state| {
            var bytes: [14]u8 = undefined;
            bytes[0] = state.opacity;
            bytes[1] = state.emission;
            for (state.faces, 0..) |face, index| std.mem.writeInt(u16, bytes[2 + index * 2 ..][0..2], face, .little);
            hash.update(&bytes);
        }
        hash.update(registry.occlusion);
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }

    pub fn releaseDelivery(self: *Lighting) void {
        if (self.delivery_packed) |window| window.release();
        self.delivery_packed = null;
        self.deps.chunks.releaseMany(self.delivery_leases[0..self.delivery_held]);
        self.delivery_held = 0;
        self.delivery_active = false;
        self.delivery_present = 0;
    }

    pub fn currentDelivery(self: *const Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension) bool {
        if (!self.delivery_saved) return self.background.current(self.deps.chunks, world, x, z, dimension);
        const region: Workspace.Region = .{ .world = world, .x = x, .z = z, .minimum = dimension.minimumSection(), .count = dimension.sectionCount(), .skylight = dimension.skylight };
        return self.stored_region != null and std.meta.eql(self.stored_region.?, region) and self.stored_watch.unchanged();
    }

    fn watchDelivery(watch: *chunks.Watch, region: Workspace.Region) !void {
        var previous: [9 * maximum_sections]u64 = undefined;
        watch.configure(.{ .world = region.world, .minimum = .{ .x = try std.math.sub(i32, region.x, 1), .y = region.minimum, .z = try std.math.sub(i32, region.z, 1) }, .maximum = .{ .x = try std.math.add(i32, region.x, 1), .y = region.minimum + @as(i32, @intCast(region.count)) - 1, .z = try std.math.add(i32, region.z, 1) } }, &previous);
    }

    /// Borrowed frames remain valid until the next batch. Watches cover edits during the read.
    pub fn prepareDeliveries(self: *Lighting, deliveries: []const Delivery) !void {
        assert(deliveries.len <= self.prepared.len and !self.delivery_active);
        for (&self.prepared) |*entry| entry.region = null;
        errdefer {
            for (&self.prepared) |*entry| entry.region = null;
        }
        if (!self.config.stored or deliveries.len == 0) return;
        var requests: [chunks.Light.batch_max]chunks.Light.Request = undefined;
        var snapshots: [chunks.Light.batch_max]chunks.Light.Snapshot = undefined;
        for (deliveries, self.prepared[0..deliveries.len], requests[0..deliveries.len]) |delivery, *entry, *request| {
            const dimension = delivery.dimension;
            const count = dimension.sectionCount();
            if (count == 0 or count > maximum_sections) return error.UnsupportedLightingHeight;
            const region: Workspace.Region = .{ .world = delivery.world, .x = delivery.x, .z = delivery.z, .minimum = dimension.minimumSection(), .count = count, .skylight = dimension.skylight };
            try watchDelivery(entry.watch, region);
            entry.region = region;
            request.* = .{ .column = .{ .world = delivery.world, .x = delivery.x, .z = delivery.z }, .minimum = region.minimum, .count = count, .destination = entry.frame };
        }
        try self.deps.chunks.lightSnapshots(requests[0..deliveries.len], snapshots[0..deliveries.len]);
        for (self.prepared[0..deliveries.len], snapshots[0..deliveries.len]) |*entry, snapshot| entry.snapshot = snapshot;
    }

    pub fn prepareDelivery(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, priority: chunks.GenerationPriority) !bool {
        const count = dimension.sectionCount();
        if (count == 0 or count > maximum_sections) return error.UnsupportedLightingHeight;
        if (self.delivery_active and self.currentDelivery(world, x, z, dimension)) return true;
        self.releaseDelivery();
        self.delivery_saved = false;
        const region: Workspace.Region = .{ .world = world, .x = x, .z = z, .minimum = dimension.minimumSection(), .count = count, .skylight = dimension.skylight };
        if (self.config.stored) {
            var valid = self.stored_region != null and std.meta.eql(self.stored_region.?, region) and self.stored_watch.unchanged();
            if (!valid) {
                self.stored_region = null;
                self.stored_view = null;
                var frame = self.stored_workspace.frame;
                const snapshot = prefetched: {
                    for (&self.prepared) |*entry| {
                        if (entry.region == null or !std.meta.eql(entry.region.?, region) or !entry.watch.unchanged()) continue;
                        entry.region = null;
                        const watch = self.stored_watch;
                        self.stored_watch = entry.watch;
                        entry.watch = watch;
                        frame = entry.frame;
                        break :prefetched entry.snapshot;
                    }
                    try watchDelivery(self.stored_watch, region);
                    break :prefetched try self.deps.chunks.lightSnapshot(.{ .world = world, .x = x, .z = z }, region.minimum, count, frame);
                };
                if (snapshot.length) |length| {
                    const decoded: ?chunks.Light.View = self.stored_workspace.decode(frame[0..length]) catch |err| switch (err) {
                        error.Outdated => null,
                        else => return err,
                    };
                    if (decoded) |view| {
                        valid = snapshot.clean and self.stored_watch.unchanged() and
                            view.header.minimum == region.minimum and view.header.count == count and view.header.skylight == region.skylight and
                            view.header.coverage == (@as(u32, 1) << @intCast(count)) - 1 and
                            std.mem.eql(u8, &view.header.rules, &self.rules) and std.mem.eql(u64, &view.header.revisions, &snapshot.revisions);
                        if (valid) {
                            self.stored_region = region;
                            self.stored_view = view;
                            for (0..9) |column| for (0..count) |section| {
                                if (view.biomes[column][section]) |bytes| for (&self.delivery_biomes[column * maximum_sections + section], 0..) |*value, index| {
                                    value.* = std.mem.readInt(u16, bytes[index * 2 ..][0..2], .little);
                                };
                            };
                        }
                    }
                }
            }
            if (valid) {
                const view = &self.stored_view.?;
                for (self.delivery_sections[0..count], 0..) |*section, index| {
                    const uniform = view.header.uniform & (@as(u32, 1) << @intCast(index)) != 0;
                    const state = view.header.states[index];
                    if (uniform and state >= self.deps.blocks.light.states.len) return error.Corrupt;
                    section.* = .{
                        .stamp = if (uniform) .{ .constant = state } else .{},
                        .view = if (uniform) .{ .uniform = state } else .unavailable,
                        .biomes = if (view.biomes[4][index] != null) &self.delivery_biomes[4 * maximum_sections + index] else null,
                    };
                }
                self.delivery_present = view.header.uniform;
                self.delivery_saved = true;
                self.delivery_active = true;
                self.stored_hits.add(1);
                return true;
            }
        }
        self.stored_misses.add(1);
        return self.background.prepareInputsMode(self.deps.chunks, world, x, z, dimension, priority, .background);
    }

    pub fn prepareDeliverySections(self: *Lighting, requested: u32, priority: chunks.GenerationPriority) !bool {
        if (!self.delivery_saved) return true;
        assert(self.delivery_active);
        if (!self.stored_watch.unchanged()) {
            self.releaseDelivery();
            return false;
        }
        const region = self.stored_region.?;
        const all = (@as(u32, 1) << @intCast(region.count)) - 1;
        var selection = requested;
        if (selection & all & ~self.delivery_present != 0 and self.delivery_packed != null) {
            selection |= self.delivery_present;
            self.delivery_packed.?.release();
            self.delivery_packed = null;
            self.deps.chunks.releaseMany(self.delivery_leases[0..self.delivery_held]);
            self.delivery_held = 0;
            self.delivery_present = self.stored_view.?.header.uniform;
        }
        const missing = selection & all & ~self.delivery_present;
        if (missing == 0) return true;
        var positions: [maximum_sections]chunks.Section = undefined;
        var indices: [maximum_sections]usize = undefined;
        var count: usize = 0;
        for (0..region.count) |index| {
            if (missing & (@as(u32, 1) << @intCast(index)) == 0) continue;
            positions[count] = .{ .world = region.world, .x = region.x, .z = region.z, .y = region.minimum + @as(i32, @intCast(index)) };
            indices[count] = index;
            count += 1;
        }
        var packed_sections: [maximum_sections]chunks.Chunks.PackedSection = undefined;
        const packed_window = try self.deps.chunks.tryBorrowPacked(positions[0..count], packed_sections[0..count], self.stored_watch);
        if (packed_window) |window| {
            assert(self.delivery_packed == null);
            self.delivery_packed = window;
            for (packed_sections[0..count], indices[0..count]) |prepared, index| {
                self.delivery_sections[index].stamp = .{ .index = prepared.index, .generation = prepared.generation, .revision = prepared.revision, .storage = .encoded };
                self.delivery_sections[index].view = .{ .encoded = prepared.view };
                self.delivery_present |= @as(u32, 1) << @intCast(index);
            }
            if (!self.stored_watch.unchanged()) {
                self.releaseDelivery();
                return false;
            }
            return true;
        }
        if (!self.stored_watch.unchanged()) {
            self.releaseDelivery();
            return false;
        }
        assert(self.delivery_held + count <= region.count);
        if (self.delivery_held + count > self.deps.chunks.backgroundCapacity()) {
            self.releaseDelivery();
            self.delivery_saved = false;
            const dimension = self.deps.worlds.get(region.world).?.dimension;
            return self.background.prepareInputsMode(self.deps.chunks, region.world, region.x, region.z, dimension, priority, .background);
        }
        const leases = self.delivery_leases[self.delivery_held..][0..count];
        var ready: [1]bool = undefined;
        try self.deps.chunks.prepareMany(&.{.{ .sections = positions[0..count], .leases = leases, .priority = priority }}, &ready);
        if (!ready[0]) return false;
        self.delivery_held += count;
        if (!self.stored_watch.unchanged()) {
            self.releaseDelivery();
            return false;
        }
        for (leases, indices[0..count]) |lease, index| {
            const section = &self.delivery_sections[index];
            section.stamp = .{ .index = lease.record.index, .generation = lease.record.generation, .revision = lease.record.revision() };
            section.view = if (lease.view() == .uniform) .{ .uniform = lease.view().uniform } else .{ .chunk = lease.view() };
        }
        self.delivery_present |= missing;
        return true;
    }

    pub fn deliverySections(self: *const Lighting, selection: u32) []const Section {
        if (self.delivery_saved) assert(self.delivery_active);
        if (self.delivery_saved) assert(selection & ((@as(u32, 1) << @intCast(self.stored_region.?.count)) - 1) & ~self.delivery_present == 0);
        return if (self.delivery_saved) self.delivery_sections[0..self.stored_region.?.count] else self.background.sections();
    }

    pub fn deliveryBiomes(self: *const Lighting, output: []?*const [64]u16) void {
        const count = if (self.delivery_saved) self.stored_region.?.count else (self.background.pending orelse self.background.region.?).count;
        assert(output.len == 9 * count);
        for (0..9) |column| for (0..count) |section| {
            const index = column * maximum_sections + section;
            output[column * count + section] = if (self.delivery_saved)
                if (self.stored_view.?.biomes[column][section] != null) &self.delivery_biomes[index] else null
            else if (self.background.biome_present[index]) &self.background.biome_values[index] else null;
        };
    }

    pub fn deliveryData(self: *const Lighting) Data {
        if (!self.delivery_saved) return self.background.data();
        const view = &self.stored_view.?;
        return .{ .source = .{ .stored = view }, .count = @as(usize, view.header.count) + 2, .masks = .{ @intCast(view.masks[0]), @intCast(view.masks[1]) }, .coverage = view.header.coverage };
    }

    pub fn lightDelivery(self: *Lighting, selection: u32) !void {
        if (self.delivery_saved) {
            const all = (@as(u32, 1) << @intCast(self.stored_view.?.header.count)) - 1;
            assert(selection & all & ~self.stored_view.?.header.coverage == 0);
            return;
        }
        const region = self.background.pending orelse self.background.region.?;
        const persist = self.config.stored and self.deps.chunks.lightClean(.{ .world = region.world, .x = region.x, .z = region.z }, region.minimum, region.count);
        try self.background.solve(if (persist) (@as(u32, 1) << @intCast(region.count)) - 1 else selection);
        self.publish(self.background);
        if (persist) _ = try self.persistBackground();
    }

    pub fn bake(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension) !bool {
        if (!try self.background.prepare(self.deps.chunks, world, x, z, dimension, 0)) return false;
        return self.persistBackground();
    }

    fn persistBackground(self: *Lighting) !bool {
        const region = self.background.region.?;
        const all = (@as(u32, 1) << @intCast(region.count)) - 1;
        if (self.background.coverage != all) return false;
        const column: chunks.Light.Column = .{ .world = region.world, .x = region.x, .z = region.z };
        const snapshot = try self.deps.chunks.lightSnapshot(column, region.minimum, region.count, null);
        if (!snapshot.clean) return false;
        const definition = self.deps.worlds.get(region.world).?.dimension;
        if (!self.background.current(self.deps.chunks, region.world, region.x, region.z, definition)) return false;
        self.stored_region = null;
        self.stored_view = null;
        var biomes: [9]u32 = @splat(0);
        var uniform: u32 = 0;
        var states: [chunks.Light.maximum_sections]u16 = @splat(0);
        for (0..region.count) |section| if (self.background.uniforms[4 * maximum_sections + section]) |state| {
            uniform |= @as(u32, 1) << @intCast(section);
            states[section] = state;
        };
        for (0..9) |neighbor| for (0..region.count) |section| {
            if (self.background.biome_present[neighbor * maximum_sections + section]) biomes[neighbor] |= @as(u32, 1) << @intCast(section);
        };
        self.stored_workspace.begin(.{ .rules = self.rules, .minimum = region.minimum, .count = @intCast(region.count), .skylight = region.skylight, .coverage = all, .revisions = snapshot.revisions, .biomes = biomes, .uniform = uniform, .states = states });
        for (0..9) |neighbor| for (0..region.count) |section| {
            if (biomes[neighbor] & (@as(u32, 1) << @intCast(section)) != 0) self.stored_workspace.biome(&self.background.biome_values[neighbor * maximum_sections + section]);
        };
        for ([_]lighting.Layer{ .block, .sky }) |layer| for (0..region.count + 2) |section| {
            self.background.engine.packSection(layer, .{ 1, section, 1 }, self.stored_workspace.section());
            self.stored_workspace.commitSection();
        };
        try self.deps.chunks.putLight(column, try self.stored_workspace.finish());
        return true;
    }

    pub fn prepare(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, player: usize) !bool {
        if (dimension.sectionCount() == 0 or dimension.sectionCount() > maximum_sections) return error.UnsupportedLightingHeight;
        const all = (@as(u32, 1) << @intCast(dimension.sectionCount())) - 1;
        if (self.background.coverage == all and self.background.current(self.deps.chunks, world, x, z, dimension)) return true;
        if (!try self.background.prepare(self.deps.chunks, world, x, z, dimension, player)) return false;
        self.publish(self.background);
        return true;
    }

    /// Bits select sections from the dimension minimum. Their lighting dependencies remain included.
    pub fn lightPrepared(self: *Lighting, selection: u32) !void {
        try self.background.solve(selection);
        self.publish(self.background);
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
            var query = first;
            while (query != positions.len) : (query = next[query]) {
                const section: u5 = @intCast(@divFloor(positions[query].y, 16) - region.minimum);
                if (entry.coverage & (@as(u32, 1) << section) == 0) break;
            }
            if (query != positions.len) continue;
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
        if (workspace.coverage == 0) return;
        const region = workspace.region.?;
        self.mutex.lockUncancelable(self.deps.chunks.io);
        var chosen: ?*Entry = null;
        for (self.entries) |*entry| {
            if (entry.building or entry.region == null or !std.meta.eql(entry.region.?, region)) continue;
            if (entry.watch.unchanged() and entry.coverage & workspace.coverage == workspace.coverage) {
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
                if (workspace.coverage & (@as(u32, 1) << @intCast(section)) == 0) continue;
                workspace.engine.packSection(.block, .{ 1, section + 1, 1 }, &entry.levels[0][section]);
                workspace.engine.packSection(.sky, .{ 1, section + 1, 1 }, &entry.levels[1][section]);
            }
        }
        self.mutex.lockUncancelable(self.deps.chunks.io);
        defer self.mutex.unlock(self.deps.chunks.io);
        entry.region = if (valid) region else null;
        entry.coverage = workspace.coverage;
        entry.building = false;
    }
};

fn stateIndex(column: usize, section: usize, local: usize) usize {
    const x = column % 3 * 16 + local % 16;
    const z = column / 3 * 16 + local / 16 % 16;
    const y = (section + 1) * 16 + local / 256;
    return (y * side + z) * side + x;
}

/// Borrowed until the next lighting preparation. Encode before preparing more terrain.
pub const Data = struct {
    source: union(enum) { computed: *const lighting.Engine, stored: *const chunks.Light.View },
    count: usize,
    masks: [2]u32,
    coverage: u32 = std.math.maxInt(u32),

    disclosure: u32 = std.math.maxInt(u32),
    // Unselected light sections retain their existing client data.
    selection: ?u32 = null,
    retained: [2]u32 = .{ 0, 0 },

    pub const capacity = 64 + 2 * (maximum_sections + 2) * 2051;

    fn selected(self: Data) [2]u32 {
        const selection = self.selection orelse (@as(u32, 1) << @intCast(self.count)) - 1;
        return .{ selection & ~self.retained[0], selection & ~self.retained[1] };
    }

    fn nonzero(self: Data) [2]u32 {
        const disclosure = (self.disclosure << 1) | 1 | (@as(u32, 1) << @intCast(self.count - 1));
        return .{ self.masks[0] & disclosure, self.masks[1] & disclosure };
    }

    pub fn write(self: Data, writer: *std.Io.Writer) !void {
        assert(self.count > 2 and self.count <= maximum_sections + 2);
        const all = (@as(u64, 1) << @intCast(self.count)) - 1;
        assert((@as(u64, self.masks[0] | self.masks[1]) & ~all) == 0);
        switch (self.source) {
            .computed => |engine| assert(engine.dimensions.x >= 32 and engine.dimensions.z >= 32 and engine.dimensions.y >= self.count * 16),
            .stored => |view| assert(@as(usize, view.header.count) + 2 == self.count),
        }
        const selection = self.selection orelse @as(u32, @intCast(all));
        assert(@as(u64, selection) & ~all == 0);
        for (self.retained) |bits| assert(bits & ~selection == 0);
        const world = (@as(u32, 1) << @intCast(self.count - 2)) - 1;
        assert(self.disclosure & (selection >> 1) & world & ~self.coverage == 0);
        const selected_sections = self.selected();
        const nonzero_sections = self.nonzero();
        const filtered = [2]u32{ nonzero_sections[0] & selected_sections[0], nonzero_sections[1] & selected_sections[1] };
        for ([_]u32{ filtered[1], filtered[0] }) |bits| {
            try varint(writer, 1);
            try writer.writeInt(u64, bits, .big);
        }
        for ([_]u32{ selected_sections[1] & ~filtered[1], selected_sections[0] & ~filtered[0] }) |bits| {
            try varint(writer, 1);
            try writer.writeInt(u64, bits, .big);
        }
        inline for (.{ lighting.Layer.sky, lighting.Layer.block }, .{ 1, 0 }) |layer, index| {
            const bits = filtered[index];
            try varint(writer, @popCount(bits));
            for (0..self.count) |section| {
                if (bits & (@as(u32, 1) << @intCast(section)) == 0) continue;
                try varint(writer, 2048);
                switch (self.source) {
                    .computed => |engine| {
                        const bytes = try writer.writableSlice(2048);
                        engine.packSection(layer, .{ 1, section, 1 }, bytes[0..2048]);
                    },
                    .stored => |view| {
                        const bytes = try writer.writableSlice(2048);
                        view.layers[index][section].write(bytes[0..2048]);
                    },
                }
            }
        }
    }
};

/// One client column. Reset on unload, dimension changes, or a new player lifetime.
pub const Receipt = struct {
    // Stored snapshots validate all nine input columns and the lighting rules.
    // Computed arrays have no such identity and are never retained as nonempty data.
    const Version = struct {
        rules: [32]u8,
        revisions: [9]u64,
    };

    pub const Update = struct {
        version: ?Version,
        count: usize,
        selected: [2]u32,
        nonzero: [2]u32,

        pub fn capture(data: Data) Update {
            assert(data.count > 2 and data.count <= maximum_sections + 2);
            if (data.source == .stored) {
                const header = data.source.stored.header;
                assert(@as(usize, header.count) + 2 == data.count);
                assert(header.coverage == (@as(u32, 1) << @intCast(header.count)) - 1);
            }
            return .{
                .version = switch (data.source) {
                    .stored => |view| .{ .rules = view.header.rules, .revisions = view.header.revisions },
                    .computed => null,
                },
                .count = data.count,
                .selected = data.selected(),
                .nonzero = data.nonzero(),
            };
        }
    };

    version: Version = .{ .rules = @splat(0), .revisions = @splat(0) },
    present: [2]u32 = .{ 0, 0 },
    empty: [2]u32 = .{ 0, 0 },
    count: usize = 0,

    pub fn retained(self: *const Receipt, data: Data) [2]u32 {
        if (self.count != data.count) return .{ 0, 0 };
        const selected = data.selection orelse (@as(u32, 1) << @intCast(data.count)) - 1;
        const nonzero = data.nonzero();
        const version = Update.capture(data).version;
        const unchanged = if (version) |value| std.meta.eql(self.version, value) else false;
        var result: [2]u32 = undefined;
        for (&result, 0..) |*bits, layer| {
            bits.* = selected & ((self.empty[layer] & ~nonzero[layer]) | (if (unchanged) self.present[layer] & nonzero[layer] else 0));
        }
        return result;
    }

    /// Commit only the masks admitted to the client's ordered output queue.
    pub fn apply(self: *Receipt, update: Update) void {
        assert(update.count > 2 and update.count <= maximum_sections + 2);
        const all = (@as(u32, 1) << @intCast(update.count)) - 1;
        if (self.count != update.count) self.* = .{ .count = update.count };
        if (update.version) |version| {
            if (!std.meta.eql(self.version, version)) self.present = .{ 0, 0 };
            self.version = version;
        }
        for (0..2) |layer| {
            const selected = update.selected[layer];
            assert((selected | update.nonzero[layer]) & ~all == 0);
            self.present[layer] &= ~selected;
            self.empty[layer] = (self.empty[layer] & ~selected) | (selected & ~update.nonzero[layer]);
            if (update.version != null) self.present[layer] |= selected & update.nonzero[layer];
            assert(self.present[layer] & self.empty[layer] == 0);
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

test "section rows preserve dense strided uniform and unaligned chunk layouts" {
    var dense: [4096]u16 = undefined;
    var bytes: [8193]u8 = undefined;
    const strided = try std.testing.allocator.alloc(u16, side * side * 16);
    defer std.testing.allocator.free(strided);
    @memset(strided, 0xffff);
    for (&dense, 0..) |*state, index| {
        state.* = @truncate(index * 331 + 5);
        std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], state.*, .little);
        strided[index / 256 * side * side + index / 16 % 16 * side + index % 16] = state.*;
    }
    const views = [_]Section.View{ .{ .uniform = 42 }, .{ .dense = &dense }, .{ .rows = strided }, .{ .chunk = .{ .uniform = 42 } }, .{ .chunk = .{ .dense = bytes[1..] } } };
    for (views) |view| for (0..256) |row| {
        const states = view.row(@intCast(row));
        for (states, 0..) |state, x| try std.testing.expectEqual(view.get(@intCast(row * 16 + x)), state);
    };
}

test "partial light updates preserve unselected client sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var engine = try lighting.Engine.init(arena.allocator(), .{ .x = 48, .y = 48, .z = 48 }, try game_data.lighting.init(arena.allocator()));
    try engine.load(.{ .uniform = 0 });
    engine.relight(true);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const data: Data = .{ .source = .{ .computed = &engine }, .count = 3, .masks = .{ 0, 7 }, .disclosure = 1, .selection = 2 };
    try data.write(&writer);
    for ([_]u64{ 2, 0, 0, 2 }, 0..) |expected, index| {
        try std.testing.expectEqual(@as(u8, 1), buffer[index * 9]);
        try std.testing.expectEqual(expected, std.mem.readInt(u64, buffer[index * 9 + 1 ..][0..8], .big));
    }
}

test "lighting receipts require an accepted snapshot and preserve layer independence" {
    var view: chunks.Light.View = .{ .header = .{ .rules = @splat(1), .minimum = 0, .count = 1, .skylight = true, .coverage = 1, .revisions = @splat(0), .biomes = @splat(0) }, .masks = .{ 2, 7 } };
    const data: Data = .{ .source = .{ .stored = &view }, .count = 3, .masks = .{ 2, 7 }, .disclosure = 1 };
    var receipt: Receipt = .{};
    const original = Receipt.Update.capture(data);
    try std.testing.expectEqual([2]u32{ 0, 0 }, receipt.retained(data));
    receipt.apply(original);
    try std.testing.expectEqual([2]u32{ 7, 7 }, receipt.retained(data));

    var changed = data;
    changed.masks[0] = 0;
    try std.testing.expectEqual([2]u32{ 5, 7 }, receipt.retained(changed));
    changed.retained = receipt.retained(changed);
    receipt.apply(Receipt.Update.capture(changed));
    try std.testing.expectEqual([2]u32{ 7, 7 }, receipt.retained(changed));
    try std.testing.expectEqual([2]u32{ 5, 7 }, receipt.retained(data));
    receipt.apply(original);

    var concealed = data;
    concealed.disclosure = 0;
    try std.testing.expectEqual([2]u32{ 5, 5 }, receipt.retained(concealed));
    concealed.retained = receipt.retained(concealed);
    receipt.apply(Receipt.Update.capture(concealed));
    try std.testing.expectEqual([2]u32{ 5, 5 }, receipt.retained(data));
    receipt.apply(original);

    for (&view.header.revisions) |*revision| {
        revision.* += 1;
        try std.testing.expectEqual([2]u32{ 5, 0 }, receipt.retained(data));
        receipt.apply(Receipt.Update.capture(data));
        try std.testing.expectEqual([2]u32{ 7, 7 }, receipt.retained(data));
    }
    view.header.rules[0] += 1;
    try std.testing.expectEqual([2]u32{ 5, 0 }, receipt.retained(data));
    receipt.apply(Receipt.Update.capture(data));
    receipt = .{};
    try std.testing.expectEqual([2]u32{ 0, 0 }, receipt.retained(data));
}

test "omitted lighting leaves client arrays unchanged and computed light remains conservative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var engine = try lighting.Engine.init(arena.allocator(), .{ .x = 48, .y = 48, .z = 48 }, try game_data.lighting.init(arena.allocator()));
    try engine.load(.{ .uniform = 0 });
    engine.relight(true);
    var buffer: [8192]u8 = undefined;
    var receipt: Receipt = .{};
    var data: Data = .{ .source = .{ .computed = &engine }, .count = 3, .masks = .{ 0, 7 }, .disclosure = 1 };
    receipt.apply(Receipt.Update.capture(data));
    try std.testing.expectEqual([2]u32{ 7, 0 }, receipt.retained(data));
    data.retained = receipt.retained(data);
    var writer: std.Io.Writer = .fixed(&buffer);
    try data.write(&writer);
    for ([_]u64{ 7, 0, 0, 0 }, 0..) |expected, index| {
        try std.testing.expectEqual(@as(u8, 1), buffer[index * 9]);
        try std.testing.expectEqual(expected, std.mem.readInt(u64, buffer[index * 9 + 1 ..][0..8], .big));
    }
    var dark = data;
    dark.masks = .{ 0, 0 };
    dark.retained = .{ 0, 0 };
    receipt.apply(Receipt.Update.capture(dark));
    dark.retained = receipt.retained(dark);
    writer = .fixed(&buffer);
    try dark.write(&writer);
    try std.testing.expectEqual(@as(usize, 38), writer.end);
    for (0..4) |index| try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buffer[index * 9 + 1 ..][0..8], .big));
    try std.testing.expectEqual([2]u32{ 7, 0 }, receipt.retained(data));
}

test "retained lighting matches a client model through rejected updates reveals and unloads" {
    var view: chunks.Light.View = .{ .header = .{ .rules = @splat(1), .minimum = 0, .count = 1, .skylight = true, .coverage = 1, .revisions = @splat(0), .biomes = @splat(0) } };
    var receipt: Receipt = .{};
    var client: [2][3]?u8 = @splat(@splat(null));
    var buffer: [Data.capacity]u8 = undefined;
    for (0..512) |step| {
        if (step % 31 == 0) {
            receipt = .{};
            client = @splat(@splat(null));
        }
        view.header.revisions[step % 9] += 1;
        var data: Data = .{ .source = .{ .stored = &view }, .count = 3, .masks = .{ 0, 0 }, .disclosure = @intCast(step % 2), .selection = @intCast(step % 8) };
        for (0..2) |layer| for (0..3) |section| {
            const level: u4 = @intCast((step / (layer + section + 1) * 7) % 16);
            view.layers[layer][section] = .{ .uniform = level };
            if (level != 0) data.masks[layer] |= @as(u32, 1) << @intCast(section);
        };
        const first = Receipt.Update.capture(data);
        const accepted = step % 3 != 0;
        for (0..2) |pass| {
            data.retained = receipt.retained(data);
            var writer: std.Io.Writer = .fixed(&buffer);
            try data.write(&writer);
            var reader = std.Io.Reader.fixed(writer.buffered());
            var masks: [4]u64 = undefined;
            for (&masks) |*mask| {
                try std.testing.expectEqual(@as(u32, 1), try reader.takeLeb128(u32));
                mask.* = try reader.takeInt(u64, .big);
            }
            var next = client;
            for ([_]usize{ 1, 0 }, 0..) |layer, order| {
                try std.testing.expectEqual(@as(u32, @popCount(masks[order])), try reader.takeLeb128(u32));
                for (0..3) |section| {
                    const bit = @as(u64, 1) << @intCast(section);
                    try std.testing.expect(masks[order] & masks[order + 2] & bit == 0);
                    if (masks[order] & bit != 0) {
                        try std.testing.expectEqual(@as(u32, 2048), try reader.takeLeb128(u32));
                        const bytes = try reader.take(2048);
                        try std.testing.expect(std.mem.allEqual(u8, bytes, bytes[0]));
                        next[layer][section] = bytes[0];
                    } else if (masks[order + 2] & bit != 0) next[layer][section] = 0;
                    if (first.selected[layer] & @as(u32, @intCast(bit)) != 0) {
                        const expected = if (first.nonzero[layer] & @as(u32, @intCast(bit)) != 0) @as(u8, view.layers[layer][section].uniform) * 17 else 0;
                        try std.testing.expectEqual(@as(?u8, expected), next[layer][section]);
                    } else try std.testing.expectEqual(client[layer][section], next[layer][section]);
                }
            }
            try std.testing.expectEqual(writer.end, reader.seek);
            if (pass == 0 and accepted) {
                receipt.apply(Receipt.Update.capture(data));
                client = next;
            }
        }
    }
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
    const service = try Lighting.init(allocator, .{ .cache_columns = 1 }, .{ .metrics = &registry, .blocks = try vanilla_definitions.blocks(allocator), .chunks = terrain, .worlds = dimensions });
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
        return self.initHeight(1);
    }

    fn initHeight(self: *ConcurrentLighting, sections: u16) !void {
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
        self.terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 8, .demand_sections = 2, .cache_groups = 2 }, .{
            .metrics = &self.registry,
            .storage = try self.store.openSpace("chunks"),
            .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
        });
        self.dimensions = try worlds.Worlds.allocate(allocator, .{ .maximum = 2 });
        for ([_][]const u8{ "test:sky", "test:dark" }, 0..) |name, index| {
            const world = try self.dimensions.create(.{ .name = name, .dimension = .{ .name = name, .minimum_section = 0, .section_count = sections, .skylight = index == 0 } });
            assert(world == index);
        }
        self.service = try Lighting.init(allocator, .{ .cache_columns = 1 }, .{ .metrics = &self.registry, .blocks = try vanilla_definitions.blocks(allocator), .chunks = self.terrain, .worlds = self.dimensions });
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
    const Mode = enum { prepare, snapshot, publish, settle, selected, bake, delivery };
    const Command = struct { mode: Mode, world: u32 = 0, x: i32 = 0, selection: u32 = std.math.maxInt(u32), additional: ?u32 = null };

    fixture: *ConcurrentLighting,
    thread: ?std.Thread = null,
    ready: std.Io.Event = .unset,
    request: std.Io.Event = .unset,
    entered: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
    command: Command = undefined,
    result: anyerror!void = {},
    held_sections: usize = 0,
    held_groups: usize = 0,
    states: [maximum_sections]u16 = @splat(0),

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
        defer fixture.service.releaseDelivery();
        switch (command.mode) {
            .prepare => _ = try fixture.service.prepare(command.world, command.x, 0, dimension, 0),
            .publish => fixture.service.publish(fixture.service.background),
            .bake => if (!try fixture.service.persistBackground()) return error.LightDependenciesDirty,
            .snapshot, .settle, .selected, .delivery => {
                for (0..128) |_| {
                    fixture.terrain.ready().reset();
                    const complete = switch (command.mode) {
                        .snapshot => try fixture.service.background.prepare(fixture.terrain, command.world, command.x, 0, dimension, 0),
                        .selected => try fixture.service.background.prepareInputs(fixture.terrain, command.world, command.x, 0, dimension, 0),
                        .delivery => try fixture.service.prepareDelivery(command.world, command.x, 0, dimension, .{}) and try fixture.service.prepareDeliverySections(command.selection, .{}),
                        else => try fixture.service.prepare(command.world, command.x, 0, dimension, 0),
                    };
                    if (complete) {
                        if (command.mode == .selected) try fixture.service.lightPrepared(command.selection);
                        if (command.mode == .delivery) {
                            if (command.additional) |selection| {
                                if (!try fixture.service.prepareDeliverySections(selection, .{})) continue;
                            }
                            self.held_sections = fixture.service.delivery_held;
                            self.held_groups = if (fixture.service.delivery_packed) |window| window.count else 0;
                            for (fixture.service.deliverySections(command.selection), 0..) |section, index| {
                                if (section.view != .unavailable) self.states[index] = section.view.get(8 * 256 + 8 * 16 + 8);
                            }
                            try fixture.service.lightDelivery(command.selection);
                        }
                        return;
                    }
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

test "lighting windows retain settled overlap and rebuild after an overlapping edit" {
    var fixture: ConcurrentLighting = .{};
    try fixture.init();
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const workspace = fixture.service.background;
    var fresh = try lighting.Engine.init(std.testing.allocator, workspace.engine.dimensions, workspace.engine.registry);
    defer fresh.deinit();
    const actual = try std.testing.allocator.alloc(u8, workspace.states.len / 2);
    defer std.testing.allocator.free(actual);
    const expected = try std.testing.allocator.alloc(u8, actual.len);
    defer std.testing.allocator.free(expected);
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    for ([_]i32{ -1, 0, 1, 2 }) |x| {
        try fixture.terrain.setBlock(0, .{ .x = x * 16 + 5, .y = 8, .z = 8 }, glowstone);
    }
    for ([_]i32{ 0, 1, 2, 1, 0, -1, 0 }, 0..) |x, step| {
        if (step == 3) try fixture.terrain.setBlock(0, .{ .x = 21, .y = 8, .z = 8 }, stone);
        try worker.begin(.{ .mode = .snapshot, .x = x });
        try worker.finish();
        try fresh.load(.{ .ring = .{ .states = workspace.states, .origin = workspace.origin, .sections = .{ .uniforms = &workspace.uniforms, .first = 1, .count = workspace.region.?.count, .stride = maximum_sections } } });
        fresh.relight(true);
        for ([_]lighting.Layer{ .block, .sky }) |layer| {
            workspace.engine.pack(layer, actual);
            fresh.pack(layer, expected);
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
        try std.testing.expectEqual(if (x == 1 and step >= 3) stone else glowstone, workspace.sections()[0].view.get(8 * 256 + 8 * 16 + 5));
    }
    try std.testing.expect(workspace.work.scrolls >= 4);
    try std.testing.expectEqual(@as(usize, 2), workspace.work.relights);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "stored lighting matches computed packets and rejects dirty or persisted neighboring edits" {
    var fixture: ConcurrentLighting = .{};
    try fixture.init();
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const expected = try std.testing.allocator.alloc(u8, Data.capacity);
    defer std.testing.allocator.free(expected);
    const actual = try std.testing.allocator.alloc(u8, Data.capacity);
    defer std.testing.allocator.free(actual);
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const position: chunks.Position = .{ .x = -1, .y = 8, .z = 8 };
    try fixture.terrain.setBlock(0, position, glowstone);
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    var before: std.Io.Writer = .fixed(expected);
    try fixture.service.background.data().write(&before);
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    try worker.begin(.{ .mode = .bake });
    try worker.finish();
    try fixture.store.waitDurable(try fixture.store.commit(1));
    const solves = fixture.service.background.work.relights;
    const deliveries = [_]Lighting.Delivery{.{ .world = 0, .x = 0, .z = 0, .dimension = fixture.dimensions.get(0).?.dimension }};
    try fixture.service.prepareDeliveries(&deliveries);
    try worker.begin(.{ .mode = .delivery });
    try worker.finish();
    try std.testing.expect(fixture.service.delivery_saved);
    try std.testing.expectEqual(solves, fixture.service.background.work.relights);
    var after: std.Io.Writer = .fixed(actual);
    try fixture.service.deliveryData().write(&after);
    try std.testing.expectEqualSlices(u8, before.buffered(), after.buffered());
    try fixture.service.prepareDeliveries(&deliveries);
    try fixture.terrain.setBlock(0, position, 0);
    const dirty = try fixture.terrain.lightSnapshot(.{ .world = 0, .x = 0, .z = 0 }, 0, 1, null);
    try std.testing.expect(!dirty.clean);
    try worker.begin(.{ .mode = .delivery });
    try worker.finish();
    try std.testing.expect(!fixture.service.delivery_saved);
    try std.testing.expectEqual(@as(u8, 0), fixture.service.background.engine.get(.block, stateIndex(4, 0, 8 * 256 + 8 * 16)));
    try worker.begin(.{ .mode = .bake });
    try std.testing.expectError(error.LightDependenciesDirty, worker.finish());
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    try worker.begin(.{ .mode = .delivery });
    try worker.finish();
    try std.testing.expect(!fixture.service.delivery_saved);
    try worker.begin(.{ .mode = .delivery });
    try worker.finish();
    try std.testing.expect(fixture.service.delivery_saved);
    const data = fixture.service.deliveryData();
    var plane: [2048]u8 = undefined;
    data.source.stored.layers[0][1].write(&plane);
    try std.testing.expect(std.mem.allEqual(u8, &plane, 0));
    try std.testing.expect(!fixture.bounded.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "stored delivery borrows only requested nonuniform sections and accumulates protocol groups" {
    var fixture: ConcurrentLighting = .{};
    try fixture.initHeight(3);
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 8, .z = 8 }, stone);
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 24, .z = 8 }, stone);
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    try worker.begin(.{ .mode = .bake });
    try worker.finish();
    try worker.begin(.{ .mode = .delivery, .selection = 0 });
    try worker.finish();
    try std.testing.expect(fixture.service.delivery_saved);
    try std.testing.expectEqual(@as(usize, 0), worker.held_sections);
    try std.testing.expect(fixture.service.delivery_sections[0].view == .unavailable);
    try std.testing.expect(fixture.service.delivery_sections[1].view == .unavailable);
    try std.testing.expect(fixture.service.delivery_sections[2].view == .uniform);
    try std.testing.expectEqual(@as(?u16, 0), fixture.service.delivery_sections[2].stamp.constant);
    try worker.begin(.{ .mode = .delivery, .selection = 1 });
    try worker.finish();
    try std.testing.expectEqual(@as(usize, 0), worker.held_sections);
    try std.testing.expect(worker.held_groups > 0);
    try std.testing.expect(fixture.service.delivery_sections[0].view != .unavailable);
    try std.testing.expect(fixture.service.delivery_sections[1].view == .unavailable);
    try worker.begin(.{ .mode = .delivery, .selection = 1, .additional = 2 });
    try worker.finish();
    try std.testing.expectEqual(@as(usize, 0), worker.held_sections);
    try std.testing.expect(worker.held_groups > 0);
    try std.testing.expect(!fixture.bounded.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "stored delivery exceeds decoded cache capacity without expanding sections" {
    var fixture: ConcurrentLighting = .{};
    try fixture.initHeight(8);
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const count = fixture.terrain.backgroundCapacity() + 1;
    try std.testing.expect(count <= 8);
    for (0..count) |index| try fixture.terrain.setBlock(0, .{ .x = 8, .y = @intCast(index * 16 + 8), .z = 8 }, stone);
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    try worker.begin(.{ .mode = .bake });
    try worker.finish();
    try worker.begin(.{ .mode = .delivery, .selection = (@as(u32, 1) << @intCast(count)) - 1 });
    try worker.finish();
    try std.testing.expect(fixture.service.delivery_saved);
    try std.testing.expectEqual(@as(usize, 0), worker.held_sections);
    try std.testing.expect(worker.held_groups > 0);
    for (worker.states[0..count]) |state| try std.testing.expectEqual(stone, state);
    try std.testing.expect(!fixture.bounded.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "stored lighting delivery stays current while edited dependencies are checkpointed" {
    var fixture: ConcurrentLighting = .{};
    try fixture.init();
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const position: chunks.Position = .{ .x = -1, .y = 8, .z = 8 };
    const space = try fixture.store.openSpace(chunks.Chunks.id);
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    try fixture.terrain.checkpoint(space);
    try worker.begin(.{ .mode = .bake });
    try worker.finish();
    for (0..32) |iteration| {
        const lit = iteration % 2 == 0;
        try fixture.terrain.setBlock(0, position, if (lit) glowstone else 0);
        try worker.begin(.{ .mode = .delivery });
        try fixture.terrain.checkpoint(space);
        try worker.finish();
        var plane: [2048]u8 = undefined;
        switch (fixture.service.deliveryData().source) {
            .stored => |view| view.layers[0][1].write(&plane),
            .computed => |engine| engine.packSection(.block, .{ 1, 1, 1 }, &plane),
        }
        const local = 8 * 256 + 8 * 16;
        try std.testing.expectEqual(@as(u8, if (lit) 14 else 0), plane[local / 2] & 15);
        try worker.begin(.{ .mode = .bake });
        try worker.finish();
    }
    try std.testing.expect(!fixture.bounded.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "partial lighting preserves hidden source influence and rejects uncovered cache queries" {
    var fixture: ConcurrentLighting = .{};
    try fixture.initHeight(3);
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const hidden: chunks.Position = .{ .x = 0, .y = 8, .z = 8 };
    const boundary: chunks.Position = .{ .x = 0, .y = 31, .z = 8 };
    const visible: chunks.Position = .{ .x = 0, .y = 32, .z = 8 };
    try fixture.terrain.setBlock(0, hidden, glowstone);
    try fixture.terrain.setBlock(0, boundary, glowstone);
    try worker.begin(.{ .mode = .selected, .selection = 4 });
    try worker.finish();
    try std.testing.expectEqual(@as(u32, 4), fixture.service.background.coverage);
    var samples: [1]Sample = undefined;
    var hits = fixture.service.cache_hits;
    try fixture.service.sampleMany(0, &.{visible}, &samples);
    try std.testing.expectEqual(hits + 1, fixture.service.cache_hits);
    try std.testing.expectEqual(Sample{ .block = 14, .sky = 15 }, samples[0]);
    const misses = fixture.service.cache_misses;
    try fixture.service.sampleMany(0, &.{hidden}, &samples);
    try std.testing.expectEqual(misses + 1, fixture.service.cache_misses);
    try std.testing.expectEqual(Sample{ .block = 15, .sky = 0 }, samples[0]);
    try fixture.terrain.setBlock(0, boundary, 0);
    try worker.begin(.{ .mode = .selected, .selection = 4 });
    try worker.finish();
    try fixture.service.sampleMany(0, &.{visible}, &samples);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[0]);
    try worker.begin(.{ .mode = .selected, .selection = 1 });
    try worker.finish();
    hits = fixture.service.cache_hits;
    try fixture.service.sampleMany(0, &.{hidden}, &samples);
    try std.testing.expectEqual(hits + 1, fixture.service.cache_hits);
    try std.testing.expectEqual(Sample{ .block = 15, .sky = 0 }, samples[0]);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "moving partial lighting uses requested depth and matches a complete solve" {
    var fixture: ConcurrentLighting = .{};
    try fixture.initHeight(3);
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const workspace = fixture.service.background;
    var fresh = try lighting.Engine.init(std.testing.allocator, workspace.engine.dimensions, workspace.engine.registry);
    defer fresh.deinit();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    for ([_]i32{ -1, 0, 1, 2, 3 }) |x| try fixture.terrain.setBlock(0, .{ .x = x * 16 + 8, .y = 31, .z = 8 }, glowstone);
    const Step = struct { x: i32, selection: u32, coverage: u32, first: usize };
    const steps = [_]Step{
        .{ .x = 0, .selection = 2, .coverage = 6, .first = 1 },
        .{ .x = 1, .selection = 4, .coverage = 4, .first = 2 },
        .{ .x = 2, .selection = 4, .coverage = 4, .first = 2 },
        .{ .x = 1, .selection = 2, .coverage = 6, .first = 1 },
        .{ .x = 0, .selection = 4, .coverage = 4, .first = 2 },
        .{ .x = 0, .selection = 2, .coverage = 6, .first = 1 },
        .{ .x = 0, .selection = 4, .coverage = 6, .first = 1 },
        .{ .x = 3, .selection = 0, .coverage = 0, .first = 4 },
    };
    for (steps) |step| {
        try worker.begin(.{ .mode = .selected, .x = step.x, .selection = step.selection });
        try worker.finish();
        try std.testing.expectEqual(step.coverage, workspace.coverage);
        try std.testing.expectEqual(step.first * side * side, workspace.engine.minimum);
        if (step.selection == 0) {
            try std.testing.expect(workspace.engine.uniform_air);
            try std.testing.expectEqual(@as(u64, 0), workspace.engine.work.loaded_rows);
        }
        try fresh.load(.{ .ring = .{ .states = workspace.states, .origin = workspace.origin, .sections = .{ .uniforms = &workspace.uniforms, .first = 1, .count = 3, .stride = maximum_sections } } });
        fresh.relight(true);
        for ([_]lighting.Layer{ .block, .sky }) |layer| for (@min(step.first, 3)..3) |section| for (0..4096) |local| {
            const index = stateIndex(4, section, local);
            try std.testing.expectEqual(fresh.get(layer, index), workspace.engine.get(layer, index));
        };
    }
    try std.testing.expectEqual(@as(usize, 6), workspace.work.relights);
    try std.testing.expectEqual(@as(usize, 1), workspace.work.scrolls);
    try std.testing.expect(!fixture.bounded.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

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

test "persisted lighting and generated eviction fit the worker stack without runtime allocation" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/cold-stack", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{});
    const options: storage.Store.Options = .{ .path = path, .io_mode = .standard, .maximum_wal_pages = 4096 };
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                request.output[0] = 1;
                for (0..4096) |index| {
                    const state: u16 = if (request.section.y < 4 and index % 17 < 8) game_data.registry.block_stone_default_state else 0;
                    std.mem.writeInt(u16, request.output[1 + index * 2 ..][0..2], state, .little);
                }
                request.result = chunks.encoding.dense_block_bytes;
            }
        }
    };
    var store = try storage.Store.init(allocator, io, options);
    var closed = false;
    defer if (!closed) store.deinit();
    const space = try store.openSpace(chunks.Chunks.id);
    const terrain = try chunks.Chunks.init(allocator, io, .{}, .{ .metrics = &registry, .storage = space, .record_workspaces = resources });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    for (0..9) |column| {
        var sections: [maximum_sections]chunks.Section = undefined;
        var leases: [maximum_sections]chunks.Lease = undefined;
        for (&sections, 0..) |*section, index| section.* = .{ .world = 0, .x = @as(i32, @intCast(column % 3)) - 1, .z = @as(i32, @intCast(column / 3)) - 1, .y = @as(i32, @intCast(index)) - 4 };
        try terrain.acquireMany(&sections, &leases);
        terrain.releaseMany(&leases);
    }
    try terrain.checkpoint(space);
    try store.waitDurable(try store.commit(1));
    store.deinit();
    closed = true;
    var reopened = try storage.Store.init(allocator, io, options);
    defer reopened.deinit();
    const restored = try chunks.Chunks.init(allocator, io, .{}, .{ .metrics = &registry, .storage = try reopened.openSpace(chunks.Chunks.id), .record_workspaces = resources });
    restored.setSource(chunks.Source.init(&source, Source.read));
    var dirty_sections: [maximum_sections]chunks.Section = undefined;
    var dirty_leases: [maximum_sections]chunks.Lease = undefined;
    for (&dirty_sections, 0..) |*section, index| section.* = .{ .world = 0, .x = 32, .z = 0, .y = @as(i32, @intCast(index)) - 4 };
    try restored.acquireMany(&dirty_sections, &dirty_leases);
    restored.releaseMany(&dirty_leases);
    const workspace = try Workspace.init(allocator, restored, try game_data.lighting.init(allocator));
    failing.fail_index = failing.alloc_index;
    const Actor = struct {
        workspace: *Workspace,
        terrain: *chunks.Chunks,
        result: anyerror!void = error.NotRun,

        fn run(self: *@This()) void {
            self.terrain.attach();
            defer self.terrain.stop();
            self.result = self.prepare();
        }

        fn prepare(self: *@This()) !void {
            const dimension: worlds.Worlds.Dimension = .{ .name = "test:cold", .minimum_section = -4, .section_count = maximum_sections, .skylight = true };
            for (0..9 * maximum_sections) |_| {
                if (try self.workspace.prepare(self.terrain, 0, 0, 0, dimension, 0)) return;
            }
            return error.MissingPersistedTerrain;
        }
    };
    var actor: Actor = .{ .workspace = workspace, .terrain = restored };
    // Leave 64 KiB of the terrain worker's stack for its caller frames.
    const thread = try std.Thread.spawn(.{ .stack_size = 192 * 1024 }, Actor.run, .{&actor});
    thread.join();
    try actor.result;
    try std.testing.expectEqual(@as(u64, 9 * maximum_sections), workspace.work.acquired_sections);
    try std.testing.expect(restored.cache.backend.store.discovery_revision != 0);
    try std.testing.expectEqual(@as(u8, 15), workspace.engine.get(.sky, ((height - 17) * side + side / 2) * side + side / 2));
    try std.testing.expectEqual(@as(usize, 0), restored.borrowed_count);
    try std.testing.expectEqual(failing.fail_index, failing.alloc_index);
}
