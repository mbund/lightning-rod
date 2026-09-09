const geometry = @import("world/geometry.zig");
const connection = @import("connection_api.zig");
const session_exchange = @import("session_exchange.zig");
const std = @import("std");
const world_identity = @import("world/identity.zig");

pub const Phase = enum(u8) { handshake, status, login, configuration, play };
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

pub const OutputTarget = struct {
    connection: connection.Handle,
    protocol: Protocol,
    phase: Phase,
    class: DeliveryClass,
    policy: DeliveryPolicy,
};

pub const SessionExchange = session_exchange.Exchange;
pub const SessionExchangeLimits = session_exchange.Limits;
pub const SessionToCore = session_exchange.Inbound;
pub const CoreToSession = session_exchange.Outbound;
pub const SessionToCoreKind = session_exchange.ToCoreKind;
pub const CoreToSessionKind = session_exchange.ToSessionsKind;
/// Identity of one independent Core output exchange. Page and offset values are
/// only unique within this source.
pub const OutputSource = struct {
    value: usize,

    pub fn eql(a: OutputSource, b: OutputSource) bool {
        return a.value == b.value;
    }
};

pub fn outputSource(exchange: anytype) OutputSource {
    return .{ .value = @intFromPtr(exchange) };
}

pub const Output = struct {
    connection: connection.Handle,
    protocol: Protocol,
    phase: Phase,
    class: DeliveryClass,
    policy: DeliveryPolicy,
    payload: []const u8,
};

pub const Egress = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stage: *const fn (*anyopaque, Output) PacketAdmission,
        stage_fanout: *const fn (*anyopaque, []const OutputTarget, []const u8) PacketAdmission,
        encode: *const fn (*anyopaque, OutputTarget, PacketEncoder) PacketAdmission,
        encode_fanout: *const fn (*anyopaque, []const OutputTarget, PacketEncoder) PacketAdmission,
        flush: *const fn (*anyopaque) void,
    };

    pub fn stage(self: Egress, output: Output) PacketAdmission {
        return self.vtable.stage(self.context, output);
    }

    pub fn encode(self: Egress, target: OutputTarget, encoder: PacketEncoder) PacketAdmission {
        return self.vtable.encode(self.context, target, encoder);
    }

    pub fn stageFanout(self: Egress, targets: []const OutputTarget, payload: []const u8) PacketAdmission {
        return self.vtable.stage_fanout(self.context, targets, payload);
    }

    pub fn encodeFanout(self: Egress, targets: []const OutputTarget, encoder: PacketEncoder) PacketAdmission {
        return self.vtable.encode_fanout(self.context, targets, encoder);
    }

    pub fn flush(self: Egress) void {
        self.vtable.flush(self.context);
    }
};

pub const Ingress = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stage: *const fn (*anyopaque, CoreInput) bool,
    };

    pub fn stage(self: Ingress, input: CoreInput) bool {
        return self.vtable.stage(self.context, input);
    }
};

/// Routes one connection's input batch to its assigned Core ingress. Route slots
/// are fixed at compile time and deliberately use a linear bounded lookup: session
/// handles are sparse, so indexing storage by `Handle.index` would hide an
/// unbounded allocation behind the router.
///
/// The coordinator must obtain a quiescent token only after it has stopped
/// publishing this router and drained the affected Core exchange. `bind` and
/// `unbind` intentionally do not implement live ownership transfer. The optional
/// default ingress is selected once during Sessions-thread startup. It may claim
/// only a previously unbound batch carrying an attachment; it is not a fallback
/// for packet-only or detachment-only input.
pub fn InputRouter(comptime maximum_connections: usize) type {
    if (maximum_connections == 0) @compileError("an input router needs at least one connection slot");
    return struct {
        const Self = @This();
        const Slot = struct {
            occupied: bool = false,
            connection: connection.Handle = undefined,
            ingress: Ingress = undefined,
        };

        pub const Admission = enum { accepted, backpressured, unbound, mixed_connection, invalid_batch };
        pub const BindError = error{ AlreadyBound, CapacityFull };
        pub const UnbindError = error{NotBound};
        pub const Quiescent = struct { router: *Self };

        slots: [maximum_connections]Slot = @splat(.{}),
        default_ingress: ?Ingress,

        /// The Sessions thread owns publication and route mutation. `default`
        /// is a startup policy for newly attached connections, not a live
        /// balancing mechanism; transfer commands and acknowledgements belong
        /// to a future coordinator protocol.
        pub fn init(default: ?Ingress) Self {
            return .{ .default_ingress = default };
        }

        /// This token records the coordinator-side quiescence boundary. It is not
        /// a lock; the coordinator remains the sole publisher and sole route owner.
        pub fn quiescent(self: *Self) Quiescent {
            return .{ .router = self };
        }

        /// Adapter for Sessions' per-connection publication callback. Only an
        /// accepted batch returns true; every other admission leaves it held by
        /// Sessions for a later attempt.
        pub fn ingress(self: *Self) Ingress {
            return .{ .context = self, .vtable = &.{ .stage = stage } };
        }

        pub fn bind(token: *Quiescent, handle: connection.Handle, target: Ingress) BindError!void {
            const self = token.router;
            var free: ?*Slot = null;
            for (&self.slots) |*slot| {
                if (slot.occupied) {
                    if (slot.connection.eql(handle)) return error.AlreadyBound;
                } else if (free == null) free = slot;
            }
            const slot = free orelse return error.CapacityFull;
            slot.* = .{ .occupied = true, .connection = handle, .ingress = target };
        }

        pub fn unbind(token: *Quiescent, handle: connection.Handle) UnbindError!void {
            const self = token.router;
            for (&self.slots) |*slot| {
                if (slot.occupied and slot.connection.eql(handle)) {
                    slot.* = .{};
                    return;
                }
            }
            return error.NotBound;
        }

        /// Publishes exactly once after validating the entire per-connection
        /// batch. A backpressured ingress has not received any part of the batch:
        /// InputProducer plans all records/pages before publication, so callers may
        /// retry the unchanged batch without duplicate fragments.
        pub fn publish(self: *Self, input: CoreInput) Admission {
            if (input.packet_claimed.len != input.packet_views.len) return .invalid_batch;
            const handle = batchConnection(input) orelse return .accepted;
            if (!sameConnection(input, handle)) return .mixed_connection;
            for (&self.slots) |*slot| {
                if (slot.occupied and slot.connection.eql(handle))
                    return if (slot.ingress.stage(input)) .accepted else .backpressured;
            }
            if (input.attachments.len == 0) return .unbound;
            const target = self.default_ingress orelse return .unbound;
            const slot = self.firstFreeSlot() orelse return .unbound;
            // Assignment precedes staging. If staging is backpressured, the
            // caller retries the exact batch through this same ingress.
            slot.* = .{ .occupied = true, .connection = handle, .ingress = target };
            return if (target.stage(input)) .accepted else .backpressured;
        }

        fn firstFreeSlot(self: *Self) ?*Slot {
            for (&self.slots) |*slot| if (!slot.occupied) return slot;
            return null;
        }

        fn stage(raw: *anyopaque, input: CoreInput) bool {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.publish(input) == .accepted;
        }

        fn batchConnection(input: CoreInput) ?connection.Handle {
            if (input.attachments.len != 0) return input.attachments[0].connection;
            if (input.detachments.len != 0) return input.detachments[0].connection;
            if (input.packet_views.len != 0) return input.packet_views[0].connection;
            return null;
        }

        fn sameConnection(input: CoreInput, handle: connection.Handle) bool {
            for (input.attachments) |value| if (!value.connection.eql(handle)) return false;
            for (input.detachments) |value| if (!value.connection.eql(handle)) return false;
            for (input.packet_views) |value| if (!value.connection.eql(handle)) return false;
            return true;
        }
    };
}

