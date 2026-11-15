const std = @import("std");
const custom_data = @import("custom_data.zig");
const tags = @import("content_tags.zig");
const ids = @import("content_ids.zig");
const game_data = @import("game_data");

pub const Registries = struct {
    pub const Entry = struct {
        name: []const u8,
        nbt: []const u8,
        baseline: ?[]const u8 = null,
    };
    pub const Registry = struct {
        name: []const u8,
        synchronized: bool,
        entries: []const Entry,
        names: std.StringHashMapUnmanaged(u32),
        tags: tags.Tags,

        pub fn id(self: *const Registry, name: []const u8) ?u32 {
            return self.names.get(name);
        }
        pub fn get(self: *const Registry, name: []const u8) ?*const Entry {
            return &self.entries[self.id(name) orelse return null];
        }
    };
    values: []const Registry,
    names: std.StringHashMapUnmanaged(usize),

    pub fn get(self: *const Registries, name: []const u8) ?*const Registry {
        return &self.values[self.names.get(name) orelse return null];
    }

    pub const Presentation = struct {
        protocol: i32,
        registry: []const u8,
        name: []const u8,
        nbt: []const u8,
    };

    pub fn validatePresentations(self: *const Registries, presentations: []const Presentation) !void {
        for (presentations) |entry| {
            if (entry.protocol <= 0) return error.InvalidPresentationProtocol;
            const registry = self.get(entry.registry) orelse return error.UnknownRegistry;
            if (!registry.synchronized) return error.StaticRegistry;
            if (registry.get(entry.name) == null) return error.UnknownRegistryEntry;
            _ = try custom_data.Compound.init(entry.nbt);
        }
    }

    pub const Definition = struct { registry: []const u8, name: []const u8, nbt: []const u8 };
    pub fn prepare(allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: []const Definition, tag_definitions: []const tags.Definition) !Registries {
        return prepareSubset(allocator, scratch, &.{}, definitions, tag_definitions);
    }

    pub fn prepareSubset(allocator: std.mem.Allocator, scratch: std.mem.Allocator, selected: []const []const u8, definitions: []const Definition, tag_definitions: []const tags.Definition) !Registries {
        var registries: std.ArrayList(Registry) = .empty;
        var iterator = try game_data.snapshot.Iterator.init(game_data.registry_snapshot);
        while (try iterator.next()) |native| {
            if (selected.len > 0) {
                const included = for (selected) |name| {
                    if (std.mem.eql(u8, name, native.name)) break true;
                } else false;
                if (!included) continue;
            }
            var entries: std.ArrayList(Entry) = .empty;
            var names: std.StringHashMapUnmanaged(u32) = .empty;
            var native_entries = native.entries();
            while (try native_entries.next()) |entry| {
                if (native.synchronized) continue;
                try names.put(scratch, entry.name, @intCast(entries.items.len));
                try entries.append(scratch, .{ .name = entry.name, .nbt = entry.nbt, .baseline = entry.nbt });
            }
            for (definitions) |definition| {
                if (!std.mem.eql(u8, definition.registry, native.name)) continue;
                if (!ids.validName(definition.name)) return error.InvalidRegistryDefinition;
                _ = try custom_data.Compound.init(definition.nbt);
                if (!native.synchronized) return error.StaticRegistry;
                if (names.get(definition.name)) |index| {
                    entries.items[index].nbt = definition.nbt;
                } else {
                    try names.put(scratch, definition.name, @intCast(entries.items.len));
                    try entries.append(scratch, .{ .name = definition.name, .nbt = definition.nbt });
                }
            }
            const entry_names = try scratch.alloc([]const u8, entries.items.len);
            for (entries.items, entry_names) |entry, *name| name.* = entry.name;
            const resolved = try tags.Tags.prepare(allocator, scratch, tag_definitions, native.name, entry_names);
            var final_names: std.StringHashMapUnmanaged(u32) = .empty;
            try final_names.ensureTotalCapacity(allocator, names.count());
            var name_iterator = names.iterator();
            while (name_iterator.next()) |entry| final_names.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
            try registries.append(scratch, .{ .name = native.name, .synchronized = native.synchronized, .entries = try allocator.dupe(Entry, entries.items), .names = final_names, .tags = resolved });
        }
        var names: std.StringHashMapUnmanaged(usize) = .empty;
        try names.ensureTotalCapacity(allocator, @intCast(registries.items.len));
        for (registries.items, 0..) |registry, index| names.putAssumeCapacityNoClobber(registry.name, index);
        for (definitions) |definition| if (!names.contains(definition.registry)) return error.UnknownRegistry;
        for (tag_definitions) |definition| if (!names.contains(definition.registry)) return error.UnknownTagRegistry;
        return .{ .values = try allocator.dupe(Registry, registries.items), .names = names };
    }
};
