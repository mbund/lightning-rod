//! What mobs read about each block state: the path type it has alone, as
//! WalkNodeEvaluator.getPathTypeFromState gives it, and the tags, classes, identities and
//! properties that movement, collisions and block effects test. Tags come from the block
//! registry, so a datapack that changes them applies, and are read again when it publishes.
//! Classes and methods tags cannot tell come from the snapshot.

const std = @import("std");
const game_data = @import("game_data");
const Blocks = @import("vanilla_content").blocks.Blocks;
const shape_classes = @import("shape_classes.zig");

const registry = game_data.registry;
const assert = std.debug.assert;

/// PathType, in vanilla's order: getPathTypeOfMob walks the types a mob's box touches in this
/// order, so it decides which of equal maluses wins.
pub const PathType = enum(u8) {
    blocked,
    open,
    walkable,
    walkable_door,
    trapdoor,
    powder_snow,
    danger_powder_snow,
    fence,
    lava,
    water,
    water_border,
    rail,
    unpassable_rail,
    danger_fire,
    damage_fire,
    danger_other,
    damage_other,
    door_open,
    door_wood_closed,
    door_iron_closed,
    breach,
    leaves,
    sticky_honey,
    cocoa,
    damage_cautious,
    danger_trapdoor,

    pub const count = @typeInfo(PathType).@"enum".field_names.len;

    /// PathType.getMalus, what a mob pays to step on the type unless it overrides it.
    pub fn malus(self: PathType) f32 {
        return switch (self) {
            .blocked, .powder_snow, .fence, .lava, .unpassable_rail, .damage_other, .door_wood_closed, .door_iron_closed, .leaves => -1,
            .open, .walkable, .walkable_door, .trapdoor, .danger_powder_snow, .rail, .door_open, .cocoa, .damage_cautious, .danger_trapdoor => 0,
            .water, .water_border, .danger_fire, .danger_other, .sticky_honey => 8,
            .breach => 4,
            .damage_fire => 16,
        };
    }
};

/// Blocks whose identity vanilla tests, by block name.
pub const Kind = enum(u8) {
    other,
    lily_pad,
    big_dripleaf,
    powder_snow,
    cactus,
    sweet_berry_bush,
    honey_block,
    cocoa,
    wither_rose,
    pointed_dripstone,
    lava,
    water,
    bubble_column,
    magma_block,
    lava_cauldron,
    water_cauldron,
    powder_snow_cauldron,
    grass_block,
    ladder,
    scaffolding,
    cobweb,
    slime_block,
    farmland,
    hay_block,
    turtle_egg,
    soul_sand,
    moving_piston,
    fire,
    soul_fire,
    campfire,
    soul_campfire,
};

pub const Facing = enum(u3) { none, north, south, west, east, up, down };

pub const Flags = packed struct(u32) {
    air: bool = false,
    solid: bool = false,
    solid_render: bool = false,
    suffocating: bool = false,
    pathfindable_land: bool = false,
    climbable: bool = false,
    fence: bool = false,
    wall: bool = false,
    fence_gate: bool = false,
    door: bool = false,
    trapdoor: bool = false,
    cauldron: bool = false,
    fall_damage_resetting: bool = false,
    fire: bool = false,
    lit_campfire: bool = false,
    bed: bool = false,
    animals_spawnable_on: bool = false,
    open: bool = false,
    /// The top half, for trapdoors and slabs.
    top: bool = false,
    /// Bubble columns that pull down.
    drag: bool = false,
    /// BlockState.hasLargeCollisionShape: a collision shape reaching past its block, as fences do.
    large_shape: bool = false,
    /// An age property above zero, as grown sweet berry bushes have.
    aged: bool = false,
    /// A cauldron's fill level, 1 to 3.
    level: u2 = 0,
    padding: u8 = 0,
};

pub const State = struct {
    kind: Kind = .other,
    facing: Facing = .none,
    flags: Flags = .{},
    path: PathType = .open,
    /// The space its collision shape covers, by shape_classes: an edit between two states of
    /// one class changes no collision.
    collision: u16 = shape_classes.empty,
};

/// A shape reaching past its block (BlockState.hasLargeCollisionShape, or a moving piston), which
/// collision scans look one block further for.
pub const mark_large: u8 = 1;
/// A fluid, which bodies float in and are pushed by.
pub const mark_fluid: u8 = 2;
/// A block that acts on a mob inside it (BlockBehaviour.entityInside).
pub const mark_inside: u8 = 4;

