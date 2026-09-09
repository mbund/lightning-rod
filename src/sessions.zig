const driver = @import("sessions/driver.zig");
const core_exchange = @import("core_exchange.zig");
const protocol_support = @import("protocol_support");
const std = @import("std");
const version = @import("version.zig");
const players = @import("world/players.zig");

pub const Protocol = @import("session_api.zig").Protocol;
pub const Phase = @import("session_api.zig").Phase;
pub const PacketView = core_exchange.PacketView;
pub const PacketAdmission = @import("session_api.zig").PacketAdmission;
pub const EncodedPacket = @import("session_api.zig").EncodedPacket;
pub const PacketEncoder = @import("session_api.zig").PacketEncoder;
pub const PacketBatchItem = @import("session_api.zig").PacketBatchItem;
pub const FanoutResult = @import("session_api.zig").FanoutResult;
pub const FanoutAdmissions = @import("session_api.zig").FanoutAdmissions;
pub const DeliveryClass = @import("session_api.zig").DeliveryClass;
pub const DeliveryPolicy = @import("session_api.zig").DeliveryPolicy;
pub const Claim = @import("session_api.zig").Claim;
pub const OutputState = @import("session_api.zig").OutputState;
pub const Runtime = @import("session_api.zig").Runtime;
pub const Packet = struct {
    phase: Phase,
    protocol: Protocol,
    id: i32,
    body: []const u8,
};

