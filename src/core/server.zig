const composition = @import("composition.zig");
const core_exchange = @import("../core_exchange.zig");
const exchange = @import("../transport_exchange.zig");
const lifecycle = @import("../player_lifecycle.zig");
const packet_writer = @import("../packet_writer.zig");
const persistence = @import("../persistence.zig");
const profiler = @import("../plugin_profiler.zig");
const inputs = @import("../world/inputs.zig");
const players = @import("../world/players.zig");
const random = @import("../world/random.zig");
const contracts = @import("../runtime/contracts.zig");
const session_driver = @import("../sessions/driver.zig");
const session_api = @import("../session_api.zig");
const std = @import("std");

const Attachment = struct {
    connection: exchange.Connection,
    protocol: i32,
};

const BridgeStorage = struct {
    attachments: []?Attachment,
    connection_slots: []?u16,
    packet_views: []core_exchange.PacketView,
    joined: []lifecycle.PlayerJoined,
    left: []lifecycle.PlayerLeft,
    play_started: []lifecycle.PlayStarted,
};

fn allocateBridgeStorage(
    allocator: std.mem.Allocator,
    player_count: usize,
    input_capacity: usize,
) !BridgeStorage {
    const attachments = try allocator.alloc(?Attachment, player_count);
    errdefer allocator.free(attachments);
    const connection_slots = try allocator.alloc(?u16, player_count);
    errdefer allocator.free(connection_slots);
    const packet_views = try allocator.alloc(core_exchange.PacketView, input_capacity);
    errdefer allocator.free(packet_views);
    const joined = try allocator.alloc(lifecycle.PlayerJoined, player_count);
    errdefer allocator.free(joined);
    const left = try allocator.alloc(lifecycle.PlayerLeft, player_count);
    errdefer allocator.free(left);
    const play_started = try allocator.alloc(lifecycle.PlayStarted, player_count);
    @memset(attachments, null);
    @memset(connection_slots, null);
    return .{
        .attachments = attachments,
        .connection_slots = connection_slots,
        .packet_views = packet_views,
        .joined = joined,
        .left = left,
        .play_started = play_started,
    };
}

const Boundary = struct {
    attachments: []?Attachment,
    connection_slots: []?u16,

    pub fn attach(self: *Boundary, slot: u16, value: exchange.AttachPlayer) bool {
        if (slot >= self.attachments.len or self.attachments[slot] != null or value.connection.index >= self.connection_slots.len)
            return false;
        if (self.connection_slots[value.connection.index] != null) return false;
        self.attachments[slot] = .{ .connection = value.connection, .protocol = value.protocol };
        self.connection_slots[value.connection.index] = slot;
        return true;
    }

    pub fn player(self: *const Boundary, handle: exchange.Connection) ?u16 {
        if (handle.index >= self.connection_slots.len) return null;
        const slot = self.connection_slots[handle.index] orelse return null;
        const attachment = self.attachments[slot] orelse return null;
        return if (attachment.connection.eql(handle)) slot else null;
    }

    pub fn connection(self: *const Boundary, slot: u16) ?exchange.Connection {
        if (slot >= self.attachments.len) return null;
        return if (self.attachments[slot]) |value| value.connection else null;
    }

    pub fn detach(self: *Boundary, handle: exchange.Connection) ?u16 {
        const slot = self.player(handle) orelse return null;
        self.attachments[slot] = null;
        self.connection_slots[handle.index] = null;
        return slot;
    }
};

