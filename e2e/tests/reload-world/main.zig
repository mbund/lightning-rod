const records = @import("records");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");
const e2e = @import("e2e");

const render_distance = 32;
const player_names = [_][]const u8{ "alice", "bob" };
const bob_initial_x = 8.5;
const bob_resumed_x = 12.5;
const bob_resumed_health = 14;
const progress_ticks = 10;

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{lightning_rod.plugin.configured(vanilla.Players, .{ .render_distance = render_distance })}),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

const Probe = struct {
    pub const id = "e2e:reload_world";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *vanilla.Players,
        streaming: *vanilla.Streaming,
        chunks: *vanilla.Chunks,
        reload: *vanilla.Reload,
        control: *e2e.Control,
        storage: lightning_rod.storage.Space,
        metrics: *lightning_rod.metrics.Registry,
    };
    const Phase = enum { loading, reloading, resumed, complete };
    const blocks = [_][]const u8{ "minecraft:gold_block", "minecraft:diamond_block" };
    const saved_bytes = player_names.len * @sizeOf(u128);

    deps: Dependencies,
    phase: Phase = .loading,
    positioned: bool = false,
    ready: u2 = 0,
    uuids: [player_names.len]u128 = @splat(0),
    ticks: u64 = 0,
    configuring_ticks: u64 = 0,
    first_players: lightning_rod.metrics.Gauge,
    presence_ticks: lightning_rod.metrics.Counter,
    slow_ticks: lightning_rod.metrics.Counter,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{
            .deps = deps,
            .first_players = try deps.metrics.gauge(.{ .name = "e2e.reload.first_resumed_players", .description = "Players present on the first resumed tick" }),
            .presence_ticks = try deps.metrics.counter(.{ .name = "e2e.reload.presence_ticks", .description = "Resumed ticks with both original players present" }),
            .slow_ticks = try deps.metrics.counter(.{ .name = "e2e.reload.slow_configuration_ticks", .description = "Ticks with the fast client playing and the slow player still configuring" }),
        };
        var saved: [saved_bytes]u8 = undefined;
        if (try records.Value.init(deps.storage).read(&saved)) |length| {
            if (length != saved.len) return error.InvalidReloadPlayers;
            for (&self.uuids, 0..) |*uuid, index| uuid.* = std.mem.readInt(u128, saved[index * @sizeOf(u128) ..][0..@sizeOf(u128)], .little);
            if (self.uuids[0] == 0 or self.uuids[1] == 0 or self.uuids[0] == self.uuids[1]) return error.InvalidReloadPlayers;
            self.phase = .resumed;
        } else {
            for (blocks, 0..) |block, index| try deps.chunks.setBlock(deps.players.spawn_world, .{ .x = 3 + @as(i32, @intCast(index)), .y = 65, .z = 3 }, @intCast(protocols.registry.blockStateId(block).?));
        }
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "terrain_ready")) return .unhandled;
        const player = &self.deps.players.records[handle.index];
        if (player.handle == null or !std.meta.eql(player.handle.?, handle) or player.stage != .ready) return error.ReloadPlayerNotReady;
        const name = player.name[0..player.name_len];
        const index: u1 = if (std.mem.eql(u8, name, player_names[0])) 0 else if (std.mem.eql(u8, name, player_names[1])) 1 else return error.UnexpectedReloadPlayer;
        const visibility = self.deps.streaming.snapshotVisibility();
        const center = visibility.viewCenter(handle.index);
        for (0..2 * render_distance + 1) |z| for (0..2 * render_distance + 1) |x| {
            if (!visibility.visible(handle.index, player, player.world, center.x + @as(i32, @intCast(x)) - render_distance, center.z + @as(i32, @intCast(z)) - render_distance)) return error.ReloadTerrainIncomplete;
        };
        if (self.ready & (@as(u2, 1) << index) != 0) return error.DuplicateReloadReadiness;
        self.ready |= @as(u2, 1) << index;
        if (self.phase == .loading) {
            self.uuids[index] = player.uuid;
            if (self.ready == std.math.maxInt(u2)) {
                self.phase = .reloading;
                try self.deps.reload.stage(id);
            }
        } else if (self.phase != .resumed) return error.UnexpectedReloadReadiness;
        return .handled;
    }

    pub fn checkpoint(self: *Probe, space: lightning_rod.storage.Space) !void {
        if (self.phase == .loading) return;
        var saved: [saved_bytes]u8 = undefined;
        for (self.uuids, 0..) |uuid, index| std.mem.writeInt(u128, saved[index * @sizeOf(u128) ..][0..@sizeOf(u128)], uuid, .little);
        try records.Value.init(space).write(&saved);
    }

    pub fn tick(self: *Probe) !void {
        if (self.phase == .complete) return;
        var present: [player_names.len]?*vanilla.Players.Player = @splat(null);
        var count: usize = 0;
        for (self.deps.players.records) |*player| {
            if (!player.inWorld()) continue;
            count += 1;
            for (player_names, 0..) |name, index| if (std.mem.eql(u8, player.name[0..player.name_len], name)) {
                if (present[index] != null) return error.DuplicateReloadPlayer;
                present[index] = player;
            };
        }
        if (self.phase == .loading) {
            if (!self.positioned) if (present[1]) |bob| {
                if (bob.stage == .ready) {
                    try self.deps.players.teleport(bob, bob.world, .{ .x = bob_initial_x, .y = 65, .z = 0.5 }, .{ .yaw = 0, .pitch = 0 });
                    self.positioned = true;
                }
            };
            return;
        }
        if (self.phase == .reloading) return;
        if (self.ticks == 0) self.first_players.set(count);
        if (count != player_names.len) return error.ReloadLostPlayer;
        for (present, self.uuids) |maybe_player, uuid| {
            const player = maybe_player orelse return error.ReloadLostPlayer;
            if (player.uuid != uuid) return error.ReloadReplacedPlayer;
        }
        const alice = present[0].?;
        const bob = present[1].?;
        if (self.ticks == 0) {
            if (alice.position.x != 0.5 or bob.position.x != bob_initial_x or alice.world != bob.world) return error.ReloadLostPlayerState;
            for (blocks, 0..) |block, index| {
                if (try self.deps.chunks.getBlock(alice.world, .{ .x = 3 + @as(i32, @intCast(index)), .y = 65, .z = 3 }) != protocols.registry.blockStateId(block).?) return error.ReloadLostWorld;
            }
            bob.health = bob_resumed_health;
            try self.deps.players.teleport(bob, bob.world, .{ .x = bob_resumed_x, .y = 65, .z = 0.5 }, .{ .yaw = 0, .pitch = 0 });
        }
        if (bob.health != bob_resumed_health or bob.position.x != bob_resumed_x) return error.ReloadRestoredStalePlayer;
        self.ticks += 1;
        self.presence_ticks.add(1);
        if (alice.stage == .ready and bob.configuring) {
            self.configuring_ticks += 1;
            self.slow_ticks.add(1);
            if (self.configuring_ticks == progress_ticks) try self.deps.control.send(alice.handle.?, "simulation_progressed");
        }
        if (self.phase == .resumed and self.ready == std.math.maxInt(u2)) {
            if (self.configuring_ticks < progress_ticks) return error.ReloadWaitedForSlowClient;
            const request = self.deps.reload.latest() orelse return error.ReloadUnavailable;
            if (request.result != .succeeded) return error.ReloadDidNotSucceed;
            var buffer: [128]u8 = undefined;
            try self.deps.control.broadcast(try std.fmt.bufPrint(&buffer, "verified {d} {d}", .{ request.elapsed_ms, self.configuring_ticks }));
            self.phase = .complete;
        }
    }
};
