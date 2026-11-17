const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const std = @import("std");
const section_views = @import("lighting").section_views;
const deflate = @import("deflate");
const builtin = @import("builtin");
const chunks = @import("chunks");
const delivery_cache = @import("delivery_cache.zig");
const protocol_set = @import("minecraft_packets").protocols;
const game_data = @import("game_data");
const packets = @import("minecraft_packets");
const sessions = @import("sessions");
const support = @import("protocol_support");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_26_1 = @import("wire_26_1");
const lightning_rod = @import("lightning_rod");
const lighting = @import("lighting.zig");
const worlds = @import("worlds");
const assert = std.debug.assert;
const BlockProperties = @import("block_properties").BlockProperties;
const light_engine = @import("lighting");
/// The words of a section without a palette, and the length that may precede them.
const direct_word_bytes = 4096 / 4 * 8 + 3;
const palette_word_bytes = blk: {
    var sizes: [5]u16 = undefined;
    for (&sizes, 4..) |*size, bits| {
        const per_word = 64 / bits;
        size.* = @intCast((4096 + per_word - 1) / per_word * 8);
    }
    break :blk sizes;
};

pub const Workspace = struct {
    const Mapping = struct {
        number: i32,
        biomes: [game_data.registry.biome_names.len]i32 = @splat(-1),
        biome_bits: ?u8 = null,

        fn biome(self: *Mapping, protocol: *const sessions.Protocol, value: u16) !i32 {
            assert(self.number == protocol.number);
            if (value >= self.biomes.len) return error.UnsupportedBiome;
            const cached = &self.biomes[value];
            if (cached.* < 0) cached.* = try protocol.registryId("minecraft:worldgen/biome", game_data.registry.biome_names[value]);
            return cached.*;
        }
    };

    const BiomeEncoding = struct {
        valid: bool = false,
        protocol: i32 = 0,
        preparation: u64 = 0,
        source: section_views.Biomes = .{ .constant = 0 },
        hash: u64 = 0,
        key: [128]u8 = undefined,
        key_length: u8 = 0,
        bytes: [257]u8 = undefined,
        length: u16 = 0,
    };

    const Summary = struct {
        const State = struct {
            stamp: section_views.Stamp = .{ .generation = std.math.maxInt(u64) },
            palette_len: u16 = 0,
            count: u16 = 0,
            fluid_count: u16 = 0,
            block_entities: u16 = 0,
            direct: bool = false,
        };

        state: State = .{},
        baked: ?*const chunks.Prepared.Section = null,
        heights: [256]u8 = undefined,
        palette: [256]u16 = undefined,
        entities: [64]u64 = undefined,

        fn reset(self: *Summary) void {
            self.state = .{};
            self.baked = null;
        }

        fn paletteState(self: *const Summary, rank: usize) u16 {
            assert(rank < self.state.palette_len);
            return if (self.baked) |section| section.state(rank) else self.palette[rank];
        }

        /// Baked sections store packed heights, so they decode into the caller's buffer.
        fn heightValues(self: *const Summary, buffer: *[256]u8) *const [256]u8 {
            const section = self.baked orelse return &self.heights;
            section.heights.decode(buffer);
            return buffer;
        }
    };

    const Column = struct {
        valid: bool = false,
        stamps: [section_views.maximum_sections]section_views.Stamp = undefined,
        count: usize = 0,
        heights: [256]u16 = undefined,
        heightmap: [chunks.Prepared.Heightmap.maximum_bytes]u8 = undefined,
        heightmap_bytes: usize = 0,
    };

    represented: [section_views.maximum_sections]section_views.Section = undefined,
    terrain: [section_views.maximum_sections]chunks.Prepared.Section = undefined,
    baked: ?*const chunks.Light.View = null,
    baked_generation: u64 = 0,
    word_decoder: deflate.fragments.Decoder,
    fragments: deflate.fragments.Stream = undefined,
    uniform_light: *lighting.Data.Uniforms,
    /// Runs of alike uniform sections, compressed once and reused for every column and player.
    section_runs: SectionRuns = .{},
    direct_words: [8192]u8 = undefined,
    biome_padding: [section_views.maximum_sections][64]u16 = undefined,
    biome_projection: BiomeNeighborhood.Cache = .{},
    projected_biomes: [section_views.maximum_sections]?section_views.Biomes = undefined,
    biome_encodings: [section_views.maximum_sections]BiomeEncoding = @splat(.{}),
    last_biome_encoding: ?usize = null,
    disclosure: u32 = std.math.maxInt(u32),
    concealment: u16 = 0,
    frontier: u32 = 0,
    column: Column = .{},
    summaries: [section_views.maximum_sections]Summary = @splat(.{}),
    cover: Summary = .{},
    summary_builds: u64 = 0,
    preparation: u64 = 0,
    palette_indices: [1 << game_data.registry.block_state_bits]u16 = @splat(std.math.maxInt(u16)),
    properties: []const u8,
    blocks: *const BlockProperties,
    mappings: []Mapping,
    current_mapping: ?*Mapping = null,

    pub fn init(allocator: std.mem.Allocator, packet_bytes: usize, protocols: []const sessions.Protocol, blocks: *const BlockProperties) !*Workspace {
        assert(packet_bytes > 0 and packet_bytes < 1 << 21);
        assert(blocks.stateCount() == game_data.registry.block_state_to_block.len);
        const self = try allocator.create(Workspace);
        errdefer allocator.destroy(self);
        const properties = try materialProperties(allocator, blocks);
        const mappings = try allocator.alloc(Mapping, protocols.len);
        for (mappings, protocols) |*entry, protocol| entry.* = .{ .number = protocol.number };
        self.* = .{ .mappings = mappings, .properties = properties, .blocks = blocks, .word_decoder = try deflate.fragments.Decoder.init(allocator, chunks.Prepared.maximum_fragment), .uniform_light = try lighting.Data.Uniforms.init(allocator) };
        return self;
    }

    pub fn initDeliveryCatalog(allocator: std.mem.Allocator, definitions: []const sessions.Protocol) !delivery_cache.Catalog {
        var codecs: [protocol_set.implementations.len]delivery_cache.Codec = undefined;
        inline for (protocol_set.implementations, &codecs) |Version, *codec| codec.* = .{
            .number = Version.protocol_number,
            .fluids = comptime switch (sessions.packet_api.select(Version, write)) {
                0 => false,
                1 => true,
                else => @compileError("Chunk delivery layout needs a distinct encoding identity"),
            },
            .registry = packets.Registry.forVersion(Version),
        };
        return delivery_cache.Catalog.init(allocator, definitions, &codecs);
    }

    pub fn prepareDelivery(self: *Workspace, cache: *delivery_cache.Workspace, chunk: Chunk, protocol: i32) !Delivery {
        const source: chunks.Delivery.Source = if (chunk.sections == .baked) .fromHeader(&chunk.sections.baked.view.header) else .{
            .rules = game_data.canonical_identity,
            .revision = 0,
            .minimum = chunk.minimum_section,
            .count = @intCast(chunk.sections.count()),
        };
        const persistent = chunk.sections == .baked;
        const column: chunks.Light.Column = .{ .world = chunk.world, .x = chunk.x, .z = chunk.z };
        var needs_record = false;
        var selected = chunk.disclosure & ~chunk.frontier & @as(u32, @truncate((@as(u64, 1) << @intCast(source.count)) - 1));
        while (selected != 0) : (selected &= selected - 1) {
            const index = @ctz(selected);
            if (chunk.sections == .baked) {
                const frame = chunk.sections.baked.view;
                if (frame.header.uniform & (@as(u32, 1) << @intCast(index)) == 0 or self.blocks.entityName(frame.header.states[index]) != null) needs_record = true;
            } else {
                const view = chunk.sections.loaded[index].view;
                if (view != .uniform or self.blocks.entityName(view.uniform) != null) needs_record = true;
            }
        }
        if (!needs_record and !persistent) cache.catalog.metrics.unbaked_uniform.add(1);
        const record: ?chunks.Delivery.View = if (!needs_record) null else switch (try cache.lookup(column, protocol, source, persistent)) {
            .ready => |value| value,
            .deferred => return error.DeliveryDeferred,
            .missing => |slot| compiled: {
                if (!persistent) cache.catalog.metrics.transient_compiles.add(1);
                break :compiled try self.compileDelivery(cache, slot, chunk, source, persistent, protocol);
            },
        };
        self.baked = if (chunk.sections == .baked) chunk.sections.baked.view else null;
        // Baked frames reach one workspace from more than one place, and no number those
        // places keep is unique between them. The preparation that reads a frame is, and
        // it is taken first so that one which fails is never reused.
        assert(self.preparation < std.math.maxInt(u64));
        self.preparation += 1;
        self.baked_generation = self.preparation;
        const sections = self.representation(chunk);
        if (record == null or storedHeightmap(chunk) == null) try self.prepareSections(sections);
        return .{ .packet = .{ .chunk = chunk, .sections = sections, .maximum_size = if (record) |value| value.maximum_size else self.maximumSize(chunk, sections.len), .preparation = self.preparation }, .encoding = if (record) |value| .{ .record = value } else .uniform, .owner = cache, .generation = cache.generation };
    }

    /// A column whose neighbourhood stores no biomes, as in terrain generated without any,
    /// shows the fallback biome, and cannot be compiled without one.
    pub fn compileFrame(self: *Workspace, cache: *delivery_cache.Workspace, column: chunks.Light.Column, frame: *const chunks.Light.View, protocol: i32, fallback_biome: ?u16) !void {
        if (frame.header.count > section_views.maximum_sections) return error.UnsupportedLightingHeight;
        const neighborhood: BiomeNeighborhood = .{ .source = .{ .baked = frame }, .count = frame.header.count, .disclosed = frame.header.biomes };
        const biome = neighborhood.first() orelse fallback_biome orelse return error.MissingBiomeData;
        const chunk: Chunk = .{
            .world = column.world,
            .x = column.x,
            .z = column.z,
            .minimum_section = frame.header.minimum,
            .sections = .{ .baked = .{ .view = frame } },
            .biome = biome,
            .workspace = self,
            .light = .{ .source = .{ .stored = frame }, .count = @as(usize, frame.header.count) + 2, .masks = .{ @intCast(frame.masks[0]), @intCast(frame.masks[1]) }, .coverage = frame.header.coverage },
        };
        const delivery = try self.prepareDelivery(cache, chunk, protocol);
        // Uniform sections need no compiled record. Their frame is stored alone, so the column
        // reads back as stored instead of being solved again for every delivery.
        if (delivery.encoding == .uniform) {
            const slot = cache.slotOf(column);
            if (cache.compiled[slot]) return;
            var bundle = chunks.Delivery.Column.Builder.begin(cache.destination(), column, frame.bytes, cache.catalog.variants.len) catch return deliverySpace(cache);
            cache.commit(slot, bundle.finish(), true);
        }
    }

    fn compileDelivery(self: *Workspace, cache: *delivery_cache.Workspace, slot: usize, chunk: Chunk, source: chunks.Delivery.Source, persistent: bool, protocol: i32) !chunks.Delivery.View {
        const timing = cache.catalog.metrics.compilation.start();
        defer timing.end();
        const frame = if (chunk.sections == .baked) chunk.sections.baked.view.bytes else &.{};
        const at: chunks.Light.Column = .{ .world = chunk.world, .x = chunk.x, .z = chunk.z };
        var column = chunks.Delivery.Column.Builder.begin(cache.destination(), at, frame, cache.catalog.variants.len) catch return deliverySpace(cache);
        const selected = try cache.catalog.index(protocol);
        const requested = cache.catalog.variants[selected];
        const first = try self.compileVariant(cache, chunk, source, requested, column.destination());
        column.append(requested.identity, first);
        const result = try chunks.Delivery.View.read(first, source);
        // Other protocol formats keep their stored records when still current, so serving a
        // second protocol never evicts the first. A format with no current record compiles
        // when a client first requests it, or here when the cache fills eagerly.
        const stored: ?chunks.Delivery.Column = if (cache.storedBundle(slot)) |bundle| (if (std.meta.eql(bundle.column, at)) bundle else null) else null;
        for (cache.catalog.variants, 0..) |variant, index| {
            if (index == selected) continue;
            const current: ?[]const u8 = if (stored) |bundle| current: {
                const record = bundle.find(variant.identity) orelse break :current null;
                _ = chunks.Delivery.View.read(record, source) catch break :current null;
                break :current record;
            } else null;
            if (current) |record| {
                const destination = column.destination();
                if (record.len > destination.len) break;
                @memcpy(destination[0..record.len], record);
                column.append(variant.identity, destination[0..record.len]);
            } else if (cache.eager) {
                // The requested format is in. One that does not fit compiles on a later pass.
                const record = self.compileVariant(cache, chunk, source, variant, column.destination()) catch |err| switch (err) {
                    error.DeliveryDeferred, error.DeliveryRecordTooLarge => break,
                    else => return err,
                };
                column.append(variant.identity, record);
            }
        }
        cache.commit(slot, column.finish(), persistent);
        return result;
    }

    fn compileVariant(self: *Workspace, cache: *delivery_cache.Workspace, chunk: Chunk, source: chunks.Delivery.Source, variant: delivery_cache.Variant, destination: []u8) ![]const u8 {
        var full = chunk;
        full.disclosure = std.math.maxInt(u32);
        full.biome_disclosure = std.math.maxInt(u32);
        full.biome_neighbors = null;
        full.frontier = 0;
        const prepared = try self.prepare(full);
        var trace: Trace = .{};
        const plain = if (variant.codec.fluids)
            try encodeTraced(.init(cache.plain), variant.codec.registry, &prepared, variant.definition, true, &trace)
        else
            try encodeTraced(.init(cache.plain), variant.codec.registry, &prepared, variant.definition, false, &trace);
        var maximum_light = full.light;
        maximum_light.disclosure = std.math.maxInt(u32);
        maximum_light.selection = null;
        maximum_light.retained = .{ 0, 0 };
        const maximum_size = @min((1 << 21) - 1, prepared.maximum_size - full.light.encodedSize() + maximum_light.encodedSize() + prepared.sections.len * 64 + 64);
        var writer = chunks.Delivery.Writer.begin(destination, source, maximum_size) catch return deliverySpace(cache);
        for (prepared.sections, 0..) |section, index| {
            const entry = trace.sections[index];
            try appendCompiled(cache, &writer, &trace, plain, index, .header, entry.header);
            const shared = if (self.summaryAt(index).baked) |baked| baked.bits != 16 else false;
            if (!shared and entry.words.end != entry.words.start) try appendCompiled(cache, &writer, &trace, plain, index, .words, entry.words);
            if (section.biomes != null) try appendCompiled(cache, &writer, &trace, plain, index, .biome, entry.biome);
            writer.entities(index, plain[entry.entities.start..entry.entities.end], entry.entity_count) catch return deliverySpace(cache);
            writer.aggregate(index, if (shared) self.summaryAt(index).baked.?.words else null);
        }
        const bytes = writer.finish();
        return bytes;
    }

    fn mapping(self: *Workspace, protocol: *const sessions.Protocol) !*Mapping {
        if (self.current_mapping) |current| if (current.number == protocol.number) return current;
        for (self.mappings) |*entry| if (entry.number == protocol.number) {
            self.current_mapping = entry;
            return entry;
        };
        return error.UnsupportedProtocol;
    }

    pub fn prepare(self: *Workspace, chunk: Chunk) !Prepared {
        assert(chunk.workspace == self);
        if (chunk.sections == .baked) {
            const value = chunk.sections.baked;
            var selected = chunk.disclosure & ~value.view.header.uniform & ((@as(u32, 1) << @intCast(value.view.header.count)) - 1);
            while (selected != 0) : (selected &= selected - 1) assert(value.view.terrain[@ctz(selected)] != null);
        }
        self.baked = if (chunk.sections == .baked) chunk.sections.baked.view else null;
        // Baked frames reach one workspace from more than one place, and no number those
        // places keep is unique between them. The preparation that reads a frame is, and
        // it is taken first so that one which fails is never reused.
        assert(self.preparation < std.math.maxInt(u64));
        self.preparation += 1;
        self.baked_generation = self.preparation;
        const sections = self.representation(chunk);
        assert(chunk.light.count == sections.len + 2);
        try self.prepareSections(sections);
        return .{ .chunk = chunk, .sections = sections, .maximum_size = self.maximumSize(chunk, sections.len), .preparation = self.preparation };
    }

    fn maximumSize(self: *const Workspace, chunk: Chunk, section_count: usize) usize {
        var light = chunk.light;
        light.disclosure &= chunk.disclosure;
        var length: usize = 5 + 8 + 2 * (5 + 5 + chunks.Prepared.Heightmap.wordCount(section_count) * 8) + 3 + 5 + light.encodedSize();
        for (0..section_count) |index| {
            const summary = if (self.disclosure & (@as(u32, 1) << @intCast(index)) != 0) self.summaries[index].state else self.cover.state;
            // A direct section holds its states at sixteen bits or fewer, four cells to a
            // word. Twice that kept columns of many distinct states from fitting a page.
            const words: usize = if (summary.direct) direct_word_bytes else palette_word_bytes[@max(4, std.math.log2_int_ceil(usize, @max(summary.palette_len, 2))) - 4];
            length += 4 + 1;
            length += if (summary.palette_len == 1 and !summary.direct) 5 else (if (summary.direct) @as(usize, 0) else 5 + @as(usize, summary.palette_len) * 5) + words;
            length += 1 + 5 + 64 * 4;
            length += @as(usize, summary.block_entities) * (1 + 2 + 5 + 2);
        }
        return length;
    }

    fn representation(self: *Workspace, chunk: Chunk) []const section_views.Section {
        const biome_disclosure = chunk.disclosure & chunk.biome_disclosure;
        const input = chunk.sections.metadata(&self.represented, biome_disclosure, self.baked_generation);
        assert(input.len <= self.represented.len);
        const changed = self.disclosure ^ chunk.disclosure;
        const all = (@as(u32, 1) << @intCast(input.len)) - 1;
        for (input, 0..) |section, index| {
            if (chunk.disclosure & (@as(u32, 1) << @intCast(index)) != 0) assert(section.view != .unavailable or (self.baked != null and self.baked.?.terrain[index] != null));
        }
        if (changed & all != 0 or self.frontier != chunk.frontier or (chunk.disclosure & all != all and self.concealment != chunk.concealment)) self.column.valid = false;
        self.frontier = chunk.frontier;
        assert(chunk.frontier & ~chunk.disclosure == 0);
        if (chunk.frontier == 0 and chunk.disclosure & all == all and biome_disclosure & all == all) {
            self.disclosure = chunk.disclosure;
            self.concealment = chunk.concealment;
            return input;
        }

        var biome_sources: u32 = 0;
        if (chunk.biome_neighbors == null) for (input, 0..) |section, index| {
            if (section.biomes != null) biome_sources |= biome_disclosure & (@as(u32, 1) << @intCast(index));
        };
        if (chunk.biome_neighbors) |neighbors| {
            var context = neighbors.*;
            context.cache = &self.biome_projection;
            context.projectMany(all & ~biome_disclosure, self.projected_biomes[0..input.len], self.biome_padding[0..input.len]);
        }
        if (input.ptr != self.represented[0..input.len].ptr) @memcpy(self.represented[0..input.len], input);
        for (self.represented[0..input.len], 0..) |*section, index| {
            const visible = chunk.disclosure & (@as(u32, 1) << @intCast(index)) != 0;
            if (!visible) {
                section.view = .{ .uniform = chunk.concealment };
                section.stamp = .{ .constant = chunk.concealment };
            } else if (chunk.frontier & (@as(u32, 1) << @intCast(index)) != 0) {
                const state = game_data.registry.blockStateId("minecraft:pink_terracotta").?;
                section.view = .{ .uniform = @intCast(state) };
                section.stamp = .{ .constant = @intCast(state) };
            }
            if (biome_disclosure & (@as(u32, 1) << @intCast(index)) == 0) {
                section.biomes = if (chunk.biome_neighbors != null)
                    self.projected_biomes[index]
                else
                    coverBiomes(input, biome_sources, @intCast(index));
            }
        }
        self.disclosure = chunk.disclosure;
        self.concealment = chunk.concealment;
        return self.represented[0..input.len];
    }

    fn prepareSections(self: *Workspace, sections: []const section_views.Section) !void {
        assert(sections.len <= self.summaries.len);
        const all = (@as(u32, 1) << @intCast(sections.len)) - 1;
        const concealed = all & ~self.disclosure;
        var pending = all & self.disclosure;
        if (concealed != 0) pending |= concealed & (0 -% concealed);
        while (pending != 0) : (pending &= pending - 1) {
            const index = @ctz(pending);
            const section = sections[index];
            const summary = self.summaryAt(index);
            if (section.stamp.constant) |state| assert(section.view == .uniform and section.view.uniform == state);
            const baked: ?*const chunks.Prepared.Section = if (self.baked != null and section.view != .uniform and self.baked.?.terrain[index] != null) prepared: {
                self.terrain[index] = self.baked.?.terrain[index].?.view();
                break :prepared &self.terrain[index];
            } else null;
            const stamp: section_views.Stamp = if (baked != null) .{ .generation = self.baked_generation, .index = index, .storage = .baked } else section.stamp;
            if (std.meta.eql(summary.state.stamp, stamp)) {
                if (baked) |value| {
                    assert(summary.baked != null and summary.state.palette_len == value.palette.len / 2);
                    assert(summary.state.count == value.count and summary.state.fluid_count == value.fluids and summary.state.direct == (value.bits == 16));
                }
                continue;
            }
            self.summary_builds += 1;
            summary.reset();
            if (baked) |value| {
                const count = value.palette.len / 2;
                summary.state = .{ .stamp = stamp, .palette_len = @intCast(count), .count = value.count, .fluid_count = value.fluids, .block_entities = @intCast(value.entities.len / 4), .direct = value.bits == 16 };
                summary.baked = value;
                continue;
            }
            assert(section.view != .unavailable);
            const view = section.view;
            var palette_len: u16 = 0;
            defer {
                for (summary.palette[0..palette_len]) |state| self.palette_indices[state] = std.math.maxInt(u16);
            }
            if (view == .uniform) {
                const state = view.uniform;
                if (state >= self.palette_indices.len) return error.InvalidBlockState;
                summary.palette[0] = state;
                palette_len = 1;
                const empty = isAir(state);
                summary.state.count = if (empty) 0 else 4096;
                summary.state.block_entities = if (self.blocks.entityName(state) != null) 4096 else 0;
                @memset(&summary.entities, if (summary.state.block_entities == 0) 0 else std.math.maxInt(u64));
                summary.state.fluid_count = if (game_data.registry.stateContainsFluid(state)) 4096 else 0;
                @memset(&summary.heights, if (empty) 0 else 16);
            } else if (view == .encoded and view.encoded.paletteCount() > 0 and view.encoded.paletteCount() <= summary.palette.len) {
                const packed_view = view.encoded;
                palette_len = @intCast(packed_view.paletteCount());
                var present: u8 = 0;
                for (summary.palette[0..palette_len], 0..) |*state, rank| {
                    state.* = packed_view.state(rank);
                    if (state.* >= self.properties.len) return error.InvalidBlockState;
                    present |= self.properties[state.*];
                }
                const air = try packed_view.classify(self.properties, 1);
                var empty: u16 = 0;
                for (air.selected) |word| empty += @popCount(word);
                summary.state.count = 4096 - empty;
                @memset(&summary.heights, 0);
                var found: [4]u64 = @splat(0);
                var y: usize = 16;
                while (y != 0) {
                    y -= 1;
                    for (0..4) |group| {
                        const occupied = ~air.selected[y * 4 + group];
                        var added = occupied & ~found[group];
                        found[group] |= occupied;
                        while (added != 0) {
                            const cell = @ctz(added);
                            summary.heights[group * 64 + cell] = @intCast(y + 1);
                            added &= added - 1;
                        }
                    }
                }
                inline for (.{ @as(u8, 2), @as(u8, 4) }, .{ "fluid_count", "block_entities" }) |flag, field| {
                    if (present & flag != 0) {
                        const classified = try packed_view.classify(self.properties, flag);
                        var count: u16 = 0;
                        for (classified.selected) |word| count += @popCount(word);
                        @field(summary.state, field) = count;
                        if (flag == 4) summary.entities = classified.selected;
                    }
                }
            } else {
                @memset(&summary.heights, 0);
                @memset(&summary.entities, 0);
                var count: u32 = 0;
                var fluid_count: u32 = 0;
                var block_entities: u32 = 0;
                var direct = false;
                for (0..256) |row| {
                    const states = view.row(@intCast(row));
                    for (states, 0..) |state, x| {
                        if (state >= game_data.registry.block_state_to_block.len) return error.InvalidBlockState;
                        const occupied = !isAir(state);
                        count += @intFromBool(occupied);
                        if (occupied) summary.heights[row % 16 * 16 + x] = @intCast(row / 16 + 1);
                        if (self.properties[state] & 4 != 0) {
                            const cell = row * 16 + x;
                            summary.entities[cell / 64] |= @as(u64, 1) << @intCast(cell % 64);
                            block_entities += 1;
                        }
                        fluid_count += @intFromBool(game_data.registry.stateContainsFluid(state));
                        if (direct or self.palette_indices[state] != std.math.maxInt(u16)) continue;
                        if (palette_len == summary.palette.len) {
                            direct = true;
                            continue;
                        }
                        self.palette_indices[state] = palette_len;
                        summary.palette[palette_len] = state;
                        palette_len += 1;
                    }
                }
                assert(count <= 4096 and fluid_count <= 4096 and block_entities <= 4096);
                summary.state.count = @intCast(count);
                summary.state.fluid_count = @intCast(fluid_count);
                summary.state.block_entities = @intCast(block_entities);
                summary.state.direct = direct;
            }
            summary.state.palette_len = palette_len;
            summary.state.stamp = section.stamp;
        }
    }

    fn prepareColumn(self: *Workspace, sections: []const section_views.Section) *const Column {
        const column = &self.column;
        var matches = column.valid and column.count == sections.len;
        for (sections, 0..) |section, i| {
            const stamp = section.stamp;
            matches = matches and std.meta.eql(column.stamps[i], stamp);
            column.stamps[i] = stamp;
        }
        if (matches) return column;
        column.count = sections.len;
        @memset(&column.heights, 0);
        var section_index = sections.len;
        while (section_index != 0) {
            section_index -= 1;
            const section = sections[section_index];
            const summary = self.summaryAt(section_index);
            if (summary.state.count == 0) continue;
            var buffer: [256]u8 = undefined;
            const values = summary.heightValues(&buffer);
            var unresolved = false;
            for (0..16) |group| {
                const at = group * 16;
                const previous: @Vector(16, u16) = column.heights[at..][0..16].*;
                const missing = previous == @as(@Vector(16, u16), @splat(0));
                const local: @Vector(16, u8) = values[at..][0..16].*;
                const heights = @as(@Vector(16, u16), @intCast(local)) + @as(@Vector(16, u16), @splat(@intCast(section_index * 16)));
                const found = if (section.view == .uniform) missing else missing & (local != @as(@Vector(16, u8), @splat(0)));
                column.heights[at..][0..16].* = @select(u16, found, heights, previous);
                unresolved = unresolved or @reduce(.Or, missing & !found);
            }
            if (!unresolved) break;
        }
        column.heightmap_bytes = chunks.Prepared.Heightmap.pack(sections.len, &column.heights, &column.heightmap).len;
        column.valid = true;
        return column;
    }

    inline fn summaryAt(self: *Workspace, index: usize) *Summary {
        assert(index < self.summaries.len);
        return if (self.disclosure & (@as(u32, 1) << @intCast(index)) != 0) &self.summaries[index] else &self.cover;
    }
};

