const std = @import("std");

const Symbol = struct { name: []const u8, registry_name: []const u8 };
const StateSymbol = struct { name: []const u8, state_name: []const u8 };

const state_symbols = [_]StateSymbol{
    .{ .name = "farmland_moisture_0", .state_name = "minecraft:farmland[moisture=0]" },
    .{ .name = "water_level_0", .state_name = "minecraft:water[level=0]" },
    .{ .name = "water_level_15", .state_name = "minecraft:water[level=15]" },
    .{ .name = "lava_level_0", .state_name = "minecraft:lava[level=0]" },
    .{ .name = "lava_level_15", .state_name = "minecraft:lava[level=15]" },
    .{ .name = "cactus_age_0", .state_name = "minecraft:cactus[age=0]" },
    .{ .name = "sugar_cane_age_0", .state_name = "minecraft:sugar_cane[age=0]" },
    .{ .name = "kelp_plant", .state_name = "minecraft:kelp_plant" },
    .{ .name = "bamboo_none_stage_0", .state_name = "minecraft:bamboo[age=0,leaves=none,stage=0]" },
    .{ .name = "bamboo_small_stage_0", .state_name = "minecraft:bamboo[age=0,leaves=small,stage=0]" },
    .{ .name = "bamboo_large_stage_0", .state_name = "minecraft:bamboo[age=0,leaves=large,stage=0]" },
    .{ .name = "chorus_plant_empty", .state_name = "minecraft:chorus_plant[down=false,east=false,north=false,south=false,up=false,west=false]" },
    .{ .name = "chorus_flower_age_0", .state_name = "minecraft:chorus_flower[age=0]" },
    .{ .name = "chorus_flower_age_5", .state_name = "minecraft:chorus_flower[age=5]" },
    .{ .name = "end_stone", .state_name = "minecraft:end_stone" },
    .{ .name = "fire_age_0_empty", .state_name = "minecraft:fire[age=0,east=false,north=false,south=false,up=false,west=false]" },
    .{ .name = "netherrack", .state_name = "minecraft:netherrack" },
    .{ .name = "cauldron", .state_name = "minecraft:cauldron" },
    .{ .name = "water_cauldron_level_1", .state_name = "minecraft:water_cauldron[level=1]" },
    .{ .name = "clay", .state_name = "minecraft:clay" },
    .{ .name = "mud", .state_name = "minecraft:mud" },
    .{ .name = "pointed_dripstone_tip_down_dry", .state_name = "minecraft:pointed_dripstone[thickness=tip,vertical_direction=down,waterlogged=false]" },
    .{ .name = "vine_empty", .state_name = "minecraft:vine[east=false,north=false,south=false,up=false,west=false]" },
    .{ .name = "sand", .state_name = "minecraft:sand" },
    .{ .name = "pumpkin_stem_age_0", .state_name = "minecraft:pumpkin_stem[age=0]" },
    .{ .name = "melon_stem_age_0", .state_name = "minecraft:melon_stem[age=0]" },
    .{ .name = "pumpkin", .state_name = "minecraft:pumpkin" },
    .{ .name = "melon", .state_name = "minecraft:melon" },
    .{ .name = "attached_pumpkin_stem_north", .state_name = "minecraft:attached_pumpkin_stem[facing=north]" },
    .{ .name = "attached_melon_stem_north", .state_name = "minecraft:attached_melon_stem[facing=north]" },
    .{ .name = "small_amethyst_bud_north_dry", .state_name = "minecraft:small_amethyst_bud[facing=north,waterlogged=false]" },
    .{ .name = "medium_amethyst_bud_north_dry", .state_name = "minecraft:medium_amethyst_bud[facing=north,waterlogged=false]" },
    .{ .name = "large_amethyst_bud_north_dry", .state_name = "minecraft:large_amethyst_bud[facing=north,waterlogged=false]" },
    .{ .name = "amethyst_cluster_north_dry", .state_name = "minecraft:amethyst_cluster[facing=north,waterlogged=false]" },
    .{ .name = "nether_portal_axis_x", .state_name = "minecraft:nether_portal[axis=x]" },
};

const block_symbols = [_]Symbol{
    .{ .name = "air", .registry_name = "air" },                                     .{ .name = "stone", .registry_name = "stone" },
    .{ .name = "cobblestone", .registry_name = "cobblestone" },                     .{ .name = "grass_block", .registry_name = "grass_block" },
    .{ .name = "dirt", .registry_name = "dirt" },                                   .{ .name = "oak_log", .registry_name = "oak_log" },
    .{ .name = "oak_leaves", .registry_name = "oak_leaves" },                       .{ .name = "deepslate", .registry_name = "deepslate" },
    .{ .name = "netherrack", .registry_name = "netherrack" },                       .{ .name = "coal_ore", .registry_name = "coal_ore" },
    .{ .name = "iron_ore", .registry_name = "iron_ore" },                           .{ .name = "copper_ore", .registry_name = "copper_ore" },
    .{ .name = "gold_ore", .registry_name = "gold_ore" },                           .{ .name = "redstone_ore", .registry_name = "redstone_ore" },
    .{ .name = "emerald_ore", .registry_name = "emerald_ore" },                     .{ .name = "lapis_ore", .registry_name = "lapis_ore" },
    .{ .name = "diamond_ore", .registry_name = "diamond_ore" },                     .{ .name = "deepslate_coal_ore", .registry_name = "deepslate_coal_ore" },
    .{ .name = "deepslate_iron_ore", .registry_name = "deepslate_iron_ore" },       .{ .name = "deepslate_copper_ore", .registry_name = "deepslate_copper_ore" },
    .{ .name = "deepslate_gold_ore", .registry_name = "deepslate_gold_ore" },       .{ .name = "deepslate_redstone_ore", .registry_name = "deepslate_redstone_ore" },
    .{ .name = "deepslate_emerald_ore", .registry_name = "deepslate_emerald_ore" }, .{ .name = "deepslate_lapis_ore", .registry_name = "deepslate_lapis_ore" },
    .{ .name = "deepslate_diamond_ore", .registry_name = "deepslate_diamond_ore" }, .{ .name = "nether_gold_ore", .registry_name = "nether_gold_ore" },
    .{ .name = "nether_quartz_ore", .registry_name = "nether_quartz_ore" },         .{ .name = "ancient_debris", .registry_name = "ancient_debris" },
    .{ .name = "crafting_table", .registry_name = "crafting_table" },               .{ .name = "chest", .registry_name = "chest" },
    .{ .name = "furnace", .registry_name = "furnace" },                             .{ .name = "oak_sapling", .registry_name = "oak_sapling" },
    .{ .name = "glass", .registry_name = "glass" },                                 .{ .name = "clay", .registry_name = "clay" },
    .{ .name = "bookshelf", .registry_name = "bookshelf" },                         .{ .name = "terracotta", .registry_name = "terracotta" },
    .{ .name = "raw_gold_block", .registry_name = "raw_gold_block" },               .{ .name = "granite", .registry_name = "granite" },
    .{ .name = "diorite", .registry_name = "diorite" },                             .{ .name = "andesite", .registry_name = "andesite" },
    .{ .name = "sand", .registry_name = "sand" },                                   .{ .name = "red_sand", .registry_name = "red_sand" },
    .{ .name = "sandstone", .registry_name = "sandstone" },                         .{ .name = "red_sandstone", .registry_name = "red_sandstone" },
    .{ .name = "gravel", .registry_name = "gravel" },                               .{ .name = "tuff", .registry_name = "tuff" },
    .{ .name = "calcite", .registry_name = "calcite" },                             .{ .name = "mud", .registry_name = "mud" },
    .{ .name = "end_stone", .registry_name = "end_stone" },
};

