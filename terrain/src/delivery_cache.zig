const std = @import("std");
const chunks = @import("chunks");
const records = @import("records");
const packets = @import("minecraft_packets");
const sessions = @import("sessions");
const game_data = @import("game_data");
const deflate = @import("deflate");
const assert = std.debug.assert;
const metrics = @import("metrics");

pub const batch_max = 32;
pub const Codec = struct { number: i32, fluids: bool, registry: packets.Registry };
pub const Variant = struct { identity: [32]u8, codec: Codec, definition: *const sessions.Protocol };

pub const Catalog = struct {
    const Protocol = struct { number: i32, variant: usize };
    variants: []Variant,
    protocols: []Protocol,
    definitions: []const sessions.Protocol,
    codecs: []Codec,
    initialized: bool = false,
    metrics: struct {
        hits: metrics.Counter = .{},
        misses: metrics.Counter = .{},
        compiled_bytes: metrics.Counter = .{},
        compilation: metrics.Timer = .{},
        /// Compiles from unbaked sections, which cannot be stored and are rebuilt on every delivery.
        transient_compiles: metrics.Counter = .{},
        /// Unbaked columns whose disclosed sections are all uniform, so no record is looked up.
        unbaked_uniform: metrics.Counter = .{},
    } = .{},

    pub fn init(allocator: std.mem.Allocator, definitions: []const sessions.Protocol, codecs: []const Codec) !Catalog {
        const variants = try allocator.alloc(Variant, definitions.len);
        const protocols = try allocator.alloc(Protocol, definitions.len);
        const selected = try allocator.alloc(Codec, definitions.len);
        for (definitions, selected) |definition, *codec| {
            codec.* = for (codecs) |candidate| {
                if (candidate.number == definition.number) break candidate;
            } else return error.UnsupportedProtocol;
        }
        return .{ .variants = variants, .protocols = protocols, .definitions = definitions, .codecs = selected };
    }

    fn prepare(self: *Catalog) !void {
        if (self.initialized) return;
        const variants = self.variants;
        var count: usize = 0;
        for (self.definitions, self.protocols, self.codecs) |*definition, *protocol, codec| {
            var hash = std.crypto.hash.Blake3.init(.{});
            hash.update("lightning_rod:delivery:2");
            hash.update(&game_data.canonical_identity);
            hash.update(&.{ @intFromBool(codec.fluids), codec.registry.block_state_bits });
            var integer: [4]u8 = undefined;
            std.mem.writeInt(u32, &integer, @intCast(codec.registry.block_states.len), .little);
            hash.update(&integer);
            for (codec.registry.block_states) |state| {
                std.mem.writeInt(i32, &integer, state, .little);
                hash.update(&integer);
            }
            for ([_][]const u8{ "minecraft:worldgen/biome", "minecraft:block_entity_type" }) |name| {
                const entries = for (definition.registries) |registry| {
                    if (std.mem.eql(u8, registry.name, name)) break registry.entries;
                } else &.{};
                std.mem.writeInt(u32, &integer, @intCast(entries.len), .little);
                hash.update(&integer);
                for (entries) |entry| {
                    std.mem.writeInt(u32, &integer, @intCast(entry.len), .little);
                    hash.update(&integer);
                    hash.update(entry);
                }
            }
            var identity: [32]u8 = undefined;
            hash.final(&identity);
            const variant = for (variants[0..count], 0..) |selected, candidate_index| {
                if (std.mem.eql(u8, &selected.identity, &identity)) break candidate_index;
            } else new: {
                variants[count] = .{ .identity = identity, .codec = codec, .definition = definition };
                count += 1;
                break :new count - 1;
            };
            protocol.* = .{ .number = definition.number, .variant = variant };
        }
        self.variants = variants[0..count];
        self.initialized = true;
    }

    pub fn index(self: *Catalog, number: i32) !usize {
        try self.prepare();
        for (self.protocols) |protocol| if (protocol.number == number) return protocol.variant;
        return error.UnsupportedProtocol;
    }
};

pub const Request = struct { column: chunks.Light.Column, protocol: i32 };
pub const Lookup = union(enum) { ready: chunks.Delivery.View, missing: usize, deferred };

