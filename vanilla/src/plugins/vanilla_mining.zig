const std = @import("std");
const lightning_rod = @import("lightning_rod");
const registry = lightning_rod.registry_data;
const game_data = lightning_rod.game_data;
const Packets = lightning_rod.Packets;
const block_writer = lightning_rod.block_writer;
const container_menu = lightning_rod.container_menu;
const geometry = lightning_rod.geometry;
const block_store = lightning_rod.blocks;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const world_clock = lightning_rod.clock;
const block_destruction = @import("vanilla_block_destruction.zig");
const chests_plugin = @import("vanilla_chests.zig");
const furnaces_plugin = @import("vanilla_furnaces.zig");
const vanilla_collision_projection = @import("vanilla_collision_projection.zig");

pub const Mining = struct {
    pub const id = "minecraft:mining";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        clock: *world_clock.Clock,
        blocks: *block_store.Blocks,
        collision_projection: *vanilla_collision_projection.CollisionProjection,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        containers: *player_store.Containers,
        chests: *chests_plugin.Chests,
        furnaces: *furnaces_plugin.Furnaces,
        destruction: *block_destruction.BlockDestruction,
        outputs: *Packets,
    };

    const BlockChanges = block_writer.Writer;

    progress: []input_store.BlockDigProgress = &.{},
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*Mining {
        const self = try allocator.create(Mining);
        self.* = .{ .deps = deps };
        self.progress = try allocator.alloc(input_store.BlockDigProgress, deps.players.records.len);
        @memset(self.progress, .{});
        return self;
    }

    pub fn tick(self: *Mining, _: std.mem.Allocator) void {
        const clock = self.deps.clock;
        const blocks = self.deps.blocks;
        const players = self.deps.players;
        const inputs = self.deps.inputs;
        const containers = self.deps.containers;
        const outputs = self.deps.outputs;
        const block_changes = BlockChanges.init(blocks, outputs);
        self.applyPendingDigActions(clock, blocks, players, inputs, outputs);
        self.updateBlockDigs(clock, blocks, players, inputs, outputs);
        for (inputs.block_requests[0..inputs.block_request_count]) |request| {
            self.applyBlockRequest(
                blocks,
                players,
                containers,
                outputs,
                block_changes,
                request,
            );
        }
        inputs.block_request_count = 0;
    }

    fn applyPendingDigActions(
        self: *Mining,
        clock: *world_clock.Clock,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        outputs: *Packets,
    ) void {
        for (players.activeSlots()) |slot| {
            for (inputs.digActions(slot)) |action| switch (action) {
                .none => {},
                .cancel => |cancel| self.abortBlockDig(players, slot, cancel.pos, outputs),
                .start => |start| self.beginBlockDig(clock, blocks, players, inputs, outputs, slot, start.pos, start.face, start.sequence),
                .finish => |finish| self.finishBlockDig(clock, blocks, players, inputs, outputs, slot, finish.pos, finish.sequence),
            };
            inputs.clearDigActions(slot);
        }
    }

    fn beginBlockDig(
        self: *Mining,
        clock: *const world_clock.Clock,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        outputs: *Packets,
        slot: u16,
        pos: geometry.BlockPos,
        face: i32,
        sequence: i32,
    ) void {
        const player = &players.records[slot];
        if (!canMine(player, pos)) return;
        const current = blocks.blockAt(player.world, pos);
        if (current == registry.block_air_default_state) return;
        if (player.gamemode == .creative) {
            if (!enqueueBlockRequest(inputs, .{
                .world = player.world,
                .slot = slot,
                .kind = .break_block,
                .pos = pos,
                .face = face,
                .sequence = sequence,
            })) outputs.block_correction(.{ .slot = slot, .pos = pos });
            return;
        }
        const damage = blockDamagePerTick(self.deps.collision_projection, player, current);
        if (damage >= 1) {
            if (!enqueueBlockRequest(inputs, .{
                .world = player.world,
                .slot = slot,
                .kind = .break_block,
                .pos = pos,
                .face = face,
                .sequence = sequence,
            })) outputs.block_correction(.{ .slot = slot, .pos = pos });
            return;
        }
        const stage = blockBreakStage(damage);
        const progress = &self.progress[slot];
        if (progress.mining) outputs.block_correction(.{ .slot = slot, .pos = progress.pos });
        progress.mining = true;
        progress.world = player.world;
        progress.pos = pos;
        progress.face = face;
        progress.sequence = sequence;
        progress.start_tick = clock.tick;
        progress.damage = damage;
        progress.last_stage = stage;
        outputs.block_break_animation(.{ .world = player.world, .slot = slot, .pos = pos, .stage = stage });
    }

    fn finishBlockDig(
        self: *Mining,
        clock: *const world_clock.Clock,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        outputs: *Packets,
        slot: u16,
        pos: geometry.BlockPos,
        sequence: i32,
    ) void {
        const player = &players.records[slot];
        const progress = &self.progress[slot];
        if (!progress.mining or !progress.world.eql(player.world) or !geometry.sameBlock(progress.pos, pos)) return;
        progress.sequence = sequence;
        const current = blocks.blockAt(player.world, pos);
        if (current == registry.block_air_default_state) return;
        const elapsed = clock.tick -% progress.start_tick + 1;
        const damage = blockDamagePerTick(self.deps.collision_projection, player, current) * @as(f32, @floatFromInt(elapsed));
        progress.damage = damage;
        if (damage < 0.7) {
            if (!progress.failed_to_mine) {
                progress.mining = false;
                progress.failed_to_mine = true;
                progress.failed_world = progress.world;
                progress.failed_pos = progress.pos;
                progress.failed_face = progress.face;
                progress.failed_sequence = sequence;
                progress.failed_start_tick = progress.start_tick;
            }
            return;
        }
        if (!enqueueBlockRequest(inputs, blockRequest(progress.world, slot, progress.pos, progress.face, sequence))) return;
        progress.mining = false;
        outputs.block_break_animation(.{ .world = player.world, .slot = slot, .pos = pos, .stage = -1 });
    }

    fn updateBlockDigs(
        self: *Mining,
        clock: *const world_clock.Clock,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        outputs: *Packets,
    ) void {
        for (players.activeSlots()) |slot| {
            const progress = &self.progress[slot];
            const player = &players.records[slot];
            if (progress.failed_to_mine) {
                const current = blocks.blockAt(progress.failed_world, progress.failed_pos);
                if (current == registry.block_air_default_state) {
                    progress.failed_to_mine = false;
                    continue;
                }
                const elapsed = clock.tick -% progress.failed_start_tick + 2;
                const damage = blockDamagePerTick(self.deps.collision_projection, player, current) * @as(f32, @floatFromInt(elapsed));
                progress.damage = damage;
                const stage = blockBreakStage(damage);
                if (stage != progress.last_stage) {
                    progress.last_stage = stage;
                    outputs.block_break_animation(.{ .world = progress.failed_world, .slot = slot, .pos = progress.failed_pos, .stage = stage });
                }
                if (damage >= 1) {
                    if (!enqueueBlockRequest(inputs, blockRequest(progress.failed_world, slot, progress.failed_pos, progress.failed_face, progress.failed_sequence))) continue;
                    progress.failed_to_mine = false;
                }
                continue;
            }
            if (!progress.mining) continue;
            if (!progress.world.eql(player.world)) {
                progress.mining = false;
                outputs.block_break_animation(.{ .world = progress.world, .slot = slot, .pos = progress.pos, .stage = -1 });
                continue;
            }
            const current = blocks.blockAt(progress.world, progress.pos);
            if (current == registry.block_air_default_state or !player_store.playerCanReachBlock(player, progress.pos)) {
                progress.mining = false;
                progress.last_stage = -1;
                outputs.block_break_animation(.{ .world = progress.world, .slot = slot, .pos = progress.pos, .stage = -1 });
                continue;
            }
            const elapsed = clock.tick -% progress.start_tick + 2;
            const damage = blockDamagePerTick(self.deps.collision_projection, player, current) * @as(f32, @floatFromInt(elapsed));
            progress.damage = damage;
            const stage = blockBreakStage(damage);
            if (stage != progress.last_stage) {
                progress.last_stage = stage;
                outputs.block_break_animation(.{ .world = progress.world, .slot = slot, .pos = progress.pos, .stage = stage });
            }
        }
    }

    fn applyBlockRequest(
        self: *Mining,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        containers: *player_store.Containers,
        outputs: *Packets,
        block_changes: BlockChanges,
        request: input_store.BlockRequest,
    ) void {
        if (request.handled) return;
        const player = &players.records[request.slot];
        if (player.state != .play or !request.world.eql(player.world)) return;
        const current = blocks.blockAt(request.world, request.pos);
        if (self.openCraftingTable(blocks, players, containers, outputs, request)) return;
        if (player.gamemode == .adventure or player.gamemode == .spectator or
            !player_store.validBuildY(request.pos.y) or
            !player_store.playerCanReachBlock(player, request.pos))
        {
            outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
            return;
        }
        switch (request.kind) {
            .break_block => self.breakBlock(players, outputs, request, current),
            .use_item_on => self.placeBlock(blocks, players, outputs, block_changes, request, current),
        }
    }

    fn openCraftingTable(
        _: *Mining,
        blocks: *const block_store.Blocks,
        players: *player_store.Players,
        containers: *player_store.Containers,
        outputs: *Packets,
        request: input_store.BlockRequest,
    ) bool {
        if (request.kind != .use_item_on or
            blocks.blockAt(request.world, request.against_pos) != registry.block_crafting_table_default_state or
            players.records[request.slot].gamemode == .spectator or
            !player_store.validBuildY(request.against_pos.y) or
            !player_store.playerCanReachBlock(&players.records[request.slot], request.against_pos)) return false;
        container_menu.openCraftingTable(players, containers, request.slot, request.against_pos);
        outputs.container_opened(request.slot);
        return true;
    }

    fn breakBlock(
        self: *Mining,
        players: *player_store.Players,
        outputs: *Packets,
        request: input_store.BlockRequest,
        current: i32,
    ) void {
        if (current == registry.block_air_default_state) return;
        const player = &players.records[request.slot];
        const changed = self.deps.destruction.destroy(
            request.world,
            request.pos,
            selectedHotbarStack(player),
            player.gamemode == .creative,
        ) catch {
            outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
            return;
        };
        if (!changed or player.gamemode == .creative) return;
        if (damageSelectedItem(player)) |hotbar_slot|
            outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = hotbar_slot });
    }

    fn placeBlock(
        self: *Mining,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        outputs: *Packets,
        block_changes: BlockChanges,
        request: input_store.BlockRequest,
        current: i32,
    ) void {
        const player = &players.records[request.slot];
        const hotbar_slot = player.selected_hotbar_slot;
        if (!validPlacement(blocks, player, request, current)) {
            outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
            outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = hotbar_slot });
            return;
        }
        var chest_placement: ?chests_plugin.Chests.Placement = null;
        var furnace_placement: ?furnaces_plugin.Furnaces.Placement = null;
        if (isChest(request.block_state)) {
            chest_placement = self.deps.chests.reservePlacement(request.world, request.pos) catch {
                outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
                outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = hotbar_slot });
                return;
            };
        } else if (isFurnace(request.block_state)) {
            furnace_placement = self.deps.furnaces.reservePlacement(request.world, request.pos, request.block_state) catch {
                outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
                outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = hotbar_slot });
                return;
            };
        }
        outputs.block_correction(.{ .slot = request.slot, .pos = request.against_pos });
        const changed = block_changes.set(request.world, request.pos, request.block_state) catch {
            outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
            return;
        };
        if (changed) {
            if (chest_placement) |placement| self.deps.chests.commitPlacement(placement);
            if (furnace_placement) |placement| self.deps.furnaces.commitPlacement(placement);
            if (player.gamemode != .creative) consumeSelectedBlock(player, request.block_state);
            outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
        }
        outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = hotbar_slot });
    }

    fn abortBlockDig(self: *Mining, players: *const player_store.Players, slot: u16, pos: geometry.BlockPos, outputs: *Packets) void {
        const progress = &self.progress[slot];
        progress.mining = false;
        const world = players.records[slot].world;
        if (!geometry.sameBlock(progress.pos, pos))
            outputs.block_break_animation(.{ .world = world, .slot = slot, .pos = progress.pos, .stage = -1 });
        outputs.block_break_animation(.{ .world = world, .slot = slot, .pos = pos, .stage = -1 });
    }

    fn enqueueBlockRequest(inputs: *input_store.Inputs, request: input_store.BlockRequest) bool {
        inputs.enqueueBlockRequest(request) catch return false;
        return true;
    }

    fn blockRequest(world: lightning_rod.world_identity.Handle, slot: u16, pos: geometry.BlockPos, face: i32, sequence: i32) input_store.BlockRequest {
        return .{
            .world = world,
            .slot = slot,
            .kind = .break_block,
            .pos = pos,
            .face = face,
            .sequence = sequence,
        };
    }

    fn canMine(player: *const player_store.CorePlayer, pos: geometry.BlockPos) bool {
        return player.state == .play and
            player.gamemode != .adventure and
            player.gamemode != .spectator and
            player_store.validBuildY(pos.y) and
            player_store.playerCanReachBlock(player, pos);
    }

    fn blockDamagePerTick(projection: *vanilla_collision_projection.CollisionProjection, player: *const player_store.CorePlayer, block_state: i32) f32 {
        var damage = game_data.blockDamagePerTick(block_state, selectedHotbarStack(player).item_id);
        const eye = geometry.BlockPos{
            .x = geometry.blockCoord(player.position.x),
            .y = @intCast(geometry.blockCoord(player.position.y + 1.62)),
            .z = geometry.blockCoord(player.position.z),
        };
        const eye_state = projection.blockState(player.world, eye) orelse registry.block_air_default_state;
        if (eye_state == registry.state_water_level_0 or registry.stateIsWaterlogged(eye_state)) damage /= 5;
        if (!player.on_ground) damage /= 5;
        return damage;
    }

    fn validPlacement(blocks: *const block_store.Blocks, player: *const player_store.CorePlayer, request: input_store.BlockRequest, current: i32) bool {
        if (request.block_state == registry.block_air_default_state or
            !player_store.validBuildY(request.against_pos.y) or
            blocks.blockAt(request.world, request.against_pos) == registry.block_air_default_state or
            current != registry.block_air_default_state or
            player_store.playerIntersectsBlockState(player, request.pos, request.block_state)) return false;
        return player.gamemode == .creative or canConsumeSelectedBlock(player, request.block_state);
    }

    fn selectedHotbarStack(player: *const player_store.CorePlayer) player_store.HotbarStack {
        return player.hotbar[player.selected_hotbar_slot];
    }

    fn canConsumeSelectedBlock(player: *const player_store.CorePlayer, block_state: i32) bool {
        const stack = selectedHotbarStack(player);
        return !stack.isEmpty() and
            player_store.sameBlockType(player_store.playerPlacedBlockState(stack.block_state), block_state);
    }

    fn isChest(block_state: i32) bool {
        return block_state >= 0 and block_state < registry.block_state_to_block.len and
            registry.block_state_to_block[@intCast(block_state)] == registry.block_chest_id;
    }

    fn isFurnace(block_state: i32) bool {
        return block_state >= 0 and block_state < registry.block_state_to_block.len and
            registry.block_state_to_block[@intCast(block_state)] == registry.block_furnace_id;
    }

    fn consumeSelectedBlock(player: *player_store.CorePlayer, block_state: i32) void {
        const stack = &player.hotbar[player.selected_hotbar_slot];
        std.debug.assert(!stack.isEmpty());
        std.debug.assert(player_store.sameBlockType(player_store.playerPlacedBlockState(stack.block_state), block_state));
        stack.count -= 1;
        if (stack.count == 0) stack.* = .{};
    }

    fn damageSelectedItem(player: *player_store.CorePlayer) ?u4 {
        const hotbar_slot = player.selected_hotbar_slot;
        const stack = &player.hotbar[hotbar_slot];
        if (stack.isEmpty()) return null;
        const maximum = game_data.maxDurability(stack.item_id);
        if (maximum == 0) return null;
        stack.damage +|= 1;
        if (stack.damage >= maximum) stack.* = .{};
        return hotbar_slot;
    }
};

fn blockBreakStage(damage: f32) i8 {
    if (!std.math.isFinite(damage) or damage <= 0) return 0;
    return @intFromFloat(@min(@as(f32, std.math.maxInt(i8)), damage * 10));
}