pub const MobBlocks = struct {
    states: []State,
    block_definitions: *Blocks,
    /// Blocks by name, for tags, whose members name blocks by their place in another registry.
    names: std.StringHashMapUnmanaged(u16) = .empty,
    /// By block, the tags read through a property, filled while tags are read.
    /// The collision class of a whole block, as stone has.
    full_cube: u16 = 0,
    /// By state, what sections are marked for holding (see `mark_large` and the others), so a
    /// mob's window knows what its blocks cannot do.
    marks: []u8,
    trapdoors: []bool,
    campfires: []bool,

    pub fn init(allocator: std.mem.Allocator, block_definitions: *Blocks) !*MobBlocks {
        const self = try allocator.create(MobBlocks);
        self.* = .{
            .states = try allocator.alloc(State, registry.block_state_names.len),
            .block_definitions = block_definitions,
            .trapdoors = try allocator.alloc(bool, registry.blocks.len),
            .marks = try allocator.alloc(u8, registry.block_state_names.len),
            .campfires = try allocator.alloc(bool, registry.blocks.len),
        };
        try self.names.ensureTotalCapacity(allocator, @intCast(registry.blocks.len));
        for (registry.blocks, 0..) |info, block| self.names.putAssumeCapacity(blockName(registry.blockStateName(info.default_state).?), @intCast(block));
        self.readFixed();
        const collisions = try allocator.alloc(u16, self.states.len);
        defer allocator.free(collisions);
        try shape_classes.classify(allocator, collisions);
        for (self.states, collisions) |*entry, collision| entry.collision = collision;
        self.full_cube = self.states[@intCast(registry.blockStateId("minecraft:stone").?)].collision;
        for (self.marks, self.states, 0..) |*mark, entry, state| {
            mark.* = 0;
            if (entry.flags.large_shape) mark.* |= mark_large;
            if (game_data.physics.get(@intCast(state)).fluid != .none) mark.* |= mark_fluid;
            if (@import("block_effects.zig").insideActs(entry.kind)) mark.* |= mark_inside;
        }
        try self.readTags();
        try block_definitions.registry.onChange(self, readTags);
        return self;
    }

    pub fn get(self: *const MobBlocks, state: u16) State {
        return self.states[state];
    }

    /// What does not change with tags: identities, classes, properties and method results.
    fn readFixed(self: *MobBlocks) void {
        for (self.states, 0..) |*entry, index| {
            const state: u16 = @intCast(index);
            const name = registry.blockStateName(state).?;
            const physics = game_data.physics.get(state);
            const mob = game_data.physics.mobState(state);
            entry.* = .{
                .kind = kindOf(blockName(name)),
                .facing = facingOf(property(name, "facing")),
                .flags = .{
                    .air = physics.air,
                    .solid = mob.solid,
                    .solid_render = mob.solid_render,
                    .suffocating = mob.suffocating,
                    .pathfindable_land = mob.pathfindable_land,
                    .fence_gate = mob.fence_gate,
                    .trapdoor = mob.trapdoor,
                    .open = std.mem.eql(u8, property(name, "open") orelse "", "true"),
                    .top = std.mem.eql(u8, property(name, "half") orelse "", "top") or std.mem.eql(u8, property(name, "type") orelse "", "top"),
                    .drag = std.mem.eql(u8, property(name, "drag") orelse "", "true"),
                    .large_shape = largeShape(state),
                    .aged = !std.mem.eql(u8, property(name, "age") orelse "0", "0"),
                    .level = if (property(name, "level")) |value| (if (value.len == 1 and value[0] >= '1' and value[0] <= '3') @as(u2, @intCast(value[0] - '0')) else 0) else 0,
                },
            };
            if (entry.kind == .moving_piston) entry.flags.large_shape = true;
        }
    }

    /// Tags come with the block definitions, which a datapack may change. A tag a datapack
    /// leaves out has no members, as in vanilla.
    fn readTags(self: *MobBlocks) !void {
        for (self.states) |*entry| {
            entry.flags.climbable = false;
            entry.flags.fence = false;
            entry.flags.wall = false;
            entry.flags.door = false;
            entry.flags.cauldron = false;
            entry.flags.fall_damage_resetting = false;
            entry.flags.fire = false;
            entry.flags.lit_campfire = false;
            entry.flags.bed = false;
            entry.flags.animals_spawnable_on = false;
        }
        const trapdoors = self.trapdoors;
        const campfires = self.campfires;
        @memset(trapdoors, false);
        @memset(campfires, false);
        if (self.block_definitions.client.get("minecraft:block")) |block_registry| {
            const tags = &block_registry.tags;
            const Tag = enum { climbable, fences, walls, doors, cauldrons, fall_damage_resetting, fire, campfires, beds, animals_spawnable_on, trapdoors };
            inline for (@typeInfo(Tag).@"enum".field_names) |field| {
                const tag = @field(Tag, field);
                if (tags.find("minecraft:" ++ field)) |found| for (tags.members(found)) |member| {
                    if (member >= block_registry.entries.len) continue;
                    const block = self.names.get(block_registry.entries[member].name) orelse continue;
                    switch (tag) {
                        .trapdoors => trapdoors[block] = true,
                        .campfires => campfires[block] = true,
                        else => {
                            const info = registry.blocks[block];
                            var state = info.min_state;
                            while (state <= info.max_state) : (state += 1) {
                                const flags = &self.states[@intCast(state)].flags;
                                switch (tag) {
                                    .climbable => flags.climbable = true,
                                    .fences => flags.fence = true,
                                    .walls => flags.wall = true,
                                    .doors => flags.door = true,
                                    .cauldrons => flags.cauldron = true,
                                    .fall_damage_resetting => flags.fall_damage_resetting = true,
                                    .fire => flags.fire = true,
                                    .beds => flags.bed = true,
                                    .animals_spawnable_on => flags.animals_spawnable_on = true,
                                    .trapdoors, .campfires => unreachable,
                                }
                            }
                        },
                    }
                };
            }
        }
        for (self.states, 0..) |*entry, index| {
            const state: u16 = @intCast(index);
            const block = registry.block_state_to_block[state];
            const name = registry.blockStateName(state).?;
            entry.flags.lit_campfire = campfires[block] and std.mem.eql(u8, property(name, "lit") orelse "", "true");
            entry.path = pathType(entry.*, state, trapdoors[block]);
        }
    }

    /// WalkNodeEvaluator.getPathTypeFromState.
    fn pathType(entry: State, state: u16, trapdoor_tag: bool) PathType {
        const mob = game_data.physics.mobState(state);
        const fluid = game_data.physics.get(state).fluid;
        if (entry.flags.air) return .open;
        if (trapdoor_tag or entry.kind == .lily_pad or entry.kind == .big_dripleaf) return .trapdoor;
        if (entry.kind == .powder_snow) return .powder_snow;
        if (entry.kind == .cactus or entry.kind == .sweet_berry_bush) return .damage_other;
        if (entry.kind == .honey_block) return .sticky_honey;
        if (entry.kind == .cocoa) return .cocoa;
        if (entry.kind == .wither_rose or entry.kind == .pointed_dripstone) return .damage_cautious;
        if (fluid == .lava) return .lava;
        // NodeEvaluator.isBurningBlock.
        if (entry.flags.fire or entry.kind == .lava or entry.kind == .magma_block or entry.flags.lit_campfire or entry.kind == .lava_cauldron) return .damage_fire;
        if (mob.door) return if (mob.door_open) .door_open else if (mob.door_by_hand) .door_wood_closed else .door_iron_closed;
        if (mob.rail) return .rail;
        if (mob.leaves) return .leaves;
        if (entry.flags.fence or entry.flags.wall or (mob.fence_gate and !mob.fence_gate_open)) return .fence;
        if (!mob.pathfindable_land) return .blocked;
        return if (fluid == .water) .water else .open;
    }
};

