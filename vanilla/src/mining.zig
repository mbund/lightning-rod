const std = @import("std");
const block_sync = @import("block_sync.zig");
const block_actions = @import("block_actions.zig");
const chunks = @import("chunks");
const minecraft = @import("minecraft");
const registry = @import("protocols").registry;
const inventories = @import("inventories");

const Chunks = chunks.Chunks;
const Players = @import("players.zig").Players;
const Menus = @import("menus.zig").Menus;
const BlockLoot = @import("block_loot.zig").BlockLoot;
const ItemEntities = @import("item_entities.zig").ItemEntities;

const assert = std.debug.assert;

pub const Mining = struct {
    pub const id = "minecraft:mining";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *Players,
        chunks: *Chunks,
        menus: *Menus,
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
        return self;
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

            if (state.sequence >= 0 and self.deps.blocks.observers[index].pending == 0 and players.send(player.protocol, &.{handle}, .{ .block_ack = state.sequence }))
                state.sequence = -1;
            const events = players.deps.input.values(handle);
            if (events.len == 0 and !state.active and state.stage == -1) continue;

            for (0..events.len + 1) |event_index| {
                if (event_index < events.len and events[event_index] == .held_slot) {
                    const selected = events[event_index].held_slot;

                    if (selected >= 0 and selected < 9) state.selected_slot = @intCast(selected);
                    continue;
                }

                if (event_index < events.len and events[event_index] != .dig and events[event_index] != .swing) continue;
                if (event_index == events.len and !state.active and state.stage == -1) continue;

                const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 + @as(u16, state.selected_slot) };
                const held = try self.deps.menus.deps.inventories.get(slot);
                var complete = false;
                if (event_index < events.len) {
                    const event = events[event_index];
                    if (event == .swing) {
                        for (players.records, 0..) |observer, other| {
                            const recipient = observer.handle orelse continue;
                            if (other == index or observer.world != player.world or observer.stage != .ready) continue;
                            _ = players.send(observer.protocol, &.{recipient}, .{ .animation = .{
                                .entity = @intCast(index + 1),
                                .animation = if (event.swing == 0) 0 else 3,
                            } });
                        }
                    }

                    if (event != .dig) continue;

                    const dig = event.dig;
                    state.sequence = @max(state.sequence, dig.sequence);
                    if (dig.action == .cancel) {
                        state.active = false;
                        state.finishing = false;
                        state.stage = -1;
                        continue;
                    }

                    if (dig.action != .start and dig.action != .finish) continue;
                    if (player.gamemode == .spectator or player.gamemode == .adventure) continue;

                    const dimension = players.deps.worlds.get(player.world).?.dimension;
                    const minimum_y = dimension.minimumSection() * 16;
                    if (dig.position.y < minimum_y or dig.position.y >= minimum_y + @as(i32, @intCast(dimension.sectionCount() * 16))) continue;

                    const dx = player.position.x - (@as(f64, @floatFromInt(dig.position.x)) + 0.5);
                    const dy = player.position.y + 1.62 - (@as(f64, @floatFromInt(dig.position.y)) + 0.5);
                    const dz = player.position.z - (@as(f64, @floatFromInt(dig.position.z)) + 0.5);
                    if (dx * dx + dy * dy + dz * dz > 36) continue;

                    const block = try self.deps.chunks.getBlock(player.world, .{ .x = dig.position.x, .y = dig.position.y, .z = dig.position.z });
                    if (block == 0 or block >= registry.block_state_to_block.len) continue;

                    const info = registry.blocks[registry.block_state_to_block[block]];
                    if (!info.diggable or info.hardness < 0) continue;

                    const loot = try self.deps.loot.evaluate(block, held.stack);
                    const delta = if (info.hardness == 0) std.math.inf(f32) else loot.speed / info.hardness / @as(f32, if (loot.harvest) 30 else 100) / @as(f32, if (player.on_ground) 1 else 5);

                    if (dig.action == .start) {
                        state.position = dig.position;
                        state.started = players.ticks;
                        state.active = true;
                        state.finishing = false;
                        complete = player.gamemode == .creative or delta >= 1;
                    } else if (state.active and std.meta.eql(state.position, dig.position)) {
                        complete = delta * @as(f32, @floatFromInt(players.ticks - state.started + 1)) >= 0.7;
                        state.finishing = !complete;
                    }
                }

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
                                    const tool_info = try self.deps.loot.deps.items.describe(tool);

                                    if (info.hardness != 0 and self.random.random().uintLessThan(u32, @intCast(tool_info.unbreaking + 1)) == 0)
                                        worn = try self.deps.loot.deps.items.wear(tool, 1);
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
                                const committed = try self.deps.menus.deps.inventories.set(slot, held.revision, worn);
                                assert(committed);
                                self.deps.menus.changed(index);
                            }

                            for (players.records, 0..) |observer, other| {
                                const recipient = observer.handle orelse continue;
                                if (other == index or observer.world != player.world or observer.stage != .ready) continue;
                                _ = players.send(observer.protocol, &.{recipient}, .{ .world_event = .{ .event = 2001, .position = state.position, .data = block } });
                            }

                            state.active = false;
                            state.finishing = false;
                            stage = -1;
                        }
                    }
                }

                state.stage = stage;
            }
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
                    if (!players.send(observer.protocol, &.{recipient}, .{ .block_progress = .{
                        .entity = @intCast(index + 1),
                        .position = seen.position,
                        .stage = -1,
                    } }))
                        continue;
                    seen.stage = -1;
                }

                if (!same_world) continue;
                if (state.stage >= 0 and state.stage != seen.stage) {
                    if (!players.send(observer.protocol, &.{recipient}, .{ .block_progress = .{
                        .entity = @intCast(index + 1),
                        .position = state.position,
                        .stage = state.stage,
                    } }))
                        continue;
                    seen.position = state.position;
                    seen.stage = state.stage;
                }
            }

            state.visible = false;

            for (row) |seen| state.visible = state.visible or seen.stage >= 0;
        }
    }
};