pub const Workspace = struct {
    catalog: *Catalog = undefined,
    read_bank: []u8,
    write_bank: []u8,
    plain: []u8,
    fragment: []u8,
    baker: deflate.fragments.Baker,
    columns: [batch_max]chunks.Light.Column = undefined,
    keys: [batch_max][chunks.Delivery.key_bytes]u8 = undefined,
    values: [batch_max]?[]const u8 = undefined,
    complete: [batch_max]bool = undefined,
    compiled: [batch_max]bool = @splat(false),
    /// Bundles verified once per batch, since sizing output and encoding both read them.
    parsed: [batch_max]?chunks.Delivery.Column = undefined,
    writes: [batch_max]records.Write = undefined,
    write_count: usize = 0,
    count: usize = 0,
    used: usize = 0,
    output: records.PackedRead = undefined,
    batch: chunks.Delivery.ReadBatch = undefined,
    active: bool = false,
    /// Compile every encoding a column lacks along with the requested one. Prewarming sets
    /// this. Serving leaves each encoding for its first client.
    eager: bool = false,
    generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, protocols: usize) !*Workspace {
        assert(protocols > 0);
        // One complete encoding guarantees progress. Other variants share the remaining space.
        const capacity = try std.math.add(usize, try chunks.Delivery.Column.bound(1), try std.math.mul(usize, protocols - 1, chunks.Delivery.Column.entry_size));
        const self = try allocator.create(Workspace);
        self.* = .{
            .read_bank = try allocator.alloc(u8, capacity),
            .write_bank = try allocator.alloc(u8, capacity),
            .plain = try allocator.alloc(u8, 1 << 21),
            .fragment = try allocator.alloc(u8, 65536),
            .baker = try .init(allocator),
        };
        return self;
    }

    pub fn begin(self: *Workspace, catalog: *Catalog, input: []const Request) !*chunks.Delivery.ReadBatch {
        assert(input.len <= batch_max and self.write_count == 0 and !self.active and self.generation < std.math.maxInt(u64));
        self.active = true;
        errdefer self.active = false;
        self.catalog = catalog;
        self.generation += 1;
        self.count = 0;
        self.used = 0;
        self.compiled = @splat(false);
        for (input) |request| {
            _ = try self.catalog.index(request.protocol);
            var duplicate = false;
            for (self.columns[0..self.count]) |column| {
                if (std.meta.eql(column, request.column)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            self.columns[self.count] = request.column;
            self.keys[self.count] = chunks.Delivery.key(request.column);
            self.count += 1;
        }
        @memset(self.values[0..self.count], null);
        @memset(self.parsed[0..self.count], null);
        @memset(self.complete[0..self.count], true);
        self.output = .{ .bytes = self.read_bank, .values = self.values[0..self.count], .complete = self.complete[0..self.count], .prefix_bytes = self.read_bank.len };
        self.batch = .{ .keys = self.keys[0..self.count], .output = &self.output };
        return &self.batch;
    }

    pub fn lookup(self: *Workspace, column: chunks.Light.Column, protocol: i32, source: chunks.Delivery.Source, persistent: bool) !Lookup {
        assert(self.active);
        const variant = try self.catalog.index(protocol);
        for (self.columns[0..self.count], 0..) |selected, slot| {
            if (!std.meta.eql(selected, column)) continue;
            if (persistent and !self.complete[slot]) return .deferred;
            if (persistent or self.compiled[slot]) if (self.values[slot] != null) {
                const bundle = self.storedBundle(slot) orelse {
                    self.catalog.metrics.misses.add(1);
                    return .{ .missing = slot };
                };
                if (!std.meta.eql(bundle.column, column)) {
                    self.catalog.metrics.misses.add(1);
                    return .{ .missing = slot };
                }
                const record = bundle.find(self.catalog.variants[variant].identity) orelse {
                    self.catalog.metrics.misses.add(1);
                    return .{ .missing = slot };
                };
                const view = chunks.Delivery.View.read(record, source) catch {
                    self.catalog.metrics.misses.add(1);
                    return .{ .missing = slot };
                };
                self.catalog.metrics.hits.add(1);
                return .{ .ready = view };
            };
            self.catalog.metrics.misses.add(1);
            return .{ .missing = slot };
        }
        unreachable;
    }

    /// The stored bundle read for this slot, verified once per batch.
    pub fn storedBundle(self: *Workspace, slot: usize) ?chunks.Delivery.Column {
        assert(self.active and slot < self.count);
        if (self.parsed[slot]) |parsed| return parsed;
        const bytes = self.values[slot] orelse return null;
        const parsed = chunks.Delivery.Column.read(bytes) catch return null;
        self.parsed[slot] = parsed;
        return parsed;
    }

    /// The packet bound a stored record declares for this column and protocol, or null when
    /// the batch read found none. Call after the batch read completes.
    pub fn packetBound(self: *Workspace, column: chunks.Light.Column, protocol: i32) !?usize {
        assert(self.active);
        const variant = try self.catalog.index(protocol);
        for (self.columns[0..self.count], 0..) |selected, slot| {
            if (!std.meta.eql(selected, column)) continue;
            if (!self.complete[slot]) return null;
            const stored = self.storedBundle(slot) orelse return null;
            if (!std.meta.eql(stored.column, column)) return null;
            const identity = self.catalog.variants[variant].identity;
            const record = stored.find(identity) orelse return null;
            const maximum = chunks.Delivery.View.declaredMaximum(record) orelse return null;
            return maximum;
        }
        return null;
    }

    /// The batch slot of a requested column.
    pub fn slotOf(self: *const Workspace, column: chunks.Light.Column) usize {
        assert(self.active);
        for (self.columns[0..self.count], 0..) |selected, slot| {
            if (std.meta.eql(selected, column)) return slot;
        }
        unreachable;
    }

    pub fn destination(self: *Workspace) []u8 {
        assert(self.active and self.used <= self.write_bank.len);
        return self.write_bank[self.used..];
    }

    pub fn commit(self: *Workspace, slot: usize, bytes: []const u8, persistent: bool) void {
        assert(self.active);
        assert(slot < self.count and bytes.ptr == self.write_bank[self.used..].ptr and bytes.len <= self.write_bank.len - self.used);
        assert(std.meta.eql((chunks.Delivery.Column.read(bytes) catch unreachable).column, self.columns[slot]));
        self.catalog.metrics.compiled_bytes.add(bytes.len);
        self.used += bytes.len;
        self.values[slot] = bytes;
        self.parsed[slot] = null;
        self.complete[slot] = true;
        self.compiled[slot] = true;
        if (persistent) {
            // A column compiled for another encoding in the same batch supersedes its earlier
            // bundle. A second write under the same key would leave the table to pick one.
            const key: []const u8 = &self.keys[slot];
            const write = for (self.writes[0..self.write_count]) |*pending| {
                if (pending.key.ptr == key.ptr) break pending;
            } else added: {
                assert(self.write_count < self.count);
                self.write_count += 1;
                break :added &self.writes[self.write_count - 1];
            };
            write.* = .{ .key = key, .value = bytes };
        }
    }

    pub fn finish(self: *Workspace, terrain: ?*chunks.Chunks) !void {
        assert(self.active);
        if (terrain) |store| try store.putDeliveryRecords(self.writes[0..self.write_count]);
        self.cancel();
    }

    pub fn cancel(self: *Workspace) void {
        self.write_count = 0;
        self.count = 0;
        self.active = false;
    }
};

test "delivery variants share effective encodings and observe configuration completed after initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mappings = [_]i32{ 0, 1, 2 };
    const registry: packets.Registry = .{ .block_states = &mappings, .block_state_bits = 15, .entities = &.{}, .items = &.{}, .blocks = &.{}, .sounds = &.{}, .effects = &.{}, .attributes = &.{} };
    const base = [_]sessions.Protocol.Registry{
        .{ .name = "minecraft:worldgen/biome", .entries = &.{ "minecraft:plains", "minecraft:desert" } },
        .{ .name = "minecraft:block_entity_type", .entries = &.{"minecraft:chest"} },
    };
    const reordered = [_]sessions.Protocol.Registry{
        .{ .name = "minecraft:worldgen/biome", .entries = &.{ "minecraft:desert", "minecraft:plains" } },
        base[1],
    };
    var definitions = [_]sessions.Protocol{ .{ .number = 1, .registries = &base }, .{ .number = 2, .registries = &base }, .{ .number = 3, .registries = &base }, .{ .number = 4, .registries = &base } };
    const codecs = [_]Codec{ .{ .number = 1, .fluids = false, .registry = registry }, .{ .number = 2, .fluids = false, .registry = registry }, .{ .number = 3, .fluids = true, .registry = registry }, .{ .number = 4, .fluids = false, .registry = registry } };
    var catalog = try Catalog.init(arena.allocator(), &definitions, &codecs);
    definitions[3].registries = &reordered;
    try std.testing.expectEqual(try catalog.index(1), try catalog.index(2));
    try std.testing.expect(try catalog.index(1) != try catalog.index(3));
    try std.testing.expect(try catalog.index(1) != try catalog.index(4));
    try std.testing.expectEqual(@as(usize, 3), catalog.variants.len);
    const original = catalog.variants[try catalog.index(1)].identity;
    mappings[1] = 7;
    var changed = try Catalog.init(arena.allocator(), &definitions, &codecs);
    const updated = changed.variants[try changed.index(1)].identity;
    try std.testing.expect(!std.mem.eql(u8, &original, &updated));
}
