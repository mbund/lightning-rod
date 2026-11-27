const std = @import("std");
const inventories = @import("inventories");
const entities = @import("entities");
const worlds = @import("worlds");
const chunks = @import("chunks");
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const item_physics = @import("vanilla_item_entities").item_physics;
const ItemPhysics = item_physics.ItemPhysics;
const ItemMerging = @import("vanilla_item_entities").item_merging.ItemMerging;
const ItemPickup = @import("item_pickup.zig").ItemPickup;
const Players = @import("players").players.Players;
const WorldBorder = @import("vanilla_world").world_border.WorldBorder;
const Items = @import("vanilla_items").items.Items;
const Dimensions = @import("vanilla_content").dimensions.Dimensions;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const hazards_module = @import("item_hazards.zig");
const replication = @import("replication");

const Models = replication.models.Models;
const Model = replication.models.Model;
const Classes = replication.models.Classes;

const Level = @import("vanilla_bodies").body.Level;
const BlockEdits = @import("vanilla_bodies").block_edits.BlockEdits;
const assert = std.debug.assert;

pub const ItemTick = struct {
    pub const id = "minecraft:item_tick";

    pub const Configuration = struct {
        /// Seeds what pushes items out of blocks they are stuck in: vanilla's Entity.random.
        seed: u64 = 0x6974656d73,
    };

    pub const Dependencies = struct {
        dropped: *ItemEntities,
        physics: *ItemPhysics,
        merging: *ItemMerging,
        pickup: *ItemPickup,
        players: *Players,
        /// The world border items collide with, when the server has one.
        world_border: ?*WorldBorder = null,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
        worlds: *worlds.Worlds,
        dimensions: *Dimensions,
        client: *ClientRegistries,
        block_edits: *BlockEdits,
    };

    deps: Dependencies,
    /// Room to name the players' columns, for what stays in memory.
    centers: []entities.residency.Center,
    /// What the last refresh went by: while all of it stands, so does what is in memory.
    last_centers: []entities.residency.Center,
    last_center_count: usize = 0,
    last_radius: i32 = 0,
    last_ticking: u64 = std.math.maxInt(u64),
    last_held: u64 = std.math.maxInt(u64),
    /// What went wrong waking sleepers from inside a block notification, told at the next tick.
    failure: ?anyerror = null,
    stepped: u64 = 0,
    merged: u64 = 0,
    /// The world the last item was in and whether its dimension is ultrawarm, as items come in
    /// runs of one world.
    last_world: ?u32 = null,
    last_ultrawarm: bool = false,
    hazards: hazards_module.Hazards,
    /// Where the items near one merging are, in order.
    nearby: []entities.space.Entry,
    random: std.Random.DefaultPrng,
    /// What clients have of items, which step them themselves: each item's models are stepped
    /// beside it, as their clients step it. Their replication sets it.
    client_models: ?*Models = null,
    /// While entities tick: this tick's number.
    now: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ItemTick {
        const self = try allocator.create(ItemTick);
        self.* = .{
            .deps = deps,
            .centers = try allocator.alloc(entities.residency.Center, deps.players.records.len),
            .last_centers = try allocator.alloc(entities.residency.Center, deps.players.records.len),
            .hazards = try .init(allocator, .{
                .blocks = deps.physics.deps.blocks,
                .items = deps.items,
                .client = deps.client,
                .players = deps.players,
                .worlds = deps.worlds,
                .inventories = deps.inventories,
                .levels = deps.physics.deps.levels,
                .block_edits = deps.block_edits,
            }),
            .nearby = try allocator.alloc(entities.space.Entry, 1024),
            .random = .init(config.seed),
        };
        try deps.physics.deps.levels.deps.chunks.observe(.init(self, blocksChanged));
        // A solid entity moving onto a sleeping item wakes it, to be pushed out as vanilla's would.
        if (deps.physics.deps.levels.deps.collisions) |collisions| try collisions.register(ItemEntities.kinds, .{ .context = self, .wake = wakeItem });
        try deps.entities.addTicker(self.ticker());
        return self;
    }

    /// Items take their turns in the one tick order, one at a time: one merging changes the
    /// next.
    pub fn ticker(self: *ItemTick) entities.Entities.Ticker {
        return .init(ItemTick, self, ItemEntities.kinds, 1);
    }

    /// Sleepers within a section of an edit wake on the next tick to look again: the block
    /// they rest on may be gone, and they fall on their own tick of four.
    fn blocksChanged(self: *ItemTick, section: chunks.Section, _: []const chunks.BlockEdit, _: []const u16) void {
        const dropped = self.deps.dropped;
        // The sleepers of the sections about it, a section each way, look again.
        const low: [3]f64 = .{ @floatFromInt((section.x - 1) * 16), @floatFromInt((section.y - 1) * 16), @floatFromInt((section.z - 1) * 16) };
        const high: [3]f64 = .{ std.math.nextAfter(f64, low[0] + 48, -std.math.inf(f64)), std.math.nextAfter(f64, low[1] + 48, -std.math.inf(f64)), std.math.nextAfter(f64, low[2] + 48, -std.math.inf(f64)) };
        const Ask = struct {
            tick: *ItemTick,
            pub fn visit(context: @This(), slot: u32) bool {
                const owner = context.tick;
                owner.deps.dropped.ask(owner.deps.dropped.deps.entities.directory.entry(slot).id) catch |err| {
                    owner.failure = err;
                };
                return true;
            }
        };
        _ = dropped.places.space.eachDormant(section.world, .{ .low = low, .high = high }, ItemEntities.kinds, Ask{ .tick = self });
        // Clients step their items before they hear of the edit: those in or next to the section
        // are sent as they are.
        const models = self.client_models orelse return;
        const near_low: [3]f64 = .{ @floatFromInt(section.x * 16 - 1), @floatFromInt(section.y * 16 - 1), @floatFromInt(section.z * 16 - 1) };
        const near: entities.space.Box = .{ .min = near_low, .max = .{ near_low[0] + 18, near_low[1] + 18, near_low[2] + 18 } };
        dropped.places.space.each(section.world, near, ItemEntities.kinds, models, struct {
            fn visit(context: *Models, entry: entities.space.Entry) anyerror!bool {
                context.disturb(entry.slot);
                return false;
            }
        }.visit) catch |err| {
            self.failure = err;
        };
    }

    fn wakeItem(context: *anyopaque, slot: u32) void {
        const self: *ItemTick = @ptrCast(@alignCast(context));
        self.deps.dropped.ask(self.deps.entities.directory.entry(slot).id) catch |err| {
            self.failure = err;
        };
    }

    /// Whether lava flows strongly in the world, as in the nether, which pushes items harder.
    fn ultrawarm(self: *ItemTick, world: u32) !bool {
        if (self.last_world != world) {
            const entry = self.deps.worlds.get(world) orelse return error.Corrupt;
            self.last_ultrawarm = if (self.deps.dimensions.get(entry.dimension.name)) |dimension| dimension.ultrawarm else false;
            self.last_world = world;
        }
        return self.last_ultrawarm;
    }

    /// Before entities tick: items near players come into memory, and sleepers due to look
    /// again wake to be met at their turns.
    pub fn prepareTick(self: *ItemTick) !void {
        const dropped = self.deps.dropped;
        if (self.failure) |err| return err;
        try self.refresh();
        self.now = dropped.clock.tick + 1;
        // Items tick in the tick order: others reading one know from this whether it has had
        // this tick.
        dropped.clock = .{ .tick = self.now, .running = true };
        try dropped.wakeDue(self.now);
    }

    /// Items next in the tick order.
    pub fn tickRun(self: *ItemTick, run: []const entities.order.Entry) !void {
        const dropped = self.deps.dropped;
        const now = self.now;
        for (run) |entry| {
            // Every place before this one has had the tick, sleepers between included.
            dropped.clock.last = entry.sequence - 1;
            defer dropped.clock.last = entry.sequence;
            if (dropped.asleepAt(entry.slot)) |sleep| {
                const elapsed = now - sleep.since;
                const ticks = sleep.ticks +% @as(u32, @intCast(elapsed));
                const despawning = @as(i64, sleep.age) + @as(i64, @intCast(elapsed)) >= 6000;
                // Due a merge check with nothing to merge with, its tick is what its replay
                // does: it sleeps on.
                const merging = ticks % 40 == 0 and dropped.sleeperNearOthers(entry.id);
                if (!despawning and !merging and !sleep.asked) {
                    try dropped.sleepOn(entry.id, now);
                    continue;
                }
                try dropped.wake(entry.id, std.math.maxInt(u64));
            }
            try self.tickOne(entry.id, entry.sequence);
        }
    }

    pub fn finishTick(self: *ItemTick) !void {
        self.deps.dropped.clock.running = false;
    }

    /// Items in memory are those near players, out to their view and one more, and those of
    /// the columns that tick.
    fn refresh(self: *ItemTick) !void {
        const dropped = self.deps.dropped;
        var center_count: usize = 0;
        var radius: i32 = 1;
        for (self.deps.players.activeSlots()) |at| {
            const player = self.deps.players.records[at];
            if (player.stage != .ready) continue;
            const column = entities.space.columnOf(player.world, .{ player.position.x, player.position.y, player.position.z });
            self.centers[center_count] = .{ .world = column.world, .x = column.x, .z = column.z };
            center_count += 1;
            radius = @max(radius, self.deps.players.viewDistanceOf(player) + 1);
        }
        const centers = self.centers[0..center_count];
        if (radius == self.last_radius and dropped.places.ticking_revision == self.last_ticking and dropped.residency.held == self.last_held and
            std.mem.eql(u8, std.mem.sliceAsBytes(centers), std.mem.sliceAsBytes(self.last_centers[0..self.last_center_count]))) return;
        @memcpy(self.last_centers[0..center_count], centers);
        self.last_center_count = center_count;
        self.last_radius = radius;
        self.last_ticking = dropped.places.ticking_revision;
        try dropped.refresh(centers, radius, dropped.places.tickingColumns());
        self.last_held = dropped.residency.held;
    }

    fn tickOne(self: *ItemTick, entity: entities.Id, sequence: u64) !void {
        const dropped = self.deps.dropped;
        const view = (try dropped.read(entity)) orelse return;
        var metadata = view.metadata;
        if (!metadata.alive) return;
        var body = view.body;
        const level = self.deps.physics.level(body.world);
        // Visited but not ticked: moved this tick where nothing ticks.
        if (!dropped.places.ticks(ItemEntities.columnOf(body))) return;
        const before = body.position;
        metadata.ticks +%= 1;

        // Entity.baseTick: pushed by currents, then burning down.
        var pushed = body;
        const fluids = try self.deps.physics.push(&level, &pushed, try self.ultrawarm(body.world));
        var subject: hazards_module.Subject = .{
            .world = body.world,
            .position = body.position,
            .old_position = body.position,
            .velocity = pushed.velocity,
            .on_ground = metadata.on_ground,
            .fire_ticks = metadata.fire_ticks,
            .ticks_frozen = metadata.ticks_frozen,
            .health = metadata.health,
            .slot = ItemEntities.slot(body),
        };
        const was_burning = metadata.fire_ticks > 0;
        // Entity.isInLava, which is false on an entity's first tick.
        try self.hazards.burn(&subject, metadata.ticks > 1 and fluids.lava > 0);
        var advanced: ItemPhysics.Result = .{ .body = pushed, .ground = metadata.ground(), .crossed_block = false };
        var hooked: hazards_module.Hook = .{ .hazards = &self.hazards, .subject = &subject };
        if (!subject.removed) {
            if (metadata.pickup_delay > 0 and metadata.pickup_delay != 32767) metadata.pickup_delay -= 1;
            advanced = try self.deps.physics.advanceRandomly(&level, self.deps.dropped.givenId(entity), metadata.ticks, pushed, metadata.ground(), fluids, metadata.stuck.multiplier(), hooked.physics(), self.random.random());
            if (advanced.moved) metadata.stuck = ItemEntities.Stuck.of(subject.stuck);
        }
        metadata.stand(advanced.ground);
        metadata.fire_ticks = subject.fire_ticks;
        metadata.ticks_frozen = @intCast(subject.ticks_frozen);
        metadata.health = subject.health;
        // Burning shows on the item, and a hurt item sends its velocity again.
        if (subject.hurt or was_burning != (metadata.fire_ticks > 0)) metadata.revision += 1;

        if (!std.meta.eql(body, advanced.body)) {
            try dropped.move(entity, body, advanced.body);
            metadata.revision += 1;
            body = advanced.body;
        }
        const moved_revision = metadata.revision;

        if (subject.removed) {
            // ItemEntity.hurtServer: an item with no health left is destroyed.
            const held = try self.deps.inventories.get(ItemEntities.slot(body));
            const removed = try self.deps.inventories.set(ItemEntities.slot(body), held.revision, null);
            assert(removed);
            try dropped.retire(entity, body, &metadata);
            return;
        }

        self.stepped += 1;
        const interval: u32 = if (advanced.crossed_block) 2 else 40;
        if (metadata.ticks % interval == 0 and metadata.age != -32768 and metadata.age < 6000 and metadata.pickup_delay != 32767) try self.mergeWithNeighbours(entity, &body, &metadata);

        if (metadata.alive and metadata.age != -32768) metadata.age += 1;
        // ItemEntity.tick's second Entity.updateWaterState, after moving and merging: pushed
        // again by the currents where it ended up.
        if (metadata.alive) {
            var again = body;
            _ = try self.deps.physics.push(&level, &again, try self.ultrawarm(body.world));
            if (!std.meta.eql(again, body)) {
                try dropped.move(entity, body, again);
                metadata.revision += 1;
                body = again;
            }
            // Its clients step it too: their models step beside it, and are held to it.
            if (self.client_models) |models| try self.stepModels(models, &level, entity, body, metadata.on_ground);
        }
        const world = self.deps.worlds.get(body.world) orelse return error.UnknownWorld;
        const void_y: f64 = @floatFromInt(world.dimension.minimumSection() * 16 - 64);

        if (metadata.alive and (metadata.age >= 6000 or body.position[1] < void_y)) {
            const held = try self.deps.inventories.get(ItemEntities.slot(body));
            const removed = try self.deps.inventories.set(ItemEntities.slot(body), held.revision, null);
            assert(removed);
            try dropped.retire(entity, body, &metadata);
        }

        // Resting where it is, with nothing around to change it, it sleeps until something does.
        const restful = dropped.sleep and metadata.alive and advanced.moved and advanced.ground.on and !advanced.crossed_block and
            std.meta.eql(before, body.position) and @abs(body.velocity[0]) < 1.0e-5 and @abs(body.velocity[2]) < 1.0e-5 and
            fluids.water == 0 and fluids.lava == 0 and metadata.fire_ticks == 0 and metadata.ticks_frozen == 0 and !subject.hurt and
            metadata.stuck == .none and metadata.age >= 0 and metadata.age < 5999 and metadata.revision == moved_revision;
        if (metadata.alive) try dropped.put(entity, metadata);
        if (restful) if (try self.deps.physics.rest(&level, body)) |still| try dropped.lull(entity, sequence, body, metadata, still.speed, still.friction);
    }

    /// Steps an item's models, each as the clients holding it step the item, and has them judged
    /// against the item as it now is. Clients whose steps would differ, by their release's rules or
    /// by whether their own tick count moves an item at rest this tick, are stepped apart.
    fn stepModels(self: *ItemTick, models: *Models, level: *const Level, entity: entities.Id, body: entities.State, on_ground: bool) !void {
        const slot = self.deps.dropped.items.slotOf(entity).?;
        const entries = (try models.begin(slot, entity)) orelse return;
        const given = self.deps.dropped.givenId(entity);
        const warm = try self.ultrawarm(body.world);
        for (entries) |entry| {
            var left = entry.classes;
            while (left != 0) {
                const first: u8 = @ctz(left);
                const way = stepWay(models, first, entry.model, given);
                var alike: Classes = 0;
                var each = left;
                while (each != 0) : (each &= each - 1) {
                    const class: u8 = @ctz(each);
                    if (stepWay(models, class, entry.model, given) == way) alike |= @as(Classes, 1) << @intCast(class);
                }
                left &= ~alike;
                var state = body;
                state.position = entry.model.position;
                state.velocity = entry.model.velocity;
                const fluids = try self.deps.physics.push(level, &state, warm);
                const stepped = try self.deps.physics.advanceClient(level, given, models.ticksOf(first), state, .{ .on = entry.model.on_ground, .no_blocks = entry.model.on_ground_no_blocks }, fluids, ItemPhysics.releaseOf(models.rulesOf(first)));
                var after = stepped.body;
                _ = try self.deps.physics.push(level, &after, warm);
                const model: Model = .{ .position = after.position, .velocity = after.velocity, .on_ground = stepped.ground.on, .on_ground_no_blocks = stepped.ground.no_blocks };
                // Each class, as whether its tick count moves the item next tick is its own.
                var each_alike = alike;
                while (each_alike != 0) : (each_alike &= each_alike - 1) {
                    const class: u8 = @ctz(each_alike);
                    models.put(model, @as(Classes, 1) << @intCast(class), standsStill(model, models.ticksOf(class) + 1, given));
                }
            }
        }
        models.judge(.{ .position = body.position, .velocity = body.velocity, .on_ground = on_ground });
    }

    /// Whether a client will not move an item next tick, its tick count then `ticks`: at rest on
    /// the ground, off its tick of four.
    fn standsStill(model: Model, ticks: u32, given: u32) bool {
        const across = model.velocity[0] * model.velocity[0] + model.velocity[2] * model.velocity[2];
        return model.on_ground and !(across > @as(f64, @as(f32, 0.00001))) and !item_physics.movesOnPhase(ticks, given);
    }

    /// What decides a class's step from a model: its rules, and, on the ground, whether its tick
    /// count moves it this tick. Classes alike in both step alike.
    fn stepWay(models: *const Models, class: u8, model: Model, given: u32) u8 {
        const rules = models.rulesOf(class);
        const gated = model.on_ground and item_physics.movesOnPhase(models.ticksOf(class), given);
        return rules * 2 + @intFromBool(gated or !model.on_ground);
    }

    /// ItemEntity.mergeWithNeighbours: the items in its box grown by 0.5 sideways, in vanilla's
    /// order, merge into it or it into them while its stack has room.
    fn mergeWithNeighbours(self: *ItemTick, entity: entities.Id, body: *entities.State, metadata: *ItemEntities.Metadata) !void {
        // A full stack finds out when its stack is read, once there is something to merge with.
        // Only those within it merge: the rest are passed over before they are put in order.
        const within: entities.Feet = .{ .low = .{ body.position[0] - 0.75, body.position[1] - 0.25, body.position[2] - 0.75 }, .high = .{ body.position[0] + 0.75, body.position[1] + 0.25, body.position[2] + 0.75 } };
        var merging: struct { tick: *ItemTick, entity: entities.Id, body: *entities.State, metadata: *ItemEntities.Metadata } = .{ .tick = self, .entity = entity, .body = body, .metadata = metadata };
        try self.deps.dropped.places.space.eachWithin(body.world, within, ItemEntities.kinds, self.nearby, &merging, struct {
            fn visit(context: *@TypeOf(merging), candidate: entities.space.Entry) anyerror!bool {
                if (candidate.id == context.entity) return false;
                // The index knows where each is: those out of the box are not read.
                const at = candidate.position;
                const here = context.body.position;
                if (@abs(here[0] - at[0]) >= 0.75 or @abs(here[1] - at[1]) >= 0.25 or @abs(here[2] - at[2]) >= 0.75) return false;
                return switch (try context.tick.mergeWith(context.entity, context.body.*, context.metadata, candidate)) {
                    .next => false,
                    .done => true,
                };
            }
        }.visit);
    }

    const Merge = enum { next, done };

    /// One neighbour, as ItemEntity.tryToMerge takes it.
    fn mergeWith(self: *ItemTick, entity: entities.Id, body: entities.State, metadata: *ItemEntities.Metadata, candidate: entities.space.Entry) !Merge {
        const dropped = self.deps.dropped;
        const other_id = candidate.id;
        // The space gave its slot: it is not found again by its id.
        const view = try dropped.readAt(other_id, candidate.slot);
        var other_meta = view.metadata;
        const other = view.body;
        if (!other_meta.alive or other_meta.owner != metadata.owner or other_meta.age == -32768 or other_meta.age >= 6000 or other_meta.pickup_delay == 32767) return .next;
        assert(other.world == body.world);
        if (@abs(body.position[0] - other.position[0]) >= 0.75 or @abs(body.position[1] - other.position[1]) >= 0.25 or @abs(body.position[2] - other.position[2]) >= 0.75) return .next;
        var contents: [2]inventories.Contents = undefined;
        try self.deps.inventories.getMany(&.{ ItemEntities.slot(body), ItemEntities.slot(other) }, &contents);
        const first = contents[0];
        const second = contents[1];
        const held = first.stack orelse return error.Corrupt;
        const maximum = try dropped.stackLimit(held);
        if (held.count >= maximum) return .done;
        if (second.stack == null) return error.Corrupt;
        if (!inventories.Stack.sameItem(held, second.stack.?)) return .next;
        const merged = self.deps.merging.merge(
            .{ .stack = held, .maximum_stack = maximum, .age = metadata.age, .pickup_delay = metadata.pickup_delay, .owner = metadata.owner },
            .{ .stack = second.stack.?, .maximum_stack = maximum, .age = other_meta.age, .pickup_delay = other_meta.pickup_delay, .owner = other_meta.owner },
        ) orelse return .next;
        const remainder = if (merged.source) |source| source.stack else null;
        const committed = try self.deps.inventories.editMany(&.{
            .{ .slot = ItemEntities.slot(body), .revision = first.revision, .stack = if (merged.destination_is_first) merged.destination.stack else remainder },
            .{ .slot = ItemEntities.slot(other), .revision = second.revision, .stack = if (merged.destination_is_first) remainder else merged.destination.stack },
        });
        assert(committed);
        metadata.revision += 1;
        other_meta.revision += 1;
        const destination = if (merged.destination_is_first) metadata else &other_meta;
        destination.age = merged.destination.age;
        destination.pickup_delay = merged.destination.pickup_delay;
        if (merged.source == null) {
            if (merged.destination_is_first) try dropped.retire(other_id, other, &other_meta) else try dropped.retire(entity, body, metadata);
        }
        try dropped.put(other_id, other_meta);
        self.merged += 1;
        if (!metadata.alive) return .done;
        const now_held = if (merged.destination_is_first) merged.destination.stack else remainder;
        if (now_held == null or now_held.?.count >= maximum) return .done;
        return .next;
    }
};
