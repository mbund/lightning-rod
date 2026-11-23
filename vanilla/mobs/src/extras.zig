//! Mobs' rare parts. A mob's row links to an entry of links, one per part, each to a record of
//! that part's own table, all in the entities' pool: a mob with none of them costs its row's one
//! link, and one with a part costs that part. The entry goes with the last part.

const std = @import("std");
const entities = @import("entities");
const mob_state = @import("mob.zig");

const Part = mob_state.Part;
const PartType = mob_state.PartType;
const Rare = mob_state.Rare;
const Records = entities.extras.Records;

pub const none = entities.extras.none;
const parts = std.enums.values(Part);

pub const Store = struct {
    links: Records(Links),
    focus: Records(mob_state.Focus),
    follow: Records(mob_state.Follow),
    breeding: Records(mob_state.Breeding),
    ageing: Records(mob_state.Ageing),
    hurt: Records(mob_state.Hurt),

    const Links = struct { parts: [parts.len]u32 = @splat(none) };

    pub fn init(allocator: std.mem.Allocator, pool: *entities.Pool) !Store {
        var self: Store = undefined;
        inline for (@typeInfo(Store).@"struct".field_names) |name| @field(self, name) = try .init(allocator, pool);
        return self;
    }

    fn table(self: *Store, comptime which: Part) *Records(PartType(which)) {
        return &@field(self, @tagName(which));
    }

    pub fn get(self: *Store, link: u32, comptime which: Part) ?*PartType(which) {
        if (link == none) return null;
        const index = self.links.at(link).parts[@backingInt(which)];
        return if (index == none) null else self.table(which).at(index);
    }

    /// A part set, made if the mob had none, as its link's entry is.
    pub fn put(self: *Store, link: *u32, comptime which: Part, value: PartType(which)) !*PartType(which) {
        if (link.* == none) link.* = try self.links.add(.{});
        const slot = &self.links.at(link.*).parts[@backingInt(which)];
        if (slot.* == none) slot.* = try self.table(which).add(value) else self.table(which).at(slot.*).* = value;
        return self.table(which).at(slot.*);
    }

    /// A part goes; the link's entry with the last.
    pub fn drop(self: *Store, link: *u32, comptime which: Part) void {
        if (link.* == none) return;
        const entry = self.links.at(link.*);
        const slot = &entry.parts[@backingInt(which)];
        if (slot.* == none) return;
        self.table(which).remove(slot.*);
        slot.* = none;
        for (entry.parts) |index| if (index != none) return;
        self.links.remove(link.*);
        link.* = none;
    }

    pub fn read(self: *Store, link: u32) Rare {
        var rare: Rare = .{};
        inline for (parts) |which| {
            if (self.get(link, which)) |value| @field(rare, @tagName(which)) = value.*;
        }
        return rare;
    }

    /// The parts made what `rare` holds.
    pub fn write(self: *Store, link: *u32, rare: Rare) !void {
        inline for (parts) |which| {
            if (@field(rare, @tagName(which))) |value| _ = try self.put(link, which, value) else self.drop(link, which);
        }
    }

    /// Every part of a mob that leaves goes.
    pub fn free(self: *Store, link: *u32) void {
        inline for (parts) |which| self.drop(link, which);
    }

    pub fn clear(self: *Store) void {
        inline for (@typeInfo(Store).@"struct".field_names) |name| @field(self, name).clear();
    }
};
