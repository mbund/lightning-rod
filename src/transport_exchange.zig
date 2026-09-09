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
        release_input: *const fn (*anyopaque, Page) void,
        close: *const fn (*anyopaque, Connection, DisconnectReason) void,
        submit: *const fn (*anyopaque) void,
    };

    pub fn complete(self: Transport, events: []TransportEvent) []const TransportEvent {
        return events[0..self.vtable.complete(self.context, events)];
    }
};

pub const AttachPlayer = struct {
    connection: Connection,
    uuid: u128,
    protocol: i32,
    name: [16]u8,
    name_len: u8,
    reconfiguring: bool,
};
pub const DetachPlayer = struct { connection: Connection, reason: DisconnectReason };
pub const CoreInput = struct {
    attachments: []const AttachPlayer,
    detachments: []const DetachPlayer,
    packet_views: []const core_exchange.PacketView,
    packet_claimed: []bool,
};
