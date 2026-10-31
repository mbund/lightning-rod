const recipes = @import("recipes.zig");
const std = @import("std");
const inventories = @import("inventories");
const support = @import("protocol_support");

pub const maximum_components = 128;
const header_bytes = 10;
const entry_bytes = 12;
const removed = std.math.maxInt(u32);

pub const Component = recipes.Component;

pub fn key(comptime tag: anytype) u64 {
    return support.cursor.layout.nameKey(@tagName(tag));
}

pub const View = struct {
    kind: u32,
    bytes: []const u8,
    count: u16,

    pub fn parse(bytes: []const u8) !View {
        if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..4], "LRI2")) return error.UnsupportedItemFormat;
        const count = std.mem.readInt(u16, bytes[8..10], .little);
        if (count > maximum_components) return error.Corrupt;
        var rest = bytes[header_bytes..];
        var previous: ?u64 = null;
        for (0..count) |_| {
            if (rest.len < entry_bytes) return error.Corrupt;
            const id = std.mem.readInt(u64, rest[0..8], .little);
            const length = std.mem.readInt(u32, rest[8..12], .little);
            if (previous != null and id <= previous.?) return error.Corrupt;
            previous = id;
            rest = rest[entry_bytes..];
            if (length != removed) {
                if (length > rest.len) return error.Corrupt;
                rest = rest[length..];
            }
        }
        if (rest.len != 0) return error.Corrupt;
        return .{ .kind = std.mem.readInt(u32, bytes[4..8], .little), .bytes = bytes, .count = count };
    }

    pub fn iterator(self: View) Iterator {
        return .{ .rest = self.bytes[header_bytes..] };
    }

    pub fn at(self: View, offset: usize) Component {
        std.debug.assert(offset >= header_bytes and offset <= self.bytes.len and entry_bytes <= self.bytes.len - offset);
        var it: Iterator = .{ .rest = self.bytes[offset..] };
        return it.next().?;
    }

    pub fn get(self: View, id: u64) ?Component {
        var it = self.iterator();
        while (it.next()) |component| {
            if (component.key == id) return component;
            if (component.key > id) break;
        }
        return null;
    }

    pub fn value(self: View, comptime tag: anytype) ?[]const u8 {
        return if (self.get(key(tag))) |component| component.value else null;
    }
};

pub const Iterator = struct {
    rest: []const u8,

    pub fn next(self: *Iterator) ?Component {
        if (self.rest.len == 0) return null;
        const id = std.mem.readInt(u64, self.rest[0..8], .little);
        const length = std.mem.readInt(u32, self.rest[8..12], .little);
        self.rest = self.rest[entry_bytes..];
        const bytes = if (length == removed) null else self.rest[0..length];
        if (bytes) |payload| self.rest = self.rest[payload.len..];
        return .{ .key = id, .value = bytes };
    }
};

/// Canonical ordering makes identity independent of client component ordering.
pub fn defaultId(kind: u32) inventories.ItemId {
    var bytes: [header_bytes]u8 = @splat(0);
    @memcpy(bytes[0..4], "LRI2");
    std.mem.writeInt(u32, bytes[4..8], kind, .little);
    var id: inventories.ItemId = undefined;
    std.crypto.hash.Blake3.hash(&bytes, &id, .{});
    return id;
}

pub fn encodedSize(components: []const Component) !usize {
    if (components.len > maximum_components) return error.ItemTooLarge;
    var size = header_bytes + entry_bytes * components.len;
    for (components) |component| if (component.value) |bytes| {
        if (bytes.len >= removed) return error.ItemTooLarge;
        size = try std.math.add(usize, size, bytes.len);
    };
    return size;
}

