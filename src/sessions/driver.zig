const api = @import("../session_api.zig");
const core_exchange = @import("../core_exchange.zig");
const contracts = @import("../runtime/contracts.zig");
const exchange = @import("../transport_exchange.zig");
const std = @import("std");

test "egress fanout preserves sparse mixed protocols and batches never bypass egress" {
    const Player = @import("../world/players.zig").Session;
    const Fixture = struct {
        fallback: bool,
        encodes: usize = 0,
        groups: usize = 0,
        flushes: usize = 0,
        received: [6]u8 = @splat(0),
        const versions = [_]?i32{ 772, null, 772, 773, 772, 773 };

        fn protocol(_: *const anyopaque, player: Player) ?api.Protocol {
            return .{ .value = versions[player.slot] orelse return null };
        }
        fn connection(_: *anyopaque, player: Player) ?exchange.Connection {
            if (player.slot == 4) return null;
            return .{ .index = 1_000 + @as(u32, player.slot), .generation = @intCast(player.generation) };
        }
        fn encode(raw: *const anyopaque, version: api.Protocol, bytes: []u8) ?api.EncodedPacket {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.encodes += 1;
            std.mem.writeInt(i32, bytes[0..4], version.value, .little);
            return .{ .payload = bytes[0..4] };
        }
        fn stage(raw: *anyopaque, output: core_exchange.Output) api.PacketAdmission {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const slot = output.connection.index - 1_000;
            std.debug.assert(output.protocol.value == versions[slot].?);
            std.debug.assert(std.mem.readInt(i32, output.payload[0..4], .little) == versions[slot].?);
            self.received[slot] += 1;
            return .accepted;
        }
        fn stageFanout(raw: *anyopaque, targets: []const core_exchange.OutputTarget, payload: []const u8) api.PacketAdmission {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.groups += 1;
            for (targets) |target| {
                std.debug.assert(target.protocol.eql(targets[0].protocol));
                _ = stage(raw, .{ .connection = target.connection, .protocol = target.protocol, .phase = target.phase, .class = target.class, .policy = target.policy, .payload = payload });
            }
            return .accepted;
        }
        fn encodeOne(raw: *anyopaque, target: core_exchange.OutputTarget, encoder: api.PacketEncoder) api.PacketAdmission {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.fallback) return .wrong_protocol;
            var bytes: [4]u8 = undefined;
            const encoded = encoder.encode(encoder.context, target.protocol, &bytes).?;
            return stage(raw, .{ .connection = target.connection, .protocol = target.protocol, .phase = target.phase, .class = target.class, .policy = target.policy, .payload = encoded.payload });
        }
        fn encodeFanout(raw: *anyopaque, targets: []const core_exchange.OutputTarget, encoder: api.PacketEncoder) api.PacketAdmission {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.fallback) return .wrong_protocol;
            var bytes: [4]u8 = undefined;
            const encoded = encoder.encode(encoder.context, targets[0].protocol, &bytes).?;
            return stageFanout(raw, targets, encoded.payload);
        }
        fn flush(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.flushes += 1;
        }
    };
    for ([_]bool{ false, true }) |fallback| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture = Fixture{ .fallback = fallback };
        var core_vtable: CoreBoundary.VTable = undefined;
        core_vtable.player_protocol = Fixture.protocol;
        core_vtable.connection_for_player = Fixture.connection;
        var egress_vtable: core_exchange.Egress.VTable = undefined;
        egress_vtable.stage = Fixture.stage;
        egress_vtable.stage_fanout = Fixture.stageFanout;
        egress_vtable.encode = Fixture.encodeOne;
        egress_vtable.encode_fanout = Fixture.encodeFanout;
        egress_vtable.flush = Fixture.flush;
        var driver: Driver = undefined;
        driver.core = .{ .context = &fixture, .vtable = &core_vtable };
        driver.egress = .{ .context = &fixture, .vtable = &egress_vtable };
        var recipients: [6]Player = undefined;
        for (&recipients, 0..) |*player, index| player.* = .{ .slot = @intCast(index), .generation = 8 };
        const encoder = api.PacketEncoder{ .context = &fixture, .phase = .play, .maximum_payload_bytes = 4, .encode = Fixture.encode };
        const runtime = driver.packetRuntime();
        const result = try runtime.vtable.fanout(runtime.context, arena.allocator(), &recipients, encoder, .other, .reliable);
        try std.testing.expectEqual(@as(usize, 4), result.delivered.len);
        try std.testing.expectEqualSlices(Player, recipients[1..2], result.wrong_protocol);
        try std.testing.expectEqualSlices(Player, recipients[4..5], result.closed);
        try std.testing.expectEqual(@as(usize, 2), fixture.encodes);
        try std.testing.expectEqual(@as(usize, 2), fixture.groups);
        try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 1, 0, 1 }, &fixture.received);
        const items = [_]api.PacketBatchItem{
            .{ .recipient = recipients[0], .encoder = encoder },
            .{ .recipient = recipients[1], .encoder = encoder },
            .{ .recipient = recipients[4], .encoder = encoder },
        };
        const batch = try runtime.vtable.batch(runtime.context, arena.allocator(), &items, .other, .reliable);
        try std.testing.expectEqualSlices(api.PacketAdmission, &.{ .accepted, .wrong_protocol, .closed }, batch.values);
        try std.testing.expectEqual(@as(usize, 3), fixture.encodes);
        runtime.flush();
        try std.testing.expectEqual(@as(usize, 1), fixture.flushes);
    }
}

