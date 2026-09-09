pub const Handle = extern struct {
    index: u32,
    generation: u32,

    pub fn eql(a: Handle, b: Handle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

pub const Page = enum(u32) { _ };

pub const DisconnectReason = enum(u8) {
    peer_closed,
    timeout,
    transport_error,
    malformed_packet,
    overloaded,
    authentication_failed,
    server_shutdown,
    kicked,
};

pub const Limits = struct {
    connections: u16,
    pages: u16,
    page_bytes: u16,
    completions_per_advance: u16,
    packets_per_advance: u16,

    pub fn valid(self: Limits) bool {
        return self.connections != 0 and self.pages != 0 and self.page_bytes != 0 and
            self.completions_per_advance != 0 and self.packets_per_advance != 0;
    }
};