pub const InputDrain = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { drain: *const fn (*anyopaque, *Inbox) bool };
    pub fn drain(self: InputDrain, inbox: *Inbox) bool {
        return self.vtable.drain(self.context, inbox);
    }
};

pub fn InputConsumer(comptime ExchangeType: type) type {
    return struct {
        const Self = @This();
        exchange: *ExchangeType,
        pub fn init(exchange: *ExchangeType) Self {
            return .{ .exchange = exchange };
        }
        pub fn inputDrain(self: *Self) InputDrain {
            return .{ .context = self, .vtable = &.{ .drain = drainInput } };
        }
        fn drainInput(raw: *anyopaque, inbox: *Inbox) bool {
            const self: *Self = @ptrCast(@alignCast(raw));
            inbox.clear();
            var remaining = self.exchange.to_core.pendingMessages();
            while (remaining != 0) {
                const first = self.exchange.to_core.peek(0).?;
                var count: usize = 1;
                switch (first.kind) {
                    .attached => if (inbox.attachment_count == inbox.attachments.len) break,
                    .detached => if (inbox.detachment_count == inbox.detachments.len or inbox.packet_count != 0 or inbox.attachment_count != 0) break,
                    .input => {
                        if (first.fragment != .whole and first.fragment != .begin) return false;
                        const total = if (first.fragment == .whole) first.len else first.total_len;
                        if (total < 13 or total - 13 > inbox.bytes.len or inbox.packets.len == 0) return false;
                        if (inbox.packet_count == inbox.packets.len or total - 13 > inbox.bytes.len - inbox.byte_count) break;
                        if (first.fragment == .begin) {
                            var bytes: usize = first.len;
                            if (bytes >= total) return false;
                            while (count < remaining) : (count += 1) {
                                const next = self.exchange.to_core.peek(count).?;
                                if (next.kind != .input or !next.connection.eql(first.connection) or
                                    next.total_len != total or next.len > total - bytes) return false;
                                bytes += next.len;
                                if (next.fragment == .end) {
                                    if (bytes != total) return false;
                                    count += 1;
                                    break;
                                }
                                if (next.fragment != .continuation or bytes >= total) return false;
                            }
                            if (bytes != total) break;
                        }
                    },
                }
                for (0..count) |_| {
                    const message = self.exchange.to_core.receive().?;
                    const ok = inbox.consume(message, self.exchange.to_core.consumerBytes(message));
                    const released = self.exchange.to_core.release(message);
                    if (!ok) {
                        std.log.err("event=session_input_decode_failed kind={s} fragment={s} len={d} total={d} packets={d}/{d} bytes={d}/{d}", .{
                            @tagName(message.kind),
                            @tagName(message.fragment),
                            message.len,
                            message.total_len,
                            inbox.packet_count,
                            inbox.packets.len,
                            inbox.byte_count,
                            inbox.bytes.len,
                        });
                    }
                    if (!released) std.log.err("event=session_input_release_failed", .{});
                    if (!released or !ok) return false;
                }
                remaining -= count;
            }
            return true;
        }
    };
}

pub fn InputProducer(comptime ExchangeType: type) type {
    return struct {
        const Self = @This();
        exchange: *ExchangeType,

        pub fn init(exchange: *ExchangeType) Self {
            return .{ .exchange = exchange };
        }
        pub fn ingress(self: *Self) Ingress {
            return .{ .context = self, .vtable = &.{ .stage = stage } };
        }

        fn stage(raw: *anyopaque, input: CoreInput) bool {
            const self: *Self = @ptrCast(@alignCast(raw));
            const page_bytes = @TypeOf(self.exchange.to_core).capacity_bytes;
            if ((input.attachments.len != 0 and page_bytes < 46) or
                (input.detachments.len != 0 and page_bytes < 9)) return false;
            var plan = self.exchange.to_core.planner();
            for (input.attachments) |_| if (!plan.record(46)) return false;
            for (input.packet_views) |value| if (!plan.stream(13 + value.bytes.len)) return false;
            for (input.detachments) |_| if (!plan.record(9)) return false;
            for (input.attachments) |value| if (!self.put(.attached, value.connection, encodeAttach, &value)) return false;
            for (input.packet_views) |value| if (!self.putPacket(value)) return false;
            for (input.detachments) |value| if (!self.put(.detached, value.connection, encodeDetach, &value)) return false;
            return true;
        }

        fn putPacket(self: *Self, value: PacketView) bool {
            const total = 13 + value.bytes.len;
            var offset: usize = 0;
            while (offset != total) {
                const page = self.exchange.to_core.acquire() orelse unreachable;
                const destination = self.exchange.to_core.producerBytes(page);
                const length = @min(destination.len, total - offset);
                if (offset < 13) {
                    var header: [13]u8 = undefined;
                    encodePacketHeader(&header, value);
                    const head = @min(length, 13 - offset);
                    @memcpy(destination[0..head], header[offset..][0..head]);
                    if (length > head) @memcpy(destination[head..length], value.bytes[0 .. length - head]);
                } else @memcpy(destination[0..length], value.bytes[offset - 13 ..][0..length]);
                const fragment: session_exchange.Fragment = if (offset == 0 and length == total)
                    .whole
                else if (offset == 0)
                    .begin
                else if (offset + length == total)
                    .end
                else
                    .continuation;
                std.debug.assert(self.exchange.to_core.submit(.{ .connection = value.connection, .kind = .input, .fragment = fragment, .total_len = @intCast(total), .page = page, .len = @intCast(length) }));
                offset += length;
            }
            return true;
        }

        fn put(self: *Self, kind: session_exchange.ToCoreKind, handle: connection.Handle, comptime encode: anytype, value: anytype) bool {
            const page = self.exchange.to_core.acquireFor(if (kind == .attached) 46 else 9) orelse return false;
            const bytes = self.exchange.to_core.producerBytes(page);
            const len = encode(bytes, value) orelse unreachable;
            return self.exchange.to_core.submit(.{ .connection = handle, .kind = kind, .page = page, .len = @intCast(len) });
        }
    };
}

