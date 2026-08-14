const std = @import("std");
const config = @import("config.zig").value;
const huge_pages = @import("huge_page_allocator.zig");

const page_size = std.heap.page_size_min;
const protection_enabled = config.tick_input_memory_guards;
const body_len = std.mem.alignForward(usize, config.tick_input_arena_bytes, page_size);
const region_stride = body_len + page_size;

pub const Reservation = struct {
    offset: u32,
    bytes: []u8,
};

pub const Arena = struct {
    reservation: []align(page_size) u8,
    region_count: usize,
    active_region: usize = 0,
    cursor: usize = 0,

    pub fn init() !Arena {
        const requested_len = if (protection_enabled) config.tick_input_virtual_bytes else page_size + region_stride;
        const region_count = (requested_len - page_size) / region_stride;
        if (region_count == 0) return error.TickInputVirtualAddressTooSmall;
        const mapping_len = page_size + region_count * region_stride;
        const reservation = try std.posix.mmap(null, mapping_len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        errdefer std.posix.munmap(reservation);
        var self = Arena{ .reservation = reservation, .region_count = region_count };
        try protect(self.activeBody(), true);
        try huge_pages.commit(self.activeBody());
        return self;
    }

    pub fn deinit(self: *Arena) void {
        std.posix.munmap(self.reservation);
        self.* = undefined;
    }

    pub fn reserve(self: *Arena, len: usize) !Reservation {
        if (len > config.tick_input_arena_bytes -| self.cursor) return error.TickInputArenaFull;
        if (len > std.math.maxInt(u32) or self.cursor > std.math.maxInt(u32)) return error.TickInputArenaFull;
        const offset: u32 = @intCast(self.cursor);
        const bytes = self.activeBody()[self.cursor .. self.cursor + len];
        self.cursor += len;
        return .{ .offset = offset, .bytes = bytes };
    }

    pub fn cancelReservation(self: *Arena, reservation: Reservation) void {
        const end = @as(usize, reservation.offset) + reservation.bytes.len;
        std.debug.assert(end == self.cursor);
        self.cursor = reservation.offset;
    }

    pub fn copy(self: *Arena, source: []const u8) ![]u8 {
        const reservation = try self.reserve(source.len);
        @memcpy(reservation.bytes, source);
        return reservation.bytes;
    }

    /// Ends the current packet lifetime. In guarded builds the address is never
    /// reused: it becomes inaccessible and its physical pages are discarded.
    pub fn finishTick(self: *Arena) !void {
        if (protection_enabled) {
            if (self.active_region + 1 == self.region_count) return error.TickInputVirtualAddressExhausted;
            const consumed = self.activeBody();
            try protect(consumed, false);
            try std.posix.madvise(consumed.ptr, consumed.len, std.posix.MADV.DONTNEED);
            self.active_region += 1;
            try protect(self.activeBody(), true);
            try huge_pages.commit(self.activeBody());
        }
        self.cursor = 0;
    }

    pub fn activeAddress(self: *const Arena) usize {
        return @intFromPtr(self.activeBody().ptr);
    }

    pub fn reservedBytes(self: *const Arena) usize {
        return self.reservation.len;
    }

    fn activeBody(self: *const Arena) []align(page_size) u8 {
        const start = page_size + self.active_region * region_stride;
        return @alignCast(self.reservation[start .. start + body_len]);
    }
};

fn protect(memory: []align(page_size) u8, writable: bool) !void {
    const flags: std.posix.PROT = if (writable)
        .{ .READ = true, .WRITE = true }
    else
        .{};
    switch (std.posix.errno(std.posix.system.mprotect(memory.ptr, memory.len, flags))) {
        .SUCCESS => {},
        .PERM => return error.PermissionDenied,
        .ACCES => return error.AccessDenied,
        .NOMEM => return error.OutOfMemory,
        .INVAL => return error.InvalidArenaProtection,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

test "tick arena stores packet bodies and rotates debug mappings" {
    var arena = try Arena.init();
    defer arena.deinit();
    const body = try arena.copy("hello");
    try std.testing.expectEqualStrings("hello", body);
    const previous = arena.activeAddress();
    try arena.finishTick();
    if (protection_enabled)
        try std.testing.expect(previous != arena.activeAddress());
}

test "debug quarantine faults an escaped tick slice" {
    if (!protection_enabled) return;
    var arena = try Arena.init();
    defer arena.deinit();
    const escaped = try arena.copy("borrowed");
    try arena.finishTick();

    const fork_result = std.posix.system.fork();
    switch (std.posix.errno(fork_result)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    if (fork_result == 0) {
        const default_action: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.debug.updateSegfaultHandler(&default_action);
        const byte: *const volatile u8 = @ptrCast(escaped.ptr);
        _ = byte.*;
        std.posix.system.exit(0);
    }

    var status: c_int = undefined;
    var waited = false;
    for (0..1024) |_| switch (std.posix.errno(std.posix.system.waitpid(@intCast(fork_result), &status, 0))) {
        .SUCCESS => {
            waited = true;
            break;
        },
        .INTR => continue,
        else => |err| return std.posix.unexpectedErrno(err),
    };
    try std.testing.expect(waited);
    try std.testing.expect(std.posix.W.IFSIGNALED(@bitCast(status)));
}

test "guard page catches a small overrun" {
    if (!protection_enabled) return;
    var arena = try Arena.init();
    defer arena.deinit();
    const body = arena.activeBody();
    const guard: *const volatile u8 = @ptrFromInt(@intFromPtr(body.ptr) + body.len);

    const fork_result = std.posix.system.fork();
    switch (std.posix.errno(fork_result)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    if (fork_result == 0) {
        const default_action: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.debug.updateSegfaultHandler(&default_action);
        _ = guard.*;
        std.posix.system.exit(0);
    }
    var status: c_int = undefined;
    var waited = false;
    for (0..1024) |_| switch (std.posix.errno(std.posix.system.waitpid(@intCast(fork_result), &status, 0))) {
        .SUCCESS => {
            waited = true;
            break;
        },
        .INTR => continue,
        else => |err| return std.posix.unexpectedErrno(err),
    };
    try std.testing.expect(waited);
    try std.testing.expect(std.posix.W.IFSIGNALED(@bitCast(status)));
}
