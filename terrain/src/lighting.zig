const deflate = @import("deflate");
const test_blocks = @import("test_blocks.zig");
const BlockProperties = @import("block_properties").BlockProperties;
const std = @import("std");
const chunk_encoding = @import("chunk_encoding.zig");
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
const zstandard = @import("zstandard");
const Generation = @import("generation.zig").Generation;
const section_hull = @import("occlusion").section_hull;
const light_store = @import("lighting").light_store;
const assert = std.debug.assert;

const section_views = @import("lighting").section_views;
const maximum_sections = section_views.maximum_sections;
const side = section_views.side;
const height = (maximum_sections + 2) * 16;
const Stamp = section_views.Stamp;
const Section = section_views.Section;
const Biomes = section_views.Biomes;

/// Each owner has a separate workspace. Chunk leases protect the input snapshot.
pub const Workspace = struct {
    pub const Region = struct { world: u32, x: i32, z: i32, minimum: i32, count: usize, skylight: bool };

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
        darkened_rows: u64 = 0,
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
    /// Reads block sections for the solver. Its budget bounds a batch.
    client: chunks.Chunks.Client,
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

    pub fn init(allocator: std.mem.Allocator, client: chunks.Chunks.Client, registry: lighting.Registry) !*Workspace {
        const self = try allocator.create(Workspace);
        const terrain = client.chunks;
        const capacity = client.budget();
        self.* = .{
            .client = client,
            .watch = try chunks.Watch.init(allocator, terrain, 9 * maximum_sections),
            .engine = try lighting.Engine.init(allocator, .{ .x = side, .y = height, .z = side }, registry),
            .states = try allocator.alloc(u16, side * maximum_sections * 16 * side),
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
        if (!try self.prepareInputsMode(terrain, world, x, z, dimension, .{ .player = player })) return false;
        try self.solve(std.math.maxInt(u32));
        return true;
    }

    /// Drops copied inputs and solved light, as after a block definition change.
    fn forget(self: *Workspace, registry: lighting.Registry) void {
        // Content validates rules before it publishes them, and the number of states is fixed.
        self.engine.changeRegistry(registry) catch unreachable;
        self.region = null;
        self.pending = null;
        self.solved = null;
        self.input_ready = false;
        self.coverage = 0;
        @memset(&self.copied, false);
    }

    /// Snapshots are borrowed until the next prepare. Lighting is not computed here.
    pub fn prepareInputs(self: *Workspace, terrain: *chunks.Chunks, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, player: usize) !bool {
        return self.prepareInputsMode(terrain, world, x, z, dimension, .{ .player = player });
    }

    fn prepareInputsMode(self: *Workspace, terrain: *chunks.Chunks, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, priority: chunks.GenerationPriority) !bool {
        assert(terrain == self.client.chunks);
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
        const capacity = self.client.budget();
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
                const requests = self.preparation.requests;
                const ready = self.preparation.ready;
                for (requests[0 .. end - begin], 0..) |*request, index| request.* = .{
                    .sections = positions[begin + index ..][0..1],
                    .leases = leases[index..][0..1],
                    .priority = priority,
                };
                try self.client.prepareMany(requests[0 .. end - begin], ready[0 .. end - begin]);
                for (ready[0 .. end - begin], 0..) |complete, index| if (complete) {
                    leases[held] = leases[index];
                    indices[begin + held] = indices[begin + index];
                    held += 1;
                };
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
            section.* = .{ .stamp = self.stamps[at], .biomes = if (self.biome_present[at]) .{ .values = &self.biome_values[at] } else null, .view = if (self.uniforms[at]) |state| .{ .uniform = state } else .{ .rows = self.states[self.snapshotIndex(4, y, 0)..] } };
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
        self.work.darkened_rows += self.engine.work.darkened_rows;
    }

    fn copy(self: *Workspace, column: usize, section: usize, view: chunks.View) ?u16 {
        if (view == .uniform) return view.uniform;
        const first: @Vector(16, u16) = @splat(view.get(0));
        var uniform = true;
        const base = self.snapshotIndex(column, section, 0);
        // Rows decode in pairs straight into the snapshot, reading each bit plane word once.
        for (0..128) |group| {
            const row = group * 2;
            const even = self.states[base + row / 16 * side * side + row % 16 * side ..][0..16];
            const odd = self.states[base + row / 16 * side * side + (row % 16 + 1) * side ..][0..16];
            view.pair(@intCast(group), even, odd);
            uniform = uniform and @reduce(.And, @as(@Vector(16, u16), even.*) == first) and @reduce(.And, @as(@Vector(16, u16), odd.*) == first);
        }
        return if (uniform) first[0] else null;
    }

    fn snapshotIndex(self: *const Workspace, column: usize, section: usize, local: usize) usize {
        const x = (column % 3 + self.origin[0]) % 3 * 16 + local % 16;
        const z = (column / 3 * 16 + self.origin[1]) % side + local / 16 % 16;
        const y = section * 16 + local / 256;
        return (y * side + z) * side + x;
    }

    /// Block snapshots are available before lighting is solved and borrowed until the next prepare.
    pub fn sections(self: *const Workspace) []const Section {
        assert(self.input_ready);
        return self.section_views[0..(self.pending orelse self.region.?).count];
    }

    /// Occluder cells just outside the six faces of a center column section, laid out as
    /// `section_hull.Faces`. Uncaptured neighbours and cells outside the world stay exposed.
    pub fn hullFaces(self: *const Workspace, table: section_hull.Table, section: usize) section_hull.Faces {
        const count = (self.pending orelse self.region.?).count;
        assert(section < count);
        const level: i64 = @intCast(section);
        // Columns are numbered z * 3 + x around the center column 4.
        const north = 1;
        const west = 3;
        const center = 4;
        const east = 5;
        const south = 7;
        const last = section_hull.side - 1;
        return .{
            self.facePlane(table, west, level, 0, last),
            self.facePlane(table, east, level, 0, 0),
            self.facePlane(table, center, level - 1, 1, last),
            self.facePlane(table, center, level + 1, 1, 0),
            self.facePlane(table, north, level, 2, last),
            self.facePlane(table, south, level, 2, 0),
        };
    }

    /// Occluders of one plane of a neighbouring section, at coordinate `at` along `axis`.
    fn facePlane(self: *const Workspace, table: section_hull.Table, column: usize, section: i64, comptime axis: usize, at: usize) [section_hull.side]u16 {
        assert(column < 9 and at < section_hull.side);
        const count = (self.pending orelse self.region.?).count;
        if (section < 0 or section >= count) return @splat(0);
        const index = column * maximum_sections + @as(usize, @intCast(section));
        if (!self.copied[index]) return @splat(0);
        if (self.uniforms[index]) |state| return @splat(if (table[state] & section_hull.occluder != 0) 0xffff else 0);
        const Snapshot = struct {
            workspace: *const Workspace,
            column: usize,
            section: usize,

            pub fn get(snapshot: @This(), local: u12) u16 {
                return snapshot.workspace.states[snapshot.workspace.snapshotIndex(snapshot.column, snapshot.section, local)];
            }
        };
        return section_hull.readPlane(Snapshot{ .workspace = self, .column = column, .section = @intCast(section) }, table, axis, at);
    }

    pub fn columnSections(self: *const Workspace, column: usize, output: []Section) void {
        assert(self.input_ready and column < 9);
        assert(output.len == (self.pending orelse self.region.?).count);
        for (output, 0..) |*section, y| {
            const at = column * maximum_sections + y;
            section.* = .{
                .stamp = self.stamps[at],
                .biomes = if (self.biome_present[at]) .{ .values = &self.biome_values[at] } else null,
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

pub const Sample = light_store.Sample;

pub const Lighting = struct {
    pub const id = "minecraft:lighting";
    /// The light store is sized by whoever knows the player limit. A server gets one from
    /// streaming. Set `store` to have one without it.
    pub const Configuration = struct {
        store: ?light_store.Configuration = null,
        stored: bool = true,
        /// Sections the solver reads at once on the terrain thread, generation it waits for included.
        chunk_sections: usize = 192,
    };
    pub const Dependencies = struct { metrics: *metrics.Registry, blocks: *BlockProperties, chunks: *chunks.Chunks, worlds: *worlds.Worlds };
    pub const delivery_batch_max = storage.batch_size;
    const batch_max = 256;
    const Key = struct { x: i32, z: i32 };
    /// Edits of one column that are patched together.
    const patch_max = lighting.batch_max;

    /// Hears what happened to stored light. Called on the simulation thread.
    pub const Sink = struct {
        context: *anyopaque,
        /// The edits to this column were patched. These light sections changed around it,
        /// by layer and by column of the nine, the edited one being 4. Their light can be
        /// read with `storedLight` until the callback returns.
        patched: *const fn (*anyopaque, u32, i32, i32, [2][9]u32) void,
        /// The stored light of the nine columns around this one is gone, and whoever was
        /// sent them needs their light from a solve. A stamp names the solve that may
        /// bring its column back with `offer`. Zero is a column outside the world.
        unlit: *const fn (*anyopaque, u32, i32, i32, [9]u64) void,
        /// Gameplay asked for the light of this column and no stage has it. The stamp
        /// names the solve that may bring it in with `offer`.
        wanted: *const fn (*anyopaque, u32, i32, i32, u64) void,
    };

    /// Memory for moving the light of one column between the store and somewhere else.
    const Scratch = struct {
        bytes: [light_store.Copy.capacity][light_store.section_bytes]u8 = undefined,
        record: [light_store.Copy.record_bytes]u8 = undefined,
        copy: light_store.Copy = undefined,
    };

    /// Disk work the simulation thread hands the terrain thread, done in the order asked.
    /// The order matters: a record written for a column is on disk before it is read.
    const Ops = struct {
        const Op = union(enum) {
            /// Writes the overflow record in `bytes[offset..][0..length]`.
            write: struct { key: light_store.Key, offset: u32, length: u32 },
            delete: light_store.Key,
            /// Deletes every overflow record, after the store forgot what they were for.
            purge,
            load: struct { key: light_store.Key, shape: light_store.Shape, stamp: u64, source: light_store.Source },
            /// Reads these sections of the nine columns around `key` into the chunk cache.
            warm: struct { key: light_store.Key, shape: light_store.Shape, sections: u32 },
        };
        ops: []Op,
        count: usize = 0,
        /// The terrain thread has done the ops before this one.
        next: usize = 0,
        bytes: []u8,
        used: usize = 0,

        fn done(self: *const Ops) bool {
            return self.next == self.count;
        }

        fn clear(self: *Ops) void {
            self.count = 0;
            self.next = 0;
            self.used = 0;
        }
    };

    /// Light the terrain thread read or solved, on its way to the store.
    const Results = struct {
        const Entry = struct {
            key: light_store.Key,
            shape: light_store.Shape,
            stamp: u64,
            kind: enum { solved, record, frame, failed },
            dense: [2]u32 = .{ 0, 0 },
            /// The level of a uniform section, or the index in `bytes` of a dense one.
            slots: [2][light_store.sections_max]u32 = undefined,
            /// For a frame: the stamp of the last edit batch when it was read, and the
            /// sections of its nine columns whose changes then were in memory only.
            edit_stamp: u64 = 0,
            unsaved_start: u32 = 0,
            unsaved_count: u32 = 0,
        };
        entries: []Entry,
        count: usize = 0,
        bytes: [][light_store.section_bytes]u8,
        used: usize = 0,
        unsaved: []chunks.Chunks.Unsaved,
        unsaved_used: usize = 0,

        /// Room for one more column, however dense its light.
        fn room(self: *const Results) bool {
            return self.count < self.entries.len and self.bytes.len - self.used >= light_store.Copy.capacity and self.unsaved.len - self.unsaved_used >= unsaved_max;
        }

        fn clear(self: *Results) void {
            self.count = 0;
            self.used = 0;
            self.unsaved_used = 0;
        }

        /// Copies a column of light in. The caller made sure there is room.
        fn add(self: *Results, entry: Entry, light: ?*const light_store.Sections) *Entry {
            assert(self.room());
            const slot = &self.entries[self.count];
            self.count += 1;
            slot.* = entry;
            const sections = light orelse return slot;
            for (0..2) |layer| for (0..entry.shape.sections()) |index| switch (sections.light[layer][index]) {
                .uniform => |level| slot.slots[layer][index] = level,
                .dense => |levels| if (light_store.uniformLevel(levels)) |level| {
                    slot.slots[layer][index] = level;
                } else {
                    @memcpy(&self.bytes[self.used], levels);
                    slot.slots[layer][index] = @intCast(self.used);
                    slot.dense[layer] |= @as(u32, 1) << @intCast(index);
                    self.used += 1;
                },
            };
            return slot;
        }

        fn view(self: *const Results, entry: *const Entry, output: *light_store.Sections) void {
            for (0..2) |layer| for (0..entry.shape.sections()) |index| {
                const slot = entry.slots[layer][index];
                output.light[layer][index] = if (entry.dense[layer] & (@as(u32, 1) << @intCast(index)) == 0) .{ .uniform = @intCast(slot) } else .{ .dense = &self.bytes[slot] };
            };
        }
    };

    /// What the simulation thread knows of an edit that light is not settled for.
    const Unsettled = struct {
        state: u16,
        /// The stamp of the chunk edit batch it was made in.
        stamp: u64,
        /// The tick it was made in.
        tick: u64,
    };

    /// A column gameplay sampled that was not in memory.
    const Want = struct { key: light_store.Key, shape: light_store.Shape };

    /// What the store did, as counters an operator can read.
    const StoreCounters = struct {
        patched: metrics.Counter,
        failed: metrics.Counter,
        attempts: metrics.Counter,
        steps: metrics.Counter,
        waits: metrics.Counter,
        darkened: metrics.Counter,
        deferred: metrics.Counter,
        late: metrics.Counter,
        frames: metrics.Counter,
        restores: metrics.Counter,
        solves: metrics.Counter,
        stale: metrics.Counter,
        evictions: metrics.Counter,
        overflows: metrics.Counter,
        forgotten: metrics.Counter,
        resets: metrics.Counter,
        sample_hits: metrics.Counter,
        sample_misses: metrics.Counter,
        crowded: metrics.Counter,
        refused: metrics.Counter,
        write_failures: metrics.Counter,
    };

    /// Records one write carries.
    const record_batch = chunks.Chunks.patched_light_batch_max;
    /// Columns read from disk together.
    const load_batch = 9;
    /// Columns gameplay may ask for in one tick.
    const wants_max = 64;
    /// Sections of a column's neighbourhood that may have unsaved changes when its frame
    /// is read. More cannot be checked and the frame is not used.
    const unsaved_max = 16;
    /// Ticks an edit may wait for the light or blocks around it to be read. Past that,
    /// its light is dropped and solved again.
    const pending_ticks_max = 40;
    /// Ops the terrain thread does in one go before it lets deliveries run.
    const ops_per_poll = 64;

    pub const Delivery = struct { world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, selection: u32 = std.math.maxInt(u32) };
    const Hull = struct {
        table: section_hull.Table,
        /// Hulled copies of loaded center sections, borrowed by the latest delivery.
        states: [maximum_sections][section_hull.volume]u16 = undefined,
        sections: [maximum_sections]Section = undefined,
        generation: u64 = 0,
    };
    const Prepared = struct {
        region: ?Workspace.Region = null,
        clean: bool = false,
        complete: bool = false,
        watch: *chunks.Watch,
        view: ?chunks.Light.View = null,
    };

    deps: Dependencies,
    background: *Workspace,
    /// Light kept in memory for edits and gameplay. The simulation thread owns it and
    /// does no IO for it. The terrain thread does every disk read and write it needs.
    store: ?*light_store.LightStore = null,
    /// Reads the block sections a patch needs, from memory only, on the simulation thread.
    store_client: ?chunks.Chunks.Client = null,
    /// Marks the overflow records of this process. Older ones describe blocks that may
    /// never have been saved.
    stamp: u64 = 0,
    /// Simulation thread. One column on its way out of the store.
    scratch: *Scratch = undefined,
    compressor: zstandard.Compressor = undefined,
    /// Terrain thread. One column being read, decoded or packed.
    terrain_scratch: *Scratch = undefined,
    store_frames: chunks.Light.Workspace = undefined,
    decompressor: zstandard.Decompressor = undefined,
    unsaved_scratch: [unsaved_max]chunks.Chunks.Unsaved = undefined,
    /// Guards only which buffer each thread holds, and the idle flag.
    store_mutex: std.Io.Mutex = .init,
    /// The simulation thread fills one while the terrain thread works through the other.
    ops: *Ops = undefined,
    ops_working: *Ops = undefined,
    /// The terrain thread fills one while the simulation thread takes in the other.
    results: *Results = undefined,
    results_taken: *Results = undefined,
    /// Nothing waited on the simulation side when it last handed work over.
    store_idle: bool = true,
    /// Every overflow record on disk is meaningless and waits to be deleted.
    purge: bool = false,
    /// Simulation thread. Edits that light is not settled for, oldest first.
    unsettled: []light_store.Pending = &.{},
    unsettled_info: []Unsettled = &.{},
    unsettled_count: usize = 0,
    settling: []light_store.Pending = &.{},
    settling_info: []Unsettled = &.{},
    settle_order: []light_store.Key = &.{},
    pending_columns: std.AutoHashMapUnmanaged(light_store.Key, light_store.Waiting.Range) = .empty,
    patch_edits: [patch_max]lighting.patch.Edit = undefined,
    sink: ?Sink = null,
    ticks: u64 = 0,
    /// Cells one tick of patches may visit, and how many the store had visited when the
    /// tick began.
    patch_steps: u64 = 0,
    tick_steps: u64 = 0,
    wants: [wants_max]Want = undefined,
    want_count: usize = 0,
    store_seen: light_store.Stats = .{},
    store_counters: StoreCounters = undefined,
    store_reads: metrics.Timer = .{},
    store_writes: metrics.Timer = .{},
    groups: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    config: Configuration,
    rules: [32]u8,
    stored_workspace: chunks.Light.Workspace,
    terrain_baker: *chunks.Prepared.Baker,
    terrain_properties: []const u8,
    delivery_generation: u64 = 0,
    stored_view: ?*const chunks.Light.View = null,
    fallback_view: chunks.Light.View = undefined,
    stored_region: ?Workspace.Region = null,
    stored_watch: *chunks.Watch,
    fallback_watch: *chunks.Watch,
    prepared: [delivery_batch_max]Prepared,
    classification: ?*const chunks.classification.Index = null,
    delivery_prepared: bool = false,
    delivery_metadata_ready: bool = false,
    delivery_active: bool = false,
    delivery_sections: [maximum_sections]Section = undefined,
    /// Present when hidden blocks are replaced before terrain reaches clients.
    hull: ?*Hull = null,
    stored_hits: metrics.Counter,
    stored_decodes: metrics.Counter,
    stored_misses: metrics.Counter,
    /// Why a delivery-time solve was or was not baked into a reusable frame.
    baked_frames: metrics.Counter,
    unbaked_dirty: metrics.Counter,
    unbaked_frame: metrics.Counter,
    bake_timers: struct { solve: metrics.Timer, frame: metrics.Timer },

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Lighting {
        const registry = deps.blocks.light;
        const self = try allocator.create(Lighting);
        self.* = .{
            .deps = deps,
            .background = try Workspace.init(allocator, try deps.chunks.client(.{ .name = "lighting", .sections = config.chunk_sections }), registry),
            .config = config,
            .rules = rulesHash(registry, false),
            .stored_workspace = try chunks.Light.Workspace.init(allocator),
            .terrain_baker = try chunks.Prepared.Baker.init(allocator),
            .terrain_properties = try chunk_encoding.materialProperties(allocator, deps.blocks),
            .stored_watch = try chunks.Watch.initInvalidation(allocator, deps.chunks),
            .fallback_watch = undefined,
            .prepared = undefined,
            .stored_hits = try deps.metrics.counter(.{ .name = "lighting.stored.hits", .description = "Chunk deliveries using persisted lighting" }),
            .stored_decodes = try deps.metrics.counter(.{ .name = "lighting.stored.decodes", .description = "Persisted lighting frames decoded" }),
            .stored_misses = try deps.metrics.counter(.{ .name = "lighting.stored.misses", .description = "Chunk deliveries requiring lighting reconstruction" }),
            .baked_frames = try deps.metrics.counter(.{ .name = "lighting.delivery.baked", .description = "Delivery solves baked into a reusable frame" }),
            .unbaked_dirty = try deps.metrics.counter(.{ .name = "lighting.delivery.unbaked_dirty", .description = "Delivery solves not baked because the neighbourhood was dirty or generating" }),
            .unbaked_frame = try deps.metrics.counter(.{ .name = "lighting.delivery.unbaked_frame", .description = "Delivery solves not baked because the frame could not be built or changed" }),
            .bake_timers = .{
                .solve = try deps.metrics.timer(.{ .name = "lighting.bake.solve.cpu", .description = "Acquire and light a cold column neighbourhood", .clock = .thread_cpu, .detailed = true }),
                .frame = try deps.metrics.timer(.{ .name = "lighting.bake.frame.cpu", .description = "Encode a solved column into a stored frame", .clock = .thread_cpu, .detailed = true }),
            },
        };
        self.fallback_watch = self.stored_watch;
        for (&self.prepared) |*entry| entry.* = .{
            .watch = try chunks.Watch.initInvalidation(allocator, deps.chunks),
        };
        const timings: Workspace.Timings = .{
            .acquire = try deps.metrics.timer(.{ .name = "lighting.acquire.cpu", .description = "Acquire lighting input sections", .clock = .thread_cpu, .detailed = true }),
            .snapshot = try deps.metrics.timer(.{ .name = "lighting.snapshot.cpu", .description = "Copy and retain lighting input snapshots", .clock = .thread_cpu, .detailed = true }),
            .materials = try deps.metrics.timer(.{ .name = "lighting.materials.cpu", .description = "Prepare lighting material rows", .clock = .thread_cpu, .detailed = true }),
            .propagate = try deps.metrics.timer(.{ .name = "lighting.propagate.cpu", .description = "Propagate a fresh lighting field", .clock = .thread_cpu, .detailed = true }),
            .scroll = try deps.metrics.timer(.{ .name = "lighting.scroll.cpu", .description = "Retain settled light and propagate incoming boundaries", .clock = .thread_cpu, .detailed = true }),
        };
        self.background.timings = timings;
        try self.groups.ensureTotalCapacity(allocator, batch_max);
        if (config.store) |store| try self.includeStore(allocator, store);
        try deps.blocks.listen(Lighting, self, definitionsChanged);
        return self;
    }

    fn definitionsChanged(self: *Lighting) void {
        self.rules = rulesHash(self.deps.blocks.light, self.hull != null);
        self.stored_region = null;
        self.stored_view = null;
        for (&self.prepared) |*entry| entry.region = null;
        self.background.forget(self.deps.blocks.light);
        if (self.store) |store| {
            // Light and records made under the old definitions mean nothing now.
            store.changeRules(self.deps.blocks.light);
            self.unsettled_count = 0;
            self.want_count = 0;
            self.purge = true;
        }
    }

    /// Gives the service a light store. Call during startup, once the player limit that
    /// sizes it is known. A second call keeps the first store.
    pub fn includeStore(self: *Lighting, allocator: std.mem.Allocator, config: light_store.Configuration) !void {
        if (self.store != null) return;
        // One column of sections at a time, all a patch of one column reads together.
        self.store_client = try self.deps.chunks.simulation(light_store.sections_max - 2);
        self.scratch = try allocator.create(Scratch);
        self.terrain_scratch = try allocator.create(Scratch);
        for ([_]*Scratch{ self.scratch, self.terrain_scratch }) |scratch| scratch.* = .{ .copy = .{ .bytes = &scratch.bytes } };
        self.store_frames = try chunks.Light.Workspace.init(allocator);
        self.compressor = try zstandard.Compressor.init(allocator, 1, light_store.Copy.record_bytes);
        self.decompressor = try zstandard.Decompressor.init(allocator);
        for ([_]**Ops{ &self.ops, &self.ops_working }) |slot| {
            const ops = try allocator.create(Ops);
            ops.* = .{
                // Loads for the nine columns of a first edit by every player a tick, and
                // the writes and deletes of what leaves memory.
                .ops = try allocator.alloc(Ops.Op, 256 + 32 * config.players),
                // Records compress to a few KiB. The largest one always fits.
                .bytes = try allocator.alloc(u8, zstandard.bound(light_store.Copy.record_bytes) + 16 * 1024 * config.players),
            };
            assert(ops.bytes.len <= std.math.maxInt(u32));
            slot.* = ops;
        }
        for ([_]**Results{ &self.results, &self.results_taken }) |slot| {
            const results = try allocator.create(Results);
            const entries = 25 + 4 * config.players;
            results.* = .{
                .entries = try allocator.alloc(Results.Entry, entries),
                // A column of typical terrain holds about six dense sections, and the
                // largest one always fits.
                .bytes = try allocator.alloc([light_store.section_bytes]u8, @max(2 * light_store.Copy.capacity, 6 * entries)),
                .unsaved = try allocator.alloc(chunks.Chunks.Unsaved, @max(unsaved_max, 2 * entries)),
            };
            assert(results.bytes.len <= std.math.maxInt(u32));
            slot.* = results;
        }
        assert(config.edits != 0 and config.edits <= std.math.maxInt(u32));
        assert(config.patch_steps != 0);
        self.patch_steps = config.patch_steps;
        self.unsettled = try allocator.alloc(light_store.Pending, config.edits);
        self.unsettled_info = try allocator.alloc(Unsettled, config.edits);
        self.settling = try allocator.alloc(light_store.Pending, config.edits);
        self.settling_info = try allocator.alloc(Unsettled, config.edits);
        self.settle_order = try allocator.alloc(light_store.Key, config.edits);
        try self.pending_columns.ensureTotalCapacity(allocator, @intCast(config.edits));
        self.deps.chunks.io.random(std.mem.asBytes(&self.stamp));
        const registry = self.deps.metrics;
        self.store_counters = .{
            .patched = try registry.counter(.{ .name = "lighting.store.patched", .description = "Edited columns whose stored light was patched in place" }),
            .failed = try registry.counter(.{ .name = "lighting.store.failed", .description = "Patches that did not fit" }),
            .attempts = try registry.counter(.{ .name = "lighting.store.attempts", .description = "Patches run, counting each one a missing block section cut short" }),
            .steps = try registry.counter(.{ .name = "lighting.store.steps", .description = "Light cells patches visited, across every attempt" }),
            .waits = try registry.counter(.{ .name = "lighting.store.waits", .description = "Patches put off for a tick because block states were not in memory" }),
            .darkened = try registry.counter(.{ .name = "lighting.store.darkened", .description = "Columns whose stored light was dropped because no patch could follow an edit" }),
            .deferred = try registry.counter(.{ .name = "lighting.store.deferred", .description = "Column patches put off to the next tick because this one had done its share" }),
            .late = try registry.counter(.{ .name = "lighting.store.late", .description = "Edits whose light or blocks were not read in time, so their light was solved again" }),
            .frames = try registry.counter(.{ .name = "lighting.store.frames", .description = "Columns lit from their baked frame" }),
            .restores = try registry.counter(.{ .name = "lighting.store.restores", .description = "Columns lit from their overflow record" }),
            .solves = try registry.counter(.{ .name = "lighting.store.solves", .description = "Columns lit from a solve by the terrain thread" }),
            .stale = try registry.counter(.{ .name = "lighting.store.stale", .description = "Frames read that an unsaved edit may already be in, which were not used" }),
            .evictions = try registry.counter(.{ .name = "lighting.store.evictions", .description = "Columns that left memory to make room" }),
            .overflows = try registry.counter(.{ .name = "lighting.store.overflows", .description = "Patched columns that left memory for their overflow record" }),
            .forgotten = try registry.counter(.{ .name = "lighting.store.forgotten", .description = "Remembered columns dropped from the table" }),
            .resets = try registry.counter(.{ .name = "lighting.store.resets", .description = "Times the table ran out and all stored light was dropped" }),
            .sample_hits = try registry.counter(.{ .name = "lighting.store.sample_hits", .description = "Columns sampled from memory" }),
            .sample_misses = try registry.counter(.{ .name = "lighting.store.sample_misses", .description = "Columns sampled that were not in memory" }),
            .crowded = try registry.counter(.{ .name = "lighting.store.crowded", .description = "Disk work not asked for because the hand-off to the terrain thread was full" }),
            .refused = try registry.counter(.{ .name = "lighting.store.refused", .description = "Solved columns the hand-off had no room for" }),
            .write_failures = try registry.counter(.{ .name = "lighting.store.write_failures", .description = "Overflow record writes or deletes the disk cache did not take" }),
        };
        self.store_reads = try registry.timer(.{ .name = "lighting.store.read", .description = "Terrain thread reads of stored light from disk", .clock = .thread_cpu });
        self.store_writes = try registry.timer(.{ .name = "lighting.store.write", .description = "Terrain thread writes of overflow records", .clock = .thread_cpu });
        self.store = try light_store.LightStore.init(allocator, self.deps.blocks.light, config);
        // What an earlier process left describes blocks that may never have been saved.
        // This runs at startup, before the first tick.
        while (self.deps.chunks.clearPatchedLights()) {}
        try self.deps.chunks.observe(chunks.Observer.init(self, blocksChanged));
    }

    /// Routes what happens to stored light to whoever sends light to clients.
    pub fn setSink(self: *Lighting, sink: Sink) void {
        assert(self.sink == null and self.store != null);
        self.sink = sink;
    }

    fn rulesHash(registry: lighting.Registry, hull: bool) [32]u8 {
        var hash = std.crypto.hash.Blake3.init(.{});
        var version: [20]u8 = undefined;
        std.mem.writeInt(u32, version[0..4], chunks.Light.algorithm_version, .little);
        std.mem.writeInt(u64, version[4..12], @intCast(registry.states.len), .little);
        std.mem.writeInt(u64, version[12..20], @intCast(registry.faces), .little);
        hash.update(&version);
        hash.update(&game_data.canonical_identity);
        for (registry.states) |state| {
            var bytes: [14]u8 = undefined;
            bytes[0] = state.opacity;
            bytes[1] = state.emission;
            for (state.faces, 0..) |face, index| std.mem.writeInt(u16, bytes[2 + index * 2 ..][0..2], face, .little);
            hash.update(&bytes);
        }
        hash.update(registry.occlusion);
        // Frames baked with hull replacement hold different terrain.
        if (hull) hash.update("lightning_rod:hull:1");
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }

    pub fn releaseDelivery(self: *Lighting) void {
        self.releaseCurrent();
    }

    fn releaseCurrent(self: *Lighting) void {
        self.delivery_active = false;
        self.delivery_metadata_ready = false;
    }

    pub fn currentDelivery(self: *const Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension) bool {
        if (!self.delivery_prepared) return self.background.current(self.deps.chunks, world, x, z, dimension);
        const region: Workspace.Region = .{ .world = world, .x = x, .z = z, .minimum = dimension.minimumSection(), .count = dimension.sectionCount(), .skylight = dimension.skylight };
        return self.stored_region != null and std.meta.eql(self.stored_region.?, region) and self.stored_watch.unchanged();
    }

    fn watchDelivery(watch: *chunks.Watch, region: Workspace.Region) !void {
        watch.observe(.{ .world = region.world, .minimum = .{ .x = try std.math.sub(i32, region.x, 1), .y = region.minimum, .z = try std.math.sub(i32, region.z, 1) }, .maximum = .{ .x = try std.math.add(i32, region.x, 1), .y = region.minimum + @as(i32, @intCast(region.count)) - 1, .z = try std.math.add(i32, region.z, 1) } });
    }

    /// Columns must be distinct. Borrowed frames remain valid until the next batch.
    /// Watches cover edits during the read.
    pub fn prepareDeliveries(self: *Lighting, deliveries: []const Delivery, cache: *chunks.Delivery.ReadBatch) !void {
        assert(deliveries.len <= delivery_batch_max and deliveries.len == cache.keys.len and !self.delivery_active);
        self.stored_region = null;
        self.stored_view = null;
        for (&self.prepared) |*entry| {
            entry.region = null;
            entry.view = null;
        }
        errdefer for (&self.prepared) |*entry| {
            entry.region = null;
        };
        if (!self.config.stored or deliveries.len == 0) {
            cache.submitted = true;
            return;
        }
        var requests: [delivery_batch_max]chunks.Light.Request = undefined;
        for (deliveries, requests[0..deliveries.len], self.prepared[0..deliveries.len], 0..) |delivery, *request, *entry, index| {
            const count = delivery.dimension.sectionCount();
            if (count == 0 or count > maximum_sections) return error.UnsupportedLightingHeight;
            const region: Workspace.Region = .{ .world = delivery.world, .x = delivery.x, .z = delivery.z, .minimum = delivery.dimension.minimumSection(), .count = count, .skylight = delivery.dimension.skylight };
            for (self.prepared[0..index]) |previous| assert(!std.meta.eql(previous.region.?, region));
            entry.region = region;
            entry.complete = false;
            entry.clean = false;
            try watchDelivery(entry.watch, region);
            request.* = .{ .column = .{ .world = region.world, .x = region.x, .z = region.z }, .minimum = region.minimum, .count = region.count };
        }
        var frames: [delivery_batch_max]?[]const u8 = undefined;
        var complete: [delivery_batch_max]bool = undefined;
        var clean: [delivery_batch_max]bool = undefined;
        var batch: chunks.Light.FrameBatch = .{ .bytes = &.{}, .frames = frames[0..deliveries.len], .complete = complete[0..deliveries.len], .clean = clean[0..deliveries.len] };
        try self.deps.chunks.deliveryFrames(requests[0..deliveries.len], &batch, cache);
        for (self.prepared[0..deliveries.len], frames[0..deliveries.len], complete[0..deliveries.len], clean[0..deliveries.len]) |*entry, frame, finished, unchanged| {
            entry.complete = finished;
            entry.clean = unchanged;
            if (!finished or !unchanged or !entry.watch.unchanged()) continue;
            const data = frame orelse continue;
            self.stored_decodes.add(1);
            const view = self.stored_workspace.decode(data) catch continue;
            if (self.validStored(&view, unchanged, entry.watch, entry.region.?)) entry.view = view;
        }
    }

    /// Whether the batch read found a usable stored frame for this column, so delivering it
    /// needs no neighbourhood solve. Without stored lighting every column is solved alike.
    pub fn deliveryStored(self: *const Lighting, world: u32, x: i32, z: i32) bool {
        if (!self.config.stored) return true;
        for (&self.prepared) |*entry| {
            const region = entry.region orelse continue;
            if (region.world != world or region.x != x or region.z != z) continue;
            return entry.complete and entry.view != null;
        }
        return false;
    }

    /// Replaces hidden blocks in terrain delivered from now on. Frames baked without the hull
    /// carry different rules and are rebuilt.
    /// Called at startup, before any delivery. Repeated calls keep the first hull.
    pub fn includeHull(self: *Lighting, allocator: std.mem.Allocator) !void {
        assert(!self.delivery_active and !self.delivery_prepared);
        if (self.hull != null) return;
        const hull = try allocator.create(Hull);
        hull.* = .{ .table = try section_hull.initTable(allocator) };
        self.hull = hull;
        self.rules = rulesHash(self.deps.blocks.light, true);
        self.stored_region = null;
        self.stored_view = null;
    }

    pub fn includeClassification(self: *Lighting, index: *const chunks.classification.Index) void {
        const codec = index.codec.?.column.?;
        assert(codec.maximum > 0 and codec.maximum <= chunks.Light.maximum_metadata);
        assert(self.classification == null or self.classification.? == index);
        self.classification = index;
    }

    /// Borrows the current frame until the next preparation.
    pub fn deliveryFrame(self: *const Lighting) ?*const chunks.Light.View {
        return if (self.delivery_prepared) self.stored_view else null;
    }

    fn validStored(self: *const Lighting, view: *const chunks.Light.View, clean: bool, watch: *const chunks.Watch, region: Workspace.Region) bool {
        if (self.classification) |index| {
            const metadata = view.metadata orelse return false;
            if (!std.mem.eql(u8, &metadata.identity, &index.identity)) return false;
        }
        return clean and watch.unchanged() and view.header.minimum == region.minimum and view.header.count == region.count and
            view.header.skylight == region.skylight and view.header.coverage == (@as(u32, 1) << @intCast(region.count)) - 1 and
            bakedSelection(view, std.math.maxInt(u32)) and
            std.mem.eql(u8, &view.header.rules, &self.rules);
    }

    pub const DeliveryStatus = enum { ready, pending, deferred };

    pub fn prepareDelivery(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, priority: chunks.GenerationPriority) !DeliveryStatus {
        const count = dimension.sectionCount();
        if (count == 0 or count > maximum_sections) return error.UnsupportedLightingHeight;
        if (self.delivery_active and self.currentDelivery(world, x, z, dimension)) return .ready;
        self.releaseCurrent();
        assert(self.delivery_generation < std.math.maxInt(u64));
        self.delivery_generation += 1;
        self.delivery_prepared = false;
        const region: Workspace.Region = .{ .world = world, .x = x, .z = z, .minimum = dimension.minimumSection(), .count = count, .skylight = dimension.skylight };
        if (self.config.stored) {
            var valid = self.stored_region != null and std.meta.eql(self.stored_region.?, region) and self.stored_watch.unchanged();
            if (!valid) {
                self.stored_region = null;
                self.stored_view = null;
                var prepared: ?*Prepared = null;
                for (&self.prepared) |*entry| {
                    if (entry.region == null or !std.meta.eql(entry.region.?, region) or !entry.watch.unchanged()) continue;
                    if (!entry.complete) return .deferred;
                    self.stored_watch = entry.watch;
                    prepared = entry;
                    break;
                }
                var clean = false;
                const decoded: ?*const chunks.Light.View = if (prepared) |entry| prefetched: {
                    clean = entry.clean;
                    break :prefetched if (entry.view) |*view| view else null;
                } else fallback: {
                    self.stored_watch = self.fallback_watch;
                    try watchDelivery(self.stored_watch, region);
                    var frames: [1]?[]const u8 = undefined;
                    var complete: [1]bool = undefined;
                    var cleanliness: [1]bool = undefined;
                    var batch: chunks.Light.FrameBatch = .{ .bytes = self.stored_workspace.raw, .frames = &frames, .complete = &complete, .clean = &cleanliness };
                    try self.deps.chunks.lightFrames(&.{.{ .column = .{ .world = world, .x = x, .z = z }, .minimum = region.minimum, .count = count }}, &batch);
                    assert(complete[0]);
                    clean = cleanliness[0];
                    const frame = frames[0] orelse break :fallback null;
                    self.stored_decodes.add(1);
                    self.fallback_view = self.stored_workspace.decode(frame) catch break :fallback null;
                    break :fallback &self.fallback_view;
                };
                if (decoded) |view| {
                    valid = self.validStored(view, clean, self.stored_watch, region);
                    if (valid) {
                        self.stored_region = region;
                        self.stored_view = view;
                    }
                }
            }
            if (valid) {
                const view = self.stored_view.?;
                var uniform = view.header.uniform;
                while (uniform != 0) : (uniform &= uniform - 1) {
                    if (view.header.states[@ctz(uniform)] >= self.deps.blocks.light.states.len) return error.Corrupt;
                }
                self.delivery_prepared = true;
                self.delivery_active = true;
                self.stored_hits.add(1);
                return .ready;
            }
        }
        self.stored_misses.add(1);
        return if (try self.background.prepareInputsMode(self.deps.chunks, world, x, z, dimension, priority)) .ready else .pending;
    }

    pub fn validateDelivery(self: *Lighting) bool {
        if (!self.delivery_prepared) return true;
        assert(self.delivery_active and bakedSelection(self.stored_view.?, std.math.maxInt(u32)));
        if (self.stored_watch.unchanged()) return true;
        self.releaseDelivery();
        return false;
    }

    fn bakedSelection(view: *const chunks.Light.View, selection: u32) bool {
        const all = (@as(u32, 1) << @intCast(view.header.count)) - 1;
        var missing = selection & all & ~view.header.uniform;
        while (missing != 0) : (missing &= missing - 1) {
            if (view.terrain[@ctz(missing)] == null) return false;
        }
        return true;
    }

    pub fn deliveryTerrain(self: *Lighting, selection: u32) chunk_encoding.Sections {
        if (!self.delivery_prepared) return .{ .loaded = self.hulledSections(self.background.sections()) };
        assert(self.delivery_active and bakedSelection(self.stored_view.?, selection));
        return .{ .baked = .{ .view = self.stored_view.? } };
    }

    /// Hulled copies of loaded center sections, borrowed until the next call.
    fn hulledSections(self: *Lighting, sections: []const Section) []const Section {
        const hull = self.hull orelse return sections;
        for (sections, 0..) |section, index| {
            const target = &hull.sections[index];
            target.* = section;
            if (section.view == .uniform) continue;
            const states = &hull.states[index];
            for (states, 0..) |*state, cell| state.* = section.view.get(@intCast(cell));
            const faces = self.background.hullFaces(hull.table, index);
            if (section_hull.apply(states, &faces, hull.table) == 0) continue;
            hull.generation += 1;
            target.view = .{ .dense = states };
            target.stamp = .{ .generation = hull.generation, .index = index, .storage = .hulled };
        }
        return hull.sections[0..sections.len];
    }

    pub fn deliveryMetadata(self: *Lighting) []const Section {
        if (!self.delivery_prepared) return self.background.sections();
        assert(self.delivery_active);
        const count = self.stored_region.?.count;
        if (!self.delivery_metadata_ready) {
            const view = self.stored_view.?;
            for (self.delivery_sections[0..count], 0..) |*section, index| {
                const uniform = view.header.uniform & (@as(u32, 1) << @intCast(index)) != 0;
                const state = view.header.states[index];
                if (uniform) section.* = .{ .stamp = .{ .constant = state }, .view = .{ .uniform = state } } else section.* = .{ .stamp = .{ .generation = self.delivery_generation, .index = index, .storage = .baked }, .view = .unavailable };
                section.biomes = if (view.biome(4, index)) |biome| switch (biome) {
                    .uniform => |value| .{ .constant = value },
                    .dense => |bytes| .{ .encoded = .{ .bytes = bytes } },
                    .palette => |values| .{ .palette = values },
                } else null;
            }
            self.delivery_metadata_ready = true;
        }
        return self.delivery_sections[0..count];
    }

    pub fn deliveryBiomes(self: *const Lighting, output: []?Biomes) chunk_encoding.BiomeNeighborhood.Source {
        if (self.delivery_prepared) return .{ .baked = self.stored_view.? };
        const count = (self.background.pending orelse self.background.region.?).count;
        assert(output.len == 9 * count);
        for (0..9) |column| for (0..count) |section| {
            const index = column * maximum_sections + section;
            output[column * count + section] = if (self.background.biome_present[index]) .{ .values = &self.background.biome_values[index] } else null;
        };
        return .{ .loaded = output };
    }

    pub fn deliveryCoverage(self: *const Lighting) u32 {
        if (self.delivery_prepared) return self.stored_view.?.header.coverage;
        return if (self.background.pending == null and self.background.engine.lit) self.background.coverage else 0;
    }

    pub fn deliveryData(self: *const Lighting) Data {
        if (!self.delivery_prepared) return self.background.data();
        const view = self.stored_view.?;
        return .{ .source = .{ .stored = view }, .count = @as(usize, view.header.count) + 2, .masks = .{ @intCast(view.masks[0]), @intCast(view.masks[1]) }, .coverage = view.header.coverage };
    }

    pub fn lightDelivery(self: *Lighting, selection: u32) !void {
        if (self.delivery_prepared) {
            const all = (@as(u32, 1) << @intCast(self.stored_view.?.header.count)) - 1;
            assert(selection & all & ~self.stored_view.?.header.coverage == 0);
            return;
        }
        const region = self.background.pending orelse self.background.region.?;
        const persist = self.config.stored and self.deps.chunks.lightClean(.{ .world = region.world, .x = region.x, .z = region.z }, region.minimum, region.count);
        const requested = if (persist) (@as(u32, 1) << @intCast(region.count)) - 1 else selection;
        try self.background.solve(requested);
        if (persist) {
            try watchDelivery(self.fallback_watch, region);
            if (try self.prepareBackgroundFrame() and self.fallback_watch.unchanged()) {
                self.fallback_view = try self.stored_workspace.decode(try self.stored_workspace.finish());
                self.stored_view = &self.fallback_view;
                self.stored_region = region;
                self.stored_watch = self.fallback_watch;
                self.delivery_prepared = true;
                self.delivery_active = true;
                self.delivery_metadata_ready = false;
                self.baked_frames.add(1);
            } else self.unbaked_frame.add(1);
        } else if (self.config.stored) self.unbaked_dirty.add(1);
    }

    pub fn bake(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension) !bool {
        if (!try self.background.prepare(self.deps.chunks, world, x, z, dimension, 0)) return false;
        return self.persistBackground();
    }

    pub const Bake = union(enum) { loading, unstorable, baked: chunks.Light.View };

    /// Solves and bakes a column with no stored frame outside any delivery, publishing its light
    /// as a delivery solve would. The frame borrows the baker until its next bake. Unstorable
    /// means the neighbourhood is dirty or generating, so only an inline delivery can serve it.
    pub fn bakeDelivery(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, player: usize) !Bake {
        assert(!self.delivery_active);
        // The bake replaces the background workspace and stored frame of any earlier delivery.
        self.delivery_prepared = false;
        self.stored_region = null;
        self.stored_view = null;
        {
            const cpu = self.bake_timers.solve.start();
            defer cpu.end();
            if (!try self.background.prepare(self.deps.chunks, world, x, z, dimension, player)) return .loading;
        }
        const cpu = self.bake_timers.frame.start();
        defer cpu.end();
        if (!try self.prepareBackgroundFrame()) {
            self.unbaked_frame.add(1);
            return .unstorable;
        }
        self.baked_frames.add(1);
        return .{ .baked = try self.stored_workspace.decode(try self.stored_workspace.finish()) };
    }

    /// The frame borrows the baker until its next bake.
    pub fn bakeFrame(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension) !?chunks.Light.View {
        if (!try self.background.prepare(self.deps.chunks, world, x, z, dimension, 0)) return null;
        if (!try self.prepareBackgroundFrame()) return null;
        return try self.stored_workspace.decode(try self.stored_workspace.finish());
    }

    fn persistBackground(self: *Lighting) !bool {
        if (!try self.prepareBackgroundFrame()) return false;
        const region = self.background.region.?;
        const frame = try self.stored_workspace.finish();
        return self.deps.chunks.putLight(.{ .world = region.world, .x = region.x, .z = region.z }, try chunks.Light.Prefix.revisions(frame), frame);
    }

    /// Store facts a stored frame records, read while the workspace inputs are current.
    const FrameInputs = struct {
        revisions: [9]u64,
        metadata_length: usize = 0,
        metadata: [chunks.Light.maximum_metadata]u8 = undefined,
    };

    /// Null when the neighbourhood is dirty or generating, so a frame would not be storable.
    fn frameInputs(self: *Lighting, workspace: *const Workspace) !?FrameInputs {
        assert(self.deps.chunks.ownsCurrentThread() and workspace.input_ready);
        const region = workspace.pending orelse workspace.region.?;
        const column: chunks.Light.Column = .{ .world = region.world, .x = region.x, .z = region.z };
        var snapshots: [1]chunks.Light.Dependencies = undefined;
        try self.deps.chunks.lightDependencies(&.{.{ .column = column, .minimum = region.minimum, .count = region.count }}, &snapshots);
        if (!snapshots[0].clean) return null;
        var inputs: FrameInputs = .{ .revisions = snapshots[0].revisions };
        if (self.classification) |index| {
            var summaries: [1]chunks.classification.ColumnSummary = undefined;
            try self.deps.chunks.summarize(&.{.{ .world = region.world, .x = region.x, .z = region.z, .minimum = region.minimum, .count = @intCast(region.count) }}, &summaries, index.properties, index.selected);
            const codec = index.codec.?.column.?;
            inputs.metadata_length = try codec.encode(&summaries[0], inputs.metadata[0..codec.maximum]);
            assert(inputs.metadata_length > 0 and inputs.metadata_length <= codec.maximum);
        }
        return inputs;
    }

    /// Encodes a solved workspace into a frame.
    fn encodeFrame(self: *const Lighting, workspace: *Workspace, frame: *chunks.Light.Workspace, baker: *chunks.Prepared.Baker, inputs: *const FrameInputs) !bool {
        const region = workspace.region.?;
        const all = (@as(u32, 1) << @intCast(region.count)) - 1;
        if (workspace.coverage != all) return false;
        var biomes: [9]u32 = @splat(0);
        var uniform: u32 = 0;
        var states: [chunks.Light.maximum_sections]u16 = @splat(0);
        for (0..region.count) |section| if (workspace.uniforms[4 * maximum_sections + section]) |state| {
            uniform |= @as(u32, 1) << @intCast(section);
            states[section] = state;
        };
        for (0..9) |neighbor| for (0..region.count) |section| {
            if (workspace.biome_present[neighbor * maximum_sections + section]) biomes[neighbor] |= @as(u32, 1) << @intCast(section);
        };
        frame.begin(.{ .rules = self.rules, .minimum = region.minimum, .count = @intCast(region.count), .skylight = region.skylight, .coverage = all, .revisions = inputs.revisions, .biomes = biomes, .uniform = uniform, .states = states });
        if (self.classification) |index| {
            assert(inputs.metadata_length > 0);
            frame.metadata(index.identity, inputs.metadata[0..inputs.metadata_length]);
        }
        for (0..9) |neighbor| for (0..region.count) |section| {
            if (biomes[neighbor] & (@as(u32, 1) << @intCast(section)) != 0) frame.biome(&workspace.biome_values[neighbor * maximum_sections + section]);
        };
        var heights: [256]u16 = @splat(0);
        for (workspace.sections(), 0..) |section, index| {
            const destination = frame.terrainSection();
            const base: u16 = @intCast(index * 16);
            switch (section.view) {
                .uniform => |state| {
                    frame.commitUniformTerrain(state);
                    if (state >= self.terrain_properties.len) return error.InvalidBlockState;
                    if (self.terrain_properties[state] & 1 == 0) @memset(&heights, base + 16);
                },
                else => {
                    for (0..256) |row| baker.states[row * 16 ..][0..16].* = section.view.row(@intCast(row));
                    if (self.hull) |hull| {
                        const faces = workspace.hullFaces(hull.table, index);
                        _ = section_hull.apply(&baker.states, &faces, hull.table);
                    }
                    switch (try baker.encode(self.terrain_properties, destination)) {
                        .uniform => |state| frame.commitUniformTerrain(state),
                        .section => |bytes| frame.commitTerrain(bytes.len),
                    }
                    for (&heights, baker.heights) |*value, local| if (local != 0) {
                        value.* = base + local;
                    };
                },
            }
        }
        try frame.heightmap(&heights);
        for ([_]lighting.Layer{ .block, .sky }) |layer| for (0..region.count + 2) |section| {
            workspace.engine.packSection(layer, .{ 1, section, 1 }, frame.section());
            try frame.commitSection();
        };
        _ = try frame.finish();
        return true;
    }

    fn prepareBackgroundFrame(self: *Lighting) !bool {
        assert(self.deps.chunks.ownsCurrentThread());
        const region = self.background.region.?;
        if (self.background.coverage != (@as(u32, 1) << @intCast(region.count)) - 1) return false;
        const definition = self.deps.worlds.get(region.world).?.dimension;
        if (!self.background.current(self.deps.chunks, region.world, region.x, region.z, definition)) return false;
        const inputs = (try self.frameInputs(self.background)) orelse return false;
        self.stored_region = null;
        self.stored_view = null;
        return self.encodeFrame(self.background, &self.stored_workspace, self.terrain_baker, &inputs);
    }

    pub fn prepare(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, player: usize) !bool {
        if (dimension.sectionCount() == 0 or dimension.sectionCount() > maximum_sections) return error.UnsupportedLightingHeight;
        const all = (@as(u32, 1) << @intCast(dimension.sectionCount())) - 1;
        const solved = self.background.coverage == all and self.background.current(self.deps.chunks, world, x, z, dimension);
        if (!solved and !try self.background.prepare(self.deps.chunks, world, x, z, dimension, player)) return false;
        return true;
    }

    /// Bits select sections from the dimension minimum. Their lighting dependencies remain included.
    pub fn lightPrepared(self: *Lighting, selection: u32) !void {
        try self.background.solve(selection);
    }

    /// Simulation thread. Skylight is raw propagation light. Time and weather belong to
    /// the caller. Preserves input order.
    ///
    /// Light is what the store holds, which includes every edit whose blocks and light
    /// were in memory. An edit that waits for them is in the answer a tick or two later,
    /// as light lags in vanilla. A position whose column is not in memory answers null
    /// and the column is asked for. Nothing is read from disk or solved here.
    pub fn sampleMany(self: *Lighting, world: u32, positions: []const chunks.Position, output: []?Sample) !void {
        assert(positions.len == output.len);
        const definition = self.deps.worlds.get(world) orelse return error.UnknownWorld;
        const dimension = definition.dimension;
        if (dimension.sectionCount() == 0 or dimension.sectionCount() > maximum_sections) return error.UnsupportedLightingHeight;
        const bottom = @as(i64, dimension.minimumSection()) * 16;
        const top = bottom + @as(i64, dimension.section_count) * 16;
        for (positions) |position| {
            if (position.y < bottom or position.y >= top) return error.InvalidLightingPosition;
        }
        const store = self.store orelse {
            @memset(output, null);
            return;
        };
        // What can be settled from memory is in the answer.
        self.settle();
        const shape = dimensionShape(dimension);
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
                const key: light_store.Key = .{ .world = world, .x = group.key_ptr.x, .z = group.key_ptr.z };
                var cells: [batch_max]u32 = undefined;
                var order: [batch_max]usize = undefined;
                var levels: [batch_max]Sample = undefined;
                var count: usize = 0;
                var index = group.value_ptr.*;
                while (index != points.len) : (index = next[index]) {
                    const position = points[index];
                    const y: usize = @intCast(@as(i64, position.y) - bottom);
                    // Light sections start one below the world.
                    cells[count] = @intCast((y / 16 + 1) * 4096 + y % 16 * 256 + @as(usize, @intCast(@mod(position.z, 16))) * 16 + @as(usize, @intCast(@mod(position.x, 16))));
                    order[count] = index;
                    count += 1;
                }
                if (store.sample(key, shape, cells[0..count], levels[0..count])) {
                    for (order[0..count], levels[0..count]) |at, level| samples[at] = level;
                    continue;
                }
                for (order[0..count]) |at| samples[at] = null;
                self.wantColumn(key, shape);
            }
            begin = end;
        }
    }

    fn dimensionShape(dimension: worlds.Worlds.Dimension) light_store.Shape {
        return .{ .minimum = dimension.minimumSection(), .count = @intCast(dimension.sectionCount()), .skylight = dimension.skylight };
    }

    fn wantColumn(self: *Lighting, key: light_store.Key, shape: light_store.Shape) void {
        for (self.wants[0..self.want_count]) |entry| {
            if (std.meta.eql(entry.key, key)) return;
        }
        if (self.want_count == self.wants.len) return;
        self.wants[self.want_count] = .{ .key = key, .shape = shape };
        self.want_count += 1;
    }

    fn lightColumn(key: light_store.Key) chunks.Light.Column {
        return .{ .world = key.world, .x = key.x, .z = key.z };
    }

    fn neighbourKey(key: light_store.Key, index: usize) ?light_store.Key {
        const x = std.math.add(i32, key.x, @as(i32, @intCast(index % 3)) - 1) catch return null;
        const z = std.math.add(i32, key.z, @as(i32, @intCast(index / 3)) - 1) catch return null;
        return .{ .world = key.world, .x = x, .z = z };
    }

    fn near(a: light_store.Key, b: light_store.Key) bool {
        return a.world == b.world and @abs(@as(i64, a.x) - b.x) <= 1 and @abs(@as(i64, a.z) - b.z) <= 1;
    }

    fn sectionKey(section: chunks.Section) light_store.Key {
        return .{ .world = section.world, .x = section.x, .z = section.z };
    }

    /// Simulation thread, while the chunks announce an edit. Notes a light changing edit
    /// as unsettled and asks for the light of whichever of the nine columns around it is
    /// not in memory. Nothing is read here.
    fn blocksChanged(self: *Lighting, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        assert(edits.len == previous.len);
        const store = self.store.?;
        const registry = self.deps.blocks.light;
        var changed: usize = 0;
        var unknown = false;
        for (edits, previous) |edit, before| {
            if (edit.state == before) continue;
            const known = before < registry.states.len and edit.state < registry.states.len;
            if (known and registry.alike(before, edit.state)) continue;
            changed += 1;
            unknown = unknown or !known;
        }
        if (changed == 0) return;
        const dimension = (self.deps.worlds.get(section.world) orelse return).dimension;
        const count = dimension.sectionCount();
        if (count == 0 or count > maximum_sections) return;
        // Blocks outside the lit sections of the dimension change no light.
        const offset = @as(i64, section.y) - dimension.minimumSection();
        if (offset < 0 or offset >= count) return;
        const key = sectionKey(section);
        const shape = dimensionShape(dimension);
        store.noteFlush(self.deps.chunks.flushMark());
        // A state the rules do not know, or more edits than can be carried, cannot be patched.
        if (unknown or changed > self.unsettled.len - self.unsettled_count) return self.darkenAround(key, shape);
        const ready = self.prepareAround(key, shape) orelse return self.darkenAround(key, shape);
        // Whoever edits where everything was in memory is working there. Their next edit
        // one column over should find its light in memory too.
        if (ready) self.wantRing(key, shape);
        const stamp = self.deps.chunks.editStamp();
        for (edits, previous) |edit, before| {
            if (edit.state == before or registry.alike(before, edit.state)) continue;
            self.unsettled[self.unsettled_count] = .{ .section = section, .index = edit.index, .previous = before };
            self.unsettled_info[self.unsettled_count] = .{ .state = edit.state, .stamp = stamp, .tick = self.ticks };
            self.unsettled_count += 1;
        }
    }

    /// Asks for the sixteen columns just beyond the nine around an edit.
    fn wantRing(self: *Lighting, key: light_store.Key, shape: light_store.Shape) void {
        const store = self.store.?;
        var dz: i32 = -2;
        while (dz <= 2) : (dz += 1) {
            var dx: i32 = -2;
            while (dx <= 2) : (dx += 1) {
                if (@abs(dx) != 2 and @abs(dz) != 2) continue;
                const at: light_store.Key = .{
                    .world = key.world,
                    .x = std.math.add(i32, key.x, dx) catch continue,
                    .z = std.math.add(i32, key.z, dz) catch continue,
                };
                if (store.presence(at, shape) != .resident) self.wantColumn(at, shape);
            }
        }
    }

    /// Makes sure the light of the nine columns around `key` is in memory or on its way.
    /// True when all of it is in memory, which pins it. Null when one of them has no
    /// light that a patch could start from, or a load could not be asked for.
    fn prepareAround(self: *Lighting, key: light_store.Key, shape: light_store.Shape) ?bool {
        const store = self.store.?;
        var keys: [9]light_store.Key = undefined;
        for (&keys, 0..) |*at, index| {
            // A patch reads light across every border of the edited column.
            at.* = neighbourKey(key, index) orelse return null;
            if (store.presence(at.*, shape) == .unlit) return null;
        }
        var ready = true;
        for (keys) |at| switch (store.presence(at, shape)) {
            .resident => store.pin(at),
            .loading => ready = false,
            .unlit => unreachable,
            .absent, .overflowed => {
                ready = false;
                if (!self.requestLoad(at, shape)) return null;
            },
        };
        return ready;
    }

    /// Asks the terrain thread for the light of a column from disk. False when the store
    /// cannot load it or the hand-off is full.
    fn requestLoad(self: *Lighting, key: light_store.Key, shape: light_store.Shape) bool {
        const store = self.store.?;
        if (self.ops.count == self.ops.ops.len) {
            self.store_counters.crowded.add(1);
            return false;
        }
        const load = store.beginLoad(key, shape) orelse return false;
        self.ops.ops[self.ops.count] = .{ .load = .{ .key = key, .shape = shape, .stamp = load.stamp, .source = load.source } };
        self.ops.count += 1;
        return true;
    }

    /// Takes the stored light of the nine columns around an edit away, because no patch
    /// can follow the edit. Whoever was sent those columns hears about it.
    fn darkenAround(self: *Lighting, key: light_store.Key, shape: light_store.Shape) void {
        const store = self.store.?;
        const result = store.darken(key, shape);
        if (result.reset) {
            self.purge = true;
        } else for (result.records, 0..) |recorded, index| {
            if (recorded) self.deleteRecord(neighbourKey(key, index).?);
        }
        // The edits this column still had unsettled are part of what was lost.
        var kept: usize = 0;
        for (self.unsettled[0..self.unsettled_count], self.unsettled_info[0..self.unsettled_count]) |edit, info| {
            if (std.meta.eql(sectionKey(edit.section), key)) continue;
            self.unsettled[kept] = edit;
            self.unsettled_info[kept] = info;
            kept += 1;
        }
        self.unsettled_count = kept;
        if (self.sink) |sink| sink.unlit(sink.context, key.world, key.x, key.z, result.stamps);
    }

    /// A record nobody reads again stays on disk until the next purge when there is no
    /// room to ask for its delete. It is never read, as the store does not believe in it.
    fn deleteRecord(self: *Lighting, key: light_store.Key) void {
        if (self.purge or self.ops.count == self.ops.ops.len) return;
        self.ops.ops[self.ops.count] = .{ .delete = key };
        self.ops.count += 1;
    }

    /// Simulation thread. Patches stored light for every edit whose light and blocks are
    /// in memory. Runs before light is sampled and when a tick ends. Each column is
    /// settled against blocks in which the edits still waiting have not happened. An
    /// edit that waits too long has its light dropped and solved again.
    pub fn settle(self: *Lighting) void {
        const store = self.store orelse return;
        const count = self.unsettled_count;
        if (count == 0) return;
        // The edits move to `settling` grouped by column, columns in the order of their
        // first edit and edits in the order they were made. Each step is linear.
        self.pending_columns.clearRetainingCapacity();
        var columns: usize = 0;
        for (self.unsettled[0..count]) |edit| {
            const found = self.pending_columns.getOrPutAssumeCapacity(sectionKey(edit.section));
            if (!found.found_existing) {
                found.value_ptr.* = .{ .start = 0, .len = 0, .waiting = true };
                self.settle_order[columns] = found.key_ptr.*;
                columns += 1;
            }
            found.value_ptr.len += 1;
        }
        var start: u32 = 0;
        for (self.settle_order[0..columns]) |key| {
            const range = self.pending_columns.getPtr(key).?;
            range.start = start;
            start += range.len;
            range.len = 0;
        }
        assert(start == count);
        for (self.unsettled[0..count], self.unsettled_info[0..count]) |edit, info| {
            const range = self.pending_columns.getPtr(sectionKey(edit.section)).?;
            self.settling[range.start + range.len] = edit;
            self.settling_info[range.start + range.len] = info;
            range.len += 1;
        }
        self.unsettled_count = 0;
        const waiting: light_store.Waiting = .{ .edits = self.settling[0..count], .columns = &self.pending_columns };
        for (self.settle_order[0..columns]) |key| {
            const range = self.pending_columns.getPtr(key).?;
            // The edits being settled are not what the patch waits on.
            range.waiting = false;
            range.waiting = self.settleColumn(store, key, range.start, range.len, waiting);
        }
        // What still waits goes back in the same order. Nothing settling edits blocks.
        assert(self.unsettled_count == 0);
        for (self.settle_order[0..columns]) |key| {
            const range = self.pending_columns.get(key).?;
            if (!range.waiting) continue;
            @memcpy(self.unsettled[self.unsettled_count..][0..range.len], self.settling[range.start..][0..range.len]);
            @memcpy(self.unsettled_info[self.unsettled_count..][0..range.len], self.settling_info[range.start..][0..range.len]);
            self.unsettled_count += range.len;
        }
        assert(self.unsettled_count <= count);
    }

    /// Settles the edits of one column, which sit at `settling[start..][0..len]`. True
    /// when they wait for a later tick.
    fn settleColumn(self: *Lighting, store: *light_store.LightStore, key: light_store.Key, start: u32, len: u32, waiting: light_store.Waiting) bool {
        assert(len != 0);
        const edits = self.settling[start..][0..len];
        var oldest: u64 = std.math.maxInt(u64);
        for (self.settling_info[start..][0..len]) |info| oldest = @min(oldest, info.tick);
        // The world and its shape were checked when the edits were noted.
        const shape = dimensionShape(self.deps.worlds.get(key.world).?.dimension);
        const late = self.ticks - oldest >= pending_ticks_max;
        var loading = false;
        var lit = true;
        for (0..9) |index| switch (store.presence(neighbourKey(key, index).?, shape)) {
            .resident => {},
            .loading => loading = true,
            .unlit, .absent, .overflowed => lit = false,
        };
        if (!lit or len > self.patch_edits.len) {
            self.darkenAround(key, shape);
            return false;
        }
        if (loading) {
            if (!late) return true;
            self.store_counters.late.add(1);
            self.darkenAround(key, shape);
            return false;
        }
        // A tick patches its share and the rest waits, oldest first.
        if (!late and store.stats.steps - self.tick_steps >= self.patch_steps) {
            self.store_counters.deferred.add(1);
            return true;
        }
        for (edits, self.patch_edits[0..len]) |edit, *cell| {
            cell.* = .{ .section = @intCast(@as(i64, edit.section.y) - shape.minimum), .local = edit.index };
        }
        switch (store.settle(self.store_client.?, key, shape, self.patch_edits[0..len], waiting)) {
            .patched => |changes| if (self.sink) |sink| sink.patched(sink.context, key.world, key.x, key.z, changes.sections),
            .failed => self.darkenAround(key, shape),
            .waiting => |sections| {
                if (!late) {
                    self.requestWarm(key, shape, sections);
                    return true;
                }
                self.store_counters.late.add(1);
                self.darkenAround(key, shape);
            },
        }
        return false;
    }

    /// Asks the terrain thread to read block sections of the nine columns around `key`
    /// into the chunk cache. A request for the same column already in the hand-off
    /// grows instead.
    fn requestWarm(self: *Lighting, key: light_store.Key, shape: light_store.Shape, sections: u32) void {
        for (self.ops.ops[0..self.ops.count]) |*op| switch (op.*) {
            .warm => |*warm| if (std.meta.eql(warm.key, key)) {
                warm.sections |= sections;
                return;
            },
            else => {},
        };
        if (self.ops.count == self.ops.ops.len) {
            self.store_counters.crowded.add(1);
            return;
        }
        self.ops.ops[self.ops.count] = .{ .warm = .{ .key = key, .shape = shape, .sections = sections } };
        self.ops.count += 1;
    }

    /// Keeps the light around every unsettled edit in memory until it settles.
    fn pinPending(self: *Lighting) void {
        const store = self.store.?;
        var previous: ?light_store.Key = null;
        for (self.unsettled[0..self.unsettled_count]) |edit| {
            const key = sectionKey(edit.section);
            // The edits of a column sit together after a settle, and mostly before.
            if (previous) |known| if (std.meta.eql(known, key)) continue;
            previous = key;
            const shape = dimensionShape(self.deps.worlds.get(key.world).?.dimension);
            for (0..9) |index| {
                const at = neighbourKey(key, index) orelse continue;
                if (store.presence(at, shape) == .resident) store.pin(at);
            }
        }
    }

    /// Simulation thread. The light of a column in memory, borrowed until the store next
    /// changes. For the sink, which copies the sections a patch changed.
    pub fn storedLight(self: *Lighting, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, output: *light_store.Sections) bool {
        const store = self.store orelse return false;
        const count = dimension.sectionCount();
        if (count == 0 or count > maximum_sections) return false;
        return store.lightOf(.{ .world = world, .x = x, .z = z }, dimensionShape(dimension), output);
    }

    /// Simulation thread. Forgets the edits of a tick that did not complete, along with
    /// the stored light they may have left stale.
    pub fn discardUnsettled(self: *Lighting) void {
        if (self.store == null) return;
        while (self.unsettled_count != 0) {
            const key = sectionKey(self.unsettled[0].section);
            self.darkenAround(key, dimensionShape(self.deps.worlds.get(key.world).?.dimension));
        }
    }

    /// Simulation thread, once between player passes. The light around the columns then
    /// named with `protect` is kept for the players standing there.
    pub fn beginProtection(self: *Lighting) void {
        if (self.store) |store| store.beginProtection();
    }

    pub fn protect(self: *Lighting, world: u32, x: i32, z: i32) void {
        if (self.store) |store| store.protect(.{ .world = world, .x = x, .z = z });
    }

    /// Simulation thread, when a tick ends. Takes in what the terrain thread read or
    /// solved, settles what it can, makes room for the next tick and hands the disk
    /// work this asks for to the terrain thread. Nothing here does IO.
    pub fn finishTick(self: *Lighting) void {
        const store = self.store orelse return;
        self.ticks += 1;
        store.noteFlush(self.deps.chunks.flushMark());
        store.unpin();
        // Light the unsettled edits need stays while what was read comes in beside it.
        self.pinPending();
        self.takeResults();
        self.settle();
        // The next tick's share starts here.
        self.tick_steps = store.stats.steps;
        self.pinPending();
        if (self.purge and self.ops.count != self.ops.ops.len) {
            self.ops.ops[self.ops.count] = .purge;
            self.ops.count += 1;
            self.purge = false;
        }
        const scratch = self.scratch;
        // The largest record fits whenever there is room for any.
        const record_room = zstandard.bound(light_store.Copy.record_bytes);
        while (self.ops.count != self.ops.ops.len and self.ops.bytes.len - self.ops.used >= record_room) {
            switch (store.maintain(&scratch.copy)) {
                .idle => break,
                .overflow => {
                    const raw = scratch.copy.encode(self.stamp, &scratch.record);
                    const squeezed = self.compressor.encode(raw, self.ops.bytes[self.ops.used..]) catch {
                        store.lose(scratch.copy.key);
                        continue;
                    };
                    self.ops.ops[self.ops.count] = .{ .write = .{ .key = scratch.copy.key, .offset = @intCast(self.ops.used), .length = @intCast(squeezed.len) } };
                    self.ops.count += 1;
                    self.ops.used += squeezed.len;
                },
                .forgotten => |key| self.deleteRecord(key),
            }
        }
        // Columns gameplay asked for come in from disk, or from a solve when no stage has them.
        var waiting: usize = 0;
        for (self.wants[0..self.want_count]) |entry| switch (store.presence(entry.key, entry.shape)) {
            .resident, .loading => {},
            .unlit => self.requestSolve(entry.key, entry.shape),
            .absent, .overflowed => {
                if (self.requestLoad(entry.key, entry.shape)) continue;
                if (self.ops.count == self.ops.ops.len) {
                    self.wants[waiting] = entry;
                    waiting += 1;
                } else self.requestSolve(entry.key, entry.shape);
            },
        };
        self.want_count = waiting;
        self.publishOps();
        self.countStore();
    }

    /// Hands the ops of this tick to the terrain thread once it is done with the last.
    fn publishOps(self: *Lighting) void {
        self.store_mutex.lockUncancelable(self.deps.chunks.io);
        defer self.store_mutex.unlock(self.deps.chunks.io);
        if (self.ops_working.done() and self.ops.count != 0) {
            self.ops_working.clear();
            std.mem.swap(*Ops, &self.ops, &self.ops_working);
        }
        self.store_idle = self.ops.count == 0 and self.unsettled_count == 0 and self.want_count == 0;
    }

    /// Whether the light store waits for nothing: no disk work is asked for or under
    /// way, nothing read waits to be taken in, and no edit waits to be settled. Any thread.
    pub fn storeIdle(self: *Lighting) bool {
        if (self.store == null) return true;
        self.store_mutex.lockUncancelable(self.deps.chunks.io);
        defer self.store_mutex.unlock(self.deps.chunks.io);
        return self.store_idle and self.ops_working.done() and self.results.count == 0;
    }

    /// Simulation thread. Takes in the columns the terrain thread read or solved.
    fn takeResults(self: *Lighting) void {
        const store = self.store.?;
        {
            self.store_mutex.lockUncancelable(self.deps.chunks.io);
            defer self.store_mutex.unlock(self.deps.chunks.io);
            if (self.results.count == 0) return;
            std.mem.swap(*Results, &self.results, &self.results_taken);
        }
        const taken = self.results_taken;
        defer taken.clear();
        var sections: light_store.Sections = .{};
        for (taken.entries[0..taken.count]) |*entry| {
            if (entry.kind != .failed) taken.view(entry, &sections);
            switch (entry.kind) {
                // A solve read the current blocks, edits still waiting included. Next to such
                // an edit it is not the light a patch starts from. The edit finds the
                // column unlit, drops its own light and asks for a solve after it.
                .solved => {
                    if (!self.pendingNear(entry.key) and store.admitSolved(entry.key, entry.shape, entry.stamp, &sections)) store.pin(entry.key);
                    continue;
                },
                .record => if (!store.admitLoaded(entry.key, entry.shape, entry.stamp, &sections)) store.failLoad(entry.key, entry.stamp),
                .frame => {
                    if (self.frameCurrent(entry, taken.unsaved[entry.unsaved_start..][0..entry.unsaved_count]) and store.admitLoaded(entry.key, entry.shape, entry.stamp, &sections)) continue;
                    store.failLoad(entry.key, entry.stamp);
                },
                .failed => store.failLoad(entry.key, entry.stamp),
            }
            // A column that could not be read has to be solved. Edits waiting for it
            // darken it and ask again, and then only their solve counts.
            if (store.presence(entry.key, entry.shape) == .unlit) self.requestSolve(entry.key, entry.shape);
        }
    }

    /// Whether an edit waits to be settled in the nine columns around `key`.
    fn pendingNear(self: *const Lighting, key: light_store.Key) bool {
        for (self.unsettled[0..self.unsettled_count]) |edit| {
            if (near(sectionKey(edit.section), key)) return true;
        }
        return false;
    }

    /// Whether a frame read for a column is the light a patch of the unsettled edits
    /// around it starts from. A frame matches the saved blocks. Every unsettled edit
    /// made before it was read must then still have been in memory only, or the frame
    /// may have been baked with the edit in it already. An edit made after it was read
    /// cannot be in it.
    fn frameCurrent(self: *Lighting, entry: *const Results.Entry, unsaved: []const chunks.Chunks.Unsaved) bool {
        for (self.unsettled[0..self.unsettled_count], self.unsettled_info[0..self.unsettled_count]) |edit, info| {
            if (info.stamp > entry.edit_stamp or !near(sectionKey(edit.section), entry.key)) continue;
            const kept = for (unsaved) |section| {
                if (std.meta.eql(section.section, edit.section) and section.since <= info.stamp) break true;
            } else false;
            if (kept) continue;
            self.store_counters.stale.add(1);
            return false;
        }
        return true;
    }

    /// Asks for a solve of a column no stage has light for.
    fn requestSolve(self: *Lighting, key: light_store.Key, shape: light_store.Shape) void {
        const stamp = self.store.?.request(key, shape);
        if (stamp == 0) return;
        if (self.sink) |sink| sink.wanted(sink.context, key.world, key.x, key.z, stamp);
    }

    /// Adds what the store did since the last tick to the counters.
    fn countStore(self: *Lighting) void {
        const now = self.store.?.snapshot();
        const seen = self.store_seen;
        const counters = &self.store_counters;
        counters.patched.add(now.patches - seen.patches);
        counters.attempts.add(now.attempts - seen.attempts);
        counters.steps.add(now.steps - seen.steps);
        counters.failed.add(now.failures - seen.failures);
        counters.waits.add(now.waits - seen.waits);
        counters.darkened.add(now.darkened - seen.darkened);
        counters.frames.add(now.frames - seen.frames);
        counters.restores.add(now.restores - seen.restores);
        counters.solves.add(now.solves - seen.solves);
        counters.evictions.add(now.evictions - seen.evictions);
        counters.overflows.add(now.overflows - seen.overflows);
        counters.forgotten.add(now.forgotten - seen.forgotten);
        counters.resets.add(now.resets - seen.resets);
        counters.sample_hits.add(now.hits - seen.hits);
        counters.sample_misses.add(now.misses - seen.misses);
        self.store_seen = now;
    }

    /// Terrain thread. Does the disk work the simulation thread handed over, in order and
    /// as far as there is room for what it reads. Answers whether it did any.
    pub fn pollStore(self: *Lighting) !bool {
        if (self.store == null) return false;
        const ops = ops: {
            self.store_mutex.lockUncancelable(self.deps.chunks.io);
            defer self.store_mutex.unlock(self.deps.chunks.io);
            break :ops self.ops_working;
        };
        // The simulation thread swaps these ops out only once they are done, which may
        // happen between the look above and the write below. Done ops are not written.
        var done = ops.next;
        const start = done;
        defer if (done != start) {
            self.store_mutex.lockUncancelable(self.deps.chunks.io);
            assert(self.ops_working == ops);
            ops.next = done;
            self.store_mutex.unlock(self.deps.chunks.io);
        };
        while (done < ops.count and done - start < ops_per_poll) {
            const first = ops.ops[done];
            // Ops of one kind that follow each other go to disk together.
            var end = done + 1;
            const limit = @min(ops.count, done + @as(usize, switch (first) {
                .write, .delete => record_batch,
                .load => load_batch,
                .purge, .warm => 1,
            }));
            while (end < limit and std.meta.activeTag(ops.ops[end]) == std.meta.activeTag(first)) : (end += 1) {
                if (first == .load and ops.ops[end].load.source != first.load.source) break;
            }
            const batch = ops.ops[done..end];
            switch (first) {
                .write => self.writeRecords(ops, batch),
                .delete => self.deleteRecords(batch),
                .purge => {
                    const timing = self.store_writes.start();
                    defer timing.end();
                    while (self.deps.chunks.clearPatchedLights()) {}
                },
                .warm => |warm| try self.warmSections(warm.key, warm.shape, warm.sections),
                .load => {
                    // What is read must fit where the simulation thread takes it in.
                    const fits = self.resultRoom(batch.len);
                    if (fits == 0) break;
                    end = done + fits;
                    switch (first.load.source) {
                        .record => self.loadRecords(ops.ops[done..end]),
                        .frame => try self.loadFrames(ops.ops[done..end]),
                    }
                },
            }
            done = end;
        }
        return done != start;
    }

    /// How many of the next loads the results have room for.
    fn resultRoom(self: *Lighting, wanted: usize) usize {
        self.store_mutex.lockUncancelable(self.deps.chunks.io);
        defer self.store_mutex.unlock(self.deps.chunks.io);
        const results = self.results;
        const by_entries = results.entries.len - results.count;
        const by_bytes = (results.bytes.len - results.used) / light_store.Copy.capacity;
        const by_unsaved = (results.unsaved.len - results.unsaved_used) / unsaved_max;
        return @min(wanted, by_entries, by_bytes, by_unsaved);
    }

    /// Terrain thread. Adds a column to the results. The caller checked there is room.
    fn addResult(self: *Lighting, entry: Results.Entry, light: ?*const light_store.Sections, unsaved: []const chunks.Chunks.Unsaved) void {
        assert(unsaved.len <= unsaved_max);
        self.store_mutex.lockUncancelable(self.deps.chunks.io);
        defer self.store_mutex.unlock(self.deps.chunks.io);
        const results = self.results;
        const added = results.add(entry, light);
        added.unsaved_start = @intCast(results.unsaved_used);
        added.unsaved_count = @intCast(unsaved.len);
        @memcpy(results.unsaved[results.unsaved_used..][0..unsaved.len], unsaved);
        results.unsaved_used += unsaved.len;
    }

    fn writeRecords(self: *Lighting, ops: *const Ops, batch: []const Ops.Op) void {
        const timing = self.store_writes.start();
        defer timing.end();
        var columns: [record_batch]chunks.Light.Column = undefined;
        var values: [record_batch]?[]const u8 = undefined;
        for (batch, columns[0..batch.len], values[0..batch.len]) |op, *column, *value| {
            column.* = lightColumn(op.write.key);
            value.* = ops.bytes[op.write.offset..][0..op.write.length];
        }
        // A record the cache did not take is missing when it is read, and its column
        // is solved then.
        if (!self.deps.chunks.putPatchedLights(columns[0..batch.len], values[0..batch.len])) self.store_counters.write_failures.add(batch.len);
    }

    fn deleteRecords(self: *Lighting, batch: []const Ops.Op) void {
        const timing = self.store_writes.start();
        defer timing.end();
        var columns: [record_batch]chunks.Light.Column = undefined;
        const values: [record_batch]?[]const u8 = @splat(null);
        for (batch, columns[0..batch.len]) |op, *column| column.* = lightColumn(op.delete);
        if (!self.deps.chunks.putPatchedLights(columns[0..batch.len], values[0..batch.len])) self.store_counters.write_failures.add(batch.len);
    }

    /// Reads block sections the patch of an edit needs into the chunk cache, so that
    /// the simulation thread finds them in memory.
    fn warmSections(self: *Lighting, key: light_store.Key, shape: light_store.Shape, sections: u32) !void {
        var positions: [9 * maximum_sections]chunks.Section = undefined;
        var count: usize = 0;
        for (0..9) |index| {
            const at = neighbourKey(key, index) orelse continue;
            var bits = sections & ((@as(u32, 1) << @intCast(shape.count)) - 1);
            while (bits != 0) : (bits &= bits - 1) {
                positions[count] = .{ .world = at.world, .x = at.x, .y = shape.minimum + @as(i32, @intCast(@ctz(bits))), .z = at.z };
                count += 1;
            }
        }
        var leases: [9 * maximum_sections]chunks.Lease = undefined;
        var begin: usize = 0;
        while (begin < count) {
            const end = begin + @min(count - begin, self.background.client.budget());
            const held = leases[begin..end];
            try self.background.client.acquireMany(positions[begin..end], held);
            self.deps.chunks.releaseMany(held);
            begin = end;
        }
    }

    fn loadRecords(self: *Lighting, batch: []const Ops.Op) void {
        const timing = self.store_reads.start();
        defer timing.end();
        var columns: [load_batch]chunks.Light.Column = undefined;
        var values: [load_batch]?[]const u8 = undefined;
        var complete: [load_batch]bool = undefined;
        for (batch, columns[0..batch.len]) |op, *column| column.* = lightColumn(op.load.key);
        const scratch = self.terrain_scratch;
        var begin: usize = 0;
        while (begin < batch.len) {
            // What the buffer had no room left for is read again, on its own at worst.
            var read: records.PackedRead = .{ .bytes = self.store_frames.raw, .values = values[begin..batch.len], .complete = complete[begin..batch.len] };
            self.deps.chunks.patchedLights(columns[begin..batch.len], &read);
            const finished = begin + (std.mem.indexOfScalar(bool, complete[begin..batch.len], false) orelse batch.len - begin);
            for (batch[begin..@max(finished, begin + 1)], values[begin..@max(finished, begin + 1)]) |op, value| {
                const load = op.load;
                const entry: Results.Entry = .{ .key = load.key, .shape = load.shape, .stamp = load.stamp, .kind = .record };
                const record = value orelse {
                    self.addResult(.{ .key = load.key, .shape = load.shape, .stamp = load.stamp, .kind = .failed }, null, &.{});
                    continue;
                };
                const raw = self.decompressor.decode(record, &scratch.record) catch null;
                if (raw == null or !scratch.copy.decode(load.key, load.shape, self.stamp, raw.?)) {
                    self.addResult(.{ .key = load.key, .shape = load.shape, .stamp = load.stamp, .kind = .failed }, null, &.{});
                    continue;
                }
                const light = scratch.copy.view();
                self.addResult(entry, &light, &.{});
            }
            begin = @max(finished, begin + 1);
        }
    }

    fn loadFrames(self: *Lighting, batch: []const Ops.Op) !void {
        const timing = self.store_reads.start();
        defer timing.end();
        var requests: [load_batch]chunks.Light.Request = undefined;
        var snapshots: [load_batch]?chunks.Chunks.UnsavedSnapshot = undefined;
        var unsaved: [load_batch][unsaved_max]chunks.Chunks.Unsaved = undefined;
        for (batch, requests[0..batch.len], snapshots[0..batch.len], unsaved[0..batch.len]) |op, *request, *snapshot, *list| {
            const load = op.load;
            request.* = .{ .column = lightColumn(load.key), .minimum = load.shape.minimum, .count = load.shape.count };
            // What is in memory only is noted before the frame is read.
            snapshot.* = self.deps.chunks.unsavedAround(request.column, load.shape.minimum, load.shape.count, list);
        }
        var frames: [load_batch]?[]const u8 = undefined;
        var complete: [load_batch]bool = undefined;
        var clean: [load_batch]bool = undefined;
        var sections: light_store.Sections = .{};
        var begin: usize = 0;
        while (begin < batch.len) {
            var read: chunks.Light.FrameBatch = .{ .bytes = self.store_frames.raw, .frames = frames[begin..batch.len], .complete = complete[begin..batch.len], .clean = clean[begin..batch.len] };
            try self.deps.chunks.lightFrames(requests[begin..batch.len], &read);
            const write_mark = self.deps.chunks.writeMark();
            const finished = begin + (std.mem.indexOfScalar(bool, complete[begin..batch.len], false) orelse batch.len - begin);
            for (batch[begin..@max(finished, begin + 1)], frames[begin..@max(finished, begin + 1)], snapshots[begin..@max(finished, begin + 1)], unsaved[begin..@max(finished, begin + 1)]) |op, value, snapshot, *list| {
                const load = op.load;
                const failed: Results.Entry = .{ .key = load.key, .shape = load.shape, .stamp = load.stamp, .kind = .failed };
                const frame = value orelse {
                    self.addResult(failed, null, &.{});
                    continue;
                };
                // A section written while the frame was read may have brought an unsaved
                // edit into it. One noted as in memory only must still be.
                const noted = snapshot orelse {
                    self.addResult(failed, null, &.{});
                    continue;
                };
                if (noted.write_mark != write_mark or !self.frameLight(frame, load.shape, &sections)) {
                    self.addResult(failed, null, &.{});
                    continue;
                }
                self.addResult(.{ .key = load.key, .shape = load.shape, .stamp = load.stamp, .kind = .frame, .edit_stamp = noted.stamp }, &sections, list[0..noted.count]);
            }
            begin = @max(finished, begin + 1);
        }
    }

    /// Decodes the light of a frame into the terrain scratch. False when the frame was
    /// not baked for this shape of world under these rules.
    fn frameLight(self: *Lighting, frame: []const u8, shape: light_store.Shape, output: *light_store.Sections) bool {
        const view = self.store_frames.decode(frame) catch return false;
        if (view.header.minimum != shape.minimum or view.header.count != shape.count or view.header.skylight != shape.skylight) return false;
        if (view.header.coverage != (@as(u32, 1) << @intCast(shape.count)) - 1) return false;
        if (!std.mem.eql(u8, &view.header.rules, &self.rules)) return false;
        var used: usize = 0;
        for (0..2) |layer| for (0..shape.sections()) |section| {
            if (view.layers[layer][section].level()) |level| {
                output.light[layer][section] = .{ .uniform = level };
                continue;
            }
            view.layer(layer, section).write(&self.terrain_scratch.bytes[used]) catch return false;
            output.light[layer][section] = .{ .dense = &self.terrain_scratch.bytes[used] };
            used += 1;
        };
        return true;
    }

    /// Terrain thread. Hands the store the light of the column the background workspace
    /// has just solved in full, in answer to the request the stamp names. The store
    /// takes it at the end of the next tick, unless an edit darkened the column again.
    /// False when the hand-off has no room, which leaves the column unlit until
    /// something asks again.
    pub fn offer(self: *Lighting, stamp: u64) bool {
        assert(stamp != 0 and self.store != null);
        // The solve it hands over is in the workspace of the terrain thread.
        assert(self.deps.chunks.ownsCurrentThread());
        const workspace = self.background;
        const region = workspace.region.?;
        assert(workspace.coverage == (@as(u32, 1) << @intCast(region.count)) - 1);
        const shape: light_store.Shape = .{ .minimum = region.minimum, .count = @intCast(region.count), .skylight = region.skylight };
        if (self.resultRoom(1) == 0) {
            self.store_counters.refused.add(1);
            return false;
        }
        const scratch = self.terrain_scratch;
        var sections: light_store.Sections = .{};
        var used: usize = 0;
        inline for (.{ lighting.Layer.block, lighting.Layer.sky }, 0..) |layer, index| {
            for (0..shape.sections()) |section| {
                workspace.engine.packSection(layer, .{ 1, section, 1 }, &scratch.bytes[used]);
                sections.light[index][section] = .{ .dense = &scratch.bytes[used] };
                used += 1;
            }
        }
        self.addResult(.{ .key = .{ .world = region.world, .x = region.x, .z = region.z }, .shape = shape, .stamp = stamp, .kind = .solved }, &sections, &.{});
        return true;
    }

    /// Bytes the store and everything that moves light in and out of it hold for the
    /// whole life of the service.
    pub fn storeMemory(self: *const Lighting) usize {
        const store = self.store orelse return 0;
        var total = store.memory() + 2 * @sizeOf(Scratch) + self.store_frames.raw.len + self.compressor.memory.len;
        total += (self.unsettled.len + self.settling.len) * (@sizeOf(light_store.Pending) + @sizeOf(Unsettled)) + self.settle_order.len * @sizeOf(light_store.Key);
        for ([_]*const Ops{ self.ops, self.ops_working }) |ops| total += @sizeOf(Ops) + ops.ops.len * @sizeOf(Ops.Op) + ops.bytes.len;
        for ([_]*const Results{ self.results, self.results_taken }) |results| {
            total += @sizeOf(Results) + results.entries.len * @sizeOf(Results.Entry) + results.bytes.len * light_store.section_bytes + results.unsaved.len * @sizeOf(chunks.Chunks.Unsaved);
        }
        return total;
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
    pub const Uniforms = struct {
        allocator: std.mem.Allocator,
        patterns: [16][2050]u8 = undefined,
        views: [16][]const u8 = undefined,
        baker: deflate.fragments.Baker,
        repetitions: deflate.fragments.Repetitions(512) = undefined,

        pub fn init(allocator: std.mem.Allocator) !*Uniforms {
            const self = try allocator.create(Uniforms);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .baker = try .init(allocator) };
            errdefer self.baker.deinit();
            for (&self.patterns, &self.views, 0..) |*pattern, *view, level| {
                var writer: std.Io.Writer = .fixed(pattern);
                try varint(&writer, 2048);
                @memset(try writer.writableSlice(2048), @as(u8, @intCast(level)) * 17);
                view.* = writer.buffered();
                assert(view.len == pattern.len);
            }
            self.repetitions = try .init(allocator, &self.views, maximum_sections + 2, &self.baker);
            return self;
        }

        pub fn deinit(self: *Uniforms) void {
            const allocator = self.allocator;
            self.repetitions.deinit();
            self.baker.deinit();
            allocator.destroy(self);
        }
    };

    source: union(enum) {
        computed: *const lighting.Engine,
        stored: *const chunks.Light.View,
        /// Sections a patch changed, held by whoever sends them. Only selected sections are read.
        patched: *const light_store.Sections,
    },
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

    pub fn encodedSize(self: Data) usize {
        assert(self.count > 2 and self.count <= maximum_sections + 2);
        const selected_sections = self.selected();
        const nonzero_sections = self.nonzero();
        const layers: usize = @as(usize, @popCount(selected_sections[0] & nonzero_sections[0])) + @popCount(selected_sections[1] & nonzero_sections[1]);
        return 4 * 9 + 2 + layers * (2 + 2048);
    }

    pub fn write(self: Data, writer: *std.Io.Writer) !void {
        return self.writeData(writer, null, null);
    }

    pub fn writeFragments(self: Data, fragments: *deflate.fragments.Stream, uniforms: *Uniforms) !void {
        return self.writeData(&fragments.writer, fragments, uniforms);
    }

    fn writeData(self: Data, writer: *std.Io.Writer, fragments: ?*deflate.fragments.Stream, uniforms: ?*Uniforms) !void {
        assert(self.count > 2 and self.count <= maximum_sections + 2);
        const all = (@as(u64, 1) << @intCast(self.count)) - 1;
        assert((@as(u64, self.masks[0] | self.masks[1]) & ~all) == 0);
        switch (self.source) {
            .computed => |engine| assert(engine.dimensions.x >= 32 and engine.dimensions.z >= 32 and engine.dimensions.y >= self.count * 16),
            .stored => |view| assert(@as(usize, view.header.count) + 2 == self.count),
            .patched => {},
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
            var bits = filtered[index];
            try varint(writer, @popCount(bits));
            while (bits != 0) {
                const section = @ctz(bits);
                bits &= bits - 1;
                if (fragments) |splice| if (self.source == .stored) {
                    const view = self.source.stored;
                    if (view.layers[index][section].level()) |level| {
                        var count: usize = 1;
                        while (bits != 0) {
                            const next = @ctz(bits);
                            const plane = view.layers[index][next];
                            if (plane.level() != level) break;
                            count += 1;
                            bits &= bits - 1;
                        }
                        if (try uniforms.?.repetitions.get(level, count)) |fragment| {
                            try splice.append(fragment);
                        } else {
                            try writer.splatBytesAll(uniforms.?.views[level], count);
                        }
                        continue;
                    }
                };
                try varint(writer, 2048);
                switch (self.source) {
                    .computed => |engine| {
                        const bytes = try writer.writableSlice(2048);
                        engine.packSection(layer, .{ 1, section, 1 }, bytes[0..2048]);
                    },
                    .stored => |view| {
                        const plane = view.layer(index, section);
                        if (fragments) |splice| switch (plane) {
                            .encoded => |value| {
                                try splice.append(value.fragment);
                                continue;
                            },
                            .uniform, .dense => {},
                        };
                        const bytes = try writer.writableSlice(2048);
                        try plane.write(bytes[0..2048]);
                    },
                    .patched => |sections| {
                        const bytes = try writer.writableSlice(2048);
                        switch (sections.light[index][section]) {
                            .uniform => |level| @memset(bytes[0..2048], @as(u8, level) * 17),
                            .dense => |levels| @memcpy(bytes[0..2048], levels),
                        }
                    },
                }
            }
        }
    }
};

/// One client column. Reset on unload, dimension changes, or a new player lifetime.
pub const Receipt = struct {
    const Layer = packed struct(u64) { present: u29 = 0, empty: u29 = 0, count: u6 = 0 };

    pub const Update = struct {
        owner: *const Receipts,
        version: ?u64,
        count: u6,
        selection: u32,
        selected: [2]u32,
        nonzero: [2]u32,
    };

    revision: u64 = 0,
    layers: [2]Layer = @splat(.{}),

    fn retained(self: *const Receipt, update: Update) [2]u32 {
        assert(self.layers[0].count == self.layers[1].count);
        if (self.layers[0].count != update.count) return .{ 0, 0 };
        const unchanged = if (update.version) |version| self.revision == version else false;
        var result: [2]u32 = undefined;
        for (&result, self.layers, 0..) |*bits, layer, index| {
            bits.* = update.selection & ((@as(u32, layer.empty) & ~update.nonzero[index]) | (if (unchanged) @as(u32, layer.present) & update.nonzero[index] else 0));
        }
        return result;
    }

    fn apply(self: *Receipt, update: Update) void {
        assert(update.count > 2 and update.count <= maximum_sections + 2);
        const all = (@as(u32, 1) << @intCast(update.count)) - 1;
        if (self.layers[0].count != update.count) self.* = .{};
        if (update.version) |version| {
            if (self.revision != version) for (&self.layers) |*layer| {
                layer.present = 0;
            };
            self.revision = version;
        }
        for (&self.layers, 0..) |*layer, index| {
            const selected = update.selected[index];
            assert((selected | update.nonzero[index]) & ~all == 0);
            layer.present &= ~@as(u29, @intCast(selected));
            layer.empty = @intCast((@as(u32, layer.empty) & ~selected) | (selected & ~update.nonzero[index]));
            if (update.version != null) layer.present |= @intCast(selected & update.nonzero[index]);
            layer.count = update.count;
            assert(layer.present & layer.empty == 0);
        }
    }
};

/// Rules are immutable for this bank's lifetime. A new lighting instance starts with empty receipts.
pub const Receipts = struct {
    rules: [32]u8,
    entries: []Receipt,

    pub fn init(allocator: std.mem.Allocator, count: usize, rules: [32]u8) !Receipts {
        const entries = try allocator.alloc(Receipt, count);
        @memset(entries, .{});
        return .{ .rules = rules, .entries = entries };
    }

    pub fn capture(self: *const Receipts, data: Data) Receipt.Update {
        assert(data.count > 2 and data.count <= maximum_sections + 2);
        if (data.source == .stored) {
            const header = data.source.stored.header;
            assert(std.mem.eql(u8, &header.rules, &self.rules));
            assert(@as(usize, header.count) + 2 == data.count);
            assert(header.coverage == (@as(u32, 1) << @intCast(header.count)) - 1);
        }
        return .{
            .owner = self,
            .version = switch (data.source) {
                .stored => |view| view.header.revision(),
                .computed, .patched => null,
            },
            .count = @intCast(data.count),
            .selection = data.selection orelse (@as(u32, 1) << @intCast(data.count)) - 1,
            .selected = data.selected(),
            .nonzero = data.nonzero(),
        };
    }

    pub fn retained(self: *const Receipts, index: usize, update: Receipt.Update) [2]u32 {
        assert(update.owner == self);
        return self.entries[index].retained(update);
    }

    /// Commit only the masks admitted to the client's ordered output queue.
    pub fn apply(self: *Receipts, index: usize, update: Receipt.Update) void {
        assert(update.owner == self);
        self.entries[index].apply(update);
    }

    pub fn reset(self: *Receipts, begin: usize, count: usize) void {
        @memset(self.entries[begin..][0..count], .{});
    }
};

comptime {
    assert(maximum_sections + 2 <= 29);
    assert(@sizeOf(Receipt) == 24);
}

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

test "uniform light runs preserve complete sparse packets without runtime allocation" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const uniforms = try Data.Uniforms.init(bounded.allocator());
    defer uniforms.deinit();
    var decoder = try deflate.Decoder.init(bounded.allocator());
    defer decoder.deinit();
    const expected = try bounded.allocator().alloc(u8, Data.capacity);
    defer bounded.allocator().free(expected);
    const encoded = try bounded.allocator().alloc(u8, Data.capacity + 2048);
    defer bounded.allocator().free(encoded);
    const actual = try bounded.allocator().alloc(u8, Data.capacity);
    defer bounded.allocator().free(actual);
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var view: chunks.Light.View = .{ .header = .{ .rules = @splat(0), .minimum = -4, .count = maximum_sections, .skylight = true, .coverage = 0xffffff, .revisions = @splat(1), .biomes = @splat(0) } };
    var random = std.Random.DefaultPrng.init(0x1a6e91);
    for (0..96) |iteration| {
        for (&view.layers) |*layers| for (layers, 0..) |*plane, index| {
            plane.* = .uniform(if (iteration < 16) @intCast(iteration) else @intCast((index / 3 + iteration) % 16));
        };
        const all: u32 = (1 << (maximum_sections + 2)) - 1;
        const selection = if (iteration < 32) all else random.random().int(u32) & all;
        const data: Data = .{ .source = .{ .stored = &view }, .count = maximum_sections + 2, .masks = .{ all, all }, .selection = selection };
        var plain: std.Io.Writer = .fixed(expected);
        try data.write(&plain);
        var fragments = try deflate.fragments.Stream.begin(encoded);
        try data.writeFragments(&fragments, uniforms);
        const frame = try fragments.finish();
        try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(frame, actual));
        if (iteration < 16) try std.testing.expect(frame.len < plain.end / 10);
    }
    try std.testing.expect(!bounded.has_induced_failure);
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
    var receipt_storage: [1]Receipt = @splat(.{});
    var receipts: Receipts = .{ .entries = &receipt_storage, .rules = @splat(1) };
    const original = receipts.capture(data);
    try std.testing.expectEqual([2]u32{ 0, 0 }, receipts.retained(0, receipts.capture(data)));
    receipts.apply(0, original);
    try std.testing.expectEqual([2]u32{ 7, 7 }, receipts.retained(0, receipts.capture(data)));

    var changed = data;
    changed.masks[0] = 0;
    try std.testing.expectEqual([2]u32{ 5, 7 }, receipts.retained(0, receipts.capture(changed)));
    changed.retained = receipts.retained(0, receipts.capture(changed));
    receipts.apply(0, receipts.capture(changed));
    try std.testing.expectEqual([2]u32{ 7, 7 }, receipts.retained(0, receipts.capture(changed)));
    try std.testing.expectEqual([2]u32{ 5, 7 }, receipts.retained(0, receipts.capture(data)));
    receipts.apply(0, original);

    var concealed = data;
    concealed.disclosure = 0;
    try std.testing.expectEqual([2]u32{ 5, 5 }, receipts.retained(0, receipts.capture(concealed)));
    concealed.retained = receipts.retained(0, receipts.capture(concealed));
    receipts.apply(0, receipts.capture(concealed));
    try std.testing.expectEqual([2]u32{ 5, 5 }, receipts.retained(0, receipts.capture(data)));
    receipts.apply(0, original);

    for (&view.header.revisions, 1..) |*revision, sequence| {
        revision.* = sequence;
        try std.testing.expectEqual([2]u32{ 5, 0 }, receipts.retained(0, receipts.capture(data)));
        receipts.apply(0, receipts.capture(data));
        try std.testing.expectEqual([2]u32{ 7, 7 }, receipts.retained(0, receipts.capture(data)));
    }
    view.header.rules[0] += 1;
    var changed_storage: [1]Receipt = @splat(.{});
    var changed_receipts: Receipts = .{ .entries = &changed_storage, .rules = view.header.rules };
    try std.testing.expectEqual([2]u32{ 0, 0 }, changed_receipts.retained(0, changed_receipts.capture(data)));
    changed_receipts.apply(0, changed_receipts.capture(data));
    try std.testing.expectEqual([2]u32{ 7, 7 }, changed_receipts.retained(0, changed_receipts.capture(data)));
    view.header.rules = receipts.rules;
    receipts.reset(0, 1);
    try std.testing.expectEqual([2]u32{ 0, 0 }, receipts.retained(0, receipts.capture(data)));
}

test "lighting receipts preserve both boundary layers at the maximum dimension height" {
    var receipt_storage: [1]Receipt = @splat(.{});
    var receipts: Receipts = .{ .entries = &receipt_storage, .rules = @splat(1) };
    const all = (@as(u32, 1) << (maximum_sections + 2)) - 1;
    const view: chunks.Light.View = .{ .header = .{ .rules = receipts.rules, .minimum = -4, .count = maximum_sections, .skylight = true, .coverage = (@as(u32, 1) << maximum_sections) - 1, .revisions = @splat(7), .biomes = @splat(0) } };
    var data: Data = .{ .source = .{ .stored = &view }, .count = maximum_sections + 2, .masks = .{ all, all } };
    receipts.apply(0, receipts.capture(data));
    try std.testing.expectEqual([2]u32{ all, all }, receipts.retained(0, receipts.capture(data)));
    const top = @as(u32, 1) << (maximum_sections + 1);
    data.selection = top;
    data.masks = .{ all ^ top, all };
    receipts.apply(0, receipts.capture(data));
    try std.testing.expectEqual([2]u32{ top, top }, receipts.retained(0, receipts.capture(data)));
    data.selection = null;
    try std.testing.expectEqual([2]u32{ all, all }, receipts.retained(0, receipts.capture(data)));
}

test "omitted lighting leaves client arrays unchanged and computed light remains conservative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var engine = try lighting.Engine.init(arena.allocator(), .{ .x = 48, .y = 48, .z = 48 }, try game_data.lighting.init(arena.allocator()));
    try engine.load(.{ .uniform = 0 });
    engine.relight(true);
    var buffer: [8192]u8 = undefined;
    var receipt_storage: [1]Receipt = @splat(.{});
    var receipts: Receipts = .{ .entries = &receipt_storage, .rules = @splat(1) };
    var data: Data = .{ .source = .{ .computed = &engine }, .count = 3, .masks = .{ 0, 7 }, .disclosure = 1 };
    receipts.apply(0, receipts.capture(data));
    try std.testing.expectEqual([2]u32{ 7, 0 }, receipts.retained(0, receipts.capture(data)));
    data.retained = receipts.retained(0, receipts.capture(data));
    var writer: std.Io.Writer = .fixed(&buffer);
    try data.write(&writer);
    for ([_]u64{ 7, 0, 0, 0 }, 0..) |expected, index| {
        try std.testing.expectEqual(@as(u8, 1), buffer[index * 9]);
        try std.testing.expectEqual(expected, std.mem.readInt(u64, buffer[index * 9 + 1 ..][0..8], .big));
    }
    var dark = data;
    dark.masks = .{ 0, 0 };
    dark.retained = .{ 0, 0 };
    receipts.apply(0, receipts.capture(dark));
    dark.retained = receipts.retained(0, receipts.capture(dark));
    writer = .fixed(&buffer);
    try dark.write(&writer);
    try std.testing.expectEqual(@as(usize, 38), writer.end);
    for (0..4) |index| try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buffer[index * 9 + 1 ..][0..8], .big));
    try std.testing.expectEqual([2]u32{ 7, 0 }, receipts.retained(0, receipts.capture(data)));
}

