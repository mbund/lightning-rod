const std = @import("std");

pub const Rendering = struct {
    occluder: bool,
    block_entity: bool,
    beacon: bool,
    gateway: bool,
    debug_bounds: bool,
};

pub const Fluid = enum(u8) { none, water, lava };
pub const State = struct {
    friction: f32,
    speed: f32,
    water_block: bool,
    fluid: Fluid,
    amount: u8,
    blocks_motion: bool,
    falling: bool,
    ice: bool,
    sturdy: u8,
    collision_top_full: bool = false,
    air: bool = false,
    liquid_block: bool = false,

    pub fn height(self: State) f32 {
        return @as(f32, @floatFromInt(self.amount)) / 9;
    }
};

pub const Experience = struct {
    minimum: u8 = 0,
    bound: u8 = 0,
    rolls: u8 = 0,
    enchantments: bool = false,

    pub fn maximum(self: Experience) i32 {
        std.debug.assert(self.rolls == 0 or self.bound > 0);
        return @as(i32, self.minimum) + @as(i32, self.rolls) * (@as(i32, self.bound) - 1);
    }

    pub fn sample(self: Experience, random: std.Random) i32 {
        std.debug.assert(self.rolls == 0 or self.bound > 0);
        var value: i32 = self.minimum;
        for (0..self.rolls) |_| value += @intCast(random.uintLessThan(u32, self.bound));
        std.debug.assert(value >= self.minimum and value <= self.maximum());
        return value;
    }
};

/// What mobs read about a block state that its tags cannot tell.
pub const MobState = struct {
    solid: bool,
    solid_render: bool,
    pathfindable_land: bool,
    pathfindable_water: bool,
    pathfindable_air: bool,
    door: bool,
    door_open: bool,
    door_by_hand: bool,
    rail: bool,
    leaves: bool,
    fence_gate: bool,
    fence_gate_open: bool,
    trapdoor: bool,
    suffocating: bool,
    jump_factor: f32,
    /// The path type vanilla gives the state alone, with vanilla's tags. Only for checking the
    /// port, which reads tags from the registry so datapacks apply. 255 where it is unknown.
    vanilla_path_type: u8,
};

pub const EntityType = struct {
    width: f32,
    height: f32,
    eye_height: f32,
    fixed: bool,
    fire_immune: bool,
    track_deltas: bool,
    summonable: bool,
    living: bool,
    category: u8,
    /// In chunks.
    tracking_range: u8,
    /// In ticks.
    update_interval: u32,
    attribute_offset: u32,
    attribute_count: u8,
};

const mob_state_size = 7;

/// Where an item's attribute modifiers apply, as vanilla's EquipmentSlotGroup names them.
pub const SlotGroup = enum { any, mainhand, offhand, hand, feet, legs, chest, head, armor, body, saddle };

pub const ItemModifier = struct {
    pub const Operation = enum(u8) { add_value, add_multiplied_base, add_multiplied_total };
    attribute: []const u8,
    id: []const u8,
    slot: SlotGroup,
    operation: Operation,
    amount: f64,
};

pub const Weapon = struct { damage_per_attack: u16, disable_blocking_seconds: f32 };

/// A blocks_attacks component: an item that blocks while raised, as shields do.
pub const BlocksAttacks = struct {
    pub const Reduction = struct { horizontal_angle: f32, typed: bool, base: f32, factor: f32 };
    block_delay_seconds: f32,
    disable_cooldown_scale: f32,
    /// The damage reductions, `reduction_bytes` each, read with `reduction`.
    reductions: []const u8,
    damage_threshold: f32,
    damage_base: f32,
    damage_factor: f32,
    /// A damage type tag that passes the block, a sound for a block and one for being disabled,
    /// empty for none.
    bypassed_by: []const u8,
    block_sound: []const u8,
    disabled_sound: []const u8,

    pub const reduction_bytes = 4 + 1 + 4 + 4;

    pub fn reductionCount(self: BlocksAttacks) usize {
        return self.reductions.len / reduction_bytes;
    }

    pub fn reduction(self: BlocksAttacks, index: usize) Reduction {
        const entry = self.reductions[index * reduction_bytes ..][0..reduction_bytes];
        return .{
            .horizontal_angle = @bitCast(std.mem.readInt(u32, entry[0..4], .big)),
            .typed = entry[4] != 0,
            .base = @bitCast(std.mem.readInt(u32, entry[5..9], .big)),
            .factor = @bitCast(std.mem.readInt(u32, entry[9..13], .big)),
        };
    }
};

