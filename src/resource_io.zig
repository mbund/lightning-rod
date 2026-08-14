const std = @import("std");
const preallocated = @import("preallocated");

const linux = std.os.linux;
const lookup_empty = std.math.maxInt(u16);

pub const Configuration = struct {
    maximum_concurrent_operations: usize = 512,
    maximum_resource_bytes: usize = 512 * 1024,
    inline_resource_bytes: usize = 64 * 1024,
    maximum_large_resources: usize = 16,
    maximum_path_bytes: usize = 192,

    pub fn validate(self: Configuration) !void {
        if (self.maximum_concurrent_operations == 0 or
            self.maximum_concurrent_operations > std.math.maxInt(u13) / 4)
            return error.InvalidResourceCapacity;
        if (!std.math.isPowerOfTwo(self.maximum_concurrent_operations))
            return error.InvalidResourceCapacity;
        if (self.maximum_resource_bytes == 0 or self.maximum_path_bytes == 0 or
            self.maximum_path_bytes > std.math.maxInt(u16))
            return error.InvalidResourceCapacity;
        if (self.inline_resource_bytes == 0 or
            self.inline_resource_bytes >= self.maximum_resource_bytes or
            self.maximum_large_resources == 0 or
            self.maximum_large_resources > self.maximum_concurrent_operations)
            return error.InvalidResourceCapacity;
    }
};

pub const Status = enum(u8) {
    ok,
    pending,
    missing,
    backpressured,
    failed,
};

pub const Data = struct {
    status: Status,
    bytes: []const u8 = &.{},
};

pub const WritePoll = enum {
    not_started,
    pending,
    complete,
    failed,
};

pub const MemoryRecord = struct {
    path: []const u8,
    bytes: []const u8,
};

const CompletionStage = enum(u16) {
    state_machine,
    read_open,
    read_data,
    read_close,
};

const Phase = enum(u8) {
    idle,
    opening_read,
    reading,
    closing_read,
    creating_parent,
    opening_write,
    writing,
    syncing_write,
    closing_write,
    renaming,
    opening_parent,
    syncing_parent,
    closing_parent,
    aborting,
};

const Entry = struct {
    occupied: bool = false,
    result: Status = .pending,
    release_next_tick: bool = false,
    write_operation: bool = false,
    phase: Phase = .idle,
    fd: linux.fd_t = -1,
    path_len: u16 = 0,
    parent_path_len: u16 = 0,
    path_hash: u64 = 0,
    data_len: usize = 0,
    offset: usize = 0,
    path: []u8 = &.{},
    temporary_path: []u8 = &.{},
    parent_path: []u8 = &.{},
    inline_data: []u8 = &.{},
    data: []u8 = &.{},
    large_buffer: u16 = lookup_empty,

    fn pathSlice(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }

    fn reset(self: *Entry) void {
        const path = self.path;
        const temporary_path = self.temporary_path;
        const parent_path = self.parent_path;
        const inline_data = self.inline_data;
        self.* = .{
            .path = path,
            .temporary_path = temporary_path,
            .parent_path = parent_path,
            .inline_data = inline_data,
            .data = inline_data,
        };
    }
};