const item_symbols = [_]Symbol{
    .{ .name = "stone", .registry_name = "stone" },                         .{ .name = "cobblestone", .registry_name = "cobblestone" },
    .{ .name = "grass_block", .registry_name = "grass_block" },             .{ .name = "dirt", .registry_name = "dirt" },
    .{ .name = "diamond_shovel", .registry_name = "diamond_shovel" },       .{ .name = "diamond_pickaxe", .registry_name = "diamond_pickaxe" },
    .{ .name = "wooden_pickaxe", .registry_name = "wooden_pickaxe" },       .{ .name = "diamond_axe", .registry_name = "diamond_axe" },
    .{ .name = "diamond_hoe", .registry_name = "diamond_hoe" },             .{ .name = "diamond_sword", .registry_name = "diamond_sword" },
    .{ .name = "trident", .registry_name = "trident" },                     .{ .name = "mace", .registry_name = "mace" },
    .{ .name = "crafting_table", .registry_name = "crafting_table" },       .{ .name = "chest", .registry_name = "chest" },
    .{ .name = "furnace", .registry_name = "furnace" },                     .{ .name = "oak_planks", .registry_name = "oak_planks" },
    .{ .name = "oak_log", .registry_name = "oak_log" },                     .{ .name = "stick", .registry_name = "stick" },
    .{ .name = "coal", .registry_name = "coal" },                           .{ .name = "charcoal", .registry_name = "charcoal" },
    .{ .name = "coal_block", .registry_name = "coal_block" },               .{ .name = "lava_bucket", .registry_name = "lava_bucket" },
    .{ .name = "bucket", .registry_name = "bucket" },                       .{ .name = "raw_iron", .registry_name = "raw_iron" },
    .{ .name = "iron_ore", .registry_name = "iron_ore" },                   .{ .name = "deepslate_iron_ore", .registry_name = "deepslate_iron_ore" },
    .{ .name = "iron_ingot", .registry_name = "iron_ingot" },               .{ .name = "raw_gold", .registry_name = "raw_gold" },
    .{ .name = "gold_ore", .registry_name = "gold_ore" },                   .{ .name = "deepslate_gold_ore", .registry_name = "deepslate_gold_ore" },
    .{ .name = "gold_ingot", .registry_name = "gold_ingot" },               .{ .name = "raw_copper", .registry_name = "raw_copper" },
    .{ .name = "copper_ore", .registry_name = "copper_ore" },               .{ .name = "deepslate_copper_ore", .registry_name = "deepslate_copper_ore" },
    .{ .name = "copper_ingot", .registry_name = "copper_ingot" },           .{ .name = "sand", .registry_name = "sand" },
    .{ .name = "red_sand", .registry_name = "red_sand" },                   .{ .name = "glass", .registry_name = "glass" },
    .{ .name = "smooth_stone", .registry_name = "smooth_stone" },           .{ .name = "clay_ball", .registry_name = "clay_ball" },
    .{ .name = "brick", .registry_name = "brick" },                         .{ .name = "netherrack", .registry_name = "netherrack" },
    .{ .name = "nether_brick", .registry_name = "nether_brick" },           .{ .name = "cactus", .registry_name = "cactus" },
    .{ .name = "green_dye", .registry_name = "green_dye" },                 .{ .name = "porkchop", .registry_name = "porkchop" },
    .{ .name = "cooked_porkchop", .registry_name = "cooked_porkchop" },     .{ .name = "beef", .registry_name = "beef" },
    .{ .name = "cooked_beef", .registry_name = "cooked_beef" },             .{ .name = "chicken", .registry_name = "chicken" },
    .{ .name = "cooked_chicken", .registry_name = "cooked_chicken" },       .{ .name = "cod", .registry_name = "cod" },
    .{ .name = "cooked_cod", .registry_name = "cooked_cod" },               .{ .name = "salmon", .registry_name = "salmon" },
    .{ .name = "cooked_salmon", .registry_name = "cooked_salmon" },         .{ .name = "potato", .registry_name = "potato" },
    .{ .name = "baked_potato", .registry_name = "baked_potato" },           .{ .name = "mutton", .registry_name = "mutton" },
    .{ .name = "cooked_mutton", .registry_name = "cooked_mutton" },         .{ .name = "rabbit", .registry_name = "rabbit" },
    .{ .name = "cooked_rabbit", .registry_name = "cooked_rabbit" },         .{ .name = "kelp", .registry_name = "kelp" },
    .{ .name = "dried_kelp", .registry_name = "dried_kelp" },               .{ .name = "clay", .registry_name = "clay" },
    .{ .name = "terracotta", .registry_name = "terracotta" },               .{ .name = "ancient_debris", .registry_name = "ancient_debris" },
    .{ .name = "netherite_scrap", .registry_name = "netherite_scrap" },     .{ .name = "dried_kelp_block", .registry_name = "dried_kelp_block" },
    .{ .name = "blaze_rod", .registry_name = "blaze_rod" },                 .{ .name = "bamboo", .registry_name = "bamboo" },
    .{ .name = "oak_sapling", .registry_name = "oak_sapling" },             .{ .name = "rotten_flesh", .registry_name = "rotten_flesh" },
    .{ .name = "glow_ink_sac", .registry_name = "glow_ink_sac" },           .{ .name = "wheat", .registry_name = "wheat" },
    .{ .name = "carrot", .registry_name = "carrot" },                       .{ .name = "beetroot", .registry_name = "beetroot" },
    .{ .name = "carrot_on_a_stick", .registry_name = "carrot_on_a_stick" }, .{ .name = "leather", .registry_name = "leather" },
    .{ .name = "book", .registry_name = "book" },
};

const entity_symbols = [_]Symbol{
    .{ .name = "item", .registry_name = "item" },
    .{ .name = "player", .registry_name = "player" },
    .{ .name = "zombie", .registry_name = "zombie" },
    .{ .name = "zombified_piglin", .registry_name = "zombified_piglin" },
    .{ .name = "turtle", .registry_name = "turtle" },
    .{ .name = "cow", .registry_name = "cow" },
    .{ .name = "pig", .registry_name = "pig" },
    .{ .name = "chicken", .registry_name = "chicken" },
};

