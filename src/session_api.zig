const exchange = @import("transport_exchange.zig");
const core_exchange = @import("core_exchange.zig");
const runtime = @import("runtime/contracts.zig");
const std = @import("std");
const players = @import("world/players.zig");

pub const Phase = core_exchange.Phase;
pub const PacketView = core_exchange.PacketView;
pub const ShutdownProgress = enum(u8) { pending, complete };
pub const Admission = enum(u8) { accepted, full, unsupported };
pub const StatusSnapshot = struct { revision: u64, json: []const u8 };
pub const Protocol = extern struct {
    value: i32,

    pub fn eql(a: Protocol, b: Protocol) bool {
        return a.value == b.value;
    }
};
pub const PacketAdmission = enum(u8) { accepted, backpressured, closed, wrong_protocol, wrong_phase };
pub const DeliveryClass = enum(u8) { control, chunks, entities, other };
pub const DeliveryPolicy = enum(u8) { reliable, optional };
pub const EncodedPacket = struct { payload: []const u8 };
pub const PacketEncoder = struct {
    phase: Phase,
    maximum_payload_bytes: usize,
    context: *const anyopaque,
    encode: *const fn (*const anyopaque, Protocol, []u8) ?EncodedPacket,
};
pub const PacketBatchItem = struct {
    recipient: players.Session,
    encoder: PacketEncoder,
};
pub const WirePacketBatchItem = struct {
    recipient: exchange.Connection,
    encoder: PacketEncoder,
};
pub const FanoutResult = struct {
    delivered: []const players.Session,
    backpressured: []const players.Session,
    closed: []const players.Session,
    wrong_protocol: []const players.Session,
    wrong_phase: []const players.Session,
};
pub const FanoutAdmissions = struct {
    values: []const PacketAdmission,
};
pub const Claim = enum { claimed, unavailable };
pub const OutputState = struct {
    credit_bytes: usize,
    queued_bytes: usize,
    capacity_bytes: usize,
};
pub const Runtime = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        player_session: *const fn (*anyopaque, u16) ?players.Session,
        player_protocol: *const fn (*anyopaque, players.Session) ?Protocol,
        output_state: *const fn (*anyopaque, players.Session) ?OutputState,
        packet_views: *const fn (*const anyopaque) []const core_exchange.PacketView,
        claim_packet: *const fn (*anyopaque, core_exchange.PacketView) Claim,
        send_one: *const fn (*anyopaque, players.Session, PacketEncoder, DeliveryClass, DeliveryPolicy) PacketAdmission,
        batch: *const fn (*anyopaque, std.mem.Allocator, []const PacketBatchItem, DeliveryClass, DeliveryPolicy) std.mem.Allocator.Error!FanoutAdmissions,
        fanout: *const fn (*anyopaque, std.mem.Allocator, []const players.Session, PacketEncoder, DeliveryClass, DeliveryPolicy) std.mem.Allocator.Error!FanoutResult,
    };
};

pub fn fanoutResult(
    temporary: std.mem.Allocator,
    recipients: []const players.Session,
    admissions: []const PacketAdmission,
) std.mem.Allocator.Error!FanoutResult {
    var counts: [5]usize = @splat(0);
    for (admissions) |admission| counts[@intFromEnum(admission)] += 1;
    const delivered = try temporary.alloc(players.Session, counts[@intFromEnum(PacketAdmission.accepted)]);
    const backpressured = try temporary.alloc(players.Session, counts[@intFromEnum(PacketAdmission.backpressured)]);
    const closed = try temporary.alloc(players.Session, counts[@intFromEnum(PacketAdmission.closed)]);
    const wrong_protocol = try temporary.alloc(players.Session, counts[@intFromEnum(PacketAdmission.wrong_protocol)]);
    const wrong_phase = try temporary.alloc(players.Session, counts[@intFromEnum(PacketAdmission.wrong_phase)]);
    var cursors: [5]usize = @splat(0);
    for (recipients, admissions) |recipient, admission| {
        const index = @intFromEnum(admission);
        const destination = switch (admission) {
            .accepted => delivered,
            .backpressured => backpressured,
            .closed => closed,
            .wrong_protocol => wrong_protocol,
            .wrong_phase => wrong_phase,
        };
        destination[cursors[index]] = recipient;
        cursors[index] += 1;
    }
    return .{
        .delivered = delivered,
        .backpressured = backpressured,
        .closed = closed,
        .wrong_protocol = wrong_protocol,
        .wrong_phase = wrong_phase,
    };
}