pub const Store = struct {
    configuration: Configuration = .{},
    entries: []Entry = &.{},
    lookup: []u16 = &.{},
    free_entries: []u16 = &.{},
    free_entry_count: usize = 0,
    large_buffers: [][]u8 = &.{},
    free_large_buffers: []u16 = &.{},
    free_large_buffer_count: usize = 0,

    pub fn allocate(self: *Store, allocator: std.mem.Allocator, configuration: Configuration) !void {
        try configuration.validate();
        self.* = .{ .configuration = configuration };
        self.entries = try preallocated.alloc(Entry, allocator, configuration.maximum_concurrent_operations);
        @memset(self.entries, .{});
        self.lookup = try preallocated.alloc(u16, allocator, configuration.maximum_concurrent_operations * 2);
        self.free_entries = try preallocated.alloc(u16, allocator, configuration.maximum_concurrent_operations);
        self.large_buffers = try preallocated.alloc([]u8, allocator, configuration.maximum_large_resources);
        self.free_large_buffers = try preallocated.alloc(u16, allocator, configuration.maximum_large_resources);
        for (self.large_buffers, 0..) |*buffer, index| {
            buffer.* = try preallocated.alloc(u8, allocator, configuration.maximum_resource_bytes + 1);
            self.free_large_buffers[index] = @intCast(configuration.maximum_large_resources - 1 - index);
        }
        self.free_large_buffer_count = self.free_large_buffers.len;
        for (self.entries) |*entry| {
            entry.path = try preallocated.alloc(u8, allocator, configuration.maximum_path_bytes + 1);
            entry.temporary_path = try preallocated.alloc(u8, allocator, configuration.maximum_path_bytes + 5);
            entry.parent_path = try preallocated.alloc(u8, allocator, configuration.maximum_path_bytes + 1);
            entry.inline_data = try preallocated.alloc(
                u8,
                allocator,
                configuration.inline_resource_bytes,
            );
            entry.data = entry.inline_data;
        }
        self.rebuildLookup();
    }

    pub fn beginTick(self: *Store) void {
        var changed = false;
        for (self.entries) |*entry| {
            if (!entry.release_next_tick) continue;
            if (entry.phase != .idle) continue;
            discardPages(entry.data);
            self.releaseLargeBuffer(entry);
            entry.reset();
            changed = true;
        }
        if (changed) self.rebuildLookup();
    }

    pub fn hasPendingOperations(self: *const Store) bool {
        for (self.entries) |*entry| {
            if (entry.occupied and entry.phase != .idle) return true;
        }
        return false;
    }

    pub fn read(
        self: *Store,
        ring: *linux.IoUring,
        path: []const u8,
        user_data_base: u64,
    ) Data {
        const index = self.findOrCreate(path) orelse return .{ .status = .backpressured };
        const entry = &self.entries[index];
        if (entry.phase == .idle and entry.result == .pending and entry.offset == 0) {
            self.startRead(index, ring, user_data_base) catch {
                entry.result = .failed;
            };
        }
        if (entry.result == .pending)
            return .{ .status = .pending };
        entry.release_next_tick = true;
        if (entry.result != .ok) return .{ .status = entry.result };
        return .{
            .status = .ok,
            .bytes = entry.data[0..entry.data_len],
        };
    }

    pub fn prefetch(
        self: *Store,
        ring: *linux.IoUring,
        path: []const u8,
        user_data_base: u64,
    ) Status {
        const index = self.findOrCreate(path) orelse return .backpressured;
        const entry = &self.entries[index];
        if (entry.phase == .idle and entry.result == .pending and
            entry.offset == 0)
        {
            self.startRead(index, ring, user_data_base) catch {
                entry.result = .failed;
            };
        }
        if (entry.result == .pending)
            return .pending;
        if (entry.result != .ok) entry.release_next_tick = true;
        return entry.result;
    }

    pub fn write(
        self: *Store,
        ring: *linux.IoUring,
        path: []const u8,
        bytes: []const u8,
        user_data_base: u64,
    ) Status {
        if (bytes.len > self.configuration.maximum_resource_bytes) {
            std.log.err(
                "event=resource_write_capacity path={s} required={} capacity={}",
                .{ path, bytes.len, self.configuration.maximum_resource_bytes },
            );
            return .failed;
        }
        const index = self.findOrCreate(path) orelse {
            std.log.err(
                "event=resource_write_table_exhausted path={s} capacity={}",
                .{ path, self.entries.len },
            );
            return .backpressured;
        };
        const entry = &self.entries[index];
        if (entry.phase != .idle) return .pending;
        if (!self.ensureDataCapacity(index, bytes.len, entry.data_len))
            return .backpressured;
        entry.release_next_tick = false;
        if (entry.result == .ok and entry.write_operation) {
            if (entry.data_len == bytes.len and
                std.mem.eql(u8, entry.data[0..entry.data_len], bytes))
            {
                entry.release_next_tick = true;
                return .ok;
            }
            @memcpy(entry.data[0..bytes.len], bytes);
            entry.data_len = bytes.len;
            entry.offset = 0;
            entry.result = .pending;
            self.startWrite(index, ring, user_data_base) catch {
                entry.result = .failed;
                return .failed;
            };
            return .pending;
        }
        if (entry.result == .ok and
            entry.data_len == bytes.len and
            std.mem.eql(u8, entry.data[0..entry.data_len], bytes))
        {
            entry.release_next_tick = true;
            return .ok;
        }
        if (entry.result == .failed) {
            entry.release_next_tick = true;
            entry.result = .pending;
            entry.data_len = 0;
            entry.offset = 0;
            return .failed;
        }
        @memcpy(entry.data[0..bytes.len], bytes);
        entry.data_len = bytes.len;
        entry.result = .pending;
        self.startWrite(index, ring, user_data_base) catch {
            entry.result = .failed;
            return .failed;
        };
        return .pending;
    }

    pub fn pollWrite(self: *Store, path: []const u8) WritePoll {
        const index = self.find(path) orelse return .not_started;
        const entry = &self.entries[index];
        if (!entry.write_operation) return .not_started;
        if (entry.phase != .idle or entry.result == .pending) return .pending;
        entry.release_next_tick = true;
        return switch (entry.result) {
            .ok => .complete,
            .failed, .missing, .backpressured => .failed,
            .pending => unreachable,
        };
    }

    pub fn readMemory(self: *Store, path: []const u8) Data {
        const index = self.findOrCreate(path) orelse return .{ .status = .backpressured };
        const entry = &self.entries[index];
        if (entry.result != .ok) return .{ .status = .missing };
        return .{
            .status = .ok,
            .bytes = entry.data[0..entry.data_len],
        };
    }

    pub fn writeMemory(self: *Store, path: []const u8, bytes: []const u8) Status {
        if (bytes.len > self.configuration.maximum_resource_bytes) return .failed;
        const index = self.findOrCreate(path) orelse return .backpressured;
        const entry = &self.entries[index];
        if (entry.phase != .idle) return .backpressured;
        if (!self.ensureDataCapacity(index, bytes.len, entry.data_len))
            return .backpressured;
        @memcpy(entry.data[0..bytes.len], bytes);
        entry.data_len = bytes.len;
        entry.result = .ok;
        return .ok;
    }

    pub fn memoryRecord(self: *const Store, index: usize) ?MemoryRecord {
        if (index >= self.entries.len) return null;
        const entry = &self.entries[index];
        if (!entry.occupied or entry.result != .ok) return null;
        return .{
            .path = entry.pathSlice(),
            .bytes = entry.data[0..entry.data_len],
        };
    }

    pub fn complete(
        self: *Store,
        index: usize,
        raw_stage: u16,
        ring: *linux.IoUring,
        cqe: linux.io_uring_cqe,
        user_data_base: u64,
    ) !void {
        if (index >= self.entries.len) return error.InvalidResourceCompletion;
        const entry = &self.entries[index];
        if (!entry.occupied or entry.phase == .idle)
            return error.StaleResourceCompletion;
        const stage = std.enums.fromInt(CompletionStage, raw_stage) orelse
            return error.InvalidResourceCompletionStage;
        if (stage != .state_machine)
            return self.completeRead(
                index,
                stage,
                ring,
                cqe,
                user_data_base,
            );
        const user_data = completionUserData(user_data_base, index, .state_machine);
        const completion_error = cqe.err();
        if (entry.phase == .opening_write and completion_error == .NOENT) {
            entry.phase = .creating_parent;
            _ = try ring.mkdirat(
                user_data,
                linux.AT.FDCWD,
                entry.parent_path[0..entry.parent_path_len :0].ptr,
                0o755,
            );
            return;
        }
        if (entry.phase == .creating_parent and completion_error == .EXIST) {
            entry.phase = .opening_write;
            try submitOpenWrite(entry, ring, user_data);
            return;
        }
        if (completion_error != .SUCCESS) {
            std.log.err(
                "event=resource_write_completion_failed path={s} phase={s} errno={}",
                .{ entry.pathSlice(), @tagName(entry.phase), completion_error },
            );
            if (entry.fd >= 0 and entry.phase != .aborting) {
                entry.phase = .aborting;
                _ = try ring.close(user_data, entry.fd);
                return;
            }
            fail(entry);
            return;
        }
        try completeWrite(entry, ring, cqe, user_data);
    }

    fn completeWrite(entry: *Entry, ring: *linux.IoUring, cqe: linux.io_uring_cqe, user_data: u64) !void {
        switch (entry.phase) {
            .opening_read, .reading, .closing_read => unreachable,
            .creating_parent => {
                entry.phase = .opening_write;
                try submitOpenWrite(entry, ring, user_data);
            },
            .opening_write => {
                entry.fd = @intCast(cqe.res);
                entry.phase = .writing;
                try submitWrite(entry, ring, user_data);
            },
            .writing => {
                if (cqe.res <= 0) return error.ResourceWriteMadeNoProgress;
                entry.offset += @intCast(cqe.res);
                if (entry.offset < entry.data_len) {
                    try submitWrite(entry, ring, user_data);
                    return;
                }
                std.debug.assert(entry.offset == entry.data_len);
                entry.phase = .syncing_write;
                _ = try ring.fsync(user_data, entry.fd, 0);
            },
            .syncing_write => {
                entry.phase = .closing_write;
                _ = try ring.close(user_data, entry.fd);
            },
            .closing_write => {
                entry.fd = -1;
                entry.phase = .renaming;
                _ = try ring.renameat(
                    user_data,
                    linux.AT.FDCWD,
                    entry.temporary_path[0 .. entry.path_len + 4 :0].ptr,
                    linux.AT.FDCWD,
                    entry.path[0..entry.path_len :0].ptr,
                    0,
                );
            },
            .renaming => {
                entry.phase = .opening_parent;
                _ = try ring.openat(
                    user_data,
                    linux.AT.FDCWD,
                    entry.parent_path[0..entry.parent_path_len :0].ptr,
                    .{
                        .ACCMODE = .RDONLY,
                        .DIRECTORY = true,
                        .CLOEXEC = true,
                    },
                    0,
                );
            },
            .opening_parent => {
                entry.fd = @intCast(cqe.res);
                entry.phase = .syncing_parent;
                _ = try ring.fsync(user_data, entry.fd, 0);
            },
            .syncing_parent => {
                entry.phase = .closing_parent;
                _ = try ring.close(user_data, entry.fd);
            },
            .closing_parent => {
                entry.fd = -1;
                entry.result = .ok;
                entry.phase = .idle;
            },
            .aborting => fail(entry),
            .idle => unreachable,
        }
    }

    fn findOrCreate(self: *Store, path: []const u8) ?usize {
        if (!validPath(path, self.configuration.maximum_path_bytes)) return null;
        const hash = std.hash.Wyhash.hash(0x7265_736f_7572_6365, path);
        var probe: usize = @intCast(hash & (self.lookup.len - 1));
        var empty_slot: ?usize = null;
        for (0..self.lookup.len) |_| {
            const encoded = self.lookup[probe];
            if (encoded == lookup_empty) {
                empty_slot = probe;
                break;
            }
            const entry = &self.entries[encoded];
            if (entry.path_hash == hash and
                std.mem.eql(u8, entry.pathSlice(), path))
                return encoded;
            probe = (probe + 1) & (self.lookup.len - 1);
        }
        const slot = empty_slot orelse return null;
        if (self.free_entry_count == 0) return null;
        self.free_entry_count -= 1;
        const index = self.free_entries[self.free_entry_count];
        const entry = &self.entries[index];
        std.debug.assert(!entry.occupied);
        entry.reset();
        entry.occupied = true;
        entry.path_hash = hash;
        entry.path_len = @intCast(path.len);
        @memcpy(entry.path[0..path.len], path);
        entry.path[path.len] = 0;
        @memcpy(entry.temporary_path[0..path.len], path);
        @memcpy(entry.temporary_path[path.len .. path.len + 4], ".tmp");
        entry.temporary_path[path.len + 4] = 0;
        const parent = parentPath(path);
        @memcpy(entry.parent_path[0..parent.len], parent);
        entry.parent_path[parent.len] = 0;
        entry.parent_path_len = @intCast(parent.len);
        self.lookup[slot] = index;
        return index;
    }

    fn find(self: *const Store, path: []const u8) ?usize {
        if (!validPath(path, self.configuration.maximum_path_bytes)) return null;
        const hash = std.hash.Wyhash.hash(0x7265_736f_7572_6365, path);
        var probe: usize = @intCast(hash & (self.lookup.len - 1));
        for (0..self.lookup.len) |_| {
            const encoded = self.lookup[probe];
            if (encoded == lookup_empty) return null;
            const entry = &self.entries[encoded];
            if (entry.path_hash == hash and std.mem.eql(u8, entry.pathSlice(), path))
                return encoded;
            probe = (probe + 1) & (self.lookup.len - 1);
        }
        return null;
    }

    fn rebuildLookup(self: *Store) void {
        @memset(self.lookup, lookup_empty);
        self.free_entry_count = 0;
        for (self.entries, 0..) |*entry, index| {
            if (!entry.occupied) {
                self.free_entries[self.free_entry_count] = @intCast(index);
                self.free_entry_count += 1;
                continue;
            }
            var probe: usize = @intCast(
                entry.path_hash & (self.lookup.len - 1),
            );
            for (0..self.lookup.len) |_| {
                if (self.lookup[probe] == lookup_empty) {
                    self.lookup[probe] = @intCast(index);
                    break;
                }
                probe = (probe + 1) & (self.lookup.len - 1);
            } else unreachable;
        }
    }

    fn ensureDataCapacity(self: *Store, index: usize, required: usize, preserve: usize) bool {
        const entry = &self.entries[index];
        if (required <= entry.data.len) return true;
        if (required > self.configuration.maximum_resource_bytes or
            self.free_large_buffer_count == 0)
            return false;
        std.debug.assert(entry.large_buffer == lookup_empty);
        self.free_large_buffer_count -= 1;
        const buffer_index = self.free_large_buffers[self.free_large_buffer_count];
        const buffer = self.large_buffers[buffer_index];
        @memcpy(buffer[0..preserve], entry.data[0..preserve]);
        entry.data = buffer;
        entry.large_buffer = buffer_index;
        return true;
    }

    fn releaseLargeBuffer(self: *Store, entry: *Entry) void {
        if (entry.large_buffer == lookup_empty) return;
        std.debug.assert(self.free_large_buffer_count < self.free_large_buffers.len);
        self.free_large_buffers[self.free_large_buffer_count] = entry.large_buffer;
        self.free_large_buffer_count += 1;
        entry.large_buffer = lookup_empty;
        entry.data = entry.inline_data;
    }

    fn startRead(self: *Store, index: usize, ring: *linux.IoUring, user_data_base: u64) !void {
        const entry = &self.entries[index];
        entry.write_operation = false;
        entry.offset = 0;
        entry.phase = .opening_read;
        errdefer entry.phase = .idle;
        const open = try ring.openat(
            completionUserData(user_data_base, index, .read_open),
            linux.AT.FDCWD,
            entry.path[0..entry.path_len :0].ptr,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            0,
        );
        open.flags |= linux.IOSQE_ASYNC;
    }

    fn completeRead(
        self: *Store,
        index: usize,
        stage: CompletionStage,
        ring: *linux.IoUring,
        cqe: linux.io_uring_cqe,
        user_data_base: u64,
    ) !void {
        const entry = &self.entries[index];
        switch (stage) {
            .read_open => {
                if (cqe.err() == .SUCCESS) {
                    entry.fd = @intCast(cqe.res);
                    entry.phase = .reading;
                    try submitRead(entry, index, ring, user_data_base);
                    return;
                }
                entry.result = if (cqe.err() == .NOENT) .missing else .failed;
                if (entry.result == .failed) {
                    std.log.err("event=resource_read_open_failed path={s} errno={}", .{ entry.pathSlice(), cqe.err() });
                }
                entry.phase = .idle;
            },
            .read_data => {
                if (cqe.err() != .SUCCESS or cqe.res < 0) {
                    entry.result = .failed;
                } else {
                    const bytes_read: usize = @intCast(cqe.res);
                    entry.offset += bytes_read;
                    if (entry.offset > self.configuration.maximum_resource_bytes) {
                        entry.result = .failed;
                    } else if (bytes_read != 0 and entry.offset == entry.data.len and
                        entry.data.len < self.configuration.maximum_resource_bytes + 1)
                    {
                        if (!self.ensureDataCapacity(index, self.configuration.maximum_resource_bytes, entry.offset)) {
                            entry.result = .backpressured;
                        } else {
                            try submitRead(entry, index, ring, user_data_base);
                            return;
                        }
                    } else {
                        entry.data_len = entry.offset;
                        entry.result = .ok;
                    }
                }
                entry.phase = .closing_read;
                _ = try ring.close(
                    completionUserData(user_data_base, index, .read_close),
                    entry.fd,
                );
            },
            .read_close => {
                entry.fd = -1;
                entry.phase = .idle;
                if (cqe.err() != .SUCCESS) entry.result = .failed;
            },
            .state_machine => unreachable,
        }
        if (entry.phase == .idle) entry.release_next_tick = true;
    }

    fn startWrite(self: *Store, index: usize, ring: *linux.IoUring, user_data_base: u64) !void {
        const entry = &self.entries[index];
        entry.write_operation = true;
        entry.offset = 0;
        entry.phase = .opening_write;
        errdefer entry.phase = .idle;
        try submitOpenWrite(
            entry,
            ring,
            completionUserData(user_data_base, index, .state_machine),
        );
    }
};