test "retained lighting matches a client model through rejected updates reveals and unloads" {
    var view: chunks.Light.View = .{ .header = .{ .rules = @splat(1), .minimum = 0, .count = 1, .skylight = true, .coverage = 1, .revisions = @splat(0), .biomes = @splat(0) } };
    var receipt_storage: [1]Receipt = @splat(.{});
    var receipts: Receipts = .{ .entries = &receipt_storage, .rules = @splat(1) };
    var client: [2][3]?u8 = @splat(@splat(null));
    var buffer: [Data.capacity]u8 = undefined;
    for (0..512) |step| {
        if (step % 31 == 0) {
            receipts.reset(0, 1);
            client = @splat(@splat(null));
        }
        view.header.revisions[step % 9] = step + 1;
        var data: Data = .{ .source = .{ .stored = &view }, .count = 3, .masks = .{ 0, 0 }, .disclosure = @intCast(step % 2), .selection = @intCast(step % 8) };
        for (0..2) |layer| for (0..3) |section| {
            const level: u4 = @intCast((step / (layer + section + 1) * 7) % 16);
            view.layers[layer][section] = .uniform(level);
            if (level != 0) data.masks[layer] |= @as(u32, 1) << @intCast(section);
        };
        const first = receipts.capture(data);
        const accepted = step % 3 != 0;
        for (0..2) |pass| {
            data.retained = receipts.retained(0, receipts.capture(data));
            var writer: std.Io.Writer = .fixed(&buffer);
            try data.write(&writer);
            try std.testing.expectEqual(data.encodedSize(), writer.end);
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
                        const expected = if (first.nonzero[layer] & @as(u32, @intCast(bit)) != 0) @as(u8, view.layers[layer][section].level().?) * 17 else 0;
                        try std.testing.expectEqual(@as(?u8, expected), next[layer][section]);
                    } else try std.testing.expectEqual(client[layer][section], next[layer][section]);
                }
            }
            try std.testing.expectEqual(writer.end, reader.seek);
            if (pass == 0 and accepted) {
                receipts.apply(0, receipts.capture(data));
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
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = resources });
    const workspace = try Workspace.init(allocator, try terrain.client(.{ .name = "lighting", .sections = @min(192, terrain.unbudgeted()) }), try game_data.lighting.init(allocator));
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
    const restored = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = resources });
    const reloaded = try Workspace.init(allocator, try restored.client(.{ .name = "lighting", .sections = @min(192, restored.unbudgeted()) }), try game_data.lighting.init(allocator));
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
    const asynchronous = try chunks.Chunks.init(bounded, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("asynchronous"), .record_workspaces = resources });
    const pending = try Workspace.init(bounded, try asynchronous.client(.{ .name = "lighting", .sections = @min(192, asynchronous.unbudgeted()) }), try game_data.lighting.init(bounded));
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
    configuration: Lighting.Configuration = .{ .store = .forPlayers(1), .chunk_sections = 6 },
    metrics_enabled: bool = false,
    path: [256]u8 = undefined,
    delivery_bytes: []u8 = undefined,

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
        self.registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = self.metrics_enabled });
        errdefer self.registry.deinit();
        self.store = try storage.Store.init(std.testing.allocator, io, .{ .path = try std.fmt.bufPrint(&self.path, ".zig-cache/tmp/{s}/concurrent-lighting", .{self.directory.sub_path}) });
        errdefer self.store.deinit();
        // The cache holds the budgets and nothing more, so every read past them evicts.
        const store_sections: usize = if (self.configuration.store != null) light_store.sections_max - 2 else 0;
        self.terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = store_sections, .cache_sections = 1 + self.configuration.chunk_sections + store_sections, .cache_groups = 2 }, .{
            .metrics = &self.registry,
            .storage = try self.store.openSpace("chunks"),
            .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
        });
        self.dimensions = try worlds.Worlds.allocate(allocator, .{ .maximum = 2 });
        for ([_][]const u8{ "test:sky", "test:dark" }, 0..) |name, index| {
            const world = try self.dimensions.create(.{ .name = name, .dimension = .{ .name = name, .minimum_section = 0, .section_count = sections, .skylight = index == 0 } });
            assert(world == index);
        }
        self.service = try Lighting.init(allocator, self.configuration, .{ .metrics = &self.registry, .blocks = try test_blocks.vanilla(allocator), .chunks = self.terrain, .worlds = self.dimensions });
        self.delivery_bytes = try allocator.alloc(u8, 2 * chunks.Light.maximum_read_bytes);
        self.terrain.setSource(chunks.Source.init(&self.source, Source.read));
        self.generation = try Generation.init(allocator, io, self.terrain.generation, 1);
        self.bounded.fail_index = self.bounded.alloc_index;
        try self.generation.start();
    }

    fn prepareDeliveries(self: *ConcurrentLighting, deliveries: []const Lighting.Delivery) !void {
        assert(deliveries.len <= 2);
        var keys: [2][chunks.Delivery.key_bytes]u8 = undefined;
        var values: [2]?[]const u8 = undefined;
        var complete: [2]bool = undefined;
        for (deliveries, keys[0..deliveries.len]) |delivery, *key| key.* = chunks.Delivery.key(.{ .world = delivery.world, .x = delivery.x, .z = delivery.z });
        var output: records.PackedRead = .{ .bytes = self.delivery_bytes, .values = values[0..deliveries.len], .complete = complete[0..deliveries.len] };
        var batch: chunks.Delivery.ReadBatch = .{ .keys = keys[0..deliveries.len], .output = &output };
        try self.service.prepareDeliveries(deliveries, &batch);
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
    const Mode = enum { prepare, snapshot, settle, selected, bake, delivery, batch_delivery, batch_prepare };
    const Command = struct { mode: Mode, reverse: bool = false, world: u32 = 0, x: i32 = 0, selection: u32 = std.math.maxInt(u32), additional: ?u32 = null };

    fixture: *ConcurrentLighting,
    thread: ?std.Thread = null,
    ready: std.Io.Event = .unset,
    request: std.Io.Event = .unset,
    entered: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
    command: Command = undefined,
    result: anyerror!void = {},
    baked_delivery: bool = false,
    states: [maximum_sections]u16 = @splat(0),

    fn deliveredState(self: *LightingWorker, terrain: chunk_encoding.Sections, section: usize) !u16 {
        const cell = 8 * 256 + 8 * 16 + 8;
        if (terrain == .loaded) return terrain.loaded[section].view.get(cell);
        const baked = terrain.baked;
        if (baked.view.header.uniform & (@as(u32, 1) << @intCast(section)) != 0) return baked.view.header.states[section];
        var words: [8192]u8 = undefined;
        var states: [4096]u16 = undefined;
        try baked.view.terrain[section].?.view().materialize(&self.fixture.service.stored_workspace.fragment_decoder, &words, &states);
        return states[cell];
    }

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
            .batch_delivery, .batch_prepare => {
                var deliveries: [2]Lighting.Delivery = undefined;
                for (&deliveries, 0..) |*delivery, index| delivery.* = .{ .world = command.world, .x = command.x + @as(i32, @intCast(if (command.reverse) 1 - index else index)), .z = 0, .dimension = dimension, .selection = command.selection };
                try fixture.prepareDeliveries(&deliveries);
                if (command.mode == .batch_prepare) return;
                for (deliveries, 0..) |delivery, index| {
                    try std.testing.expectEqual(.ready, try fixture.service.prepareDelivery(delivery.world, delivery.x, delivery.z, dimension, .{}));
                    try std.testing.expect(fixture.service.validateDelivery());
                    if (command.additional != null) try std.testing.expect(fixture.service.validateDelivery());
                    const terrain = fixture.service.deliveryTerrain(command.selection | (command.additional orelse 0));
                    self.baked_delivery = terrain == .baked;
                    self.states[index] = try self.deliveredState(terrain, 0);
                    if (command.additional != null) self.states[index + 2] = try self.deliveredState(terrain, 1);
                    try fixture.service.lightDelivery(command.selection);
                }
            },
            .prepare => _ = try fixture.service.prepare(command.world, command.x, 0, dimension, 0),
            .bake => if (!try fixture.service.persistBackground()) return error.LightDependenciesDirty,
            .snapshot, .settle, .selected, .delivery => {
                for (0..128) |_| {
                    fixture.terrain.ready().reset();
                    const complete = switch (command.mode) {
                        .snapshot => try fixture.service.background.prepare(fixture.terrain, command.world, command.x, 0, dimension, 0),
                        .selected => try fixture.service.background.prepareInputs(fixture.terrain, command.world, command.x, 0, dimension, 0),
                        .delivery => (try fixture.service.prepareDelivery(command.world, command.x, 0, dimension, .{})) == .ready and fixture.service.validateDelivery(),
                        else => try fixture.service.prepare(command.world, command.x, 0, dimension, 0),
                    };
                    if (complete) {
                        if (command.mode == .selected) try fixture.service.lightPrepared(command.selection);
                        if (command.mode == .delivery) {
                            if (command.additional != null) {
                                if (!fixture.service.validateDelivery()) continue;
                            }
                            const selection = command.selection | (command.additional orelse 0);
                            const terrain = fixture.service.deliveryTerrain(selection);
                            self.baked_delivery = terrain == .baked;
                            for (0..dimension.sectionCount()) |index| {
                                if (selection & (@as(u32, 1) << @intCast(index)) != 0) self.states[index] = try self.deliveredState(terrain, index);
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
    const actual = try std.testing.allocator.alloc(u8, workspace.engine.dimensions.volume() / 2);
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
    try fixture.prepareDeliveries(&deliveries);
    try worker.begin(.{ .mode = .delivery });
    try worker.finish();
    try std.testing.expect(fixture.service.delivery_prepared);
    try std.testing.expectEqual(solves, fixture.service.background.work.relights);
    var after: std.Io.Writer = .fixed(actual);
    try fixture.service.deliveryData().write(&after);
    try std.testing.expectEqualSlices(u8, before.buffered(), after.buffered());
    try fixture.prepareDeliveries(&deliveries);
    try fixture.terrain.setBlock(0, position, 0);
    var dirty: [1]chunks.Light.Dependencies = undefined;
    try fixture.terrain.lightDependencies(&.{.{ .column = .{ .world = 0, .x = 0, .z = 0 }, .minimum = 0, .count = 1 }}, &dirty);
    try std.testing.expect(!dirty[0].clean);
    try worker.begin(.{ .mode = .delivery });
    try worker.finish();
    try std.testing.expect(!fixture.service.delivery_prepared);
    try std.testing.expectEqual(@as(u8, 0), fixture.service.background.engine.get(.block, stateIndex(4, 0, 8 * 256 + 8 * 16)));
    try worker.begin(.{ .mode = .bake });
    try std.testing.expectError(error.LightDependenciesDirty, worker.finish());
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    try worker.begin(.{ .mode = .delivery });
    try worker.finish();
    try std.testing.expect(fixture.service.delivery_prepared);
    try worker.begin(.{ .mode = .delivery });
    try worker.finish();
    try std.testing.expect(fixture.service.delivery_prepared);
    const data = fixture.service.deliveryData();
    var plane: [2048]u8 = undefined;
    try data.source.stored.layer(0, 1).write(&plane);
    try std.testing.expect(std.mem.allEqual(u8, &plane, 0));
    try std.testing.expect(!fixture.bounded.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "delivery batches borrow common frames and reject overlapping edits" {
    var fixture: ConcurrentLighting = .{ .metrics_enabled = true };
    try fixture.initHeight(3);
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const stone: u16 = game_data.registry.block_stone_default_state;
    const dirt: u16 = game_data.registry.block_dirt_default_state;
    for (0..2) |column| for (0..2) |section| try fixture.terrain.setBlock(0, .{ .x = @as(i32, @intCast(column)) * 16 + 8, .y = @as(i32, @intCast(section)) * 16 + 8, .z = 8 }, if (column == 0) stone else dirt);
    for (0..2) |column| {
        try worker.begin(.{ .mode = .snapshot, .x = @intCast(column) });
        try worker.finish();
    }
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    for (0..2) |column| {
        try worker.begin(.{ .mode = .snapshot, .x = @intCast(column) });
        try worker.finish();
        try worker.begin(.{ .mode = .bake });
        try worker.finish();
    }
    try worker.begin(.{ .mode = .batch_delivery, .selection = 1 });
    try worker.finish();
    try std.testing.expectEqualSlices(u16, &.{ stone, dirt }, worker.states[0..2]);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.cache.backend.store.readers);
    var expected_decodes: u64 = 2;
    try std.testing.expectEqual(expected_decodes, fixture.service.stored_decodes.value());
    const repeat_batches = 16;
    for (0..repeat_batches) |turn| {
        try worker.begin(.{ .mode = .batch_delivery, .selection = 1, .reverse = turn % 2 != 0 });
        try worker.finish();
        const expected = if (turn % 2 != 0) [2]u16{ dirt, stone } else [2]u16{ stone, dirt };
        try std.testing.expectEqualSlices(u16, &expected, worker.states[0..2]);
    }
    expected_decodes += 2 * repeat_batches;
    try std.testing.expectEqual(expected_decodes, fixture.service.stored_decodes.value());
    try worker.begin(.{ .mode = .batch_delivery, .selection = 1, .additional = 2 });
    try worker.finish();
    try std.testing.expectEqualSlices(u16, &.{ stone, dirt, stone, dirt }, worker.states[0..4]);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.cache.backend.store.readers);
    expected_decodes += 2;
    try std.testing.expectEqual(expected_decodes, fixture.service.stored_decodes.value());
    try fixture.terrain.setBlock(0, .{ .x = -1, .y = 8, .z = 8 }, stone);
    try worker.begin(.{ .mode = .batch_prepare, .selection = 1 });
    try worker.finish();
    try std.testing.expect(fixture.service.prepared[0].view == null);
    try std.testing.expect(fixture.service.prepared[1].view != null);
    expected_decodes += 1;
    try std.testing.expectEqual(expected_decodes, fixture.service.stored_decodes.value());
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    try worker.begin(.{ .mode = .bake });
    try worker.finish();
    try worker.begin(.{ .mode = .batch_delivery, .selection = 1 });
    try worker.finish();
    expected_decodes += 2;
    try std.testing.expectEqual(expected_decodes, fixture.service.stored_decodes.value());
    try std.testing.expect(!fixture.bounded.has_induced_failure);
}

test "stored delivery selects prepared sections without borrowing voxel groups" {
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
    try std.testing.expect(fixture.service.delivery_prepared);
    try std.testing.expect(worker.baked_delivery);
    try worker.begin(.{ .mode = .delivery, .selection = 1 });
    try worker.finish();
    try std.testing.expectEqual(stone, worker.states[0]);
    try std.testing.expect(worker.baked_delivery);
    try worker.begin(.{ .mode = .delivery, .selection = 1, .additional = 2 });
    try worker.finish();
    try std.testing.expect(!fixture.bounded.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "hull replacement hides an enclosed ore in loaded and stored terrain until it is exposed" {
    var fixture: ConcurrentLighting = .{};
    try fixture.initHeight(1);
    defer fixture.deinit();
    try fixture.service.includeHull(fixture.arena.allocator());
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const ore: u16 = @intCast(game_data.registry.blockStateId("minecraft:coal_ore").?);
    const air: u16 = 0;
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 8, .z = 8 }, ore);
    for ([_][3]i32{ .{ 7, 8, 8 }, .{ 9, 8, 8 }, .{ 8, 7, 8 }, .{ 8, 9, 8 }, .{ 8, 8, 7 }, .{ 8, 8, 9 } }) |at| try fixture.terrain.setBlock(0, .{ .x = at[0], .y = at[1], .z = at[2] }, stone);
    try worker.begin(.{ .mode = .delivery, .selection = 1 });
    try worker.finish();
    try std.testing.expect(!worker.baked_delivery);
    try std.testing.expectEqual(stone, worker.states[0]);
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    try worker.begin(.{ .mode = .bake });
    try worker.finish();
    try worker.begin(.{ .mode = .delivery, .selection = 1 });
    try worker.finish();
    try std.testing.expect(worker.baked_delivery);
    try std.testing.expectEqual(stone, worker.states[0]);
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 8, .z = 8 }, air);
    try worker.begin(.{ .mode = .delivery, .selection = 1 });
    try worker.finish();
    try std.testing.expectEqual(ore, worker.states[0]);
    try std.testing.expect(!fixture.bounded.has_induced_failure);
}

test "stored delivery exceeds decoded cache capacity without expanding sections" {
    var fixture: ConcurrentLighting = .{};
    try fixture.initHeight(8);
    defer fixture.deinit();
    var worker: LightingWorker = .{ .fixture = &fixture };
    try worker.start();
    defer worker.stop();
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const count = fixture.service.background.client.budget() + 1;
    try std.testing.expect(count <= 8);
    for (0..count) |index| try fixture.terrain.setBlock(0, .{ .x = 8, .y = @intCast(index * 16 + 8), .z = 8 }, stone);
    try worker.begin(.{ .mode = .snapshot });
    try worker.finish();
    try fixture.terrain.checkpoint(try fixture.store.openSpace(chunks.Chunks.id));
    try worker.begin(.{ .mode = .bake });
    try worker.finish();
    try worker.begin(.{ .mode = .delivery, .selection = (@as(u32, 1) << @intCast(count)) - 1 });
    try worker.finish();
    try std.testing.expect(fixture.service.delivery_prepared);
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
            .stored => |view| try view.layer(0, 1).write(&plane),
            .computed => |engine| engine.packSection(.block, .{ 1, 1, 1 }, &plane),
            .patched => unreachable,
        }
        const local = 8 * 256 + 8 * 16;
        try std.testing.expectEqual(@as(u8, if (lit) 14 else 0), plane[local / 2] & 15);
        try worker.begin(.{ .mode = .bake });
        try worker.finish();
    }
    try std.testing.expect(!fixture.bounded.has_induced_failure);
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
    const reader = try terrain.client(.{ .name = "test", .sections = maximum_sections });
    for (0..9) |column| {
        var sections: [maximum_sections]chunks.Section = undefined;
        var leases: [maximum_sections]chunks.Lease = undefined;
        for (&sections, 0..) |*section, index| section.* = .{ .world = 0, .x = @as(i32, @intCast(column % 3)) - 1, .z = @as(i32, @intCast(column / 3)) - 1, .y = @as(i32, @intCast(index)) - 4 };
        try reader.acquireMany(&sections, &leases);
        terrain.releaseMany(&leases);
    }
    try terrain.checkpoint(space);
    try store.waitDurable(try store.commit(1));
    store.deinit();
    closed = true;
    var reopened = try storage.Store.init(allocator, io, options);
    defer reopened.deinit();
    const restored = try chunks.Chunks.init(allocator, io, .{}, .{ .metrics = &registry, .storage = try reopened.openSpace(chunks.Chunks.id), .record_workspaces = resources });
    const restored_reader = try restored.client(.{ .name = "test", .sections = maximum_sections });
    restored.setSource(chunks.Source.init(&source, Source.read));
    var dirty_sections: [maximum_sections]chunks.Section = undefined;
    var dirty_leases: [maximum_sections]chunks.Lease = undefined;
    for (&dirty_sections, 0..) |*section, index| section.* = .{ .world = 0, .x = 32, .z = 0, .y = @as(i32, @intCast(index)) - 4 };
    try restored_reader.acquireMany(&dirty_sections, &dirty_leases);
    restored.releaseMany(&dirty_leases);
    const workspace = try Workspace.init(allocator, try restored.client(.{ .name = "lighting", .sections = @min(192, restored.unbudgeted()) }), try game_data.lighting.init(allocator));
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

test "biome views borrow unaligned encoded cells with the same values as native cells" {
    var native: [64]u16 = undefined;
    var bytes: [129]u8 = undefined;
    for (&native, 0..) |*value, index| {
        value.* = @intCast(index * 977);
        std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], value.*, .little);
    }
    const encoded: Biomes = .{ .encoded = .{ .bytes = bytes[1..][0..128] } };
    const values: Biomes = .{ .values = &native };
    try std.testing.expect(encoded.encoded.bytes == bytes[1..][0..128]);
    for (0..64) |index| try std.testing.expectEqual(values.get(@intCast(index)), encoded.get(@intCast(index)));
    try std.testing.expect(values.uniform() == null and encoded.uniform() == null);
    @memset(&native, 977);
    for (0..64) |index| std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], 977, .little);
    try std.testing.expectEqual(@as(?u16, 977), values.uniform());
    try std.testing.expectEqual(@as(?u16, 977), encoded.uniform());
}

