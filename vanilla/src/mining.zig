const EnchantmentRegistry = @import("enchantment_registry.zig").EnchantmentRegistry;
const MiningRegistry = @import("mining_registry.zig").MiningRegistry;
const loot_tables = @import("loot.zig");
const item_data = @import("item_data.zig");
const sparse_sets = @import("lightning_rod").system.sparse_sets;
const SpatialIndex = @import("player_spatial.zig").Index;
const SpatialGroups = @import("player_spatial.zig").Groups;
const IndexSet = @import("lightning_rod").system.IndexSet;
const audience_storage = @import("audience.zig");
const Visibility = @import("visibility.zig").Visibility;
const game_data = @import("game_data");
const std = @import("std");
const metrics = @import("metrics");
const wire_1_21_5 = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const block_sync = @import("block_sync.zig");
const block_actions = @import("block_actions.zig");
const entities = @import("entities");
const chunks = @import("chunks");
const minecraft = @import("minecraft_model");
const inventories = @import("inventories");
const sessions = @import("sessions");
const worlds = @import("worlds");
const storage = @import("storage");
const Random = @import("random.zig").Random;
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;
const Items = @import("items.zig").Items;
const Durability = @import("item_properties.zig").Durability;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const BlockLoot = @import("block_loot.zig").BlockLoot;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const Experience = @import("experience.zig").Experience;

const Chunks = chunks.Chunks;

const Blocks = @import("blocks.zig").Blocks;
const EquipmentAttributes = @import("equipment_attributes.zig").EquipmentAttributes;

const assert = std.debug.assert;

