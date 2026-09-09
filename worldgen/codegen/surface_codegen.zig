const std = @import("std");
const minecraft = @import("minecraft_registry");

const RuleTag = enum { block, sequence, condition, badlands };
const ConditionTag = enum {
    biome,
    noise_threshold,
    vertical_gradient,
    y_above,
    water,
    temperature,
    steep,
    not,
    hole,
    above_preliminary_surface,
    stone_depth,
};
const AnchorTag = enum { absolute, above_bottom, below_top };

const Rule = struct {
    tag: RuleTag,
    a: u16 = 0,
    start: u16 = 0,
    len: u16 = 0,
};

const Condition = struct {
    tag: ConditionTag,
    a: u16 = 0,
    start: u16 = 0,
    len: u16 = 0,
    i0: i32 = 0,
    i1: i32 = 0,
    i2: i32 = 0,
    i3: i32 = 0,
    x: f64 = 0,
    y: f64 = 0,
};

const NoiseSpec = struct {
    id: []const u8,
    first_octave: i32,
    amplitude_start: u16,
    amplitude_len: u8,
};
const SurfaceReferences = struct {
    root: u16,
    surface_noise: u16,
    surface_secondary_noise: u16,
    clay_bands_offset_noise: u16,
    badlands_pillar_noise: u16,
    badlands_pillar_roof_noise: u16,
    badlands_surface_noise: u16,
    iceberg_pillar_noise: u16,
    iceberg_pillar_roof_noise: u16,
    iceberg_surface_noise: u16,
    terracotta: u16,
    orange_terracotta: u16,
    yellow_terracotta: u16,
    brown_terracotta: u16,
    red_terracotta: u16,
    white_terracotta: u16,
    light_gray_terracotta: u16,
    packed_ice: u16,
    snow_block: u16,
};

