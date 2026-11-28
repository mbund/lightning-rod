//! Debugging views of the work the server spares. `/debug sleep` shows the player who asks it,
//! every few ticks, a particle over each entity near them that sleeps, by how it sleeps: green
//! asleep in the tick order, blue dormant, orange a mob at rest, white a mob idling in the herd.
//! Asked again, it stops.

const std = @import("std");
const commands = @import("commands");
const entities = @import("entities");
const Players = @import("players").players.Players;
const Player = @import("players").player_state.Player;
const world_effects = @import("vanilla_world").world_effects;
const Mobs = @import("vanilla_mobs").mobs.Mobs;

pub const SleepDebug = struct {
    pub const id = "lightning_rod:sleep_debug";
    pub const Configuration = struct {
        /// Ticks between particles, and how far from a watching player entities are shown.
        interval: u32 = 5,
        radius: f64 = 24,
    };
    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *Players,
        entities: *entities.Entities,
        mobs: *Mobs,
    };

    pub const permission: commands.Permission = .{ .name = "lightning_rod.command.debug", .description = "Show debugging views of what the server spares" };

    deps: Dependencies,
    config: Configuration,
    effects: world_effects.Effects,
    /// The players watching, by UUID.
    watching: []u128,
    watching_count: usize = 0,
    ticks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*SleepDebug {
        if (config.interval == 0) return error.InvalidConfiguration;
        const self = try allocator.create(SleepDebug);
        self.* = .{
            .deps = deps,
            .config = config,
            .effects = try .init(allocator, deps.players),
            .watching = try allocator.alloc(u128, deps.players.records.len),
        };
        const root = try deps.commands.literal(.{ .name = "debug", .description = "Show debugging views", .permission = &permission });
        _ = try root.add(self, commands.leaf(SleepDebug, NoArguments, .{
            .name = "sleep",
            .description = "Show or stop showing sleeping entities near you",
            .handler = toggle,
            .arguments = .{},
        }));
        return self;
    }

    const NoArguments = struct {};

    fn toggle(self: *SleepDebug, context: commands.Context, _: NoArguments) anyerror!void {
        for (self.watching[0..self.watching_count], 0..) |uuid, at| {
            if (uuid != context.sender) continue;
            self.watching[at] = self.watching[self.watching_count - 1];
            self.watching_count -= 1;
            context.reply("Stopped showing sleeping entities");
            return;
        }
        if (self.watching_count == self.watching.len) return error.TooManyWatching;
        self.watching[self.watching_count] = context.sender;
        self.watching_count += 1;
        context.reply("Showing sleeping entities: green asleep, blue dormant, orange a resting mob, white an idle mob");
    }

    pub fn tick(self: *SleepDebug) !void {
        self.ticks += 1;
        if (self.ticks % self.config.interval != 0) return;
        var all: entities.Kinds = .{};
        all.bits = .full;
        all.bits.unset(Players.entityKind());
        for (self.watching[0..self.watching_count]) |uuid| {
            const player = self.deps.players.find(uuid) orelse continue;
            const at: [3]f64 = .{ player.position.x, player.position.y, player.position.z };
            const reach = self.config.radius;
            var walk: Walk = .{ .debug = self, .player = player };
            try self.deps.entities.places.space.each(player.world, .{ .min = .{ at[0] - reach, at[1] - reach, at[2] - reach }, .max = .{ at[0] + reach, at[1] + reach, at[2] + reach } }, all, &walk, Walk.visit);
        }
    }

    const Walk = struct {
        debug: *SleepDebug,
        player: *const Player,

        fn visit(walk: *Walk, entry: entities.space.Entry) anyerror!bool {
            const debug = walk.debug;
            const placed = debug.deps.entities.directory.entry(entry.slot);
            // Out of the tick order, as a rider is, it neither ticks nor sleeps.
            if (placed.sequence == 0) return false;
            const particle: world_effects.Effects.Particles = .{
                .particle = if (placed.dormant) .soul_fire_flame else if (!placed.awake) .happy_villager else switch (debug.deps.mobs.restOf(entry.slot) orelse return false) {
                    .awake => return false,
                    .resting => .wax_on,
                    .idling => .wax_off,
                },
                .at = .{ .x = entry.position[0], .y = entry.position[1] + entry.shape.height + 0.4, .z = entry.position[2] },
                .count = 1,
            };
            debug.effects.particlesTo(walk.player, particle);
            return false;
        }
    };
};

comptime {
    // A plugin compiles only where referenced, so its tests reference it.
    _ = &SleepDebug.init;
    _ = &SleepDebug.tick;
}
