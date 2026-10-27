const std = @import("std");
pub const handoff = @import("handoff.zig");

pub const Compatibility = struct {
    pub const capacity = 256;
    bytes: [capacity * 12]u8 = undefined,
    length: usize = 0,

    pub fn supports(self: *const Compatibility, protocol: i32, format: ?u64) bool {
        std.debug.assert(self.length <= self.bytes.len and self.length % 12 == 0);
        var index: usize = 0;
        while (index < self.length) : (index += 12) {
            if (std.mem.readInt(i32, self.bytes[index..][0..4], .little) == protocol and
                (format == null or std.mem.readInt(u64, self.bytes[index + 4 ..][0..8], .little) == format.?)) return true;
        }
        return false;
    }
};

pub const signal_token = "lightning_rod.signal.v1";

pub const Request = struct {
    enabled: bool,
    pending: bool = false,
    reply_bytes: [handoff.reply_token_capacity]u8 = undefined,
    reply_len: u16 = 0,
    sequence: u64 = 0,
    started_ns: i96 = 0,
    result: ?enum { succeeded, rolled_back, rejected } = null,
    elapsed_ms: u64 = 0,

    pub fn token(self: *const Request) []const u8 {
        return self.reply_bytes[0..self.reply_len];
    }

    pub fn stage(self: *Request, reply_token: []const u8) error{ Unavailable, AlreadyPending }!void {
        if (!self.enabled) return error.Unavailable;
        if (self.pending) return error.AlreadyPending;
        self.reply_len = if (reply_token.len <= self.reply_bytes.len) @intCast(reply_token.len) else 0;
        // The caller's token may be tick-local. Oversized metadata is best-effort.
        @memcpy(self.reply_bytes[0..self.reply_len], reply_token[0..self.reply_len]);
        self.pending = true;
    }
};

pub const Reload = struct {
    pub const id = "lightning_rod:reload";

    pub const Configuration = struct { request: ?*Request = null };

    request: ?*Request,

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !*Reload {
        const self = try allocator.create(Reload);
        self.* = .{ .request = config.request };
        return self;
    }

    pub fn available(self: *const Reload) bool {
        return if (self.request) |request| request.enabled else false;
    }

    pub fn latest(self: *const Reload) ?*const Request {
        return self.request;
    }

    pub fn stage(self: *Reload, reply_token: []const u8) error{ Unavailable, AlreadyPending }!void {
        if (!self.available()) return error.Unavailable;
        try self.request.?.stage(reply_token);
    }
};
