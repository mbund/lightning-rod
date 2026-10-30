const std = @import("std");
const provider = @import("definition_provider.zig");

const fields = .{
    .{ "items", "tags", "tags/item" },
    .{ "blocks", "tags", "tags/block" },
    .{ "dimensions", "tags", "tags/dimension_type" },
    .{ "enchantments", "tags", "tags/enchantment" },
    .{ "client", "tags", "tags" },
    .{ "dimensions", "dimensions", "dimension_type" },
    .{ "enchantments", "entries", "enchantment" },
    .{ "enchantments", "effects", "enchantment" },
    .{ "client", "entries", "" },
    .{ "crafting", "recipes", "recipe" },
    .{ "furnaces", "recipes", "recipe" },
    .{ "loot", "tables", "loot_table" },
    .{ "book", "unlocks", "advancement" },
};

pub fn resources(deps: provider.Dependencies, allocator: std.mem.Allocator) ![]const []const u8 {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    inline for (fields) |field| {
        const registry = &@field(deps, field[0]).registry;
        for (registry.contributions()) |source| {
            for (@field(source.definitions, field[1])) |entry| try names.put(allocator, try resourceName(@TypeOf(entry), allocator, field[2], entry), {});
        }
    }
    const result = try allocator.alloc([]const u8, names.count());
    var iterator = names.keyIterator();
    var count: usize = 0;
    while (iterator.next()) |name| {
        result[count] = name.*;
        count += 1;
    }
    return result;
}

pub fn exclusions(deps: provider.Dependencies, allocator: std.mem.Allocator, blocked: []const []const u8) !provider.Exclusions {
    if (blocked.len == 0) return .{};
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (blocked) |name| try names.put(allocator, name, {});
    var result: provider.Exclusions = .{};
    inline for (@typeInfo(provider.Exclusions).@"struct".fields) |owner| {
        const T = @typeInfo(owner.type).pointer.child;
        var entries: std.ArrayList(T) = .empty;
        inline for (fields) |field| {
            if (comptime std.mem.eql(u8, field[0], owner.name)) {
                const registry = &@field(deps, owner.name).registry;
                for (registry.contributions()) |source| {
                    for (@field(source.definitions, field[1])) |entry| {
                        if (!names.contains(try resourceName(@TypeOf(entry), allocator, field[2], entry))) continue;
                        try entries.append(allocator, .{
                            .field = @field(std.meta.FieldEnum(@TypeOf(source.definitions)), field[1]),
                            .name = entry.name,
                            .registry = if (@hasField(@TypeOf(entry), "registry")) entry.registry else "",
                        });
                    }
                }
            }
        }
        @field(result, owner.name) = entries.items;
    }
    return result;
}

fn resourceName(comptime T: type, allocator: std.mem.Allocator, comptime directory: []const u8, entry: T) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, entry.name, ':').?;
    var path = directory;
    if (comptime @hasField(T, "registry")) {
        const registry = entry.registry[std.mem.indexOfScalar(u8, entry.registry, ':').? + 1 ..];
        if (directory.len == 0) path = registry;
        if (std.mem.eql(u8, directory, "tags")) path = try std.fmt.allocPrint(allocator, "tags/{s}", .{registry});
    }
    return std.fmt.allocPrint(allocator, "{s}:{s}/{s}.json", .{ entry.name[0..colon], path, entry.name[colon + 1 ..] });
}
