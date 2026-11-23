const std = @import("std");
const inventories = @import("inventories");
const entities = @import("entities");
const worlds = @import("worlds");
const chunks = @import("chunks");
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const ItemMerging = @import("vanilla_item_entities").item_merging.ItemMerging;
const ItemPickup = @import("item_pickup.zig").ItemPickup;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const Items = @import("vanilla_items").items.Items;
const Dimensions = @import("vanilla_content").dimensions.Dimensions;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const hazards_module = @import("item_hazards.zig");

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
        /// For the world border, when the server keeps players in one.
        player_states: ?*PlayerStates = null,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
        worlds: *worlds.Worlds,
        dimensions: *Dimensions,
        client: *ClientRegistries,
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
    /// While entities tick: this tick's number, and the blocks items read, shared by them all.
    now: u64 = 0,
    neighborhood: ?ItemPhysics.Window = null,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ItemTick {
        const self = try allocator.create(ItemTick);
        // Items collide with the border players are kept in.
        if (deps.player_states) |states| if (states.config.world_border) |diameter| {
            deps.physics.border = diameter / 2;
        };
        self.* = .{
            .deps = deps,
            .centers = try allocator.alloc(entities.residency.Center, deps.players.records.len),
            .last_centers = try allocator.alloc(entities.residency.Center, deps.players.records.len),
            .hazards = try .init(allocator, .{
                .chunks = deps.physics.deps.chunks,
                .blocks = deps.physics.deps.blocks,
                .items = deps.items,
                .client = deps.client,
                .players = deps.players,
                .worlds = deps.worlds,
                .inventories = deps.inventories,
            }),
            .nearby = try allocator.alloc(entities.space.Entry, 1024),
            .random = .init(config.seed),
        };
        try deps.physics.deps.chunks.observe(.init(self, blocksChanged));
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
        if (dropped.sleepers.count() == 0) return;
        var x = section.x - 1;
        while (x <= section.x + 1) : (x += 1) {
            var z = section.z - 1;
            while (z <= section.z + 1) : (z += 1) {
                var walk = dropped.places.space.entries(.{ .world = section.world, .x = x, .z = z }, ItemEntities.kinds);
                while (walk.next()) |entry| {
                    if (@abs(entry.section - section.y) > 1) continue;
                    dropped.ask(entry.id) catch |err| {
                        self.failure = err;
                    };
                }
            }
        }
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
        self.neighborhood = self.deps.physics.readWindow();
        self.hazards.window = &self.neighborhood.?;
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
            if (dropped.asleep(entry.id)) |sleep| {
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
            try self.tickOne(&self.neighborhood.?, entry.id, entry.sequence);
        }
    }

    pub fn finishTick(self: *ItemTick) !void {
        self.deps.dropped.clock.running = false;
        self.hazards.endTick();
        self.hazards.window = null;
        if (self.neighborhood) |*neighborhood| neighborhood.deinit();
        self.neighborhood = null;
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

    fn tickOne(self: *ItemTick, neighborhood: *ItemPhysics.Window, entity: entities.Id, sequence: u64) !void {
        const dropped = self.deps.dropped;
        const view = (try dropped.read(entity)) orelse return;
        var metadata = view.metadata;
        if (!metadata.alive) return;
        var body = view.body;
        // Visited but not ticked: moved this tick where nothing ticks.
        if (!dropped.places.ticks(ItemEntities.columnOf(body))) return;
        const before = body.position;
        metadata.ticks +%= 1;

        // Entity.baseTick: pushed by currents, then burning down.
        var pushed = body;
        const fluids = try self.deps.physics.push(neighborhood, &pushed, try self.ultrawarm(body.world));
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
        var advanced: ItemPhysics.Result = .{ .body = pushed, .on_ground = metadata.on_ground, .crossed_block = false };
        if (!subject.removed) {
            if (metadata.pickup_delay > 0 and metadata.pickup_delay != 32767) metadata.pickup_delay -= 1;
            advanced = try self.deps.physics.advanceRandomly(neighborhood, self.deps.dropped.givenId(entity), metadata.ticks, pushed, metadata.on_ground, fluids, metadata.stuck.multiplier(), hazards_module.Hook{ .hazards = &self.hazards, .subject = &subject }, self.random.random());
            if (advanced.moved) metadata.stuck = ItemEntities.Stuck.of(subject.stuck);
        }
        metadata.on_ground = advanced.on_ground;
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
            _ = try self.deps.physics.push(neighborhood, &again, try self.ultrawarm(body.world));
            if (!std.meta.eql(again, body)) {
                try dropped.move(entity, body, again);
                metadata.revision += 1;
                body = again;
            }
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
        const restful = dropped.sleep and metadata.alive and advanced.moved and advanced.on_ground and !advanced.crossed_block and
            std.meta.eql(before, body.position) and @abs(body.velocity[0]) < 1.0e-5 and @abs(body.velocity[2]) < 1.0e-5 and
            fluids.water == 0 and fluids.lava == 0 and metadata.fire_ticks == 0 and metadata.ticks_frozen == 0 and !subject.hurt and
            metadata.stuck == .none and metadata.age >= 0 and metadata.age < 5999 and metadata.revision == moved_revision;
        if (metadata.alive) try dropped.put(entity, metadata);
        if (restful) if (try self.deps.physics.rest(neighborhood, body)) |still| try dropped.lull(entity, sequence, body, metadata, still.speed, still.friction);
    }

    /// ItemEntity.mergeWithNeighbours: the items in its box grown by 0.5 sideways, in vanilla's
    /// order, merge into it or it into them while its stack has room.
    fn mergeWithNeighbours(self: *ItemTick, entity: entities.Id, body: *entities.State, metadata: *ItemEntities.Metadata) !void {
        const dropped = self.deps.dropped;
        // A full stack finds out when its stack is read, once there is something to merge with.
        const low: [3]i32 = .{ entities.space.coordinate(body.position[0] - 0.75), entities.space.coordinate(body.position[1] - 0.25), entities.space.coordinate(body.position[2] - 0.75) };
        const high: [3]i32 = .{ entities.space.coordinate(body.position[0] + 0.75), entities.space.coordinate(body.position[1] + 0.25), entities.space.coordinate(body.position[2] + 0.75) };
        var x = low[0];
        while (x <= high[0]) : (x += 1) {
            // Within one x, vanilla's sections go by z from 0 up, then the negative ones: the box
            // spans two columns at most.
            const z_first = if (low[2] < 0 and high[2] >= 0) high[2] else low[2];
            const z_order = [2]i32{ z_first, if (z_first == low[2]) high[2] else low[2] };
            for (z_order[0 .. @as(usize, @intCast(high[2] - low[2])) + 1]) |z| {
                var ordered = dropped.inColumn(.{ .world = body.world, .x = x, .z = z }, low[1], high[1], self.nearby);
                while (true) {
                    const entries = try ordered.next();
                    if (entries.len == 0) break;
                    for (entries) |candidate| {
                        if (candidate.id == entity) continue;
                        // The index knows where each is: those out of the box are not read.
                        const at = candidate.position;
                        if (@abs(body.position[0] - at[0]) >= 0.75 or @abs(body.position[1] - at[1]) >= 0.25 or @abs(body.position[2] - at[2]) >= 0.75) continue;
                        switch (try self.mergeWith(entity, body.*, metadata, candidate.id)) {
                            .next => {},
                            .done => return,
                        }
                    }
                }
            }
        }
    }

    const Merge = enum { next, done };

    /// One neighbour, as ItemEntity.tryToMerge takes it.
    fn mergeWith(self: *ItemTick, entity: entities.Id, body: entities.State, metadata: *ItemEntities.Metadata, other_id: entities.Id) !Merge {
        const dropped = self.deps.dropped;
        const view = (try dropped.read(other_id)) orelse return .next;
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