pub const Sessions = struct {
    configuration_entries: [configuration.maximum_entries]configuration.Entry = undefined,
    configuration_count: usize = 0,
    status_provider: ?driver.Status = null,
    compression_threshold: ?i32 = 256,
    default_status_json: [256]u8 = undefined,
    default_status_len: usize = 0,
    runtime: ?Runtime = null,

    pub fn init(protocol: i32) Sessions {
        var self: Sessions = .{};
        self.default_status_len = (std.fmt.bufPrint(
            &self.default_status_json,
            "{{\"version\":{{\"name\":\"{s}\",\"protocol\":{d}}},\"description\":{{\"text\":\"Lightning Rod\"}}}}",
            .{ version.brand, protocol },
        ) catch unreachable).len;
        return self;
    }

    pub fn configure(self: *Sessions, plan: configuration.Plan) !void {
        if (!plan.valid()) return error.InvalidConfigurationPlan;
        if (plan.entries.len > self.configuration_entries.len - self.configuration_count)
            return error.ConfigurationCapacity;
        @memcpy(self.configuration_entries[self.configuration_count..][0..plan.entries.len], plan.entries);
        self.configuration_count += plan.entries.len;
    }

    pub fn status(self: *Sessions, provider: driver.Status) !void {
        if (self.status_provider != null) return error.StatusAlreadyRegistered;
        self.status_provider = provider;
    }

    pub fn configurationPlan(self: *const Sessions) !configuration.Plan {
        if (self.configuration_count == 0) return error.ConfigurationNotRegistered;
        return .{ .entries = self.configuration_entries[0..self.configuration_count] };
    }

    pub fn statusProvider(self: *const Sessions) driver.Status {
        return self.status_provider orelse .{ .context = self, .vtable = &.{ .snapshot = defaultStatus } };
    }

    pub fn compressionThreshold(self: *const Sessions) ?i32 {
        return self.compression_threshold;
    }

    pub fn bindRuntime(self: *Sessions, value: Runtime) void {
        std.debug.assert(self.runtime == null);
        self.runtime = value;
    }

    pub fn flush(self: *Sessions) void {
        const runtime = self.runtime orelse return;
        runtime.flush();
    }

    pub fn playerSession(self: *const Sessions, slot: u16) ?players.Session {
        const runtime = self.runtime orelse return null;
        return runtime.vtable.player_session(runtime.context, slot);
    }

    pub fn playerProtocol(self: *const Sessions, value: players.Session) ?Protocol {
        const runtime = self.runtime orelse return null;
        return runtime.vtable.player_protocol(runtime.context, value);
    }

    pub fn outputState(self: *const Sessions, value: players.Session) ?OutputState {
        const runtime = self.runtime orelse return null;
        return runtime.vtable.output_state(runtime.context, value);
    }

    pub fn protocolForPlayer(self: *const Sessions, slot: u16) ?Protocol {
        const player = self.playerSession(slot) orelse return null;
        return self.playerProtocol(player);
    }

    pub fn packetViews(self: *const Sessions) []const core_exchange.PacketView {
        const runtime = self.runtime orelse return &.{};
        return runtime.vtable.packet_views(runtime.context);
    }

    pub fn claimPacket(self: *Sessions, value: core_exchange.PacketView) Claim {
        const runtime = self.runtime orelse return .unavailable;
        return runtime.vtable.claim_packet(runtime.context, value);
    }

    pub fn send(
        self: *Sessions,
        temporary: std.mem.Allocator,
        recipients: []const players.Session,
        class: DeliveryClass,
        comptime Descriptor: type,
        arguments: *const Descriptor.Arguments,
    ) std.mem.Allocator.Error!FanoutResult {
        return self.fanout(temporary, recipients, class, generated(Descriptor, arguments));
    }

    pub fn trySend(
        self: *Sessions,
        temporary: std.mem.Allocator,
        recipients: []const players.Session,
        class: DeliveryClass,
        comptime Descriptor: type,
        arguments: *const Descriptor.Arguments,
    ) std.mem.Allocator.Error!FanoutResult {
        return self.tryFanout(temporary, recipients, class, generated(Descriptor, arguments));
    }

    pub fn sendOne(
        self: *Sessions,
        temporary: std.mem.Allocator,
        recipient: players.Session,
        class: DeliveryClass,
        comptime Descriptor: type,
        arguments: *const Descriptor.Arguments,
    ) std.mem.Allocator.Error!PacketAdmission {
        return self.fanoutOne(temporary, recipient, class, generated(Descriptor, arguments), .reliable);
    }

    pub fn trySendOne(
        self: *Sessions,
        temporary: std.mem.Allocator,
        recipient: players.Session,
        class: DeliveryClass,
        comptime Descriptor: type,
        arguments: *const Descriptor.Arguments,
    ) std.mem.Allocator.Error!PacketAdmission {
        return self.fanoutOne(temporary, recipient, class, generated(Descriptor, arguments), .optional);
    }

    pub fn sendPacket(
        self: *Sessions,
        temporary: std.mem.Allocator,
        recipients: []const players.Session,
        class: DeliveryClass,
        packet: *const Packet,
    ) std.mem.Allocator.Error!FanoutResult {
        return self.fanout(temporary, recipients, class, raw(packet));
    }

    pub fn trySendPacket(
        self: *Sessions,
        temporary: std.mem.Allocator,
        recipients: []const players.Session,
        class: DeliveryClass,
        packet: *const Packet,
    ) std.mem.Allocator.Error!FanoutResult {
        return self.tryFanout(temporary, recipients, class, raw(packet));
    }

    pub fn fanout(
        self: *Sessions,
        temporary: std.mem.Allocator,
        recipients: []const players.Session,
        class: DeliveryClass,
        encoder: PacketEncoder,
    ) std.mem.Allocator.Error!FanoutResult {
        const runtime = self.runtime orelse return closedFanout(temporary, recipients);
        return runtime.vtable.fanout(runtime.context, temporary, recipients, encoder, class, .reliable);
    }

    pub fn tryFanout(
        self: *Sessions,
        temporary: std.mem.Allocator,
        recipients: []const players.Session,
        class: DeliveryClass,
        encoder: PacketEncoder,
    ) std.mem.Allocator.Error!FanoutResult {
        const runtime = self.runtime orelse return closedFanout(temporary, recipients);
        return runtime.vtable.fanout(runtime.context, temporary, recipients, encoder, class, .optional);
    }

    pub fn tryBatch(
        self: *Sessions,
        temporary: std.mem.Allocator,
        items: []const PacketBatchItem,
        class: DeliveryClass,
    ) std.mem.Allocator.Error![]const PacketAdmission {
        const runtime = self.runtime orelse {
            const admissions = try temporary.alloc(PacketAdmission, items.len);
            @memset(admissions, .closed);
            return admissions;
        };
        return (try runtime.vtable.batch(
            runtime.context,
            temporary,
            items,
            class,
            .optional,
        )).values;
    }

    pub fn batch(
        self: *Sessions,
        temporary: std.mem.Allocator,
        items: []const PacketBatchItem,
        class: DeliveryClass,
    ) std.mem.Allocator.Error![]const PacketAdmission {
        const runtime = self.runtime orelse {
            const admissions = try temporary.alloc(PacketAdmission, items.len);
            @memset(admissions, .closed);
            return admissions;
        };
        return (try runtime.vtable.batch(
            runtime.context,
            temporary,
            items,
            class,
            .reliable,
        )).values;
    }

    pub fn fanoutOne(self: *Sessions, temporary: std.mem.Allocator, recipient: players.Session, class: DeliveryClass, encoder: PacketEncoder, policy: DeliveryPolicy) std.mem.Allocator.Error!PacketAdmission {
        _ = temporary;
        const runtime = self.runtime orelse return .closed;
        return runtime.vtable.send_one(runtime.context, recipient, encoder, class, policy);
    }

    fn defaultStatus(context: *const anyopaque) @import("session_api.zig").StatusSnapshot {
        const self: *const Sessions = @ptrCast(@alignCast(context));
        return .{ .revision = 1, .json = self.default_status_json[0..self.default_status_len] };
    }
};

