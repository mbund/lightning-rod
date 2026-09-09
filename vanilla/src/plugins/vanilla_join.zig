const lightning_rod = @import("lightning_rod");
const std = @import("std");

const entities = lightning_rod.entities;
const geometry = lightning_rod.geometry;
const lifecycle = lightning_rod.player_lifecycle;
const players = lightning_rod.players;
const Packets = lightning_rod.Packets;
const TabList = @import("vanilla_tab_list.zig").TabList;

pub const PlayJoin = struct {
    pub const id = "minecraft:play_join";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        blocks: *lightning_rod.blocks.Blocks,
        events: *lifecycle.Events,
        materialization: *@import("vanilla_persistence.zig").Materializer,
        players: *players.Players,
        output: *Packets,
        worlds: *lightning_rod.worlds.Worlds,
    };

    const Placement = enum(u8) { none, collision, spawn_surface, bootstrap };
    const BootstrapStep = enum(u8) {
        play_login,
        brand,
        abilities,
        inventory,
        held_item,
        combat_attributes,
        health,
        view_center,
        spawn_position,
        start_waiting_for_chunks,
        correction,
        complete,
    };

    deps: Dependencies,
    pending: []Placement,
    ready: []bool,
    bootstrap_steps: []BootstrapStep,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayJoin {
        const self = try allocator.create(PlayJoin);
        self.* = .{
            .deps = deps,
            .pending = try allocator.alloc(Placement, deps.players.records.len),
            .ready = try allocator.alloc(bool, deps.players.records.len),
            .bootstrap_steps = try allocator.alloc(BootstrapStep, deps.players.records.len),
        };
        @memset(self.pending, .none);
        @memset(self.ready, false);
        @memset(self.bootstrap_steps, .play_login);
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
                self.bootstrap_steps[slot] = .play_login;
                continue;
            }
            if (placement != .bootstrap) {
                const chunk = playerChunk(player);
                if (self.deps.materialization.requestRender(player.world, chunk) != .resident) continue;
                _ = self.place(@intCast(slot), placement == .spawn_surface);
                self.pending[slot] = .bootstrap;
            }
            if (self.bootstrap(@intCast(slot))) self.pending[slot] = .none;
        }
    }

    fn start(self: *PlayJoin, value: lifecycle.PlayStarted) void {
        self.ready[value.slot] = false;
        self.bootstrap_steps[value.slot] = .play_login;
        const player = &self.deps.players.records[value.slot];
        const placement: Placement = if (value.new_player) .spawn_surface else .collision;
        if (self.deps.materialization.requestRender(player.world, playerChunk(player)) == .resident) {
            _ = self.place(value.slot, placement == .spawn_surface);
            if (!self.bootstrap(value.slot)) self.pending[value.slot] = .bootstrap;
        } else {
            self.pending[value.slot] = placement;
        }
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

    fn bootstrap(self: *PlayJoin, slot: u16) bool {
        const player = &self.deps.players.records[slot];
        if (player.state != .play) return false;
        while (true) {
            const accepted = switch (self.bootstrap_steps[slot]) {
                .play_login => self.deps.output.bootstrap(slot, .play_login),
                .brand => self.deps.output.brand(slot),
                .abilities => self.deps.output.bootstrap(slot, .abilities),
                .inventory => self.deps.output.emitPlayerInventory(slot),
                .held_item => self.deps.output.bootstrap(slot, .held_item),
                .combat_attributes => self.deps.output.bootstrap(slot, .combat_attributes),
                .health => self.deps.output.emitPlayerHealth(slot),
                .view_center => self.deps.output.bootstrap(slot, .view_center),
                .spawn_position => self.deps.output.bootstrap(slot, .spawn_position),
                .start_waiting_for_chunks => self.deps.output.bootstrap(slot, .start_waiting_for_chunks),
                .correction => self.deps.output.emitPlayerCorrection(slot),
                .complete => return true,
            };
            if (!accepted) return false;
            self.bootstrap_steps[slot] = @enumFromInt(@intFromEnum(self.bootstrap_steps[slot]) + 1);
            if (self.bootstrap_steps[slot] == .complete) {
                self.ready[slot] = true;
                return true;
            }
        }
    }

    pub fn presentationReady(self: *const PlayJoin, slot: u16) bool {
        return slot < self.ready.len and self.ready[slot];
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
        join: *PlayJoin,
        players: *players.Players,
        living: *entities.LivingEntities,
        items: *entities.ItemEntities,
        output: *Packets,
        tabs: *TabList,
    };

    const Stage = enum { none, initial, observers };

    deps: Dependencies,
    pending: []Stage,
    cursors: []usize,
    observer_pending: []u64,
    project_to_observers: []bool,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayJoinProjection {
        const observer_words = std.math.divCeil(usize, deps.players.records.len, 64) catch unreachable;
        const self = try allocator.create(PlayJoinProjection);
        self.* = .{
            .deps = deps,
            .pending = try allocator.alloc(Stage, deps.players.records.len),
            .cursors = try allocator.alloc(usize, deps.players.records.len),
            .observer_pending = try allocator.alloc(u64, try std.math.mul(usize, deps.players.records.len, observer_words)),
            .project_to_observers = try allocator.alloc(bool, deps.players.records.len),
        };
        @memset(self.pending, .none);
        @memset(self.cursors, 0);
        @memset(self.observer_pending, 0);
        @memset(self.project_to_observers, false);
        return self;
    }

    pub fn tick(self: *PlayJoinProjection, _: std.mem.Allocator) void {
        for (self.deps.events.play_started) |start| {
            self.pending[start.slot] = .initial;
            self.cursors[start.slot] = 0;
            self.project_to_observers[start.slot] = start.project_to_observers;
        }
        for (self.pending, 0..) |pending, slot| {
            if (pending == .none) continue;
            const target: u16 = @intCast(slot);
            if (self.deps.players.records[target].state != .play) {
                self.pending[target] = .none;
                continue;
            }
            if (!self.deps.join.presentationReady(target)) continue;
            if (self.pending[target] == .initial) {
                const target_player = &self.deps.players.records[target];
                while (self.cursors[target] < self.deps.players.records.len) : (self.cursors[target] += 1) {
                    const subject: u16 = @intCast(self.cursors[target]);
                    const player = &self.deps.players.records[subject];
                    if (player.state != .play) continue;
                    if (!self.deps.tabs.ensure(target, player.uuid)) break;
                    if (subject != target and player.world.eql(target_player.world))
                        self.deps.output.playerSpawn(target, subject);
                }
                if (self.cursors[target] != self.deps.players.records.len) continue;
                self.projectEntities(target);
                self.pending[target] = if (self.project_to_observers[target]) .observers else .none;
                const words = std.math.divCeil(usize, self.pending.len, 64) catch unreachable;
                @memset(self.observer_pending[target * words ..][0..words], std.math.maxInt(u64));
            }
            if (self.pending[target] == .observers) {
                const player = &self.deps.players.records[target];
                const words = std.math.divCeil(usize, self.pending.len, 64) catch unreachable;
                const remaining = self.observer_pending[target * words ..][0..words];
                var waiting = false;
                for (self.deps.players.records, 0..) |*observer, observer_index| {
                    const mask = @as(u64, 1) << @intCast(observer_index % 64);
                    const word = &remaining[observer_index / 64];
                    if (word.* & mask == 0) continue;
                    const observer_slot: u16 = @intCast(observer_index);
                    if (observer_slot == target or observer.state != .play or !observer.presentation_ready) {
                        word.* &= ~mask;
                        continue;
                    }
                    if (!self.deps.tabs.ensure(observer_slot, player.uuid)) {
                        waiting = true;
                        continue;
                    }
                    if (observer.world.eql(player.world)) self.deps.output.playerSpawn(observer_slot, target);
                    word.* &= ~mask;
                }
                if (!waiting) self.pending[target] = .none;
            }
        }
    }

    fn projectEntities(self: *PlayJoinProjection, target: u16) void {
        const target_player = &self.deps.players.records[target];
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
        for (self.deps.events.left.values) |left| {
            for (self.deps.players.activeSlots()) |target| {
                if (self.deps.players.records[target].world.eql(left.player.world))
                    self.deps.output.entityDestroyFor(target, left.player.entity_id);
            }
        }
    }
};

