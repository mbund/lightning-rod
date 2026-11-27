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

/// Alice, in survival with a bow and two arrows, shoots a cow six blocks ahead with a partial
/// draw. It takes 4 to 6, so it lives, and it panics. Once it calms down she shoots it again at
/// full draw, a critical hit of at least 6, and it dies. A player killed it, so it drops beef,
/// maybe leather, and 1 to 3 experience where it fell. Its body lies for twenty ticks, the
/// client sees it dying all the while, and then it is gone.
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
    pub const id = "e2e:kill";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *Players, inventories: *Inventories, inventory: *vanilla.PlayerInventory, items: *vanilla.Items, mobs: *vanilla.Mobs, experience: *vanilla.Experience, dropped: *vanilla.ItemEntities, control: *e2e.Control };
    const Phase = enum { waiting, first, panicking, second, dying, gone, done };
    /// The cow spawns here, six blocks ahead of Alice.
    const start: [3]f64 = .{ 0.5, 65, 6.5 };
    /// What the client draws for: 17 ticks is a partial draw, too weak to kill, and 30 a full
    /// one, which is critical.
    const partial = 17;
    const full = 30;

    deps: Dependencies,
    phase: Phase = .waiting,
    cow: u64 = 0,
    ticks: u64 = 0,
    hit: u64 = 0,
    panicked: bool = false,
    died: u64 = 0,
    /// What the client saw of the death: ticks from dying to gone, its body's last death time,
    /// and the orbs and items it saw by the body.
    seen: ?struct { ticks: u32, death_time: u32, orbs: u32, items: u32 } = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "ready")) {
            if (self.phase != .waiting) return error.ReadyTwice;
            try self.give(36, "minecraft:bow", 1);
            try self.give(37, "minecraft:arrow", 2);
            self.cow = try self.deps.mobs.spawn(.{ .species = .cow, .world = self.deps.players.records[0].world, .position = start, .yaw = 0 });
            self.phase = .first;
            try self.shoot(handle, partial);
        } else if (std.mem.startsWith(u8, text, "gone ")) {
            var fields = std.mem.tokenizeScalar(u8, text["gone ".len..], ' ');
            var values: [4]u32 = undefined;
            for (&values) |*value| value.* = try std.fmt.parseInt(u32, fields.next() orelse return error.GoneMalformed, 10);
            self.seen = .{ .ticks = values[0], .death_time = values[1], .orbs = values[2], .items = values[3] };
        } else return .unhandled;
        return .handled;
    }

    fn shoot(self: *Probe, handle: sessions.Handle, draw: u32) !void {
        var buffer: [48]u8 = undefined;
        try self.deps.control.send(handle, try std.fmt.bufPrint(&buffer, "shoot {d} {d}", .{ draw, self.deps.experience.networkId(self.cow) }));
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
        self.ticks += 1;
        const handle = self.deps.players.records[0].handle orelse return;
        switch (self.phase) {
            .waiting, .done => {},
            .first => {
                // Read as it stands, so watching it does not wake it.
                const cow = (try self.deps.mobs.byId(self.cow)) orelse return error.CowGone;
                if (cow.living.health == 10) return;
                std.log.info("event=kill_first_hit health={d}", .{cow.living.health});
                if (!cow.alive() or cow.living.health < 4 or cow.living.health > 6) return error.FirstHitIncorrect;
                if (try self.arrows() != 1) return error.ArrowNotSpent;
                self.hit = self.ticks;
                self.phase = .panicking;
            },
            .panicking => {
                const cow = (try self.deps.mobs.byId(self.cow)) orelse return error.CowGone;
                if (vanilla.mob_goals.isPanicking(cow)) {
                    self.panicked = true;
                    return;
                }
                // The panic goal starts on the next goal update, within two ticks.
                if (!self.panicked) {
                    if (self.ticks - self.hit > 3) return error.CowDidNotPanic;
                    return;
                }
                if (!cow.motion.on_ground) return;
                const moved = distance(cow.motion.position, start);
                std.log.info("event=kill_calm moved={d:.2} health={d}", .{ moved, cow.living.health });
                if (moved < 1) return error.CowDidNotFlee;
                self.phase = .second;
                try self.shoot(handle, full);
            },
            .second => {
                const cow = (try self.deps.mobs.byId(self.cow)) orelse return error.CowGone;
                if (!cow.living.dead) return;
                if (try self.arrows() != 0) return error.ArrowNotSpent;
                std.log.info("event=kill_died death_time={d}", .{cow.living.death_time});
                if (cow.living.death_time != 0) return error.DeathTimeIncorrect;
                try self.verifyDrops(cow.motion.position);
                self.died = self.ticks;
                self.phase = .dying;
            },
            .dying => {
                if (try self.deps.mobs.byId(self.cow)) |cow| {
                    if (self.ticks - self.died > 20) return error.BodyLingered;
                    if (cow.living.death_time != self.ticks - self.died) return error.DeathTimeIncorrect;
                    return;
                }
                std.log.info("event=kill_removed after={d}", .{self.ticks - self.died});
                if (self.ticks - self.died != 20) return error.BodyRemovedEarly;
                self.phase = .gone;
            },
            .gone => {
                const seen = self.seen orelse return;
                std.log.info("event=kill_seen ticks={d} death_time={d} orbs={d} items={d}", .{ seen.ticks, seen.death_time, seen.orbs, seen.items });
                // The client counts by its own ticks, which drift against the server's.
                if (seen.ticks < 18 or seen.ticks > 22) return error.ClientDeathLength;
                if (seen.death_time < 18) return error.ClientDeathAnimation;
                if (seen.orbs == 0) return error.ClientSawNoOrbs;
                if (seen.items == 0) return error.ClientSawNoItems;
                self.phase = .done;
                try self.deps.control.send(handle, "verified");
            },
        }
    }

    /// LivingEntity.dropAllDeathLoot for a cow a player killed: the cow loot table, 1 to 3 beef
    /// and 0 to 2 leather, and Animal's 1 to 3 experience, all where it fell.
    fn verifyDrops(self: *Probe, at: [3]f64) !void {
        var value: i32 = 0;
        var buffer: [64]u64 = undefined;
        for (try self.deps.experience.live(&buffer)) |entity| {
            const found = (try self.deps.experience.get(entity)) orelse continue;
            const body = found.body orelse continue;
            if (distance(body.position, at) > 1) return error.OrbAstray;
            value += found.orb.value * found.orb.count;
        }
        var beef: u32 = 0;
        var leather: u32 = 0;
        var rows = self.deps.dropped.rows();
        while (try rows.next()) |row| {
            if (!row.metadata.alive) continue;
            const view = (try self.deps.dropped.read(row.id)) orelse continue;
            if (distance(view.body.position, at) > 1) return error.ItemAstray;
            const stack = (try self.deps.inventories.get(vanilla.ItemEntities.slot(view.body))).stack orelse return error.ItemEmpty;
            const kind = try self.deps.items.kind(stack);
            if (kind == game_data.registry.itemId("minecraft:beef").?) {
                beef += stack.count;
            } else if (kind == game_data.registry.itemId("minecraft:leather").?) {
                leather += stack.count;
            } else return error.UnexpectedDrop;
        }
        std.log.info("event=kill_drops experience={d} beef={d} leather={d}", .{ value, beef, leather });
        if (value < 1 or value > 3) return error.ExperienceIncorrect;
        if (beef < 1 or beef > 3 or leather > 2) return error.LootIncorrect;
    }

    fn distance(a: [3]f64, b: [3]f64) f64 {
        const d: @Vector(3, f64) = @as(@Vector(3, f64), a) - @as(@Vector(3, f64), b);
        return @sqrt(@reduce(.Add, d * d));
    }
};