fn encodeAttach(bytes: []u8, value: *const AttachPlayer) ?usize {
    if (bytes.len < 46) return null;
    std.mem.writeInt(u32, bytes[0..4], value.connection.index, .little);
    std.mem.writeInt(u32, bytes[4..8], value.connection.generation, .little);
    std.mem.writeInt(u128, bytes[8..24], value.uuid, .little);
    std.mem.writeInt(i32, bytes[24..28], value.protocol, .little);
    @memcpy(bytes[28..44], &value.name);
    bytes[44] = value.name_len;
    bytes[45] = @intFromBool(value.reconfiguring);
    return 46;
}

fn encodeDetach(bytes: []u8, value: *const DetachPlayer) ?usize {
    if (bytes.len < 9) return null;
    std.mem.writeInt(u32, bytes[0..4], value.connection.index, .little);
    std.mem.writeInt(u32, bytes[4..8], value.connection.generation, .little);
    bytes[8] = @intFromEnum(value.reason);
    return 9;
}

fn encodePacketHeader(bytes: *[13]u8, value: PacketView) void {
    bytes[0] = @intFromEnum(value.phase);
    std.mem.writeInt(i32, bytes[1..5], value.protocol, .little);
    std.mem.writeInt(i32, bytes[5..9], value.id, .little);
    std.mem.writeInt(i32, bytes[9..13], if (value.player) |player| @intCast(player) else -1, .little);
}

fn encodePacket(bytes: []u8, value: *const PacketView) ?usize {
    const header_len = 13;
    if (bytes.len < header_len + value.bytes.len) return null;
    var header: [header_len]u8 = undefined;
    encodePacketHeader(&header, value.*);
    @memcpy(bytes[0..header_len], &header);
    @memcpy(bytes[header_len..][0..value.bytes.len], value.bytes);
    return header_len + value.bytes.len;
}

pub const Inbox = struct {
    attachments: []AttachPlayer,
    detachments: []DetachPlayer,
    packets: []PacketView,
    claimed: []bool,
    bytes: []u8,
    attachment_count: usize = 0,
    detachment_count: usize = 0,
    packet_count: usize = 0,
    byte_count: usize = 0,
    packet_header: [13]u8 = undefined,
    packet_header_len: usize = 0,
    packet_total: usize = 0,
    packet_start: usize = 0,
    packet_received: usize = 0,
    packet_connection: ?connection.Handle = null,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, byte_capacity: usize) !Inbox {
        const attachments = try allocator.alloc(AttachPlayer, capacity);
        errdefer allocator.free(attachments);
        const detachments = try allocator.alloc(DetachPlayer, capacity);
        errdefer allocator.free(detachments);
        const packets = try allocator.alloc(PacketView, capacity);
        errdefer allocator.free(packets);
        const claimed = try allocator.alloc(bool, capacity);
        errdefer allocator.free(claimed);
        return .{ .attachments = attachments, .detachments = detachments, .packets = packets, .claimed = claimed, .bytes = try allocator.alloc(u8, byte_capacity) };
    }

    pub fn clear(self: *Inbox) void {
        self.attachment_count = 0;
        self.detachment_count = 0;
        self.packet_count = 0;
        self.byte_count = 0;
        self.packet_header_len = 0;
        self.packet_total = 0;
        self.packet_start = 0;
        self.packet_received = 0;
        self.packet_connection = null;
    }

    pub fn consume(self: *Inbox, message: SessionToCore, source: []const u8) bool {
        if (source.len != message.len) return false;
        return switch (message.kind) {
            .attached => self.decodeAttach(source),
            .detached => self.decodeDetach(source),
            .input => self.decodePacketFragment(message, source),
        };
    }

    pub fn input(self: *const Inbox) CoreInput {
        return .{ .attachments = self.attachments[0..self.attachment_count], .detachments = self.detachments[0..self.detachment_count], .packet_views = self.packets[0..self.packet_count], .packet_claimed = self.claimed[0..self.packet_count] };
    }

    fn decodeAttach(self: *Inbox, bytes: []const u8) bool {
        if (bytes.len != 46 or self.attachment_count == self.attachments.len or bytes[44] > 16 or bytes[45] > 1) return false;
        const value = &self.attachments[self.attachment_count];
        value.* = .{ .connection = .{ .index = std.mem.readInt(u32, bytes[0..4], .little), .generation = std.mem.readInt(u32, bytes[4..8], .little) }, .uuid = std.mem.readInt(u128, bytes[8..24], .little), .protocol = std.mem.readInt(i32, bytes[24..28], .little), .name = undefined, .name_len = bytes[44], .reconfiguring = bytes[45] != 0 };
        @memcpy(&value.name, bytes[28..44]);
        self.attachment_count += 1;
        return true;
    }

    fn decodeDetach(self: *Inbox, bytes: []const u8) bool {
        if (bytes.len != 9 or self.detachment_count == self.detachments.len) return false;
        if (bytes[8] > @intFromEnum(connection.DisconnectReason.kicked)) return false;
        const reason: connection.DisconnectReason = @enumFromInt(bytes[8]);
        self.detachments[self.detachment_count] = .{ .connection = .{ .index = std.mem.readInt(u32, bytes[0..4], .little), .generation = std.mem.readInt(u32, bytes[4..8], .little) }, .reason = reason };
        self.detachment_count += 1;
        return true;
    }

    fn decodePacket(self: *Inbox, handle: connection.Handle, bytes: []const u8) bool {
        if (bytes.len < 13 or self.packet_count == self.packets.len) return false;
        if (bytes[0] > @intFromEnum(Phase.play)) return false;
        const phase: Phase = @enumFromInt(bytes[0]);
        const payload = bytes[13..];
        if (payload.len > self.bytes.len - self.byte_count) return false;
        @memcpy(self.bytes[self.byte_count..][0..payload.len], payload);
        const player = std.mem.readInt(i32, bytes[9..13], .little);
        self.packets[self.packet_count] = .{ .connection = handle, .protocol = std.mem.readInt(i32, bytes[1..5], .little), .phase = phase, .id = std.mem.readInt(i32, bytes[5..9], .little), .bytes = self.bytes[self.byte_count..][0..payload.len], .player = if (player < 0) null else @intCast(player) };
        self.claimed[self.packet_count] = false;
        self.packet_count += 1;
        self.byte_count += payload.len;
        return true;
    }

    fn decodePacketFragment(self: *Inbox, message: SessionToCore, bytes: []const u8) bool {
        if (message.fragment == .whole) return self.decodePacket(message.connection, bytes);
        if (message.fragment == .begin) {
            if (self.packet_connection != null or message.total_len < 13 or message.total_len - 13 > self.bytes.len - self.byte_count) return false;
            self.packet_total = message.total_len;
            self.packet_connection = message.connection;
            self.packet_start = self.byte_count;
            self.packet_received = 0;
            self.packet_header_len = @min(bytes.len, 13);
            @memcpy(self.packet_header[0..self.packet_header_len], bytes[0..self.packet_header_len]);
            if (bytes.len > self.packet_header_len) @memcpy(self.bytes[self.byte_count..][0 .. bytes.len - self.packet_header_len], bytes[self.packet_header_len..]);
            const payload = bytes.len - self.packet_header_len;
            self.byte_count += payload;
            self.packet_received += payload;
            return true;
        }
        const handle = self.packet_connection orelse return false;
        if (!handle.eql(message.connection) or message.total_len != self.packet_total) return false;
        const header = @min(bytes.len, 13 - self.packet_header_len);
        @memcpy(self.packet_header[self.packet_header_len..][0..header], bytes[0..header]);
        self.packet_header_len += header;
        const payload = bytes[header..];
        if (payload.len > self.packet_total - 13 - self.packet_received) return false;
        @memcpy(self.bytes[self.byte_count..][0..payload.len], payload);
        self.byte_count += payload.len;
        self.packet_received += payload.len;
        if (message.fragment == .continuation) return true;
        if (message.fragment != .end or self.packet_header_len != 13 or self.packet_received != self.packet_total - 13 or self.packet_count == self.packets.len) return false;
        if (self.packet_header[0] > @intFromEnum(Phase.play)) return false;
        const player = std.mem.readInt(i32, self.packet_header[9..13], .little);
        self.packets[self.packet_count] = .{ .connection = handle, .protocol = std.mem.readInt(i32, self.packet_header[1..5], .little), .phase = @enumFromInt(self.packet_header[0]), .id = std.mem.readInt(i32, self.packet_header[5..9], .little), .bytes = self.bytes[self.packet_start..self.byte_count], .player = if (player < 0) null else @intCast(player) };
        self.claimed[self.packet_count] = false;
        self.packet_count += 1;
        self.packet_connection = null;
        self.packet_header_len = 0;
        self.packet_total = 0;
        self.packet_start = 0;
        self.packet_received = 0;
        return true;
    }
};

