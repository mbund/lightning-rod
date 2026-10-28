const std = @import("std");
const game_data = @import("game_data");
const chunks = @import("chunks");

pub const Kind = enum { chest, furnace, crafting };
pub const Facing = enum(u2) { north, south, west, east };
pub const ChestType = enum(u2) { single, left, right };

pub const ChestInfo = packed struct(u8) { facing: Facing, side: ChestType, waterlogged: bool, padding: u3 = 0 };
pub const FurnaceInfo = packed struct(u8) { facing: Facing, lit: bool, padding: u5 = 0 };

pub const States = struct {
    chests: [4][3][2]u16,
    furnaces: [4][2]u16,
    crafting: u16,
    chest_minimum: u16,
    furnace_minimum: u16,
    chest_info: [24]ChestInfo,
    furnace_info: [8]FurnaceInfo,

    pub fn init() !States {
        var self: States = undefined;
        const chest_block = game_data.registry.blocks[game_data.registry.block_state_to_block[game_data.registry.block_chest_default_state]];
        const furnace_block = game_data.registry.blocks[game_data.registry.block_state_to_block[game_data.registry.block_furnace_default_state]];
        if (chest_block.max_state - chest_block.min_state + 1 != self.chest_info.len or furnace_block.max_state - furnace_block.min_state + 1 != self.furnace_info.len) return error.InvalidContainerStates;
        self.chest_minimum = @intCast(chest_block.min_state);
        self.furnace_minimum = @intCast(furnace_block.min_state);
        var buffer: [128]u8 = undefined;
        inline for (std.meta.tags(Facing)) |direction| {
            inline for (std.meta.tags(ChestType)) |side| for (0..2) |water| {
                const name = try std.fmt.bufPrint(&buffer, "minecraft:chest[facing={s},type={s},waterlogged={s}]", .{ @tagName(direction), @tagName(side), if (water == 0) "false" else "true" });
                const state: u16 = @intCast(game_data.registry.blockStateId(name) orelse return error.MissingChestState);
                self.chests[@intFromEnum(direction)][@intFromEnum(side)][water] = state;
                self.chest_info[state - self.chest_minimum] = .{ .facing = direction, .side = side, .waterlogged = water != 0 };
            };
            for (0..2) |lit| {
                const name = try std.fmt.bufPrint(&buffer, "minecraft:furnace[facing={s},lit={s}]", .{ @tagName(direction), if (lit == 0) "false" else "true" });
                const state: u16 = @intCast(game_data.registry.blockStateId(name) orelse return error.MissingFurnaceState);
                self.furnaces[@intFromEnum(direction)][lit] = state;
                self.furnace_info[state - self.furnace_minimum] = .{ .facing = direction, .lit = lit != 0 };
            }
        }
        self.crafting = @intCast(game_data.registry.block_crafting_table_default_state);
        return self;
    }

    pub fn kind(self: *const States, state: u16) ?Kind {
        const block = game_data.registry.block_state_to_block[state];
        if (block == game_data.registry.block_state_to_block[self.chests[0][0][0]]) return .chest;
        if (block == game_data.registry.block_state_to_block[self.furnaces[0][0]]) return .furnace;
        if (state == self.crafting) return .crafting;
        return null;
    }

    pub fn facing(self: *const States, state: u16) Facing {
        if (self.kind(state) == .furnace) return self.furnaceInfo(state).facing;
        std.debug.assert(self.kind(state) == .chest);
        return self.chest_info[state - self.chest_minimum].facing;
    }

    pub fn furnaceInfo(self: *const States, state: u16) FurnaceInfo {
        std.debug.assert(self.kind(state) == .furnace);
        return self.furnace_info[state - self.furnace_minimum];
    }

    pub fn chestType(self: *const States, state: u16) ChestType {
        std.debug.assert(self.kind(state) == .chest);
        return self.chest_info[state - self.chest_minimum].side;
    }

    pub fn waterlogged(self: *const States, state: u16) bool {
        std.debug.assert(self.kind(state) == .chest);
        return self.chest_info[state - self.chest_minimum].waterlogged;
    }

    pub fn chest(self: *const States, state: u16, side: ChestType) u16 {
        return self.chests[@intFromEnum(self.facing(state))][@intFromEnum(side)][@intFromBool(self.waterlogged(state))];
    }

    pub fn partner(self: *const States, state: u16, position: chunks.Position) ?chunks.Position {
        const side = self.chestType(state);
        if (side == .single) return null;
        const right = rightOf(self.facing(state));
        const sign: i32 = if (side == .left) 1 else -1;
        return .{ .x = position.x + right[0] * sign, .y = position.y, .z = position.z + right[1] * sign };
    }
};

pub fn placedFacing(yaw: f32) Facing {
    const direction: usize = @intFromFloat(@mod(@floor(yaw / 90.0 + 0.5), 4));
    return ([_]Facing{ .north, .east, .south, .west })[direction];
}

pub fn rightOf(facing: Facing) [2]i32 {
    return switch (facing) {
        .north => .{ 1, 0 },
        .south => .{ -1, 0 },
        .west => .{ 0, -1 },
        .east => .{ 0, 1 },
    };
}

test "containers face the placing player in every quadrant" {
    for ([_]f32{ 0, 90, 180, -90 }, [_]Facing{ .north, .east, .south, .west }) |yaw, facing| try std.testing.expectEqual(facing, placedFacing(yaw));
}

pub fn entityName(state: u16) ?[]const u8 {
    const block = game_data.registry.block_state_to_block[state];
    if (block == game_data.registry.block_state_to_block[game_data.registry.block_chest_default_state]) return "minecraft:chest";
    if (block == game_data.registry.block_state_to_block[game_data.registry.block_furnace_default_state]) return "minecraft:furnace";
    return null;
}
