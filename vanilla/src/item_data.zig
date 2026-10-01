const std = @import("std");
const inventories = @import("inventories");
const support = @import("protocol_support");

pub const maximum_components = 128;
const header_bytes = 10;
const entry_bytes = 12;
const removed = std.math.maxInt(u32);

pub const Component = struct { key: u64, value: ?[]const u8 };

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
/// Payloads are copied into the immutable definition owned by Inventories.
pub fn encode(buffer: []u8, kind: u32, components: []const Component) ![]const u8 {
    if (components.len > maximum_components or buffer.len < header_bytes) return error.ItemTooLarge;
    var sorted: [maximum_components]Component = undefined;
    @memcpy(sorted[0..components.len], components);
    std.mem.sort(Component, sorted[0..components.len], {}, struct {
        fn less(_: void, a: Component, b: Component) bool {
            return a.key < b.key;
        }
    }.less);
    @memcpy(buffer[0..4], "LRI2");
    std.mem.writeInt(u32, buffer[4..8], kind, .little);
    std.mem.writeInt(u16, buffer[8..10], @intCast(components.len), .little);
    var rest = buffer[header_bytes..];
    for (sorted[0..components.len], 0..) |component, index| {
        if (index != 0 and sorted[index - 1].key == component.key) return error.DuplicateComponent;
        const length = if (component.value) |payload| payload.len else 0;
        if (length >= removed or rest.len < entry_bytes or length > rest.len - entry_bytes) return error.ItemTooLarge;
        std.mem.writeInt(u64, rest[0..8], component.key, .little);
        std.mem.writeInt(u32, rest[8..12], if (component.value != null) @intCast(length) else removed, .little);
        rest = rest[entry_bytes..];
        if (component.value) |payload| @memcpy(rest[0..length], payload);
        rest = rest[length..];
    }
    return buffer[0 .. buffer.len - rest.len];
}

pub fn replace(store: *inventories.Inventories, stack: inventories.Stack, component: Component) !inventories.Stack {
    var buffer: [64 * 1024]u8 = undefined;
    var length: usize = undefined;
    {
        const lease = try store.acquireItem(stack.item);
        defer lease.release();
        const view = try View.parse(lease.read().?);
        var entries: [maximum_components]Component = undefined;
        var count: usize = 0;
        var it = view.iterator();
        while (it.next()) |entry| {
            if (entry.key == component.key) continue;
            if (count == entries.len) return error.ItemTooLarge;
            entries[count] = entry;
            count += 1;
        }
        if (count == entries.len) return error.ItemTooLarge;
        entries[count] = component;
        length = (try encode(&buffer, view.kind, entries[0 .. count + 1])).len;
    }
    return .{ .item = try store.defineItem(buffer[0..length]), .count = stack.count };
}