/// A lighting service with a light store over storage-backed terrain. The fixture plays
/// the terrain thread: it solves the columns the sink asks for and hands them back. A
/// second workspace solves from scratch to say what the light should be.
const StoreFixture = struct {
    const count = 3;
    const Ground = struct {
        stone: u16,

        fn read(self: *Ground, _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(if (request.section.y == 0) self.stone else 0, request.output);
        }
    };
    const Ask = struct { x: i32, z: i32, stamp: u64 };
    const Heard = struct {
        patched: usize = 0,
        sections: usize = 0,
        unlit: usize = 0,
        wanted: usize = 0,
        asks: [512]Ask = undefined,
        ask_count: usize = 0,

        fn onPatched(raw: *anyopaque, _: u32, _: i32, _: i32, sections: [2][9]u32) void {
            const self: *Heard = @ptrCast(@alignCast(raw));
            self.patched += 1;
            for (sections) |layer| for (layer) |mask| {
                self.sections += @popCount(mask);
            };
        }

        fn onUnlit(raw: *anyopaque, _: u32, x: i32, z: i32, stamps: [9]u64) void {
            const self: *Heard = @ptrCast(@alignCast(raw));
            for (stamps, 0..) |stamp, index| {
                if (stamp == 0) continue;
                self.unlit += 1;
                self.note(.{ .x = x + @as(i32, @intCast(index % 3)) - 1, .z = z + @as(i32, @intCast(index / 3)) - 1, .stamp = stamp });
            }
        }

        fn onWanted(raw: *anyopaque, _: u32, x: i32, z: i32, stamp: u64) void {
            const self: *Heard = @ptrCast(@alignCast(raw));
            self.wanted += 1;
            self.note(.{ .x = x, .z = z, .stamp = stamp });
        }

        /// Only the newest request of a column counts, as on the streaming thread.
        fn note(self: *Heard, ask: Ask) void {
            for (self.asks[0..self.ask_count]) |*known| {
                if (known.x != ask.x or known.z != ask.z) continue;
                known.stamp = ask.stamp;
                return;
            }
            self.asks[self.ask_count] = ask;
            self.ask_count += 1;
        }
    };

    directory: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    registry: metrics.Registry,
    database: storage.Store,
    terrain: *chunks.Chunks,
    dimensions: *worlds.Worlds,
    dimension: worlds.Worlds.Dimension,
    service: *Lighting,
    reference: *Workspace,
    ground: Ground,
    heard: Heard = .{},
    commits: u64 = 0,
    path: [256]u8 = undefined,
    truth: [2048]u8 = undefined,
    random: u64 = 0x2545f4914f6cdd1d,

    fn init(self: *StoreFixture, config: light_store.Configuration) !void {
        const io = std.testing.io;
        self.heard = .{};
        self.commits = 0;
        self.random = 0x2545f4914f6cdd1d;
        self.directory = std.testing.tmpDir(.{});
        self.arena = .init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        self.database = try storage.Store.init(std.testing.allocator, io, .{ .path = try std.fmt.bufPrint(&self.path, ".zig-cache/tmp/{s}/light-store", .{self.directory.sub_path}) });
        // Edits, the service solver, the light store reading on the simulation thread, and the
        // reference solver.
        self.terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = light_store.sections_max - 2, .cache_sections = 1 + 48 + (light_store.sections_max - 2) + 48 }, .{ .metrics = &self.registry, .storage = try self.database.openSpace("chunks"), .record_workspaces = try records.Workspaces.init(allocator, io, .{}) });
        self.ground = .{ .stone = @intCast(game_data.registry.blockStateId("minecraft:stone").?) };
        self.terrain.setSource(chunks.Source.init(&self.ground, Ground.read));
        self.dimensions = try worlds.Worlds.allocate(allocator, .{});
        self.dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = count, .skylight = true };
        assert(try self.dimensions.create(.{ .name = "test:stored", .dimension = self.dimension }) == 0);
        const blocks = try test_blocks.vanilla(allocator);
        self.service = try Lighting.init(allocator, .{ .store = config, .chunk_sections = 48 }, .{ .metrics = &self.registry, .blocks = blocks, .chunks = self.terrain, .worlds = self.dimensions });
        self.service.setSink(.{ .context = &self.heard, .patched = Heard.onPatched, .unlit = Heard.onUnlit, .wanted = Heard.onWanted });
        self.reference = try Workspace.init(allocator, try self.terrain.client(.{ .name = "reference", .sections = 48 }), blocks.light);
    }

    /// Reads twice as many far sections as the cache holds, so no block section the test
    /// touched stays in memory.
    fn evictBlocks(self: *StoreFixture) !void {
        const client = self.reference.client;
        var far: [48]chunks.Section = undefined;
        var leases: [48]chunks.Lease = undefined;
        var done: usize = 0;
        while (done < 2 * self.terrain.cache.entries.len) : (done += far.len) {
            for (&far, 0..) |*section, index| section.* = .{ .world = 0, .x = 500 + @as(i32, @intCast(done + index)), .y = 0, .z = 0 };
            try client.acquireMany(&far, &leases);
            self.terrain.releaseMany(&leases);
        }
    }

    fn deinit(self: *StoreFixture) void {
        self.database.deinit();
        self.registry.deinit();
        self.arena.deinit();
        self.directory.cleanup();
    }

    fn next(self: *StoreFixture) u64 {
        self.random ^= self.random << 13;
        self.random ^= self.random >> 7;
        self.random ^= self.random << 17;
        return self.random;
    }

    fn pump(self: *StoreFixture) !void {
        while (try self.terrain.generation.processOne(std.testing.io)) {}
        try self.terrain.poll();
    }

    fn store(self: *StoreFixture) *light_store.LightStore {
        return self.service.store.?;
    }

    /// Ends a tick as the simulation does, then does the disk work it handed over as the
    /// terrain thread does between ticks, and checks the bookkeeping of the store.
    fn tick(self: *StoreFixture) void {
        self.service.finishTick();
        self.store().check();
        while (self.service.pollStore() catch unreachable) {}
    }

    /// Ticks until every edit is settled and nothing is waited for, answering solves
    /// the sink asked for as the terrain thread would.
    fn settleAll(self: *StoreFixture) !void {
        for (0..64) |_| {
            self.tick();
            _ = try self.answer();
            if (self.service.storeIdle() and self.heard.ask_count == 0) {
                // What was solved last is taken in by one more tick.
                self.tick();
                if (self.service.storeIdle()) return;
            }
        }
        return error.LightDidNotSettle;
    }

    /// Saves every edit made so far, as an autosave does.
    fn checkpoint(self: *StoreFixture) !void {
        try self.terrain.checkpoint(try self.database.openSpace("chunks"));
        self.commits += 1;
        try self.database.waitDurable(try self.database.commit(self.commits));
    }

    /// Solves a column in full on the terrain side.
    fn solve(self: *StoreFixture, x: i32, z: i32) !void {
        for (0..256) |_| {
            if (try self.service.prepare(0, x, z, self.dimension, 0)) return;
            try self.pump();
        }
        return error.LightingDidNotSettle;
    }

    /// Plays the terrain thread: solves the columns the sink asked for and offers them,
    /// as far as the hand-off has room. The rest wait for the next call. Answers how
    /// many were handed over.
    fn answer(self: *StoreFixture) !usize {
        var taken: usize = 0;
        while (taken < self.heard.ask_count and (self.service.resultRoom(1) != 0)) : (taken += 1) {
            const ask = self.heard.asks[taken];
            try self.solve(ask.x, ask.z);
            try std.testing.expect(self.service.offer(ask.stamp));
        }
        std.mem.copyForwards(Ask, self.heard.asks[0 .. self.heard.ask_count - taken], self.heard.asks[taken..self.heard.ask_count]);
        self.heard.ask_count -= taken;
        return taken;
    }

    /// Bakes the frame of a column, as a delivery does. False while its blocks are not saved.
    fn bake(self: *StoreFixture, x: i32, z: i32) !bool {
        for (0..256) |_| {
            if (try self.service.background.prepare(self.terrain, 0, x, z, self.dimension, 0)) break;
            try self.pump();
        } else return error.LightingDidNotSettle;
        return self.service.persistBackground();
    }

    /// Generates, saves and bakes every column within `radius` of the origin.
    fn prewarm(self: *StoreFixture, radius: i32) !void {
        for (0..2) |pass| {
            var z: i32 = -radius;
            while (z <= radius) : (z += 1) {
                var x: i32 = -radius;
                while (x <= radius) : (x += 1) {
                    const baked = try self.bake(x, z);
                    if (pass == 1) try std.testing.expect(baked);
                }
            }
            if (pass == 0) try self.checkpoint();
        }
    }

    fn key(x: i32, z: i32) light_store.Key {
        return .{ .world = 0, .x = x, .z = z };
    }

    fn shape(self: *const StoreFixture) light_store.Shape {
        return .{ .minimum = 0, .count = count, .skylight = self.dimension.skylight };
    }

    fn solveReference(self: *StoreFixture, x: i32, z: i32) !void {
        for (0..256) |_| {
            if (try self.reference.prepare(self.terrain, 0, x, z, self.dimension, 0)) return;
            try self.pump();
        }
        return error.LightingDidNotSettle;
    }

    /// The stored light of a column must equal a solve of the current blocks from scratch.
    fn expectExact(self: *StoreFixture, x: i32, z: i32) !void {
        try self.solveReference(x, z);
        var stored: light_store.Sections = .{};
        try std.testing.expect(self.store().lightOf(key(x, z), self.shape(), &stored));
        inline for (.{ lighting.Layer.block, lighting.Layer.sky }, 0..) |layer, index| for (0..count + 2) |section| {
            self.reference.engine.packSection(layer, .{ 1, section, 1 }, &self.truth);
            var uniform: [2048]u8 = undefined;
            const actual: *const [2048]u8 = switch (stored.light[index][section]) {
                .dense => |levels| levels,
                .uniform => |level| filled: {
                    @memset(&uniform, @as(u8, level) * 17);
                    break :filled &uniform;
                },
            };
            if (std.mem.eql(u8, &self.truth, actual)) continue;
            std.debug.print("stored light differs column={d},{d} layer={d} section={d}\n", .{ x, z, index, section });
            return error.TestUnexpectedResult;
        };
    }

    /// Every column in memory must be exact. Answers how many there were.
    fn expectAllExact(self: *StoreFixture) !usize {
        var seen: usize = 0;
        for (0..self.store().columns.len) |slot| {
            const at = self.store().residentAt(slot) orelse continue;
            try self.expectExact(at.x, at.z);
            seen += 1;
        }
        return seen;
    }

    fn expectSquareExact(self: *StoreFixture, x: i32, z: i32, radius: i32) !void {
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) try self.expectExact(x + dx, z + dz);
        }
    }
};