const sound_symbols = [_]Symbol{
    .{ .name = "entity_cow_ambient", .registry_name = "entity.cow.ambient" },
    .{ .name = "entity_cow_death", .registry_name = "entity.cow.death" },
    .{ .name = "entity_cow_hurt", .registry_name = "entity.cow.hurt" },
    .{ .name = "entity_cow_milk", .registry_name = "entity.cow.milk" },
    .{ .name = "entity_cow_step", .registry_name = "entity.cow.step" },
};

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
    const recipes_path = args.next() orelse return error.MissingRecipesPath;
    const collision_shapes_path = args.next() orelse return error.MissingCollisionShapesPath;
    const enchantments_path = args.next() orelse return error.MissingEnchantmentsPath;
    const protocol_path = args.next() orelse return error.MissingProtocolPath;
    const biomes_path = args.next() orelse return error.MissingBiomesPath;
    const canonical_blocks_path = args.next() orelse return error.MissingCanonicalBlocksPath;
    const canonical_items_path = args.next() orelse return error.MissingCanonicalItemsPath;
    const canonical_entities_path = args.next() orelse return error.MissingCanonicalEntitiesPath;
    const output_path = args.next() orelse return error.MissingOutputPath;

    const cwd = std.Io.Dir.cwd();
    const blocks = try parseFile(init.io, cwd, allocator, blocks_path);
    const items = try parseFile(init.io, cwd, allocator, items_path);
    const entities = try parseFile(init.io, cwd, allocator, entities_path);
    const sounds = try parseFile(init.io, cwd, allocator, sounds_path);
    const materials = try parseFile(init.io, cwd, allocator, materials_path);
    const recipes = try parseFile(init.io, cwd, allocator, recipes_path);
    const collision_shapes = try parseFile(init.io, cwd, allocator, collision_shapes_path);
    const enchantments = try parseFile(init.io, cwd, allocator, enchantments_path);
    const protocol = try parseFile(init.io, cwd, allocator, protocol_path);
    const biomes = try parseFile(init.io, cwd, allocator, biomes_path);
    const canonical_blocks = try parseFile(init.io, cwd, allocator, canonical_blocks_path);
    const canonical_items = try parseFile(init.io, cwd, allocator, canonical_items_path);
    const canonical_entities = try parseFile(init.io, cwd, allocator, canonical_entities_path);

    var output = std.array_list.Managed(u8).init(allocator);
    try output.appendSlice(
        "// Generated from Prismarine minecraft-data. Do not edit by hand.\n\n" ++
            "const std = @import(\"std\");\n\n" ++
            "pub const ItemInfo = struct { stack_size: u8, max_durability: u16, block_state: i32, attack_damage: f32, attack_speed: f32, equipment_slot: u8, armor: f32, armor_toughness: f32 };\n" ++
            "pub const BlockInfo = struct { default_state: i32, min_state: i32, max_state: i32, hardness: f32, drop_item: i32, material_offset: u32, material_count: u8, harvest_offset: u32, harvest_count: u8, emitted_light: u4, filtered_light: u4, diggable: bool, visually_transparent: bool };\n" ++
            "pub const ToolSpeed = struct { item_id: i32, multiplier: f32 };\n" ++
            "pub const RecipeKind = enum(u8) { shaped, shapeless };\n" ++
            "pub const Recipe = struct { kind: RecipeKind, width: u8, height: u8, ingredient_count: u8, ingredients: [9]i16, result_item: i32, result_count: u8 };\n\n" ++
            "pub const CollisionBox = packed struct { min_x: i8, min_y: i8, min_z: i8, max_x: i8, max_y: i8, max_z: i8 };\n" ++
            "pub const CollisionShape = struct { offset: u32, count: u8 };\n\n" ++
            "pub const LightFace = [4]u64;\n" ++
            "pub const LightFaces = [6]LightFace;\n\n",
    );

    for (block_symbols) |symbol| {
        const block = try findObjectByName(blocks, symbol.registry_name);
        try output.print("pub const block_{s}_id: i32 = {};\n", .{ symbol.name, try intField(block, "id") });
        try output.print("pub const block_{s}_default_state: i32 = {};\n", .{ symbol.name, try intField(block, "defaultState") });
        try output.print("pub const block_{s}_drop_item_id: i32 = {};\n", .{ symbol.name, (try firstIntArrayField(block, "drops")) orelse 0 });
    }
    var maximum_block_state: u64 = 0;
    for (blocks.array.items) |entry| maximum_block_state = @max(maximum_block_state, @as(u64, @intCast(try intField(entry.object, "maxStateId"))));
    try output.print("\npub const maximum_block_state: u32 = {};\n", .{maximum_block_state});
    try output.print("pub const block_state_bits: u8 = {};\n\n", .{std.math.log2_int_ceil(u64, maximum_block_state + 1)});

    try writeStateSymbols(&output, allocator, blocks);

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

    for (item_symbols) |symbol| {
        const item = try findObjectByName(items, symbol.registry_name);
        try output.print("pub const item_{s}_id: i32 = {};\n", .{ symbol.name, try intField(item, "id") });
        try output.print("pub const item_{s}_stack_size: u8 = {};\n", .{ symbol.name, try intField(item, "stackSize") });
    }
    try output.appendSlice("\npub const item_names = &[_][]const u8{\n");
    for (items.array.items, 0..) |entry, item_index| {
        const item = entry.object;
        if (try intField(item, "id") != item_index) return error.NonDenseItemRegistry;
        try output.print("    \"minecraft:{s}\",\n", .{item.get("name").?.string});
    }
    try output.appendSlice(
        "};\n\n" ++
            "pub fn itemName(item_id: i32) ?[]const u8 {\n" ++
            "    if (item_id < 0 or item_id >= item_names.len) return null;\n" ++
            "    return item_names[@intCast(item_id)];\n" ++
            "}\n\n" ++
            "pub fn itemId(name: []const u8) ?i32 {\n" ++
            "    for (item_names, 0..) |candidate, item_id| if (std.mem.eql(u8, candidate, name)) return @intCast(item_id);\n" ++
            "    return null;\n" ++
            "}\n",
    );
    try output.append('\n');
    try writeNamedRegistry(&output, "enchantment", enchantments.array.items);
    const component_mappings = protocol.object.get("types").?.object.get("SlotComponentType").?.array.items[1].object.get("mappings").?.object;
    try writeMappedRegistry(&output, "data_component", "dataComponent", component_mappings);

    for (entity_symbols) |symbol| {
        const entity = try findObjectByName(entities, symbol.registry_name);
        try output.print("pub const entity_{s}_type_id: i32 = {};\n", .{ symbol.name, try intField(entity, "id") });
    }
    for (sound_symbols) |symbol| {
        const sound = try findObjectByName(sounds, symbol.registry_name);
        try output.print("pub const sound_{s}_id: i32 = {};\n", .{ symbol.name, try intField(sound, "id") });
    }
    try output.appendSlice("\npub const sound_names = &[_][]const u8{\n    \"\",\n");
    for (sounds.array.items, 0..) |entry, sound_index| {
        const sound = entry.object;
        if (try intField(sound, "id") != sound_index + 1) return error.NonDenseSoundRegistry;
        try output.print("    \"minecraft:{s}\",\n", .{sound.get("name").?.string});
    }
    try output.appendSlice(
        "};\n\n" ++
            "pub fn soundName(sound_id: i32) ?[]const u8 {\n" ++
            "    if (sound_id < 0 or sound_id >= sound_names.len) return null;\n" ++
            "    return sound_names[@intCast(sound_id)];\n" ++
            "}\n\n",
    );
    try writeCanonicalTranslations(&output, allocator, blocks, items, entities, canonical_blocks, canonical_items, canonical_entities);

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
    for (items.array.items, 0..) |entry, item_index| {
        const item = entry.object;
        if (try intField(item, "id") != item_index) return error.NonDenseItemRegistry;
        const item_name = item.get("name").?.string;
        const block_state = if (findObjectByName(blocks, item_name)) |block| try intField(block, "defaultState") else |_| 0;
        const combat = itemCombatInfo(item_name);
        try output.print("    .{{ .stack_size = {}, .max_durability = {}, .block_state = {}, .attack_damage = {d}, .attack_speed = {d}, .equipment_slot = {}, .armor = {d}, .armor_toughness = {d} }},\n", .{
            try intField(item, "stackSize"), try optionalIntField(item, "maxDurability", 0), block_state,
            combat.attack_damage,            combat.attack_speed,                            combat.equipment_slot,
            combat.armor,                    combat.armor_toughness,
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

    try output.appendSlice("pub const collision_light_faces = &[_]LightFaces{\n");
    shape_iterator = shapes.iterator();
    while (shape_iterator.next()) |entry| {
        try output.appendSlice("    .{");
        for (0..6) |face| {
            const mask = try collisionLightFaceMask(entry.value_ptr.*, face);
            try output.print(" .{{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }},", .{
                mask[0], mask[1], mask[2], mask[3],
            });
        }
        try output.appendSlice(" },\n");
    }
    try output.appendSlice("};\n\n");

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
    try writeWaterloggedStates(&output, blocks, @intCast(maximum_block_state + 1));

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

    try output.appendSlice("pub const open_trapdoor_state_bits = &[_]u64{\n");
    var trapdoor_word: u64 = 0;
    var trapdoor_state_index: usize = 0;
    for (blocks.array.items) |entry| {
        const block = entry.object;
        const name = block.get("name").?.string;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        std.debug.assert(min_state == trapdoor_state_index);
        for (0..max_state - min_state + 1) |offset| {
            if (std.mem.endsWith(u8, name, "_trapdoor") and try boolStateProperty(block, offset, "open"))
                trapdoor_word |= @as(u64, 1) << @intCast(trapdoor_state_index & 63);
            trapdoor_state_index += 1;
            if (trapdoor_state_index & 63 == 0) {
                try output.print("    0x{x},\n", .{trapdoor_word});
                trapdoor_word = 0;
            }
        }
    }
    if (trapdoor_state_index & 63 != 0) try output.print("    0x{x},\n", .{trapdoor_word});
    try output.appendSlice("};\n\n");

    try writeRandomTickData(&output, allocator, blocks);

    var recipe_buckets: [10]std.array_list.Managed(u16) = undefined;
    for (&recipe_buckets) |*bucket| bucket.* = .init(allocator);
    defer for (&recipe_buckets) |*bucket| bucket.deinit();
    try output.appendSlice("pub const recipes = &[_]Recipe{\n");
    var recipe_index: usize = 0;
    var recipe_groups = recipes.object.iterator();
    while (recipe_groups.next()) |group| for (group.value_ptr.array.items) |entry| {
        const ingredient_count = try writeRecipe(&output, entry.object);
        if (ingredient_count >= recipe_buckets.len or recipe_index > std.math.maxInt(u16)) return error.RecipeIndexCapacity;
        try recipe_buckets[ingredient_count].append(@intCast(recipe_index));
        recipe_index += 1;
    };
    try output.appendSlice("};\n\npub const recipe_count_offsets = &[_]u16{");
    var recipe_offset: usize = 0;
    for (recipe_buckets, 0..) |bucket, count| {
        try output.print("{s}{}", .{ if (count == 0) "" else ", ", recipe_offset });
        recipe_offset += bucket.items.len;
    }
    try output.print(", {} }};\npub const recipe_indices_by_count = &[_]u16{{", .{recipe_offset});
    var first_recipe_index = true;
    for (recipe_buckets) |bucket| for (bucket.items) |index| {
        try output.print("{s}{}", .{ if (first_recipe_index) "" else ", ", index });
        first_recipe_index = false;
    };
    try output.appendSlice("};\n");
    try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = output.items });
}

