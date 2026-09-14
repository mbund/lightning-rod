const std = @import("std");
const inventories = @import("inventories");
const protocols = @import("protocols");

const support = protocols.support;
const component_count = 96;

pub const Items = struct {
    pub const id = "minecraft:items";

    pub const Configuration = struct {};

    pub const Dependencies = struct { inventories: *inventories.Inventories };

    deps: Dependencies,

    pub const Description = struct {
        kind: u32,
        maximum: u16,
        durability: i32,
        damage: i32 = 0,
        unbreakable: bool = false,
        efficiency: i32 = 0,
        silk_touch: bool = false,
        fortune: i32 = 0,
        unbreaking: i32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Items {
        const self = try allocator.create(Items);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn define(self: *Items, name: []const u8) !inventories.ItemId {
        const item = protocols.registry.itemId(name) orelse return error.UnknownItem;
        var definition: [6]u8 = undefined;
        std.mem.writeInt(u32, definition[0..4], @intCast(item), .little);
        definition[4..].* = .{ 0, 0 };
        return self.deps.inventories.defineItem(&definition);
    }

    pub fn stackLimit(self: *Items, stack: inventories.Stack) !u16 {
        return (try self.describe(stack)).maximum;
    }

    pub fn describe(self: *Items, stack: inventories.Stack) !Description {
        const lease = try self.deps.inventories.acquireItem(stack.item);
        defer lease.release();
        return describeBytes(lease.read().?);
    }

    pub fn describeBytes(bytes: []const u8) !Description {
        if (bytes.len < 6) return error.Corrupt;

        const item = std.mem.readInt(u32, bytes[0..4], .little);
        if (item >= protocols.registry.item_stack_sizes.len) return error.Corrupt;

        var result: Description = .{
            .kind = item,
            .maximum = protocols.registry.items[item].stack_size,
            .durability = protocols.registry.items[item].max_durability,
        };
        const added, var rest = try support.read_varint(bytes[4..]);
        const removed, rest = try support.read_varint(rest);
        if (added < 0 or removed < 0 or added > component_count or removed > component_count) return error.Corrupt;

        var seen: u128 = 0;

        for (0..@intCast(added)) |_| {
            const component, const value = try support.read_varint(rest);
            if (component < 0 or component >= component_count) return error.Corrupt;

            const bit = @as(u128, 1) << @intCast(component);
            if (seen & bit != 0) return error.Corrupt;
            seen |= bit;
            rest = (try protocols.wire.SlotComponent.read(rest).scan())._cursor.rest;

            switch (component) {
                1, 2, 3 => {
                    const number, _ = try support.read_varint(value);
                    if (number < 0) return error.Corrupt;

                    switch (component) {
                        1 => {
                            if (number == 0 or number > 99) return error.Corrupt;
                            result.maximum = @intCast(number);
                        },
                        2 => result.durability = number,
                        3 => result.damage = number,
                        else => unreachable,
                    }
                },
                4 => result.unbreakable = true,
                10 => {
                    const count, var enchantments = try support.read_varint(value);
                    if (count < 0) return error.Corrupt;

                    for (0..@intCast(count)) |_| {
                        const enchantment, enchantments = try support.read_varint(enchantments);
                        const level, enchantments = try support.read_varint(enchantments);
                        if (level < 0 or level > 255) return error.Corrupt;

                        const name = protocols.registry.enchantmentName(enchantment) orelse return error.Corrupt;

                        if (std.mem.eql(u8, name, "minecraft:efficiency")) result.efficiency = level;

                        if (std.mem.eql(u8, name, "minecraft:silk_touch")) result.silk_touch = level > 0;

                        if (std.mem.eql(u8, name, "minecraft:fortune")) result.fortune = level;

                        if (std.mem.eql(u8, name, "minecraft:unbreaking")) result.unbreaking = level;
                    }
                },
                else => {},
            }
        }

        for (0..@intCast(removed)) |_| {
            const component, rest = try support.read_varint(rest);
            if (component < 0 or component >= component_count or component == 1) return error.Corrupt;

            const bit = @as(u128, 1) << @intCast(component);
            if (seen & bit != 0) return error.Corrupt;
            seen |= bit;

            if (component == 2) result.durability = 0;
        }

        if (rest.len != 0) return error.Corrupt;
        if (result.durability > 0 and result.maximum != 1) return error.Corrupt;
        return result;
    }

    pub fn wear(self: *Items, stack: inventories.Stack, amount: i32) !?inventories.Stack {
        std.debug.assert(amount > 0);
        const info = try self.describe(stack);
        if (info.durability == 0 or info.unbreakable) return stack;
        if (amount >= info.durability - info.damage) return null;

        var encoded: [64 * 1024]u8 = undefined;
        var length: usize = undefined;
        {
            const lease = try self.deps.inventories.acquireItem(stack.item);
            defer lease.release();
            const bytes = lease.read().?;
            const added, var rest = try support.read_varint(bytes[4..]);
            const removed, rest = try support.read_varint(rest);
            const components = rest;
            var has_damage = false;

            for (0..@intCast(added)) |_| {
                const component, _ = try support.read_varint(rest);
                has_damage = has_damage or component == 3;
                rest = (try protocols.wire.SlotComponent.read(rest).scan())._cursor.rest;
            }

            var remaining_removed = removed;
            var removed_scan = rest;

            for (0..@intCast(removed)) |_| {
                const component, removed_scan = try support.read_varint(removed_scan);

                if (component == 3) remaining_removed -= 1;
            }

            std.mem.writeInt(u32, encoded[0..4], info.kind, .little);
            var output = try support.write_varint(encoded[4..], added + @as(i32, if (has_damage) 0 else 1));
            output = try support.write_varint(output, remaining_removed);
            rest = components;
            var written = false;

            for (0..@intCast(added)) |_| {
                const before = rest;
                const component, _ = try support.read_varint(rest);
                rest = (try protocols.wire.SlotComponent.read(rest).scan())._cursor.rest;

                if (!written and component >= 3) {
                    output = try support.write_varint(output, 3);
                    output = try support.write_varint(output, info.damage + amount);
                    written = true;
                }

                if (component == 3) continue;

                const size = before.len - rest.len;
                if (output.len < size) return error.ItemTooLarge;
                @memcpy(output[0..size], before[0..size]);
                output = output[size..];
            }

            if (!written) {
                output = try support.write_varint(output, 3);
                output = try support.write_varint(output, info.damage + amount);
            }

            for (0..@intCast(removed)) |_| {
                const component, rest = try support.read_varint(rest);

                if (component != 3) output = try support.write_varint(output, component);
            }

            length = encoded.len - output.len;
        }
        return .{ .item = try self.deps.inventories.defineItem(encoded[0..length]), .count = stack.count };
    }

    pub fn writeStack(self: *Items, protocol: i32, output: []u8, stack: ?inventories.Stack) ![]u8 {
        const value = stack orelse return support.write_varint(output, 0);
        const lease = try self.deps.inventories.acquireItem(value.item);
        defer lease.release();
        const bytes = lease.read().?;
        if (bytes.len < 6) return error.Corrupt;

        const item = std.mem.readInt(u32, bytes[0..4], .little);
        var wire: i32 = -1;

        inline for (protocols.catalog.entries) |Version| {
            if (protocol == Version.protocol_number and item < Version.Registry.canonical_item_to_wire.len)
                wire = Version.Registry.canonical_item_to_wire[item];
        }

        if (wire < 0) return error.UnsupportedItem;

        var rest = try support.write_varint(output, value.count);
        rest = try support.write_varint(rest, wire);
        if (rest.len < bytes.len - 4) return error.EndOfStream;
        @memcpy(rest[0 .. bytes.len - 4], bytes[4..]);
        return rest[bytes.len - 4 ..];
    }
};
