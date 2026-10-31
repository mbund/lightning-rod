const std = @import("std");
const wire = @import("wire_1_21_5");
const encoding = @import("protocol_support");
const game_data = @import("game_data");
const inventories = @import("inventories");
const components = @import("item_components.zig");
const data = @import("item_data.zig");
const Items = @import("items.zig").Items;
const EnchantmentRegistry = @import("enchantment_registry.zig").EnchantmentRegistry;
const Players = @import("players.zig").Players;

const Integer = wire.SlotComponent.cases.data.max_stack_size.Payload;
const Text = wire.SlotComponent.cases.data.custom_name.Payload;
const Empty = wire.SlotComponent.cases.data.unbreakable.Payload;

pub const ItemProperties = struct {
    pub const id = "minecraft:item_properties";
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *Items };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemProperties {
        const self = try allocator.create(ItemProperties);
        self.* = .{ .deps = deps };
        try deps.items.components.on(.repair_cost, self, .{ .read = readInteger, .write = writeInteger });
        try deps.items.components.on(.max_stack_size, self, .{
            .read = readInteger,
            .write = writeStackLimit,
            .present = stackLimitPresentation,
            .retain = retainStackLimit,
            .maximum_extra_bytes = 17,
        });
        try deps.items.components.on(.custom_name, self, .{ .read = readText, .write = writeText });
        try deps.items.components.on(.item_name, self, .{ .read = readText, .write = writeText });
        return self;
    }
};

fn stackLimitPresentation(self: *ItemProperties, view: data.View, _: u128, stored: ?data.Component) components.Presentation {
    if (stored != null) return .stored;
    return if (self.deps.items.deps.definitions.properties[view.kind].stack_size != game_data.registry.items[view.kind].stack_size) .added else .absent;
}

fn retainStackLimit(self: *ItemProperties, context: components.RetentionContext) !bool {
    const bytes = context.component.value orelse return true;
    const value, const rest = try encoding.read_varint(bytes);
    std.debug.assert(rest.len == 0);
    return value != self.deps.items.deps.definitions.properties[context.kind].stack_size;
}

fn writeStackLimit(packet: Integer.Writer, self: *ItemProperties, context: components.WriteContext) !Integer.Writer.Done {
    if (context.value != null) return writeInteger(packet, self, context);
    return packet.value(self.deps.items.deps.definitions.properties[context.item.kind].stack_size);
}

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
    pub const Dependencies = struct { items: *Items, inventories: *inventories.Inventories, enchantments: *EnchantmentRegistry };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Durability {
        const self = try allocator.create(Durability);
        self.* = .{ .deps = deps };
        try deps.items.components.on(.max_damage, self, .{
            .read = readNumber,
            .write = writeMaximum,
            .present = maximumPresentation,
            .retain = retainMaximum,
            .maximum_extra_bytes = 17,
        });
        try deps.items.components.on(.damage, self, .{ .read = readNumber, .write = writeNumber });
        try deps.items.components.on(.unbreakable, self, .{ .read = readEmpty, .write = writeEmpty });
        return self;
    }

    fn maximumPresentation(self: *Durability, view: data.View, _: u128, stored: ?data.Component) components.Presentation {
        if (stored != null) return .stored;
        const maximum = self.deps.items.deps.definitions.properties[view.kind].durability;
        if (maximum == game_data.registry.items[view.kind].max_durability) return .absent;
        return if (maximum == 0) .removed else .added;
    }

    fn retainMaximum(self: *Durability, context: components.RetentionContext) !bool {
        const maximum = self.deps.items.deps.definitions.properties[context.kind].durability;
        const bytes = context.component.value orelse return maximum != 0;
        const value, const rest = try encoding.read_varint(bytes);
        std.debug.assert(rest.len == 0);
        return value != @as(i32, @intCast(maximum));
    }

    fn writeMaximum(packet: Integer.Writer, self: *Durability, context: components.WriteContext) !Integer.Writer.Done {
        if (context.value != null) return writeNumber(packet, self, context);
        const maximum = self.deps.items.deps.definitions.properties[context.item.kind].durability;
        std.debug.assert(maximum > 0 and maximum <= std.math.maxInt(i32));
        return packet.value(@intCast(maximum));
    }

    pub const Wear = struct {
        amount: i32,
        slot: u3,
        actor: *const Players.Player,
        random: std.Random,
        scratch: *std.heap.FixedBufferAllocator,
    };

    pub fn wear(self: *Durability, stack: inventories.Stack, context: Wear) !?inventories.Stack {
        var amount = context.amount;
        std.debug.assert(amount > 0);
        var damage: i32 = 0;
        {
            const lease = try self.deps.inventories.acquireItem(stack.item);
            defer lease.release();
            const view = try data.View.parse(lease.read().?);
            var maximum: i32 = @intCast(self.deps.items.deps.definitions.properties[view.kind].durability);
            if (view.get(data.key(.max_damage))) |entry| maximum = if (entry.value) |value| (try encoding.read_varint(value))[0] else 0;
            if (maximum == 0 or view.value(.unbreakable) != null) return stack;
            const modified = try self.deps.enchantments.effects.modifyFloat(.{
                .item = view,
                .slot = context.slot,
                .amount = @floatFromInt(amount),
                .channel = .item_damage,
                .random = context.random,
                .player = context.actor.uuid,
                .actor = context.actor,
                .location = .{ .world = context.actor.world, .position = context.actor.position },
                .scratch = context.scratch,
                .item_tags = &self.deps.items.deps.definitions.tags,
            });
            if (modified < 0.5) return stack;
            amount = if (modified >= 2147483648) std.math.maxInt(i32) else @intFromFloat(@round(modified));
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
    pub const Dependencies = struct { items: *Items, enchantments: *EnchantmentRegistry };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*EquipmentSlots {
        const self = try allocator.create(EquipmentSlots);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn removable(self: *EquipmentSlots, stack: inventories.Stack, equipped_slot: u3) !bool {
        const lease = try self.deps.items.acquire(stack);
        defer lease.release();
        return !try self.deps.enchantments.effects.prevents(lease.view, equipped_slot, .armor_change);
    }

    pub fn slot(self: *EquipmentSlots, stack: inventories.Stack) !u8 {
        return self.deps.items.deps.definitions.properties[try self.deps.items.kind(stack)].equipment;
    }
};
