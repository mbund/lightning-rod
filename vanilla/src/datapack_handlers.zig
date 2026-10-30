const std = @import("std");
const ids = @import("content_ids.zig");
const crafting = @import("crafting.zig");
const loot = @import("loot.zig");

pub const RecipeType = struct {
    name: []const u8,
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { decode: *const fn (*anyopaque, std.mem.Allocator, std.mem.Allocator, std.json.Value) anyerror!crafting.Binding };
};
pub const LootType = struct {
    name: []const u8,
    kind: loot.Kind,
    context: *const anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { decode: *const fn (*const anyopaque, std.mem.Allocator, std.mem.Allocator, std.json.Value) anyerror!loot.Binding };
};

pub fn Recipe(comptime Owner: type) type {
    return struct {
        const vtable: RecipeType.VTable = .{ .decode = decode };
        pub fn register(owner: *Owner) RecipeType {
            comptime std.debug.assert(ids.validName(Owner.id));
            return .{ .name = Owner.id, .context = owner, .vtable = &vtable };
        }
        fn decode(raw: *anyopaque, allocator: std.mem.Allocator, scratch: std.mem.Allocator, json: std.json.Value) !crafting.Binding {
            const owner: *Owner = @ptrCast(@alignCast(raw));
            const parameters = if (@hasDecl(Owner, "decode")) try owner.decode(allocator, scratch, json) else try decodeParameters(Owner.Parameters, allocator, scratch, json, &.{"type"});
            return crafting.Implementation(Owner).define(allocator, owner, parameters);
        }
    };
}

pub fn Loot(comptime Owner: type) type {
    return struct {
        const vtable: LootType.VTable = .{ .decode = decode };
        pub fn register(owner: *const Owner) LootType {
            comptime std.debug.assert(ids.validName(Owner.id));
            return .{ .name = Owner.id, .kind = Owner.kind, .context = owner, .vtable = &vtable };
        }
        fn decode(raw: *const anyopaque, allocator: std.mem.Allocator, scratch: std.mem.Allocator, json: std.json.Value) !loot.Binding {
            const owner: *const Owner = @ptrCast(@alignCast(raw));
            const ignored: []const []const u8 = switch (Owner.kind) {
                .condition => &.{"condition"},
                .function => &.{ "function", "conditions" },
                .entry => &.{ "type", "conditions", "functions", "weight" },
            };
            const parameters = if (@hasDecl(Owner, "decode")) try owner.decode(allocator, scratch, json) else try decodeParameters(Owner.Parameters, allocator, scratch, json, ignored);
            return @unionInit(loot.Binding, @tagName(Owner.kind), try loot.Implementation(Owner).define(allocator, owner, parameters));
        }
    };
}

fn decodeParameters(comptime T: type, allocator: std.mem.Allocator, scratch: std.mem.Allocator, json: std.json.Value, ignored: []const []const u8) !T {
    if (json != .object) return error.InvalidDefinition;
    var fields: std.json.ObjectMap = .empty;
    var iterator = json.object.iterator();
    entries: while (iterator.next()) |entry| {
        for (ignored) |name| if (std.mem.eql(u8, name, entry.key_ptr.*)) continue :entries;
        try fields.put(scratch, entry.key_ptr.*, entry.value_ptr.*);
    }
    return std.json.parseFromValueLeaky(T, allocator, .{ .object = fields }, .{ .allocate = .alloc_always });
}
