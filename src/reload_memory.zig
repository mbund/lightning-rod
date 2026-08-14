const std = @import("std");
const huge_pages = @import("huge_page_allocator.zig");
const posix = std.posix;

/// One reusable virtual-memory arena for reloadable module state. A generation
/// is revoked and discarded before its successor can commit this address range.
pub const Arena = struct {
    mapping: []align(std.heap.page_size_min) u8,
    page_size: usize,
    occupied: bool = false,

    pub const default_virtual_bytes: usize = 1024 * 1024 * 1024 * 1024;

    pub const Region = struct {
        bytes: []u8,
        mapped: []align(std.heap.page_size_min) u8,
    };

    pub fn init(virtual_bytes: usize) !Arena {
        const page_size = std.heap.pageSize();
        const reserve = std.mem.alignForward(usize, virtual_bytes, page_size);
        if (reserve < page_size * 3) return error.ReloadAddressSpaceTooSmall;
        const mapping = try posix.mmap(
            null,
            reserve,
            .{},
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        return .{ .mapping = mapping, .page_size = page_size };
    }

    pub fn deinit(self: *Arena) void {
        posix.munmap(self.mapping);
        self.* = undefined;
    }

    pub fn allocate(self: *Arena, size: usize, alignment: usize) !Region {
        if (self.occupied) return error.ReloadStateArenaOccupied;
        if (size == 0 or alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidModuleStateLayout;
        if (alignment > self.page_size) return error.UnsupportedModuleStateAlignment;
        const body_len = std.mem.alignForward(usize, size, self.page_size);
        const mapping_address = @intFromPtr(self.mapping.ptr);
        const region_alignment = if (self.mapping.len >= huge_pages.huge_page_bytes * 2)
            huge_pages.huge_page_bytes
        else
            self.page_size;
        const absolute_start = std.mem.alignForward(
            usize,
            mapping_address + self.page_size,
            region_alignment,
        );
        const start = absolute_start - mapping_address;
        const end = std.math.add(usize, start, body_len) catch return error.ReloadAddressSpaceExhausted;
        const next = std.math.add(usize, end, self.page_size) catch return error.ReloadAddressSpaceExhausted;
        if (next > self.mapping.len) return error.ReloadAddressSpaceExhausted;
        const mapped: []align(std.heap.page_size_min) u8 = @alignCast(self.mapping[start..end]);
        try protect(mapped, .{ .READ = true, .WRITE = true });
        self.occupied = true;
        return .{ .bytes = mapped[0..size], .mapped = mapped };
    }

    pub fn retire(self: *Arena, region: Region) !void {
        std.debug.assert(self.occupied);
        try revoke(region.mapped);
        self.occupied = false;
    }

    pub fn trim(_: *Arena, region: Region, used_bytes: usize) !Region {
        if (used_bytes == 0 or used_bytes > region.bytes.len)
            return error.InvalidModuleStateUsage;
        const mapped_len = std.mem.alignForward(usize, used_bytes, std.heap.pageSize());
        if (mapped_len < region.mapped.len) {
            const tail: []align(std.heap.page_size_min) u8 =
                @alignCast(region.mapped[mapped_len..]);
            try revoke(tail);
        }
        const trimmed = Region{
            .bytes = region.bytes[0..used_bytes],
            .mapped = @alignCast(region.mapped[0..mapped_len]),
        };
        huge_pages.advise(trimmed.mapped);
        try huge_pages.commit(trimmed.mapped);
        return trimmed;
    }
};

fn protect(
    memory: []align(std.heap.page_size_min) u8,
    protection: posix.PROT,
) !void {
    switch (posix.errno(posix.system.mprotect(memory.ptr, memory.len, protection))) {
        .SUCCESS => {},
        .PERM => return error.PermissionDenied,
        .ACCES => return error.AccessDenied,
        .NOMEM => return error.OutOfMemory,
        .INVAL => return error.InvalidGenerationProtection,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn revoke(memory: []align(std.heap.page_size_min) u8) !void {
    try protect(memory, .{});
    try huge_pages.discard(memory);
}

test "retired reload generation faults and the arena reuses one address" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena = try Arena.init(huge_pages.huge_page_bytes * 4);
    defer arena.deinit();
    const first = try arena.allocate(32, 8);
    const first_address = @intFromPtr(first.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 0), first_address % huge_pages.huge_page_bytes);
    try arena.retire(first);
    try expectReadFault(first_address);
    const second = try arena.allocate(32, 8);
    try std.testing.expectEqual(first_address, @intFromPtr(second.bytes.ptr));
    try expectReadFault(@intFromPtr(second.mapped.ptr) + second.mapped.len);
}

test "generation state can discard unused capacity before activation" {
    var arena = try Arena.init(16 * std.heap.pageSize());
    defer arena.deinit();
    const region = try arena.allocate(std.heap.pageSize() * 4, 8);
    const trimmed = try arena.trim(region, std.heap.pageSize() + 17);
    try std.testing.expectEqual(std.heap.pageSize() + 17, trimmed.bytes.len);
    try std.testing.expectEqual(std.heap.pageSize() * 2, trimmed.mapped.len);
    try expectReadFault(@intFromPtr(region.mapped.ptr) + trimmed.mapped.len);
}

fn expectReadFault(address: usize) !void {
    const child = posix.system.fork();
    switch (posix.errno(child)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    if (child == 0) {
        const default_action: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        std.debug.updateSegfaultHandler(&default_action);
        const byte: *const volatile u8 = @ptrFromInt(address);
        _ = byte.*;
        posix.system.exit(0);
    }
    var status: c_int = undefined;
    var waited = false;
    for (0..1024) |_| switch (posix.errno(posix.system.waitpid(@intCast(child), &status, 0))) {
        .SUCCESS => {
            waited = true;
            break;
        },
        .INTR => continue,
        else => |err| return posix.unexpectedErrno(err),
    };
    try std.testing.expect(waited);
    try std.testing.expect(posix.W.IFSIGNALED(@bitCast(status)));
}
