const std = @import("std");

const block_symbols = [_][]const u8{ "stone", "grass_block", "dirt", "netherrack", "end_stone" };

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const blocks_path = args.next() orelse return error.MissingBlocksPath;
    const items_path = args.next() orelse return error.MissingItemsPath;
    const entities_path = args.next() orelse return error.MissingEntitiesPath;
    const sounds_path = args.next() orelse return error.MissingSoundsPath;
    const materials_path = args.next() orelse return error.MissingMaterialsPath;
    const collision_shapes_path = args.next() orelse return error.MissingCollisionShapesPath;
    const enchantments_path = args.next() orelse return error.MissingEnchantmentsPath;
    const protocol_path = args.next() orelse return error.MissingProtocolPath;
    const biomes_path = args.next() orelse return error.MissingBiomesPath;
    const effects_path = args.next() orelse return error.MissingEffectsPath;
    const attributes_path = args.next() orelse return error.MissingAttributesPath;
    const canonical_blocks_path = args.next() orelse return error.MissingCanonicalBlocksPath;
    const canonical_items_path = args.next() orelse return error.MissingCanonicalItemsPath;
    const canonical_entities_path = args.next() orelse return error.MissingCanonicalEntitiesPath;
    const canonical_sounds_path = args.next() orelse return error.MissingCanonicalSoundsPath;
    const canonical_effects_path = args.next() orelse return error.MissingCanonicalEffectsPath;
    const canonical_attributes_path = args.next() orelse return error.MissingCanonicalAttributesPath;
    const canonical_snapshot_path = args.next() orelse return error.MissingCanonicalSnapshotPath;
    const output_path = args.next() orelse return error.MissingOutputPath;

    const cwd = std.Io.Dir.cwd();
    const blocks = try parseFile(init.io, cwd, allocator, blocks_path);
    const items = try parseFile(init.io, cwd, allocator, items_path);
    const entities = try parseFile(init.io, cwd, allocator, entities_path);
    const sounds = try parseFile(init.io, cwd, allocator, sounds_path);
    const materials = try parseFile(init.io, cwd, allocator, materials_path);
    const collision_shapes = try parseFile(init.io, cwd, allocator, collision_shapes_path);
    const enchantments = try parseFile(init.io, cwd, allocator, enchantments_path);
    const protocol = try parseFile(init.io, cwd, allocator, protocol_path);
    const biomes = try parseFile(init.io, cwd, allocator, biomes_path);
    const effects = try parseFile(init.io, cwd, allocator, effects_path);
    const attributes = try parseFile(init.io, cwd, allocator, attributes_path);
    const canonical_blocks = if (std.mem.eql(u8, blocks_path, canonical_blocks_path)) blocks else try parseFile(init.io, cwd, allocator, canonical_blocks_path);
    const canonical_items = if (std.mem.eql(u8, items_path, canonical_items_path)) items else try parseFile(init.io, cwd, allocator, canonical_items_path);
    const canonical_entities = if (std.mem.eql(u8, entities_path, canonical_entities_path)) entities else try parseFile(init.io, cwd, allocator, canonical_entities_path);
    const canonical_sounds = if (std.mem.eql(u8, sounds_path, canonical_sounds_path)) sounds else try parseFile(init.io, cwd, allocator, canonical_sounds_path);
    const canonical_effects = if (std.mem.eql(u8, effects_path, canonical_effects_path)) effects else try parseFile(init.io, cwd, allocator, canonical_effects_path);
    const canonical_attributes = if (std.mem.eql(u8, attributes_path, canonical_attributes_path)) attributes else try parseFile(init.io, cwd, allocator, canonical_attributes_path);

    var output = std.array_list.Managed(u8).init(allocator);
    try output.appendSlice(
        "// Generated from Prismarine minecraft-data. Do not edit by hand.\n\n" ++
            "const std = @import(\"std\");\n\n" ++
            "pub const ItemInfo = struct { stack_size: u8, max_durability: u16, block_state: i32 };\n" ++
            "pub const BlockInfo = struct { default_state: i32, min_state: i32, max_state: i32, hardness: f32, drop_item: i32, material_offset: u32, material_count: u8, harvest_offset: u32, harvest_count: u8, emitted_light: u4, filtered_light: u4, diggable: bool, visually_transparent: bool };\n" ++
            "pub const ToolSpeed = struct { item_id: i32, multiplier: f32 };\n" ++
            "pub const CollisionBox = packed struct { min_x: i8, min_y: i8, min_z: i8, max_x: i8, max_y: i8, max_z: i8 };\n" ++
            "pub const CollisionShape = struct { offset: u32, count: u8 };\n\n" ++
            "pub const LightFace = [4]u64;\n\n",
    );

    for (block_symbols) |name| {
        const block = try findObjectByName(blocks, name);
        try output.print("pub const block_{s}_default_state: i32 = {};\n", .{ name, try intField(block, "defaultState") });
    }

    var maximum_block_state: u64 = 0;

    for (blocks.array.items) |entry|
        maximum_block_state = @max(maximum_block_state, @as(u64, @intCast(try intField(entry.object, "maxStateId"))));
    try output.print("\npub const maximum_block_state: u32 = {};\n", .{maximum_block_state});
    try output.print("pub const block_state_bits: u8 = {};\n\n", .{std.math.log2_int_ceil(u64, maximum_block_state + 1)});

    try output.appendSlice("pub const block_state_names = &[_][]const u8{\n");

    for (blocks.array.items) |entry| {
        const block = entry.object;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        const states = block.get("states").?.array.items;
        var state_count: usize = 1;

        for (states) |state| state_count *= @intCast(try intField(state.object, "num_values"));
        if (state_count != max_state - min_state + 1) return error.InvalidBlockStateProduct;

        for (0..state_count) |offset| {
            try output.appendSlice("    \"");
            try writeBlockStateName(&output, block, offset);
            try output.appendSlice("\",\n");
        }
    }

    try output.appendSlice(
        "};\n\n" ++
            "pub fn blockStateName(state: i32) ?[]const u8 {\n" ++
            "    if (state < 0 or state >= block_state_names.len) return null;\n" ++
            "    return block_state_names[@intCast(state)];\n" ++
            "}\n\n" ++
            "pub fn blockStateId(name: []const u8) ?i32 {\n" ++
            "    for (block_state_names, 0..) |candidate, state| if (std.mem.eql(u8, candidate, name)) return @intCast(state);\n" ++
            "    return null;\n" ++
            "}\n\n",
    );

    try writeNamedRegistry(&output, "item", items.array.items);
    try output.append('\n');
    try writeNamedRegistry(&output, "enchantment", enchantments.array.items);
    const component_mappings = protocol.object.get("types").?.object.get("SlotComponentType").?.array.items[1].object.get("mappings").?.object;
    try writeMappedRegistry(&output, "data_component", "dataComponent", component_mappings);

    for (sounds.array.items, 0..) |entry, index| {
        if (try intField(entry.object, "id") != index + 1) return error.NonDenseSoundRegistry;
    }

    try writeCanonicalTranslations(&output, allocator, blocks, items, entities, canonical_blocks, canonical_items, canonical_entities);
    _ = try writeIdTranslations(&output, allocator, "sound", sounds.array.items, canonical_sounds.array.items, 1);
    _ = try writeIdTranslations(&output, allocator, "block", blocks.array.items, canonical_blocks.array.items, 0);
    _ = try writeIdTranslations(&output, allocator, "effect", effects.array.items, canonical_effects.array.items, 0);
    _ = try writeIdTranslations(&output, allocator, "attribute", attributes.array.items, canonical_attributes.array.items, 0);
    const snapshot = try cwd.readFileAlloc(init.io, canonical_snapshot_path, allocator, .limited(16 * 1024 * 1024));
    var reader = std.Io.Reader.fixed(snapshot);
    if (!std.mem.eql(u8, try reader.take(8), "LRREG002")) return error.InvalidSnapshot;
    _ = try reader.take(try reader.takeInt(u16, .big));
    const registry_count = try reader.takeInt(u32, .big);
    try output.appendSlice("\npub const NamedRegistry = struct { name: []const u8, entries: []const []const u8 };\npub const named_registries = [_]NamedRegistry{\n");
    for (0..registry_count) |_| {
        const name = try reader.take(try reader.takeInt(u16, .big));
        if (try reader.takeByte() > 1) return error.InvalidSnapshot;
        const count = try reader.takeInt(u32, .big);
        try output.print("    .{{ .name = \"{f}\", .entries = &.{{\n", .{std.zig.fmtString(name)});
        for (0..count) |_| {
            const entry = try reader.take(try reader.takeInt(u16, .big));
            _ = try reader.take(try reader.takeInt(u32, .big));
            try output.print("        \"{f}\",\n", .{std.zig.fmtString(entry)});
        }
        try output.appendSlice("    } },\n");
    }
    _ = try reader.take(try reader.takeInt(u32, .big));
    if (reader.seek != snapshot.len) return error.InvalidSnapshot;
    try output.appendSlice("};\n");

    try output.appendSlice("\npub const biome_names = &[_][]const u8{\n");

    for (biomes.array.items, 0..) |entry, biome_index| {
        const biome = entry.object;
        if (try intField(biome, "id") != biome_index) return error.NonDenseBiomeRegistry;
        try output.print("    \"minecraft:{s}\",\n", .{biome.get("name").?.string});
    }

    try output.appendSlice(
        "};\n\n" ++
            "pub fn biomeId(name: []const u8) ?u8 {\n" ++
            "    for (biome_names, 0..) |candidate, biome_id| if (std.mem.eql(u8, candidate, name)) return @intCast(biome_id);\n" ++
            "    return null;\n" ++
            "}\n\n",
    );

    try output.appendSlice("\npub const items = &[_]ItemInfo{\n");
    var blocks_by_name = std.StringHashMap(std.json.ObjectMap).init(allocator);

    for (blocks.array.items) |entry| try blocks_by_name.putNoClobber(entry.object.get("name").?.string, entry.object);

    for (items.array.items, 0..) |entry, item_index| {
        const item = entry.object;
        if (try intField(item, "id") != item_index) return error.NonDenseItemRegistry;

        const item_name = item.get("name").?.string;
        const block_state = if (blocks_by_name.get(item_name)) |block| try intField(block, "defaultState") else 0;
        try output.print("    .{{ .stack_size = {}, .max_durability = {}, .block_state = {} }},\n", .{
            try intField(item, "stackSize"), try optionalIntField(item, "maxDurability", 0), block_state,
        });
    }

    try output.appendSlice("};\n\n");

    const shapes = collision_shapes.object.get("shapes").?.object;
    try output.appendSlice("pub const collision_shapes = &[_]CollisionShape{\n");
    var collision_box_offset: usize = 0;
    var expected_shape_id: usize = 0;
    var shape_iterator = shapes.iterator();

    while (shape_iterator.next()) |entry| : (expected_shape_id += 1) {
        const shape_id = try std.fmt.parseInt(usize, entry.key_ptr.*, 10);
        if (shape_id != expected_shape_id) return error.NonDenseCollisionShapes;

        const count = entry.value_ptr.array.items.len;
        if (count > std.math.maxInt(u8)) return error.CollisionShapeTooLarge;
        try output.print("    .{{ .offset = {}, .count = {} }},\n", .{ collision_box_offset, count });
        collision_box_offset += count;
    }

    try output.appendSlice("};\n\npub const collision_boxes = &[_]CollisionBox{\n");
    shape_iterator = shapes.iterator();

    while (shape_iterator.next()) |entry| {
        for (entry.value_ptr.array.items) |box_value| {
            if (box_value.array.items.len != 6) return error.InvalidCollisionBox;
            try output.appendSlice("    .{");
            const names = [_][]const u8{ "min_x", "min_y", "min_z", "max_x", "max_y", "max_z" };

            for (box_value.array.items, names) |coordinate, name| {
                try output.print(" .{s} = {} ,", .{ name, try collisionCoordinate(coordinate) });
            }

            try output.appendSlice(" },\n");
        }
    }

    try output.appendSlice("};\n\n");

    var light_faces: std.AutoArrayHashMapUnmanaged([4]u64, void) = .empty;
    try output.appendSlice("const collision_light_faces = &[_][6]u16{\n");
    shape_iterator = shapes.iterator();

    while (shape_iterator.next()) |entry| {
        try output.appendSlice("    .{");

        for (0..6) |face| {
            const mask = try collisionLightFaceMask(entry.value_ptr.*, face);
            const result = try light_faces.getOrPut(allocator, mask);
            if (result.index > std.math.maxInt(u16)) return error.TooManyLightFaces;
            try output.print(" {},", .{result.index});
        }

        try output.appendSlice(" },\n");
    }

    try output.appendSlice("};\nconst light_faces = &[_]LightFace{\n");

    for (light_faces.keys()) |mask| try output.print("    .{{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }},\n", .{ mask[0], mask[1], mask[2], mask[3] });
    try output.appendSlice("};\npub fn collisionLightFace(shape: u16, face: usize) LightFace {\n    return light_faces[collision_light_faces[shape][face]];\n}\n\n");

    var state_shapes = try std.array_list.Managed(u16).initCapacity(allocator, @intCast(maximum_block_state + 1));
    try state_shapes.appendNTimes(0, @intCast(maximum_block_state + 1));
    const collision_blocks = collision_shapes.object.get("blocks").?.object;

    for (blocks.array.items) |entry| {
        const block = entry.object;
        const name = block.get("name").?.string;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        const shape_value = collision_blocks.get(name) orelse return error.BlockCollisionShapeNotFound;

        switch (shape_value) {
            .integer => |shape_id| {
                for (min_state..max_state + 1) |state| state_shapes.items[state] = @intCast(shape_id);
            },
            .array => |shape_ids| {
                if (shape_ids.items.len != max_state - min_state + 1) return error.BlockCollisionStateCountMismatch;

                for (shape_ids.items, min_state..) |shape_id, state| state_shapes.items[state] = @intCast(shape_id.integer);
            },
            else => return error.InvalidBlockCollisionShape,
        }
    }

    try output.appendSlice("pub const block_state_collision_shape = &[_]u16{\n");

    for (state_shapes.items, 0..) |shape_id, state| {
        if (state % 16 == 0) try output.appendSlice("    ");
        try output.print("{},", .{shape_id});

        if (state % 16 == 15) try output.append('\n') else try output.append(' ');
    }

    if (state_shapes.items.len % 16 != 0) try output.append('\n');
    try output.appendSlice("};\n\n");
    try writeFluidStates(&output, blocks, @intCast(maximum_block_state + 1));

    try output.appendSlice("pub const material_tools = &[_]ToolSpeed{\n");
    var material_it = materials.object.iterator();

    while (material_it.next()) |entry| {
        var tool_it = entry.value_ptr.object.iterator();

        while (tool_it.next()) |tool| {
            try output.print("    .{{ .item_id = {}, .multiplier = {d} }},\n", .{ try std.fmt.parseInt(i32, tool.key_ptr.*, 10), try numberValue(tool.value_ptr.*) });
        }
    }

    try output.appendSlice("};\n\npub const harvest_tools = &[_]i32{\n");

    for (blocks.array.items) |entry| {
        if (entry.object.get("harvestTools")) |value| {
            var harvest_it = value.object.iterator();

            while (harvest_it.next()) |tool| try output.print("    {},\n", .{try std.fmt.parseInt(i32, tool.key_ptr.*, 10)});
        }
    }

    try output.appendSlice("};\n\npub const blocks = &[_]BlockInfo{\n");
    var harvest_offset: u32 = 0;

    for (blocks.array.items, 0..) |entry, block_index| {
        const block = entry.object;
        if (try intField(block, "id") != block_index) return error.NonDenseBlockRegistry;

        const material_name = block.get("material").?.string;
        const material_range = try objectValueRange(materials.object, material_name);
        const harvest_count: usize = if (block.get("harvestTools")) |value| value.object.count() else 0;
        try output.print("    .{{ .default_state = {}, .min_state = {}, .max_state = {}, .hardness = {d}, .drop_item = {}, .material_offset = {}, .material_count = {}, .harvest_offset = {}, .harvest_count = {}, .emitted_light = {}, .filtered_light = {}, .diggable = {}, .visually_transparent = {} }},\n", .{
            try intField(block, "defaultState"),            try intField(block, "minStateId"),                 try intField(block, "maxStateId"),
            try optionalNumberField(block, "hardness", -1), (try firstIntArrayField(block, "drops")) orelse 0, material_range.offset,
            material_range.count,                           harvest_offset,                                    harvest_count,
            try intField(block, "emitLight"),               try intField(block, "filterLight"),                try boolField(block, "diggable"),
            try boolField(block, "transparent"),
        });
        harvest_offset += @intCast(harvest_count);
    }

    try output.appendSlice("};\n\npub const block_state_to_block = &[_]u16{\n");
    var state_blocks = try allocator.alloc(u16, @intCast(maximum_block_state + 1));
    defer allocator.free(state_blocks);
    @memset(state_blocks, 0);

    for (blocks.array.items, 0..) |entry, block_index| {
        const block = entry.object;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        @memset(state_blocks[min_state .. max_state + 1], @intCast(block_index));
    }

    for (state_blocks, 0..) |block_id, state| {
        if (state % 16 == 0) try output.appendSlice("    ");
        try output.print("{},", .{block_id});

        if (state % 16 == 15 or state + 1 == state_blocks.len)
            try output.append('\n')
        else
            try output.append(' ');
    }

    try output.appendSlice("};\n\n");

    try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = output.items });
}

