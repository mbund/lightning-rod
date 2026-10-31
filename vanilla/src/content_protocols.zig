const std = @import("std");
const game_data = @import("game_data");
const custom_data = @import("custom_data.zig");
const native_nbt = @import("native_nbt.zig");
const content_types = @import("content_types.zig");
const vanilla_definitions = @import("vanilla_definitions");
const Registries = @import("content_registries.zig").Registries;

pub fn configure(registries: *const Registries, presentations: []const Registries.Presentation, comptime Catalog: type, allocator: std.mem.Allocator, catalog: *Catalog) !void {
    var temporary = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    var references: std.StringHashMapUnmanaged([]const u8) = .empty;
    const baseline = vanilla_definitions.definitions(content_types.Definitions);
    for (baseline.registries) |entry| try references.put(scratch, try registryKey(scratch, entry.registry, entry.name), entry.nbt);
    for (baseline.dimension_types) |entry| try references.put(scratch, try registryKey(scratch, "minecraft:dimension_type", entry.name), try native_nbt.encode(scratch, entry.definition));
    var baseline_tags: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    for (baseline.tags) |entry| {
        const group = try baseline_tags.getOrPut(scratch, entry.registry);
        if (!group.found_existing) group.value_ptr.* = .empty;
        try group.value_ptr.put(scratch, entry.name, {});
    }
    inline for (Catalog.versions, 0..) |Version, version_index| {
        const Builder = Version.RegistryProvider.Builder;
        var snapshot = try Version.RegistryProvider.snapshot(scratch);
        const previous_registries = try scratch.dupe(Builder.Registry, snapshot.registries);
        var projected: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;
        for (presentations) |entry| {
            if (entry.protocol != Version.protocol_number) continue;
            const registry = try projected.getOrPut(scratch, entry.registry);
            if (!registry.found_existing) registry.value_ptr.* = .empty;
            try registry.value_ptr.put(scratch, entry.name, entry.nbt);
        }
        for (registries.values) |registry| {
            if (!registry.synchronized) continue;
            const exists = for (snapshot.registries) |client| {
                if (std.mem.eql(u8, client.id, registry.name)) break true;
            } else false;
            if (!exists) for (registry.entries) |source| {
                const entry = try referenceEntry(scratch, &references, registry.name, source);
                if (!unchanged(entry)) return error.UnsupportedClientRegistry;
            };
        }
        var changed = false;
        for (@constCast(snapshot.registries)) |*registry| {
            const loaded = registries.get(registry.id) orelse continue;
            if (!registry.synchronized) continue;
            const registry_presentations: std.StringHashMapUnmanaged([]const u8) = projected.get(registry.id) orelse .empty;
            var entries: std.ArrayList(Builder.RegistryEntry) = .empty;
            for (registry.entries) |entry| {
                if (references.contains(try registryKey(scratch, registry.id, entry.id)) and loaded.get(entry.id) == null) {
                    changed = true;
                    continue;
                }
                try entries.append(scratch, entry);
            }
            for (loaded.entries) |source| {
                const entry = try referenceEntry(scratch, &references, registry.id, source);
                const presentation = registry_presentations.get(entry.name);
                const definition_bytes = presentation orelse entry.nbt;
                if (std.mem.eql(u8, registry.id, "minecraft:jukebox_song")) {
                    const definition = try custom_data.Compound.init(definition_bytes);
                    const field = try definition.get("sound_event") orelse return error.MissingJukeboxSound;
                    if (field.tag == 8) {
                        const sound = (try definition.getString("sound_event", scratch)).?;
                        const sounds = for (snapshot.registries) |candidate| {
                            if (std.mem.eql(u8, candidate.id, "minecraft:sound_event")) break candidate.entries;
                        } else return error.MissingSoundRegistry;
                        // Named sound holders cannot reference sounds absent from the client registry.
                        const found = for (sounds) |candidate| {
                            if (std.mem.eql(u8, candidate.id, sound)) break true;
                        } else false;
                        if (!found) {
                            if (presentation == null and unchanged(entry)) continue;
                            return error.UnsupportedClientSound;
                        }
                    }
                }
                const reference = entry.baseline;
                var template: ?[]const u8 = null;
                for (registry.entries) |candidate| if (std.mem.eql(u8, candidate.id, entry.name)) {
                    template = candidate.nbt;
                    break;
                };
                if (template == null and std.mem.eql(u8, registry.id, "minecraft:dimension_type")) {
                    const definition = try custom_data.Compound.init(definition_bytes);
                    const effects = try definition.getString("effects", scratch) orelse return error.MissingDimensionEffects;
                    template = for (registry.entries) |candidate| {
                        if (std.mem.eql(u8, candidate.id, effects)) break candidate.nbt;
                    } else null;
                    if (template == null) for (registry.entries) |candidate| {
                        const metadata = try custom_data.Compound.init(candidate.nbt);
                        const rendering = try metadata.getString("effects", scratch) orelse continue;
                        if (std.mem.eql(u8, rendering, effects)) {
                            template = candidate.nbt;
                            break;
                        }
                    };
                    if (template == null) return error.UnknownDimensionEffects;
                }
                const nbt = presentation orelse try project(scratch, reference, template, entry.nbt);
                const replaced = for (entries.items) |*previous| {
                    if (!std.mem.eql(u8, previous.id, entry.name)) continue;
                    changed = changed or !std.mem.eql(u8, previous.nbt, nbt);
                    previous.nbt = nbt;
                    break true;
                } else false;
                if (!replaced) {
                    try entries.append(scratch, .{ .id = entry.name, .nbt = nbt });
                    changed = true;
                }
            }
            registry.entries = entries.items;
        }
        var groups = try readTags(scratch, snapshot.tags);
        for (snapshot.registries) |registry| {
            const loaded = registries.get(registry.id) orelse continue;
            const group_index = for (groups.items, 0..) |group, index| {
                if (std.mem.eql(u8, group.name, registry.id)) break index;
            } else blk: {
                try groups.append(scratch, .{ .name = registry.id });
                break :blk groups.items.len - 1;
            };
            const group = &groups.items[group_index];
            const previous = for (previous_registries) |candidate| {
                if (std.mem.eql(u8, candidate.id, registry.id)) break candidate;
            } else unreachable;
            var retained: TagGroup = .{ .name = group.name };
            var ids: std.StringHashMapUnmanaged(i32) = .empty;
            try ids.ensureTotalCapacity(scratch, @intCast(registry.entries.len));
            for (registry.entries, 0..) |entry, index| ids.putAssumeCapacityNoClobber(entry.id, @intCast(index));
            for (group.entries.items) |tag| {
                if (loaded.tags.find(tag.name) != null) continue;
                const native_tags: std.StringHashMapUnmanaged(void) = baseline_tags.get(registry.id) orelse .empty;
                if (native_tags.contains(tag.name)) continue;
                var values: std.ArrayList(i32) = .empty;
                for (tag.values) |member| {
                    if (member < 0 or member >= previous.entries.len) return error.InvalidTag;
                    if (ids.get(previous.entries[@intCast(member)].id)) |id| try values.append(scratch, id);
                }
                try retained.put(scratch, .{ .name = tag.name, .values = values.items });
            }
            group.* = retained;
            for (loaded.tags.entries) |tag| {
                var values: std.ArrayList(i32) = .empty;
                for (tag.values) |member| if (ids.get(loaded.entries[member].name)) |selected| try values.append(scratch, selected);
                try group.put(scratch, .{ .name = tag.name, .values = values.items });
            }
        }
        const tags = try writeTags(scratch, groups.items);
        changed = changed or !std.mem.eql(u8, snapshot.tags, tags);
        snapshot.tags = tags;
        const prepared = if (changed)
            try Builder.build(allocator, Version.protocol_number, snapshot)
        else
            try Version.RegistryProvider.init(allocator);
        catalog.prepared[version_index].deinit(allocator);
        catalog.prepared[version_index] = prepared;
        catalog.values[version_index] = prepared.configurationData();
        catalog.values[version_index].frame_bound = Version.Connection.Wire.frame_bound;
    }
}