test "an edit with no stored light around it is solved and the next one is patched in place" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const service = fixture.service;
    const store = fixture.store();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);

    // Nothing was baked. The light of the nine columns is asked of disk, which has none,
    // so the edit cannot be patched. Its light is dropped and solved by the terrain side.
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 20, .z = 8 }, glowstone);
    try std.testing.expectEqual(@as(usize, 1), service.unsettled_count);
    try std.testing.expectEqual(@as(usize, 9), store.snapshot().loading);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(usize, 9), fixture.heard.unlit);
    try std.testing.expectEqual(@as(usize, 9), store.snapshot().resident);
    try std.testing.expectEqual(@as(u64, 9), store.snapshot().solves);
    try fixture.expectSquareExact(0, 0, 1);

    // The next edit there finds everything in memory and is patched at the end of its
    // own tick. Whoever edits where everything was in memory is working there, so the
    // sixteen columns just beyond are asked for.
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, stone);
    fixture.tick();
    try std.testing.expectEqual(@as(usize, 1), fixture.heard.patched);
    try std.testing.expect(fixture.heard.sections != 0);
    try fixture.expectSquareExact(0, 0, 1);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(usize, 25), store.snapshot().resident);

    // An edit one column over finds all nine of its columns and darkens nothing. Its
    // patch may wait a tick for block states the terrain side reads into memory.
    try fixture.terrain.setBlock(0, .{ .x = 17, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(usize, 2), fixture.heard.patched);
    try std.testing.expectEqual(@as(usize, 9), fixture.heard.unlit);
    // The twenty five, and the ring beyond the second edit.
    try std.testing.expect(try fixture.expectAllExact() >= 25);

    // A solve that answers an older request is refused: an edit darkened the column
    // again after the request, and the solve may have read the blocks before it.
    try fixture.terrain.setBlock(0, .{ .x = 400, .y = 20, .z = 8 }, glowstone);
    fixture.tick();
    fixture.tick();
    try std.testing.expect(fixture.heard.ask_count != 0);
    const stale = fixture.heard.asks[fixture.heard.ask_count - 1];
    try std.testing.expectEqual(light_store.Presence.unlit, store.presence(StoreFixture.key(stale.x, stale.z), fixture.shape()));
    try fixture.terrain.setBlock(0, .{ .x = 400, .y = 21, .z = 8 }, glowstone);
    try fixture.solve(stale.x, stale.z);
    try std.testing.expect(service.offer(stale.stamp));
    fixture.tick();
    try std.testing.expectEqual(light_store.Presence.unlit, store.presence(StoreFixture.key(stale.x, stale.z), fixture.shape()));
    try fixture.settleAll();
    try fixture.expectSquareExact(25, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "an edit somewhere new is patched from the baked frames of its nine columns one tick later" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const service = fixture.service;
    const store = fixture.store();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    try fixture.prewarm(4);

    // The edit reads nothing. Its tick hands the nine reads to the terrain side, and
    // the next tick takes them in. The patch follows once the blocks around it are in
    // memory too.
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 20, .z = 8 }, glowstone);
    try std.testing.expectEqual(@as(u64, 0), store.snapshot().frames);
    fixture.tick();
    try std.testing.expectEqual(@as(usize, 0), fixture.heard.patched);
    fixture.tick();
    try std.testing.expectEqual(@as(u64, 9), store.snapshot().frames);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(usize, 1), fixture.heard.patched);
    try std.testing.expectEqual(@as(usize, 0), fixture.heard.unlit);
    try std.testing.expectEqual(@as(usize, 0), service.unsettled_count);
    try fixture.expectSquareExact(0, 0, 1);

    // The edit is not saved. A column further out is still read from its frame, which
    // matches the saved blocks: the edit there waits in memory only, and so cannot be
    // in it. The columns the first edit reached are not read again.
    try fixture.terrain.setBlock(0, .{ .x = 24, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(u64, 12), store.snapshot().frames);
    try std.testing.expectEqual(@as(usize, 2), fixture.heard.patched);
    try std.testing.expectEqual(@as(usize, 0), fixture.heard.unlit);
    try std.testing.expectEqual(@as(usize, 12), try fixture.expectAllExact());

    // Once saved, the old frames stop matching and a frame baked from here on holds the
    // edits. An edit beside columns the store has since forgotten reads such a frame.
    try fixture.checkpoint();
    store.clear();
    var z: i32 = -1;
    while (z <= 1) : (z += 1) {
        var x: i32 = -1;
        while (x <= 1) : (x += 1) try std.testing.expect(try fixture.bake(x, z));
    }
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, stone);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(usize, 3), fixture.heard.patched);
    try std.testing.expectEqual(@as(usize, 0), fixture.heard.unlit);
    try std.testing.expectEqual(@as(usize, 9), try fixture.expectAllExact());

    // A store that had to forget everything cannot tell which frames an unsaved edit
    // made stale. It trusts none until a checkpoint has saved the edits, not even
    // frames that still match the saved blocks, as the ones around this edit do.
    store.reset();
    try std.testing.expect(!store.framesTrusted());
    const frames = store.snapshot().frames;
    try fixture.terrain.setBlock(0, .{ .x = -40, .y = 20, .z = -40 }, glowstone);
    try std.testing.expectEqual(@as(usize, 9), fixture.heard.unlit);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().loading);
    try fixture.checkpoint();
    fixture.tick();
    try std.testing.expect(store.framesTrusted());
    try fixture.settleAll();
    try std.testing.expectEqual(frames, store.snapshot().frames);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "a frame read after an edit was saved is not taken for the light before the edit" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const store = fixture.store();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    try fixture.prewarm(2);
    // Between the edit and the read of the frames around it, the edit is saved and the
    // frames are baked again. They match the saved blocks and hold the edit already, so
    // they are not the light a patch of the edit starts from.
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 20, .z = 8 }, glowstone);
    try fixture.checkpoint();
    for (0..9) |index| try std.testing.expect(try fixture.bake(@as(i32, @intCast(index % 3)) - 1, @as(i32, @intCast(index / 3)) - 1));
    try fixture.settleAll();
    try std.testing.expectEqual(@as(u64, 0), store.snapshot().frames);
    try std.testing.expectEqual(@as(u64, 9), store.snapshot().solves);
    try std.testing.expectEqual(@as(usize, 9), fixture.heard.unlit);
    try fixture.expectSquareExact(0, 0, 1);
    // With the edit settled, those same frames are the light of their columns.
    store.clear();
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 20, .z = 8 }, 0);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(u64, 9), store.snapshot().frames);
    try fixture.expectSquareExact(0, 0, 1);
    // A write during the read may save an edit the read was told is unsaved. The frame
    // is not used either.
    store.clear();
    try fixture.terrain.setBlock(0, .{ .x = 10, .y = 20, .z = 8 }, glowstone);
    fixture.service.finishTick();
    try fixture.terrain.checkpoint(try fixture.database.openSpace("chunks"));
    while (try fixture.service.pollStore()) {}
    try fixture.settleAll();
    try fixture.expectSquareExact(0, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "patched light leaves memory as an overflow record and comes back exact" {
    var fixture: StoreFixture = undefined;
    // Room for only a few lit neighbourhoods.
    try fixture.init(.{ .sections = 2 * light_store.Copy.capacity, .columns = 256, .players = 1, .guaranteed = 16 });
    defer fixture.deinit();
    const store = fixture.store();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);

    // Each site is lit by a solve, which no frame vouches for, so its light can only
    // leave memory as a record. There are enough of them to press on the table too.
    const sites = 26;
    for (0..sites) |site| {
        const x: i32 = @intCast(site * 64 + 8);
        try fixture.terrain.setBlock(0, .{ .x = x, .y = 20, .z = 8 }, glowstone);
        try fixture.settleAll();
    }
    var stats = store.snapshot();
    try std.testing.expect(stats.overflows != 0 and stats.overflowed != 0);
    try std.testing.expect(stats.sections <= 2 * light_store.Copy.capacity);
    try std.testing.expectEqual(light_store.Presence.overflowed, store.presence(StoreFixture.key(0, 0), fixture.shape()));

    // An edit at the first site reads its records back and is patched without a solve.
    const unlit = fixture.heard.unlit;
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, stone);
    try fixture.settleAll();
    // Columns whose light is one level throughout hold no pool section and never left.
    try std.testing.expect(store.snapshot().restores >= 4);
    try std.testing.expectEqual(unlit, fixture.heard.unlit);
    try std.testing.expectEqual(@as(usize, 1), fixture.heard.patched);
    try fixture.expectSquareExact(0, 0, 1);

    // A column that came back and was not changed leaves again without a second write.
    // One the patch changed is written again.
    const overflows = store.snapshot().overflows;
    for (0..sites) |site| {
        const x: i32 = @intCast(site * 64 + 8);
        try fixture.terrain.setBlock(0, .{ .x = x, .y = 22, .z = 8 }, glowstone);
        try fixture.settleAll();
    }
    try std.testing.expect(store.snapshot().overflows > overflows);
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, 0);
    try fixture.settleAll();
    try fixture.expectSquareExact(0, 0, 1);

    // Once a checkpoint has saved the edits, a column the table needs room for is
    // forgotten and its record deleted. Until then it stays however short the table
    // is, so that no stale frame can be mistaken for its light.
    try std.testing.expect(store.vacant_count < store.reserve_columns);
    for (0..sites) |site| for (0..9) |index| {
        const at = StoreFixture.key(@as(i32, @intCast(site * 4 + index % 3)) - 1, @as(i32, @intCast(index / 3)) - 1);
        try std.testing.expect(store.presence(at, fixture.shape()) != .absent);
    };
    // An autosave lets the table make room before the next edits need it.
    try fixture.checkpoint();
    fixture.tick();
    try std.testing.expect(store.vacant_count >= store.reserve_columns);
    for (0..40) |site| {
        if (site % 2 == 0) try fixture.checkpoint();
        const x: i32 = @intCast(-(@as(i32, @intCast(site)) * 64) - 56);
        try fixture.terrain.setBlock(0, .{ .x = x, .y = 20, .z = 8 }, glowstone);
        try fixture.settleAll();
    }
    stats = store.snapshot();
    try std.testing.expect(stats.forgotten != 0);
    try std.testing.expectEqual(@as(u64, 0), stats.resets);
    _ = try fixture.expectAllExact();
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "edits after the light rules change are patched by the new rules" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const service = fixture.service;
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    try fixture.prewarm(3);
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    // Content dims glowstone while the server runs, as a datapack may.
    var rules = service.deps.blocks.light;
    const states = try fixture.arena.allocator().dupe(lighting.Properties, rules.states);
    states[glowstone].emission = 7;
    rules.states = states;
    service.deps.blocks.changeLight(rules);
    // The reference solve follows the new rules too.
    fixture.reference.forget(rules);
    try fixture.prewarm(3);
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    try std.testing.expect(try fixture.expectAllExact() >= 9);
    var samples: [1]?Sample = undefined;
    try service.sampleMany(0, &.{.{ .x = 9, .y = 20, .z = 8 }}, &samples);
    try std.testing.expectEqual(@as(u4, 7), samples[0].?.block);
}