fn blockName(state_name: []const u8) []const u8 {
    return state_name[0 .. std.mem.indexOfScalar(u8, state_name, '[') orelse state_name.len];
}

fn property(name: []const u8, key: []const u8) ?[]const u8 {
    const begin = std.mem.indexOfScalar(u8, name, '[') orelse return null;
    var properties = std.mem.splitScalar(u8, name[begin + 1 .. name.len - 1], ',');
    while (properties.next()) |entry| {
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..separator], key)) return entry[separator + 1 ..];
    }
    return null;
}

fn facingOf(value: ?[]const u8) Facing {
    const name = value orelse return .none;
    inline for (@typeInfo(Facing).@"enum".field_names) |field| {
        if (std.mem.eql(u8, name, field)) return @field(Facing, field);
    }
    return .none;
}

fn kindOf(name: []const u8) Kind {
    const prefix = "minecraft:";
    if (!std.mem.startsWith(u8, name, prefix)) return .other;
    const path = name[prefix.len..];
    inline for (@typeInfo(Kind).@"enum".field_names) |field| {
        if (comptime !std.mem.eql(u8, field, "other")) {
            if (std.mem.eql(u8, path, field)) return @field(Kind, field);
        }
    }
    return .other;
}

fn largeShape(state: u16) bool {
    const boxes = game_data.physics.spawnCollision(state, 0, 0, 0);
    for (0..boxes.count) |index| {
        const value = boxes.get(index);
        if (value[0] < 0 or value[1] < 0 or value[2] < 0 or value[3] > 1 or value[4] > 1 or value[5] > 1) return true;
    }
    return false;
}
