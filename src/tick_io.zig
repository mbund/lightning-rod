const std = @import("std");
const config = @import("config.zig").value;
const preallocated = @import("preallocated");
const resource_io = @import("resource_io.zig");

const linux = std.os.linux;
const completion_user_data_base: u64 = 0;
pub const Configuration = resource_io.Configuration;

pub const Status = resource_io.Status;
pub const Data = resource_io.Data;
pub const MemoryRecord = resource_io.MemoryRecord;

pub const ReadResult = union(enum) {
    pending,
    missing,
    failed,
    ready: []const u8,
};

pub const WriteResult = enum {
    pending,
    complete,
    failed,
};

pub const WritePoll = resource_io.WritePoll;

pub const TestingApi = struct {
    context: *anyopaque,
    prefetch: *const fn (*anyopaque, []const u8) Status,
    read: *const fn (*anyopaque, []const u8) Data,
    write: *const fn (*anyopaque, []const u8, []const u8) Status,
};

const Disk = struct {
    store: resource_io.Store = .{},
    ring: linux.IoUring,
};

const Backend = union(enum) {
    disk: *Disk,
    memory: *resource_io.Store,
    testing: *const TestingApi,
};

pub const TickIo = struct {
    backend: Backend,
    configuration: Configuration,

    pub fn create(allocator: std.mem.Allocator, configuration: Configuration) !*TickIo {
        try configuration.validate();
        try prepareDirectories();
        const self = try preallocated.create(TickIo, allocator);
        const disk = try preallocated.create(Disk, allocator);
        disk.* = .{ .ring = try linux.IoUring.init(@intCast(configuration.maximum_concurrent_operations * 4), 0) };
        errdefer disk.ring.deinit();
        try disk.store.allocate(allocator, configuration);
        self.* = .{ .backend = .{ .disk = disk }, .configuration = configuration };
        return self;
    }

    pub fn createMemory(allocator: std.mem.Allocator, configuration: Configuration) !*TickIo {
        try configuration.validate();
        const self = try preallocated.create(TickIo, allocator);
        const store = try preallocated.create(resource_io.Store, allocator);
        store.* = .{};
        try store.allocate(allocator, configuration);
        self.* = .{ .backend = .{ .memory = store }, .configuration = configuration };
        return self;
    }

    pub fn initTesting(api: *const TestingApi) TickIo {
        return .{ .backend = .{ .testing = api }, .configuration = .{} };
    }

    pub fn begin(self: TickIo) !void {
        switch (self.backend) {
            .disk => |disk| try pump(disk, false),
            .memory => |store| store.beginTick(),
            .testing => {},
        }
    }

    pub fn finish(self: TickIo) !void {
        switch (self.backend) {
            .disk => |disk| _ = try disk.ring.submit(),
            .memory, .testing => {},
        }
    }

    pub fn synchronize(self: TickIo) !void {
        switch (self.backend) {
            .disk => |disk| try drain(disk),
            .memory, .testing => {},
        }
    }

    pub fn deinit(self: TickIo) void {
        switch (self.backend) {
            .disk => |disk| {
                drain(disk) catch |err|
                    std.log.err("event=tick_io_drain_failed err={s}", .{@errorName(err)});
                disk.ring.deinit();
            },
            .memory, .testing => {},
        }
    }

    pub fn prefetch(self: TickIo, path: []const u8) Status {
        if (!validPath(path, self.configuration.maximum_path_bytes)) return .failed;
        return switch (self.backend) {
            .disk => |disk| disk.store.prefetch(&disk.ring, path, completion_user_data_base),
            .memory => |store| store.readMemory(path).status,
            .testing => |api| api.prefetch(api.context, path),
        };
    }

    pub fn ensureDirectory(self: TickIo, path: []const u8) !void {
        if (!validPath(path, self.configuration.maximum_path_bytes)) return error.InvalidResourcePath;
        switch (self.backend) {
            .disk => try std.Io.Dir.cwd().createDirPath(
                std.Io.Threaded.global_single_threaded.io(),
                path,
            ),
            .memory, .testing => {},
        }
    }

    pub fn read(self: TickIo, path: []const u8) ReadResult {
        if (!validPath(path, self.configuration.maximum_path_bytes)) return .failed;
        const result = switch (self.backend) {
            .disk => |disk| disk.store.read(&disk.ring, path, completion_user_data_base),
            .memory => |store| store.readMemory(path),
            .testing => |api| api.read(api.context, path),
        };
        return readResult(result);
    }

    pub fn write(self: TickIo, path: []const u8, value: []const u8) WriteResult {
        if (!validPath(path, self.configuration.maximum_path_bytes) or value.len > self.configuration.maximum_resource_bytes) return .failed;
        const status = switch (self.backend) {
            .disk => |disk| disk.store.write(&disk.ring, path, value, completion_user_data_base),
            .memory => |store| store.writeMemory(path, value),
            .testing => |api| api.write(api.context, path, value),
        };
        return writeResult(status);
    }

    pub fn pollWrite(self: TickIo, path: []const u8) WritePoll {
        if (!validPath(path, self.configuration.maximum_path_bytes)) return .failed;
        return switch (self.backend) {
            .disk => |disk| disk.store.pollWrite(path),
            .memory => |store| store.pollWrite(path),
            .testing => .not_started,
        };
    }

    pub fn readSync(self: TickIo, path: []const u8) !?[]const u8 {
        for (0..self.configuration.maximum_concurrent_operations * 16) |_| {
            switch (self.read(path)) {
                .ready => |bytes| return bytes,
                .missing => return null,
                .failed => return error.ResourceReadFailed,
                .pending => {},
            }
            try self.finish();
            try self.synchronize();
        }
        return error.ResourceOperationStalled;
    }

    pub fn writeSync(self: TickIo, path: []const u8, value: []const u8) !void {
        for (0..self.configuration.maximum_concurrent_operations * 16) |_| {
            switch (self.write(path, value)) {
                .complete => return,
                .failed => return error.ResourceWriteFailed,
                .pending => {},
            }
            try self.finish();
            try self.synchronize();
        }
        return error.ResourceOperationStalled;
    }

    pub fn prefetchPlugin(self: TickIo, plugin_id: []const u8) Status {
        var storage: [config.max_resource_path_bytes]u8 = undefined;
        return self.prefetch(pluginPath(&storage, plugin_id) catch return .failed);
    }

    pub fn readPlugin(self: TickIo, plugin_id: []const u8) ReadResult {
        var storage: [config.max_resource_path_bytes]u8 = undefined;
        return self.read(pluginPath(&storage, plugin_id) catch return .failed);
    }

    pub fn writePlugin(self: TickIo, plugin_id: []const u8, value: []const u8) WriteResult {
        var storage: [config.max_resource_path_bytes]u8 = undefined;
        return self.write(pluginPath(&storage, plugin_id) catch return .failed, value);
    }

    pub fn readPluginSync(self: TickIo, plugin_id: []const u8) !?[]const u8 {
        var storage: [config.max_resource_path_bytes]u8 = undefined;
        return self.readSync(try pluginPath(&storage, plugin_id));
    }

    pub fn writePluginSync(self: TickIo, plugin_id: []const u8, value: []const u8) !void {
        var storage: [config.max_resource_path_bytes]u8 = undefined;
        try self.writeSync(try pluginPath(&storage, plugin_id), value);
    }

    pub fn memoryRecord(self: TickIo, index: usize) ?MemoryRecord {
        return switch (self.backend) {
            .memory => |store| store.memoryRecord(index),
            .disk, .testing => null,
        };
    }
};