pub fn OutputProducer(comptime ExchangeType: type) type {
    return struct {
        const Self = @This();

        exchange: *ExchangeType,

        pub fn init(exchange: *ExchangeType) Self {
            return .{ .exchange = exchange };
        }

        pub fn egress(self: *Self) Egress {
            return .{ .context = self, .vtable = &.{ .stage = stage, .stage_fanout = stageFanout, .encode = encode, .encode_fanout = encodeFanout, .flush = flush } };
        }

        fn flush(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.exchange.to_sessions.flush();
        }

        fn stage(raw: *anyopaque, output: Output) PacketAdmission {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (output.payload.len == 0 or output.payload.len > @TypeOf(self.exchange.to_sessions).capacity_bytes)
                return .wrong_protocol;
            const page = self.exchange.to_sessions.acquireFor(output.payload.len) orelse return .backpressured;
            @memcpy(self.exchange.to_sessions.producerBytes(page)[0..output.payload.len], output.payload);
            std.debug.assert(self.exchange.to_sessions.submit(.{
                .connection = output.connection,
                .kind = .packet,
                .protocol = output.protocol.value,
                .phase = @intFromEnum(output.phase),
                .delivery_class = @intFromEnum(output.class),
                .delivery_policy = @intFromEnum(output.policy),
                .fragment = .whole,
                .total_len = @intCast(output.payload.len),
                .page = page,
                .len = @intCast(output.payload.len),
            }));
            _ = self.exchange.copied_payload_bytes.fetchAdd(@intCast(output.payload.len), .monotonic);
            return .accepted;
        }

        fn stageFanout(raw: *anyopaque, targets: []const OutputTarget, payload: []const u8) PacketAdmission {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (targets.len == 0 or targets.len > std.math.maxInt(u16) or payload.len == 0 or
                payload.len > @TypeOf(self.exchange.to_sessions).capacity_bytes) return .wrong_protocol;
            const first = targets[0];
            for (targets[1..]) |target| if (!target.protocol.eql(first.protocol) or target.phase != first.phase or
                target.class != first.class or target.policy != first.policy) return .wrong_protocol;
            if (!self.exchange.to_sessions.canSubmit(targets.len, payload.len)) return .backpressured;
            const page = self.exchange.to_sessions.acquireFor(payload.len) orelse return .backpressured;
            const offset = self.exchange.to_sessions.producerOffset(page);
            @memcpy(self.exchange.to_sessions.producerBytes(page)[0..payload.len], payload);
            for (targets, 0..) |target, index| {
                const message: session_exchange.Outbound = .{
                    .connection = target.connection,
                    .kind = .packet_shared,
                    .protocol = first.protocol.value,
                    .phase = @intFromEnum(first.phase),
                    .delivery_class = @intFromEnum(first.class),
                    .delivery_policy = @intFromEnum(first.policy),
                    .fragment = .whole,
                    .total_len = @intCast(payload.len),
                    .recipient_count = @intCast(targets.len),
                    .page = page,
                    .len = @intCast(payload.len),
                };
                const submitted = if (index == 0)
                    self.exchange.to_sessions.submit(message)
                else
                    self.exchange.to_sessions.submitReference(message, offset);
                std.debug.assert(submitted);
            }
            _ = self.exchange.copied_payload_bytes.fetchAdd(@intCast(payload.len), .monotonic);
            _ = self.exchange.fanout_deliveries.fetchAdd(@intCast(targets.len), .monotonic);
            return .accepted;
        }

        fn encode(raw: *anyopaque, target: OutputTarget, encoder: PacketEncoder) PacketAdmission {
            const self: *Self = @ptrCast(@alignCast(raw));
            var page = self.exchange.to_sessions.acquire() orelse return .backpressured;
            var destination = self.exchange.to_sessions.producerBytes(page);
            var encoded = encoder.encode(encoder.context, target.protocol, destination);
            if (encoded == null and destination.len != @TypeOf(self.exchange.to_sessions).capacity_bytes) {
                self.exchange.to_sessions.flush();
                page = self.exchange.to_sessions.acquireFor(@TypeOf(self.exchange.to_sessions).capacity_bytes) orelse return .backpressured;
                destination = self.exchange.to_sessions.producerBytes(page);
                encoded = encoder.encode(encoder.context, target.protocol, destination);
            }
            const payload = (encoded orelse return .wrong_protocol).payload;
            const begin = @intFromPtr(destination.ptr);
            const payload_begin = @intFromPtr(payload.ptr);
            if (payload.len == 0 or payload_begin != begin or payload.len > destination.len)
                return .wrong_protocol;
            const submitted = self.exchange.to_sessions.submit(.{
                .connection = target.connection,
                .kind = .packet,
                .protocol = target.protocol.value,
                .phase = @intFromEnum(target.phase),
                .delivery_class = @intFromEnum(target.class),
                .delivery_policy = @intFromEnum(target.policy),
                .fragment = .whole,
                .total_len = @intCast(payload.len),
                .page = page,
                .len = @intCast(payload.len),
            });
            std.debug.assert(submitted);
            _ = self.exchange.direct_payload_bytes.fetchAdd(@intCast(payload.len), .monotonic);
            return .accepted;
        }

        fn encodeFanout(raw: *anyopaque, targets: []const OutputTarget, encoder: PacketEncoder) PacketAdmission {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (targets.len == 0 or targets.len > std.math.maxInt(u16)) return .wrong_protocol;
            const first = targets[0];
            for (targets[1..]) |target| {
                if (!target.protocol.eql(first.protocol) or target.phase != first.phase or
                    target.class != first.class or target.policy != first.policy) return .wrong_protocol;
            }
            if (!self.exchange.to_sessions.canSubmit(targets.len, 1)) return .backpressured;
            var page = self.exchange.to_sessions.acquire() orelse return .backpressured;
            var destination = self.exchange.to_sessions.producerBytes(page);
            var encoded = encoder.encode(encoder.context, first.protocol, destination);
            if (encoded == null and destination.len != @TypeOf(self.exchange.to_sessions).capacity_bytes) {
                self.exchange.to_sessions.flush();
                page = self.exchange.to_sessions.acquireFor(@TypeOf(self.exchange.to_sessions).capacity_bytes) orelse return .backpressured;
                destination = self.exchange.to_sessions.producerBytes(page);
                encoded = encoder.encode(encoder.context, first.protocol, destination);
            }
            const payload = (encoded orelse return .wrong_protocol).payload;
            if (payload.len == 0 or payload.ptr != destination.ptr or payload.len > destination.len)
                return .wrong_protocol;
            const offset = self.exchange.to_sessions.producerOffset(page);
            for (targets, 0..) |target, index| {
                const output: session_exchange.Outbound = .{
                    .connection = target.connection,
                    .kind = .packet_shared,
                    .protocol = first.protocol.value,
                    .phase = @intFromEnum(first.phase),
                    .delivery_class = @intFromEnum(first.class),
                    .delivery_policy = @intFromEnum(first.policy),
                    .fragment = .whole,
                    .total_len = @intCast(payload.len),
                    .recipient_count = @intCast(targets.len),
                    .page = page,
                    .len = @intCast(payload.len),
                };
                const submitted = if (index == 0)
                    self.exchange.to_sessions.submit(output)
                else
                    self.exchange.to_sessions.submitReference(output, offset);
                std.debug.assert(submitted);
            }
            _ = self.exchange.fanout_payload_bytes.fetchAdd(@intCast(payload.len), .monotonic);
            _ = self.exchange.fanout_deliveries.fetchAdd(@intCast(targets.len), .monotonic);
            return .accepted;
        }
    };
}