fn writeFluidStates(output: *std.array_list.Managed(u8), blocks: std.json.Value, state_count: usize) !void {
    try output.appendSlice("pub const fluid_state_bits = &[_]u64{\n");
    var word: u64 = 0;
    var state_id: usize = 0;

    for (blocks.array.items) |entry| {
        const block = entry.object;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        if (min_state != state_id) return error.NonDenseBlockStateRegistry;
        var intrinsic_fluid = false;
        for ([_][]const u8{ "water", "lava", "kelp", "kelp_plant", "seagrass", "tall_seagrass", "bubble_column" }) |name| {
            intrinsic_fluid = intrinsic_fluid or std.mem.eql(u8, block.get("name").?.string, name);
        }

        for (0..max_state - min_state + 1) |offset| {
            if (intrinsic_fluid or try boolStateProperty(block, offset, "waterlogged"))
                word |= @as(u64, 1) << @intCast(state_id % 64);
            state_id += 1;

            if (state_id % 64 == 0) {
                try output.print("    0x{x},\n", .{word});
                word = 0;
            }
        }
    }

    if (state_id != state_count) return error.NonDenseBlockStateRegistry;

    if (state_id % 64 != 0) try output.print("    0x{x},\n", .{word});
    try output.appendSlice(
        \\};
    ++ "pub inline fn stateContainsFluid(block_state: i32) bool {\n" ++
        \\    if (block_state < 0 or block_state >= block_state_to_block.len) return false;
        \\    const state: usize = @intCast(block_state);
    ++ "    return fluid_state_bits[state >> 6] & (@as(u64, 1) << @intCast(state & 63)) != 0;\n" ++
        \\}
        \\
        \\
    );
}