fn isAir(state: u16) bool {
    return state == game_data.registry.block_air_default_state or state == game_data.registry.block_cave_air_default_state or state == game_data.registry.block_void_air_default_state;
}

fn coverBiomes(sections: []const section_views.Section, sources: u32, index: u5) ?section_views.Biomes {
    assert(index < sections.len and sections.len <= section_views.maximum_sections);
    assert(sources & (@as(u32, 1) << index) == 0);
    if (sources == 0) return null;
    const below = sources & ((@as(u32, 1) << index) - 1);
    const above = sources & ~((@as(u32, 1) << index) - 1);
    const lower: u5 = if (below != 0) @intCast(31 - @clz(below)) else 0;
    const upper: u5 = if (above != 0) @intCast(@ctz(above)) else 0;
    const selected = if (below == 0) upper else if (above == 0 or index - lower <= upper - index) lower else upper;
    assert(sources & (@as(u32, 1) << selected) != 0);
    return sections[selected].biomes.?;
}

pub const BiomeNeighborhood = struct {
    pub const Source = union(enum) {
        loaded: []const ?section_views.Biomes,
        baked: *const chunks.Light.View,

        pub inline fn get(self: Source, count: usize, column: usize, section: usize) ?section_views.Biomes {
            assert(column < 9 and section < count);
            return switch (self) {
                .loaded => |biomes| biomes[column * count + section],
                .baked => |view| if (view.biome(column, section)) |biome| switch (biome) {
                    .uniform => |value| .{ .constant = value },
                    .dense => |bytes| .{ .encoded = .{ .bytes = bytes } },
                    .palette => |values| .{ .palette = values },
                } else null,
            };
        }

        pub fn available(self: Source, count: usize) [9]u32 {
            assert(count > 0 and count <= section_views.maximum_sections);
            if (self == .baked) return self.baked.header.biomes;
            var masks: [9]u32 = @splat(0);
            for (&masks, 0..) |*mask, column| for (0..count) |section| {
                if (self.get(count, column, section) != null) mask.* |= @as(u32, 1) << @intCast(section);
            };
            return masks;
        }
    };

    source: Source,
    count: usize,
    disclosed: [9]u32,
    cache: ?*Cache = null,

    pub const Cache = struct {
        // Reuse geometry across columns. Every application reads the current column's biome values.
        const capacity = section_views.maximum_sections * lighting.Lighting.delivery_batch_max;
        const Entry = struct {
            valid: bool = false,
            disclosed: [9]u32 = undefined,
            count: u8 = 0,
            section: u8 = 0,
            plan: Plan = undefined,
        };
        entries: [capacity]Entry = @splat(.{}),

        fn slot(self: *Cache, sources: *const [9]u32, section: usize) *Entry {
            const hash = std.hash.Wyhash.hash(section, std.mem.asBytes(sources));
            return &self.entries[hash % self.entries.len];
        }
    };

    const Plan = struct {
        columns: [4]@Vector(16, u8),
        rows: [4][9]u8,
        active: [4]u16,
        minimum: i32,
        maximum: i32,
        plane: bool = false,

        fn apply(self: *const Plan, neighborhood: *const BiomeNeighborhood, output: *[64]u16) Projected {
            for (0..if (self.plane) @as(usize, 1) else 4) |y| {
                var values: @Vector(16, u16) = @splat(0);
                var pending = self.active[y];
                while (pending != 0) : (pending &= pending - 1) {
                    const column = @ctz(pending);
                    const absolute = self.rows[y][column];
                    assert(absolute < neighborhood.count * 4);
                    assert(neighborhood.disclosed[column] & (@as(u32, 1) << @intCast(absolute / 4)) != 0);
                    const source = neighborhood.source.get(neighborhood.count, column, absolute / 4).?;
                    const row = source.row(@intCast(absolute % 4));
                    const projected = projectRow(row, column);
                    const chosen = self.columns[y] == @as(@Vector(16, u8), @splat(@intCast(column)));
                    values = @select(u16, chosen, @as(@Vector(16, u16), projected), values);
                }
                output[y * 16 ..][0..16].* = values;
            }
            return .{ .value = if (self.plane) .{ .plane = output[0..16] } else .{ .values = output }, .minimum = self.minimum, .maximum = self.maximum };
        }
    };

    pub fn first(self: *const BiomeNeighborhood) ?u16 {
        assert(self.count > 0 and self.count <= section_views.maximum_sections);
        for (self.disclosed, 0..) |mask, column| {
            if (mask != 0) return self.source.get(self.count, column, @ctz(mask)).?.get(0);
        }
        return null;
    }

    const Projected = struct { value: ?section_views.Biomes, minimum: i32, maximum: i32 };
    const Horizontal = struct { distance: @Vector(16, u8), cells: [16]u4 };
    const horizontal = blk: {
        var result: [9]Horizontal = undefined;
        for (&result, 0..) |*entry, column| {
            var distances: [16]u8 = undefined;
            for (0..16) |cell| {
                const x: i32 = @intCast(cell % 4);
                const z: i32 = @intCast(cell / 4);
                const dx = (@as(i32, @intCast(column % 3)) - 1) * 4;
                const dz = (@as(i32, @intCast(column / 3)) - 1) * 4;
                const source_x = std.math.clamp(x - dx, 0, 3);
                const source_z = std.math.clamp(z - dz, 0, 3);
                const offset_x = dx + source_x - x;
                const offset_z = dz + source_z - z;
                distances[cell] = @intCast(offset_x * offset_x + offset_z * offset_z);
                entry.cells[cell] = @intCast(source_z * 4 + source_x);
            }
            entry.distance = distances;
        }
        break :blk result;
    };

    fn projectRow(row: [16]u16, column: usize) @Vector(16, u16) {
        return switch (column) {
            inline 0...8 => |index| @shuffle(u16, @as(@Vector(16, u16), row), undefined, mask: {
                var cells: [16]i32 = undefined;
                for (&cells, horizontal[index].cells) |*cell, value| cell.* = value;
                break :mask cells;
            }),
            else => unreachable,
        };
    }

    pub fn projectMany(self: *const BiomeNeighborhood, selection: u32, output: []?section_views.Biomes, cells: [][64]u16) void {
        assert(self.count > 0 and self.count <= section_views.maximum_sections);
        assert(output.len == self.count and cells.len == self.count and @as(u64, selection) >> @intCast(self.count) == 0);
        if (selection == 0) return;
        var cached: Projected = .{ .value = null, .minimum = 0, .maximum = -1 };
        var pending = selection;
        while (pending != 0) : (pending &= pending - 1) {
            const index = @ctz(pending);
            const section: i32 = @intCast(index);
            if (section < cached.minimum or section > cached.maximum) cached = self.project(index, &cells[index]);
            assert(section >= cached.minimum and section <= cached.maximum);
            output[index] = cached.value;
        }
    }

    fn uniformProjection(self: *const BiomeNeighborhood, section: usize) ?Projected {
        var common: ?u16 = null;
        var minimum: i32 = 0;
        var maximum: i32 = @intCast(self.count - 1);
        const bit = @as(u32, 1) << @intCast(section);
        for (self.disclosed, 0..) |mask, column| {
            if (mask == 0) continue;
            const below = mask & (bit - 1);
            const above = mask & ~((bit - 1) | bit);
            const lower: usize = if (below != 0) 31 - @clz(below) else 0;
            const upper: usize = if (above != 0) @ctz(above) else 0;
            var bottom_section: usize = undefined;
            var top_section: usize = undefined;
            if (mask & bit != 0) {
                bottom_section = section;
                top_section = section;
                minimum = @max(minimum, @as(i32, @intCast(section)));
                maximum = @min(maximum, @as(i32, @intCast(section)));
            } else if (below == 0) {
                bottom_section = upper;
                top_section = upper;
                maximum = @min(maximum, @as(i32, @intCast(upper)));
            } else if (above == 0) {
                bottom_section = lower;
                top_section = lower;
                minimum = @max(minimum, @as(i32, @intCast(lower)));
            } else {
                const low = (section - lower) * 4;
                const high = (upper - section) * 4;
                bottom_section = if (low - 3 <= high) lower else upper;
                top_section = if (low <= high - 3) lower else upper;
                minimum = @max(minimum, @as(i32, @intCast(lower)));
                maximum = @min(maximum, @as(i32, @intCast(upper)));
                if (bottom_section == top_section) {
                    const sum: i32 = @intCast((lower + upper) * 4);
                    if (bottom_section == lower) maximum = @min(maximum, @divFloor(sum - 3, 8)) else minimum = @max(minimum, @divFloor(sum + 3, 8) + 1);
                }
            }
            // The nearest vertical source changes monotonically across the four biome rows.
            for ([_]usize{ bottom_section, top_section }) |selected| {
                const values = self.source.get(self.count, column, selected).?;
                if (values != .constant) return null;
                if (common) |value| {
                    if (value != values.constant) return null;
                } else common = values.constant;
            }
        }
        assert(minimum <= @as(i32, @intCast(section)) and maximum >= @as(i32, @intCast(section)));
        return if (common) |value| .{ .value = .{ .constant = value }, .minimum = minimum, .maximum = maximum } else null;
    }

    fn project(self: *const BiomeNeighborhood, section: usize, output: *[64]u16) Projected {
        assert(self.count > 0 and self.count <= section_views.maximum_sections and section < self.count);
        if (self.localProjection(section, output)) |value| return value;
        if (self.uniformProjection(section)) |value| return value;
        var nearest: [9]u32 = undefined;
        const source_bit = @as(u32, 1) << @intCast(section);
        if (self.cache != null) for (self.disclosed, &nearest) |mask, *sources_| {
            if (mask & source_bit != 0) {
                sources_.* = source_bit;
                continue;
            }
            const below = mask & (source_bit - 1);
            const above = mask & ~(source_bit - 1);
            sources_.* = if (below == 0) 0 else @as(u32, 1) << @intCast(31 - @clz(below));
            sources_.* |= above & (0 -% above);
        };
        const entry = if (self.cache) |cache| cache.slot(&nearest, section) else null;
        if (entry) |cached| {
            if (cached.valid and cached.count == self.count and cached.section == section and std.mem.eql(u32, &cached.disclosed, &nearest)) return cached.plan.apply(self, output);
        }
        const Candidate = struct { distance: u14, absolute_y: u7, y: u2 };
        var candidates: [9][4]Candidate = undefined;
        const current: i32 = @intCast(section);
        var minimum: i32 = 0;
        var maximum: i32 = @intCast(self.count - 1);
        var active: u16 = 0;
        const bit = @as(u32, 1) << @intCast(section);
        for (self.disclosed, 0..) |mask, column| {
            assert(@as(u64, mask) >> @intCast(self.count) == 0);
            if (mask == 0) continue;
            active |= @as(u16, 1) << @intCast(column);
            const below = mask & (bit - 1);
            const above = mask & ~((bit - 1) | bit);
            const lower: usize = if (below != 0) 31 - @clz(below) else 0;
            const upper: usize = if (above != 0) @ctz(above) else 0;
            for (0..4) |y| {
                const low_distance = (@as(i32, @intCast(section)) - @as(i32, @intCast(lower))) * 4 + @as(i32, @intCast(y)) - 3;
                const high_distance = (@as(i32, @intCast(upper)) - @as(i32, @intCast(section))) * 4 - @as(i32, @intCast(y));
                const selected = if (mask & bit != 0) section else if (below == 0) upper else if (above == 0 or low_distance <= high_distance) lower else upper;
                const source_y = if (selected < section) 3 else if (selected > section) 0 else y;
                const dy = (@as(i32, @intCast(selected)) - @as(i32, @intCast(section))) * 4 + @as(i32, @intCast(source_y)) - @as(i32, @intCast(y));
                assert(mask & (@as(u32, 1) << @intCast(selected)) != 0);
                const absolute_y: i32 = @intCast(selected * 4 + source_y);
                const local_y: i32 = @intCast(y);
                if (selected == section) {
                    minimum = current;
                    maximum = current;
                } else if (selected < section) {
                    minimum = @max(minimum, -@divFloor(-(absolute_y - local_y), 4));
                    if (above != 0) maximum = @min(maximum, @divFloor(@divFloor(absolute_y + @as(i32, @intCast(upper * 4)), 2) - local_y, 4));
                } else {
                    maximum = @min(maximum, @divFloor(absolute_y - local_y, 4));
                    if (below != 0) minimum = @max(minimum, -@divFloor(-(@divFloor(@as(i32, @intCast(lower * 4 + 3)) + absolute_y, 2) + 1 - local_y), 4));
                }
                candidates[column][y] = .{ .y = @intCast(source_y), .absolute_y = @intCast(absolute_y), .distance = @intCast(dy * dy) };
            }
        }
        assert(minimum <= current and maximum >= current);
        if (active == 0) return .{ .value = null, .minimum = minimum, .maximum = maximum };
        const Distance = @Vector(16, i16);
        comptime {
            const span = section_views.maximum_sections * 4 - 1;
            assert(span * span + 2 * 4 * 4 <= std.math.maxInt(i16));
            assert(span * 8 * (section_views.maximum_sections - 1) <= std.math.maxInt(i16));
        }
        const Columns = @Vector(16, u8);
        var pending: u16 = undefined;
        var plan: Plan = .{ .columns = undefined, .rows = undefined, .active = @splat(0), .minimum = 0, .maximum = 0 };
        var first_y: Distance = undefined;
        for ([_]usize{ 0, 3, 1, 2 }) |y| {
            var distance: Distance = @splat(std.math.maxInt(i16));
            var selected: Columns = @splat(0);
            var selected_y: Distance = @splat(0);
            pending = active;
            while (pending != 0) : (pending &= pending - 1) {
                const column = @ctz(pending);
                const squared = @as(Distance, @intCast(horizontal[column].distance)) + @as(Distance, @splat(candidates[column][y].distance));
                const closer = squared < distance;
                distance = @select(i16, closer, squared, distance);
                selected = @select(u8, closer, @as(Columns, @splat(@intCast(column))), selected);
                selected_y = @select(i16, closer, @as(Distance, @splat(candidates[column][y].absolute_y)), selected_y);
            }
            // Squared-distance differences are linear in section height. Preserve every winner and its tie order.
            if (minimum != maximum) {
                pending = active;
                while (pending != 0) : (pending &= pending - 1) {
                    const column = @ctz(pending);
                    const tied = @as(Columns, @splat(@intCast(column))) < selected;
                    const margin = @as(Distance, @intCast(horizontal[column].distance)) + @as(Distance, @splat(candidates[column][y].distance)) - distance - @as(Distance, @intFromBool(tied));
                    assert(@reduce(.And, margin >= @as(Distance, @splat(0))));
                    const delta = @as(Distance, @splat(candidates[column][y].absolute_y)) - selected_y;
                    const upper = (delta > @as(Distance, @splat(0))) & (margin < delta * @as(Distance, @splat(@intCast(8 * (maximum - current)))));
                    const lower = (delta < @as(Distance, @splat(0))) & (margin < -delta * @as(Distance, @splat(@intCast(8 * (current - minimum)))));
                    var violations: u16 = @bitCast(upper | lower);
                    const margins: [16]i16 = margin;
                    const deltas: [16]i16 = delta;
                    while (violations != 0) : (violations &= violations - 1) {
                        const cell = @ctz(violations);
                        const steps: i32 = @intCast(@as(u32, @intCast(margins[cell])) / (8 * @abs(deltas[cell])));
                        if (deltas[cell] > 0) maximum = @min(maximum, current + steps) else minimum = @max(minimum, current - steps);
                    }
                }
            }
            if (y == 0) first_y = selected_y;
            // A source winning at both vertical endpoints wins between them because squared-distance differences are affine.
            if (y == 3 and @reduce(.And, selected == plan.columns[0]) and @reduce(.And, selected_y == first_y)) {
                plan.plane = true;
                break;
            }
            plan.columns[y] = selected;
            var values: @Vector(16, u16) = @splat(0);
            pending = active;
            while (pending != 0) : (pending &= pending - 1) {
                const column = @ctz(pending);
                if (!@reduce(.Or, selected == @as(Columns, @splat(@intCast(column))))) continue;
                plan.active[y] |= @as(u16, 1) << @intCast(column);
                plan.rows[y][column] = candidates[column][y].absolute_y;
                const candidate = candidates[column][y];
                const row = self.source.get(self.count, column, candidate.absolute_y / 4).?.row(candidate.y);
                const projected = projectRow(row, column);
                const chosen = selected == @as(Columns, @splat(@intCast(column)));
                values = @select(u16, chosen, @as(@Vector(16, u16), projected), values);
            }
            output[y * 16 ..][0..16].* = values;
        }
        assert(minimum <= current and maximum >= current);
        plan.minimum = minimum;
        plan.maximum = maximum;
        if (entry) |cached| cached.* = .{ .valid = true, .disclosed = nearest, .count = @intCast(self.count), .section = @intCast(section), .plan = plan };
        return .{ .value = if (plan.plane) .{ .plane = output[0..16] } else .{ .values = output }, .minimum = minimum, .maximum = maximum };
    }

    fn localProjection(self: *const BiomeNeighborhood, section: usize, output: *[64]u16) ?Projected {
        const mask = self.disclosed[4];
        if (mask == 0) return null;
        const bit = @as(u32, 1) << @intCast(section);
        if (mask & bit != 0) return .{ .value = self.source.get(self.count, 4, section).?, .minimum = @intCast(section), .maximum = @intCast(section) };
        const below = mask & (bit - 1);
        const above = mask & ~(bit - 1);
        const lower_bit = if (below == 0) @as(u32, 0) else @as(u32, 1) << @intCast(31 - @clz(below));
        const upper_bit = above & (0 -% above);
        const gap = (if (upper_bit == 0) std.math.maxInt(u32) else upper_bit - 1) & ~(if (lower_bit == 0) @as(u32, 0) else lower_bit | (lower_bit - 1));
        for (self.disclosed) |neighbor| if (neighbor & gap != 0) return null;
        // Neighbors have no closer vertical source and always have positive horizontal distance.
        const lower: usize = if (below == 0) 0 else 31 - @clz(below);
        const upper: usize = if (above == 0) 0 else @ctz(above);
        const bottom = if (below == 0) upper else if (above == 0 or (section - lower) * 4 - 3 <= (upper - section) * 4) lower else upper;
        const top = if (below == 0) upper else if (above == 0 or (section - lower) * 4 <= (upper - section) * 4 - 3) lower else upper;
        var minimum: i32 = if (below == 0) 0 else @intCast(lower + 1);
        var maximum: i32 = if (above == 0) @intCast(self.count - 1) else @intCast(upper - 1);
        if (below != 0 and above != 0) {
            const sum: i32 = @intCast((lower + upper) * 4);
            if (bottom != top) {
                minimum = @intCast(section);
                maximum = @intCast(section);
            } else if (bottom == lower) maximum = @min(maximum, @divFloor(sum - 3, 8)) else minimum = @max(minimum, @divFloor(sum + 3, 8) + 1);
        }
        assert(minimum <= section and maximum >= section);
        const first_biome = self.source.get(self.count, 4, bottom).?;
        if (bottom == top and first_biome == .constant) return .{ .value = first_biome, .minimum = minimum, .maximum = maximum };
        if (bottom == top) {
            output[0..16].* = first_biome.row(if (bottom < section) 3 else 0);
            return .{ .value = .{ .plane = output[0..16] }, .minimum = minimum, .maximum = maximum };
        }
        const last_biome = if (bottom == top) first_biome else self.source.get(self.count, 4, top).?;
        for (0..4) |y| {
            const selected = if (below == 0) upper else if (above == 0 or (section - lower) * 4 + y - 3 <= (upper - section) * 4 - y) lower else upper;
            const source_y: u2 = if (selected < section) 3 else 0;
            output[y * 16 ..][0..16].* = (if (selected == bottom) first_biome else last_biome).row(source_y);
        }
        return .{ .value = .{ .values = output }, .minimum = minimum, .maximum = maximum };
    }
};

