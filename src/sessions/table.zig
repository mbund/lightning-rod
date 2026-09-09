const std = @import("std");
const exchange = @import("../transport_exchange.zig");
const api = @import("../session_api.zig");
const core_exchange = @import("../core_exchange.zig");
const session_exchange = @import("../session_exchange.zig");
const configuration = @import("../configuration_plan.zig");
const minecraft = @import("../minecraft_session.zig");
const crypto = @import("../crypto_support.zig");

const prepared_page_bytes = 16 * 1024;
const PreparedFrame = struct {
    pages: [25]u16 = @splat(0),
    page_count: u8 = 0,
    len: u32 = 0,
    references: u16 = 0,
    class: api.DeliveryClass = .other,
    shared_group: ?u16 = null,
    compression_threshold: ?i32 = null,
    occupied: bool = false,
};
const SharedGroup = struct {
    source: core_exchange.OutputSource = .{ .value = 0 },
    source_page: session_exchange.Page = @enumFromInt(0),
    source_offset: u32 = 0,
    remaining: u16 = 0,
    occupied: bool = false,
};
const ConnectionQueue = struct {
    head: u16 = 0,
    len: u16 = 0,
    bytes: u32 = 0,
    classes: [4]u16 = @splat(0),
};
const Delivery = struct {
    frame: u16,
    offset: u32 = 0,
};
const QueueMetrics = struct { frames: usize = 0, prepared: usize = 0, deliveries: usize = 0 };
pub fn Table(comptime capacity: usize, comptime batch_capacity: usize) type {
    if (capacity == 0 or batch_capacity == 0) @compileError("session capacities must be nonzero");
    return struct {
        const Self = @This();
        const status_bytes = 4096;
        const staged_output_bytes = @max(minecraft.Codec.max_state_bytes, batch_capacity * 8 * 1024);
        const prepared_page_count = (staged_output_bytes + prepared_page_bytes - 1) / prepared_page_bytes;
        const input_quota = @max(1, batch_capacity / capacity);
        sessions: [capacity]minecraft.Session = undefined,
        occupied: [capacity]bool = @splat(false),
        workspace: minecraft.Workspace = .{},
        protocols: []const minecraft.Protocol = &.{},
        configuration_plan: configuration.Plan = .{},
        configuration_plan_locked: bool = false,
        handshake_decoder: ?minecraft.HandshakeDecoder = null,
        authentication: ?api.Authentication = null,
        authentication_timeout_ns: u64 = 0,
        now_ns: u64 = 0,
        attachments: [batch_capacity]exchange.AttachPlayer = undefined,
        attachment_count: usize = 0,
        detachments: [batch_capacity]exchange.DetachPlayer = undefined,
        detachment_count: usize = 0,
        packet_views: [batch_capacity]core_exchange.PacketView = undefined,
        packet_claimed: [batch_capacity]bool = undefined,
        packet_view_count: usize = 0,
        /// A full connection handle owns every staged record and borrowed page
        /// for this slot until its per-connection publication is accepted.
        input_pending: [capacity]?exchange.Connection = @splat(null),
        /// A retained page may also contain a prefix borrowed by a pending packet
        /// view. This separate bit avoids holding unrelated partial input pages
        /// when a connection closes.
        retained_input_borrowed: [capacity]?exchange.Connection = @splat(null),
        held_pages: [batch_capacity]exchange.Page = undefined,
        held_connections: [batch_capacity]exchange.Connection = undefined,
        held_count: usize = 0,
        retained_cursor: usize = 0,
        status_cache: [capacity][status_bytes]u8 = undefined,
        status_cache_len: [capacity]u16 = @splat(0),
        status_cache_revision: [capacity]u64 = @splat(0),
        login_output_len: [capacity]u16 = @splat(0),
        login_output_encrypted: [capacity]bool = @splat(false),
        prepared_pages: [prepared_page_count][prepared_page_bytes]u8 = undefined,
        prepared_page_used: [prepared_page_count]bool = @splat(false),
        prepared_frames: [batch_capacity]PreparedFrame = @splat(.{}),
        shared_groups: [batch_capacity]SharedGroup = @splat(.{}),
        delivery_queues: [capacity]ConnectionQueue = @splat(.{}),
        deliveries: [capacity][batch_capacity]Delivery = undefined,
        delivery_cursor: usize = 0,
        packet_scratch: [minecraft.Codec.max_packet_bytes]u8 = undefined,
        encoding_scratch: [minecraft.Codec.max_packet_bytes + 16]u8 = undefined,
        compression_threshold: ?i32 = 256,
        accepting: bool = true,
        final_detachments_staged: bool = false,
        fatal_started: bool = false,
        fatal_encoded: [capacity]bool = @splat(false),
        prepared_copy_bytes: u64 = 0,
        transport_direct_bytes: u64 = 0,
        transport_fallback_copy_bytes: u64 = 0,

        pub fn initialize(self: *Self) void {
            @memset(&self.occupied, false);
            self.protocols = &.{};
            self.configuration_plan = .{};
            self.configuration_plan_locked = false;
            self.handshake_decoder = null;
            self.authentication = null;
            self.authentication_timeout_ns = 0;
            self.now_ns = 0;
            self.attachment_count = 0;
            self.detachment_count = 0;
            self.packet_view_count = 0;
            @memset(&self.packet_claimed, false);
            @memset(&self.input_pending, null);
            @memset(&self.retained_input_borrowed, null);
            self.held_count = 0;
            self.retained_cursor = 0;
            @memset(&self.status_cache_len, 0);
            @memset(&self.status_cache_revision, 0);
            @memset(&self.login_output_len, 0);
            @memset(&self.login_output_encrypted, false);
            @memset(&self.prepared_page_used, false);
            @memset(&self.prepared_frames, .{});
            @memset(&self.shared_groups, .{});
            @memset(&self.delivery_queues, .{});
            self.delivery_cursor = 0;
            self.accepting = true;
            self.final_detachments_staged = false;
            self.fatal_started = false;
            @memset(&self.fatal_encoded, false);
            self.prepared_copy_bytes = 0;
            self.transport_direct_bytes = 0;
            self.transport_fallback_copy_bytes = 0;
        }

        pub fn setProtocols(self: *Self, protocols: []const minecraft.Protocol) bool {
            if (protocols.len > batch_capacity) return false;
            self.protocols = protocols;
            return true;
        }

        pub fn setConfigurationPlan(self: *Self, plan: configuration.Plan) bool {
            if (!plan.valid() or self.configuration_plan_locked) return false;
            self.configuration_plan = plan;
            return true;
        }

        pub fn setAuthentication(self: *Self, authentication: ?api.Authentication, timeout_ns: u64) void {
            self.authentication = authentication;
            self.authentication_timeout_ns = timeout_ns;
        }

        pub fn setCompressionThreshold(self: *Self, threshold: ?i32) bool {
            if (threshold) |value| if (value < 0) return false;
            self.compression_threshold = threshold;
            return true;
        }

        pub fn setHandshakeDecoder(self: *Self, decoder: minecraft.HandshakeDecoder) void {
            self.handshake_decoder = decoder;
        }

        pub fn interface(self: *Self) api.Sessions {
            return .{
                .context = self,
                .vtable = &sessions_vtable,
                .readiness = if (self.authentication) |authentication| authentication.readiness else null,
            };
        }

        /// Bind this consumer to its independent Core exchange source. Its page
        /// pool may reuse every page and offset value used by another exchange.
        pub fn coreOutputConsumer(self: *Self, source: core_exchange.OutputSource) api.CoreOutputConsumer {
            return .{ .context = self, .vtable = &.{ .consume = consumeCoreOutputApi }, .source = source };
        }

        pub fn stopAccepting(self: *Self) void {
            self.accepting = false;
        }

        pub fn advanceReconfigurationWithTransport(self: *Self, transport: exchange.Transport) api.Admission {
            self.accepting = false;
            for (&self.sessions, self.occupied, 0..) |*item, occupied, index| {
                if (!occupied) continue;
                if (item.phase != .play) {
                    if (item.phase == .configuration and !item.attached) {
                        transport.vtable.close(transport.context, item.connection, .kicked);
                        self.occupied[index] = false;
                        continue;
                    }
                    if (item.phase == .configuration and item.attached) {
                        item.configuration_step = 0;
                        item.configuration_barrier = true;
                        continue;
                    }
                    if (item.authentication_pending or item.authentication_challenged) {
                        if (self.authentication) |auth| auth.vtable.cancel(auth.context, item.connection);
                        item.authentication_pending = false;
                        item.authentication_challenged = false;
                    }
                    transport.vtable.close(transport.context, item.connection, .kicked);
                    continue;
                }
                const codec = item.codec orelse return .unsupported;
                const len = codec.vtable.start_configuration(codec.context, item, &self.encoding_scratch) orelse return .unsupported;
                if (len == 0 or len > self.encoding_scratch.len) return .unsupported;
                if (!self.writeEncrypted(transport, item, self.encoding_scratch[0..len])) continue;
                _ = item.reconfigure();
                item.configuration_barrier = true;
            }
            return if (self.configurationBarrierStaged()) .accepted else .full;
        }

        pub fn beginReconfigurationWithTransport(self: *Self, transport: exchange.Transport) api.Admission {
            return self.advanceReconfigurationWithTransport(transport);
        }

        pub fn abortReconfigurationWithTransport(self: *Self, transport: exchange.Transport) void {
            self.accepting = true;
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (!occupied) continue;
                if (item.phase != .configuration or !item.configuration_barrier) continue;
                item.configuration_step = 0;
                item.configuration_barrier = false;
            }
            self.flushConfiguration(transport);
        }

        pub fn configurationBarrierStaged(self: *const Self) bool {
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (!occupied) continue;
                if (item.phase != .configuration or !item.configuration_barrier) return false;
            }
            return true;
        }

        pub const resume_id: u32 = 0x4d43_534e;
        pub const resume_version: u16 = 2;
        const resume_fixed_bytes = minecraft.Continuation.fixed_bytes;

        pub fn validateResume(self: *const Self, capacity_bytes: usize) bool {
            if (self.packet_view_count != 0 or self.attachment_count != 0 or self.detachment_count != 0 or self.held_count != 0) return false;
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (!occupied) continue;
                if (item.phase != .configuration and item.phase != .play) continue;
                if (!self.validateOneResume(item, capacity_bytes)) return false;
                if (item.protocol != 0 and self.protocol(item.protocol) == null) return false;
            }
            return true;
        }

        pub fn encodeResume(self: *const Self, handle: exchange.Connection, output: []u8) ?[]const u8 {
            const item = self.findConst(handle) orelse return null;
            if (!self.validateOneResume(item, output.len)) return null;
            var writer = ResumeWriter{ .bytes = output };
            writer.int(u8, @intFromEnum(item.phase)) catch return null;
            writer.int(u8, item.configuration_step) catch return null;
            writer.int(i32, item.protocol) catch return null;
            writer.int(u128, item.uuid) catch return null;
            writer.int(u8, item.name.len) catch return null;
            writer.write(item.name.bytes[0..item.name.len]) catch return null;
            writer.int(u8, @intFromBool(item.attached)) catch return null;
            writer.int(u8, @intFromBool(item.status_response_pending)) catch return null;
            writer.int(u64, item.status_revision) catch return null;
            writer.int(u8, item.status_ping_len) catch return null;
            writer.write(item.status_ping[0..item.status_ping_len]) catch return null;
            writeCipher(&writer, item.encryptor) catch return null;
            writeCipher(&writer, item.decryptor) catch return null;
            if (item.compression_threshold) |threshold| {
                writer.int(u8, 1) catch return null;
                writer.int(i32, threshold) catch return null;
            } else writer.int(u8, 0) catch return null;
            writer.int(u16, item.codec_state_len) catch return null;
            writer.write(item.codec_state[0..item.codec_state_len]) catch return null;
            return output[0..writer.len];
        }

        pub fn restoreResume(self: *Self, handle: exchange.Connection, id: u32, version: u16, bytes: []const u8) bool {
            if (id != resume_id or version != resume_version or handle.index >= capacity or self.occupied[handle.index]) return false;
            var reader = ResumeReader{ .bytes = bytes };
            const phase = reader.enumValue(api.Phase) orelse return false;
            const configuration_step = reader.int(u8) orelse return false;
            if (configuration_step > self.configurationPlanSteps()) return false;
            const protocol_number = reader.int(i32) orelse return false;
            const codec = if (protocol_number == 0) null else (self.protocol(protocol_number) orelse return false);
            const uuid = reader.int(u128) orelse return false;
            const name_len = reader.int(u8) orelse return false;
            if (name_len > 16) return false;
            var name: minecraft.Name = .{};
            const name_bytes = reader.take(name_len) orelse return false;
            @memcpy(name.bytes[0..name_len], name_bytes);
            name.len = name_len;
            const attached_raw = reader.int(u8) orelse return false;
            if (attached_raw > 1) return false;
            const attached = attached_raw == 1;
            const status_pending_raw = reader.int(u8) orelse return false;
            if (status_pending_raw > 1) return false;
            const status_response_pending = status_pending_raw == 1;
            const status_revision = reader.int(u64) orelse return false;
            const ping_len = reader.int(u8) orelse return false;
            if (ping_len > 16) return false;
            var ping: [16]u8 = @splat(0);
            @memcpy(ping[0..ping_len], reader.take(ping_len) orelse return false);
            const encryptor = (readCipher(&reader) orelse return false).value;
            const decryptor = (readCipher(&reader) orelse return false).value;
            const compression_present = reader.int(u8) orelse return false;
            if (compression_present > 1) return false;
            const threshold = if (compression_present == 1) (reader.int(i32) orelse return false) else null;
            const state_len = reader.int(u16) orelse return false;
            if (state_len > minecraft.Codec.max_state_bytes) return false;
            const state = reader.take(state_len) orelse return false;
            if (reader.remaining().len != 0) return false;
            var value = minecraft.Session{ .connection = handle, .phase = phase, .configuration_step = configuration_step, .protocol = protocol_number, .uuid = uuid, .name = name, .attached = attached, .status_response_pending = status_response_pending, .status_revision = status_revision, .status_ping = ping, .status_ping_len = ping_len, .codec = if (codec) |selected| selected.codec else null, .compression_threshold = threshold, .workspace = &self.workspace };
            value.encryptor = encryptor;
            value.decryptor = decryptor;
            value.codec_state_len = state_len;
            @memcpy(value.codec_state[0..state_len], state);
            if (!self.validateOneResume(&value, bytes.len)) return false;
            self.sessions[handle.index] = value;
            self.occupied[handle.index] = true;
            self.configuration_plan_locked = true;
            return true;
        }

        pub fn stageFinalDetachments(self: *Self) void {
            self.accepting = false;
            self.final_detachments_staged = true;
            for (&self.sessions, self.occupied, 0..) |*item, occupied, index| {
                if (!occupied) continue;
                if (item.authentication_pending or item.authentication_challenged) if (self.authentication) |auth| auth.vtable.cancel(auth.context, item.connection);
                if (item.attached or item.retained_page != null) item.closing = .server_shutdown else self.occupied[index] = false;
            }
            self.flushDetaches();
        }

        pub fn fatalDisconnect(self: *Self, transport: exchange.Transport) api.ShutdownProgress {
            self.accepting = false;
            if (!self.fatal_started) {
                self.fatal_started = true;
                for (self.held_pages[0..self.held_count]) |page| transport.vtable.release_input(transport.context, page);
                self.held_count = 0;
                self.attachment_count = 0;
                self.detachment_count = 0;
                self.packet_view_count = 0;
                @memset(&self.input_pending, null);
                @memset(&self.retained_input_borrowed, null);
                for (&self.sessions, self.occupied) |*item, occupied| {
                    if (!occupied) continue;
                    if (item.authentication_pending or item.authentication_challenged) if (self.authentication) |auth|
                        auth.vtable.cancel(auth.context, item.connection);
                    item.authentication_pending = false;
                    item.authentication_challenged = false;
                    if (item.retained_page) |page| transport.vtable.release_input(transport.context, page);
                    item.retained_page = null;
                    item.retained_offset = 0;
                }
            }
            var events: [batch_capacity]exchange.TransportEvent = undefined;
            for (transport.complete(&events)) |event| switch (event) {
                .accepted => |handle| transport.vtable.close(transport.context, handle, .server_shutdown),
                .received => |received| transport.vtable.release_input(transport.context, received.page.id),
                .closed => |closed| {
                    if (self.find(closed.connection) != null) {
                        self.dropPreparedQueue(closed.connection);
                        self.occupied[closed.connection.index] = false;
                    }
                },
            };
            self.flushOutput(transport);
            self.flushLoginOutput(transport);
            var pending = false;
            for (&self.sessions, self.occupied, 0..) |*item, occupied, index| {
                if (!occupied) continue;
                pending = true;
                if (self.delivery_queues[index].len != 0 or self.login_output_len[index] != 0) continue;
                if (!self.fatal_encoded[index]) {
                    if (item.codec) |codec| if (codec.vtable.disconnect) |emit| {
                        if (emit(codec.context, item, &self.status_cache[index])) |len| {
                            std.debug.assert(len <= self.status_cache[index].len);
                            self.login_output_len[index] = @intCast(len);
                            self.login_output_encrypted[index] = true;
                        }
                    };
                    self.fatal_encoded[index] = true;
                    self.flushOneLoginOutput(transport, item);
                    if (self.login_output_len[index] != 0) continue;
                }
                const metrics = transport.vtable.output_metrics(transport.context, item.connection);
                if (metrics != null and metrics.?.queued_bytes != 0) continue;
                transport.vtable.close(transport.context, item.connection, .server_shutdown);
                self.occupied[index] = false;
            }
            return if (pending) .pending else .complete;
        }

        pub fn shutdownProgress(self: *Self) api.ShutdownProgress {
            if (!self.final_detachments_staged) return .pending;
            for (self.occupied) |occupied| if (occupied) return .pending;
            return if (self.detachment_count == 0) .complete else .pending;
        }

        pub fn advance(self: *Self, transport: exchange.Transport, now_ns: u64, snapshot: api.StatusSnapshot) void {
            self.now_ns = now_ns;
            self.flushConfiguration(transport);
            var events: [batch_capacity]exchange.TransportEvent = undefined;
            self.flushOutput(transport);
            self.flushStatuses(transport, snapshot);
            self.flushLoginOutput(transport);
            self.releaseClosingUnattached(transport);
            self.flushDetaches();
            self.pollAuthentication(transport, now_ns);
            self.processRetained(transport, snapshot);
            for (transport.complete(&events)) |event| self.consume(transport, event, snapshot);
            self.flushConfiguration(transport);
            self.flushOutput(transport);
            self.flushStatuses(transport, snapshot);
        }

        pub fn input(self: *Self) exchange.CoreInput {
            return .{
                .attachments = self.attachments[0..self.attachment_count],
                .detachments = self.detachments[0..self.detachment_count],
                .packet_views = self.packet_views[0..self.packet_view_count],
                .packet_claimed = self.packet_claimed[0..self.packet_view_count],
            };
        }

        pub fn finishInput(self: *Self, transport: exchange.Transport) void {
            for (self.packet_views[0..self.packet_view_count], self.packet_claimed[0..self.packet_view_count]) |view, claimed|
                if (!claimed) transport.vtable.close(transport.context, view.connection, .malformed_packet);
            for (self.held_pages[0..self.held_count]) |page| transport.vtable.release_input(transport.context, page);
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (occupied) if (item.codec) |codec| codec.vtable.finish_input(codec.context, item);
            }
            self.attachment_count = 0;
            self.detachment_count = 0;
            self.packet_view_count = 0;
            self.held_count = 0;
            @memset(&self.input_pending, null);
            @memset(&self.retained_input_borrowed, null);
        }

        pub fn publishInput(self: *Self, transport: exchange.Transport, ingress: core_exchange.Ingress) bool {
            const Group = struct {
                connection: ?exchange.Connection = null,
                attachment: ?usize = null,
                detachment: ?usize = null,
                first: usize = 0,
                count: usize = 0,
                written: usize = 0,
                accepted: bool = false,
            };
            var groups: [capacity]Group = @splat(.{});
            var views: [batch_capacity]core_exchange.PacketView = undefined;
            var claimed: [batch_capacity]bool = undefined;
            inline for (.{ self.attachments[0..self.attachment_count], self.detachments[0..self.detachment_count], self.packet_views[0..self.packet_view_count] }, 0..) |records, kind| {
                for (records, 0..) |record, index| {
                    const group = &groups[record.connection.index];
                    if (group.connection) |handle| std.debug.assert(handle.eql(record.connection));
                    group.connection = record.connection;
                    switch (kind) {
                        0 => {
                            std.debug.assert(group.attachment == null);
                            group.attachment = index;
                        },
                        1 => {
                            std.debug.assert(group.detachment == null);
                            group.detachment = index;
                        },
                        2 => group.count += 1,
                        else => unreachable,
                    }
                }
            }
            var offset: usize = 0;
            for (&groups) |*group| {
                group.first = offset;
                offset += group.count;
            }
            for (self.packet_views[0..self.packet_view_count], self.packet_claimed[0..self.packet_view_count]) |view, was_claimed| {
                const group = &groups[view.connection.index];
                const index = group.first + group.written;
                views[index] = view;
                claimed[index] = was_claimed;
                group.written += 1;
            }
            var progressed = false;
            for (&groups) |*group| {
                const handle = group.connection orelse continue;
                group.accepted = ingress.stage(.{
                    .attachments = if (group.attachment) |index| self.attachments[index..][0..1] else &.{},
                    .detachments = if (group.detachment) |index| self.detachments[index..][0..1] else &.{},
                    .packet_views = views[group.first..][0..group.count],
                    .packet_claimed = claimed[group.first..][0..group.count],
                });
                if (!group.accepted) continue;
                progressed = true;
                const item = &self.sessions[handle.index];
                if (item.connection.eql(handle)) if (item.codec) |codec| codec.vtable.finish_input(codec.context, item);
            }
            var kept: usize = 0;
            for (self.held_pages[0..self.held_count], self.held_connections[0..self.held_count]) |page, handle| {
                if (groups[handle.index].accepted) {
                    transport.vtable.release_input(transport.context, page);
                } else {
                    self.held_pages[kept] = page;
                    self.held_connections[kept] = handle;
                    kept += 1;
                }
            }
            self.held_count = kept;
            kept = 0;
            for (self.attachments[0..self.attachment_count]) |record| {
                if (groups[record.connection.index].accepted) continue;
                self.attachments[kept] = record;
                kept += 1;
            }
            self.attachment_count = kept;
            kept = 0;
            for (self.detachments[0..self.detachment_count]) |record| {
                if (groups[record.connection.index].accepted) continue;
                self.detachments[kept] = record;
                kept += 1;
            }
            self.detachment_count = kept;
            kept = 0;
            for (self.packet_views[0..self.packet_view_count], self.packet_claimed[0..self.packet_view_count]) |view, was_claimed| {
                if (groups[view.connection.index].accepted) continue;
                self.packet_views[kept] = view;
                self.packet_claimed[kept] = was_claimed;
                kept += 1;
            }
            self.packet_view_count = kept;
            for (&groups) |*group| if (group.accepted) {
                const handle = group.connection orelse unreachable;
                self.clearPending(handle);
                self.clearRetainedInputBorrowed(handle);
            };
            return progressed;
        }

        pub fn connectionProtocol(self: *const Self, connection: exchange.Connection) ?api.Protocol {
            const item = self.findConst(connection) orelse return null;
            if (item.protocol == 0) return null;
            return .{ .value = item.protocol };
        }

        pub fn connectionOutputState(self: *const Self, transport: exchange.Transport, connection: exchange.Connection) ?api.OutputState {
            _ = self.findConst(connection) orelse return null;
            const metrics = transport.vtable.output_metrics(transport.context, connection) orelse return null;
            return .{
                .credit_bytes = transport.vtable.output_credit(transport.context, connection),
                .queued_bytes = metrics.queued_bytes,
                .capacity_bytes = metrics.capacity_bytes,
            };
        }

        pub fn outputIdle(self: *const Self) bool {
            for (self.delivery_queues) |queue| if (queue.len != 0) return false;
            return true;
        }

        pub fn sendOne(self: *Self, transport: exchange.Transport, connection: exchange.Connection, encoder: api.PacketEncoder, class: api.DeliveryClass, policy: api.DeliveryPolicy) api.PacketAdmission {
            const admission = self.stageOne(transport, connection, encoder, class, policy);
            if (admission == .accepted) self.flushOutput(transport);
            return admission;
        }

        pub fn consumeCoreOutput(self: *Self, transport: exchange.Transport, source: core_exchange.OutputSource, message: core_exchange.CoreToSession, bytes: []const u8) api.PacketAdmission {
            if (message.len != bytes.len) return .wrong_protocol;
            return switch (message.kind) {
                .packet => self.consumePacketFragment(transport, message, bytes),
                .packet_shared => self.consumePacketShared(transport, source, message, bytes),
                .reconfigure, .disconnect, .status => .wrong_phase,
            };
        }

        fn consumePacketShared(self: *Self, transport: exchange.Transport, source: core_exchange.OutputSource, message: core_exchange.CoreToSession, payload: []const u8) api.PacketAdmission {
            if (message.fragment != .whole or message.recipient_count == 0 or message.recipient_count > capacity or
                message.total_len != payload.len or message.phase > @intFromEnum(api.Phase.play) or
                message.delivery_class > @intFromEnum(api.DeliveryClass.other) or
                message.delivery_policy > @intFromEnum(api.DeliveryPolicy.optional)) return .wrong_protocol;
            const phase: api.Phase = @enumFromInt(message.phase);
            const class: api.DeliveryClass = @enumFromInt(message.delivery_class);
            const policy: api.DeliveryPolicy = @enumFromInt(message.delivery_policy);
            const group = self.sharedGroup(source, message) orelse return .backpressured;
            const target = self.findConst(message.connection);
            if (target != null and target.?.attached and target.?.phase == phase and target.?.protocol == message.protocol) {
                var frame = self.sharedFrame(group, target.?.compression_threshold);
                if (frame == null) {
                    const item = self.find(message.connection) orelse unreachable;
                    const codec = item.codec orelse {
                        self.finishSharedMessage(group);
                        return .wrong_protocol;
                    };
                    const framed_len = codec.vtable.frame_payload(codec.context, item, payload, &self.encoding_scratch) orelse {
                        self.finishSharedMessage(group);
                        return .wrong_protocol;
                    };
                    if (framed_len == 0 or framed_len > self.encoding_scratch.len) {
                        self.finishSharedMessage(group);
                        return .wrong_protocol;
                    }
                    frame = self.allocatePrepared(self.encoding_scratch[0..framed_len], class);
                    if (frame == null) {
                        if (policy == .optional) self.finishSharedMessage(group);
                        return .backpressured;
                    }
                    self.prepared_frames[frame.?].shared_group = @intCast(group);
                    self.prepared_frames[frame.?].compression_threshold = item.compression_threshold;
                }
                if (!self.queueHasSpace(message.connection, class)) {
                    if (policy == .reliable) return .backpressured;
                } else std.debug.assert(self.enqueuePrepared(message.connection, frame.?));
            }
            self.finishSharedMessage(group);
            self.flushOutput(transport);
            return .accepted;
        }

        fn sharedGroup(self: *Self, source: core_exchange.OutputSource, message: core_exchange.CoreToSession) ?usize {
            for (self.shared_groups, 0..) |group, index| {
                if (group.occupied and group.source.eql(source) and group.source_page == message.page and group.source_offset == message.offset) return index;
            }
            for (&self.shared_groups, 0..) |*group, index| {
                if (group.occupied) continue;
                group.* = .{ .source = source, .source_page = message.page, .source_offset = message.offset, .remaining = message.recipient_count, .occupied = true };
                return index;
            }
            return null;
        }

        fn sharedFrame(self: *const Self, group: usize, threshold: ?i32) ?usize {
            const group_index: u16 = @intCast(group);
            for (self.prepared_frames, 0..) |frame, index| {
                if (frame.occupied and frame.shared_group == group_index and frame.compression_threshold == threshold) return index;
            }
            return null;
        }

        fn finishSharedMessage(self: *Self, group: usize) void {
            const group_index: u16 = @intCast(group);
            const source = &self.shared_groups[group];
            std.debug.assert(source.occupied and source.remaining != 0);
            source.remaining -= 1;
            if (source.remaining != 0) return;
            source.* = .{};
            for (&self.prepared_frames, 0..) |*frame, index| {
                if (!frame.occupied or frame.shared_group != group_index) continue;
                frame.shared_group = null;
                if (frame.references == 0) self.releasePrepared(index);
            }
        }

        fn consumePacketFragment(self: *Self, transport: exchange.Transport, message: core_exchange.CoreToSession, bytes: []const u8) api.PacketAdmission {
            if (message.fragment != .whole or message.total_len != bytes.len or
                message.phase > @intFromEnum(api.Phase.play)) return .wrong_phase;
            if (message.delivery_class > @intFromEnum(api.DeliveryClass.other) or
                message.delivery_policy > @intFromEnum(api.DeliveryPolicy.optional)) return .wrong_protocol;
            const phase: api.Phase = @enumFromInt(message.phase);
            const class: api.DeliveryClass = @enumFromInt(message.delivery_class);
            const policy: api.DeliveryPolicy = @enumFromInt(message.delivery_policy);
            if (bytes.len == 0 or bytes.len > self.packet_scratch.len)
                return unavailable(transport, message.connection, policy);
            return self.stagePayload(transport, message.connection, message.protocol, phase, bytes, class, policy);
        }

        fn consumeCoreOutputApi(raw: *anyopaque, transport: exchange.Transport, source: core_exchange.OutputSource, message: core_exchange.CoreToSession, bytes: []const u8) api.PacketAdmission {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.consumeCoreOutput(transport, source, message, bytes);
        }

        fn stagePayload(self: *Self, transport: exchange.Transport, connection: exchange.Connection, protocol_number: i32, phase: api.Phase, payload: []const u8, class: api.DeliveryClass, policy: api.DeliveryPolicy) api.PacketAdmission {
            const item = self.find(connection) orelse return .closed;
            if (!item.attached or item.phase != phase) return .wrong_phase;
            if (item.protocol != protocol_number) return .wrong_protocol;
            if (policy == .optional and (transport.vtable.output_credit(transport.context, connection) == 0 or !self.queueHasSpace(connection, class))) return .backpressured;
            const codec = item.codec orelse return .wrong_protocol;
            const framed_len = codec.vtable.frame_payload(codec.context, item, payload, &self.encoding_scratch) orelse return .wrong_protocol;
            if (framed_len == 0 or framed_len > self.encoding_scratch.len) return .wrong_protocol;
            if (self.delivery_queues[connection.index].len == 0 and
                transport.vtable.output_credit(transport.context, connection) >= framed_len and
                self.writeEncrypted(transport, item, self.encoding_scratch[0..framed_len]))
                return .accepted;
            const frame = self.allocatePrepared(self.encoding_scratch[0..framed_len], class) orelse return unavailable(transport, connection, policy);
            if (!self.enqueuePrepared(connection, frame)) {
                self.releasePrepared(frame);
                return unavailable(transport, connection, policy);
            }
            self.flushOutput(transport);
            return .accepted;
        }

        fn stageOne(self: *Self, transport: exchange.Transport, connection: exchange.Connection, encoder: api.PacketEncoder, class: api.DeliveryClass, policy: api.DeliveryPolicy) api.PacketAdmission {
            const item = self.find(connection) orelse return .closed;
            if (!item.attached or item.phase != encoder.phase) return .wrong_phase;
            if (policy == .optional and (transport.vtable.output_credit(transport.context, connection) == 0 or !self.queueHasSpace(connection, class)))
                return .backpressured;
            if (encoder.maximum_payload_bytes > self.packet_scratch.len) return unavailable(transport, connection, policy);
            const payload = self.packet_scratch[0..encoder.maximum_payload_bytes];
            const wire_protocol = api.Protocol{ .value = item.protocol };
            const encoded = encoder.encode(encoder.context, wire_protocol, payload) orelse return .wrong_protocol;
            const start = @intFromPtr(payload.ptr);
            const encoded_start = @intFromPtr(encoded.payload.ptr);
            std.debug.assert(encoded_start >= start and encoded_start + encoded.payload.len <= start + payload.len);
            const codec = item.codec orelse return .wrong_protocol;
            const framed_len = codec.vtable.frame_payload(codec.context, item, encoded.payload, &self.encoding_scratch) orelse return .wrong_protocol;
            if (framed_len == 0 or framed_len > self.encoding_scratch.len) return .wrong_protocol;
            if (self.delivery_queues[connection.index].len == 0 and
                transport.vtable.output_credit(transport.context, connection) >= framed_len and
                self.writeEncrypted(transport, item, self.encoding_scratch[0..framed_len]))
                return .accepted;
            const frame = self.allocatePrepared(self.encoding_scratch[0..framed_len], class) orelse return unavailable(transport, connection, policy);
            if (!self.enqueuePrepared(connection, frame)) {
                self.releasePrepared(frame);
                return unavailable(transport, connection, policy);
            }
            return .accepted;
        }

        pub fn batch(
            self: *Self,
            transport: exchange.Transport,
            items: []const api.WirePacketBatchItem,
            class: api.DeliveryClass,
            policy: api.DeliveryPolicy,
            temporary: std.mem.Allocator,
        ) std.mem.Allocator.Error!api.FanoutAdmissions {
            if (items.len > batch_capacity) return error.OutOfMemory;
            const admissions = try temporary.alloc(api.PacketAdmission, items.len);
            for (items, admissions) |entry, *admission|
                admission.* = self.stageOne(transport, entry.recipient, entry.encoder, class, policy);
            self.flushOutput(transport);
            return .{ .values = admissions };
        }

        fn unavailable(transport: exchange.Transport, connection: exchange.Connection, policy: api.DeliveryPolicy) api.PacketAdmission {
            _ = transport;
            _ = connection;
            _ = policy;
            return .backpressured;
        }

        pub fn fanout(
            self: *Self,
            transport: exchange.Transport,
            recipients: []const exchange.Connection,
            encoder: api.PacketEncoder,
            class: api.DeliveryClass,
            policy: api.DeliveryPolicy,
            temporary: std.mem.Allocator,
        ) std.mem.Allocator.Error!api.FanoutAdmissions {
            const admissions = try temporary.alloc(api.PacketAdmission, recipients.len);
            const protocols = try temporary.alloc(api.Protocol, recipients.len);
            if (encoder.maximum_payload_bytes > self.packet_scratch.len) return error.OutOfMemory;
            const payload = self.packet_scratch[0..encoder.maximum_payload_bytes];
            var protocol_count: usize = 0;
            for (recipients, 0..) |connection, index| {
                const item = self.findConst(connection) orelse {
                    admissions[index] = .closed;
                    continue;
                };
                if (item.phase != encoder.phase or !item.attached) {
                    admissions[index] = .wrong_phase;
                    continue;
                }
                const wire_protocol = api.Protocol{ .value = item.protocol };
                admissions[index] = .wrong_protocol;
                for (protocols[0..protocol_count]) |existing| {
                    if (existing.eql(wire_protocol)) break;
                } else {
                    protocols[protocol_count] = wire_protocol;
                    protocol_count += 1;
                }
            }
            for (protocols[0..protocol_count]) |wire_protocol| {
                const encoded = encoder.encode(encoder.context, wire_protocol, payload) orelse {
                    self.markFanoutWrongProtocol(recipients, admissions, wire_protocol, encoder.phase);
                    continue;
                };
                const start = @intFromPtr(payload.ptr);
                const end = start + payload.len;
                const encoded_start = @intFromPtr(encoded.payload.ptr);
                std.debug.assert(encoded_start >= start and encoded_start + encoded.payload.len <= end);
                self.stagePreparedFanout(transport, recipients, admissions, wire_protocol, encoded.payload, encoder.phase, class, policy);
            }
            self.flushOutput(transport);
            return .{ .values = admissions };
        }

        fn markFanoutWrongProtocol(self: *const Self, recipients: []const exchange.Connection, admissions: []api.PacketAdmission, wire_protocol: api.Protocol, phase: api.Phase) void {
            for (recipients, admissions) |connection, *admission| {
                const item = self.findConst(connection) orelse continue;
                if (item.phase == phase and item.attached and item.protocol == wire_protocol.value) admission.* = .wrong_protocol;
            }
        }

        fn stagePreparedFanout(self: *Self, transport: exchange.Transport, recipients: []const exchange.Connection, admissions: []api.PacketAdmission, wire_protocol: api.Protocol, payload: []const u8, phase: api.Phase, class: api.DeliveryClass, policy: api.DeliveryPolicy) void {
            const representative = self.familySession(recipients, wire_protocol.value) orelse return self.markFanoutWrongProtocol(recipients, admissions, wire_protocol, phase);
            const codec = representative.codec orelse return self.markFanoutWrongProtocol(recipients, admissions, wire_protocol, phase);
            const framed_len = codec.vtable.frame_payload(codec.context, representative, payload, &self.encoding_scratch) orelse return self.markFanoutWrongProtocol(recipients, admissions, wire_protocol, phase);
            if (framed_len == 0 or framed_len > self.encoding_scratch.len) return self.markFanoutWrongProtocol(recipients, admissions, wire_protocol, phase);
            const frame = self.allocatePrepared(self.encoding_scratch[0..framed_len], class) orelse {
                self.markFanoutUnavailable(recipients, admissions, wire_protocol, phase);
                return;
            };
            for (recipients, admissions) |connection, *admission| {
                const item = self.findConst(connection) orelse continue;
                if (item.phase != phase or !item.attached or item.protocol != wire_protocol.value) continue;
                if (policy == .optional and (transport.vtable.output_credit(transport.context, connection) == 0 or !self.queueHasSpace(connection, class))) {
                    admission.* = .backpressured;
                    continue;
                }
                if (!self.enqueuePrepared(connection, frame)) {
                    admission.* = .backpressured;
                    continue;
                }
                admission.* = .accepted;
            }
            if (self.prepared_frames[frame].references == 0) self.releasePrepared(frame);
        }

        fn markFanoutUnavailable(self: *const Self, recipients: []const exchange.Connection, admissions: []api.PacketAdmission, wire_protocol: api.Protocol, phase: api.Phase) void {
            for (recipients, admissions) |connection, *admission| {
                const item = self.findConst(connection) orelse continue;
                if (item.phase != phase or !item.attached or item.protocol != wire_protocol.value) continue;
                admission.* = .backpressured;
            }
        }

        fn allocatePrepared(self: *Self, bytes: []const u8, class: api.DeliveryClass) ?usize {
            const pages = (bytes.len + prepared_page_bytes - 1) / prepared_page_bytes;
            if (pages == 0 or pages > 25) return null;
            var frame: usize = 0;
            while (frame < self.prepared_frames.len and self.prepared_frames[frame].occupied) : (frame += 1) {}
            if (frame == self.prepared_frames.len) return null;
            var selected: [25]u16 = undefined;
            var count: usize = 0;
            for (self.prepared_page_used, 0..) |used, index| {
                if (used) continue;
                selected[count] = @intCast(index);
                count += 1;
                if (count == pages) break;
            }
            if (count != pages) return null;
            var offset: usize = 0;
            for (selected[0..pages]) |page| {
                const len = @min(prepared_page_bytes, bytes.len - offset);
                @memcpy(self.prepared_pages[page][0..len], bytes[offset..][0..len]);
                self.prepared_page_used[page] = true;
                offset += len;
            }
            self.prepared_copy_bytes +%= bytes.len;
            self.prepared_frames[frame] = .{ .pages = selected, .page_count = @intCast(pages), .len = @intCast(bytes.len), .references = 0, .class = class, .occupied = true };
            return frame;
        }

        fn queueHasSpace(self: *const Self, connection: exchange.Connection, class: api.DeliveryClass) bool {
            if (connection.index >= capacity) return false;
            const queue = self.delivery_queues[connection.index];
            if (queue.len == batch_capacity) return false;
            const control_reserve = @min(8, batch_capacity / 2);
            if (class != .control and queue.len >= batch_capacity - control_reserve) return false;
            const limit = switch (class) {
                .control => batch_capacity,
                .chunks => batch_capacity - control_reserve,
                .entities => @max(1, batch_capacity / 4),
                .other => @max(1, batch_capacity / 8),
            };
            return queue.classes[@intFromEnum(class)] < limit;
        }

        fn enqueuePrepared(self: *Self, connection: exchange.Connection, frame: usize) bool {
            const class = self.prepared_frames[frame].class;
            if (!self.queueHasSpace(connection, class)) return false;
            const queue = &self.delivery_queues[connection.index];
            const fair_bytes = @max(prepared_page_bytes, staged_output_bytes / capacity);
            if (queue.len != 0 and @as(usize, queue.bytes) + self.prepared_frames[frame].len > fair_bytes)
                return false;
            const tail = (@as(usize, queue.head) + queue.len) % batch_capacity;
            self.deliveries[connection.index][tail] = .{ .frame = @intCast(frame) };
            queue.len += 1;
            queue.bytes += self.prepared_frames[frame].len;
            queue.classes[@intFromEnum(class)] += 1;
            self.prepared_frames[frame].references += 1;
            return true;
        }

        fn releasePrepared(self: *Self, frame: usize) void {
            const value = &self.prepared_frames[frame];
            std.debug.assert(value.occupied and value.references == 0 and value.shared_group == null);
            for (value.pages[0..value.page_count]) |page| self.prepared_page_used[page] = false;
            value.* = .{};
        }

        fn dequeuePrepared(self: *Self, connection: exchange.Connection) void {
            const queue = &self.delivery_queues[connection.index];
            std.debug.assert(queue.len != 0);
            const frame: usize = self.deliveries[connection.index][queue.head].frame;
            const class = self.prepared_frames[frame].class;
            queue.head = @intCast((@as(usize, queue.head) + 1) % batch_capacity);
            queue.len -= 1;
            queue.classes[@intFromEnum(class)] -= 1;
            self.prepared_frames[frame].references -= 1;
            if (self.prepared_frames[frame].references == 0 and self.prepared_frames[frame].shared_group == null) self.releasePrepared(frame);
        }

        fn asSessions(context: *anyopaque) *Self {
            return @ptrCast(@alignCast(context));
        }
        fn sessionAdvance(context: *anyopaque, transport: exchange.Transport, now_ns: u64, snapshot: api.StatusSnapshot) void {
            asSessions(context).advance(transport, now_ns, snapshot);
        }
        fn sessionInput(context: *anyopaque) exchange.CoreInput {
            return asSessions(context).input();
        }
        fn sessionFinish(context: *anyopaque, transport: exchange.Transport) void {
            asSessions(context).finishInput(transport);
        }
        fn sessionProtocol(context: *const anyopaque, connection: exchange.Connection) ?api.Protocol {
            const self: *const Self = @ptrCast(@alignCast(context));
            return self.connectionProtocol(connection);
        }
        fn sessionOutputState(context: *const anyopaque, transport: exchange.Transport, connection: exchange.Connection) ?api.OutputState {
            const self: *const Self = @ptrCast(@alignCast(context));
            return self.connectionOutputState(transport, connection);
        }
        fn sessionSendOne(context: *anyopaque, transport: exchange.Transport, connection: exchange.Connection, encoder: api.PacketEncoder, class: api.DeliveryClass, policy: api.DeliveryPolicy) api.PacketAdmission {
            return asSessions(context).sendOne(transport, connection, encoder, class, policy);
        }
        fn sessionBatch(context: *anyopaque, transport: exchange.Transport, items: []const api.WirePacketBatchItem, class: api.DeliveryClass, policy: api.DeliveryPolicy, temporary: std.mem.Allocator) std.mem.Allocator.Error!api.FanoutAdmissions {
            return asSessions(context).batch(transport, items, class, policy, temporary);
        }
        fn sessionFanout(context: *anyopaque, transport: exchange.Transport, recipients: []const exchange.Connection, encoder: api.PacketEncoder, class: api.DeliveryClass, policy: api.DeliveryPolicy, temporary: std.mem.Allocator) std.mem.Allocator.Error!api.FanoutAdmissions {
            return asSessions(context).fanout(transport, recipients, encoder, class, policy, temporary);
        }
        fn sessionStop(context: *anyopaque) void {
            asSessions(context).stopAccepting();
        }
        fn sessionDetach(context: *anyopaque) void {
            asSessions(context).stageFinalDetachments();
        }
        fn sessionShutdown(context: *anyopaque) api.ShutdownProgress {
            return asSessions(context).shutdownProgress();
        }
        fn sessionFatal(context: *anyopaque, transport: exchange.Transport) api.ShutdownProgress {
            return asSessions(context).fatalDisconnect(transport);
        }
        const sessions_vtable: api.Sessions.VTable = .{
            .advance = sessionAdvance,
            .take_input = sessionInput,
            .finish_input = sessionFinish,
            .protocol = sessionProtocol,
            .output_state = sessionOutputState,
            .send_one = sessionSendOne,
            .batch = sessionBatch,
            .fanout = sessionFanout,
            .stop_accepting = sessionStop,
            .stage_final_detachments = sessionDetach,
            .fatal_disconnect = sessionFatal,
            .shutdown_progress = sessionShutdown,
        };

        fn consume(self: *Self, transport: exchange.Transport, event: exchange.TransportEvent, snapshot: api.StatusSnapshot) void {
            switch (event) {
                .accepted => |handle| self.accept(transport, handle),
                .received => |received| self.receive(transport, received.connection, received.page, snapshot),
                .closed => |closed| self.detach(transport, closed.connection, closed.reason),
            }
        }

        fn inputPending(self: *const Self, handle: exchange.Connection) bool {
            return handle.index < capacity and if (self.input_pending[handle.index]) |pending| pending.eql(handle) else false;
        }

        fn markInputPending(self: *Self, handle: exchange.Connection) void {
            std.debug.assert(handle.index < capacity);
            if (self.input_pending[handle.index]) |pending| {
                std.debug.assert(pending.eql(handle));
                return;
            }
            self.input_pending[handle.index] = handle;
        }

        fn clearPending(self: *Self, handle: exchange.Connection) void {
            if (handle.index >= capacity) return;
            if (self.input_pending[handle.index]) |pending| {
                if (pending.eql(handle)) self.input_pending[handle.index] = null;
            }
        }

        fn retainedInputBorrowed(self: *const Self, handle: exchange.Connection) bool {
            return handle.index < capacity and if (self.retained_input_borrowed[handle.index]) |pending| pending.eql(handle) else false;
        }

        fn markRetainedInputBorrowed(self: *Self, handle: exchange.Connection) void {
            std.debug.assert(handle.index < capacity);
            if (self.retained_input_borrowed[handle.index]) |pending| {
                std.debug.assert(pending.eql(handle));
                return;
            }
            self.retained_input_borrowed[handle.index] = handle;
        }

        fn clearRetainedInputBorrowed(self: *Self, handle: exchange.Connection) void {
            if (handle.index >= capacity) return;
            if (self.retained_input_borrowed[handle.index]) |pending| {
                if (pending.eql(handle)) self.retained_input_borrowed[handle.index] = null;
            }
        }

        fn accept(self: *Self, transport: exchange.Transport, handle: exchange.Connection) void {
            if (!self.accepting or handle.index >= capacity or self.occupied[handle.index] or self.input_pending[handle.index] != null) {
                transport.vtable.close(transport.context, handle, .overloaded);
                return;
            }
            self.configuration_plan_locked = true;
            self.login_output_len[handle.index] = 0;
            self.sessions[handle.index] = .{ .connection = handle, .workspace = &self.workspace };
            self.occupied[handle.index] = true;
        }

        fn receive(self: *Self, transport: exchange.Transport, handle: exchange.Connection, page: exchange.InputPage, snapshot: api.StatusSnapshot) void {
            const item = self.find(handle) orelse return transport.vtable.release_input(transport.context, page.id);
            item.decrypt(page.bytes);
            if (self.inputPending(handle)) return self.retain(item, page.id);
            switch (item.phase) {
                .handshake => self.handshake(transport, item, page),
                .status => self.status(transport, item, page, snapshot),
                .login, .configuration, .play => self.decode(transport, item, page),
            }
        }

        fn handshake(self: *Self, transport: exchange.Transport, item: *minecraft.Session, page: exchange.InputPage) void {
            const decoder = self.handshake_decoder orelse return self.reject(transport, item.connection, page.id, .malformed_packet);
            const result = decoder.decode(decoder.context, item, page.bytes);
            const progress = switch (result) {
                .malformed => return self.reject(transport, item.connection, page.id, .malformed_packet),
                .progress => |value| value,
            };
            if (progress.consumed > page.bytes.len) return self.reject(transport, item.connection, page.id, .malformed_packet);
            const value = progress.value orelse {
                self.consumeOrRetain(transport, item, page, progress.consumed, false);
                return;
            };
            const number = switch (value) {
                .status, .login => |number| number,
            };
            const selected = self.protocol(number) orelse return self.reject(transport, item.connection, page.id, .malformed_packet);
            if (!selected.codec.vtable.init(selected.codec.context, item)) return self.reject(transport, item.connection, page.id, .malformed_packet);
            item.protocol = number;
            item.codec = selected.codec;
            item.phase = switch (value) {
                .status => .status,
                .login => .login,
            };
            self.consumeOrRetain(transport, item, page, progress.consumed, false);
        }

        fn status(self: *Self, transport: exchange.Transport, item: *minecraft.Session, page: exchange.InputPage, snapshot: api.StatusSnapshot) void {
            const codec = item.codec orelse return self.reject(transport, item.connection, page.id, .malformed_packet);
            var decoded: [batch_capacity]minecraft.Packet = undefined;
            const progress = switch (codec.vtable.decode(codec.context, item, page.bytes, &decoded)) {
                .malformed => return self.reject(transport, item.connection, page.id, .malformed_packet),
                .progress => |value| value,
            };
            const count = progress.packets;
            if (count == 0) return self.consumeOrRetain(transport, item, page, progress.consumed, false);
            if (count > decoded.len or progress.consumed > page.bytes.len) return self.reject(transport, item.connection, page.id, .malformed_packet);
            for (decoded[0..count]) |packet| switch (codec.vtable.classify(codec.context, .status, packet)) {
                .status_request => item.status_response_pending = true,
                .status_ping => |payload| {
                    if (payload.len > item.status_ping.len) return self.reject(transport, item.connection, page.id, .malformed_packet);
                    @memcpy(item.status_ping[0..payload.len], payload);
                    item.status_ping_len = @intCast(payload.len);
                },
                else => return self.reject(transport, item.connection, page.id, .malformed_packet),
            };
            codec.vtable.finish_input(codec.context, item);
            self.consumeOrRetain(transport, item, page, progress.consumed, false);
            self.sendStatus(transport, item, snapshot);
        }

        fn sendStatus(self: *Self, transport: exchange.Transport, item: *minecraft.Session, snapshot: api.StatusSnapshot) void {
            if (item.status_response_pending) self.sendStatusResponse(transport, item, snapshot);
            if (item.status_ping_len != 0 and self.encodePacket(transport, item.connection, 0, item.status_ping[0..item.status_ping_len])) item.status_ping_len = 0;
        }

        fn sendStatusResponse(self: *Self, transport: exchange.Transport, item: *minecraft.Session, snapshot: api.StatusSnapshot) void {
            const slot: usize = @intCast(item.connection.index);
            if ((self.status_cache_len[slot] == 0 or self.status_cache_revision[slot] != snapshot.revision) and !self.cacheStatus(item, slot, snapshot)) {
                item.status_response_pending = false;
                return transport.vtable.close(transport.context, item.connection, .overloaded);
            }
            const len = self.status_cache_len[slot];
            if (!self.writeClear(transport, item.connection, self.status_cache[slot][0..len])) return;
            item.status_response_pending = false;
        }

        fn flushStatuses(self: *Self, transport: exchange.Transport, snapshot: api.StatusSnapshot) void {
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (!occupied) continue;
                if (item.phase == .status) self.sendStatus(transport, item, snapshot);
            }
        }

        fn cacheStatus(self: *Self, item: *minecraft.Session, slot: usize, snapshot: api.StatusSnapshot) bool {
            const codec = item.codec orelse return false;
            const len = codec.vtable.status(codec.context, item.protocol, snapshot.json, &self.status_cache[slot]) orelse return false;
            if (len > status_bytes) return false;
            self.status_cache_len[slot] = @intCast(len);
            self.status_cache_revision[slot] = snapshot.revision;
            item.status_revision = snapshot.revision;
            return true;
        }

        fn decode(self: *Self, transport: exchange.Transport, item: *minecraft.Session, page: exchange.InputPage) void {
            const codec = item.codec orelse return self.reject(transport, item.connection, page.id, .malformed_packet);
            var decoded: [batch_capacity]minecraft.Packet = undefined;
            const available = @min(@min(decoded.len, input_quota), batch_capacity - self.packet_view_count);
            if (self.held_count == batch_capacity or available == 0) return self.retain(item, page.id);
            switch (codec.vtable.decode(codec.context, item, page.bytes, decoded[0..available])) {
                .malformed => self.reject(transport, item.connection, page.id, .malformed_packet),
                .progress => |progress| {
                    const count = progress.packets;
                    if (progress.consumed > page.bytes.len) return self.reject(transport, item.connection, page.id, .malformed_packet);
                    if (count == 0) return self.consumeOrRetain(transport, item, page, progress.consumed, false);
                    if (count > available) return self.reject(transport, item.connection, page.id, .malformed_packet);
                    const first_view = self.packet_view_count;
                    var uses_page = false;
                    for (decoded[0..count]) |packet| {
                        const before = self.packet_view_count;
                        if (!self.route(transport, item, codec, packet)) {
                            self.consumeOrRetain(transport, item, page, progress.consumed, self.packet_view_count != first_view and uses_page);
                            return;
                        }
                        if (self.packet_view_count != before and packet.storage == .input_page) uses_page = true;
                    }
                    if (self.packet_view_count == first_view) codec.vtable.finish_input(codec.context, item);
                    self.consumeOrRetain(transport, item, page, progress.consumed, uses_page);
                },
            }
        }

        fn encodePacket(self: *Self, transport: exchange.Transport, connection: exchange.Connection, id: i32, bytes: []const u8) bool {
            const item = self.find(connection) orelse return true;
            const codec = item.codec orelse {
                transport.vtable.close(transport.context, connection, .malformed_packet);
                return true;
            };
            const encoded_bound = codec.vtable.encoded_capacity(codec.context, item, id, bytes) orelse {
                transport.vtable.close(transport.context, connection, .overloaded);
                return true;
            };
            if (encoded_bound > self.encoding_scratch.len) {
                transport.vtable.close(transport.context, connection, .overloaded);
                return true;
            }
            const len = codec.vtable.encode(codec.context, item, id, bytes, self.encoding_scratch[0..encoded_bound]) orelse {
                transport.vtable.close(transport.context, connection, .overloaded);
                return true;
            };
            if (len == 0 or len > encoded_bound) return false;
            return self.writeEncrypted(transport, item, self.encoding_scratch[0..len]);
        }

        fn familySession(self: *Self, recipients: []const exchange.Connection, family: i32) ?*minecraft.Session {
            for (recipients) |recipient| {
                const item = self.find(recipient) orelse continue;
                if (item.protocol == family and item.codec != null) return item;
            }
            return null;
        }

        fn flushOutput(self: *Self, transport: exchange.Transport) void {
            var delivered: usize = 0;
            while (delivered < batch_capacity) {
                var selected: ?usize = null;
                for (0..capacity) |offset| {
                    const index = (self.delivery_cursor + offset) % capacity;
                    if (self.delivery_queues[index].len == 0 or !self.occupied[index]) continue;
                    const connection = self.sessions[index].connection;
                    const item = self.find(connection) orelse continue;
                    const delivery = &self.deliveries[index][self.delivery_queues[index].head];
                    const frame: usize = delivery.frame;
                    const credit = transport.vtable.output_credit(transport.context, connection);
                    if (credit == 0) continue;
                    const remaining = @as(usize, self.prepared_frames[frame].len) - delivery.offset;
                    const length = @min(remaining, @min(credit, prepared_page_bytes));
                    if (!self.writePreparedRange(transport, item, frame, delivery.offset, length)) continue;
                    delivery.offset += @intCast(length);
                    self.delivery_queues[index].bytes -= @intCast(length);
                    if (delivery.offset == self.prepared_frames[frame].len) self.dequeuePrepared(connection);
                    selected = index;
                    break;
                }
                const index = selected orelse return;
                self.delivery_cursor = (index + 1) % capacity;
                delivered += 1;
            }
        }

        fn writeClear(_: *Self, transport: exchange.Transport, connection: exchange.Connection, bytes: []const u8) bool {
            if (bytes.len == 0 or transport.vtable.output_credit(transport.context, connection) < bytes.len) return false;
            const written = transport.vtable.write(transport.context, connection, bytes);
            std.debug.assert(written);
            return true;
        }

        fn writeEncrypted(_: *Self, transport: exchange.Transport, item: *minecraft.Session, bytes: []u8) bool {
            if (transport.vtable.output_credit(transport.context, item.connection) < bytes.len) return false;
            item.encrypt(bytes);
            const written = transport.vtable.write(transport.context, item.connection, bytes);
            std.debug.assert(written);
            return true;
        }

        fn writePreparedRange(self: *Self, transport: exchange.Transport, item: *minecraft.Session, frame: usize, offset: usize, len: usize) bool {
            std.debug.assert(len != 0 and offset + len <= self.prepared_frames[frame].len);
            if (transport.vtable.reserve_output(transport.context, item.connection, len)) |destination| {
                const bytes = self.copyPreparedRange(frame, offset, destination);
                item.encrypt(bytes);
                const committed = transport.vtable.commit_output(transport.context, item.connection, len);
                std.debug.assert(committed);
                self.transport_direct_bytes +%= len;
                return true;
            }
            const bytes = self.copyPreparedRange(frame, offset, self.encoding_scratch[0..len]);
            self.transport_fallback_copy_bytes +%= len * 2;
            return self.writeEncrypted(transport, item, bytes);
        }

        fn copyPreparedRange(self: *const Self, frame: usize, start: usize, output: []u8) []u8 {
            const value = self.prepared_frames[frame];
            std.debug.assert(value.occupied and start + output.len <= value.len);
            var source = start;
            var destination: usize = 0;
            while (destination != output.len) {
                const page = value.pages[source / prepared_page_bytes];
                const page_offset = source % prepared_page_bytes;
                const len = @min(output.len - destination, prepared_page_bytes - page_offset);
                @memcpy(output[destination..][0..len], self.prepared_pages[page][page_offset..][0..len]);
                source += len;
                destination += len;
            }
            return output;
        }

        pub fn copyMetrics(self: *const Self) struct { prepared: u64, direct: u64, fallback: u64 } {
            return .{
                .prepared = self.prepared_copy_bytes,
                .direct = self.transport_direct_bytes,
                .fallback = self.transport_fallback_copy_bytes,
            };
        }

        pub fn queueMetrics(self: *const Self) QueueMetrics {
            var result = QueueMetrics{};
            for (self.prepared_frames) |frame| {
                if (!frame.occupied) continue;
                result.frames += 1;
                result.prepared += frame.len;
            }
            for (self.delivery_queues) |queue| result.deliveries += queue.bytes;
            return result;
        }

        fn route(self: *Self, transport: exchange.Transport, item: *minecraft.Session, codec: minecraft.Codec, packet: minecraft.Packet) bool {
            const disposition = codec.vtable.classify(codec.context, item.phase, packet);
            switch (disposition) {
                .core => self.appendPacketView(item, packet, false),
                .begin_login => |name| self.startAuthentication(transport, item, name),
                .encryption_response => |response| self.completeEncryption(transport, item, response.shared_secret, response.verify_token),
                .login_acknowledged => item.enterConfiguration(),
                .configuration_known_packs => {},
                .finish_configuration => self.attach(transport, item),
                .ignored => if (item.phase == .play) self.appendPacketView(item, packet, true),
                .status_request, .status_ping => {
                    transport.vtable.close(transport.context, item.connection, .malformed_packet);
                    return false;
                },
                .invalid => if (item.phase == .play) self.appendPacketView(item, packet, false) else {
                    transport.vtable.close(transport.context, item.connection, .malformed_packet);
                    return false;
                },
            }
            return true;
        }

        fn appendPacketView(self: *Self, item: *const minecraft.Session, packet: minecraft.Packet, claimed: bool) void {
            std.debug.assert(self.packet_view_count < batch_capacity);
            const index = self.packet_view_count;
            self.packet_views[index] = .{
                .connection = item.connection,
                .protocol = item.protocol,
                .phase = item.phase,
                .id = packet.id,
                .bytes = packetBody(packet.bytes),
                .ticket = @intCast(index),
            };
            self.packet_claimed[index] = claimed;
            self.packet_view_count += 1;
            self.markInputPending(item.connection);
        }

        fn packetBody(bytes: []const u8) []const u8 {
            for (0..@min(bytes.len, 5)) |index| {
                if (bytes[index] & 0x80 == 0) return bytes[index + 1 ..];
            }
            unreachable;
        }

        fn startAuthentication(self: *Self, transport: exchange.Transport, item: *minecraft.Session, name: []const u8) void {
            if (item.name.len != 0) return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            const auth = self.authentication orelse {
                if (name.len > item.name.bytes.len) return transport.vtable.close(transport.context, item.connection, .malformed_packet);
                @memcpy(item.name.bytes[0..name.len], name);
                item.name.len = @intCast(name.len);
                return;
            };
            if (auth.max_pending != 0 and self.pendingAuthentication() >= auth.max_pending) return transport.vtable.close(transport.context, item.connection, .overloaded);
            if (name.len > item.name.bytes.len) return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            @memcpy(item.name.bytes[0..name.len], name);
            item.name.len = @intCast(name.len);
            item.auth_deadline_ns = self.now_ns +| self.authentication_timeout_ns;
            self.applyAuthentication(transport, item, auth.vtable.start(auth.context, .{ .connection = item.connection, .username = name, .deadline_ns = item.auth_deadline_ns }));
        }

        fn completeEncryption(self: *Self, transport: exchange.Transport, item: *minecraft.Session, shared_secret: []const u8, verify_token: []const u8) void {
            const auth = self.authentication orelse return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            if (item.authentication_pending or !item.authentication_challenged) return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            item.authentication_challenged = false;
            self.applyAuthentication(transport, item, auth.vtable.respond(auth.context, .{
                .connection = item.connection,
                .username = item.name.slice(),
                .shared_secret = shared_secret,
                .verify_token = verify_token,
                .deadline_ns = item.auth_deadline_ns,
            }));
        }

        fn applyAuthentication(self: *Self, transport: exchange.Transport, item: *minecraft.Session, result: api.Authentication.Result) void {
            switch (result) {
                .pending => {
                    item.authentication_pending = true;
                },
                .encryption_request => |request| {
                    item.authentication_challenged = true;
                    self.sendEncryptionRequest(transport, item, request);
                },
                .accepted => |accepted| {
                    item.uuid = accepted.uuid;
                    if (accepted.secret) |secret| item.enableEncryption(secret);
                    self.sendLoginSuccess(transport, item);
                },
                .rejected => transport.vtable.close(transport.context, item.connection, .authentication_failed),
            }
        }

        fn sendEncryptionRequest(self: *Self, transport: exchange.Transport, item: *minecraft.Session, request: api.Authentication.EncryptionRequest) void {
            const codec = item.codec orelse return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            const emit = codec.vtable.encryption_request orelse return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            const slot: usize = @intCast(item.connection.index);
            const len = emit(codec.context, item, request, &self.status_cache[slot]) orelse
                return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            if (len == 0 or len > self.status_cache[slot].len) return transport.vtable.close(transport.context, item.connection, .overloaded);
            self.login_output_len[slot] = @intCast(len);
            self.login_output_encrypted[slot] = false;
            self.flushOneLoginOutput(transport, item);
        }

        fn sendLoginSuccess(self: *Self, transport: exchange.Transport, item: *minecraft.Session) void {
            const codec = item.codec orelse return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            const emit = codec.vtable.login_success orelse return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            const slot: usize = @intCast(item.connection.index);
            const bytes = &self.status_cache[slot];
            var used: usize = 0;
            if (self.compression_threshold) |threshold| {
                const set = codec.vtable.set_compression orelse {
                    return transport.vtable.close(transport.context, item.connection, .malformed_packet);
                };
                used = set(codec.context, item, threshold, bytes) orelse {
                    return transport.vtable.close(transport.context, item.connection, .malformed_packet);
                };
                item.compression_threshold = threshold;
            }
            const success = emit(codec.context, item, item.uuid, item.name.slice(), bytes[used..]) orelse {
                item.compression_threshold = null;
                return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            };
            const len = used + success;
            if (len == 0 or len > bytes.len) {
                item.compression_threshold = null;
                return transport.vtable.close(transport.context, item.connection, .overloaded);
            }
            self.login_output_len[slot] = @intCast(len);
            self.login_output_encrypted[slot] = true;
            self.flushOneLoginOutput(transport, item);
        }

        fn flushLoginOutput(self: *Self, transport: exchange.Transport) void {
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (!occupied) continue;
                self.flushOneLoginOutput(transport, item);
            }
        }

        fn flushOneLoginOutput(self: *Self, transport: exchange.Transport, item: *minecraft.Session) void {
            const slot: usize = @intCast(item.connection.index);
            const len = self.login_output_len[slot];
            if (len == 0) return;
            const bytes = self.status_cache[slot][0..len];
            const written = if (self.login_output_encrypted[slot])
                self.writeEncrypted(transport, item, bytes)
            else
                self.writeClear(transport, item.connection, bytes);
            if (written) self.login_output_len[slot] = 0;
        }

        fn pollAuthentication(self: *Self, transport: exchange.Transport, now_ns: u64) void {
            const auth = self.authentication orelse return;
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (!occupied) continue;
                if (!item.authentication_pending and !item.authentication_challenged) continue;
                if (now_ns >= item.auth_deadline_ns) {
                    item.authentication_pending = false;
                    item.authentication_challenged = false;
                    auth.vtable.cancel(auth.context, item.connection);
                    transport.vtable.close(transport.context, item.connection, .timeout);
                    continue;
                }
                if (item.authentication_challenged) continue;
                const result = auth.vtable.poll(auth.context, item.connection);
                switch (result) {
                    .pending => {},
                    .accepted, .encryption_request => {
                        item.authentication_pending = false;
                        self.applyAuthentication(transport, item, result);
                    },
                    .rejected => {
                        item.authentication_pending = false;
                        transport.vtable.close(transport.context, item.connection, .authentication_failed);
                    },
                }
            }
        }

        fn pendingAuthentication(self: *const Self) u16 {
            var count: u16 = 0;
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (occupied and (item.authentication_pending or item.authentication_challenged)) count += 1;
            }
            return count;
        }

        fn configurationPlanSteps(self: *const Self) u8 {
            return @intCast(self.configuration_plan.entries.len + 1);
        }

        fn configurationPacket(self: *const Self, codec: minecraft.Codec, item: *minecraft.Session, output: []u8) ?usize {
            if (self.configuration_plan.at(item.configuration_step)) |entry| {
                const encode = codec.vtable.configuration_entry orelse return null;
                return encode(codec.context, item, entry, output);
            }
            if (item.configuration_step == self.configuration_plan.entries.len)
                return (codec.vtable.finish_configuration orelse return null)(codec.context, item, output);
            return null;
        }

        fn attach(self: *Self, transport: exchange.Transport, item: *minecraft.Session) void {
            if (item.configuration_step != self.configurationPlanSteps()) return transport.vtable.close(transport.context, item.connection, .malformed_packet);
            const reconfiguring = item.attached;
            if (self.attachment_count == batch_capacity or (!item.finishConfiguration() and !reconfiguring)) return transport.vtable.close(transport.context, item.connection, .overloaded);
            self.attachments[self.attachment_count] = .{ .connection = item.connection, .uuid = item.uuid, .protocol = item.protocol, .name = item.name.bytes, .name_len = item.name.len, .reconfiguring = reconfiguring };
            self.attachment_count += 1;
            self.markInputPending(item.connection);
            std.log.info("event=session_play_attached connection={d}:{d} protocol={d} reconfiguring={}", .{ item.connection.index, item.connection.generation, item.protocol, reconfiguring });
        }

        fn flushConfiguration(self: *Self, transport: exchange.Transport) void {
            for (&self.sessions, self.occupied) |*item, occupied| {
                if (!occupied) continue;
                if (item.phase != .configuration or item.configuration_barrier or item.configuration_step >= self.configurationPlanSteps()) continue;
                const codec = item.codec orelse {
                    transport.vtable.close(transport.context, item.connection, .malformed_packet);
                    continue;
                };
                const len = self.configurationPacket(codec, item, &self.encoding_scratch) orelse {
                    transport.vtable.close(transport.context, item.connection, .malformed_packet);
                    continue;
                };
                if (len == 0 or len > self.encoding_scratch.len) return transport.vtable.close(transport.context, item.connection, .overloaded);
                if (!self.writeEncrypted(transport, item, self.encoding_scratch[0..len])) continue;
                item.configuration_step += 1;
            }
        }

        fn startConfiguration(self: *Self, transport: exchange.Transport, handle: exchange.Connection) bool {
            const item = self.find(handle) orelse return true;
            if (item.phase != .play) return true;
            const codec = item.codec orelse {
                transport.vtable.close(transport.context, handle, .malformed_packet);
                return true;
            };
            const len = codec.vtable.start_configuration(codec.context, item, &self.encoding_scratch) orelse {
                transport.vtable.close(transport.context, handle, .malformed_packet);
                return true;
            };
            if (len == 0 or len > self.encoding_scratch.len) return true;
            if (!self.writeEncrypted(transport, item, self.encoding_scratch[0..len])) return false;
            _ = item.reconfigure();
            return true;
        }

        fn processRetained(self: *Self, transport: exchange.Transport, snapshot: api.StatusSnapshot) void {
            const start = self.retained_cursor;
            for (0..capacity) |step| {
                const index = (start + step) % capacity;
                if (!self.occupied[index]) continue;
                const item = &self.sessions[index];
                if (self.inputPending(item.connection)) continue;
                const id = item.retained_page orelse continue;
                self.retained_cursor = (index + 1) % capacity;
                const page = transport.vtable.input_page(transport.context, id) orelse {
                    transport.vtable.close(transport.context, item.connection, .malformed_packet);
                    continue;
                };
                const offset: usize = @intCast(item.retained_offset);
                if (offset >= page.bytes.len) return self.reject(transport, item.connection, id, .malformed_packet);
                const rest = exchange.InputPage{ .id = id, .bytes = page.bytes[offset..] };
                switch (item.phase) {
                    .handshake => self.handshake(transport, item, rest),
                    .status => self.status(transport, item, rest, snapshot),
                    .login, .configuration, .play => self.decode(transport, item, rest),
                }
            }
        }

        fn consumeOrRetain(self: *Self, transport: exchange.Transport, item: *minecraft.Session, page: exchange.InputPage, consumed: usize, uses_page: bool) void {
            const base: usize = if (item.retained_page != null and @intFromEnum(item.retained_page.?) == @intFromEnum(page.id)) @intCast(item.retained_offset) else 0;
            if (consumed < page.bytes.len) {
                item.retained_page = page.id;
                item.retained_offset = @intCast(base + consumed);
                if (uses_page) self.markRetainedInputBorrowed(item.connection) else self.clearRetainedInputBorrowed(item.connection);
                return;
            }
            item.retained_page = null;
            item.retained_offset = 0;
            self.clearRetainedInputBorrowed(item.connection);
            if (uses_page) {
                self.held_pages[self.held_count] = page.id;
                self.held_connections[self.held_count] = item.connection;
                self.held_count += 1;
            } else transport.vtable.release_input(transport.context, page.id);
        }

        fn retain(_: *Self, item: *minecraft.Session, page: exchange.Page) void {
            if (item.retained_page) |current| {
                std.debug.assert(@intFromEnum(current) == @intFromEnum(page));
                return;
            }
            item.retained_page = page;
            item.retained_offset = 0;
        }

        fn reject(self: *Self, transport: exchange.Transport, handle: exchange.Connection, page: exchange.Page, reason: exchange.DisconnectReason) void {
            if (self.find(handle)) |item| if (item.retained_page != null and @intFromEnum(item.retained_page.?) == @intFromEnum(page)) {
                item.retained_page = null;
                item.retained_offset = 0;
                self.clearRetainedInputBorrowed(handle);
            };
            transport.vtable.release_input(transport.context, page);
            transport.vtable.close(transport.context, handle, reason);
        }
        fn detach(self: *Self, transport: exchange.Transport, handle: exchange.Connection, reason: exchange.DisconnectReason) void {
            const item = self.find(handle) orelse return;
            self.releaseOrHoldRetained(transport, item);
            if (item.authentication_pending or item.authentication_challenged) if (self.authentication) |auth| auth.vtable.cancel(auth.context, handle);
            if (item.attached and self.detachment_count < batch_capacity) {
                self.detachments[self.detachment_count] = .{ .connection = handle, .reason = reason };
                self.detachment_count += 1;
                self.markInputPending(handle);
            } else if (item.attached) {
                item.closing = reason;
                return;
            }
            self.login_output_len[handle.index] = 0;
            self.dropPreparedQueue(handle);
            self.occupied[handle.index] = false;
        }

        fn flushDetaches(self: *Self) void {
            for (&self.sessions, self.occupied, 0..) |*item, occupied, index| {
                if (!occupied) continue;
                const reason = item.closing orelse continue;
                if (!item.attached) continue;
                if (self.detachment_count == batch_capacity) return;
                if (item.retained_page) |page| {
                    if (self.held_count == self.held_pages.len) return;
                    self.held_pages[self.held_count] = page;
                    self.held_connections[self.held_count] = item.connection;
                    self.held_count += 1;
                    item.retained_page = null;
                    item.retained_offset = 0;
                    self.clearRetainedInputBorrowed(item.connection);
                }
                self.detachments[self.detachment_count] = .{ .connection = item.connection, .reason = reason };
                self.detachment_count += 1;
                self.markInputPending(item.connection);
                self.dropPreparedQueue(item.connection);
                self.occupied[index] = false;
            }
        }

        fn releaseClosingUnattached(self: *Self, transport: exchange.Transport) void {
            for (&self.sessions, self.occupied, 0..) |*item, occupied, index| {
                if (!occupied or item.attached or item.closing == null) continue;
                self.releaseOrHoldRetained(transport, item);
                self.dropPreparedQueue(item.connection);
                self.occupied[index] = false;
            }
        }

        fn releaseOrHoldRetained(self: *Self, transport: exchange.Transport, item: *minecraft.Session) void {
            const page = item.retained_page orelse return;
            if (self.retainedInputBorrowed(item.connection)) {
                std.debug.assert(self.held_count != self.held_pages.len);
                self.held_pages[self.held_count] = page;
                self.held_connections[self.held_count] = item.connection;
                self.held_count += 1;
            } else transport.vtable.release_input(transport.context, page);
            item.retained_page = null;
            item.retained_offset = 0;
            self.clearRetainedInputBorrowed(item.connection);
        }

        fn dropPreparedQueue(self: *Self, connection: exchange.Connection) void {
            while (self.delivery_queues[connection.index].len != 0) self.dequeuePrepared(connection);
        }
        fn find(self: *Self, handle: exchange.Connection) ?*minecraft.Session {
            if (handle.index >= capacity) return null;
            if (!self.occupied[handle.index]) return null;
            const item = &self.sessions[handle.index];
            if (item.connection.eql(handle)) return item;
            return null;
        }

        fn findConst(self: *const Self, handle: exchange.Connection) ?*const minecraft.Session {
            if (handle.index >= capacity) return null;
            if (!self.occupied[handle.index]) return null;
            const item = &self.sessions[handle.index];
            if (item.connection.eql(handle)) return item;
            return null;
        }

        fn validateOneResume(self: *const Self, item: *const minecraft.Session, capacity_bytes: usize) bool {
            for (self.packet_views[0..self.packet_view_count]) |view| if (view.connection.eql(item.connection)) return false;
            for (self.attachments[0..self.attachment_count]) |attachment| if (attachment.connection.eql(item.connection)) return false;
            for (self.detachments[0..self.detachment_count]) |detachment| if (detachment.connection.eql(item.connection)) return false;
            for (self.held_connections[0..self.held_count]) |handle| if (handle.eql(item.connection)) return false;
            const resumable_phase = item.phase == .configuration or item.phase == .play;
            return resumable_phase and item.protocol != 0 and item.codec != null and item.uuid != 0 and item.name.len != 0 and
                item.configuration_step <= self.configurationPlanSteps() and !item.authentication_pending and !item.authentication_challenged and item.retained_page == null and !item.codec_state_exposed and
                resume_fixed_bytes + item.name.len + item.status_ping_len + item.codec_state_len <= capacity_bytes;
        }

        const ResumeWriter = struct {
            bytes: []u8,
            len: usize = 0,

            fn int(self: *ResumeWriter, comptime T: type, value: T) error{NoSpace}!void {
                if (@sizeOf(T) > self.bytes.len - self.len) return error.NoSpace;
                @import("std").mem.writeInt(T, self.bytes[self.len..][0..@sizeOf(T)], value, .little);
                self.len += @sizeOf(T);
            }
            fn write(self: *ResumeWriter, value: []const u8) error{NoSpace}!void {
                if (value.len > self.bytes.len - self.len) return error.NoSpace;
                @memcpy(self.bytes[self.len..][0..value.len], value);
                self.len += value.len;
            }
        };

        const ResumeReader = struct {
            bytes: []const u8,
            offset: usize = 0,

            fn remaining(self: *const ResumeReader) []const u8 {
                return self.bytes[self.offset..];
            }
            fn take(self: *ResumeReader, len: usize) ?[]const u8 {
                if (len > self.bytes.len - self.offset) return null;
                const value = self.bytes[self.offset..][0..len];
                self.offset += len;
                return value;
            }
            fn int(self: *ResumeReader, comptime T: type) ?T {
                const value = self.take(@sizeOf(T)) orelse return null;
                return @import("std").mem.readInt(T, @ptrCast(value.ptr), .little);
            }
            fn enumValue(self: *ResumeReader, comptime E: type) ?E {
                const Tag = @import("std").meta.Tag(E);
                const value = self.int(Tag) orelse return null;
                return @import("std").enums.fromInt(E, value);
            }
        };

        fn writeCipher(writer: *ResumeWriter, value: ?crypto.Cfb8) error{NoSpace}!void {
            if (value) |cipher| {
                const snapshot = cipher.snapshot();
                try writer.int(u8, 1);
                try writer.write(&snapshot.secret);
                try writer.write(&snapshot.feedback);
            } else try writer.int(u8, 0);
        }

        const CipherRead = struct { value: ?crypto.Cfb8 };

        fn readCipher(reader: *ResumeReader) ?CipherRead {
            const present = reader.int(u8) orelse return null;
            if (present == 0) return .{ .value = null };
            if (present != 1) return null;
            var snapshot: crypto.Cfb8.Snapshot = undefined;
            @memcpy(&snapshot.secret, reader.take(snapshot.secret.len) orelse return null);
            @memcpy(&snapshot.feedback, reader.take(snapshot.feedback.len) orelse return null);
            return .{ .value = crypto.Cfb8.restore(snapshot) };
        }

        fn protocol(self: *const Self, number: i32) ?minecraft.Protocol {
            for (self.protocols) |value| if (value.number == number) return value;
            return null;
        }
    };
}

