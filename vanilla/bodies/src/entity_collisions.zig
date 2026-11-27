//! How bodies meet each other, for every kind at once. Each kind says once how others meet its
//! entities, by vanilla's three entity selectors and its class of the living:
//! Entity.canBeCollidedWith makes one a wall to everything that moves, boats as shulkers;
//! Entity.isPushable makes it one to vehicles, as AbstractBoat.canCollideWith's
//! canVehicleCollide, and what living things push; isPickable makes it what a look or a
//! projectile can hit; a LivingEntity is what a sweep or a smash reaches. Every move and free
//! check through body.collide and body.noCollision meets them, through the level's
//! `entities`, and the pushing, picking and living queries here find them. A mover never meets
//! itself, nor what shares its root vehicle.

const std = @import("std");
const entities = @import("entities");
const body = @import("body.zig");

const Box = body.Box;

pub const EntityCollisions = struct {
    pub const id = "minecraft:entity_collisions";
    pub const Configuration = struct {};
    pub const Dependencies = struct { entities: *entities.Entities };

    /// The box a kind gives its entity in the slot, if that entity counts now.
    pub const Answer = *const fn (context: *anyopaque, slot: u32) anyerror!?Box;

    /// How others meet a kind's entities. Spectators answer none, as EntitySelector.NO_SPECTATORS
    /// passes them by.
    pub const Rule = struct {
        context: *anyopaque,
        /// Entity.canBeCollidedWith.
        solid: ?Answer = null,
        /// Entity.isPushable.
        pushable: ?Answer = null,
        /// Entity.isPickable.
        pickable: ?Answer = null,
        /// Whether it is a LivingEntity, as EntityGetter.getEntitiesOfClass(LivingEntity) finds them:
        /// any not removed, the dying too.
        living: ?Answer = null,
        /// A sleeping entity of the kind wakes to look about it again, as one that may be inside a
        /// solid entity now: vanilla's, awake, would be pushed out.
        wake: ?*const fn (context: *anyopaque, slot: u32) void = null,
        /// Where the entity is now, which the space may trail within a tick: kinds that push answer.
        position: ?*const fn (context: *anyopaque, slot: u32) [3]f64 = null,
        /// Something pushable met it, as Entity.push(Entity) does: a resting one wakes, as its own
        /// pushEntities would have found the other.
        touched: ?*const fn (context: *anyopaque, slot: u32) void = null,
        /// Entity.push(x, y, z) on the entity: its velocity moves by `by` across, and it wakes. None,
        /// and a push leaves it as it is, as a player's client moves it.
        nudge: ?*const fn (context: *anyopaque, slot: u32, by: [2]f64) void = null,
        /// A kind's own Entity.push(Entity) test before stepping apart from `other`, as
        /// AbstractBoat.push has: none, and it always steps apart.
        pushes: ?*const fn (context: *anyopaque, slot: u32, own: Box, other: u32, other_box: Box) bool = null,
    };

    /// Which of the selectors a query takes.
    pub const Test = enum { solid, pushable, pickable, living };

    /// What a query visits, each in the level's order: whether to stop.
    pub const Visitor = struct {
        context: *anyopaque,
        visit: *const fn (context: *anyopaque, entry: entities.space.Entry, box: Box) anyerror!bool,
    };

    deps: Dependencies,
    rules: [entities.Kinds.max_kinds]?Rule = @splat(null),
    /// The kinds each selector can find.
    solid: entities.Kinds = .{},
    pushable: entities.Kinds = .{},
    pickable: entities.Kinds = .{},
    living: entities.Kinds = .{},
    /// The kinds whose sleepers a solid entity moving wakes.
    sleepers: entities.Kinds = .{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*EntityCollisions {
        const self = try allocator.create(EntityCollisions);
        self.* = .{ .deps = deps };
        return self;
    }

    /// Each kind says once.
    pub fn register(self: *EntityCollisions, kinds: entities.Kinds, rule: Rule) !void {
        var each_kind = kinds.bits.iterator(.{});
        while (each_kind.next()) |kind| {
            if (self.rules[kind] != null) return error.CollisionRuleTaken;
            self.rules[kind] = rule;
            if (rule.solid != null) self.solid.bits.set(kind);
            if (rule.pushable != null) self.pushable.bits.set(kind);
            if (rule.pickable != null) self.pickable.bits.set(kind);
            if (rule.living != null) self.living.bits.set(kind);
            if (rule.wake != null) self.sleepers.bits.set(kind);
        }
    }

    /// What a level asks of the entities.
    pub fn source(self: *EntityCollisions) body.EntitySource {
        return .{ .context = self, .gather = gather };
    }

    /// A solid entity moved to `box`: the sleepers about it wake, a block either way, as those it
    /// now meets would be pushed out of it.
    pub fn disturb(self: *EntityCollisions, world: u32, box: Box) void {
        const space = &self.deps.entities.places.space;
        if (space.countOf(self.sleepers) == 0) return;
        const Wake = struct {
            collisions: *EntityCollisions,
            pub fn visit(wake: @This(), slot: u32) bool {
                const rule = wake.collisions.rules[wake.collisions.deps.entities.directory.entry(slot).kind].?;
                rule.wake.?(rule.context, slot);
                return true;
            }
        };
        const near = box.inflate(1, 1, 1);
        _ = space.eachDormant(world, .{ .low = near.min, .high = near.max }, self.sleepers, Wake{ .collisions = self });
    }

    /// Level.getEntities(except, query, selector): those the selector takes whose boxes meet the
    /// query, in the level's order, all found before the first is visited.
    pub fn each(self: *EntityCollisions, world: u32, query: Box, except: u32, test_kind: Test, visitor: Visitor) !void {
        return self.eachOf(world, query, except, test_kind, .all, visitor);
    }

    /// As `each`, of the kinds `within` alone.
    pub fn eachOf(self: *EntityCollisions, world: u32, query: Box, except: u32, test_kind: Test, within: entities.Kinds, visitor: Visitor) !void {
        const selected = switch (test_kind) {
            .solid => self.solid,
            .pushable => self.pushable,
            .pickable => self.pickable,
            .living => self.living,
        };
        const kinds = selected.only(within);
        // None of the kinds anywhere, as there are no boats in most worlds, is nothing to look for.
        if (self.deps.entities.places.space.countOf(kinds) == 0) return;
        var walk: Walk = .{ .collisions = self, .query = query, .except = except, .test_kind = test_kind, .visitor = visitor };
        try self.deps.entities.places.space.each(world, .{ .min = query.min, .max = query.max }, kinds, &walk, Walk.visit);
    }

    /// Entity.push(Entity): `this` and `other` step apart, unless they ride the same vehicle, `this`
    /// kind's own test says no, or they stand too close to tell a way; each moves that carries
    /// nothing and is pushable.
    /// `this_box` and `other_box` are what each answered as pushable, null where it is not: the
    /// queries that find them have them in hand.
    pub fn push(self: *EntityCollisions, this: u32, this_box: ?Box, other: u32, other_box: ?Box) !void {
        const owned = self.deps.entities;
        if (owned.rootOf(this) == owned.rootOf(other)) return;
        const this_rule = self.rules[owned.directory.entry(this).kind].?;
        const other_rule = self.rules[owned.directory.entry(other).kind].?;
        // Neither moves nor wakes, as two players do, whose clients move them: nothing to do.
        if (this_rule.touched == null and other_rule.touched == null and this_rule.nudge == null and other_rule.nudge == null) return;
        if (this_rule.touched) |touched| touched(this_rule.context, this);
        if (other_rule.touched) |touched| touched(other_rule.context, other);
        if (this_rule.pushes) |pushes| {
            const own = this_box orelse try self.placedBox(this);
            if (!pushes(this_rule.context, this, own, other, other_box orelse try self.placedBox(other))) return;
        }
        const from = if (this_rule.position) |at| at(this_rule.context, this) else try self.placedPosition(this);
        const to = if (other_rule.position) |at| at(other_rule.context, other) else try self.placedPosition(other);
        const apart = body.pushApart(from, to) orelse return;
        if (!owned.isVehicle(this) and this_box != null) if (this_rule.nudge) |nudge| nudge(this_rule.context, this, .{ -apart[0], -apart[1] });
        if (!owned.isVehicle(other) and other_box != null) if (other_rule.nudge) |nudge| nudge(other_rule.context, other, apart);
    }

    /// Where the space has an entity, for a kind that does not answer itself.
    fn placedBox(self: *EntityCollisions, slot: u32) !Box {
        const placed = self.deps.entities.places.space.atSlot(slot) orelse return error.EntityNotPlaced;
        const value = placed.entry.box();
        return .{ .min = value.min, .max = value.max };
    }

    fn placedPosition(self: *EntityCollisions, slot: u32) ![3]f64 {
        const placed = self.deps.entities.places.space.atSlot(slot) orelse return error.EntityNotPlaced;
        return placed.entry.position;
    }

    const Walk = struct {
        collisions: *EntityCollisions,
        query: Box,
        except: u32,
        test_kind: Test,
        visitor: Visitor,

        fn visit(walk: *Walk, entry: entities.space.Entry) anyerror!bool {
            if (entry.slot == walk.except) return false;
            const rule = walk.collisions.rules[entry.shape.kind].?;
            const answer = switch (walk.test_kind) {
                .solid => rule.solid,
                .pushable => rule.pushable,
                .pickable => rule.pickable,
                .living => rule.living,
            }.?;
            const value = (try answer(rule.context, entry.slot)) orelse return false;
            if (!value.intersects(walk.query)) return false;
            return walk.visitor.visit(walk.visitor.context, entry, value);
        }
    };

    fn gather(context: *anyopaque, world: u32, query: Box, mover: body.Context, output: []Box) anyerror![]Box {
        const self: *EntityCollisions = @ptrCast(@alignCast(context));
        // CollisionContext.empty has no entity: EntitySelector.CAN_BE_COLLIDED_WITH alone.
        const vehicle = mover.vehicle and !mover.empty;
        const kinds = if (vehicle) self.solid.with(self.pushable) else self.solid;
        const owned = self.deps.entities;
        if (owned.places.space.countOf(kinds) == 0) return output[0..0];
        const Find = struct {
            collisions: *EntityCollisions,
            query: Box,
            vehicle: bool,
            mover: u32,
            root: u32,
            output: []Box,
            count: usize = 0,

            fn visit(find: *@This(), entry: entities.space.Entry) anyerror!bool {
                const collisions = find.collisions;
                if (entry.slot == find.mover) return false;
                // Entity.isPassengerOfSameVehicle.
                if (find.mover != body.no_slot and collisions.deps.entities.rootOf(entry.slot) == find.root) return false;
                const rule = collisions.rules[entry.shape.kind].?;
                var found: ?Box = if (rule.solid) |solid| try solid(rule.context, entry.slot) else null;
                if (found == null and find.vehicle) if (rule.pushable) |pushable| {
                    found = try pushable(rule.context, entry.slot);
                };
                const value = found orelse return false;
                if (!value.intersects(find.query)) return false;
                find.output[find.count] = value;
                find.count += 1;
                return find.count == find.output.len;
            }
        };
        const slot = if (mover.empty) body.no_slot else mover.slot;
        var find: Find = .{
            .collisions = self,
            .query = query,
            .vehicle = vehicle,
            .mover = slot,
            .root = if (slot == body.no_slot) body.no_slot else owned.rootOf(slot),
            .output = output,
        };
        try owned.places.space.each(world, .{ .min = query.min, .max = query.max }, kinds, &find, Find.visit);
        return output[0..find.count];
    }
};
