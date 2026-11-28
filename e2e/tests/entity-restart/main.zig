//! Every kind of entity comes back after a restart as it went: a cow, a dropped stack, an
//! experience orb and a stuck arrow are made by the player, left to settle, and the server
//! reloads. Their columns come back into memory as the player does, and each is found by its uuid
//! with what marked it.

const records = @import("records");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Players = @import("players").players.Players;
const Reload = @import("reload").Reload;
const sessions = @import("sessions");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 4 })}),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

const Probe = struct {
    pub const id = "e2e:entity_restart";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *Players,
        entities: *vanilla.Entities,
        mobs: *vanilla.Mobs,
        cow: *vanilla.Cow,
        dropped: *vanilla.ItemEntities,
        experience: *vanilla.Experience,
        projectiles: *vanilla.Projectiles,
        items: *vanilla.Items,
        reload: *Reload,
        control: *e2e.Control,
        storage: lightning_rod.storage.Space,
    };
    const Phase = enum { waiting, settling, reloading, resumed, complete };
    /// What each was made with, to be found again after the restart.
    const cow_health: f32 = 7;
    const orb_value = 17;
    const settle_ticks = 60;
    const resume_ticks = 400;
    const Expected = extern struct { cow: u128 = 0, item: u128 = 0, orb: u128 = 0, arrow: u128 = 0 };

    deps: Dependencies,
    phase: Phase = .waiting,
    ticks: u64 = 0,
    expected: Expected = .{},
    /// The client has the terrain again after the reload, so a message reaches it.
    rejoined: bool = false,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        var saved: [@sizeOf(Expected)]u8 = undefined;
        if (try records.Value.init(deps.storage).read(&saved)) |length| {
            if (length != saved.len) return error.InvalidEntityRestart;
            self.expected = std.mem.bytesToValue(Expected, &saved);
            self.phase = .resumed;
        }
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "terrain_ready")) return .unhandled;
        if (self.phase == .resumed) self.rejoined = true;
        if (self.phase != .waiting) return .handled;
        const player = &self.deps.players.records[handle.index];
        if (player.stage != .ready) return error.EntityRestartPlayerNotReady;
        const world = player.world;
        const cow = try self.deps.mobs.spawn(.{ .species = self.deps.cow.species, .world = world, .position = .{ 4.5, 65, 4.5 }, .yaw = 0 });
        const mob = (try self.deps.mobs.get(cow)).?;
        mob.living.health = cow_health;
        self.expected.cow = mob.entity.uuid;
        const stone = try self.deps.items.define("minecraft:stone");
        const item = try self.deps.dropped.create(world, .{ -3.5, 66, 2.5 }, .{ 0, 0, 0 }, .{ .item = stone, .count = 5 });
        self.expected.item = (try self.deps.entities.getById(item)).?.uuid;
        // Past the 8 blocks an orb follows a player from.
        try self.deps.experience.award(world, .{ 12.5, 66, -12.5 }, orb_value);
        const arrow = try self.deps.items.define("minecraft:arrow");
        try self.deps.projectiles.launch(.{ .kind = .arrow, .world = world, .position = .{ -2.5, 67, -2.5 }, .velocity = .{ 0, -0.6, 0 }, .owner = handle.index, .stack = .{ .item = arrow, .count = 1 }, .pickup = .disallowed });
        self.phase = .settling;
        return .handled;
    }

    pub fn checkpoint(self: *Probe, space: lightning_rod.storage.Space) !void {
        if (self.phase != .reloading and self.phase != .resumed and self.phase != .complete) return;
        try records.Value.init(space).write(std.mem.asBytes(&self.expected));
    }

    pub fn tick(self: *Probe) !void {
        switch (self.phase) {
            .waiting, .reloading, .complete => {},
            .settling => {
                self.ticks += 1;
                if (self.ticks < settle_ticks) return;
                const orbs = self.deps.experience.ids();
                if (orbs.len != 1) return error.EntityRestartOrbsSplit;
                self.expected.orb = ((try self.deps.experience.get(orbs[0])).?.body orelse return error.EntityRestartOrbLost).uuid;
                var arrows: [2]u128 = undefined;
                const found = try self.deps.projectiles.uuids(&arrows);
                if (found.len != 1) return error.EntityRestartArrowsLost;
                self.expected.arrow = found[0];
                if (!(try self.deps.projectiles.find(self.expected.arrow)).?.in_ground) return error.EntityRestartArrowNotStuck;
                self.phase = .reloading;
                try self.deps.reload.stage(id);
            },
            .resumed => {
                self.ticks += 1;
                if (self.rejoined and try self.restored()) {
                    try self.deps.control.broadcast("verified");
                    self.phase = .complete;
                } else if (self.ticks > resume_ticks) return error.EntitiesLostInRestart;
            },
        }
    }

    /// Whether each came back, failing at once on one that came back changed.
    fn restored(self: *Probe) !bool {
        const mobs = self.deps.mobs;
        var cow = false;
        for (0..mobs.active.count) |at| {
            const mob = try mobs.copyAt(mobs.active.at(at));
            if (mob.entity.uuid != self.expected.cow) continue;
            if (mob.entity.removed or mob.living.health != cow_health) return error.CowRestoredChanged;
            cow = true;
        }
        var item = false;
        var rows = self.deps.dropped.rows();
        while (try rows.next()) |row| {
            const body = (try self.deps.entities.getById(row.id)) orelse continue;
            if (body.uuid != self.expected.item) continue;
            if (!row.metadata.alive) return error.ItemRestoredChanged;
            item = true;
        }
        var orb = false;
        for (self.deps.experience.ids()) |entity| {
            const found = (try self.deps.experience.get(entity)) orelse continue;
            const body = found.body orelse continue;
            if (body.uuid != self.expected.orb) continue;
            if (found.orb.value != orb_value or !found.orb.alive) return error.OrbRestoredChanged;
            orb = true;
        }
        const arrow = (try self.deps.projectiles.find(self.expected.arrow)) orelse return false;
        if (!arrow.in_ground) return error.ArrowRestoredChanged;
        return cow and item and orb;
    }
};