fn testOutputCredit(_: *anyopaque, _: exchange.Connection) usize {
    return std.math.maxInt(usize);
}

fn testNoOutputCredit(_: *anyopaque, _: exchange.Connection) usize {
    return 0;
}

fn testOutputMetrics(_: *anyopaque, _: exchange.Connection) ?exchange.OutputMetrics {
    return .{ .queued_bytes = 0, .capacity_bytes = std.math.maxInt(usize) };
}

fn testWrite(_: *anyopaque, _: exchange.Connection, _: []const u8) bool {
    return true;
}

test "configuration plan locks when the first connection is admitted" {
    const T = Table(1, 1);
    const State = struct { closes: usize = 0 };
    const Stub = struct {
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn inputPage(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn input(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn release(_: *anyopaque, _: exchange.Page) void {}
        fn close(raw: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {
            const state: *State = @ptrCast(@alignCast(raw));
            state.closes += 1;
        }
        fn submit(_: *anyopaque) void {}
    };
    const first: configuration.Plan = .{ .entries = &.{.{ .tags = .{ .payload = &.{0} } }} };
    const replacement: configuration.Plan = .{ .entries = &.{.{ .feature_flags = .{ .values = &.{"minecraft:vanilla"} } }} };
    var state = State{};
    const transport = exchange.Transport{ .context = &state, .vtable = &.{ .complete = Stub.complete, .input_page = Stub.input, .output_credit = testOutputCredit, .output_metrics = testOutputMetrics, .write = testWrite, .release_input = Stub.release, .close = Stub.close, .submit = Stub.submit } };
    var table = T{};
    try std.testing.expect(table.setConfigurationPlan(first));
    table.accept(transport, .{ .index = 0, .generation = 1 });
    try std.testing.expectEqual(@as(usize, 0), state.closes);
    table.occupied[0] = false;
    try std.testing.expect(!table.setConfigurationPlan(replacement));
}

test "configuration finish is accepted only after every plan entry" {
    const T = Table(1, 1);
    const State = struct { closes: usize = 0 };
    const Stub = struct {
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn input(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn release(_: *anyopaque, _: exchange.Page) void {}
        fn close(raw: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {
            const state: *State = @ptrCast(@alignCast(raw));
            state.closes += 1;
        }
        fn submit(_: *anyopaque) void {}
    };
    var state = State{};
    const transport = exchange.Transport{ .context = &state, .vtable = &.{ .complete = Stub.complete, .input_page = Stub.input, .output_credit = testOutputCredit, .output_metrics = testOutputMetrics, .write = testWrite, .release_input = Stub.release, .close = Stub.close, .submit = Stub.submit } };
    var table = T{};
    try std.testing.expect(table.setConfigurationPlan(.{ .entries = &.{.{ .tags = .{ .payload = &.{0} } }} }));
    table.sessions[0] = .{ .connection = .{ .index = 0, .generation = 1 }, .phase = .configuration };
    table.occupied[0] = true;

    table.attach(transport, &table.sessions[0]);
    try std.testing.expectEqual(@as(usize, 1), state.closes);
    try std.testing.expectEqual(api.Phase.configuration, table.sessions[0].phase);

    table.sessions[0].configuration_step = table.configurationPlanSteps();
    table.attach(transport, &table.sessions[0]);
    try std.testing.expectEqual(@as(usize, 1), table.attachment_count);
    try std.testing.expectEqual(api.Phase.play, table.sessions[0].phase);
}

test "Core reconfiguration enters the configuration schedule after Start Configuration" {
    const T = Table(1, 2);
    const State = struct {
        bytes: [8]u8 = undefined,
        sent: [3]u8 = undefined,
        count: usize = 0,
        available: bool = true,
        closes: usize = 0,
    };
    const CodecStub = struct {
        fn init(_: *anyopaque, _: *minecraft.Session) bool {
            return true;
        }
        fn decode(_: *anyopaque, _: *minecraft.Session, _: []const u8, _: []minecraft.Packet) minecraft.Codec.Decode {
            return .{ .progress = .{ .consumed = 0, .packets = 0, .needs_more = true } };
        }
        fn finish(_: *anyopaque, _: *minecraft.Session) void {}
        fn classify(_: *anyopaque, _: api.Phase, _: minecraft.Packet) minecraft.Disposition {
            return .invalid;
        }
        fn start(_: *anyopaque, _: *minecraft.Session, output: []u8) ?usize {
            output[0] = 0xa1;
            return 1;
        }
        fn entry(_: *anyopaque, _: *minecraft.Session, _: configuration.Entry, output: []u8) ?usize {
            output[0] = 0xb2;
            return 1;
        }
        fn finish_configuration(_: *anyopaque, _: *minecraft.Session, output: []u8) ?usize {
            output[0] = 0xc3;
            return 1;
        }
        fn capacity(_: *anyopaque, _: *const minecraft.Session, _: i32, _: []const u8) ?usize {
            return 1;
        }
        fn encode(_: *anyopaque, _: *minecraft.Session, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
        fn status(_: *anyopaque, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
    };
    const TransportStub = struct {
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn input(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn credit(raw: *anyopaque, _: exchange.Connection) usize {
            const state: *State = @ptrCast(@alignCast(raw));
            return if (state.available) state.bytes.len else 0;
        }
        fn metrics(_: *anyopaque, _: exchange.Connection) ?exchange.OutputMetrics {
            return null;
        }
        fn release(_: *anyopaque, _: exchange.Page) void {}
        fn write(raw: *anyopaque, _: exchange.Connection, bytes: []const u8) bool {
            const state: *State = @ptrCast(@alignCast(raw));
            if (!state.available or state.count == state.sent.len or bytes.len == 0) return false;
            state.sent[state.count] = bytes[0];
            state.count += 1;
            state.available = false;
            return true;
        }
        fn close(raw: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {
            const state: *State = @ptrCast(@alignCast(raw));
            state.closes += 1;
        }
        fn submit(_: *anyopaque) void {}
    };
    var codec_context: u8 = 0;
    const codec = minecraft.Codec{ .context = &codec_context, .vtable = &.{ .init = CodecStub.init, .decode = CodecStub.decode, .finish_input = CodecStub.finish, .classify = CodecStub.classify, .start_configuration = CodecStub.start, .configuration_entry = CodecStub.entry, .finish_configuration = CodecStub.finish_configuration, .encoded_capacity = CodecStub.capacity, .encode = CodecStub.encode, .status = CodecStub.status } };
    var state = State{};
    const transport = exchange.Transport{ .context = &state, .vtable = &.{ .complete = TransportStub.complete, .input_page = TransportStub.input, .output_credit = TransportStub.credit, .output_metrics = TransportStub.metrics, .write = TransportStub.write, .release_input = TransportStub.release, .close = TransportStub.close, .submit = TransportStub.submit } };
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    var table = T{};
    try std.testing.expect(table.setConfigurationPlan(.{ .entries = &.{.{ .tags = .{ .payload = &.{0} } }} }));
    table.sessions[0] = .{ .connection = connection, .phase = .play, .protocol = 772, .codec = codec };
    table.occupied[0] = true;
    try std.testing.expect(table.startConfiguration(transport, connection));
    try std.testing.expectEqual(api.Phase.configuration, table.sessions[0].phase);
    table.flushConfiguration(transport);
    try std.testing.expectEqual(@as(usize, 0), state.closes);
    try std.testing.expectEqual(@as(u8, 0), table.sessions[0].configuration_step);
    state.available = true;
    table.flushConfiguration(transport);
    state.available = true;
    table.flushConfiguration(transport);
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0xb2, 0xc3 }, state.sent[0..state.count]);
    try std.testing.expectEqual(table.configurationPlanSteps(), table.sessions[0].configuration_step);
}

test "re-exec closes a pre-Play configuration session before handoff" {
    const T = Table(1, 1);
    const State = struct { closes: usize = 0 };
    const Stub = struct {
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn input(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn release(_: *anyopaque, _: exchange.Page) void {}
        fn close(raw: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {
            const state: *State = @ptrCast(@alignCast(raw));
            state.closes += 1;
        }
        fn submit(_: *anyopaque) void {}
    };
    var state = State{};
    const transport = exchange.Transport{ .context = &state, .vtable = &.{ .complete = Stub.complete, .input_page = Stub.input, .output_credit = testOutputCredit, .output_metrics = testOutputMetrics, .write = testWrite, .release_input = Stub.release, .close = Stub.close, .submit = Stub.submit } };
    var table = T{};
    table.sessions[0] = .{ .connection = .{ .index = 0, .generation = 1 }, .phase = .configuration };
    table.occupied[0] = true;
    try std.testing.expectEqual(api.Admission.accepted, table.advanceReconfigurationWithTransport(transport));
    try std.testing.expectEqual(@as(usize, 1), state.closes);
    try std.testing.expect(!table.occupied[0]);
    try std.testing.expect(table.configurationBarrierStaged());
}

test "replacement barrier suppresses the predecessor configuration plan" {
    const T = Table(1, 1);
    const State = struct { acquires: usize = 0 };
    const Stub = struct {
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn input(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn release(_: *anyopaque, _: exchange.Page) void {}
        fn close(_: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {}
        fn submit(_: *anyopaque) void {}
    };
    var state = State{};
    const transport = exchange.Transport{ .context = &state, .vtable = &.{ .complete = Stub.complete, .input_page = Stub.input, .output_credit = testOutputCredit, .output_metrics = testOutputMetrics, .write = testWrite, .release_input = Stub.release, .close = Stub.close, .submit = Stub.submit } };
    var table = T{};
    try std.testing.expect(table.setConfigurationPlan(.{ .entries = &.{.{ .tags = .{ .payload = &.{0} } }} }));
    table.sessions[0] = .{ .connection = .{ .index = 0, .generation = 1 }, .phase = .configuration, .attached = true, .configuration_barrier = true };
    table.occupied[0] = true;
    table.flushConfiguration(transport);
    try std.testing.expectEqual(@as(usize, 0), state.acquires);
    try std.testing.expectEqual(@as(u8, 0), table.sessions[0].configuration_step);

    table.accepting = false;
    table.abortReconfigurationWithTransport(transport);
    try std.testing.expect(table.accepting);
    try std.testing.expect(!table.sessions[0].configuration_barrier);
}

test "session resume preserves opaque selected codec state" {
    const T = Table(1, 1);
    const Stub = struct {
        fn init(_: *anyopaque, _: *minecraft.Session) bool {
            return true;
        }
        fn decode(_: *anyopaque, _: *minecraft.Session, _: []const u8, _: []minecraft.Packet) minecraft.Codec.Decode {
            return .{ .progress = .{ .consumed = 0, .packets = 0, .needs_more = true } };
        }
        fn finish(_: *anyopaque, _: *minecraft.Session) void {}
        fn classify(_: *anyopaque, _: api.Phase, _: minecraft.Packet) minecraft.Disposition {
            return .invalid;
        }
        fn start(_: *anyopaque, _: *minecraft.Session, _: []u8) ?usize {
            return null;
        }
        fn capacity(_: *anyopaque, _: *const minecraft.Session, _: i32, _: []const u8) ?usize {
            return null;
        }
        fn encode(_: *anyopaque, _: *minecraft.Session, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
        fn status(_: *anyopaque, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
    };
    var context: u8 = 0;
    const codec = minecraft.Codec{ .context = &context, .vtable = &.{ .init = Stub.init, .decode = Stub.decode, .finish_input = Stub.finish, .classify = Stub.classify, .start_configuration = Stub.start, .encoded_capacity = Stub.capacity, .encode = Stub.encode, .status = Stub.status } };
    const protocol = minecraft.Protocol{ .number = 772, .codec = codec };
    var source = T{};
    try std.testing.expect(source.setProtocols(&.{protocol}));
    var session = minecraft.Session{ .connection = .{ .index = 0, .generation = 7 }, .phase = .configuration, .protocol = 772, .uuid = 9, .attached = true, .codec = codec, .compression_threshold = 256 };
    session.name.len = 3;
    @memcpy(session.name.bytes[0..3], "cat");
    session.enableEncryption([_]u8{0x42} ** 16);
    session.codec_state_len = 3;
    @memcpy(session.codec_state[0..3], "raw");
    source.sessions[0] = session;
    source.occupied[0] = true;
    var bytes: [256]u8 = undefined;
    const encoded = source.encodeResume(session.connection, &bytes).?;
    var restored = T{};
    try std.testing.expect(restored.setProtocols(&.{protocol}));
    try std.testing.expect(restored.restoreResume(session.connection, T.resume_id, T.resume_version, encoded));
    const actual = restored.sessions[0];
    try std.testing.expectEqual(session.phase, actual.phase);
    try std.testing.expectEqual(session.protocol, actual.protocol);
    try std.testing.expectEqual(session.uuid, actual.uuid);
    try std.testing.expectEqualStrings("cat", actual.name.slice());
    try std.testing.expectEqualSlices(u8, "raw", actual.codec_state[0..actual.codec_state_len]);
    try std.testing.expect(actual.encryptor != null and actual.decryptor != null);
    try std.testing.expect(!restored.setConfigurationPlan(.{ .entries = &.{.{ .tags = .{ .payload = &.{0} } }} }));
}

test "authentication progresses while Core input is backpressured" {
    const State = struct {
        polls: usize = 0,
        cancellations: usize = 0,
        closed: [3]?exchange.DisconnectReason = @splat(null),
        fn poll(raw: *anyopaque, handle: exchange.Connection) api.Authentication.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(handle.index == 1);
            self.polls += 1;
            return .rejected;
        }
        fn cancel(raw: *anyopaque, handle: exchange.Connection) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(handle.index == 2);
            self.cancellations += 1;
        }
        fn close(raw: *anyopaque, handle: exchange.Connection, reason: exchange.DisconnectReason) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.closed[handle.index] == null);
            self.closed[handle.index] = reason;
        }
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
    };
    var state = State{};
    var transport_vtable: exchange.Transport.VTable = undefined;
    transport_vtable.complete = State.complete;
    transport_vtable.close = State.close;
    const transport = exchange.Transport{ .context = &state, .vtable = &transport_vtable };
    var auth_vtable: api.Authentication.VTable = undefined;
    auth_vtable.poll = State.poll;
    auth_vtable.cancel = State.cancel;
    var table = Table(3, 1){};
    table.initialize();
    var io = std.testing.io;
    table.authentication = .{ .context = &state, .vtable = &auth_vtable, .io = &io, .max_pending = 2 };
    for (&table.sessions, &table.occupied, 0..) |*item, *occupied, index| {
        item.* = .{ .connection = .{ .index = @intCast(index), .generation = 1 }, .phase = if (index == 0) .play else .login };
        occupied.* = true;
    }
    table.sessions[1].authentication_pending = true;
    table.sessions[1].auth_deadline_ns = 10;
    table.sessions[2].authentication_challenged = true;
    table.sessions[2].auth_deadline_ns = 10;
    table.packet_view_count = 1;
    table.packet_views[0] = .{ .connection = table.sessions[0].connection, .protocol = 772, .id = 7, .bytes = "unconsumed" };
    table.packet_claimed[0] = false;
    const status = api.StatusSnapshot{ .revision = 1, .json = "{}" };
    table.advance(transport, 5, status);
    try std.testing.expectEqual(@as(usize, 1), state.polls);
    try std.testing.expectEqual(exchange.DisconnectReason.authentication_failed, state.closed[1].?);
    try std.testing.expect(state.closed[2] == null);
    table.advance(transport, 11, status);
    table.advance(transport, 12, status);
    try std.testing.expectEqual(@as(usize, 1), state.polls);
    try std.testing.expectEqual(@as(usize, 1), state.cancellations);
    try std.testing.expectEqual(exchange.DisconnectReason.timeout, state.closed[2].?);
    try std.testing.expect(state.closed[0] == null);
    try std.testing.expectEqual(@as(usize, 1), table.packet_view_count);
    try std.testing.expectEqualStrings("unconsumed", table.packet_views[0].bytes);
    try std.testing.expect(!table.packet_claimed[0]);
}

test "decode reserves input metadata before advancing any protocol phase" {
    const State = struct {
        decodes: usize = 0,
        releases: usize = 0,
        fn decode(raw: *anyopaque, _: *minecraft.Session, bytes: []const u8, output: []minecraft.Packet) minecraft.Codec.Decode {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(output.len == 1);
            self.decodes += 1;
            return .{ .progress = .{ .consumed = bytes.len, .packets = 0 } };
        }
        fn release(raw: *anyopaque, _: exchange.Page) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
    };
    var state = State{};
    var codec_vtable: minecraft.Codec.VTable = undefined;
    codec_vtable.decode = State.decode;
    var transport_vtable: exchange.Transport.VTable = undefined;
    transport_vtable.release_input = State.release;
    const transport = exchange.Transport{ .context = &state, .vtable = &transport_vtable };
    var table = Table(1, 1){};
    table.initialize();
    inline for (.{ api.Phase.login, api.Phase.configuration, api.Phase.play }, 0..) |phase, index| {
        table.sessions[0] = .{ .connection = .{ .index = 0, .generation = 1 }, .phase = phase, .codec = .{ .context = &state, .vtable = &codec_vtable } };
        table.packet_view_count = 1;
        var bytes = "packet".*;
        const page = exchange.InputPage{ .id = @enumFromInt(0), .bytes = &bytes };
        table.decode(transport, &table.sessions[0], page);
        try std.testing.expectEqual(index, state.decodes);
        try std.testing.expectEqual(index, state.releases);
        try std.testing.expect(table.sessions[0].retained_page != null);
        table.packet_view_count = 0;
        table.decode(transport, &table.sessions[0], page);
        try std.testing.expectEqual(index + 1, state.decodes);
        try std.testing.expectEqual(index + 1, state.releases);
        try std.testing.expect(table.sessions[0].retained_page == null);
    }
}

test "resume waits for connection input and detached ownership to drain" {
    var table = Table(2, 2){};
    table.initialize();
    var context: u8 = 0;
    const vtable: minecraft.Codec.VTable = undefined;
    const codec = minecraft.Codec{ .context = &context, .vtable = &vtable };
    const protocols = [_]minecraft.Protocol{.{ .number = 772, .codec = codec }};
    table.protocols = &protocols;
    const handle = exchange.Connection{ .index = 0, .generation = 1 };
    table.sessions[0] = .{ .connection = handle, .phase = .play, .protocol = 772, .uuid = 9, .codec = codec };
    table.sessions[0].name.bytes[0] = 'A';
    table.sessions[0].name.len = 1;
    table.occupied[0] = true;
    var bytes: [512]u8 = undefined;
    try std.testing.expect(table.validateResume(bytes.len));
    try std.testing.expect(table.encodeResume(handle, &bytes) != null);
    inline for (0..4) |kind| {
        switch (kind) {
            0 => {
                table.packet_views[0] = .{ .connection = handle, .protocol = 772, .id = 1, .bytes = "borrowed" };
                table.packet_view_count = 1;
            },
            1 => {
                table.attachments[0] = .{ .connection = handle, .uuid = 9, .name = @splat(0), .name_len = 0, .protocol = 772, .reconfiguring = false };
                table.attachment_count = 1;
            },
            2 => {
                table.detachments[0] = .{ .connection = handle, .reason = .timeout };
                table.detachment_count = 1;
            },
            3 => {
                table.held_connections[0] = handle;
                table.held_count = 1;
            },
            else => unreachable,
        }
        try std.testing.expect(!table.validateResume(bytes.len));
        try std.testing.expect(table.encodeResume(handle, &bytes) == null);
        table.occupied[0] = false;
        try std.testing.expect(!table.validateResume(bytes.len));
        table.occupied[0] = true;
        table.packet_view_count = 0;
        table.attachment_count = 0;
        table.detachment_count = 0;
        table.held_count = 0;
        try std.testing.expect(table.validateResume(bytes.len));
        try std.testing.expect(table.encodeResume(handle, &bytes) != null);
    }
}

test "an unauthenticated session cannot be serialized as a replacement continuation" {
    const T = Table(1, 1);
    var table = T{};
    table.sessions[0] = .{
        .connection = .{ .index = 0, .generation = 1 },
        .phase = .login,
        .protocol = 772,
        .uuid = 9,
    };
    table.occupied[0] = true;
    var bytes: [256]u8 = undefined;
    try @import("std").testing.expect(table.validateResume(bytes.len));
    try @import("std").testing.expect(table.encodeResume(.{ .index = 0, .generation = 1 }, &bytes) == null);
}

test "prepared frame is shared and released after its final recipient" {
    const T = Table(2, 4);
    var table = T{};
    table.initialize();
    const frame = table.allocatePrepared("shared", .other).?;
    try std.testing.expect(table.enqueuePrepared(.{ .index = 0, .generation = 1 }, frame));
    try std.testing.expect(table.enqueuePrepared(.{ .index = 1, .generation = 1 }, frame));
    try std.testing.expectEqual(@as(u16, 2), table.prepared_frames[frame].references);
    table.dequeuePrepared(.{ .index = 0, .generation = 1 });
    try std.testing.expect(table.prepared_frames[frame].occupied);
    table.dequeuePrepared(.{ .index = 1, .generation = 1 });
    try std.testing.expect(!table.prepared_frames[frame].occupied);
}

test "shared Core output groups include their exchange source" {
    var table = Table(2, 2){};
    table.initialize();
    const message: core_exchange.CoreToSession = .{
        .connection = .{ .index = 0, .generation = 1 },
        .kind = .packet_shared,
        .recipient_count = 2,
        .page = @enumFromInt(0),
        .len = 1,
    };
    const first_source: core_exchange.OutputSource = .{ .value = 17 };
    const second_source: core_exchange.OutputSource = .{ .value = 18 };
    const first = table.sharedGroup(first_source, message).?;
    try std.testing.expectEqual(first, table.sharedGroup(first_source, message).?);
    const second = table.sharedGroup(second_source, message).?;
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(u16, 2), table.shared_groups[first].remaining);
    try std.testing.expectEqual(@as(u16, 2), table.shared_groups[second].remaining);
    table.finishSharedMessage(first);
    try std.testing.expectEqual(@as(u16, 1), table.shared_groups[first].remaining);
    try std.testing.expectEqual(@as(u16, 2), table.shared_groups[second].remaining);
}

test "prepared queues preserve each connection order" {
    const T = Table(1, 4);
    var table = T{};
    table.initialize();
    const first = table.allocatePrepared("first", .control).?;
    const second = table.allocatePrepared("second", .control).?;
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    try std.testing.expect(table.enqueuePrepared(connection, first));
    try std.testing.expect(table.enqueuePrepared(connection, second));
    var bytes: [16]u8 = undefined;
    try std.testing.expectEqualStrings("first", table.copyPreparedRange(table.deliveries[0][0].frame, 0, bytes[0..5]));
    table.dequeuePrepared(connection);
    try std.testing.expectEqualStrings("second", table.copyPreparedRange(table.deliveries[0][1].frame, 0, bytes[0..6]));
    table.dequeuePrepared(connection);
}

test "a prepared packet larger than transport credit advances in ordered fragments" {
    const T = Table(1, 4);
    const State = struct {
        bytes: [prepared_page_bytes * 3]u8 = undefined,
        len: usize = 0,
        credit: usize = prepared_page_bytes,
    };
    const Stub = struct {
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn input(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn credit(raw: *anyopaque, _: exchange.Connection) usize {
            const state: *State = @ptrCast(@alignCast(raw));
            return state.credit;
        }
        fn metrics(raw: *anyopaque, _: exchange.Connection) ?exchange.OutputMetrics {
            const state: *State = @ptrCast(@alignCast(raw));
            return .{ .queued_bytes = state.len, .capacity_bytes = state.bytes.len };
        }
        fn write(raw: *anyopaque, _: exchange.Connection, bytes: []const u8) bool {
            const state: *State = @ptrCast(@alignCast(raw));
            if (bytes.len > state.credit or bytes.len > state.bytes.len - state.len) return false;
            @memcpy(state.bytes[state.len..][0..bytes.len], bytes);
            state.len += bytes.len;
            state.credit -= bytes.len;
            return true;
        }
        fn release(_: *anyopaque, _: exchange.Page) void {}
        fn close(_: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {}
        fn submit(_: *anyopaque) void {}
    };
    var state = State{};
    const transport = exchange.Transport{ .context = &state, .vtable = &.{
        .complete = Stub.complete,
        .input_page = Stub.input,
        .output_credit = Stub.credit,
        .output_metrics = Stub.metrics,
        .write = Stub.write,
        .release_input = Stub.release,
        .close = Stub.close,
        .submit = Stub.submit,
    } };
    var source: [prepared_page_bytes * 2 + 7]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index);
    var table = T{};
    table.initialize();
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    table.sessions[0] = .{ .connection = connection, .attached = true, .phase = .play };
    table.occupied[0] = true;
    const frame = table.allocatePrepared(&source, .chunks).?;
    try std.testing.expect(table.enqueuePrepared(connection, frame));
    while (table.delivery_queues[0].len != 0) {
        state.credit = prepared_page_bytes;
        table.flushOutput(transport);
    }
    try std.testing.expectEqualSlices(u8, &source, state.bytes[0..state.len]);
}

test "optional fanout has isolated queue admission" {
    const T = Table(2, 1);
    var table = T{};
    table.initialize();
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    const frame = table.allocatePrepared("x", .other).?;
    try std.testing.expect(table.enqueuePrepared(connection, frame));
    try std.testing.expect(!table.queueHasSpace(connection, .other));
    try std.testing.expect(table.queueHasSpace(.{ .index = 1, .generation = 1 }, .other));
}

test "optional traffic cannot consume control queue capacity" {
    const T = Table(1, 16);
    var table = T{};
    table.initialize();
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    const chunk = table.allocatePrepared("chunk", .chunks).?;
    for (0..8) |_| try std.testing.expect(table.enqueuePrepared(connection, chunk));
    try std.testing.expect(!table.queueHasSpace(connection, .chunks));
    const control = table.allocatePrepared("control", .control).?;
    for (0..8) |_| try std.testing.expect(table.enqueuePrepared(connection, control));
    try std.testing.expect(!table.queueHasSpace(connection, .control));
}

test "input publication retains only the backpressured connection and its borrowed pages" {
    const State = struct {
        blocked: bool = true,
        published: [2]usize = @splat(0),
        finished: [2]usize = @splat(0),
        released: [2]usize = @splat(0),
        rejected: usize = 0,
        fn stage(raw: *anyopaque, input: core_exchange.CoreInput) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const handle = input.attachments[0].connection;
            if (handle.index == 0 and self.blocked) return false;
            std.debug.assert(self.published[handle.index] == 0);
            std.debug.assert(input.attachments.len == 1);
            std.debug.assert(input.packet_views.len == if (handle.index == 0) @as(usize, 2) else 1);
            for (input.packet_views, 0..) |packet, index| {
                std.debug.assert(packet.connection.eql(handle));
                std.debug.assert(packet.id == @as(i32, @intCast(index)) + 10);
                std.debug.assert(std.mem.eql(u8, packet.bytes, if (handle.index == 0) "slow" else "fast"));
            }
            self.published[handle.index] += 1;
            return true;
        }
        fn finish(raw: *anyopaque, item: *minecraft.Session) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.finished[item.connection.index] += 1;
            @memset(item.codec_state[0..4], 0xee);
        }
        fn release(raw: *anyopaque, page: exchange.Page) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.released[@intFromEnum(page)] += 1;
        }
        fn close(raw: *anyopaque, handle: exchange.Connection, reason: exchange.DisconnectReason) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(handle.index == 0 and handle.generation == 2 and reason == .overloaded);
            self.rejected += 1;
        }
    };
    var state = State{};
    var transport_vtable: exchange.Transport.VTable = undefined;
    transport_vtable.release_input = State.release;
    transport_vtable.close = State.close;
    const transport = exchange.Transport{ .context = &state, .vtable = &transport_vtable };
    var codec_vtable: minecraft.Codec.VTable = undefined;
    codec_vtable.finish_input = State.finish;
    var table = Table(2, 4){};
    table.initialize();
    for (&table.sessions, 0..) |*item, index| {
        item.* = .{ .connection = .{ .index = @intCast(index), .generation = 1 }, .codec = .{ .context = &state, .vtable = &codec_vtable } };
        @memcpy(item.codec_state[0..4], if (index == 0) "slow" else "fast");
        table.attachments[index] = .{ .connection = item.connection, .uuid = index + 1, .name = @splat(0), .name_len = 0, .protocol = 772, .reconfiguring = false };
        table.held_pages[index] = @enumFromInt(index);
        table.held_connections[index] = item.connection;
    }
    table.attachment_count = 2;
    table.held_count = 2;
    for ([_]usize{ 0, 1, 0 }, 0..) |slot, index| {
        table.packet_views[index] = .{ .connection = table.sessions[slot].connection, .protocol = 772, .id = if (index == 2) 11 else 10, .bytes = table.sessions[slot].codec_state[0..4] };
        table.packet_claimed[index] = false;
    }
    table.packet_view_count = 3;
    for (table.sessions) |item| table.markInputPending(item.connection);
    const ingress = core_exchange.Ingress{ .context = &state, .vtable = &.{ .stage = State.stage } };
    try std.testing.expect(table.publishInput(transport, ingress));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, &state.published);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, &state.finished);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, &state.released);
    try std.testing.expectEqual(@as(usize, 2), table.packet_view_count);
    try std.testing.expectEqual(@as(usize, 1), table.attachment_count);
    try std.testing.expectEqual(@as(usize, 1), table.held_count);
    try std.testing.expect(!table.publishInput(transport, ingress));
    table.accept(transport, .{ .index = 0, .generation = 2 });
    try std.testing.expectEqual(@as(usize, 1), state.rejected);
    try std.testing.expectEqualStrings("slow", table.packet_views[0].bytes);
    state.blocked = false;
    try std.testing.expect(table.publishInput(transport, ingress));
    try std.testing.expectEqualSlices(usize, &.{ 1, 1 }, &state.published);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1 }, &state.finished);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1 }, &state.released);
    try std.testing.expectEqual(@as(usize, 0), table.packet_view_count);
    try std.testing.expectEqual(@as(usize, 0), table.attachment_count);
    try std.testing.expectEqual(@as(usize, 0), table.held_count);
}

