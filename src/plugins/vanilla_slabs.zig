const lightning_rod = @import("lightning_rod");
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const std = @import("std");
const registry = lightning_rod.registry_data;
const block_writer = lightning_rod.block_writer;
const Packets = lightning_rod.Packets;

const BlockWriter = block_writer.Writer;

pub const Slabs = struct {
    pub const id = "minecraft:slabs";

    blocks: *block_store.Blocks,
    players: *player_store.Players,
    inputs: *input_store.Inputs,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, blocks: *block_store.Blocks, players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) !*Slabs {
        const self = try allocator.create(Slabs);
        self.* = .{ .blocks = blocks, .players = players, .inputs = inputs, .outputs = outputs };
        return self;
    }

    const SlabType = enum(u2) { top, bottom, double };

    const Slab = struct {
        block_id: u16,
        slab_type: SlabType,
        waterlogged: bool,

        fn state(self: Slab) i32 {
            return registry.blocks[self.block_id].min_state +
                @as(i32, @intFromEnum(self.slab_type)) * 2 +
                @intFromBool(!self.waterlogged);
        }
    };

    pub fn tick(self: *Slabs, _: std.mem.Allocator) void {
        const blocks = self.blocks;
        const players = self.players;
        const inputs = self.inputs;
        const outputs = self.outputs;
        const writer = BlockWriter.init(blocks, outputs);
        for (inputs.block_requests[0..inputs.block_request_count]) |*request| {
            if (request.handled or request.kind != .use_item_on) continue;
            const template = decodeSlab(request.block_state) orelse continue;
            if (decodeSlab(blocks.blockAt(request.world, request.against_pos))) |existing| {
                if (existing.block_id == template.block_id and shouldMerge(existing, request.*)) {
                    request.handled = true;
                    mergeSlab(players, outputs, writer, request.*, existing);
                    continue;
                }
            }
            var placed = template;
            placed.slab_type = placementType(request.*);
            placed.waterlogged = false;
            request.block_state = placed.state();
        }
    }

    fn blockBaseName(block_state: i32) ?[]const u8 {
        const name = registry.blockStateName(block_state) orelse return null;
        return name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
    }

    fn decodeSlab(block_state: i32) ?Slab {
        const name = blockBaseName(block_state) orelse return null;
        if (!std.mem.endsWith(u8, name, "_slab")) return null;
        const state_index: usize = @intCast(block_state);
        if (state_index >= registry.block_state_to_block.len) return null;
        const block_id = registry.block_state_to_block[state_index];
        const block = registry.blocks[block_id];
        if (block.max_state - block.min_state != 5) return null;
        const state_offset: u3 = @intCast(block_state - block.min_state);
        return .{
            .block_id = block_id,
            .slab_type = @enumFromInt(state_offset / 2),
            .waterlogged = (state_offset & 1) == 0,
        };
    }

    fn isHorizontalFace(face: i32) bool {
        return face >= 2 and face <= 5;
    }

    fn shouldMerge(existing: Slab, request: input_store.BlockRequest) bool {
        return switch (existing.slab_type) {
            .bottom => request.face == 1 or (isHorizontalFace(request.face) and request.cursor.y > 0.5),
            .top => request.face == 0 or (isHorizontalFace(request.face) and request.cursor.y <= 0.5),
            .double => false,
        };
    }

    fn placementType(request: input_store.BlockRequest) SlabType {
        if (request.face == 0 or (isHorizontalFace(request.face) and request.cursor.y > 0.5)) return .top;
        return .bottom;
    }

    fn canConsumeSelected(players: *const player_store.Players, slot: u16, block_state: i32) bool {
        const player = &players.records[slot];
        const stack = player.hotbar[player.selected_hotbar_slot];
        return !stack.isEmpty() and player_store.sameBlockType(player_store.playerPlacedBlockState(stack.block_state), block_state);
    }

    fn consumeSelected(players: *player_store.Players, slot: u16, block_state: i32) void {
        const player = &players.records[slot];
        const stack = &player.hotbar[player.selected_hotbar_slot];
        std.debug.assert(!stack.isEmpty());
        std.debug.assert(player_store.sameBlockType(player_store.playerPlacedBlockState(stack.block_state), block_state));
        stack.count -= 1;
        if (stack.count == 0) stack.* = .{};
    }

    fn rejectMerge(players: *const player_store.Players, outputs: *Packets, request: input_store.BlockRequest) void {
        const player = &players.records[request.slot];
        outputs.block_correction(.{ .slot = request.slot, .pos = request.against_pos });
        outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = player.selected_hotbar_slot });
    }

    fn mergeSlab(
        players: *player_store.Players,
        outputs: *Packets,
        writer: BlockWriter,
        request: input_store.BlockRequest,
        existing: Slab,
    ) void {
        const player = &players.records[request.slot];
        var merged = existing;
        merged.slab_type = .double;
        merged.waterlogged = false;
        const valid = player.gamemode != .adventure and player.gamemode != .spectator and
            player_store.validBuildY(request.against_pos.y) and
            player_store.playerCanReachBlock(player, request.against_pos) and
            !player_store.playerIntersectsBlockState(player, request.against_pos, merged.state()) and
            (player.gamemode == .creative or canConsumeSelected(players, request.slot, request.block_state));
        if (!valid) {
            rejectMerge(players, outputs, request);
            return;
        }
        const changed = writer.set(request.world, request.against_pos, merged.state()) catch {
            rejectMerge(players, outputs, request);
            return;
        };
        if (changed and player.gamemode != .creative)
            consumeSelected(players, request.slot, request.block_state);
        outputs.block_correction(.{ .slot = request.slot, .pos = request.against_pos });
        outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = player.selected_hotbar_slot });
    }
};

test "slab state codec round trips every generated slab" {
    var count: usize = 0;
    for (registry.block_state_names, 0..) |_, state| {
        const slab = Slabs.decodeSlab(@intCast(state)) orelse continue;
        try std.testing.expectEqual(@as(i32, @intCast(state)), slab.state());
        count += 1;
    }
    try std.testing.expect(count >= 62 * 6);
}

test "slab placement and merge select the vanilla halves" {
    const template = Slabs.decodeSlab(registry.blockStateId("minecraft:oak_slab[type=bottom,waterlogged=false]").?).?;
    const bottom = Slabs.Slab{ .block_id = template.block_id, .slab_type = .bottom, .waterlogged = false };
    const top = Slabs.Slab{ .block_id = template.block_id, .slab_type = .top, .waterlogged = false };
    const base = input_store.BlockRequest{
        .slot = 0,
        .kind = .use_item_on,
        .pos = .{ .x = 0, .y = 0, .z = 0 },
        .against_pos = .{ .x = 0, .y = 0, .z = 0 },
        .block_state = template.state(),
        .face = 1,
        .cursor = .{ .x = 0.5, .y = 0.5, .z = 0.5 },
        .sequence = 0,
    };
    try std.testing.expectEqual(Slabs.SlabType.bottom, Slabs.placementType(base));
    try std.testing.expect(Slabs.shouldMerge(bottom, base));
    var down = base;
    down.face = 0;
    try std.testing.expectEqual(Slabs.SlabType.top, Slabs.placementType(down));
    try std.testing.expect(Slabs.shouldMerge(top, down));
    var high_side = base;
    high_side.face = 2;
    high_side.cursor.y = 0.75;
    try std.testing.expectEqual(Slabs.SlabType.top, Slabs.placementType(high_side));
    try std.testing.expect(Slabs.shouldMerge(bottom, high_side));
}
