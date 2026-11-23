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

/// Alice, in survival with a bow and two arrows, draws fully at a cow six blocks ahead, and the
/// arrow hurts it. She shoots the second at her feet, where it sticks, and picks it up again.
/// The bow wears by a point a shot.
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
    pub const id = "e2e:ranged";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *Players, inventories: *Inventories, inventory: *vanilla.PlayerInventory, items: *vanilla.Items, mobs: *vanilla.Mobs, projectiles: *vanilla.Projectiles, control: *e2e.Control };
    const Phase = enum { waiting, aiming, down, landed, done };
    deps: Dependencies,
    phase: Phase = .waiting,
    cow: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "ready")) return .unhandled;
        if (self.phase != .waiting) return error.ReadyTwice;
        try self.give(36, "minecraft:bow", 1);
        try self.give(37, "minecraft:arrow", 2);
        self.cow = try self.deps.mobs.spawn(.{ .species = .cow, .world = self.deps.players.records[0].world, .position = .{ 0.5, 65, 6.5 }, .yaw = 0 });
        self.phase = .aiming;
        try self.deps.control.send(handle, "aim");
        return .handled;
    }

    fn give(self: *Probe, index: u16, name: []const u8, count: u16) !void {
        const item = try vanilla.item_data.define(self.deps.inventories, @intCast(game_data.registry.itemId(name).?), &.{});
        const at: inventories.Slot = .{ .owner = self.deps.players.records[0].uuid, .index = index };
        const old = try self.deps.inventories.get(at);
        if (!try self.deps.inventories.set(at, old.revision, .{ .item = item, .count = count })) return error.EquipmentConflict;
        self.deps.inventory.changed(0);
    }

    fn arrows(self: *Probe) !u16 {
        var total: u16 = 0;
        for (0..46) |index| {
            const stack = (try self.deps.inventories.get(.{ .owner = self.deps.players.records[0].uuid, .index = @intCast(index) })).stack orelse continue;
            if (try self.deps.items.kind(stack) == game_data.registry.itemId("minecraft:arrow").?) total += stack.count;
        }
        return total;
    }

    pub fn tick(self: *Probe) !void {
        const handle = self.deps.players.records[0].handle orelse return;
        switch (self.phase) {
            .aiming => {
                const cow = (try self.deps.mobs.get(self.cow)) orelse return error.CowGone;
                if (cow.living.health >= 10 and cow.alive()) return;
                if (try self.arrows() != 1) return error.ArrowNotSpent;
                self.phase = .down;
                try self.deps.control.send(handle, "down");
            },
            .down => if (self.deps.projectiles.activeCount() > 0 and try self.arrows() == 0) {
                self.phase = .landed;
            },
            .landed => {
                if (try self.arrows() != 1) return;
                if (self.deps.projectiles.activeCount() != 0) return error.ArrowStillThere;
                const bow = (try self.deps.inventories.get(.{ .owner = self.deps.players.records[0].uuid, .index = 36 })).stack orelse return error.BowGone;
                const pinned = try self.deps.items.acquire(bow);
                defer pinned.release();
                const damage = pinned.view.value(.damage) orelse return error.BowNotWorn;
                if ((try protocols.support.read_varint(damage))[0] != 2) return error.BowWearIncorrect;
                self.phase = .done;
                try self.deps.control.send(handle, "verified");
            },
            else => {},
        }
    }
};