fn submitRead(entry: *Entry, index: usize, ring: *linux.IoUring, user_data_base: u64) !void {
    const read_sqe = try ring.read(
        completionUserData(user_data_base, index, .read_data),
        entry.fd,
        .{ .buffer = entry.data[entry.offset..] },
        entry.offset,
    );
    read_sqe.flags |= linux.IOSQE_ASYNC;
}

fn submitOpenWrite(entry: *Entry, ring: *linux.IoUring, user_data: u64) !void {
    const open = try ring.openat(
        user_data,
        linux.AT.FDCWD,
        entry.temporary_path[0 .. entry.path_len + 4 :0].ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    open.flags |= linux.IOSQE_ASYNC;
}

fn completionUserData(
    base: u64,
    index: usize,
    stage: CompletionStage,
) u64 {
    std.debug.assert(index <= std.math.maxInt(u16));
    return base |
        (@as(u64, @intFromEnum(stage)) << 16) |
        @as(u64, @intCast(index));
}

fn discardPages(memory: []u8) void {
    const page_size = std.heap.page_size_min;
    const memory_start = @intFromPtr(memory.ptr);
    const memory_end = memory_start + memory.len;
    const start = std.mem.alignForward(usize, memory_start, page_size);
    const end = memory_end - memory_end % page_size;
    if (start >= end) return;
    const pages: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    std.posix.madvise(pages, end - start, std.posix.MADV.DONTNEED) catch {};
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    if (slash == 0) return ".";
    return path[0..slash];
}

fn validPath(path: []const u8, maximum_bytes: usize) bool {
    if (path.len == 0 or path.len > maximum_bytes) return false;
    if (path[0] == '/' or std.mem.indexOf(u8, path, "..") != null) return false;
    for (path) |byte| {
        if (byte == 0 or byte == '\\') return false;
    }
    return true;
}

fn submitWrite(entry: *Entry, ring: *linux.IoUring, user_data: u64) !void {
    const write = try ring.write(
        user_data,
        entry.fd,
        entry.data[entry.offset..entry.data_len],
        entry.offset,
    );
    write.flags |= linux.IOSQE_ASYNC;
}

fn fail(entry: *Entry) void {
    const release_next_tick = !entry.write_operation;
    entry.fd = -1;
    entry.result = .failed;
    entry.phase = .idle;
    entry.release_next_tick = release_next_tick;
}

test "resource paths are relative and bounded" {
    try std.testing.expect(validPath("world/chunks/0_0.lrc", 192));
    try std.testing.expect(!validPath("/etc/passwd", 192));
    try std.testing.expect(!validPath("world/../secret", 192));
    try std.testing.expect(!validPath("", 192));
}

test "large resource buffers are borrowed only when needed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = Configuration{
        .maximum_concurrent_operations = 8,
        .maximum_resource_bytes = 128 * 1024,
        .inline_resource_bytes = 64 * 1024,
        .maximum_large_resources = 2,
    };
    var store: Store = .{};
    try store.allocate(arena.allocator(), configuration);
    const index = store.findOrCreate("world/chunks/0/0_0.lrc").?;
    const entry = &store.entries[index];
    try std.testing.expectEqual(configuration.inline_resource_bytes, entry.data.len);
    try std.testing.expect(store.ensureDataCapacity(index, 65 * 1024, 0));
    try std.testing.expectEqual(configuration.maximum_resource_bytes + 1, entry.data.len);
    try std.testing.expectEqual(@as(usize, 1), store.free_large_buffer_count);

    entry.release_next_tick = true;
    store.beginTick();
    try std.testing.expectEqual(@as(usize, 2), store.free_large_buffer_count);
    try std.testing.expectEqual(configuration.inline_resource_bytes, entry.data.len);
}

