const lightning_rod = @import("lightning_rod");
const std = @import("std");

const entities = lightning_rod.entities;
const geometry = lightning_rod.geometry;
const lifecycle = lightning_rod.player_lifecycle;
const players = lightning_rod.players;
const Packets = lightning_rod.Packets;

pub const PlayJoin = struct {
    pub const id = "minecraft:play_join";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        blocks: *lightning_rod.blocks.Blocks,
        events: *lifecycle.Events,
        paging: *@import("vanilla_persistence.zig").Persistence,
        players: *players.Players,
        output: *Packets,
        worlds: *lightning_rod.worlds.Worlds,
    };

    const Placement = enum(u8) { none, collision, spawn_surface };

    deps: Dependencies,
    pending: []Placement,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayJoin {
        const self = try allocator.create(PlayJoin);
        self.* = .{
            .deps = deps,
            .pending = try allocator.alloc(Placement, deps.players.records.len),
        };
        @memset(self.pending, .none);
        return self;
    }

    pub fn tick(self: *PlayJoin, _: std.mem.Allocator) void {
        self.placePending();
        for (self.deps.events.play_started) |event| self.start(event);
    }

    fn placePending(self: *PlayJoin) void {
        for (self.pending, 0..) |placement, slot| {
            if (placement == .none) continue;
            const player = &self.deps.players.records[slot];
            if (player.state != .play) {
                self.pending[slot] = .none;
                continue;
            }
            const chunk = playerChunk(player);
            if (self.deps.paging.request(player.world, chunk) != .resident) continue;
            const moved = self.place(@intCast(slot), placement == .spawn_surface);
            self.pending[slot] = .none;
            if (!moved) continue;
            if (placement == .spawn_surface)
                self.deps.output.bootstrap(@intCast(slot), .spawn_position);
            self.deps.output.emitPlayerPosition(@intCast(slot), null);
            self.deps.output.emitPlayerCorrection(@intCast(slot));
        }
    }

    fn start(self: *PlayJoin, value: lifecycle.PlayStarted) void {
        const player = &self.deps.players.records[value.slot];
        const placement: Placement = if (value.new_player) .spawn_surface else .collision;
        if (self.deps.paging.request(player.world, playerChunk(player)) == .resident) {
            _ = self.place(value.slot, placement == .spawn_surface);
        } else {
            self.pending[value.slot] = placement;
            if (value.new_player) self.placeAboveWorld(value.slot);
        }
        self.bootstrap(value.slot);
    }

    fn place(self: *PlayJoin, slot: u16, force_surface: bool) bool {
        const player = &self.deps.players.records[slot];
        if (!force_surface and !playerCollides(self.deps.blocks, player)) return false;
        const x = geometry.blockCoord(player.position.x);
        const z = geometry.blockCoord(player.position.z);
        const y: i16 = self.deps.blocks.highestBlockYAt(player.world, x, z) + 1;
        if (force_surface) self.deps.worlds.get(player.world).?.spawn_y = y;
        self.deps.players.teleport(slot, player.world, .{
            .x = @as(f64, @floatFromInt(x)) + 0.5,
            .y = @floatFromInt(y),
            .z = @as(f64, @floatFromInt(z)) + 0.5,
        }, player.rotation);
        return true;
    }

    fn placeAboveWorld(self: *PlayJoin, slot: u16) void {
        const player = &self.deps.players.records[slot];
        const x = geometry.blockCoord(player.position.x);
        const z = geometry.blockCoord(player.position.z);
        self.deps.players.teleport(slot, player.world, .{
            .x = @as(f64, @floatFromInt(x)) + 0.5,
            .y = @floatFromInt(@as(i32, lightning_rod.blocks.world_top_y) + 1),
            .z = @as(f64, @floatFromInt(z)) + 0.5,
        }, player.rotation);
    }

    fn bootstrap(self: *PlayJoin, slot: u16) void {
        const player = &self.deps.players.records[slot];
        if (player.state != .play) return;
        self.deps.output.bootstrap(slot, .play_login);
        self.deps.output.brand(slot);
        self.deps.output.bootstrap(slot, .abilities);
        self.deps.output.emitPlayerInventory(slot);
        self.deps.output.bootstrap(slot, .held_item);
        self.deps.output.bootstrap(slot, .combat_attributes);
        self.deps.output.emitPlayerHealth(slot);
        self.deps.output.bootstrap(slot, .view_center);
        self.deps.output.bootstrap(slot, .spawn_position);
        self.deps.output.bootstrap(slot, .start_waiting_for_chunks);
        self.deps.output.emitPlayerCorrection(slot);
    }
};

fn playerChunk(player: *const players.CorePlayer) geometry.ChunkPos {
    return geometry.chunkForBlock(.{
        .x = geometry.blockCoord(player.position.x),
        .y = 0,
        .z = geometry.blockCoord(player.position.z),
    });
}

fn playerCollides(blocks: *lightning_rod.blocks.Blocks, player: *const players.CorePlayer) bool {
    return lightning_rod.block_queries.livingBoxCollides(
        blocks,
        player.world,
        lightning_rod.collision.entityBox(
            player.position.x,
            player.position.y,
            player.position.z,
            0.6,
            1.8,
        ),
    );
}

