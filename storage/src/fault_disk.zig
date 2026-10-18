//! Deterministic power-loss model for the real storage backend. Successful writes modify
//! volatile bytes. Only successful syncs establish the durable image. A crash may persist
//! arbitrary sectors from working writes, including a torn sector, and discard the rest.
const std = @import("std");
const assert = std.debug.assert;
const metadata_bytes = 4096;

pub const Disk = struct {
    pub const Mode = enum { discard, persist, alternating, alternating_inverse, torn, torn_inverse, metadata_first, metadata_first_inverse };
    const capacity = 1024 * 1024;
    const sector_bytes = 512;
    const File = struct {
        inode: std.Io.File.INode,
        durable: []u8,
        working: []u8,
        durable_len: usize,
        working_len: usize,
    };

    allocator: std.mem.Allocator,
    underlying: std.Io,
    vtable: std.Io.VTable,
    files: []File,
    mutex: std.Io.Mutex = .init,
    events: usize = 0,
    syncs: usize = 0,
    directory_syncs: usize = 0,
    cut: usize,
    failed: bool = false,
    short_writes: bool,
    // Tests run one disk at a time. Preserve the underlying userdata so all unwrapped
    // std.Io operations keep their original implementation and worker ownership.
    var active: ?*Disk = null;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, files: []const std.Io.File, cut: usize, short_writes: bool) !Disk {
        const images = try allocator.alloc(File, files.len);
        errdefer allocator.free(images);
        var self: Disk = .{ .allocator = allocator, .underlying = io, .vtable = io.vtable.*, .files = images, .cut = cut, .short_writes = short_writes };
        var count: usize = 0;
        errdefer for (self.files[0..count]) |file| {
            allocator.free(file.durable);
            allocator.free(file.working);
        };
        for (files, self.files) |file, *image| {
            const durable = try allocator.alloc(u8, capacity);
            errdefer allocator.free(durable);
            const working = try allocator.alloc(u8, capacity);
            errdefer allocator.free(working);
            const stat = try file.stat(io);
            const len = stat.size;
            if (len > capacity) return error.NoSpaceLeft;
            if (try file.readPositionalAll(io, durable[0..len], 0) != len) return error.EndOfStream;
            @memcpy(working[0..len], durable[0..len]);
            image.* = .{ .inode = stat.inode, .durable = durable, .working = working, .durable_len = @intCast(len), .working_len = @intCast(len) };
            count += 1;
        }
        self.vtable.fileWritePositional = write;
        self.vtable.fileReadPositional = read;
        self.vtable.fileStat = fileStat;
        self.vtable.fileSync = sync;
        self.vtable.fileSetLength = setLength;
        return self;
    }

    pub fn deinit(self: *Disk) void {
        assert(active != self);
        for (self.files) |file| {
            self.allocator.free(file.durable);
            self.allocator.free(file.working);
        }
        self.allocator.free(self.files);
    }

    pub fn interface(self: *Disk) std.Io {
        assert(active == null or active == self);
        active = self;
        return .{ .userdata = self.underlying.userdata, .vtable = &self.vtable };
    }

    pub fn detach(self: *Disk) void {
        assert(active == self);
        active = null;
    }

    fn find(self: *Disk, file: std.Io.File) ?*File {
        const stat = file.stat(self.underlying) catch return null;
        for (self.files) |*image| if (image.inode == stat.inode) return image;
        return null;
    }

    fn event(self: *Disk) bool {
        if (self.failed) return false;
        self.events += 1;
        if (self.events == self.cut) {
            self.failed = true;
            return false;
        }
        return true;
    }

    fn write(_: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
        const self = active.?;
        self.mutex.lockUncancelable(self.underlying);
        defer self.mutex.unlock(self.underlying);
        const image = self.find(file) orelse return self.underlying.vtable.fileWritePositional(self.underlying.userdata, file, header, data, splat, offset);
        if (!self.event()) return error.InputOutput;
        // Persist one vector at a time, exercising short writes across scatter/gather boundaries.
        const bytes = if (header.len != 0) header else data[0];
        const len = if (self.short_writes) @min(bytes.len, 1021) else bytes.len;
        if (offset + len > capacity) return error.NoSpaceLeft;
        const n = len;
        if (offset > image.working_len) @memset(image.working[image.working_len..offset], 0);
        @memcpy(image.working[offset..][0..n], bytes[0..n]);
        image.working_len = @max(image.working_len, @as(usize, @intCast(offset)) + n);
        return n;
    }

    fn read(_: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        const self = active.?;
        self.mutex.lockUncancelable(self.underlying);
        defer self.mutex.unlock(self.underlying);
        const image = self.find(file) orelse return self.underlying.vtable.fileReadPositional(self.underlying.userdata, file, data, offset);
        if (offset >= image.working_len) return 0;
        var at: usize = @intCast(offset);
        for (data) |bytes| {
            const n = @min(bytes.len, image.working_len - at);
            @memcpy(bytes[0..n], image.working[at..][0..n]);
            at += n;
            if (at == image.working_len) break;
        }
        return at - @as(usize, @intCast(offset));
    }

    fn fileStat(_: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const self = active.?;
        self.mutex.lockUncancelable(self.underlying);
        defer self.mutex.unlock(self.underlying);
        var result = try file.stat(self.underlying);
        for (self.files) |image| if (image.inode == result.inode) {
            result.size = image.working_len;
            break;
        };
        return result;
    }

    fn sync(_: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        const self = active.?;
        self.mutex.lockUncancelable(self.underlying);
        defer self.mutex.unlock(self.underlying);
        const image = self.find(file);
        if (!self.event()) return error.InputOutput;
        // The model, rather than the host filesystem's page cache, determines durability.
        // Host fsync would add machine-dependent latency without adding a modeled guarantee.
        if (image) |f| {
            self.syncs += 1;
            @memcpy(f.durable[0..f.working_len], f.working[0..f.working_len]);
            f.durable_len = f.working_len;
        } else self.directory_syncs += 1;
    }

    fn setLength(_: ?*anyopaque, file: std.Io.File, len: u64) std.Io.File.SetLengthError!void {
        const self = active.?;
        self.mutex.lockUncancelable(self.underlying);
        defer self.mutex.unlock(self.underlying);
        const image = self.find(file) orelse return file.setLength(self.underlying, len);
        if (!self.event()) return error.InputOutput;
        if (len > capacity) return error.FileTooBig;
        if (len > image.working_len) @memset(image.working[image.working_len..len], 0);
        image.working_len = @intCast(len);
    }

    /// Drain pending I/O before crashing. Inodes identify files reopened during recovery.
    /// Do not flush during crash cleanup. That would persist writes the interrupted process never synced.
    pub fn crash(self: *Disk, mode: Mode) void {
        assert(active == null);
        for (self.files, 0..) |*image, file_index| {
            const len = switch (mode) {
                .discard => image.durable_len,
                .persist, .alternating_inverse, .torn_inverse, .metadata_first, .metadata_first_inverse => image.working_len,
                .alternating, .torn => @max(image.durable_len, image.working_len),
            };
            if (len > image.durable_len) @memset(image.durable[image.durable_len..len], 0);
            var offset: usize = 0;
            while (offset < len) : (offset += sector_bytes) {
                const end = @min(len, offset + sector_bytes);
                const persist = switch (mode) {
                    .discard => false,
                    .persist => true,
                    .metadata_first => offset < metadata_bytes or (offset / sector_bytes + file_index) % 2 == 0,
                    .metadata_first_inverse => offset < metadata_bytes or (offset / sector_bytes + file_index) % 2 != 0,
                    .alternating, .torn => (offset / sector_bytes + file_index) % 2 == 0,
                    .alternating_inverse, .torn_inverse => (offset / sector_bytes + file_index) % 2 != 0,
                };
                if (persist) {
                    const stop = if (mode == .torn or mode == .torn_inverse) offset + (end - offset) / 2 else end;
                    @memcpy(image.durable[offset..stop], image.working[offset..stop]);
                }
            }
            image.durable_len = len;
            image.working_len = len;
            @memcpy(image.working[0..len], image.durable[0..len]);
        }
    }
};
