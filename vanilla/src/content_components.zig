const custom_data = @import("custom_data.zig");
const Enchantments = @import("enchantments.zig").Enchantments;
const ids = @import("content_ids.zig");
const recipes = @import("recipes.zig");
const std = @import("std");
const game_data = @import("game_data");
const support = @import("protocol_support");
const data = @import("item_data.zig");

pub const Components = struct {
    pub fn decode(allocator: std.mem.Allocator, value: std.json.Value) ![]const recipes.Component {
        if (value != .object) return error.InvalidItemComponents;
        const result = try allocator.alloc(recipes.Component, value.object.count());
        var iterator = value.object.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| {
            const removed = std.mem.startsWith(u8, entry.key_ptr.*, "!");
            const name = try ids.identifier(allocator, if (removed) entry.key_ptr.*[1..] else entry.key_ptr.*);
            if (!std.mem.startsWith(u8, name, "minecraft:")) return error.UnsupportedItemComponent;
            if (removed) {
                if (entry.value_ptr.* != .object or entry.value_ptr.object.count() != 0) return error.InvalidItemComponents;
                result[index] = .{ .key = try componentKey(name["minecraft:".len..]), .value = null };
                index += 1;
                continue;
            }
            var output: std.Io.Writer.Allocating = .init(allocator);
            if (std.mem.eql(u8, name, "minecraft:suspicious_stew_effects")) {
                const effects = entry.value_ptr.*;
                if (effects != .array or effects.array.items.len > 256) return error.InvalidItemComponents;
                try integer(&output.writer, @intCast(effects.array.items.len));
                for (effects.array.items) |effect| {
                    if (effect != .object) return error.InvalidItemComponents;
                    const effect_name = effect.object.get("id") orelse return error.InvalidItemComponents;
                    const duration = effect.object.get("duration") orelse return error.InvalidItemComponents;
                    if (effect_name != .string or duration != .integer or duration.integer < 0 or duration.integer > std.math.maxInt(i32)) return error.InvalidItemComponents;
                    const id = try game_data.snapshot.id(game_data.registry_snapshot, "minecraft:mob_effect", effect_name.string) orelse return error.UnknownEffect;
                    try integer(&output.writer, @intCast(id));
                    try integer(&output.writer, @intCast(duration.integer));
                }
            } else if (std.mem.eql(u8, name, "minecraft:damage") or std.mem.eql(u8, name, "minecraft:max_damage") or std.mem.eql(u8, name, "minecraft:max_stack_size") or std.mem.eql(u8, name, "minecraft:repair_cost")) {
                if (entry.value_ptr.* != .integer or entry.value_ptr.integer < 0 or entry.value_ptr.integer > std.math.maxInt(i32)) return error.InvalidItemComponents;
                if (std.mem.eql(u8, name, "minecraft:max_stack_size") and (entry.value_ptr.integer == 0 or entry.value_ptr.integer > 99)) return error.InvalidItemComponents;
                if (std.mem.eql(u8, name, "minecraft:max_damage") and entry.value_ptr.integer == 0) return error.InvalidItemComponents;
                try integer(&output.writer, @intCast(entry.value_ptr.integer));
            } else if (std.mem.eql(u8, name, "minecraft:custom_name") or std.mem.eql(u8, name, "minecraft:item_name")) {
                try output.writer.writeAll(try encodeNbt(allocator, allocator, entry.value_ptr.*));
            } else if (std.mem.eql(u8, name, "minecraft:lore")) {
                if (entry.value_ptr.* != .array or entry.value_ptr.array.items.len > 256) return error.InvalidItemComponents;
                try integer(&output.writer, @intCast(entry.value_ptr.array.items.len));
                for (entry.value_ptr.array.items) |line| try output.writer.writeAll(try encodeNbt(allocator, allocator, line));
            } else if (std.mem.eql(u8, name, "minecraft:enchantments")) {
                if (entry.value_ptr.* != .object or entry.value_ptr.object.count() > 256) return error.InvalidItemComponents;
                const values = try allocator.alloc(Enchantments.Entry, entry.value_ptr.object.count());
                var enchantments = entry.value_ptr.object.iterator();
                var at: usize = 0;
                while (enchantments.next()) |enchantment| {
                    if (enchantment.value_ptr.* != .integer or enchantment.value_ptr.integer < 0 or enchantment.value_ptr.integer > 255) return error.InvalidItemComponents;
                    values[at] = .{ .name = try ids.identifier(allocator, enchantment.key_ptr.*), .level = @intCast(enchantment.value_ptr.integer) };
                    at += 1;
                }
                var size: usize = 6;
                for (values) |value_entry| size += 6 + value_entry.name.len;
                try output.writer.writeAll(try Enchantments.encode(values, try allocator.alloc(u8, size)));
            } else if (std.mem.eql(u8, name, "minecraft:unbreakable")) {
                if (entry.value_ptr.* != .object or entry.value_ptr.object.count() != 0) return error.InvalidItemComponents;
            } else if (std.mem.eql(u8, name, "minecraft:custom_data")) {
                if (entry.value_ptr.* != .object) return error.InvalidItemComponents;
                try output.writer.writeByte(10);
                try nbtPayload(allocator, &output.writer, entry.value_ptr.*, 0);
            } else return error.UnsupportedItemComponent;
            result[index] = .{ .key = try componentKey(name["minecraft:".len..]), .value = output.written() };
            index += 1;
        }
        std.mem.sort(data.Component, result, {}, struct {
            fn less(_: void, a: data.Component, b: data.Component) bool {
                return a.key < b.key;
            }
        }.less);
        for (result, 0..) |component, at| if (at != 0 and result[at - 1].key == component.key) return error.InvalidItemComponents;
        return result;
    }
};