fn writeStateSymbols(output: *std.array_list.Managed(u8), allocator: std.mem.Allocator, blocks: std.json.Value) !void {
    var found = [_]?i32{null} ** state_symbols.len;
    var name = std.array_list.Managed(u8).init(allocator);
    for (blocks.array.items) |entry| {
        const block = entry.object;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        for (0..max_state - min_state + 1) |offset| {
            name.clearRetainingCapacity();
            try writeBlockStateName(&name, block, offset);
            for (state_symbols, 0..) |symbol, symbol_index| {
                if (found[symbol_index] == null and std.mem.eql(u8, name.items, symbol.state_name))
                    found[symbol_index] = @intCast(min_state + offset);
            }
        }
    }
    for (state_symbols, found) |symbol, state_id| {
        try output.print("pub const state_{s}: i32 = {};\n", .{ symbol.name, state_id orelse return error.StateSymbolNotFound });
    }
    try output.append('\n');
}

fn writeWaterloggedStates(output: *std.array_list.Managed(u8), blocks: std.json.Value, state_count: usize) !void {
    try output.appendSlice("pub const waterlogged_state_bits = &[_]u64{\n");
    var word: u64 = 0;
    var state_id: usize = 0;
    for (blocks.array.items) |entry| {
        const block = entry.object;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        if (min_state != state_id) return error.NonDenseBlockStateRegistry;
        for (0..max_state - min_state + 1) |offset| {
            if (try boolStateProperty(block, offset, "waterlogged"))
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
        \\pub inline fn stateIsWaterlogged(block_state: i32) bool {
        \\    if (block_state < 0 or block_state >= block_state_to_block.len) return false;
        \\    const state: usize = @intCast(block_state);
        \\    return waterlogged_state_bits[state >> 6] & (@as(u64, 1) << @intCast(state & 63)) != 0;
        \\}
        \\
        \\
    );
}

const RandomTickKind = enum(u8) {
    none,
    crop,
    stem,
    cocoa,
    nether_wart,
    mushroom,
    vine,
    ice,
    snow,
    leaves,
    farmland,
    cactus,
    sugar_cane,
    kelp,
    bamboo,
    bamboo_sapling,
    chorus_flower,
    mangrove_propagule,
    sweet_berry_bush,
    spreadable,
    nylium,
    sapling,
    lava,
    mud,
    redstone_ore,
    nether_portal,
    turtle_egg,
    budding_amethyst,
    copper,
    pointed_dripstone,
};

const GeneratedRandomTickState = struct {
    kind: RandomTickKind = .none,
    age: i8 = -1,
    moisture: i8 = -1,
    distance: i8 = -1,
    stage: i8 = -1,
    layers: i8 = -1,
    hatch: i8 = -1,
    eggs: i8 = -1,
    next_age: i32 = -1,
    next_stage: i32 = -1,
    next_oxidation: i32 = -1,
    oxidation_stage: i8 = -1,
    vine_faces: u5 = 0,
    enum_value: i8 = -1,
    vertical_direction: i8 = -1,
    lit: bool = false,
    persistent: bool = false,
    hanging: bool = false,
    waterlogged: bool = false,
};

fn writeRandomTickData(output: *std.array_list.Managed(u8), allocator: std.mem.Allocator, blocks: std.json.Value) !void {
    var maximum_state: usize = 0;
    for (blocks.array.items) |entry| maximum_state = @max(maximum_state, @as(usize, @intCast(try intField(entry.object, "maxStateId"))));
    const states = try allocator.alloc(GeneratedRandomTickState, maximum_state + 1);
    defer allocator.free(states);
    @memset(states, .{});

    for (blocks.array.items) |entry| {
        const block = entry.object;
        const name = block.get("name").?.string;
        const kind = randomTickKind(name);
        const oxidation_target = if (kind == .copper) try oxidationTarget(blocks, allocator, name) else null;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        if (oxidation_target) |target| {
            const target_count = try intField(target, "maxStateId") - try intField(target, "minStateId") + 1;
            if (target_count != max_state - min_state + 1) return error.OxidationStateLayoutMismatch;
        }
        for (0..max_state - min_state + 1) |offset| {
            const state = &states[min_state + offset];
            state.kind = kind;
            state.age = try integerStateProperty(block, offset, "age");
            state.moisture = try integerStateProperty(block, offset, "moisture");
            state.distance = try integerStateProperty(block, offset, "distance");
            state.stage = try integerStateProperty(block, offset, "stage");
            state.layers = try integerStateProperty(block, offset, "layers");
            state.hatch = try integerStateProperty(block, offset, "hatch");
            state.eggs = try integerStateProperty(block, offset, "eggs");
            state.next_age = try stateWithNextIntegerProperty(block, offset, "age");
            state.next_stage = try stateWithNextIntegerProperty(block, offset, "stage");
            if (oxidation_target) |target| state.next_oxidation = @intCast(try intField(target, "minStateId") + @as(i64, @intCast(offset)));
            state.oxidation_stage = oxidationStage(name);
            if (kind == .vine) {
                state.vine_faces = (@as(u5, @intFromBool(try boolStateProperty(block, offset, "east"))) << 0) |
                    (@as(u5, @intFromBool(try boolStateProperty(block, offset, "north"))) << 1) |
                    (@as(u5, @intFromBool(try boolStateProperty(block, offset, "south"))) << 2) |
                    (@as(u5, @intFromBool(try boolStateProperty(block, offset, "up"))) << 3) |
                    (@as(u5, @intFromBool(try boolStateProperty(block, offset, "west"))) << 4);
            }
            state.enum_value = if (kind == .bamboo) try enumStateProperty(block, offset, "leaves") else if (kind == .pointed_dripstone) try enumStateProperty(block, offset, "thickness") else -1;
            state.vertical_direction = if (kind == .pointed_dripstone) try enumStateProperty(block, offset, "vertical_direction") else -1;
            state.lit = try boolStateProperty(block, offset, "lit");
            state.persistent = try boolStateProperty(block, offset, "persistent");
            state.hanging = try boolStateProperty(block, offset, "hanging");
            state.waterlogged = try boolStateProperty(block, offset, "waterlogged");
            if (kind == .redstone_ore and !state.lit) state.kind = .none;
            if (kind == .leaves and (state.distance != 7 or state.persistent)) state.kind = .none;
            if ((kind == .crop or kind == .cocoa or kind == .nether_wart or kind == .kelp or kind == .sweet_berry_bush) and state.next_age < 0) state.kind = .none;
            if (kind == .sapling and state.stage < 0) state.kind = .none;
            if (kind == .mangrove_propagule and !state.hanging) state.kind = .sapling;
            if (kind == .mangrove_propagule and state.hanging and state.next_age < 0) state.kind = .none;
            if (kind == .bamboo and state.stage != 0) state.kind = .none;
            if (kind == .copper and state.next_oxidation < 0) state.kind = .none;
        }
    }

    var behavior_indices = try allocator.alloc(u16, states.len);
    defer allocator.free(behavior_indices);
    @memset(behavior_indices, 0);
    var behaviors = std.array_list.Managed(GeneratedRandomTickState).init(allocator);
    defer behaviors.deinit();
    try behaviors.append(.{});
    var behavior_lookup = std.AutoHashMap(GeneratedRandomTickState, u16).init(allocator);
    defer behavior_lookup.deinit();
    try behavior_lookup.put(.{}, 0);
    for (states, 0..) |state, state_id| {
        if (state.kind == .none and state.oxidation_stage < 0) continue;
        const entry = try behavior_lookup.getOrPut(state);
        if (!entry.found_existing) {
            if (behaviors.items.len > std.math.maxInt(u16)) return error.TooManyRandomTickBehaviors;
            entry.value_ptr.* = @intCast(behaviors.items.len);
            try behaviors.append(state);
        }
        behavior_indices[state_id] = entry.value_ptr.*;
    }

    try output.appendSlice(
        "pub const RandomTickKind = enum(u8) { none, crop, stem, cocoa, nether_wart, mushroom, vine, ice, snow, leaves, farmland, cactus, sugar_cane, kelp, bamboo, bamboo_sapling, chorus_flower, mangrove_propagule, sweet_berry_bush, spreadable, nylium, sapling, lava, mud, redstone_ore, nether_portal, turtle_egg, budding_amethyst, copper, pointed_dripstone };\n" ++
            "pub const RandomTickState = struct { kind: RandomTickKind, age: i8, moisture: i8, distance: i8, stage: i8, layers: i8, hatch: i8, eggs: i8, next_age: i32, next_stage: i32, next_oxidation: i32, oxidation_stage: i8, vine_faces: u5, enum_value: i8, vertical_direction: i8, lit: bool, persistent: bool, hanging: bool, waterlogged: bool };\n" ++
            "pub const no_random_tick = RandomTickState{ .kind = .none, .age = -1, .moisture = -1, .distance = -1, .stage = -1, .layers = -1, .hatch = -1, .eggs = -1, .next_age = -1, .next_stage = -1, .next_oxidation = -1, .oxidation_stage = -1, .vine_faces = 0, .enum_value = -1, .vertical_direction = -1, .lit = false, .persistent = false, .hanging = false, .waterlogged = false };\n" ++
            "pub const random_tick_states = &[_]RandomTickState{\n",
    );
    for (behaviors.items) |state| {
        try output.print(
            "    .{{ .kind = .{s}, .age = {}, .moisture = {}, .distance = {}, .stage = {}, .layers = {}, .hatch = {}, .eggs = {}, .next_age = {}, .next_stage = {}, .next_oxidation = {}, .oxidation_stage = {}, .vine_faces = {}, .enum_value = {}, .vertical_direction = {}, .lit = {}, .persistent = {}, .hanging = {}, .waterlogged = {} }},\n",
            .{ @tagName(state.kind), state.age, state.moisture, state.distance, state.stage, state.layers, state.hatch, state.eggs, state.next_age, state.next_stage, state.next_oxidation, state.oxidation_stage, state.vine_faces, state.enum_value, state.vertical_direction, state.lit, state.persistent, state.hanging, state.waterlogged },
        );
    }
    try output.appendSlice("};\n\npub const random_tick_state_indices = &[_]u16{\n");
    for (behavior_indices, 0..) |index, state_id| {
        if (state_id % 16 == 0) try output.appendSlice("    ");
        try output.print("{},", .{index});
        if (state_id % 16 == 15 or state_id + 1 == behavior_indices.len)
            try output.append('\n')
        else
            try output.append(' ');
    }
    try output.appendSlice(
        "};\n\npub inline fn randomTickState(block_state: i32) *const RandomTickState {\n" ++
            "    if (block_state < 0 or block_state >= random_tick_state_indices.len) return &no_random_tick;\n" ++
            "    return &random_tick_states[random_tick_state_indices[@intCast(block_state)]];\n" ++
            "}\n\n",
    );

    const behavior_flags = try allocator.alloc(u8, states.len);
    defer allocator.free(behavior_flags);
    @memset(behavior_flags, 0);

    const leaf_distances = try allocator.alloc(i8, states.len);
    defer allocator.free(leaf_distances);
    @memset(leaf_distances, -1);

    const leaf_support_words = try allocator.alloc(u64, (states.len + 63) / 64);
    defer allocator.free(leaf_support_words);
    @memset(leaf_support_words, 0);

    for (blocks.array.items) |entry| {
        const block = entry.object;
        const name = block.get("name").?.string;
        const min_state: usize = @intCast(try intField(block, "minStateId"));
        const max_state: usize = @intCast(try intField(block, "maxStateId"));
        const mushroom_substrate = std.mem.eql(u8, name, "mycelium") or std.mem.eql(u8, name, "podzol");
        const flammable = isFlammable(name);
        const flags = @as(u8, @intFromBool(mushroom_substrate)) |
            (@as(u8, @intFromBool(flammable)) << 1);
        @memset(behavior_flags[min_state .. max_state + 1], flags);

        if (std.mem.endsWith(u8, name, "_leaves")) {
            for (min_state..max_state + 1) |state|
                leaf_distances[state] = states[state].distance;
        }
        if (isLeafSupport(name)) {
            for (min_state..max_state + 1) |state|
                leaf_support_words[state >> 6] |= @as(u64, 1) << @intCast(state & 63);
        }
    }

    try output.appendSlice(
        "pub const BlockBehaviorFlags = packed struct(u8) { mushroom_substrate: bool = false, flammable: bool = false, _: u6 = 0 };\n" ++
            "const block_behavior_bits = &[_]u8{\n",
    );
    for (behavior_flags, 0..) |flags, state| {
        if (state % 32 == 0) try output.appendSlice("    ");
        try output.print("{},", .{flags});
        if (state % 32 == 31 or state + 1 == behavior_flags.len)
            try output.append('\n')
        else
            try output.append(' ');
    }
    try output.appendSlice(
        "};\n\n" ++
            "pub inline fn blockBehaviorFlags(block_state: i32) BlockBehaviorFlags {\n" ++
            "    if (block_state < 0 or block_state >= block_behavior_bits.len) return .{};\n" ++
            "    return @bitCast(block_behavior_bits[@intCast(block_state)]);\n" ++
            "}\n\n" ++
            "pub const leaf_distances = &[_]i8{\n",
    );
    for (leaf_distances, 0..) |distance, state| {
        if (state % 32 == 0) try output.appendSlice("    ");
        try output.print("{},", .{distance});
        if (state % 32 == 31 or state + 1 == leaf_distances.len)
            try output.append('\n')
        else
            try output.append(' ');
    }
    try output.appendSlice(
        "};\n\npub inline fn leafDistance(block_state: i32) ?u8 {\n" ++
            "    if (block_state < 0 or block_state >= leaf_distances.len) return null;\n" ++
            "    const distance = leaf_distances[@intCast(block_state)];\n" ++
            "    return if (distance < 0) null else @intCast(distance);\n" ++
            "}\n\n" ++
            "const leaf_support_words = &[_]u64{\n",
    );
    for (leaf_support_words) |word| {
        try output.print("    0x{x},\n", .{word});
    }
    try output.appendSlice(
        "};\n\npub inline fn isLeafSupport(block_state: i32) bool {\n" ++
            "    if (block_state < 0 or block_state > maximum_block_state) return false;\n" ++
            "    const state: usize = @intCast(block_state);\n" ++
            "    return leaf_support_words[state >> 6] & (@as(u64, 1) << @intCast(state & 63)) != 0;\n" ++
            "}\n\n",
    );
}

fn isLeafSupport(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_log") or std.mem.endsWith(u8, name, "_wood") or
        std.mem.endsWith(u8, name, "_stem") or std.mem.endsWith(u8, name, "_hyphae") or
        std.mem.eql(u8, name, "mangrove_roots");
}

fn isFlammable(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_planks") or std.mem.endsWith(u8, name, "_log") or
        std.mem.endsWith(u8, name, "_wood") or std.mem.endsWith(u8, name, "_leaves") or
        std.mem.endsWith(u8, name, "_wool") or std.mem.endsWith(u8, name, "_carpet") or
        std.mem.endsWith(u8, name, "_fence") or std.mem.endsWith(u8, name, "_fence_gate") or
        std.mem.eql(u8, name, "hay_block") or std.mem.eql(u8, name, "bookshelf") or
        std.mem.eql(u8, name, "tnt") or std.mem.eql(u8, name, "dried_kelp_block");
}

fn randomTickKind(name: []const u8) RandomTickKind {
    if (std.mem.eql(u8, name, "wheat") or std.mem.eql(u8, name, "carrots") or std.mem.eql(u8, name, "potatoes") or std.mem.eql(u8, name, "beetroots") or std.mem.eql(u8, name, "torchflower_crop") or std.mem.eql(u8, name, "pitcher_crop")) return .crop;
    if (std.mem.eql(u8, name, "pumpkin_stem") or std.mem.eql(u8, name, "melon_stem")) return .stem;
    if (std.mem.eql(u8, name, "cocoa")) return .cocoa;
    if (std.mem.eql(u8, name, "nether_wart")) return .nether_wart;
    if (std.mem.eql(u8, name, "brown_mushroom") or std.mem.eql(u8, name, "red_mushroom")) return .mushroom;
    if (std.mem.eql(u8, name, "vine")) return .vine;
    if (std.mem.eql(u8, name, "ice")) return .ice;
    if (std.mem.eql(u8, name, "snow")) return .snow;
    if (std.mem.endsWith(u8, name, "_leaves")) return .leaves;
    if (std.mem.eql(u8, name, "farmland")) return .farmland;
    if (std.mem.eql(u8, name, "cactus")) return .cactus;
    if (std.mem.eql(u8, name, "sugar_cane")) return .sugar_cane;
    if (std.mem.eql(u8, name, "kelp")) return .kelp;
    if (std.mem.eql(u8, name, "bamboo")) return .bamboo;
    if (std.mem.eql(u8, name, "bamboo_sapling")) return .bamboo_sapling;
    if (std.mem.eql(u8, name, "chorus_flower")) return .chorus_flower;
    if (std.mem.eql(u8, name, "mangrove_propagule")) return .mangrove_propagule;
    if (std.mem.eql(u8, name, "sweet_berry_bush")) return .sweet_berry_bush;
    if (std.mem.eql(u8, name, "grass_block") or std.mem.eql(u8, name, "mycelium")) return .spreadable;
    if (std.mem.endsWith(u8, name, "_nylium")) return .nylium;
    if (std.mem.endsWith(u8, name, "_sapling") and !std.mem.startsWith(u8, name, "potted_")) return .sapling;
    if (std.mem.eql(u8, name, "lava")) return .lava;
    if (std.mem.eql(u8, name, "mud")) return .mud;
    if (std.mem.endsWith(u8, name, "redstone_ore")) return .redstone_ore;
    if (std.mem.eql(u8, name, "nether_portal")) return .nether_portal;
    if (std.mem.eql(u8, name, "turtle_egg")) return .turtle_egg;
    if (std.mem.eql(u8, name, "budding_amethyst")) return .budding_amethyst;
    if (isUnwaxedOxidizableCopper(name)) return .copper;
    if (std.mem.eql(u8, name, "pointed_dripstone")) return .pointed_dripstone;
    return .none;
}

fn isUnwaxedOxidizableCopper(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "waxed_") or std.mem.startsWith(u8, name, "oxidized_")) return false;
    if (std.mem.eql(u8, name, "copper_ore") or std.mem.eql(u8, name, "deepslate_copper_ore") or std.mem.eql(u8, name, "raw_copper_block")) return false;
    return std.mem.indexOf(u8, name, "copper") != null;
}