pub const InputAdmission = enum { accepted, full };
pub const AttachPlayer = struct {
    connection: connection.Handle,
    uuid: u128,
    protocol: i32,
    name: [16]u8,
    name_len: u8,
    reconfiguring: bool,
};
pub const DetachPlayer = struct { connection: connection.Handle, reason: connection.DisconnectReason };
pub const Text = struct { offset: u32, len: u16 };

pub const Input = union(enum) {
    teleport_confirm: struct { player: u16, id: i32 },
    movement: struct {
        player: u16,
        position: ?geometry.Vec3,
        rotation: ?geometry.Rotation,
        on_ground: bool,
    },
    player_input: struct { player: u16, shift: bool, sprint: bool },
    sprint: struct { player: u16, sprinting: bool },
    dig: DigInput,
    place: PlaceInput,
    held_item: struct { player: u16, selected: i16 },
    keep_alive_response: struct { player: u16, id: i64 },
    chunk_batch_received: struct { player: u16, chunks_per_tick: f32 },
    player_loaded: struct { player: u16 },
    chat: struct { player: u16, text: Text },
    command: struct { player: u16, text: Text },
    arm_animation: struct { player: u16, hand: i32 },
    attack_entity: struct { player: u16, entity_id: i32 },
    interact_entity: struct { player: u16, entity_id: i32, hand: i32 },
    respawn: struct { player: u16 },
    use_item: struct { player: u16, hand: i32, sequence: i32, rotation: geometry.Rotation },
    window_click: WindowClickInput,
    creative_slot: CreativeSlotInput,
    close_window: struct { player: u16, window_id: i32 },
};