fn writeCanonicalTranslations(
    output: *std.array_list.Managed(u8),
    allocator: std.mem.Allocator,
    target_blocks: std.json.Value,
    target_items: std.json.Value,
    target_entities: std.json.Value,
    canonical_blocks: std.json.Value,
    canonical_items: std.json.Value,
    canonical_entities: std.json.Value,
) !void {
    var block_ids = std.StringHashMap(i32).init(allocator);
    var name_buffer = std.array_list.Managed(u8).init(allocator);

    for (target_blocks.array.items) |entry| {
        const block = entry.object;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));

        for (0..max_state - min_state + 1) |offset| {
            name_buffer.clearRetainingCapacity();
            try writeBlockStateName(&name_buffer, block, offset);
            try block_ids.put(try allocator.dupe(u8, name_buffer.items), @intCast(min_state + offset));
        }
    }

    var identity = true;
    try output.appendSlice("\npub const canonical_block_state_to_wire = &[_]i32{\n");

    for (canonical_blocks.array.items) |entry| {
        const block = entry.object;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));

        for (0..max_state - min_state + 1) |offset| {
            name_buffer.clearRetainingCapacity();
            try writeBlockStateName(&name_buffer, block, offset);
            const wire_id = block_ids.get(name_buffer.items) orelse -1;

            if (wire_id != @as(i32, @intCast(min_state + offset))) identity = false;
            try output.print("    {},\n", .{wire_id});
        }
    }

    try output.appendSlice("};\n");

    const item_identity = try writeIdTranslations(output, allocator, "item", target_items.array.items, canonical_items.array.items, 0);
    try writeNamedRegistry(output, "entity", target_entities.array.items);
    const entity_identity = try writeIdTranslations(output, allocator, "entity", target_entities.array.items, canonical_entities.array.items, 0);
    identity = identity and item_identity and entity_identity;
    try output.print("\npub const canonical_registries_identity = {};\n", .{identity});
}