test "edits to neighbouring columns in one tick are each settled against blocks without the other" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    try fixture.prewarm(3);
    // Two sources either side of a border, and a wall between them, in one tick. The
    // light each patch starts from knows none of them.
    try fixture.terrain.setBlock(0, .{ .x = 15, .y = 20, .z = 8 }, glowstone);
    try fixture.terrain.setBlock(0, .{ .x = 17, .y = 20, .z = 8 }, glowstone);
    try fixture.terrain.setBlock(0, .{ .x = 16, .y = 20, .z = 8 }, stone);
    try std.testing.expectEqual(@as(usize, 3), fixture.service.unsettled_count);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(usize, 2), fixture.heard.patched);
    // The twelve columns of the two patches, and what was asked for around them.
    try std.testing.expect(try fixture.expectAllExact() >= 12);
    // The same cells again, written twice within the tick, and this time patched at
    // the end of the same tick.
    try fixture.terrain.setBlock(0, .{ .x = 15, .y = 20, .z = 8 }, stone);
    try fixture.terrain.setBlock(0, .{ .x = 15, .y = 20, .z = 8 }, 0);
    try fixture.terrain.setBlock(0, .{ .x = 16, .y = 20, .z = 8 }, 0);
    try fixture.terrain.setBlock(0, .{ .x = 17, .y = 20, .z = 8 }, 0);
    try fixture.terrain.setBlock(0, .{ .x = 17, .y = 20, .z = 8 }, glowstone);
    fixture.tick();
    try std.testing.expectEqual(@as(usize, 0), fixture.service.unsettled_count);
    try std.testing.expect(try fixture.expectAllExact() >= 12);
    try std.testing.expectEqual(@as(usize, 0), fixture.heard.unlit);
}