pub const DigInput = struct { player: u16, status: i32, position: geometry.BlockPos, face: i32, sequence: i32 };
pub const PlaceKind = enum(u8) { break_block, use_item_on };
pub const PlaceInput = struct {
    world: world_identity.Handle,
    player: u16,
    kind: PlaceKind,
    position: geometry.BlockPos,
    against_position: geometry.BlockPos,
    face: i32,
    cursor: struct { x: f32, y: f32, z: f32 },
    sequence: i32,
};
pub const WindowClickInput = struct {
    player: u16,
    window_id: i32,
    state_id: i32,
    protocol_slot: i16,
    mouse_button: i8,
    mode: i32,
};
pub const CreativeSlotInput = struct { player: u16, inventory_slot: i16, item_id: i32, count: u8 };

pub const InputBatch = struct {
    records: []Input,
    count: usize = 0,
    bytes: []u8,
    byte_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, byte_capacity: usize) !InputBatch {
        if (capacity == 0 or byte_capacity == 0) return error.InvalidCapacity;
        const records = try allocator.alloc(Input, capacity);
        errdefer allocator.free(records);
        return .{ .records = records, .bytes = try allocator.alloc(u8, byte_capacity) };
    }

    pub fn deinit(self: *InputBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn clear(self: *InputBatch) void {
        self.count = 0;
        self.byte_count = 0;
    }

    pub fn append(self: *InputBatch, input: Input) InputAdmission {
        if (self.count == self.records.len) return .full;
        self.records[self.count] = input;
        self.count += 1;
        return .accepted;
    }

    pub fn items(self: *const InputBatch) []const Input {
        return self.records[0..self.count];
    }

    pub fn copyText(self: *InputBatch, value: []const u8) error{ByteFull}!Text {
        if (value.len > std.math.maxInt(u16) or value.len > self.bytes.len - self.byte_count) return error.ByteFull;
        const offset = self.byte_count;
        @memcpy(self.bytes[offset..][0..value.len], value);
        self.byte_count += value.len;
        return .{ .offset = @intCast(offset), .len = @intCast(value.len) };
    }

    pub fn text(self: *const InputBatch, value: Text) []const u8 {
        const start: usize = value.offset;
        const end = start + value.len;
        std.debug.assert(end <= self.byte_count);
        return self.bytes[start..end];
    }
};

pub const PacketView = struct {
    connection: connection.Handle,
    protocol: i32,
    phase: Phase = .play,
    id: i32,
    bytes: []const u8,
    player: ?u16 = null,
    ticket: u16 = 0,
};

pub const CoreInput = struct {
    attachments: []const AttachPlayer,
    detachments: []const DetachPlayer,
    packet_views: []const PacketView,
    packet_claimed: []bool,
};

test "canonical input is bounded and ordered" {
    var storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var batch = try InputBatch.init(fixed.allocator(), 2, 64);
    try std.testing.expectEqual(InputAdmission.accepted, batch.append(.{ .sprint = .{ .player = 1, .sprinting = true } }));
    try std.testing.expectEqual(InputAdmission.accepted, batch.append(.{ .player_input = .{ .player = 1, .shift = false, .sprint = false } }));
    try std.testing.expectEqual(InputAdmission.full, batch.append(.{ .sprint = .{ .player = 2, .sprinting = false } }));
    try std.testing.expectEqual(@as(u16, 1), batch.items()[0].sprint.player);
}

test "canonical input owns bounded text until Core consumes it" {
    var storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var batch = try InputBatch.init(fixed.allocator(), 2, 8);
    const text = try batch.copyText("hello");
    try std.testing.expectEqual(InputAdmission.accepted, batch.append(.{ .chat = .{ .player = 7, .text = text } }));
    try std.testing.expectEqualStrings("hello", batch.text(batch.items()[0].chat.text));
    try std.testing.expectError(error.ByteFull, batch.copyText("more"));
}

test "output producer publishes one bounded packet record" {
    const TestExchange = SessionExchange(.{
        .to_core_pages = 1,
        .to_sessions_pages = 1,
        .to_core_page_bytes = 4,
        .to_sessions_page_bytes = 9,
        .to_core_messages = 1,
        .to_sessions_messages = 1,
    });
    var exchange = TestExchange{};
    exchange.initialize();
    var producer = OutputProducer(TestExchange).init(&exchange);
    try std.testing.expectEqual(PacketAdmission.accepted, producer.egress().stage(.{
        .connection = .{ .index = 2, .generation = 1 },
        .protocol = .{ .value = 772 },
        .phase = .play,
        .class = .chunks,
        .policy = .reliable,
        .payload = "abcdefghi",
    }));
    const message = exchange.to_sessions.receive().?;
    try std.testing.expectEqual(session_exchange.Fragment.whole, message.fragment);
    try std.testing.expectEqualStrings("abcdefghi", exchange.to_sessions.consumerBytes(message));
    try std.testing.expect(exchange.to_sessions.release(message));
}

test "input detachment follows the tick consuming its final packets" {
    const TestExchange = SessionExchange(.{ .to_core_pages = 4, .to_sessions_pages = 1, .to_core_page_bytes = 64, .to_sessions_page_bytes = 64, .to_core_messages = 4, .to_sessions_messages = 1 });
    var exchange = TestExchange{};
    exchange.initialize();
    var producer = InputProducer(TestExchange).init(&exchange);
    var consumer = InputConsumer(TestExchange).init(&exchange);
    const handle = connection.Handle{ .index = 3, .generation = 2 };
    const packets = [_]PacketView{.{ .connection = handle, .protocol = 772, .id = 7, .bytes = "last action" }};
    var claimed = [_]bool{false};
    try std.testing.expect(producer.ingress().stage(.{
        .attachments = &.{.{ .connection = handle, .protocol = 772, .uuid = 1, .name = @splat(0), .name_len = 0, .reconfiguring = false }},
        .packet_views = &packets,
        .packet_claimed = &claimed,
        .detachments = &.{.{ .connection = handle, .reason = .timeout }},
    }));
    var memory: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var inbox = try Inbox.init(fixed.allocator(), 4, 64);
    try std.testing.expect(consumer.inputDrain().drain(&inbox));
    try std.testing.expectEqual(@as(usize, 1), inbox.attachment_count);
    try std.testing.expectEqualStrings("last action", inbox.input().packet_views[0].bytes);
    try std.testing.expectEqual(@as(usize, 0), inbox.detachment_count);
    try std.testing.expectEqual(@as(usize, 1), exchange.to_core.pendingMessages());
    try std.testing.expect(consumer.inputDrain().drain(&inbox));
    try std.testing.expectEqual(@as(usize, 0), inbox.packet_count);
    try std.testing.expectEqual(@as(usize, 1), inbox.detachment_count);
    try std.testing.expect(inbox.detachments[0].connection.eql(handle));
    try std.testing.expectEqual(@as(usize, 0), exchange.to_core.pendingMessages());
}