fn integer(writer: *std.Io.Writer, value: i32) !void {
    var bytes: [5]u8 = undefined;
    const rest = try support.write_varint(&bytes, value);
    try writer.writeAll(bytes[0 .. bytes.len - rest.len]);
}

pub fn encodeNbt(allocator: std.mem.Allocator, scratch: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(scratch);
    defer output.deinit();
    try output.writer.writeByte(try nbtTag(value));
    try nbtPayload(scratch, &output.writer, value, 0);
    return allocator.dupe(u8, output.written());
}

fn componentKey(name: []const u8) !u64 {
    inline for (.{ "suspicious_stew_effects", "damage", "max_damage", "max_stack_size", "repair_cost", "custom_data", "custom_name", "item_name", "lore", "enchantments", "unbreakable" }) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return support.cursor.layout.nameKey(candidate);
    }
    return error.UnsupportedItemComponent;
}

fn nbtTag(value: std.json.Value) !u8 {
    return switch (value) {
        .bool => 1,
        .integer => if (value.integer >= std.math.minInt(i32) and value.integer <= std.math.maxInt(i32)) 3 else 4,
        .float => 6,
        .string => 8,
        .array => 9,
        .object => 10,
        else => error.InvalidNbtValue,
    };
}

fn nbtString(writer: *std.Io.Writer, value: []const u8) !void {
    try custom_data.writeString(writer, value);
}

fn nbtPayload(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value, depth: usize) anyerror!void {
    if (depth >= 64) return error.NbtDepthLimit;
    switch (value) {
        .bool => try writer.writeByte(@intFromBool(value.bool)),
        .integer => if (try nbtTag(value) == 3) try writer.writeInt(i32, @intCast(value.integer), .big) else try writer.writeInt(i64, value.integer, .big),
        .float => try writer.writeInt(u64, @bitCast(value.float), .big),
        .string => try nbtString(writer, value.string),
        .array => {
            const values = value.array.items;
            const tag = if (values.len == 0) 0 else try nbtTag(values[0]);
            if (values.len > std.math.maxInt(i32)) return error.NbtLengthLimit;
            try writer.writeByte(tag);
            try writer.writeInt(i32, @intCast(values.len), .big);
            for (values) |element| {
                if (try nbtTag(element) != tag) return error.MixedNbtList;
                try nbtPayload(allocator, writer, element, depth + 1);
            }
        },
        .object => {
            const keys = try allocator.alloc([]const u8, value.object.count());
            @memcpy(keys, value.object.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            for (keys) |key| {
                const entry = value.object.get(key).?;
                try writer.writeByte(try nbtTag(entry));
                try nbtString(writer, key);
                try nbtPayload(allocator, writer, entry, depth + 1);
            }
            try writer.writeByte(0);
        },
        else => return error.InvalidNbtValue,
    }
}

test "component definitions encode Unicode NBT and validate removals and bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"minecraft:custom_data":{"name":"a\u0000\ud83d\ude00"},"!minecraft:damage":{}}
    , .{});
    const decoded = try Components.decode(allocator, parsed.value);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    for (decoded) |component| {
        if (component.key == data.key(.damage)) {
            try std.testing.expectEqual(@as(?[]const u8, null), component.value);
        } else {
            try std.testing.expectEqual(data.key(.custom_data), component.key);
            const compound = try custom_data.Compound.init(component.value.?);
            try std.testing.expectEqualStrings("a\x00\u{1f600}", (try compound.getString("name", allocator)).?);
        }
    }
    for ([_][]const u8{
        \\{"minecraft:max_stack_size":0}
        ,
        \\{"minecraft:max_stack_size":100}
        ,
        \\{"minecraft:max_damage":0}
        ,
        \\{"minecraft:damage":1,"!minecraft:damage":{}}
    }) |invalid| {
        const value = try std.json.parseFromSlice(std.json.Value, allocator, invalid, .{});
        try std.testing.expectError(error.InvalidItemComponents, Components.decode(allocator, value.value));
    }
}

test "component names share default namespace resolution and reject aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"damage":7,"custom_data":{"charge":12}}
    , .{});
    const components = try Components.decode(allocator, json);
    try std.testing.expectEqual(@as(usize, 2), components.len);
    const aliases = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"damage":7,"minecraft:damage":8}
    , .{});
    try std.testing.expectError(error.InvalidItemComponents, Components.decode(allocator, aliases));
}
