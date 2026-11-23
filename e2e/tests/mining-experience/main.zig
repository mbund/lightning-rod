const inventories = @import("inventories");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Chunks = @import("chunks").Chunks;
const Inventories = @import("inventories").Inventories;
const Players = @import("players").players.Players;
const Reload = @import("reload").Reload;
const game_data = @import("game_data");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 2, .spawn_for_player = spawn }),
            lightning_rod.plugin.configured(vanilla.PlayerStates, .{ .gamemode = .survival }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

fn spawn(_: *const Players.Player) minecraft.Position {
    return .{ .x = 0.5, .y = 65, .z = 3.5 };
}

const Probe = struct {
    pub const id = "e2e:mining_experience";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *Players,
        player_states: *vanilla.PlayerStates,
        chunks: *Chunks,
        inventories: *Inventories,
        inventory: *vanilla.PlayerInventory,
        experience: *vanilla.Experience,
        mining: *vanilla.Mining,
        control: *e2e.Control,
        reload: *Reload,
    };
    const Phase = enum { waiting, normal, normal_mined, silk, silk_mined, wrong, wrong_mined, reloading, restored };
    const target: minecraft.BlockPosition = .{ .x = 0, .y = 66, .z = 0 };
    deps: Dependencies,
    phase: Phase = .waiting,
    total: i32 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "ready")) {
            if (self.phase != .waiting) return error.UnexpectedMiningReady;
            if (self.deps.reload.latest()) |previous| if (previous.sequence > 0) {
                if (!std.mem.eql(u8, previous.token(), "e2e:mining-xp")) return error.UnexpectedMiningReload;
                const amount = self.deps.player_states.records[handle.index].experience.total;
                if (amount < 3 or amount > 7) return error.MiningExperienceNotPersisted;
                self.phase = .restored;
                try self.deps.control.send(handle, "restored");
                return .handled;
            };
            try self.prepare(handle, .normal);
        } else if (std.mem.eql(u8, text, "normal_verified")) {
            if (self.phase != .normal_mined) return error.UnexpectedMiningObservation;
            try self.prepare(handle, .silk);
        } else if (std.mem.eql(u8, text, "silk_verified")) {
            if (self.phase != .silk_mined) return error.UnexpectedMiningObservation;
            try self.prepare(handle, .wrong);
        } else if (std.mem.eql(u8, text, "wrong_verified")) {
            if (self.phase != .wrong_mined) return error.UnexpectedMiningObservation;
            self.phase = .reloading;
            try self.deps.reload.stage("e2e:mining-xp");
        } else return .unhandled;
        return .handled;
    }

    fn prepare(self: *Probe, handle: sessions.Handle, phase: Phase) !void {
        const player = self.deps.players.records[handle.index];
        const kind: u32 = @intCast(game_data.registry.itemId(if (phase == .wrong) "minecraft:wooden_pickaxe" else "minecraft:diamond_pickaxe").?);
        var bytes: [128]u8 = undefined;
        var enchantments = [_]vanilla.Enchantments.Entry{.{ .name = "minecraft:silk_touch", .level = 1 }};
        const components: []const vanilla.Items.Component = if (phase == .silk) &.{.{ .key = vanilla.Items.key(.enchantments), .value = try vanilla.Enchantments.encode(&enchantments, &bytes) }} else &.{};
        const item = try vanilla.item_data.define(self.deps.inventories, kind, components);
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 };
        const held = try self.deps.inventories.get(slot);
        if (!try self.deps.inventories.set(slot, held.revision, .{ .item = item, .count = 1 })) return error.MiningEquipmentConflict;
        self.deps.inventory.changed(handle.index);
        try self.deps.chunks.setBlock(player.world, .{ .x = target.x, .y = target.y, .z = target.z }, @intCast(game_data.registry.blockStateId("minecraft:diamond_ore").?));
        self.phase = phase;
        try self.deps.control.send(handle, @tagName(phase));
    }

    pub fn tick(self: *Probe) !void {
        if (self.phase != .normal and self.phase != .silk and self.phase != .wrong) return;
        const player = self.deps.players.records[0];
        if (player.handle == null or self.deps.mining.states[0].active or try (try self.deps.chunks.simulation(1)).getBlock(player.world, .{ .x = target.x, .y = target.y, .z = target.z }) != 0) return;
        const remaining = try self.deps.experience.totalValue();
        const points = self.deps.player_states.records[0].experience;
        if (self.phase == .normal) {
            if (remaining > 0) return;
            if (points.total < 3 or points.total > 7) return error.MiningExperienceIncorrect;
            self.total = points.total;
            self.phase = .normal_mined;
        } else {
            if (remaining != 0 or points.total != self.total) return error.UnexpectedMiningExperience;
            self.phase = if (self.phase == .silk) .silk_mined else .wrong_mined;
        }
        try self.deps.control.send(player.handle.?, @tagName(self.phase));
    }
};