fn writeIdTranslations(output: *std.array_list.Managed(u8), allocator: std.mem.Allocator, comptime prefix: []const u8, target: []const std.json.Value, canonical: []const std.json.Value, offset: usize) !bool {
    var target_ids = std.StringHashMap(i32).init(allocator);
    const reverse = try allocator.alloc(i32, target.len + offset);
    @memset(reverse, -1);
    for (0..offset) |index| reverse[index] = @intCast(index);
    for (target, 0..) |entry, index| {
        const id: i64 = if (entry.object.get("id")) |value| value.integer else @intCast(index + offset);
        if (id != index + offset) return error.NonDenseNamedRegistry;
        try target_ids.put(entry.object.get("name").?.string, @intCast(id));
    }

    var identity = target.len == canonical.len;
    try output.print("\npub const canonical_{s}_to_wire = &[_]i32{{\n", .{prefix});
    for (0..offset) |index| try output.print("    {},\n", .{index});
    for (canonical, 0..) |entry, index| {
        const id: i64 = if (entry.object.get("id")) |value| value.integer else @intCast(index + offset);
        if (id != index + offset) return error.NonDenseNamedRegistry;
        const mapped = target_ids.get(entry.object.get("name").?.string) orelse -1;
        if (mapped >= 0) reverse[@intCast(mapped)] = @intCast(id);
        identity = identity and mapped == id;
        try output.print("    {},\n", .{mapped});
    }
    try output.print("}};\npub const wire_{s}_to_canonical = &[_]i32{{\n", .{prefix});
    for (reverse) |id| try output.print("    {},\n", .{id});
    try output.print("}};\npub const {s}_identity = {};\n", .{ prefix, identity });
    return identity;
}

