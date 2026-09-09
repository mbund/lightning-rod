const exchange = @import("transport_exchange.zig");
const core_exchange = @import("core_exchange.zig");
const runtime = @import("runtime/contracts.zig");
const std = @import("std");
const players = @import("world/players.zig");

pub const Phase = core_exchange.Phase;
pub const PacketView = core_exchange.PacketView;
pub const Exchange = core_exchange.SessionExchange;
pub const ExchangeLimits = core_exchange.SessionExchangeLimits;
pub const SessionToCore = core_exchange.SessionToCore;
pub const CoreToSession = core_exchange.CoreToSession;
pub const Egress = core_exchange.Egress;
pub const Output = core_exchange.Output;
pub const CoreOutputConsumer = struct {
    context: *anyopaque,
    vtable: *const VTable,
    source: core_exchange.OutputSource,

    pub const VTable = struct {
        consume: *const fn (*anyopaque, exchange.Transport, core_exchange.OutputSource, CoreToSession, []const u8) PacketAdmission,
    };

    pub fn consume(self: CoreOutputConsumer, transport: exchange.Transport, message: CoreToSession, bytes: []const u8) PacketAdmission {
        return self.vtable.consume(self.context, transport, self.source, message, bytes);
    }
};
pub const ShutdownProgress = enum(u8) { pending, complete };
pub const Admission = enum(u8) { accepted, full, unsupported };
pub const StatusSnapshot = struct { revision: u64, json: []const u8 };
pub const Protocol = core_exchange.Protocol;
pub const PacketAdmission = core_exchange.PacketAdmission;
pub const DeliveryClass = core_exchange.DeliveryClass;
pub const DeliveryPolicy = core_exchange.DeliveryPolicy;
pub const EncodedPacket = core_exchange.EncodedPacket;
pub const PacketEncoder = core_exchange.PacketEncoder;
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
        flush: *const fn (*anyopaque) void,
    };

    pub fn flush(self: Runtime) void {
        self.vtable.flush(self.context);
    }
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
        authenticate: bool = true,
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
        fatal_disconnect: *const fn (*anyopaque, exchange.Transport) ShutdownProgress,
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
    pub fn fatalDisconnect(self: Sessions, transport: exchange.Transport) ShutdownProgress {
        return self.vtable.fatal_disconnect(self.context, transport);
    }
    pub fn shutdownProgress(self: Sessions) ShutdownProgress {
        return self.vtable.shutdown_progress(self.context);
    }
};
