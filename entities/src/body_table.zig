//! A kind whose entities are a body and a record of the kind's own: one row each in the kind's
//! table, in the tick order's sequence, the body a column the entities' body calls reach through
//! the directory. Used as a table of the kind's records by id.

const std = @import("std");
const entities_module = @import("entities.zig");
const kind_table = @import("kind_table.zig");
const directory = @import("directory.zig");

const Entities = entities_module.Entities;
const State = entities_module.State;
const Id = entities_module.Id;
const Shape = entities_module.Shape;

pub fn BodyTable(comptime Extra: type) type {
    return struct {
        const Self = @This();
        pub const Row = struct { body: State, extra: Extra, bodied: bool = true };
        pub const Table = kind_table.Table(Row);

        entities: *Entities,
        table: Table,
        kind: u32,

        pub fn init(allocator: std.mem.Allocator, owner: *Entities, kind: u32) !Self {
            return .{ .entities = owner, .table = try .init(allocator, &owner.pool, &owner.directory), .kind = kind };
        }

        /// Maintained with every table at the end of each tick, and the kind's bodies reached
        /// through it. Called once the table is where it stays.
        pub fn register(self: *Self) !void {
            try self.entities.addTable(self.kind, &self.table.core);
            const Adapter = struct {
                fn body(raw: *anyopaque, slot: u32) ?*State {
                    const held: *Self = @ptrCast(@alignCast(raw));
                    const row = held.table.ref(slot);
                    return if (row.field("bodied").*) row.field("body") else null;
                }
            };
            try self.entities.addBodyColumn(self.kind, .{ .context = self, .body = Adapter.body });
        }

        pub fn slotOf(self: *const Self, entity: Id) ?u32 {
            const slot = self.entities.directory.slotOf(entity) orelse return null;
            const entry = self.entities.directory.entry(slot);
            return if (entry.kind != self.kind or entry.block == directory.none) null else slot;
        }

        pub fn contains(self: *const Self, entity: Id) bool {
            return self.slotOf(entity) != null;
        }

        pub fn count(self: *const Self) usize {
            return self.table.standingCount();
        }

        /// How many entities memory holds at most, of every kind.
        pub fn bound(self: *const Self) usize {
            return self.entities.directory.capacity();
        }

        /// The kind's record where it lies, good until the tick's end.
        pub fn ptr(self: *const Self, entity: Id) !?*Extra {
            return self.table.ref(self.slotOf(entity) orelse return null).field("extra");
        }

        pub fn get(self: *const Self, entity: Id) !?Extra {
            return (try self.ptr(entity) orelse return null).*;
        }

        /// The kind's record kept again, for an entity that has one.
        pub fn put(self: *Self, entity: Id, value: Extra) !void {
            (try self.ptr(entity) orelse return error.UnknownEntity).* = value;
        }

        /// An entity comes into memory: placed where its body is, in the tick order last if its
        /// column ticks, and its row written.
        pub fn add(self: *Self, entity: Id, body: State, value: Extra, shape: Shape) !void {
            const slot = try self.entities.enter(entity, self.kind);
            errdefer self.entities.leave(slot);
            try self.entities.places.insert(entity, body.world, body.position, shape);
            errdefer self.entities.places.remove(entity);
            try self.table.add(slot, .{ .body = body, .extra = value }, false);
        }

        /// The entity's body goes, its record staying, as a gone entity's does until forgotten.
        pub fn dropBody(self: *Self, entity: Id) void {
            const slot = self.slotOf(entity) orelse return;
            self.table.ref(slot).field("bodied").* = false;
        }

        /// The entity goes from memory: out of its place and the tick order, and its row with it.
        pub fn remove(self: *Self, entity: Id) void {
            const slot = self.slotOf(entity) orelse return;
            self.entities.places.remove(entity);
            self.table.remove(slot);
            self.entities.leave(slot);
        }

        pub fn take(self: *Self, entity: Id) !?Extra {
            const value = try self.get(entity) orelse return null;
            self.remove(entity);
            return value;
        }

        /// The ids of the kind's entities, sorted, into `output`.
        pub fn ids(self: *const Self, output: []Id) []Id {
            return self.table.idsInto(output);
        }

        pub fn clear(self: *Self) void {
            var at: usize = 0;
            while (at < self.entities.directory.high()) : (at += 1) {
                const slot: u32 = @intCast(at);
                const entry = self.entities.directory.entry(slot);
                if (entry.id == 0 or entry.kind != self.kind or entry.block == directory.none) continue;
                self.entities.places.remove(entry.id);
                entry.block = directory.none;
                self.entities.leave(slot);
            }
            self.table.clear();
        }
    };
}
