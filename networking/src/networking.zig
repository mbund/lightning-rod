const std = @import("std");

pub const Handle = struct {
    index: u16,
    generation: u32,
};

pub const CloseReason = enum { peer_closed, local_close, io_failure, capacity };

/// Each completion releases its buffer loan. A successful send may be partial.
pub const Result = struct {
    bytes: usize,
    errno: ?i32 = null,
};

pub const Completion = struct {
    handle: Handle,
    result: Result,
};

pub const Event = union(enum) {
    accepted: Handle,
    received: Completion,
    sent: Completion,
    closed: struct {
        handle: Handle,
        reason: CloseReason,
    },
};

pub const Limits = struct {
    connections: usize,
    operations: usize,
    events: usize,
};

pub const QueueError = error{ InvalidHandle, Busy, Full, Closed };

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,
    inheritance: ?Inheritance = null,

    pub const VTable = struct {
        queue_receive: *const fn (*anyopaque, std.Io, Handle, []u8) QueueError!void,
        queue_send: *const fn (*anyopaque, std.Io, Handle, []const u8) QueueError!void,
        close: *const fn (*anyopaque, std.Io, Handle, CloseReason) void,
        release: *const fn (*anyopaque, std.Io, Handle) void,
        notify: *const fn (*anyopaque, std.Io) void,
        submit: *const fn (*anyopaque, std.Io) anyerror!void,
        poll: *const fn (*anyopaque, std.Io, ?std.Io.Timeout, []Event) anyerror!usize,
    };

    pub fn queueReceive(t: Transport, io: std.Io, h: Handle, b: []u8) QueueError!void {
        return t.vtable.queue_receive(t.context, io, h, b);
    }

    pub fn queueSend(t: Transport, io: std.Io, h: Handle, b: []const u8) QueueError!void {
        return t.vtable.queue_send(t.context, io, h, b);
    }

    pub fn close(t: Transport, io: std.Io, h: Handle, r: CloseReason) void {
        t.vtable.close(t.context, io, h, r);
    }

    /// Release the connection slot after receiving closed and returning all
    /// application-owned loans. No operation may reference this handle afterward.
    pub fn release(t: Transport, io: std.Io, h: Handle) void {
        t.vtable.release(t.context, io, h);
    }

    /// Thread-safe wakeup. The transport must outlive all notifying threads.
    pub fn notify(t: Transport, io: std.Io) void {
        t.vtable.notify(t.context, io);
    }

    pub fn poll(t: Transport, io: std.Io, d: ?std.Io.Timeout, e: []Event) !usize {
        return t.vtable.poll(t.context, io, d, e);
    }

    /// Start queued operations without waiting for their completion.
    pub fn submit(t: Transport, io: std.Io) !void {
        return t.vtable.submit(t.context, io);
    }
};

/// Optional native-descriptor ownership boundary. The Session owner pauses
/// admission, drains operations, then exports. Import happens before polling.
pub const Inheritance = struct {
    context: *anyopaque,
    pause: *const fn (*anyopaque, std.Io, bool) void,
    ready: *const fn (*anyopaque) bool,
    listener: *const fn (*anyopaque) i32,
    descriptor: *const fn (*anyopaque, Handle) i32,
    adopt: *const fn (*anyopaque, i32) anyerror!Handle,
};

pub fn validLimits(comptime x: Limits) void {
    comptime {
        if (x.connections == 0 or x.connections > std.math.maxInt(u16)) @compileError("connections must fit Handle.index");

        if (x.operations == 0 or x.events < x.operations + 2 * x.connections)
            @compileError("events must hold every operation plus accepted and closed connection statuses");
    }
}
