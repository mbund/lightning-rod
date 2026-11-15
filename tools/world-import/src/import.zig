const std = @import("std");
const chunks = @import("chunks");
const anvil = @import("anvil");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Chunks = @import("chunks").Chunks;
const Entities = @import("entities").Entities;
const Lighting = @import("terrain").lighting.Lighting;
const Players = @import("players").players.Players;
const Streaming = @import("terrain").streaming.Streaming;
const Worlds = @import("worlds").Worlds;
const records = @import("records");
const inventories = @import("inventories");
const game_data = @import("game_data");
const nbt = @import("nbt");
const fields = @import("nbt.zig");
const item_import = @import("items.zig");
const player_import = @import("players.zig");
const entity_import = @import("entities.zig");
const block_import = @import("blocks.zig");
const delivery = @import("delivery.zig");
const protocols = @import("protocols");
const assert = std.debug.assert;

const chunk_configuration: chunks.Chunks.Configuration = .{ .cache_sections = 192, .demand_sections = 0 };

pub const Mapping = struct {
    original: u128,
    destination: u128,

    pub fn jsonStringify(self: Mapping, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        var original: [32]u8 = undefined;
        var destination: [32]u8 = undefined;
        try writer.write(.{
            .original = std.fmt.bufPrint(&original, "{x:0>32}", .{self.original}) catch unreachable,
            .destination = std.fmt.bufPrint(&destination, "{x:0>32}", .{self.destination}) catch unreachable,
        });
    }
};
pub const Options = struct {
    input: []const u8,
    output: []const u8,
    skip_unsupported: bool = false,
    players: []const Mapping = &.{},
    lighting: bool = false,
};
pub const Counts = struct {
    columns: usize = 0,
    sections: usize = 0,
    players: usize = 0,
    stacks: usize = 0,
    chests: usize = 0,
    furnaces: usize = 0,
    items: usize = 0,
    orbs: usize = 0,
    incomplete_chunks: usize = 0,
    lit_columns: usize = 0,
    deferred_lighting: usize = 0,
    /// Lit columns whose whole neighbourhood has no biome data. Delivery falls back to the
    /// configured biome, so no record is compiled for them.
    uncompiled_columns: usize = 0,
};

