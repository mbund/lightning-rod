const std = @import("std");
const nbt = @import("nbt");
const vanilla = @import("vanilla");
const inventories = @import("inventories");
const game_data = @import("game_data");
const fields = @import("nbt.zig");
const world_import = @import("import.zig");

pub fn stack(owner: *world_import.Import, allocator: std.mem.Allocator, doc: nbt.Document, node: nbt.Node) !?inventories.Stack {
    const name = try (try fields.field(doc, node, "id")).string();
    if (std.mem.eql(u8, name, "minecraft:air")) return null;
    const kind = game_data.registry.itemId(name) orelse {
        try owner.unsupported("item", name);
        return null;
    };
    const count = try fields.integer(node.childNamed(doc.nodes, "count") orelse node.childNamed(doc.nodes, "Count") orelse return error.MissingItemCount);
    if (count <= 0 or count > std.math.maxInt(u16)) return error.InvalidItemCount;
    var components: std.ArrayList(vanilla.Items.Component) = .empty;
    if (node.childNamed(doc.nodes, "components")) |values| {
        _ = try values.expectTag(.compound);
        var iterator = values.childIterator(doc.nodes);
        while (iterator.next()) |value| try component(owner, allocator, doc, value, &components);
    }
    if (node.childNamed(doc.nodes, "tag")) |tag| try legacy(owner, allocator, doc, tag, &components);
    const maximum = try owner.items.maximumDefinition(@intCast(kind), components.items);
    if (count > maximum) return error.InvalidItemCount;
    owner.counts.stacks += 1;
    return .{ .item = try vanilla.item_data.define(owner.inventories, @intCast(kind), components.items), .count = @intCast(count) };
}

fn component(owner: *world_import.Import, allocator: std.mem.Allocator, doc: nbt.Document, node: nbt.Node, output: *std.ArrayList(vanilla.Items.Component)) !void {
    if (std.mem.eql(u8, node.name, "minecraft:custom_data")) {
        try custom(allocator, node, output);
        return;
    }
    if (std.mem.eql(u8, node.name, "minecraft:block_state")) {
        _ = try node.expectTag(.compound);
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        try varint(&bytes.writer, @intCast(node.child_count));
        var iterator = node.childIterator(doc.nodes);
        while (iterator.next()) |property| {
            try string(&bytes.writer, property.name);
            try string(&bytes.writer, try property.string());
        }
        try output.append(allocator, .{ .key = vanilla.Items.key(.block_state), .value = bytes.written() });
        return;
    }
    var value = fields.json(allocator, doc, node) catch |err| switch (err) {
        error.UnsupportedNbtValue => {
            try owner.unsupported("item component", node.name);
            return;
        },
        else => return err,
    };
    if (value == .object) if (value.object.get("show_in_tooltip")) |visible| {
        if ((visible == .integer and visible.integer == 0) or (visible == .bool and !visible.bool)) try owner.unsupported("hidden item tooltip", node.name);
    };
    if (std.mem.eql(u8, node.name, "minecraft:enchantments") and value == .object) {
        if (value.object.get("levels")) |levels| value = levels;
    }
    if (std.mem.eql(u8, node.name, "minecraft:enchantments") and value == .object) try enchantments(owner, allocator, &value.object);
    if (std.mem.eql(u8, node.name, "minecraft:custom_name") or std.mem.eql(u8, node.name, "minecraft:item_name")) value = try text(allocator, value);
    if (std.mem.eql(u8, node.name, "minecraft:lore") and value == .array) {
        for (value.array.items) |*line| line.* = try text(allocator, line.*);
    }
    if (std.mem.eql(u8, node.name, "minecraft:unbreakable")) value = .{ .object = .empty };
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, node.name, value);
    const decoded = vanilla.content_components.Components.decode(allocator, .{ .object = object }) catch |err| switch (err) {
        error.UnsupportedItemComponent => {
            try owner.unsupported("item component", node.name);
            return;
        },
        else => return err,
    };
    try output.appendSlice(allocator, decoded);
}

fn enchantments(owner: *world_import.Import, allocator: std.mem.Allocator, values: *std.json.ObjectMap) !void {
    const registry = owner.content.enchantments.client.get("minecraft:enchantment").?;
    var index: usize = 0;
    while (index < values.count()) {
        const name = values.keys()[index];
        const qualified = if (std.mem.indexOfScalar(u8, name, ':') != null) name else try std.fmt.allocPrint(allocator, "minecraft:{s}", .{name});
        if (registry.id(qualified) == null) {
            try owner.unsupported("enchantment", qualified);
            _ = values.orderedRemove(name);
        } else index += 1;
    }
}

