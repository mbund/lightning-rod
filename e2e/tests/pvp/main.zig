const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Inventories = @import("inventories").Inventories;
const Players = @import("players").players.Players;
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const sessions = @import("sessions");
const inventories = @import("inventories");
const e2e = @import("e2e");

/// Alice, with a diamond axe, faces Bob, who raises a shield toward her. Her first full swing
/// lands on the shield: Bob takes nothing, and the axe puts the shield on cooldown and lowers it.
/// Her second lands on Bob for the axe's 9.
pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{ lightning_rod.plugin.configured(Players, .{ .maximum = 2, .render_distance = 2, .spawn_for_player = spawn }), lightning_rod.plugin.configured(vanilla.PlayerStates, .{ .gamemode = .survival }) }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

fn isAlice(player: *const Players.Player) bool {
    return std.mem.eql(u8, player.name[0..player.name_len], "alice");
}

fn spawn(player: *const Players.Player) minecraft.Position {
    return .{ .x = 0.5, .y = 65, .z = if (isAlice(player)) 0.5 else 2.5 };
}

const Probe = struct {
    pub const id = "e2e:pvp";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *Players, player_states: *vanilla.PlayerStates, inventories: *Inventories, inventory: *vanilla.PlayerInventory, using: *vanilla.ItemUsing, cooldowns: *vanilla.ItemCooldowns, control: *e2e.Control };
    const Phase = enum { waiting, raising, blocked, struck, done };
    deps: Dependencies,
    phase: Phase = .waiting,
    ready: u2 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn slotOf(self: *Probe, alice: bool) ?usize {
        for (self.deps.players.activeSlots()) |slot| if (isAlice(&self.deps.players.records[slot]) == alice) return slot;
        return null;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "ready")) {
            const player = &self.deps.players.records[handle.index];
            try self.give(handle.index, if (isAlice(player)) "minecraft:diamond_axe" else "minecraft:shield", if (isAlice(player)) 36 else 45);
            try self.deps.control.send(handle, "armed");
            self.ready += 1;
            if (self.ready == 2) self.phase = .raising;
        } else if (std.mem.eql(u8, text, "attacked")) {
            const bob = self.slotOf(false) orelse return error.BobGone;
            const health = self.deps.player_states.of(&self.deps.players.records[bob]).health;
            switch (self.phase) {
                .blocked => {
                    if (health != 20) {
                        std.log.err("event=pvp_blocked health={d}", .{health});
                        return error.ShieldDidNotBlock;
                    }
                    if (!self.deps.cooldowns.active(bob, @intCast(game_data.registry.itemId("minecraft:shield").?))) return error.ShieldNotDisabled;
                    if (self.deps.using.of(bob) != null) return error.ShieldStillRaised;
                    self.phase = .struck;
                    try self.deps.control.send(handle, "again");
                },
                .struck => {
                    if (health != 11) {
                        std.log.err("event=pvp_struck health={d}", .{health});
                        return error.AxeHitIncorrect;
                    }
                    self.phase = .done;
                    for (self.deps.players.activeSlots()) |slot| try self.deps.control.send(self.deps.players.records[slot].handle.?, "verified");
                },
                else => return error.UnexpectedAttack,
            }
        } else return .unhandled;
        return .handled;
    }

    fn give(self: *Probe, slot: usize, name: []const u8, index: u16) !void {
        const item = try vanilla.item_data.define(self.deps.inventories, @intCast(game_data.registry.itemId(name).?), &.{});
        const at: inventories.Slot = .{ .owner = self.deps.players.records[slot].uuid, .index = index };
        const old = try self.deps.inventories.get(at);
        if (!try self.deps.inventories.set(at, old.revision, .{ .item = item, .count = 1 })) return error.EquipmentConflict;
        self.deps.inventory.changed(slot);
    }

    /// Once Bob has held his shield up long enough to block, Alice may swing.
    pub fn tick(self: *Probe) !void {
        if (self.phase != .raising) return;
        const bob = self.slotOf(false) orelse return;
        const alice = self.slotOf(true) orelse return;
        const use = self.deps.using.of(bob) orelse return;
        if (use.ticks < 10) return;
        self.phase = .blocked;
        var buffer: [32]u8 = undefined;
        try self.deps.control.send(self.deps.players.records[alice].handle.?, try std.fmt.bufPrint(&buffer, "attack {d}", .{bob + 1}));
    }
};