const Builder = struct {
    io: std.Io,
    cwd: std.Io.Dir,
    allocator: std.mem.Allocator,
    noise_dir: []const u8,
    rules: std.ArrayListUnmanaged(Rule) = .empty,
    rule_children: std.ArrayListUnmanaged(u16) = .empty,
    conditions: std.ArrayListUnmanaged(Condition) = .empty,
    biome_indices: std.ArrayListUnmanaged(u16) = .empty,
    block_states: std.ArrayListUnmanaged([]const u8) = .empty,
    biome_names: std.ArrayListUnmanaged([]const u8) = .empty,
    random_names: std.ArrayListUnmanaged([]const u8) = .empty,
    noise_specs: std.ArrayListUnmanaged(NoiseSpec) = .empty,
    amplitudes: std.ArrayListUnmanaged(f64) = .empty,

    fn appendRule(self: *Builder, value: std.json.Value) anyerror!u16 {
        const object = value.object;
        const kind = stripMinecraft((object.get("type") orelse return error.MissingSurfaceRuleType).string);
        if (std.mem.eql(u8, kind, "block")) return self.appendRuleNode(.{
            .tag = .block,
            .a = try self.blockStateIndex((object.get("result_state") orelse return error.MissingBlockState).object),
        });
        if (std.mem.eql(u8, kind, "bandlands")) return self.appendRuleNode(.{ .tag = .badlands });
        if (std.mem.eql(u8, kind, "condition")) return self.appendRuleNode(.{
            .tag = .condition,
            .a = try self.appendCondition(object.get("if_true") orelse return error.MissingSurfaceCondition),
            .start = try self.appendRule(object.get("then_run") orelse return error.MissingConditionalRule),
        });
        if (std.mem.eql(u8, kind, "sequence")) {
            const sequence = (object.get("sequence") orelse return error.MissingSurfaceSequence).array.items;
            var local: std.ArrayListUnmanaged(u16) = .empty;
            defer local.deinit(self.allocator);
            try local.ensureTotalCapacity(self.allocator, sequence.len);
            for (sequence) |child| local.appendAssumeCapacity(try self.appendRule(child));
            if (self.rule_children.items.len + local.items.len > std.math.maxInt(u16))
                return error.TooManySurfaceRuleChildren;
            const start: u16 = @intCast(self.rule_children.items.len);
            try self.rule_children.appendSlice(self.allocator, local.items);
            return self.appendRuleNode(.{
                .tag = .sequence,
                .start = start,
                .len = @intCast(local.items.len),
            });
        }
        return error.UnsupportedSurfaceRule;
    }

    fn appendCondition(self: *Builder, value: std.json.Value) anyerror!u16 {
        const object = value.object;
        const kind = stripMinecraft((object.get("type") orelse return error.MissingSurfaceConditionType).string);
        if (std.mem.eql(u8, kind, "temperature")) return self.appendConditionNode(.{ .tag = .temperature });
        if (std.mem.eql(u8, kind, "steep")) return self.appendConditionNode(.{ .tag = .steep });
        if (std.mem.eql(u8, kind, "hole")) return self.appendConditionNode(.{ .tag = .hole });
        if (std.mem.eql(u8, kind, "above_preliminary_surface"))
            return self.appendConditionNode(.{ .tag = .above_preliminary_surface });
        if (std.mem.eql(u8, kind, "not")) return self.appendConditionNode(.{
            .tag = .not,
            .a = try self.appendCondition(object.get("invert") orelse return error.MissingInvertedCondition),
        });
        if (std.mem.eql(u8, kind, "biome")) return self.appendBiomeCondition(object);
        if (std.mem.eql(u8, kind, "noise_threshold")) return self.appendConditionNode(.{
            .tag = .noise_threshold,
            .a = try self.noiseIndex((object.get("noise") orelse return error.MissingSurfaceNoise).string),
            .x = try jsonF64(object.get("min_threshold") orelse return error.MissingNoiseThreshold),
            .y = try jsonF64(object.get("max_threshold") orelse return error.MissingNoiseThreshold),
        });
        if (std.mem.eql(u8, kind, "vertical_gradient")) return self.appendVerticalGradient(object);
        if (std.mem.eql(u8, kind, "y_above")) {
            const anchor = try parseAnchor((object.get("anchor") orelse return error.MissingYAnchor).object);
            return self.appendConditionNode(.{
                .tag = .y_above,
                .i0 = @intFromEnum(anchor.tag),
                .i1 = anchor.value,
                .i2 = try jsonI32(object.get("surface_depth_multiplier") orelse return error.MissingDepthMultiplier),
                .i3 = @intFromBool(try jsonBool(object.get("add_stone_depth") orelse return error.MissingAddStoneDepth)),
            });
        }
        if (std.mem.eql(u8, kind, "water")) return self.appendConditionNode(.{
            .tag = .water,
            .i0 = try jsonI32(object.get("offset") orelse return error.MissingWaterOffset),
            .i1 = try jsonI32(object.get("surface_depth_multiplier") orelse return error.MissingDepthMultiplier),
            .i2 = @intFromBool(try jsonBool(object.get("add_stone_depth") orelse return error.MissingAddStoneDepth)),
        });
        if (std.mem.eql(u8, kind, "stone_depth")) return self.appendStoneDepth(object);
        return error.UnsupportedSurfaceCondition;
    }

    fn appendBiomeCondition(self: *Builder, object: std.json.ObjectMap) !u16 {
        const names = (object.get("biome_is") orelse return error.MissingBiomes).array.items;
        if (self.biome_indices.items.len + names.len > std.math.maxInt(u16)) return error.TooManySurfaceBiomes;
        const start: u16 = @intCast(self.biome_indices.items.len);
        for (names) |name| try self.biome_indices.append(self.allocator, try stringIndex(&self.biome_names, self.allocator, name.string));
        return self.appendConditionNode(.{ .tag = .biome, .start = start, .len = @intCast(names.len) });
    }

    fn appendVerticalGradient(self: *Builder, object: std.json.ObjectMap) !u16 {
        const lower = try parseAnchor((object.get("true_at_and_below") orelse return error.MissingGradientAnchor).object);
        const upper = try parseAnchor((object.get("false_at_and_above") orelse return error.MissingGradientAnchor).object);
        return self.appendConditionNode(.{ .tag = .vertical_gradient, .a = try stringIndex(&self.random_names, self.allocator, (object.get("random_name") orelse return error.MissingRandomName).string), .i0 = @intFromEnum(lower.tag), .i1 = lower.value, .i2 = @intFromEnum(upper.tag), .i3 = upper.value });
    }

    fn appendStoneDepth(self: *Builder, object: std.json.ObjectMap) !u16 {
        const surface_type = (object.get("surface_type") orelse return error.MissingSurfaceType).string;
        return self.appendConditionNode(.{ .tag = .stone_depth, .i0 = try jsonI32(object.get("offset") orelse return error.MissingStoneOffset), .i1 = @intFromBool(try jsonBool(object.get("add_surface_depth") orelse return error.MissingAddSurfaceDepth)), .i2 = try jsonI32(object.get("secondary_depth_range") orelse return error.MissingSecondaryDepthRange), .i3 = if (std.mem.eql(u8, surface_type, "ceiling")) 1 else if (std.mem.eql(u8, surface_type, "floor")) 0 else return error.InvalidSurfaceType });
    }

    fn appendRuleNode(self: *Builder, rule: Rule) !u16 {
        if (self.rules.items.len >= std.math.maxInt(u16)) return error.TooManySurfaceRules;
        const index: u16 = @intCast(self.rules.items.len);
        try self.rules.append(self.allocator, rule);
        return index;
    }

    fn appendConditionNode(self: *Builder, condition: Condition) !u16 {
        if (self.conditions.items.len >= std.math.maxInt(u16)) return error.TooManySurfaceConditions;
        const index: u16 = @intCast(self.conditions.items.len);
        try self.conditions.append(self.allocator, condition);
        return index;
    }

    fn blockStateIndex(self: *Builder, object: std.json.ObjectMap) !u16 {
        var output = std.array_list.Managed(u8).init(self.allocator);
        try output.appendSlice((object.get("Name") orelse return error.MissingBlockName).string);
        if (object.get("Properties")) |properties_value| {
            const properties = properties_value.object;
            var keys: std.ArrayListUnmanaged([]const u8) = .empty;
            defer keys.deinit(self.allocator);
            var iterator = properties.iterator();
            while (iterator.next()) |entry| try keys.append(self.allocator, entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, stringLessThan);
            try output.append('[');
            for (keys.items, 0..) |key, index| {
                if (index != 0) try output.append(',');
                try output.appendSlice(key);
                try output.append('=');
                try output.appendSlice(properties.get(key).?.string);
            }
            try output.append(']');
        }
        return self.namedBlockStateIndex(try output.toOwnedSlice());
    }

    fn namedBlockStateIndex(self: *Builder, canonical: []const u8) !u16 {
        for (self.block_states.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, canonical)) {
                self.allocator.free(canonical);
                return @intCast(index);
            }
        }
        if (self.block_states.items.len >= std.math.maxInt(u16)) return error.TooManySurfaceStates;
        try self.block_states.append(self.allocator, canonical);
        return @intCast(self.block_states.items.len - 1);
    }

    fn noiseIndex(self: *Builder, raw_id: []const u8) !u16 {
        const id = stripMinecraft(raw_id);
        for (self.noise_specs.items, 0..) |spec, index|
            if (std.mem.eql(u8, spec.id, id)) return @intCast(index);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.noise_dir, id });
        const bytes = try self.cwd.readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        const object = parsed.value.object;
        const values = (object.get("amplitudes") orelse return error.MissingNoiseAmplitudes).array.items;
        const start: u16 = @intCast(self.amplitudes.items.len);
        for (values) |value| try self.amplitudes.append(self.allocator, try jsonF64(value));
        const index: u16 = @intCast(self.noise_specs.items.len);
        try self.noise_specs.append(self.allocator, .{
            .id = id,
            .first_octave = try jsonI32(object.get("firstOctave") orelse return error.MissingFirstOctave),
            .amplitude_start = start,
            .amplitude_len = @intCast(values.len),
        });
        return index;
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const noise_dir = args.next() orelse return error.MissingNoiseDirectory;
    const settings_path = args.next() orelse return error.MissingNoiseSettings;
    const output_path = args.next() orelse return error.MissingOutputPath;
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(init.io, settings_path, allocator, .limited(4 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const legacy_random_source = (parsed.value.object.get("legacy_random_source") orelse
        return error.MissingLegacyRandomSource).bool;
    var builder: Builder = .{
        .io = init.io,
        .cwd = cwd,
        .allocator = allocator,
        .noise_dir = noise_dir,
    };
    const references = try collectSurfaceReferences(allocator, &builder, parsed.value.object);

    try writeSurfaceOutput(allocator, init.io, cwd, output_path, &builder, legacy_random_source, references);
}

fn writeSurfaceOutput(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, output_path: []const u8, builder: *const Builder, legacy_random_source: bool, references: SurfaceReferences) !void {
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    try output.appendSlice(
        \\pub const RuleTag = enum(u8) { block, sequence, condition, badlands };
        \\pub const ConditionTag = enum(u8) { biome, noise_threshold, vertical_gradient, y_above, water, temperature, steep, not, hole, above_preliminary_surface, stone_depth };
        \\pub const Rule = struct { tag: RuleTag, a: u16, start: u16, len: u16 };
        \\pub const Condition = struct { tag: ConditionTag, a: u16, start: u16, len: u16, i0: i32, i1: i32, i2: i32, i3: i32, x: f64, y: f64 };
        \\pub const NoiseSpec = struct { id: []const u8, first_octave: i32, amplitude_start: u16, amplitude_len: u8 };
        \\
    );
    try output.print("pub const legacy_random_source = {};\n", .{legacy_random_source});
    try writeStrings(&output, "block_states", builder.block_states.items);
    try output.appendSlice("pub const canonical_state_ids = [_]u32{\n");
    for (builder.block_states.items) |state| {
        const canonical = minecraft.State.parse(state) orelse return error.UnknownBlockState;
        try output.print("    {d},\n", .{canonical.id});
    }
    try output.appendSlice("};\npub const log_or_leaves = [_]bool{\n");
    for (builder.block_states.items) |state|
        try output.print("    {},\n", .{
            std.mem.indexOf(u8, state, "_leaves[") != null or
                std.mem.indexOf(u8, state, "_log[") != null,
        });
    var state_table_size: usize = 1;
    for (0..16) |_| {
        if (state_table_size >= builder.block_states.items.len * 2) break;
        state_table_size *= 2;
    }
    if (state_table_size < builder.block_states.items.len * 2) return error.TooManySurfaceStates;
    const state_table = try allocator.alloc(u16, state_table_size);
    defer allocator.free(state_table);
    @memset(state_table, std.math.maxInt(u16));
    for (builder.block_states.items, 0..) |state, index| {
        var slot: usize = @intCast(stateNameHash(state) & (state_table_size - 1));
        var installed = false;
        for (0..state_table_size) |_| {
            if (state_table[slot] == std.math.maxInt(u16)) {
                state_table[slot] = @intCast(index);
                installed = true;
                break;
            }
            slot = (slot + 1) & (state_table_size - 1);
        }
        if (!installed) return error.SurfaceStateIndexFull;
    }
    try output.appendSlice("};\npub const state_index_table = [_]u16{\n");
    for (state_table) |index| try output.print("    {d},\n", .{index});
    try output.appendSlice(
        "};\npub fn stateIndex(comptime name: []const u8) u16 {\n" ++
            "    const index = comptime stateIndexLookup(name);\n" ++
            "    if (comptime index == null) @compileError(\"unknown surface state: \" ++ name);\n" ++
            "    return index.?;\n" ++
            "}\n" ++
            "fn stateIndexLookup(comptime name: []const u8) ?u16 {\n" ++
            "    var slot: usize = @intCast(stateNameHash(name) & (state_index_table.len - 1));\n" ++
            "    for (0..state_index_table.len) |_| {\n" ++
            "        const index = state_index_table[slot];\n" ++
            "        if (index == 65535) return null;\n" ++
            "        if (stateNameEqual(name, block_states[index])) return index;\n" ++
            "        slot = (slot + 1) & (state_index_table.len - 1);\n" ++
            "    }\n" ++
            "    return null;\n" ++
            "}\n" ++
            "fn stateNameHash(comptime name: []const u8) u64 {\n" ++
            "    var hash: u64 = 0xcbf29ce484222325;\n" ++
            "    for (name) |byte| hash = (hash ^ byte) *% 0x100000001b3;\n" ++
            "    return hash;\n" ++
            "}\n" ++
            "fn stateNameEqual(a: []const u8, b: []const u8) bool {\n" ++
            "    if (a.len != b.len) return false;\n" ++
            "    for (a, b) |left, right| if (left != right) return false;\n" ++
            "    return true;\n" ++
            "}\n\n",
    );
    try writeStrings(&output, "biome_names", builder.biome_names.items);
    try writeStrings(&output, "random_names", builder.random_names.items);
    try output.appendSlice("pub const amplitudes = [_]f64{\n");
    for (builder.amplitudes.items) |value|
        try output.print("    @bitCast(@as(u64, 0x{x:0>16})),\n", .{@as(u64, @bitCast(value))});
    try output.appendSlice("};\npub const noise_specs = [_]NoiseSpec{\n");
    for (builder.noise_specs.items) |spec| try output.print(
        "    .{{ .id = \"minecraft:{s}\", .first_octave = {d}, .amplitude_start = {d}, .amplitude_len = {d} }},\n",
        .{ spec.id, spec.first_octave, spec.amplitude_start, spec.amplitude_len },
    );
    try output.appendSlice("};\npub const biome_indices = [_]u16{\n");
    for (builder.biome_indices.items) |index| try output.print("    {d},\n", .{index});
    try output.appendSlice("};\npub const rule_children = [_]u16{\n");
    for (builder.rule_children.items) |index| try output.print("    {d},\n", .{index});
    try output.appendSlice("};\npub const conditions = [_]Condition{\n");
    for (builder.conditions.items) |condition| try output.print(
        "    .{{ .tag = .{s}, .a = {d}, .start = {d}, .len = {d}, .i0 = {d}, .i1 = {d}, .i2 = {d}, .i3 = {d}, .x = @bitCast(@as(u64, 0x{x:0>16})), .y = @bitCast(@as(u64, 0x{x:0>16})) }},\n",
        .{ @tagName(condition.tag), condition.a, condition.start, condition.len, condition.i0, condition.i1, condition.i2, condition.i3, @as(u64, @bitCast(condition.x)), @as(u64, @bitCast(condition.y)) },
    );
    try output.appendSlice("};\npub const rules = [_]Rule{\n");
    for (builder.rules.items) |rule| try output.print(
        "    .{{ .tag = .{s}, .a = {d}, .start = {d}, .len = {d} }},\n",
        .{ @tagName(rule.tag), rule.a, rule.start, rule.len },
    );
    try appendSurfaceReferences(&output, references);
    try cwd.writeFile(io, .{ .sub_path = output_path, .data = output.items });
}

fn stateNameHash(name: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (name) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    return hash;
}

fn appendSurfaceReferences(output: *std.array_list.Managed(u8), references: SurfaceReferences) !void {
    try output.print(
        \\}};
        \\pub const root: u16 = {d};
        \\pub const surface_noise: u16 = {d};
        \\pub const surface_secondary_noise: u16 = {d};
        \\pub const clay_bands_offset_noise: u16 = {d};
        \\pub const badlands_pillar_noise: u16 = {d};
        \\pub const badlands_pillar_roof_noise: u16 = {d};
        \\pub const badlands_surface_noise: u16 = {d};
        \\pub const iceberg_pillar_noise: u16 = {d};
        \\pub const iceberg_pillar_roof_noise: u16 = {d};
        \\pub const iceberg_surface_noise: u16 = {d};
        \\pub const terracotta: u16 = {d};
        \\pub const orange_terracotta: u16 = {d};
        \\pub const yellow_terracotta: u16 = {d};
        \\pub const brown_terracotta: u16 = {d};
        \\pub const red_terracotta: u16 = {d};
        \\pub const white_terracotta: u16 = {d};
        \\pub const light_gray_terracotta: u16 = {d};
        \\pub const packed_ice: u16 = {d};
        \\pub const snow_block: u16 = {d};
        \\
    ,
        .{
            references.root,
            references.surface_noise,
            references.surface_secondary_noise,
            references.clay_bands_offset_noise,
            references.badlands_pillar_noise,
            references.badlands_pillar_roof_noise,
            references.badlands_surface_noise,
            references.iceberg_pillar_noise,
            references.iceberg_pillar_roof_noise,
            references.iceberg_surface_noise,
            references.terracotta,
            references.orange_terracotta,
            references.yellow_terracotta,
            references.brown_terracotta,
            references.red_terracotta,
            references.white_terracotta,
            references.light_gray_terracotta,
            references.packed_ice,
            references.snow_block,
        },
    );
}