test "a tick patches its share of edits and the rest follow in later ticks" {
    var fixture: StoreFixture = undefined;
    var config: light_store.Configuration = .forPlayers(1);
    config.patch_steps = 1;
    try fixture.init(config);
    defer fixture.deinit();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    try fixture.prewarm(3);
    const places = [_]i32{ -24, 8, 40 };
    // A first round brings the blocks the patches read into memory.
    for (places) |x| try fixture.terrain.setBlock(0, .{ .x = x, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    // Three columns far enough apart to be patched alone, each over the share of a tick.
    for (places) |x| try fixture.terrain.setBlock(0, .{ .x = x, .y = 20, .z = 8 }, 0);
    for (0..places.len) |tick| {
        const before = fixture.heard.patched;
        fixture.tick();
        try std.testing.expectEqual(before + 1, fixture.heard.patched);
        try std.testing.expectEqual(places.len - 1 - tick, fixture.service.unsettled_count);
    }
    try std.testing.expect(try fixture.expectAllExact() >= 27);
    try std.testing.expectEqual(@as(usize, 0), fixture.heard.unlit);
}

test "edits past what the queue holds have their light dropped and solved again exact" {
    var fixture: StoreFixture = undefined;
    var config: light_store.Configuration = .forPlayers(1);
    config.edits = 4;
    try fixture.init(config);
    defer fixture.deinit();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    try fixture.prewarm(3);
    // Ten sources over three columns in one tick. The four in the first column fill
    // the queue and the rest cannot wait.
    for (0..10) |index| try fixture.terrain.setBlock(0, .{ .x = @as(i32, @intCast(index)) * 4 + 2, .y = 20, .z = 8 }, glowstone);
    try std.testing.expectEqual(@as(usize, 4), fixture.service.unsettled_count);
    try std.testing.expect(fixture.heard.unlit != 0);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(usize, 0), fixture.service.unsettled_count);
    try std.testing.expect(try fixture.expectAllExact() >= 9);
}

test "light samples answer from memory and ask for what is missing without reading anything" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const service = fixture.service;
    const store = fixture.store();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    try fixture.prewarm(3);
    const near: chunks.Position = .{ .x = 8, .y = 20, .z = 8 };
    var samples: [3]?Sample = undefined;

    // A column that is not in memory answers nothing. Nothing is read or solved for
    // the answer. Its frame is read by the terrain side and taken in a tick later.
    try service.sampleMany(0, &.{near}, samples[0..1]);
    try std.testing.expectEqual(@as(?Sample, null), samples[0]);
    fixture.tick();
    try std.testing.expectEqual(@as(u64, 0), store.snapshot().frames);
    fixture.tick();
    try std.testing.expectEqual(@as(u64, 1), store.snapshot().frames);
    try service.sampleMany(0, &.{near}, samples[0..1]);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[0].?);

    // With the nine columns in memory, an edit is in the answer within its own tick,
    // and input order is kept.
    var around: [9]chunks.Position = undefined;
    for (&around, 0..) |*position, index| position.* = .{ .x = @as(i32, @intCast(index % 3)) * 16 - 8, .y = 20, .z = @as(i32, @intCast(index / 3)) * 16 - 8 };
    var nine: [9]?Sample = undefined;
    try service.sampleMany(0, &around, &nine);
    try fixture.settleAll();
    // A first edit brings the blocks the patch reads into memory as well.
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, 0);
    try service.sampleMany(0, &.{near}, samples[0..1]);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[0].?);
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, glowstone);
    try service.sampleMany(0, &.{ .{ .x = 10, .y = 20, .z = 8 }, near, .{ .x = 9, .y = 20, .z = 8 } }, &samples);
    try std.testing.expectEqual(Sample{ .block = 14, .sky = 15 }, samples[0].?);
    try std.testing.expectEqual(Sample{ .block = 14, .sky = 15 }, samples[1].?);
    try std.testing.expectEqual(Sample{ .block = 15, .sky = 0 }, samples[2].?);
    try std.testing.expectEqual(@as(usize, 0), service.unsettled_count);

    // Where the light is not in memory, an edit waits for it to be read. Until then the
    // answer is the light from before the edit, as light lags in vanilla.
    try fixture.terrain.setBlock(0, .{ .x = 41, .y = 20, .z = 8 }, glowstone);
    try service.sampleMany(0, &.{.{ .x = 40, .y = 20, .z = 8 }}, samples[0..1]);
    try std.testing.expect(samples[0] == null or samples[0].?.block == 0);
    try fixture.settleAll();
    try service.sampleMany(0, &.{.{ .x = 40, .y = 20, .z = 8 }}, samples[0..1]);
    try std.testing.expectEqual(Sample{ .block = 14, .sky = 15 }, samples[0].?);

    // Where nothing was baked, the terrain side is asked for a solve.
    const far: chunks.Position = .{ .x = 808, .y = 20, .z = 8 };
    try service.sampleMany(0, &.{far}, samples[0..1]);
    try std.testing.expectEqual(@as(?Sample, null), samples[0]);
    try fixture.settleAll();
    try std.testing.expect(fixture.heard.wanted != 0);
    try service.sampleMany(0, &.{far}, samples[0..1]);
    try std.testing.expectEqual(Sample{ .block = 0, .sky = 15 }, samples[0].?);
    try std.testing.expectEqual(@as(u64, 0), store.snapshot().failures);

    var many: [Lighting.batch_max + 3]chunks.Position = @splat(near);
    many[1] = far;
    var results: [many.len]?Sample = undefined;
    try service.sampleMany(0, &many, &results);
    for (results, 0..) |sample, index| try std.testing.expectEqual(Sample{ .block = if (index == 1) 0 else 14, .sky = 15 }, sample.?);
    try service.sampleMany(0, &.{}, &.{});
    try std.testing.expectError(error.UnknownWorld, service.sampleMany(std.math.maxInt(u32), &.{near}, samples[0..1]));
    try std.testing.expectError(error.InvalidLightingPosition, service.sampleMany(0, &.{.{ .x = 0, .y = 48, .z = 0 }}, samples[0..1]));
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "stored light stays exact through random edits checkpoints bakes and evictions" {
    var fixture: StoreFixture = undefined;
    // Too little room for the area, so light keeps moving between memory and disk.
    try fixture.init(.{ .sections = 2 * light_store.Copy.capacity + 24, .columns = 96, .players = 2, .guaranteed = 16 });
    defer fixture.deinit();
    const service = fixture.service;
    const store = fixture.store();
    const states = [_]u16{
        @intCast(game_data.registry.blockStateId("minecraft:glowstone").?),
        @intCast(game_data.registry.blockStateId("minecraft:glowstone").?),
        @intCast(game_data.registry.blockStateId("minecraft:stone").?),
        @intCast(game_data.registry.blockStateId("minecraft:glass").?),
        0,
        0,
    };
    try fixture.prewarm(4);
    var compared: usize = 0;
    var sampled: usize = 0;
    for (0..360) |round| {
        const action = fixture.next() % 16;
        // Edits cluster in a few columns, so that they meet at borders and repeat cells.
        const edits = 1 + fixture.next() % 5;
        const spread: i32 = if (fixture.next() % 4 == 0) 112 else 40;
        for (0..edits) |_| {
            const value = fixture.next();
            const position: chunks.Position = .{
                .x = @as(i32, @intCast(value % @as(u64, @intCast(spread)))) - @divTrunc(spread, 2) + 8,
                .y = 12 + @as(i32, @intCast((value >> 16) % 30)),
                .z = @as(i32, @intCast((value >> 24) % @as(u64, @intCast(spread)))) - @divTrunc(spread, 2) + 8,
            };
            try fixture.terrain.setBlock(0, position, states[(value >> 40) % states.len]);
            // Gameplay looks at light in the middle of a tick now and then. With no edit
            // waiting the answer is exact.
            if ((value >> 48) % 8 == 0) {
                var seen: [1]?Sample = undefined;
                try service.sampleMany(0, &.{position}, &seen);
                if (seen[0]) |sample| if (service.unsettled_count == 0) {
                    try fixture.solveReference(@divFloor(position.x, 16), @divFloor(position.z, 16));
                    const state = stateIndex(4, @intCast(@divFloor(position.y, 16)), @intCast(@mod(position.y, 16) * 256 + @mod(position.z, 16) * 16 + @mod(position.x, 16)));
                    try std.testing.expectEqual(Sample{ .block = fixture.reference.engine.get(.block, state), .sky = fixture.reference.engine.get(.sky, state) }, sample);
                    sampled += 1;
                };
            }
        }
        // The simulation saves after the work of a tick and before its light settles.
        if (action == 0) try fixture.checkpoint();
        service.beginProtection();
        service.protect(0, 0, 0);
        // The terrain side is sometimes a tick late with the disk work.
        if (action % 5 == 2) {
            service.finishTick();
            store.check();
        } else fixture.tick();
        // It is sometimes late with solves too, so that some answer old requests.
        if (action % 3 != 1) _ = try fixture.answer();
        if (action == 1) try fixture.checkpoint();
        // A delivery bakes a frame wherever the blocks around a column are saved.
        if (action >= 12) _ = try fixture.bake(@as(i32, @intCast(fixture.next() % 9)) - 4, @as(i32, @intCast(fixture.next() % 9)) - 4);
        if (round % 6 == 5) {
            try fixture.settleAll();
            compared += try fixture.expectAllExact();
        }
    }
    try fixture.settleAll();
    compared += try fixture.expectAllExact();
    const stats = store.snapshot();
    // Every way light gets in and out of memory was taken.
    try std.testing.expect(compared > 1000 and sampled != 0);
    try std.testing.expect(stats.patches != 0 and stats.frames != 0 and stats.restores != 0 and stats.solves != 0);
    try std.testing.expect(stats.darkened != 0 and stats.overflows != 0 and stats.forgotten != 0);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "a patch waits a tick for block states that are not in memory and reads nothing itself" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const store = fixture.store();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    try fixture.prewarm(3);
    // The light of the nine columns is in memory and their blocks are not.
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    try fixture.checkpoint();
    for (0..fixture.terrain.cache.entries.len) |_| {
        _ = try fixture.reference.client.getBlock(0, .{ .x = 2000, .y = 0, .z = 0 });
    }
    try fixture.evictBlocks();
    // The edit itself reads its own section. Its neighbours stay on disk.
    const reads = fixture.terrain.cache.backend.store.bases.metrics.reads.value();
    const waits = store.snapshot().waits;
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 20, .z = 8 }, 0);
    const after_edit = fixture.terrain.cache.backend.store.bases.metrics.reads.value();
    try std.testing.expect(after_edit >= reads);
    fixture.service.finishTick();
    // The tick read nothing from disk. It handed the reads to the terrain side.
    try std.testing.expectEqual(after_edit, fixture.terrain.cache.backend.store.bases.metrics.reads.value());
    try std.testing.expect(store.snapshot().waits > waits);
    try std.testing.expectEqual(@as(usize, 1), fixture.service.unsettled_count);
    while (try fixture.service.pollStore()) {}
    try fixture.settleAll();
    try std.testing.expectEqual(@as(usize, 2), fixture.heard.patched);
    try fixture.expectSquareExact(0, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "a patched column that left memory is never lit from the frame its edit made stale" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.{ .sections = 2 * light_store.Copy.capacity, .columns = 256, .players = 1, .guaranteed = 16 });
    defer fixture.deinit();
    const store = fixture.store();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    try fixture.prewarm(2);

    // The edit is patched from frames and is not saved. The frames of its nine columns
    // go on matching the saved blocks while their light is out of date.
    try fixture.terrain.setBlock(0, .{ .x = 8, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    try std.testing.expectEqual(@as(u64, 9), store.snapshot().frames);

    // Light elsewhere pushes those columns out of memory.
    for (1..20) |site| {
        const x: i32 = @intCast(site * 96 + 8);
        try fixture.terrain.setBlock(0, .{ .x = x, .y = 20, .z = 8 }, glowstone);
        try fixture.settleAll();
    }
    try std.testing.expectEqual(light_store.Presence.overflowed, store.presence(StoreFixture.key(0, 0), fixture.shape()));

    // Gameplay then asks for more columns than the table has room to remember. The
    // table lets go of columns no unsaved edit touched and keeps the patched ones.
    var samples: [1]?Sample = undefined;
    for (0..120) |index| {
        try fixture.service.sampleMany(0, &.{.{ .x = @intCast(index * 16), .y = 20, .z = 4000 }}, &samples);
        try fixture.settleAll();
    }
    try std.testing.expect(store.snapshot().forgotten != 0);
    try std.testing.expectEqual(@as(u64, 0), store.snapshot().resets);
    for (0..9) |index| {
        const at = StoreFixture.key(@as(i32, @intCast(index % 3)) - 1, @as(i32, @intCast(index / 3)) - 1);
        try std.testing.expect(store.presence(at, fixture.shape()) != .absent);
    }

    // The next edit there starts from the patched light, not from the frames.
    const frames = store.snapshot().frames;
    try fixture.terrain.setBlock(0, .{ .x = 9, .y = 20, .z = 8 }, stone);
    try fixture.settleAll();
    try std.testing.expectEqual(frames, store.snapshot().frames);
    try fixture.expectSquareExact(0, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}

test "a column is settled against blocks in which later unsettled edits have not happened" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const service = fixture.service;
    const magma: u16 = @intCast(game_data.registry.blockStateId("minecraft:magma_block").?);
    try std.testing.expectEqual(@as(u8, 3), service.deps.blocks.light.states[magma].emission);
    // A stone wall along the west face of the east column, two sections high.
    var wall: [256]chunks.BlockEdit = undefined;
    for (&wall, 0..) |*edit, index| edit.* = .{ .index = @intCast(index * 16), .state = fixture.ground.stone };
    for (1..3) |section| try fixture.terrain.setBlocks(.{ .world = 0, .x = 1, .y = @intCast(section), .z = 0 }, &wall);
    try fixture.settleAll();
    try fixture.expectSquareExact(1, 0, 1);
    // Every column around both edits is in memory before they are made.
    try fixture.terrain.setBlock(0, .{ .x = 0, .y = 30, .z = 0 }, fixture.ground.stone);
    try fixture.settleAll();
    const Seen = struct {
        calls: usize = 0,
        east_of_first: u32 = std.math.maxInt(u32),
        centre_of_second: u32 = 0,

        fn patched(raw: *anyopaque, _: u32, x: i32, _: i32, sections: [2][9]u32) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.calls == 0 and x == 0) self.east_of_first = sections[0][5];
            if (self.calls == 1 and x == 1) self.centre_of_second = sections[0][4];
            self.calls += 1;
        }

        fn unlit(_: *anyopaque, _: u32, _: i32, _: i32, _: [9]u64) void {
            unreachable;
        }

        fn wanted(_: *anyopaque, _: u32, _: i32, _: i32, _: u64) void {}
    };
    var seen: Seen = .{};
    service.sink = .{ .context = &seen, .patched = Seen.patched, .unlit = Seen.unlit, .wanted = Seen.wanted };
    // In one tick a weak light goes up against the wall and the wall cell beside it is
    // opened. The light is too weak to get around or over the wall.
    try fixture.terrain.setBlock(0, .{ .x = 15, .y = 24, .z = 8 }, magma);
    try fixture.terrain.setBlock(0, .{ .x = 16, .y = 24, .z = 8 }, 0);
    service.settle();
    // Settling the light first sees the wall whole, so nothing changes east of it. The
    // opening is settled next and lets the light through.
    try std.testing.expectEqual(@as(usize, 2), seen.calls);
    try std.testing.expectEqual(@as(u32, 0), seen.east_of_first);
    try std.testing.expect(seen.centre_of_second != 0);
    var samples: [1]?Sample = undefined;
    try service.sampleMany(0, &.{.{ .x = 16, .y = 24, .z = 8 }}, &samples);
    try std.testing.expectEqual(@as(u4, 2), samples[0].?.block);
    for ([_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, -1 }, .{ 1, 1 }, .{ 2, 0 } }) |column| try fixture.expectExact(column[0], column[1]);
    try std.testing.expectEqual(@as(u64, 0), fixture.store().snapshot().failures);
}