fn custom(allocator: std.mem.Allocator, node: nbt.Node, output: *std.ArrayList(vanilla.Items.Component)) !void {
    _ = try node.expectTag(.compound);
    const raw = try allocator.alloc(u8, 1 + node.payload.len);
    raw[0] = 10;
    @memcpy(raw[1..], node.payload);
    const canonical = try vanilla.custom_data.canonicalize(raw, try allocator.alloc(u8, raw.len), allocator);
    try output.append(allocator, .{ .key = vanilla.Items.key(.custom_data), .value = canonical });
}

fn text(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    if (value == .string and value.string.len != 0 and (value.string[0] == '{' or value.string[0] == '[' or value.string[0] == '"')) {
        return std.json.parseFromSliceLeaky(std.json.Value, allocator, value.string, .{});
    }
    return value;
}

fn legacy(owner: *world_import.Import, allocator: std.mem.Allocator, doc: nbt.Document, tag: nbt.Node, output: *std.ArrayList(vanilla.Items.Component)) !void {
    try custom(allocator, tag, output);
    var object: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "Damage", "RepairCost" }, [_][]const u8{ "minecraft:damage", "minecraft:repair_cost" }) |old, current| {
        if (tag.childNamed(doc.nodes, old)) |value| try object.put(allocator, current, .{ .integer = try fields.integer(value) });
    }
    if (tag.childNamed(doc.nodes, "Unbreakable")) |value| if (try fields.integer(value) != 0) try object.put(allocator, "minecraft:unbreakable", .{ .object = .empty });
    if (tag.childNamed(doc.nodes, "display")) |display| {
        if (display.childNamed(doc.nodes, "Name")) |name| try object.put(allocator, "minecraft:custom_name", try text(allocator, .{ .string = try name.string() }));
        if (display.childNamed(doc.nodes, "Lore")) |lore| {
            const lines = try fields.json(allocator, doc, lore);
            if (lines != .array) return error.InvalidItemComponents;
            for (lines.array.items) |*line| line.* = try text(allocator, line.*);
            try object.put(allocator, "minecraft:lore", lines);
        }
        if (display.childNamed(doc.nodes, "color") != null) try owner.unsupported("legacy item tag", "display.color");
    }
    if (tag.childNamed(doc.nodes, "Enchantments")) |list| {
        var levels: std.json.ObjectMap = .empty;
        var iterator = list.childIterator(doc.nodes);
        while (iterator.next()) |enchantment| try levels.put(allocator, try (try fields.field(doc, enchantment, "id")).string(), .{ .integer = try fields.integer(try fields.field(doc, enchantment, "lvl")) });
        try enchantments(owner, allocator, &levels);
        try object.put(allocator, "minecraft:enchantments", .{ .object = levels });
    }
    for ([_][]const u8{ "StoredEnchantments", "AttributeModifiers", "BlockEntityTag", "CanDestroy", "CanPlaceOn", "Potion", "pages" }) |name| {
        if (tag.childNamed(doc.nodes, name) != null) try owner.unsupported("legacy item tag", name);
    }
    try output.appendSlice(allocator, try vanilla.content_components.Components.decode(allocator, .{ .object = object }));
}

pub fn varint(writer: *std.Io.Writer, value: i32) !void {
    var bytes: [5]u8 = undefined;
    const rest = try game_data.encoding.write_varint(&bytes, value);
    try writer.writeAll(bytes[0 .. bytes.len - rest.len]);
}

fn string(writer: *std.Io.Writer, value: []const u8) !void {
    try varint(writer, @intCast(value.len));
    try writer.writeAll(value);
}

pub fn inventory(owner: *world_import.Import, allocator: std.mem.Allocator, doc: nbt.Document, list: nbt.Node, uuid: u128, player: bool, capacity: usize) !void {
    _ = try list.expectTag(.list);
    var edits: [64]inventories.Edit = undefined;
    var count: usize = 0;
    var used: u64 = 0;
    var iterator = list.childIterator(doc.nodes);
    while (iterator.next()) |entry| {
        const raw: u8 = @bitCast(try (try fields.field(doc, entry, "Slot")).byte());
        const index: u16 = if (player) switch (raw) {
            0...8 => raw + 36,
            9...35 => raw,
            100...103 => 108 - @as(u16, raw),
            150 => 45,
            else => return error.InvalidInventorySlot,
        } else raw;
        if (index >= capacity or index >= 64) return error.InvalidInventorySlot;
        const bit = @as(u64, 1) << @intCast(index);
        if (used & bit != 0) return error.DuplicateInventorySlot;
        used |= bit;
        const item = try stack(owner, allocator, doc, entry) orelse continue;
        edits[count] = .{ .slot = .{ .owner = uuid, .index = index }, .revision = 0, .stack = item };
        count += 1;
    }
    if (!try owner.inventories.editMany(edits[0..count])) return error.DuplicateInventory;
}
