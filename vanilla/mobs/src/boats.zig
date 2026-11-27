//! Boats and rafts, each a record of its own beside its body, kept with its column: they tick in
//! the tick list's order where the domains tick, are found by the area index, and collide with and
//! push what is around them as vanilla's do. Their tick is boat.zig's; this keeps them, hurts and
//! breaks them, and answers for the world around them.

const std = @import("std");
const lightning_rod = @import("lightning_rod");
const game_data = @import("game_data");
const entities = @import("entities");
const records = @import("records");
const storage = @import("storage");
const inventories = @import("inventories");
const Players = @import("players").players.Players;
const Input = @import("players").input.Input;
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const wire = @import("wire_1_21_5");
const entity_sync = @import("replication").entity_sync;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const Containers = @import("vanilla_containers").containers.Containers;
const EntityCollisions = bodies.entity_collisions.EntityCollisions;
const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
const canInteractWithEntity = @import("mob_interaction.zig").canInteractWithEntity;
const item_data = @import("vanilla_items").item_data;
const bodies = @import("vanilla_bodies");
const boat_module = @import("boat.zig");
const living = @import("living.zig");
const Mobs = @import("mobs.zig").Mobs;
const Mob = @import("mob.zig").Mob;

const body = bodies.body;
const mth = bodies.mth;
const JavaRandom = bodies.java_random.JavaRandom;
const block_effects = bodies.block_effects;
const Boat = boat_module.Boat;
const Box = body.Box;
const assert = std.debug.assert;

