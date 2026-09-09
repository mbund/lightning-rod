const std = @import("std");
const minecraft = @import("minecraft_registry");

fn stateNameHash(name: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (name) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    return hash;
}

const Ore = struct {
    name: []const u8,
    step: u8,
    index: u8,
    placement: []const u8,
    minimum_kind: []const u8,
    minimum: i32,
    maximum_kind: []const u8,
    maximum: i32,
    count_kind: []const u8,
    count_minimum: u8,
    count_maximum: u8,
    size: u8,
    discard: f32,
    targets: []Target,
};

const Target = struct {
    tag: []const u8,
    state: []const u8,
    state_index: u16,
};

const Lichen = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_minimum: u8,
    count_maximum: u8,
    minimum_kind: []const u8,
    minimum: i32,
    maximum_kind: []const u8,
    maximum: i32,
    surface_maximum: i32,
    search_range: u8,
    spread_chance: f32,
    can_place_on: [][]const u8,
    state_base: u16,
};

const Disk = struct {
    name: []const u8,
    index: u8,
    count: u8,
    radius_minimum: u8,
    radius_maximum: u8,
    half_height: u8,
    requires_water: bool,
    targets: []u16,
    state: u16,
    state_above_air: ?u16,
    state_rule: []const u8,
};

const LavaLake = struct {
    name: []const u8,
    step: u8,
    index: u8,
    rarity: u16,
    placement: []const u8,
    max_scan: u8,
    surface_maximum: i8,
    fluid: u16,
    air: u16,
    barrier: u16,
};

const Iceberg = struct {
    name: []const u8,
    step: u8,
    index: u8,
    rarity: u16,
    state: u16,
};

const MonsterRoom = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count: u8,
    height_minimum: i16,
    height_maximum: i16,
};

const Magma = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_minimum: u8,
    count_maximum: u8,
    minimum_kind: []const u8,
    minimum: i32,
    maximum_kind: []const u8,
    maximum: i32,
    surface_maximum: i32,
    floor_search_range: u8,
    radius: u8,
    probability: f32,
    state: u16,
};

const OreVeins = struct {
    copper_ore: u16,
    raw_copper_block: u16,
    granite: u16,
    iron_ore: u16,
    raw_iron_block: u16,
    tuff: u16,
};

const Spring = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count: u8,
    height_kind: []const u8,
    minimum_kind: []const u8,
    minimum: i32,
    maximum_kind: []const u8,
    maximum: i32,
    inner: u16,
    state: u16,
    requires_block_below: bool,
    rock_count: u8,
    hole_count: u8,
    valid_blocks: [][]const u8,
};

const PointedDripstone = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_minimum: u8,
    count_maximum: u16,
    height_minimum_kind: []const u8,
    height_minimum: i32,
    height_maximum_kind: []const u8,
    height_maximum: i32,
    repetitions_minimum: u8,
    repetitions_maximum: u8,
    xz_mean: f32,
    xz_deviation: f32,
    xz_minimum: i8,
    xz_maximum: i8,
    y_mean: f32,
    y_deviation: f32,
    y_minimum: i8,
    y_maximum: i8,
    search_range: u8,
    taller_chance: f32,
    directional_spread_chance: f32,
    radius_two_chance: f32,
    radius_three_chance: f32,
    dripstone_block: u16,
    pointed_states: [4][2]u16,
};

const AmethystGeode = struct {
    name: []const u8,
    step: u8,
    index: u8,
    rarity: u8,
    height_minimum_kind: []const u8,
    height_minimum: i32,
    height_maximum_kind: []const u8,
    height_maximum: i32,
    minimum_generation_offset: i8,
    maximum_generation_offset: i8,
    noise_multiplier: f64,
    invalid_blocks_threshold: u8,
    outer_wall_distance: [2]u8,
    distribution_points: [2]u8,
    point_offset: [2]u8,
    potential_placement_chance: f64,
    alternate_inner_layer_chance: f64,
    placements_require_alternate: bool,
    layer_thickness: [4]f64,
    crack_chance: f64,
    base_crack_size: f64,
    crack_point_offset: u8,
    inner_layer_state: u16,
    alternate_inner_layer_state: u16,
    middle_layer_state: u16,
    outer_layer_state: u16,
    inner_placements: [4][6][2]u16,
};

const LargeDripstone = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_minimum: u8,
    count_maximum: u8,
    height_minimum_kind: []const u8,
    height_minimum: i32,
    height_maximum_kind: []const u8,
    height_maximum: i32,
    search_range: u8,
    radius_minimum: u8,
    radius_maximum: u8,
    height_scale: [2]f32,
    max_radius_to_cave_height_ratio: f32,
    stalactite_bluntness: [2]f32,
    stalagmite_bluntness: [2]f32,
    minimum_radius_for_wind: u8,
    minimum_bluntness_for_wind: f32,
    wind_speed: [2]f32,
    dripstone_block: u16,
};

const DripstoneCluster = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_minimum: u8,
    count_maximum: u8,
    height_minimum_kind: []const u8,
    height_minimum: i32,
    height_maximum_kind: []const u8,
    height_maximum: i32,
    search_range: u8,
    column_height_minimum: u8,
    column_height_maximum: u8,
    wetness: [4]f32,
    density: [2]f32,
    radius_minimum: u8,
    radius_maximum: u8,
    max_height_difference: u8,
    height_deviation: u8,
    layer_minimum: u8,
    layer_maximum: u8,
    edge_chance: f32,
    edge_distance: u8,
    height_bias_distance: u8,
    pointed_states: [10][2]u16,
};

const Tree = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_minimum: u8,
    count_maximum: u8,
    minimum_weight: u8,
    maximum_weight: u8,
    selectors: [4]f32,
    trunk_base_height: u8,
    trunk_height_rand_a: u8,
    trunk_height_rand_b: u8,
    foliage_radius: u8,
    foliage_height: u8,
    beehive_probability: f32,
    dirt_state: u16,
    log_state: u16,
    log_x_state: u16,
    log_z_state: u16,
    leaf_state_base: u16,
    birch_log_state: u16,
    birch_log_x_state: u16,
    birch_log_z_state: u16,
    birch_leaf_state_base: u16,
    spruce_log_state: u16,
    spruce_log_x_state: u16,
    spruce_log_z_state: u16,
    spruce_leaf_state_base: u16,
    acacia_log_state: u16,
    acacia_leaf_state_base: u16,
    podzol_state: u16,
    jungle_log_state: u16,
    jungle_log_x_state: u16,
    jungle_log_z_state: u16,
    jungle_leaf_state_base: u16,
    cocoa_states: [4][3]u16,
    litter_state_base: u16,
    red_mushroom_state: u16,
    brown_mushroom_state: u16,
    vine_east_state: u16,
    vine_west_state: u16,
    vine_south_state: u16,
    vine_north_state: u16,
    bee_nest_state: u16,
};

const BasicTreeSelector = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_kind: []const u8,
    count_minimum: u8,
    count_maximum: u8,
    minimum_weight: u8,
    maximum_weight: u8,
    rarity: u16,
    survival_filter: bool,
    max_water_depth: u8,
    choice_count: u8,
    choices: [4][]const u8,
    chances: [4]f32,
    default_choice: []const u8,
};

const HugeMushroom = struct {
    name: []const u8,
    step: u8,
    index: u8,
    foliage_radius: [2]u8,
    cap_states: [2][64]u16,
    stem_state: u16,
};

const RandomPatch = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count: u8,
    tries: u8,
    xz_spread: u8,
    y_spread: u8,
    state: u16,
};

const ForestFlowers = struct {
    name: []const u8,
    step: u8,
    index: u8,
    rarity: u16,
    count_minimum: i8,
    count_maximum: i8,
    count_clamp_minimum: u8,
    count_clamp_maximum: u8,
    tries: u8,
    xz_spread: u8,
    y_spread: u8,
    lower_states: [3]u16,
    upper_states: [3]u16,
    lily_state: u16,
};

const CaveVines = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count: u16,
    height_minimum: i16,
    height_maximum: i16,
    search_range: u8,
    plant_height_ranges: [3][2]u8,
    plant_height_weights: [3]u8,
    plant_states: [2]u16,
    tip_states: [6]u16,
};

const BirchTrees = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_minimum: u8,
    count_maximum: u8,
    minimum_weight: u8,
    maximum_weight: u8,
    fallen_chance: f32,
    beehive_probability: f32,
};

const TallBirchTrees = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_minimum: u8,
    count_maximum: u8,
    minimum_weight: u8,
    maximum_weight: u8,
    selectors: [3]f32,
    beehive_probability: f32,
};

const FlowerPatch = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count_kind: []const u8,
    count_below: u8,
    count_above: u8,
    count_noise: f64,
    rarity: u16,
    heightmap: []const u8,
    tries: u8,
    xz_spread: u8,
    y_spread: u8,
    provider: []const u8,
    first_octave: i8,
    scale: f32,
    slow_first_octave: i8,
    slow_scale: f32,
    variety_minimum: u8,
    variety_maximum: u8,
    threshold: f32,
    high_chance: f32,
    low_count: u8,
    high_count: u8,
    state_count: u8,
    total_weight: u8,
    upper_state: ?u16,
    states: [16]u16,
    weights: [16]u8,
};

const SurfacePatch = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count: u8,
    rarity: u16,
    heightmap: []const u8,
    tries: u8,
    xz_spread: u8,
    y_spread: u8,
    placement: []const u8,
    state_count: u8,
    states: [12]u16,
};

const NearWaterPatch = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count: u8,
    rarity: u16,
    heightmap: []const u8,
    tries: u8,
    xz_spread: u8,
    y_spread: u8,
    placement: []const u8,
    state: u16,
    column_minimum: u8,
    column_maximum: u8,
};

const NoiseGrassPatch = struct {
    name: []const u8,
    step: u8,
    index: u8,
    noise_level: f64,
    below_noise: u8,
    above_noise: u8,
    rarity: u16,
    heightmap: []const u8,
    tries: u8,
    xz_spread: u8,
    y_spread: u8,
    state: u16,
    upper_state: u16,
    double_plant: bool,
};

const FreezeTopLayer = struct {
    name: []const u8,
    step: u8,
    index: u8,
    ice_state: u16,
    snow_state: u16,
    snowy_states: [3][2]u16,
};

const Seagrass = struct {
    name: []const u8,
    step: u8,
    index: u8,
    count: u8,
    tall_probability: f32,
};

const Kelp = struct {
    name: []const u8,
    step: u8,
    index: u8,
    noise_factor: f64,
    noise_to_count_ratio: u16,
};