fn registryKey(allocator: std.mem.Allocator, registry: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ registry, name });
}

fn referenceEntry(allocator: std.mem.Allocator, references: *const std.StringHashMapUnmanaged([]const u8), registry: []const u8, source: Registries.Entry) !Registries.Entry {
    if (unchanged(source)) return source;
    var entry = source;
    entry.baseline = references.get(try registryKey(allocator, registry, source.name)) orelse source.baseline;
    return entry;
}

fn unchanged(entry: Registries.Entry) bool {
    const baseline = entry.baseline orelse return false;
    return std.mem.eql(u8, entry.nbt, baseline);
}

fn project(allocator: std.mem.Allocator, reference: ?[]const u8, template: ?[]const u8, definition: []const u8) ![]const u8 {
    const native = template orelse return definition;
    // Client schemas can add required fields or change representations between versions.
    // Unchanged baseline fields retain their client representation regardless of pack provenance.
    if (reference) |original| if (std.mem.eql(u8, original, definition)) return native;
    var editor = try (try custom_data.Compound.init(native)).edit(allocator);
    const loaded = try custom_data.Compound.init(definition);
    const baseline: ?custom_data.Compound = if (reference) |bytes| try .init(bytes) else null;
    var fields = loaded.fields();
    while (try fields.next()) |field| {
        if (baseline) |original| if (try original.get(field.name)) |previous| {
            if (previous.tag == field.tag and std.mem.eql(u8, previous.payload, field.payload)) continue;
        };
        try editor.put(field);
    }
    if (baseline) |original| {
        var previous = original.fields();
        while (try previous.next()) |field| if (try loaded.get(field.name) == null) try editor.remove(field.name);
    }
    return editor.finish();
}