test "asynchronous missing resource completes as missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    var ring = try linux.IoUring.init(8, 0);
    defer ring.deinit();

    const base: u64 = 4 << 56;
    const path = ".zig-cache/lightning-rod-resource-does-not-exist";
    try std.testing.expectEqual(
        Status.pending,
        store.read(&ring, path, base).status,
    );
    _ = try ring.submit();

    var completions: [1]linux.io_uring_cqe = undefined;
    const count = try ring.copy_cqes(&completions, 1);
    try std.testing.expectEqual(@as(u32, 1), count);
    for (completions[0..count]) |completion| {
        const index: u16 = @truncate(completion.user_data);
        const stage: u16 = @truncate(completion.user_data >> 16);
        try store.complete(index, stage, &ring, completion, base);
    }
    try std.testing.expectEqual(
        Status.missing,
        store.read(&ring, path, base).status,
    );
}

test "missing read open is terminal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    const index = store.findOrCreate("world/chunks/0_0.lrc").?;
    store.entries[index].phase = .opening_read;
    var ring = try linux.IoUring.init(2, 0);
    defer ring.deinit();
    const base: u64 = 4 << 56;

    try store.complete(index, @intFromEnum(CompletionStage.read_open), &ring, .{
        .user_data = completionUserData(base, index, .read_open),
        .res = -@as(i32, @intFromEnum(linux.E.NOENT)),
        .flags = 0,
    }, base);
    try std.testing.expectEqual(Status.missing, store.entries[index].result);
    try std.testing.expectEqual(Phase.idle, store.entries[index].phase);
}