test "join retries tab admission before player spawning without blocking other observers" {
    const sessions = lightning_rod.sessions;
    const Admission = struct {
        blocked: ?u16 = 2,
        tabs: [3]usize = @splat(0),
        entities: [3]usize = @splat(0),
        fn send(raw: *anyopaque, target: players.Session, _: sessions.PacketEncoder, class: sessions.DeliveryClass, _: sessions.DeliveryPolicy) sessions.PacketAdmission {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (class == .control) {
                if (self.blocked == target.slot) return .backpressured;
                self.tabs[target.slot] += 1;
            } else {
                std.debug.assert(self.tabs[target.slot] != 0);
                self.entities[target.slot] += 1;
            }
            return .accepted;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var records: [3]players.CorePlayer align(64) = @splat(.{});
    for (&records, 1..) |*record, id| {
        record.state = .play;
        record.presentation_ready = true;
        record.uuid = id;
        record.entity_id = @intCast(id);
    }
    var generations = [_]u64{ 1, 1, 1 };
    var player_store: players.Players = .{ .deps = undefined, .initial_world = .{ .value = 1 }, .records = &records, .session_generations = &generations };
    var admission = Admission{};
    var vtable: sessions.Runtime.VTable = undefined;
    vtable.send_one = Admission.send;
    var session_store = sessions.Sessions.init(772);
    session_store.runtime = .{ .context = &admission, .vtable = &vtable };
    var output: Packets = undefined;
    output.deps.players = &player_store;
    output.deps.sessions = &session_store;
    output.temporary = arena.allocator();
    var ready = [_]bool{ true, true, true };
    var join: PlayJoin = undefined;
    join.ready = &ready;
    var living: entities.LivingEntities = .{};
    var items: entities.ItemEntities = .{};
    var events: lifecycle.Events = undefined;
    events.play_started = &.{.{ .slot = 2, .connection = .{ .index = 2, .generation = 1 }, .reason = .joined, .project_to_observers = true }};
    const tabs = try TabList.init(arena.allocator(), .{ .events = &events, .players = &player_store, .output = &output, .join = &join }, .{});
    for (records) |record| try tabs.put(.{ .uuid = record.uuid, .name = "test", .gamemode = 0 });
    const projection = try PlayJoinProjection.init(arena.allocator(), .{ .events = &events, .join = &join, .players = &player_store, .living = &living, .items = &items, .output = &output, .tabs = tabs }, .{});
    projection.tick(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), admission.entities[2]);
    try std.testing.expectEqual(PlayJoinProjection.Stage.initial, projection.pending[2]);
    events.play_started = &.{};
    admission.blocked = 0;
    projection.tick(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), admission.tabs[2]);
    try std.testing.expectEqual(@as(usize, 4), admission.entities[2]);
    try std.testing.expectEqual(@as(usize, 1), admission.tabs[1]);
    try std.testing.expectEqual(@as(usize, 2), admission.entities[1]);
    try std.testing.expectEqual(@as(usize, 0), admission.entities[0]);
    projection.tick(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), admission.tabs[1]);
    try std.testing.expectEqual(@as(usize, 4), admission.entities[2]);
    admission.blocked = null;
    projection.tick(arena.allocator());
    try std.testing.expectEqual(PlayJoinProjection.Stage.none, projection.pending[2]);
    try std.testing.expectEqual(@as(usize, 1), admission.tabs[0]);
    try std.testing.expectEqual(@as(usize, 2), admission.entities[0]);
    projection.tick(arena.allocator());
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 3 }, &admission.tabs);
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 4 }, &admission.entities);
}

