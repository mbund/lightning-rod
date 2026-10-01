const std = @import("std");
const wire = @import("wire_1_21_5");
const inventories = @import("inventories");
const sessions = @import("sessions");
const protocols = @import("protocols");
const packets = @import("minecraft_packets");
const components = @import("item_components.zig");
const data = @import("item_data.zig");
const Items = @import("items.zig").Items;

pub const Incoming = struct { count: u16, definition: []const u8 };

pub fn readStack(items: *Items, allocator: std.mem.Allocator, bytes: []const u8, selected: *const sessions.Protocol, recipient: u128) !?Incoming {
    const packet = wire.UntrustedSlot.read(bytes);
    const count, const counted = try packet.itemCount();
    var choice = try counted.anon_1();
    const branch = try choice.begin();
    if (count == 0) {
        _, const done = try branch.case_0();
        try (try choice.advance(done)).finish();
        return null;
    }
    if (count < 0 or count > 99) return error.InvalidItemCount;
    var contents = try branch.case_default();
    const item, const identified = try (try contents.begin()).itemId();
    var kind: ?u32 = null;
    inline for (protocols.implementations) |Version| {
        if (selected.number == Version.protocol_number) {
            comptime wire.UntrustedSlot.Reader.requireCompatible(Version.Protocol.UntrustedSlot.Reader);
            if (item < 0 or item >= Version.Registry.wire_item_to_canonical.len) return error.UnsupportedItem;
            const mapped = Version.Registry.wire_item_to_canonical[@intCast(item)];
            if (mapped < 0) return error.UnsupportedItem;
            kind = @intCast(mapped);
        }
    }
    const added, const after_added = try identified.addedComponentCount();
    const removed, const counts = try after_added.removedComponentCount();
    if (added < 0 or removed < 0 or added > data.maximum_components or removed > data.maximum_components - added) return error.ItemTooLarge;
    var entries: [data.maximum_components]data.Component = undefined;
    var seen: [data.maximum_components]u64 = undefined;
    var seen_count: usize = 0;
    const scratch = try allocator.alloc(u8, items.deps.inventories.config.max_item_bytes);
    defer allocator.free(scratch);
    var output = scratch;
    var added_entries = try counts.components();
    var index: usize = 0;
    while (try added_entries.next()) |entry| {
        const tag, const payload = try entry.type();
        const encoded, const done = try payload.data();
        const start = output;
        var retain = true;
        const key = try items.components.dispatch.readPayload(selected.number, tag, encoded, .{ .output = &output, .retain = &retain, .selected = selected, .recipient = recipient });
        for (seen[0..seen_count]) |previous| if (previous == key) return error.DuplicateComponent;
        seen[seen_count] = key;
        seen_count += 1;
        if (retain) {
            entries[index] = .{ .key = key, .value = start[0 .. start.len - output.len] };
            index += 1;
        } else output = start;
        try added_entries.advance(done);
    }
    var removed_entries = try (try added_entries.finish()).removeComponents();
    while (try removed_entries.next()) |entry| {
        const tag, const done = try entry.type();
        const key = try items.components.dispatch.keyForTag(selected.number, tag);
        for (seen[0..seen_count]) |previous| if (previous == key) return error.DuplicateComponent;
        seen[seen_count] = key;
        seen_count += 1;
        entries[index] = .{ .key = key, .value = null };
        index += 1;
        try removed_entries.advance(done);
    }
    try (try choice.advance(try contents.advance(try removed_entries.finish()))).finish();
    const definition = try allocator.alloc(u8, 10 + index * 12 + scratch.len - output.len);
    errdefer allocator.free(definition);
    const encoded = try data.encode(definition, kind orelse return error.UnsupportedProtocol, entries[0..index]);
    if (count > try Items.maximum(try data.View.parse(encoded))) return error.InvalidItemCount;
    return .{ .count = @intCast(count), .definition = encoded };
}

pub const SlotArguments = struct {
    registry: packets.Registry,
    items: *Items,
    stack: ?inventories.Stack,
    recipient: u128,
};

pub const writeSlot: fn (destination: wire.Slot.Destination, args: SlotArguments) anyerror!wire.Slot.Completion = packets.nested(.{encodeSlot}).write;

fn encodeSlot(packet: wire.Slot.Writer, args: SlotArguments) !wire.Slot.Writer.Done {
    const registry = args.registry;
    const items = args.items;
    const stack = args.stack;
    const recipient = args.recipient;
    const counted = try packet.itemCount(if (stack) |value| value.count else 0);
    var choice = try counted.anon_1();
    const branch = try choice.begin();
    const value = stack orelse return choice.advance(try branch.case_0());
    const lease = try items.deps.inventories.acquireItem(value.item);
    defer lease.release();
    const view = try data.View.parse(lease.read().?);
    var emitted: [data.maximum_components]usize = undefined;
    var added: usize = 0;
    var removed: usize = 0;
    var it = view.iterator();
    while (it.next()) |component| {
        if (items.components.dispatch.find(component.key) == null) return error.UnsupportedComponent;
        removed += @intFromBool(component.value == null);
    }
    for (0..items.components.dispatch.count) |index| {
        if (!items.components.present(index, view, recipient)) continue;
        emitted[added] = index;
        added += 1;
        if (view.get(items.components.dispatch.entries[index].key)) |component| removed -= @intFromBool(component.value == null);
    }
    var contents = try branch.case_default();
    const identified = try (try contents.begin()).itemId(try registry.itemId(@intCast(view.kind)));
    const counts = try (try identified.addedComponentCount(@intCast(added))).removedComponentCount(@intCast(removed));
    var entries = try counts.components();
    for (emitted[0..added]) |index| {
        const entry = (try entries.next()).?;
        const key = items.components.dispatch.entries[index].key;
        try entries.advance(try items.components.dispatch.write(entry, key, components.WriteContext{
            .item = view,
            .value = if (view.get(key)) |stored| stored.value else null,
            .registry = registry,
            .protocol = packet._cursor.protocol_number,
            .recipient = recipient,
        }));
    }
    var removals = try (try entries.finish()).removeComponents();
    it = view.iterator();
    while (it.next()) |component| {
        if (component.value != null) continue;
        var present = false;
        for (emitted[0..added]) |index| present = present or items.components.dispatch.entries[index].key == component.key;
        if (present) continue;
        const entry = (try removals.next()).?;
        try removals.advance(try entry.type(@intCast(try items.components.dispatch.tagForKey(packet._cursor.protocol_number, component.key))));
    }
    return choice.advance(try contents.advance(try removals.finish()));
}