test "write acknowledges only the exact durable value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    var ring = try linux.IoUring.init(8, 0);
    defer ring.deinit();
    const base: u64 = 4 << 56;
    const path = "world/plugins/test.lrp";
    const index = store.findOrCreate(path).?;
    const entry = &store.entries[index];
    @memcpy(entry.data[0..3], "old");
    entry.data_len = 3;
    entry.result = .ok;

    try std.testing.expectEqual(
        Status.pending,
        store.write(&ring, path, "new", base),
    );
    try std.testing.expectEqual(Phase.opening_write, entry.phase);
    try std.testing.expectEqualStrings("new", entry.data[0..entry.data_len]);
}

test "missing write parent is created before retrying the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    var ring = try linux.IoUring.init(4, 0);
    defer ring.deinit();
    const base: u64 = 4 << 56;
    const index = store.findOrCreate("world/chunks/abc/0_0.lrc").?;
    const entry = &store.entries[index];
    entry.phase = .opening_write;
    entry.write_operation = true;

    try store.complete(index, @intFromEnum(CompletionStage.state_machine), &ring, .{
        .user_data = completionUserData(base, index, .state_machine),
        .res = -@as(i32, @intFromEnum(linux.E.NOENT)),
        .flags = 0,
    }, base);
    try std.testing.expectEqual(Phase.creating_parent, entry.phase);

    try store.complete(index, @intFromEnum(CompletionStage.state_machine), &ring, .{
        .user_data = completionUserData(base, index, .state_machine),
        .res = 0,
        .flags = 0,
    }, base);
    try std.testing.expectEqual(Phase.opening_write, entry.phase);
}

