const std = @import("std");
const abi = @import("hot_reload_abi.zig");
const completion = @import("reactor_completion.zig");
const config_module = @import("config.zig");
const connections = @import("reactor_connection.zig");
const exchange = @import("reactor_exchange.zig");
const linux_support = @import("reactor_linux.zig");
const output = @import("reactor_output.zig");

const config = config_module.value;
const connection_capacity = connections.virtual_capacity;
const linux = std.os.linux;
const log = std.log.scoped(.server_io);
const protocol_log = std.log.scoped(.protocol);

pub const Network = struct {
    allocator: std.mem.Allocator,
    listener: std.posix.socket_t = -1,
    ring: linux.IoUring,
    recv_group: linux.IoUring.BufferGroup,
    connections: connections.Table,
    output: output.Pool,

    pub fn allocate(self: *Network, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.listener = -1;
        try self.connections.allocate(allocator);
        errdefer self.connections.deinit();
        try self.output.allocate(allocator);
    }

    pub fn initializeRing(self: *Network, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.ring = try linux.IoUring.init(
            config.ring_entries,
            linux.IORING_SETUP_SINGLE_ISSUER,
        );
        errdefer self.ring.deinit();
        try self.ring.register_files_sparse(connection_capacity);
        errdefer self.ring.unregister_files() catch {};
        try linux_support.registerFileRange(&self.ring, 0, connection_capacity);
        self.recv_group = try linux.IoUring.BufferGroup.init(
            &self.ring,
            allocator,
            config.recv_buffer_group,
            config.recv_buffer_size,
            config.recv_buffer_count,
        );
    }

    pub fn initializeListener(self: *Network, address: std.Io.net.IpAddress) !void {
        self.listener = linux_support.listen(address, config.listen_backlog) catch |err| {
            log.err("event=server_bind_failed address={f} err={}", .{ address, err });
            return err;
        };
    }

    pub fn deinit(self: *Network) void {
        self.ring.unregister_files() catch {};
        self.recv_group.deinit(self.allocator);
        self.ring.deinit();
        linux_support.close(self.listener);
        self.connections.deinit();
    }

    pub fn ensurePlayerCapacity(self: *Network, players: usize) !void {
        try self.connections.ensurePlayerCapacity(players);
    }

    pub fn shrinkConnectionCapacity(self: *Network, capacity: usize) !void {
        try self.connections.shrinkCapacity(capacity);
    }

    pub fn submitAccept(self: *Network) !void {
        _ = try self.ring.accept_multishot_direct(
            (completion.Tag{ .kind = .accept, .index = std.math.maxInt(u16), .token = 0 }).pack(),
            self.listener,
            null,
            null,
            linux.SOCK.NONBLOCK,
        );
    }

    pub fn submitRecv(self: *Network, slot: u16) !void {
        const client = &self.connections.items[slot];
        const tag = completion.Tag{
            .kind = .recv,
            .index = slot,
            .token = client.generation,
        };
        const sqe = try self.recv_group.recv_multishot(
            tag.pack(),
            client.fd,
            linux.MSG.NOSIGNAL,
        );
        sqe.flags |= linux.IOSQE_FIXED_FILE;
    }

    pub fn submitSend(self: *Network, slot: u16) !void {
        const client = &self.connections.items[slot];
        if (!client.hasQueuedOutput()) return;
        std.debug.assert(!client.send_pending);
        const queued = client.output_segment_count - client.send_segment_count;
        const count = @min(queued, config.max_send_iovecs);
        for (0..count) |index| {
            const segment = client.constOutputSegment(client.send_segment_count + index).*;
            std.debug.assert(segment.offset < segment.len);
            const bytes = self.output.buffers[segment.buffer_index][segment.offset..segment.len];
            client.send_iovecs[index] = .{ .base = bytes.ptr, .len = bytes.len };
        }
        client.send_msg = .{
            .name = null,
            .namelen = 0,
            .iov = client.send_iovecs[0..count].ptr,
            .iovlen = count,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const tag = completion.Tag{ .kind = .send, .index = slot, .token = client.generation };
        const sqe = try self.ring.sendmsg(tag.pack(), client.fd, &client.send_msg, linux.MSG.NOSIGNAL);
        sqe.flags |= linux.IOSQE_FIXED_FILE | linux.IOSQE_ASYNC;
        client.send_pending = true;
        client.send_segment_count += count;
    }

    pub fn completeAccept(
        self: *Network,
        mailbox: *exchange.Mailbox,
        cqe: linux.io_uring_cqe,
    ) !void {
        if (cqe.err() != .SUCCESS) {
            log.warn("event=accept_error errno={} result={} flags={x}", .{ cqe.err(), cqe.res, cqe.flags });
            try self.submitAccept();
            return;
        }
        const direct_fd: std.posix.socket_t = @intCast(cqe.res);
        const slot = self.connections.freeSlot() orelse {
            const tag = completion.Tag{ .kind = .close, .index = std.math.maxInt(u16), .token = 0 };
            _ = try self.ring.close_direct(tag.pack(), @intCast(direct_fd));
            return;
        };
        const client = &self.connections.items[slot];
        client.reset();
        client.fd = direct_fd;
        client.phase = .handshaking;
        self.connections.connected_count += 1;
        if (!mailbox.connected(self.connections.handle(@intCast(slot))))
            @panic("tick event buffer exhausted while staging connection");
        log.info("accept slot={} connected={}", .{ slot, self.connections.connected_count });
        try self.submitRecv(@intCast(slot));
        if (cqe.flags & linux.IORING_CQE_F_MORE == 0) try self.submitAccept();
    }

    pub fn completeRecv(
        self: *Network,
        mailbox: *exchange.Mailbox,
        tag: completion.Tag,
        cqe: linux.io_uring_cqe,
    ) !void {
        const slot: usize = tag.index;
        if (slot >= self.connections.items.len) return;
        const client = &self.connections.items[slot];
        if (client.phase == .free or client.generation != tag.token) return;
        if (cqe.err() != .SUCCESS)
            return self.close(mailbox, slot, .transport_error);
        if (cqe.res == 0) return self.close(mailbox, slot, .peer_closed);
        const bytes = self.recv_group.get(cqe) catch |err| {
            log.warn("event=recv_buffer_error slot={} err={}", .{ slot, err });
            return self.close(mailbox, slot, .transport_error);
        };
        defer self.recv_group.put(cqe) catch {};
        if (!mailbox.rawInput(self.connections.handle(@intCast(slot)), bytes)) {
            protocol_log.warn("event=client_input_backpressure slot={}", .{slot});
            return self.close(mailbox, slot, .transport_error);
        }
        if (cqe.flags & linux.IORING_CQE_F_MORE == 0 and client.phase != .free)
            try self.submitRecv(@intCast(slot));
    }

    pub fn completeSend(
        self: *Network,
        mailbox: *exchange.Mailbox,
        tag: completion.Tag,
        cqe: linux.io_uring_cqe,
    ) !void {
        const slot: usize = tag.index;
        if (slot >= self.connections.items.len) return;
        const client = &self.connections.items[slot];
        if (client.generation != tag.token) return;
        client.send_pending = false;
        if (cqe.err() != .SUCCESS) {
            if (client.phase != .free) {
                log.warn("event=send_error slot={} errno={}", .{ slot, cqe.err() });
                self.close(mailbox, slot, .transport_error);
            } else {
                self.output.freeClient(client, 0);
                client.reset();
            }
            return;
        }
        client.send_completed_bytes = @intCast(cqe.res);
        try self.finishSend(mailbox, @intCast(slot));
    }

    pub fn flushAll(self: *Network) !void {
        for (self.connections.items, 0..) |*client, slot| {
            if (!client.hasQueuedOutput()) continue;
            try self.flush(@intCast(slot));
        }
    }

    pub fn flush(self: *Network, slot: u16) !void {
        const client = &self.connections.items[slot];
        if (client.send_pending or !client.hasQueuedOutput()) return;
        try self.submitSend(slot);
    }

    pub fn close(
        self: *Network,
        mailbox: *exchange.Mailbox,
        slot: usize,
        reason: abi.DisconnectReason,
    ) void {
        const client = &self.connections.items[slot];
        if (client.phase == .free or client.release_pending) return;
        if (!mailbox.disconnected(
            self.connections.handle(@intCast(slot)),
            reason,
        ))
            @panic("tick event buffer exhausted while staging disconnection");
        client.protocol_number = 0;
        log.info("event=disconnect slot={} state={}", .{ slot, client.phase });
        const tag = completion.Tag{ .kind = .close, .index = @intCast(slot), .token = client.generation };
        _ = self.ring.close_direct(tag.pack(), @intCast(client.fd)) catch {};
        self.connections.removePlaying(@intCast(slot));
        if (!client.send_pending) {
            self.output.freeClient(client, 0);
        } else {
            self.output.freeClient(client, client.send_segment_count);
        }
        client.fd = -1;
        client.phase = .free;
        client.reload_transition_pending = false;
        client.output_lease_active = false;
        client.release_pending = true;
        std.debug.assert(self.connections.connected_count > 0);
        self.connections.connected_count -= 1;
    }

    pub fn playSlotValid(self: *const Network, slot: u16) bool {
        const client = &self.connections.items[slot];
        return client.in_play_slots and client.phase == .play;
    }

    fn finishSend(self: *Network, mailbox: *exchange.Mailbox, slot: u16) !void {
        const client = &self.connections.items[slot];
        if (client.send_pending or client.send_completed_bytes == 0) return;
        self.output.releaseSent(client, client.send_completed_bytes);
        client.send_completed_bytes = 0;
        client.send_segment_count = 0;
        if (client.phase == .free) {
            if (!client.hasQueuedOutput() and !client.release_pending) client.reset();
            return;
        }
        if (client.close_after_send and !client.hasQueuedOutput())
            return self.close(mailbox, slot, client.close_after_send_reason);
        if (client.hasQueuedOutput()) try self.submitSend(slot);
    }
};