fn writeNamedRegistry(output: *std.array_list.Managed(u8), comptime prefix: []const u8, entries: []const std.json.Value) !void {
    try output.print("pub const {s}_names = &[_][]const u8{{\n", .{prefix});

    for (entries, 0..) |entry, index| {
        if (try intField(entry.object, "id") != index) return error.NonDenseNamedRegistry;
        try output.print("    \"minecraft:{s}\",\n", .{entry.object.get("name").?.string});
    }

    try writeRegistryLookup(output, prefix, prefix);
    try output.print("pub const {s}_ids = struct {{\n", .{prefix});
    for (entries) |entry| {
        try output.print("    pub const @\"{s}\": i32 = {};\n", .{ entry.object.get("name").?.string, try intField(entry.object, "id") });
    }
    try output.appendSlice("};\n\n");
}

fn writeMappedRegistry(output: *std.array_list.Managed(u8), comptime prefix: []const u8, comptime function_prefix: []const u8, mappings: std.json.ObjectMap) !void {
    try output.print("pub const {s}_names = &[_][]const u8{{\n", .{prefix});
    var key_storage: [32]u8 = undefined;

    for (0..mappings.count()) |index| {
        const key = try std.fmt.bufPrint(&key_storage, "{}", .{index});
        const value = mappings.get(key) orelse return error.NonDenseMappedRegistry;
        try output.print("    \"minecraft:{s}\",\n", .{value.string});
    }

    try writeRegistryLookup(output, prefix, function_prefix);
}