pub fn materialProperties(allocator: std.mem.Allocator, blocks: *const BlockProperties) ![]const u8 {
    const properties = try allocator.alloc(u8, game_data.registry.block_state_to_block.len);
    for (properties, 0..) |*value, state| value.* = @as(u8, @intFromBool(isAir(@intCast(state)))) |
        (@as(u8, @intFromBool(game_data.registry.stateContainsFluid(@intCast(state)))) << 1) |
        (@as(u8, @intFromBool(blocks.entityName(@intCast(state)) != null)) << 2);
    return properties;
}

pub const Sections = union(enum) {
    pub const Baked = struct { view: *const chunks.Light.View };
    loaded: []const section_views.Section,
    baked: Baked,

    pub fn count(self: Sections) usize {
        return switch (self) {
            .loaded => |values| values.len,
            .baked => |value| value.view.header.count,
        };
    }

    /// `generation` names the preparation that reads a baked frame.
    fn metadata(self: Sections, output: []section_views.Section, biome_selection: u32, generation: u64) []const section_views.Section {
        if (self == .loaded) return self.loaded;
        const view = self.baked.view;
        assert(output.len >= view.header.count);
        for (output[0..view.header.count], 0..) |*section, index| {
            const uniform = view.header.uniform & (@as(u32, 1) << @intCast(index)) != 0;
            const state = view.header.states[index];
            section.* = if (uniform) .{ .stamp = .{ .constant = state }, .view = .{ .uniform = state } } else .{ .stamp = .{ .generation = generation, .index = index, .storage = .baked }, .view = .unavailable };
            section.biomes = if (biome_selection & (@as(u32, 1) << @intCast(index)) == 0) null else if (view.biome(4, index)) |biome| switch (biome) {
                .uniform => |value| .{ .constant = value },
                .dense => |bytes| .{ .encoded = .{ .bytes = bytes } },
                .palette => |values| .{ .palette = values },
            } else null;
        }
        return output[0..view.header.count];
    }
};

pub const Chunk = struct {
    world: u32 = 0,
    x: i32,
    z: i32,
    sections: Sections,
    biome: i32,
    minimum_section: i32,
    workspace: *Workspace,
    light: lighting.Data,
    disclosure: u32 = std.math.maxInt(u32),
    biome_disclosure: u32 = std.math.maxInt(u32),
    biome_neighbors: ?*const BiomeNeighborhood = null,
    concealment: u16 = 0,
    frontier: u32 = 0,
};

pub const Prepared = struct {
    chunk: Chunk,
    sections: []const section_views.Section,
    maximum_size: usize,
    preparation: u64,
};

/// Source frames and encoding workspaces remain borrowed until this packet is encoded.
pub const Delivery = struct {
    packet: Prepared,
    encoding: union(enum) { uniform, record: chunks.Delivery.View },
    owner: *delivery_cache.Workspace,
    generation: u64,

    pub fn maximumSize(self: *const Delivery) usize {
        return self.packet.maximum_size;
    }

    pub fn writePacket(self: *const Delivery, frontend: *packets.Packets, protocol: i32, packet: *sessions.Service.Packet, definition: *const sessions.Protocol) ![]u8 {
        const workspace = self.packet.chunk.workspace;
        assert(workspace.preparation == self.packet.preparation and self.owner.active and self.owner.generation == self.generation);
        const compressed = try frontend.writePacket(write_delivery, protocol, packet.bytes, .{ self, definition });
        packet.prepare(workspace.fragments.decoded);
        return compressed;
    }
};