test "a solve beside an edit still waiting is not taken for the light that edit is patched on" {
    var fixture: StoreFixture = undefined;
    try fixture.init(.forPlayers(1));
    defer fixture.deinit();
    const service = fixture.service;
    const store = fixture.store();
    const glowstone: u16 = @intCast(game_data.registry.blockStateId("minecraft:glowstone").?);
    try fixture.prewarm(4);
    // A light source by the border with the column east, settled.
    try fixture.terrain.setBlock(0, .{ .x = 15, .y = 20, .z = 8 }, glowstone);
    try fixture.settleAll();
    try fixture.checkpoint();
    // Its blocks leave memory, so that removing it has to wait a tick for them.
    try fixture.evictBlocks();
    try fixture.terrain.setBlock(0, .{ .x = 15, .y = 20, .z = 8 }, 0);
    fixture.tick();
    try std.testing.expectEqual(@as(usize, 1), service.unsettled_count);
    // Meanwhile an edit beside it could not be patched, and the column east of the
    // waiting edit lost its light. Its solve reads the blocks without the light source.
    service.darkenAround(StoreFixture.key(2, 0), fixture.shape());
    try std.testing.expectEqual(light_store.Presence.unlit, store.presence(StoreFixture.key(1, 0), fixture.shape()));
    _ = try fixture.answer();
    fixture.tick();
    // It is not taken in beside the waiting edit: the edit would be patched over light
    // that already lacks the source. The light comes out exact.
    try std.testing.expect(store.presence(StoreFixture.key(1, 0), fixture.shape()) != .resident or service.unsettled_count == 0);
    try fixture.settleAll();
    try fixture.expectSquareExact(0, 0, 1);
    try fixture.expectSquareExact(2, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), fixture.terrain.borrowed_count);
}