fn oxidationTarget(blocks: std.json.Value, allocator: std.mem.Allocator, name: []const u8) !?std.json.ObjectMap {
    var target = std.array_list.Managed(u8).init(allocator);
    if (std.mem.eql(u8, name, "copper_block")) {
        try target.appendSlice("exposed_copper");
    } else if (std.mem.startsWith(u8, name, "exposed_")) {
        try target.appendSlice("weathered_");
        try target.appendSlice(name["exposed_".len..]);
    } else if (std.mem.startsWith(u8, name, "weathered_")) {
        try target.appendSlice("oxidized_");
        try target.appendSlice(name["weathered_".len..]);
    } else {
        try target.appendSlice("exposed_");
        try target.appendSlice(name);
    }
    return findObjectByName(blocks, target.items) catch null;
}

fn oxidationStage(name: []const u8) i8 {
    if (std.mem.startsWith(u8, name, "waxed_") or std.mem.eql(u8, name, "copper_ore") or
        std.mem.eql(u8, name, "deepslate_copper_ore") or std.mem.eql(u8, name, "raw_copper_block") or
        std.mem.indexOf(u8, name, "copper") == null) return -1;
    if (std.mem.startsWith(u8, name, "oxidized_")) return 3;
    if (std.mem.startsWith(u8, name, "weathered_")) return 2;
    if (std.mem.startsWith(u8, name, "exposed_")) return 1;
    return 0;
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

    var item_ids = std.StringHashMap(i32).init(allocator);
    for (target_items.array.items) |entry| {
        const item = entry.object;
        try item_ids.put(item.get("name").?.string, @intCast(try intField(item, "id")));
    }
    try output.appendSlice("\npub const canonical_item_to_wire = &[_]i32{\n");
    for (canonical_items.array.items, 0..) |entry, canonical_id| {
        const wire_id = item_ids.get(entry.object.get("name").?.string) orelse -1;
        if (wire_id != @as(i32, @intCast(canonical_id))) identity = false;
        try output.print("    {},\n", .{wire_id});
    }
    try output.appendSlice("};\n");

    var entity_ids = std.StringHashMap(i32).init(allocator);
    try output.appendSlice("\npub const entity_names = &[_][]const u8{\n");
    for (target_entities.array.items) |entry| {
        const entity = entry.object;
        try entity_ids.put(entity.get("name").?.string, @intCast(try intField(entity, "id")));
        try output.print("    \"minecraft:{s}\",\n", .{entity.get("name").?.string});
    }
    try output.appendSlice("};\n\npub const canonical_entity_to_wire = &[_]i32{\n");
    for (canonical_entities.array.items, 0..) |entry, canonical_id| {
        const wire_id = entity_ids.get(entry.object.get("name").?.string) orelse -1;
        if (wire_id != @as(i32, @intCast(canonical_id))) identity = false;
        try output.print("    {},\n", .{wire_id});
    }
    try output.print("}};\n\npub const canonical_registries_identity = {};\n", .{identity});
}

