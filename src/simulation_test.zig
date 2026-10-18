const std = @import("std");
const lightning_rod = @import("lightning_rod");
const storage = @import("storage");

const Database = struct {
    directory: std.testing.TmpDir,
    path: []u8,
    store: storage.Store,

    fn init() !Database {
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{directory.sub_path});
        errdefer std.testing.allocator.free(path);
        return .{ .directory = directory, .path = path, .store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024 }) };
    }
    fn deinit(self: *Database) void {
        self.store.deinit();
        std.testing.allocator.free(self.path);
        self.directory.cleanup();
    }
};
fn deadline() std.Io.Clock.Timestamp {
    return .fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromSeconds(5) });
}
const Probe = struct {
    pub const id = "test:checkpoint";
    pub const Configuration = struct {};
    pub const Dependencies = struct { checkpoint: *lightning_rod.Checkpoint };
    deps: Dependencies,
    value: u64 = 0,
    saved: u64 = 0,
    checkpoints: usize = 0,
    fail_at: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *Probe) !void {
        self.value += 1;
        if (self.value == self.fail_at) return error.TickFailed;
    }

    pub fn checkpoint(self: *Probe, _: storage.Space) !void {
        self.saved = self.value;
        self.checkpoints += 1;
    }
};

const CheckpointScratch = struct {
    pub const id = "test:checkpoint_scratch";
    pub const Configuration = struct {};
    pub const Dependencies = struct {};
    const scratch_bytes = 1024;

    address: usize = 0,
    checkpoints: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*CheckpointScratch {
        const self = try allocator.create(CheckpointScratch);
        self.* = .{};
        return self;
    }

    pub fn tick(self: *CheckpointScratch, allocator: std.mem.Allocator) !void {
        const bytes = try allocator.alloc(u8, scratch_bytes);
        @memset(bytes, 1);
        self.address = @intFromPtr(bytes.ptr);
    }

    pub fn checkpoint(self: *CheckpointScratch, _: storage.Space, allocator: std.mem.Allocator, _: std.Io) !void {
        const bytes = try allocator.alloc(u8, scratch_bytes);
        try std.testing.expectEqual(self.address, @intFromPtr(bytes.ptr));
        @memset(bytes, 2);
        self.checkpoints += 1;
    }
};