pub const Authentication = struct {
    io: *std.Io,
    max_pending: u16,
    context: *anyopaque,
    vtable: *const VTable,
    readiness: ?runtime.Readiness = null,

    pub const Result = union(enum) {
        pending,
        accepted: Accepted,
        encryption_request: EncryptionRequest,
        rejected,
    };
    pub const Accepted = struct {
        uuid: u128,
        secret: ?[16]u8 = null,
    };
    pub const EncryptionRequest = struct {
        public_key: []const u8,
        verify_token: []const u8,
    };
    pub const LoginStart = struct {
        connection: exchange.Connection,
        username: []const u8,
        deadline_ns: u64,
    };
    pub const EncryptionResponse = struct {
        connection: exchange.Connection,
        username: []const u8,
        shared_secret: []const u8,
        verify_token: []const u8,
        deadline_ns: u64,
    };
    pub const VTable = struct {
        start: *const fn (*anyopaque, LoginStart) Result,
        respond: *const fn (*anyopaque, EncryptionResponse) Result,
        poll: *const fn (*anyopaque, exchange.Connection) Result,
        cancel: *const fn (*anyopaque, exchange.Connection) void,
    };
};

pub const Sessions = struct {
    context: *anyopaque,
    vtable: *const VTable,
    readiness: ?runtime.Readiness = null,

    pub const VTable = struct {
        advance: *const fn (*anyopaque, exchange.Transport, u64, StatusSnapshot) void,
        take_input: *const fn (*anyopaque) exchange.CoreInput,
        finish_input: *const fn (*anyopaque, exchange.Transport) void,
        protocol: *const fn (*const anyopaque, exchange.Connection) ?Protocol,
        output_state: *const fn (*const anyopaque, exchange.Transport, exchange.Connection) ?OutputState,
        send_one: *const fn (*anyopaque, exchange.Transport, exchange.Connection, PacketEncoder, DeliveryClass, DeliveryPolicy) PacketAdmission,
        batch: *const fn (*anyopaque, exchange.Transport, []const WirePacketBatchItem, DeliveryClass, DeliveryPolicy, std.mem.Allocator) std.mem.Allocator.Error!FanoutAdmissions,
        fanout: *const fn (*anyopaque, exchange.Transport, []const exchange.Connection, PacketEncoder, DeliveryClass, DeliveryPolicy, std.mem.Allocator) std.mem.Allocator.Error!FanoutAdmissions,
        stop_accepting: *const fn (*anyopaque) void,
        stage_final_detachments: *const fn (*anyopaque) void,
        shutdown_progress: *const fn (*anyopaque) ShutdownProgress,
    };

    pub fn advance(self: Sessions, transport: exchange.Transport, now_ns: u64, status: StatusSnapshot) void {
        self.vtable.advance(self.context, transport, now_ns, status);
    }
    pub fn takeInput(self: Sessions) exchange.CoreInput {
        return self.vtable.take_input(self.context);
    }
    pub fn finishInput(self: Sessions, transport: exchange.Transport) void {
        self.vtable.finish_input(self.context, transport);
    }
    pub fn protocol(self: Sessions, connection: exchange.Connection) ?Protocol {
        return self.vtable.protocol(self.context, connection);
    }
    pub fn outputState(self: Sessions, transport: exchange.Transport, connection: exchange.Connection) ?OutputState {
        return self.vtable.output_state(self.context, transport, connection);
    }
    pub fn sendOne(self: Sessions, transport: exchange.Transport, connection: exchange.Connection, encoder: PacketEncoder, class: DeliveryClass, policy: DeliveryPolicy) PacketAdmission {
        return self.vtable.send_one(self.context, transport, connection, encoder, class, policy);
    }
    pub fn batch(self: Sessions, transport: exchange.Transport, items: []const WirePacketBatchItem, class: DeliveryClass, policy: DeliveryPolicy, temporary: std.mem.Allocator) std.mem.Allocator.Error!FanoutAdmissions {
        return self.vtable.batch(self.context, transport, items, class, policy, temporary);
    }
    pub fn fanout(
        self: Sessions,
        transport: exchange.Transport,
        recipients: []const exchange.Connection,
        encoder: PacketEncoder,
        class: DeliveryClass,
        policy: DeliveryPolicy,
        temporary: std.mem.Allocator,
    ) std.mem.Allocator.Error!FanoutAdmissions {
        return self.vtable.fanout(self.context, transport, recipients, encoder, class, policy, temporary);
    }
    pub fn stopAccepting(self: Sessions) void {
        self.vtable.stop_accepting(self.context);
    }
    pub fn stageFinalDetachments(self: Sessions) void {
        self.vtable.stage_final_detachments(self.context);
    }
    pub fn shutdownProgress(self: Sessions) ShutdownProgress {
        return self.vtable.shutdown_progress(self.context);
    }
};