fn writeNamedRegistry(output: *std.array_list.Managed(u8), comptime prefix: []const u8, entries: []const std.json.Value) !void {
    try output.print("pub const {s}_names = &[_][]const u8{{\n", .{prefix});
    for (entries, 0..) |entry, index| {
        if (try intField(entry.object, "id") != index) return error.NonDenseNamedRegistry;
        try output.print("    \"minecraft:{s}\",\n", .{entry.object.get("name").?.string});
    }
    try output.print(
        "}};\n\npub fn {s}Name(id: i32) ?[]const u8 {{\n" ++
            "    if (id < 0 or id >= {s}_names.len) return null;\n" ++
            "    return {s}_names[@intCast(id)];\n" ++
            "}}\n\npub fn {s}Id(name: []const u8) ?i32 {{\n" ++
            "    for ({s}_names, 0..) |candidate, id| if (std.mem.eql(u8, candidate, name)) return @intCast(id);\n" ++
            "    return null;\n" ++
            "}}\n\n",
        .{ prefix, prefix, prefix, prefix, prefix },
    );
}

fn writeMappedRegistry(output: *std.array_list.Managed(u8), comptime prefix: []const u8, comptime function_prefix: []const u8, mappings: std.json.ObjectMap) !void {
    try output.print("pub const {s}_names = &[_][]const u8{{\n", .{prefix});
    var key_storage: [32]u8 = undefined;
    for (0..mappings.count()) |index| {
        const key = try std.fmt.bufPrint(&key_storage, "{}", .{index});
        const value = mappings.get(key) orelse return error.NonDenseMappedRegistry;
        try output.print("    \"minecraft:{s}\",\n", .{value.string});
    }
    try output.print(
        "}};\n\npub fn {s}Name(id: i32) ?[]const u8 {{\n" ++
            "    if (id < 0 or id >= {s}_names.len) return null;\n" ++
            "    return {s}_names[@intCast(id)];\n" ++
            "}}\n\npub fn {s}Id(name: []const u8) ?i32 {{\n" ++
            "    for ({s}_names, 0..) |candidate, id| if (std.mem.eql(u8, candidate, name)) return @intCast(id);\n" ++
            "    return null;\n" ++
            "}}\n\n",
        .{ function_prefix, prefix, prefix, function_prefix, prefix },
    );
}