pub const Clock = struct {
    context: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now_ns: *const fn (*const anyopaque) u64,
    };

    pub inline fn nowNs(self: Clock) u64 {
        return self.vtable.now_ns(self.context);
    }
};

pub const Status = struct {
    context: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        snapshot: *const fn (*const anyopaque) api.StatusSnapshot,
    };

    pub inline fn snapshot(self: Status) api.StatusSnapshot {
        return self.vtable.snapshot(self.context);
    }
};

pub const CoreBoundary = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        drain_input: *const fn (*anyopaque) bool,
        finish_input: *const fn (*anyopaque) void,
        player_session: *const fn (*anyopaque, u16) ?@import("../world/players.zig").Session,
        player_protocol: *const fn (*const anyopaque, @import("../world/players.zig").Session) ?api.Protocol,
        connection_for_player: *const fn (*anyopaque, @import("../world/players.zig").Session) ?exchange.Connection,
        packet_views: *const fn (*const anyopaque) []const core_exchange.PacketView,
        claim_packet: *const fn (*anyopaque, core_exchange.PacketView) api.Claim,
    };
};

pub const Driver = struct {
    sessions: api.Sessions,
    transport: exchange.Transport,
    clock: Clock,
    status: Status,
    core: CoreBoundary,
    egress: ?core_exchange.Egress = null,
    ingress: ?core_exchange.Ingress = null,
    input_published: bool = false,
    output_scratch: [@import("../minecraft_session.zig").Codec.max_packet_bytes]u8 = undefined,

    pub fn init(
        sessions: api.Sessions,
        transport: exchange.Transport,
        clock: Clock,
        status: Status,
        core: CoreBoundary,
    ) Driver {
        return .{ .sessions = sessions, .transport = transport, .clock = clock, .status = status, .core = core };
    }

    pub fn runtime(self: *Driver) contracts.Sessions {
        return .{ .context = self, .vtable = &runtime_vtable, .readiness = self.sessions.readiness };
    }

    pub fn bindEgress(self: *Driver, value: core_exchange.Egress) void {
        std.debug.assert(self.egress == null);
        self.egress = value;
    }
    pub fn bindIngress(self: *Driver, value: core_exchange.Ingress) void {
        std.debug.assert(self.ingress == null);
        self.ingress = value;
    }

    pub fn packetRuntime(self: *Driver) api.Runtime {
        return .{ .context = self, .vtable = &packet_runtime_vtable };
    }

    fn from(raw: *anyopaque) *Driver {
        return @ptrCast(@alignCast(raw));
    }

    fn advance(raw: *anyopaque) contracts.Outcome {
        const self = from(raw);
        self.sessions.advance(self.transport, self.clock.nowNs(), self.status.snapshot());
        return .ok;
    }

    fn takeInput(raw: *anyopaque) contracts.Outcome {
        const self = from(raw);
        if (self.input_published) return .failed;
        const ingress = self.ingress orelse return .failed;
        const accepted = ingress.stage(self.sessions.takeInput());
        if (!accepted or !self.core.vtable.drain_input(self.core.context)) return .failed;
        self.input_published = true;
        return .ok;
    }

    fn finishInput(raw: *anyopaque) contracts.Outcome {
        const self = from(raw);
        if (!self.input_published) return .failed;
        self.core.vtable.finish_input(self.core.context);
        self.sessions.finishInput(self.transport);
        self.input_published = false;
        return .ok;
    }

    fn playerSession(raw: *anyopaque, slot: u16) ?@import("../world/players.zig").Session {
        const self = from(raw);
        return self.core.vtable.player_session(self.core.context, slot);
    }

    fn playerProtocol(raw: *const anyopaque, player: @import("../world/players.zig").Session) ?api.Protocol {
        const self: *const Driver = @ptrCast(@alignCast(raw));
        if (self.egress != null) return self.core.vtable.player_protocol(self.core.context, player);
        const connection = self.core.vtable.connection_for_player(self.core.context, player) orelse return null;
        return self.sessions.protocol(connection);
    }

    fn outputState(raw: *anyopaque, player: @import("../world/players.zig").Session) ?api.OutputState {
        const self = from(raw);
        const connection = self.core.vtable.connection_for_player(self.core.context, player) orelse return null;
        return self.sessions.outputState(self.transport, connection);
    }

    fn packetViews(raw: *const anyopaque) []const core_exchange.PacketView {
        const self: *const Driver = @ptrCast(@alignCast(raw));
        return self.core.vtable.packet_views(self.core.context);
    }

    fn claimPacket(raw: *anyopaque, packet: core_exchange.PacketView) api.Claim {
        const self = from(raw);
        return self.core.vtable.claim_packet(self.core.context, packet);
    }

    fn sendOne(raw: *anyopaque, player: @import("../world/players.zig").Session, encoder: api.PacketEncoder, class: api.DeliveryClass, policy: api.DeliveryPolicy) api.PacketAdmission {
        const self = from(raw);
        if (self.egress != null) {
            var bridge = self.packetBridge();
            const value = bridge.runtime();
            return value.vtable.send_one(value.context, player, encoder, class, policy);
        }
        const connection = self.core.vtable.connection_for_player(self.core.context, player) orelse return .closed;
        return self.sessions.sendOne(self.transport, connection, encoder, class, policy);
    }

    fn batch(raw: *anyopaque, temporary: @import("std").mem.Allocator, items: []const api.PacketBatchItem, class: api.DeliveryClass, policy: api.DeliveryPolicy) @import("std").mem.Allocator.Error!api.FanoutAdmissions {
        const self = from(raw);
        if (self.egress != null) {
            var bridge = self.packetBridge();
            const value = bridge.runtime();
            return value.vtable.batch(value.context, temporary, items, class, policy);
        }
        const wire = try temporary.alloc(api.WirePacketBatchItem, items.len);
        for (items, wire) |item, *entry| {
            entry.* = .{
                .recipient = self.core.vtable.connection_for_player(self.core.context, item.recipient) orelse
                    .{ .index = @import("std").math.maxInt(u32), .generation = 0 },
                .encoder = item.encoder,
            };
        }
        return self.sessions.batch(self.transport, wire, class, policy, temporary);
    }

    fn fanout(raw: *anyopaque, temporary: @import("std").mem.Allocator, players: []const @import("../world/players.zig").Session, encoder: api.PacketEncoder, class: api.DeliveryClass, policy: api.DeliveryPolicy) @import("std").mem.Allocator.Error!api.FanoutResult {
        const self = from(raw);
        if (self.egress != null) {
            var bridge = self.packetBridge();
            const value = bridge.runtime();
            return value.vtable.fanout(value.context, temporary, players, encoder, class, policy);
        }
        const connections = try temporary.alloc(exchange.Connection, players.len);
        for (players, connections) |player, *connection|
            connection.* = self.core.vtable.connection_for_player(self.core.context, player) orelse .{ .index = @import("std").math.maxInt(u32), .generation = 0 };
        const admissions = try self.sessions.fanout(self.transport, connections, encoder, class, policy, temporary);
        return api.fanoutResult(temporary, players, admissions.values);
    }

    fn packetBridge(self: *Driver) @import("packet_bridge.zig").Bridge {
        return @import("packet_bridge.zig").Bridge.init(self.core, self.egress.?, .{
            .context = self,
            .state = connectionOutputState,
        }, &self.output_scratch);
    }

    fn connectionOutputState(raw: *const anyopaque, connection: exchange.Connection) ?api.OutputState {
        const self: *const Driver = @ptrCast(@alignCast(raw));
        return self.sessions.outputState(self.transport, connection);
    }

    fn flush(raw: *anyopaque) void {
        const self = from(raw);
        if (self.egress) |egress| egress.flush() else self.transport.vtable.submit(self.transport.context);
    }

    fn stopAccepting(raw: *anyopaque) contracts.Outcome {
        from(raw).sessions.stopAccepting();
        return .ok;
    }

    fn stageFinalDetachments(raw: *anyopaque) contracts.Outcome {
        from(raw).sessions.stageFinalDetachments();
        return .ok;
    }

    fn shutdownProgress(raw: *anyopaque) contracts.Progress {
        return switch (from(raw).sessions.shutdownProgress()) {
            .pending => .pending,
            .complete => .complete,
        };
    }

    fn fatalDisconnect(raw: *anyopaque) contracts.Progress {
        const self = from(raw);
        return switch (self.sessions.fatalDisconnect(self.transport)) {
            .pending => .pending,
            .complete => .complete,
        };
    }

    const runtime_vtable: contracts.Sessions.VTable = .{
        .advance = advance,
        .take_input = takeInput,
        .finish_input = finishInput,
        .stop_accepting = stopAccepting,
        .stage_final_detachments = stageFinalDetachments,
        .fatal_disconnect = fatalDisconnect,
        .shutdown_progress = shutdownProgress,
    };

    const packet_runtime_vtable: api.Runtime.VTable = .{
        .player_session = playerSession,
        .player_protocol = playerProtocol,
        .output_state = outputState,
        .packet_views = packetViews,
        .claim_packet = claimPacket,
        .send_one = sendOne,
        .batch = batch,
        .fanout = fanout,
        .flush = flush,
    };
};