fn collectSurfaceReferences(allocator: std.mem.Allocator, builder: *Builder, settings: std.json.ObjectMap) !SurfaceReferences {
    return .{ .root = try builder.appendRule(settings.get("surface_rule") orelse return error.MissingSurfaceRule), .surface_noise = try builder.noiseIndex("minecraft:surface"), .surface_secondary_noise = try builder.noiseIndex("minecraft:surface_secondary"), .clay_bands_offset_noise = try builder.noiseIndex("minecraft:clay_bands_offset"), .badlands_pillar_noise = try builder.noiseIndex("minecraft:badlands_pillar"), .badlands_pillar_roof_noise = try builder.noiseIndex("minecraft:badlands_pillar_roof"), .badlands_surface_noise = try builder.noiseIndex("minecraft:badlands_surface"), .iceberg_pillar_noise = try builder.noiseIndex("minecraft:iceberg_pillar"), .iceberg_pillar_roof_noise = try builder.noiseIndex("minecraft:iceberg_pillar_roof"), .iceberg_surface_noise = try builder.noiseIndex("minecraft:iceberg_surface"), .terracotta = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:terracotta")), .orange_terracotta = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:orange_terracotta")), .yellow_terracotta = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:yellow_terracotta")), .brown_terracotta = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:brown_terracotta")), .red_terracotta = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:red_terracotta")), .white_terracotta = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:white_terracotta")), .light_gray_terracotta = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:light_gray_terracotta")), .packed_ice = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:packed_ice")), .snow_block = try builder.namedBlockStateIndex(try allocator.dupe(u8, "minecraft:snow_block")) };
}