test "input producer copies packet bytes into a Core-owned inbox" {
    const TestExchange = SessionExchange(.{ .to_core_pages = 1, .to_sessions_pages = 1, .to_core_page_bytes = 64, .to_sessions_page_bytes = 64, .to_core_messages = 1, .to_sessions_messages = 1 });
    var exchange = TestExchange{};
    exchange.initialize();
    var producer = InputProducer(TestExchange).init(&exchange);
    const packets = [_]PacketView{.{ .connection = .{ .index = 3, .generation = 2 }, .protocol = 772, .phase = .play, .id = 7, .bytes = "owned" }};
    var claimed = [_]bool{false};
    try std.testing.expect(producer.ingress().stage(.{ .attachments = &.{}, .detachments = &.{}, .packet_views = &packets, .packet_claimed = &claimed }));
    var memory: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var inbox = try Inbox.init(fixed.allocator(), 2, 64);
    const message = exchange.to_core.receive().?;
    try std.testing.expect(inbox.consume(message, exchange.to_core.consumerBytes(message)));
    try std.testing.expect(exchange.to_core.release(message));
    try std.testing.expectEqualStrings("owned", inbox.input().packet_views[0].bytes);
}

test "input fragmentation is atomic and preserves prior packet storage" {
    const TestExchange = SessionExchange(.{ .to_core_pages = 8, .to_sessions_pages = 1, .to_core_page_bytes = 16, .to_sessions_page_bytes = 16, .to_core_messages = 8, .to_sessions_messages = 1 });
    var exchange = TestExchange{};
    exchange.initialize();
    var producer = InputProducer(TestExchange).init(&exchange);
    var large: [80]u8 = undefined;
    for (&large, 0..) |*byte, index| byte.* = @intCast(index);
    const packets = [_]PacketView{
        .{ .connection = .{ .index = 1, .generation = 2 }, .protocol = 772, .id = 3, .bytes = "ab" },
        .{ .connection = .{ .index = 1, .generation = 2 }, .protocol = 772, .id = 4, .bytes = &large },
    };
    var claimed = [_]bool{ false, false };
    try std.testing.expect(producer.ingress().stage(.{ .attachments = &.{}, .detachments = &.{}, .packet_views = &packets, .packet_claimed = &claimed }));
    var memory: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var inbox = try Inbox.init(fixed.allocator(), 2, 128);
    var consumer = InputConsumer(TestExchange).init(&exchange);
    try std.testing.expect(consumer.inputDrain().drain(&inbox));
    try std.testing.expectEqualStrings("ab", inbox.input().packet_views[0].bytes);
    try std.testing.expectEqualSlices(u8, &large, inbox.input().packet_views[1].bytes);

    const Full = SessionExchange(.{ .to_core_pages = 2, .to_sessions_pages = 1, .to_core_page_bytes = 16, .to_sessions_page_bytes = 16, .to_core_messages = 2, .to_sessions_messages = 1 });
    var full = Full{};
    full.initialize();
    var blocked = InputProducer(Full).init(&full);
    try std.testing.expect(!blocked.ingress().stage(.{ .attachments = &.{}, .detachments = &.{}, .packet_views = packets[1..], .packet_claimed = claimed[1..] }));
    try std.testing.expect(full.to_core.receive() == null);
}

test "input drain retains pressure and incomplete publications without losing order" {
    for ([_]usize{ 1, 2 }) |capacity| {
        const TestExchange = SessionExchange(.{ .to_core_pages = 8, .to_sessions_pages = 1, .to_core_page_bytes = 46, .to_sessions_page_bytes = 16, .to_core_messages = 12, .to_sessions_messages = 1 });
        var exchange = TestExchange{};
        exchange.initialize();
        var producer = InputProducer(TestExchange).init(&exchange);
        var consumer = InputConsumer(TestExchange).init(&exchange);
        var memory: [1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&memory);
        var inbox = try Inbox.init(fixed.allocator(), capacity, 8);
        const handle = connection.Handle{ .index = 900, .generation = 7 };
        const packets = [_]PacketView{
            .{ .connection = handle, .protocol = 772, .id = 1, .bytes = "first" },
            .{ .connection = handle, .protocol = 772, .id = 2, .bytes = "second" },
        };
        const attached = AttachPlayer{ .connection = handle, .uuid = 1, .protocol = 772, .name = @splat(0), .name_len = 0, .reconfiguring = false };
        try std.testing.expect(producer.ingress().stage(.{ .attachments = &.{attached}, .detachments = &.{}, .packet_views = &packets, .packet_claimed = &.{} }));
        try std.testing.expect(consumer.inputDrain().drain(&inbox));
        try std.testing.expectEqual(@as(usize, 1), inbox.attachment_count);
        try std.testing.expectEqualStrings("first", inbox.input().packet_views[0].bytes);
        try std.testing.expect(exchange.to_core.pendingMessages() != 0);
        try std.testing.expect(consumer.inputDrain().drain(&inbox));
        try std.testing.expectEqualStrings("second", inbox.input().packet_views[0].bytes);
        try std.testing.expectEqual(@as(usize, 0), exchange.to_core.pendingMessages());

        var encoded: [21]u8 = undefined;
        const length = encodePacket(&encoded, &.{ .connection = handle, .protocol = 772, .id = 3, .bytes = "complete" }).?;
        const first = exchange.to_core.acquireFor(5).?;
        @memcpy(exchange.to_core.producerBytes(first)[0..5], encoded[0..5]);
        try std.testing.expect(exchange.to_core.submit(.{ .connection = handle, .kind = .input, .fragment = .begin, .total_len = @intCast(length), .page = first, .len = 5 }));
        for (0..3) |_| {
            try std.testing.expect(consumer.inputDrain().drain(&inbox));
            try std.testing.expectEqual(@as(usize, 0), inbox.packet_count);
            try std.testing.expectEqual(@as(usize, 1), exchange.to_core.pendingMessages());
        }
        const last = exchange.to_core.acquireFor(length - 5).?;
        @memcpy(exchange.to_core.producerBytes(last)[0 .. length - 5], encoded[5..length]);
        try std.testing.expect(exchange.to_core.submit(.{ .connection = handle, .kind = .input, .fragment = .end, .total_len = @intCast(length), .page = last, .len = @intCast(length - 5) }));
        try std.testing.expect(consumer.inputDrain().drain(&inbox));
        try std.testing.expectEqual(@as(i32, 3), inbox.input().packet_views[0].id);
        try std.testing.expectEqualStrings("complete", inbox.input().packet_views[0].bytes);
        try std.testing.expectEqual(@as(usize, 0), exchange.to_core.pendingMessages());
    }
}