test "join retains bootstrap order through waiting and correction backpressure" {
    const sessions = lightning_rod.sessions;
    const Admission = struct {
        calls: usize = 0,
        block_call: ?usize = 4,

        fn send(raw: *anyopaque, _: players.Session, _: sessions.PacketEncoder, _: sessions.DeliveryClass, _: sessions.DeliveryPolicy) sessions.PacketAdmission {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return if (self.block_call == self.calls) .backpressured else .accepted;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const worlds = try lightning_rod.worlds.Worlds.init(arena.allocator(), .{ .initial = &.{.{
        .key = .{ .value = 1 },
        .name = "test:join",
        .dimension = .{ .index = 0 },
        .generator = @enumFromInt(0),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }}, .maximum_worlds = 1 });
    const world = worlds.find(.{ .value = 1 }).?;
    var records: [1]players.CorePlayer align(64) = .{.{ .state = .play, .world = world, .next_teleport_id = 1 }};
    var generations = [_]u64{1};
    var player_store: players.Players = .{ .deps = undefined, .initial_world = .{ .value = 1 }, .records = &records, .session_generations = &generations };
    var admission = Admission{};
    var vtable: sessions.Runtime.VTable = undefined;
    vtable.send_one = Admission.send;
    var session_store = sessions.Sessions.init(772);
    session_store.runtime = .{ .context = &admission, .vtable = &vtable };
    var output: Packets = undefined;
    output.deps.players = &player_store;
    output.deps.sessions = &session_store;
    output.deps.worlds = worlds;
    output.temporary = arena.allocator();
    output.config = .{ .brand = "test" };
    var pending = [_]PlayJoin.Placement{.bootstrap};
    var ready = [_]bool{false};
    var steps = [_]PlayJoin.BootstrapStep{.play_login};
    var join: PlayJoin = .{ .deps = undefined, .pending = &pending, .ready = &ready, .bootstrap_steps = &steps };
    join.deps.players = &player_store;
    join.deps.output = &output;

    try std.testing.expect(!join.bootstrap(0));
    try std.testing.expectEqual(@as(usize, 4), admission.calls);
    try std.testing.expectEqual(PlayJoin.BootstrapStep.inventory, steps[0]);
    try std.testing.expect(!ready[0]);
    try std.testing.expectEqual(@as(i32, 1), records[0].next_teleport_id);
    try std.testing.expectEqual(@as(i32, 0), records[0].inventory_state_id);

    admission.block_call = 11;
    try std.testing.expect(!join.bootstrap(0));
    try std.testing.expectEqual(@as(usize, 11), admission.calls);
    try std.testing.expectEqual(PlayJoin.BootstrapStep.start_waiting_for_chunks, steps[0]);
    try std.testing.expect(!ready[0]);
    try std.testing.expectEqual(@as(i32, 1), records[0].next_teleport_id);
    try std.testing.expectEqual(@as(i32, 1), records[0].inventory_state_id);

    admission.block_call = 13;
    try std.testing.expect(!join.bootstrap(0));
    try std.testing.expectEqual(@as(usize, 13), admission.calls);
    try std.testing.expectEqual(PlayJoin.BootstrapStep.correction, steps[0]);
    try std.testing.expect(!ready[0]);
    try std.testing.expectEqual(@as(i32, 1), records[0].next_teleport_id);

    admission.block_call = null;
    try std.testing.expect(join.bootstrap(0));
    try std.testing.expectEqual(@as(usize, 14), admission.calls);
    try std.testing.expectEqual(PlayJoin.BootstrapStep.complete, steps[0]);
    try std.testing.expect(ready[0]);
    try std.testing.expectEqual(@as(i32, 2), records[0].next_teleport_id);
    try std.testing.expectEqual(@as(i32, 1), records[0].pending_teleport_id);
}

test "replacement reconfiguration projects each later player to earlier observers" {
    const first = lifecycle.PlayStarted{ .slot = 1, .connection = .{ .index = 1, .generation = 1 }, .reason = .reconfigured, .project_to_observers = true };
    const same_core = lifecycle.PlayStarted{ .slot = 1, .connection = .{ .index = 1, .generation = 1 }, .reason = .reconfigured };
    try std.testing.expect(first.project_to_observers);
    try std.testing.expect(!same_core.project_to_observers);
}
