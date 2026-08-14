const lightning_rod = @import("lightning_rod");
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const std = @import("std");
const config = lightning_rod.config.value;
const registry = lightning_rod.registry_data;
const collision = lightning_rod.collision;
const block_writer = lightning_rod.block_writer;
const Packets = lightning_rod.Packets;
const world_identity = lightning_rod.world_identity;

const Direction = enum(u2) { north, south, west, east };
const DoorHalf = enum(u1) { upper, lower };
const TrapdoorHalf = enum(u1) { top, bottom };
const Hinge = enum(u1) { left, right };

const Door = struct {
    block_id: u16,
    facing: Direction,
    half: DoorHalf,
    hinge: Hinge,
    open: bool,
    powered: bool,

    fn state(self: Door) i32 {
        const block = registry.blocks[self.block_id];
        return block.min_state +
            @as(i32, @intFromEnum(self.facing)) * 16 +
            @as(i32, @intFromEnum(self.half)) * 8 +
            @as(i32, @intFromEnum(self.hinge)) * 4 +
            @as(i32, @intFromBool(!self.open)) * 2 +
            @intFromBool(!self.powered);
    }
};

const Trapdoor = struct {
    block_id: u16,
    facing: Direction,
    half: TrapdoorHalf,
    open: bool,
    powered: bool,
    waterlogged: bool,

    fn state(self: Trapdoor) i32 {
        const block = registry.blocks[self.block_id];
        return block.min_state +
            @as(i32, @intFromEnum(self.facing)) * 16 +
            @as(i32, @intFromEnum(self.half)) * 8 +
            @as(i32, @intFromBool(!self.open)) * 4 +
            @as(i32, @intFromBool(!self.powered)) * 2 +
            @intFromBool(!self.waterlogged);
    }
};