pub const Boats = struct {
    pub const id = "minecraft:boats";
    pub const Configuration = struct {
        seed: u64 = 0x626f617473,
        /// The columns holding boats, and the columns they tick in.
        columns: usize = 16384,
    };
    pub const Dependencies = struct {
        entities: *entities.Entities,
        players: *Players,
        player_states: *PlayerStates,
        mobs: *Mobs,
        dropped: *ItemEntities,
        inventories: *inventories.Inventories,
        storage: storage.Space,
        record_workspaces: *records.Workspaces,
        input: *Input,
        containers: *Containers,
        attributes: *EquipmentAttributes,
        collisions: *EntityCollisions,
    };

    /// The woods boats are made of, and bamboo, whose boat is a raft.
    pub const Variant = enum(u8) {
        oak,
        spruce,
        birch,
        jungle,
        acacia,
        cherry,
        dark_oak,
        pale_oak,
        mangrove,
        bamboo,
    };
    const variant_count = @typeInfo(Variant).@"enum".field_names.len;

    /// A boat's entity type: its wood, and whether it carries a chest, as AbstractChestBoat does.
    pub const Model = struct {
        variant: Variant,
        chest: bool = false,

        pub const count = variant_count * 2;

        pub fn index(self: Model) usize {
            return @backingInt(self.variant) + variant_count * @as(usize, @intFromBool(self.chest));
        }

        pub fn at(position: usize) Model {
            return .{ .variant = @fromBackingInt(@intCast(position % variant_count)), .chest = position >= variant_count };
        }

        /// The entity type's name, which the boat's item has too.
        pub fn name(self: Model) []const u8 {
            return switch (self.variant) {
                inline else => |tag| if (self.chest) "minecraft:" ++ comptime path(tag, true) else "minecraft:" ++ comptime path(tag, false),
            };
        }

        /// The translation key of its name, as Entity.getDisplayName gives it.
        pub fn title(self: Model) []const u8 {
            return switch (self.variant) {
                inline else => |tag| if (self.chest) "entity.minecraft." ++ comptime path(tag, true) else "entity.minecraft." ++ comptime path(tag, false),
            };
        }

        fn path(comptime variant: Variant, comptime chest: bool) []const u8 {
            const hull = if (variant == .bamboo) "raft" else "boat";
            return @tagName(variant) ++ (if (chest) "_chest_" else "_") ++ hull;
        }

        /// AbstractBoat.getMaxPassengers: a chest takes a seat.
        pub fn capacity(self: Model) u8 {
            return if (self.chest) 1 else Riders.max;
        }
    };

    /// A boat in memory, and where its record in the store lies.
    pub const Stored = struct {
        boat: Boat,
        model: Model,
        stored: ?entities.Column = null,
        dirty: bool = true,
        /// Who rides it, in AbstractBoat's order: the first steers.
        riders: Riders = .{},
        /// AbstractBoat.DATA_ID_PADDLE_LEFT and DATA_ID_PADDLE_RIGHT, as its rider's client says.
        paddles: [2]bool = .{ false, false },
        steer: Steer = .{},
    };

    /// What rides a boat: a player, as the slot, connection and life it boarded with, or a mob,
    /// as its slot and id.
    pub const Rider = union(enum) {
        player: struct { slot: usize, generation: u32, life: u32 },
        mob: struct { slot: u32, id: u64 },
    };

    pub const Riders = struct {
        /// AbstractBoat.getMaxPassengers of a boat without a chest, the most any boat carries.
        pub const max = 2;
        list: [max]Rider = undefined,
        count: u8 = 0,

        fn remove(self: *Riders, at: usize) void {
            std.mem.copyForwards(Rider, self.list[at .. self.count - 1], self.list[at + 1 .. self.count]);
            self.count -= 1;
        }

        fn indexOf(self: *const Riders, rider: Rider) ?usize {
            for (self.list[0..self.count], 0..) |held, at| if (std.meta.eql(held, rider)) return at;
            return null;
        }
    };

    /// What handleMoveVehicle holds of a boat its rider's client moves: where the tick began, where
    /// the last move left it, and the moves since, which block effects trace.
    pub const Steer = struct {
        first_good: [3]f64 = .{ 0, 0, 0 },
        last_good: [3]f64 = .{ 0, 0, 0 },
        moves: [8]block_effects.Movement = undefined,
        move_count: u8 = 0,

        fn record(self: *Steer, movement: block_effects.Movement) void {
            // Vanilla keeps a hundred, merging the oldest: a tick of moves from a client is few.
            if (self.move_count == self.moves.len) {
                self.moves[1] = .{ .from = self.moves[0].from, .to = self.moves[1].to, .axis_independent = false };
                std.mem.copyForwards(block_effects.Movement, self.moves[0 .. self.moves.len - 1], self.moves[1..]);
                self.move_count -= 1;
            }
            self.moves[self.move_count] = movement;
            self.move_count += 1;
        }
    };

    /// What a boat keeps in the store beside its body, which is what vanilla saves of one: how far
    /// it fell, its fire, how frozen it is, and whether it was on the ground. The rest begins anew
    /// when it is read, as vanilla's does. A chest's contents are kept as its owner's slots.
    pub const Saved = struct {
        pub const encoded_size = 18;
        fall_distance: f64 = 0,
        fire_ticks: i16 = 0,
        ticks_frozen: i32 = 0,
        on_ground: bool = false,
        model: Model,

        pub fn of(stored: Stored) Saved {
            const boat = stored.boat;
            return .{ .fall_distance = boat.fall_distance, .fire_ticks = @intCast(std.math.clamp(boat.fire_ticks, std.math.minInt(i16), std.math.maxInt(i16))), .ticks_frozen = boat.ticks_frozen, .on_ground = boat.on_ground, .model = stored.model };
        }

        pub fn encode(self: Saved) [encoded_size]u8 {
            var bytes: [encoded_size]u8 = @splat(0);
            bytes[0] = 1;
            std.mem.writeInt(u64, bytes[1..9], @bitCast(self.fall_distance), .little);
            std.mem.writeInt(i16, bytes[9..11], self.fire_ticks, .little);
            std.mem.writeInt(i32, bytes[11..15], self.ticks_frozen, .little);
            bytes[15] = @intFromBool(self.on_ground);
            bytes[16] = @backingInt(self.model.variant);
            bytes[17] = @intFromBool(self.model.chest);
            return bytes;
        }

        pub fn decode(bytes: []const u8) !Saved {
            if (bytes.len != encoded_size or bytes[0] != 1 or bytes[15] > 1 or bytes[16] >= variant_count or bytes[17] > 1) return error.CorruptBoat;
            const fall_distance: f64 = @bitCast(std.mem.readInt(u64, bytes[1..9], .little));
            if (!std.math.isFinite(fall_distance)) return error.CorruptBoat;
            return .{
                .fall_distance = fall_distance,
                .fire_ticks = std.mem.readInt(i16, bytes[9..11], .little),
                .ticks_frozen = std.mem.readInt(i32, bytes[11..15], .little),
                .on_ground = bytes[15] == 1,
                .model = .{ .variant = @fromBackingInt(@intCast(bytes[16])), .chest = bytes[17] == 1 },
            };
        }
    };

    const record_prefix = 0x42;
    pub const record_bytes = entities.encoded_bytes + Saved.encoded_size;

    deps: Dependencies,
    config: Configuration,
    allocator: std.mem.Allocator,
    /// The entity type of each model, by its index.
    types: [Model.count]u32,
    /// What lookups of boats are after, among every kind in the space.
    kinds: entities.Kinds,
    boats: entities.BodyTable(Stored),
    places: *entities.Places,
    residency: entities.Residency,
    /// Room to copy ids into, for passes that change what they pass over.
    scratch: []entities.Id,
    centers: []entities.residency.Center,
    last_centers: []entities.residency.Center,
    last_center_count: usize = 0,
    last_radius: i32 = 0,
    last_ticking: u64 = std.math.maxInt(u64),
    last_held: u64 = std.math.maxInt(u64),
    /// Seeds for new boats' randoms, as RandomSupport.generateUniqueSeed gives each entity its own.
    seeds: std.Random.DefaultPrng,
    table: records.Table,
    /// Boats gone since their records were last let go.
    retired: []entities.Id,
    retired_count: usize = 0,
    /// Boats whose replicated state changed since replication last looked.
    replicated: lightning_rod.system.IndexSet,
    /// Animations of boats since replication last sent them, in order.
    animations: [64]Animation = undefined,
    animation_count: usize = 0,
    /// Ticks since start, which boarding waits counted against.
    now: u64 = 0,
    /// By player slot, the tick before which it may not board, as Entity.boardingCooldown.
    boarding: []u64,
    /// By slot, the tick before which a mob may not board, the mobs riding, and what each rides.
    mob_boarding: []u64,
    /// The boat ticking, for the world's answers to its tick.
    ticking: ?Ticking = null,
    /// How the boat ticking moves: by itself, or by its rider, until an eject frees it.
    steering: boat_module.Steering = .{},
    work: boat_module.Scratch = .{},

    const Ticking = struct { slot: u32 };
    pub const Animation = struct { slot: u32, animation: u8 };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Boats {
        const self = try allocator.create(Boats);
        const bound = deps.entities.directory.capacity();
        var types: [Model.count]u32 = undefined;
        var kind_list: [Model.count]u32 = undefined;
        for (&types, &kind_list, 0..) |*kind, *listed, index| {
            kind.* = @intCast(game_data.registry.entityId(Model.at(index).name()) orelse return error.UnknownEntityType);
            listed.* = kind.*;
        }
        const kinds: entities.Kinds = .of(&kind_list);
        self.* = .{
            .deps = deps,
            .config = config,
            .allocator = allocator,
            .types = types,
            .kinds = kinds,
            .boats = try .init(allocator, deps.entities, kinds),
            .places = &deps.entities.places,
            .residency = try .init(allocator, config.columns),
            .scratch = try allocator.alloc(entities.Id, bound),
            .centers = try allocator.alloc(entities.residency.Center, deps.players.records.len),
            .last_centers = try allocator.alloc(entities.residency.Center, deps.players.records.len),
            .seeds = .init(config.seed),
            .table = records.Table.init(deps.storage, deps.record_workspaces.resources),
            .retired = try allocator.alloc(entities.Id, bound),
            .replicated = try .init(allocator, bound),
            .boarding = try allocator.alloc(u64, deps.players.records.len),
            .mob_boarding = try allocator.alloc(u64, bound),
        };
        @memset(self.boarding, 0);
        @memset(self.mob_boarding, 0);
        // EntityType's clientTrackingRange of 10 chunks.
        try deps.entities.declare(.{ .kinds = kinds, .tracking_range = 10 * 16 });
        try deps.entities.addTicker(.init(Boats, self, kinds, 1));
        try deps.entities.addColumnHolder(.init(Boats, self, columnLoaded, columnUnloaded));
        try self.boats.register();
        // AbstractBoat: canBeCollidedWith, isPushable and isPickable while it is in the world, and
        // its own push.
        try deps.collisions.register(kinds, .{ .context = self, .solid = boatBox, .pushable = boatBox, .pickable = boatBox, .position = boatPosition, .nudge = boatNudge, .pushes = boatPushes });
        deps.mobs.boats = self;
        try deps.input.on(.vehicle_move, self, onVehicleMove);
        try deps.input.on(.steer_boat, self, onSteerBoat);
        deps.players.openVehicleInventories(.{ .context = self, .open = openRidden });
        return self;
    }

    /// The model of a boat's entity type.
    pub fn modelOf(self: *const Boats, kind: u32) ?Model {
        for (self.types, 0..) |known, index| if (known == kind) return Model.at(index);
        return null;
    }

    pub fn count(self: *const Boats) usize {
        return self.boats.count();
    }

    /// The ids of the boats in memory, gone ones not yet forgotten included, by id.
    pub fn ids(self: *Boats) []const entities.Id {
        return self.boats.ids(self.scratch);
    }

    pub fn shapeOf(kind: u32) entities.Shape {
        return .{ .kind = kind, .half_width = boat_module.box_width / 2, .height = boat_module.box_height };
    }

    pub const Spawn = struct {
        model: Model,
        world: u32,
        position: [3]f64,
        velocity: [3]f64 = .{ 0, 0, 0 },
        yaw: f32 = 0,
    };

    /// A boat comes into the world where asked, as Level.addFreshEntity adds one.
    pub fn spawn(self: *Boats, request: Spawn) !entities.Id {
        for (request.position) |component| assert(std.math.isFinite(component) and @abs(component) <= 30_000_000);
        if (self.deps.players.deps.worlds.get(request.world) == null) return error.UnknownWorld;
        errdefer self.deps.storage.fail();
        const entity = self.deps.entities.next_id;
        const kind = self.types[request.model.index()];
        const state: entities.State = .{ .uuid = self.uuidOf(entity), .kind = kind, .world = request.world, .position = request.position, .velocity = request.velocity, .yaw = request.yaw };
        if (!entities.valid(state)) return error.InvalidEntity;
        const created = try self.deps.entities.reserveIds(1);
        assert(created == entity);
        const boat: Boat = .{ .random = JavaRandom.init(@bitCast(self.seeds.next())), .old_position = request.position };
        try self.boats.add(entity, state, .{ .boat = boat, .model = request.model }, shapeOf(kind));
        try self.residency.hold(entities.space.columnOf(request.world, request.position));
        self.replicated.insert(self.boats.slotOf(entity).?);
        return entity;
    }

    /// A random UUID of the kind Mth.createInsecureUUID makes, from the entity's own seed.
    fn uuidOf(self: *Boats, entity: entities.Id) u128 {
        var random = std.Random.DefaultPrng.init(self.config.seed ^ entity);
        var uuid = random.random().int(u128);
        // Version 4, variant 2, as UUID.randomUUID marks one.
        uuid = (uuid & ~(@as(u128, 0xf) << 76)) | (@as(u128, 4) << 76);
        uuid = (uuid & ~(@as(u128, 0x3) << 62)) | (@as(u128, 2) << 62);
        return uuid;
    }

    /// A boat as it is, for tests and for whoever looks at one at a time.
    pub fn get(self: *Boats, entity: entities.Id) !?struct { stored: Stored, body: ?entities.State } {
        const stored = try self.boats.getById(entity) orelse return null;
        return .{ .stored = stored, .body = try self.deps.entities.getById(entity) };
    }

    /// Who hurt a boat, as VehicleEntity.hurtServer reads the damage source: a player, and whether
    /// in creative, or the world.
    pub const Attacker = union(enum) { world, player: struct { slot: usize, creative: bool } };

    /// VehicleEntity.hurtServer: the boat wobbles, takes ten times the damage, and breaks past 40,
    /// or at once for a player in creative, who takes nothing from it.
    pub fn hurt(self: *Boats, slot: u32, amount: f32, attacker: Attacker) !bool {
        const stored = self.boats.ptr(slot);
        const boat = &stored.boat;
        if (boat.removed) return true;
        boat.hurt_dir = -boat.hurt_dir;
        boat.hurt_time = 10;
        boat.hurt_marked = true;
        boat.damage += amount * 10;
        stored.dirty = true;
        self.replicated.insert(slot);
        const creative = attacker == .player and attacker.player.creative;
        if (!creative and boat.damage > 40) {
            try self.destroy(slot);
        } else if (creative) {
            try self.discard(slot);
        }
        return true;
    }

    /// VehicleEntity.destroy: the boat goes, and its item drops where it was, as
    /// Entity.spawnAtLocation drops one.
    fn destroy(self: *Boats, slot: u32) !void {
        const stored = self.boats.ptr(slot);
        const state = self.deps.entities.body(slot).?.*;
        try self.discard(slot);
        const random = self.deps.mobs.levelRandom();
        const dx = random.nextDouble() * 0.2 - 0.1;
        const dz = random.nextDouble() * 0.2 - 0.1;
        const kind: u32 = @intCast(game_data.registry.itemId(stored.model.name()) orelse return error.UnknownItem);
        const stack: inventories.Stack = .{ .item = try item_data.define(self.deps.inventories, kind, &.{}), .count = 1 };
        _ = try self.deps.dropped.create(state.world, state.position, .{ dx, 0.2, dz }, stack);
    }

    /// Entity.discard: the boat is removed, its body and place at the tick's end, and its riders
    /// get off, as Entity.setRemoved has them stop riding.
    fn discard(self: *Boats, slot: u32) !void {
        const stored = self.boats.ptr(slot);
        if (stored.boat.removed) return;
        // AbstractChestBoat.remove drops the chest's contents before the boat goes.
        if (stored.model.chest) try self.dropContents(slot);
        stored.boat.removed = true;
        self.retired[self.retired_count] = self.deps.entities.directory.entry(slot).id;
        self.retired_count += 1;
        try self.eject(slot);
    }

    /// Entity.push(x, y, z) on a boat: its velocity changes, and replication sends it.
    fn nudge(self: *Boats, slot: u32, by: [2]f64) void {
        const state = self.deps.entities.body(slot).?;
        state.velocity[0] += by[0];
        state.velocity[2] += by[1];
        const stored = self.boats.ptr(slot);
        stored.boat.impulse = true;
        stored.dirty = true;
        self.replicated.insert(slot);
    }

    fn boatNudge(context: *anyopaque, slot: u32, by: [2]f64) void {
        const self: *Boats = @ptrCast(@alignCast(context));
        self.nudge(slot, by);
    }

    fn boatPosition(context: *anyopaque, slot: u32) [3]f64 {
        const self: *Boats = @ptrCast(@alignCast(context));
        return self.deps.entities.body(slot).?.position;
    }

    /// AbstractBoat.push(Entity): another boat counts only from below this one's top, anything
    /// else only from no higher than its bottom.
    fn boatPushes(context: *anyopaque, _: u32, own: Box, other: u32, other_box: Box) bool {
        const self: *Boats = @ptrCast(@alignCast(context));
        if (self.isBoat(other)) return other_box.min[1] < own.max[1];
        return other_box.min[1] <= own.min[1];
    }

    /// Entity.push(x, y, z) from a hit: the boat's velocity changes, and replication sends it.
    pub fn knock(self: *Boats, slot: u32, by: [3]f64) void {
        const state = self.deps.entities.body(slot).?;
        for (&state.velocity, by) |*component, add| component.* += add;
        const stored = self.boats.ptr(slot);
        stored.boat.impulse = true;
        stored.dirty = true;
        self.replicated.insert(slot);
    }

    /// Entity.igniteForSeconds, from Fire Aspect: it burns for at least that long.
    pub fn ignite(self: *Boats, slot: u32, seconds: f32) void {
        const stored = self.boats.ptr(slot);
        const ticks = mth.floorFloat(seconds * 20.0);
        if (stored.boat.fire_ticks < ticks) stored.boat.fire_ticks = ticks;
        stored.dirty = true;
        self.replicated.insert(slot);
    }

    /// ClientboundAnimatePacket for a boat, as a crit's sparks: held for replication to send.
    pub fn animate(self: *Boats, slot: u32, animation: u8) void {
        if (self.animation_count == self.animations.len) return;
        self.animations[self.animation_count] = .{ .slot = slot, .animation = animation };
        self.animation_count += 1;
    }

    fn boatBox(context: *anyopaque, slot: u32) anyerror!?Box {
        const self: *Boats = @ptrCast(@alignCast(context));
        if (self.boats.ptr(slot).boat.removed) return null;
        return boat_module.boxAt(self.deps.entities.body(slot).?.position);
    }

    /// Whether the boat in the slot is still in the world, as what collides with and pushes others.
    pub fn solid(self: *const Boats, slot: u32) bool {
        return !self.boats.ptr(slot).boat.removed;
    }

    /// Whether a pickable entity but `except` whose box meets `query` holds the point, as
    /// BoatItem.use asks of Level.getEntities with the player and EntitySelector.CAN_BE_PICKED.
    pub fn pickableHolds(self: *Boats, world: u32, query: Box, point: [3]f64, except: u32) !bool {
        const Find = struct {
            point: [3]f64,
            found: bool = false,
            fn visit(context: *anyopaque, _: entities.space.Entry, box: Box) anyerror!bool {
                const find: *@This() = @ptrCast(@alignCast(context));
                // AABB.contains, the pick radius none.
                for (0..3) |axis| if (!(find.point[axis] >= box.min[axis] and find.point[axis] < box.max[axis])) return false;
                find.found = true;
                return true;
            }
        };
        var find: Find = .{ .point = point };
        try self.deps.collisions.each(world, query, except, .pickable, .{ .context = &find, .visit = Find.visit });
        return find.found;
    }

    /// CollisionGetter.noCollision for a boat with its box there, the one in `slot` or one about to
    /// be placed: no block shape, no entity it would collide with, and not the world border's
    /// outside.
    pub fn clear(self: *Boats, world: u32, box: Box, bottom: f64, slot: u32) !bool {
        const level = self.deps.mobs.level(world);
        return body.noCollision(&level, box, .{ .bottom = bottom, .slot = slot, .vehicle = true });
    }

    /// Before entities tick: boats near players come into memory.
    pub fn prepareTick(self: *Boats) !void {
        errdefer self.deps.storage.fail();
        self.now += 1;
        try self.forgetRetired();
        if (!self.deps.entities.columns_followed) try self.refresh();
    }

    /// One boat at a time, as a boat's tick pushes others of its kind.
    pub fn tickRun(self: *Boats, run: []const entities.order.Entry) !void {
        errdefer self.deps.storage.fail();
        for (run) |entry| try self.tickOne(entry.slot);
    }

    /// After entities tick: the boats that went are let go.
    pub fn finishTick(self: *Boats) !void {
        errdefer self.deps.storage.fail();
        try self.forgetRetired();
    }

    fn tickOne(self: *Boats, slot: u32) !void {
        const stored = self.boats.ptr(slot);
        if (stored.boat.removed) return;
        const state = self.deps.entities.body(slot) orelse return error.CorruptBoat;
        // Visited but not ticked: moved this tick where nothing ticks.
        if (!self.places.ticks(entities.space.columnOf(state.world, state.position))) return;
        const before = state.*;
        const replicated_before = replicatedOf(stored.boat);
        const level = self.deps.mobs.level(state.world);
        self.ticking = .{ .slot = slot };
        defer self.ticking = null;
        // A boat a player steers is moved by its client: its tick traces the moves since the last.
        self.steering = .{ .steered = self.steeredBy(slot) != null, .movements = stored.steer.moves[0..stored.steer.move_count] };
        try boat_module.tick(&level, self.around(state.world, slot), state, &stored.boat, &self.work, &self.steering);
        stored.steer.move_count = 0;
        // AbstractBoat.tick: paddles turn only under a player.
        if (stored.riders.count == 0 and (stored.paddles[0] or stored.paddles[1])) stored.paddles = .{ false, false };
        if (stored.boat.removed and !self.isRetired(slot)) {
            // Gone below the world, as Entity.onBelowWorld discards it.
            stored.boat.removed = false;
            try self.discard(slot);
        }
        if (!stored.boat.removed) try self.pushAround(slot);
        // ServerLevel.tickPassenger: its riders tick after it.
        try self.rideTicks(slot);
        stored.steer.first_good = state.position;
        stored.steer.last_good = state.position;
        if (!std.meta.eql(before, state.*)) {
            stored.dirty = true;
            try self.places.move(slot, state.world, state.position);
        }
        if (!std.meta.eql(replicated_before, replicatedOf(stored.boat))) self.replicated.insert(slot);
    }

    fn isRetired(self: *const Boats, slot: u32) bool {
        const entity = self.deps.entities.directory.entry(slot).id;
        return std.mem.indexOfScalar(entities.Id, self.retired[0..self.retired_count], entity) != null;
    }

    /// What of a boat replication sends beside its body.
    fn replicatedOf(boat: Boat) [5]i64 {
        return .{ boat.hurt_time, boat.hurt_dir, @as(i32, @bitCast(boat.damage)), boat.bubble_time, @intFromBool(boat.fire_ticks > 0) };
    }

    /// AbstractBoat.tick's end: what is pushable in the box a little wider and a little lower than
    /// the boat's, in the order the level finds them, boards it if it is a small living thing the
    /// boat has room for and no player steers it, and is pushed away otherwise. What rides it is
    /// passed over.
    fn pushAround(self: *Boats, slot: u32) !void {
        const state = self.deps.entities.body(slot).?.*;
        const box = boat_module.boxAt(state.position).inflate(@as(f32, 0.2), @as(f32, -0.01), @as(f32, 0.2));
        const Around = struct {
            boats: *Boats,
            slot: u32,
            own: ?Box,

            fn visit(context: *anyopaque, entry: entities.space.Entry, found: Box) anyerror!bool {
                const reach: *@This() = @ptrCast(@alignCast(context));
                const boats = reach.boats;
                const owned = boats.deps.entities;
                const carrier = boats.boats.ptr(reach.slot);
                // A small living thing that rides nothing, not a player, boards a boat no player
                // steers that has room.
                const width = found.max[0] - found.min[0];
                if (boats.deps.mobs.kinds.has(entry.shape.kind) and boats.steeredBy(reach.slot) == null and carrier.riders.count < carrier.model.capacity() and
                    owned.vehicleOf(entry.slot) == null and width < boat_module.box_width)
                {
                    try boats.mountMob(reach.slot, entry.slot);
                    return false;
                }
                try boats.deps.collisions.push(reach.slot, reach.own, entry.slot, found);
                return false;
            }
        };
        var reach: Around = .{ .boats = self, .slot = slot, .own = try boatBox(self, slot) };
        try self.deps.collisions.each(state.world, box, slot, .pushable, .{ .context = &reach, .visit = Around.visit });
    }

    fn around(self: *Boats, world: u32, slot: u32) boat_module.Around {
        return .{
            .context = self,
            .slot = slot,
            .hurt = hurtByWorld,
            .sound = sound,
            .destroy_block = destroyBlock,
            .break_block = breakBlock,
            .lower_cauldron = lowerCauldron,
            .eject = ejectTicking,
            .level_random = self.deps.mobs.levelRandom(),
            .mob_griefing = self.deps.mobs.mobGriefing(),
            .ultrawarm = self.deps.mobs.ultrawarm(world),
        };
    }

    fn hurtByWorld(context: *anyopaque, amount: f32) anyerror!bool {
        const self: *Boats = @ptrCast(@alignCast(context));
        return self.hurt(self.ticking.?.slot, amount, .world);
    }

    fn sound(context: *anyopaque, kind: boat_module.Sound, volume: f32, pitch: f32) void {
        const self: *Boats = @ptrCast(@alignCast(context));
        const state = self.deps.entities.body(self.ticking.?.slot).?;
        const name = switch (kind) {
            .generic_splash => "minecraft:entity.generic.splash",
            .generic_burn => "minecraft:entity.generic.burn",
            .generic_extinguish_fire => "minecraft:entity.generic.extinguish_fire",
            .honey_block_slide => "minecraft:block.honey_block.slide",
        };
        const mobs = self.deps.mobs;
        mobs.effects.sound(state.world, .{ .x = state.position[0], .y = state.position[1], .z = state.position[2] }, name, .neutral, volume, pitch, @bitCast(mobs.sound_seeds.next()), null);
    }

    fn destroyBlock(context: *anyopaque, world: u32, position: [3]i32) anyerror!void {
        const self: *Boats = @ptrCast(@alignCast(context));
        return self.deps.mobs.destroyBlock(world, position);
    }

    fn breakBlock(context: *anyopaque, world: u32, position: [3]i32) anyerror!void {
        const self: *Boats = @ptrCast(@alignCast(context));
        return self.deps.mobs.breakBlock(world, position);
    }

    /// Entity.ejectPassengers for the boat ticking, which then moves itself.
    fn ejectTicking(context: *anyopaque) anyerror!void {
        const self: *Boats = @ptrCast(@alignCast(context));
        try self.eject(self.ticking.?.slot);
        self.steering.steered = false;
    }

    fn lowerCauldron(context: *anyopaque, world: u32, position: [3]i32) anyerror!void {
        const self: *Boats = @ptrCast(@alignCast(context));
        return self.deps.mobs.lowerCauldron(world, position);
    }

    // Riding.

    /// AbstractBoat.interact: a player not sneaking boards a boat not too long under water. Then
    /// AbstractChestBoat.interact: one that did not board opens the chest, sneaking or with the
    /// boat full.
    pub fn interact(self: *Boats, player_slot: usize, slot: u32) !void {
        const stored = self.boats.ptr(slot);
        if (stored.boat.removed) return;
        const sneaking = self.deps.players.records[player_slot].flags.sneaking;
        if (!sneaking and stored.boat.out_of_control < boat_module.out_of_control_limit) if (try self.mount(player_slot, slot)) return;
        if (!stored.model.chest) return;
        if (self.roomFor(slot) and !sneaking) return;
        try self.openChest(player_slot, slot);
    }

    /// AbstractChestBoat.openCustomInventoryScreen: the inventory key of a chest boat's rider.
    fn openRidden(context: *anyopaque, player_slot: usize) anyerror!void {
        const self: *Boats = @ptrCast(@alignCast(context));
        const slot = self.deps.players.vehicleOf(player_slot) orelse return;
        if (!self.isBoat(slot)) return;
        if (self.boats.ptr(slot).model.chest) try self.openChest(player_slot, slot);
    }

    /// Player.openMenu with the chest boat's ChestMenu.threeRows, titled with its name.
    fn openChest(self: *Boats, player_slot: usize, slot: u32) !void {
        const stored = self.boats.ptr(slot);
        const state = self.deps.entities.body(slot).?;
        try self.deps.containers.openEntity(player_slot, .{
            .context = self,
            .entity = self.deps.entities.directory.entry(slot).id,
            .world = state.world,
            .owner = Containers.EntityContainer.ownerOf(state.uuid),
            .title = stored.model.title(),
            .still_valid = chestStillValid,
        });
    }

    /// ContainerEntity.isChestVehicleStillValid: the boat is there, within the player's
    /// interaction range and four blocks more.
    fn chestStillValid(context: *anyopaque, entity: u64, player_slot: usize) anyerror!bool {
        const self: *Boats = @ptrCast(@alignCast(context));
        const slot = self.boats.slotOf(entity) orelse return false;
        if (self.boats.ptr(slot).boat.removed) return false;
        const state = self.deps.entities.body(slot).?;
        const player = &self.deps.players.records[player_slot];
        if (player.world != state.world) return false;
        return canInteractWithEntity(self.deps.attributes, player, player_slot, boat_module.boxAt(state.position), 4.0);
    }

    /// Containers.dropContents for a chest boat removed for good, as AbstractChestBoat.remove: each
    /// stack in pieces of 10 to 30 from a point in the block the boat is in, flung a little.
    fn dropContents(self: *Boats, slot: u32) !void {
        const state = self.deps.entities.body(slot).?.*;
        const owner = Containers.EntityContainer.ownerOf(state.uuid);
        var slots: [27]inventories.Slot = undefined;
        var contents: [27]inventories.Contents = undefined;
        for (&slots, 0..) |*destination, at| destination.* = .{ .owner = owner, .index = @intCast(at) };
        try self.deps.inventories.getMany(&slots, &contents);
        const random = self.deps.mobs.levelRandom();
        // EntityType.ITEM's width.
        const width: f64 = @as(f32, 0.25);
        const room = 1.0 - width;
        const middle = width / 2.0;
        for (slots, contents) |destination, value| {
            var stack = value.stack orelse continue;
            // Containers.dropItemStack.
            const x = @floor(state.position[0]) + random.nextDouble() * room + middle;
            const y = @floor(state.position[1]) + random.nextDouble() * room;
            const z = @floor(state.position[2]) + random.nextDouble() * room + middle;
            // A stack holds at most 99, as DataComponents.MAX_STACK_SIZE allows: 10 pieces at most.
            var spawns: [10]ItemEntities.Spawn = undefined;
            var made: [10]entities.Id = undefined;
            var pieces: usize = 0;
            while (stack.count > 0) : (pieces += 1) {
                const piece: @TypeOf(stack.count) = @intCast(@min(stack.count, random.nextIntBounded(21) + 10));
                stack.count -= piece;
                // ItemEntity's own push, overwritten.
                _ = random.nextDouble();
                _ = random.nextDouble();
                const velocity: [3]f64 = .{ random.triangle(0, 0.11485000171139836), random.triangle(0.2, 0.11485000171139836), random.triangle(0, 0.11485000171139836) };
                spawns[pieces] = .{ .world = state.world, .position = .{ x, y, z }, .velocity = velocity, .stack = .{ .item = stack.item, .count = piece } };
            }
            try self.deps.dropped.createMany(spawns[0..pieces], made[0..pieces]);
            const committed = try self.deps.inventories.editMany(&.{.{ .slot = destination, .revision = value.revision, .stack = null }});
            assert(committed);
        }
    }

    /// ServerPlayer.startRiding: Entity.startRiding's rules, then the rider is placed, told where
    /// it is and what it rides.
    fn mount(self: *Boats, player_slot: usize, slot: u32) !bool {
        const player = &self.deps.players.records[player_slot];
        const players = self.deps.players;
        if (players.vehicleOf(player_slot) == slot) return false;
        // Entity.canRide: not sneaking, and not just off a vehicle.
        if (player.flags.sneaking or self.now < self.boarding[player_slot]) return false;
        if (!self.roomFor(slot)) return false;
        if (players.vehicleOf(player_slot)) |was| if (self.isBoat(was)) try self.dismount(was, self.riderIndex(was, .{ .player = .{ .slot = player_slot, .generation = player.handle.?.generation, .life = player.life } }) orelse return false);
        const at = self.board(slot, .{ .player = .{ .slot = player_slot, .generation = player.handle.?.generation, .life = player.life } });
        self.deps.entities.ride(players.entitySlot(player_slot).?, slot);
        // ServerPlayer.startRiding: placed where the boat seats it, its client teleported there and
        // told what it rides.
        try self.deps.players.placeRider(player_slot, toPosition(self.seatOf(slot, at)));
        try self.deps.players.teleport(player, player.world, player.position, player.rotation);
        self.tellRider(player_slot, slot);
        return true;
    }

    /// AbstractBoat.tick taking a small living thing aboard, as Entity.startRiding does for it.
    fn mountMob(self: *Boats, slot: u32, mob: u32) !void {
        // Entity.canRide: not just off a vehicle; mobs never sneak.
        if (self.now < self.mob_boarding[mob]) return;
        if (!self.roomFor(slot)) return;
        _ = self.board(slot, .{ .mob = .{ .slot = mob, .id = self.deps.entities.directory.entry(mob).id } });
        self.deps.entities.ride(mob, slot);
    }

    /// AbstractBoat.canAddPassenger: room for one more, its eyes out of the water.
    fn roomFor(self: *Boats, slot: u32) bool {
        const stored = self.boats.ptr(slot);
        return stored.riders.count < stored.model.capacity() and !stored.boat.eye_in_water;
    }

    /// Entity.addPassenger: a player goes first, unless one is first already; where it went.
    fn board(self: *Boats, slot: u32, rider: Rider) usize {
        const stored = self.boats.ptr(slot);
        const first = rider == .player and (stored.riders.count == 0 or stored.riders.list[0] != .player);
        const at: usize = if (first) 0 else stored.riders.count;
        std.mem.copyBackwards(Rider, stored.riders.list[at + 1 .. stored.riders.count + 1], stored.riders.list[at..stored.riders.count]);
        stored.riders.list[at] = rider;
        stored.riders.count += 1;
        self.replicated.insert(slot);
        return at;
    }

    fn riderIndex(self: *Boats, slot: u32, rider: Rider) ?usize {
        return self.boats.ptr(slot).riders.indexOf(rider);
    }

    /// A mob whose slot is freed rides nothing, so what next takes the slot does not.
    pub fn forgetMob(self: *Boats, mob: u32) void {
        const slot = self.deps.entities.vehicleOf(mob) orelse return;
        if (!self.isBoat(slot)) return;
        const stored = self.boats.ptr(slot);
        for (stored.riders.list[0..stored.riders.count], 0..) |rider, at| if (rider == .mob and rider.mob.slot == mob) {
            self.letGo(slot, at);
            return;
        };
        self.deps.entities.alight(mob);
    }

    /// Whether the entity in a slot is a boat.
    fn isBoat(self: *const Boats, slot: u32) bool {
        return self.kinds.has(self.deps.entities.directory.entry(slot).kind);
    }

    /// Entity.positionRider with AbstractBoat.getPassengerAttachmentPoint: where the boat seats its
    /// rider at `index`, the rider's vehicle attachment under it, a player's 0.6 up, an animal's
    /// none and a fifth of a block forward when it has company; one alone in a chest boat sits
    /// before the chest.
    fn seatOf(self: *Boats, slot: u32, index: usize) [3]f64 {
        const stored = self.boats.ptr(slot);
        const state = self.deps.entities.body(slot).?;
        const rider = stored.riders.list[index];
        // Boat.rideHeight and Raft.rideHeight, in floats.
        const ride_height: f64 = if (stored.model.variant == .bamboo) boat_module.box_height * @as(f32, 0.8888889) else boat_module.box_height / 3.0;
        // AbstractChestBoat.getSinglePassengerXOffset: forward of the chest.
        var offset: f32 = if (stored.model.chest) 0.15 else 0;
        if (stored.riders.count > 1) {
            offset = if (index == 0) 0.2 else -0.6;
            if (rider == .mob) offset += 0.2;
        }
        const attachment: f64 = if (rider == .player) 0.6 else 0;
        // Vec3.yRot of (0, rideHeight, offset) by the boat's turn.
        const angle = -state.yaw * 0.017453292;
        const cosine: f64 = mth.cos(angle);
        const sine: f64 = mth.sin(angle);
        const along: f64 = offset;
        return .{ state.position[0] + along * sine, state.position[1] + ride_height - attachment, state.position[2] + along * cosine };
    }

    /// After the boat's tick, its riders' ride ticks, in their order: one gone is let go, a player
    /// sneaking gets off, and the rest tick and are seated.
    fn rideTicks(self: *Boats, slot: u32) !void {
        const stored = self.boats.ptr(slot);
        const held = stored.riders;
        for (held.list[0..held.count]) |rider| {
            if (stored.riders.indexOf(rider) == null) continue;
            if (!try self.present(rider, slot)) {
                self.letGo(slot, stored.riders.indexOf(rider).?);
                continue;
            }
            switch (rider) {
                .player => |who| {
                    const player = &self.deps.players.records[who.slot];
                    // Player.rideTick: one sneaking gets off, and stops sneaking.
                    if (player.flags.sneaking) {
                        try self.dismount(slot, stored.riders.indexOf(rider).?);
                        player.flags.sneaking = false;
                        continue;
                    }
                    try self.deps.players.placeRider(who.slot, toPosition(self.seatOf(slot, stored.riders.indexOf(rider).?)));
                    // AbstractBoat.clampRotation.
                    const yaw = self.deps.entities.body(slot).?.yaw;
                    const off = mth.wrapDegrees(player.rotation.yaw - yaw);
                    const kept = mth.clamp(off, -105.0, 105.0);
                    player.rotation.yaw += kept - off;
                },
                .mob => |carried| {
                    try self.deps.mobs.rideTick(carried.slot);
                    // Its tick may have ended it.
                    if (!try self.present(rider, slot)) {
                        if (stored.riders.indexOf(rider)) |at| self.letGo(slot, at);
                        continue;
                    }
                    const at = stored.riders.indexOf(rider).?;
                    const state = self.deps.entities.body(slot).?;
                    try self.deps.mobs.seatRider(carried.slot, self.seatOf(slot, at), state.yaw, stored.riders.count == stored.model.capacity());
                },
            }
        }
    }

    /// Whether a rider is still what boarded, in the boat's world: a player of the same connection
    /// and life, alive, riding it; a mob of the same id, alive.
    fn present(self: *Boats, rider: Rider, slot: u32) !bool {
        switch (rider) {
            .player => |who| {
                const player = &self.deps.players.records[who.slot];
                const handle = player.handle orelse return false;
                return handle.generation == who.generation and player.life == who.life and player.inWorld() and self.deps.players.vehicleOf(who.slot) == slot and
                    player.world == self.deps.entities.body(slot).?.world and self.deps.player_states.of(player).health > 0;
            },
            .mob => |carried| {
                const mobs = self.deps.mobs;
                if (mobs.slotOf(carried.id) != carried.slot) return false;
                const mob = try mobs.inSlot(carried.slot);
                return !mob.entity.removed and mob.alive();
            },
        }
    }

    /// A rider gone from the world, or riding no more, is let go without being moved.
    fn letGo(self: *Boats, slot: u32, at: usize) void {
        const stored = self.boats.ptr(slot);
        const rider = stored.riders.list[at];
        stored.riders.remove(at);
        self.replicated.insert(slot);
        switch (rider) {
            .player => |who| {
                const player = &self.deps.players.records[who.slot];
                if (player.handle != null and player.handle.?.generation == who.generation and self.deps.players.vehicleOf(who.slot) == slot) self.deps.entities.alight(self.deps.players.entitySlot(who.slot).?);
            },
            // The slot may be another's by now, which rides what it rides.
            .mob => |carried| if (self.deps.entities.vehicleOf(carried.slot) == slot) self.deps.entities.alight(carried.slot),
        }
    }

    /// Entity.stopRiding for the rider at `at`: off the boat, kept from boarding for 60 ticks, and
    /// set down where LivingEntity.dismountVehicle puts it; a player is told it rides nothing.
    fn dismount(self: *Boats, slot: u32, at: usize) !void {
        const stored = self.boats.ptr(slot);
        const rider = stored.riders.list[at];
        // Where it goes is found with the rider off the boat, as removeVehicle comes first.
        stored.riders.remove(at);
        self.replicated.insert(slot);
        switch (rider) {
            .player => |who| {
                const player = &self.deps.players.records[who.slot];
                self.deps.entities.alight(self.deps.players.entitySlot(who.slot).?);
                self.boarding[who.slot] = self.now + 60;
                self.tellRider(who.slot, slot);
                const position = try self.dismountLocation(slot, .{ player.position.x, player.position.y, player.position.z }, player.rotation.yaw, 0.6, &.{ 1.8, 1.5, 0.6 });
                try self.deps.players.teleport(player, player.world, toPosition(position), player.rotation);
            },
            .mob => |carried| {
                self.deps.entities.alight(carried.slot);
                self.mob_boarding[carried.slot] = self.now + 60;
                const mob = try self.deps.mobs.inSlot(carried.slot);
                const width = living.width(self.deps.mobs, mob);
                const position = try self.dismountLocation(slot, mob.motion.position, mob.motion.yaw, width, &.{living.height(self.deps.mobs, mob)});
                try self.deps.mobs.dismountTo(carried.slot, position);
            },
        }
    }

    /// Entity.ejectPassengers: the last first.
    fn eject(self: *Boats, slot: u32) !void {
        const stored = self.boats.ptr(slot);
        while (stored.riders.count > 0) {
            const at = stored.riders.count - 1;
            if (try self.present(stored.riders.list[at], slot)) {
                try self.dismount(slot, at);
            } else self.letGo(slot, at);
        }
    }

    /// LivingEntity.dismountVehicle: beside a boat still there, as AbstractBoat finds room for a
    /// rider of the width and the heights of its poses, else where the rider is, no lower than
    /// the boat.
    fn dismountLocation(self: *Boats, slot: u32, at: [3]f64, yaw: f32, width: f32, heights: []const f32) ![3]f64 {
        const stored = self.boats.ptr(slot);
        const state = self.deps.entities.body(slot).?;
        if (stored.boat.removed) return .{ at[0], @max(at[1], state.position[1]), at[2] };
        // AbstractBoat.getDismountLocationForPassenger, from Entity.getCollisionHorizontalEscapeVector.
        const reach = (@as(f64, boat_module.box_width * std.math.sqrt2) + @as(f64, width) + @as(f64, @as(f32, 1.0e-5))) / 2.0;
        const turn = yaw * 0.017453292;
        const f = -mth.sin(turn);
        const g = mth.cos(turn);
        const h = @max(@abs(f), @abs(g));
        const x = state.position[0] + @as(f64, f) * reach / @as(f64, h);
        const z = state.position[2] + @as(f64, g) * reach / @as(f64, h);
        const top = boat_module.boxAt(state.position).max[1];
        const above: [3]i32 = .{ mth.floor(x), mth.floor(top), mth.floor(z) };
        const level = self.deps.mobs.level(state.world);
        if ((try level.fluid(above[0], above[1] - 1, above[2])).fluid != .water) {
            var floors: [2]f64 = undefined;
            var found: usize = 0;
            for ([2]i32{ above[1], above[1] - 1 }) |y| {
                const floor = try blockFloorHeight(&level, .{ above[0], y, above[2] });
                if (std.math.isInf(floor) or !(floor < 1.0)) continue;
                floors[found] = @as(f64, @floatFromInt(y)) + floor;
                found += 1;
            }
            // Its dismount poses, each tried on every floor.
            for (heights) |tall| for (floors[0..found]) |y| {
                const room = body.makeBox(.{ x, y, z }, width, tall);
                if (try body.canDismountTo(&level, room, .{ .bottom = y })) return .{ x, y, z };
            };
        }
        return .{ state.position[0], top, state.position[2] };
    }

    /// BlockGetter.getBlockFloorHeight: how high the floor stands in a block, from the block below
    /// when it has none of its own.
    fn blockFloorHeight(level: *const body.Level, at: [3]i32) !f64 {
        const own = body.contextFreeBoxes(try level.state(at[0], at[1], at[2]), at[0], at[2]);
        if (own.count > 0) return topOf(own);
        const below = body.contextFreeBoxes(try level.state(at[0], at[1] - 1, at[2]), at[0], at[2]);
        if (below.count == 0) return -std.math.inf(f64);
        const reach = topOf(below);
        return if (reach >= 1.0) reach - 1.0 else -std.math.inf(f64);
    }

    fn topOf(boxes: game_data.physics.Boxes) f64 {
        var top: f64 = -std.math.inf(f64);
        for (0..boxes.count) |index| top = @max(top, boxes.get(index)[4]);
        return top;
    }

    fn toPosition(at: [3]f64) minecraft.Position {
        return .{ .x = at[0], .y = at[1], .z = at[2] };
    }

    /// ClientboundSetPassengersPacket of a boat, to a rider that boarded or left it.
    fn tellRider(self: *Boats, player_slot: usize, slot: u32) void {
        const player = &self.deps.players.records[player_slot];
        const handle = player.handle orelse return;
        _ = self.deps.players.sendPacket(writePassengers, player.protocol, handle, .{ entities.Entities.networkOfSlot(slot), self.passengersOf(slot) });
    }

    /// What a boat carries, by network id, in its order: players' ids are their slots plus one.
    pub fn passengersOf(self: *Boats, slot: u32) entity_sync.Passengers {
        const stored = self.boats.ptr(slot);
        var carried: entity_sync.Passengers = .{};
        for (stored.riders.list[0..stored.riders.count]) |rider| {
            carried.ids[carried.count] = switch (rider) {
                .player => |who| @intCast(who.slot + 1),
                .mob => |mob| entities.Entities.networkOfSlot(mob.slot),
            };
            carried.count += 1;
        }
        return carried;
    }

    /// The player that steers the boat, if its first rider is one: AbstractBoat.getControllingPassenger.
    fn steeredBy(self: *Boats, slot: u32) ?usize {
        const stored = self.boats.ptr(slot);
        if (stored.riders.count == 0) return null;
        return switch (stored.riders.list[0]) {
            .player => |who| who.slot,
            .mob => null,
        };
    }

    /// ServerGamePacketListenerImpl.handlePaddleBoat: the paddles of the boat the player steers.
    fn onSteerBoat(self: *Boats, handle: sessions.Handle, packet: wire.play.toServer.packet_steer_boat.Reader) !void {
        const left, const a = try packet.leftPaddle();
        const right, const done = try a.rightPaddle();
        try done.finish();
        const slot = self.steered(handle) orelse return;
        const stored = self.boats.ptr(slot);
        if (stored.paddles[0] == left and stored.paddles[1] == right) return;
        stored.paddles = .{ left, right };
        self.replicated.insert(slot);
    }

    /// The boat a player steers, as its connection: Player.getControlledVehicle.
    fn steered(self: *Boats, handle: sessions.Handle) ?u32 {
        const player = &self.deps.players.records[handle.index];
        if (player.stage != .ready) return null;
        const slot = self.deps.players.vehicleOf(handle.index) orelse return null;
        if (!self.isBoat(slot)) return null;
        if (self.steeredBy(slot) != handle.index) return null;
        return slot;
    }

    /// ServerGamePacketListenerImpl.handleMoveVehicle: where the rider's client moved the boat it
    /// steers, taken unless too fast, or wrong where blocks or entities stand.
    fn onVehicleMove(self: *Boats, handle: sessions.Handle, packet: wire.play.toServer.packet_vehicle_move.Reader) !void {
        const x, const a = try packet.x();
        const y, const b = try a.y();
        const z, const c = try b.z();
        const yaw, const d = try c.yaw();
        const pitch, const e = try d.pitch();
        const on_ground, const done = try e.onGround();
        try done.finish();
        const player = &self.deps.players.records[handle.index];
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(z) or !std.math.isFinite(yaw) or !std.math.isFinite(pitch)) return self.deps.players.refuse(player, "multiplayer.disconnect.invalid_vehicle_movement");
        if (!player.loaded) return;
        const slot = self.steered(handle) orelse return;
        const stored = self.boats.ptr(slot);
        const state = self.deps.entities.body(slot).?;
        const was = state.position;
        const to: [3]f64 = .{ std.math.clamp(x, -3.0e7, 3.0e7), std.math.clamp(y, -2.0e7, 2.0e7), std.math.clamp(z, -3.0e7, 3.0e7) };
        const turned: [2]f32 = .{ mth.wrapDegrees(yaw), mth.wrapDegrees(pitch) };
        // Moved too quickly: farther from where the tick began than its speed explains.
        const v = state.velocity;
        var travelled: f64 = 0;
        for (to, stored.steer.first_good) |now, first| travelled += (now - first) * (now - first);
        if (travelled - (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) > 100.0) return self.correctVehicle(handle, slot);
        const old_box = boat_module.boxAt(was);
        const level = self.deps.mobs.level(state.world);
        self.ticking = .{ .slot = slot };
        defer self.ticking = null;
        const step: [3]f64 = .{ to[0] - stored.steer.last_good[0], to[1] - stored.steer.last_good[1], to[2] - stored.steer.last_good[2] };
        const kept = try boat_module.moveBy(&level, self.around(state.world, slot), state, &stored.boat, step);
        // Moved wrongly: the move fell short of where the client says by more than a quarter
        // block across. Up and down never count.
        const off_x = to[0] - state.position[0];
        const off_z = to[2] - state.position[2];
        const wrongly = off_x * off_x + off_z * off_z > 0.0625;
        if ((wrongly and try self.clear(state.world, old_box, was[1], slot)) or try self.newlyColliding(slot, old_box, to)) {
            state.position = was;
            state.yaw = turned[0];
            state.pitch = std.math.clamp(turned[1], -90.0, 90.0);
            return self.correctVehicle(handle, slot);
        }
        state.position = to;
        state.yaw = @rem(turned[0], 360.0);
        state.pitch = @rem(std.math.clamp(turned[1], -90.0, 90.0), 360.0);
        if (kept) |movement| stored.steer.record(movement);
        try self.places.move(slot, state.world, state.position);
        stored.dirty = true;
        self.replicated.insert(slot);
        const moved: [3]f64 = .{ to[0] - was[0], to[1] - was[1], to[2] - was[2] };
        // ServerPlayer.handlePlayerKnownMovement: what its vehicle moved, it moved.
        player.known_movement = moved;
        player.moved = true;
        try boat_module.landBy(&level, state, &stored.boat, moved, on_ground);
        stored.steer.last_good = state.position;
    }

    /// ClientboundMoveVehiclePacket: the boat where the server has it, which the client takes.
    fn correctVehicle(self: *Boats, handle: sessions.Handle, slot: u32) void {
        const state = self.deps.entities.body(slot).?;
        const player = &self.deps.players.records[handle.index];
        _ = self.deps.players.sendPacket(writeVehicleMove, player.protocol, handle, .{ state.position, state.yaw, state.pitch });
    }

    /// isEntityCollidingWithAnythingNew: a shape the boat's box meets where the client put it that
    /// it did not meet where it was.
    fn newlyColliding(self: *Boats, slot: u32, old_box: Box, to: [3]f64) !bool {
        const state = self.deps.entities.body(slot).?;
        const level = self.deps.mobs.level(state.world);
        const deflate = @as(f64, @as(f32, 1.0e-5));
        const was = old_box.inflate(-deflate, -deflate, -deflate);
        const now = boat_module.boxAt(to).inflate(-deflate, -deflate, -deflate);
        var shapes: body.Shapes = .init(&level, now, .{ .bottom = old_box.min[1], .fall_distance = self.boats.ptr(slot).boat.fall_distance });
        while (try shapes.next()) |shape| for (0..shape.boxes.count) |index| {
            const piece = shape.get(index);
            if (piece.intersects(now) and !piece.intersects(was)) return true;
        };
        const context: body.Context = .{ .bottom = old_box.min[1], .slot = slot, .vehicle = true };
        for (try body.entityCollisions(&level, now, context, &level.colliders.?.entity_boxes)) |other| if (!other.intersects(was)) return true;
        if (body.borderFor(&level, now, now)) |border| for (border) |side| if (side.intersects(now) and !side.intersects(was)) return true;
        return false;
    }

    /// The records of boats that went go too, and their bodies and places with them.
    fn forgetRetired(self: *Boats) !void {
        for (self.retired[0..self.retired_count]) |entity| {
            const stored = try self.boats.takeById(entity) orelse continue;
            if (stored.stored) |column| try self.table.putBatch(&.{.{ .key = &entities.durable.key(record_prefix, column, entity), .value = null }});
        }
        self.retired_count = 0;
    }

    /// Every boat's state and body, for telling two runs apart.
    pub fn digest(self: *Boats) !u64 {
        var sum: u64 = 0;
        for (self.ids()) |entity| {
            const stored = (try self.boats.getById(entity)).?;
            var hasher = std.hash.Wyhash.init(entity);
            const boat = stored.boat;
            inline for (.{ "hurt_time", "hurt_dir", "damage", "bubble_time", "out_of_control", "water_level", "land_friction", "last_yd", "fall_distance", "fire_ticks", "ticks_frozen", "on_ground", "removed" }) |name| hasher.update(std.mem.asBytes(&@field(boat, name)));
            hasher.update(std.mem.asBytes(&boat.random.seed));
            if (try self.deps.entities.getById(entity)) |state| inline for (@typeInfo(entities.State).@"struct".field_names) |name| hasher.update(std.mem.asBytes(&@field(state, name)));
            sum +%= hasher.final();
        }
        return sum;
    }

    /// Boats in memory are those near players, out to their view and one more, and those of the
    /// columns that tick.
    pub fn refresh(self: *Boats) !void {
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
        if (radius == self.last_radius and self.places.ticking_revision == self.last_ticking and self.residency.held == self.last_held and
            std.mem.eql(u8, std.mem.sliceAsBytes(centers), std.mem.sliceAsBytes(self.last_centers[0..self.last_center_count]))) return;
        @memcpy(self.last_centers[0..center_count], centers);
        self.last_center_count = center_count;
        self.last_radius = radius;
        self.last_ticking = self.places.ticking_revision;
        try self.residency.refresh(centers, radius, self.places.tickingColumns(), self, unloadColumn, loadColumn);
        self.last_held = self.residency.held;
    }

    fn columnLoaded(self: *Boats, column: entities.Column) anyerror!void {
        if (try self.residency.enter(column)) try self.loadColumn(column);
    }

    fn columnUnloaded(self: *Boats, column: entities.Column) anyerror!void {
        if (!self.residency.holds(column)) return;
        try self.unloadColumn(column);
        _ = self.residency.leave(column);
    }

    fn unloadColumn(self: *Boats, column: entities.Column) anyerror!void {
        var batch: entities.durable.Batch(record_bytes) = .{ .table = self.table };
        var leaving_count: usize = 0;
        var walk = self.places.space.entries(column, self.kinds);
        while (walk.next()) |entry| {
            self.scratch[leaving_count] = entry.id;
            leaving_count += 1;
        }
        for (self.scratch[0..leaving_count]) |entity| {
            // Its riders stay behind, each kept on its own: vanilla would keep them in its record.
            const slot = self.boats.slotOf(entity).?;
            const riders = &self.boats.ptr(slot).riders;
            while (riders.count > 0) self.letGo(slot, riders.count - 1);
            // Its viewers are told it is gone, so its slot is marked no more.
            self.replicated.remove(slot);
            const state = (try self.deps.entities.getById(entity)).?;
            const stored = (try self.boats.takeById(entity)).?;
            if (stored.boat.removed) {
                if (stored.stored) |was| try batch.delete(entities.durable.key(record_prefix, was, entity));
                continue;
            }
            try save(&batch, entity, state, stored);
        }
        try batch.flush();
    }

    fn loadColumn(self: *Boats, column: entities.Column) anyerror!void {
        var reader = entities.durable.ColumnReader(record_bytes).init(self.table, record_prefix, column);
        var rows: [16]entities.durable.ColumnReader(record_bytes).Row = undefined;
        while (true) {
            const found = try reader.next(&rows);
            if (found.len == 0) break;
            for (found) |row| {
                if (row.value.len != record_bytes) return error.CorruptBoat;
                const state = try entities.decode(row.value[0..entities.encoded_bytes]);
                const saved = try Saved.decode(row.value[entities.encoded_bytes..]);
                if (self.boats.contains(row.id) or !std.meta.eql(self.modelOf(state.kind), saved.model)) return error.CorruptBoat;
                if (!entities.valid(state)) return error.InvalidEntity;
                const boat: Boat = .{
                    .random = JavaRandom.init(@bitCast(self.seeds.next())),
                    .old_position = state.position,
                    .fall_distance = saved.fall_distance,
                    .fire_ticks = saved.fire_ticks,
                    .ticks_frozen = saved.ticks_frozen,
                    .on_ground = saved.on_ground,
                };
                try self.boats.add(row.id, state, .{ .boat = boat, .model = saved.model, .stored = column, .dirty = false }, shapeOf(state.kind));
            }
        }
    }

    fn save(batch: *entities.durable.Batch(record_bytes), entity: entities.Id, state: entities.State, stored: Stored) !void {
        const here = entities.space.columnOf(state.world, state.position);
        if (stored.stored) |was| if (!std.meta.eql(was, here)) try batch.delete(entities.durable.key(record_prefix, was, entity));
        var value: [record_bytes]u8 = undefined;
        entities.encode(state, value[0..entities.encoded_bytes]);
        @memcpy(value[entities.encoded_bytes..], &Saved.of(stored).encode());
        try batch.put(entities.durable.key(record_prefix, here, entity), &value);
    }

    pub fn checkpoint(self: *Boats, space: storage.Space) !void {
        errdefer space.fail();
        var batch: entities.durable.Batch(record_bytes) = .{ .table = self.table };
        for (self.ids()) |entity| {
            const stored = (try self.boats.ptrById(entity)).?;
            if (stored.boat.removed or !stored.dirty) continue;
            const state = (try self.deps.entities.getById(entity)).?;
            try save(&batch, entity, state, stored.*);
            stored.stored = entities.space.columnOf(state.world, state.position);
            stored.dirty = false;
        }
        try batch.flush();
    }
};

/// ClientboundSetPassengersPacket.
const writePassengers = entity_sync.writePassengers;

/// ClientboundMoveVehiclePacket: where the server has the boat its rider steers.
fn writeVehicleMove(packet: wire.play.toClient.packet_vehicle_move.Writer, position: [3]f64, yaw: f32, pitch: f32) ![]u8 {
    return (try (try (try (try (try packet.x(position[0])).y(position[1])).z(position[2])).yaw(yaw)).pitch(pitch)).finish();
}
