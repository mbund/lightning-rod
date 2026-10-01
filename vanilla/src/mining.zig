const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const block_sync = @import("block_sync.zig");
const block_actions = @import("block_actions.zig");
const chunks = @import("chunks");
const minecraft = @import("minecraft_model");
const registry = @import("game_data").registry;
const inventories = @import("inventories");
const sessions = @import("sessions");
const worlds = @import("worlds");

const Chunks = chunks.Chunks;
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;
const Items = @import("items.zig").Items;
const Durability = @import("item_properties.zig").Durability;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const BlockLoot = @import("block_loot.zig").BlockLoot;
const ItemEntities = @import("item_entities.zig").ItemEntities;

const assert = std.debug.assert;

pub const Mining = struct {
    pub const id = "minecraft:mining";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *Players,
        input: *Input,
        inventories: *inventories.Inventories,
        items: *Items,
        durability: *Durability,
        worlds: *worlds.Worlds,
        chunks: *Chunks,
        menus: *PlayerInventory,
        loot: *BlockLoot,
        dropped: *ItemEntities,
        blocks: *block_sync.BlockSynchronization,
        actions: *block_actions.BlockActions,
    };

    const State = struct {
        generation: u32 = 0,
        teleport_id: i32 = 0,
        position: minecraft.BlockPosition = .{ .x = 0, .y = 0, .z = 0 },
        started: u64 = 0,
        active: bool = false,
        finishing: bool = false,
        complete: bool = false,
        stage: i8 = -1,
        sequence: i32 = -1,
        selected_slot: u4 = 0,
        visible: bool = false,
    };

    const Seen = struct {
        generation: u32 = 0,
        life: u32 = 0,
        position: minecraft.BlockPosition = .{ .x = 0, .y = 0, .z = 0 },
        stage: i8 = -1,
    };

    deps: Dependencies,
    states: []State,
    seen: []Seen,
    random: std.Random.DefaultPrng = .init(0),

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Mining {
        const self = try allocator.create(Mining);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        const seen = try allocator.alloc(Seen, states.len * states.len);
        @memset(seen, .{});
        self.* = .{ .deps = deps, .states = states, .seen = seen };
        try deps.players.observeDig(self, onDig);
        try deps.input.on(.arm_animation, self, onSwing);
        return self;
    }

    fn onSwing(self: *Mining, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_arm_animation.Reader) !void {
        const hand, const done = body.hand() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const players = self.deps.players;
        const player = players.records[handle.index];
        if (player.stage != .ready) return;
        for (players.records, 0..) |observer, other| {
            const recipient = observer.handle orelse continue;
            if (other == handle.index or observer.world != player.world or observer.stage != .ready) continue;
            _ = players.sendPacket(writeAnimation, observer.protocol, &.{recipient}, .{ @as(i32, @intCast(handle.index + 1)), @as(u8, if (hand == 0) 0 else 3) });
        }
    }

    fn onDig(self: *Mining, handle: sessions.Handle, dig: minecraft.Dig) !void {
        const action = dig.action;
        const position = dig.position;
        const sequence = dig.sequence;
        const players = self.deps.players;
        const player = players.records[handle.index];
        if (player.stage != .ready or player.health == 0) return;
        const state = &self.states[handle.index];
        if (state.generation != handle.generation or state.teleport_id != player.teleport_id)
            state.* = .{ .generation = handle.generation, .teleport_id = player.teleport_id, .selected_slot = player.selected_slot, .visible = state.visible };
        state.selected_slot = player.selected_slot;
        state.sequence = @max(state.sequence, sequence);
        if (action == .cancel) {
            state.active = false;
            state.finishing = false;
            state.complete = false;
            state.stage = -1;
            return;
        }
        if (action != .start and action != .finish) return;
        if (player.gamemode == .spectator or player.gamemode == .adventure) return;
        const dimension = self.deps.worlds.get(player.world).?.dimension;
        const minimum_y = dimension.minimumSection() * 16;
        if (position.y < minimum_y or position.y >= minimum_y + @as(i32, @intCast(dimension.sectionCount() * 16))) return;
        const dx = player.position.x - (@as(f64, @floatFromInt(position.x)) + 0.5);
        const dy = player.position.y + 1.62 - (@as(f64, @floatFromInt(position.y)) + 0.5);
        const dz = player.position.z - (@as(f64, @floatFromInt(position.z)) + 0.5);
        if (dx * dx + dy * dy + dz * dz > 36) return;
        const block = try self.deps.chunks.getBlock(player.world, .{ .x = position.x, .y = position.y, .z = position.z });
        if (block == 0 or block >= registry.block_state_to_block.len) return;
        const info = registry.blocks[registry.block_state_to_block[block]];
        if (!info.diggable or info.hardness < 0) return;
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 + @as(u16, player.selected_slot) };
        const held = try self.deps.inventories.get(slot);
        const loot = try self.deps.loot.evaluate(block, held.stack);
        const delta = if (info.hardness == 0) std.math.inf(f32) else loot.speed / info.hardness / @as(f32, if (loot.harvest) 30 else 100) / @as(f32, if (player.on_ground) 1 else 5);
        const current_tick = players.ticks + 1;
        if (action == .start) {
            state.position = .{ .x = position.x, .y = position.y, .z = position.z };
            state.started = current_tick;
            state.active = true;
            state.finishing = false;
            state.complete = player.gamemode == .creative or delta >= 1;
        } else if (state.active and std.meta.eql(state.position, minecraft.BlockPosition{ .x = position.x, .y = position.y, .z = position.z })) {
            state.complete = delta * @as(f32, @floatFromInt(current_tick - state.started + 1)) >= 0.7;
            state.finishing = !state.complete;
        }
    }

    pub fn tick(self: *Mining) !void {
        const players = self.deps.players;

        for (players.records, self.states, 0..) |player, *state, index| {
            if (player.handle == null or player.stage != .ready or player.health == 0) {
                state.active = false;
                state.stage = -1;
                continue;
            }

            const handle = player.handle.?;

            if (state.generation != handle.generation or state.teleport_id != player.teleport_id)
                state.* = .{
                    .generation = handle.generation,
                    .teleport_id = player.teleport_id,
                    .selected_slot = player.selected_slot,
                    .visible = state.visible,
                };

            if (state.sequence >= 0 and self.deps.blocks.observers[index].pending == 0 and players.sendBlockAck(player.protocol, &.{handle}, state.sequence))
                state.sequence = -1;
            state.selected_slot = player.selected_slot;
            if (!state.active and state.stage == -1) continue;
            const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 + @as(u16, state.selected_slot) };
            const held = try self.deps.inventories.get(slot);
            var complete = state.complete;

            var stage: i8 = -1;
            if (state.active) {
                const position: chunks.Position = .{ .x = state.position.x, .y = state.position.y, .z = state.position.z };
                const block = try self.deps.chunks.getBlock(player.world, position);

                if (block == 0) state.active = false else {
                    const info = registry.blocks[registry.block_state_to_block[block]];
                    const loot = try self.deps.loot.evaluate(block, held.stack);
                    const progress = if (info.hardness < 0) @as(f32, 0) else if (info.hardness == 0) @as(f32, 1) else loot.speed / info.hardness / @as(f32, if (loot.harvest) 30 else 100) / @as(f32, if (player.on_ground) 1 else 5) * @as(f32, @floatFromInt(players.ticks - state.started + 1));
                    complete = complete or (state.finishing and progress >= 1);
                    stage = @intFromFloat(@min(9, @floor(progress * 10)));
                    if (complete) {
                        var worn = held.stack;

                        if (player.gamemode != .creative) {
                            if (held.stack) |tool| {
                                if (info.hardness != 0) worn = try self.deps.durability.wear(tool, 1);
                            }

                            if (loot.stack) |stack| {
                                const random = self.random.random();
                                _ = try self.deps.dropped.create(player.world, .{
                                    @as(f64, @floatFromInt(position.x)) + 0.25 + random.float(f64) * 0.5,
                                    @as(f64, @floatFromInt(position.y)) + 0.25 + random.float(f64) * 0.5 - 0.125,
                                    @as(f64, @floatFromInt(position.z)) + 0.25 + random.float(f64) * 0.5,
                                }, .{ random.float(f64) * 0.2 - 0.1, 0.2, random.float(f64) * 0.2 - 0.1 }, stack);
                            }
                        }

                        const removed = try self.deps.actions.apply(.{
                            .action = .remove,
                            .player = &player,
                            .position = position,
                            .state = block,
                        });
                        assert(removed != .denied);

                        if (removed == .pass) try self.deps.chunks.setBlock(player.world, position, 0);

                        if (!std.meta.eql(worn, held.stack)) {
                            const committed = try self.deps.inventories.set(slot, held.revision, worn);
                            assert(committed);
                            self.deps.menus.changed(index);
                        }

                        for (players.records, 0..) |observer, other| {
                            const recipient = observer.handle orelse continue;
                            if (other == index or observer.world != player.world or observer.stage != .ready) continue;
                            _ = players.sendPacket(writeWorldEvent, observer.protocol, &.{recipient}, .{ state.position, block });
                        }

                        state.active = false;
                        state.finishing = false;
                        state.complete = false;
                        stage = -1;
                    }
                }
            }

            state.stage = stage;
        }

        for (self.states, 0..) |*state, index| {
            if (!state.active and !state.visible) continue;

            const row = self.seen[index * self.states.len ..][0..self.states.len];

            for (players.records, row, 0..) |observer, *seen, other| {
                const recipient = observer.handle orelse {
                    seen.* = .{};
                    continue;
                };

                if (seen.generation != recipient.generation or seen.life != observer.life)
                    seen.* = .{ .generation = recipient.generation, .life = observer.life };

                if (other == index or observer.stage != .ready) continue;

                const same_world = observer.world == players.records[index].world;
                if (seen.stage >= 0 and (!same_world or state.stage < 0 or !std.meta.eql(seen.position, state.position))) {
                    if (!players.sendPacket(writeBlockProgress, observer.protocol, &.{recipient}, .{
                        @as(i32, @intCast(index + 1)), seen.position, @as(i8, -1),
                    }))
                        continue;
                    seen.stage = -1;
                }

                if (!same_world) continue;
                if (state.stage >= 0 and state.stage != seen.stage) {
                    if (!players.sendPacket(writeBlockProgress, observer.protocol, &.{recipient}, .{
                        @as(i32, @intCast(index + 1)), state.position, state.stage,
                    }))
                        continue;
                    seen.position = state.position;
                    seen.stage = state.stage;
                }
            }

            state.visible = false;

            for (row) |seen| state.visible = state.visible or seen.stage >= 0;
        }
    }

    fn writeAnimation(packet: wire_1_21_5.play.toClient.packet_animation.Writer, entity: i32, animation: u8) ![]u8 {
        return (try (try packet.entityId(entity)).animation(animation)).finish();
    }

    fn writeWorldEvent(cursor: wire_1_21_5.play.toClient.packet_world_event.Writer, mapping: packets.Registry, position: minecraft.BlockPosition, block: u32) ![]u8 {
        const packet = try cursor.effectId(2001);
        const located = try packet.location(.{ .x = @intCast(position.x), .y = @intCast(position.y), .z = @intCast(position.z) });
        return (try (try located.data(try mapping.blockState(@intCast(block)))).global(false)).finish();
    }

    fn writeBlockProgress(cursor: wire_1_21_5.play.toClient.packet_block_break_animation.Writer, entity: i32, position: minecraft.BlockPosition, stage: i8) ![]u8 {
        const packet = try cursor.entityId(entity);
        const located = try packet.location(.{ .x = @intCast(position.x), .y = @intCast(position.y), .z = @intCast(position.z) });
        return (try located.destroyStage(stage)).finish();
    }
};