pub const HingedBlocks = struct {
    pub const id = "minecraft:hinged_blocks";

    observed_mutation_sequence: u64 = 0,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    inputs: *input_store.Inputs,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, blocks: *block_store.Blocks, players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) !*HingedBlocks {
        const self = try allocator.create(HingedBlocks);
        self.* = .{ .blocks = blocks, .players = players, .inputs = inputs, .outputs = outputs };
        return self;
    }

    pub fn tick(self: *HingedBlocks, _: std.mem.Allocator) void {
        const blocks = self.blocks;
        const players = self.players;
        const inputs = self.inputs;
        const outputs = self.outputs;
        const writer = Writer.init(blocks, outputs);
        processRequests(blocks, players, inputs, outputs, writer);
        self.reconcileDoorRemoval(blocks, writer);
    }

    const Writer = block_writer.Writer;

    fn blockBaseName(block_state: i32) ?[]const u8 {
        const name = registry.blockStateName(block_state) orelse return null;
        return name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
    }

    fn hasBlockSuffix(block_state: i32, suffix: []const u8) bool {
        const name = blockBaseName(block_state) orelse return false;
        return std.mem.endsWith(u8, name, suffix);
    }

    fn decodeDoor(block_state: i32) ?Door {
        if (!hasBlockSuffix(block_state, "_door") or hasBlockSuffix(block_state, "_trapdoor")) return null;
        const state_index: usize = @intCast(block_state);
        if (state_index >= registry.block_state_to_block.len) return null;
        const block_id = registry.block_state_to_block[state_index];
        const block = registry.blocks[block_id];
        if (block.max_state - block.min_state != 63) return null;
        const state_offset: u6 = @intCast(block_state - block.min_state);
        return .{
            .block_id = block_id,
            .facing = @enumFromInt(state_offset / 16),
            .half = @enumFromInt((state_offset / 8) & 1),
            .hinge = @enumFromInt((state_offset / 4) & 1),
            .open = (state_offset & 2) == 0,
            .powered = (state_offset & 1) == 0,
        };
    }

    fn decodeTrapdoor(block_state: i32) ?Trapdoor {
        if (!hasBlockSuffix(block_state, "_trapdoor")) return null;
        const state_index: usize = @intCast(block_state);
        if (state_index >= registry.block_state_to_block.len) return null;
        const block_id = registry.block_state_to_block[state_index];
        const block = registry.blocks[block_id];
        if (block.max_state - block.min_state != 63) return null;
        const state_offset: u6 = @intCast(block_state - block.min_state);
        return .{
            .block_id = block_id,
            .facing = @enumFromInt(state_offset / 16),
            .half = @enumFromInt((state_offset / 8) & 1),
            .open = (state_offset & 4) == 0,
            .powered = (state_offset & 2) == 0,
            .waterlogged = (state_offset & 1) == 0,
        };
    }

    fn opensByHand(block_state: i32) bool {
        const name = blockBaseName(block_state) orelse return false;
        return !std.mem.eql(u8, name, "minecraft:iron_door") and
            !std.mem.eql(u8, name, "minecraft:iron_trapdoor");
    }

    fn opposite(direction: Direction) Direction {
        return switch (direction) {
            .north => .south,
            .south => .north,
            .west => .east,
            .east => .west,
        };
    }

    fn clockwise(direction: Direction) Direction {
        return switch (direction) {
            .north => .east,
            .east => .south,
            .south => .west,
            .west => .north,
        };
    }

    fn counterClockwise(direction: Direction) Direction {
        return clockwise(clockwise(clockwise(direction)));
    }

    fn offset(position: geometry.BlockPos, direction: Direction) geometry.BlockPos {
        var result = position;
        switch (direction) {
            .north => result.z -= 1,
            .south => result.z += 1,
            .west => result.x -= 1,
            .east => result.x += 1,
        }
        return result;
    }

    fn above(position: geometry.BlockPos) geometry.BlockPos {
        return .{ .x = position.x, .y = position.y + 1, .z = position.z };
    }

    fn below(position: geometry.BlockPos) geometry.BlockPos {
        return .{ .x = position.x, .y = position.y - 1, .z = position.z };
    }

    fn placementFacing(yaw: f32) Direction {
        const quadrant: i32 = @mod(@as(i32, @intFromFloat(@floor(yaw / 90.0 + 0.5))), 4);
        const toward_player: Direction = switch (quadrant) {
            0 => .north,
            1 => .east,
            2 => .south,
            3 => .west,
            else => unreachable,
        };
        return opposite(toward_player);
    }

    fn faceDirection(face: i32) ?Direction {
        return switch (face) {
            2 => .north,
            3 => .south,
            4 => .west,
            5 => .east,
            else => null,
        };
    }

    fn isFullCube(block_state: i32) bool {
        const boxes = collision.shapeBoxes(block_state);
        if (boxes.len != 1) return false;
        const box = boxes[0];
        return box.min_x == 0 and box.min_y == 0 and box.min_z == 0 and
            box.max_x == 64 and box.max_y == 64 and box.max_z == 64;
    }

    fn supportsDoor(block_state: i32) bool {
        return collision.hasFullSquareTopSupport(block_state);
    }

    fn isLowerDoor(block_state: i32) bool {
        const door = decodeDoor(block_state) orelse return false;
        return door.half == .lower;
    }

    fn doorHinge(blocks: *const block_store.Blocks, request: input_store.BlockRequest, facing: Direction) Hinge {
        const position = request.pos;
        const upper = above(position);
        const left_direction = counterClockwise(facing);
        const right_direction = clockwise(facing);
        const left = offset(position, left_direction);
        const upper_left = offset(upper, left_direction);
        const right = offset(position, right_direction);
        const upper_right = offset(upper, right_direction);
        const left_state = blocks.blockAt(request.world, left);
        const right_state = blocks.blockAt(request.world, right);
        var obstruction_score: i8 = 0;
        obstruction_score -= @intFromBool(isFullCube(left_state));
        obstruction_score -= @intFromBool(isFullCube(blocks.blockAt(request.world, upper_left)));
        obstruction_score += @intFromBool(isFullCube(right_state));
        obstruction_score += @intFromBool(isFullCube(blocks.blockAt(request.world, upper_right)));
        const left_door = isLowerDoor(left_state);
        const right_door = isLowerDoor(right_state);
        if ((left_door and !right_door) or obstruction_score > 0) return .right;
        if ((right_door and !left_door) or obstruction_score < 0) return .left;

        const hit_x = @as(f64, @floatFromInt(request.against_pos.x)) + request.cursor.x;
        const hit_z = @as(f64, @floatFromInt(request.against_pos.z)) + request.cursor.z;
        const local_x = hit_x - @as(f64, @floatFromInt(position.x));
        const local_z = hit_z - @as(f64, @floatFromInt(position.z));
        const right_hinge = switch (facing) {
            .west => local_z < 0.5,
            .east => local_z > 0.5,
            .north => local_x > 0.5,
            .south => local_x < 0.5,
        };
        return if (right_hinge) .right else .left;
    }

    fn canConsumeSelected(players: *const player_store.Players, slot: u16, block_state: i32) bool {
        const player = &players.records[slot];
        const stack = player.hotbar[player.selected_hotbar_slot];
        return !stack.isEmpty() and player_store.sameBlockType(player_store.playerPlacedBlockState(stack.block_state), block_state);
    }

    fn consumeSelected(players: *player_store.Players, slot: u16, block_state: i32) void {
        const player = &players.records[slot];
        const stack = &player.hotbar[player.selected_hotbar_slot];
        if (stack.isEmpty() or !player_store.sameBlockType(player_store.playerPlacedBlockState(stack.block_state), block_state)) return;
        stack.count -= 1;
        if (stack.count == 0) stack.* = .{};
    }

    fn rejectPlacement(players: *const player_store.Players, outputs: *Packets, request: input_store.BlockRequest) void {
        const player = &players.records[request.slot];
        outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
        outputs.block_correction(.{ .slot = request.slot, .pos = above(request.pos) });
        outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = player.selected_hotbar_slot });
    }

    fn placeDoor(blocks: *block_store.Blocks, players: *player_store.Players, outputs: *Packets, writer: Writer, request: input_store.BlockRequest, template: Door) void {
        const player = &players.records[request.slot];
        const upper_position = above(request.pos);
        const valid = player.gamemode != .adventure and player.gamemode != .spectator and
            player_store.validBuildY(request.pos.y) and player_store.validBuildY(upper_position.y) and
            player_store.playerCanReachBlock(player, request.pos) and
            blocks.blockAt(request.world, request.pos) == registry.block_air_default_state and
            blocks.blockAt(request.world, upper_position) == registry.block_air_default_state and
            supportsDoor(blocks.blockAt(request.world, below(request.pos))) and
            !player_store.playerIntersectsBlock(player, request.pos) and
            !player_store.playerIntersectsBlock(player, upper_position) and
            (player.gamemode == .creative or canConsumeSelected(players, request.slot, request.block_state));
        if (!valid) {
            rejectPlacement(players, outputs, request);
            return;
        }

        const facing = placementFacing(player.rotation.yaw);
        const hinge = doorHinge(blocks, request, facing);
        const lower = Door{
            .block_id = template.block_id,
            .facing = facing,
            .half = .lower,
            .hinge = hinge,
            .open = false,
            .powered = false,
        };
        var upper = lower;
        upper.half = .upper;
        var batch = writer.beginBatch();
        batch.set(request.world, request.pos, lower.state()) catch {
            rejectPlacement(players, outputs, request);
            return;
        };
        batch.set(request.world, upper_position, upper.state()) catch {
            rejectPlacement(players, outputs, request);
            return;
        };
        _ = batch.finish() catch {
            rejectPlacement(players, outputs, request);
            return;
        };
        if (player.gamemode != .creative) consumeSelected(players, request.slot, request.block_state);
        outputs.block_correction(.{ .slot = request.slot, .pos = request.against_pos });
        outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
        outputs.block_correction(.{ .slot = request.slot, .pos = upper_position });
        outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = player.selected_hotbar_slot });
    }

    fn toggleDoor(blocks: *block_store.Blocks, writer: Writer, world: world_identity.Handle, position: geometry.BlockPos, door: Door) void {
        const other_position = if (door.half == .lower) above(position) else below(position);
        const other = decodeDoor(blocks.blockAt(world, other_position)) orelse return;
        if (other.block_id != door.block_id or other.half == door.half) return;
        var clicked = door;
        clicked.open = !door.open;
        var counterpart = other;
        counterpart.open = clicked.open;
        var batch = writer.beginBatch();
        batch.set(world, position, clicked.state()) catch return;
        batch.set(world, other_position, counterpart.state()) catch return;
        _ = batch.finish() catch return;
    }

    fn toggleTrapdoor(writer: Writer, world: world_identity.Handle, position: geometry.BlockPos, trapdoor: Trapdoor) void {
        var toggled = trapdoor;
        toggled.open = !trapdoor.open;
        _ = writer.set(world, position, toggled.state()) catch {};
    }

    fn prepareTrapdoorPlacement(request: *input_store.BlockRequest, player: *const player_store.CorePlayer, template: Trapdoor) void {
        var placed = template;
        placed.open = false;
        placed.powered = false;
        placed.waterlogged = false;
        if (faceDirection(request.face)) |facing| {
            placed.facing = facing;
            placed.half = if (request.cursor.y > 0.5) .top else .bottom;
        } else {
            placed.facing = opposite(placementFacing(player.rotation.yaw));
            placed.half = if (request.face == 1) .bottom else .top;
        }
        request.block_state = placed.state();
    }

    fn processRequests(blocks: *block_store.Blocks, players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets, writer: Writer) void {
        for (0..inputs.block_request_count) |request_offset| {
            const request = &inputs.block_requests[request_offset];
            if (request.handled or request.kind != .use_item_on) continue;
            const player = &players.records[request.slot];
            const against_state = blocks.blockAt(request.world, request.against_pos);
            if (!player.sneaking and opensByHand(against_state)) {
                if (decodeDoor(against_state)) |door| {
                    request.handled = true;
                    toggleDoor(blocks, writer, request.world, request.against_pos, door);
                    continue;
                }
                if (decodeTrapdoor(against_state)) |trapdoor| {
                    request.handled = true;
                    toggleTrapdoor(writer, request.world, request.against_pos, trapdoor);
                    continue;
                }
            }
            if (decodeTrapdoor(request.block_state)) |trapdoor| {
                prepareTrapdoorPlacement(request, player, trapdoor);
                continue;
            }
            if (decodeDoor(request.block_state)) |door| {
                request.handled = true;
                placeDoor(blocks, players, outputs, writer, request.*, door);
            }
        }
    }

    fn reconcileDoorRemoval(self: *HingedBlocks, blocks: *block_store.Blocks, writer: Writer) void {
        const latest = blocks.blockMutationSequence();
        const pending = latest -% self.observed_mutation_sequence;
        if (pending > config.max_block_mutation_history) {
            self.observed_mutation_sequence = latest;
            return;
        }
        var sequence = self.observed_mutation_sequence;
        for (0..@as(usize, @intCast(pending))) |_| {
            sequence +%= 1;
            if (sequence == 0) sequence = 1;
            const mutation = blocks.blockMutation(sequence);
            const previous = decodeDoor(mutation.previous_state) orelse continue;
            if (decodeDoor(mutation.block_state) != null) continue;
            const counterpart_position = if (previous.half == .lower) above(mutation.pos) else below(mutation.pos);
            const counterpart = decodeDoor(blocks.blockAt(mutation.world, counterpart_position)) orelse continue;
            if (counterpart.block_id == previous.block_id and counterpart.half != previous.half)
                _ = writer.set(mutation.world, counterpart_position, registry.block_air_default_state) catch {};
        }
        self.observed_mutation_sequence = blocks.blockMutationSequence();
    }
};