test "completed write does not acknowledge a different value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    var ring = try linux.IoUring.init(2, 0);
    defer ring.deinit();
    const path = "world/plugins/test.lrp";
    const index = store.findOrCreate(path).?;
    const entry = &store.entries[index];
    @memcpy(entry.data[0..3], "old");
    entry.data_len = 3;
    entry.result = .ok;
    entry.write_operation = true;

    try std.testing.expectEqual(
        Status.pending,
        store.write(&ring, path, "new", 4 << 56),
    );
    try std.testing.expectEqual(Phase.opening_write, entry.phase);
    try std.testing.expect(!entry.release_next_tick);
    try std.testing.expectEqualStrings("new", entry.data[0..entry.data_len]);
}

test "write polling never resubmits a completed resource" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    const path = "world/chunks/1/0_0.lrc";
    try std.testing.expectEqual(WritePoll.not_started, store.pollWrite(path));
    const entry = &store.entries[store.findOrCreate(path).?];
    entry.write_operation = true;
    entry.phase = .writing;
    try std.testing.expectEqual(WritePoll.pending, store.pollWrite(path));
    entry.phase = .idle;
    entry.result = .ok;
    try std.testing.expectEqual(WritePoll.complete, store.pollWrite(path));
    try std.testing.expect(entry.release_next_tick);
}

