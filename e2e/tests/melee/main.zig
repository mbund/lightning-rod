const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Inventories = @import("inventories").Inventories;
const Players = @import("players").players.Players;
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const sessions = @import("sessions");
const inventories = @import("inventories");
const protocols = @import("protocols");
const e2e = @import("e2e");

/// Alice, in survival, holds a sword with Sharpness I and Fire Aspect I and strikes the middle of
/// three cows at full strength, standing still: the hit takes 8 of its 10 health and sets it
/// alight, the sweep takes 2 from each neighbor, and the sword wears by one.
pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{ lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 2, .spawn_for_player = spawn }), lightning_rod.plugin.configured(vanilla.PlayerStates, .{ .gamemode = .survival }) }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

fn spawn(_: *const Players.Player) minecraft.Position {
    return .{ .x = 0.5, .y = 65, .z = 0.5 };
}

const Probe = struct {
    pub const id = "e2e:melee";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *Players, inventories: *Inventories, inventory: *vanilla.PlayerInventory, items: *vanilla.Items, mobs: *vanilla.Mobs, control: *e2e.Control };
    const sword_slot: u16 = 36;
    deps: Dependencies,
    cows: [3]u64 = undefined,
    spawned: bool = false,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "ready")) {
            try self.give();
            try self.deps.control.send(handle, "armed");
        } else if (std.mem.eql(u8, text, "charged")) {
            if (self.spawned) return error.ChargedTwice;
            // A cow's box is 0.9 wide: the neighbors stand clear of the middle one, inside its
            // box grown by one, and within three blocks of Alice.
            for (&self.cows, [_]f64{ -0.65, 0.5, 1.65 }) |*cow, x| cow.* = try self.deps.mobs.spawn(.{ .species = .cow, .world = self.deps.players.records[0].world, .position = .{ x, 65, -1.5 }, .yaw = 0 });
            self.spawned = true;
            var buffer: [32]u8 = undefined;
            // The id its client knows it by.
            try self.deps.control.send(handle, try std.fmt.bufPrint(&buffer, "attack {d}", .{self.deps.mobs.deps.entities.networkOf(self.cows[1]).?}));
        } else if (std.mem.eql(u8, text, "attacked")) {
            try self.verify();
            try self.deps.control.send(handle, "verified");
        } else return .unhandled;
        return .handled;
    }

    fn give(self: *Probe) !void {
        var entries = [_]vanilla.Enchantments.Entry{ .{ .name = "minecraft:sharpness", .level = 1 }, .{ .name = "minecraft:fire_aspect", .level = 1 } };
        var buffer: [128]u8 = undefined;
        const encoded = try vanilla.Enchantments.encode(&entries, &buffer);
        const item = try vanilla.item_data.define(self.deps.inventories, @intCast(game_data.registry.itemId("minecraft:diamond_sword").?), &.{.{ .key = vanilla.item_data.key(.enchantments), .value = encoded }});
        const slot: inventories.Slot = .{ .owner = self.deps.players.records[0].uuid, .index = sword_slot };
        const old = try self.deps.inventories.get(slot);
        if (!try self.deps.inventories.set(slot, old.revision, .{ .item = item, .count = 1 })) return error.EquipmentConflict;
        self.deps.inventory.changed(0);
    }

    fn verify(self: *Probe) !void {
        const target = (try self.deps.mobs.get(self.cows[1])) orelse return error.TargetGone;
        // A diamond sword's 7, and Sharpness I's 1.
        if (target.living.health != 2) {
            std.log.err("event=melee_target health={d}", .{target.living.health});
            return error.TargetHealthIncorrect;
        }
        // Fire Aspect I: four seconds alight.
        if (target.entity.fire_ticks <= 0 or target.entity.fire_ticks > 80) return error.TargetNotBurning;
        // The sweep's 1, and Sharpness I's 1 again.
        for ([_]u64{ self.cows[0], self.cows[2] }) |cow| {
            const neighbor = (try self.deps.mobs.get(cow)) orelse return error.NeighborGone;
            if (neighbor.living.health != 8) {
                std.log.err("event=melee_neighbor health={d}", .{neighbor.living.health});
                return error.SweepIncorrect;
            }
        }
        const held = try self.deps.inventories.get(.{ .owner = self.deps.players.records[0].uuid, .index = sword_slot });
        const pinned = try self.deps.items.acquire(held.stack orelse return error.SwordGone);
        defer pinned.release();
        const damage = pinned.view.value(.damage) orelse return error.SwordNotWorn;
        if ((try protocols.support.read_varint(damage))[0] != 1) return error.SwordWearIncorrect;
    }
};