fn writeRegistryLookup(output: *std.array_list.Managed(u8), comptime names: []const u8, comptime functions: []const u8) !void {
    try output.print(
        "}};\n\npub fn {s}Name(id: i32) ?[]const u8 {{\n" ++
            "    if (id < 0 or id >= {s}_names.len) return null;\n" ++
            "    return {s}_names[@intCast(id)];\n" ++
            "}}\n\npub fn {s}Id(name: []const u8) ?i32 {{\n" ++
            "    for ({s}_names, 0..) |candidate, id| if (std.mem.eql(u8, candidate, name)) return @intCast(id);\n" ++
            "    return null;\n" ++
            "}}\n\n",
        .{ functions, names, names, functions, names },
    );
}

fn parseFile(io: std.Io, cwd: std.Io.Dir, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    return (try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{})).value;
}

fn findObjectByName(root: std.json.Value, name: []const u8) !std.json.ObjectMap {
    for (root.array.items) |entry| if (std.mem.eql(u8, entry.object.get("name").?.string, name)) return entry.object;
    return error.RegistryNameNotFound;
}

fn writeBlockStateName(output: *std.array_list.Managed(u8), block: std.json.ObjectMap, offset: usize) !void {
    try output.appendSlice("minecraft:");
    try output.appendSlice(block.get("name").?.string);
    const states = block.get("states").?.array.items;
    if (states.len == 0) return;
    try output.append('[');

    for (states, 0..) |state_value, property_index| {
        const state = state_value.object;
        var stride: usize = 1;

        for (states[property_index + 1 ..]) |later| stride *= @intCast(try intField(later.object, "num_values"));
        const value_count: usize = @intCast(try intField(state, "num_values"));
        const value_index = (offset / stride) % value_count;
        const value = if (state.get("values")) |values|
            values.array.items[value_index].string
        else if (std.mem.eql(u8, state.get("type").?.string, "bool"))
            if (value_index == 0) "true" else "false"
        else
            return error.MissingBlockStateValues;

        if (property_index != 0) try output.append(',');
        try output.appendSlice(state.get("name").?.string);
        try output.append('=');
        try output.appendSlice(value);
    }

    try output.append(']');
}