const ItemCombatInfo = struct {
    attack_damage: f32 = 1,
    attack_speed: f32 = 4,
    equipment_slot: u8 = 0,
    armor: f32 = 0,
    armor_toughness: f32 = 0,
};

fn itemCombatInfo(name: []const u8) ItemCombatInfo {
    var result = ItemCombatInfo{};
    const materials = [_]struct { prefix: []const u8, sword: f32, shovel: f32, pickaxe: f32, axe: f32 }{
        .{ .prefix = "wooden_", .sword = 4, .shovel = 2.5, .pickaxe = 2, .axe = 7 },
        .{ .prefix = "golden_", .sword = 4, .shovel = 2.5, .pickaxe = 2, .axe = 7 },
        .{ .prefix = "stone_", .sword = 5, .shovel = 3.5, .pickaxe = 3, .axe = 9 },
        .{ .prefix = "iron_", .sword = 6, .shovel = 4.5, .pickaxe = 4, .axe = 9 },
        .{ .prefix = "diamond_", .sword = 7, .shovel = 5.5, .pickaxe = 5, .axe = 9 },
        .{ .prefix = "netherite_", .sword = 8, .shovel = 6.5, .pickaxe = 6, .axe = 10 },
    };
    for (materials) |material| if (std.mem.startsWith(u8, name, material.prefix)) {
        const kind = name[material.prefix.len..];
        if (std.mem.eql(u8, kind, "sword")) return .{ .attack_damage = material.sword, .attack_speed = 1.6 };
        if (std.mem.eql(u8, kind, "shovel")) return .{ .attack_damage = material.shovel, .attack_speed = 1 };
        if (std.mem.eql(u8, kind, "pickaxe")) return .{ .attack_damage = material.pickaxe, .attack_speed = 1.2 };
        if (std.mem.eql(u8, kind, "axe")) return .{ .attack_damage = material.axe, .attack_speed = axeSpeed(material.prefix) };
        if (std.mem.eql(u8, kind, "hoe")) return .{ .attack_damage = 1, .attack_speed = hoeSpeed(material.prefix) };
    };
    if (std.mem.eql(u8, name, "trident")) return .{ .attack_damage = 9, .attack_speed = 1.1 };
    if (std.mem.eql(u8, name, "mace")) return .{ .attack_damage = 6, .attack_speed = 0.6 };

    const armor_materials = [_]struct { prefix: []const u8, head: f32, chest: f32, legs: f32, feet: f32, toughness: f32 }{
        .{ .prefix = "leather_", .head = 1, .chest = 3, .legs = 2, .feet = 1, .toughness = 0 },
        .{ .prefix = "golden_", .head = 2, .chest = 5, .legs = 3, .feet = 1, .toughness = 0 },
        .{ .prefix = "chainmail_", .head = 2, .chest = 5, .legs = 4, .feet = 1, .toughness = 0 },
        .{ .prefix = "iron_", .head = 2, .chest = 6, .legs = 5, .feet = 2, .toughness = 0 },
        .{ .prefix = "diamond_", .head = 3, .chest = 8, .legs = 6, .feet = 3, .toughness = 2 },
        .{ .prefix = "netherite_", .head = 3, .chest = 8, .legs = 6, .feet = 3, .toughness = 3 },
    };
    for (armor_materials) |material| if (std.mem.startsWith(u8, name, material.prefix)) {
        const kind = name[material.prefix.len..];
        if (std.mem.eql(u8, kind, "helmet")) return .{ .equipment_slot = 5, .armor = material.head, .armor_toughness = material.toughness };
        if (std.mem.eql(u8, kind, "chestplate")) return .{ .equipment_slot = 4, .armor = material.chest, .armor_toughness = material.toughness };
        if (std.mem.eql(u8, kind, "leggings")) return .{ .equipment_slot = 3, .armor = material.legs, .armor_toughness = material.toughness };
        if (std.mem.eql(u8, kind, "boots")) return .{ .equipment_slot = 2, .armor = material.feet, .armor_toughness = material.toughness };
    };
    if (std.mem.eql(u8, name, "turtle_helmet")) result = .{ .equipment_slot = 5, .armor = 2 };
    return result;
}

