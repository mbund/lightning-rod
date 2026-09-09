const std = @import("std");

const core_exchange = @import("../core_exchange.zig");
const players = @import("../world/players.zig");
const session_api = @import("../session_api.zig");
const transport = @import("../transport_exchange.zig");

const Core = struct {
    context: *anyopaque,
    player_session: *const fn (*anyopaque, u16) ?players.Session,
    player_protocol: *const fn (*const anyopaque, players.Session) ?session_api.Protocol,
    connection_for_player: *const fn (*anyopaque, players.Session) ?transport.Connection,
    packet_views: *const fn (*const anyopaque) []const core_exchange.PacketView,
    claim_packet: *const fn (*anyopaque, core_exchange.PacketView) session_api.Claim,
};

pub const OutputState = struct {
    context: *const anyopaque,
    state: *const fn (*const anyopaque, transport.Connection) ?session_api.OutputState,
};

pub const Bridge = struct {
    core: Core,
    egress: core_exchange.Egress,
    output: OutputState,
    scratch: []u8,

    pub fn init(value: @import("driver.zig").CoreBoundary, egress: core_exchange.Egress, output: OutputState, scratch: []u8) Bridge {
        return .{
            .core = .{
                .context = value.context,
                .player_session = value.vtable.player_session,
                .player_protocol = value.vtable.player_protocol,
                .connection_for_player = value.vtable.connection_for_player,
                .packet_views = value.vtable.packet_views,
                .claim_packet = value.vtable.claim_packet,
            },
            .egress = egress,
            .output = output,
            .scratch = scratch,
        };
    }

    pub fn runtime(self: *Bridge) session_api.Runtime {
        return .{ .context = self, .vtable = &.{
            .player_session = playerSession,
            .player_protocol = playerProtocol,
            .output_state = outputState,
            .packet_views = packetViews,
            .claim_packet = claimPacket,
            .send_one = sendOne,
            .batch = batch,
            .fanout = fanout,
            .flush = flush,
        } };
    }

    fn from(raw: *anyopaque) *Bridge {
        return @ptrCast(@alignCast(raw));
    }

    fn playerSession(raw: *anyopaque, slot: u16) ?players.Session {
        const self = from(raw);
        return self.core.player_session(self.core.context, slot);
    }

    fn playerProtocol(raw: *const anyopaque, player: players.Session) ?session_api.Protocol {
        const self: *const Bridge = @ptrCast(@alignCast(raw));
        return self.core.player_protocol(self.core.context, player);
    }

    fn outputState(raw: *anyopaque, player: players.Session) ?session_api.OutputState {
        const self = from(raw);
        const connection = self.core.connection_for_player(self.core.context, player) orelse return null;
        return self.output.state(self.output.context, connection);
    }

    fn packetViews(raw: *const anyopaque) []const core_exchange.PacketView {
        const self: *const Bridge = @ptrCast(@alignCast(raw));
        return self.core.packet_views(self.core.context);
    }

    fn claimPacket(raw: *anyopaque, packet: core_exchange.PacketView) session_api.Claim {
        const self = from(raw);
        return self.core.claim_packet(self.core.context, packet);
    }

    fn flush(raw: *anyopaque) void {
        from(raw).egress.flush();
    }

    fn sendOne(raw: *anyopaque, player: players.Session, encoder: session_api.PacketEncoder, class: session_api.DeliveryClass, policy: session_api.DeliveryPolicy) session_api.PacketAdmission {
        const self = from(raw);
        return self.stagePlayer(player, encoder, class, policy);
    }

    fn batch(raw: *anyopaque, temporary: std.mem.Allocator, items: []const session_api.PacketBatchItem, class: session_api.DeliveryClass, policy: session_api.DeliveryPolicy) std.mem.Allocator.Error!session_api.FanoutAdmissions {
        const self = from(raw);
        const values = try temporary.alloc(session_api.PacketAdmission, items.len);
        for (items, values) |item, *value| value.* = self.stagePlayer(item.recipient, item.encoder, class, policy);
        return .{ .values = values };
    }

    fn fanout(raw: *anyopaque, temporary: std.mem.Allocator, recipients: []const players.Session, encoder: session_api.PacketEncoder, class: session_api.DeliveryClass, policy: session_api.DeliveryPolicy) std.mem.Allocator.Error!session_api.FanoutResult {
        const self = from(raw);
        const admissions = try temporary.alloc(session_api.PacketAdmission, recipients.len);
        const protocols = try temporary.alloc(?session_api.Protocol, recipients.len);
        const targets = try temporary.alloc(core_exchange.OutputTarget, recipients.len);
        for (recipients, protocols, admissions) |player, *protocol, *admission| {
            protocol.* = self.core.player_protocol(self.core.context, player);
            admission.* = if (protocol.* == null) .wrong_protocol else .wrong_phase;
        }
        for (protocols, 0..) |entry, index| {
            const protocol = entry orelse continue;
            if (contains(protocols[0..index], protocol)) continue;
            var target_count: usize = 0;
            for (recipients, protocols, admissions) |player, player_protocol, *admission| {
                if (player_protocol == null or !player_protocol.?.eql(protocol)) continue;
                const connection = self.core.connection_for_player(self.core.context, player) orelse {
                    admission.* = .closed;
                    continue;
                };
                targets[target_count] = .{ .connection = connection, .protocol = protocol, .phase = encoder.phase, .class = class, .policy = policy };
                target_count += 1;
            }
            if (target_count == 0) continue;
            const direct = self.egress.encodeFanout(targets[0..target_count], encoder);
            if (direct != .wrong_protocol) {
                for (protocols, admissions) |player_protocol, *admission| {
                    if (player_protocol != null and player_protocol.?.eql(protocol) and admission.* != .closed) admission.* = direct;
                }
                continue;
            }
            if (encoder.maximum_payload_bytes > self.scratch.len) {
                for (protocols, admissions) |player_protocol, *admission| {
                    if (player_protocol != null and player_protocol.?.eql(protocol) and admission.* != .closed) admission.* = .backpressured;
                }
                continue;
            }
            const payload = encoder.encode(encoder.context, protocol, self.scratch[0..encoder.maximum_payload_bytes]) orelse continue;
            const staged = self.egress.stageFanout(targets[0..target_count], payload.payload);
            for (protocols, admissions) |player_protocol, *admission| {
                if (player_protocol != null and player_protocol.?.eql(protocol) and admission.* != .closed)
                    admission.* = staged;
            }
        }
        return session_api.fanoutResult(temporary, recipients, admissions);
    }

    fn stagePlayer(self: *Bridge, player: players.Session, encoder: session_api.PacketEncoder, class: session_api.DeliveryClass, policy: session_api.DeliveryPolicy) session_api.PacketAdmission {
        const protocol = self.core.player_protocol(self.core.context, player) orelse return .wrong_protocol;
        const connection = self.core.connection_for_player(self.core.context, player) orelse return .closed;
        const direct = self.egress.encode(.{
            .connection = connection,
            .protocol = protocol,
            .phase = encoder.phase,
            .class = class,
            .policy = policy,
        }, encoder);
        if (direct != .wrong_protocol) return direct;
        if (encoder.maximum_payload_bytes > self.scratch.len) return .backpressured;
        const payload = encoder.encode(encoder.context, protocol, self.scratch[0..encoder.maximum_payload_bytes]) orelse return .wrong_protocol;
        return stage(self.egress, connection, protocol, encoder.phase, payload.payload, class, policy);
    }
};

fn stage(egress: core_exchange.Egress, connection: transport.Connection, protocol: session_api.Protocol, phase: session_api.Phase, payload: []const u8, class: session_api.DeliveryClass, policy: session_api.DeliveryPolicy) session_api.PacketAdmission {
    return egress.stage(.{ .connection = connection, .protocol = protocol, .phase = phase, .class = class, .policy = policy, .payload = payload });
}

fn contains(values: []const ?session_api.Protocol, target: session_api.Protocol) bool {
    for (values) |value| if (value != null and value.?.eql(target)) return true;
    return false;
}