test "pending input isolates other sessions and retains a closed borrowed page" {
    const Context = struct {
        completes: usize = 0,
        writes: usize = 0,
        releases: usize = 0,
        closes: usize = 0,
        blocked: bool = true,
        published: usize = 0,
        status_page: [1]u8 = .{0},
    };
    const Stub = struct {
        fn complete(raw: *anyopaque, events: []exchange.TransportEvent) usize {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.completes += 1;
            if (context.completes != 1) return 0;
            events[0] = .{ .closed = .{ .connection = .{ .index = 0, .generation = 1 }, .reason = .kicked } };
            events[1] = .{ .accepted = .{ .index = 0, .generation = 2 } };
            events[2] = .{ .received = .{ .connection = .{ .index = 1, .generation = 1 }, .page = .{ .id = @enumFromInt(1), .bytes = context.status_page[0..] } } };
            return 3;
        }
        fn inputPage(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn release(raw: *anyopaque, _: exchange.Page) void {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.releases += 1;
        }
        fn close(raw: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.closes += 1;
        }
        fn write(raw: *anyopaque, _: exchange.Connection, _: []const u8) bool {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.writes += 1;
            return true;
        }
        fn credit(_: *anyopaque, _: exchange.Connection) usize {
            return 4096;
        }
        fn submit(_: *anyopaque) void {}
    };
    const Codec = struct {
        fn init(_: *anyopaque, _: *minecraft.Session) bool {
            return true;
        }
        fn decode(_: *anyopaque, item: *minecraft.Session, bytes: []const u8, output: []minecraft.Packet) minecraft.Codec.Decode {
            if (item.phase != .status) return .{ .progress = .{ .consumed = 0, .packets = 0 } };
            output[0] = .{ .id = 0, .bytes = bytes, .storage = .input_page };
            return .{ .progress = .{ .consumed = bytes.len, .packets = 1 } };
        }
        fn finish(_: *anyopaque, _: *minecraft.Session) void {}
        fn classify(_: *anyopaque, phase: api.Phase, _: minecraft.Packet) minecraft.Disposition {
            return if (phase == .status) .status_request else .core;
        }
        fn start(_: *anyopaque, _: *minecraft.Session, _: []u8) ?usize {
            return null;
        }
        fn capacity(_: *anyopaque, _: *const minecraft.Session, _: i32, _: []const u8) ?usize {
            return null;
        }
        fn encode(_: *anyopaque, _: *minecraft.Session, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
        fn status(_: *anyopaque, _: i32, _: []const u8, output: []u8) ?usize {
            output[0] = 's';
            return 1;
        }
        fn stage(raw: *anyopaque, input: core_exchange.CoreInput) bool {
            const context: *Context = @ptrCast(@alignCast(raw));
            if (context.blocked) return false;
            std.debug.assert(input.detachments.len == 1);
            std.debug.assert(input.packet_views.len == 1);
            std.debug.assert(std.mem.eql(u8, "view", input.packet_views[0].bytes));
            context.published += 1;
            return true;
        }
    };
    var context = Context{};
    const transport = exchange.Transport{ .context = &context, .vtable = &.{ .complete = Stub.complete, .input_page = Stub.inputPage, .output_credit = Stub.credit, .output_metrics = testOutputMetrics, .write = Stub.write, .release_input = Stub.release, .close = Stub.close, .submit = Stub.submit } };
    const codec = minecraft.Codec{ .context = &context, .vtable = &.{ .init = Codec.init, .decode = Codec.decode, .finish_input = Codec.finish, .classify = Codec.classify, .start_configuration = Codec.start, .encoded_capacity = Codec.capacity, .encode = Codec.encode, .status = Codec.status } };
    var table = Table(2, 3){};
    table.initialize();
    const first = exchange.Connection{ .index = 0, .generation = 1 };
    var page = [_]u8{ 'v', 'i', 'e', 'w', 'x' };
    table.sessions[0] = .{ .connection = first, .attached = true, .phase = .play, .protocol = 772, .codec = codec, .retained_page = @enumFromInt(0), .retained_offset = 4 };
    table.sessions[1] = .{ .connection = .{ .index = 1, .generation = 1 }, .phase = .status, .protocol = 772, .codec = codec };
    table.occupied[0] = true;
    table.occupied[1] = true;
    table.packet_views[0] = .{ .connection = first, .protocol = 772, .id = 1, .bytes = page[0..4] };
    table.packet_claimed[0] = false;
    table.packet_view_count = 1;
    table.markInputPending(first);
    table.markRetainedInputBorrowed(first);
    table.advance(transport, 0, .{ .revision = 0, .json = "{}" });
    try std.testing.expectEqual(@as(usize, 1), context.completes);
    try std.testing.expectEqual(@as(usize, 1), context.writes);
    try std.testing.expectEqual(@as(usize, 1), context.releases);
    try std.testing.expectEqual(@as(usize, 1), context.closes);
    try std.testing.expectEqual(@as(usize, 1), table.held_count);
    try std.testing.expectEqual(@as(usize, 1), table.detachment_count);
    const ingress = core_exchange.Ingress{ .context = &context, .vtable = &.{ .stage = Codec.stage } };
    try std.testing.expect(!table.publishInput(transport, ingress));
    try std.testing.expectEqual(@as(usize, 1), context.releases);
    context.blocked = false;
    try std.testing.expect(table.publishInput(transport, ingress));
    try std.testing.expectEqual(@as(usize, 1), context.published);
    try std.testing.expectEqual(@as(usize, 2), context.releases);
    try std.testing.expectEqual(@as(usize, 0), table.packet_view_count);
    try std.testing.expectEqual(@as(usize, 0), table.detachment_count);
    try std.testing.expect(!table.inputPending(first));
}

test "pending codec input retains a later decrypted transport page" {
    const State = struct {
        event_round: usize = 0,
        releases: [2]usize = @splat(0),
        blocked: bool = true,
        published: [2]usize = @splat(0),
        pages: [2][1]u8 = .{ .{'a'}, .{'b'} },
        fn complete(raw: *anyopaque, events: []exchange.TransportEvent) usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.event_round >= 2) return 0;
            const page: exchange.Page = @enumFromInt(self.event_round);
            events[0] = .{ .received = .{ .connection = .{ .index = 0, .generation = 1 }, .page = .{ .id = page, .bytes = self.pages[self.event_round][0..] } } };
            self.event_round += 1;
            return 1;
        }
        fn inputPage(raw: *anyopaque, page: exchange.Page) ?exchange.InputPage {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const index = @intFromEnum(page);
            return .{ .id = page, .bytes = self.pages[index][0..] };
        }
        fn release(raw: *anyopaque, page: exchange.Page) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases[@intFromEnum(page)] += 1;
        }
        fn close(_: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {}
        fn submit(_: *anyopaque) void {}
        fn stage(raw: *anyopaque, batch: core_exchange.CoreInput) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.blocked) return false;
            std.debug.assert(batch.packet_views.len == 1);
            const id: usize = @intCast(batch.packet_views[0].id - 1);
            std.debug.assert(std.mem.eql(u8, if (id == 0) "first" else "second", batch.packet_views[0].bytes));
            self.published[id] += 1;
            return true;
        }
    };
    const Codec = struct {
        fn init(_: *anyopaque, _: *minecraft.Session) bool {
            return true;
        }
        fn decode(_: *anyopaque, item: *minecraft.Session, bytes: []const u8, output: []minecraft.Packet) minecraft.Codec.Decode {
            const second = bytes[0] == 'b';
            const value = if (second) "\x02second" else "\x01first";
            @memcpy(item.decoded_state[0..value.len], value);
            item.codec_state_exposed = true;
            output[0] = .{ .id = if (second) 2 else 1, .bytes = item.decoded_state[0..value.len], .storage = .session };
            return .{ .progress = .{ .consumed = bytes.len, .packets = 1 } };
        }
        fn finish(_: *anyopaque, item: *minecraft.Session) void {
            item.codec_state_exposed = false;
        }
        fn classify(_: *anyopaque, _: api.Phase, _: minecraft.Packet) minecraft.Disposition {
            return .core;
        }
        fn start(_: *anyopaque, _: *minecraft.Session, _: []u8) ?usize {
            return null;
        }
        fn capacity(_: *anyopaque, _: *const minecraft.Session, _: i32, _: []const u8) ?usize {
            return null;
        }
        fn encode(_: *anyopaque, _: *minecraft.Session, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
        fn status(_: *anyopaque, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
    };
    var state = State{};
    const secret = [_]u8{0x5a} ** 16;
    var peer = crypto.Cfb8.init(secret);
    peer.encrypt(state.pages[0][0..]);
    peer.encrypt(state.pages[1][0..]);
    const transport = exchange.Transport{ .context = &state, .vtable = &.{ .complete = State.complete, .input_page = State.inputPage, .output_credit = testOutputCredit, .output_metrics = testOutputMetrics, .write = testWrite, .release_input = State.release, .close = State.close, .submit = State.submit } };
    const codec = minecraft.Codec{ .context = &state, .vtable = &.{ .init = Codec.init, .decode = Codec.decode, .finish_input = Codec.finish, .classify = Codec.classify, .start_configuration = Codec.start, .encoded_capacity = Codec.capacity, .encode = Codec.encode, .status = Codec.status } };
    var table = Table(1, 2){};
    table.initialize();
    table.sessions[0] = .{ .connection = .{ .index = 0, .generation = 1 }, .phase = .play, .protocol = 772, .codec = codec, .decryptor = crypto.Cfb8.init(secret) };
    table.occupied[0] = true;
    const ingress = core_exchange.Ingress{ .context = &state, .vtable = &.{ .stage = State.stage } };
    table.advance(transport, 0, .{ .revision = 0, .json = "{}" });
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, &state.releases);
    try std.testing.expect(table.inputPending(table.sessions[0].connection));
    table.advance(transport, 1, .{ .revision = 0, .json = "{}" });
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, &state.releases);
    try std.testing.expectEqual(@as(exchange.Page, @enumFromInt(1)), table.sessions[0].retained_page.?);
    try std.testing.expect(!table.publishInput(transport, ingress));
    state.blocked = false;
    try std.testing.expect(table.publishInput(transport, ingress));
    table.advance(transport, 2, .{ .revision = 0, .json = "{}" });
    try std.testing.expectEqualSlices(usize, &.{ 1, 1 }, &state.releases);
    try std.testing.expect(table.publishInput(transport, ingress));
    try std.testing.expectEqualSlices(usize, &.{ 1, 1 }, &state.published);
    try std.testing.expectEqualSlices(u8, "a", state.pages[0][0..]);
    try std.testing.expectEqualSlices(u8, "b", state.pages[1][0..]);
}