const Tag = struct { name: []const u8, values: []const i32 };
const TagGroup = struct {
    name: []const u8,
    entries: std.ArrayList(Tag) = .empty,
    names: std.StringHashMapUnmanaged(usize) = .empty,

    fn put(self: *TagGroup, allocator: std.mem.Allocator, tag: Tag) !void {
        const entry = try self.names.getOrPut(allocator, tag.name);
        if (entry.found_existing) {
            self.entries.items[entry.value_ptr.*] = tag;
        } else {
            entry.value_ptr.* = self.entries.items.len;
            try self.entries.append(allocator, tag);
        }
    }
};

fn readInteger(bytes: *[]const u8) !i32 {
    const value, const rest = try game_data.encoding.read_varint(bytes.*);
    bytes.* = rest;
    if (value < 0) return error.InvalidTagPacket;
    return value;
}

fn readString(bytes: *[]const u8) ![]const u8 {
    const length: usize = @intCast(try readInteger(bytes));
    if (length > bytes.len) return error.InvalidTagPacket;
    const value = bytes.*[0..length];
    bytes.* = bytes.*[length..];
    return value;
}

fn readTags(allocator: std.mem.Allocator, encoded: []const u8) !std.ArrayList(TagGroup) {
    var bytes = encoded;
    const count: usize = @intCast(try readInteger(&bytes));
    if (count > bytes.len / 2) return error.InvalidTagPacket;
    var groups: std.ArrayList(TagGroup) = .empty;
    for (0..count) |_| {
        var group: TagGroup = .{ .name = try readString(&bytes) };
        const tags: usize = @intCast(try readInteger(&bytes));
        if (tags > bytes.len / 2) return error.InvalidTagPacket;
        for (0..tags) |_| {
            const name = try readString(&bytes);
            const members: usize = @intCast(try readInteger(&bytes));
            if (members > bytes.len) return error.InvalidTagPacket;
            const values = try allocator.alloc(i32, members);
            for (values) |*value| value.* = try readInteger(&bytes);
            if (group.names.contains(name)) return error.InvalidTagPacket;
            try group.put(allocator, .{ .name = name, .values = values });
        }
        for (groups.items) |previous| if (std.mem.eql(u8, previous.name, group.name)) return error.InvalidTagPacket;
        try groups.append(allocator, group);
    }
    if (bytes.len != 0) return error.InvalidTagPacket;
    return groups;
}

fn writeTags(allocator: std.mem.Allocator, groups: []const TagGroup) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try writeInteger(&output.writer, @intCast(groups.len));
    for (groups) |group| {
        try writeString(&output.writer, group.name);
        try writeInteger(&output.writer, @intCast(group.entries.items.len));
        for (group.entries.items) |tag| {
            try writeString(&output.writer, tag.name);
            try writeInteger(&output.writer, @intCast(tag.values.len));
            for (tag.values) |member| try writeInteger(&output.writer, member);
        }
    }
    return output.written();
}

fn writeInteger(writer: *std.Io.Writer, value: i32) !void {
    var bytes: [5]u8 = undefined;
    const rest = try game_data.encoding.write_varint(&bytes, value);
    try writer.writeAll(bytes[0 .. bytes.len - rest.len]);
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try writeInteger(writer, @intCast(value.len));
    try writer.writeAll(value);
}

test "protocol projection preserves client defaults and applies definition edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const reference = try native_nbt.encode(allocator, .{ .asset_id = @as([]const u8, "original"), .optional = @as(i32, 1) });
    const template = try native_nbt.encode(allocator, .{ .asset_id = @as([]const u8, "client-original"), .baby_asset_id = @as([]const u8, "baby"), .optional = @as(i32, 2) });
    try std.testing.expectEqualSlices(u8, template, try project(allocator, reference, template, reference));
    const edited = try native_nbt.encode(allocator, .{ .asset_id = @as([]const u8, "custom") });
    const actual = try custom_data.Compound.init(try project(allocator, reference, template, edited));
    try std.testing.expectEqualStrings("custom", (try actual.getString("asset_id", allocator)).?);
    try std.testing.expectEqualStrings("baby", (try actual.getString("baby_asset_id", allocator)).?);
    try std.testing.expect(try actual.get("optional") == null);
    try std.testing.expectEqualSlices(u8, edited, try project(allocator, reference, null, edited));
}