pub const write = .{ writeLegacy, writeFluidCount };

const Trace = struct {
    const Span = struct { start: usize, end: usize };
    const Section = struct { header: Span, words: Span, biome: Span, entities: Span, entity_count: u16 };
    sections: [section_views.maximum_sections]Section = undefined,
};

fn deliverySpace(cache: *const delivery_cache.Workspace) error{ DeliveryDeferred, DeliveryRecordTooLarge } {
    return if (cache.used == 0) error.DeliveryRecordTooLarge else error.DeliveryDeferred;
}

fn appendCompiled(cache: *delivery_cache.Workspace, writer: *chunks.Delivery.Writer, trace: *const Trace, plain: []const u8, index: usize, comptime component: chunks.Delivery.Component, span: Trace.Span) !void {
    const bytes = plain[span.start..span.end];
    assert(bytes.len > 0);
    for (trace.sections[0..index], 0..) |section, previous| {
        const candidate = switch (component) {
            .header => section.header,
            .words => section.words,
            .biome => section.biome,
        };
        if (candidate.end - candidate.start != bytes.len or !std.mem.eql(u8, bytes, plain[candidate.start..candidate.end])) continue;
        if (writer.reuse(index, component, previous)) return;
    }
    const fragment = try cache.baker.encode(bytes, cache.fragment);
    writer.append(index, component, fragment) catch return deliverySpace(cache);
}

fn storedHeightmap(chunk: Chunk) ?chunks.Light.Heightmap {
    if (chunk.frontier != 0 or chunk.sections != .baked) return null;
    const view = chunk.sections.baked.view;
    const heightmap = view.heightmap orelse return null;
    if (heightmap.sections & ~chunk.disclosure != 0) return null;
    const all: u32 = @truncate((@as(u64, 1) << @intCast(view.header.count)) - 1);
    if (!isAir(chunk.concealment) and chunk.disclosure & all != all) return null;
    return heightmap;
}

const write_delivery = .{ writeLegacyDelivery, writeFluidDelivery };

fn writeLegacyDelivery(packet: wire_1_21_5.play.toClient.packet_map_chunk.Writer, registry: packets.Registry, prepared: *const Delivery, protocol: *const sessions.Protocol) ![]u8 {
    return encodeDelivery(packet._cursor, registry, prepared, protocol, false);
}

fn writeFluidDelivery(packet: wire_26_1.play.toClient.packet_map_chunk.Writer, registry: packets.Registry, prepared: *const Delivery, protocol: *const sessions.Protocol) ![]u8 {
    return encodeDelivery(packet._cursor, registry, prepared, protocol, true);
}

fn encodeDelivery(cursor: support.cursor.State(.write), registry: packets.Registry, delivery: *const Delivery, protocol: *const sessions.Protocol, comptime fluids: bool) ![]u8 {
    assert(delivery.owner.active and delivery.owner.generation == delivery.generation);
    const prepared = &delivery.packet;
    const chunk = prepared.chunk;
    const workspace = chunk.workspace;
    assert(workspace.preparation == prepared.preparation);
    const record: ?chunks.Delivery.View = switch (delivery.encoding) {
        .uniform => null,
        .record => |value| value,
    };
    if (record) |value| assert(value.count == prepared.sections.len);
    const mapping = try workspace.mapping(protocol);
    const prefix = cursor.buffer.len - cursor.rest.len;
    var header: [5]u8 = undefined;
    assert(prefix <= header.len);
    @memcpy(header[0..prefix], cursor.buffer[0..prefix]);
    const stream = &workspace.fragments;
    stream.* = try .begin(cursor.buffer);
    const writer = &stream.writer;
    try writer.writeAll(header[0..prefix]);
    try writer.writeInt(i32, chunk.x, .big);
    try writer.writeInt(i32, chunk.z, .big);
    const heightmap = storedHeightmap(chunk);
    const column = if (heightmap == null) workspace.prepareColumn(prepared.sections) else null;
    try varint(writer, 2);
    for ([_]i32{ 1, 4 }) |kind| {
        try varint(writer, kind);
        try varint(writer, @intCast(chunks.Prepared.Heightmap.wordCount(prepared.sections.len)));
        if (heightmap) |value| try stream.append(value.words) else try writer.writeAll(column.?.heightmap[0..column.?.heightmap_bytes]);
    }
    const length_field = try stream.placeholder(&.{ 0, 0, 0 });
    const start = stream.count();
    var index: usize = 0;
    while (index < prepared.sections.len) : (index += 1) {
        const section = prepared.sections[index];
        if (section.view == .uniform) {
            const biome: ?u16 = if (section.biomes) |values| if (values == .constant) values.constant else null else @intCast(chunk.biome);
            if (biome) |value| {
                var end = index + 1;
                while (end < prepared.sections.len) : (end += 1) {
                    const next = prepared.sections[end];
                    const next_biome: ?u16 = if (next.biomes) |values| if (values == .constant) values.constant else null else @intCast(chunk.biome);
                    if (next.view != .uniform or next.view.uniform != section.view.uniform or next_biome == null or next_biome.? != value) break;
                }
                if (end - index > 1) {
                    var bytes: [16]u8 = undefined;
                    var pattern: std.Io.Writer = .fixed(&bytes);
                    try writeUniformBlock(&pattern, registry, section.view.uniform, fluids);
                    try pattern.writeByte(0);
                    try varint(&pattern, try mapping.biome(protocol, value));
                    if (workspace.section_runs.get(&workspace.uniform_light.baker, pattern.buffered(), end - index)) |fragment| {
                        try stream.append(fragment);
                    } else try writer.splatBytesAll(pattern.buffered(), end - index);
                    index = end - 1;
                    continue;
                }
            }
        }
        const bit = @as(u32, 1) << @intCast(index);
        const selected_record = if (record) |value| value.section(index) else null;
        if (section.view == .uniform) {
            const state = section.view.uniform;
            try writeUniformBlock(writer, registry, state, fluids);
        } else {
            const selected_record_value = selected_record.?;
            var fragments: [3]deflate.fragments.Fragment = undefined;
            fragments[0] = selected_record_value.header;
            var count: usize = 1;
            if (selected_record_value.words) |words| {
                fragments[count] = words;
                count += 1;
            } else if (chunk.sections == .baked and chunk.sections.baked.view.header.uniform & bit == 0) {
                const terrain = chunk.sections.baked.view.terrain[index].?.view();
                assert(terrain.bits != 16);
                fragments[count] = terrain.words;
                count += 1;
            }
            if (chunk.biome_disclosure & bit != 0 and selected_record_value.biome != null) {
                fragments[count] = selected_record_value.biome.?;
                count += 1;
                try stream.appendMany(fragments[0..count], selected_record_value.full_digest);
                continue;
            }
            try stream.appendMany(fragments[0..count], selected_record_value.terrain_digest);
        }
        if (chunk.biome_disclosure & bit != 0 and selected_record != null and selected_record.?.biome != null) {
            try stream.append(selected_record.?.biome.?);
        } else if (section.biomes) |values| {
            try writeBiomes(writer, values, protocol, mapping, workspace);
        } else {
            try writer.writeByte(0);
            try varint(writer, try mapping.biome(protocol, @intCast(chunk.biome)));
        }
    }
    const length = stream.count() - start;
    const length_bytes: [3]u8 = .{ @as(u8, @truncate(length & 127)) | 128, @as(u8, @truncate(length >> 7 & 127)) | 128, @intCast(length >> 14) };
    stream.patch(length_field, &length_bytes);
    var entity_sections = (if (record) |value| value.entity_sections else 0) & chunk.disclosure & ~chunk.frontier;
    var entity_count: i32 = 0;
    var remaining = entity_sections;
    while (remaining != 0) : (remaining &= remaining - 1) entity_count += record.?.section(@ctz(remaining)).entity_count;
    try varint(writer, entity_count);
    while (entity_sections != 0) : (entity_sections &= entity_sections - 1) try writer.writeAll(record.?.section(@ctz(entity_sections)).entities);
    var light = chunk.light;
    light.disclosure &= chunk.disclosure;
    try light.writeFragments(stream, workspace.uniform_light);
    assert(stream.count() <= prepared.maximum_size);
    return stream.finish();
}

fn writeUniformBlock(writer: *std.Io.Writer, registry: packets.Registry, state: u16, comptime fluids: bool) !void {
    try writer.writeInt(u16, if (isAir(state)) 0 else 4096, .big);
    if (fluids) try writer.writeInt(u16, if (game_data.registry.stateContainsFluid(state)) 4096 else 0, .big);
    try writer.writeByte(0);
    try varint(writer, try registry.blockState(state));
}

fn writeLegacy(packet: wire_1_21_5.play.toClient.packet_map_chunk.Writer, registry: packets.Registry, prepared: *const Prepared, protocol: *const sessions.Protocol) ![]u8 {
    return encode(packet._cursor, registry, prepared, protocol, false);
}

fn writeFluidCount(packet: wire_26_1.play.toClient.packet_map_chunk.Writer, registry: packets.Registry, prepared: *const Prepared, protocol: *const sessions.Protocol) ![]u8 {
    return encode(packet._cursor, registry, prepared, protocol, true);
}

// The schema exposes chunkData as opaque bytes, so section encoding must handle the 26.1 fluid count.
fn encode(cursor: support.cursor.State(.write), registry: packets.Registry, prepared: *const Prepared, protocol: *const sessions.Protocol, comptime write_fluid_count: bool) ![]u8 {
    return encodeTraced(cursor, registry, prepared, protocol, write_fluid_count, null);
}

fn encodeTraced(cursor: support.cursor.State(.write), registry: packets.Registry, prepared: *const Prepared, protocol: *const sessions.Protocol, comptime write_fluid_count: bool, trace: ?*Trace) ![]u8 {
    const chunk = prepared.chunk;
    assert(chunk.workspace.preparation == prepared.preparation);
    const x = chunk.x;
    const z = chunk.z;
    const sections = prepared.sections;
    assert(chunk.light.count == sections.len + 2);
    // Retention must describe the final disclosure encoded below.
    assert((chunk.light.retained[0] | chunk.light.retained[1]) == 0 or
        chunk.light.disclosure & ~chunk.disclosure & ((@as(u32, 1) << @intCast(sections.len)) - 1) == 0);
    const biome = chunk.biome;
    if (biome < 0 or biome >= game_data.registry.biome_names.len) return error.UnsupportedBiome;
    const mapping = try chunk.workspace.mapping(protocol);
    const wire_biome = try mapping.biome(protocol, @intCast(biome));
    const output = cursor.buffer;
    var plain: std.Io.Writer = .fixed(output);
    plain.end = output.len - cursor.rest.len;
    const writer = &plain;
    if (trace == null) {
        try writer.writeInt(i32, x, .big);
        try writer.writeInt(i32, z, .big);
    }
    const workspace = chunk.workspace;
    if (trace == null) {
        const column = workspace.prepareColumn(sections);
        try varint(writer, 2);
        for ([_]i32{ 1, 4 }) |kind| {
            try varint(writer, kind);
            try varint(writer, @intCast(chunks.Prepared.Heightmap.wordCount(sections.len)));
            try writer.writeAll(column.heightmap[0..column.heightmap_bytes]);
        }
    }

    const length_offset = writer.end;
    try writer.splatByteAll(0, 3);
    const data_start = writer.end;
    const palette_indices = &workspace.palette_indices;

    var section_cursor: usize = 0;
    while (section_cursor < sections.len) : (section_cursor += 1) {
        const traced: ?*Trace.Section = if (trace) |value| &value.sections[section_cursor] else null;
        if (traced) |value| value.header.start = writer.end;
        const snapshot = &sections[section_cursor];
        const summary = workspace.summaryAt(section_cursor);
        const section: section_views.Section.View = if (summary.baked != null) .unavailable else snapshot.view;
        const count = summary.state.count;
        const fluid_count = summary.state.fluid_count;
        const palette_len: usize = summary.state.palette_len;
        const palette = &summary.palette;
        const direct = summary.state.direct;
        if (trace == null and section == .uniform) {
            const uniform_biome: ?u16 = if (snapshot.biomes) |values| if (values == .constant) values.constant else null else @intCast(biome);
            if (uniform_biome) |value| {
                var end = section_cursor + 1;
                while (end < sections.len) : (end += 1) {
                    const next = sections[end];
                    if (next.view != .uniform or next.view.uniform != section.uniform) break;
                    const next_biome: ?u16 = if (next.biomes) |values| if (values == .constant) values.constant else null else @intCast(biome);
                    if (next_biome == null or next_biome.? != value) break;
                }
                if (end - section_cursor > 1) {
                    var bytes: [16]u8 = undefined;
                    var uniform: std.Io.Writer = .fixed(&bytes);
                    try uniform.writeInt(u16, count, .big);
                    if (write_fluid_count) try uniform.writeInt(u16, fluid_count, .big);
                    try uniform.writeByte(0);
                    try varint(&uniform, try registry.blockState(section.uniform));
                    try uniform.writeByte(0);
                    try varint(&uniform, try mapping.biome(protocol, value));
                    try writer.splatBytesAll(uniform.buffered(), end - section_cursor);
                    section_cursor = end - 1;
                    continue;
                }
            }
        }
        const indexed = !direct and section != .unavailable and section != .uniform and !(section == .encoded and section.encoded.paletteCount() == palette_len);
        if (indexed) for (palette[0..palette_len], 0..) |state, index| {
            palette_indices[state] = @intCast(index);
        };
        defer if (indexed) {
            for (palette[0..palette_len]) |state| palette_indices[state] = std.math.maxInt(u16);
        };

        try writer.writeInt(u16, count, .big);
        if (write_fluid_count) try writer.writeInt(u16, fluid_count, .big);

        if (palette_len == 1 and !direct) {
            try writer.writeByte(0);
            try varint(writer, try registry.blockState(section.get(0)));
            if (traced) |value| {
                value.header.end = writer.end;
                value.words = .{ .start = writer.end, .end = writer.end };
            }
        } else {
            const bits: u8 = if (direct) registry.block_state_bits else @intCast(@max(4, std.math.log2_int_ceil(usize, palette_len)));
            try writer.writeByte(bits);

            if (!direct) {
                try varint(writer, @intCast(palette_len));

                const bytes = try writer.writableSliceGreedy(palette_len * 5);
                var used: usize = 0;
                for (0..palette_len) |rank| {
                    var number: u32 = @bitCast(try registry.blockState(summary.paletteState(rank)));
                    while (number >= 128) : (number >>= 7) {
                        bytes[used] = @as(u8, @truncate(number & 127)) | 128;
                        used += 1;
                    }
                    bytes[used] = @intCast(number);
                    used += 1;
                }
                writer.advance(used);
            }

            if (traced) |value| {
                value.header.end = writer.end;
                value.words.start = writer.end;
            }
            if (section == .unavailable) {
                const baked = summary.baked.?.*;
                if (!direct) {
                    assert(bits == baked.bits);
                    if (trace == null) {
                        const destination = try writer.writableSlice(baked.words.decoded);
                        _ = try workspace.word_decoder.decode(baked.words, destination);
                    }
                } else {
                    _ = try workspace.word_decoder.decode(baked.words, &workspace.direct_words);
                    const per_word: usize = 64 / bits;
                    for (0..(4096 + per_word - 1) / per_word) |word| {
                        var value: u64 = 0;
                        for (0..per_word) |lane| {
                            const cell = word * per_word + lane;
                            if (cell >= 4096) break;
                            const state = std.mem.readInt(u16, workspace.direct_words[cell * 2 ..][0..2], .big);
                            value |= @as(u64, @intCast(try registry.blockState(state))) << @intCast(lane * bits);
                        }
                        try writer.writeInt(u64, value, .big);
                    }
                }
            } else if (section == .encoded and !direct and section.encoded.paletteCount() == palette_len) {
                switch (bits) {
                    inline 4, 5, 6, 7, 8 => |width| try writePacked(writer, section.encoded, width),
                    else => unreachable,
                }
            } else if (bits == 4 and !direct) {
                try writePaletted4(writer, section, palette_indices, @intCast(palette_len));
            } else {
                const per_word: usize = 64 / bits;
                for (0..(4096 + per_word - 1) / per_word) |word| {
                    var value: u64 = 0;

                    for (0..per_word) |i| {
                        const index = word * per_word + i;

                        if (index < 4096) {
                            const state = section.get(@intCast(index));
                            const encoded: u32 = if (direct) @intCast(try registry.blockState(state)) else palette_indices[state];
                            assert(direct or encoded < palette_len);
                            value |= @as(u64, encoded) << @intCast(i * bits);
                        }
                    }

                    try writer.writeInt(u64, value, .big);
                }
            }
            if (traced) |value| value.words.end = writer.end;
        }

        if (traced) |value| value.biome.start = writer.end;
        if (snapshot.biomes) |values| {
            try writeBiomes(writer, values, protocol, mapping, workspace);
        } else {
            try writer.writeByte(0);
            try varint(writer, wire_biome);
        }
        if (traced) |value| value.biome.end = writer.end;
    }

    const length: u32 = @intCast(writer.end - data_start);
    var length_bytes: [3]u8 = undefined;
    length_bytes[0] = @as(u8, @truncate(length & 127)) | 128;
    length_bytes[1] = @as(u8, @truncate((length >> 7) & 127)) | 128;
    length_bytes[2] = @intCast(length >> 14);
    @memcpy(output[length_offset..][0..3], &length_bytes);
    var entities: usize = 0;
    for (0..sections.len) |index| entities += workspace.summaryAt(index).state.block_entities;
    try varint(writer, @intCast(entities));
    for (sections, 0..) |section, section_index| {
        const summary = workspace.summaryAt(section_index);
        if (trace) |value| {
            value.sections[section_index].entities = .{ .start = writer.end, .end = writer.end };
            value.sections[section_index].entity_count = summary.state.block_entities;
        }
        if (summary.state.block_entities == 0) continue;
        if (summary.baked) |baked| {
            for (0..baked.entities.len / 4) |entity| {
                const index = std.mem.readInt(u16, baked.entities[entity * 4 ..][0..2], .little);
                const state = std.mem.readInt(u16, baked.entities[entity * 4 + 2 ..][0..2], .little);
                const name = workspace.blocks.entityName(state) orelse return error.UnsupportedBlockEntity;
                try writer.writeByte(@intCast(((index % 16) << 4) | ((index / 16) % 16)));
                try writer.writeInt(i16, @intCast((chunk.minimum_section + @as(i32, @intCast(section_index))) * 16 + @as(i32, @intCast(index / 256))), .big);
                try varint(writer, try protocol.registryId("minecraft:block_entity_type", name));
                try writer.writeAll(&.{ 10, 0 });
            }
            if (trace) |value| value.sections[section_index].entities.end = writer.end;
            continue;
        }
        for (workspace.summaryAt(section_index).entities, 0..) |word, at| {
            var remaining = word;
            while (remaining != 0) {
                const index = at * 64 + @ctz(remaining);
                remaining &= remaining - 1;
                const name = workspace.blocks.entityName(section.view.get(@intCast(index))).?;
                try writer.writeByte(@intCast(((index % 16) << 4) | ((index / 16) % 16)));
                try writer.writeInt(i16, @intCast((chunk.minimum_section + @as(i32, @intCast(section_index))) * 16 + @as(i32, @intCast(index / 256))), .big);
                try varint(writer, try protocol.registryId("minecraft:block_entity_type", name));
                try writer.writeAll(&.{ 10, 0 });
            }
        }
        if (trace) |value| value.sections[section_index].entities.end = writer.end;
    }
    if (trace != null) return output[0..writer.end];
    var light = chunk.light;
    light.disclosure &= chunk.disclosure;
    try light.write(writer);
    assert(writer.end <= prepared.maximum_size);
    return output[0..writer.end];
}