fn boolStateProperty(block: std.json.ObjectMap, offset: usize, property_name: []const u8) !bool {
    const states = block.get("states").?.array.items;

    for (states, 0..) |state_value, property_index| {
        const state = state_value.object;
        if (!std.mem.eql(u8, state.get("name").?.string, property_name)) continue;
        if (!std.mem.eql(u8, state.get("type").?.string, "bool")) return error.BlockStatePropertyIsNotBoolean;

        var stride: usize = 1;

        for (states[property_index + 1 ..]) |later| stride *= @intCast(try intField(later.object, "num_values"));
        return ((offset / stride) % 2) == 0;
    }

    return false;
}

fn objectValueRange(root: std.json.ObjectMap, name: []const u8) !struct {
    offset: usize,
    count: usize,
} {
    var offset: usize = 0;
    var it = root.iterator();

    while (it.next()) |entry| {
        const count = entry.value_ptr.object.count();
        if (std.mem.eql(u8, entry.key_ptr.*, name)) return .{ .offset = offset, .count = count };

        offset += count;
    }

    return error.MaterialNotFound;
}

fn intField(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (object.get(name) orelse return error.MissingField) {
        .integer => |v| v,
        else => error.FieldIsNotInteger,
    };
}

fn optionalIntField(object: std.json.ObjectMap, name: []const u8, default: i64) !i64 {
    return if (object.get(name)) |value| switch (value) {
        .integer => |v| v,
        else => error.FieldIsNotInteger,
    } else default;
}