test "final shutdown releases an unattached retained page on the next advance" {
    const State = struct {
        releases: usize = 0,
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn inputPage(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn release(raw: *anyopaque, _: exchange.Page) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
        fn close(_: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {}
        fn submit(_: *anyopaque) void {}
    };
    var state = State{};
    const transport = exchange.Transport{ .context = &state, .vtable = &.{ .complete = State.complete, .input_page = State.inputPage, .output_credit = testOutputCredit, .output_metrics = testOutputMetrics, .write = testWrite, .release_input = State.release, .close = State.close, .submit = State.submit } };
    var table = Table(1, 1){};
    table.initialize();
    table.sessions[0] = .{ .connection = .{ .index = 0, .generation = 1 }, .phase = .login, .retained_page = @enumFromInt(0) };
    table.occupied[0] = true;
    table.stageFinalDetachments();
    try std.testing.expect(table.occupied[0]);
    table.advance(transport, 0, .{ .revision = 0, .json = "{}" });
    try std.testing.expect(!table.occupied[0]);
    try std.testing.expectEqual(@as(usize, 1), state.releases);
}

test "Play packets require an explicit Core claim" {
    const State = struct { closes: usize = 0 };
    const Stub = struct {
        fn init(_: *anyopaque, _: *minecraft.Session) bool {
            return true;
        }
        fn decode(_: *anyopaque, _: *minecraft.Session, _: []const u8, _: []minecraft.Packet) minecraft.Codec.Decode {
            return .{ .progress = .{ .consumed = 0, .packets = 0 } };
        }
        fn finish(_: *anyopaque, _: *minecraft.Session) void {}
        fn classify(_: *anyopaque, _: api.Phase, _: minecraft.Packet) minecraft.Disposition {
            return .core;
        }
        fn start(_: *anyopaque, _: *minecraft.Session, _: []u8) ?usize {
            return null;
        }
        fn capacity(_: *anyopaque, _: *const minecraft.Session, _: i32, _: []const u8) ?usize {
            return null;
        }
        fn encode(_: *anyopaque, _: *minecraft.Session, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
        fn status(_: *anyopaque, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn input(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
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
        fn close(raw: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {
            const state: *State = @ptrCast(@alignCast(raw));
            state.closes += 1;
        }
        fn submit(_: *anyopaque) void {}
    };
    var state = State{};
    var codec_context: u8 = 0;
    const codec = minecraft.Codec{ .context = &codec_context, .vtable = &.{
        .init = Stub.init,
        .decode = Stub.decode,
        .finish_input = Stub.finish,
        .classify = Stub.classify,
        .start_configuration = Stub.start,
        .encoded_capacity = Stub.capacity,
        .encode = Stub.encode,
        .status = Stub.status,
    } };
    const transport = exchange.Transport{ .context = &state, .vtable = &.{
        .complete = Stub.complete,
        .input_page = Stub.input,
        .output_credit = Stub.credit,
        .output_metrics = Stub.metrics,
        .write = Stub.write,
        .release_input = Stub.release,
        .close = Stub.close,
        .submit = Stub.submit,
    } };
    var table = Table(1, 2){};
    table.initialize();
    table.sessions[0] = .{ .connection = .{ .index = 0, .generation = 1 }, .phase = .play, .protocol = 772, .codec = codec };
    table.occupied[0] = true;
    const item = &table.sessions[0];
    try std.testing.expect(table.route(transport, item, codec, .{ .id = 127, .bytes = &.{ 0x7f, 1, 2 }, .storage = .session }));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, table.packet_views[0].bytes);
    try std.testing.expect(!table.packet_claimed[0]);
    table.packet_claimed[0] = true;
    table.finishInput(transport);
    try std.testing.expectEqual(@as(usize, 0), state.closes);

    try std.testing.expect(table.route(transport, item, codec, .{ .id = 127, .bytes = &.{ 0x7f, 3 }, .storage = .session }));
    table.finishInput(transport);
    try std.testing.expectEqual(@as(usize, 1), state.closes);
}

test "Play packet views retain their transport page until Core finishes input" {
    const Context = struct { releases: usize = 0, closes: usize = 0 };
    const CodecStub = struct {
        fn init(_: *anyopaque, _: *minecraft.Session) bool {
            return true;
        }
        fn decode(_: *anyopaque, _: *minecraft.Session, bytes: []const u8, output: []minecraft.Packet) minecraft.Codec.Decode {
            output[0] = .{ .id = 41, .bytes = bytes, .storage = .input_page };
            return .{ .progress = .{ .consumed = bytes.len, .packets = 1 } };
        }
        fn finish(_: *anyopaque, _: *minecraft.Session) void {}
        fn classify(_: *anyopaque, _: api.Phase, _: minecraft.Packet) minecraft.Disposition {
            return .core;
        }
        fn start(_: *anyopaque, _: *minecraft.Session, _: []u8) ?usize {
            return null;
        }
        fn capacity(_: *anyopaque, _: *const minecraft.Session, _: i32, _: []const u8) ?usize {
            return null;
        }
        fn encode(_: *anyopaque, _: *minecraft.Session, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
        fn status(_: *anyopaque, _: i32, _: []const u8, _: []u8) ?usize {
            return null;
        }
    };
    const TransportStub = struct {
        fn complete(_: *anyopaque, _: []exchange.TransportEvent) usize {
            return 0;
        }
        fn input(_: *anyopaque, _: exchange.Page) ?exchange.InputPage {
            return null;
        }
        fn release(raw: *anyopaque, _: exchange.Page) void {
            (@as(*Context, @ptrCast(@alignCast(raw)))).releases += 1;
        }
        fn close(raw: *anyopaque, _: exchange.Connection, _: exchange.DisconnectReason) void {
            (@as(*Context, @ptrCast(@alignCast(raw)))).closes += 1;
        }
        fn submit(_: *anyopaque) void {}
    };
    var codec_context: u8 = 0;
    const codec = minecraft.Codec{ .context = &codec_context, .vtable = &.{ .init = CodecStub.init, .decode = CodecStub.decode, .finish_input = CodecStub.finish, .classify = CodecStub.classify, .start_configuration = CodecStub.start, .encoded_capacity = CodecStub.capacity, .encode = CodecStub.encode, .status = CodecStub.status } };
    var context = Context{};
    const transport = exchange.Transport{ .context = &context, .vtable = &.{ .complete = TransportStub.complete, .input_page = TransportStub.input, .output_credit = testOutputCredit, .output_metrics = testOutputMetrics, .write = testWrite, .release_input = TransportStub.release, .close = TransportStub.close, .submit = TransportStub.submit } };
    var table = Table(1, 1){};
    table.initialize();
    table.sessions[0] = .{ .connection = .{ .index = 0, .generation = 1 }, .phase = .play, .protocol = 772, .codec = codec };
    table.occupied[0] = true;
    var bytes = [_]u8{ 1, 2, 3 };
    table.decode(transport, &table.sessions[0], .{ .id = @enumFromInt(0), .bytes = &bytes });
    try std.testing.expectEqual(@as(usize, 1), table.packet_view_count);
    try std.testing.expectEqual(@as(usize, 1), table.held_count);
    try std.testing.expectEqual(@as(usize, 0), context.releases);
    table.finishInput(transport);
    try std.testing.expectEqual(@as(usize, 1), context.releases);
    try std.testing.expectEqual(@as(usize, 0), table.packet_view_count);
}