test "door and trapdoor state codecs round trip every generated state" {
    var doors: usize = 0;
    var trapdoors: usize = 0;
    for (registry.block_state_names, 0..) |_, state| {
        if (HingedBlocks.decodeDoor(@intCast(state))) |door| {
            try std.testing.expectEqual(@as(i32, @intCast(state)), door.state());
            doors += 1;
        }
        if (HingedBlocks.decodeTrapdoor(@intCast(state))) |trapdoor| {
            try std.testing.expectEqual(@as(i32, @intCast(state)), trapdoor.state());
            trapdoors += 1;
        }
    }
    try std.testing.expect(doors >= 64);
    try std.testing.expect(trapdoors >= 64);
}

test "leaves are collision cubes but not door supports" {
    try std.testing.expect(HingedBlocks.isFullCube(registry.block_oak_leaves_default_state));
    try std.testing.expect(!HingedBlocks.supportsDoor(registry.block_oak_leaves_default_state));
    try std.testing.expect(HingedBlocks.supportsDoor(registry.block_stone_default_state));
    try std.testing.expect(HingedBlocks.supportsDoor(registry.blockStateId("minecraft:oak_slab[type=top,waterlogged=false]").?));
    try std.testing.expect(!HingedBlocks.supportsDoor(registry.blockStateId("minecraft:oak_slab[type=bottom,waterlogged=false]").?));
}
