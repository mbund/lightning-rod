const connection = @import("connection_api.zig");
const core_exchange = @import("core_exchange.zig");

pub const Connection = connection.Handle;
pub const Page = connection.Page;
pub const DisconnectReason = connection.DisconnectReason;
pub const InputPage = struct { id: Page, bytes: []u8 };

pub const TransportEvent = union(enum) {
    accepted: Connection,
    received: struct { connection: Connection, page: InputPage },
    closed: struct { connection: Connection, reason: DisconnectReason },
};

pub const OutputMetrics = struct {
    queued_bytes: usize,
    capacity_bytes: usize,
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        complete: *const fn (*anyopaque, []TransportEvent) usize,
        input_page: *const fn (*anyopaque, Page) ?InputPage,
        output_credit: *const fn (*anyopaque, Connection) usize,
        output_metrics: *const fn (*anyopaque, Connection) ?OutputMetrics,
        write: *const fn (*anyopaque, Connection, []const u8) bool,
        reserve_output: *const fn (*anyopaque, Connection, usize) ?[]u8 = reserveOutputUnavailable,
        commit_output: *const fn (*anyopaque, Connection, usize) bool = commitOutputUnavailable,
        release_input: *const fn (*anyopaque, Page) void,
        close: *const fn (*anyopaque, Connection, DisconnectReason) void,
        submit: *const fn (*anyopaque) void,
    };

    pub fn complete(self: Transport, events: []TransportEvent) []const TransportEvent {
        return events[0..self.vtable.complete(self.context, events)];
    }
};

fn reserveOutputUnavailable(_: *anyopaque, _: Connection, _: usize) ?[]u8 {
    return null;
}

fn commitOutputUnavailable(_: *anyopaque, _: Connection, _: usize) bool {
    return false;
}

pub const AttachPlayer = core_exchange.AttachPlayer;
pub const DetachPlayer = core_exchange.DetachPlayer;
pub const CoreInput = core_exchange.CoreInput;