fn writePaletted4(writer: *std.Io.Writer, view: section_views.Section.View, palette: *const [1 << game_data.registry.block_state_bits]u16, count: u16) !void {
    assert(count >= 2 and count <= 16);
    const output = try writer.writableSlice(256 * 8);
    for (0..256) |row| {
        const states = view.row(@intCast(row));
        var ranks: @Vector(16, u16) = undefined;
        inline for (0..16) |lane| ranks[lane] = palette[states[lane]];
        assert(@reduce(.Max, ranks) < count);
        var word: u64 = 0;
        inline for (0..16) |lane| word |= @as(u64, ranks[lane]) << (4 * lane);
        std.mem.writeInt(u64, output[row * 8 ..][0..8], word, .big);
    }
}

fn writePacked(writer: *std.Io.Writer, view: chunks.encoding.Packed, comptime bits: u8) !void {
    if (bits == 4) {
        const output = try writer.writableSlice(2048);
        for (0..64) |group| {
            const words: @Vector(4, u64) = view.nibbles(@intCast(group));
            const wire_words = if (builtin.cpu.arch.endian() == .little) @byteSwap(words) else words;
            @memcpy(output[group * 32 ..][0..32], std.mem.asBytes(&wire_words));
        }
        return;
    }
    const per_word: usize = 64 / bits;
    const count = (4096 + per_word - 1) / per_word;
    const output = try writer.writableSlice(count * 8);
    var row: usize = 128;
    var ranks: [32]u16 = undefined;
    for (0..count) |word| {
        var value: u64 = 0;
        inline for (0..per_word) |lane| {
            const index = word * per_word + lane;
            if (index < 4096) {
                if (index / ranks.len != row) {
                    row = index / ranks.len;
                    ranks = view.ranks(@intCast(row));
                }
                value |= @as(u64, ranks[index % ranks.len]) << (lane * bits);
            }
        }
        std.mem.writeInt(u64, output[word * 8 ..][0..8], value, .big);
    }
}

fn varint(writer: *std.Io.Writer, value: i32) !void {
    var number: u32 = @bitCast(value);

    while (number >= 128) : (number >>= 7) try writer.writeByte(@as(u8, @truncate(number & 127)) | 128);
    try writer.writeByte(@intCast(number));
}

/// Block properties for tests, with block entities in chests and furnaces as vanilla
/// content defines them. Encoding reads no light.
fn testBlocks(allocator: std.mem.Allocator) !*BlockProperties {
    const count = game_data.registry.block_state_to_block.len;
    const light = try allocator.alloc(light_engine.Properties, count);
    @memset(light, .{ .opacity = 0, .emission = 0, .faces = @splat(0) });
    const entities = try allocator.alloc(?u8, count);
    const chest = game_data.registry.block_state_to_block[game_data.registry.block_chest_default_state];
    const furnace = game_data.registry.block_state_to_block[game_data.registry.block_furnace_default_state];
    for (entities, 0..) |*entity, state| {
        const block = game_data.registry.block_state_to_block[state];
        entity.* = if (block == chest) 0 else if (block == furnace) 1 else null;
    }
    const blocks = try allocator.create(BlockProperties);
    blocks.* = .init(.{ .states = light, .faces = 1, .occlusion = &.{0} }, entities, &.{ "minecraft:chest", "minecraft:furnace" });
    return blocks;
}

test "stored bitplanes produce protocol words without changing block states" {
    var raw: [chunks.encoding.maximum_decoded_bytes]u8 = undefined;
    var storage_bytes: [chunks.encoding.maximum_decoded_bytes]u8 = undefined;
    var actual: [8192]u8 = undefined;
    raw[0] = 1;
    inline for (.{ 4, 5, 6, 7, 8 }) |bits| {
        for ([_]usize{ (@as(usize, 1) << (bits - 1)) + 1, @as(usize, 1) << bits }) |count| {
            for (0..4096) |index| std.mem.writeInt(u16, raw[1 + index * 2 ..][0..2], @intCast((index * 31 + index / 19) % count), .little);
            const bytes = try chunks.encoding.encode(raw[0..chunks.encoding.dense_block_bytes], &storage_bytes);
            const view = try chunks.encoding.Packed.init(bytes);
            var writer: std.Io.Writer = .fixed(&actual);
            try writePacked(&writer, view, bits);
            const per_word = 64 / bits;
            for (0..4096) |index| {
                const word = std.mem.readInt(u64, actual[index / per_word * 8 ..][0..8], .big);
                const rank = (word >> @intCast(index % per_word * bits)) & ((@as(u64, 1) << bits) - 1);
                try std.testing.expectEqual(view.get(@intCast(index)), view.state(@intCast(rank)));
            }
        }
    }
}

test "four bit packet words match scalar encoding for every section layout" {
    const dense = try std.testing.allocator.alloc(u16, 4096);
    defer std.testing.allocator.free(dense);
    const strided = try std.testing.allocator.alloc(u16, 16 * 48 * 48);
    defer std.testing.allocator.free(strided);
    const palette = try std.testing.allocator.create([1 << game_data.registry.block_state_bits]u16);
    defer std.testing.allocator.destroy(palette);
    @memset(palette, std.math.maxInt(u16));
    var chunk: [8193]u8 = undefined;
    chunk[0] = 1;
    var actual: [2048]u8 = undefined;
    var expected: [2048]u8 = undefined;
    for ([_]u16{ 2, 3, 8, 16 }) |count| {
        for (0..count) |rank| palette[200 + rank * 17] = count - 1 - @as(u16, @intCast(rank));
        for (dense, 0..) |*value, index| {
            value.* = @intCast(200 + ((index * 331 + index / 17) % count) * 17);
            strided[index / 256 * 48 * 48 + index / 16 % 16 * 48 + index % 16] = value.*;
            std.mem.writeInt(u16, chunk[1 + index * 2 ..][0..2], value.*, .little);
        }
        for ([_]section_views.Section.View{ .{ .dense = dense[0..4096] }, .{ .rows = strided }, .{ .chunk = .{ .dense = chunk[1..] } }, .{ .uniform = 200 } }) |view| {
            for (0..256) |word| {
                var encoded: u64 = 0;
                for (0..16) |lane| encoded |= @as(u64, palette[view.get(@intCast(word * 16 + lane))]) << @intCast(lane * 4);
                std.mem.writeInt(u64, expected[word * 8 ..][0..8], encoded, .big);
            }
            var writer: std.Io.Writer = .fixed(&actual);
            try writePaletted4(&writer, view, palette, count);
            try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
        }
    }
}

test "biome padding preserves edges corners and vertical variation against exhaustive cell distances" {
    const count = 3;
    var values: [9][count][64]u16 = undefined;
    var sections: [9 * count]?section_views.Biomes = undefined;
    const fixed_cases = [_][9]u32{
        .{ 0, 0, 0, 7, 0, 7, 0, 0, 0 },
        .{ 7, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 5, 0, 0, 0, 0 },
        .{ 1, 0, 4, 0, 0, 0, 0, 2, 0 },
    };
    var cases: [36][9]u32 = undefined;
    @memcpy(cases[0..fixed_cases.len], &fixed_cases);
    var random = std.Random.DefaultPrng.init(0x3141b10);
    for (cases[fixed_cases.len..]) |*masks| {
        for (masks) |*mask| mask.* = random.random().int(u3);
    }
    var projection_cache: BiomeNeighborhood.Cache = .{};
    for (0..3) |mode| {
        for (&values, 0..) |*column, xz| for (column, 0..) |*cells, y| {
            for (cells, 0..) |*cell, index| cell.* = if (mode == 0) @intCast(xz * 1000 + y * 100 + index) else if (mode == 1) 7 else @intCast(xz * 1000 + y * 100);
            sections[xz * count + y] = if (mode == 0) .{ .values = cells } else .{ .constant = cells[0] };
        };
        for (cases) |disclosed| {
            const neighborhood: BiomeNeighborhood = .{ .count = count, .source = .{ .loaded = &sections }, .disclosed = disclosed, .cache = &projection_cache };
            var actual: [count][64]u16 = undefined;
            var projected: [count]?section_views.Biomes = undefined;
            for (0..2) |_| neighborhood.projectMany(7, &projected, &actual);
            for (0..count) |target_section| {
                for (0..64) |target| {
                    const biome = projected[target_section].?.get(@intCast(target));
                    const x: i32 = @intCast(target % 4);
                    const y: i32 = @intCast(target_section * 4 + target / 16);
                    const z: i32 = @intCast(target / 4 % 4);
                    var expected: ?u16 = null;
                    var nearest: i32 = std.math.maxInt(i32);
                    for (disclosed, 0..) |mask, column| for (0..count) |section| {
                        if (mask & (@as(u32, 1) << @intCast(section)) == 0) continue;
                        for (0..64) |source| {
                            const dx = (@as(i32, @intCast(column % 3)) - 1) * 4 + @as(i32, @intCast(source % 4)) - x;
                            const dy = @as(i32, @intCast(section * 4 + source / 16)) - y;
                            const dz = (@as(i32, @intCast(column / 3)) - 1) * 4 + @as(i32, @intCast(source / 4 % 4)) - z;
                            const distance = dx * dx + dy * dy + dz * dz;
                            if (distance >= nearest) continue;
                            nearest = distance;
                            expected = values[column][section][source];
                        }
                    };
                    try std.testing.expectEqual(expected.?, biome);
                }
            }
        }
    }
    const empty: BiomeNeighborhood = .{ .count = count, .source = .{ .loaded = &sections }, .disclosed = @splat(0) };
    var output: [64]u16 = @splat(65535);
    try std.testing.expect(empty.project(1, &output).value == null);
    try std.testing.expect(empty.first() == null);
    for (output) |biome| try std.testing.expectEqual(@as(u16, 65535), biome);
}

test "concealed sections borrow the nearest disclosed biome without exposing hidden biomes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workspace = try Workspace.init(arena.allocator(), 1 << 20, &.{.{ .number = 0 }}, try testBlocks(arena.allocator()));
    var biomes: [5][64]u16 = undefined;
    var sections: [5]section_views.Section = undefined;
    for (&sections, &biomes, 0..) |*section, *values, index| {
        @memset(values, @intCast(index));
        section.* = .{ .stamp = .{ .generation = index + 1, .constant = 1 }, .view = .{ .uniform = 1 }, .biomes = .{ .values = values } };
    }
    var chunk: Chunk = .{ .x = 0, .z = 0, .minimum_section = -4, .sections = .{ .loaded = &sections }, .biome = 0, .workspace = workspace, .light = undefined, .disclosure = 17 };
    const covered = workspace.representation(chunk);
    try workspace.prepareSections(covered);
    for (covered, 0..) |section, index| {
        const expected: usize = if (index <= 2) 0 else 4;
        try std.testing.expect(section.biomes.?.values == &biomes[expected]);
        try std.testing.expectEqual(@as(u16, if (index == 0 or index == 4) 1 else 0), section.view.get(0));
        try std.testing.expectEqual(@as(u16, if (index == 0 or index == 4) 4096 else 0), workspace.summaryAt(index).state.count);
    }
    chunk.disclosure = 0;
    for (workspace.representation(chunk)) |section| try std.testing.expect(section.biomes == null);
    chunk.disclosure = 31;
    for (workspace.representation(chunk), &biomes) |section, *values| try std.testing.expect(section.biomes.?.values == values);
    chunk.biome_disclosure = 0;
    for (workspace.representation(chunk)) |section| {
        try std.testing.expect(section.biomes == null);
        try std.testing.expectEqual(@as(u16, 1), section.view.get(0));
    }
    chunk.biome_disclosure = 16;
    for (workspace.representation(chunk)) |section| try std.testing.expect(section.biomes.?.values == &biomes[4]);
}

test "all vanilla air variants have empty section counts and heightmaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workspace = try Workspace.init(arena.allocator(), 1 << 20, &.{.{ .number = 0 }}, try testBlocks(arena.allocator()));
    var sections: [3]section_views.Section = undefined;
    for (&sections, [_]u16{ @intCast(game_data.registry.block_air_default_state), @intCast(game_data.registry.block_cave_air_default_state), @intCast(game_data.registry.block_void_air_default_state) }, 0..) |*section, state, index| {
        section.* = .{ .stamp = .{ .generation = index + 1 }, .view = .{ .uniform = state } };
    }
    try workspace.prepareSections(&sections);
    for (workspace.summaries[0..sections.len]) |summary| {
        try std.testing.expectEqual(@as(u16, 0), summary.state.count);
        for (summary.heights) |height| try std.testing.expectEqual(@as(u8, 0), height);
    }
    const states = try arena.allocator().alloc(u16, 16 * 48 * 48);
    @memset(states, @intCast(game_data.registry.block_void_air_default_state));
    sections[0].view = .{ .rows = states };
    sections[0].stamp.revision += 1;
    try workspace.prepareSections(&sections);
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    states[15 * 48 + 15] = @intCast(game_data.registry.block_stone_default_state);
    sections[0].stamp.revision += 1;
    try workspace.prepareSections(&sections);
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u8, 1), workspace.summaries[0].heights[255]);
}