pub fn Server(comptime Selections: type) type {
    const Composition = composition.Composition(Selections);

    return struct {
        const Self = @This();

        composition: *Composition,
        player_store: *players.Players,
        rng: *random.Random,
        events: *lifecycle.Events,
        packets: *packet_writer.Packets,
        boundary: Boundary,
        packet_views: []core_exchange.PacketView,
        packet_view_count: usize = 0,
        joined: []lifecycle.PlayerJoined,
        left: []lifecycle.PlayerLeft,
        play_started: []lifecycle.PlayStarted,
        joined_count: usize = 0,
        left_count: usize = 0,
        play_started_count: usize = 0,
        input: ?exchange.CoreInput = null,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            selections: Selections,
            persistence_interface: persistence.Interface,
            configuration: composition.Configuration,
            counter: ?profiler.Counter,
            environment: anytype,
        ) !*Self {
            const value = try Composition.init(
                allocator,
                io,
                selections,
                persistence_interface,
                configuration,
                counter,
                environment,
            );
            const self = initBridge(value.generation.allocator(), value) catch |err| {
                if (@as(anyerror, err) == error.OutOfMemory)
                    return error.ConfiguredMemoryMaximumExceeded;
                return err;
            };
            value.finishInitialization();
            return self;
        }

        fn initBridge(allocator: std.mem.Allocator, value: *Composition) !*Self {
            const self = try allocator.create(Self);
            const player_store = value.get(players.Players);
            const packets = value.get(packet_writer.Packets);
            const storage = try allocateBridgeStorage(
                allocator,
                player_store.records.len,
                packets.input.records.len,
            );
            self.* = .{
                .composition = value,
                .player_store = player_store,
                .rng = value.get(random.Random),
                .events = value.get(lifecycle.Events),
                .packets = packets,
                .boundary = .{
                    .attachments = storage.attachments,
                    .connection_slots = storage.connection_slots,
                },
                .packet_views = storage.packet_views,
                .joined = storage.joined,
                .left = storage.left,
                .play_started = storage.play_started,
            };
            return self;
        }

        pub inline fn get(self: *Self, comptime Plugin: type) *Plugin {
            return self.composition.get(Plugin);
        }

        pub fn memory(self: *const Self) composition.Memory {
            return self.composition.memory();
        }

        pub fn runtime(self: *Self) contracts.Core {
            return .{ .context = self, .vtable = &core_vtable, .readiness = self.composition.readiness() };
        }

        pub fn sessionsBoundary(self: *Self) session_driver.CoreBoundary {
            return .{ .context = self, .vtable = &session_vtable };
        }

        pub fn bindPacketRuntime(self: *Self, value: session_api.Runtime) void {
            self.packets.bindRuntime(value);
        }

        fn publishInput(raw: *anyopaque, input: exchange.CoreInput) bool {
            const self = from(raw);
            if (self.input != null) return false;
            self.input = input;
            return true;
        }

        fn releaseInput(raw: *anyopaque) void {
            const self = from(raw);
            std.debug.assert(self.input != null);
            self.clearPacketViews();
            self.input = null;
        }

        fn service(raw: *anyopaque) contracts.Outcome {
            const self = from(raw);
            const input = self.input orelse return .failed;
            self.beginEvents();
            if (!self.attachAll(input.attachments)) return .failed;
            self.detachAll(input.detachments);
            if (!self.setPacketViews(input.packet_views, input.packet_claimed)) return .failed;
            self.publishEvents();
            return .ok;
        }

        fn tick(raw: *anyopaque) contracts.Outcome {
            const self = from(raw);
            defer self.clearPacketViews();
            if (self.composition.tick() != .ok) return .failed;
            if (self.packets.failure() != null) return .failed;
            return .ok;
        }

        fn checkpoint(raw: *anyopaque) contracts.CheckpointCapture {
            return from(raw).composition.captureCheckpoint();
        }

        fn checkpointProgress(raw: *anyopaque) contracts.Progress {
            return from(raw).composition.checkpointProgress();
        }

        fn beginClose(raw: *anyopaque, deadline_ns: i128) contracts.Outcome {
            return from(raw).composition.beginClose(deadline_ns);
        }

        fn closeProgress(raw: *anyopaque) contracts.Progress {
            return from(raw).composition.closeProgress();
        }

        fn takeControl(raw: *anyopaque) ?contracts.ControlRequest {
            const self = from(raw);
            const slot = self.packets.takeReloadRequest() orelse return null;
            return .{ .reload = slot };
        }

        fn controlResult(raw: *anyopaque, request: contracts.ControlRequest, accepted: bool) void {
            const self = from(raw);
            switch (request) {
                .reload => |slot| if (!accepted) self.packets.system(slot, "Reload is unavailable on this server host", .{}),
            }
        }

        fn beginEvents(self: *Self) void {
            self.joined_count = 0;
            self.left_count = 0;
            self.play_started_count = 0;
        }

        fn attachAll(self: *Self, values: []const exchange.AttachPlayer) bool {
            for (values) |value| if (!self.attach(value)) return false;
            return true;
        }

        fn attach(self: *Self, value: exchange.AttachPlayer) bool {
            if (value.reconfiguring) return self.reattach(value);
            const slot = self.freeSlot() orelse return false;
            self.player_store.beginConnection(self.rng, slot);
            const name = value.name[0..value.name_len];
            const disposition = self.player_store.login(self.rng, slot, name, value.uuid) catch {
                self.player_store.discardConnection(slot);
                return false;
            };
            self.player_store.transition(slot, .configuration);
            self.player_store.transition(slot, .play);
            if (!self.boundary.attach(slot, value)) return false;
            self.packets.setPlayerProtocol(slot, value.protocol);
            std.log.info("event=core_player_attached slot={d} connection={d}:{d} protocol={d}", .{ slot, value.connection.index, value.connection.generation, value.protocol });
            return self.recordStart(slot, value.connection, .joined, disposition == .new_player, true, true);
        }

        fn reattach(self: *Self, value: exchange.AttachPlayer) bool {
            if (self.boundary.player(value.connection)) |slot| {
                if (self.player_store.records[slot].state != .play) return false;
                return self.recordStart(slot, value.connection, .reconfigured, false, false, false);
            }
            return self.restoreReconfigured(value);
        }

        fn restoreReconfigured(self: *Self, value: exchange.AttachPlayer) bool {
            const slot = self.freeSlot() orelse return false;
            const name = value.name[0..value.name_len];
            if (!self.player_store.hasSaved(value.uuid, name)) return false;
            self.player_store.beginConnection(self.rng, slot);
            const disposition = self.player_store.login(self.rng, slot, name, value.uuid) catch {
                self.player_store.discardConnection(slot);
                return false;
            };
            if (disposition != .restored_player) {
                self.player_store.discardConnection(slot);
                return false;
            }
            self.player_store.transition(slot, .configuration);
            self.player_store.transition(slot, .play);
            if (!self.boundary.attach(slot, value)) {
                self.player_store.discardConnection(slot);
                return false;
            }
            self.packets.setPlayerProtocol(slot, value.protocol);
            return self.recordStart(slot, value.connection, .reconfigured, false, false, true);
        }

        fn recordStart(
            self: *Self,
            slot: u16,
            connection: exchange.Connection,
            reason: lifecycle.PlayStartReason,
            new_player: bool,
            joined: bool,
            project_to_observers: bool,
        ) bool {
            self.player_store.records[slot].client_loaded = false;
            self.player_store.records[slot].pending_teleport_id = 0;
            if (self.play_started_count == self.play_started.len) return false;
            self.play_started[self.play_started_count] = .{
                .slot = slot,
                .connection = connection,
                .reason = reason,
                .new_player = new_player,
                .project_to_observers = project_to_observers,
            };
            self.play_started_count += 1;
            if (!joined) return true;
            if (self.joined_count == self.joined.len) return false;
            self.joined[self.joined_count] = .{ .slot = slot, .connection = connection };
            self.joined_count += 1;
            return true;
        }

        fn freeSlot(self: *const Self) ?u16 {
            for (self.boundary.attachments, 0..) |connection, index| {
                if (connection == null and self.player_store.records[index].state == .free)
                    return @intCast(index);
            }
            return null;
        }

        fn detachAll(self: *Self, values: []const exchange.DetachPlayer) void {
            for (values) |value| self.detach(value);
        }

        fn detach(self: *Self, value: exchange.DetachPlayer) void {
            const slot = self.boundary.detach(value.connection) orelse return;
            if (self.left_count == self.left.len) @panic("player lifecycle detach capacity exhausted");
            self.left[self.left_count] = .{
                .slot = slot,
                .connection = value.connection,
                .reason = value.reason,
                .player = snapshot(
                    self.player_store.records[slot],
                    self.packets.deps.inputs.blockDigIntent(slot),
                ),
            };
            self.left_count += 1;
            self.packets.clearPlayerProtocol(slot);
        }

        fn setPacketViews(self: *Self, values: []const core_exchange.PacketView, claimed: []bool) bool {
            if (values.len > self.packet_views.len or claimed.len != values.len) return false;
            for (values, 0..) |value, index| {
                const slot = self.boundary.player(value.connection) orelse return false;
                self.packet_views[index] = value;
                self.packet_views[index].player = slot;
                self.packet_views[index].ticket = @intCast(index);
            }
            self.packet_view_count = values.len;
            self.packets.setPacketViews(self.packet_views[0..self.packet_view_count], claimed);
            return true;
        }

        fn clearPacketViews(self: *Self) void {
            self.packet_view_count = 0;
            self.packets.clearPacketViews();
        }

        fn publishEvents(self: *Self) void {
            self.events.begin(
                .{ .values = self.joined[0..self.joined_count] },
                .{ .values = self.left[0..self.left_count] },
                self.play_started[0..self.play_started_count],
            );
        }

        fn from(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }

        fn playerSession(raw: *anyopaque, slot: u16) ?players.Session {
            return from(raw).player_store.session(slot);
        }

        fn connectionForPlayer(raw: *anyopaque, value: players.Session) ?exchange.Connection {
            const self = from(raw);
            if (!self.player_store.validSession(value)) return null;
            return self.boundary.connection(value.slot);
        }

        fn packetViews(raw: *const anyopaque) []const core_exchange.PacketView {
            const self: *const Self = @ptrCast(@alignCast(raw));
            return self.packets.packetViews();
        }

        fn claimPacket(raw: *anyopaque, value: core_exchange.PacketView) session_api.Claim {
            return from(raw).packets.claimPacket(value);
        }

        const session_vtable: session_driver.CoreBoundary.VTable = .{
            .publish_input = publishInput,
            .release_input = releaseInput,
            .player_session = playerSession,
            .connection_for_player = connectionForPlayer,
            .packet_views = packetViews,
            .claim_packet = claimPacket,
        };
        const core_vtable: contracts.Core.VTable = .{
            .service = service,
            .tick = tick,
            .capture_checkpoint = checkpoint,
            .checkpoint_progress = checkpointProgress,
            .begin_close = beginClose,
            .close_progress = closeProgress,
            .take_control = takeControl,
            .control_result = controlResult,
        };
    };
}