fn boolField(object: std.json.ObjectMap, name: []const u8) !bool {
    return switch (object.get(name) orelse return error.MissingField) {
        .bool => |v| v,
        else => error.FieldIsNotBoolean,
    };
}

fn numberValue(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => error.FieldIsNotNumber,
    };
}

fn optionalNumberField(object: std.json.ObjectMap, name: []const u8, default: f64) !f64 {
    return if (object.get(name)) |value| numberValue(value) else default;
}

fn firstIntArrayField(object: std.json.ObjectMap, name: []const u8) !?i64 {
    const value = object.get(name) orelse return null;
    if (value.array.items.len == 0) return null;
    return switch (value.array.items[0]) {
        .integer => |v| v,
        else => error.FieldIsNotInteger,
    };
}

fn collisionCoordinate(value: std.json.Value) !i8 {
    const scaled = (try numberValue(value)) * 64.0;
    const rounded = @round(scaled);
    if (@abs(scaled - rounded) > 0.0000001 or rounded < std.math.minInt(i8) or rounded > std.math.maxInt(i8))
        return error.InvalidCollisionCoordinate;
    return @intFromFloat(rounded);
}

fn collisionLightFaceMask(shape: std.json.Value, face: usize) ![4]u64 {
    std.debug.assert(face < 6);
    var rows: [64]u64 = @splat(0);
    const axis = face / 2;
    const horizontal: usize = if (axis == 0) 1 else 0;
    const vertical: usize = if (axis == 2) 1 else 2;

    for (shape.array.items) |box| {
        if (box.array.items.len != 6) return error.InvalidCollisionBox;

        var coordinates: [6]i8 = undefined;

        for (box.array.items, &coordinates) |value, *coordinate| coordinate.* = try collisionCoordinate(value);
        if (coordinates[axis + (face % 2) * 3] != (if (face % 2 == 0) @as(i8, 0) else 64)) continue;

        const left: usize = @intCast(std.math.clamp(coordinates[horizontal], 0, 64));
        const right: usize = @intCast(std.math.clamp(coordinates[horizontal + 3], 0, 64));
        const bottom: usize = @intCast(std.math.clamp(coordinates[vertical], 0, 64));
        const top: usize = @intCast(std.math.clamp(coordinates[vertical + 3], 0, 64));
        if (left >= right or bottom >= top) continue;

        const full: u64 = std.math.maxInt(u64);
        const mask = (full << @as(u6, @intCast(left))) & (full >> @as(u6, @intCast(64 - right)));
        std.debug.assert(mask != 0);

        for (rows[bottom..top]) |*row| row.* |= mask;
    }

    var result: [4]u64 = @splat(0);

    for (0..16) |v| {
        const covered = rows[v * 4] & rows[v * 4 + 1] & rows[v * 4 + 2] & rows[v * 4 + 3];

        for (0..16) |u| {
            const mask = @as(u64, 15) << @as(u6, @intCast(u * 4));

            if (covered & mask == mask) {
                const bit = v * 16 + u;
                result[bit >> 6] |= @as(u64, 1) << @intCast(bit & 63);
            }
        }
    }

    return result;
}
