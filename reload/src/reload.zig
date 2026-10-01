const std = @import("std");

pub const signal_token = "lightning_rod.signal.v1";

pub const Request = struct {
    enabled: bool,
    pending: bool = false,
    reply_bytes: [256]u8 = undefined,
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

    pub const Configuration = struct {};

    pub const Dependencies = struct { reload_request: ?*Request };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Reload {
        const self = try allocator.create(Reload);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn available(self: *const Reload) bool {
        return if (self.deps.reload_request) |request| request.enabled else false;
    }

    pub fn latest(self: *const Reload) ?*const Request {
        return self.deps.reload_request;
    }

    pub fn stage(self: *Reload, reply_token: []const u8) error{ Unavailable, AlreadyPending }!void {
        if (!self.available()) return error.Unavailable;
        try self.deps.reload_request.?.stage(reply_token);
    }
};