test "baked terrain produces identical packets through both section layouts and every palette width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const baker = try chunks.Prepared.Baker.init(allocator);
    const native_workspace = try Workspace.init(allocator, 1 << 20, &.{.{ .number = 0 }}, try testBlocks(allocator));
    const baked_workspace = try Workspace.init(allocator, 1 << 20, &.{.{ .number = 0 }}, try testBlocks(allocator));
    var column_codec = try chunks.Light.Workspace.init(allocator);
    defer column_codec.deinit();
    const states = try allocator.alloc(i32, game_data.registry.block_state_to_block.len);
    for (states, 0..) |*state, index| state.* = @intCast(index);
    const registry: packets.Registry = .{ .entities = &.{}, .items = &.{}, .blocks = &.{}, .block_states = states, .block_state_bits = game_data.registry.block_state_bits, .sounds = &.{}, .effects = &.{}, .attributes = &.{} };
    const protocol: sessions.Protocol = .{ .number = 0, .registries = &.{
        .{ .name = "minecraft:worldgen/biome", .entries = &.{"minecraft:plains"} },
        .{ .name = "minecraft:block_entity_type", .entries = &.{ "minecraft:chest", "minecraft:furnace" } },
    } };
    var caches: [2]*delivery_cache.Workspace = undefined;
    var catalogs: [2]delivery_cache.Catalog = undefined;
    for (&caches, &catalogs, [_]bool{ false, true }) |*cache, *catalog, fluids| {
        cache.* = try .init(allocator, 1);
        catalog.* = try .init(allocator, &.{protocol}, &.{.{ .number = 0, .fluids = fluids, .registry = registry }});
    }
    const biome: u16 = @intCast(game_data.registry.biomeId("minecraft:plains").?);
    const biomes: [64]u16 = @splat(biome);
    const raw = try allocator.alloc(u8, chunks.encoding.dense_block_bytes);
    const packed_section = try allocator.alloc(u8, chunks.encoding.maximum_decoded_bytes);
    const loaded_output = try allocator.alloc(u8, 1 << 20);
    const baked_output = try allocator.alloc(u8, loaded_output.len);
    const wire_output = try allocator.alloc(u8, loaded_output.len);
    const inflated_output = try allocator.alloc(u8, loaded_output.len);
    var inflater = try deflate.Decoder.init(allocator);
    defer inflater.deinit();
    for ([_]u16{ 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 300 }) |palette| {
        raw[0] = 1;
        for (&baker.states, 0..) |*state, cell| {
            state.* = if (cell % 173 == 0) @intCast(game_data.registry.block_chest_default_state) else if (cell % 107 == 0) @intCast(game_data.registry.block_water_default_state) else @intCast(cell % palette);
            std.mem.writeInt(u16, raw[1 + cell * 2 ..][0..2], state.*, .little);
        }
        const encoded = try chunks.encoding.encode(raw, packed_section);
        const packed_view = try chunks.encoding.Packed.init(encoded);
        var loaded = [_]section_views.Section{.{ .stamp = .{ .generation = palette }, .view = .{ .encoded = packed_view } }};
        column_codec.begin(.{ .rules = @splat(3), .minimum = 0, .count = 1, .skylight = false, .coverage = 1, .revisions = @splat(0), .biomes = .{ 0, 0, 0, 0, 1, 0, 0, 0, 0 } });
        column_codec.biome(&biomes);
        const baked = try baker.encode(native_workspace.properties, column_codec.terrainSection());
        column_codec.commitTerrain(baked.section.len);
        for (0..6) |layer| {
            const plane = column_codec.section();
            for (plane, 0..) |*byte, cell| byte.* = if (layer == 0) 0 else if (layer % 2 == 0) 255 else @truncate(cell * 73 + cell / 17);
            try column_codec.commitSection();
        }
        const view = try column_codec.decode(try column_codec.finish());
        for (caches, &catalogs) |cache, *catalog| {
            _ = try cache.begin(catalog, &.{.{ .column = .{ .world = 0, .x = -17, .z = 33 }, .protocol = 0 }});
            try baked_workspace.compileFrame(cache, .{ .world = 0, .x = -17, .z = 33 }, &view, 0, null);
        }
        inline for (.{ false, true }) |fluids| for ([_]u32{ 0, 1 }) |disclosure| for ([_]u32{ 0, disclosure }) |frontier| {
            var chunk: Chunk = .{ .x = -17, .z = 33, .sections = .{ .loaded = &loaded }, .biome = biome, .minimum_section = 0, .workspace = native_workspace, .light = .{ .source = .{ .stored = &view }, .count = 3, .masks = .{ @intCast(view.masks[0]), @intCast(view.masks[1]) }, .coverage = 1 }, .disclosure = disclosure, .biome_disclosure = disclosure, .frontier = frontier };
            const expected = try encode(.init(loaded_output), registry, &(try native_workspace.prepare(chunk)), &protocol, fluids);
            chunk.sections = .{ .baked = .{ .view = &view } };
            chunk.workspace = baked_workspace;
            const actual = try encode(.init(baked_output), registry, &(try baked_workspace.prepare(chunk)), &protocol, fluids);
            try std.testing.expectEqualSlices(u8, expected, actual);
            const prepared = try baked_workspace.prepare(chunk);
            if (frontier != 0) {
                try std.testing.expectEqual(@as(u16, @intCast(game_data.registry.blockStateId("minecraft:pink_terracotta").?)), prepared.sections[0].view.uniform);
                try std.testing.expectEqual(@as(u16, 0), baked_workspace.summaryAt(0).state.block_entities);
            }
            const compiled = try baked_workspace.prepareDelivery(caches[@intFromBool(fluids)], chunk, 0);
            const delivery_bytes = try encodeDelivery(.init(wire_output), registry, &compiled, &protocol, fluids);
            const delivered = try inflater.decode(delivery_bytes, inflated_output);
            try std.testing.expectEqualSlices(u8, expected, delivered);
        };
        for (caches) |cache| try cache.finish(null);
    }
}

test "baked frames from different places keep their own section summaries in one workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const baker = try chunks.Prepared.Baker.init(allocator);
    const workspace = try Workspace.init(allocator, 1 << 20, &.{.{ .number = 0 }}, try testBlocks(allocator));
    const states = try allocator.alloc(i32, game_data.registry.block_state_to_block.len);
    for (states, 0..) |*state, index| state.* = @intCast(index);
    const registry: packets.Registry = .{ .entities = &.{}, .items = &.{}, .blocks = &.{}, .block_states = states, .block_state_bits = game_data.registry.block_state_bits, .sounds = &.{}, .effects = &.{}, .attributes = &.{} };
    const protocol: sessions.Protocol = .{ .number = 0, .registries = &.{
        .{ .name = "minecraft:worldgen/biome", .entries = &.{"minecraft:plains"} },
        .{ .name = "minecraft:block_entity_type", .entries = &.{ "minecraft:chest", "minecraft:furnace" } },
    } };
    const biome: u16 = @intCast(game_data.registry.biomeId("minecraft:plains").?);
    const biomes: [64]u16 = @splat(biome);
    var codecs: [2]chunks.Light.Workspace = undefined;
    for (&codecs) |*codec| codec.* = try .init(allocator);
    defer for (&codecs) |*codec| codec.deinit();
    var views: [2]chunks.Light.View = undefined;
    for (&views, &codecs, [_]u16{ 2, 300 }) |*view, *codec, palette| {
        for (&baker.states, 0..) |*state, cell| state.* = @intCast(cell % palette);
        codec.begin(.{ .rules = @splat(3), .minimum = 0, .count = 1, .skylight = false, .coverage = 1, .revisions = @splat(0), .biomes = .{ 0, 0, 0, 0, 1, 0, 0, 0, 0 } });
        codec.biome(&biomes);
        const baked = try baker.encode(workspace.properties, codec.terrainSection());
        codec.commitTerrain(baked.section.len);
        for (0..6) |layer| {
            @memset(codec.section(), if (layer == 0) 0 else 255);
            try codec.commitSection();
        }
        view.* = try codec.decode(try codec.finish());
    }
    const actual = try allocator.alloc(u8, 1 << 20);
    const expected = try allocator.alloc(u8, actual.len);
    // One frame arrives from a cold record and the next with the light of a delivery. What
    // the workspace learned about the first must not stand for the second.
    for (&views) |*view| {
        var chunk: Chunk = .{ .x = -17, .z = 33, .sections = .{ .baked = .{ .view = view } }, .biome = biome, .minimum_section = 0, .workspace = workspace, .light = .{ .source = .{ .stored = view }, .count = 3, .masks = .{ @intCast(view.masks[0]), @intCast(view.masks[1]) }, .coverage = 1 }, .disclosure = 1, .biome_disclosure = 1 };
        const shared = try encode(.init(actual), registry, &(try workspace.prepare(chunk)), &protocol, false);
        chunk.workspace = try Workspace.init(allocator, 1 << 20, &.{.{ .number = 0 }}, try testBlocks(allocator));
        const alone = try encode(.init(expected), registry, &(try chunk.workspace.prepare(chunk)), &protocol, false);
        try std.testing.expectEqualSlices(u8, alone, shared);
    }
}

test "uniform section runs preserve biomes counts and every wire layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const workspace = try Workspace.init(allocator, 1 << 20, &.{.{ .number = 0 }}, try testBlocks(allocator));
    const states = try allocator.alloc(i32, game_data.registry.block_state_to_block.len);
    for (states, 0..) |*state, index| state.* = @intCast(index + 1024);
    const registry: packets.Registry = .{ .entities = &.{}, .items = &.{}, .blocks = &.{}, .block_states = states, .block_state_bits = game_data.registry.block_state_bits, .sounds = &.{}, .effects = &.{}, .attributes = &.{} };
    const protocol: sessions.Protocol = .{ .number = 0, .registries = &.{.{ .name = "minecraft:worldgen/biome", .entries = &.{ "minecraft:plains", "minecraft:desert" } }} };
    const biomes = [_]u16{ @intCast(game_data.registry.biomeId("minecraft:plains").?), @intCast(game_data.registry.biomeId("minecraft:desert").?) };
    const materials = [_]u16{ game_data.registry.block_air_default_state, game_data.registry.block_stone_default_state, game_data.registry.block_water_default_state };
    var column = try chunks.Light.Workspace.init(allocator);
    defer column.deinit();
    const expected_bytes = try allocator.alloc(u8, 1 << 20);
    const actual_bytes = try allocator.alloc(u8, expected_bytes.len);
    var cells: [section_views.maximum_sections][64]u16 = undefined;
    var sections: [section_views.maximum_sections]section_views.Section = undefined;
    for ([_]usize{ 1, 2, 3, 8, section_views.maximum_sections }) |run| {
        var header: chunks.Light.Header = .{ .rules = @splat(0), .minimum = -4, .count = sections.len, .skylight = false, .coverage = (1 << sections.len) - 1, .revisions = @splat(0), .biomes = @splat(0), .uniform = (1 << sections.len) - 1 };
        for (&sections, &cells, 0..) |*section, *values, index| {
            const state = materials[index / run % materials.len];
            values.* = @splat(biomes[index / (run + 1) % biomes.len]);
            section.* = .{ .stamp = .{ .constant = state }, .view = .{ .uniform = state }, .biomes = .{ .values = values } };
            header.states[index] = state;
        }
        column.begin(header);
        var heights: [256]u16 = @splat(0);
        for (sections, 0..) |section, index| {
            _ = column.terrainSection();
            column.commitUniformTerrain(section.view.uniform);
            if (!isAir(section.view.uniform)) @memset(&heights, @intCast((index + 1) * 16));
        }
        try column.heightmap(&heights);
        for (0..2 * (sections.len + 2)) |_| {
            @memset(column.section(), 0);
            try column.commitSection();
        }
        const view = try column.decode(try column.finish());
        var chunk: Chunk = .{ .x = -33, .z = 17, .sections = .{ .baked = .{ .view = &view } }, .biome = biomes[0], .minimum_section = -4, .workspace = workspace, .light = .{ .source = .{ .stored = &view }, .count = sections.len + 2, .masks = .{ 0, 0 }, .coverage = header.coverage } };
        inline for (.{ false, true }) |fluids| for ([_]u16{ 0, game_data.registry.block_stone_default_state }) |cover| for ([_]u32{ header.coverage, 0, 1, 1 << (sections.len - 1), 0x555555 }) |disclosure| {
            chunk.concealment = cover;
            chunk.disclosure = disclosure;
            chunk.biome_disclosure = disclosure;
            for (&sections, &cells) |*section, *values| section.biomes = .{ .values = values };
            const expected = try encode(.init(expected_bytes), registry, &(try workspace.prepare(chunk)), &protocol, fluids);
            for (&sections, &cells) |*section, *values| section.biomes = .{ .constant = values[0] };
            const actual = try encode(.init(actual_bytes), registry, &(try workspace.prepare(chunk)), &protocol, fluids);
            try std.testing.expectEqualSlices(u8, expected, actual);
            if (run == sections.len) for (&sections) |*section| {
                section.biomes = null;
            };
        };
    }
}

test "section summaries invalidate on edits and slot reuse and recover after errors" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var metric_registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 48 });
    defer metric_registry.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/encoding", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const transaction = store.transaction();
    defer transaction.fail();
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 4 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("chunks"), .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
    const workspace = try Workspace.init(arena.allocator(), 1 << 20, &.{.{ .number = 0 }}, try testBlocks(arena.allocator()));
    const position: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    const snapshot = try lighting.Workspace.init(arena.allocator(), try terrain.client(.{ .name = "lighting", .sections = @min(192, terrain.unbudgeted()) }), try game_data.lighting.init(arena.allocator()));
    const world_dimension: worlds.Worlds.Dimension = .{ .name = "test:encoding", .minimum_section = 0, .section_count = 1, .skylight = true };
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepareSections(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = 1 }});
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepareSections(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u8, 16), workspace.summaries[0].heights[255]);
    try std.testing.expectEqual(@as(u16, 2), workspace.summaries[0].state.palette_len);
    var states: [258]i32 = undefined;
    for (&states, 0..) |*state, i| state.* = @intCast(i);
    const registry: packets.Registry = .{
        .entities = &.{},
        .items = &.{},
        .blocks = &.{},
        .block_states = &states,
        .block_state_bits = game_data.registry.block_state_bits,
        .sounds = &.{},
        .effects = &.{},
        .attributes = &.{},
    };
    const protocol: sessions.Protocol = .{
        .number = 0,
        .registries = &.{.{ .name = "minecraft:worldgen/biome", .entries = &.{"minecraft:plains"} }},
    };
    var column: Chunk = .{
        .x = 0,
        .z = 0,
        .sections = .{ .loaded = snapshot.sections() },
        .biome = game_data.registry.biomeId("minecraft:plains").?,
        .minimum_section = 0,
        .workspace = workspace,
        .light = snapshot.data(),
    };
    var short: [640]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encode(.init(&short), registry, &(try column.workspace.prepare(column)), &protocol, true));
    for (workspace.palette_indices) |index| try std.testing.expectEqual(std.math.maxInt(u16), index);
    var reused: [32 * 1024]u8 = undefined;
    var fresh: [32 * 1024]u8 = undefined;
    inline for (.{ false, true }) |fluid_count| {
        column.workspace = workspace;
        const actual = try encode(.init(&reused), registry, &(try column.workspace.prepare(column)), &protocol, fluid_count);
        column.workspace = try Workspace.init(arena.allocator(), 1 << 20, &.{.{ .number = 0 }}, try testBlocks(arena.allocator()));
        const expected = try encode(.init(&fresh), registry, &(try column.workspace.prepare(column)), &protocol, fluid_count);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
    const revision = workspace.summaries[0].state.stamp;
    try workspace.prepareSections(snapshot.sections());
    try std.testing.expectEqual(revision, workspace.summaries[0].state.stamp);
    var edits: [257]chunks.BlockEdit = undefined;
    for (&edits, 0..) |*edit, i| edit.* = .{ .index = @intCast(i), .state = @intCast(i + 1) };
    try terrain.setBlocks(position, &edits);
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepareSections(snapshot.sections());
    try std.testing.expect(workspace.summaries[0].state.direct);
    try std.testing.expectEqual(@as(u16, 258), workspace.summaries[0].state.count);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = std.math.maxInt(u16) }});
    try std.testing.expectError(error.InvalidEdit, prepareSnapshot(snapshot, terrain, world_dimension, 0));
    for (workspace.palette_indices) |index| try std.testing.expectEqual(std.math.maxInt(u16), index);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = 0 }});
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepareSections(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 257), workspace.summaries[0].state.count);
    column.sections = .{ .loaded = snapshot.sections() };
    const changed = workspace.prepareColumn(column.sections.loaded);
    try std.testing.expectEqual(@as(u16, 1), changed.heights[255]);
    try std.testing.expectEqual(@as(u16, 2), changed.heights[0]);
    column.minimum_section = -4;
    const dimension = workspace.prepareColumn(column.sections.loaded);
    try std.testing.expectEqual(@as(u16, 2), dimension.heights[0]);

    try prepareSnapshot(snapshot, terrain, world_dimension, 1);
    try workspace.prepareSections(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.palette_len);
    try std.testing.expectEqual(@as(u8, 0), workspace.summaries[0].heights[255]);
    column.sections = .{ .loaded = snapshot.sections() };
    try std.testing.expectEqual(@as(u16, 0), workspace.prepareColumn(column.sections.loaded).heights[0]);

    var concealed_sections = [_]section_views.Section{.{
        .stamp = .{ .generation = 900, .revision = 1 },
        .view = .{ .uniform = @intCast(game_data.registry.block_chest_default_state) },
    }};
    column.sections = .{ .loaded = &concealed_sections };
    column.minimum_section = 0;
    column.workspace = workspace;
    column.disclosure = 0;
    column.concealment = 1;
    const concealed = try encode(.init(&reused), registry, &(try column.workspace.prepare(column)), &protocol, true);
    var reader = std.Io.Reader.fixed(concealed);
    _ = try reader.take(8);
    try std.testing.expectEqual(@as(u32, 2), try readVarint(&reader));
    for (0..2) |_| {
        _ = try readVarint(&reader);
        try std.testing.expectEqual(@as(u32, 22), try readVarint(&reader));
        _ = try reader.take(22 * 8);
    }
    _ = try readVarint(&reader);
    try std.testing.expectEqual(@as(u16, 4096), try reader.takeInt(u16, .big));
    try std.testing.expectEqual(@as(u16, 0), try reader.takeInt(u16, .big));
    try std.testing.expectEqual(@as(u8, 0), try reader.takeByte());
    try std.testing.expectEqual(@as(u32, 1), try readVarint(&reader));
    try std.testing.expectEqual(@as(u8, 0), try reader.takeByte());
    _ = try readVarint(&reader);
    try std.testing.expectEqual(@as(u32, 0), try readVarint(&reader));
    for (0..2) |_| {
        try std.testing.expectEqual(@as(u32, 1), try readVarint(&reader));
        try std.testing.expectEqual(@as(u64, 0), (try reader.takeInt(u64, .big)) & 2);
    }
    try std.testing.expectEqual(@as(u16, 0), workspace.summaryAt(0).state.block_entities);
    column.disclosure = 1;
    const revealed = workspace.representation(column);
    try workspace.prepareSections(revealed);
    try std.testing.expectEqual(@as(u16, 4096), workspace.summaryAt(0).state.block_entities);
    concealed_sections[0].view = .{ .uniform = 1 };
    concealed_sections[0].stamp.revision += 1;
    column.light.coverage = 0;
    column.light.disclosure = 0;
    _ = try encode(.init(&reused), registry, &(try column.workspace.prepare(column)), &protocol, true);
}

