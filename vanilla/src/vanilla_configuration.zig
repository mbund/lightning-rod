const lightning_rod = @import("lightning_rod");
const std = @import("std");

const configuration = lightning_rod.sessions.configuration;
const dimensions = lightning_rod.dimensions;
const protocol_versions = lightning_rod.protocol_versions;
const registry = lightning_rod.registry_data;

const maximum_tag_bytes = 32 * 1024;
const plan_entry_count = 14;

pub const ConfigureClient = struct {
    pub const id = "minecraft:configuration";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        dimensions: *dimensions.Vanilla,
        sessions: *lightning_rod.sessions.Sessions,
    };

    dimension_entries: [dimensions.max_dimensions]configuration.RegistryEntry,
    dimension_nbt: [dimensions.max_dimensions][dimensions.max_protocol_nbt_bytes]u8,
    biome_entries: [registry.biome_names.len]configuration.RegistryEntry,
    damage_entries: [damage_types.len]configuration.RegistryEntry,
    singleton_entries: [singleton_registries.len]configuration.RegistryEntry,
    tag_bytes: [maximum_tag_bytes]u8,
    entries: [plan_entry_count]configuration.Entry,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: @This().Configuration) !*@This() {
        const self = try allocator.create(@This());
        try self.initialize(dimensions.Vanilla.service());
        try deps.sessions.configure(self.plan());
        return self;
    }

    fn initialize(self: *@This(), dimension_service: lightning_rod.dimension_api.Service) !void {
        if (dimension_service.definitions.len > self.dimension_entries.len)
            return error.DimensionRegistryCapacity;
        initializeNamedEntries(&self.biome_entries, registry.biome_names);
        initializeNamedEntries(&self.damage_entries, &damage_types);
        for (singleton_registries, 0..) |item, index|
            self.singleton_entries[index] = .{ .id = item.entry_id };
        try self.initializeDimensions(dimension_service);
        const tags = try writeGameplayTags(&self.tag_bytes);

        var index: usize = 0;
        self.append(&index, .{ .feature_flags = .{ .values = &.{"minecraft:vanilla"} } });
        self.append(&index, .{ .known_packs = .{ .values = &known_packs } });
        self.append(&index, .{ .registry = .{ .id = "minecraft:dimension_type", .entries = self.dimension_entries[0..dimension_service.definitions.len] } });
        self.append(&index, .{ .registry = .{ .id = "minecraft:worldgen/biome", .entries = &self.biome_entries } });
        self.append(&index, .{ .registry = .{ .id = "minecraft:damage_type", .entries = &self.damage_entries } });
        for (singleton_registries, 0..) |item, singleton_index| {
            self.append(&index, .{ .registry = .{ .id = item.registry_id, .entries = self.singleton_entries[singleton_index..][0..1] } });
        }
        self.append(&index, .{ .tags = .{ .payload = tags } });
        std.debug.assert(index == self.entries.len);
    }

    pub fn plan(self: *const @This()) configuration.Plan {
        return .{ .entries = &self.entries };
    }

    fn initializeDimensions(self: *@This(), service: lightning_rod.dimension_api.Service) !void {
        for (service.definitions, 0..) |definition, index| {
            const payload = if (definition.known_pack)
                null
            else
                try dimensions.writeProtocolNbt(&self.dimension_nbt[index], definition);
            self.dimension_entries[index] = .{ .id = definition.id, .nbt = payload };
        }
    }

    fn append(self: *@This(), index: *usize, entry: configuration.Entry) void {
        std.debug.assert(index.* < self.entries.len);
        self.entries[index.*] = entry;
        index.* += 1;
    }
};

const known_packs = knownPacks();

fn knownPacks() [protocol_versions.minecraft_names.len]configuration.KnownPack {
    var result: [protocol_versions.minecraft_names.len]configuration.KnownPack = undefined;
    for (protocol_versions.minecraft_names, 0..) |name, index| result[index] = .{
        .namespace = "minecraft",
        .id = "core",
        .version = name,
    };
    return result;
}

fn initializeNamedEntries(output: []configuration.RegistryEntry, names: []const []const u8) void {
    std.debug.assert(output.len == names.len);
    for (output, names) |*entry, name| entry.* = .{ .id = name };
}

const SingletonRegistry = struct {
    registry_id: []const u8,
    entry_id: []const u8,
};

const singleton_registries = [_]SingletonRegistry{
    .{ .registry_id = "minecraft:cat_variant", .entry_id = "minecraft:tabby" },
    .{ .registry_id = "minecraft:chicken_variant", .entry_id = "minecraft:temperate" },
    .{ .registry_id = "minecraft:cow_variant", .entry_id = "minecraft:temperate" },
    .{ .registry_id = "minecraft:frog_variant", .entry_id = "minecraft:temperate" },
    .{ .registry_id = "minecraft:painting_variant", .entry_id = "minecraft:kebab" },
    .{ .registry_id = "minecraft:pig_variant", .entry_id = "minecraft:temperate" },
    .{ .registry_id = "minecraft:wolf_sound_variant", .entry_id = "minecraft:classic" },
    .{ .registry_id = "minecraft:wolf_variant", .entry_id = "minecraft:pale" },
};