fn axeSpeed(prefix: []const u8) f32 {
    if (std.mem.eql(u8, prefix, "iron_")) return 0.9;
    if (std.mem.eql(u8, prefix, "diamond_") or std.mem.eql(u8, prefix, "golden_") or std.mem.eql(u8, prefix, "netherite_")) return 1;
    return 0.8;
}

fn hoeSpeed(prefix: []const u8) f32 {
    if (std.mem.eql(u8, prefix, "stone_")) return 2;
    if (std.mem.eql(u8, prefix, "iron_")) return 3;
    if (std.mem.eql(u8, prefix, "diamond_") or std.mem.eql(u8, prefix, "netherite_")) return 4;
    return 1;
}

fn parseFile(io: std.Io, cwd: std.Io.Dir, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    return (try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{})).value;
}

fn writeRecipe(output: *std.array_list.Managed(u8), object: std.json.ObjectMap) !usize {
    var ingredients = [_]i16{0} ** 9;
    var kind: []const u8 = "shapeless";
    var width: usize = 0;
    var height: usize = 0;
    var count: usize = 0;
    if (object.get("inShape")) |shape| {
        kind = "shaped";
        height = shape.array.items.len;
        width = shape.array.items[0].array.items.len;
        for (shape.array.items, 0..) |row, y| for (row.array.items, 0..) |cell, x| switch (cell) {
            .integer => |value| {
                ingredients[y * 3 + x] = @intCast(value);
                count += 1;
            },
            .null => {},
            else => return error.InvalidRecipeIngredient,
        };
    } else if (object.get("ingredients")) |values| {
        count = values.array.items.len;
        width = count;
        height = 1;
        for (values.array.items, 0..) |value, index| ingredients[index] = @intCast(value.integer);
    } else return error.InvalidRecipe;
    const result = object.get("result").?.object;
    try output.print("    .{{ .kind = .{s}, .width = {}, .height = {}, .ingredient_count = {}, .ingredients = .{{", .{ kind, width, height, count });
    for (ingredients, 0..) |ingredient, index| try output.print("{s}{}", .{ if (index == 0) "" else ", ", ingredient });
    try output.print("}}, .result_item = {}, .result_count = {} }},\n", .{ try intField(result, "id"), try optionalIntField(result, "count", 1) });
    return count;
}

fn findObjectByName(root: std.json.Value, name: []const u8) !std.json.ObjectMap {
    for (root.array.items) |entry| if (std.mem.eql(u8, entry.object.get("name").?.string, name)) return entry.object;
    return error.RegistryNameNotFound;
}

fn writeBlockStateName(output: *std.array_list.Managed(u8), block: std.json.ObjectMap, offset: usize) !void {
    try output.print("minecraft:{s}", .{block.get("name").?.string});
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
        try output.print("{s}{s}={s}", .{ if (property_index == 0) "" else ",", state.get("name").?.string, value });
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

fn integerStateProperty(block: std.json.ObjectMap, offset: usize, property_name: []const u8) !i8 {
    const states = block.get("states").?.array.items;
    for (states, 0..) |state_value, property_index| {
        const state = state_value.object;
        if (!std.mem.eql(u8, state.get("name").?.string, property_name)) continue;
        if (!std.mem.eql(u8, state.get("type").?.string, "int")) return error.BlockStatePropertyIsNotInteger;
        const value_index = statePropertyValueIndex(states, property_index, offset);
        return std.fmt.parseInt(i8, state.get("values").?.array.items[value_index].string, 10);
    }
    return -1;
}

fn enumStateProperty(block: std.json.ObjectMap, offset: usize, property_name: []const u8) !i8 {
    const states = block.get("states").?.array.items;
    for (states, 0..) |state_value, property_index| {
        const state = state_value.object;
        if (!std.mem.eql(u8, state.get("name").?.string, property_name)) continue;
        if (!std.mem.eql(u8, state.get("type").?.string, "enum")) return error.BlockStatePropertyIsNotEnum;
        return @intCast(statePropertyValueIndex(states, property_index, offset));
    }
    return -1;
}

fn stateWithNextIntegerProperty(block: std.json.ObjectMap, offset: usize, property_name: []const u8) !i32 {
    const states = block.get("states").?.array.items;
    for (states, 0..) |state_value, property_index| {
        const state = state_value.object;
        if (!std.mem.eql(u8, state.get("name").?.string, property_name)) continue;
        if (!std.mem.eql(u8, state.get("type").?.string, "int")) return error.BlockStatePropertyIsNotInteger;
        const value_index = statePropertyValueIndex(states, property_index, offset);
        const value_count: usize = @intCast(try intField(state, "num_values"));
        if (value_index + 1 == value_count) return -1;
        var stride: usize = 1;
        for (states[property_index + 1 ..]) |later| stride *= @intCast(try intField(later.object, "num_values"));
        return @intCast(try intField(block, "minStateId") + @as(i64, @intCast(offset + stride)));
    }
    return -1;
}

fn statePropertyValueIndex(states: []const std.json.Value, property_index: usize, offset: usize) usize {
    var stride: usize = 1;
    for (states[property_index + 1 ..]) |later| stride *= @intCast(later.object.get("num_values").?.integer);
    return (offset / stride) % @as(usize, @intCast(states[property_index].object.get("num_values").?.integer));
}

fn objectValueRange(root: std.json.ObjectMap, name: []const u8) !struct { offset: usize, count: usize } {
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
    if (@abs(scaled - rounded) > 0.0000001 or rounded < std.math.minInt(i8) or rounded > std.math.maxInt(i8)) return error.InvalidCollisionCoordinate;
    return @intFromFloat(rounded);
}

fn collisionLightFaceMask(shape: std.json.Value, face: usize) ![4]u64 {
    var result: [4]u64 = @splat(0);
    for (0..16) |v| {
        for (0..16) |u| {
            var covered = true;
            for (0..4) |dv| {
                for (0..4) |du| {
                    const a: i8 = @intCast(u * 4 + du);
                    const b: i8 = @intCast(v * 4 + dv);
                    var point_covered = false;
                    for (shape.array.items) |box| {
                        if (box.array.items.len != 6) return error.InvalidCollisionBox;
                        const min_x = try collisionCoordinate(box.array.items[0]);
                        const min_y = try collisionCoordinate(box.array.items[1]);
                        const min_z = try collisionCoordinate(box.array.items[2]);
                        const max_x = try collisionCoordinate(box.array.items[3]);
                        const max_y = try collisionCoordinate(box.array.items[4]);
                        const max_z = try collisionCoordinate(box.array.items[5]);
                        point_covered = switch (face) {
                            0 => min_x == 0 and a >= min_y and a < max_y and b >= min_z and b < max_z,
                            1 => max_x == 64 and a >= min_y and a < max_y and b >= min_z and b < max_z,
                            2 => min_y == 0 and a >= min_x and a < max_x and b >= min_z and b < max_z,
                            3 => max_y == 64 and a >= min_x and a < max_x and b >= min_z and b < max_z,
                            4 => min_z == 0 and a >= min_x and a < max_x and b >= min_y and b < max_y,
                            5 => max_z == 64 and a >= min_x and a < max_x and b >= min_y and b < max_y,
                            else => unreachable,
                        };
                        if (point_covered) break;
                    }
                    if (!point_covered) {
                        covered = false;
                        break;
                    }
                }
                if (!covered) break;
            }
            if (covered) {
                const bit = v * 16 + u;
                result[bit >> 6] |= @as(u64, 1) << @intCast(bit & 63);
            }
        }
    }
    return result;
}
