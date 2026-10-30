const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const sessions = @import("sessions");
const inventories = @import("inventories");
const e2e = @import("e2e");
const SilkSpawners = @import("silk_spawners").SilkSpawners;
const StormStick = @import("storm_stick").StormStick;

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 1, .render_distance = 2, .gamemode = .survival, .spawn_for_player = spawn })}),
        lightning_rod.plugin.configured(SilkSpawners, .{}),
        lightning_rod.plugin.configured(StormStick, .{}),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

fn spawn(_: *const vanilla.Players.Player) minecraft.Position {
    return .{ .x = 0.5, .y = 65, .z = 3.5 };
}

const Probe = struct {
    pub const id = "e2e:enchantments";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *vanilla.Players, chunks: *vanilla.Chunks, inventories: *vanilla.Inventories, inventory: *vanilla.PlayerInventory, items: *vanilla.Items, experience: *vanilla.Experience, dropped: *vanilla.ItemEntities, storm: *StormStick, control: *e2e.Control, reload: *vanilla.Reload };
    const Phase = enum { waiting, normal, normal_done, silk, silk_done, plain, enchanted, lightning, reloading, restored };
    const spawner: minecraft.BlockPosition = .{ .x = 0, .y = 66, .z = 0 };
    const target: minecraft.BlockPosition = .{ .x = 0, .y = 65, .z = -8 };
    deps: Dependencies,
    phase: Phase = .waiting,
    experience: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn give(self: *Probe, name: []const u8, enchantments: []const vanilla.Enchantments.Entry) !void {
        const player = self.deps.players.records[0];
        var copied: [3]vanilla.Enchantments.Entry = undefined;
        @memcpy(copied[0..enchantments.len], enchantments);
        var buffer: [512]u8 = undefined;
        const encoded = try vanilla.Enchantments.encode(copied[0..enchantments.len], &buffer);
        const item = try vanilla.item_data.define(self.deps.inventories, @intCast(game_data.registry.itemId(name).?), if (enchantments.len == 0) &.{} else &.{.{ .key = vanilla.item_data.key(.enchantments), .value = encoded }});
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 };
        const old = try self.deps.inventories.get(slot);
        if (!try self.deps.inventories.set(slot, old.revision, .{ .item = item, .count = 1 })) return error.EquipmentConflict;
        self.deps.inventory.changed(0);
    }

    fn totalExperience(self: *Probe) i64 {
        var amount: i64 = self.deps.players.records[0].experience.total;
        for (self.deps.experience.active.values()) |index| {
            const orb = self.deps.experience.orbs[index];
            if (orb.alive) amount += @as(i64, orb.value) * orb.count;
        }
        return amount;
    }

    fn message(self: *Probe, _: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "ready")) {
            if (self.phase != .waiting) return error.UnexpectedReady;
            if (self.deps.reload.latest()) |previous| if (previous.sequence > 0) {
                const slot = try self.deps.inventories.get(.{ .owner = self.deps.players.records[0].uuid, .index = 36 });
                const pinned = try self.deps.items.acquire(slot.stack orelse return error.MissingRestoredWand);
                defer pinned.release();
                if (try vanilla.Enchantments.level(pinned.view, "example:storm_calling") != 1) return error.EnchantmentNotPersisted;
                self.phase = .restored;
                try self.deps.control.send(self.deps.players.records[0].handle.?, "restored");
                return .handled;
            };
            try self.give("minecraft:diamond_pickaxe", &.{});
            try self.deps.chunks.setBlock(self.deps.players.records[0].world, .{ .x = spawner.x, .y = spawner.y, .z = spawner.z }, @intCast(game_data.registry.blockStateId("minecraft:spawner").?));
            self.phase = .normal;
        } else if (std.mem.eql(u8, text, "normal_verified")) {
            if (self.phase != .normal_done) return error.UnexpectedNormalObservation;
            try self.give("minecraft:diamond_pickaxe", &.{ .{ .name = "minecraft:silk_touch", .level = 1 }, .{ .name = "minecraft:efficiency", .level = 5 } });
            try self.deps.chunks.setBlock(self.deps.players.records[0].world, .{ .x = spawner.x, .y = spawner.y, .z = spawner.z }, @intCast(game_data.registry.blockStateId("minecraft:spawner").?));
            self.phase = .silk;
        } else if (std.mem.eql(u8, text, "silk_verified")) {
            if (self.phase != .silk_done) return error.UnexpectedSilkObservation;
            try self.give("minecraft:stick", &.{});
            try self.deps.chunks.setBlock(self.deps.players.records[0].world, .{ .x = target.x, .y = target.y, .z = target.z }, @intCast(game_data.registry.blockStateId("minecraft:gold_block").?));
            self.phase = .plain;
        } else if (std.mem.eql(u8, text, "plain_used")) {
            if (self.phase != .plain or self.deps.storm.casts != 0) return error.UnenchantedStickCast;
            try self.give("minecraft:stick", &.{.{ .name = "example:storm_calling", .level = 1 }});
            self.phase = .enchanted;
        } else if (std.mem.eql(u8, text, "lightning_verified")) {
            if (self.phase != .lightning or self.deps.storm.casts != 1) return error.UnexpectedLightningObservation;
            self.phase = .reloading;
            try self.deps.reload.stage("e2e:enchantments");
            return .handled;
        } else return .unhandled;
        try self.deps.control.send(self.deps.players.records[0].handle.?, @tagName(self.phase));
        return .handled;
    }

    pub fn tick(self: *Probe) !void {
        if (self.phase == .normal or self.phase == .silk) {
            const player = self.deps.players.records[0];
            if (try self.deps.chunks.getBlock(player.world, .{ .x = spawner.x, .y = spawner.y, .z = spawner.z }) != 0) return;
            if (self.phase == .normal) {
                self.experience = self.totalExperience();
                if (self.experience < 15 or self.experience > 43) return error.SpawnerExperienceIncorrect;
                if (self.deps.dropped.active.values().len != 0) return error.UnenchantedSpawnerDropped;
                self.phase = .normal_done;
            } else {
                if (self.totalExperience() != self.experience) return error.SilkSpawnerProducedExperience;
                if (self.deps.dropped.active.values().len != 1) return error.SilkSpawnerMissing;
                self.phase = .silk_done;
            }
            try self.deps.control.send(player.handle.?, @tagName(self.phase));
        } else if (self.phase == .enchanted and self.deps.storm.casts != 0) {
            if (self.deps.storm.casts != 1 or !std.meta.eql(self.deps.storm.last.?.block, .{ .x = target.x, .y = target.y, .z = target.z })) return error.LightningRaycastIncorrect;
            self.phase = .lightning;
            try self.deps.control.send(self.deps.players.records[0].handle.?, "lightning");
        }
    }
};
