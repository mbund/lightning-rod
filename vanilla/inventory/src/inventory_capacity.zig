const std = @import("std");
const inventories = @import("inventories");
const Players = @import("players").players.Players;
const menu_click = @import("menu_click.zig");

pub const InventoryCapacity = struct {
    pub const id = "minecraft:inventory_capacity";
    pub const Configuration = struct {
        /// Item stacks in memory beside players' slots: each dropped item owns one, which its
        /// tick, merges and replication read. As many as the item records cache holds.
        item_slots: usize = 8192,
    };
    pub const Dependencies = struct { players: *Players };
    pub const Provides = .{inventories.SlotCapacity};

    capacity: inventories.SlotCapacity,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*InventoryCapacity {
        const slots = try std.math.add(usize, try std.math.mul(usize, menu_click.maximum_slots, deps.players.records.len), config.item_slots);
        const self = try allocator.create(InventoryCapacity);
        self.* = .{ .capacity = .{ .slots = slots } };
        return self;
    }

    pub fn provide(self: *InventoryCapacity, comptime Contract: type) Contract {
        if (Contract == inventories.SlotCapacity) return self.capacity;
        @compileError("unsupported inventory capacity contract");
    }
};
