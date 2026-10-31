const std = @import("std");
const ids = @import("content_ids.zig");
const assert = std.debug.assert;

pub const Tags = struct {
    pub const Id = enum(usize) { _ };
    pub const Entry = struct { name: []const u8, values: []const u32 };
    entries: []const Entry,
    names: std.StringHashMapUnmanaged(Id),

    pub fn find(self: *const Tags, name: []const u8) ?Id {
        return self.names.get(name);
    }

    pub fn members(self: *const Tags, id: Id) []const u32 {
        assert(@backingInt(id) < self.entries.len);
        return self.entries[@backingInt(id)].values;
    }

    pub fn contains(self: *const Tags, id: Id, value: u32) bool {
        const values = self.members(id);
        return std.sort.binarySearch(u32, values, value, struct {
            fn compare(key: u32, element: u32) std.math.Order {
                return std.math.order(key, element);
            }
        }.compare) != null;
    }

    pub fn prepare(allocator: std.mem.Allocator, temporary: std.mem.Allocator, declarations: []const Definition, registry: []const u8, value_names: []const []const u8) !Tags {
        var builder: Preparation = .{ .allocator = allocator, .temporary = temporary, .declarations = declarations, .registry = registry };
        var unique: std.StringHashMapUnmanaged(void) = .empty;
        for (declarations) |declaration| if (std.mem.eql(u8, declaration.registry, registry)) {
            if (!ids.validName(declaration.name)) return error.InvalidTag;
            try unique.put(temporary, declaration.name, {});
        };
        const definitions = try temporary.alloc(Pending, unique.count());
        var iterator = unique.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |name| {
            definitions[index] = .{ .name = name.* };
            index += 1;
        }
        std.mem.sortUnstable(Pending, definitions, {}, struct {
            fn less(_: void, a: Pending, b: Pending) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        builder.definitions = definitions;
        builder.entries = try allocator.alloc(Entry, definitions.len);
        try builder.tags.ensureTotalCapacity(allocator, @intCast(definitions.len));
        for (definitions, 0..) |definition, at| builder.tags.putAssumeCapacityNoClobber(definition.name, @fromBackingInt(@intCast(at)));
        try builder.values.ensureTotalCapacity(temporary, @intCast(value_names.len));
        for (value_names, 0..) |name, at| builder.values.putAssumeCapacityNoClobber(name, @intCast(at));
        for (0..definitions.len) |at| try builder.resolve(at, 0);
        return .{ .entries = builder.entries, .names = builder.tags };
    }
};

pub const Definition = struct {
    registry: []const u8,
    name: []const u8,
    replace: bool = false,
    values: []const Value,
    pub const Value = struct { id: []const u8, required: bool = true };
};
const Pending = struct { name: []const u8, state: enum { pending, resolving, ready } = .pending };
const Reference = struct { name: []const u8, tag: bool, required: bool };
const Preparation = struct {
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    declarations: []const Definition,
    registry: []const u8,
    definitions: []Pending = &.{},
    entries: []Tags.Entry = &.{},
    tags: std.StringHashMapUnmanaged(Tags.Id) = .empty,
    values: std.StringHashMapUnmanaged(u32) = .empty,

    fn resolve(self: *Preparation, index: usize, depth: usize) anyerror!void {
        const definition = &self.definitions[index];
        if (definition.state == .ready) return;
        if (definition.state == .resolving or depth >= 256) return error.TagCycle;
        definition.state = .resolving;
        var arena = std.heap.ArenaAllocator.init(self.temporary);
        defer arena.deinit();
        const temporary = arena.allocator();
        var references: std.ArrayList(Reference) = .empty;
        for (self.declarations) |layer| {
            if (!std.mem.eql(u8, layer.registry, self.registry) or !std.mem.eql(u8, layer.name, definition.name)) continue;
            if (layer.replace) references.clearRetainingCapacity();
            for (layer.values) |value| {
                const tag = std.mem.startsWith(u8, value.id, "#");
                const name = value.id[@intFromBool(tag)..];
                if (!ids.validName(name)) return error.InvalidTagReference;
                try references.append(temporary, .{ .name = name, .tag = tag, .required = value.required });
            }
        }
        var members = try std.DynamicBitSetUnmanaged.initEmpty(temporary, self.values.count());
        for (references.items) |reference| {
            if (reference.tag) {
                const target = self.tags.get(reference.name) orelse {
                    if (reference.required) return error.UnknownTag;
                    continue;
                };
                try self.resolve(@backingInt(target), depth + 1);
                for (self.entries[@backingInt(target)].values) |value| members.set(value);
            } else {
                const value = self.values.get(reference.name) orelse {
                    if (reference.required) return error.UnknownTagValue;
                    continue;
                };
                members.set(value);
            }
        }
        const result = try self.allocator.alloc(u32, members.count());
        var member_iterator = members.iterator(.{});
        var count: usize = 0;
        while (member_iterator.next()) |value| {
            result[count] = @intCast(value);
            count += 1;
        }
        assert(count == result.len);
        self.entries[index] = .{ .name = definition.name, .values = result };
        definition.state = .ready;
    }
};
