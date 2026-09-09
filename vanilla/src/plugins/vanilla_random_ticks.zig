const engine = @import("random_ticks/engine.zig");
const lightning_rod = @import("lightning_rod");
const std = @import("std");
const chunk_tickets = @import("../vanilla/chunk_tickets.zig");
const simulation_admission = @import("../vanilla/simulation_admission.zig");
const vanilla_persistence = @import("vanilla_persistence.zig");
const vanilla_collision_projection = @import("vanilla_collision_projection.zig");

pub const ScheduledBlockTicks = engine.ScheduledBlockTicks;
pub const CropGrowth = @import("random_ticks/crop_growth.zig").CropGrowth;
pub const PlantGrowth = @import("random_ticks/plant_growth.zig").PlantGrowth;
pub const PlantSpread = @import("random_ticks/plant_spread.zig").PlantSpread;
pub const FarmlandHydration = @import("random_ticks/farmland_hydration.zig").FarmlandHydration;
pub const LeafDecay = @import("random_ticks/leaf_decay.zig").LeafDecay;
pub const FireAndLava = @import("random_ticks/fire_and_lava.zig").FireAndLava;
pub const IceAndSnow = @import("random_ticks/ice_and_snow.zig").IceAndSnow;
pub const CopperWeathering = @import("random_ticks/copper_weathering.zig").CopperWeathering;
pub const RandomBlockEvents = @import("random_ticks/random_block_events.zig").RandomBlockEvents;

pub const RandomTicks = struct {
    pub const id = "minecraft:random_ticks";
    pub const Trace = engine.RandomTicks.Trace;
    pub const Configuration = engine.RandomTicks.Configuration;
    pub const Dependencies = struct {
        scheduled: *ScheduledBlockTicks,
        crops: *CropGrowth,
        growth: *PlantGrowth,
        spread: *PlantSpread,
        farmland: *FarmlandHydration,
        leaves: *LeafDecay,
        fire_and_lava: *FireAndLava,
        ice_and_snow: *IceAndSnow,
        copper: *CopperWeathering,
        block_events: *RandomBlockEvents,
        worlds: *lightning_rod.worlds.Worlds,
        clock: *lightning_rod.clock.Clock,
        time: *lightning_rod.time.Time,
        rules: *lightning_rod.game_rules.GameRules,
        random: *lightning_rod.random.Random,
        blocks: *lightning_rod.blocks.Blocks,
        players: *lightning_rod.players.Players,
        active: *chunk_tickets.ChunkTickets,
        admission: *simulation_admission.SimulationAdmission,
        materialization: *vanilla_persistence.Materializer,
        collision_projection: *vanilla_collision_projection.CollisionProjection,
        living: *lightning_rod.entities.LivingEntities,
        items: *lightning_rod.entities.ItemEntities,
        outputs: *lightning_rod.Packets,
        runtime_metrics: ?*lightning_rod.metrics.Runtime = null,
    };

    state: *engine.RandomTicks,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, settings: Configuration) !*RandomTicks {
        const self = try allocator.create(RandomTicks);
        errdefer allocator.destroy(self);
        self.* = .{ .state = try engine.RandomTicks.init(allocator, .{
            .scheduled = deps.scheduled,
            .crops = deps.crops.behavior(),
            .growth = deps.growth.behavior(),
            .spread = deps.spread.behavior(),
            .farmland = deps.farmland.behavior(),
            .leaves = deps.leaves.behavior(),
            .fire_and_lava = deps.fire_and_lava.behavior(),
            .ice_and_snow = deps.ice_and_snow.behavior(),
            .copper = deps.copper.behavior(),
            .block_events = deps.block_events.behavior(),
            .worlds = deps.worlds,
            .clock = deps.clock,
            .time = deps.time,
            .rules = deps.rules,
            .random = deps.random,
            .blocks = deps.blocks,
            .players = deps.players,
            .active = deps.active,
            .admission = deps.admission,
            .materialization = deps.materialization,
            .collision_projection = deps.collision_projection,
            .living = deps.living,
            .items = deps.items,
            .outputs = deps.outputs,
            .runtime_metrics = deps.runtime_metrics,
        }, settings) };
        return self;
    }

    pub fn tick(self: *RandomTicks, io: std.Io, allocator: std.mem.Allocator) lightning_rod.plugin_lifecycle.FatalError!void {
        try self.state.tick(io, allocator);
    }
};
