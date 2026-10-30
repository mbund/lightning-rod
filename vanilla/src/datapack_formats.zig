const std = @import("std");
const datapacks = @import("datapacks");
const recipes = @import("recipes.zig");
const ids = @import("content_ids.zig");
const Components = @import("content_components.zig").Components;

pub const supported = block: {
    const formats = std.enums.values(Format);
    var result: [formats.len]datapacks.Version = undefined;
    for (formats, &result) |format, *version| version.* = .{ .major = @intFromEnum(format) };
    break :block result;
};

pub const Format = enum(u32) {
    v1_21 = 48,
    v1_21_5 = 71,
    v1_21_8 = 81,

    pub fn select(version: ?datapacks.Version) !Format {
        const value = version orelse return error.MissingPackFormat;
        if (value.minor != 0) return error.IncompatiblePackFormat;
        return std.enums.fromInt(Format, value.major) orelse error.IncompatiblePackFormat;
    }

    pub fn components(self: Format, allocator: std.mem.Allocator, value: std.json.Value) ![]const recipes.Component {
        if (self != .v1_21) return Components.decode(allocator, value);
        if (value != .object) return error.InvalidItemComponents;
        var normalized: std.json.ObjectMap = .empty;
        var entries = value.object.iterator();
        while (entries.next()) |entry| {
            const name = if (std.mem.startsWith(u8, entry.key_ptr.*, "!")) entry.key_ptr.* else try ids.identifier(allocator, entry.key_ptr.*);
            var component = entry.value_ptr.*;
            if (std.mem.eql(u8, name, "minecraft:enchantments")) {
                if (component != .object) return error.InvalidItemComponents;
                if (component.object.get("show_in_tooltip")) |visible| {
                    if (visible != .bool) return error.InvalidItemComponents;
                    if (!visible.bool) return error.UnsupportedItemComponent;
                }
                component = component.object.get("levels") orelse component;
            } else if (std.mem.eql(u8, name, "minecraft:unbreakable")) {
                if (component != .object) return error.InvalidItemComponents;
                if (component.object.get("show_in_tooltip")) |visible| {
                    if (visible != .bool) return error.InvalidItemComponents;
                    if (!visible.bool) return error.UnsupportedItemComponent;
                }
                component = .{ .object = .empty };
            } else if (std.mem.eql(u8, name, "minecraft:custom_name") or std.mem.eql(u8, name, "minecraft:item_name")) {
                component = try legacyText(allocator, component);
            } else if (std.mem.eql(u8, name, "minecraft:lore")) {
                if (component != .array) return error.InvalidItemComponents;
                var lines: std.array_list.Managed(std.json.Value) = .init(allocator);
                for (component.array.items) |line| try lines.append(try legacyText(allocator, line));
                component = .{ .array = lines };
            }
            const field = try normalized.getOrPut(allocator, name);
            if (field.found_existing) return error.InvalidItemComponents;
            field.value_ptr.* = component;
        }
        return Components.decode(allocator, .{ .object = normalized });
    }
};

fn legacyText(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    if (value != .string) return error.InvalidTextComponent;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, value.string, .{ .allocate = .alloc_always });
    return normalizeText(allocator, parsed, 0);
}

fn normalizeText(allocator: std.mem.Allocator, value: std.json.Value, depth: usize) anyerror!std.json.Value {
    if (depth == 64) return error.TextComponentDepthLimit;
    switch (value) {
        .string => return value,
        .array => {
            var result: std.array_list.Managed(std.json.Value) = .init(allocator);
            for (value.array.items) |element| try result.append(try normalizeText(allocator, element, depth + 1));
            return .{ .array = result };
        },
        .object => {
            var result: std.json.ObjectMap = .empty;
            var entries = value.object.iterator();
            while (entries.next()) |entry| {
                var name = entry.key_ptr.*;
                var field = entry.value_ptr.*;
                if (std.mem.eql(u8, name, "extra") or std.mem.eql(u8, name, "with") or std.mem.eql(u8, name, "separator")) {
                    field = try normalizeText(allocator, field, depth + 1);
                } else if (std.mem.eql(u8, name, "hoverEvent")) {
                    name = "hover_event";
                    if (field != .object) return error.InvalidTextComponent;
                    const action = field.object.get("action") orelse return error.InvalidTextComponent;
                    if (action != .string) return error.InvalidTextComponent;
                    if (!std.mem.eql(u8, action.string, "show_text")) return error.UnsupportedTextComponent;
                    const contents = field.object.get("contents") orelse return error.UnsupportedTextComponent;
                    var event: std.json.ObjectMap = .empty;
                    try event.put(allocator, "action", action);
                    try event.put(allocator, "value", try normalizeText(allocator, contents, depth + 1));
                    field = .{ .object = event };
                } else if (std.mem.eql(u8, name, "clickEvent")) {
                    name = "click_event";
                    if (field != .object) return error.InvalidTextComponent;
                    const action = field.object.get("action") orelse return error.InvalidTextComponent;
                    const content = field.object.get("value") orelse return error.InvalidTextComponent;
                    if (action != .string or content != .string) return error.InvalidTextComponent;
                    const key = if (std.mem.eql(u8, action.string, "open_url")) "url" else if (std.mem.eql(u8, action.string, "run_command") or std.mem.eql(u8, action.string, "suggest_command")) "command" else if (std.mem.eql(u8, action.string, "copy_to_clipboard")) "value" else return error.UnsupportedTextComponent;
                    var event: std.json.ObjectMap = .empty;
                    try event.put(allocator, "action", action);
                    try event.put(allocator, key, content);
                    field = .{ .object = event };
                }
                try result.put(allocator, name, field);
            }
            return .{ .object = result };
        },
        else => return error.InvalidTextComponent,
    }
}

test "legacy component conversion preserves nested text interactions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const legacy = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"text":"Accept","clickEvent":{"action":"run_command","value":"/accept"},"hoverEvent":{"action":"show_text","contents":{"text":"Invitation","extra":[{"text":" details"}]}}}
    , .{});
    const converted = try normalizeText(allocator, legacy, 0);
    const click = converted.object.get("click_event").?;
    try std.testing.expectEqualStrings("/accept", click.object.get("command").?.string);
    try std.testing.expect(!converted.object.contains("clickEvent"));
    const hover = converted.object.get("hover_event").?;
    const text = hover.object.get("value").?;
    try std.testing.expectEqualStrings(" details", text.object.get("extra").?.array.items[0].object.get("text").?.string);
    try std.testing.expectError(error.MissingPackFormat, Format.select(null));
    try std.testing.expectError(error.IncompatiblePackFormat, Format.select(.{ .major = 81, .minor = 1 }));
    const hidden = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"minecraft:unbreakable":{"show_in_tooltip":false}}
    , .{});
    try std.testing.expectError(error.UnsupportedItemComponent, Format.v1_21.components(allocator, hidden));
}

test "legacy aliases cannot overwrite a component or conceal invalid input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{
        \\{"damage":1,"minecraft:damage":2}
        ,
        \\{"damage":1,"!minecraft:damage":{}}
        ,
        \\{"custom_name":"\"First\"","minecraft:custom_name":"\"Second\""}
    }) |bytes| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
        try std.testing.expectError(error.InvalidItemComponents, Format.v1_21.components(allocator, value));
    }
}