pub fn generated(comptime Descriptor: type, arguments: *const Descriptor.Arguments) PacketEncoder {
    comptime {
        if (!@hasDecl(Descriptor, "phase") or !@hasDecl(Descriptor, "maximum_payload_bytes") or !@hasDecl(Descriptor, "encode"))
            @compileError("a generated packet descriptor must declare phase, maximum_payload_bytes, and encode");
    }
    const Adapter = struct {
        fn encode(context: *const anyopaque, protocol: Protocol, output: []u8) ?EncodedPacket {
            const value: *const Descriptor.Arguments = @ptrCast(@alignCast(context));
            return Descriptor.encode(protocol, value, output);
        }
    };
    return .{
        .phase = Descriptor.phase,
        .maximum_payload_bytes = Descriptor.maximum_payload_bytes,
        .context = arguments,
        .encode = Adapter.encode,
    };
}

pub fn raw(packet: *const Packet) PacketEncoder {
    const Adapter = struct {
        fn encode(context: *const anyopaque, protocol: Protocol, output: []u8) ?EncodedPacket {
            const value: *const Packet = @ptrCast(@alignCast(context));
            if (!protocol.eql(value.protocol)) return null;
            var rest = protocol_support.write_varint(output, value.id) catch return null;
            if (rest.len < value.body.len) return null;
            @memcpy(rest[0..value.body.len], value.body);
            rest = rest[value.body.len..];
            return .{ .payload = output[0 .. output.len - rest.len] };
        }
    };
    return .{
        .phase = packet.phase,
        .maximum_payload_bytes = packet.body.len + 5,
        .context = packet,
        .encode = Adapter.encode,
    };
}

pub const fanoutResult = @import("session_api.zig").fanoutResult;

fn closedFanout(temporary: std.mem.Allocator, recipients: []const players.Session) std.mem.Allocator.Error!FanoutResult {
    const states = try temporary.alloc(PacketAdmission, recipients.len);
    @memset(states, .closed);
    return fanoutResult(temporary, recipients, states);
}

pub const Table = @import("sessions/table.zig").Table;
pub const Catalog = @import("protocol_sessions.zig").Catalog;
pub const configuration = @import("configuration_plan.zig");
pub const Continuation = @import("minecraft_session.zig").Continuation;
pub const Driver = driver.Driver;
pub const Clock = driver.Clock;
pub const Status = driver.Status;
pub const CoreBoundary = driver.CoreBoundary;
pub const PacketBridge = @import("sessions/packet_bridge.zig").Bridge;

test {
    _ = driver;
}

test "configuration contributions retain composition order" {
    var value = Sessions.init(772);
    const entries = [_]configuration.Entry{.{ .feature_flags = .{ .values = &.{"minecraft:vanilla"} } }};
    try value.configure(.{ .entries = &entries });
    try value.configure(.{ .entries = &entries });
    try std.testing.expectEqual(@as(usize, 2), (try value.configurationPlan()).entries.len);
}