test "driver preserves both exchange ownership contracts" {
    const testing = @import("std").testing;
    const State = struct {
        now: u64 = 41,
        session_calls: u8 = 0,
        published_inputs: u8 = 0,
        released_inputs: u8 = 0,
    };
    const Stub = struct {
        fn state(raw: *anyopaque) *State {
            return @ptrCast(@alignCast(raw));
        }
        fn constState(raw: *const anyopaque) *const State {
            return @ptrCast(@alignCast(raw));
        }
        fn advance(raw: *anyopaque, _: exchange.Transport, now_ns: u64, status: api.StatusSnapshot) void {
            const item = state(raw);
            item.session_calls += 1;
            @import("std").debug.assert(now_ns == item.now and status.revision == 7);
        }
        fn input(raw: *anyopaque) exchange.CoreInput {
            state(raw).session_calls += 1;
            return .{ .attachments = &.{}, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} };
        }
        fn finish(raw: *anyopaque, _: exchange.Transport) void {
            state(raw).session_calls += 1;
        }
        fn protocol(_: *const anyopaque, _: exchange.Connection) ?api.Protocol {
            return .{ .value = 772 };
        }
        fn outputState(_: *const anyopaque, _: exchange.Transport, _: exchange.Connection) ?api.OutputState {
            return .{ .credit_bytes = 1, .queued_bytes = 2, .capacity_bytes = 3 };
        }
        fn sendOne(_: *anyopaque, _: exchange.Transport, _: exchange.Connection, _: api.PacketEncoder, _: api.DeliveryClass, _: api.DeliveryPolicy) api.PacketAdmission {
            return .accepted;
        }
        fn batch(raw: *anyopaque, _: exchange.Transport, recipients: []const api.WirePacketBatchItem, _: api.DeliveryClass, _: api.DeliveryPolicy, temporary: @import("std").mem.Allocator) @import("std").mem.Allocator.Error!api.FanoutAdmissions {
            state(raw).session_calls += 1;
            const values = try temporary.alloc(api.PacketAdmission, recipients.len);
            @memset(values, .accepted);
            return .{ .values = values };
        }
        fn fanout(raw: *anyopaque, _: exchange.Transport, recipients: []const exchange.Connection, _: api.PacketEncoder, _: api.DeliveryClass, _: api.DeliveryPolicy, temporary: @import("std").mem.Allocator) @import("std").mem.Allocator.Error!api.FanoutAdmissions {
            state(raw).session_calls += 1;
            const values = try temporary.alloc(api.PacketAdmission, recipients.len);
            @memset(values, .accepted);
            return .{ .values = values };
        }
        fn lifecycle(raw: *anyopaque) void {
            state(raw).session_calls += 1;
        }
        fn progress(raw: *anyopaque) api.ShutdownProgress {
            state(raw).session_calls += 1;
            return .complete;
        }
        fn fatal(raw: *anyopaque, _: exchange.Transport) api.ShutdownProgress {
            return progress(raw);
        }
        fn drain(raw: *anyopaque) bool {
            state(raw).published_inputs += 1;
            return true;
        }
        fn releaseInput(raw: *anyopaque) void {
            state(raw).released_inputs += 1;
        }
        fn ingress(_: *anyopaque, _: core_exchange.CoreInput) bool {
            return true;
        }
        fn player(_: *anyopaque, slot: u16) ?@import("../world/players.zig").Session {
            return .{ .slot = slot, .generation = 1 };
        }
        fn playerProtocol(_: *const anyopaque, _: @import("../world/players.zig").Session) ?api.Protocol {
            return .{ .value = 772 };
        }
        fn connection(_: *anyopaque, player_value: @import("../world/players.zig").Session) ?exchange.Connection {
            return .{ .index = player_value.slot, .generation = @intCast(player_value.generation) };
        }
        fn views(_: *const anyopaque) []const core_exchange.PacketView {
            return &.{};
        }
        fn claim(_: *anyopaque, _: core_exchange.PacketView) api.Claim {
            return .unavailable;
        }
        fn now(raw: *const anyopaque) u64 {
            return constState(raw).now;
        }
        fn snapshot(_: *const anyopaque) api.StatusSnapshot {
            return .{ .revision = 7, .json = "{}" };
        }
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn inputPage(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn credit(_: *anyopaque, _: exchange.Connection) usize {
            return 0;
        }
        fn metrics(_: *anyopaque, _: exchange.Connection) ?exchange.OutputMetrics {
            return null;
        }
        fn write(_: *anyopaque, _: exchange.Connection, _: []const u8) bool {
            return false;
        }
        fn releasePage(_: *anyopaque, _: exchange.Page) void {}
        fn close(_: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {}
        fn submit(_: *anyopaque) void {}
    };

    var state = State{};
    const sessions = api.Sessions{ .context = &state, .vtable = &.{
        .advance = Stub.advance,
        .take_input = Stub.input,
        .finish_input = Stub.finish,
        .protocol = Stub.protocol,
        .output_state = Stub.outputState,
        .send_one = Stub.sendOne,
        .batch = Stub.batch,
        .fanout = Stub.fanout,
        .stop_accepting = Stub.lifecycle,
        .stage_final_detachments = Stub.lifecycle,
        .fatal_disconnect = Stub.fatal,
        .shutdown_progress = Stub.progress,
    } };
    const transport = exchange.Transport{ .context = &state, .vtable = &.{
        .complete = Stub.complete,
        .input_page = Stub.inputPage,
        .output_credit = Stub.credit,
        .output_metrics = Stub.metrics,
        .write = Stub.write,
        .release_input = Stub.releasePage,
        .close = Stub.close,
        .submit = Stub.submit,
    } };
    const core = CoreBoundary{ .context = &state, .vtable = &.{
        .drain_input = Stub.drain,
        .finish_input = Stub.releaseInput,
        .player_session = Stub.player,
        .player_protocol = Stub.playerProtocol,
        .connection_for_player = Stub.connection,
        .packet_views = Stub.views,
        .claim_packet = Stub.claim,
    } };
    var driver = Driver.init(sessions, transport, .{ .context = &state, .vtable = &.{ .now_ns = Stub.now } }, .{ .context = &state, .vtable = &.{ .snapshot = Stub.snapshot } }, core);
    driver.bindIngress(.{ .context = &state, .vtable = &.{ .stage = Stub.ingress } });
    const runtime = driver.runtime();

    try testing.expectEqual(contracts.Outcome.ok, runtime.advance());
    try testing.expectEqual(contracts.Outcome.ok, runtime.takeInput());
    try testing.expectEqual(contracts.Outcome.failed, runtime.takeInput());
    try testing.expectEqual(contracts.Outcome.ok, runtime.finishInput());
    try testing.expectEqual(contracts.Outcome.failed, runtime.finishInput());
    try testing.expectEqual(contracts.Outcome.ok, runtime.stopAccepting());
    try testing.expectEqual(contracts.Outcome.ok, runtime.stageFinalDetachments());
    try testing.expectEqual(contracts.Progress.complete, runtime.shutdownProgress());
    try testing.expectEqual(@as(u8, 1), state.published_inputs);
    try testing.expectEqual(@as(u8, 1), state.released_inputs);
}