fn prepareSnapshot(snapshot: *lighting.Workspace, terrain: *chunks.Chunks, dimension: worlds.Worlds.Dimension, x: i32) !void {
    for (0..128) |_| {
        if (try snapshot.prepare(terrain, 0, x, 0, dimension, 0)) return;
        try terrain.poll();
    }
    return error.SnapshotStalled;
}

fn writeBiomes(writer: *std.Io.Writer, values: section_views.Biomes, protocol: *const sessions.Protocol, mapping: *Workspace.Mapping, workspace: *Workspace) !void {
    if (values.uniform()) |first| {
        if (first >= game_data.registry.biome_names.len) return error.UnsupportedBiome;
        const id = try mapping.biome(protocol, first);
        try writer.writeByte(0);
        try varint(writer, id);
        return;
    }
    if (workspace.last_biome_encoding) |slot| {
        const entry = &workspace.biome_encodings[slot];
        if (entry.valid and entry.protocol == protocol.number and entry.preparation == workspace.preparation and std.meta.eql(entry.source, values)) {
            try writer.writeAll(entry.bytes[0..entry.length]);
            return;
        }
    }
    var cells: [64]u16 = undefined;
    const packed_palette: ?chunks.Light.Biome.Palette = if (values == .palette and values.palette.bits() <= 2) values.palette else null;
    const key = if (packed_palette) |palette| palette.bytes else if (values == .plane) std.mem.asBytes(values.plane) else key: {
        for (0..4) |index| cells[index * 16 ..][0..16].* = values.row(@intCast(index));
        break :key std.mem.asBytes(&cells);
    };
    const hash = std.hash.Wyhash.hash(0, key);
    const slot = hash % workspace.biome_encodings.len;
    const cached = &workspace.biome_encodings[slot];
    workspace.last_biome_encoding = slot;
    if (cached.valid and cached.protocol == protocol.number and cached.hash == hash and cached.key_length == key.len and std.mem.eql(u8, cached.key[0..cached.key_length], key)) {
        cached.preparation = workspace.preparation;
        cached.source = values;
        try writer.writeAll(cached.bytes[0..cached.length]);
        return;
    }
    cached.valid = false;
    var encoded: std.Io.Writer = .fixed(&cached.bytes);
    if (packed_palette) |palette| try writePackedBiomes(&encoded, palette, protocol, mapping) else try writeBiomeCells(&encoded, if (values == .plane) values.plane else &cells, protocol, mapping);
    cached.protocol = protocol.number;
    cached.preparation = workspace.preparation;
    cached.source = values;
    cached.hash = hash;
    @memcpy(cached.key[0..key.len], key);
    cached.key_length = @intCast(key.len);
    cached.length = @intCast(encoded.end);
    cached.valid = true;
    try writer.writeAll(cached.bytes[0..cached.length]);
}

fn writePackedBiomes(writer: *std.Io.Writer, palette: chunks.Light.Biome.Palette, protocol: *const sessions.Protocol, mapping: *Workspace.Mapping) !void {
    assert(palette.bits() == 1 or palette.bits() == 2);
    const count = palette.states().len / 2;
    assert(count > 1 and count <= 4 and palette.bits() == std.math.log2_int_ceil(usize, count));
    assert(palette.ranks().len == @as(usize, palette.bits()) * 8);
    if (count == 3) {
        const ranks: @Vector(16, u8) = palette.ranks()[0..16].*;
        assert(@reduce(.Or, ranks & (ranks >> @splat(1)) & @as(@Vector(16, u8), @splat(0x55))) == 0);
    }
    try writer.writeByte(palette.bits());
    try varint(writer, @intCast(count));
    for (0..count) |index| {
        const biome = std.mem.readInt(u16, palette.states()[index * 2 ..][0..2], .little);
        try varint(writer, try mapping.biome(protocol, biome));
    }
    for (0..palette.ranks().len / 8) |index| try writer.writeInt(u64, std.mem.readInt(u64, palette.ranks()[index * 8 ..][0..8], .little), .big);
}

fn writeBiomeCells(writer: *std.Io.Writer, cells: []const u16, protocol: *const sessions.Protocol, mapping: *Workspace.Mapping) !void {
    assert(cells.len == 16 or cells.len == 64);
    var palette: [64]u16 = undefined;
    var indices: [64]u16 = undefined;
    var count: usize = 0;
    var ranks: [game_data.registry.biome_names.len]u8 = @splat(255);
    for (cells, indices[0..cells.len]) |biome, *rank| {
        if (biome >= ranks.len) return error.UnsupportedBiome;
        if (ranks[biome] == 255) {
            ranks[biome] = @intCast(count);
            palette[count] = biome;
            count += 1;
        }
        rank.* = ranks[biome];
    }
    var wire: [64]u32 = undefined;
    for (palette[0..count], wire[0..count]) |biome, *encoded| {
        if (biome >= game_data.registry.biome_names.len) return error.UnsupportedBiome;
        encoded.* = @intCast(try mapping.biome(protocol, biome));
    }
    if (count == 1) {
        try writer.writeByte(0);
        try varint(writer, @intCast(wire[0]));
        return;
    }
    const direct = count > 8;
    const bits: u8 = if (direct) direct: {
        if (mapping.biome_bits) |cached| break :direct cached;
        const registry_count: usize = for (protocol.registries) |registry| {
            if (std.mem.eql(u8, registry.name, "minecraft:worldgen/biome")) break registry.entries.len;
        } else return error.UnsupportedBiome;
        if (registry_count == 0 or registry_count > std.math.maxInt(i32)) return error.UnsupportedBiome;
        const selected: u8 = @intCast(@max(4, std.math.log2_int_ceil(usize, registry_count)));
        mapping.biome_bits = selected;
        break :direct selected;
    } else @intCast(std.math.log2_int_ceil(usize, count));
    try writer.writeByte(bits);
    if (!direct) {
        try varint(writer, @intCast(count));
        for (wire[0..count]) |id| try varint(writer, @intCast(id));
    }
    const per_word = 64 / @as(usize, bits);
    for (0..(64 + per_word - 1) / per_word) |word| {
        var encoded: u64 = 0;
        for (0..per_word) |offset| {
            const index = word * per_word + offset;
            if (index >= 64) break;
            const rank = indices[index & (cells.len - 1)];
            const value: u64 = if (direct) wire[rank] else rank;
            encoded |= value << @intCast(offset * bits);
        }
        try writer.writeInt(u64, encoded, .big);
    }
}

fn readVarint(reader: *std.Io.Reader) !u32 {
    var value: u32 = 0;
    for (0..5) |index| {
        const byte = try reader.takeByte();
        value |= @as(u32, byte & 127) << @intCast(index * 7);
        if (byte & 128 == 0) return value;
    }
    return error.InvalidVarint;
}

test "packed biome palettes preserve protocol mappings and every rank without expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workspace = try Workspace.init(arena.allocator(), 1 << 20, &.{ .{ .number = 0 }, .{ .number = 1 } }, try testBlocks(arena.allocator()));
    var reversed = game_data.registry.biome_names.*;
    std.mem.reverse([]const u8, &reversed);
    const protocols = [_]sessions.Protocol{
        .{ .number = 0, .registries = &.{.{ .name = "minecraft:worldgen/biome", .entries = game_data.registry.biome_names }} },
        .{ .number = 1, .registries = &.{.{ .name = "minecraft:worldgen/biome", .entries = &reversed }} },
    };
    var random = std.Random.DefaultPrng.init(0x94519);
    var palette_bytes: [26]u8 = undefined;
    var cells: [64]u16 = undefined;
    var expected: [257]u8 = undefined;
    var actual: [257]u8 = undefined;
    for (2..5) |count| for (0..128) |trial| {
        const bits: u4 = @intCast(std.math.log2_int_ceil(usize, count));
        const states = palette_bytes[2..][0 .. count * 2];
        const ranks = palette_bytes[2 + count * 2 ..][0 .. @as(usize, bits) * 8];
        palette_bytes[0] = bits + 2;
        palette_bytes[1] = @intCast(count);
        @memset(ranks, 0);
        for (0..count) |index| std.mem.writeInt(u16, states[index * 2 ..][0..2], @intCast((index + trial) % game_data.registry.biome_names.len), .little);
        for (&cells, 0..) |*cell, index| {
            const rank = if (index < count) index else random.random().uintLessThan(usize, count);
            cell.* = std.mem.readInt(u16, states[rank * 2 ..][0..2], .little);
            const bit = index * bits;
            ranks[bit / 8] |= @as(u8, @intCast(rank)) << @as(u3, @intCast(bit % 8));
        }
        const values: section_views.Biomes = .{ .palette = .{ .bytes = palette_bytes[0 .. 2 + count * 2 + @as(usize, bits) * 8] } };
        for (&protocols) |*protocol| {
            const mapping = try workspace.mapping(protocol);
            var reference: std.Io.Writer = .fixed(&expected);
            try writeBiomeCells(&reference, &cells, protocol, mapping);
            for ([_]section_views.Biomes{ values, values, .{ .values = &cells }, values }) |source| {
                workspace.preparation += 1;
                var writer: std.Io.Writer = .fixed(&actual);
                try writeBiomes(&writer, source, protocol, mapping, workspace);
                try std.testing.expectEqualSlices(u8, reference.buffered(), writer.buffered());
            }
        }
    };
}

test "biome planes match expanded cells through every palette width and protocol mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workspace = try Workspace.init(arena.allocator(), 1 << 20, &.{ .{ .number = 0 }, .{ .number = 1 } }, try testBlocks(arena.allocator()));
    var reversed = game_data.registry.biome_names.*;
    std.mem.reverse([]const u8, &reversed);
    var cells: [64]u16 = undefined;
    var actual: [257]u8 = undefined;
    var expected: [257]u8 = undefined;
    for (0..2) |version| {
        const protocol: sessions.Protocol = .{ .number = @intCast(version), .registries = &.{.{ .name = "minecraft:worldgen/biome", .entries = if (version == 0) game_data.registry.biome_names else &reversed }} };
        const mapping = try workspace.mapping(&protocol);
        for (1..17) |count| {
            for (&cells, 0..) |*value, cell| value.* = @intCast(cell % 16 % count);
            workspace.preparation += 1;
            var writer: std.Io.Writer = .fixed(&actual);
            var oracle: std.Io.Writer = .fixed(&expected);
            try writeBiomes(&writer, .{ .plane = cells[0..16] }, &protocol, mapping, workspace);
            try writeBiomeCells(&oracle, &cells, &protocol, mapping);
            try std.testing.expectEqualSlices(u8, oracle.buffered(), writer.buffered());
        }
    }
}

test "disclosure variants retain immutable source summaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workspace = try Workspace.init(arena.allocator(), 1 << 20, &.{.{ .number = 0 }}, try testBlocks(arena.allocator()));
    var states: [4096]u16 = @splat(0);
    states[256] = @intCast(game_data.registry.block_stone_default_state);
    const sections = [_]section_views.Section{
        .{ .stamp = .{ .generation = 1, .revision = 1 }, .view = .{ .dense = &states } },
        .{ .stamp = .{ .generation = 2, .revision = 1 }, .view = .{ .dense = &states } },
    };
    var chunk: Chunk = .{ .x = 0, .z = 0, .minimum_section = 0, .sections = .{ .loaded = &sections }, .biome = 0, .workspace = workspace, .light = undefined, .disclosure = 3 };
    try workspace.prepareSections(workspace.representation(chunk));
    try std.testing.expectEqual(@as(u64, 2), workspace.summary_builds);
    const source = workspace.summaries[0].state;
    chunk.disclosure = 2;
    try workspace.prepareSections(workspace.representation(chunk));
    try std.testing.expectEqualDeep(source, workspace.summaries[0].state);
    try std.testing.expectEqual(@as(u16, 0), workspace.summaryAt(0).state.count);
    const builds = workspace.summary_builds;
    chunk.disclosure = 3;
    try workspace.prepareSections(workspace.representation(chunk));
    try std.testing.expectEqual(builds, workspace.summary_builds);
    try std.testing.expectEqual(@as(u16, 1), workspace.summaryAt(0).state.count);
}

test "concealed biome height intervals reuse cells across the full column" {
    const count = 24;
    var values: [64]u16 = undefined;
    for (&values, 0..) |*value, index| value.* = @intCast(index);
    var sections: [9 * count]?section_views.Biomes = @splat(null);
    sections[4 * count + 12] = .{ .values = &values };
    const neighborhood: BiomeNeighborhood = .{ .count = count, .source = .{ .loaded = &sections }, .disclosed = .{ 0, 0, 0, 0, 1 << 12, 0, 0, 0, 0 } };
    var cells: [count][64]u16 = undefined;
    var output: [count]?section_views.Biomes = undefined;
    neighborhood.projectMany((1 << count) - 1, &output, &cells);
    for (output, 0..) |projected, index| {
        if (index == 12) try std.testing.expect(projected.?.values == &values) else try std.testing.expect(projected.?.plane == (if (index < 12) cells[0][0..16] else cells[13][0..16]));
        for (0..64) |cell| {
            const expected: u16 = @intCast(if (index < 12) cell % 16 else if (index == 12) cell else 48 + cell % 16);
            try std.testing.expectEqual(expected, projected.?.get(@intCast(cell)));
        }
    }
}

test "uniform biome projection reads only disclosed sources and preserves unselected sections" {
    const count = 4;
    var sources: [9 * count]?section_views.Biomes = @splat(.{ .constant = 99 });
    var masks: [9]u32 = @splat(0);
    for (&masks, 0..) |*mask, column| {
        mask.* = @as(u32, 1) << @intCast(column % count);
        sources[column * count + column % count] = .{ .constant = 5 };
    }
    const neighborhood: BiomeNeighborhood = .{ .count = count, .source = .{ .loaded = &sources }, .disclosed = masks };
    var padding: [count][64]u16 = undefined;
    var output: [count]?section_views.Biomes = @splat(.{ .constant = 77 });
    neighborhood.projectMany(5, &output, &padding);
    for (output, 0..) |value, index| try std.testing.expectEqual(@as(u16, if (index % 2 == 0) 5 else 77), value.?.get(0));
}