test "every Sessions wrapper dispatches once" {
    const State = struct { calls: u8 = 0 };
    const Stub = struct {
        fn state(raw: *anyopaque) *State {
            return @ptrCast(@alignCast(raw));
        }
        fn advance(raw: *anyopaque, _: exchange.Transport, _: u64, _: StatusSnapshot) void {
            state(raw).calls += 1;
        }
        fn input(raw: *anyopaque) exchange.CoreInput {
            state(raw).calls += 1;
            return .{ .attachments = &.{}, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} };
        }
        fn finish(raw: *anyopaque, _: exchange.Transport) void {
            state(raw).calls += 1;
        }
        fn protocol(_: *const anyopaque, _: exchange.Connection) ?Protocol {
            return .{ .value = 772 };
        }
        fn outputState(_: *const anyopaque, _: exchange.Transport, _: exchange.Connection) ?OutputState {
            return .{ .credit_bytes = 1, .queued_bytes = 2, .capacity_bytes = 3 };
        }
        fn sendOne(raw: *anyopaque, _: exchange.Transport, _: exchange.Connection, _: PacketEncoder, _: DeliveryClass, _: DeliveryPolicy) PacketAdmission {
            state(raw).calls += 1;
            return .backpressured;
        }
        fn batch(raw: *anyopaque, _: exchange.Transport, items: []const WirePacketBatchItem, _: DeliveryClass, _: DeliveryPolicy, temporary: std.mem.Allocator) std.mem.Allocator.Error!FanoutAdmissions {
            state(raw).calls += 1;
            const values = try temporary.alloc(PacketAdmission, items.len);
            @memset(values, .accepted);
            return .{ .values = values };
        }
        fn fanout(raw: *anyopaque, _: exchange.Transport, recipients: []const exchange.Connection, _: PacketEncoder, _: DeliveryClass, _: DeliveryPolicy, temporary: std.mem.Allocator) std.mem.Allocator.Error!FanoutAdmissions {
            state(raw).calls += 1;
            const values = try temporary.alloc(PacketAdmission, recipients.len);
            @memset(values, .accepted);
            return .{ .values = values };
        }
        fn stop(raw: *anyopaque) void {
            state(raw).calls += 1;
        }
        fn detach(raw: *anyopaque) void {
            state(raw).calls += 1;
        }
        fn progress(raw: *anyopaque) ShutdownProgress {
            state(raw).calls += 1;
            return .complete;
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
        fn release(_: *anyopaque, _: exchange.Page) void {}
        fn close(_: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {}
        fn submit(_: *anyopaque) void {}
    };
    var state = State{};
    var transport_state: u8 = 0;
    const transport = exchange.Transport{ .context = &transport_state, .vtable = &.{ .complete = Stub.complete, .input_page = Stub.inputPage, .output_credit = Stub.credit, .output_metrics = Stub.metrics, .write = Stub.write, .release_input = Stub.release, .close = Stub.close, .submit = Stub.submit } };
    const sessions = Sessions{ .context = &state, .vtable = &.{ .advance = Stub.advance, .take_input = Stub.input, .finish_input = Stub.finish, .protocol = Stub.protocol, .output_state = Stub.outputState, .send_one = Stub.sendOne, .batch = Stub.batch, .fanout = Stub.fanout, .stop_accepting = Stub.stop, .stage_final_detachments = Stub.detach, .shutdown_progress = Stub.progress } };
    sessions.advance(transport, 9, .{ .revision = 1, .json = "{}" });
    _ = sessions.takeInput();
    sessions.finishInput(transport);
    var fanout_bytes: [128]u8 = undefined;
    var fanout_allocator = std.heap.FixedBufferAllocator.init(&fanout_bytes);
    const encoder = PacketEncoder{ .phase = .play, .maximum_payload_bytes = 0, .context = &state, .encode = struct {
        fn encode(_: *const anyopaque, _: Protocol, _: []u8) ?EncodedPacket {
            return .{ .payload = &.{} };
        }
    }.encode };
    try @import("std").testing.expectEqual(@as(i32, 772), sessions.protocol(.{ .index = 0, .generation = 1 }).?.value);
    try @import("std").testing.expectEqual(@as(usize, 2), sessions.outputState(transport, .{ .index = 0, .generation = 1 }).?.queued_bytes);
    try @import("std").testing.expectEqual(PacketAdmission.backpressured, sessions.sendOne(transport, .{ .index = 0, .generation = 1 }, encoder, .other, .optional));
    try @import("std").testing.expectEqual(@as(usize, 1), (try sessions.batch(transport, &.{.{ .recipient = .{ .index = 0, .generation = 1 }, .encoder = encoder }}, .other, .optional, fanout_allocator.allocator())).values.len);
    try @import("std").testing.expectEqual(@as(usize, 1), (try sessions.fanout(transport, &.{.{ .index = 0, .generation = 1 }}, encoder, .other, .reliable, fanout_allocator.allocator())).values.len);
    sessions.stopAccepting();
    sessions.stageFinalDetachments();
    try @import("std").testing.expectEqual(ShutdownProgress.complete, sessions.shutdownProgress());
    try @import("std").testing.expectEqual(@as(u8, 9), state.calls);
}