pub const Import = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    store: *lightning_rod.storage.Store,
    content: vanilla.definition_provider.Dependencies,
    worlds: *Worlds,
    chunks: *Chunks,
    spawn: *vanilla.Spawn,
    inventories: *inventories.Inventories,
    items: *vanilla.Items,
    entities: *Entities,
    workspace: *records.Workspaces,
    players: records.Table,
    player_states: records.Table,
    containers: vanilla.container_storage.Persistence,
    dropped: records.Table,
    orbs: records.Table,
    recipes: records.Table,
    recipe_names: std.StringHashMap(usize),
    recipe_identities: [][32]u8,
    registry: anvil.Registry,
    counts: Counts = .{},
    skipped: std.StringHashMap(usize),
    source: Column = undefined,
    entity_ids: std.AutoHashMap(u128, void),
    player_ids: std.AutoHashMap(u128, u128),
    sequence: u64 = 0,
    columns_since_save: usize = 0,
    lighting: *Lighting,
    columns: std.AutoArrayHashMapUnmanaged(chunks.Light.Column, void),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options, store: *lightning_rod.storage.Store, metrics: *lightning_rod.metrics.Registry) !Import {
        const content = try vanilla.prepareDefinitions(allocator);
        const workspace = try records.Workspaces.init(allocator, io, .{});
        const identity = try vanilla.RegistryIdentity.init(allocator, .{ .storage = try store.openSpace(vanilla.RegistryIdentity.id) });
        const worlds = try Worlds.init(allocator, .{}, .{ .storage = try store.openSpace(Worlds.id) });
        _ = try vanilla.VanillaWorlds.init(allocator, .{ .registry_identity = identity, .worlds = worlds, .dimensions = content.dimensions });
        var recipe_names = std.StringHashMap(usize).init(allocator);
        const recipe_identities = try allocator.alloc([32]u8, content.book.table.book.len);
        for (content.book.table.book, recipe_identities, 0..) |recipe, *recipe_identity, index| {
            try recipe_names.put(recipe.name, index);
            std.crypto.hash.Blake3.hash(recipe.name, recipe_identity, .{});
        }
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 256, .cache_items = 16 }, .{ .record_workspaces = workspace, .metrics = metrics, .storage = try store.openSpace(inventories.Inventories.id) });
        const terrain = try Chunks.init(allocator, io, chunk_configuration, .{ .record_workspaces = workspace, .metrics = metrics, .storage = try store.openSpace(Chunks.id) });
        const spawn = try vanilla.Spawn.init(allocator, .{}, .{ .record_workspaces = workspace, .storage = try store.openSpace(vanilla.Spawn.id), .worlds = worlds, .chunks = terrain, .blocks = content.blocks, .dimensions = content.dimensions });
        const lighting = try Lighting.init(allocator, .{}, .{ .metrics = metrics, .blocks = &content.blocks.published, .chunks = terrain, .worlds = worlds });
        if (options.lighting) lighting.includeClassification(try Streaming.prepareMetadata(allocator, terrain));
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .store = store,
            .content = content,
            .workspace = workspace,
            .worlds = worlds,
            .inventories = ownership,
            .chunks = terrain,
            .spawn = spawn,
            .lighting = lighting,
            .columns = .empty,
            .items = try vanilla.Items.init(allocator, .{}, .{ .definitions = content.items, .registry_identity = identity, .inventories = ownership }),
            .entities = try Entities.init(allocator, io, .{}, .{ .record_workspaces = workspace, .metrics = metrics, .storage = try store.openSpace(Entities.id) }),
            .players = records.Table.init(try store.openSpace(Players.id), workspace.resources),
            .player_states = records.Table.init(try store.openSpace(vanilla.PlayerStates.id), workspace.resources),
            .containers = try vanilla.container_storage.Persistence.init(try store.openSpace(vanilla.Containers.id), workspace),
            .dropped = records.Table.init(try store.openSpace(vanilla.ItemEntities.id), workspace.resources),
            .orbs = records.Table.init(try store.openSpace(vanilla.Experience.id), workspace.resources),
            .recipes = records.Table.init(try store.openSpace(vanilla.RecipeBook.id), workspace.resources),
            .recipe_names = recipe_names,
            .recipe_identities = recipe_identities,
            .registry = try anvil.Registry.init(allocator, game_data.registry.block_state_names),
            .skipped = std.StringHashMap(usize).init(allocator),
            .entity_ids = std.AutoHashMap(u128, void).init(allocator),
            .player_ids = std.AutoHashMap(u128, u128).init(allocator),
        };
    }

    pub fn unsupported(self: *Import, category: []const u8, name: []const u8) !void {
        if (!self.options.skip_unsupported) {
            std.log.warn("unsupported {s}: {s}", .{ category, name });
            return error.UnsupportedWorldData;
        }
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ category, name });
        const entry = try self.skipped.getOrPut(key);
        if (entry.found_existing) self.allocator.free(key) else {
            entry.value_ptr.* = 0;
            std.log.warn("skipping unsupported {s}: {s}", .{ category, name });
        }
        entry.value_ptr.* += 1;
    }

    pub fn mappedUuid(self: *const Import, uuid: u128) u128 {
        for (self.options.players) |mapping| if (mapping.original == uuid) return mapping.destination;
        return uuid;
    }

    pub fn save(self: *Import) !void {
        try self.chunks.checkpoint(try self.store.openSpace(Chunks.id));
        try self.inventories.checkpoint(self.inventories.deps.storage);
        try self.entities.checkpoint(self.entities.deps.storage);
        try self.worlds.checkpoint(try self.store.openSpace(Worlds.id));
        try self.spawn.checkpoint(try self.store.openSpace(vanilla.Spawn.id));
        self.sequence += 1;
        try self.store.waitDurable(try self.store.commit(self.sequence));
        const threshold = self.store.limits.checkpoint_bytes;
        self.store.limits.checkpoint_bytes = 64;
        defer self.store.limits.checkpoint_bytes = threshold;
        while (self.store.end != 64 or self.store.phase != .idle) {
            _ = try self.store.pollMaintenance(.{ .index_entries = lightning_rod.storage.batch_size, .pages = lightning_rod.storage.batch_size });
            if (self.store.maintenance_io.active) try self.store.maintenance_io.drain();
            if (self.store.filesystem.pending) try self.store.filesystem.wait(null);
        }
        self.columns_since_save = 0;
    }

    pub fn run(self: *Import) !void {
        self.chunks.setSource(.init(&self.source, Column.read));
        const dimensions = [_]struct { name: []const u8, legacy: []const u8, modern: []const u8 }{
            .{ .name = "minecraft:overworld", .legacy = "", .modern = "dimensions/minecraft/overworld" },
            .{ .name = "minecraft:the_nether", .legacy = "DIM-1", .modern = "dimensions/minecraft/the_nether" },
            .{ .name = "minecraft:the_end", .legacy = "DIM1", .modern = "dimensions/minecraft/the_end" },
        };
        for (dimensions) |dimension| {
            const world = self.worlds.find(dimension.name).?;
            const modern = try std.fs.path.join(self.allocator, &.{ self.options.input, dimension.modern });
            const modern_region = try std.fs.path.join(self.allocator, &.{ modern, "region" });
            const path = if (exists(self.io, modern_region)) modern else try std.fs.path.join(self.allocator, &.{ self.options.input, dimension.legacy });
            try self.regions(path, &world, false);
            try self.regions(path, &world, true);
        }
        try self.checkDimensions();
        if (self.counts.columns == 0) return error.NoTerrainFound;
        try player_import.all(self);
        try self.save();
        if (self.options.lighting) try self.bakeLighting();
    }

    /// Bakes caches for a database imported without them. Columns are discovered from stored
    /// terrain groups, and a column counts only when every section of its dimension is stored.
    pub fn prewarmExisting(self: *Import) !void {
        assert(self.options.lighting and self.columns.count() == 0);
        const index = self.lighting.classification.?;
        const store = self.chunks.cache.backend.store;
        const side: i32 = store.side;
        var footprints: std.AutoArrayHashMapUnmanaged([12]u8, void) = .empty;
        defer footprints.deinit(self.allocator);
        var after: [64]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        while (true) {
            var keys: [records.Table.read_batch_size][64]u8 = undefined;
            var entries: [records.Table.read_batch_size]records.ScanKey = undefined;
            for (&keys, &entries) |*key, *entry| entry.* = .{ .key = key };
            const result = try store.bases.backend.table.scanKeys(&cursor, &entries);
            for (entries[0..result.count]) |entry| {
                if (entry.key_len != 16) return error.UnexpectedTerrainKey;
                try footprints.put(self.allocator, entry.key[0..12].*, {});
            }
            if (!result.more) break;
        }
        const partial = try self.discoverStored(footprints.keys(), side, index);
        // Row order lets each bake scroll the lighting neighbourhood by one column.
        const Order = struct {
            keys: []const chunks.Light.Column,
            pub fn lessThan(order: @This(), a: usize, b: usize) bool {
                const left = order.keys[a];
                const right = order.keys[b];
                if (left.world != right.world) return left.world < right.world;
                if (left.z != right.z) return left.z < right.z;
                return left.x < right.x;
            }
        };
        self.columns.sort(Order{ .keys = self.columns.keys() });
        std.log.info("event=prewarm_discovered footprints={d} columns={d} partial={d}", .{ footprints.count(), self.columns.count(), partial });
        try self.bakeLighting();
    }

    /// Summaries record which sections are stored. Returns how many columns were partial.
    fn discoverStored(self: *Import, footprints: []const [12]u8, side: i32, index: *const chunks.classification.Index) !usize {
        self.chunks.attach();
        defer self.chunks.stop();
        var partial: usize = 0;
        var candidates: [chunks.classification.column_batch_max]chunks.classification.Column = undefined;
        var summaries: [chunks.classification.column_batch_max]chunks.classification.ColumnSummary = undefined;
        var pending: usize = 0;
        for (footprints) |key| {
            const world = std.mem.readInt(u32, key[0..4], .big);
            const dimension = (self.worlds.get(world) orelse return error.UnknownWorld).dimension;
            const base_x = std.mem.readInt(i32, key[4..8], .big) * side;
            const base_z = std.mem.readInt(i32, key[8..12], .big) * side;
            for (0..@intCast(side * side)) |offset| {
                candidates[pending] = .{ .world = world, .x = base_x + @as(i32, @intCast(offset % @as(usize, @intCast(side)))), .z = base_z + @as(i32, @intCast(offset / @as(usize, @intCast(side)))), .minimum = dimension.minimumSection(), .count = @intCast(dimension.sectionCount()) };
                pending += 1;
                if (pending == candidates.len) {
                    partial += try self.keepStored(candidates[0..pending], summaries[0..pending], index);
                    pending = 0;
                }
            }
        }
        if (pending != 0) partial += try self.keepStored(candidates[0..pending], summaries[0..pending], index);
        return partial;
    }

    /// Returns how many candidates had only some of their sections stored.
    fn keepStored(self: *Import, candidates: []const chunks.classification.Column, summaries: []chunks.classification.ColumnSummary, index: *const chunks.classification.Index) !usize {
        assert(candidates.len == summaries.len);
        try self.chunks.summarize(candidates, summaries, index.properties, index.selected);
        var partial: usize = 0;
        for (candidates, summaries) |candidate, summary| {
            const all: u32 = @truncate((@as(u64, 1) << @intCast(candidate.count)) - 1);
            // A section is stored only once classified. An unclassified absent section is not
            // yet marked missing, which once admitted columns the import never wrote.
            if (summary.known & all == 0) continue;
            if (summary.missing & all != 0 or summary.known & all != all) {
                partial += 1;
                continue;
            }
            try self.columns.put(self.allocator, .{ .world = candidate.world, .x = candidate.x, .z = candidate.z }, {});
        }
        return partial;
    }

    fn bakeLighting(self: *Import) !void {
        const cache = self.chunks.cache.backend.store.derived;
        const before = (try cache.store.database.stat(self.io)).size;
        const generation = cache.generation.load(.acquire);
        self.chunks.attach();
        defer self.chunks.stop();
        std.log.info("event=lighting_bake_started columns={d} cache_bytes={d}", .{ self.columns.count(), before });
        var selected = try protocols.Default.init(self.allocator);
        defer selected.deinit(self.allocator);
        var compiler = try delivery.Compiler.init(self.allocator, &selected, &self.content.blocks.published);
        defer compiler.workspace.cancel();
        const columns = self.columns.keys();
        var offset: usize = 0;
        while (offset < columns.len) {
            const batch = columns[offset..@min(columns.len, offset + compiler.capacity())];
            try compiler.begin(batch);
            for (batch) |column_key| {
                const neighbors = try column_key.neighbors();
                var complete = true;
                for (neighbors) |neighbor| complete = complete and self.columns.contains(neighbor);
                if (!complete) {
                    self.counts.deferred_lighting += 1;
                    continue;
                }
                const dimension = self.worlds.get(column_key.world).?.dimension;
                const frame = try self.lighting.bakeFrame(column_key.world, column_key.x, column_key.z, dimension) orelse return error.LightingBakeIncomplete;
                compiler.compile(self.chunks, column_key, &frame) catch |err| switch (err) {
                    error.MissingBiomeData => self.counts.uncompiled_columns += 1,
                    else => return err,
                };
                self.counts.lit_columns += 1;
            }
            try compiler.finish(self.chunks);
            offset += batch.len;
            if (offset / 16384 != (offset - batch.len) / 16384) std.log.info("event=lighting_bake_progress columns={d}/{d}", .{ offset, columns.len });
        }
        // A cache emptied or dropped along the way holds only part of the bake.
        if (cache.state.load(.acquire) != .ready or cache.generation.load(.acquire) != generation) return error.PrewarmLost;
        const after = (try cache.store.database.stat(self.io)).size;
        std.log.info("event=lighting_bake_finished columns={d} deferred={d} uncompiled={d} before_bytes={d} after_bytes={d}", .{ self.counts.lit_columns, self.counts.deferred_lighting, self.counts.uncompiled_columns, before, after });
    }

    fn checkDimensions(self: *Import) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.options.input, "dimensions" });
        defer self.allocator.free(path);
        var directory = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer directory.close(self.io);
        var walker = try directory.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .directory or !std.mem.eql(u8, entry.basename, "region")) continue;
            if (std.mem.eql(u8, entry.path, "minecraft/overworld/region") or std.mem.eql(u8, entry.path, "minecraft/the_nether/region") or std.mem.eql(u8, entry.path, "minecraft/the_end/region")) continue;
            try self.unsupported("dimension", std.fs.path.dirname(entry.path).?);
            walker.leave(self.io);
        }
    }

    fn regions(self: *Import, directory: []const u8, world: *const Worlds.World, entities: bool) !void {
        const path = try std.fs.path.join(self.allocator, &.{ directory, if (entities) "entities" else "region" });
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);
        var reader = try anvil.Reader.initRegion(self.allocator, self.io, path, null);
        defer reader.deinit();
        var iterator = dir.iterate();
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        while (try iterator.next(self.io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".mca")) {
            try names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
        };
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        for (names.items) |name| {
            const coordinates = try regionCoordinates(name);
            const file = try dir.openFile(self.io, name, .{});
            defer file.close(self.io);
            const size = (try file.stat(self.io)).size;
            if (size == 0) continue;
            if (size < 8192) return error.TruncatedRegion;
            var locations: [4096]u8 = undefined;
            if (try file.readPositionalAll(self.io, &locations, 0) != locations.len) return error.TruncatedRegion;
            for (0..1024) |ordinal| {
                const side: usize = chunk_configuration.storage_group_side;
                const tile = ordinal / (side * side);
                const local = ordinal % (side * side);
                const index = (tile / (32 / side) * side + local / side) * 32 + tile % (32 / side) * side + local % side;
                if (std.mem.readInt(u32, locations[index * 4 ..][0..4], .big) == 0) continue;
                const x = coordinates[0] * 32 + @as(i32, @intCast(index % 32));
                const z = coordinates[1] * 32 + @as(i32, @intCast(index / 32));
                _ = scratch.reset(.retain_capacity);
                const doc = if (entities) try reader.read(x, z) else reader.load(x, z) catch |err| switch (err) {
                    error.ChunkNotGenerated => {
                        self.counts.incomplete_chunks += 1;
                        continue;
                    },
                    else => {
                        std.log.err("{s}/{s}, chunk {d},{d}: {s}", .{ path, name, x, z, @errorName(err) });
                        return err;
                    },
                };
                if (entities) {
                    const position = try (doc.childNamed("Position") orelse return error.MissingCoordinates).intArray();
                    if (position.len() != 2 or position.get(0) != x or position.get(1) != z) return error.WrongCoordinates;
                }
                if (entities) try entity_import.column(self, scratch.allocator(), doc, world.id) else try self.column(scratch.allocator(), doc, world, x, z);
                self.columns_since_save += 1;
                if (self.columns_since_save == 8) try self.save();
            }
            std.log.info("imported {s}/{s}", .{ path, name });
        }
    }

    fn column(self: *Import, scratch: std.mem.Allocator, doc: nbt.Document, world: *const Worlds.World, x: i32, z: i32) !void {
        self.source = .{ .scratch = scratch, .registry = &self.registry, .doc = doc, .world = world.id, .x = x, .z = z, .minimum = world.dimension.minimum_section, .sections = @splat(null) };
        const source = &self.source;
        if (world.dimension.section_count > source.sections.len) return error.DimensionTooTall;
        const sections = doc.childNamed("sections") orelse return error.MissingSections;
        var iterator = sections.childIterator(doc.nodes);
        while (iterator.next()) |section| {
            const y = std.math.cast(i32, try fields.integer(try fields.field(doc, section, "Y"))) orelse return error.InvalidSectionY;
            const offset = @as(i64, y) - world.dimension.minimum_section;
            if (offset < 0 or offset >= world.dimension.section_count) {
                var bytes: [anvil.section_bytes]u8 = undefined;
                const decoded = try anvil.section(scratch, &self.registry, doc, section, &bytes);
                if (decoded.len != 3 or std.mem.readInt(u16, decoded[1..3], .little) != self.registry.states.get("minecraft:air\x00").?) return error.SectionOutsideDimension;
                continue;
            }
            if (source.sections[@intCast(offset)] != null) return error.DuplicateSection;
            source.sections[@intCast(offset)] = section;
        }
        try source.importSections(self.chunks, world.dimension.section_count);
        try block_import.column(self, scratch, doc, world.id);
        self.counts.columns += 1;
        try self.columns.put(self.allocator, .{ .world = world.id, .x = x, .z = z }, {});
        self.counts.sections += world.dimension.section_count;
    }
};

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn regionCoordinates(name: []const u8) ![2]i32 {
    if (!std.mem.startsWith(u8, name, "r.") or !std.mem.endsWith(u8, name, ".mca")) return error.InvalidRegionName;
    var values = std.mem.splitScalar(u8, name[2 .. name.len - 4], '.');
    const x = try std.fmt.parseInt(i32, values.next() orelse return error.InvalidRegionName, 10);
    const z = try std.fmt.parseInt(i32, values.next() orelse return error.InvalidRegionName, 10);
    const minimum = @divFloor(-30_000_000, 32 * 16);
    const maximum = @divFloor(29_999_999, 32 * 16);
    if (values.next() != null or x < minimum or x > maximum or z < minimum or z > maximum) return error.InvalidRegionName;
    return .{ x, z };
}

