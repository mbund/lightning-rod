const wire_26_1 = @import("wire_26_1");
const std = @import("std");
const wire = @import("wire_1_21_5");
const inventories = @import("inventories");
const sessions = @import("sessions");
const protocols = @import("protocols");
const packets = @import("minecraft_packets");
const components = @import("item_components.zig");
const data = @import("item_data.zig");
const Items = @import("items.zig").Items;

pub const Incoming = struct { count: u16, kind: u32, components: []const data.Component, encoded_bytes: usize };

pub fn readStack(items: *Items, scratch: []u8, entries: []data.Component, bytes: []const u8, selected: *const sessions.Protocol, recipient: u128) !?Incoming {
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
    const canonical = kind orelse return error.UnsupportedProtocol;
    const added, const after_added = try identified.addedComponentCount();
    const removed, const counts = try after_added.removedComponentCount();
    if (added < 0 or removed < 0 or added > data.maximum_components or removed > data.maximum_components - added) return error.ItemTooLarge;
    if (entries.len < @as(usize, @intCast(added + removed))) return error.ItemTooLarge;
    var seen: [data.maximum_components]u64 = undefined;
    var seen_count: usize = 0;
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
        const component: data.Component = .{ .key = key, .value = start[0 .. start.len - output.len] };
        if (retain and try items.components.retain(.{ .kind = canonical, .recipient = recipient, .component = component })) {
            entries[index] = component;
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
        const component: data.Component = .{ .key = key, .value = null };
        if (try items.components.retain(.{ .kind = canonical, .recipient = recipient, .component = component })) {
            entries[index] = component;
            index += 1;
        }
        try removed_entries.advance(done);
    }
    try (try choice.advance(try contents.advance(try removed_entries.finish()))).finish();
    if (count > try items.maximumDefinition(canonical, entries[0..index])) return error.InvalidItemCount;
    return .{ .count = @intCast(count), .kind = canonical, .components = entries[0..index], .encoded_bytes = 10 + index * 12 + scratch.len - output.len };
}

pub const SlotArguments = struct {
    registry: packets.Registry,
    items: *Items,
    stack: ?inventories.Stack,
    recipient: u128,
    /// Borrowed from a pinned definition for the duration of encoding.
    view: ?data.View,
};

pub const writeSlot: fn (destination: wire.Slot.Destination, args: SlotArguments) anyerror!wire.Slot.Completion = packets.nested(.{encodeSlot}).write;

pub const writeTemplate: fn (destination: wire_26_1.ItemStackTemplate.Destination, args: SlotArguments) anyerror!wire_26_1.ItemStackTemplate.Completion = packets.nested(.{encodeTemplate}).write;

fn encodeSlot(packet: wire.Slot.Writer, args: SlotArguments) !wire.Slot.Writer.Done {
    std.debug.assert((args.stack == null) == (args.view == null));
    const counted = try packet.itemCount(if (args.stack) |value| value.count else 0);
    var choice = try counted.anon_1();
    const branch = try choice.begin();
    if (args.stack == null) return choice.advance(try branch.case_0());
    var contents = try branch.case_default();
    const Body = @TypeOf(try contents.begin());
    const identified = try (try contents.begin()).itemId(try args.registry.itemId(@intCast(args.view.?.kind)));
    return choice.advance(try contents.advance(try encodeComponents(@TypeOf(identified), Body.Done, identified, args)));
}

fn encodeTemplate(packet: wire_26_1.ItemStackTemplate.Writer, args: SlotArguments) !wire_26_1.ItemStackTemplate.Writer.Done {
    const identified = try (try packet.itemId(try args.registry.itemId(@intCast(args.view.?.kind)))).itemCount(args.stack.?.count);
    return encodeComponents(@TypeOf(identified), wire_26_1.ItemStackTemplate.Writer.Done, identified, args);
}

fn encodeComponents(comptime Writer: type, comptime Done: type, packet: Writer, args: SlotArguments) !Done {
    const registry = args.registry;
    const items = args.items;
    const recipient = args.recipient;
    const view = args.view.?;
    std.debug.assert(items.components.dispatch.count <= data.maximum_components);
    var offsets: [data.maximum_components]usize = undefined;
    const count = items.components.dispatch.count;
    try items.components.resolve(view, offsets[0..count]);
    var emitted: std.StaticBitSet(data.maximum_components) = .empty;
    var removals: std.StaticBitSet(data.maximum_components) = .empty;
    for (offsets[0..count], 0..) |offset, index| {
        const stored = if (offset == std.math.maxInt(usize)) null else view.at(offset);
        switch (items.components.present(index, view, recipient, stored)) {
            .stored => if (stored.?.value != null) emitted.set(index) else removals.set(index),
            .added => emitted.set(index),
            .removed => removals.set(index),
            .absent => {},
        }
    }
    const counts = try (try packet.addedComponentCount(@intCast(emitted.count()))).removedComponentCount(@intCast(removals.count()));
    var entries = try counts.components();
    var writing = emitted.iterator(.{});
    while (writing.next()) |index| {
        const entry = (try entries.next()).?;
        try entries.advance(try items.components.dispatch.writeAt(entry, index, components.WriteContext{
            .item = view,
            .value = if (offsets[index] == std.math.maxInt(usize)) null else view.at(offsets[index]).value,
            .registry = registry,
            .protocol = packet._cursor.protocol_number,
            .recipient = recipient,
        }));
    }
    var removed_entries = try (try entries.finish()).removeComponents();
    for (items.components.order[0..count]) |index| {
        if (!removals.isSet(index)) continue;
        const entry = (try removed_entries.next()).?;
        try removed_entries.advance(try entry.type(@intCast(try items.components.dispatch.tagAt(packet._cursor.protocol_number, index))));
    }
    return removed_entries.finish();
}