test "input router uses bounded full-handle ownership and preserves backpressure retries" {
    const TestExchange = SessionExchange(.{ .to_core_pages = 1, .to_sessions_pages = 1, .to_core_page_bytes = 64, .to_sessions_page_bytes = 64, .to_core_messages = 1, .to_sessions_messages = 1 });
    const Router = InputRouter(2);
    var first = TestExchange{};
    var second = TestExchange{};
    first.initialize();
    second.initialize();
    var first_producer = InputProducer(TestExchange).init(&first);
    var second_producer = InputProducer(TestExchange).init(&second);
    var router = Router.init(null);
    var quiescent = router.quiescent();
    const original = connection.Handle{ .index = 80_000, .generation = 3 };
    const replacement = connection.Handle{ .index = 80_000, .generation = 4 };
    try Router.bind(&quiescent, original, first_producer.ingress());
    try std.testing.expectError(error.AlreadyBound, Router.bind(&quiescent, original, second_producer.ingress()));

    const attachment = AttachPlayer{ .connection = original, .uuid = 1, .protocol = 772, .name = @splat(0), .name_len = 0, .reconfiguring = false };
    const batch = CoreInput{ .attachments = &.{attachment}, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} };
    try std.testing.expectEqual(Router.Admission.accepted, router.publish(batch));
    try std.testing.expectEqual(Router.Admission.backpressured, router.publish(batch));
    try std.testing.expectEqual(@as(usize, 1), first.to_core.pendingMessages());
    try std.testing.expectEqual(@as(usize, 0), second.to_core.pendingMessages());
    const message = first.to_core.receive().?;
    try std.testing.expect(first.to_core.release(message));
    first.to_core.flush();
    try std.testing.expectEqual(Router.Admission.accepted, router.publish(batch));

    try std.testing.expectEqual(Router.Admission.unbound, router.publish(.{ .attachments = &.{.{ .connection = replacement, .uuid = 2, .protocol = 772, .name = @splat(0), .name_len = 0, .reconfiguring = false }}, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} }));
    try std.testing.expectError(error.NotBound, Router.unbind(&quiescent, replacement));
    try Router.unbind(&quiescent, original);
    try Router.bind(&quiescent, replacement, second_producer.ingress());
    const mixed = [_]AttachPlayer{ attachment, .{ .connection = replacement, .uuid = 2, .protocol = 772, .name = @splat(0), .name_len = 0, .reconfiguring = false } };
    try std.testing.expectEqual(Router.Admission.mixed_connection, router.publish(.{ .attachments = &mixed, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} }));
    try std.testing.expectEqual(@as(usize, 0), second.to_core.pendingMessages());
}

test "input router assigns its startup default only to a new attachment" {
    const TestExchange = SessionExchange(.{ .to_core_pages = 1, .to_sessions_pages = 1, .to_core_page_bytes = 64, .to_sessions_page_bytes = 64, .to_core_messages = 1, .to_sessions_messages = 1 });
    const Router = InputRouter(2);
    var first = TestExchange{};
    var second = TestExchange{};
    first.initialize();
    second.initialize();
    var first_producer = InputProducer(TestExchange).init(&first);
    var second_producer = InputProducer(TestExchange).init(&second);
    var router = Router.init(first_producer.ingress());
    const original = connection.Handle{ .index = 80_000, .generation = 3 };
    const replacement = connection.Handle{ .index = 80_000, .generation = 4 };
    const overflow = connection.Handle{ .index = 80_000, .generation = 5 };
    const attachment = AttachPlayer{ .connection = original, .uuid = 1, .protocol = 772, .name = @splat(0), .name_len = 0, .reconfiguring = false };
    const batch = CoreInput{ .attachments = &.{attachment}, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} };

    try std.testing.expectEqual(Router.Admission.accepted, router.publish(batch));
    try std.testing.expectEqual(Router.Admission.backpressured, router.publish(batch));
    try std.testing.expectEqual(@as(usize, 1), first.to_core.pendingMessages());
    try std.testing.expectEqual(@as(usize, 0), second.to_core.pendingMessages());
    const message = first.to_core.receive().?;
    try std.testing.expect(first.to_core.release(message));
    first.to_core.flush();
    try std.testing.expectEqual(Router.Admission.accepted, router.publish(batch));

    var quiescent = router.quiescent();
    try Router.bind(&quiescent, replacement, second_producer.ingress());
    var claimed = [_]bool{false};
    const packet = [_]PacketView{.{ .connection = replacement, .protocol = 772, .id = 1, .bytes = "bound" }};
    try std.testing.expectEqual(Router.Admission.accepted, router.publish(.{ .attachments = &.{}, .detachments = &.{}, .packet_views = &packet, .packet_claimed = &claimed }));
    try std.testing.expectEqual(@as(usize, 1), first.to_core.pendingMessages());
    try std.testing.expectEqual(@as(usize, 1), second.to_core.pendingMessages());

    var unknown_claimed = [_]bool{false};
    const unknown = [_]PacketView{.{ .connection = overflow, .protocol = 772, .id = 1, .bytes = "unknown" }};
    try std.testing.expectEqual(Router.Admission.unbound, router.publish(.{ .attachments = &.{}, .detachments = &.{}, .packet_views = &unknown, .packet_claimed = &unknown_claimed }));
    try std.testing.expectEqual(Router.Admission.unbound, router.publish(.{ .attachments = &.{}, .detachments = &.{.{ .connection = overflow, .reason = .peer_closed }}, .packet_views = &.{}, .packet_claimed = &.{} }));
    try std.testing.expectEqual(Router.Admission.unbound, router.publish(.{ .attachments = &.{.{ .connection = overflow, .uuid = 2, .protocol = 772, .name = @splat(0), .name_len = 0, .reconfiguring = false }}, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} }));
}