fn snapshot(player: players.CorePlayer, dig: ?inputs.BlockDigIntent) lifecycle.DetachedPlayer {
    var result: lifecycle.DetachedPlayer = .{
        .world = player.world,
        .entity_id = player.entity_id,
        .uuid = player.uuid,
        .name_len = @intCast(player.name_len),
        .dig_position = if (dig) |value| value.pos else null,
    };
    @memcpy(result.name[0..player.name_len], player.name_slice());
    return result;
}

test "bridge startup fails when the configured reservation is one byte short" {
    const testing = std.testing;
    var bytes: [16 * 1024]u8 = undefined;
    var full = std.heap.FixedBufferAllocator.init(&bytes);
    _ = try allocateBridgeStorage(full.allocator(), 17, 29);
    const used = full.end_index;
    try testing.expect(used != 0);

    var exact = std.heap.FixedBufferAllocator.init(bytes[0..used]);
    _ = try allocateBridgeStorage(exact.allocator(), 17, 29);
    try testing.expectEqual(used, exact.end_index);

    var limited = std.heap.FixedBufferAllocator.init(bytes[0 .. used - 1]);
    try testing.expectError(
        error.OutOfMemory,
        allocateBridgeStorage(limited.allocator(), 17, 29),
    );
}

test "departure snapshots outlive the recycled player slot" {
    var player = players.CorePlayer{ .uuid = 9, .entity_id = 3, .name_len = 4 };
    @memcpy(player.name[0..4], "test");
    const departed = snapshot(player, null);
    player = .{};
    try std.testing.expectEqual(@as(u128, 9), departed.uuid);
    try std.testing.expectEqualStrings("test", departed.nameSlice());
}

test "connection mapping attaches once and frees the exact player slot" {
    var attachments = [_]?Attachment{ null, null };
    var connection_slots = [_]?u16{ null, null, null, null };
    var boundary = Boundary{
        .packets = undefined,
        .players = undefined,
        .attachments = &attachments,
        .connection_slots = &connection_slots,
    };
    const first = exchange.Connection{ .index = 3, .generation = 7 };
    const attached = exchange.AttachPlayer{
        .connection = first,
        .protocol = 772,
        .uuid = 9,
        .name = @splat(0),
        .name_len = 0,
        .reconfiguring = false,
    };
    try std.testing.expect(boundary.attach(1, attached));
    try std.testing.expect(!boundary.attach(1, attached));
    try std.testing.expectEqual(@as(?u16, 1), boundary.player(first));
    try std.testing.expectEqual(@as(?u16, 1), boundary.detach(first));
    try std.testing.expectEqual(@as(?u16, null), boundary.player(first));
    try std.testing.expect(boundary.attach(1, .{ .connection = .{ .index = 3, .generation = 8 }, .protocol = 772, .uuid = 9, .name = @splat(0), .name_len = 0, .reconfiguring = false }));
}
