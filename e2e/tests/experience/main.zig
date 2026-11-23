const game_data = @import("game_data");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Inventories = @import("inventories").Inventories;
const Players = @import("players").players.Players;
const Reload = @import("reload").Reload;
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = 2, .render_distance = 2, .spawn_for_player = spawn }),
            lightning_rod.plugin.configured(vanilla.PlayerStates, .{ .gamemode = .survival }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

fn spawn(player: *const Players.Player) minecraft.Position {
    return .{ .x = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) -8.5 else 16.5, .y = 65, .z = 0.5 };
}

const Probe = struct {
    pub const id = "e2e:experience";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *Players,
        player_states: *vanilla.PlayerStates,
        inventories: *Inventories,
        inventory: *vanilla.PlayerInventory,
        experience: *vanilla.Experience,
        control: *e2e.Control,
        reload: *Reload,
    };
    deps: Dependencies,
    ready: [2]u32 = @splat(0),
    seen: [2]bool = @splat(false),

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        const player = &self.deps.players.records[handle.index];
        if (std.mem.eql(u8, text, "ready")) {
            if (self.ready[handle.index] == handle.generation) return error.DuplicateExperienceReady;
            self.ready[handle.index] = handle.generation;
            if (!std.mem.eql(u8, player.name[0..player.name_len], "alice")) _ = self.deps.player_states.setGameMode(player, .spectator);
            for (self.ready) |generation| if (generation == 0) return .handled;
            const previous = self.deps.reload.latest();
            if (previous != null and previous.?.sequence > 0) {
                if (std.mem.eql(u8, previous.?.token(), "e2e:xp-collected")) {
                    try self.verifyPlayers(99);
                    if ((try self.orbTotal()) != 0) return error.ExperienceOrbsDuplicated;
                    try self.deps.control.broadcast("complete");
                } else if (std.mem.eql(u8, previous.?.token(), "e2e:orbs")) {
                    try self.verifyPlayers(0);
                    if ((try self.orbTotal()) != 100) return error.ExperienceOrbsLost;
                    try self.deps.control.broadcast("restored_orbs");
                } else return error.UnexpectedExperienceReload;
            } else {
                try self.verifyPlayers(0);
                for (self.deps.players.activeSlots()) |index| {
                    const alice = self.deps.players.records[index];
                    if (!std.mem.eql(u8, alice.name[0..alice.name_len], "alice")) continue;
                    var enchantment: [128]u8 = undefined;
                    var entries = [_]vanilla.Enchantments.Entry{.{ .name = "minecraft:mending", .level = 1 }};
                    const enchanted = try vanilla.Enchantments.encode(&entries, &enchantment);
                    const item = try vanilla.item_data.define(self.deps.inventories, @intCast(game_data.registry.itemId("minecraft:diamond_pickaxe").?), &.{
                        .{ .key = vanilla.Items.key(.enchantments), .value = enchanted },
                        .{ .key = vanilla.Items.key(.damage), .value = &.{2} },
                    });
                    if (!try self.deps.inventories.set(.{ .owner = alice.uuid, .index = 36 }, 0, .{ .item = item, .count = 1 })) return error.ExperienceEquipmentConflict;
                    self.deps.inventory.changed(index);
                }
                try self.deps.experience.award(player.world, .{ 8.5, 65, 0.5 }, 100);
                if ((try self.orbTotal()) != 100) return error.ExperienceAwardIncorrect;
                try self.deps.control.broadcast("spawned");
            }
        } else if (std.mem.eql(u8, text, "seen")) {
            if (self.seen[handle.index]) return error.DuplicateExperienceObservation;
            self.seen[handle.index] = true;
            for (self.seen) |seen| if (!seen) return .handled;
            try self.verifyPlayers(0);
            try self.deps.reload.stage("e2e:orbs");
        } else if (std.mem.eql(u8, text, "collected")) {
            try self.verifyPlayers(99);
            if ((try self.orbTotal()) != 0) return error.ExperienceOrbStillAlive;
            try self.deps.reload.stage("e2e:xp-collected");
        } else if (std.mem.startsWith(u8, text, "points ")) {
            self.deps.experience.givePoints(handle.index, try std.fmt.parseInt(i32, text["points ".len..], 10));
            try self.deps.control.send(handle, "arithmetic");
        } else if (std.mem.startsWith(u8, text, "levels ")) {
            self.deps.experience.giveLevels(handle.index, try std.fmt.parseInt(i32, text["levels ".len..], 10));
            try self.deps.control.send(handle, "arithmetic");
        } else return .unhandled;
        return .handled;
    }

    fn orbTotal(self: *Probe) !i64 {
        return self.deps.experience.totalValue();
    }

    fn verifyPlayers(self: *Probe, amount: i32) !void {
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            const points = self.deps.player_states.records[index].experience;
            const expected = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) amount else 0;
            if (points.total != expected or points.score != expected) return error.PlayerExperienceIncorrect;
            if (expected == 99 and (points.level != 7 or @abs(points.progress - @as(f32, 8.0 / 21.0)) > 0.00001)) return error.PlayerLevelIncorrect;
        }
    }
};