fn pump(disk: *Disk, wait: bool) !void {
    disk.store.beginTick();
    _ = try disk.ring.submit();
    var completions: [config.completion_batch]linux.io_uring_cqe = undefined;
    for (0..disk.store.entries.len * 16) |_| {
        if (wait and disk.store.hasPendingOperations())
            _ = try disk.ring.submit_and_wait(1);
        const count = try disk.ring.copy_cqes(&completions, 0);
        if (count == 0) return;
        for (completions[0..count]) |completion| {
            const index: u16 = @truncate(completion.user_data);
            const stage: u16 = @truncate(completion.user_data >> 16);
            try disk.store.complete(index, stage, &disk.ring, completion, completion_user_data_base);
        }
        _ = try disk.ring.submit();
    }
    return error.TickIoCompletionLimitExceeded;
}

fn drain(disk: *Disk) !void {
    for (0..disk.store.entries.len * 16) |_| {
        try pump(disk, true);
        if (!disk.store.hasPendingOperations()) return;
    }
    return error.TickIoDrainLimitExceeded;
}

fn prepareDirectories() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, config.world_chunks_path);
    try cwd.createDirPath(io, config.world_plugins_path);
}

fn writeResult(status: Status) WriteResult {
    return switch (status) {
        .ok => .complete,
        .pending, .backpressured => .pending,
        .missing, .failed => .failed,
    };
}

fn readResult(value: Data) ReadResult {
    return switch (value.status) {
        .pending, .backpressured => .pending,
        .missing => .missing,
        .failed => .failed,
        .ok => .{ .ready = value.bytes },
    };
}

fn validPath(path: []const u8, maximum_bytes: usize) bool {
    if (path.len == 0 or path.len > maximum_bytes) return false;
    if (path[0] == '/' or std.mem.indexOf(u8, path, "..") != null) return false;
    for (path) |byte| if (byte == 0 or byte == '\\') return false;
    return true;
}

pub fn pluginPath(buffer: []u8, plugin_id: []const u8) ![]const u8 {
    if (plugin_id.len == 0 or plugin_id.len > config.max_plugin_id_bytes)
        return error.InvalidPluginId;
    const prefix = config.world_plugins_path ++ "/";
    const suffix = ".lrp";
    const path_len = prefix.len + plugin_id.len * 2 + suffix.len;
    if (path_len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..prefix.len], prefix);
    const hex = "0123456789abcdef";
    var cursor = prefix.len;
    for (plugin_id) |byte| {
        buffer[cursor] = hex[byte >> 4];
        buffer[cursor + 1] = hex[byte & 0x0f];
        cursor += 2;
    }
    @memcpy(buffer[cursor .. cursor + suffix.len], suffix);
    return buffer[0..path_len];
}

test "plugin resource paths are stable and isolated" {
    var storage: [config.max_resource_path_bytes]u8 = undefined;
    const path = try pluginPath(&storage, "example:economy");
    try std.testing.expectEqualStrings(
        "world/plugins/6578616d706c653a65636f6e6f6d79.lrp",
        path,
    );
}

test "memory storage supports deterministic harnesses without filesystem IO" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = try TickIo.createMemory(arena.allocator(), .{});
    try std.testing.expectEqual(WriteResult.complete, io.writePlugin("test:state", "value"));
    switch (io.readPlugin("test:state")) {
        .ready => |bytes| try std.testing.expectEqualStrings("value", bytes),
        else => return error.ExpectedStoredValue,
    }
    try io.writePluginSync("test:state", "new value");
    const bytes = (try io.readPluginSync("test:state")) orelse
        return error.ExpectedStoredValue;
    try std.testing.expectEqualStrings("new value", bytes);
}