test "concealed biome height intervals preserve exhaustive nearest cells across sparse disclosures" {
    const count = section_views.maximum_sections;
    var values: [9][count][64]u16 = undefined;
    var sources: [9 * count]?section_views.Biomes = undefined;
    for (&values, 0..) |*column, xz| for (column, 0..) |*section, y| {
        for (section, 0..) |*value, cell| value.* = @intCast((xz * count + y) * 64 + cell);
        sources[xz * count + y] = .{ .values = section };
    };
    var projection_cache: BiomeNeighborhood.Cache = .{};
    var random = std.Random.DefaultPrng.init(0xc0a312);
    for (0..64) |trial| {
        if (trial == 12) {
            for (&values, 0..) |*column, xz| for (column, 0..) |*section, y| {
                const biome: u16 = @intCast((xz / 3 + y / 4) % 3);
                section.* = @splat(biome);
                sources[xz * count + y] = .{ .constant = biome };
            };
        }
        var masks: [9]u32 = undefined;
        for (&masks) |*mask| mask.* = random.random().int(u24) & random.random().int(u24) & random.random().int(u24) & random.random().int(u24);
        if (trial == 0) masks = .{ 1, 0, 0, 0, 1 << 12, 0, 0, 0, 1 << 23 };
        if (trial >= 24) {
            for (&values, 0..) |*column, xz| for (column, 0..) |*section, y| {
                for (section, 0..) |*value, cell| value.* = @intCast(xz * 1000 + y * 64 + cell);
                sources[xz * count + y] = .{ .values = section };
            };
            if (trial < 36) {
                const mask = @as(u32, 1) << @intCast((trial - 24) * 2);
                masks = @splat(mask | (if (trial % 2 == 0) @as(u32, 1) << 23 else @as(u32, 0)));
                masks[trial % 4] = 0;
            }
        }
        const neighborhood: BiomeNeighborhood = .{ .count = count, .source = .{ .loaded = &sources }, .disclosed = masks, .cache = &projection_cache };
        var padding: [count][64]u16 = undefined;
        var actual: [count]?section_views.Biomes = undefined;
        for (0..2) |_| neighborhood.projectMany((1 << count) - 1, &actual, &padding);
        for (0..count) |section| for (0..64) |cell| {
            const target_x: i32 = @intCast(cell % 4);
            const target_z: i32 = @intCast(cell / 4 % 4);
            const target_y: i32 = @intCast(section * 4 + cell / 16);
            var closest: i32 = std.math.maxInt(i32);
            var expected: ?u16 = null;
            for (masks, 0..) |mask, column| {
                const origin_x = (@as(i32, @intCast(column % 3)) - 1) * 4;
                const origin_z = (@as(i32, @intCast(column / 3)) - 1) * 4;
                const source_x = std.math.clamp(target_x - origin_x, 0, 3);
                const source_z = std.math.clamp(target_z - origin_z, 0, 3);
                const dx = origin_x + source_x - target_x;
                const dz = origin_z + source_z - target_z;
                for (0..count) |source_section| {
                    if (mask & (@as(u32, 1) << @intCast(source_section)) == 0) continue;
                    for (0..4) |source_y| {
                        const dy = @as(i32, @intCast(source_section * 4 + source_y)) - target_y;
                        const distance = dx * dx + dy * dy + dz * dz;
                        if (distance >= closest) continue;
                        closest = distance;
                        expected = values[column][source_section][source_y * 16 + @as(usize, @intCast(source_z * 4 + source_x))];
                    }
                }
            }
            if (expected) |value| try std.testing.expectEqual(value, actual[section].?.get(@intCast(cell))) else try std.testing.expect(actual[section] == null);
        };
    }
}

test "compiled delivery matches canonical encoding through every selected protocol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var selected = try protocol_set.Default.init(allocator);
    defer selected.deinit(allocator);
    const native = try Workspace.init(allocator, 1 << 20, &selected.values, try testBlocks(allocator));
    const compiled = try Workspace.init(allocator, 1 << 20, &selected.values, try testBlocks(allocator));
    var catalog = try Workspace.initDeliveryCatalog(allocator, &selected.values);
    const cache = try delivery_cache.Workspace.init(allocator, selected.values.len);
    var requests: [protocol_set.implementations.len]delivery_cache.Request = undefined;
    for (selected.values, &requests) |definition, *request| request.* = .{ .column = .{ .world = 0, .x = -2, .z = 3 }, .protocol = definition.number };
    _ = try cache.begin(&catalog, &requests);
    defer cache.cancel();
    const baker = try chunks.Prepared.Baker.init(allocator);
    const materials = [_]u16{ @intCast(game_data.registry.block_stone_default_state), @intCast(game_data.registry.block_water_default_state), @intCast(game_data.registry.block_chest_default_state) };
    for (&baker.states, 0..) |*state, index| state.* = materials[index % materials.len];
    const plains: u16 = @intCast(game_data.registry.biomeId("minecraft:plains").?);
    const desert: u16 = @intCast(game_data.registry.biomeId("minecraft:desert").?);
    var biomes: [64]u16 = undefined;
    for (&biomes, 0..) |*biome, index| biome.* = if (index % 3 == 0) desert else plains;
    const loaded = [_]section_views.Section{
        .{ .stamp = .{ .generation = 1 }, .view = .{ .dense = &baker.states }, .biomes = .{ .values = &biomes } },
        .{ .stamp = .{ .constant = 0 }, .view = .{ .uniform = 0 }, .biomes = .{ .constant = plains } },
    };
    var frame_writer = try chunks.Light.Workspace.init(allocator);
    defer frame_writer.deinit();
    frame_writer.begin(.{ .rules = @splat(5), .minimum = -4, .count = 2, .skylight = true, .coverage = 3, .revisions = @splat(0), .biomes = .{ 0, 0, 0, 0, 3, 0, 0, 0, 0 }, .uniform = 2 });
    frame_writer.biome(&biomes);
    frame_writer.biome(&@as([64]u16, @splat(plains)));
    const baked = try baker.encode(native.properties, frame_writer.terrainSection());
    frame_writer.commitTerrain(baked.section.len);
    _ = frame_writer.terrainSection();
    frame_writer.commitUniformTerrain(0);
    try frame_writer.heightmap(&@as([256]u16, @splat(16)));
    for (0..8) |index| {
        @memset(frame_writer.section(), if (index < 4) 0 else 255);
        try frame_writer.commitSection();
    }
    const view = try frame_writer.decode(try frame_writer.finish());
    const expected = try allocator.alloc(u8, 1 << 20);
    const output = try allocator.alloc(u8, expected.len);
    const inflated = try allocator.alloc(u8, expected.len);
    var decoder = try deflate.Decoder.init(allocator);
    defer decoder.deinit();
    inline for (protocol_set.implementations) |Version| {
        const definition = for (&selected.values) |*value| {
            if (value.number == Version.protocol_number) break value;
        } else unreachable;
        const registry = packets.Registry.forVersion(Version);
        for ([_]u32{ 0, 1, 3 }) |mask| {
            var chunk: Chunk = .{ .x = -2, .z = 3, .minimum_section = -4, .sections = .{ .loaded = &loaded }, .biome = plains, .workspace = native, .light = .{ .source = .{ .stored = &view }, .count = 4, .masks = .{ @intCast(view.masks[0]), @intCast(view.masks[1]) }, .coverage = 3, .disclosure = mask, .selection = if (mask == 1) 2 else null }, .disclosure = mask, .biome_disclosure = mask };
            const canonical = try native.prepare(chunk);
            const reference = try sessions.packet_api.encode(Version, write, expected, .{ registry, &canonical, definition });
            chunk.sections = .{ .baked = .{ .view = &view } };
            chunk.workspace = compiled;
            const prepared = try compiled.prepareDelivery(cache, chunk, Version.protocol_number);
            const wire_bytes = try sessions.packet_api.encode(Version, write_delivery, output, .{ registry, &prepared, definition });
            try std.testing.expectEqualSlices(u8, reference, try decoder.decode(wire_bytes, inflated));
        }
    }
    try std.testing.expectEqual(@as(usize, 1), cache.count);
    const column = try chunks.Delivery.Column.read(cache.values[0].?);
    try std.testing.expectEqualSlices(u8, view.bytes, column.frame);
    try std.testing.expectEqual(catalog.variants.len, column.variants);
    for (catalog.variants) |variant| try std.testing.expect(column.find(variant.identity) != null);
    // Each protocol's compile superseded the column's pending bundle, so one write stores
    // the last and fullest.
    try std.testing.expectEqual(@as(usize, 1), cache.write_count);
    try std.testing.expectEqual(cache.values[0].?.ptr, cache.writes[0].value.?.ptr);
    const bank = cache.write_bank;
    if (catalog.variants.len > 1) {
        const variant = catalog.variants[0];
        const reference = try allocator.dupe(u8, column.find(variant.identity).?);
        // The writer lays out one full entry per section before packing the unique ones, so
        // compiling a record takes that much room beyond its finished length.
        const working = @as(usize, view.header.count) * chunks.Delivery.work_entry_bytes;
        const limit = chunks.Delivery.Column.header_size + view.bytes.len + catalog.variants.len * chunks.Delivery.Column.entry_size + reference.len + working;
        cache.cancel();
        cache.write_bank = cache.write_bank[0..limit];
        _ = try cache.begin(&catalog, &requests);
        try compiled.compileFrame(cache, requests[0].column, &view, variant.codec.number, null);
        const bounded = try chunks.Delivery.Column.read(cache.values[0].?);
        try std.testing.expectEqual(@as(usize, 1), bounded.variants);
        try std.testing.expectEqual(catalog.variants.len, bounded.slots);
        try std.testing.expectEqualSlices(u8, reference, bounded.find(variant.identity).?);
    }
    // Each protocol compiling its own format on request and an eager cache compiling them
    // all on the first request must store the same records.
    cache.cancel();
    cache.write_bank = bank;
    _ = try cache.begin(&catalog, &requests);
    for (selected.values) |definition| try compiled.compileFrame(cache, requests[0].column, &view, definition.number, null);
    try std.testing.expectEqual(@as(usize, 1), cache.write_count);
    const lazy = try chunks.Delivery.Column.read(try allocator.dupe(u8, cache.values[0].?));
    try std.testing.expectEqual(catalog.variants.len, lazy.variants);
    cache.cancel();
    cache.eager = true;
    _ = try cache.begin(&catalog, &requests);
    try compiled.compileFrame(cache, requests[0].column, &view, catalog.variants[catalog.variants.len - 1].codec.number, null);
    try std.testing.expectEqual(@as(usize, 1), cache.write_count);
    const eager = try chunks.Delivery.Column.read(cache.values[0].?);
    try std.testing.expectEqual(catalog.variants.len, eager.variants);
    for (catalog.variants) |variant| try std.testing.expectEqualSlices(u8, lazy.find(variant.identity).?, eager.find(variant.identity).?);
}

test "uniform columns store their frame without a compiled record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var selected = try protocol_set.Default.init(allocator);
    defer selected.deinit(allocator);
    const compiled = try Workspace.init(allocator, 1 << 20, &selected.values, try testBlocks(allocator));
    var catalog = try Workspace.initDeliveryCatalog(allocator, &selected.values);
    const cache = try delivery_cache.Workspace.init(allocator, selected.values.len);
    const column: chunks.Light.Column = .{ .world = 0, .x = 4, .z = -9 };
    const requests = [_]delivery_cache.Request{.{ .column = column, .protocol = selected.values[0].number }};
    _ = try cache.begin(&catalog, &requests);
    defer cache.cancel();
    const plains: u16 = @intCast(game_data.registry.biomeId("minecraft:plains").?);
    var frame_writer = try chunks.Light.Workspace.init(allocator);
    defer frame_writer.deinit();
    frame_writer.begin(.{ .rules = @splat(5), .minimum = -4, .count = 2, .skylight = true, .coverage = 3, .revisions = @splat(0), .biomes = .{ 0, 0, 0, 0, 3, 0, 0, 0, 0 }, .uniform = 3 });
    for (0..2) |_| frame_writer.biome(&@as([64]u16, @splat(plains)));
    for (0..2) |_| {
        _ = frame_writer.terrainSection();
        frame_writer.commitUniformTerrain(0);
    }
    try frame_writer.heightmap(&@as([256]u16, @splat(0)));
    for (0..8) |_| {
        @memset(frame_writer.section(), 255);
        try frame_writer.commitSection();
    }
    const view = try frame_writer.decode(try frame_writer.finish());
    // Every protocol compiles the same column. Only the first stores the frame.
    for (selected.values) |definition| try compiled.compileFrame(cache, column, &view, definition.number, null);
    try std.testing.expectEqual(@as(usize, 1), cache.write_count);
    const stored = try chunks.Delivery.Column.read(cache.values[0].?);
    try std.testing.expectEqualSlices(u8, view.bytes, stored.frame);
    try std.testing.expectEqual(@as(usize, 0), stored.variants);
    try std.testing.expectEqual(column, stored.column);
}

test "a column with no stored biomes around it shows the fallback biome" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var selected = try protocol_set.Default.init(allocator);
    defer selected.deinit(allocator);
    const compiled = try Workspace.init(allocator, 1 << 20, &selected.values, try testBlocks(allocator));
    var catalog = try Workspace.initDeliveryCatalog(allocator, &selected.values);
    const cache = try delivery_cache.Workspace.init(allocator, selected.values.len);
    const column: chunks.Light.Column = .{ .world = 0, .x = 7, .z = 2 };
    const requests = [_]delivery_cache.Request{.{ .column = column, .protocol = selected.values[0].number }};
    var frame_writer = try chunks.Light.Workspace.init(allocator);
    defer frame_writer.deinit();
    frame_writer.begin(.{ .rules = @splat(5), .minimum = -4, .count = 2, .skylight = true, .coverage = 3, .revisions = @splat(0), .biomes = @splat(0), .uniform = 3 });
    for (0..2) |_| {
        _ = frame_writer.terrainSection();
        frame_writer.commitUniformTerrain(0);
    }
    try frame_writer.heightmap(&@as([256]u16, @splat(0)));
    for (0..8) |_| {
        @memset(frame_writer.section(), 255);
        try frame_writer.commitSection();
    }
    const view = try frame_writer.decode(try frame_writer.finish());
    _ = try cache.begin(&catalog, &requests);
    try std.testing.expectError(error.MissingBiomeData, compiled.compileFrame(cache, column, &view, selected.values[0].number, null));
    cache.cancel();
    _ = try cache.begin(&catalog, &requests);
    defer cache.cancel();
    const void_biome: u16 = @intCast(game_data.registry.biomeId("minecraft:the_void").?);
    try compiled.compileFrame(cache, column, &view, selected.values[0].number, void_biome);
    try std.testing.expectEqual(@as(usize, 1), cache.write_count);
}

/// Runs of alike uniform sections compressed once: a column's sky and deep ground are mostly
/// such runs, and storing them raw cost more than the rest of a flat column. Entries are replaced
/// on collision, so a run that misses is compressed again, never sent wrong.
const SectionRuns = struct {
    const capacity = 64;
    const pattern_maximum = 16;
    const count_maximum = section_views.maximum_sections;

    const Entry = struct {
        key: [pattern_maximum + 1]u8 = undefined,
        key_length: u8 = 0,
        bytes: [128]u8 = undefined,
        fragment: deflate.fragments.Fragment = undefined,
    };

    entries: [capacity]Entry = @splat(.{}),

    /// The run of `count` copies of `pattern` as a fragment, or null when it does not fit one.
    fn get(self: *SectionRuns, baker: *deflate.fragments.Baker, pattern: []const u8, count: usize) ?deflate.fragments.Fragment {
        assert(count > 1);
        if (pattern.len == 0 or pattern.len > pattern_maximum or count > count_maximum) return null;
        var key: [pattern_maximum + 1]u8 = undefined;
        @memcpy(key[0..pattern.len], pattern);
        key[pattern.len] = @intCast(count);
        const length = pattern.len + 1;
        const entry = &self.entries[std.hash.Wyhash.hash(0, key[0..length]) % capacity];
        if (entry.key_length == length and std.mem.eql(u8, entry.key[0..length], key[0..length])) return entry.fragment;
        var input: [pattern_maximum * count_maximum]u8 = undefined;
        for (0..count) |index| @memcpy(input[index * pattern.len ..][0..pattern.len], pattern);
        entry.key_length = 0;
        entry.fragment = baker.encode(input[0 .. count * pattern.len], &entry.bytes) catch return null;
        @memcpy(entry.key[0..length], key[0..length]);
        entry.key_length = @intCast(length);
        return entry.fragment;
    }
};

test "runs of alike sections compress once and decode to the run" {
    var baker = try deflate.fragments.Baker.init(std.testing.allocator);
    defer baker.deinit();
    var decoder = try deflate.fragments.Decoder.init(std.testing.allocator, 1024);
    defer decoder.deinit();
    var runs: SectionRuns = .{};
    var output: [1024]u8 = undefined;
    const pattern = [_]u8{ 0, 0, 0, 1, 0, 0x28, 0 };
    for (2..section_views.maximum_sections + 1) |count| {
        const fragment = runs.get(&baker, &pattern, count).?;
        try std.testing.expectEqual(fragment.bytes.ptr, runs.get(&baker, &pattern, count).?.bytes.ptr);
        const decoded = try decoder.decode(fragment, &output);
        try std.testing.expectEqual(count * pattern.len, decoded.len);
        for (0..count) |index| try std.testing.expectEqualSlices(u8, &pattern, decoded[index * pattern.len ..][0..pattern.len]);
        try std.testing.expect(fragment.bytes.len < 32);
    }
    const long: [17]u8 = @splat(1);
    try std.testing.expectEqual(null, runs.get(&baker, &long, 2));
}