test "typed fanout delegates to the session runtime" {
    const State = struct {
        calls: u8 = 0,

        fn from(context: *anyopaque) *@This() {
            return @ptrCast(@alignCast(context));
        }

        fn session(_: *anyopaque, slot: u16) ?players.Session {
            return if (slot == 1) .{ .slot = slot, .generation = 1 } else null;
        }

        fn protocol(_: *anyopaque, _: players.Session) ?Protocol {
            return .{ .value = 772 };
        }

        fn outputState(_: *anyopaque, _: players.Session) ?OutputState {
            return .{ .credit_bytes = 1, .queued_bytes = 2, .capacity_bytes = 3 };
        }

        fn views(_: *const anyopaque) []const core_exchange.PacketView {
            return &.{};
        }

        fn claim(_: *anyopaque, _: core_exchange.PacketView) Claim {
            return .unavailable;
        }

        fn sendOne(_: *anyopaque, _: players.Session, _: PacketEncoder, _: DeliveryClass, _: DeliveryPolicy) PacketAdmission {
            return .accepted;
        }

        fn batch(_: *anyopaque, temporary: std.mem.Allocator, items: []const PacketBatchItem, _: DeliveryClass, _: DeliveryPolicy) std.mem.Allocator.Error!FanoutAdmissions {
            const values = try temporary.alloc(PacketAdmission, items.len);
            @memset(values, .accepted);
            return .{ .values = values };
        }

        fn fanout(context: *anyopaque, temporary: std.mem.Allocator, recipients: []const players.Session, encoder: PacketEncoder, class: DeliveryClass, policy: DeliveryPolicy) std.mem.Allocator.Error!FanoutResult {
            const state = from(context);
            state.calls += 1;
            std.debug.assert(class == .entities and policy == .optional and encoder.maximum_payload_bytes == 4);
            var output: [4]u8 = undefined;
            const encoded = encoder.encode(encoder.context, .{ .value = 772 }, &output).?;
            std.debug.assert(encoded.payload.len == 1);
            return fanoutResult(temporary, recipients, &.{.backpressured});
        }

        fn flush(_: *anyopaque) void {}
    };
    const Descriptor = struct {
        pub const Arguments = State;
        pub const phase: @import("session_api.zig").Phase = .play;
        pub const maximum_payload_bytes = 4;

        pub fn encode(protocol: Protocol, _: *const Arguments, output: []u8) ?EncodedPacket {
            output[0] = @intCast(protocol.value - 770);
            return .{ .payload = output[0..1] };
        }
    };

    var state = State{};
    var value = Sessions.init(772);
    value.bindRuntime(.{ .context = &state, .vtable = &.{
        .player_session = State.session,
        .player_protocol = State.protocol,
        .output_state = State.outputState,
        .packet_views = State.views,
        .claim_packet = State.claim,
        .send_one = State.sendOne,
        .batch = State.batch,
        .fanout = State.fanout,
        .flush = State.flush,
    } });
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const recipients = [_]players.Session{
        .{ .slot = 1, .generation = 1 },
    };
    const result = try value.trySend(fixed.allocator(), &recipients, .entities, Descriptor, &state);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try std.testing.expectEqual(@as(usize, 0), result.delivered.len);
    try std.testing.expectEqual(@as(usize, 1), result.backpressured.len);
    try std.testing.expectEqual(@as(u16, 1), result.backpressured[0].slot);
}

test "raw packets are exact-protocol payloads" {
    const packet = Packet{ .phase = .play, .protocol = .{ .value = 772 }, .id = 42, .body = &.{ 1, 2, 3 } };
    const encoder = raw(&packet);
    var output: [16]u8 = undefined;
    try std.testing.expect(encoder.encode(encoder.context, .{ .value = 771 }, &output) == null);
    const encoded = encoder.encode(encoder.context, .{ .value = 772 }, &output).?;
    try std.testing.expectEqualSlices(u8, &.{ 42, 1, 2, 3 }, encoded.payload);
}

pub const ResourcePack = struct {
    pub const id = "lightning_rod:resource_pack";
    pub const Dependencies = struct { sessions: *Sessions };
    pub const Configuration = configuration.ResourcePack;

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, settings: Configuration) !*ResourcePack {
        try deps.sessions.configure(.{ .entries = &.{.{ .resource_pack = settings }} });
        return allocator.create(ResourcePack);
    }
};

test "sessions retain packets until the Core boundary" {
    var table = Table(1, 1){};
    const Stub = struct {
        fn complete(_: *anyopaque, events: []@import("transport_exchange.zig").TransportEvent) usize {
            _ = events;
            return 0;
        }
        fn inputPage(_: *anyopaque, _: @import("connection_api.zig").Page) ?@import("transport_exchange.zig").InputPage {
            return null;
        }
        fn outputCredit(_: *anyopaque, _: @import("connection_api.zig").Handle) usize {
            return 0;
        }
        fn outputMetrics(_: *anyopaque, _: @import("connection_api.zig").Handle) ?@import("transport_exchange.zig").OutputMetrics {
            return null;
        }
        fn write(_: *anyopaque, _: @import("connection_api.zig").Handle, _: []const u8) bool {
            return false;
        }
        fn release(_: *anyopaque, _: @import("connection_api.zig").Page) void {}
        fn close(_: *anyopaque, _: @import("connection_api.zig").Handle, _: @import("connection_api.zig").DisconnectReason) void {
            unreachable;
        }
        fn submit(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    table.initialize();
    table.advance(.{ .context = &context, .vtable = &.{ .complete = Stub.complete, .input_page = Stub.inputPage, .output_credit = Stub.outputCredit, .output_metrics = Stub.outputMetrics, .write = Stub.write, .release_input = Stub.release, .close = Stub.close, .submit = Stub.submit } }, 0, .{ .revision = 1, .json = "{}" });
    try @import("std").testing.expectEqual(@as(usize, 0), table.input().packet_views.len);
}