const Column = struct {
    scratch: std.mem.Allocator,
    registry: *const anvil.Registry,
    doc: nbt.Document,
    world: u32,
    x: i32,
    z: i32,
    minimum: i32,
    sections: [64]?nbt.Node,

    fn read(self: *Column, _: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| {
            const section = request.section;
            std.debug.assert(section.world == self.world and section.x == self.x and section.z == self.z);
            var bytes: [anvil.section_bytes]u8 = undefined;
            const decoded = anvil.section(self.scratch, self.registry, self.doc, self.sections[@intCast(section.y - self.minimum)], &bytes) catch |err| {
                request.result = err;
                continue;
            };
            var biomes: [64]u16 = undefined;
            const present = anvil.biomes(self.doc, self.sections[@intCast(section.y - self.minimum)], game_data.registry.biome_names, &biomes) catch |err| {
                request.result = err;
                continue;
            };
            const offset: usize = if (present) chunks.encoding.biome_header_bytes else 0;
            if (present) {
                request.output[0] = 3;
                for (biomes, 0..) |biome, index| std.mem.writeInt(u16, request.output[1 + index * 2 ..][0..2], biome, .little);
            }
            @memcpy(request.output[offset..][0..decoded.len], decoded);
            request.result = offset + decoded.len;
        }
    }

    fn importSections(self: *Column, owner: *chunks.Chunks, count: usize) !void {
        var positions: [64]chunks.Section = undefined;
        var leases: [64]chunks.Lease = undefined;
        for (positions[0..count], 0..) |*position, index| position.* = .{ .world = self.world, .x = self.x, .z = self.z, .y = self.minimum + @as(i32, @intCast(index)) };
        try owner.acquireMany(positions[0..count], leases[0..count]);
        owner.releaseMany(leases[0..count]);
    }
};
