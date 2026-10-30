const std = @import("std");
const lightning_rod = @import("lightning_rod");
const inventories = @import("inventories");
const wire = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const Players = @import("players.zig").Players;
const Items = @import("items.zig").Items;
const Enchantments = @import("enchantments.zig").Enchantments;
const EnchantmentRegistry = @import("enchantment_registry.zig").EnchantmentRegistry;
const ClientRegistries = @import("client_registries.zig").ClientRegistries;
const Registries = @import("content_registries.zig").Registries;
const custom_data = @import("custom_data.zig");
const effects = @import("enchantment_effects.zig");

pub const EquipmentAttributes = struct {
    pub const id = "minecraft:equipment_attributes";
    pub const Base = struct { name: []const u8, value: f64 };
    pub const Configuration = struct { bases: []const Base = &.{} };
    pub const Dependencies = struct { players: *Players, items: *Items, enchantments: *EnchantmentRegistry, client: *ClientRegistries };
    const Range = struct { base: f64, client_base: f64, minimum: f64, maximum: f64 };
    const State = struct {
        owner: ?u128 = null,
        generation: u32 = 0,
        life: u32 = 0,
        selected: u4 = 0,
        slots: [6]u16 = undefined,
        invalid: u64 = 63,
        pending: bool = false,
    };
    const Key = struct { attribute: u32, slot: u3, id: []const u8 };
    const Sum = struct { add: f64 = 0, base: f64 = 0, total: f64 = 1 };
    const Modifier = struct { amount: f64, operation: effects.Operation };
    const KeyContext = struct {
        pub fn hash(_: @This(), key: Key) u64 {
            var hasher = std.hash.Wyhash.init(key.attribute);
            hasher.update(&.{key.slot});
            hasher.update(key.id);
            return hasher.final();
        }
        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return a.attribute == b.attribute and a.slot == b.slot and std.mem.eql(u8, a.id, b.id);
        }
    };
    const Property = struct { id: u32, value: f64 };
    deps: Dependencies,
    allocator: std.mem.Allocator,
    registry: *const Registries.Registry,
    ranges: []Range,
    states: []State,
    desired: []f64,
    sent: []f64,
    sums: []Sum,
    properties: []Property,
    modifiers: std.HashMapUnmanaged(Key, Modifier, KeyContext, 80) = .empty,
    actors: lightning_rod.system.IndexSet,
    observer: *inventories.Inventories.Observer,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*EquipmentAttributes {
        const registry = deps.client.client.get("minecraft:attribute") orelse return error.MissingAttributeRegistry;
        if (deps.items.deps.inventories.config.cache_items < 6) return error.ItemCacheTooSmall;
        const self = try allocator.create(EquipmentAttributes);
        self.* = .{
            .deps = deps,
            .allocator = allocator,
            .registry = registry,
            .ranges = try allocator.alloc(Range, registry.entries.len),
            .states = try allocator.alloc(State, deps.players.records.len),
            .desired = try allocator.alloc(f64, try std.math.mul(usize, registry.entries.len, deps.players.records.len)),
            .sent = try allocator.alloc(f64, try std.math.mul(usize, registry.entries.len, deps.players.records.len)),
            .sums = try allocator.alloc(Sum, registry.entries.len),
            .properties = try allocator.alloc(Property, registry.entries.len),
            .actors = try .init(allocator, deps.players.records.len),
            .observer = try deps.items.deps.inventories.observe(allocator, deps.players.records.len),
        };
        @memset(self.states, .{});
        @memset(self.sent, std.math.nan(f64));
        for (registry.entries, self.ranges) |entry, *range| {
            const data = try custom_data.Compound.init(entry.nbt);
            const initial = try data.getDouble("player_base") orelse return error.MissingAttributeDefault;
            range.* = .{ .base = initial, .client_base = initial, .minimum = try data.getDouble("minimum") orelse return error.MissingAttributeDefault, .maximum = try data.getDouble("maximum") orelse return error.MissingAttributeDefault };
            if (!std.math.isFinite(range.base) or !std.math.isFinite(range.minimum) or !std.math.isFinite(range.maximum) or range.minimum > range.base or range.base > range.maximum) return error.InvalidAttributeDefault;
        }
        for (configuration.bases) |base| {
            const index = registry.id(base.name) orelse return error.UnknownAttribute;
            if (!std.math.isFinite(base.value) or base.value < self.ranges[index].minimum or base.value > self.ranges[index].maximum) return error.InvalidAttributeBase;
            self.ranges[index].base = base.value;
        }
        try self.refresh();
        try deps.enchantments.registry.onChange(self, refresh);
        try deps.client.registry.onChange(self, refresh);
        return self;
    }

    fn refresh(self: *EquipmentAttributes) !void {
        self.registry = self.deps.client.client.get("minecraft:attribute").?;
        std.debug.assert(self.registry.entries.len == self.ranges.len);
        self.modifiers.clearRetainingCapacity();
        const capacity = try std.math.mul(usize, 6, self.deps.enchantments.effects.attribute_count);
        try self.modifiers.ensureTotalCapacity(self.allocator, std.math.cast(u32, capacity) orelse return error.TooManyAttributeModifiers);
        for (self.deps.enchantments.effects.values) |definition| for (definition.attributes) |attribute| {
            if (self.registry.id(attribute.attribute) == null) return error.UnknownAttribute;
        };
        for (self.states) |*state| state.invalid = 63;
    }

    fn ensure(self: *EquipmentAttributes, index: usize) !void {
        const player = &self.deps.players.records[index];
        const handle = player.handle orelse return error.PlayerNotConnected;
        const state = &self.states[index];
        const desired = self.desired[index * self.ranges.len ..][0..self.ranges.len];
        const sent = self.sent[index * self.ranges.len ..][0..self.ranges.len];
        if (state.owner != player.uuid or state.generation != handle.generation or state.life != player.life) {
            if (state.owner) |owner| self.observer.unwatch(owner);
            state.* = .{ .owner = player.uuid, .generation = handle.generation, .life = player.life, .selected = player.selected_slot, .slots = .{ 36 + @as(u16, player.selected_slot), 45, 5, 6, 7, 8 } };
            self.observer.watch(player.uuid, &state.slots, .{ .dirty = &state.invalid });
            self.actors.insert(index);
            @memset(sent, std.math.nan(f64));
        }
        if (state.selected != player.selected_slot) {
            state.slots[0] = 36 + @as(u16, player.selected_slot);
            state.selected = player.selected_slot;
            state.invalid |= 1;
        }
        if (state.invalid == 0) return;
        var slots: [6]inventories.Slot = undefined;
        for (state.slots, &slots) |at, *slot| slot.* = .{ .owner = player.uuid, .index = at };
        var contents: [6]inventories.Contents = undefined;
        try self.deps.items.deps.inventories.getMany(&slots, &contents);
        var stacks: [6]inventories.Stack = undefined;
        var equipped: [6]u3 = undefined;
        var count: usize = 0;
        for (contents, 0..) |entry, at| if (entry.stack) |stack| {
            stacks[count] = stack;
            equipped[count] = @intCast(at);
            count += 1;
        };
        var pinned: [6]Items.Prepared = undefined;
        try self.deps.items.acquireMany(stacks[0..count], pinned[0..count]);
        defer for (pinned[0..count]) |item| item.release();
        self.modifiers.clearRetainingCapacity();
        for (pinned[0..count], equipped[0..count]) |item, slot| {
            var entries = try Enchantments.Iterator.init(item.view.value(.enchantments) orelse continue);
            while (try entries.next()) |entry| {
                const enchantment_index = self.deps.enchantments.effects.registry.id(entry.name) orelse continue;
                const definition = self.deps.enchantments.effects.values[enchantment_index];
                if (entry.level == 0 or !definition.slots.contains(slot)) continue;
                for (definition.attributes) |modifier| {
                    const attribute = self.registry.id(modifier.attribute).?;
                    const amount = modifier.amount.evaluate(entry.level);
                    if (!std.math.isFinite(amount)) return error.InvalidEnchantmentEffect;
                    self.modifiers.putAssumeCapacity(.{ .attribute = attribute, .slot = slot, .id = modifier.id }, .{ .amount = amount, .operation = modifier.operation });
                }
            }
        }
        @memset(self.sums, .{});
        var modifiers = self.modifiers.iterator();
        while (modifiers.next()) |entry| {
            const sum = &self.sums[entry.key_ptr.attribute];
            switch (entry.value_ptr.operation) {
                .add_value => sum.add += entry.value_ptr.amount,
                .add_multiplied_base => sum.base += entry.value_ptr.amount,
                .add_multiplied_total => sum.total *= 1 + entry.value_ptr.amount,
            }
        }
        for (self.ranges, self.sums, desired) |range, sum, *actual| {
            actual.* = std.math.clamp((range.base + sum.add) * (1 + sum.base) * sum.total, range.minimum, range.maximum);
            if (!std.math.isFinite(actual.*)) return error.InvalidAttributeValue;
        }
        state.invalid = 0;
        state.pending = true;
    }

    pub fn value(self: *EquipmentAttributes, player_index: usize, name: []const u8) !f64 {
        try self.ensure(player_index);
        const attribute = self.registry.id(name) orelse return error.UnknownAttribute;
        return self.desired[player_index * self.ranges.len + attribute];
    }

    pub fn tick(self: *EquipmentAttributes) !void {
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            if (player.stage != .ready or !player.inWorld()) continue;
            try self.ensure(index);
            const state = &self.states[index];
            if (!state.pending) continue;
            const desired = self.desired[index * self.ranges.len ..][0..self.ranges.len];
            const sent = self.sent[index * self.ranges.len ..][0..self.ranges.len];
            var count: usize = 0;
            for (desired, sent, self.ranges, 0..) |current, previous, range, at| {
                if (current == previous or (std.math.isNan(previous) and current == range.client_base)) continue;
                self.properties[count] = .{ .id = @intCast(at), .value = current };
                count += 1;
            }
            if (count == 0) {
                state.pending = false;
                continue;
            }
            if (self.deps.players.sendPacket(write, player.protocol, player.handle.?, .{ @as(i32, @intCast(index + 1)), self.properties[0..count] })) {
                for (self.properties[0..count]) |property| sent[property.id] = property.value;
                state.pending = false;
            }
        }
        var at: usize = 0;
        while (at < self.actors.count) {
            const index = self.actors.indices[at];
            const player = self.deps.players.records[index];
            if (player.inWorld()) {
                at += 1;
                continue;
            }
            const state = &self.states[index];
            self.observer.unwatch(state.owner.?);
            state.* = .{};
            self.actors.remove(index);
        }
    }

    fn write(packet: wire.play.toClient.packet_entity_update_attributes.Writer, registry: packets.Registry, entity: i32, properties: []const Property) ![]u8 {
        var entries = try (try packet.entityId(entity)).properties(properties.len);
        for (properties) |property| {
            const entry = (try entries.next()).?;
            const modifiers = try (try (try entry.key(try registry.attributeId(@intCast(property.id)))).value(property.value)).modifiers(0);
            try entries.advance(try modifiers.finish());
        }
        return (try entries.finish()).finish();
    }
};
