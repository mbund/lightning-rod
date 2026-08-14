const abi = @import("hot_reload_abi.zig");

pub const Reservation = struct {
    lease: abi.OutputLease,
    body: []u8,
};

pub fn begin(
    kernel: *const abi.KernelApi,
    handle: abi.ConnectionHandle,
    minimum_body_bytes: usize,
) !Reservation {
    var lease: abi.OutputLease = .{ .bytes = undefined };
    try kernelResult(kernel.reserve_output(
        kernel.context,
        handle,
        minimum_body_bytes,
        &lease,
    ));
    return .{ .lease = lease, .body = lease.bytes.slice() };
}

pub fn cancel(kernel: *const abi.KernelApi, reservation: Reservation) void {
    kernel.cancel_output(kernel.context, reservation.lease.id);
}

pub fn finish(
    kernel: *const abi.KernelApi,
    reservation: Reservation,
    body_len: usize,
) !void {
    if (body_len > reservation.body.len) return error.InvalidOutputLease;
    try kernelResult(kernel.commit_output(
        kernel.context,
        reservation.lease.id,
        body_len,
    ));
}

fn kernelResult(status: abi.KernelStatus) !void {
    return switch (status) {
        .ok => {},
        .incomplete => error.IncompletePacket,
        .invalid_connection => error.InvalidConnection,
        .backpressured => error.PlayerWriteBackpressure,
        .invalid_lease => error.InvalidOutputLease,
        .unsupported => error.OutputKernelUnavailable,
        .rejected => error.OutputRejected,
    };
}