test "completed read can become a write before tick cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    var ring = try linux.IoUring.init(2, 0);
    defer ring.deinit();
    const path = "world/chunks/1/0_0.lrc";
    const index = store.findOrCreate(path).?;
    const entry = &store.entries[index];
    @memcpy(entry.data[0..3], "old");
    entry.data_len = 3;
    entry.result = .ok;
    entry.release_next_tick = true;

    try std.testing.expectEqual(
        Status.pending,
        store.write(&ring, path, "new", 4 << 56),
    );
    try std.testing.expectEqual(Phase.opening_write, entry.phase);
    try std.testing.expect(!entry.release_next_tick);
    try std.testing.expectEqualStrings("new", entry.data[0..entry.data_len]);
}

test "completed prefetched read expires on the next tick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    var ring = try linux.IoUring.init(2, 0);
    defer ring.deinit();
    const index = store.findOrCreate("world/chunks/1/0_0.lrc").?;
    const entry = &store.entries[index];
    entry.phase = .closing_read;
    entry.result = .ok;

    try store.complete(index, @intFromEnum(CompletionStage.read_close), &ring, .{
        .user_data = completionUserData(4 << 56, index, .read_close),
        .res = 0,
        .flags = 0,
    }, 4 << 56);
    try std.testing.expect(entry.release_next_tick);
    store.beginTick();
    try std.testing.expect(!entry.occupied);
}

test "durable write remains readable through the reload transaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store: Store = .{};
    try store.allocate(arena.allocator(), .{});
    var ring = try linux.IoUring.init(2, 0);
    defer ring.deinit();
    const path = "world/plugins/test-state.lrp";
    try std.testing.expectEqual(Status.ok, store.writeMemory(path, "session"));
    try std.testing.expectEqual(Status.ok, store.write(&ring, path, "session", 4 << 56));
    const restored = store.read(&ring, path, 4 << 56);
    try std.testing.expectEqual(Status.ok, restored.status);
    try std.testing.expectEqualStrings("session", restored.bytes);

    store.beginTick();
    try std.testing.expectEqual(Status.pending, store.read(&ring, path, 4 << 56).status);
}