pub fn encode(output: []u8, kind: u32, components: []const Component) !View {
    const size = try encodedSize(components);
    if (output.len < size) return error.ItemTooLarge;
    var sorted: [maximum_components]Component = undefined;
    @memcpy(sorted[0..components.len], components);
    std.mem.sortUnstable(Component, sorted[0..components.len], {}, struct {
        fn less(_: void, a: Component, b: Component) bool {
            return a.key < b.key;
        }
    }.less);
    @memcpy(output[0..4], "LRI2");
    std.mem.writeInt(u32, output[4..8], kind, .little);
    std.mem.writeInt(u16, output[8..10], @intCast(components.len), .little);
    var offset: usize = header_bytes;
    for (sorted[0..components.len], 0..) |component, index| {
        if (index != 0 and sorted[index - 1].key == component.key) return error.DuplicateComponent;
        std.mem.writeInt(u64, output[offset..][0..8], component.key, .little);
        std.mem.writeInt(u32, output[offset + 8 ..][0..4], if (component.value) |value| @intCast(value.len) else removed, .little);
        offset += entry_bytes;
        if (component.value) |value| {
            @memcpy(output[offset..][0..value.len], value);
            offset += value.len;
        }
    }
    std.debug.assert(offset == size);
    return View.parse(output[0..size]);
}

const Parts = struct {
    header: [header_bytes]u8 = undefined,
    headers: [maximum_components][entry_bytes]u8 = undefined,
    parts: [1 + maximum_components * 2][]const u8 = undefined,
    count: usize = 0,

    fn init(self: *Parts, kind: u32, components: []const Component) !void {
        if (components.len > maximum_components) return error.ItemTooLarge;
        var sorted: [maximum_components]Component = undefined;
        @memcpy(sorted[0..components.len], components);
        std.mem.sortUnstable(Component, sorted[0..components.len], {}, struct {
            fn less(_: void, a: Component, b: Component) bool {
                return a.key < b.key;
            }
        }.less);
        @memcpy(self.header[0..4], "LRI2");
        std.mem.writeInt(u32, self.header[4..8], kind, .little);
        std.mem.writeInt(u16, self.header[8..10], @intCast(components.len), .little);
        self.parts[0] = &self.header;
        self.count = 1;
        for (sorted[0..components.len], self.headers[0..components.len], 0..) |component, *entry, index| {
            if (index != 0 and sorted[index - 1].key == component.key) return error.DuplicateComponent;
            const length = if (component.value) |bytes| bytes.len else 0;
            if (length >= removed) return error.ItemTooLarge;
            std.mem.writeInt(u64, entry[0..8], component.key, .little);
            std.mem.writeInt(u32, entry[8..12], if (component.value != null) @intCast(length) else removed, .little);
            self.parts[self.count] = entry;
            self.count += 1;
            if (component.value) |bytes| {
                self.parts[self.count] = bytes;
                self.count += 1;
            }
        }
    }
};

pub fn identity(kind: u32, components: []const Component) !inventories.ItemId {
    var parts: Parts = .{};
    try parts.init(kind, components);
    var hash = std.crypto.hash.Blake3.init(.{});
    for (parts.parts[0..parts.count]) |part| hash.update(part);
    var id: inventories.ItemId = undefined;
    hash.final(&id);
    return id;
}

pub fn define(store: *inventories.Inventories, kind: u32, components: []const Component) !inventories.ItemId {
    if (try encodedSize(components) > store.config.max_item_bytes) return error.ItemTooLarge;
    var parts: Parts = .{};
    try parts.init(kind, components);
    return store.defineItem(parts.parts[0..parts.count]);
}

pub fn replace(store: *inventories.Inventories, stack: inventories.Stack, component: Component) !inventories.Stack {
    return update(store, stack, component.key, component);
}

pub fn clearOverride(store: *inventories.Inventories, stack: inventories.Stack, component: u64) !inventories.Stack {
    return update(store, stack, component, null);
}

fn update(store: *inventories.Inventories, stack: inventories.Stack, component_key: u64, replacement: ?Component) !inventories.Stack {
    const lease = try store.acquireItem(stack.item);
    defer lease.release();
    const view = try View.parse(lease.read().?);
    var entries: [maximum_components]Component = undefined;
    var count: usize = 0;
    var it = view.iterator();
    while (it.next()) |entry| {
        if (entry.key == component_key) continue;
        if (count == entries.len) return error.ItemTooLarge;
        entries[count] = entry;
        count += 1;
    }
    if (replacement) |component| {
        if (count == entries.len) return error.ItemTooLarge;
        entries[count] = component;
        count += 1;
    }
    return .{ .item = try define(store, view.kind, entries[0..count]), .count = stack.count };
}