const SimpleFeature = struct {
    name: []const u8,
    step: u8,
    index: u8,
    kind: []const u8,
    count_kind: []const u8,
    count_minimum: u16,
    count_maximum: u16,
    height_kind: []const u8,
    height_minimum: i16,
    height_maximum: i16,
    state_count: u8,
    states: [5]u16,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const feature_path = args.next() orelse return error.MissingFeaturePath;
    const biome_tree_path = args.next() orelse return error.MissingBiomeTreePath;
    const biome_directory = args.next() orelse return error.MissingBiomeDirectory;
    const output_path = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.UnexpectedArgument;

    const cwd = std.Io.Dir.cwd();
    const feature_bytes = try cwd.readFileAlloc(init.io, feature_path, allocator, .limited(1024 * 1024));
    const parsed_features = try std.json.parseFromSlice(std.json.Value, allocator, feature_bytes, .{});
    const ore_values = (parsed_features.value.object.get("ores") orelse return error.MissingOres).array.items;
    if (ore_values.len > 64) return error.TooManyOreFeatures;

    var states: std.ArrayListUnmanaged([]const u8) = .empty;
    if (parsed_features.value.object.get("structure_states")) |values| {
        for (values.array.items) |value|
            _ = try stateIndex(allocator, &states, value.string);
    }
    var ores: std.ArrayListUnmanaged(Ore) = .empty;
    for (ore_values) |value| {
        const object = value.object;
        const height = (object.get("height") orelse return error.MissingHeight).array.items;
        if (height.len != 5) return error.InvalidHeight;
        const target_values = (object.get("targets") orelse return error.MissingTargets).array.items;
        const targets = try allocator.alloc(Target, target_values.len);
        for (target_values, targets) |target_value, *target| {
            const fields = target_value.array.items;
            if (fields.len != 2) return error.InvalidTarget;
            const state = fields[1].string;
            target.* = .{
                .tag = fields[0].string,
                .state = state,
                .state_index = try stateIndex(allocator, &states, state),
            };
        }
        var count_kind: []const u8 = undefined;
        var count_minimum: u8 = undefined;
        var count_maximum: u8 = undefined;
        if (object.get("count")) |count| {
            count_kind = "constant";
            count_minimum = try jsonU8(count);
            count_maximum = count_minimum;
        } else if (object.get("count_range")) |range_value| {
            const range = range_value.array.items;
            if (range.len != 2) return error.InvalidCountRange;
            count_kind = "uniform";
            count_minimum = try jsonU8(range[0]);
            count_maximum = try jsonU8(range[1]);
        } else if (object.get("rarity")) |rarity| {
            count_kind = "rarity";
            count_minimum = try jsonU8(rarity);
            count_maximum = count_minimum;
        } else return error.MissingCount;
        try ores.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = if (object.get("step")) |step| try jsonU8(step) else 6,
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .placement = height[0].string,
            .minimum_kind = height[1].string,
            .minimum = try jsonI32(height[2]),
            .maximum_kind = height[3].string,
            .maximum = try jsonI32(height[4]),
            .count_kind = count_kind,
            .count_minimum = count_minimum,
            .count_maximum = count_maximum,
            .size = try jsonU8(object.get("size") orelse return error.MissingSize),
            .discard = try jsonF32(object.get("discard") orelse return error.MissingDiscard),
            .targets = targets,
        });
    }
    const disk_values =
        (parsed_features.value.object.get("disks") orelse return error.MissingDisks).array.items;
    if (disk_values.len > 64) return error.TooManyDiskFeatures;
    var disks: std.ArrayListUnmanaged(Disk) = .empty;
    for (disk_values) |value| {
        const object = value.object;
        const radius = (object.get("radius") orelse return error.MissingRadius).array.items;
        if (radius.len != 2) return error.InvalidRadius;
        const target_values =
            (object.get("targets") orelse return error.MissingTargets).array.items;
        const targets = try allocator.alloc(u16, target_values.len);
        for (target_values, targets) |target, *state|
            state.* = try stateIndex(allocator, &states, target.string);
        const state_above_air = if (object.get("state_above_air")) |state|
            try stateIndex(allocator, &states, state.string)
        else
            null;
        try disks.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .count = try jsonU8(object.get("count") orelse return error.MissingCount),
            .radius_minimum = try jsonU8(radius[0]),
            .radius_maximum = try jsonU8(radius[1]),
            .half_height = try jsonU8(
                object.get("half_height") orelse return error.MissingHalfHeight,
            ),
            .requires_water = switch (object.get("requires_water") orelse
                return error.MissingRequiresWater) {
                .bool => |enabled| enabled,
                else => return error.ExpectedBoolean,
            },
            .targets = targets,
            .state = try stateIndex(
                allocator,
                &states,
                (object.get("state") orelse return error.MissingState).string,
            ),
            .state_above_air = state_above_air,
            .state_rule = if (object.get("state_rule")) |rule| rule.string else "below_air",
        });
    }
    const lake_values =
        (parsed_features.value.object.get("lava_lakes") orelse return error.MissingLavaLakes)
            .array.items;
    if (lake_values.len > 8) return error.TooManyLavaLakes;
    var lava_lakes: std.ArrayListUnmanaged(LavaLake) = .empty;
    for (lake_values) |value| {
        const object = value.object;
        try lava_lakes.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .rarity = try jsonU16(object.get("rarity") orelse return error.MissingRarity),
            .placement = (object.get("placement") orelse return error.MissingPlacement).string,
            .max_scan = try jsonU8(object.get("max_scan") orelse return error.MissingMaxScan),
            .surface_maximum = try jsonI8(
                object.get("surface_max") orelse return error.MissingSurfaceMaximum,
            ),
            .fluid = try stateIndex(
                allocator,
                &states,
                (object.get("fluid") orelse return error.MissingFluid).string,
            ),
            .air = try stateIndex(
                allocator,
                &states,
                (object.get("air") orelse return error.MissingAir).string,
            ),
            .barrier = try stateIndex(
                allocator,
                &states,
                (object.get("barrier") orelse return error.MissingBarrier).string,
            ),
        });
    }
    const iceberg_values =
        (parsed_features.value.object.get("icebergs") orelse return error.MissingIcebergs)
            .array.items;
    if (iceberg_values.len > 8) return error.TooManyIcebergs;
    var icebergs: std.ArrayListUnmanaged(Iceberg) = .empty;
    for (iceberg_values) |value| {
        const object = value.object;
        try icebergs.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .rarity = try jsonU16(object.get("rarity") orelse return error.MissingRarity),
            .state = try stateIndex(
                allocator,
                &states,
                (object.get("state") orelse return error.MissingState).string,
            ),
        });
    }
    const iceberg_states_object =
        (parsed_features.value.object.get("iceberg_states") orelse
            return error.MissingIcebergStates).object;
    var iceberg_states: [5]u16 = undefined;
    for ([_][]const u8{ "air", "water", "ice", "snow", "snow_block" }, &iceberg_states) |name, *state|
        state.* = try stateIndex(
            allocator,
            &states,
            (iceberg_states_object.get(name) orelse return error.MissingState).string,
        );
    const monster_room_values =
        (parsed_features.value.object.get("monster_rooms") orelse
            return error.MissingMonsterRooms).array.items;
    if (monster_room_values.len > 8) return error.TooManyMonsterRooms;
    var monster_rooms: std.ArrayListUnmanaged(MonsterRoom) = .empty;
    for (monster_room_values) |value| {
        const object = value.object;
        const height_values =
            (object.get("height") orelse return error.MissingHeight).array.items;
        if (height_values.len != 2) return error.InvalidHeight;
        try monster_rooms.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .count = try jsonU8(object.get("count") orelse return error.MissingCount),
            .height_minimum = try jsonI16(height_values[0]),
            .height_maximum = try jsonI16(height_values[1]),
        });
    }
    const room_states_object =
        (parsed_features.value.object.get("monster_room_states") orelse
            return error.MissingMonsterRoomStates).object;
    const room_chest_values =
        (room_states_object.get("chests") orelse return error.MissingChests).array.items;
    if (room_chest_values.len != 4) return error.InvalidChests;
    var monster_room_states: [8]u16 = undefined;
    monster_room_states[0] = try stateIndex(
        allocator,
        &states,
        (room_states_object.get("air") orelse return error.MissingAir).string,
    );
    monster_room_states[1] = try stateIndex(
        allocator,
        &states,
        (room_states_object.get("cobblestone") orelse return error.MissingState).string,
    );
    monster_room_states[2] = try stateIndex(
        allocator,
        &states,
        (room_states_object.get("mossy_cobblestone") orelse return error.MissingState).string,
    );
    monster_room_states[3] = try stateIndex(
        allocator,
        &states,
        (room_states_object.get("spawner") orelse return error.MissingState).string,
    );
    for (room_chest_values, monster_room_states[4..]) |value, *state|
        state.* = try stateIndex(allocator, &states, value.string);
    const magma_object =
        (parsed_features.value.object.get("underwater_magma") orelse
            return error.MissingUnderwaterMagma).object;
    const magma_count = (magma_object.get("count") orelse return error.MissingCount).array.items;
    if (magma_count.len != 2) return error.InvalidCountRange;
    const magma_height =
        (magma_object.get("height") orelse return error.MissingHeight).array.items;
    if (magma_height.len != 5 or
        !std.mem.eql(u8, magma_height[0].string, "uniform"))
        return error.InvalidHeight;
    const magma: Magma = .{
        .name = (magma_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(magma_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(magma_object.get("index") orelse return error.MissingIndex),
        .count_minimum = try jsonU8(magma_count[0]),
        .count_maximum = try jsonU8(magma_count[1]),
        .minimum_kind = magma_height[1].string,
        .minimum = try jsonI32(magma_height[2]),
        .maximum_kind = magma_height[3].string,
        .maximum = try jsonI32(magma_height[4]),
        .surface_maximum = try jsonI32(
            magma_object.get("surface_max") orelse return error.MissingSurfaceMaximum,
        ),
        .floor_search_range = try jsonU8(
            magma_object.get("floor_search_range") orelse
                return error.MissingFloorSearchRange,
        ),
        .radius = try jsonU8(magma_object.get("radius") orelse return error.MissingRadius),
        .probability = try jsonF32(
            magma_object.get("probability") orelse return error.MissingProbability,
        ),
        .state = try stateIndex(
            allocator,
            &states,
            (magma_object.get("state") orelse return error.MissingState).string,
        ),
    };
    const vein_object =
        (parsed_features.value.object.get("ore_veins") orelse
            return error.MissingOreVeins).object;
    const veins: OreVeins = .{
        .copper_ore = try stateIndex(
            allocator,
            &states,
            (vein_object.get("copper_ore") orelse return error.MissingCopperOre).string,
        ),
        .raw_copper_block = try stateIndex(
            allocator,
            &states,
            (vein_object.get("raw_copper_block") orelse
                return error.MissingRawCopperBlock).string,
        ),
        .granite = try stateIndex(
            allocator,
            &states,
            (vein_object.get("granite") orelse return error.MissingGranite).string,
        ),
        .iron_ore = try stateIndex(
            allocator,
            &states,
            (vein_object.get("iron_ore") orelse return error.MissingIronOre).string,
        ),
        .raw_iron_block = try stateIndex(
            allocator,
            &states,
            (vein_object.get("raw_iron_block") orelse return error.MissingRawIronBlock).string,
        ),
        .tuff = try stateIndex(
            allocator,
            &states,
            (vein_object.get("tuff") orelse return error.MissingTuff).string,
        ),
    };
    const spring_values =
        (parsed_features.value.object.get("fluid_springs") orelse
            return error.MissingFluidSprings).array.items;
    if (spring_values.len > 8) return error.TooManyFluidSprings;
    var springs: std.ArrayListUnmanaged(Spring) = .empty;
    for (spring_values) |value| {
        const object = value.object;
        const spring_height =
            (object.get("height") orelse return error.MissingHeight).array.items;
        if (spring_height.len != 6) return error.InvalidHeight;
        const valid_block_values =
            (object.get("valid_blocks") orelse return error.MissingValidBlocks).array.items;
        const valid_blocks = try allocator.alloc([]const u8, valid_block_values.len);
        for (valid_block_values, valid_blocks) |valid_block, *name|
            name.* = valid_block.string;
        try springs.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .count = try jsonU8(object.get("count") orelse return error.MissingCount),
            .height_kind = spring_height[0].string,
            .minimum_kind = spring_height[1].string,
            .minimum = try jsonI32(spring_height[2]),
            .maximum_kind = spring_height[3].string,
            .maximum = try jsonI32(spring_height[4]),
            .inner = try jsonU16(spring_height[5]),
            .state = try stateIndex(
                allocator,
                &states,
                (object.get("state") orelse return error.MissingState).string,
            ),
            .requires_block_below = switch (object.get("requires_block_below") orelse
                return error.MissingRequiresBlockBelow) {
                .bool => |enabled| enabled,
                else => return error.ExpectedBoolean,
            },
            .rock_count = try jsonU8(
                object.get("rock_count") orelse return error.MissingRockCount,
            ),
            .hole_count = try jsonU8(
                object.get("hole_count") orelse return error.MissingHoleCount,
            ),
            .valid_blocks = valid_blocks,
        });
    }
    const pointed_object =
        (parsed_features.value.object.get("pointed_dripstone") orelse
            return error.MissingPointedDripstone).object;
    const pointed_count =
        (pointed_object.get("count") orelse return error.MissingCount).array.items;
    const pointed_height =
        (pointed_object.get("height") orelse return error.MissingHeight).array.items;
    const pointed_repetitions =
        (pointed_object.get("repetitions") orelse return error.MissingRepetitions).array.items;
    const xz_offset =
        (pointed_object.get("xz_offset") orelse return error.MissingHorizontalOffset).array.items;
    const y_offset =
        (pointed_object.get("y_offset") orelse return error.MissingVerticalOffset).array.items;
    const pointed_state_values =
        (pointed_object.get("pointed_states") orelse return error.MissingPointedStates).array.items;
    if (pointed_count.len != 2 or pointed_height.len != 5 or
        pointed_repetitions.len != 2 or xz_offset.len != 4 or y_offset.len != 4 or
        pointed_state_values.len != 4)
        return error.InvalidPointedDripstone;
    var pointed_states: [4][2]u16 = undefined;
    for (pointed_state_values, &pointed_states) |value, *pair| {
        const values = value.array.items;
        if (values.len != 2) return error.InvalidPointedStates;
        pair.* = .{
            try stateIndex(allocator, &states, values[0].string),
            try stateIndex(allocator, &states, values[1].string),
        };
    }
    const pointed_dripstone: PointedDripstone = .{
        .name = (pointed_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(pointed_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(pointed_object.get("index") orelse return error.MissingIndex),
        .count_minimum = try jsonU8(pointed_count[0]),
        .count_maximum = try jsonU16(pointed_count[1]),
        .height_minimum_kind = pointed_height[1].string,
        .height_minimum = try jsonI32(pointed_height[2]),
        .height_maximum_kind = pointed_height[3].string,
        .height_maximum = try jsonI32(pointed_height[4]),
        .repetitions_minimum = try jsonU8(pointed_repetitions[0]),
        .repetitions_maximum = try jsonU8(pointed_repetitions[1]),
        .xz_mean = try jsonF32(xz_offset[0]),
        .xz_deviation = try jsonF32(xz_offset[1]),
        .xz_minimum = try jsonI8(xz_offset[2]),
        .xz_maximum = try jsonI8(xz_offset[3]),
        .y_mean = try jsonF32(y_offset[0]),
        .y_deviation = try jsonF32(y_offset[1]),
        .y_minimum = try jsonI8(y_offset[2]),
        .y_maximum = try jsonI8(y_offset[3]),
        .search_range = try jsonU8(
            pointed_object.get("search_range") orelse return error.MissingSearchRange,
        ),
        .taller_chance = try jsonF32(
            pointed_object.get("chance_of_taller_dripstone") orelse
                return error.MissingTallerChance,
        ),
        .directional_spread_chance = try jsonF32(
            pointed_object.get("chance_of_directional_spread") orelse
                return error.MissingDirectionalSpreadChance,
        ),
        .radius_two_chance = try jsonF32(
            pointed_object.get("chance_of_spread_radius2") orelse
                return error.MissingRadiusTwoChance,
        ),
        .radius_three_chance = try jsonF32(
            pointed_object.get("chance_of_spread_radius3") orelse
                return error.MissingRadiusThreeChance,
        ),
        .dripstone_block = try stateIndex(
            allocator,
            &states,
            (pointed_object.get("dripstone_block") orelse
                return error.MissingDripstoneBlock).string,
        ),
        .pointed_states = pointed_states,
    };
    const geode_object =
        (parsed_features.value.object.get("amethyst_geode") orelse
            return error.MissingAmethystGeode).object;
    const geode_height =
        (geode_object.get("height") orelse return error.MissingHeight).array.items;
    const outer_wall_distance =
        (geode_object.get("outer_wall_distance") orelse
            return error.MissingOuterWallDistance).array.items;
    const distribution_points =
        (geode_object.get("distribution_points") orelse
            return error.MissingDistributionPoints).array.items;
    const point_offset =
        (geode_object.get("point_offset") orelse return error.MissingPointOffset).array.items;
    const inner_placement_names =
        (geode_object.get("inner_placements") orelse
            return error.MissingInnerPlacements).array.items;
    if (geode_height.len != 5 or outer_wall_distance.len != 2 or
        distribution_points.len != 2 or point_offset.len != 2 or
        inner_placement_names.len != 4)
        return error.InvalidAmethystGeode;
    const direction_names = [_][]const u8{ "down", "up", "north", "south", "west", "east" };
    var inner_placements: [4][6][2]u16 = undefined;
    for (inner_placement_names, &inner_placements) |placement_value, *placement_states| {
        for (direction_names, placement_states) |direction, *water_states| {
            for ([_]bool{ false, true }, water_states) |waterlogged, *state| {
                const name = try std.fmt.allocPrint(
                    allocator,
                    "{s}[facing={s},waterlogged={s}]",
                    .{ placement_value.string, direction, booleanName(waterlogged) },
                );
                state.* = try stateIndex(allocator, &states, name);
            }
        }
    }
    const amethyst_geode: AmethystGeode = .{
        .name = (geode_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(geode_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(geode_object.get("index") orelse return error.MissingIndex),
        .rarity = try jsonU8(geode_object.get("rarity") orelse return error.MissingRarity),
        .height_minimum_kind = geode_height[1].string,
        .height_minimum = try jsonI32(geode_height[2]),
        .height_maximum_kind = geode_height[3].string,
        .height_maximum = try jsonI32(geode_height[4]),
        .minimum_generation_offset = try jsonI8(
            geode_object.get("min_gen_offset") orelse return error.MissingMinimumGenerationOffset,
        ),
        .maximum_generation_offset = try jsonI8(
            geode_object.get("max_gen_offset") orelse return error.MissingMaximumGenerationOffset,
        ),
        .noise_multiplier = try jsonF64(
            geode_object.get("noise_multiplier") orelse return error.MissingNoiseMultiplier,
        ),
        .invalid_blocks_threshold = try jsonU8(
            geode_object.get("invalid_blocks_threshold") orelse
                return error.MissingInvalidBlocksThreshold,
        ),
        .outer_wall_distance = .{
            try jsonU8(outer_wall_distance[0]),
            try jsonU8(outer_wall_distance[1]),
        },
        .distribution_points = .{
            try jsonU8(distribution_points[0]),
            try jsonU8(distribution_points[1]),
        },
        .point_offset = .{ try jsonU8(point_offset[0]), try jsonU8(point_offset[1]) },
        .potential_placement_chance = try jsonF64(
            geode_object.get("use_potential_placements_chance") orelse
                return error.MissingPotentialPlacementChance,
        ),
        .alternate_inner_layer_chance = try jsonF64(
            geode_object.get("use_alternate_inner_layer_chance") orelse
                return error.MissingAlternateInnerLayerChance,
        ),
        .placements_require_alternate = (geode_object.get("placements_require_alternate_inner_layer") orelse
            return error.MissingPlacementsRequireAlternate).bool,
        .layer_thickness = .{
            try jsonF64(geode_object.get("filling") orelse return error.MissingFilling),
            try jsonF64(geode_object.get("inner_layer") orelse return error.MissingInnerLayer),
            try jsonF64(geode_object.get("middle_layer") orelse return error.MissingMiddleLayer),
            try jsonF64(geode_object.get("outer_layer") orelse return error.MissingOuterLayer),
        },
        .crack_chance = try jsonF64(
            geode_object.get("generate_crack_chance") orelse return error.MissingCrackChance,
        ),
        .base_crack_size = try jsonF64(
            geode_object.get("base_crack_size") orelse return error.MissingBaseCrackSize,
        ),
        .crack_point_offset = try jsonU8(
            geode_object.get("crack_point_offset") orelse return error.MissingCrackPointOffset,
        ),
        .inner_layer_state = try stateIndex(
            allocator,
            &states,
            (geode_object.get("inner_layer_state") orelse return error.MissingInnerLayerState)
                .string,
        ),
        .alternate_inner_layer_state = try stateIndex(
            allocator,
            &states,
            (geode_object.get("alternate_inner_layer_state") orelse
                return error.MissingAlternateInnerLayerState).string,
        ),
        .middle_layer_state = try stateIndex(
            allocator,
            &states,
            (geode_object.get("middle_layer_state") orelse return error.MissingMiddleLayerState)
                .string,
        ),
        .outer_layer_state = try stateIndex(
            allocator,
            &states,
            (geode_object.get("outer_layer_state") orelse return error.MissingOuterLayerState)
                .string,
        ),
        .inner_placements = inner_placements,
    };
    const large_object =
        (parsed_features.value.object.get("large_dripstone") orelse
            return error.MissingLargeDripstone).object;
    const large_count =
        (large_object.get("count") orelse return error.MissingCount).array.items;
    const large_height =
        (large_object.get("height") orelse return error.MissingHeight).array.items;
    const large_radius =
        (large_object.get("column_radius") orelse return error.MissingRadius).array.items;
    const large_height_scale =
        (large_object.get("height_scale") orelse return error.MissingHeightScale).array.items;
    const stalactite_bluntness =
        (large_object.get("stalactite_bluntness") orelse
            return error.MissingStalactiteBluntness).array.items;
    const stalagmite_bluntness =
        (large_object.get("stalagmite_bluntness") orelse
            return error.MissingStalagmiteBluntness).array.items;
    const wind_speed =
        (large_object.get("wind_speed") orelse return error.MissingWindSpeed).array.items;
    if (large_count.len != 2 or large_height.len != 5 or large_radius.len != 2 or
        large_height_scale.len != 2 or stalactite_bluntness.len != 2 or
        stalagmite_bluntness.len != 2 or wind_speed.len != 2)
        return error.InvalidLargeDripstone;
    const large_dripstone: LargeDripstone = .{
        .name = (large_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(large_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(large_object.get("index") orelse return error.MissingIndex),
        .count_minimum = try jsonU8(large_count[0]),
        .count_maximum = try jsonU8(large_count[1]),
        .height_minimum_kind = large_height[1].string,
        .height_minimum = try jsonI32(large_height[2]),
        .height_maximum_kind = large_height[3].string,
        .height_maximum = try jsonI32(large_height[4]),
        .search_range = try jsonU8(
            large_object.get("floor_to_ceiling_search_range") orelse
                return error.MissingSearchRange,
        ),
        .radius_minimum = try jsonU8(large_radius[0]),
        .radius_maximum = try jsonU8(large_radius[1]),
        .height_scale = .{
            try jsonF32(large_height_scale[0]),
            try jsonF32(large_height_scale[1]),
        },
        .max_radius_to_cave_height_ratio = try jsonF32(
            large_object.get("max_column_radius_to_cave_height_ratio") orelse
                return error.MissingMaxRadiusToCaveHeightRatio,
        ),
        .stalactite_bluntness = .{
            try jsonF32(stalactite_bluntness[0]),
            try jsonF32(stalactite_bluntness[1]),
        },
        .stalagmite_bluntness = .{
            try jsonF32(stalagmite_bluntness[0]),
            try jsonF32(stalagmite_bluntness[1]),
        },
        .minimum_radius_for_wind = try jsonU8(
            large_object.get("min_radius_for_wind") orelse
                return error.MissingMinimumRadiusForWind,
        ),
        .minimum_bluntness_for_wind = try jsonF32(
            large_object.get("min_bluntness_for_wind") orelse
                return error.MissingMinimumBluntnessForWind,
        ),
        .wind_speed = .{
            try jsonF32(wind_speed[0]),
            try jsonF32(wind_speed[1]),
        },
        .dripstone_block = try stateIndex(
            allocator,
            &states,
            (large_object.get("dripstone_block") orelse
                return error.MissingDripstoneBlock).string,
        ),
    };
    const cluster_object =
        (parsed_features.value.object.get("dripstone_cluster") orelse
            return error.MissingDripstoneCluster).object;
    const cluster_count =
        (cluster_object.get("count") orelse return error.MissingCount).array.items;
    const cluster_height =
        (cluster_object.get("height") orelse return error.MissingHeight).array.items;
    const cluster_column_height =
        (cluster_object.get("column_height") orelse return error.MissingColumnHeight).array.items;
    const wetness =
        (cluster_object.get("wetness") orelse return error.MissingWetness).array.items;
    const density_values =
        (cluster_object.get("density") orelse return error.MissingDensity).array.items;
    const radius = (cluster_object.get("radius") orelse return error.MissingRadius).array.items;
    const layer =
        (cluster_object.get("layer_thickness") orelse
            return error.MissingLayerThickness).array.items;
    const cluster_pointed_values =
        (cluster_object.get("pointed_states") orelse return error.MissingPointedStates)
            .array.items;
    if (cluster_count.len != 2 or cluster_height.len != 5 or cluster_column_height.len != 2 or
        wetness.len != 4 or density_values.len != 2 or radius.len != 2 or
        layer.len != 2 or cluster_pointed_values.len != 10)
        return error.InvalidDripstoneCluster;
    var cluster_pointed_states: [10][2]u16 = undefined;
    for (cluster_pointed_values, &cluster_pointed_states) |value, *pair| {
        const values = value.array.items;
        if (values.len != 2) return error.InvalidPointedStates;
        pair.* = .{
            try stateIndex(allocator, &states, values[0].string),
            try stateIndex(allocator, &states, values[1].string),
        };
    }
    const dripstone_cluster: DripstoneCluster = .{
        .name = (cluster_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(cluster_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(cluster_object.get("index") orelse return error.MissingIndex),
        .count_minimum = try jsonU8(cluster_count[0]),
        .count_maximum = try jsonU8(cluster_count[1]),
        .height_minimum_kind = cluster_height[1].string,
        .height_minimum = try jsonI32(cluster_height[2]),
        .height_maximum_kind = cluster_height[3].string,
        .height_maximum = try jsonI32(cluster_height[4]),
        .search_range = try jsonU8(
            cluster_object.get("floor_to_ceiling_search_range") orelse
                return error.MissingSearchRange,
        ),
        .column_height_minimum = try jsonU8(cluster_column_height[0]),
        .column_height_maximum = try jsonU8(cluster_column_height[1]),
        .wetness = .{
            try jsonF32(wetness[0]),
            try jsonF32(wetness[1]),
            try jsonF32(wetness[2]),
            try jsonF32(wetness[3]),
        },
        .density = .{ try jsonF32(density_values[0]), try jsonF32(density_values[1]) },
        .radius_minimum = try jsonU8(radius[0]),
        .radius_maximum = try jsonU8(radius[1]),
        .max_height_difference = try jsonU8(
            cluster_object.get("max_height_difference") orelse
                return error.MissingMaxHeightDifference,
        ),
        .height_deviation = try jsonU8(
            cluster_object.get("height_deviation") orelse return error.MissingHeightDeviation,
        ),
        .layer_minimum = try jsonU8(layer[0]),
        .layer_maximum = try jsonU8(layer[1]),
        .edge_chance = try jsonF32(
            cluster_object.get("edge_chance") orelse return error.MissingEdgeChance,
        ),
        .edge_distance = try jsonU8(
            cluster_object.get("edge_distance") orelse return error.MissingEdgeDistance,
        ),
        .height_bias_distance = try jsonU8(
            cluster_object.get("height_bias_distance") orelse
                return error.MissingHeightBiasDistance,
        ),
        .pointed_states = cluster_pointed_states,
    };
    const lichen_object =
        (parsed_features.value.object.get("glow_lichen") orelse return error.MissingGlowLichen).object;
    const lichen_count =
        (lichen_object.get("count") orelse return error.MissingCount).array.items;
    if (lichen_count.len != 2) return error.InvalidCountRange;
    const lichen_height =
        (lichen_object.get("height") orelse return error.MissingHeight).array.items;
    if (lichen_height.len != 5 or
        !std.mem.eql(u8, lichen_height[0].string, "uniform"))
        return error.InvalidHeight;
    const place_on_values =
        (lichen_object.get("can_place_on") orelse return error.MissingCanPlaceOn).array.items;
    const can_place_on = try allocator.alloc([]const u8, place_on_values.len);
    for (place_on_values, can_place_on) |value, *name| name.* = value.string;
    if (states.items.len + 128 > std.math.maxInt(u16)) return error.TooManyFeatureStates;
    const lichen_state_base: u16 = @intCast(states.items.len);
    for (0..128) |bits| {
        const name = try std.fmt.allocPrint(
            allocator,
            "minecraft:glow_lichen[down={s},east={s},north={s},south={s},up={s},waterlogged={s},west={s}]",
            .{
                booleanName(bits & (1 << 0) != 0),
                booleanName(bits & (1 << 3) != 0),
                booleanName(bits & (1 << 2) != 0),
                booleanName(bits & (1 << 4) != 0),
                booleanName(bits & (1 << 1) != 0),
                booleanName(bits & (1 << 6) != 0),
                booleanName(bits & (1 << 5) != 0),
            },
        );
        try states.append(allocator, name);
    }
    const lichen: Lichen = .{
        .name = (lichen_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(lichen_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(lichen_object.get("index") orelse return error.MissingIndex),
        .count_minimum = try jsonU8(lichen_count[0]),
        .count_maximum = try jsonU8(lichen_count[1]),
        .minimum_kind = lichen_height[1].string,
        .minimum = try jsonI32(lichen_height[2]),
        .maximum_kind = lichen_height[3].string,
        .maximum = try jsonI32(lichen_height[4]),
        .surface_maximum = try jsonI32(
            lichen_object.get("surface_max") orelse return error.MissingSurfaceMaximum,
        ),
        .search_range = try jsonU8(
            lichen_object.get("search_range") orelse return error.MissingSearchRange,
        ),
        .spread_chance = try jsonF32(
            lichen_object.get("spread_chance") orelse return error.MissingSpreadChance,
        ),
        .can_place_on = can_place_on,
        .state_base = lichen_state_base,
    };
    const flowers_object =
        (parsed_features.value.object.get("forest_flowers") orelse
            return error.MissingForestFlowers).object;
    const flower_count =
        (flowers_object.get("count") orelse return error.MissingCount).array.items;
    if (flower_count.len != 4) return error.InvalidCountRange;
    const flower_states =
        (flowers_object.get("states") orelse return error.MissingStates).array.items;
    if (flower_states.len != 4) return error.InvalidStates;
    var lower_states: [3]u16 = undefined;
    var upper_states: [3]u16 = undefined;
    for (flower_states[0..3], 0..) |value, index| {
        lower_states[index] = try stateIndex(
            allocator,
            &states,
            try std.fmt.allocPrint(allocator, "{s}[half=lower]", .{value.string}),
        );
        upper_states[index] = try stateIndex(
            allocator,
            &states,
            try std.fmt.allocPrint(allocator, "{s}[half=upper]", .{value.string}),
        );
    }
    const flowers: ForestFlowers = .{
        .name = (flowers_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(flowers_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(flowers_object.get("index") orelse return error.MissingIndex),
        .rarity = try jsonU16(flowers_object.get("rarity") orelse return error.MissingRarity),
        .count_minimum = try jsonI8(flower_count[0]),
        .count_maximum = try jsonI8(flower_count[1]),
        .count_clamp_minimum = try jsonU8(flower_count[2]),
        .count_clamp_maximum = try jsonU8(flower_count[3]),
        .tries = try jsonU8(flowers_object.get("tries") orelse return error.MissingTries),
        .xz_spread = try jsonU8(
            flowers_object.get("xz_spread") orelse return error.MissingHorizontalSpread,
        ),
        .y_spread = try jsonU8(
            flowers_object.get("y_spread") orelse return error.MissingVerticalSpread,
        ),
        .lower_states = lower_states,
        .upper_states = upper_states,
        .lily_state = try stateIndex(allocator, &states, flower_states[3].string),
    };
    const flower_forest_object =
        (parsed_features.value.object.get("flower_forest_flowers") orelse
            return error.MissingFlowerForestFlowers).object;
    const flower_forest_count =
        (flower_forest_object.get("count") orelse return error.MissingCount).array.items;
    if (flower_forest_count.len != 4) return error.InvalidCountRange;
    const flower_forest_flowers: ForestFlowers = .{
        .name = (flower_forest_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(flower_forest_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(flower_forest_object.get("index") orelse return error.MissingIndex),
        .rarity = try jsonU16(
            flower_forest_object.get("rarity") orelse return error.MissingRarity,
        ),
        .count_minimum = try jsonI8(flower_forest_count[0]),
        .count_maximum = try jsonI8(flower_forest_count[1]),
        .count_clamp_minimum = try jsonU8(flower_forest_count[2]),
        .count_clamp_maximum = try jsonU8(flower_forest_count[3]),
        .tries = try jsonU8(
            flower_forest_object.get("tries") orelse return error.MissingTries,
        ),
        .xz_spread = try jsonU8(
            flower_forest_object.get("xz_spread") orelse
                return error.MissingHorizontalSpread,
        ),
        .y_spread = try jsonU8(
            flower_forest_object.get("y_spread") orelse
                return error.MissingVerticalSpread,
        ),
        .lower_states = flowers.lower_states,
        .upper_states = flowers.upper_states,
        .lily_state = flowers.lily_state,
    };
    const cave_vines_object =
        (parsed_features.value.object.get("cave_vines") orelse
            return error.MissingCaveVines).object;
    const cave_vines_height =
        (cave_vines_object.get("height") orelse return error.MissingHeight).array.items;
    const cave_vines_ranges =
        (cave_vines_object.get("plant_height_ranges") orelse
            return error.MissingPlantHeightRanges).array.items;
    const cave_vines_weights =
        (cave_vines_object.get("plant_height_weights") orelse
            return error.MissingPlantHeightWeights).array.items;
    const cave_vines_plant_states =
        (cave_vines_object.get("plant_states") orelse return error.MissingStates).array.items;
    const cave_vines_tip_states =
        (cave_vines_object.get("tip_states") orelse return error.MissingStates).array.items;
    if (cave_vines_height.len != 2 or cave_vines_ranges.len != 3 or
        cave_vines_weights.len != 3 or cave_vines_plant_states.len != 2 or
        cave_vines_tip_states.len != 6) return error.InvalidCaveVines;
    var cave_vines_range_values: [3][2]u8 = undefined;
    for (cave_vines_ranges, &cave_vines_range_values) |range_value, *range| {
        const entries = range_value.array.items;
        if (entries.len != 2) return error.InvalidCaveVines;
        range.* = .{ try jsonU8(entries[0]), try jsonU8(entries[1]) };
    }
    var cave_vines_weight_values: [3]u8 = undefined;
    for (cave_vines_weights, &cave_vines_weight_values) |value, *weight|
        weight.* = try jsonU8(value);
    var cave_vines_plant_state_values: [2]u16 = undefined;
    for (cave_vines_plant_states, &cave_vines_plant_state_values) |value, *state|
        state.* = try stateIndex(allocator, &states, value.string);
    var cave_vines_tip_state_values: [6]u16 = undefined;
    for (cave_vines_tip_states, &cave_vines_tip_state_values) |value, *state|
        state.* = try stateIndex(allocator, &states, value.string);
    const cave_vines: CaveVines = .{
        .name = (cave_vines_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(cave_vines_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(cave_vines_object.get("index") orelse return error.MissingIndex),
        .count = try jsonU16(cave_vines_object.get("count") orelse return error.MissingCount),
        .height_minimum = try jsonI16(cave_vines_height[0]),
        .height_maximum = try jsonI16(cave_vines_height[1]),
        .search_range = try jsonU8(
            cave_vines_object.get("search_range") orelse return error.MissingSearchRange,
        ),
        .plant_height_ranges = cave_vines_range_values,
        .plant_height_weights = cave_vines_weight_values,
        .plant_states = cave_vines_plant_state_values,
        .tip_states = cave_vines_tip_state_values,
    };
    const flower_patch_values =
        (parsed_features.value.object.get("flower_patches") orelse
            return error.MissingFlowerPatches).array.items;
    if (flower_patch_values.len > 16) return error.TooManyFlowerPatches;
    var flower_patches: std.ArrayListUnmanaged(FlowerPatch) = .empty;
    for (flower_patch_values) |value| {
        const object = value.object;
        const count = (object.get("count") orelse return error.MissingCount).array.items;
        const state_values = (object.get("states") orelse return error.MissingStates).array.items;
        const weight_values = (object.get("weights") orelse return error.MissingWeights).array.items;
        if (count.len != 4 or state_values.len == 0 or state_values.len > 16 or
            state_values.len != weight_values.len) return error.InvalidFlowerPatch;
        var state_indices: [16]u16 = @splat(0);
        var weights: [16]u8 = @splat(0);
        var total_weight: u8 = 0;
        for (state_values, weight_values, state_indices[0..state_values.len], weights[0..state_values.len]) |
            state_value,
            weight_value,
            *state,
            *weight,
        | {
            state.* = try stateIndex(allocator, &states, state_value.string);
            weight.* = try jsonU8(weight_value);
            total_weight = std.math.add(u8, total_weight, weight.*) catch
                return error.FlowerWeightOverflow;
        }
        const variety = if (object.get("variety")) |entry| entry.array.items else &.{};
        const groups = if (object.get("groups")) |entry| entry.array.items else &.{};
        if (variety.len != 0 and variety.len != 2) return error.InvalidVariety;
        if (groups.len != 0 and groups.len != 2) return error.InvalidGroups;
        try flower_patches.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .count_kind = count[0].string,
            .count_below = try jsonU8(count[1]),
            .count_above = try jsonU8(count[2]),
            .count_noise = try jsonF64(count[3]),
            .rarity = try jsonU16(object.get("rarity") orelse return error.MissingRarity),
            .heightmap = if (object.get("heightmap")) |entry|
                entry.string
            else
                "motion_blocking",
            .tries = try jsonU8(object.get("tries") orelse return error.MissingTries),
            .xz_spread = try jsonU8(object.get("xz_spread") orelse return error.MissingHorizontalSpread),
            .y_spread = try jsonU8(object.get("y_spread") orelse return error.MissingVerticalSpread),
            .provider = (object.get("provider") orelse return error.MissingProvider).string,
            .first_octave = try jsonI8(object.get("first_octave") orelse return error.MissingFirstOctave),
            .scale = try jsonF32(object.get("scale") orelse return error.MissingScale),
            .slow_first_octave = if (object.get("slow_first_octave")) |entry| try jsonI8(entry) else 0,
            .slow_scale = if (object.get("slow_scale")) |entry| try jsonF32(entry) else 1,
            .variety_minimum = if (variety.len == 2) try jsonU8(variety[0]) else 0,
            .variety_maximum = if (variety.len == 2) try jsonU8(variety[1]) else 0,
            .threshold = if (object.get("threshold")) |entry| try jsonF32(entry) else 0,
            .high_chance = if (object.get("high_chance")) |entry| try jsonF32(entry) else 0,
            .low_count = if (groups.len == 2) try jsonU8(groups[0]) else 0,
            .high_count = if (groups.len == 2) try jsonU8(groups[1]) else 0,
            .state_count = @intCast(state_values.len),
            .total_weight = total_weight,
            .upper_state = if (object.get("upper_state")) |entry|
                try stateIndex(allocator, &states, entry.string)
            else
                null,
            .states = state_indices,
            .weights = weights,
        });
    }
    std.mem.sort(FlowerPatch, flower_patches.items, {}, struct {
        fn lessThan(_: void, left: FlowerPatch, right: FlowerPatch) bool {
            return left.index < right.index;
        }
    }.lessThan);
    const tree_object =
        (parsed_features.value.object.get("oak_leaf_litter_trees") orelse
            return error.MissingOakLeafLitterTrees).object;
    const tree_count = (tree_object.get("count") orelse return error.MissingCount).array.items;
    if (tree_count.len != 4) return error.InvalidCountRange;
    const tree_selectors =
        (tree_object.get("selectors") orelse return error.MissingSelectors).array.items;
    if (tree_selectors.len != 4) return error.InvalidSelectors;
    const trunk_height =
        (tree_object.get("trunk_height") orelse return error.MissingTrunkHeight).array.items;
    if (trunk_height.len != 3) return error.InvalidTrunkHeight;
    const leaf_name = (tree_object.get("leaf_state") orelse return error.MissingLeafState).string;
    const leaf_state_base: u16 = @intCast(states.items.len);
    for (1..8) |distance| {
        try states.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}[distance={d},persistent=false,waterlogged=false]",
            .{ leaf_name, distance },
        ));
    }
    const birch_leaf_name =
        (tree_object.get("birch_leaf_state") orelse return error.MissingBirchLeafState).string;
    const birch_leaf_state_base: u16 = @intCast(states.items.len);
    for (1..8) |distance| {
        try states.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}[distance={d},persistent=false,waterlogged=false]",
            .{ birch_leaf_name, distance },
        ));
    }
    const spruce_leaf_name =
        (tree_object.get("spruce_leaf_state") orelse return error.MissingSpruceLeafState).string;
    const spruce_leaf_state_base: u16 = @intCast(states.items.len);
    for (1..8) |distance| {
        try states.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}[distance={d},persistent=false,waterlogged=false]",
            .{ spruce_leaf_name, distance },
        ));
    }
    const acacia_leaf_name =
        (tree_object.get("acacia_leaf_state") orelse return error.MissingAcaciaLeafState).string;
    const acacia_leaf_state_base: u16 = @intCast(states.items.len);
    for (1..8) |distance| {
        try states.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}[distance={d},persistent=false,waterlogged=false]",
            .{ acacia_leaf_name, distance },
        ));
    }
    const jungle_leaf_name =
        (tree_object.get("jungle_leaf_state") orelse return error.MissingJungleLeafState).string;
    const jungle_leaf_state_base: u16 = @intCast(states.items.len);
    for (1..8) |distance| {
        try states.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}[distance={d},persistent=false,waterlogged=false]",
            .{ jungle_leaf_name, distance },
        ));
    }
    var cocoa_states: [4][3]u16 = undefined;
    const cocoa_directions = [_][]const u8{ "north", "east", "south", "west" };
    const cocoa_name = (tree_object.get("cocoa_state") orelse return error.MissingCocoaState).string;
    for (cocoa_directions, 0..) |direction, direction_index| {
        for (0..3) |age| {
            cocoa_states[direction_index][age] = try stateIndex(
                allocator,
                &states,
                try std.fmt.allocPrint(allocator, "{s}[age={d},facing={s}]", .{ cocoa_name, age, direction }),
            );
        }
    }
    const litter_name =
        (tree_object.get("litter_state") orelse return error.MissingLitterState).string;
    const litter_state_base: u16 = @intCast(states.items.len);
    const litter_directions = [_][]const u8{ "north", "east", "south", "west" };
    for (1..5) |segments| {
        for (litter_directions) |direction| {
            try states.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}[facing={s},segment_amount={d}]",
                .{ litter_name, direction, segments },
            ));
        }
    }
    if (states.items.len > std.math.maxInt(u16) + 1) return error.TooManyFeatureStates;
    const tree: Tree = .{
        .name = (tree_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(tree_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(tree_object.get("index") orelse return error.MissingIndex),
        .count_minimum = try jsonU8(tree_count[0]),
        .count_maximum = try jsonU8(tree_count[1]),
        .minimum_weight = try jsonU8(tree_count[2]),
        .maximum_weight = try jsonU8(tree_count[3]),
        .selectors = .{
            try jsonF32(tree_selectors[0]),
            try jsonF32(tree_selectors[1]),
            try jsonF32(tree_selectors[2]),
            try jsonF32(tree_selectors[3]),
        },
        .trunk_base_height = try jsonU8(trunk_height[0]),
        .trunk_height_rand_a = try jsonU8(trunk_height[1]),
        .trunk_height_rand_b = try jsonU8(trunk_height[2]),
        .foliage_radius = try jsonU8(
            tree_object.get("foliage_radius") orelse return error.MissingFoliageRadius,
        ),
        .foliage_height = try jsonU8(
            tree_object.get("foliage_height") orelse return error.MissingFoliageHeight,
        ),
        .beehive_probability = try jsonF32(
            tree_object.get("beehive_probability") orelse
                return error.MissingBeehiveProbability,
        ),
        .dirt_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("dirt_state") orelse return error.MissingDirtState).string,
        ),
        .log_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("log_state") orelse return error.MissingLogState).string,
        ),
        .log_x_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("log_x_state") orelse return error.MissingLogXState).string,
        ),
        .log_z_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("log_z_state") orelse return error.MissingLogZState).string,
        ),
        .leaf_state_base = leaf_state_base,
        .birch_log_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("birch_log_state") orelse
                return error.MissingBirchLogState).string,
        ),
        .birch_log_x_state = try stateIndex(
            allocator,
            &states,
            "minecraft:birch_log[axis=x]",
        ),
        .birch_log_z_state = try stateIndex(
            allocator,
            &states,
            "minecraft:birch_log[axis=z]",
        ),
        .birch_leaf_state_base = birch_leaf_state_base,
        .spruce_log_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("spruce_log_state") orelse
                return error.MissingSpruceLogState).string,
        ),
        .spruce_log_x_state = try stateIndex(
            allocator,
            &states,
            "minecraft:spruce_log[axis=x]",
        ),
        .spruce_log_z_state = try stateIndex(
            allocator,
            &states,
            "minecraft:spruce_log[axis=z]",
        ),
        .spruce_leaf_state_base = spruce_leaf_state_base,
        .acacia_log_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("acacia_log_state") orelse return error.MissingAcaciaLogState).string,
        ),
        .acacia_leaf_state_base = acacia_leaf_state_base,
        .podzol_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("podzol_state") orelse return error.MissingPodzolState).string,
        ),
        .jungle_log_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("jungle_log_state") orelse return error.MissingJungleLogState).string,
        ),
        .jungle_log_x_state = try stateIndex(allocator, &states, "minecraft:jungle_log[axis=x]"),
        .jungle_log_z_state = try stateIndex(allocator, &states, "minecraft:jungle_log[axis=z]"),
        .jungle_leaf_state_base = jungle_leaf_state_base,
        .cocoa_states = cocoa_states,
        .litter_state_base = litter_state_base,
        .red_mushroom_state = try stateIndex(allocator, &states, "minecraft:red_mushroom"),
        .brown_mushroom_state = try stateIndex(allocator, &states, "minecraft:brown_mushroom"),
        .vine_east_state = try stateIndex(
            allocator,
            &states,
            "minecraft:vine[east=true,north=false,south=false,up=false,west=false]",
        ),
        .vine_west_state = try stateIndex(
            allocator,
            &states,
            "minecraft:vine[east=false,north=false,south=false,up=false,west=true]",
        ),
        .vine_south_state = try stateIndex(
            allocator,
            &states,
            "minecraft:vine[east=false,north=false,south=true,up=false,west=false]",
        ),
        .vine_north_state = try stateIndex(
            allocator,
            &states,
            "minecraft:vine[east=false,north=true,south=false,up=false,west=false]",
        ),
        .bee_nest_state = try stateIndex(
            allocator,
            &states,
            (tree_object.get("bee_nest_state") orelse
                return error.MissingBeeNestState).string,
        ),
    };
    const birch_trees_object =
        (parsed_features.value.object.get("birch_trees") orelse
            return error.MissingBirchTrees).object;
    const birch_tree_counts =
        (birch_trees_object.get("count") orelse return error.MissingCount).array.items;
    const birch_tree_weights =
        (birch_trees_object.get("weights") orelse return error.MissingWeights).array.items;
    if (birch_tree_counts.len != 2 or birch_tree_weights.len != 2)
        return error.InvalidBirchTrees;
    const birch_trees: BirchTrees = .{
        .name = (birch_trees_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(birch_trees_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(birch_trees_object.get("index") orelse return error.MissingIndex),
        .count_minimum = try jsonU8(birch_tree_counts[0]),
        .count_maximum = try jsonU8(birch_tree_counts[1]),
        .minimum_weight = try jsonU8(birch_tree_weights[0]),
        .maximum_weight = try jsonU8(birch_tree_weights[1]),
        .fallen_chance = try jsonF32(
            birch_trees_object.get("fallen_chance") orelse return error.MissingChance,
        ),
        .beehive_probability = try jsonF32(
            birch_trees_object.get("beehive_probability") orelse
                return error.MissingBeehiveProbability,
        ),
    };
    const tall_birch_object =
        (parsed_features.value.object.get("tall_birch_trees") orelse
            return error.MissingTallBirchTrees).object;
    const tall_birch_counts =
        (tall_birch_object.get("count") orelse return error.MissingCount).array.items;
    const tall_birch_weights =
        (tall_birch_object.get("weights") orelse return error.MissingWeights).array.items;
    const tall_birch_selectors =
        (tall_birch_object.get("selectors") orelse return error.MissingSelectors).array.items;
    if (tall_birch_counts.len != 2 or tall_birch_weights.len != 2 or
        tall_birch_selectors.len != 3) return error.InvalidTallBirchTrees;
    const tall_birch_trees: TallBirchTrees = .{
        .name = (tall_birch_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(tall_birch_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(tall_birch_object.get("index") orelse return error.MissingIndex),
        .count_minimum = try jsonU8(tall_birch_counts[0]),
        .count_maximum = try jsonU8(tall_birch_counts[1]),
        .minimum_weight = try jsonU8(tall_birch_weights[0]),
        .maximum_weight = try jsonU8(tall_birch_weights[1]),
        .selectors = .{
            try jsonF32(tall_birch_selectors[0]),
            try jsonF32(tall_birch_selectors[1]),
            try jsonF32(tall_birch_selectors[2]),
        },
        .beehive_probability = try jsonF32(
            tall_birch_object.get("beehive_probability") orelse
                return error.MissingBeehiveProbability,
        ),
    };
    const basic_tree_values =
        (parsed_features.value.object.get("basic_tree_selectors") orelse
            return error.MissingBasicTreeSelectors).array.items;
    if (basic_tree_values.len > 64) return error.TooManyBasicTreeSelectors;
    var basic_tree_selectors: std.ArrayListUnmanaged(BasicTreeSelector) = .empty;
    for (basic_tree_values) |value| {
        const object = value.object;
        const choice_values =
            (object.get("choices") orelse return error.MissingChoices).array.items;
        const chance_values =
            (object.get("chances") orelse return error.MissingChances).array.items;
        if (choice_values.len != chance_values.len or choice_values.len > 4)
            return error.InvalidBasicTreeSelector;
        var choices: [4][]const u8 = .{ "oak", "oak", "oak", "oak" };
        var chances: [4]f32 = .{ 0, 0, 0, 0 };
        for (choice_values, chance_values, 0..) |choice, chance, index| {
            choices[index] = choice.string;
            chances[index] = try jsonF32(chance);
        }
        const kind = (object.get("count_kind") orelse return error.MissingCountKind).string;
        var count_minimum: u8 = 0;
        var count_maximum: u8 = 0;
        var minimum_weight: u8 = 0;
        var maximum_weight: u8 = 0;
        var rarity: u16 = 0;
        if (std.mem.eql(u8, kind, "weighted")) {
            const counts = (object.get("count") orelse return error.MissingCount).array.items;
            const weights = (object.get("weights") orelse return error.MissingWeights).array.items;
            if (counts.len != 2 or weights.len != 2) return error.InvalidCountRange;
            count_minimum = try jsonU8(counts[0]);
            count_maximum = try jsonU8(counts[1]);
            minimum_weight = try jsonU8(weights[0]);
            maximum_weight = try jsonU8(weights[1]);
        } else if (std.mem.eql(u8, kind, "rarity")) {
            rarity = try jsonU16(object.get("rarity") orelse return error.MissingRarity);
        } else return error.InvalidCountKind;
        try basic_tree_selectors.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .count_kind = kind,
            .count_minimum = count_minimum,
            .count_maximum = count_maximum,
            .minimum_weight = minimum_weight,
            .maximum_weight = maximum_weight,
            .rarity = rarity,
            .survival_filter = (object.get("survival_filter") orelse
                return error.MissingSurvivalFilter).bool,
            .max_water_depth = if (object.get("max_water_depth")) |depth|
                try jsonU8(depth)
            else
                0,
            .choice_count = @intCast(choice_values.len),
            .choices = choices,
            .chances = chances,
            .default_choice = (object.get("default") orelse
                return error.MissingDefault).string,
        });
    }
    std.mem.sort(BasicTreeSelector, basic_tree_selectors.items, {}, struct {
        fn lessThan(_: void, left: BasicTreeSelector, right: BasicTreeSelector) bool {
            return left.index < right.index;
        }
    }.lessThan);
    const mushroom_object =
        (parsed_features.value.object.get("mushroom_island_vegetation") orelse
            return error.MissingMushroomIslandVegetation).object;
    const mushroom_radius =
        (mushroom_object.get("foliage_radius") orelse return error.MissingRadius).array.items;
    if (mushroom_radius.len != 2) return error.InvalidRadius;
    var mushroom_cap_states: [2][64]u16 = undefined;
    for ([_][]const u8{ "brown_cap", "red_cap" }, &mushroom_cap_states) |field, *cap_states| {
        const block = (mushroom_object.get(field) orelse return error.MissingState).string;
        for (cap_states, 0..) |*state, bits| {
            const name = try std.fmt.allocPrint(
                allocator,
                "{s}[down={s},east={s},north={s},south={s},up={s},west={s}]",
                .{
                    block,
                    booleanName(bits & 1 != 0),
                    booleanName(bits & 2 != 0),
                    booleanName(bits & 4 != 0),
                    booleanName(bits & 8 != 0),
                    booleanName(bits & 16 != 0),
                    booleanName(bits & 32 != 0),
                },
            );
            state.* = try stateIndex(allocator, &states, name);
        }
    }
    const huge_mushroom: HugeMushroom = .{
        .name = (mushroom_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(mushroom_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(mushroom_object.get("index") orelse return error.MissingIndex),
        .foliage_radius = .{ try jsonU8(mushroom_radius[0]), try jsonU8(mushroom_radius[1]) },
        .cap_states = mushroom_cap_states,
        .stem_state = try stateIndex(
            allocator,
            &states,
            (mushroom_object.get("stem") orelse return error.MissingState).string,
        ),
    };
    const patch_object =
        (parsed_features.value.object.get("patch_grass_forest") orelse
            return error.MissingPatchGrassForest).object;
    const patch: RandomPatch = .{
        .name = (patch_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(patch_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(patch_object.get("index") orelse return error.MissingIndex),
        .count = try jsonU8(patch_object.get("count") orelse return error.MissingCount),
        .tries = try jsonU8(patch_object.get("tries") orelse return error.MissingTries),
        .xz_spread = try jsonU8(
            patch_object.get("xz_spread") orelse return error.MissingHorizontalSpread,
        ),
        .y_spread = try jsonU8(
            patch_object.get("y_spread") orelse return error.MissingVerticalSpread,
        ),
        .state = try stateIndex(
            allocator,
            &states,
            (patch_object.get("state") orelse return error.MissingState).string,
        ),
    };
    const surface_patch_values =
        (parsed_features.value.object.get("surface_patches") orelse
            return error.MissingSurfacePatches).array.items;
    if (surface_patch_values.len > 64) return error.TooManySurfacePatches;
    var surface_patches: std.ArrayListUnmanaged(SurfacePatch) = .empty;
    for (surface_patch_values) |value| {
        const object = value.object;
        const patch_states =
            (object.get("states") orelse return error.MissingStates).array.items;
        if (patch_states.len == 0 or patch_states.len > 12) return error.InvalidStates;
        var patch_state_indices: [12]u16 = @splat(0);
        for (patch_states, patch_state_indices[0..patch_states.len]) |state, *state_index|
            state_index.* = try stateIndex(allocator, &states, state.string);
        try surface_patches.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .count = if (object.get("count")) |count| try jsonU8(count) else 1,
            .rarity = try jsonU16(object.get("rarity") orelse return error.MissingRarity),
            .heightmap = if (object.get("heightmap")) |heightmap|
                heightmap.string
            else
                "motion_blocking",
            .tries = try jsonU8(object.get("tries") orelse return error.MissingTries),
            .xz_spread = try jsonU8(
                object.get("xz_spread") orelse return error.MissingHorizontalSpread,
            ),
            .y_spread = try jsonU8(
                object.get("y_spread") orelse return error.MissingVerticalSpread,
            ),
            .placement = (object.get("placement") orelse return error.MissingPlacement).string,
            .state_count = @intCast(patch_states.len),
            .states = patch_state_indices,
        });
    }
    std.mem.sort(SurfacePatch, surface_patches.items, {}, struct {
        fn lessThan(_: void, a: SurfacePatch, b: SurfacePatch) bool {
            return a.index < b.index;
        }
    }.lessThan);
    const near_water_patch_values =
        (parsed_features.value.object.get("near_water_patches") orelse
            return error.MissingNearWaterPatches).array.items;
    if (near_water_patch_values.len > 8) return error.TooManyNearWaterPatches;
    var near_water_patches: std.ArrayListUnmanaged(NearWaterPatch) = .empty;
    for (near_water_patch_values) |value| {
        const object = value.object;
        const column_height =
            (object.get("column_height") orelse return error.MissingColumnHeight).array.items;
        if (column_height.len != 2) return error.InvalidColumnHeight;
        try near_water_patches.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .count = try jsonU8(object.get("count") orelse return error.MissingCount),
            .rarity = try jsonU16(object.get("rarity") orelse return error.MissingRarity),
            .heightmap = (object.get("heightmap") orelse return error.MissingHeightmap).string,
            .tries = try jsonU8(object.get("tries") orelse return error.MissingTries),
            .xz_spread = try jsonU8(
                object.get("xz_spread") orelse return error.MissingHorizontalSpread,
            ),
            .y_spread = try jsonU8(
                object.get("y_spread") orelse return error.MissingVerticalSpread,
            ),
            .placement = (object.get("placement") orelse return error.MissingPlacement).string,
            .state = try stateIndex(
                allocator,
                &states,
                (object.get("state") orelse return error.MissingState).string,
            ),
            .column_minimum = try jsonU8(column_height[0]),
            .column_maximum = try jsonU8(column_height[1]),
        });
    }
    const noise_grass_patch_values =
        (parsed_features.value.object.get("noise_grass_patches") orelse
            return error.MissingNoiseGrassPatches).array.items;
    if (noise_grass_patch_values.len > 8) return error.TooManyNoiseGrassPatches;
    var noise_grass_patches: std.ArrayListUnmanaged(NoiseGrassPatch) = .empty;
    for (noise_grass_patch_values) |value| {
        const object = value.object;
        try noise_grass_patches.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .noise_level = try jsonF64(
                object.get("noise_level") orelse return error.MissingNoiseLevel,
            ),
            .below_noise = try jsonU8(
                object.get("below_noise") orelse return error.MissingBelowNoise,
            ),
            .above_noise = try jsonU8(
                object.get("above_noise") orelse return error.MissingAboveNoise,
            ),
            .rarity = if (object.get("rarity")) |rarity| try jsonU16(rarity) else 1,
            .heightmap = (object.get("heightmap") orelse return error.MissingHeightmap).string,
            .tries = try jsonU8(object.get("tries") orelse return error.MissingTries),
            .xz_spread = try jsonU8(
                object.get("xz_spread") orelse return error.MissingHorizontalSpread,
            ),
            .y_spread = try jsonU8(
                object.get("y_spread") orelse return error.MissingVerticalSpread,
            ),
            .state = try stateIndex(
                allocator,
                &states,
                (object.get("state") orelse return error.MissingState).string,
            ),
            .upper_state = if (object.get("upper_state")) |state|
                try stateIndex(allocator, &states, state.string)
            else
                0,
            .double_plant = object.get("upper_state") != null,
        });
    }
    const freeze_object =
        (parsed_features.value.object.get("freeze_top_layer") orelse
            return error.MissingFreezeTopLayer).object;
    const snowy_values =
        (freeze_object.get("snowy_states") orelse return error.MissingSnowyStates).array.items;
    if (snowy_values.len != 3) return error.InvalidSnowyStates;
    var snowy_states: [3][2]u16 = undefined;
    for (snowy_values, &snowy_states) |value, *pair| {
        const values = value.array.items;
        if (values.len != 2) return error.InvalidSnowyStates;
        pair.* = .{
            try stateIndex(allocator, &states, values[0].string),
            try stateIndex(allocator, &states, values[1].string),
        };
    }
    const freeze_top_layer: FreezeTopLayer = .{
        .name = (freeze_object.get("name") orelse return error.MissingName).string,
        .step = try jsonU8(freeze_object.get("step") orelse return error.MissingStep),
        .index = try jsonU8(freeze_object.get("index") orelse return error.MissingIndex),
        .ice_state = try stateIndex(
            allocator,
            &states,
            (freeze_object.get("ice_state") orelse return error.MissingIceState).string,
        ),
        .snow_state = try stateIndex(
            allocator,
            &states,
            (freeze_object.get("snow_state") orelse return error.MissingSnowState).string,
        ),
        .snowy_states = snowy_states,
    };
    const seagrass_values =
        (parsed_features.value.object.get("seagrass") orelse
            return error.MissingSeagrass).array.items;
    if (seagrass_values.len > 8) return error.TooManySeagrassFeatures;
    var seagrass: std.ArrayListUnmanaged(Seagrass) = .empty;
    for (seagrass_values) |value| {
        const object = value.object;
        try seagrass.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .count = try jsonU8(object.get("count") orelse return error.MissingCount),
            .tall_probability = try jsonF32(
                object.get("tall_probability") orelse return error.MissingTallProbability,
            ),
        });
    }
    const kelp_values =
        (parsed_features.value.object.get("kelp") orelse return error.MissingKelp).array.items;
    if (kelp_values.len > 8) return error.TooManyKelpFeatures;
    var kelp: std.ArrayListUnmanaged(Kelp) = .empty;
    for (kelp_values) |value| {
        const object = value.object;
        try kelp.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .noise_factor = try jsonF64(
                object.get("noise_factor") orelse return error.MissingNoiseFactor,
            ),
            .noise_to_count_ratio = try jsonU16(
                object.get("noise_to_count_ratio") orelse return error.MissingNoiseToCountRatio,
            ),
        });
    }
    const aquatic_states =
        (parsed_features.value.object.get("aquatic_states") orelse
            return error.MissingAquaticStates).object;
    const kelp_state_values =
        (aquatic_states.get("kelp") orelse return error.MissingKelpStates).array.items;
    if (kelp_state_values.len != 4) return error.InvalidKelpStates;
    const seagrass_state = try stateIndex(
        allocator,
        &states,
        (aquatic_states.get("seagrass") orelse return error.MissingSeagrassState).string,
    );
    const tall_seagrass_lower_state = try stateIndex(
        allocator,
        &states,
        (aquatic_states.get("tall_seagrass_lower") orelse
            return error.MissingTallSeagrassLowerState).string,
    );
    const tall_seagrass_upper_state = try stateIndex(
        allocator,
        &states,
        (aquatic_states.get("tall_seagrass_upper") orelse
            return error.MissingTallSeagrassUpperState).string,
    );
    const kelp_plant_state = try stateIndex(
        allocator,
        &states,
        (aquatic_states.get("kelp_plant") orelse return error.MissingKelpPlantState).string,
    );
    var kelp_states: [4]u16 = undefined;
    for (kelp_state_values, &kelp_states) |value, *state|
        state.* = try stateIndex(allocator, &states, value.string);

    const simple_feature_values =
        (parsed_features.value.object.get("simple_features") orelse
            return error.MissingSimpleFeatures).array.items;
    if (simple_feature_values.len > 16) return error.TooManySimpleFeatures;
    var simple_features: std.ArrayListUnmanaged(SimpleFeature) = .empty;
    for (simple_feature_values) |value| {
        const object = value.object;
        const count = (object.get("count") orelse return error.MissingCount).array.items;
        if (count.len != 2) return error.InvalidCount;
        const height_value = (object.get("height") orelse return error.MissingHeight).array.items;
        if (height_value.len != 3) return error.InvalidHeight;
        const state_values = (object.get("states") orelse return error.MissingStates).array.items;
        if (state_values.len == 0 or state_values.len > 5) return error.InvalidStates;
        var feature_states = [_]u16{0} ** 5;
        for (state_values, feature_states[0..state_values.len]) |state, *state_index|
            state_index.* = try stateIndex(allocator, &states, state.string);
        try simple_features.append(allocator, .{
            .name = (object.get("name") orelse return error.MissingName).string,
            .step = try jsonU8(object.get("step") orelse return error.MissingStep),
            .index = try jsonU8(object.get("index") orelse return error.MissingIndex),
            .kind = (object.get("kind") orelse return error.MissingKind).string,
            .count_kind = (object.get("count_kind") orelse return error.MissingCountKind).string,
            .count_minimum = try jsonU16(count[0]),
            .count_maximum = try jsonU16(count[1]),
            .height_kind = height_value[0].string,
            .height_minimum = try jsonI16(height_value[1]),
            .height_maximum = try jsonI16(height_value[2]),
            .state_count = @intCast(state_values.len),
            .states = feature_states,
        });
    }

    const tree_bytes = try cwd.readFileAlloc(init.io, biome_tree_path, allocator, .limited(4 * 1024 * 1024));
    const parsed_tree = try std.json.parseFromSlice(std.json.Value, allocator, tree_bytes, .{});
    var biome_names: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectBiomeNames(allocator, parsed_tree.value, &biome_names);

    var output = std.array_list.Managed(u8).init(allocator);
    try output.appendSlice(
        \\pub const OffsetKind = enum(u8) { absolute, above_bottom, below_top };
        \\pub const HeightKind = enum(u8) { uniform, trapezoid, very_biased_to_bottom };
        \\pub const CountKind = enum(u8) { constant, uniform, rarity };
        \\pub const TargetTag = enum(u8) { base_stone_overworld, stone_ore_replaceables, deepslate_ore_replaceables };
        \\pub const Height = struct { kind: HeightKind, minimum_kind: OffsetKind, minimum: i32, maximum_kind: OffsetKind, maximum: i32, inner: u16 = 1 };
        \\pub const Count = struct { kind: CountKind, minimum: u8, maximum: u8 };
        \\pub const Target = struct { tag: TargetTag, state: u16 };
        \\pub const Ore = struct { name: []const u8, step: u8, index: u8, count: Count, height: Height, size: u8, discard: f32, targets: []const Target };
        \\pub const DiskStateRule = enum(u8) { below_air, above_open };
        \\pub const Disk = struct { name: []const u8, index: u8, count: u8, radius_minimum: u8, radius_maximum: u8, half_height: u8, requires_water: bool, targets: []const u8, state: u16, state_above_air: ?u16, state_rule: DiskStateRule };
        \\pub const LavaLakePlacement = enum(u8) { underground, surface };
        \\pub const LavaLake = struct { name: []const u8, step: u8, index: u8, rarity: u16, placement: LavaLakePlacement, max_scan: u8, surface_maximum: i8, fluid: u16, air: u16, barrier: u16 };
        \\pub const Iceberg = struct { name: []const u8, step: u8, index: u8, rarity: u16, state: u16 };
        \\pub const MonsterRoom = struct { name: []const u8, step: u8, index: u8, count: u8, height_minimum: i16, height_maximum: i16 };
        \\pub const Magma = struct { name: []const u8, step: u8, index: u8, count: Count, height: Height, surface_maximum: i32, floor_search_range: u8, radius: u8, probability: f32, state: u16 };
        \\pub const Lichen = struct { name: []const u8, step: u8, index: u8, count: Count, height: Height, surface_maximum: i32, search_range: u8, spread_chance: f32, can_place_on: []const []const u8, state_base: u16 };
        \\pub const Tree = struct { name: []const u8, step: u8, index: u8, count_minimum: u8, count_maximum: u8, minimum_weight: u8, maximum_weight: u8, selectors: [4]f32, trunk_base_height: u8, trunk_height_rand_a: u8, trunk_height_rand_b: u8, foliage_radius: u8, foliage_height: u8, beehive_probability: f32, dirt_state: u16, log_state: u16, log_x_state: u16, log_z_state: u16, leaf_state_base: u16, birch_log_state: u16, birch_log_x_state: u16, birch_log_z_state: u16, birch_leaf_state_base: u16, spruce_log_state: u16, spruce_log_x_state: u16, spruce_log_z_state: u16, spruce_leaf_state_base: u16, acacia_log_state: u16, acacia_leaf_state_base: u16, podzol_state: u16, jungle_log_state: u16, jungle_log_x_state: u16, jungle_log_z_state: u16, jungle_leaf_state_base: u16, cocoa_states: [4][3]u16, litter_state_base: u16, red_mushroom_state: u16, brown_mushroom_state: u16, vine_east_state: u16, vine_west_state: u16, vine_south_state: u16, vine_north_state: u16, bee_nest_state: u16 };
        \\pub const BasicTreeCount = enum(u8) { weighted, rarity };
        \\pub const BasicTreeKind = enum(u8) { fallen_oak, fallen_birch, fallen_spruce, fallen_jungle, oak, oak_leaf_litter, oak_bees_002, oak_bees_005, fancy_oak, fancy_oak_bees_002, fancy_oak_bees_005, fancy_oak_bees, birch_bees_002, super_birch_bees, spruce, pine, spruce_on_snow, pine_on_snow, swamp_oak, acacia, mega_pine, mega_spruce, jungle_tree, jungle_bush, mega_jungle, jungle_grass };
        \\pub const BasicTreeSelector = struct { name: []const u8, step: u8, index: u8, count_kind: BasicTreeCount, count_minimum: u8, count_maximum: u8, minimum_weight: u8, maximum_weight: u8, rarity: u16, survival_filter: bool, max_water_depth: u8, choice_count: u8, choices: [4]BasicTreeKind, chances: [4]f32, default_choice: BasicTreeKind };
        \\pub const HugeMushroom = struct { name: []const u8, step: u8, index: u8, foliage_radius: [2]u8, cap_states: [2][64]u16, stem_state: u16 };
        \\pub const BirchTrees = struct { name: []const u8, step: u8, index: u8, count_minimum: u8, count_maximum: u8, minimum_weight: u8, maximum_weight: u8, fallen_chance: f32, beehive_probability: f32 };
        \\pub const TallBirchTrees = struct { name: []const u8, step: u8, index: u8, count_minimum: u8, count_maximum: u8, minimum_weight: u8, maximum_weight: u8, selectors: [3]f32, beehive_probability: f32 };
        \\pub const RandomPatch = struct { name: []const u8, step: u8, index: u8, count: u8, tries: u8, xz_spread: u8, y_spread: u8, state: u16 };
        \\pub const ForestFlowers = struct { name: []const u8, step: u8, index: u8, rarity: u16, count_minimum: i8, count_maximum: i8, count_clamp_minimum: u8, count_clamp_maximum: u8, tries: u8, xz_spread: u8, y_spread: u8, lower_states: [3]u16, upper_states: [3]u16, lily_state: u16 };
        \\pub const CaveVines = struct { name: []const u8, step: u8, index: u8, count: u16, height_minimum: i16, height_maximum: i16, search_range: u8, plant_height_ranges: [3][2]u8, plant_height_weights: [3]u8, plant_states: [2]u16, tip_states: [6]u16 };
        \\pub const FlowerCount = enum { constant, noise };
        \\pub const FlowerProvider = enum { simple, weighted, noise, dual_noise, noise_threshold };
        \\pub const FlowerPatch = struct { name: []const u8, step: u8, index: u8, count_kind: FlowerCount, count_below: u8, count_above: u8, count_noise: f64, rarity: u16, heightmap: Heightmap, tries: u8, xz_spread: u8, y_spread: u8, provider: FlowerProvider, first_octave: i8, scale: f32, slow_first_octave: i8, slow_scale: f32, variety_minimum: u8, variety_maximum: u8, threshold: f32, high_chance: f32, low_count: u8, high_count: u8, state_count: u8, total_weight: u8, upper_state: ?u16, states: [16]u16, weights: [16]u8 };
        \\pub const OreVeins = struct { copper_ore: u16, raw_copper_block: u16, granite: u16, iron_ore: u16, raw_iron_block: u16, tuff: u16 };
        \\pub const Spring = struct { name: []const u8, step: u8, index: u8, count: u8, height: Height, state: u16, requires_block_below: bool, rock_count: u8, hole_count: u8, valid_blocks: []const []const u8 };
        \\pub const PointedDripstone = struct { name: []const u8, step: u8, index: u8, count_minimum: u8, count_maximum: u16, height: Height, repetitions_minimum: u8, repetitions_maximum: u8, xz_mean: f32, xz_deviation: f32, xz_minimum: i8, xz_maximum: i8, y_mean: f32, y_deviation: f32, y_minimum: i8, y_maximum: i8, search_range: u8, taller_chance: f32, directional_spread_chance: f32, radius_two_chance: f32, radius_three_chance: f32, dripstone_block: u16, pointed_states: [4][2]u16 };
        \\pub const AmethystGeode = struct { name: []const u8, step: u8, index: u8, rarity: u8, height: Height, minimum_generation_offset: i8, maximum_generation_offset: i8, noise_multiplier: f64, invalid_blocks_threshold: u8, outer_wall_distance: [2]u8, distribution_points: [2]u8, point_offset: [2]u8, potential_placement_chance: f64, alternate_inner_layer_chance: f64, placements_require_alternate: bool, layer_thickness: [4]f64, crack_chance: f64, base_crack_size: f64, crack_point_offset: u8, inner_layer_state: u16, alternate_inner_layer_state: u16, middle_layer_state: u16, outer_layer_state: u16, inner_placements: [4][6][2]u16 };
        \\pub const LargeDripstone = struct { name: []const u8, step: u8, index: u8, count_minimum: u8, count_maximum: u8, height: Height, search_range: u8, radius_minimum: u8, radius_maximum: u8, height_scale: [2]f32, max_radius_to_cave_height_ratio: f32, stalactite_bluntness: [2]f32, stalagmite_bluntness: [2]f32, minimum_radius_for_wind: u8, minimum_bluntness_for_wind: f32, wind_speed: [2]f32, dripstone_block: u16 };
        \\pub const DripstoneCluster = struct { name: []const u8, step: u8, index: u8, count_minimum: u8, count_maximum: u8, height: Height, search_range: u8, column_height_minimum: u8, column_height_maximum: u8, wetness: [4]f32, density: [2]f32, radius_minimum: u8, radius_maximum: u8, max_height_difference: u8, height_deviation: u8, layer_minimum: u8, layer_maximum: u8, edge_chance: f32, edge_distance: u8, height_bias_distance: u8, pointed_states: [10][2]u16 };
        \\pub const SurfacePatchPlacement = enum(u8) { dirt, jungle_grass, taiga_grass, weighted_flower, mushroom, grass_block, dry_grass, dead_bush, double_plant, waterlily, leaf_litter, cactus };
        \\pub const SurfacePatch = struct { name: []const u8, step: u8, index: u8, count: u8, rarity: u16, heightmap: Heightmap, tries: u8, xz_spread: u8, y_spread: u8, placement: SurfacePatchPlacement, state_count: u8, states: [12]u16 };
        \\pub const NearWaterPatchPlacement = enum(u8) { sugar_cane, firefly_bush, firefly_bush_near_water };
        \\pub const NearWaterPatch = struct { name: []const u8, step: u8, index: u8, count: u8, rarity: u16, heightmap: Heightmap, tries: u8, xz_spread: u8, y_spread: u8, placement: NearWaterPatchPlacement, state: u16, column_minimum: u8, column_maximum: u8 };
        \\pub const Seagrass = struct { name: []const u8, step: u8, index: u8, count: u8, tall_probability: f32 };
        \\pub const Kelp = struct { name: []const u8, step: u8, index: u8, noise_factor: f64, noise_to_count_ratio: u16 };
        \\pub const SimpleFeatureKind = enum(u8) { forest_rock, ice_spike, ice_patch, desert_well, blue_ice, bamboo_podzol, bamboo, vines, sea_pickle, spore_blossom };
        \\pub const SimpleCountKind = enum(u8) { constant, uniform, rarity, noise };
        \\pub const SimpleHeightKind = enum(u8) { world_surface_wg, ocean_floor_wg, motion_blocking, uniform };
        \\pub const SimpleFeature = struct { name: []const u8, step: u8, index: u8, kind: SimpleFeatureKind, count_kind: SimpleCountKind, count_minimum: u16, count_maximum: u16, height_kind: SimpleHeightKind, height_minimum: i16, height_maximum: i16, state_count: u8, states: [5]u16 };
        \\pub const NoiseGrassPatch = struct { name: []const u8, step: u8, index: u8, noise_level: f64, below_noise: u8, above_noise: u8, rarity: u16, heightmap: Heightmap, tries: u8, xz_spread: u8, y_spread: u8, state: u16, upper_state: u16, double_plant: bool };
        \\pub const FreezeTopLayer = struct { name: []const u8, step: u8, index: u8, ice_state: u16, snow_state: u16, snowy_states: [3][2]u16 };
        \\pub const Heightmap = enum(u8) { world_surface_wg, motion_blocking, motion_blocking_no_leaves };
        \\
        \\pub const state_names = [_][]const u8{
        \\
    );
    for (states.items) |state| try output.print("    \"{s}\",\n", .{state});
    try output.appendSlice("};\n\npub const canonical_state_ids = [_]u32{\n");
    for (states.items) |state| {
        const canonical = minecraft.State.parse(state) orelse return error.UnknownBlockState;
        try output.print("    {d},\n", .{canonical.id});
    }
    try output.appendSlice("};\n\npub const log_or_leaves = [_]bool{\n");
    for (states.items) |state|
        try output.print("    {},\n", .{
            std.mem.indexOf(u8, state, "_leaves[") != null or
                std.mem.indexOf(u8, state, "_log[") != null,
        });
    var state_table_size: usize = 1;
    for (0..16) |_| {
        if (state_table_size >= states.items.len * 2) break;
        state_table_size *= 2;
    }
    if (state_table_size < states.items.len * 2) return error.TooManyFeatureStates;
    const state_table = try allocator.alloc(u16, state_table_size);
    defer allocator.free(state_table);
    @memset(state_table, std.math.maxInt(u16));
    for (states.items, 0..) |state, index| {
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
        if (!installed) return error.FeatureStateIndexFull;
    }
    try output.appendSlice("};\n\npub const state_index_table = [_]u16{\n");
    for (state_table) |index| try output.print("    {d},\n", .{index});
    try output.appendSlice(
        "};\n\npub fn stateIndex(comptime name: []const u8) u16 {\n" ++
            "    const index = comptime stateIndexLookup(name);\n" ++
            "    if (comptime index == null) @compileError(\"unknown feature state: \" ++ name);\n" ++
            "    return index.?;\n" ++
            "}\n" ++
            "fn stateIndexLookup(comptime name: []const u8) ?u16 {\n" ++
            "    var slot: usize = @intCast(stateNameHash(name) & (state_index_table.len - 1));\n" ++
            "    for (0..state_index_table.len) |_| {\n" ++
            "        const index = state_index_table[slot];\n" ++
            "        if (index == 65535) return null;\n" ++
            "        if (stateNameEqual(name, state_names[index])) return index;\n" ++
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
            "}\n\n" ++
            "pub const ores = [_]Ore{\n",
    );
    for (ores.items) |ore| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .count = .{{ .kind = .{s}, .minimum = {d}, .maximum = {d} }}, .height = .{{ .kind = .{s}, .minimum_kind = .{s}, .minimum = {d}, .maximum_kind = .{s}, .maximum = {d} }}, .size = {d}, .discard = @bitCast(@as(u32, 0x{x:0>8})), .targets = &.{{",
            .{
                ore.name,
                ore.step,
                ore.index,
                ore.count_kind,
                ore.count_minimum,
                ore.count_maximum,
                ore.placement,
                ore.minimum_kind,
                ore.minimum,
                ore.maximum_kind,
                ore.maximum,
                ore.size,
                @as(u32, @bitCast(ore.discard)),
            },
        );
        for (ore.targets) |target|
            try output.print(".{{ .tag = .{s}, .state = {d} }},", .{ target.tag, target.state_index });
        try output.appendSlice("} },\n");
    }
    try output.appendSlice("};\n\npub const lava_lakes = [_]LavaLake{\n");
    for (lava_lakes.items) |lake| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .rarity = {d}, .placement = .{s}, .max_scan = {d}, .surface_maximum = {d}, .fluid = {d}, .air = {d}, .barrier = {d} }},\n",
            .{
                lake.name,
                lake.step,
                lake.index,
                lake.rarity,
                lake.placement,
                lake.max_scan,
                lake.surface_maximum,
                lake.fluid,
                lake.air,
                lake.barrier,
            },
        );
    }
    try output.appendSlice("};\n\npub const icebergs = [_]Iceberg{\n");
    for (icebergs.items) |iceberg| try output.print(
        "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .rarity = {d}, .state = {d} }},\n",
        .{ iceberg.name, iceberg.step, iceberg.index, iceberg.rarity, iceberg.state },
    );
    try output.print(
        "}};\n\npub const iceberg_states = [5]u16{{ {d}, {d}, {d}, {d}, {d} }};\n\n",
        .{ iceberg_states[0], iceberg_states[1], iceberg_states[2], iceberg_states[3], iceberg_states[4] },
    );
    try output.appendSlice("pub const monster_rooms = [_]MonsterRoom{\n");
    for (monster_rooms.items) |room| try output.print(
        "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .count = {d}, .height_minimum = {d}, .height_maximum = {d} }},\n",
        .{ room.name, room.step, room.index, room.count, room.height_minimum, room.height_maximum },
    );
    try output.print(
        "}};\n\npub const monster_room_states = [8]u16{{ {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d} }};\n\n",
        .{
            monster_room_states[0], monster_room_states[1],
            monster_room_states[2], monster_room_states[3],
            monster_room_states[4], monster_room_states[5],
            monster_room_states[6], monster_room_states[7],
        },
    );
    try output.appendSlice("pub const fluid_springs = [_]Spring{\n");
    for (springs.items) |spring| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .count = {d}, .height = .{{ .kind = .{s}, .minimum_kind = .{s}, .minimum = {d}, .maximum_kind = .{s}, .maximum = {d}, .inner = {d} }}, .state = {d}, .requires_block_below = {}, .rock_count = {d}, .hole_count = {d}, .valid_blocks = &.{{",
            .{
                spring.name,
                spring.step,
                spring.index,
                spring.count,
                spring.height_kind,
                spring.minimum_kind,
                spring.minimum,
                spring.maximum_kind,
                spring.maximum,
                spring.inner,
                spring.state,
                spring.requires_block_below,
                spring.rock_count,
                spring.hole_count,
            },
        );
        for (spring.valid_blocks) |valid_block|
            try output.print("\"{s}\",", .{valid_block});
        try output.appendSlice("} },\n");
    }
    try output.print(
        \\}};
        \\
        \\pub const pointed_dripstone: PointedDripstone = .{{
        \\    .name = "{s}",
        \\    .step = {d},
        \\    .index = {d},
        \\    .count_minimum = {d},
        \\    .count_maximum = {d},
        \\    .height = .{{ .kind = .uniform, .minimum_kind = .{s}, .minimum = {d}, .maximum_kind = .{s}, .maximum = {d} }},
        \\    .repetitions_minimum = {d},
        \\    .repetitions_maximum = {d},
        \\    .xz_mean = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .xz_deviation = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .xz_minimum = {d},
        \\    .xz_maximum = {d},
        \\    .y_mean = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .y_deviation = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .y_minimum = {d},
        \\    .y_maximum = {d},
        \\    .search_range = {d},
        \\    .taller_chance = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .directional_spread_chance = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .radius_two_chance = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .radius_three_chance = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .dripstone_block = {d},
    , .{
        pointed_dripstone.name,
        pointed_dripstone.step,
        pointed_dripstone.index,
        pointed_dripstone.count_minimum,
        pointed_dripstone.count_maximum,
        pointed_dripstone.height_minimum_kind,
        pointed_dripstone.height_minimum,
        pointed_dripstone.height_maximum_kind,
        pointed_dripstone.height_maximum,
        pointed_dripstone.repetitions_minimum,
        pointed_dripstone.repetitions_maximum,
        @as(u32, @bitCast(pointed_dripstone.xz_mean)),
        @as(u32, @bitCast(pointed_dripstone.xz_deviation)),
        pointed_dripstone.xz_minimum,
        pointed_dripstone.xz_maximum,
        @as(u32, @bitCast(pointed_dripstone.y_mean)),
        @as(u32, @bitCast(pointed_dripstone.y_deviation)),
        pointed_dripstone.y_minimum,
        pointed_dripstone.y_maximum,
        pointed_dripstone.search_range,
        @as(u32, @bitCast(pointed_dripstone.taller_chance)),
        @as(u32, @bitCast(pointed_dripstone.directional_spread_chance)),
        @as(u32, @bitCast(pointed_dripstone.radius_two_chance)),
        @as(u32, @bitCast(pointed_dripstone.radius_three_chance)),
        pointed_dripstone.dripstone_block,
    });
    try output.print(
        \\    .pointed_states = .{{ .{{ {d}, {d} }}, .{{ {d}, {d} }}, .{{ {d}, {d} }}, .{{ {d}, {d} }} }},
        \\}};
    , .{
        pointed_dripstone.pointed_states[0][0],
        pointed_dripstone.pointed_states[0][1],
        pointed_dripstone.pointed_states[1][0],
        pointed_dripstone.pointed_states[1][1],
        pointed_dripstone.pointed_states[2][0],
        pointed_dripstone.pointed_states[2][1],
        pointed_dripstone.pointed_states[3][0],
        pointed_dripstone.pointed_states[3][1],
    });
    try output.print(
        \\
        \\pub const amethyst_geode: AmethystGeode = .{{
        \\    .name = "{s}", .step = {d}, .index = {d}, .rarity = {d},
        \\    .height = .{{ .kind = .uniform, .minimum_kind = .{s}, .minimum = {d}, .maximum_kind = .{s}, .maximum = {d} }},
        \\    .minimum_generation_offset = {d}, .maximum_generation_offset = {d},
        \\    .noise_multiplier = @bitCast(@as(u64, 0x{x:0>16})),
        \\    .invalid_blocks_threshold = {d},
        \\    .outer_wall_distance = .{{ {d}, {d} }},
        \\    .distribution_points = .{{ {d}, {d} }},
        \\    .point_offset = .{{ {d}, {d} }},
        \\    .potential_placement_chance = @bitCast(@as(u64, 0x{x:0>16})),
        \\    .alternate_inner_layer_chance = @bitCast(@as(u64, 0x{x:0>16})),
        \\    .placements_require_alternate = {},
        \\    .layer_thickness = .{{ @bitCast(@as(u64, 0x{x:0>16})), @bitCast(@as(u64, 0x{x:0>16})), @bitCast(@as(u64, 0x{x:0>16})), @bitCast(@as(u64, 0x{x:0>16})) }},
        \\    .crack_chance = @bitCast(@as(u64, 0x{x:0>16})),
        \\    .base_crack_size = @bitCast(@as(u64, 0x{x:0>16})),
        \\    .crack_point_offset = {d},
        \\    .inner_layer_state = {d}, .alternate_inner_layer_state = {d},
        \\    .middle_layer_state = {d}, .outer_layer_state = {d},
        \\    .inner_placements = .{{
        \\
    , .{
        amethyst_geode.name,
        amethyst_geode.step,
        amethyst_geode.index,
        amethyst_geode.rarity,
        amethyst_geode.height_minimum_kind,
        amethyst_geode.height_minimum,
        amethyst_geode.height_maximum_kind,
        amethyst_geode.height_maximum,
        amethyst_geode.minimum_generation_offset,
        amethyst_geode.maximum_generation_offset,
        @as(u64, @bitCast(amethyst_geode.noise_multiplier)),
        amethyst_geode.invalid_blocks_threshold,
        amethyst_geode.outer_wall_distance[0],
        amethyst_geode.outer_wall_distance[1],
        amethyst_geode.distribution_points[0],
        amethyst_geode.distribution_points[1],
        amethyst_geode.point_offset[0],
        amethyst_geode.point_offset[1],
        @as(u64, @bitCast(amethyst_geode.potential_placement_chance)),
        @as(u64, @bitCast(amethyst_geode.alternate_inner_layer_chance)),
        amethyst_geode.placements_require_alternate,
        @as(u64, @bitCast(amethyst_geode.layer_thickness[0])),
        @as(u64, @bitCast(amethyst_geode.layer_thickness[1])),
        @as(u64, @bitCast(amethyst_geode.layer_thickness[2])),
        @as(u64, @bitCast(amethyst_geode.layer_thickness[3])),
        @as(u64, @bitCast(amethyst_geode.crack_chance)),
        @as(u64, @bitCast(amethyst_geode.base_crack_size)),
        amethyst_geode.crack_point_offset,
        amethyst_geode.inner_layer_state,
        amethyst_geode.alternate_inner_layer_state,
        amethyst_geode.middle_layer_state,
        amethyst_geode.outer_layer_state,
    });
    for (amethyst_geode.inner_placements) |placement_states| {
        try output.appendSlice("        .{");
        for (placement_states) |water_states|
            try output.print(".{{ {d}, {d} }},", .{ water_states[0], water_states[1] });
        try output.appendSlice("},\n");
    }
    try output.appendSlice("    },\n};\n");
    try output.print(
        \\
        \\pub const large_dripstone: LargeDripstone = .{{
        \\    .name = "{s}", .step = {d}, .index = {d},
        \\    .count_minimum = {d}, .count_maximum = {d},
        \\    .height = .{{ .kind = .uniform, .minimum_kind = .{s}, .minimum = {d}, .maximum_kind = .{s}, .maximum = {d} }},
        \\    .search_range = {d},
        \\    .radius_minimum = {d}, .radius_maximum = {d},
        \\    .height_scale = .{{ @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .max_radius_to_cave_height_ratio = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .stalactite_bluntness = .{{ @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .stalagmite_bluntness = .{{ @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .minimum_radius_for_wind = {d},
        \\    .minimum_bluntness_for_wind = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .wind_speed = .{{ @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .dripstone_block = {d},
        \\}};
        \\
    , .{
        large_dripstone.name,
        large_dripstone.step,
        large_dripstone.index,
        large_dripstone.count_minimum,
        large_dripstone.count_maximum,
        large_dripstone.height_minimum_kind,
        large_dripstone.height_minimum,
        large_dripstone.height_maximum_kind,
        large_dripstone.height_maximum,
        large_dripstone.search_range,
        large_dripstone.radius_minimum,
        large_dripstone.radius_maximum,
        @as(u32, @bitCast(large_dripstone.height_scale[0])),
        @as(u32, @bitCast(large_dripstone.height_scale[1])),
        @as(u32, @bitCast(large_dripstone.max_radius_to_cave_height_ratio)),
        @as(u32, @bitCast(large_dripstone.stalactite_bluntness[0])),
        @as(u32, @bitCast(large_dripstone.stalactite_bluntness[1])),
        @as(u32, @bitCast(large_dripstone.stalagmite_bluntness[0])),
        @as(u32, @bitCast(large_dripstone.stalagmite_bluntness[1])),
        large_dripstone.minimum_radius_for_wind,
        @as(u32, @bitCast(large_dripstone.minimum_bluntness_for_wind)),
        @as(u32, @bitCast(large_dripstone.wind_speed[0])),
        @as(u32, @bitCast(large_dripstone.wind_speed[1])),
        large_dripstone.dripstone_block,
    });
    try output.print(
        \\
        \\pub const dripstone_cluster: DripstoneCluster = .{{
        \\    .name = "{s}", .step = {d}, .index = {d},
        \\    .count_minimum = {d}, .count_maximum = {d},
        \\    .height = .{{ .kind = .uniform, .minimum_kind = .{s}, .minimum = {d}, .maximum_kind = .{s}, .maximum = {d} }},
        \\    .search_range = {d},
        \\    .column_height_minimum = {d}, .column_height_maximum = {d},
        \\    .wetness = .{{ @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .density = .{{ @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .radius_minimum = {d}, .radius_maximum = {d},
        \\    .max_height_difference = {d}, .height_deviation = {d},
        \\    .layer_minimum = {d}, .layer_maximum = {d},
        \\    .edge_chance = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .edge_distance = {d}, .height_bias_distance = {d},
        \\    .pointed_states = .{{
        \\
    , .{
        dripstone_cluster.name,
        dripstone_cluster.step,
        dripstone_cluster.index,
        dripstone_cluster.count_minimum,
        dripstone_cluster.count_maximum,
        dripstone_cluster.height_minimum_kind,
        dripstone_cluster.height_minimum,
        dripstone_cluster.height_maximum_kind,
        dripstone_cluster.height_maximum,
        dripstone_cluster.search_range,
        dripstone_cluster.column_height_minimum,
        dripstone_cluster.column_height_maximum,
        @as(u32, @bitCast(dripstone_cluster.wetness[0])),
        @as(u32, @bitCast(dripstone_cluster.wetness[1])),
        @as(u32, @bitCast(dripstone_cluster.wetness[2])),
        @as(u32, @bitCast(dripstone_cluster.wetness[3])),
        @as(u32, @bitCast(dripstone_cluster.density[0])),
        @as(u32, @bitCast(dripstone_cluster.density[1])),
        dripstone_cluster.radius_minimum,
        dripstone_cluster.radius_maximum,
        dripstone_cluster.max_height_difference,
        dripstone_cluster.height_deviation,
        dripstone_cluster.layer_minimum,
        dripstone_cluster.layer_maximum,
        @as(u32, @bitCast(dripstone_cluster.edge_chance)),
        dripstone_cluster.edge_distance,
        dripstone_cluster.height_bias_distance,
    });
    for (dripstone_cluster.pointed_states) |pair|
        try output.print(".{{ {d}, {d} }},", .{ pair[0], pair[1] });
    try output.appendSlice("},\n};\n");
    try output.print(
        \\
        \\pub const ore_veins: OreVeins = .{{
        \\    .copper_ore = {d},
        \\    .raw_copper_block = {d},
        \\    .granite = {d},
        \\    .iron_ore = {d},
        \\    .raw_iron_block = {d},
        \\    .tuff = {d},
        \\}};
        \\
        \\pub const disks = [_]Disk{{
        \\
    , .{
        veins.copper_ore,
        veins.raw_copper_block,
        veins.granite,
        veins.iron_ore,
        veins.raw_iron_block,
        veins.tuff,
    });
    for (disks.items) |disk| {
        try output.print(
            "    .{{ .name = \"{s}\", .index = {d}, .count = {d}, .radius_minimum = {d}, .radius_maximum = {d}, .half_height = {d}, .requires_water = {}, .targets = &.{{",
            .{
                disk.name,
                disk.index,
                disk.count,
                disk.radius_minimum,
                disk.radius_maximum,
                disk.half_height,
                disk.requires_water,
            },
        );
        for (disk.targets) |target| try output.print("{d},", .{target});
        try output.print(
            "}}, .state = {d}, .state_above_air = {s}, .state_rule = .{s} }},\n",
            .{
                disk.state,
                if (disk.state_above_air) |state|
                    try std.fmt.allocPrint(allocator, "{d}", .{state})
                else
                    "null",
                disk.state_rule,
            },
        );
    }
    try output.print(
        \\}};
        \\
        \\pub const underwater_magma: Magma = .{{
        \\    .name = "{s}",
        \\    .step = {d},
        \\    .index = {d},
        \\    .count = .{{ .kind = .uniform, .minimum = {d}, .maximum = {d} }},
        \\    .height = .{{ .kind = .uniform, .minimum_kind = .{s}, .minimum = {d}, .maximum_kind = .{s}, .maximum = {d} }},
        \\    .surface_maximum = {d},
        \\    .floor_search_range = {d},
        \\    .radius = {d},
        \\    .probability = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .state = {d},
        \\}};
        \\
        \\pub const glow_lichen: Lichen = .{{
        \\    .name = "{s}",
        \\    .step = {d},
        \\    .index = {d},
        \\    .count = .{{ .kind = .uniform, .minimum = {d}, .maximum = {d} }},
        \\    .height = .{{ .kind = .uniform, .minimum_kind = .{s}, .minimum = {d}, .maximum_kind = .{s}, .maximum = {d} }},
        \\    .surface_maximum = {d},
        \\    .search_range = {d},
        \\    .spread_chance = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .can_place_on = &.{{
        \\
    , .{
        magma.name,
        magma.step,
        magma.index,
        magma.count_minimum,
        magma.count_maximum,
        magma.minimum_kind,
        magma.minimum,
        magma.maximum_kind,
        magma.maximum,
        magma.surface_maximum,
        magma.floor_search_range,
        magma.radius,
        @as(u32, @bitCast(magma.probability)),
        magma.state,
        lichen.name,
        lichen.step,
        lichen.index,
        lichen.count_minimum,
        lichen.count_maximum,
        lichen.minimum_kind,
        lichen.minimum,
        lichen.maximum_kind,
        lichen.maximum,
        lichen.surface_maximum,
        lichen.search_range,
        @as(u32, @bitCast(lichen.spread_chance)),
    });
    for (lichen.can_place_on) |name| try output.print("        \"{s}\",\n", .{name});
    try output.print(
        \\    }},
        \\    .state_base = {d},
        \\}};
        \\
        \\pub const forest_flowers: ForestFlowers = .{{
        \\    .name = "{s}",
        \\    .step = {d},
        \\    .index = {d},
        \\    .rarity = {d},
        \\    .count_minimum = {d},
        \\    .count_maximum = {d},
        \\    .count_clamp_minimum = {d},
        \\    .count_clamp_maximum = {d},
        \\    .tries = {d},
        \\    .xz_spread = {d},
        \\    .y_spread = {d},
        \\    .lower_states = .{{ {d}, {d}, {d} }},
        \\    .upper_states = .{{ {d}, {d}, {d} }},
        \\    .lily_state = {d},
        \\}};
        \\
    , .{
        lichen.state_base,
        flowers.name,
        flowers.step,
        flowers.index,
        flowers.rarity,
        flowers.count_minimum,
        flowers.count_maximum,
        flowers.count_clamp_minimum,
        flowers.count_clamp_maximum,
        flowers.tries,
        flowers.xz_spread,
        flowers.y_spread,
        flowers.lower_states[0],
        flowers.lower_states[1],
        flowers.lower_states[2],
        flowers.upper_states[0],
        flowers.upper_states[1],
        flowers.upper_states[2],
        flowers.lily_state,
    });
    try output.print(
        \\pub const flower_forest_flowers: ForestFlowers = .{{
        \\    .name = "{s}",
        \\    .step = {d},
        \\    .index = {d},
        \\    .rarity = {d},
        \\    .count_minimum = {d},
        \\    .count_maximum = {d},
        \\    .count_clamp_minimum = {d},
        \\    .count_clamp_maximum = {d},
        \\    .tries = {d},
        \\    .xz_spread = {d},
        \\    .y_spread = {d},
        \\    .lower_states = .{{ {d}, {d}, {d} }},
        \\    .upper_states = .{{ {d}, {d}, {d} }},
        \\    .lily_state = {d},
        \\}};
        \\
    , .{
        flower_forest_flowers.name,
        flower_forest_flowers.step,
        flower_forest_flowers.index,
        flower_forest_flowers.rarity,
        flower_forest_flowers.count_minimum,
        flower_forest_flowers.count_maximum,
        flower_forest_flowers.count_clamp_minimum,
        flower_forest_flowers.count_clamp_maximum,
        flower_forest_flowers.tries,
        flower_forest_flowers.xz_spread,
        flower_forest_flowers.y_spread,
        flower_forest_flowers.lower_states[0],
        flower_forest_flowers.lower_states[1],
        flower_forest_flowers.lower_states[2],
        flower_forest_flowers.upper_states[0],
        flower_forest_flowers.upper_states[1],
        flower_forest_flowers.upper_states[2],
        flower_forest_flowers.lily_state,
    });
    try output.print(
        \\pub const cave_vines: CaveVines = .{{
        \\    .name = "{s}", .step = {d}, .index = {d}, .count = {d},
        \\    .height_minimum = {d}, .height_maximum = {d}, .search_range = {d},
        \\    .plant_height_ranges = .{{ .{{ {d}, {d} }}, .{{ {d}, {d} }}, .{{ {d}, {d} }} }},
        \\    .plant_height_weights = .{{ {d}, {d}, {d} }},
        \\    .plant_states = .{{ {d}, {d} }},
        \\    .tip_states = .{{ {d}, {d}, {d}, {d}, {d}, {d} }},
        \\}};
        \\
    , .{
        cave_vines.name,
        cave_vines.step,
        cave_vines.index,
        cave_vines.count,
        cave_vines.height_minimum,
        cave_vines.height_maximum,
        cave_vines.search_range,
        cave_vines.plant_height_ranges[0][0],
        cave_vines.plant_height_ranges[0][1],
        cave_vines.plant_height_ranges[1][0],
        cave_vines.plant_height_ranges[1][1],
        cave_vines.plant_height_ranges[2][0],
        cave_vines.plant_height_ranges[2][1],
        cave_vines.plant_height_weights[0],
        cave_vines.plant_height_weights[1],
        cave_vines.plant_height_weights[2],
        cave_vines.plant_states[0],
        cave_vines.plant_states[1],
        cave_vines.tip_states[0],
        cave_vines.tip_states[1],
        cave_vines.tip_states[2],
        cave_vines.tip_states[3],
        cave_vines.tip_states[4],
        cave_vines.tip_states[5],
    });
    try output.appendSlice("\npub const flower_patches = [_]FlowerPatch{\n");
    for (flower_patches.items) |flower_patch| {
        try output.print(
            \\    .{{ .name = "{s}", .step = {d}, .index = {d},
            \\        .count_kind = .{s}, .count_below = {d}, .count_above = {d},
            \\        .count_noise = @bitCast(@as(u64, 0x{x:0>16})), .rarity = {d},
            \\        .heightmap = .{s},
            \\        .tries = {d}, .xz_spread = {d}, .y_spread = {d},
            \\        .provider = .{s}, .first_octave = {d},
            \\        .scale = @bitCast(@as(u32, 0x{x:0>8})), .slow_first_octave = {d},
            \\        .slow_scale = @bitCast(@as(u32, 0x{x:0>8})),
            \\        .variety_minimum = {d}, .variety_maximum = {d},
            \\        .threshold = @bitCast(@as(u32, 0x{x:0>8})),
            \\        .high_chance = @bitCast(@as(u32, 0x{x:0>8})),
            \\        .low_count = {d}, .high_count = {d}, .state_count = {d},
            \\        .total_weight = {d}, .upper_state = {s}, .states = .{{
        , .{
            flower_patch.name,
            flower_patch.step,
            flower_patch.index,
            flower_patch.count_kind,
            flower_patch.count_below,
            flower_patch.count_above,
            @as(u64, @bitCast(flower_patch.count_noise)),
            flower_patch.rarity,
            flower_patch.heightmap,
            flower_patch.tries,
            flower_patch.xz_spread,
            flower_patch.y_spread,
            flower_patch.provider,
            flower_patch.first_octave,
            @as(u32, @bitCast(flower_patch.scale)),
            flower_patch.slow_first_octave,
            @as(u32, @bitCast(flower_patch.slow_scale)),
            flower_patch.variety_minimum,
            flower_patch.variety_maximum,
            @as(u32, @bitCast(flower_patch.threshold)),
            @as(u32, @bitCast(flower_patch.high_chance)),
            flower_patch.low_count,
            flower_patch.high_count,
            flower_patch.state_count,
            flower_patch.total_weight,
            if (flower_patch.upper_state) |state|
                try std.fmt.allocPrint(allocator, "{d}", .{state})
            else
                "null",
        });
        for (flower_patch.states, 0..) |state, index|
            try output.print("{d}{s}", .{ state, if (index + 1 == 16) "" else ", " });
        try output.appendSlice(" }, .weights = .{");
        for (flower_patch.weights, 0..) |weight, index|
            try output.print("{d}{s}", .{ weight, if (index + 1 == 16) "" else ", " });
        try output.appendSlice(" } },\n");
    }
    try output.appendSlice("};\n");
    try output.print(
        "\npub const mushroom_island_vegetation: HugeMushroom = .{{ .name = \"{s}\", .step = {d}, .index = {d}, .foliage_radius = .{{ {d}, {d} }}, .cap_states = .{{\n",
        .{ huge_mushroom.name, huge_mushroom.step, huge_mushroom.index, huge_mushroom.foliage_radius[0], huge_mushroom.foliage_radius[1] },
    );
    for (huge_mushroom.cap_states) |cap_states| {
        try output.appendSlice("    .{");
        for (cap_states) |state| try output.print(" {d},", .{state});
        try output.appendSlice(" },\n");
    }
    try output.print("}}, .stem_state = {d} }};\n", .{huge_mushroom.stem_state});
    try output.print(
        \\pub const oak_leaf_litter_trees: Tree = .{{
        \\    .name = "{s}",
        \\    .step = {d},
        \\    .index = {d},
        \\    .count_minimum = {d},
        \\    .count_maximum = {d},
        \\    .minimum_weight = {d},
        \\    .maximum_weight = {d},
        \\    .selectors = .{{ @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .trunk_base_height = {d},
        \\    .trunk_height_rand_a = {d},
        \\    .trunk_height_rand_b = {d},
        \\    .foliage_radius = {d},
        \\    .foliage_height = {d},
        \\    .beehive_probability = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .dirt_state = {d},
        \\    .log_state = {d},
        \\    .log_x_state = {d},
        \\    .log_z_state = {d},
        \\    .leaf_state_base = {d},
    , .{
        tree.name,
        tree.step,
        tree.index,
        tree.count_minimum,
        tree.count_maximum,
        tree.minimum_weight,
        tree.maximum_weight,
        @as(u32, @bitCast(tree.selectors[0])),
        @as(u32, @bitCast(tree.selectors[1])),
        @as(u32, @bitCast(tree.selectors[2])),
        @as(u32, @bitCast(tree.selectors[3])),
        tree.trunk_base_height,
        tree.trunk_height_rand_a,
        tree.trunk_height_rand_b,
        tree.foliage_radius,
        tree.foliage_height,
        @as(u32, @bitCast(tree.beehive_probability)),
        tree.dirt_state,
        tree.log_state,
        tree.log_x_state,
        tree.log_z_state,
        tree.leaf_state_base,
    });
    try output.print(
        \\    .birch_log_state = {d},
        \\    .birch_log_x_state = {d},
        \\    .birch_log_z_state = {d},
        \\    .birch_leaf_state_base = {d},
        \\    .spruce_log_state = {d},
        \\    .spruce_log_x_state = {d},
        \\    .spruce_log_z_state = {d},
        \\    .spruce_leaf_state_base = {d},
        \\    .acacia_log_state = {d},
        \\    .acacia_leaf_state_base = {d},
        \\    .podzol_state = {d},
        \\    .jungle_log_state = {d},
        \\    .jungle_log_x_state = {d},
        \\    .jungle_log_z_state = {d},
        \\    .jungle_leaf_state_base = {d},
        \\    .cocoa_states = .{{ .{{ {d}, {d}, {d} }}, .{{ {d}, {d}, {d} }}, .{{ {d}, {d}, {d} }}, .{{ {d}, {d}, {d} }} }},
        \\    .litter_state_base = {d},
        \\    .red_mushroom_state = {d},
        \\    .brown_mushroom_state = {d},
        \\    .vine_east_state = {d},
        \\    .vine_west_state = {d},
    , .{
        tree.birch_log_state,
        tree.birch_log_x_state,
        tree.birch_log_z_state,
        tree.birch_leaf_state_base,
        tree.spruce_log_state,
        tree.spruce_log_x_state,
        tree.spruce_log_z_state,
        tree.spruce_leaf_state_base,
        tree.acacia_log_state,
        tree.acacia_leaf_state_base,
        tree.podzol_state,
        tree.jungle_log_state,
        tree.jungle_log_x_state,
        tree.jungle_log_z_state,
        tree.jungle_leaf_state_base,
        tree.cocoa_states[0][0],
        tree.cocoa_states[0][1],
        tree.cocoa_states[0][2],
        tree.cocoa_states[1][0],
        tree.cocoa_states[1][1],
        tree.cocoa_states[1][2],
        tree.cocoa_states[2][0],
        tree.cocoa_states[2][1],
        tree.cocoa_states[2][2],
        tree.cocoa_states[3][0],
        tree.cocoa_states[3][1],
        tree.cocoa_states[3][2],
        tree.litter_state_base,
        tree.red_mushroom_state,
        tree.brown_mushroom_state,
        tree.vine_east_state,
        tree.vine_west_state,
    });
    try output.print(
        \\    .vine_south_state = {d},
        \\    .vine_north_state = {d},
        \\    .bee_nest_state = {d},
        \\}};
    , .{
        tree.vine_south_state,
        tree.vine_north_state,
        tree.bee_nest_state,
    });
    try output.appendSlice("\npub const basic_tree_selectors = [_]BasicTreeSelector{\n");
    for (basic_tree_selectors.items) |selector| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .count_kind = .{s}, " ++
                ".count_minimum = {d}, .count_maximum = {d}, .minimum_weight = {d}, " ++
                ".maximum_weight = {d}, .rarity = {d}, .survival_filter = {}, .max_water_depth = {d}, " ++
                ".choice_count = {d}, .choices = .{{ ",
            .{
                selector.name,
                selector.step,
                selector.index,
                selector.count_kind,
                selector.count_minimum,
                selector.count_maximum,
                selector.minimum_weight,
                selector.maximum_weight,
                selector.rarity,
                selector.survival_filter,
                selector.max_water_depth,
                selector.choice_count,
            },
        );
        for (selector.choices, 0..) |choice, index|
            try output.print(".{s}{s}", .{ choice, if (index == 3) "" else ", " });
        try output.appendSlice(" }, .chances = .{ ");
        for (selector.chances, 0..) |chance, index|
            try output.print(
                "@bitCast(@as(u32, 0x{x:0>8})){s}",
                .{ @as(u32, @bitCast(chance)), if (index == 3) "" else ", " },
            );
        try output.print(" }}, .default_choice = .{s} }},\n", .{selector.default_choice});
    }
    try output.appendSlice("};\n");
    try output.print(
        \\
        \\pub const birch_trees: BirchTrees = .{{
        \\    .name = "{s}", .step = {d}, .index = {d},
        \\    .count_minimum = {d}, .count_maximum = {d},
        \\    .minimum_weight = {d}, .maximum_weight = {d},
        \\    .fallen_chance = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .beehive_probability = @bitCast(@as(u32, 0x{x:0>8})),
        \\}};
    , .{
        birch_trees.name,
        birch_trees.step,
        birch_trees.index,
        birch_trees.count_minimum,
        birch_trees.count_maximum,
        birch_trees.minimum_weight,
        birch_trees.maximum_weight,
        @as(u32, @bitCast(birch_trees.fallen_chance)),
        @as(u32, @bitCast(birch_trees.beehive_probability)),
    });
    try output.print(
        \\
        \\pub const tall_birch_trees: TallBirchTrees = .{{
        \\    .name = "{s}", .step = {d}, .index = {d},
        \\    .count_minimum = {d}, .count_maximum = {d},
        \\    .minimum_weight = {d}, .maximum_weight = {d},
        \\    .selectors = .{{ @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})), @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .beehive_probability = @bitCast(@as(u32, 0x{x:0>8})),
        \\}};
    , .{
        tall_birch_trees.name,
        tall_birch_trees.step,
        tall_birch_trees.index,
        tall_birch_trees.count_minimum,
        tall_birch_trees.count_maximum,
        tall_birch_trees.minimum_weight,
        tall_birch_trees.maximum_weight,
        @as(u32, @bitCast(tall_birch_trees.selectors[0])),
        @as(u32, @bitCast(tall_birch_trees.selectors[1])),
        @as(u32, @bitCast(tall_birch_trees.selectors[2])),
        @as(u32, @bitCast(tall_birch_trees.beehive_probability)),
    });
    try output.print(
        \\
        \\pub const patch_grass_forest: RandomPatch = .{{
        \\    .name = "{s}",
        \\    .step = {d},
        \\    .index = {d},
        \\    .count = {d},
        \\    .tries = {d},
        \\    .xz_spread = {d},
        \\    .y_spread = {d},
        \\    .state = {d},
        \\}};
    , .{
        patch.name,
        patch.step,
        patch.index,
        patch.count,
        patch.tries,
        patch.xz_spread,
        patch.y_spread,
        patch.state,
    });
    try output.appendSlice("\npub const surface_patches = [_]SurfacePatch{\n");
    for (surface_patches.items) |surface_patch| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .count = {d}, .rarity = {d}, .heightmap = .{s}, .tries = {d}, .xz_spread = {d}, .y_spread = {d}, .placement = .{s}, .state_count = {d}, .states = .{{",
            .{
                surface_patch.name,
                surface_patch.step,
                surface_patch.index,
                surface_patch.count,
                surface_patch.rarity,
                surface_patch.heightmap,
                surface_patch.tries,
                surface_patch.xz_spread,
                surface_patch.y_spread,
                surface_patch.placement,
                surface_patch.state_count,
            },
        );
        for (surface_patch.states) |state| try output.print("{d},", .{state});
        try output.appendSlice("} },\n");
    }
    try output.appendSlice("};\n\npub const near_water_patches = [_]NearWaterPatch{\n");
    for (near_water_patches.items) |near_water_patch| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .count = {d}, .rarity = {d}, .heightmap = .{s}, .tries = {d}, .xz_spread = {d}, .y_spread = {d}, .placement = .{s}, .state = {d}, .column_minimum = {d}, .column_maximum = {d} }},\n",
            .{
                near_water_patch.name,
                near_water_patch.step,
                near_water_patch.index,
                near_water_patch.count,
                near_water_patch.rarity,
                near_water_patch.heightmap,
                near_water_patch.tries,
                near_water_patch.xz_spread,
                near_water_patch.y_spread,
                near_water_patch.placement,
                near_water_patch.state,
                near_water_patch.column_minimum,
                near_water_patch.column_maximum,
            },
        );
    }
    try output.appendSlice("};\n\npub const seagrass = [_]Seagrass{\n");
    for (seagrass.items) |feature| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .count = {d}, .tall_probability = @bitCast(@as(u32, 0x{x:0>8})) }},\n",
            .{
                feature.name,
                feature.step,
                feature.index,
                feature.count,
                @as(u32, @bitCast(feature.tall_probability)),
            },
        );
    }
    try output.appendSlice("};\n\npub const kelp = [_]Kelp{\n");
    for (kelp.items) |feature| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .noise_factor = @bitCast(@as(u64, 0x{x:0>16})), .noise_to_count_ratio = {d} }},\n",
            .{
                feature.name,
                feature.step,
                feature.index,
                @as(u64, @bitCast(feature.noise_factor)),
                feature.noise_to_count_ratio,
            },
        );
    }
    try output.appendSlice("};\n\npub const simple_features = [_]SimpleFeature{\n");
    for (simple_features.items) |simple| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .kind = .{s}, .count_kind = .{s}, .count_minimum = {d}, .count_maximum = {d}, .height_kind = .{s}, .height_minimum = {d}, .height_maximum = {d}, .state_count = {d}, .states = .{{ {d}, {d}, {d}, {d}, {d} }} }},\n",
            .{
                simple.name,
                simple.step,
                simple.index,
                simple.kind,
                simple.count_kind,
                simple.count_minimum,
                simple.count_maximum,
                simple.height_kind,
                simple.height_minimum,
                simple.height_maximum,
                simple.state_count,
                simple.states[0],
                simple.states[1],
                simple.states[2],
                simple.states[3],
                simple.states[4],
            },
        );
    }
    try output.print(
        \\}};
        \\pub const seagrass_state: u16 = {d};
        \\pub const tall_seagrass_lower_state: u16 = {d};
        \\pub const tall_seagrass_upper_state: u16 = {d};
        \\pub const kelp_plant_state: u16 = {d};
        \\pub const kelp_states = [4]u16{{ {d}, {d}, {d}, {d} }};
        \\
        \\pub const noise_grass_patches = [_]NoiseGrassPatch{{
        \\
    , .{
        seagrass_state,
        tall_seagrass_lower_state,
        tall_seagrass_upper_state,
        kelp_plant_state,
        kelp_states[0],
        kelp_states[1],
        kelp_states[2],
        kelp_states[3],
    });
    for (noise_grass_patches.items) |patch_value| {
        try output.print(
            "    .{{ .name = \"{s}\", .step = {d}, .index = {d}, .noise_level = @bitCast(@as(u64, 0x{x:0>16})), .below_noise = {d}, .above_noise = {d}, .rarity = {d}, .heightmap = .{s}, .tries = {d}, .xz_spread = {d}, .y_spread = {d}, .state = {d}, .upper_state = {d}, .double_plant = {} }},\n",
            .{
                patch_value.name,
                patch_value.step,
                patch_value.index,
                @as(u64, @bitCast(patch_value.noise_level)),
                patch_value.below_noise,
                patch_value.above_noise,
                patch_value.rarity,
                patch_value.heightmap,
                patch_value.tries,
                patch_value.xz_spread,
                patch_value.y_spread,
                patch_value.state,
                patch_value.upper_state,
                patch_value.double_plant,
            },
        );
    }
    try output.print(
        \\}};
        \\
        \\pub const freeze_top_layer: FreezeTopLayer = .{{
        \\    .name = "{s}",
        \\    .step = {d},
        \\    .index = {d},
        \\    .ice_state = {d},
        \\    .snow_state = {d},
        \\    .snowy_states = .{{ .{{ {d}, {d} }}, .{{ {d}, {d} }}, .{{ {d}, {d} }} }},
        \\}};
        \\
        \\pub const biome_lava_lake_masks = [_]u8{{
        \\
    , .{
        freeze_top_layer.name,
        freeze_top_layer.step,
        freeze_top_layer.index,
        freeze_top_layer.ice_state,
        freeze_top_layer.snow_state,
        freeze_top_layer.snowy_states[0][0],
        freeze_top_layer.snowy_states[0][1],
        freeze_top_layer.snowy_states[1][0],
        freeze_top_layer.snowy_states[1][1],
        freeze_top_layer.snowy_states[2][0],
        freeze_top_layer.snowy_states[2][1],
    });
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var mask: u8 = 0;
        for (lava_lakes.items, 0..) |lake, lake_index| {
            if (feature_steps.len <= lake.step) continue;
            for (feature_steps[lake.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, lake.name)) continue;
                mask |= @as(u8, 1) << @intCast(lake_index);
                break;
            }
        }
        try output.print("    0x{x:0>2}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n\npub const biome_iceberg_masks = [_]u8{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var mask: u8 = 0;
        for (icebergs.items, 0..) |iceberg, iceberg_index| {
            if (feature_steps.len <= iceberg.step) continue;
            for (feature_steps[iceberg.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, iceberg.name)) continue;
                mask |= @as(u8, 1) << @intCast(iceberg_index);
                break;
            }
        }
        try output.print("    0x{x:0>2}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n\npub const biome_monster_room_masks = [_]u8{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var mask: u8 = 0;
        for (monster_rooms.items, 0..) |room, room_index| {
            if (feature_steps.len <= room.step) continue;
            for (feature_steps[room.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, room.name)) continue;
                mask |= @as(u8, 1) << @intCast(room_index);
                break;
            }
        }
        try output.print("    0x{x:0>2}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n\npub const biome_ore_masks = [_]u64{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:")) name["minecraft:".len..] else name;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ biome_directory, relative });
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps = (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var mask: u64 = 0;
        for (ores.items, 0..) |ore, ore_record_index| {
            if (feature_steps.len > ore.step) {
                for (feature_steps[ore.step].array.items) |feature| {
                    if (std.mem.eql(u8, feature.string, ore.name))
                        mask |= @as(u64, 1) << @intCast(ore_record_index);
                }
            }
        }
        try output.print("    0x{x:0>16}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n\npub const biome_pointed_dripstone = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var present = false;
        if (feature_steps.len > pointed_dripstone.step) {
            for (feature_steps[pointed_dripstone.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, pointed_dripstone.name)) continue;
                present = true;
                break;
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n\npub const biome_fluid_spring_masks = [_]u8{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var mask: u8 = 0;
        for (springs.items, 0..) |spring, spring_index| {
            if (feature_steps.len <= spring.step) continue;
            for (feature_steps[spring.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, spring.name)) continue;
                mask |= @as(u8, 1) << @intCast(spring_index);
                break;
            }
        }
        try output.print("    0x{x:0>2}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n\npub const biome_glow_lichen = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:")) name["minecraft:".len..] else name;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ biome_directory, relative });
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps = (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var present = false;
        if (feature_steps.len > lichen.step) {
            for (feature_steps[lichen.step].array.items) |feature| {
                if (std.mem.eql(u8, feature.string, lichen.name)) {
                    present = true;
                    break;
                }
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n\npub const biome_disk_masks = [_]u64{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:")) name["minecraft:".len..] else name;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ biome_directory, relative });
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps = (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var mask: u64 = 0;
        if (feature_steps.len > 6) {
            for (feature_steps[6].array.items) |feature| {
                for (disks.items) |disk| {
                    if (std.mem.eql(u8, feature.string, disk.name))
                        mask |= @as(u64, 1) << @intCast(disk.index);
                }
            }
        }
        try output.print("    0x{x:0>16}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n\npub const biome_underwater_magma = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:")) name["minecraft:".len..] else name;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ biome_directory, relative });
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps = (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var present = false;
        if (feature_steps.len > magma.step) {
            for (feature_steps[magma.step].array.items) |feature| {
                if (std.mem.eql(u8, feature.string, magma.name)) {
                    present = true;
                    break;
                }
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n\npub const biome_oak_leaf_litter_trees = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var present = false;
        if (feature_steps.len > tree.step) {
            for (feature_steps[tree.step].array.items) |placed_feature| {
                if (std.mem.eql(u8, placed_feature.string, tree.name)) {
                    present = true;
                    break;
                }
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_forest_flowers = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var present = false;
        if (feature_steps.len > flowers.step) {
            for (feature_steps[flowers.step].array.items) |placed_feature| {
                if (std.mem.eql(u8, placed_feature.string, flowers.name)) {
                    present = true;
                    break;
                }
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_flower_forest_flowers = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var present = false;
        if (feature_steps.len > flower_forest_flowers.step) {
            for (feature_steps[flower_forest_flowers.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, flower_forest_flowers.name))
                    continue;
                present = true;
                break;
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_tall_birch_trees = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var present = false;
        if (feature_steps.len > tall_birch_trees.step) {
            for (feature_steps[tall_birch_trees.step].array.items) |placed_feature| {
                if (std.mem.eql(u8, placed_feature.string, tall_birch_trees.name)) {
                    present = true;
                    break;
                }
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_birch_trees = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var present = false;
        if (feature_steps.len > birch_trees.step) {
            for (feature_steps[birch_trees.step].array.items) |placed_feature| {
                if (std.mem.eql(u8, placed_feature.string, birch_trees.name)) {
                    present = true;
                    break;
                }
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_basic_tree_selector_masks = [_]u64{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var mask: u64 = 0;
        for (basic_tree_selectors.items, 0..) |selector, selector_index| {
            if (feature_steps.len <= selector.step) continue;
            for (feature_steps[selector.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, selector.name)) continue;
                mask |= @as(u64, 1) << @intCast(selector_index);
                break;
            }
        }
        try output.print("    0x{x:0>16}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_mushroom_island_vegetation = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var present = false;
        if (feature_steps.len > huge_mushroom.step) {
            for (feature_steps[huge_mushroom.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, huge_mushroom.name)) continue;
                present = true;
                break;
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_cave_vines = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var present = false;
        if (feature_steps.len > cave_vines.step) {
            for (feature_steps[cave_vines.step].array.items) |placed_feature| {
                if (std.mem.eql(u8, placed_feature.string, cave_vines.name)) {
                    present = true;
                    break;
                }
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_flower_patch_masks = [_]u16{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var mask: u16 = 0;
        for (flower_patches.items, 0..) |flower_patch, flower_index| {
            if (feature_steps.len <= flower_patch.step) continue;
            for (feature_steps[flower_patch.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, flower_patch.name)) continue;
                mask |= @as(u16, 1) << @intCast(flower_index);
                break;
            }
        }
        try output.print("    0x{x:0>4}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_patch_grass_forest = [_]bool{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var present = false;
        if (feature_steps.len > patch.step) {
            for (feature_steps[patch.step].array.items) |placed_feature| {
                if (std.mem.eql(u8, placed_feature.string, patch.name)) {
                    present = true;
                    break;
                }
            }
        }
        try output.print("    {}, // {s}\n", .{ present, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_seagrass_masks = [_]u8{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var mask: u8 = 0;
        for (seagrass.items, 0..) |feature, feature_index| {
            if (feature_steps.len <= feature.step) continue;
            for (feature_steps[feature.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, feature.name)) continue;
                mask |= @as(u8, 1) << @intCast(feature_index);
                break;
            }
        }
        try output.print("    0x{x:0>2}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_kelp_masks = [_]u8{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var mask: u8 = 0;
        for (kelp.items, 0..) |feature, feature_index| {
            if (feature_steps.len <= feature.step) continue;
            for (feature_steps[feature.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, feature.name)) continue;
                mask |= @as(u8, 1) << @intCast(feature_index);
                break;
            }
        }
        try output.print("    0x{x:0>2}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_surface_patch_masks = [_]u64{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var mask: u64 = 0;
        for (surface_patches.items, 0..) |surface_patch, patch_index| {
            if (feature_steps.len <= surface_patch.step) continue;
            for (feature_steps[surface_patch.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, surface_patch.name)) continue;
                mask |= @as(u64, 1) << @intCast(patch_index);
                break;
            }
        }
        try output.print("    0x{x:0>16}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_noise_grass_patch_masks = [_]u8{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var mask: u8 = 0;
        for (noise_grass_patches.items, 0..) |patch_value, patch_index| {
            if (feature_steps.len <= patch_value.step) continue;
            for (feature_steps[patch_value.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, patch_value.name)) continue;
                mask |= @as(u8, 1) << @intCast(patch_index);
                break;
            }
        }
        try output.print("    0x{x:0>2}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_near_water_patch_masks = [_]u8{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures).array.items;
        var mask: u8 = 0;
        for (near_water_patches.items, 0..) |near_water_patch, patch_index| {
            if (feature_steps.len <= near_water_patch.step) continue;
            for (feature_steps[near_water_patch.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, near_water_patch.name)) continue;
                mask |= @as(u8, 1) << @intCast(patch_index);
                break;
            }
        }
        try output.print("    0x{x:0>2}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n");
    try output.appendSlice("\npub const biome_simple_feature_masks = [_]u16{\n");
    for (biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.json",
            .{ biome_directory, relative },
        );
        const bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(128 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        const feature_steps =
            (parsed.value.object.get("features") orelse return error.MissingBiomeFeatures)
                .array.items;
        var mask: u16 = 0;
        for (simple_features.items, 0..) |simple, simple_index| {
            if (feature_steps.len <= simple.step) continue;
            for (feature_steps[simple.step].array.items) |placed_feature| {
                if (!std.mem.eql(u8, placed_feature.string, simple.name)) continue;
                mask |= @as(u16, 1) << @intCast(simple_index);
                break;
            }
        }
        try output.print("    0x{x:0>4}, // {s}\n", .{ mask, name });
    }
    try output.appendSlice("};\n");
    try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = output.items });
}

fn collectBiomeNames(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    names: *std.ArrayListUnmanaged([]const u8),
) !void {
    const object = value.object;
    if (object.get("biomes")) |entries| {
        for (entries.array.items) |entry|
            try appendBiomeName(allocator, entry.object, names);
        return;
    }
    if (object.get("subTree")) |children| {
        for (children.array.items) |child| try collectBiomeNames(allocator, child, names);
        return;
    }
    try appendBiomeName(allocator, object, names);
}

fn appendBiomeName(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    names: *std.ArrayListUnmanaged([]const u8),
) !void {
    const name = (object.get("biome") orelse return error.MissingBiomeName).string;
    for (names.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try names.append(allocator, name);
}

fn stateIndex(
    allocator: std.mem.Allocator,
    states: *std.ArrayListUnmanaged([]const u8),
    state: []const u8,
) !u16 {
    for (states.items, 0..) |existing, index|
        if (std.mem.eql(u8, existing, state)) return @intCast(index);
    if (states.items.len >= std.math.maxInt(u16)) return error.TooManyFeatureStates;
    try states.append(allocator, state);
    return @intCast(states.items.len - 1);
}

fn jsonU8(value: std.json.Value) !u8 {
    return switch (value) {
        .integer => |number| std.math.cast(u8, number) orelse error.IntegerOutOfRange,
        else => error.ExpectedInteger,
    };
}

fn jsonU16(value: std.json.Value) !u16 {
    return switch (value) {
        .integer => |number| std.math.cast(u16, number) orelse error.IntegerOutOfRange,
        else => error.ExpectedInteger,
    };
}

fn jsonI8(value: std.json.Value) !i8 {
    return switch (value) {
        .integer => |number| std.math.cast(i8, number) orelse error.IntegerOutOfRange,
        else => error.ExpectedInteger,
    };
}

fn jsonI32(value: std.json.Value) !i32 {
    return switch (value) {
        .integer => |number| std.math.cast(i32, number) orelse error.IntegerOutOfRange,
        else => error.ExpectedInteger,
    };
}

fn jsonI16(value: std.json.Value) !i16 {
    return switch (value) {
        .integer => |number| std.math.cast(i16, number) orelse error.IntegerOutOfRange,
        else => error.ExpectedInteger,
    };
}

fn jsonF32(value: std.json.Value) !f32 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| @floatCast(number),
        else => error.ExpectedNumber,
    };
}

fn jsonF64(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => error.ExpectedNumber,
    };
}

fn booleanName(value: bool) []const u8 {
    return if (value) "true" else "false";
}
