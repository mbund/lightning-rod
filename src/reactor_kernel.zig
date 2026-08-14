const std = @import("std");
const abi = @import("hot_reload_abi.zig");
const connection = @import("reactor_connection.zig");
const output = @import("reactor_output.zig");
const transport = @import("reactor_transport.zig");

pub const Context = struct {
    connections: *connection.Table,
    output: *output.Pool,
    transport: *transport.State,
    random: *std.Random.ChaCha,

    pub fn api(self: *Context) abi.KernelApi {
        return .{
            .capabilities = abi.KernelCapability.output_leases |
                abi.KernelCapability.entropy |
                abi.KernelCapability.bulk_work |
                abi.KernelCapability.wire_transport,
            .context = self,
            .reserve_output = reserveOutput,
            .commit_output = commitOutput,
            .cancel_output = cancelOutput,
            .fill_random = fillRandom,
            .output_backpressured = outputBackpressured,
            .append_input = appendInput,
            .next_packet = nextPacket,
            .set_compression = setCompression,
            .set_encryption = setEncryption,
        };
    }

    fn reserveOutput(
        raw: *anyopaque,
        handle: abi.ConnectionHandle,
        minimum: usize,
        lease: *abi.OutputLease,
    ) callconv(.c) abi.KernelStatus {
        const self: *Context = @ptrCast(@alignCast(raw));
        return self.transport.reserveOutput(
            self.connections,
            self.output,
            handle,
            minimum,
            lease,
        );
    }

    fn commitOutput(
        raw: *anyopaque,
        lease: u64,
        byte_count: usize,
    ) callconv(.c) abi.KernelStatus {
        const self: *Context = @ptrCast(@alignCast(raw));
        return self.transport.commitOutput(
            self.connections,
            self.output,
            lease,
            byte_count,
        );
    }

    fn cancelOutput(raw: *anyopaque, lease: u64) callconv(.c) void {
        const self: *Context = @ptrCast(@alignCast(raw));
        const slot = self.connections.lookup(unpackHandle(lease)) orelse return;
        self.output.abort(self.connections.items, @intCast(slot));
    }

    fn fillRandom(raw: *anyopaque, output_bytes: abi.MutableBytes) callconv(.c) abi.KernelStatus {
        const self: *Context = @ptrCast(@alignCast(raw));
        self.random.fill(output_bytes.slice());
        return .ok;
    }

    fn outputBackpressured(raw: *anyopaque, handle: abi.ConnectionHandle) callconv(.c) bool {
        const self: *Context = @ptrCast(@alignCast(raw));
        const slot = self.connections.lookup(handle) orelse return true;
        return self.output.backpressured(&self.connections.items[slot]);
    }

    fn appendInput(raw: *anyopaque, handle: abi.ConnectionHandle, bytes: abi.Bytes) callconv(.c) abi.KernelStatus {
        const self: *Context = @ptrCast(@alignCast(raw));
        return self.transport.appendInput(self.connections, handle, bytes.slice());
    }

    fn nextPacket(raw: *anyopaque, handle: abi.ConnectionHandle, packet: *abi.Bytes) callconv(.c) abi.KernelStatus {
        const self: *Context = @ptrCast(@alignCast(raw));
        return self.transport.nextPacket(self.connections, handle, packet);
    }

    fn setCompression(raw: *anyopaque, handle: abi.ConnectionHandle, threshold: i32) callconv(.c) abi.KernelStatus {
        const self: *Context = @ptrCast(@alignCast(raw));
        return self.transport.setCompression(self.connections, handle, threshold);
    }

    fn setEncryption(raw: *anyopaque, handle: abi.ConnectionHandle, secret: abi.Bytes) callconv(.c) abi.KernelStatus {
        const self: *Context = @ptrCast(@alignCast(raw));
        if (secret.len != 16) return .rejected;
        return self.transport.setEncryption(self.connections, handle, secret.slice()[0..16].*);
    }

    fn unpackHandle(value: u64) abi.ConnectionHandle {
        return .{ .index = @truncate(value), .generation = @truncate(value >> 32) };
    }
};
