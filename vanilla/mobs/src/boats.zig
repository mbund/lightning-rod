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
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const item_data = @import("vanilla_items").item_data;
const bodies = @import("vanilla_bodies");
const boat_module = @import("boat.zig");
const living = @import("living.zig");
const Mobs = @import("mobs.zig").Mobs;
const Mob = @import("mob.zig").Mob;

const body = bodies.body;
const mth = bodies.mth;
const JavaRandom = bodies.java_random.JavaRandom;
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
    };

    /// The woods boats are made of, and bamboo, whose boat is a raft; each its own entity type.
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

        /// The entity type's name, which the boat's item has too.
        pub fn name(self: Variant) []const u8 {
            return switch (self) {
                .bamboo => "minecraft:bamboo_raft",
                inline else => |tag| "minecraft:" ++ @tagName(tag) ++ "_boat",
            };
        }
    };
    const variant_count = @typeInfo(Variant).@"enum".field_names.len;

    /// A boat in memory, and where its record in the store lies.
    pub const Stored = struct {
        boat: Boat,
        variant: Variant,
        stored: ?entities.Column = null,
        dirty: bool = true,
    };

    /// What a boat keeps in the store beside its body, which is what vanilla saves of one: how far
    /// it fell, its fire, how frozen it is, and whether it was on the ground. The rest begins anew
    /// when it is read, as vanilla's does.
    pub const Saved = struct {
        pub const encoded_size = 17;
        fall_distance: f64 = 0,
        fire_ticks: i16 = 0,
        ticks_frozen: i32 = 0,
        on_ground: bool = false,
        variant: Variant,

        pub fn of(stored: Stored) Saved {
            const boat = stored.boat;
            return .{ .fall_distance = boat.fall_distance, .fire_ticks = @intCast(std.math.clamp(boat.fire_ticks, std.math.minInt(i16), std.math.maxInt(i16))), .ticks_frozen = boat.ticks_frozen, .on_ground = boat.on_ground, .variant = stored.variant };
        }

        pub fn encode(self: Saved) [encoded_size]u8 {
            var bytes: [encoded_size]u8 = @splat(0);
            bytes[0] = 1;
            std.mem.writeInt(u64, bytes[1..9], @bitCast(self.fall_distance), .little);
            std.mem.writeInt(i16, bytes[9..11], self.fire_ticks, .little);
            std.mem.writeInt(i32, bytes[11..15], self.ticks_frozen, .little);
            bytes[15] = @intFromBool(self.on_ground);
            bytes[16] = @backingInt(self.variant);
            return bytes;
        }

        pub fn decode(bytes: []const u8) !Saved {
            if (bytes.len != encoded_size or bytes[0] != 1 or bytes[15] > 1 or bytes[16] >= variant_count) return error.CorruptBoat;
            const fall_distance: f64 = @bitCast(std.mem.readInt(u64, bytes[1..9], .little));
            if (!std.math.isFinite(fall_distance)) return error.CorruptBoat;
            return .{
                .fall_distance = fall_distance,
                .fire_ticks = std.mem.readInt(i16, bytes[9..11], .little),
                .ticks_frozen = std.mem.readInt(i32, bytes[11..15], .little),
                .on_ground = bytes[15] == 1,
                .variant = @fromBackingInt(@intCast(bytes[16])),
            };
        }
    };

    const record_prefix = 0x42;
    pub const record_bytes = entities.encoded_bytes + Saved.encoded_size;

    deps: Dependencies,
    config: Configuration,
    allocator: std.mem.Allocator,
    /// The entity type of each variant, and the variant of each type.
    types: [variant_count]u32,
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
    /// The boat ticking, for the world's answers to its tick.
    ticking: ?Ticking = null,
    work: boat_module.Scratch = .{},

    const Ticking = struct { slot: u32 };
    pub const Animation = struct { slot: u32, animation: u8 };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Boats {
        const self = try allocator.create(Boats);
        const bound = deps.entities.directory.capacity();
        var types: [variant_count]u32 = undefined;
        var kind_list: [variant_count]u32 = undefined;
        for (&types, &kind_list, 0..) |*kind, *listed, index| {
            kind.* = @intCast(game_data.registry.entityId(@as(Variant, @fromBackingInt(@intCast(index))).name()) orelse return error.UnknownEntityType);
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
        };
        // EntityType's clientTrackingRange of 10 chunks.
        try deps.entities.declare(.{ .kinds = kinds, .tracking_range = 10 * 16 });
        try deps.entities.addTicker(.init(Boats, self, kinds, 1));
        try deps.entities.addColumnHolder(.init(Boats, self, columnLoaded, columnUnloaded));
        try self.boats.register();
        deps.mobs.boats = self;
        return self;
    }

    /// The variant of a boat's entity type.
    pub fn variantOf(self: *const Boats, kind: u32) ?Variant {
        for (self.types, 0..) |known, index| if (known == kind) return @fromBackingInt(@intCast(index));
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
        variant: Variant,
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
        const kind = self.types[@backingInt(request.variant)];
        const state: entities.State = .{ .uuid = self.uuidOf(entity), .kind = kind, .world = request.world, .position = request.position, .velocity = request.velocity, .yaw = request.yaw };
        if (!entities.valid(state)) return error.InvalidEntity;
        const created = try self.deps.entities.reserveIds(1);
        assert(created == entity);
        const boat: Boat = .{ .random = JavaRandom.init(@bitCast(self.seeds.next())), .old_position = request.position };
        try self.boats.add(entity, state, .{ .boat = boat, .variant = request.variant }, shapeOf(kind));
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
            self.discard(slot);
        }
        return true;
    }

    /// VehicleEntity.destroy: the boat goes, and its item drops where it was, as
    /// Entity.spawnAtLocation drops one.
    fn destroy(self: *Boats, slot: u32) !void {
        const stored = self.boats.ptr(slot);
        const state = self.deps.entities.body(slot).?.*;
        self.discard(slot);
        const random = self.deps.mobs.levelRandom();
        const dx = random.nextDouble() * 0.2 - 0.1;
        const dz = random.nextDouble() * 0.2 - 0.1;
        const kind: u32 = @intCast(game_data.registry.itemId(stored.variant.name()) orelse return error.UnknownItem);
        const stack: inventories.Stack = .{ .item = try item_data.define(self.deps.inventories, kind, &.{}), .count = 1 };
        _ = try self.deps.dropped.create(state.world, state.position, .{ dx, 0.2, dz }, stack);
    }

    /// Entity.discard: the boat is removed, its body and place at the tick's end.
    fn discard(self: *Boats, slot: u32) void {
        const stored = self.boats.ptr(slot);
        if (stored.boat.removed) return;
        stored.boat.removed = true;
        self.retired[self.retired_count] = self.deps.entities.directory.entry(slot).id;
        self.retired_count += 1;
    }

    /// AbstractBoat.push(Entity), the boat in the slot and another: another boat counts only from
    /// below this one's top, anything else only from no higher than its bottom; then both move
    /// apart, as Entity.push(Entity) moves each that is pushable and carries nothing. A boat pushes
    /// so as it ticks, and is pushed so by mobs as they tick.
    pub fn push(self: *Boats, slot: u32, other: Pushed) void {
        const state = self.deps.entities.body(slot).?;
        const box = boat_module.boxAt(state.position);
        if (other.boat) {
            if (!(other.box.min[1] < box.max[1])) return;
        } else if (!(other.box.min[1] <= box.min[1])) return;
        const apart = apartOf(state.position, other.position) orelse return;
        self.nudge(slot, .{ -apart[0], -apart[1] });
        other.nudge(apart);
    }

    /// Something a boat pushes or is pushed by: where it is, and how to push it.
    pub const Pushed = struct {
        position: [3]f64,
        box: Box,
        boat: bool,
        context: *anyopaque,
        push: *const fn (context: *anyopaque, by: [2]f64) void,

        fn nudge(self: Pushed, by: [2]f64) void {
            self.push(self.context, by);
        }
    };

    /// Entity.push(Entity)'s step apart: how far the other moves from this one, x and z, or none
    /// when they stand too close to tell a way.
    fn apartOf(here: [3]f64, there: [3]f64) ?[2]f64 {
        var dx = there[0] - here[0];
        var dz = there[2] - here[2];
        var farthest = @max(@abs(dx), @abs(dz));
        if (farthest < @as(f64, @as(f32, 0.01))) return null;
        farthest = @sqrt(farthest);
        dx /= farthest;
        dz /= farthest;
        const scale = @min(1.0, 1.0 / farthest);
        dx *= scale * @as(f64, @as(f32, 0.05));
        dz *= scale * @as(f64, @as(f32, 0.05));
        return .{ dx, dz };
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

    fn nudgeBoat(context: *anyopaque, by: [2]f64) void {
        const pushed: *const PushedBoat = @ptrCast(@alignCast(context));
        pushed.boats.nudge(pushed.slot, by);
    }
    const PushedBoat = struct { boats: *Boats, slot: u32 };

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

    /// Whether the boat in the slot is still in the world, as what collides with and pushes others.
    pub fn solid(self: *const Boats, slot: u32) bool {
        return !self.boats.ptr(slot).boat.removed;
    }

    /// The boats whose boxes meet `query` but `except`, as Level.getEntityCollisions finds them,
    /// into `output`: what mobs and other boats collide with, as boats are solid.
    pub fn solidBoxes(self: *Boats, world: u32, query: Box, except: ?u32, output: []Box) ![]Box {
        if (self.boats.count() == 0) return output[0..0];
        const Gather = struct {
            boats: *Boats,
            query: Box,
            except: ?u32,
            output: []Box,
            count: usize = 0,
            fn visit(gather: *@This(), entry: entities.space.Entry) anyerror!bool {
                if (gather.except == entry.slot) return false;
                if (gather.boats.boats.ptr(entry.slot).boat.removed) return false;
                const box = boat_module.boxAt(entry.position);
                if (!box.intersects(gather.query)) return false;
                if (gather.count == gather.output.len) return true;
                gather.output[gather.count] = box;
                gather.count += 1;
                return false;
            }
        };
        var gather: Gather = .{ .boats = self, .query = query, .except = except, .output = output };
        try self.places.space.each(world, .{ .min = query.min, .max = query.max }, self.kinds, &gather, Gather.visit);
        return output[0..gather.count];
    }

    /// Whether a pickable entity whose box meets `query` holds the point, as BoatItem.use asks of
    /// Level.getEntities with EntitySelector.CAN_BE_PICKED: boats and mobs not removed.
    pub fn pickableHolds(self: *Boats, world: u32, query: Box, point: [3]f64) !bool {
        const Find = struct {
            boats: *Boats,
            point: [3]f64,
            found: bool = false,
            fn visit(find: *@This(), entry: entities.space.Entry) anyerror!bool {
                const boats = find.boats;
                const box = if (boats.kinds.has(entry.shape.kind)) box: {
                    if (!boats.solid(entry.slot)) return false;
                    break :box boat_module.boxAt(entry.position);
                } else (try boats.deps.mobs.pickableBox(entry.slot)) orelse return false;
                // AABB.contains, the pick radius none.
                for (0..3) |axis| if (!(find.point[axis] >= box.min[axis] and find.point[axis] < box.max[axis])) return false;
                find.found = true;
                return true;
            }
        };
        var find: Find = .{ .boats = self, .point = point };
        try self.places.space.each(world, .{ .min = query.min, .max = query.max }, self.kinds.with(self.deps.mobs.kinds), &find, Find.visit);
        return find.found;
    }

    /// CollisionGetter.noCollision for a boat about to be placed with its box there: no block
    /// shape, no entity it would collide with, and not the world border's outside.
    pub fn clear(self: *Boats, world: u32, box: Box, bottom: f64) !bool {
        const level = self.deps.mobs.level(world);
        if (!try body.noCollision(&level, box, .{ .bottom = bottom })) return false;
        const Find = struct {
            boats: *Boats,
            box: Box,
            found: bool = false,
            fn visit(find: *@This(), entry: entities.space.Entry) anyerror!bool {
                const boats = find.boats;
                const other = if (boats.kinds.has(entry.shape.kind)) other: {
                    if (!boats.solid(entry.slot)) return false;
                    break :other boat_module.boxAt(entry.position);
                } else (try boats.deps.mobs.pushableBox(entry.slot)) orelse return false;
                if (!other.intersects(find.box)) return false;
                find.found = true;
                return true;
            }
        };
        var find: Find = .{ .boats = self, .box = box.inflate(1.0e-7, 1.0e-7, 1.0e-7) };
        try self.places.space.each(world, .{ .min = find.box.min, .max = find.box.max }, self.kinds.with(self.deps.mobs.kinds), &find, Find.visit);
        if (find.found) return false;
        const border = body.borderFor(&level, box, box) orelse return true;
        for (border) |side| if (side.intersects(box)) return false;
        return true;
    }

    /// Before entities tick: boats near players come into memory.
    pub fn prepareTick(self: *Boats) !void {
        errdefer self.deps.storage.fail();
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
        try boat_module.tick(&level, self.around(state.world), state, &stored.boat, &self.work);
        if (stored.boat.removed and !self.isRetired(slot)) {
            // Gone below the world, as Entity.onBelowWorld discards it.
            stored.boat.removed = false;
            self.discard(slot);
        }
        if (!stored.boat.removed) try self.pushAround(slot);
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
    /// the boat's is pushed away, in the order the level finds them. Small living things would
    /// board a boat no player steers; riding is not built yet, so they are pushed.
    fn pushAround(self: *Boats, slot: u32) !void {
        const state = self.deps.entities.body(slot).?.*;
        const box = boat_module.boxAt(state.position).inflate(@as(f32, 0.2), @as(f32, -0.01), @as(f32, 0.2));
        const Around = struct {
            boats: *Boats,
            slot: u32,
            box: Box,
            fn visit(reach: *@This(), entry: entities.space.Entry) anyerror!bool {
                const boats = reach.boats;
                if (entry.slot == reach.slot) return false;
                if (boats.kinds.has(entry.shape.kind)) {
                    const other = boats.boats.ptr(entry.slot);
                    if (other.boat.removed) return false;
                    const other_box = boat_module.boxAt(entry.position);
                    if (!other_box.intersects(reach.box)) return false;
                    var pushed: PushedBoat = .{ .boats = boats, .slot = entry.slot };
                    boats.push(reach.slot, .{ .position = entry.position, .box = other_box, .boat = true, .context = &pushed, .push = nudgeBoat });
                    return false;
                }
                try boats.deps.mobs.pushedByBoat(entry.slot, reach.box, reach.slot);
                return false;
            }
        };
        var reach: Around = .{ .boats = self, .slot = slot, .box = box };
        try self.places.space.each(state.world, .{ .min = box.min, .max = box.max }, self.kinds.with(self.deps.mobs.kinds), &reach, Around.visit);
    }

    fn around(self: *Boats, world: u32) boat_module.Around {
        return .{
            .context = self,
            .collisions = collisions,
            .hurt = hurtByWorld,
            .sound = sound,
            .destroy_block = destroyBlock,
            .break_block = breakBlock,
            .lower_cauldron = lowerCauldron,
            .level_random = self.deps.mobs.levelRandom(),
            .mob_griefing = self.deps.mobs.mobGriefing(),
            .ultrawarm = self.deps.mobs.ultrawarm(world),
        };
    }

    /// Level.getEntityCollisions for the boat ticking: AbstractBoat.canCollideWith, other boats and
    /// whatever is pushable, living mobs off climbables and players not spectating.
    fn collisions(context: *anyopaque, query: Box, output: []Box) anyerror![]Box {
        const self: *Boats = @ptrCast(@alignCast(context));
        const ticking = self.ticking.?;
        const state = self.deps.entities.body(ticking.slot).?;
        const Gather = struct {
            boats: *Boats,
            query: Box,
            except: u32,
            output: []Box,
            count: usize = 0,
            fn visit(gather: *@This(), entry: entities.space.Entry) anyerror!bool {
                if (entry.slot == gather.except) return false;
                const boats = gather.boats;
                const box = if (boats.kinds.has(entry.shape.kind)) box: {
                    if (boats.boats.ptr(entry.slot).boat.removed) return false;
                    break :box boat_module.boxAt(entry.position);
                } else (try boats.deps.mobs.pushableBox(entry.slot)) orelse return false;
                if (!box.intersects(gather.query)) return false;
                if (gather.count == gather.output.len) return true;
                gather.output[gather.count] = box;
                gather.count += 1;
                return false;
            }
        };
        var gather: Gather = .{ .boats = self, .query = query, .except = ticking.slot, .output = output };
        try self.places.space.each(state.world, .{ .min = query.min, .max = query.max }, self.kinds.with(self.deps.mobs.kinds), &gather, Gather.visit);
        return output[0..gather.count];
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

    fn lowerCauldron(context: *anyopaque, world: u32, position: [3]i32) anyerror!void {
        const self: *Boats = @ptrCast(@alignCast(context));
        return self.deps.mobs.lowerCauldron(world, position);
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
                if (self.boats.contains(row.id) or self.variantOf(state.kind) != saved.variant) return error.CorruptBoat;
                if (!entities.valid(state)) return error.InvalidEntity;
                const boat: Boat = .{
                    .random = JavaRandom.init(@bitCast(self.seeds.next())),
                    .old_position = state.position,
                    .fall_distance = saved.fall_distance,
                    .fire_ticks = saved.fire_ticks,
                    .ticks_frozen = saved.ticks_frozen,
                    .on_ground = saved.on_ground,
                };
                try self.boats.add(row.id, state, .{ .boat = boat, .variant = saved.variant, .stored = column, .dirty = false }, shapeOf(state.kind));
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