pub const Mining = struct {
    pub const Registry = MiningRegistry;
    pub const id = "minecraft:mining";

    pub const Configuration = struct { seed: u64 = 0, audience_words: usize = 4096, loot_scratch_bytes: usize = 64 * 1024 };

    pub const Dependencies = struct {
        enchantments: *EnchantmentRegistry,
        attributes: *EquipmentAttributes,
        block_definitions: *Blocks,
        definitions: *Registry,
        visibility: *Visibility,
        metrics: *metrics.Registry,
        storage: storage.Space,
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
        experience: *Experience,
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
        tool: BlockLoot.Tool = .{},
    };

    const View = struct {
        valid: bool = false,
        visibility_revision: u64 = 0,
        interested: audience_storage.Row = .{},
        watchers: audience_storage.Row = .{},
        current: audience_storage.Row = .{},
        pending: audience_storage.Row = .{},
        stage: i8 = -1,
        position: minecraft.BlockPosition = .{ .x = 0, .y = 0, .z = 0 },
    };

    const Observer = struct {
        generation: u32 = 0,
        life: u32 = 0,
        world: u32 = 0,
        ready: bool = false,
        cell: [2]i64 = @splat(0),
    };

    deps: Dependencies,
    actors: IndexSet,
    spatial_changes: SpatialIndex,
    neighborhoods: SpatialGroups,
    states: []State,
    views: []View,
    observers: []Observer,
    render_distance: i32 = 0,
    observer_checks: metrics.Counter,
    pair_checks: metrics.Counter,
    audience_checks: metrics.Counter,
    random: Random,
    loot_scratch: std.heap.FixedBufferAllocator,
    selections: audience_storage.Matrix,
    scratch: sparse_sets.Workspace,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Mining {
        const self = try allocate(allocator, configuration, deps);
        self.random = try .init(configuration.seed, deps.storage);
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Mining {
        const self = try allocator.create(Mining);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        const views = try allocator.alloc(View, states.len);
        @memset(views, .{});
        const observers = try allocator.alloc(Observer, states.len);
        @memset(observers, .{});
        const selections = try audience_storage.Matrix.init(allocator, deps.players, try std.math.mul(usize, states.len, 4), configuration.audience_words, .recipients);
        for (views, 0..) |*view, index| {
            view.interested = selections.row(index * 4);
            view.watchers = selections.row(index * 4 + 1);
            view.pending = selections.row(index * 4 + 2);
            view.current = selections.row(index * 4 + 3);
        }
        self.* = .{
            .actors = try IndexSet.init(allocator, states.len),
            .spatial_changes = try SpatialIndex.init(allocator, try std.math.mul(usize, 2, states.len)),
            .neighborhoods = try SpatialGroups.init(allocator, states.len),
            .selections = selections,
            .scratch = try sparse_sets.Workspace.init(allocator, 12, states.len),
            .targets = try allocator.alloc(sessions.Service.Target, states.len),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, states.len),
            .deps = deps,
            .states = states,
            .views = views,
            .observers = observers,
            .observer_checks = try deps.metrics.counter(.{ .name = "mining.replication.observers", .description = "Player snapshots examined for mining audience changes" }),
            .pair_checks = try deps.metrics.counter(.{ .name = "mining.replication.pairs", .description = "Pending mining recipient states examined" }),
            .audience_checks = try deps.metrics.counter(.{ .name = "mining.replication.audience", .description = "Spatial candidates examined for mining audience changes" }),
            .random = .{ .source = .init(configuration.seed) },
            .loot_scratch = .init(try allocator.alloc(u8, configuration.loot_scratch_bytes)),
        };
        try deps.players.observeDig(self, onDig);
        try deps.input.on(.arm_animation, self, onSwing);
        return self;
    }

    fn lootNeighbors(self: *Mining, world: u32, position: chunks.Position, offsets: []const loot_tables.Offset, output: []loot_tables.Neighbor) !void {
        assert(offsets.len == output.len and offsets.len <= 16);
        var window = chunks.ReadWindow(8).init(self.deps.chunks);
        defer window.deinit();
        var cursor: usize = 0;
        while (cursor < offsets.len) {
            var positions: [8]chunks.Position = undefined;
            var sections: [8]chunks.Section = undefined;
            var indices: [8]usize = undefined;
            var count: usize = 0;
            const end = @min(offsets.len, cursor + @min(8, self.deps.chunks.cache.entries.len));
            for (cursor..end) |index| {
                const offset = offsets[index];
                output[index] = .{ .offset = offset, .state = 0 };
                const at: chunks.Position = .{
                    .x = std.math.add(i32, position.x, offset.x) catch continue,
                    .y = std.math.add(i32, position.y, offset.y) catch continue,
                    .z = std.math.add(i32, position.z, offset.z) catch continue,
                };
                indices[count] = index;
                positions[count] = at;
                sections[count] = chunks.sectionAt(world, at);
                count += 1;
            }
            var views: [8]chunks.View = undefined;
            try window.readMany(sections[0..count], views[0..count]);
            for (views[0..count], positions[0..count], indices[0..count]) |view, at, index| output[index].state = view.get(chunks.localIndex(at));
            cursor = end;
        }
    }

    pub fn checkpoint(self: *Mining, space: storage.Space) !void {
        try self.random.checkpoint(space);
    }

    fn onSwing(self: *Mining, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_arm_animation.Reader) !void {
        const hand, const done = body.hand() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const players = self.deps.players;
        const player = players.records[handle.index];
        if (player.stage != .ready) return;
        var candidates = players.nearby(player.world, player.position, players.config.render_distance);
        const targets = self.targets;
        const deliveries = self.deliveries;
        var count: usize = 0;
        while (candidates.next()) |other| {
            if (!self.deps.visibility.player_entity.allows(handle, other)) continue;
            const observer = players.records[other];
            const recipient = observer.handle orelse continue;
            if (other == handle.index or observer.world != player.world or observer.stage != .ready) continue;
            targets[count] = .{ .handle = recipient, .protocol = observer.protocol };
            count += 1;
        }
        players.deps.packets.fanout(writeAnimation, targets[0..count], .{ @as(i32, @intCast(handle.index + 1)), @as(u8, if (hand == 0) 0 else 3) }, 2048, deliveries[0..count]) catch |err|
            std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
    }

    fn evaluateBlock(self: *Mining, player: *const Players.Player, state: *State, block: u16, position: minecraft.BlockPosition, tool: ?inventories.Stack) !Registry.Result {
        self.loot_scratch.reset();
        var result = try self.deps.definitions.evaluateContext(self.deps.items, .{
            .actor = player,
            .world = player.world,
            .position = position,
            .state = block,
            .tool = tool,
            .tick = self.deps.players.ticks,
        }, (try state.tool.resolve(self.deps.items, tool)).kind, &self.loot_scratch);
        const player_index = player.handle.?.index;
        if (result.speed > 1) result.speed += @floatCast(try self.deps.attributes.value(player_index, "minecraft:mining_efficiency"));
        result.speed *= @floatCast(try self.deps.attributes.value(player_index, "minecraft:block_break_speed"));
        const eye_y = player.position.y + if (player.flags.sneaking) @as(f64, 1.27) else @as(f64, 1.62);
        const eye: chunks.Position = .{ .x = @intFromFloat(@floor(player.position.x)), .y = @intFromFloat(@floor(eye_y)), .z = @intFromFloat(@floor(player.position.z)) };
        const fluid = self.deps.block_definitions.properties[try self.deps.chunks.getBlock(player.world, eye)];
        if (fluid.fluid == .water) {
            const above = self.deps.block_definitions.properties[try self.deps.chunks.getBlock(player.world, .{ .x = eye.x, .y = eye.y + 1, .z = eye.z })];
            const height: f64 = if (above.fluid == .water) 1 else fluid.height();
            if (eye_y < @as(f64, @floatFromInt(eye.y)) + height) result.speed *= @floatCast(try self.deps.attributes.value(player_index, "minecraft:submerged_mining_speed"));
        }
        return result;
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
            state.* = .{ .generation = handle.generation, .teleport_id = player.teleport_id, .selected_slot = player.selected_slot };
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
        if (block == 0 or block >= game_data.registry.block_state_to_block.len) return;
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 + @as(u16, player.selected_slot) };
        const held = try self.deps.inventories.get(slot);
        const evaluation = try self.evaluateBlock(&player, state, block, position, held.stack);
        if (!evaluation.diggable or evaluation.hardness < 0) return;
        const delta = if (evaluation.hardness == 0) std.math.inf(f32) else evaluation.speed / evaluation.hardness / @as(f32, if (evaluation.harvest) 30 else 100) / @as(f32, if (player.on_ground) 1 else 5);
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
        errdefer self.deps.storage.fail();
        const players = self.deps.players;
        for (players.activeSlots()) |index| self.actors.insert(index);
        var retiring: usize = 0;
        while (retiring < self.actors.count) {
            const index = self.actors.indices[retiring];
            const view = &self.views[index];
            if (players.records[index].handle == null and self.observers[index].generation == 0 and !view.watchers.view().any() and !view.pending.view().any()) self.actors.remove(index) else retiring += 1;
        }
        var terrain = chunks.ReadWindow(8).init(self.deps.chunks);
        defer terrain.deinit();
        for (self.actors.values()) |index| {
            const player = players.records[index];
            const state = &self.states[index];
            if (player.handle == null or player.stage != .ready or player.health == 0 or player.gamemode == .spectator or player.gamemode == .adventure) {
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
                };

            if (state.sequence >= 0 and self.deps.blocks.observers[index].pending == 0 and players.sendBlockAck(player.protocol, handle, state.sequence))
                state.sequence = -1;
            state.selected_slot = player.selected_slot;
            if (!state.active and state.stage == -1) continue;
            const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 + @as(u16, state.selected_slot) };
            const held = try self.deps.inventories.get(slot);
            var complete = state.complete;

            var stage: i8 = -1;
            if (state.active) {
                const position: chunks.Position = .{ .x = state.position.x, .y = state.position.y, .z = state.position.z };
                var views: [1]chunks.View = undefined;
                try terrain.readMany(&.{chunks.sectionAt(player.world, position)}, &views);
                const block = views[0].get(chunks.localIndex(position));

                if (block == 0) state.active = false else {
                    const evaluation = try self.evaluateBlock(&player, state, block, state.position, held.stack);
                    if (!evaluation.diggable or evaluation.hardness < 0) {
                        state.active = false;
                        complete = false;
                    }
                    const progress = if (!evaluation.diggable or evaluation.hardness < 0) @as(f32, 0) else if (evaluation.hardness == 0) @as(f32, 1) else evaluation.speed / evaluation.hardness / @as(f32, if (evaluation.harvest) 30 else 100) / @as(f32, if (player.on_ground) 1 else 5) * @as(f32, @floatFromInt(players.ticks - state.started + 1));
                    complete = complete or (state.finishing and progress >= 1);
                    stage = if (state.active) @intFromFloat(@min(9, @floor(progress * 10))) else -1;
                    if (complete) {
                        terrain.deinit();
                        self.loot_scratch.reset();
                        var experience_random = self.random.source;
                        var experience = if (player.gamemode != .creative) evaluation.experience.sample(experience_random.random()) else 0;
                        var drop_buffer: [loot_tables.maximum_drops]loot_tables.Drop = undefined;
                        var drops: []const loot_tables.Drop = &.{};
                        var admitted = true;
                        if (player.gamemode != .creative) {
                            const tool = if (held.stack) |stack| try self.deps.items.acquire(stack) else null;
                            defer if (tool) |prepared| prepared.release();
                            if (state.tool.enchanted and evaluation.experience.enchantments) {
                                experience = @max(0, try self.deps.enchantments.effects.modify(.{
                                    .item = tool.?.view,
                                    .slot = 0,
                                    .amount = @floatFromInt(experience),
                                    .channel = .block_experience,
                                    .random = experience_random.random(),
                                    .player = player.uuid,
                                    .actor = &player,
                                    .location = .{ .world = player.world, .position = .{ .x = @floatFromInt(position.x), .y = @floatFromInt(position.y), .z = @floatFromInt(position.z) } },
                                    .scratch = &self.loot_scratch,
                                }));
                            }
                            if (evaluation.harvest and evaluation.diggable) if (self.deps.loot.table(block)) |table| {
                                var neighbors: [16]loot_tables.Neighbor = undefined;
                                try self.lootNeighbors(player.world, position, table.offsets, neighbors[0..table.offsets.len]);
                                const context: loot_tables.Context = .{ .items = self.deps.items.deps.definitions, .state = block, .player = player.uuid, .location = .{ .world = player.world, .x = @floatFromInt(position.x), .y = @floatFromInt(position.y), .z = @floatFromInt(position.z) }, .tool = if (tool) |prepared| prepared.view else null, .neighbors = neighbors[0..table.offsets.len], .random = experience_random.random(), .scratch = &self.loot_scratch };
                                drops = table.evaluate(&context, &drop_buffer) catch |err| switch (err) {
                                    error.OutOfMemory, error.LootCapacity => exhausted: {
                                        admitted = false;
                                        break :exhausted &.{};
                                    },
                                    else => return err,
                                };
                            };
                        }
                        if (!admitted or !self.deps.experience.canAward(experience) or !self.deps.dropped.canCreate(drops.len)) {
                            self.deps.blocks.correct(player.world, position);
                            state.active = false;
                            state.finishing = false;
                            state.complete = false;
                            state.stage = -1;
                            continue;
                        }
                        terrain.deinit();
                        const following_drops = drops.len;
                        var drop_stacks: [loot_tables.maximum_drops]inventories.Stack = undefined;
                        for (drops, drop_stacks[0..drops.len]) |drop, *stack| stack.* = .{ .item = try item_data.define(self.deps.inventories, drop.kind, drop.components), .count = drop.count };
                        const removed = try self.deps.actions.apply(.{
                            .following_drops = following_drops,
                            .action = .remove,
                            .player = &player,
                            .position = position,
                            .state = block,
                        });
                        if (removed == .denied) {
                            self.deps.blocks.correct(player.world, position);
                            state.active = false;
                            state.finishing = false;
                            state.complete = false;
                            state.stage = -1;
                            continue;
                        }
                        assert(self.deps.dropped.canCreate(following_drops));
                        self.random.source = experience_random;
                        var worn = held.stack;

                        if (player.gamemode != .creative) {
                            if (held.stack) |tool| {
                                if (evaluation.hardness != 0 and evaluation.tool_damage > 0) worn = try self.deps.durability.wear(tool, .{
                                    .amount = @intCast(evaluation.tool_damage),
                                    .slot = 0,
                                    .actor = &player,
                                    .random = self.random.random(),
                                    .scratch = &self.loot_scratch,
                                });
                            }

                            var requests: [loot_tables.maximum_drops]ItemEntities.Spawn = undefined;
                            var spawned: [loot_tables.maximum_drops]entities.Id = undefined;
                            const random = self.random.random();
                            for (drop_stacks[0..drops.len], requests[0..drops.len]) |stack, *request| request.* = .{
                                .world = player.world,
                                .position = .{
                                    @as(f64, @floatFromInt(position.x)) + 0.25 + random.float(f64) * 0.5,
                                    @as(f64, @floatFromInt(position.y)) + 0.25 + random.float(f64) * 0.5 - 0.125,
                                    @as(f64, @floatFromInt(position.z)) + 0.25 + random.float(f64) * 0.5,
                                },
                                .velocity = .{ random.float(f64) * 0.2 - 0.1, 0.2, random.float(f64) * 0.2 - 0.1 },
                                .stack = stack,
                            };
                            try self.deps.dropped.createMany(requests[0..drops.len], spawned[0..drops.len]);
                        }

                        if (removed == .pass or evaluation.replacement != 0) try self.deps.chunks.setBlock(player.world, position, evaluation.replacement);
                        if (experience > 0) try self.deps.experience.award(player.world, .{ @as(f64, @floatFromInt(position.x)) + 0.5, @as(f64, @floatFromInt(position.y)) + 0.5, @as(f64, @floatFromInt(position.z)) + 0.5 }, experience);

                        if (!std.meta.eql(worn, held.stack)) {
                            const committed = try self.deps.inventories.set(slot, held.revision, worn);
                            assert(committed);
                            self.deps.menus.changed(index);
                        }

                        var candidates = players.nearby(player.world, player.position, players.config.render_distance);
                        const targets = self.targets;
                        const deliveries = self.deliveries;
                        var count: usize = 0;
                        while (candidates.next()) |other| {
                            if (!self.deps.visibility.player_entity.allows(handle, other)) continue;
                            const observer = players.records[other];
                            const recipient = observer.handle orelse continue;
                            if (other == index or observer.world != player.world or observer.stage != .ready) continue;
                            targets[count] = .{ .handle = recipient, .protocol = observer.protocol };
                            count += 1;
                        }
                        players.deps.packets.fanout(writeWorldEvent, targets[0..count], .{ state.position, block }, 2048, deliveries[0..count]) catch |err|
                            std.debug.panic("invalid server packet: {s}", .{@errorName(err)});

                        state.active = false;
                        state.finishing = false;
                        state.complete = false;
                        stage = -1;
                    }
                }
            }

            state.stage = stage;
        }

        terrain.deinit();

        const changed = self.scratch.row(0);
        changed.clear();
        const spatial_changed = self.scratch.row(1);
        spatial_changed.clear();
        const replaced = self.scratch.row(2);
        replaced.clear();
        const connected = self.scratch.row(3);
        connected.clear();
        const ready = self.scratch.row(4);
        ready.clear();
        const available = self.scratch.row(5);
        available.clear();
        while (self.spatial_changes.active.count != 0) self.spatial_changes.update(self.spatial_changes.active.indices[self.spatial_changes.active.count - 1], null);
        var regroup = false;
        for (self.actors.values()) |index| {
            const player = players.records[index];
            const previous = &self.observers[index];
            if (player.handle == null and previous.generation == 0) continue;
            const current: Observer = .{
                .generation = if (player.handle) |handle| handle.generation else 0,
                .life = player.life,
                .world = player.world,
                .ready = player.stage == .ready,
                .cell = .{ @intFromFloat(@floor(player.position.x / 16)), @intFromFloat(@floor(player.position.z / 16)) },
            };
            if (!std.meta.eql(previous.*, current)) changed.insert(index);
            if (previous.generation != current.generation or previous.world != current.world or !std.meta.eql(previous.cell, current.cell)) {
                spatial_changed.insert(index);
                if (previous.generation != 0) self.spatial_changes.update(index * 2, .{ .world = previous.world, .x = @intCast(previous.cell[0]), .z = @intCast(previous.cell[1]) });
                if (current.generation != 0) self.spatial_changes.update(index * 2 + 1, .{ .world = current.world, .x = @intCast(current.cell[0]), .z = @intCast(current.cell[1]) });
            }
            const view = self.views[index];
            regroup = regroup or (!view.valid and self.states[index].stage >= 0) or (view.valid and view.visibility_revision != self.deps.visibility.player_entity.revision(index));
            if (previous.generation != current.generation or previous.life != current.life or previous.world != current.world) replaced.insert(index);
            previous.* = current;
            if (player.handle) |handle| {
                connected.insert(index);
                if (current.ready) ready.insert(index);
                if (players.deps.sessions.outputCredit(handle) != 0) available.insert(index);
            }
        }
        self.observer_checks.add(self.actors.count);
        const distance_changed = self.render_distance != players.config.render_distance;
        self.render_distance = players.config.render_distance;
        var pairs: usize = 0;
        var audience: usize = 0;
        defer self.pair_checks.add(pairs);
        defer self.audience_checks.add(audience);
        self.neighborhoods.clear();
        regroup = regroup or distance_changed or spatial_changed.view().any();
        if (regroup) for (self.actors.values()) |index| {
            const origin = self.observers[index];
            self.neighborhoods.add(index, .{ .world = origin.world, .x = @intCast(origin.cell[0]), .z = @intCast(origin.cell[1]) });
        };
        var center: ?SpatialIndex.Position = null;
        var captured = false;
        var affected = false;
        const order = if (regroup) self.neighborhoods.ordered() else self.actors.values();
        for (order) |index| {
            const state = self.states[index];
            const view = &self.views[index];
            if (state.stage < 0 and !view.watchers.view().any() and !view.pending.view().any()) {
                view.valid = false;
                continue;
            }
            const subject = players.records[index];
            const interested = self.scratch.row(6);
            interested.copy(view.interested.view());
            const visibility_revision = self.deps.visibility.player_entity.revision(index);
            const origin = self.observers[index];
            const next_center: SpatialIndex.Position = .{ .world = origin.world, .x = @intCast(origin.cell[0]), .z = @intCast(origin.cell[1]) };
            if (!std.meta.eql(center, @as(?SpatialIndex.Position, next_center))) {
                center = next_center;
                captured = false;
                affected = false;
                if (spatial_changed.view().any()) {
                    var changes = self.spatial_changes.query(next_center, self.render_distance);
                    affected = changes.next() != null;
                    audience += changes.visited;
                }
            }
            if (subject.handle) |handle| {
                if (!view.valid or distance_changed or affected or view.visibility_revision != visibility_revision) {
                    const nearby = self.scratch.row(11);
                    if (!captured) {
                        nearby.clear();
                        var candidates = players.nearby(subject.world, subject.position, players.config.render_distance);
                        while (candidates.next()) |other| if (connected.view().contains(other)) nearby.insert(other);
                        captured = true;
                    }
                    interested.copy(nearby.view());
                    interested.remove(index);
                    view.valid = true;
                }
                _ = self.deps.visibility.player_entity.filter(handle, interested.view(), interested);
            } else interested.clear();
            view.visibility_revision = visibility_revision;
            const altered = self.scratch.row(7);
            const combined = self.scratch.row(8);
            altered.difference(interested.view(), view.interested.view());
            view.pending.unite(view.pending.view(), altered.view());
            combined.unite(interested.view(), view.watchers.view());
            altered.intersect(changed.view(), combined.view());
            view.pending.unite(view.pending.view(), altered.view());
            if (view.stage != state.stage or !std.meta.eql(view.position, state.position)) {
                view.pending.unite(view.pending.view(), combined.view());
                view.current.clear();
            }
            view.interested.copy(interested.view());
            view.stage = state.stage;
            view.position = state.position;
            combined.unite(view.pending.view(), view.watchers.view());
            const resets = self.scratch.row(9);
            resets.subtract(combined.view(), connected.view());
            altered.intersect(combined.view(), replaced.view());
            resets.unite(resets.view(), altered.view());
            var resetting = resets.view().iterator();
            while (resetting.next()) |other| {
                view.watchers.remove(other);
                view.current.remove(other);
            }
            view.pending.intersect(view.pending.view(), connected.view());
            view.pending.remove(index);
            const selected = self.scratch.row(10);
            selected.intersect(view.pending.view(), ready.view());
            selected.intersect(selected.view(), available.view());
            if (!selected.view().any()) continue;
            // Minecraft replaces and cancels crack animations by actor ID, regardless of the old position.
            for ([_]bool{ true, false }) |removing| {
                const targets = self.targets;
                const deliveries = self.deliveries;
                var count: usize = 0;
                var candidates = selected.view().iterator();
                pairs += selected.view().count();
                while (candidates.next()) |other| {
                    const wanted = interested.view().contains(other) and state.stage >= 0;
                    if (removing) {
                        if (wanted or !view.watchers.view().contains(other)) continue;
                    } else {
                        if (!wanted or view.current.view().contains(other)) continue;
                    }
                    const observer = players.records[other];
                    targets[count] = .{ .handle = observer.handle.?, .protocol = observer.protocol };
                    count += 1;
                }
                if (count == 0) continue;
                try players.deps.packets.fanout(writeBlockProgress, targets[0..count], .{ @as(i32, @intCast(index + 1)), state.position, if (removing) @as(i8, -1) else state.stage }, 2048, deliveries[0..count]);
                for (targets[0..count], deliveries[0..count]) |target, delivery| {
                    if (delivery != .queued) continue;
                    if (removing) {
                        view.watchers.remove(target.handle.index);
                        view.current.remove(target.handle.index);
                    } else {
                        view.watchers.insert(target.handle.index);
                        view.current.insert(target.handle.index);
                    }
                }
            }
            var completed = selected.view().iterator();
            pairs += selected.view().count();
            while (completed.next()) |other| {
                const wanted = interested.view().contains(other) and state.stage >= 0;
                if (if (wanted) view.current.view().contains(other) else !view.watchers.view().contains(other)) view.pending.remove(other);
            }
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
