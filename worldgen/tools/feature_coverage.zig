const std = @import("std");

const maximum_json_bytes = 16 * 1024 * 1024;
const maximum_features = 512;

const MissingKind = struct {
    name: []const u8,
    count: usize,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const manifest_path = args.next() orelse return error.MissingManifestPath;
    const overworld_biomes_path = args.next() orelse return error.MissingOverworldBiomesPath;
    const biome_path = args.next() orelse return error.MissingBiomePath;
    const placed_feature_path = args.next() orelse return error.MissingPlacedFeaturePath;
    const configured_feature_path = args.next() orelse return error.MissingConfiguredFeaturePath;
    if (args.next() != null) return error.UnexpectedArgument;

    const cwd = std.Io.Dir.cwd();
    const implemented = try readImplemented(allocator, init.io, cwd, manifest_path);
    const biome_names = try readBiomeNames(allocator, init.io, cwd, overworld_biomes_path);
    const referenced = try readReferencedFeatures(allocator, init.io, cwd, biome_path, biome_names);
    const missing = try reportMissing(allocator, init.io, cwd, implemented, referenced, placed_feature_path, configured_feature_path);
    std.debug.print(
        "Overworld biome feature coverage: biomes={d} implemented={d} referenced={d} missing={d}\n",
        .{ biome_names.len, referenced.len - missing, referenced.len, missing },
    );
}

fn readImplemented(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) ![]const []const u8 {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(maximum_json_bytes));
    const manifest = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    var implemented: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectNamedFeatures(allocator, manifest.value, &implemented);
    return implemented.items;
}

fn readBiomeNames(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) ![]const []const u8 {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(maximum_json_bytes));
    const overworld = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectObjectStrings(allocator, overworld.value, "biome", &names);
    return names.items;
}

fn readReferencedFeatures(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, biome_path: []const u8, biome_names: []const []const u8) ![]const []const u8 {
    var referenced: std.ArrayListUnmanaged([]const u8) = .empty;
    var directory = try cwd.openDir(io, biome_path, .{ .iterate = true });
    defer directory.close(io);
    for (biome_names) |biome_name| try collectBiomeFeatures(allocator, io, &directory, biome_name, &referenced);
    std.mem.sort([]const u8, referenced.items, {}, lessThan);
    return referenced.items;
}

fn collectBiomeFeatures(allocator: std.mem.Allocator, io: std.Io, directory: *std.Io.Dir, biome_name: []const u8, referenced: *std.ArrayListUnmanaged([]const u8)) !void {
    const relative = if (std.mem.startsWith(u8, biome_name, "minecraft:")) biome_name["minecraft:".len..] else biome_name;
    const path = try std.fmt.allocPrint(allocator, "{s}.json", .{relative});
    const bytes = try directory.readFileAlloc(io, path, allocator, .limited(maximum_json_bytes));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const steps = (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
    for (steps) |step| for (step.array.items) |feature| try appendUnique(allocator, referenced, feature.string);
}

fn reportMissing(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, implemented: []const []const u8, referenced: []const []const u8, placed_feature_path: []const u8, configured_feature_path: []const u8) !usize {
    var missing: usize = 0;
    var configured_types: std.ArrayListUnmanaged(MissingKind) = .empty;
    var placement_types: std.ArrayListUnmanaged(MissingKind) = .empty;
    for (referenced.items) |feature| {
        if (contains(implemented.items, feature)) continue;
        missing += 1;
        const relative = if (std.mem.startsWith(u8, feature, "minecraft:")) feature["minecraft:".len..] else feature;
        const placed_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ placed_feature_path, relative });
        const placed_bytes = try cwd.readFileAlloc(io, placed_path, allocator, .limited(maximum_json_bytes));
        const placed = try std.json.parseFromSlice(std.json.Value, allocator, placed_bytes, .{});
        const configured_name = (placed.value.object.get("feature") orelse
            return error.MissingConfiguredFeature).string;
        const configured_relative = if (std.mem.startsWith(u8, configured_name, "minecraft:"))
            configured_name["minecraft:".len..]
        else
            configured_name;
        const configured_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ configured_feature_path, configured_relative },
        );
        const configured_bytes = try cwd.readFileAlloc(
            io,
            configured_path,
            allocator,
            .limited(maximum_json_bytes),
        );
        const configured = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            configured_bytes,
            .{},
        );
        const configured_type = (configured.value.object.get("type") orelse
            return error.MissingConfiguredFeatureType).string;
        try incrementKind(allocator, &configured_types, configured_type);
        const placements = (placed.value.object.get("placement") orelse
            return error.MissingPlacements).array.items;
        for (placements) |placement| {
            const placement_type = (placement.object.get("type") orelse
                return error.MissingPlacementType).string;
            try incrementKind(allocator, &placement_types, placement_type);
        }
        std.debug.print(
            "missing {s} configured={s}\n",
            .{ feature, configured_type },
        );
    }
    printKinds("Missing configured feature types", configured_types.items);
    printKinds("Placement modifiers used by missing features", placement_types.items);
    return missing;
}

fn collectObjectStrings(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    field: []const u8,
    output: *std.ArrayListUnmanaged([]const u8),
) !void {
    switch (value) {
        .object => |object| {
            if (object.get(field)) |entry| if (entry == .string)
                try appendUnique(allocator, output, entry.string);
            var iterator = object.iterator();
            while (iterator.next()) |entry|
                try collectObjectStrings(allocator, entry.value_ptr.*, field, output);
        },
        .array => |array| for (array.items) |entry|
            try collectObjectStrings(allocator, entry, field, output),
        else => {},
    }
}

fn incrementKind(
    allocator: std.mem.Allocator,
    kinds: *std.ArrayListUnmanaged(MissingKind),
    name: []const u8,
) !void {
    for (kinds.items) |*kind| if (std.mem.eql(u8, kind.name, name)) {
        kind.count += 1;
        return;
    };
    try kinds.append(allocator, .{ .name = try allocator.dupe(u8, name), .count = 1 });
}

fn printKinds(label: []const u8, kinds: []MissingKind) void {
    std.mem.sort(MissingKind, kinds, {}, lessKind);
    std.debug.print("{s}:\n", .{label});
    for (kinds) |kind| std.debug.print("  {s}: {d}\n", .{ kind.name, kind.count });
}

fn lessKind(_: void, left: MissingKind, right: MissingKind) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn collectNamedFeatures(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    output: *std.ArrayListUnmanaged([]const u8),
) !void {
    switch (value) {
        .object => |object| {
            if (object.get("name")) |name| if (name == .string and
                std.mem.startsWith(u8, name.string, "minecraft:"))
                try appendUnique(allocator, output, name.string);
            var iterator = object.iterator();
            while (iterator.next()) |entry| try collectNamedFeatures(
                allocator,
                entry.value_ptr.*,
                output,
            );
        },
        .array => |array| for (array.items) |item|
            try collectNamedFeatures(allocator, item, output),
        else => {},
    }
}

fn appendUnique(
    allocator: std.mem.Allocator,
    values: *std.ArrayListUnmanaged([]const u8),
    value: []const u8,
) !void {
    if (contains(values.items, value)) return;
    if (values.items.len == maximum_features) return error.TooManyFeatures;
    try values.append(allocator, try allocator.dupe(u8, value));
}

fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| if (std.mem.eql(u8, candidate, value)) return true;
    return false;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
