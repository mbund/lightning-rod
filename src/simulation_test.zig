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
        return .{ .directory = directory, .path = path, .store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path, .maximum_wal_pages = 1024 }) };
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

test "scoped simulations stage independent ticks for one coordinated commit" {
    var database = try Database.init();
    defer database.deinit();
    const directory = try database.store.openSpace("worlds");
    var scopes = [_]storage.Scope{ try .create(directory), try .create(directory) };
    const plugins = .{lightning_rod.plugin.configured(Probe, .{})};
    const Simulation = lightning_rod.Simulation(@TypeOf(plugins));
    var simulations: [2]*Simulation = undefined;
    var initialized: usize = 0;
    defer for (simulations[0..initialized]) |simulation| {
        simulation.unload(deadline()) catch unreachable;
        simulation.deinit(std.testing.allocator);
    };
    for (&simulations, &scopes) |*simulation, *scope| {
        simulation.* = try Simulation.init(std.testing.allocator, std.testing.io, &database.store, .{
            .scope = scope,
            .autosave = .{ .ticks = 1 },
        });
        initialized += 1;
        try simulation.*.initialize(plugins, .{});
    }
    try simulations[0].tick();
    try simulations[1].tick();
    try simulations[1].tick();
    for (simulations) |simulation| try std.testing.expect(simulation.save_requested.requested);
    const previous = database.store.lastCommit();
    for (simulations) |simulation| try simulation.stageCheckpoint();
    try std.testing.expectEqual(previous, database.store.lastCommit());
    try std.testing.expectEqual(@as(u64, 1), scopes[0].tick);
    try std.testing.expectEqual(@as(u64, 2), scopes[1].tick);
    try database.store.waitDurable(try database.store.commit(1));
    for (simulations) |simulation| {
        try std.testing.expect(!simulation.save_requested.requested);
        try std.testing.expectEqual(@as(usize, 1), simulation.get(Probe).checkpoints);
    }
    for (&scopes, 0..) |scope, index| {
        const restored = try storage.Scope.open(directory, scope.page);
        try std.testing.expectEqual(@as(u64, index + 1), restored.tick);
    }
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

test "providers retain concrete required and optional contract types" {
    const Contract = struct { value: usize };
    const Provider = struct {
        pub const id = "test:root_provider";
        pub const Configuration = struct {};
        pub const Provides = .{*Contract};
        contract: Contract,
        pub fn init(allocator: std.mem.Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .contract = .{ .value = 42 } };
            return self;
        }
        pub fn provide(self: *@This(), comptime T: type) T {
            if (T == *Contract) return &self.contract;
            @compileError("unknown contract");
        }
    };
    const selected = .{lightning_rod.plugin.configured(Provider, .{})};
    var provider: Provider = .{ .contract = .{ .value = 42 } };
    var root: lightning_rod.plugin.Instances(@TypeOf(selected)) = .{ .pointers = .{&provider}, .initialized = 1 };
    const contract = lightning_rod.plugin.dependency("routing", *Contract, &root, .{}, 1);
    const optional = lightning_rod.plugin.dependency("routing", ?*Contract, &root, .{}, 1);
    try std.testing.expectEqual(&provider.contract, contract);
    try std.testing.expectEqual(&provider.contract, optional.?);
}

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

test "sequential simulations borrow worker scratch and unload without forcing durability" {
    var first_database = try Database.init();
    defer first_database.deinit();
    var second_database = try Database.init();
    defer second_database.deinit();
    const scratch = try std.testing.allocator.alloc(u8, 1024);
    defer std.testing.allocator.free(scratch);
    const plugins = .{ lightning_rod.plugin.configured(CheckpointScratch, .{}), lightning_rod.plugin.configured(FirstSave, .{}) };
    const Sim = lightning_rod.Simulation(@TypeOf(plugins));
    const config: lightning_rod.Configuration = .{
        .memory_bytes = 16 * 1024,
        .scratch = scratch,
        .metrics = .{ .enabled = false },
        .autosave = .{ .ticks = null },
    };
    const first = try Sim.init(std.testing.allocator, std.testing.io, &first_database.store, config);
    defer first.deinit(std.testing.allocator);
    const second = try Sim.init(std.testing.allocator, std.testing.io, &second_database.store, config);
    defer second.deinit(std.testing.allocator);
    try first.initialize(plugins, .{});
    try second.initialize(plugins, .{});
    try first.tick();
    try second.tick();
    try std.testing.expectEqual(@intFromPtr(scratch.ptr), first.get(CheckpointScratch).address);
    try std.testing.expectEqual(first.get(CheckpointScratch).address, second.get(CheckpointScratch).address);
    try first.unload(deadline());
    try second.unload(deadline());
    for ([_]*storage.Store{ &first_database.store, &second_database.store }) |store| {
        try std.testing.expectEqual(@as(u64, 1), store.lastTick());
        try std.testing.expectEqual(@as(u64, 0), store.durableTick());
        const space = try store.openSpace(FirstSave.id);
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, 1), byte);
        try store.waitDurable(store.lastCommit());
        try std.testing.expectEqual(@as(u64, 1), store.durableTick());
    }
}
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
    database.store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = database.path, .maximum_wal_pages = 1024 });
    try std.testing.expectEqual(@as(u64, 1), database.store.lastTick());
    const space = try database.store.openSpace(FirstSave.id);
    var page: storage.Page = undefined;
    try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
    for (page) |byte| try std.testing.expectEqual(@as(u8, 1), byte);
}

test "configured reservation allocates capacity without restoring or checkpointing" {
    const Reserved = struct {
        const Self = @This();
        pub const id = "test:reservation";
        pub const Configuration = struct { capacity: usize };
        pub const Dependencies = struct { storage: storage.Space };
        bytes: []u8,

        pub fn allocate(allocator: std.mem.Allocator, config: Configuration) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .bytes = try allocator.alloc(u8, config.capacity) };
            return self;
        }
        pub fn init(_: std.mem.Allocator) !*Self {
            return error.RestoreWasCalled;
        }
        pub fn checkpoint(_: *Self, _: storage.Space) !void {
            return error.CheckpointWasCalled;
        }
    };
    var database = try Database.init();
    defer database.deinit();
    var previous: usize = 0;
    for ([_]usize{ 64, 256 }) |capacity| {
        const plugins = .{lightning_rod.plugin.configured(Reserved, .{ .capacity = capacity })};
        const Simulation = lightning_rod.Simulation(@TypeOf(plugins));
        const simulation = try Simulation.init(std.testing.allocator, std.testing.io, &database.store, .{});
        try simulation.reserve(plugins, .{});
        try std.testing.expectEqual(Simulation.State.reserved, simulation.state);
        try std.testing.expectEqual(capacity, simulation.get(Reserved).bytes.len);
        try std.testing.expect(try (try database.store.openSpace(Reserved.id)).getRoot() == null);
        const assigned = simulation.permanent.used();
        if (previous != 0) try std.testing.expectEqual(@as(usize, 192), assigned - previous);
        previous = assigned;
        try simulation.unload(deadline());
        simulation.deinit(std.testing.allocator);
    }
}
