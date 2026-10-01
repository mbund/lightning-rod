const std = @import("std");
const wire = @import("wire_1_21_5");
const encoding = @import("protocol_support");
const game_data = @import("game_data");
const inventories = @import("inventories");
const components = @import("item_components.zig");
const data = @import("item_data.zig");
const Items = @import("items.zig").Items;

const Integer = wire.SlotComponent.cases.data.max_stack_size.Payload;
const Text = wire.SlotComponent.cases.data.custom_name.Payload;
const Empty = wire.SlotComponent.cases.data.unbreakable.Payload;

pub const ItemProperties = struct {
    pub const id = "minecraft:item_properties";
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *Items };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemProperties {
        const self = try allocator.create(ItemProperties);
        self.* = .{};
        try deps.items.components.on(.max_stack_size, self, .{ .read = readInteger, .write = writeInteger });
        try deps.items.components.on(.custom_name, self, .{ .read = readText, .write = writeText });
        try deps.items.components.on(.item_name, self, .{ .read = readText, .write = writeText });
        try deps.items.components.on(.custom_data, self, .{ .read = readText, .write = writeText });
        return self;
    }
};

fn readInteger(packet: Integer.Reader, _: *ItemProperties, context: components.ReadContext) !Integer.Reader.Done {
    const value, const done = try packet.value();
    if (value < 0) return error.InvalidComponent;
    context.output.* = try encoding.write_varint(context.output.*, value);
    return done;
}

fn writeInteger(packet: Integer.Writer, _: *ItemProperties, context: components.WriteContext) !Integer.Writer.Done {
    const value, const rest = try encoding.read_varint(context.value.?);
    if (rest.len != 0) return error.Corrupt;
    return packet.value(value);
}

fn readText(packet: Text.Reader, _: *ItemProperties, context: components.ReadContext) !Text.Reader.Done {
    const value, const done = try packet.value();
    context.output.* = try encoding.write_bytes(context.output.*, value);
    return done;
}

fn writeText(packet: Text.Writer, _: *ItemProperties, context: components.WriteContext) !Text.Writer.Done {
    return packet.value(context.value.?);
}

pub const Durability = struct {
    pub const id = "minecraft:durability";
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *Items, inventories: *inventories.Inventories };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Durability {
        const self = try allocator.create(Durability);
        self.* = .{ .deps = deps };
        try deps.items.components.on(.max_damage, self, .{ .read = readNumber, .write = writeNumber });
        try deps.items.components.on(.damage, self, .{ .read = readNumber, .write = writeNumber });
        try deps.items.components.on(.unbreakable, self, .{ .read = readEmpty, .write = writeEmpty });
        return self;
    }

    pub fn wear(self: *Durability, stack: inventories.Stack, amount: i32) !?inventories.Stack {
        std.debug.assert(amount > 0);
        var damage: i32 = 0;
        {
            const lease = try self.deps.inventories.acquireItem(stack.item);
            defer lease.release();
            const view = try data.View.parse(lease.read().?);
            var maximum: i32 = game_data.registry.items[view.kind].max_durability;
            if (view.get(data.key(.max_damage))) |entry| maximum = if (entry.value) |value| (try encoding.read_varint(value))[0] else 0;
            if (maximum == 0 or view.value(.unbreakable) != null) return stack;
            if (view.value(.damage)) |value| damage = (try encoding.read_varint(value))[0];
            if (amount >= maximum - damage) return null;
        }
        var bytes: [5]u8 = undefined;
        const rest = try encoding.write_varint(&bytes, damage + amount);
        return try data.replace(self.deps.inventories, stack, .{ .key = data.key(.damage), .value = bytes[0 .. bytes.len - rest.len] });
    }

    fn readNumber(packet: Integer.Reader, _: *Durability, context: components.ReadContext) !Integer.Reader.Done {
        const value, const done = try packet.value();
        if (value < 0) return error.InvalidComponent;
        context.output.* = try encoding.write_varint(context.output.*, value);
        return done;
    }

    fn writeNumber(packet: Integer.Writer, _: *Durability, context: components.WriteContext) !Integer.Writer.Done {
        const value, const rest = try encoding.read_varint(context.value.?);
        if (rest.len != 0) return error.Corrupt;
        return packet.value(value);
    }

    fn readEmpty(packet: Empty.Reader, _: *Durability, _: components.ReadContext) !Empty.Reader.Done {
        _, const done = try packet.value();
        return done;
    }

    fn writeEmpty(packet: Empty.Writer, _: *Durability, _: components.WriteContext) !Empty.Writer.Done {
        return packet.value();
    }
};

pub const EquipmentSlots = struct {
    pub const id = "minecraft:equipment_slots";
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *Items };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*EquipmentSlots {
        const self = try allocator.create(EquipmentSlots);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn slot(self: *EquipmentSlots, stack: inventories.Stack) !u8 {
        const name = game_data.registry.itemName(@intCast(try self.deps.items.kind(stack))).?;
        const local = name["minecraft:".len..];
        for ([_][]const u8{ "leather_", "golden_", "chainmail_", "iron_", "diamond_", "netherite_" }) |material| {
            if (!std.mem.startsWith(u8, local, material)) continue;
            const kind = local[material.len..];
            if (std.mem.eql(u8, kind, "helmet")) return 5;
            if (std.mem.eql(u8, kind, "chestplate")) return 4;
            if (std.mem.eql(u8, kind, "leggings")) return 3;
            if (std.mem.eql(u8, kind, "boots")) return 2;
        }
        if (std.mem.eql(u8, local, "turtle_helmet") or std.mem.eql(u8, local, "carved_pumpkin") or std.mem.endsWith(u8, local, "_head") or std.mem.endsWith(u8, local, "_skull")) return 5;
        if (std.mem.eql(u8, local, "elytra")) return 4;
        if (std.mem.eql(u8, local, "shield")) return 1;
        return 0;
    }
};