pub const PlayJoinMessage = struct {
    pub const id = "minecraft:play_join_message";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        events: *lifecycle.Events,
        players: *players.Players,
        output: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayJoinMessage {
        const self = try allocator.create(PlayJoinMessage);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PlayJoinMessage, _: std.mem.Allocator) void {
        for (self.deps.events.play_started) |start| {
            if (start.reason != .joined) continue;
            const player = &self.deps.players.records[start.slot];
            if (player.state != .play) continue;
            for (self.deps.players.activeSlots()) |target| {
                if (target != start.slot) self.deps.output.system(target, "{s} joined the game", .{player.name_slice()});
            }
        }
    }
};

pub const PlayJoinProjection = struct {
    pub const id = "minecraft:play_join_projection";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        events: *lifecycle.Events,
        players: *players.Players,
        living: *entities.LivingEntities,
        items: *entities.ItemEntities,
        output: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayJoinProjection {
        const self = try allocator.create(PlayJoinProjection);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PlayJoinProjection, _: std.mem.Allocator) void {
        for (self.deps.events.play_started) |start| {
            self.projectForStartedPlayer(start.slot);
            if (start.project_to_observers) self.projectNewPlayerForObservers(start.slot);
        }
    }

    fn projectForStartedPlayer(self: *PlayJoinProjection, target: u16) void {
        const target_player = &self.deps.players.records[target];
        if (target_player.state != .play) return;
        for (self.deps.players.activeSlots()) |subject| {
            const player = &self.deps.players.records[subject];
            if (player.state != .play) continue;
            self.deps.output.tabAdd(target, subject);
            if (subject != target and player.world.eql(target_player.world))
                self.deps.output.playerSpawn(target, subject);
        }
        const store = &self.deps.living.entities;
        for (store.active_indices[0..store.active_count]) |index| {
            if (!store.worlds[index].eql(target_player.world)) continue;
            self.deps.output.livingSpawn(target, index);
        }
        for (store.active_indices[0..store.active_count]) |index| {
            if (!store.worlds[index].eql(target_player.world)) continue;
            const rider = lightning_rod.living_entities.Handle{ .index = index, .generation = store.generations[index] };
            const vehicle = store.vehicleFor(rider) orelse continue;
            if (!store.isAlive(vehicle) or !store.worlds[vehicle.index].eql(target_player.world)) continue;
            self.deps.output.livingPassengersFor(target, vehicle.index, index);
        }
        const items = self.deps.items;
        for (items.active_indices[0..items.active_count]) |index| {
            if (!items.worlds[index].eql(target_player.world)) continue;
            self.deps.output.itemSpawnFor(target, index);
        }
    }

    fn projectNewPlayerForObservers(self: *PlayJoinProjection, subject: u16) void {
        const player = &self.deps.players.records[subject];
        if (player.state != .play) return;
        for (self.deps.players.activeSlots()) |target| {
            if (target == subject) continue;
            const observer = &self.deps.players.records[target];
            if (observer.state != .play) continue;
            self.deps.output.tabAdd(target, subject);
            if (observer.world.eql(player.world)) self.deps.output.playerSpawn(target, subject);
        }
    }
};

pub const PlayDisconnectMessage = struct {
    pub const id = "minecraft:play_disconnect_message";
    pub const Configuration = struct {};
    pub const Dependencies = struct { events: *lifecycle.Events, players: *players.Players, output: *Packets };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayDisconnectMessage {
        const self = try allocator.create(PlayDisconnectMessage);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PlayDisconnectMessage, _: std.mem.Allocator) void {
        for (self.deps.events.left.values) |left| {
            for (self.deps.players.activeSlots()) |target|
                self.deps.output.system(target, "{s} left the game", .{left.player.nameSlice()});
        }
    }
};

pub const PlayDisconnectProjection = struct {
    pub const id = "minecraft:play_disconnect_projection";
    pub const Configuration = struct {};
    pub const Dependencies = struct { events: *lifecycle.Events, players: *players.Players, output: *Packets };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayDisconnectProjection {
        const self = try allocator.create(PlayDisconnectProjection);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PlayDisconnectProjection, _: std.mem.Allocator) void {
        for (self.deps.events.left.values) |left| self.project(left);
    }

    fn project(self: *PlayDisconnectProjection, left: lifecycle.PlayerLeft) void {
        for (self.deps.players.activeSlots()) |target| {
            self.deps.output.tabRemove(target, left.player.uuid);
            if (self.deps.players.records[target].world.eql(left.player.world))
                self.deps.output.entityDestroyFor(target, left.player.entity_id);
        }
    }
};

test "join messages exclude reconfiguration" {
    try std.testing.expect(lifecycle.PlayStartReason.joined != .reconfigured);
}

test "only a real join is projected to existing observers" {
    try std.testing.expect(lifecycle.PlayStartReason.joined == .joined);
    try std.testing.expect(lifecycle.PlayStartReason.reconfigured != .joined);
}

test "replacement reconfiguration projects each later player to earlier observers" {
    const first = lifecycle.PlayStarted{ .slot = 1, .connection = .{ .index = 1, .generation = 1 }, .reason = .reconfigured, .project_to_observers = true };
    const same_core = lifecycle.PlayStarted{ .slot = 1, .connection = .{ .index = 1, .generation = 1 }, .reason = .reconfigured };
    try std.testing.expect(first.project_to_observers);
    try std.testing.expect(!same_core.project_to_observers);
}
