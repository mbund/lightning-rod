//! How bodies meet each other, for every kind at once. Each kind says once how others meet its
//! entities, by vanilla's three entity selectors: Entity.canBeCollidedWith makes one a wall to
//! everything that moves, boats as shulkers; Entity.isPushable makes it one to vehicles, as
//! AbstractBoat.canCollideWith's canVehicleCollide, and what living things push; isPickable makes
//! it what a look or a projectile can hit. Every move and free check through body.collide and
//! body.noCollision meets them, through the level's `entities`, and the pushing and picking
//! queries here find them. A mover never meets itself, nor what shares its root vehicle.

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
    };

    /// Which of the selectors a query takes.
    pub const Test = enum { solid, pushable, pickable };

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
        }
    }

    /// What a level asks of the entities.
    pub fn source(self: *EntityCollisions) body.EntitySource {
        return .{ .context = self, .gather = gather };
    }

    /// Level.getEntities(except, query, selector): those the selector takes whose boxes meet the
    /// query, in the level's order, all found before the first is visited.
    pub fn each(self: *EntityCollisions, world: u32, query: Box, except: u32, test_kind: Test, visitor: Visitor) !void {
        const kinds = switch (test_kind) {
            .solid => self.solid,
            .pushable => self.pushable,
            .pickable => self.pickable,
        };
        var walk: Walk = .{ .collisions = self, .query = query, .except = except, .test_kind = test_kind, .visitor = visitor };
        try self.deps.entities.places.space.each(world, .{ .min = query.min, .max = query.max }, kinds, &walk, Walk.visit);
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