const damage_types = [_][]const u8{
    "minecraft:arrow",
    "minecraft:bad_respawn_point",
    "minecraft:cactus",
    "minecraft:campfire",
    "minecraft:cramming",
    "minecraft:dragon_breath",
    "minecraft:drown",
    "minecraft:dry_out",
    "minecraft:ender_pearl",
    "minecraft:explosion",
    "minecraft:fall",
    "minecraft:falling_anvil",
    "minecraft:falling_block",
    "minecraft:falling_stalactite",
    "minecraft:fireball",
    "minecraft:fireworks",
    "minecraft:fly_into_wall",
    "minecraft:freeze",
    "minecraft:generic",
    "minecraft:generic_kill",
    "minecraft:hot_floor",
    "minecraft:in_fire",
    "minecraft:in_wall",
    "minecraft:indirect_magic",
    "minecraft:lava",
    "minecraft:lightning_bolt",
    "minecraft:mace_smash",
    "minecraft:magic",
    "minecraft:mob_attack",
    "minecraft:mob_attack_no_aggro",
    "minecraft:mob_projectile",
    "minecraft:on_fire",
    "minecraft:out_of_world",
    "minecraft:outside_border",
    "minecraft:player_attack",
    "minecraft:player_explosion",
    "minecraft:sonic_boom",
    "minecraft:spit",
    "minecraft:stalagmite",
    "minecraft:starve",
    "minecraft:sting",
    "minecraft:sweet_berry_bush",
    "minecraft:thorns",
    "minecraft:thrown",
    "minecraft:trident",
    "minecraft:unattributed_fireball",
    "minecraft:wind_charge",
    "minecraft:wither",
    "minecraft:wither_skull",
};

const ToolTag = struct {
    name: []const u8,
    item_id: i32,
};

const tool_tags = [_]ToolTag{
    .{ .name = "minecraft:mineable/shovel", .item_id = registry.item_diamond_shovel_id },
    .{ .name = "minecraft:mineable/pickaxe", .item_id = registry.item_diamond_pickaxe_id },
    .{ .name = "minecraft:mineable/axe", .item_id = registry.item_diamond_axe_id },
    .{ .name = "minecraft:mineable/hoe", .item_id = registry.item_diamond_hoe_id },
};

fn writeGameplayTags(buffer: []u8) ![]const u8 {
    var rest = try lightning_rod.protocol_support.write_count(buffer, i32, 1);
    rest = try lightning_rod.protocol_support.write_pstring(rest, "minecraft:block", i32);
    rest = try lightning_rod.protocol_support.write_count(rest, i32, tool_tags.len);
    inline for (tool_tags) |tool_tag| rest = try writeToolTag(rest, tool_tag);
    return buffer[0 .. buffer.len - rest.len];
}

fn writeToolTag(buffer: []u8, tool_tag: ToolTag) ![]u8 {
    var count: usize = 0;
    for (registry.blocks) |block| {
        if (blockUsesTool(block, tool_tag.item_id)) count += 1;
    }
    var rest = try lightning_rod.protocol_support.write_pstring(buffer, tool_tag.name, i32);
    rest = try lightning_rod.protocol_support.write_count(rest, i32, count);
    for (registry.blocks, 0..) |block, block_id| {
        if (blockUsesTool(block, tool_tag.item_id))
            rest = try lightning_rod.protocol_support.write_varint(rest, @intCast(block_id));
    }
    return rest;
}

fn blockUsesTool(block: registry.BlockInfo, item_id: i32) bool {
    for (registry.material_tools[block.material_offset..][0..block.material_count]) |tool| {
        if (tool.item_id == item_id) return true;
    }
    return false;
}

test "Vanilla Configuration establishes every Play registry dependency" {
    var value: ConfigureClient = undefined;
    try value.initialize(lightning_rod.dimensions.Vanilla.service());
    try std.testing.expect(value.plan().valid());
    try std.testing.expectEqualStrings("minecraft:dimension_type", value.entries[2].registry.id);
    try std.testing.expectEqualStrings("minecraft:worldgen/biome", value.entries[3].registry.id);
    try std.testing.expectEqualStrings("minecraft:damage_type", value.entries[4].registry.id);
    try std.testing.expectEqual(registry.biome_names.len, value.entries[3].registry.entries.len);
    try std.testing.expectEqualStrings("minecraft:plains", registry.biome_names[40]);
}

test "custom dimensions carry their definition instead of a known-pack reference" {
    const definition = lightning_rod.dimensions.Overworld.definition;
    var custom = definition;
    custom.id = "example:custom";
    custom.known_pack = false;
    var value: ConfigureClient = undefined;
    try value.initialize(.{ .definitions = &.{custom} });
    try std.testing.expect(value.entries[2].registry.entries[0].nbt != null);
}