/// A blocks_attacks entry past its reductions: three floats of item damage and three names.
const blocking_tail_bytes = 4 * 3 + 2 * 3;

/// An attribute modifier entry: attribute, id and slot group names, operation and amount.
const modifier_bytes = 2 + 2 + 2 + 1 + 8;

pub fn Data(comptime expected_states: usize, comptime expected_blocks: usize, comptime bytes: []const u8) type {
    const shape_count = std.mem.readInt(u32, bytes[12..16], .big);
    const box_count = std.mem.readInt(u32, bytes[16..20], .big);
    const shapes_offset = 20 + expected_states * 26;
    const boxes_offset = shapes_offset + shape_count * 6;
    const experience_offset = boxes_offset + box_count * 48;
    const rendering_offset = experience_offset + 4 + expected_blocks * 4;
    const outline_offset = rendering_offset + expected_states;
    const mob_states_offset = outline_offset + expected_states * 2;
    const entity_types_offset = mob_states_offset + 4 + expected_states * mob_state_size;
    const entity_type_count = std.mem.readInt(u32, bytes[entity_types_offset..][0..4], .big);
    const layout = comptime entities: {
        @setEvalBranchQuota(100_000);
        var offsets: [entity_type_count]u32 = undefined;
        var at: usize = entity_types_offset + 4;
        for (&offsets) |*offset_value| {
            offset_value.* = at;
            at += 20 + @as(usize, bytes[at + 19]) * 10;
        }
        break :entities .{ .offsets = offsets, .eggs = at };
    };
    const egg_count = std.mem.readInt(u32, bytes[layout.eggs..][0..4], .big);
    const sine_offset = layout.eggs + 4 + egg_count * 8;
    const arcsine_offset = sine_offset + 65536 * 4;
    const items = comptime items: {
        @setEvalBranchQuota(100_000);
        var at: usize = arcsine_offset + 257 * 16;
        const tag_count = std.mem.readInt(u32, bytes[at..][0..4], .big);
        at += 4;
        var tags: [tag_count][]const u8 = undefined;
        for (&tags) |*tag| {
            const length = std.mem.readInt(u16, bytes[at..][0..2], .big);
            tag.* = bytes[at + 2 ..][0..length];
            at += 2 + length;
        }
        const count = std.mem.readInt(u32, bytes[at..][0..4], .big);
        break :items .{ .tags = tags, .count = count, .offset = at + 4 };
    };
    const modifiers = comptime modifiers: {
        @setEvalBranchQuota(1_000_000);
        var at: usize = items.offset + items.count;
        const name_count = std.mem.readInt(u32, bytes[at..][0..4], .big);
        at += 4;
        var names: [name_count][]const u8 = undefined;
        for (&names) |*name| {
            const length = std.mem.readInt(u16, bytes[at..][0..2], .big);
            name.* = bytes[at + 2 ..][0..length];
            at += 2 + length;
        }
        const count = std.mem.readInt(u32, bytes[at..][0..4], .big);
        at += 4;
        var offsets: [count]u32 = undefined;
        var blocking: [count]u32 = undefined;
        for (&offsets, &blocking) |*offset_value, *blocking_value| {
            offset_value.* = at;
            at += 1 + @as(usize, bytes[at]) * modifier_bytes;
            at += if (bytes[at] == 0) 1 else 1 + 2 + 4;
            blocking_value.* = at;
            at += if (bytes[at] == 0) 1 else 1 + 4 + 4 + 1 + @as(usize, bytes[at + 9]) * BlocksAttacks.reduction_bytes + blocking_tail_bytes;
        }
        break :modifiers .{ .names = names, .offsets = offsets, .blocking = blocking, .end = at };
    };
    std.debug.assert(modifiers.offsets.len == items.count);
    std.debug.assert(bytes.len == modifiers.end);
    std.debug.assert(std.mem.eql(u8, bytes[0..8], "LRPHYS10"));
    std.debug.assert(std.mem.readInt(u32, bytes[8..12], .big) == expected_states);
    std.debug.assert(std.mem.readInt(u32, bytes[experience_offset..][0..4], .big) == expected_blocks);
    std.debug.assert(std.mem.readInt(u32, bytes[mob_states_offset..][0..4], .big) == expected_states);
    return struct {
        pub const entity_types = entity_type_count;

        /// Mth.SIN, sine in 65536 steps of a turn, as the JVM rounds it.
        pub fn sine(index: u16) f32 {
            return @bitCast(std.mem.readInt(u32, bytes[sine_offset + @as(usize, index) * 4 ..][0..4], .little));
        }

        /// Mth.ASIN_TAB and Mth.COS_TAB as arrays, read at compile time, for lookups that are
        /// one load each.
        pub const arcsines: [257]f64 = table(0);
        pub const arccosines: [257]f64 = table(8);

        fn table(comptime column: usize) [257]f64 {
            @setEvalBranchQuota(10_000);
            var result: [257]f64 = undefined;
            for (&result, 0..) |*value, index| value.* = @bitCast(std.mem.readInt(u64, bytes[arcsine_offset + index * 16 + column ..][0..8], .little));
            return result;
        }

        /// Mth.ASIN_TAB and Mth.COS_TAB, which Mth.atan2 reads.
        pub fn arcsine(index: u9) [2]f64 {
            std.debug.assert(index <= 256);
            const entry = bytes[arcsine_offset + @as(usize, index) * 16 ..][0..16];
            return .{ @bitCast(std.mem.readInt(u64, entry[0..8], .little)), @bitCast(std.mem.readInt(u64, entry[8..16], .little)) };
        }

        pub fn mobState(state: u16) MobState {
            std.debug.assert(state < expected_states);
            const entry = bytes[mob_states_offset + 4 + @as(usize, state) * mob_state_size ..][0..mob_state_size];
            const flags = std.mem.readInt(u16, entry[0..2], .little);
            return .{
                .solid = flags & 1 != 0,
                .solid_render = flags & 2 != 0,
                .pathfindable_land = flags & 4 != 0,
                .pathfindable_water = flags & 8 != 0,
                .pathfindable_air = flags & 16 != 0,
                .door = flags & 32 != 0,
                .door_open = flags & 64 != 0,
                .door_by_hand = flags & 128 != 0,
                .rail = flags & 256 != 0,
                .leaves = flags & 512 != 0,
                .fence_gate = flags & 1024 != 0,
                .fence_gate_open = flags & 2048 != 0,
                .trapdoor = flags & 4096 != 0,
                .suffocating = flags & 8192 != 0,
                .jump_factor = @bitCast(std.mem.readInt(u32, entry[2..6], .little)),
                .vanilla_path_type = entry[6],
            };
        }

        pub const item_count = items.count;

        /// How many default attribute modifiers an item has, as its attribute_modifiers component
        /// lists them.
        pub fn itemModifierCount(item: u32) u8 {
            std.debug.assert(item < items.count);
            return bytes[modifiers.offsets[item]];
        }

        /// One of an item's default attribute modifiers, its names read in place.
        pub fn itemModifier(item: u32, index: u8) ItemModifier {
            std.debug.assert(index < itemModifierCount(item));
            const entry = bytes[modifiers.offsets[item] + 1 + @as(usize, index) * modifier_bytes ..][0..modifier_bytes];
            const operation = std.enums.fromInt(ItemModifier.Operation, entry[6]) orelse unreachable;
            return .{
                .attribute = modifiers.names[std.mem.readInt(u16, entry[0..2], .big)],
                .id = modifiers.names[std.mem.readInt(u16, entry[2..4], .big)],
                .slot = std.meta.stringToEnum(SlotGroup, modifiers.names[std.mem.readInt(u16, entry[4..6], .big)]) orelse unreachable,
                .operation = operation,
                .amount = @bitCast(std.mem.readInt(u64, entry[7..15], .big)),
            };
        }

        /// An item's weapon component: how much an attack wears it, and how long it disables a
        /// shield it hits.
        pub fn itemWeapon(item: u32) ?Weapon {
            const at = modifiers.offsets[item] + 1 + @as(usize, itemModifierCount(item)) * modifier_bytes;
            if (bytes[at] == 0) return null;
            return .{
                .damage_per_attack = std.mem.readInt(u16, bytes[at + 1 ..][0..2], .big),
                .disable_blocking_seconds = @bitCast(std.mem.readInt(u32, bytes[at + 3 ..][0..4], .big)),
            };
        }

        /// An item's blocks_attacks component, its reductions and names read in place.
        pub fn itemBlocksAttacks(item: u32) ?BlocksAttacks {
            std.debug.assert(item < items.count);
            const at = modifiers.blocking[item];
            if (bytes[at] == 0) return null;
            const count = bytes[at + 9];
            const tail = at + 10 + @as(usize, count) * BlocksAttacks.reduction_bytes;
            return .{
                .block_delay_seconds = @bitCast(std.mem.readInt(u32, bytes[at + 1 ..][0..4], .big)),
                .disable_cooldown_scale = @bitCast(std.mem.readInt(u32, bytes[at + 5 ..][0..4], .big)),
                .reductions = bytes[at + 10 .. tail],
                .damage_threshold = @bitCast(std.mem.readInt(u32, bytes[tail..][0..4], .big)),
                .damage_base = @bitCast(std.mem.readInt(u32, bytes[tail + 4 ..][0..4], .big)),
                .damage_factor = @bitCast(std.mem.readInt(u32, bytes[tail + 8 ..][0..4], .big)),
                .bypassed_by = modifiers.names[std.mem.readInt(u16, bytes[tail + 12 ..][0..2], .big)],
                .block_sound = modifiers.names[std.mem.readInt(u16, bytes[tail + 14 ..][0..2], .big)],
                .disabled_sound = modifiers.names[std.mem.readInt(u16, bytes[tail + 16 ..][0..2], .big)],
            };
        }

        /// The damage type tag an item resists by default, as its damage_resistant component
        /// names it.
        pub fn itemResistance(item: u32) ?[]const u8 {
            std.debug.assert(item < items.count);
            const index = bytes[items.offset + item];
            if (index == 0) return null;
            return items.tags[index - 1];
        }

        pub fn entityType(kind: u32) EntityType {
            std.debug.assert(kind < entity_type_count);
            const at = layout.offsets[kind];
            const entry = bytes[at..][0..20];
            return .{
                .width = @bitCast(std.mem.readInt(u32, entry[0..4], .little)),
                .height = @bitCast(std.mem.readInt(u32, entry[4..8], .little)),
                .eye_height = @bitCast(std.mem.readInt(u32, entry[8..12], .little)),
                .fixed = entry[12] & 1 != 0,
                .fire_immune = entry[12] & 2 != 0,
                .track_deltas = entry[12] & 4 != 0,
                .summonable = entry[12] & 8 != 0,
                .living = entry[12] & 16 != 0,
                .category = entry[13],
                .tracking_range = entry[14],
                .update_interval = std.mem.readInt(u32, entry[15..19], .little),
                .attribute_offset = at + 20,
                .attribute_count = entry[19],
            };
        }

        /// The base value of an attribute the entity type has by default, by attribute id.
        pub fn attribute(kind: u32, id: u16) ?f64 {
            const entity = entityType(kind);
            for (0..entity.attribute_count) |index| {
                const entry = bytes[entity.attribute_offset + index * 10 ..][0..10];
                if (std.mem.readInt(u16, entry[0..2], .little) == id) return @bitCast(std.mem.readInt(u64, entry[2..10], .little));
            }
            return null;
        }

        /// The entity type a spawn egg item makes.
        pub fn spawnEgg(item: i32) ?u32 {
            for (0..egg_count) |index| {
                const entry = bytes[layout.eggs + 4 + index * 8 ..][0..8];
                if (std.mem.readInt(i32, entry[0..4], .little) == item) return @intCast(std.mem.readInt(i32, entry[4..8], .little));
            }
            return null;
        }

        pub const Boxes = struct {
            offset: u32,
            count: u16,
            translation: [3]f64,
            pub fn get(self: Boxes, index: usize) [6]f64 {
                std.debug.assert(index < self.count);
                const entry = bytes[boxes_offset + (@as(usize, self.offset) + index) * 48 ..][0..48];
                var result: [6]f64 = undefined;
                for (&result, 0..) |*coordinate, axis| {
                    const value: f64 = @bitCast(std.mem.readInt(u64, entry[axis * 8 ..][0..8], .little));
                    coordinate.* = value + self.translation[axis % 3];
                }
                return result;
            }
        };
        pub fn spawnCollision(state: u16, x: i32, y: i32, z: i32) Boxes {
            std.debug.assert(state < expected_states);
            const context: usize = if (y < -1) 0 else if (y == -1) 1 else 2;
            const shape = std.mem.readInt(u16, bytes[20 + @as(usize, state) * 26 + 12 + context * 2 ..][0..2], .little);
            std.debug.assert(shape < shape_count);
            const entry = bytes[shapes_offset + @as(usize, shape) * 6 ..][0..6];
            const offset_entry = bytes[20 + @as(usize, state) * 26 + 18 ..][0..8];
            const horizontal: f32 = @bitCast(std.mem.readInt(u32, offset_entry[0..4], .little));
            const vertical: f32 = @bitCast(std.mem.readInt(u32, offset_entry[4..8], .little));
            const result: Boxes = .{ .offset = std.mem.readInt(u32, entry[0..4], .little), .count = std.mem.readInt(u16, entry[4..6], .little), .translation = offset(x, z, horizontal, vertical) };
            std.debug.assert(@as(usize, result.offset) + result.count <= box_count);
            return result;
        }
        /// How far a state's shapes move with its position: horizontally, then down. Two states
        /// with the same limits move alike at every position.
        pub fn offsetLimits(state: u16) [2]f32 {
            std.debug.assert(state < expected_states);
            const offset_entry = bytes[20 + @as(usize, state) * 26 + 18 ..][0..8];
            return .{ @bitCast(std.mem.readInt(u32, offset_entry[0..4], .little)), @bitCast(std.mem.readInt(u32, offset_entry[4..8], .little)) };
        }
        /// The outline shape, which raycasts for using items and blocks trace, at a position.
        pub fn outline(state: u16, x: i32, z: i32) Boxes {
            std.debug.assert(state < expected_states);
            const shape = std.mem.readInt(u16, bytes[outline_offset + @as(usize, state) * 2 ..][0..2], .little);
            std.debug.assert(shape < shape_count);
            const entry = bytes[shapes_offset + @as(usize, shape) * 6 ..][0..6];
            const offset_entry = bytes[20 + @as(usize, state) * 26 + 18 ..][0..8];
            const horizontal: f32 = @bitCast(std.mem.readInt(u32, offset_entry[0..4], .little));
            const vertical: f32 = @bitCast(std.mem.readInt(u32, offset_entry[4..8], .little));
            const result: Boxes = .{ .offset = std.mem.readInt(u32, entry[0..4], .little), .count = std.mem.readInt(u16, entry[4..6], .little), .translation = offset(x, z, horizontal, vertical) };
            std.debug.assert(@as(usize, result.offset) + result.count <= box_count);
            return result;
        }

        pub fn experience(block: u16) Experience {
            std.debug.assert(block < expected_blocks);
            const entry = bytes[experience_offset + 4 + @as(usize, block) * 4 ..][0..4];
            return .{ .minimum = entry[0], .bound = entry[1], .rolls = entry[2], .enchantments = entry[3] & 1 != 0 };
        }

        pub fn rendering(state: u16) Rendering {
            std.debug.assert(state < expected_states);
            const flags = bytes[rendering_offset + state];
            return .{ .occluder = flags & 1 != 0, .block_entity = flags & 2 != 0, .beacon = flags & 4 != 0, .gateway = flags & 8 != 0, .debug_bounds = flags & 16 != 0 };
        }

        pub fn get(state: u16) State {
            std.debug.assert(state < expected_states);
            const entry = bytes[20 + @as(usize, state) * 26 ..][0..12];
            return .{ .friction = @bitCast(std.mem.readInt(u32, entry[0..4], .little)), .speed = @bitCast(std.mem.readInt(u32, entry[4..8], .little)), .fluid = @fromBackingInt(@intCast(entry[8])), .amount = entry[9], .blocks_motion = entry[10] & 1 != 0, .falling = entry[10] & 2 != 0, .ice = entry[10] & 4 != 0, .water_block = entry[10] & 8 != 0, .sturdy = entry[11], .collision_top_full = entry[10] & 16 != 0, .air = entry[10] & 32 != 0, .liquid_block = entry[10] & 64 != 0 };
        }
    };
}

pub fn offset(x: i32, z: i32, horizontal: f32, vertical: f32) [3]f64 {
    if (horizontal == 0 and vertical == 0) return @splat(0);
    var seed: i64 = @as(i64, x *% 3129871) ^ (@as(i64, z) *% 116129781);
    seed = (seed *% seed *% 42317861 +% seed *% 11) >> 16;
    const nx = @as(f64, @as(f32, @floatFromInt(seed & 15)) / 15);
    const ny = @as(f64, @as(f32, @floatFromInt((seed >> 4) & 15)) / 15);
    const nz = @as(f64, @as(f32, @floatFromInt((seed >> 8) & 15)) / 15);
    return .{ std.math.clamp((nx - 0.5) * 0.5, -@as(f64, horizontal), horizontal), (ny - 1) * vertical, std.math.clamp((nz - 0.5) * 0.5, -@as(f64, horizontal), horizontal) };
}