fn writeStrings(output: *std.array_list.Managed(u8), name: []const u8, strings: []const []const u8) !void {
    try output.print("pub const {s} = [_][]const u8{{\n", .{name});
    for (strings) |value| try output.print("    \"{s}\",\n", .{value});
    try output.appendSlice("};\n");
}

fn stringIndex(list: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator, value: []const u8) !u16 {
    for (list.items, 0..) |existing, index|
        if (std.mem.eql(u8, existing, value)) return @intCast(index);
    if (list.items.len >= std.math.maxInt(u16)) return error.TooManyStrings;
    try list.append(allocator, value);
    return @intCast(list.items.len - 1);
}

const Anchor = struct { tag: AnchorTag, value: i32 };

fn parseAnchor(object: std.json.ObjectMap) !Anchor {
    if (object.get("absolute")) |value| return .{ .tag = .absolute, .value = try jsonI32(value) };
    if (object.get("above_bottom")) |value| return .{ .tag = .above_bottom, .value = try jsonI32(value) };
    if (object.get("below_top")) |value| return .{ .tag = .below_top, .value = try jsonI32(value) };
    return error.InvalidVerticalAnchor;
}

fn stripMinecraft(value: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, value, "minecraft:")) value["minecraft:".len..] else value;
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn jsonF64(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => error.InvalidNumber,
    };
}

fn jsonI32(value: std.json.Value) !i32 {
    return switch (value) {
        .integer => |number| std.math.cast(i32, number) orelse error.NumberOutOfRange,
        else => error.InvalidInteger,
    };
}

fn jsonBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidBoolean,
    };
}