const CheckpointScratchFollower = struct {
    pub const id = "test:checkpoint_scratch_follower";
    pub const Configuration = struct {};
    pub const Dependencies = struct { first: *CheckpointScratch };

    deps: Dependencies,
    checkpoints: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*CheckpointScratchFollower {
        const self = try allocator.create(CheckpointScratchFollower);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn checkpoint(self: *CheckpointScratchFollower, allocator: std.mem.Allocator, _: storage.Space) !void {
        const bytes = try allocator.alloc(u8, CheckpointScratch.scratch_bytes);
        try std.testing.expectEqual(self.deps.first.address, @intFromPtr(bytes.ptr));
        @memset(bytes, 3);
        self.checkpoints += 1;
    }
};

test "disabled autosave saves the complete tick on shutdown" {
    var database = try Database.init();
    defer database.deinit();
    const plugins = .{lightning_rod.plugin.configured(Probe, .{})};
    const simulation = try lightning_rod.Simulation(@TypeOf(plugins)).init(std.testing.allocator, std.testing.io, &database.store, .{ .memory_bytes = 16 * 1024, .temporary_bytes = 1024, .metrics = .{ .enabled = false }, .autosave = .{ .ticks = null } });
    defer simulation.deinit(std.testing.allocator);
    try simulation.initialize(plugins, .{});
    const probe = simulation.get(Probe);
    for (0..300) |_| try simulation.tick();
    try std.testing.expectEqual(@as(u64, 0), database.store.lastTick());
    try std.testing.expectEqual(@as(usize, 0), probe.checkpoints);
    try simulation.close(deadline());
    try std.testing.expectEqual(@as(u64, 300), database.store.durableTick());
    try std.testing.expectEqual(@as(usize, 1), probe.checkpoints);
}

test "scheduled and requested saves preserve the active transaction" {
    var database = try Database.init();
    defer database.deinit();
    const plugins = .{lightning_rod.plugin.configured(Probe, .{})};
    const simulation = try lightning_rod.Simulation(@TypeOf(plugins)).init(std.testing.allocator, std.testing.io, &database.store, .{ .memory_bytes = 16 * 1024, .temporary_bytes = 1024, .metrics = .{ .enabled = false }, .autosave = .{ .ticks = 3 } });
    defer simulation.deinit(std.testing.allocator);
    try simulation.initialize(plugins, .{});
    const probe = simulation.get(Probe);
    for (0..3) |_| try simulation.tick();
    try std.testing.expectEqual(@as(u64, 3), database.store.lastTick());
    probe.deps.checkpoint.request();
    try simulation.tick();
    try std.testing.expectEqual(@as(u64, 4), database.store.lastTick());
    for (0..3) |_| try simulation.tick();
    try std.testing.expectEqual(@as(u64, 7), database.store.lastTick());
    try std.testing.expectEqual(@as(usize, 3), probe.checkpoints);
    try std.testing.expectEqual(&database.store, simulation.transaction.store);
    try simulation.close(deadline());
}

test "shutdown does not save state from a failed tick" {
    var database = try Database.init();
    defer database.deinit();
    const plugins = .{lightning_rod.plugin.configured(Probe, .{})};
    const simulation = try lightning_rod.Simulation(@TypeOf(plugins)).init(std.testing.allocator, std.testing.io, &database.store, .{ .memory_bytes = 16 * 1024, .temporary_bytes = 1024, .metrics = .{ .enabled = false }, .autosave = .{ .ticks = 2 } });
    defer simulation.deinit(std.testing.allocator);
    try simulation.initialize(plugins, .{});
    const probe = simulation.get(Probe);
    probe.fail_at = 3;
    try simulation.tick();
    try simulation.tick();
    try std.testing.expectError(error.TickFailed, simulation.tick());
    try simulation.close(deadline());
    try std.testing.expectEqual(@as(u64, 2), database.store.durableTick());
    try std.testing.expectEqual(@as(u64, 2), probe.saved);
}

test "save hooks each reuse the complete tick scratch buffer" {
    var database = try Database.init();
    defer database.deinit();
    const plugins = .{ lightning_rod.plugin.configured(CheckpointScratch, .{}), lightning_rod.plugin.configured(CheckpointScratchFollower, .{}) };
    const simulation = try lightning_rod.Simulation(@TypeOf(plugins)).init(std.testing.allocator, std.testing.io, &database.store, .{ .memory_bytes = 16 * 1024, .temporary_bytes = 1024, .metrics = .{ .enabled = false }, .autosave = .{ .ticks = 2 } });
    defer simulation.deinit(std.testing.allocator);
    try simulation.initialize(plugins, .{});
    const first = simulation.get(CheckpointScratch);
    const second = simulation.get(CheckpointScratchFollower);
    for (0..3) |_| try simulation.tick();
    try simulation.close(deadline());
    try std.testing.expectEqual(@as(usize, 2), first.checkpoints);
    try std.testing.expectEqual(@as(usize, 2), second.checkpoints);
    try std.testing.expectEqual(@as(usize, 0), simulation.temporary.end_index);
}

const FirstSave = struct {
    pub const id = "test:first_save";
    pub const Configuration = struct {};
    value: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) !*FirstSave {
        const self = try allocator.create(FirstSave);
        self.* = .{};
        return self;
    }
    pub fn tick(self: *FirstSave) void {
        self.value += 1;
    }
    pub fn checkpoint(self: *FirstSave, space: storage.Space) !void {
        const root = try space.getRoot() orelse blk: {
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            try space.setRoot(ids[0]);
            break :blk ids[0];
        };
        const page: storage.Page = @splat(self.value);
        try space.writePages(&.{.{ .id = root, .source = &page }});
    }
};
const SecondSave = struct {
    pub const id = "test:second_save";
    pub const Configuration = struct {};
    pub const Dependencies = struct { first: *FirstSave };
    deps: Dependencies,
    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*SecondSave {
        const self = try allocator.create(SecondSave);
        self.* = .{ .deps = deps };
        return self;
    }
    pub fn checkpoint(self: *SecondSave, _: storage.Space) !void {
        if (self.deps.first.value == 2) return error.InjectedCheckpointFailure;
    }
};

test "a failed plugin save cannot publish an earlier plugin's staged pages" {
    var database = try Database.init();
    defer database.deinit();
    const plugins = .{ lightning_rod.plugin.configured(FirstSave, .{}), lightning_rod.plugin.configured(SecondSave, .{}) };
    const simulation = try lightning_rod.Simulation(@TypeOf(plugins)).init(std.testing.allocator, std.testing.io, &database.store, .{ .memory_bytes = 16 * 1024, .temporary_bytes = 1024, .metrics = .{ .enabled = false }, .autosave = .{ .ticks = 1 } });
    try simulation.initialize(plugins, .{});
    try simulation.tick();
    try std.testing.expectError(error.InjectedCheckpointFailure, simulation.tick());
    try simulation.close(deadline());
    simulation.deinit(std.testing.allocator);
    database.store.deinit();
    database.store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = database.path, .submission = .standard, .maximum_wal_pages = 1024 });
    try std.testing.expectEqual(@as(u64, 1), database.store.lastTick());
    const space = try database.store.openSpace(FirstSave.id);
    var page: storage.Page = undefined;
    try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
    for (page) |byte| try std.testing.expectEqual(@as(u8, 1), byte);
}
