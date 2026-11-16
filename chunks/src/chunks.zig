const ChunkStore = @import("store.zig").Store;
const metrics = @import("metrics");
const std = @import("std");
pub const Prepared = @import("prepared.zig");
pub const Delivery = @import("delivery.zig");
const builtin = @import("builtin");
const records = @import("records");
const storage = @import("storage");
pub const encoding = @import("encoding.zig");
pub const patch = @import("patch.zig");
pub const Generation = @import("generation.zig").Generation;
pub const GenerationPriority = @import("generation.zig").Priority;
pub const Light = @import("light.zig");
pub const ReadWindow = @import("read_window.zig").ReadWindow;
pub const classification = @import("classification.zig");
pub const topology = @import("topology.zig");
pub const layer = @import("layer.zig");
pub const Copies = @import("copies.zig").Copies;

const Cache = records.CacheFor(Backend);
const Backend = struct {
    pub const write_batch_size = records.Table.write_batch_size;
    store: ChunkStore,

    pub fn putBatch(self: *Backend, writes: []const records.Write) !void {
        try self.store.putBatch(writes);
    }
    pub fn flush(self: *Backend) !void {
        try self.store.flush();
    }
    pub fn fail(self: *Backend) void {
        self.store.fail();
    }
};

const assert = std.debug.assert;
/// Edits one section batch may carry, one for each of its cells.
const edit_previous_max = 4096;

pub const World = u32;

pub const Position = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const Section = struct {
    world: World,
    x: i32,
    y: i32,
    z: i32,
};

pub const BlockEdit = encoding.BlockEdit;

pub const SectionEdits = struct {
    section: Section,
    edits: []const BlockEdit,
};

/// Allocate with the chunk owner. Only the snapshot reader reconfigures the watched regions.
pub const Watch = struct {
    pub const Region = struct {
        world: World,
        minimum: Position,
        maximum: Position,

        fn contains(self: Region, section: Section) bool {
            return section.world == self.world and
                section.x >= self.minimum.x and section.x <= self.maximum.x and
                section.y >= self.minimum.y and section.y <= self.maximum.y and
                section.z >= self.minimum.z and section.z <= self.maximum.z;
        }
    };

    owner: *Chunks,
    next: ?*Watch = null,
    region: Region = undefined,
    width: usize = 0,
    height: usize = 0,
    versions: []std.atomic.Value(u64),
    modified: std.atomic.Value(bool) = .init(false),
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, owner: *Chunks, capacity: usize) !*Watch {
        assert(capacity > 0);
        return create(allocator, owner, capacity);
    }

    pub fn initInvalidation(allocator: std.mem.Allocator, owner: *Chunks) !*Watch {
        return create(allocator, owner, 0);
    }

    fn create(allocator: std.mem.Allocator, owner: *Chunks, capacity: usize) !*Watch {
        const self = try allocator.create(Watch);
        self.* = .{
            .owner = owner,
            .versions = try allocator.alloc(std.atomic.Value(u64), capacity),
        };
        for (self.versions) |*version| version.* = .init(0);
        owner.mutex.lockUncancelable(owner.io);
        defer owner.mutex.unlock(owner.io);
        self.next = owner.watches;
        owner.watches = self;
        return self;
    }

    /// Capture the old section revisions at the same barrier that installs the new bounds.
    pub fn configure(self: *Watch, region: Region, previous: []u64) void {
        assert(self.versions.len != 0);
        assert(previous.len == self.versions.len);
        assert(region.minimum.x <= region.maximum.x and region.minimum.y <= region.maximum.y and region.minimum.z <= region.maximum.z);
        const width: usize = @intCast(@as(i64, region.maximum.x) - region.minimum.x + 1);
        const height: usize = @intCast(@as(i64, region.maximum.y) - region.minimum.y + 1);
        const depth: usize = @intCast(@as(i64, region.maximum.z) - region.minimum.z + 1);
        assert(width <= self.versions.len and height <= self.versions.len / width);
        assert(depth <= self.versions.len / (width * height));
        self.owner.mutex.lockUncancelable(self.owner.io);
        defer self.owner.mutex.unlock(self.owner.io);
        for (self.versions, previous) |*version, *old| {
            old.* = version.load(.monotonic);
            version.store(0, .release);
        }
        self.region = region;
        self.width = width;
        self.height = height;
        self.count = width * height * depth;
        self.modified.store(false, .release);
    }

    pub fn observe(self: *Watch, region: Region) void {
        assert(self.versions.len == 0);
        assert(region.minimum.x <= region.maximum.x and region.minimum.y <= region.maximum.y and region.minimum.z <= region.maximum.z);
        self.owner.mutex.lockUncancelable(self.owner.io);
        defer self.owner.mutex.unlock(self.owner.io);
        self.region = region;
        self.width = @intCast(@as(i64, region.maximum.x) - region.minimum.x + 1);
        self.height = @intCast(@as(i64, region.maximum.y) - region.minimum.y + 1);
        const depth: usize = @intCast(@as(i64, region.maximum.z) - region.minimum.z + 1);
        self.count = self.width * self.height * depth;
        self.modified.store(false, .release);
    }

    /// Install a result's watch only if its source snapshot is still current.
    pub fn capture(self: *Watch, source: *const Watch, expected: []const u64) bool {
        assert(self != source and self.owner == source.owner);
        self.owner.mutex.lockUncancelable(self.owner.io);
        defer self.owner.mutex.unlock(self.owner.io);
        assert(expected.len == source.count and source.versions.len >= source.count and self.versions.len >= source.count);
        for (expected, 0..) |version, index| if (source.revision(index) != version) return false;
        self.region = source.region;
        self.width = source.width;
        self.height = source.height;
        self.count = source.count;
        for (self.versions[0..self.count]) |*version| version.store(0, .release);
        self.modified.store(false, .release);
        return true;
    }

    pub fn unchanged(self: *const Watch) bool {
        return !self.modified.load(.acquire);
    }

    pub fn revision(self: *const Watch, index: usize) u64 {
        assert(index < self.count and index < self.versions.len);
        return self.versions[index].load(.acquire);
    }

    fn changed(self: *Watch, section: Section) void {
        if (self.count == 0 or !self.region.contains(section)) return;
        // Invalidate before publishing any per-section revision.
        self.modified.store(true, .release);
        if (self.versions.len == 0) return;
        const x: usize = @intCast(@as(i64, section.x) - self.region.minimum.x);
        const y: usize = @intCast(@as(i64, section.y) - self.region.minimum.y);
        const z: usize = @intCast(@as(i64, section.z) - self.region.minimum.z);
        const index = (z * self.width + x) * self.height + y;
        assert(index < self.count);
        const previous = self.versions[index].fetchAdd(1, .release);
        assert(previous != std.math.maxInt(u64));
    }
};

pub const Observer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        changed: *const fn (*anyopaque, Section, []const BlockEdit, []const u16) void,
    };

    pub fn init(owner: anytype, comptime handler: anytype) Observer {
        const Adapter = struct {
            const vtable: VTable = .{ .changed = @This().invoke };

            fn invoke(raw: *anyopaque, section: Section, edits: []const BlockEdit, previous: []const u16) void {
                const typed: @TypeOf(owner) = @ptrCast(@alignCast(raw));
                return handler(typed, section, edits, previous);
            }
        };
        return .{ .context = owner, .vtable = &Adapter.vtable };
    }

    /// Edits and previous states are borrowed. Each previous state is what its edit's cell
    /// held before the whole batch, also when the batch writes the cell more than once.
    /// Record invalidation without changing the world.
    pub fn changed(self: Observer, section: Section, edits: []const BlockEdit, previous: []const u16) void {
        assert(edits.len == previous.len);
        return self.vtable.changed(self.context, section, edits, previous);
    }
};

pub const Source = struct {
    pub const batch_max = 8;
    pub const Request = struct {
        section: Section,
        output: []u8,
        result: anyerror!usize = error.GenerationIncomplete,
        token: usize = 0,
        completed: bool = false,
    };
    pub const Batch = struct {
        requests: []Request,
        owner: *Generation,

        /// Publishing releases outputs to consumers. Never touch a published output again.
        pub fn complete(self: Batch, requests: []Request) void {
            assert(@intFromPtr(requests.ptr) >= @intFromPtr(self.requests.ptr));
            assert(@intFromPtr(requests.ptr) + requests.len * @sizeOf(Request) <= @intFromPtr(self.requests.ptr) + self.requests.len * @sizeOf(Request));
            self.owner.publish(requests);
        }
    };
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readMany: *const fn (*anyopaque, std.Io, Batch) void,
    };

    pub fn init(owner: anytype, comptime handler: anytype) Source {
        const Adapter = struct {
            const vtable: VTable = .{ .readMany = @This().invoke };
            fn invoke(raw: *anyopaque, io: std.Io, batch: Batch) void {
                const typed: @TypeOf(owner) = @ptrCast(@alignCast(raw));
                handler(typed, io, batch);
            }
        };
        return .{ .context = owner, .vtable = &Adapter.vtable };
    }

    /// Workers may call concurrently. Sources must finish accessing the batch before returning.
    /// Each output is borrowed until its completion is published.
    pub fn readMany(self: Source, io: std.Io, batch: Batch) void {
        assert(batch.requests.len > 0 and batch.requests.len <= batch_max);
        self.vtable.readMany(self.context, io, batch);
        for (batch.requests) |request| {
            if (request.completed) continue;
            batch.complete(batch.requests);
            break;
        }
    }
};

/// Writebacks one background preparation may make before it yields.
const background_writeback_attempts = 4;

pub const Chunks = struct {
    pub const id = "lightning_rod:chunks";

    const edits_client: u8 = 0;
    const simulation_client: u8 = 1;
    const unowned: u8 = std.math.maxInt(u8);

    pub const Configuration = struct {
        wakeup: ?*std.Io.Event = null,
        cache_sections: usize = 192,
        /// Sections generated at once. A section being generated for a preparation counts
        /// against the budget of the client that prepared it.
        generation_slots: usize = 192,
        /// Sections one batch of edits holds while applying it. Larger batches apply in parts.
        edit_sections: usize = 24,
        /// Sections gameplay on the simulation thread holds at once, all plugins together. They
        /// run one after another, so they share one budget sized for the deepest nesting.
        simulation_sections: usize = 64,
        /// Clients that may register a budget.
        clients: usize = 32,
        cache_groups: usize = 8,
        /// Maximum groups per storage read batch. Write bytes and prepared results are independent.
        storage_batch_groups: usize = 8,
        storage_write_bytes: ?usize = null,
        storage_prepared_groups: usize = 2,
        generation_work: storage.system.work.Limits = Generation.default_work,
        /// Side length of each persisted base group, measured in sections.
        storage_group_side: u8 = 4,
        observers: usize = 8,

        /// The policy for a server with this many player slots. A vanilla server registers 480
        /// sections of budgets: edits 24, the simulation 64, streaming and the lighting solver
        /// 192 each and block sync 8. As much again stays warm for whoever reads next, and the
        /// cache grows by two columns of sections for each slot.
        pub fn forPlayers(slots: usize) Configuration {
            assert(slots != 0);
            return .{ .cache_sections = 2 * 480 + 48 * slots };
        }
    };

    /// What a client of the section cache may hold at once. Budgets are registered while the
    /// server starts and together fit the cache, so a client waits only on its own work, on
    /// I/O and on generation, never on what another client holds.
    pub const Budget = struct {
        name: []const u8,
        sections: usize,
    };

    const ClientState = struct {
        name: []const u8,
        budget: usize,
        /// Leases and sections being generated for the client's preparations.
        held: usize = 0,
        /// Of `held`, the sections being generated.
        generating: usize = 0,
    };

    /// A registered reader of the section cache. Every lease it takes counts against its budget
    /// until released.
    pub const Client = struct {
        chunks: *Chunks,
        index: u8,

        pub fn budget(self: Client) usize {
            return self.chunks.clients[self.index].budget;
        }

        /// Sections the client may still lease or prepare. Sections being generated for its
        /// preparations count until they are ready, so this only grows behind its back.
        pub fn available(self: Client) usize {
            const owner = self.chunks;
            owner.mutex.lockUncancelable(owner.io);
            defer owner.mutex.unlock(owner.io);
            const state = owner.clients[self.index];
            return state.budget - state.held;
        }

        pub fn acquire(self: Client, section: Section) !Lease {
            var out: [1]Lease = undefined;
            try self.acquireMany(&.{section}, &out);
            return out[0];
        }

        pub fn acquireMany(self: Client, sections: []const Section, output: []Lease) !void {
            const owner = self.chunks;
            owner.mutex.lockUncancelable(owner.io);
            defer owner.mutex.unlock(owner.io);
            try owner.acquireLocked(self.index, sections, output, null);
        }

        /// Optional leases may be released to fit the budget or before waiting for I/O. The
        /// caller owns the remaining slice on both success and failure.
        pub fn acquireManyRetaining(self: Client, sections: []const Section, output: []Lease, retention: *Retention) !void {
            const owner = self.chunks;
            assert(sections.len == output.len and sections.len <= 192);
            assert(retention.limit <= self.budget() -| sections.len);
            owner.mutex.lockUncancelable(owner.io);
            defer owner.mutex.unlock(owner.io);
            owner.releaseRetained(retention, @min(retention.limit, retention.leases.len));
            try owner.acquireLocked(self.index, sections, output, retention);
        }

        /// Leases sections only if every one is in memory already. Does no IO and waits for
        /// nothing but the cache lock. False leases nothing.
        pub fn acquireCached(self: Client, sections: []const Section, output: []Lease) bool {
            return self.chunks.acquireCached(self.index, sections, output);
        }

        /// Complete results transfer their leases to the caller. Incomplete outputs remain
        /// untouched. Never waits on I/O the batch did not start.
        pub fn prepareMany(self: Client, requests: []const Preparation, completed: []bool) !void {
            return self.chunks.prepareMany(self.index, requests, completed);
        }

        pub fn iterate(self: Client, sections: []const Section, leases: []Lease) Iterator {
            assert(leases.len > 0);
            return .{ .client = self, .sections = sections, .leases = leases };
        }

        /// Reads one block, from storage if the section is not in memory.
        pub fn getBlock(self: Client, world: World, pos: Position) !u16 {
            const lease = try self.acquire(sectionAt(world, pos));
            defer lease.release();
            return lease.get(localIndex(pos));
        }
    };

    pub const Dependencies = struct {
        record_workspaces: *records.Workspaces,
        metrics: *metrics.Registry,
        storage: storage.Space,
    };

    const ReadWorkspace = struct {
        busy: bool = false,
        requests: []records.Get,
        fills: []Cache.Fill,
        lengths: []?usize,

        fn init(allocator: std.mem.Allocator, readers: usize, capacity: usize) ![]ReadWorkspace {
            assert(readers > 0 and capacity > 0 and capacity <= 192);
            const workspaces = try allocator.alloc(ReadWorkspace, readers);
            errdefer allocator.free(workspaces);
            const requests = try allocator.alloc(records.Get, readers * capacity);
            errdefer allocator.free(requests);
            const fills = try allocator.alloc(Cache.Fill, readers * capacity);
            errdefer allocator.free(fills);
            const lengths = try allocator.alloc(?usize, readers * capacity);
            for (workspaces, 0..) |*workspace, index| workspace.* = .{
                .requests = requests[index * capacity ..][0..capacity],
                .fills = fills[index * capacity ..][0..capacity],
                .lengths = lengths[index * capacity ..][0..capacity],
            };
            return workspaces;
        }
    };
    read_workspaces: []ReadWorkspace,
    generating: []?Cache.Fill,
    /// By cache entry, the client whose budget a section being generated counts against, or
    /// `unowned` when generation fills a section its requester holds a lease on.
    generating_owner: []u8,
    generating_count: usize = 0,
    borrowed_count: usize = 0,
    cache: Cache,
    clients: []ClientState,
    client_count: usize = 0,
    /// Sections reserved by edits and registered clients together.
    budgeted: usize,
    edit_sections: usize,
    mutex: std.Io.Mutex = .init,
    writeback_mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    writing: []bool,
    writing_count: usize = 0,
    checkpoint_leases: []Cache.Lease,
    checkpointing: bool = false,
    watches: ?*Watch = null,
    background_owner: std.atomic.Value(std.Thread.Id) = .init(0),
    work_ready: std.Io.Event = .unset,
    io: std.Io,
    wakeup: ?*std.Io.Event = null,

    /// Topologies the simulation thread reads summaries of, answered in `poll`.
    topologies: ?*topology.Topology = null,
    generation: *Generation,
    observers: []Observer,
    ready_observers: []*std.Io.Event,
    ready_count: usize = 0,
    observer_count: usize = 0,
    notifying: bool = false,
    /// Edits observers made in answer to the notification under way.
    chained: [chain_max]Chained = undefined,
    chained_count: usize = 0,
    /// Chained edits waiting to apply, the next on top.
    chain_stack: [chain_stack_max]Chained = undefined,
    chain_stack_count: usize = 0,
    edit_scratch: [encoding.maximum_decoded_bytes]u8 = undefined,
    /// States the cells of one applied batch held before it, kept for its notifications.
    edit_previous: [edit_previous_max]u16 = undefined,
    /// Counts batches of edits. The batch being announced has this stamp.
    edit_stamp: u64 = 0,
    /// By cache entry, the stamp of the edit batch that made a dirty section dirty.
    /// Meaningless while the entry is clean.
    dirty_since: []u64,
    /// Counts batches of dirty sections whose write to storage began.
    write_mark: std.atomic.Value(u64) = .init(0),
    /// The write mark when the edits being notified were applied.
    edit_mark: u64 = 0,
    /// Counts checkpoints that wrote every section dirty when they began.
    flush_mark: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Chunks {
        const self = try allocate(allocator, io, configuration, deps);
        try self.cache.backend.store.open();
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Chunks {
        const generation_slots = @min(configuration.cache_sections, configuration.generation_slots);
        if (configuration.generation_slots == 0 or configuration.edit_sections == 0 or configuration.edit_sections > 192 or configuration.clients == 0 or configuration.clients >= unowned)
            return error.InvalidConfiguration;
        if (configuration.simulation_sections > 192) return error.InvalidConfiguration;
        if (configuration.clients < 2 or configuration.edit_sections + configuration.simulation_sections > configuration.cache_sections) return error.InvalidConfiguration;
        const self = try allocator.create(Chunks);
        self.* = .{
            .io = io,
            .wakeup = configuration.wakeup,
            .clients = try allocator.alloc(ClientState, configuration.clients),
            .budgeted = configuration.edit_sections + configuration.simulation_sections,
            .edit_sections = configuration.edit_sections,
            .cache = try Cache.init(allocator, io, .{ .store = try ChunkStore.allocate(allocator, io, deps.storage, configuration.cache_groups, deps.metrics, deps.record_workspaces.resources, .{
                .side = configuration.storage_group_side,
                .batch_groups = configuration.storage_batch_groups,
                .write_bytes = configuration.storage_write_bytes,
                .prepared_groups = configuration.storage_prepared_groups,
            }) }, .{
                .metrics = deps.metrics,
                .metrics_namespace = "chunks.cache",
                .slots = configuration.cache_sections,
                .key_bytes = 16,
                .value_bytes = std.mem.alignForward(usize, encoding.maximum_decoded_bytes, 64),
                .codec = .{ .encode = encoding.encode },
            }),
            .observers = try allocator.alloc(Observer, configuration.observers),
            .ready_observers = try allocator.alloc(*std.Io.Event, configuration.observers),
            .generation = undefined,
            .generating = try allocator.alloc(?Cache.Fill, configuration.cache_sections),
            .generating_owner = try allocator.alloc(u8, configuration.cache_sections),
            .writing = try allocator.alloc(bool, configuration.cache_sections),
            .dirty_since = try allocator.alloc(u64, configuration.cache_sections),
            .checkpoint_leases = try allocator.alloc(Cache.Lease, configuration.cache_sections),
            .read_workspaces = try ReadWorkspace.init(allocator, deps.record_workspaces.resources.readers.slots.len, @min(192, configuration.cache_sections)),
        };
        @memset(self.generating, null);
        @memset(self.generating_owner, unowned);
        @memset(self.writing, false);
        // Edits and the simulation are the first clients. Their budgets are part of `budgeted` already.
        self.clients[edits_client] = .{ .name = "edits", .budget = configuration.edit_sections };
        self.clients[simulation_client] = .{ .name = "simulation", .budget = configuration.simulation_sections };
        self.client_count = 2;
        self.generation = try Generation.init(allocator, io, generation_slots, self.ready(), deps.metrics);
        try self.generation.configureWork(configuration.generation_work);
        return self;
    }

    /// Registers a client while the server starts. Fails when the budgets would outgrow the cache,
    /// naming each one, so a server is sized before it runs rather than starved while it does.
    pub fn client(self: *Chunks, budget: Budget) !Client {
        if (budget.sections == 0 or budget.sections > 192 or budget.name.len == 0) return error.InvalidBudget;
        if (self.client_count == self.clients.len) return error.ClientCapacity;
        if (self.budgeted + budget.sections > self.cache.entries.len) {
            std.log.warn("event=chunk_budget_exceeded cache_sections={d} budgeted={d} requested={d} client={s}", .{ self.cache.entries.len, self.budgeted, budget.sections, budget.name });
            for (self.clients[0..self.client_count]) |state| std.log.warn("event=chunk_budget client={s} sections={d}", .{ state.name, state.budget });
            return error.CacheBudgetExceeded;
        }
        self.clients[self.client_count] = .{ .name = budget.name, .budget = budget.sections };
        self.budgeted += budget.sections;
        self.client_count += 1;
        return .{ .chunks = self, .index = @intCast(self.client_count - 1) };
    }

    /// The client gameplay reads through on the simulation thread. A plugin names the most it
    /// holds at once, nested reads included, so a server too small for it fails at startup.
    pub fn simulation(self: *Chunks, sections: usize) !Client {
        const state = self.clients[simulation_client];
        if (sections > state.budget) {
            std.log.warn("event=chunk_budget_exceeded client=simulation sections={d} requested={d}", .{ state.budget, sections });
            return error.CacheBudgetExceeded;
        }
        return .{ .chunks = self, .index = simulation_client };
    }

    /// Sections no budget holds, which further clients may register.
    pub fn unbudgeted(self: *const Chunks) usize {
        return self.cache.entries.len - self.budgeted;
    }

    pub fn setSource(self: *Chunks, source: Source) void {
        assert(self.background_owner.load(.acquire) == 0);
        self.generation.setSource(source);
    }

    pub fn subscribeReady(self: *Chunks, event: *std.Io.Event) !void {
        if (self.ready_count == self.ready_observers.len) return error.ObserverCapacity;
        for (self.ready_observers[0..self.ready_count]) |previous| assert(previous != event);
        self.ready_observers[self.ready_count] = event;
        self.ready_count += 1;
    }

    pub fn unsubscribeReady(self: *Chunks, event: *std.Io.Event) void {
        for (self.ready_observers[0..self.ready_count], 0..) |previous, index| {
            if (previous != event) continue;
            self.ready_count -= 1;
            self.ready_observers[index] = self.ready_observers[self.ready_count];
            return;
        }
        unreachable;
    }

    fn notifyReady(self: *Chunks) void {
        for (self.ready_observers[0..self.ready_count]) |event| event.set(self.generation.io);
    }

    pub fn ownsCurrentThread(self: *const Chunks) bool {
        const owner = self.background_owner.load(.acquire);
        return owner == 0 or owner == std.Thread.getCurrentId();
    }

    pub fn observe(self: *Chunks, observer: Observer) !void {
        assert(!self.notifying);
        if (self.observer_count == self.observers.len)
            return error.ObserverCapacity;
        self.observers[self.observer_count] = observer;
        self.observer_count += 1;
    }

    /// This targeted query may read disk. Reuse section leases for scans and
    /// acquireMany for a known neighborhood instead of repeatedly calling it.
    pub fn lightDependencies(self: *Chunks, input: []const Light.Request, snapshots: []Light.Dependencies) !void {
        assert(input.len == snapshots.len and input.len <= Light.dependency_batch_max);
        // A flush can clear dirtiness after reading older revisions. Observe dirtiness first.
        // The caller's watch detects subsequent edits.
        self.mutex.lockUncancelable(self.io);
        for (input, snapshots) |entry, *snapshot| snapshot.clean = self.lightCleanLocked(entry.column, entry.minimum, entry.count);
        self.mutex.unlock(self.io);
        try self.cache.backend.store.lightDependencies(input, snapshots);
    }

    pub fn lightFrames(self: *Chunks, input: []const Light.Request, output: *Light.FrameBatch) !void {
        return self.deliveryFrames(input, output, null);
    }

    pub fn deliveryFrames(self: *Chunks, input: []const Light.Request, output: *Light.FrameBatch, additional: ?*Delivery.ReadBatch) !void {
        assert(input.len <= Light.frame_batch_max and input.len == output.clean.len and input.len == output.frames.len and input.len == output.complete.len);
        self.mutex.lockUncancelable(self.io);
        for (input, output.clean) |entry, *clean| clean.* = self.lightCleanLocked(entry.column, entry.minimum, entry.count);
        self.mutex.unlock(self.io);
        try self.cache.backend.store.deliveryFrames(input, output, additional);
    }

    pub fn putDeliveryRecords(self: *Chunks, writes: []const records.Write) !void {
        try self.cache.backend.store.putDeliveryRecords(writes);
    }

    pub fn savedLightColumns(self: *Chunks, cursor: *records.ScanCursor, output: []Light.Column) !records.ScanResult {
        return self.cache.backend.store.savedLightColumns(cursor, output);
    }

    pub fn lightPrefixes(self: *Chunks, input: []const Light.PrefixRequest, snapshots: []Light.PrefixSnapshot) !void {
        assert(input.len == snapshots.len and input.len <= Light.prefix_batch_max);
        self.mutex.lockUncancelable(self.io);
        for (input, snapshots) |entry, *snapshot| snapshot.clean = self.lightCleanLocked(entry.column, entry.minimum, entry.count);
        self.mutex.unlock(self.io);
        try self.cache.backend.store.lightPrefixes(input, snapshots);
    }

    pub fn lightClean(self: *Chunks, column: Light.Column, minimum: i32, count: usize) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.lightCleanLocked(column, minimum, count);
    }

    fn lightCleanLocked(self: *Chunks, column: Light.Column, minimum: i32, count: usize) bool {
        for (self.cache.dirty_entries.values()) |index| {
            const key = self.cache.keys[index * self.cache.key_bytes ..][0..16];
            if (column.contains(key, minimum, count)) return false;
        }
        if (self.generating_count != 0) for (self.generating, 0..) |fill, index| {
            if (fill == null) continue;
            const key = self.cache.keys[index * self.cache.key_bytes ..][0..16];
            if (column.contains(key, minimum, count)) return false;
        };
        return true;
    }

    pub fn putLight(self: *Chunks, column: Light.Column, revisions: [9]u64, frame: []const u8) !bool {
        return self.cache.backend.store.putLight(column, revisions, frame);
    }

    pub const patched_light_batch_max = ChunkStore.patched_batch_max;

    /// Stores, replaces or with a null value deletes the patched light of several columns
    /// in the disposable cache, as one write. The bytes mean something only to the
    /// process that wrote them. False when the cache took none of it.
    pub fn putPatchedLights(self: *Chunks, columns: []const Light.Column, values: []const ?[]const u8) bool {
        return self.cache.backend.store.putColumnRecords(.patched, columns, values);
    }

    /// Reads the patched light of several columns into one buffer. A value is null when
    /// the cache holds none or the buffer had no room left for it.
    pub fn patchedLights(self: *Chunks, columns: []const Light.Column, output: *records.PackedRead) void {
        self.cache.backend.store.columnRecords(.patched, columns, output);
    }

    /// Deletes patched light records, a batch at a time. True while more may remain.
    pub fn clearPatchedLights(self: *Chunks) bool {
        return self.cache.backend.store.clearPatchedLights();
    }

    /// Only the chunk owner may use the encoder. The workspace must not outlive these chunks.
    pub const chain_max = 64;
    pub const chain_stack_max = 1024;
    /// Chained edits one edit may set off, as vanilla bounds chained neighbour updates.
    pub const chain_limit = 1 << 16;
    const Chained = struct { world: World, position: Position, state: u16 };

    /// An edit an observer makes in answer to a notification, as a block does in a neighbour
    /// update. It applies once the notification ends, before the edit that caused it returns,
    /// and its own notification may chain further, as vanilla's chained neighbour updates do.
    pub fn chain(self: *Chunks, world: World, position: Position, state: u16) !void {
        assert(self.notifying);
        if (self.chained_count == self.chained.len) return error.ChainCapacity;
        self.chained[self.chained_count] = .{ .world = world, .position = position, .state = state };
        self.chained_count += 1;
    }

    pub fn setBlock(self: *Chunks, world: World, pos: Position, state: u16) !void {
        try self.setBlocks(sectionAt(world, pos), &.{.{ .index = localIndex(pos), .state = state }});
    }

    /// Apply a section-sized batch in caller order. Publish one change notification.
    pub fn setBlocks(self: *Chunks, section: Section, edits: []const BlockEdit) !void {
        assert(!self.notifying);
        if (edits.len == 0) return;
        try self.setSections(&.{.{ .section = section, .edits = edits }});
    }

    /// Apply section batches in caller order. Notify observers after releasing each acquired batch.
    /// Edits observers chain apply before this returns, each with what it chains in turn first.
    pub fn setSections(self: *Chunks, sections: []const SectionEdits) !void {
        assert(!self.notifying and self.chain_stack_count == 0);
        try self.applyBatches(sections);
        var applied: usize = 0;
        while (self.chain_stack_count != 0) : (applied += 1) {
            if (applied == chain_limit) return error.ChainLimit;
            self.chain_stack_count -= 1;
            const edit = self.chain_stack[self.chain_stack_count];
            try self.applyBatches(&.{.{ .section = sectionAt(edit.world, edit.position), .edits = &.{.{ .index = localIndex(edit.position), .state = edit.state }} }});
        }
    }

    fn applyBatches(self: *Chunks, sections: []const SectionEdits) !void {
        var changed: [192]bool = undefined;
        var start: usize = 0;
        while (start < sections.len) {
            // A batch ends where its edits would outgrow the previous states kept for observers.
            const limit = @min(changed.len, self.edit_sections, sections.len - start);
            var count: usize = 0;
            var edits: usize = 0;
            while (count < limit) : (count += 1) {
                const length = sections[start + count].edits.len;
                if (length > edit_previous_max) return error.WorkingSetTooLarge;
                if (edits + length > edit_previous_max) break;
                edits += length;
            }
            assert(count != 0);
            const batch = sections[start..][0..count];
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.edit_stamp += 1;
                try self.applySections(batch, changed[0..count], self.edit_previous[0..edits]);
                self.edit_mark = self.write_mark.load(.monotonic);
            }
            self.notifying = true;
            var offset: usize = 0;
            for (batch, changed[0..count]) |section, did_change| {
                const previous = self.edit_previous[offset..][0..section.edits.len];
                offset += section.edits.len;
                if (!did_change) continue;
                for (self.observers[0..self.observer_count]) |observer| observer.changed(section.section, section.edits, previous);
            }
            assert(offset == edits);
            self.notifying = false;
            try self.stackChained();
            start += count;
        }
    }

    /// Puts the edits the last notification chained on the stack, the first on top.
    fn stackChained(self: *Chunks) !void {
        defer self.chained_count = 0;
        if (self.chain_stack_count + self.chained_count > self.chain_stack.len) return error.ChainCapacity;
        var index = self.chained_count;
        while (index > 0) {
            index -= 1;
            self.chain_stack[self.chain_stack_count] = self.chained[index];
            self.chain_stack_count += 1;
        }
    }

    fn applySections(self: *Chunks, sections: []const SectionEdits, changed: []bool, previous: []u16) !void {
        assert(sections.len <= 192 and sections.len == changed.len);
        var positions: [192]Section = undefined;
        var leases: [192]Lease = undefined;
        for (sections, positions[0..sections.len]) |section, *position| {
            assert(section.edits.len <= edit_previous_max);
            position.* = section.section;
        }
        var indices: [192]usize = undefined;
        while (true) {
            try self.acquireLocked(edits_client, positions[0..sections.len], leases[0..sections.len], null);
            for (leases[0..sections.len], indices[0..sections.len]) |lease, *index| index.* = lease.record.index;
            std.mem.sort(usize, indices[0..sections.len], {}, std.sort.asc(usize));
            var first: usize = 0;
            var borrowed = false;
            while (first < sections.len) {
                var end = first + 1;
                while (end < sections.len and indices[end] == indices[first]) end += 1;
                borrowed = borrowed or self.cache.entries[indices[first]].pins != end - first;
                first = end;
            }
            if (!borrowed) break;
            self.releaseLocked(leases[0..sections.len]);
            self.waitAvailableLocked();
        }
        defer {
            self.releaseLocked(leases[0..sections.len]);
            self.available.broadcast(self.io);
        }
        var offset: usize = 0;
        for (sections, leases[0..sections.len], changed) |section, lease, *did_change| {
            const view = View.fromBytes(lease.cached().read());
            did_change.* = false;
            for (section.edits, previous[offset..][0..section.edits.len]) |edit, *state| {
                state.* = view.get(edit.index);
                did_change.* = did_change.* or state.* != edit.state;
            }
            offset += section.edits.len;
            if (!did_change.*) continue;
            // The first unsaved change of a section dates its dirtiness.
            if (!self.cache.entries[lease.record.index].dirty) self.dirty_since[lease.record.index] = self.edit_stamp;
            const stored = lease.cached().read();
            const bytes = lease.cached().edit();
            const length = if (stored) |encoded| encoded.len else uniform(0, bytes);
            lease.cached().commit(try encoding.edit(bytes, length, section.edits, &self.edit_scratch));
            var watch = self.watches;
            while (watch) |observer| {
                observer.changed(section.section);
                watch = observer.next;
            }
        }
    }

    pub const Retention = struct { leases: []Lease, limit: usize };

    fn releaseRetained(self: *Chunks, retention: *Retention, keep: usize) void {
        assert(keep <= retention.leases.len);
        if (keep == retention.leases.len) return;
        self.releaseLocked(retention.leases[keep..]);
        retention.leases = retention.leases[0..keep];
        self.available.broadcast(self.io);
    }

    fn acquireLocked(self: *Chunks, client_index: u8, sections: []const Section, output: []Lease, retention: ?*Retention) !void {
        assert(sections.len == output.len);
        const state = &self.clients[client_index];
        if (sections.len > state.budget) return error.WorkingSetTooLarge;
        // Optional leases count against the budget too, so they give way first.
        if (retention) |optional| if (state.held + sections.len > state.budget) self.releaseRetained(optional, 0);
        // The client's own sections being generated free room once they are ready.
        while (state.held + sections.len > state.budget and state.held - state.generating + sections.len <= state.budget) try self.waitGenerated();
        const retained = if (retention) |optional| optional.leases.len else 0;
        if (state.held + sections.len > state.budget) {
            std.log.warn("event=chunk_budget_overrun client={s} budget={d} held={d} requested={d} retained={d}", .{ state.name, state.budget, state.held, sections.len, retained });
            return error.CacheBudgetExceeded;
        }
        self.generation.promote(sections);
        try self.collectGenerated();
        var done: usize = 0;
        errdefer {
            self.releaseLocked(output[0..done]);
            self.available.broadcast(self.io);
        }
        var keys: [192][16]u8 = undefined;
        var slices: [192][]const u8 = undefined;
        var cached: [192]Cache.Lease = undefined;
        while (done < sections.len) {
            const count = @min(keys.len, sections.len - done);
            for (sections[done..][0..count], 0..) |section, index| {
                keys[index] = encodeKey(section);
                slices[index] = &keys[index];
            }
            while (true) {
                var victims: [192]Cache.Lease = undefined;
                const reservation = try self.cache.reserveMany(slices[0..count], cached[0..count], &victims, self.cache.entries.len);
                switch (reservation) {
                    .blocked => |shortfall| {
                        assert(shortfall > 0 and shortfall <= count);
                        // Every lease and every section generated for a preparation counts against
                        // a budget, and budgets fit the cache. Only the pins a write holds on
                        // sections nobody leases are left, and the write ends on its own.
                        assert(std.mem.indexOfScalar(bool, self.writing, true) != null);
                        self.waitAvailableLocked();
                        continue;
                    },
                    .ready => break,
                    .writeback => |held| try self.writebackLocked(held),
                }
            }
            errdefer for (cached[0..count]) |lease| lease.release();
            try self.loadLocked(cached[0..count]);
            if (self.generation.source != null) try self.generate(sections[done..][0..count], cached[0..count]);
            for (cached[0..count], output[done..][0..count]) |lease, *out| out.* = .{
                .owner = self,
                .client = client_index,
                .record = .{ .index = lease.index, .generation = lease.generation, .version = lease.revision(), .bytes = lease.read() },
            };
            self.borrowed_count += count;
            state.held += count;
            done += count;
        }
    }

    fn submitGenerated(self: *Chunks, sections: []const Section, leases: []const Cache.Lease, priority: GenerationPriority, owner: u8) void {
        var requests: [192]Generation.Request = undefined;
        var held: [192]Cache.Fill = undefined;
        var count: usize = 0;
        for (sections, leases) |section, lease| {
            if (self.generating[lease.index] != null or lease.read() != null) continue;
            held[count] = lease.reserve();
            self.generating[lease.index] = held[count];
            requests[count] = .{ .section = section, .destination = held[count].bytes[0..encoding.maximum_decoded_bytes], .token = lease.index };
            count += 1;
        }
        if (count == 0) return;
        const accepted = self.generation.submit(requests[0..count], priority);
        for (held[0..count], 0..) |fill, index| {
            if (index < accepted) {
                self.generating_count += 1;
                self.generating_owner[fill.lease.index] = owner;
                if (owner != unowned) {
                    self.clients[owner].held += 1;
                    self.clients[owner].generating += 1;
                }
            } else {
                self.generating[fill.lease.index] = null;
                fill.cancel();
            }
        }
    }

    fn waitAvailableLocked(self: *Chunks) void {
        self.available.waitUncancelable(self.io, &self.mutex);
    }

    fn loadLocked(self: *Chunks, leases: []const Cache.Lease) !void {
        while (true) {
            if (self.cache.failed) return error.FailedTransaction;
            var waiting = false;
            const missing = for (leases) |lease| {
                const entry = &self.cache.entries[lease.index];
                if (entry.loaded) continue;
                waiting = true;
                if (!entry.filling) break true;
            } else false;
            if (!missing) {
                if (!waiting) return;
                self.waitAvailableLocked();
                continue;
            }
            const workspace = for (self.read_workspaces) |*workspace| {
                if (!workspace.busy) break workspace;
            } else {
                self.waitAvailableLocked();
                continue;
            };
            assert(leases.len <= workspace.requests.len);
            workspace.busy = true;
            defer {
                workspace.busy = false;
                self.available.broadcast(self.io);
            }
            const requests = workspace.requests;
            const fills = workspace.fills;
            const lengths = workspace.lengths;
            var count: usize = 0;
            for (leases) |lease| {
                const entry = &self.cache.entries[lease.index];
                if (entry.loaded or entry.filling) continue;
                fills[count] = lease.reserve();
                requests[count] = .{ .key = lease.key(), .destination = fills[count].bytes };
                count += 1;
            }
            assert(count > 0);
            self.mutex.unlock(self.io);
            const result: anyerror!void = blk: {
                const reading = self.cache.metrics.storage.start();
                defer reading.end();
                self.cache.backend.store.getBatch(requests[0..count], lengths[0..count]) catch |err| {
                    self.cache.backend.fail();
                    break :blk err;
                };
                for (requests[0..count], lengths[0..count]) |request, length| if (length) |size| {
                    _ = encoding.Packed.init(request.destination[0..size]) catch |err| {
                        self.cache.backend.fail();
                        break :blk err;
                    };
                };
                break :blk {};
            };
            self.mutex.lockUncancelable(self.io);
            if (result) |_| {
                for (fills[0..count], lengths[0..count]) |fill, length| fill.load(length);
                self.cache.metrics.reads.add(count);
            } else |err| {
                for (fills[0..count]) |fill| fill.cancel();
                self.cache.failed = true;
                return err;
            }
        }
    }

    fn flushDirtyLocked(self: *Chunks) !void {
        while (self.writing_count != 0) self.waitAvailableLocked();
        if (self.cache.failed) return error.FailedTransaction;
        // Pin the dirty snapshot before releasing the cache lock for I/O.
        // Background fills published later belong to the next checkpoint.
        var count: usize = 0;
        for (self.cache.entries, 0..) |entry, index| {
            if (!entry.dirty) continue;
            assert(!entry.editing and !entry.filling and !self.writing[index]);
            self.checkpoint_leases[count] = self.cache.pin(index);
            count += 1;
        }
        var written: usize = 0;
        defer if (count != 0) self.ready().set(self.io);
        errdefer for (self.checkpoint_leases[written..count]) |lease| lease.release();
        while (written < count) {
            const batch = self.checkpoint_leases[written..@min(written + 192, count)];
            written += batch.len;
            try self.writebackLocked(batch);
        }
    }

    fn writebackLocked(self: *Chunks, held: []const Cache.Lease) !void {
        assert(held.len > 0 and held.len <= 192);
        // Raised under the cache lock, so an edit applied earlier reads a smaller mark.
        _ = self.write_mark.fetchAdd(1, .monotonic);
        var writes: [192]records.Write = undefined;
        for (held, writes[0..held.len]) |lease, *write| {
            assert(lease.cache == &self.cache and self.cache.entries[lease.index].dirty);
            assert(!self.writing[lease.index]);
            self.writing[lease.index] = true;
            self.writing_count += 1;
            write.* = .{ .key = lease.key(), .value = lease.read() };
        }
        self.mutex.unlock(self.io);
        const result: anyerror!void = blk: {
            self.writeback_mutex.lockUncancelable(self.io);
            defer self.writeback_mutex.unlock(self.io);
            self.cache.writeBack(writes[0..held.len]) catch |err| {
                self.cache.backend.fail();
                break :blk err;
            };
            break :blk {};
        };
        self.mutex.lockUncancelable(self.io);
        for (held) |lease| {
            assert(self.writing[lease.index] and self.writing_count > 0);
            self.writing[lease.index] = false;
            self.writing_count -= 1;
            if (result) |_| {
                lease.markWritten();
            } else |_| {}
            lease.release();
        }
        self.available.broadcast(self.io);
        result catch |err| {
            self.cache.failed = true;
            return err;
        };
    }

    fn generate(self: *Chunks, sections: []const Section, leases: []const Cache.Lease) !void {
        while (true) {
            try self.collectGenerated();
            self.submitGenerated(sections, leases, .{ .urgency = .required }, unowned);
            for (leases) |lease| {
                if (self.generating[lease.index] != null) break;
                if (lease.read() == null) break;
            } else return;
            try self.waitGenerated();
        }
    }

    pub const Preparation = struct {
        sections: []const Section,
        leases: []Lease,
        priority: GenerationPriority,
    };

    pub const StorageGroup = struct { minimum: Section, side: u8 };

    pub fn storageGroup(self: *const Chunks, section: Section) StorageGroup {
        const side = self.cache.backend.store.side;
        return .{ .side = side, .minimum = .{
            .world = section.world,
            .x = @divFloor(section.x, @as(i32, side)) * side,
            .y = @divFloor(section.y, @as(i32, side)) * side,
            .z = @divFloor(section.z, @as(i32, side)) * side,
        } };
    }

    pub const ClassificationRequest = struct { section: Section, result: *encoding.Classification, prepared: ?*classification.Prepared = null, projection: classification.Projection = .full };

    pub fn registerClassification(self: *Chunks, allocator: std.mem.Allocator, properties: []const u8, selected: u8, codec: ?classification.Codec) !*const classification.Index {
        return self.cache.backend.store.registerClassification(allocator, properties, selected, codec);
    }

    /// Opens a queue that finds what a layer says acts in columns. `identity` names what the
    /// layer is for, and its records keep it. Startup only.
    pub fn openTopology(self: *Chunks, allocator: std.mem.Allocator, counted: *const layer.Layer, identity: []const u8, capacity: usize, mask_capacity: usize) !*topology.Topology {
        assert(self.background_owner.load(.acquire) == 0);
        // One read of the sections around a section spans two storage groups per axis, or
        // three when a group is a single section.
        const side = self.cache.backend.store.side;
        try self.cache.backend.store.reservePipeline(allocator, if (side == 1) 27 else 8);
        const opened = try topology.Topology.init(allocator, self.io, counted, counted.fingerprint(identity), capacity, mask_capacity, self.ready());
        opened.next = self.topologies;
        self.topologies = opened;
        return opened;
    }

    fn answerTopologies(self: *Chunks) bool {
        var answered = false;
        var cursor = self.topologies;
        while (cursor) |queue| : (cursor = queue.next) {
            while (true) {
                const count = queue.claim(&queue.claimed);
                if (count == 0) break;
                const columns = queue.claimed[0..count];
                const answers = queue.found[0..count];
                // A failed read is answered too, so the asker may try again.
                self.countColumns(queue, columns, answers) catch |err| {
                    std.log.warn("event=topology_count_failed reason={t}", .{err});
                    for (answers, columns) |*result, column| result.* = .{ .column = column, .result = .unavailable };
                };
                queue.answer(answers, queue.found_masks[0..count]);
                answered = true;
            }
        }
        return answered;
    }

    /// Terrain thread. Answers columns from their layer records, or finds what acts from the
    /// sections around them, and saves that when nothing around them is edited in memory only.
    fn countColumns(self: *Chunks, queue: *topology.Topology, columns: []const topology.Column, answers: []topology.Answer) !void {
        assert(self.ownsCurrentThread() and columns.len == answers.len and columns.len <= topology.batch_max);
        comptime assert(topology.batch_max <= Light.dependency_batch_max and topology.batch_max <= ChunkStore.patched_batch_max);
        var requests: [topology.batch_max]Light.Request = undefined;
        var places: [topology.batch_max]Light.Column = undefined;
        for (columns, requests[0..columns.len], places[0..columns.len]) |column, *request, *place| {
            place.* = .{ .world = column.world, .x = column.x, .z = column.z };
            request.* = .{ .column = place.*, .minimum = column.minimum, .count = column.count };
        }
        var before: [topology.batch_max]Light.Dependencies = undefined;
        try self.lightDependencies(requests[0..columns.len], before[0..columns.len]);
        var values: [topology.batch_max]?[]const u8 = undefined;
        var complete: [topology.batch_max]bool = undefined;
        var read: records.PackedRead = .{ .bytes = queue.record_bytes, .values = values[0..columns.len], .complete = complete[0..columns.len] };
        self.cache.backend.store.columnRecords(.layer, places[0..columns.len], &read);
        var counted: [topology.batch_max]bool = @splat(false);
        for (columns, answers, before[0..columns.len], values[0..columns.len], queue.found_masks[0..columns.len], 0..) |column, *result, dependencies, value, *masks, index| {
            result.* = .{ .column = column, .result = .counted };
            if (dependencies.clean) if (value) |bytes| {
                if (topology.decodeRecord(bytes, queue.fingerprint, dependencies.revisions, column, &result.counts, masks)) |acting| {
                    result.masks = acting;
                    continue;
                }
            };
            if (!try self.countColumn(queue, column, result, masks)) {
                result.* = .{ .column = column, .result = .unavailable };
                continue;
            }
            counted[index] = dependencies.clean;
        }
        // A record vouches for the revisions read before its blocks, and only if nothing
        // around the column was edited or saved while it was counted.
        var after: [topology.batch_max]Light.Dependencies = undefined;
        try self.lightDependencies(requests[0..columns.len], after[0..columns.len]);
        var writes: [topology.batch_max]?[]const u8 = undefined;
        var written: [topology.batch_max]Light.Column = undefined;
        var count: usize = 0;
        for (columns, answers, before[0..columns.len], after[0..columns.len], counted[0..columns.len], places[0..columns.len], queue.found_masks[0..columns.len]) |column, result, earlier, later, fresh, place, *masks| {
            if (!fresh) continue;
            if (!later.clean or !std.mem.eql(u64, &earlier.revisions, &later.revisions)) continue;
            // The record buffer is free again, as every record read was decoded above.
            const encoded = queue.record_bytes[count * topology.record_max ..][0..topology.record_max];
            writes[count] = topology.encodeRecord(queue.fingerprint, earlier.revisions, column, result.counts[0..column.count], masks[0..result.masks], encoded);
            written[count] = place;
            count += 1;
        }
        if (count != 0) _ = self.cache.backend.store.putColumnRecords(.layer, written[0..count], writes[0..count]);
    }

    /// Terrain thread. Finds what acts in each section of a column, reading the sections around
    /// from memory where they are there and from the store elsewhere. Absent sections hold air.
    /// False when a section it needs is still being generated.
    fn countColumn(self: *Chunks, queue: *topology.Topology, column: topology.Column, result: *topology.Answer, masks: *[topology.sections_max]topology.Mask) !bool {
        for (0..column.count) |offset| {
            const y = column.minimum + @as(i32, @intCast(offset));
            var around: layer.Neighbourhood = @splat(null);
            if (!try self.readAround(queue, column, y, &.{layer.neighbour(0, 0, 0)}, &around)) return false;
            const wanted = try queue.layer.candidates(around[layer.neighbour(0, 0, 0)]);
            if (wanted.rules == 0) continue;
            if (wanted.neighbours) {
                var others: [26]usize = undefined;
                var count: usize = 0;
                for (0..27) |place| {
                    if (place == layer.neighbour(0, 0, 0)) continue;
                    others[count] = place;
                    count += 1;
                }
                if (!try self.readAround(queue, column, y, others[0..count], &around)) return false;
            }
            const acting = try queue.layer.evaluate(queue.workspace, &around, &masks[result.masks]);
            result.counts[offset] = acting;
            if (acting != 0) result.masks += 1;
        }
        return true;
    }

    /// Reads the sections at `places` around the section at `y` of `column` into the
    /// topology's buffers. False when one is still being generated.
    fn readAround(self: *Chunks, queue: *topology.Topology, column: topology.Column, y: i32, places: []const usize, around: *layer.Neighbourhood) !bool {
        var keys: [27][16]u8 = undefined;
        var reads: [27]records.Get = undefined;
        var slots: [27]usize = undefined;
        var lengths: [27]?usize = undefined;
        var stored: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.collectGenerated();
            for (places) |place| {
                const section_y = y + @as(i32, @intCast(place / 9)) - 1;
                if (section_y < column.minimum or section_y >= column.minimum + @as(i32, column.count)) continue;
                // Columns past the edge of the coordinate range hold air.
                const x = std.math.add(i32, column.x, @as(i32, @intCast(place % 3)) - 1) catch continue;
                const z = std.math.add(i32, column.z, @as(i32, @intCast(place / 3 % 3)) - 1) catch continue;
                const key = encodeKey(.{ .world = column.world, .x = x, .y = section_y, .z = z });
                if (self.cache.lookup.get(&key)) |slot| {
                    if (self.generating[slot] != null) return false;
                    if (self.cache.entries[slot].loaded) {
                        // Memory holds the section as it is now, edits included.
                        const lease = self.cache.pin(slot);
                        defer lease.release();
                        if (lease.read()) |bytes| {
                            @memcpy(queue.around_bytes[place][0..bytes.len], bytes);
                            around[place] = queue.around_bytes[place][0..bytes.len];
                        }
                        continue;
                    }
                }
                keys[stored] = key;
                reads[stored] = .{ .key = &keys[stored], .destination = &queue.around_bytes[place] };
                slots[stored] = place;
                stored += 1;
            }
        }
        if (stored == 0) return true;
        try self.cache.backend.store.decodeBatch(reads[0..stored], lengths[0..stored]);
        for (slots[0..stored], lengths[0..stored]) |place, length| {
            if (length) |n| around[place] = queue.around_bytes[place][0..n];
        }
        return true;
    }

    pub const GroupWindow = ChunkStore.GroupWindow;
    pub fn createGroupWindow(self: *Chunks, allocator: std.mem.Allocator, groups: usize) !*GroupWindow {
        return self.cache.backend.store.createGroupWindow(allocator, groups);
    }

    pub fn summarize(self: *Chunks, columns: []const classification.Column, output: []classification.ColumnSummary, properties: []const u8, selected: u8) !void {
        assert(self.ownsCurrentThread() and columns.len == output.len and columns.len <= classification.column_batch_max);
        var dirty: [classification.column_batch_max]u32 = @splat(0);
        var available: [classification.column_batch_max]u32 = @splat(0);
        var common: [classification.column_batch_max][32]u8 = undefined;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.collectGenerated();
            // Capture pending edits before storage. A flush may clear their dirty flags during the read.
            for (self.cache.dirty_entries.values()) |slot| {
                const key = self.cache.keys[slot * self.cache.key_bytes ..][0..16];
                const world = std.mem.readInt(u32, key[0..4], .big);
                const x = std.mem.readInt(i32, key[4..8], .big);
                const z = std.mem.readInt(i32, key[8..12], .big);
                const y = std.mem.readInt(i32, key[12..16], .big);
                for (columns, 0..) |column, index| {
                    const offset = @as(i64, y) - column.minimum;
                    if (column.world != world or column.x != x or column.z != z or offset < 0 or offset >= column.count) continue;
                    const bit = @as(u32, 1) << @intCast(offset);
                    dirty[index] |= bit;
                    if (!self.cache.entries[slot].loaded or self.generating[slot] != null) continue;
                    const lease = self.cache.pin(slot);
                    defer lease.release();
                    if (lease.read()) |bytes| {
                        const classified = try encoding.classify(bytes, properties, selected);
                        common[index][@intCast(offset)] = classified.common;
                        available[index] |= bit;
                    }
                }
            }
        }
        try self.cache.backend.store.summarize(columns, output, properties, selected);
        for (output, dirty[0..output.len], available[0..output.len], common[0..output.len]) |*summary, pending, known, *flags| {
            assert(known & ~pending == 0);
            summary.known = (summary.known & ~pending) | known;
            summary.prefixed &= ~pending;
            var changed = known;
            while (changed != 0) : (changed &= changed - 1) {
                const section = @ctz(changed);
                summary.common[section] = flags[section];
            }
        }
    }

    /// Reads never generate terrain or fill the section cache.
    pub fn classify(self: *Chunks, requests: []const ClassificationRequest, properties: []const u8, selected: u8) !void {
        assert(self.ownsCurrentThread() and requests.len <= 192);
        assert(std.math.isPowerOfTwo(selected));
        for (requests) |request| {
            assert(request.projection == .full or request.prepared == null);
            request.result.* = .unavailable;
            if (request.prepared) |prepared| prepared.length = 0;
        }
        var keys: [192][16]u8 = undefined;
        var reads: [192]ChunkStore.ClassificationRead = undefined;
        var count: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.collectGenerated();
            // Check live records before storage. An eviction can publish their pending edits.
            for (requests) |request| {
                const key = encodeKey(request.section);
                if (self.cache.lookup.get(&key)) |slot| {
                    if (!self.cache.entries[slot].loaded or self.generating[slot] != null) continue;
                    const lease = self.cache.pin(slot);
                    defer lease.release();
                    if (lease.read()) |bytes| {
                        const classified = try encoding.classify(bytes, properties, selected);
                        request.result.* = if (request.projection != .full) .{ .summary = .{ .common = classified.common, .property = classified.property } } else .{ .known = classified };
                    }
                    continue;
                }
                keys[count] = key;
                reads[count] = .{ .key = &keys[count], .result = request.result, .prepared = request.prepared, .projection = request.projection };
                count += 1;
            }
        }
        try self.cache.backend.store.classify(reads[0..count], properties, selected);
    }

    /// The stamp of the edit batch being announced. Valid during a change notification only.
    pub fn editStamp(self: *const Chunks) u64 {
        assert(self.notifying);
        return self.edit_stamp;
    }

    /// A section of a column's neighbourhood with changes no saved record has.
    pub const Unsaved = struct { section: Section, since: u64 };

    /// What of the nine columns around one has changes in memory only, as of now.
    pub const UnsavedSnapshot = struct {
        /// The stamp of the last edit batch applied.
        stamp: u64,
        /// The write mark. A different one later means some section was written since.
        write_mark: u64,
        count: usize,
    };

    /// Lists the dirty sections of the nine columns around `column`, each with the stamp
    /// of the edit batch that made it dirty. A section being written is left out, as its
    /// changes may be saved by now. Null when more are dirty than `output` holds. Does
    /// no IO and never waits for anything but the cache lock.
    pub fn unsavedAround(self: *Chunks, column: Light.Column, minimum: i32, count: usize, output: []Unsaved) ?UnsavedSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var found: usize = 0;
        for (self.cache.dirty_entries.values()) |slot| {
            const key = self.cache.keys[slot * self.cache.key_bytes ..][0..16];
            if (!column.contains(key, minimum, count) or self.writing[slot]) continue;
            if (found == output.len) return null;
            output[found] = .{ .section = decodeKey(key), .since = self.dirty_since[slot] };
            found += 1;
        }
        return .{ .stamp = self.edit_stamp, .write_mark = self.write_mark.load(.monotonic), .count = found };
    }

    fn acquireCached(self: *Chunks, client_index: u8, sections: []const Section, output: []Lease) bool {
        assert(sections.len == output.len);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = &self.clients[client_index];
        assert(state.held + sections.len <= state.budget);
        var slots: [192]usize = undefined;
        assert(sections.len <= slots.len);
        for (sections, slots[0..sections.len]) |section, *slot| {
            const key = encodeKey(section);
            slot.* = self.cache.lookup.get(&key) orelse return false;
            const entry = &self.cache.entries[slot.*];
            if (!entry.loaded or entry.filling or self.generating[slot.*] != null) return false;
        }
        for (slots[0..sections.len], output) |slot, *out| {
            const lease = self.cache.pin(slot);
            // In use like any other lease, so it is the last to be evicted.
            self.cache.entries[slot].referenced = true;
            out.* = .{ .owner = self, .client = client_index, .record = .{ .index = lease.index, .generation = lease.generation, .version = lease.revision(), .bytes = lease.read() } };
        }
        self.borrowed_count += sections.len;
        state.held += sections.len;
        return true;
    }

    /// Counts batches of dirty sections whose write to storage began. While it equals
    /// `editMark`, the edits being notified are in no saved record.
    pub fn writeMark(self: *const Chunks) u64 {
        return self.write_mark.load(.monotonic);
    }

    /// The write mark when the edits being notified were applied. Valid during a change
    /// notification only.
    pub fn editMark(self: *const Chunks) u64 {
        assert(self.notifying);
        return self.edit_mark;
    }

    /// Counts checkpoints that wrote every section dirty when they began. Simulation
    /// thread. An edit made under a smaller mark is saved.
    pub fn flushMark(self: *const Chunks) u64 {
        return self.flush_mark;
    }

    fn prepareMany(self: *Chunks, client_index: u8, requests: []const Preparation, completed: []bool) !void {
        assert(self.ownsCurrentThread() and requests.len == completed.len);
        @memset(completed, false);
        var sections: [192]Section = undefined;
        var count: usize = 0;
        for (requests) |request| {
            assert(request.priority.urgency != .required);
            assert(request.sections.len == request.leases.len);
            if (request.sections.len > sections.len - count) return error.WorkingSetTooLarge;
            @memcpy(sections[count..][0..request.sections.len], request.sections);
            count += request.sections.len;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.collectGenerated();
        var keys: [192][16]u8 = undefined;
        var slices: [192][]const u8 = undefined;
        var leases: [192]Cache.Lease = undefined;
        // A section this client is having generated counts against its budget already, so
        // preparing it again while it generates takes nothing more.
        var fresh: usize = 0;
        for (sections[0..count], 0..) |section, index| {
            keys[index] = encodeKey(section);
            slices[index] = &keys[index];
            const slot = self.cache.lookup.get(&keys[index]);
            fresh += @intFromBool(slot == null or self.generating[slot.?] == null or self.generating_owner[slot.?] != client_index);
        }
        const state = &self.clients[client_index];
        if (fresh > state.budget) return error.WorkingSetTooLarge;
        if (state.held + fresh > state.budget) {
            // Leases the client holds itself never free on their own.
            if (state.held - state.generating + fresh > state.budget) {
                std.log.warn("event=chunk_budget_overrun client={s} budget={d} held={d} generating={d} requested={d}", .{ state.name, state.budget, state.held, state.generating, fresh });
                return error.CacheBudgetExceeded;
            }
            // Room comes back as its own sections finish generating, and the ready event wakes
            // it then, so the batch is not ready yet.
            return;
        }
        // The batch pins its fresh sections until it returns, including while I/O releases the lock.
        state.held += fresh;
        defer state.held -= fresh;
        // A writeback cleans its victims, so the reservation is tried again at once. Returning
        // instead lets an edit dirty a victim before the next call, and a request as large as
        // the background capacity then never finds every victim clean.
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var victims: [192]Cache.Lease = undefined;
            switch (try self.cache.reserveMany(slices[0..count], leases[0..count], &victims, self.cache.entries.len)) {
                // Budgets fit the cache, so only writes, loads and generation in flight block.
                // The batch returns and tries again on the next wake.
                .blocked => return,
                .ready => break,
                .writeback => |held| {
                    try self.writebackLocked(held);
                    // Only edits made while the write released the lock dirty victims again.
                    if (attempt + 1 == background_writeback_attempts) {
                        self.ready().set(self.io);
                        return;
                    }
                },
            }
        }
        defer for (leases[0..count]) |lease| lease.release();
        try self.loadLocked(leases[0..count]);
        var begin: usize = 0;
        for (requests, completed) |request, *complete| {
            const held = leases[begin..][0..request.sections.len];
            complete.* = true;
            for (held) |lease| if (self.generating[lease.index] != null or lease.read() == null) {
                complete.* = false;
            };
            if (self.generation.source == null) complete.* = true;
            if (complete.*) {
                for (held, request.leases) |lease, *out| {
                    _ = lease.retain();
                    out.* = .{ .owner = self, .client = client_index, .record = .{ .index = lease.index, .generation = lease.generation, .version = lease.revision(), .bytes = lease.read() } };
                }
                self.borrowed_count += held.len;
                state.held += held.len;
            }
            begin += held.len;
        }
        assert(begin == count);
        if (self.generation.source != null) {
            var first: usize = 0;
            var start: usize = 0;
            while (first < requests.len) {
                const priority = requests[first].priority;
                var last = first;
                var end = start;
                while (last < requests.len and std.meta.eql(requests[last].priority, priority)) : (last += 1) end += requests[last].sections.len;
                self.submitGenerated(sections[start..end], leases[start..end], priority, client_index);
                first = last;
                start = end;
            }
        }
    }

    fn waitGenerated(self: *Chunks) !void {
        const version = self.generation.version();
        if (self.generation.ready_count.load(.acquire) == 0) {
            self.mutex.unlock(self.io);
            const result = self.generation.wait(self.generation.io, version);
            self.mutex.lockUncancelable(self.io);
            try result;
        }
        try self.collectGenerated();
    }

    fn collectGenerated(self: *Chunks) !void {
        var changed = false;
        var completions: [32]Generation.Completion = undefined;
        while (true) {
            const count = self.generation.nextMany(&completions);
            assert(count <= completions.len);
            if (count == 0) break;
            defer self.generation.releaseMany(completions[0..count]);
            var failure: ?anyerror = null;
            for (completions[0..count]) |completion| {
                const fill = self.generating[completion.token].?;
                self.generating[completion.token] = null;
                self.generating_count -= 1;
                const owner = self.generating_owner[completion.token];
                self.generating_owner[completion.token] = unowned;
                if (owner != unowned) {
                    assert(self.clients[owner].held > 0 and self.clients[owner].generating > 0);
                    self.clients[owner].held -= 1;
                    self.clients[owner].generating -= 1;
                    // The owner may be waiting for its budget to free.
                    self.available.broadcast(self.io);
                }
                const bytes = completion.result catch |err| {
                    fill.cancel();
                    if (err != error.Obsolete and failure == null) failure = err;
                    continue;
                };
                assert(bytes.ptr == fill.bytes.ptr);
                const encoded = encoding.encode(bytes, &self.edit_scratch) catch |err| {
                    fill.cancel();
                    if (failure == null) failure = err;
                    continue;
                };
                if (encoded.ptr != fill.bytes.ptr) @memcpy(fill.bytes[0..encoded.len], encoded);
                fill.publish(encoded.len);
                const key = self.cache.keys[completion.token * self.cache.key_bytes ..][0..16];
                const section: Section = .{ .world = std.mem.readInt(u32, key[0..4], .big), .x = std.mem.readInt(i32, key[4..8], .big), .z = std.mem.readInt(i32, key[8..12], .big), .y = std.mem.readInt(i32, key[12..16], .big) };
                var watch = self.watches;
                while (watch) |current| : (watch = current.next) current.changed(section);
                changed = true;
            }
            if (failure) |err| return err;
        }
        if (changed) self.notifyReady();
    }

    pub fn releaseMany(self: *Chunks, leases: []const Lease) void {
        if (leases.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.releaseLocked(leases);
        // Releases wake only blocking acquirers. Budgets fit the cache, so terrain thread
        // batches wait on writes, loads and generation, which wake it when they finish.
        self.available.broadcast(self.io);
    }

    fn releaseLocked(self: *Chunks, leases: []const Lease) void {
        for (leases) |lease| {
            assert(lease.owner == self);
            const state = &self.clients[lease.client];
            assert(state.held > 0);
            state.held -= 1;
            lease.cached().release();
        }
        assert(self.borrowed_count >= leases.len);
        self.borrowed_count -= leases.len;
    }

    pub const Iterator = struct {
        client: Client,
        sections: []const Section,
        leases: []Lease,
        live: usize = 0,
        next_section: usize = 0,

        /// The previous batch expires here. Defer deinit when exiting early.
        pub fn next(self: *Iterator) !?[]Lease {
            self.deinit();
            if (self.next_section == self.sections.len)
                return null;

            const count = @min(self.leases.len, self.client.budget(), self.sections.len - self.next_section);
            assert(count > 0);
            try self.client.acquireMany(self.sections[self.next_section..][0..count], self.leases[0..count]);
            self.live = count;
            self.next_section += count;
            assert(self.next_section <= self.sections.len);
            return self.leases[0..count];
        }

        pub fn deinit(self: *Iterator) void {
            self.client.chunks.releaseMany(self.leases[0..self.live]);

            self.live = 0;
        }
    };

    pub fn checkpoint(self: *Chunks, _: storage.Space) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assert(!self.checkpointing);
        self.checkpointing = true;
        defer self.checkpointing = false;
        try self.flushDirtyLocked();
        self.mutex.unlock(self.io);
        const result = blk: {
            self.writeback_mutex.lockUncancelable(self.io);
            defer self.writeback_mutex.unlock(self.io);
            break :blk self.cache.backend.flush();
        };
        self.mutex.lockUncancelable(self.io);
        try result;
        self.flush_mark += 1;
        self.ready().set(self.io);
    }

    pub fn attach(self: *Chunks) void {
        assert(self.background_owner.swap(std.Thread.getCurrentId(), .acq_rel) == 0);
    }

    pub fn stop(self: *Chunks) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assert(self.borrowed_count == 0);
        assert(self.background_owner.swap(0, .acq_rel) == std.Thread.getCurrentId());
    }

    pub fn ready(self: *Chunks) *std.Io.Event {
        return self.wakeup orelse &self.work_ready;
    }

    pub fn poll(self: *Chunks) !void {
        assert(self.ownsCurrentThread());
        self.mutex.lockUncancelable(self.io);
        const collected = self.collectGenerated();
        self.mutex.unlock(self.io);
        try collected;
        var progressed = try self.cache.backend.store.prepareMerge();
        progressed = self.answerTopologies() or progressed;
        if (self.writeback_mutex.tryLock()) {
            defer self.writeback_mutex.unlock(self.io);
            progressed = try self.cache.backend.store.publishPrepared() != 0 or progressed;
        }
        if (progressed) self.ready().set(self.io);
    }
};

/// Release a read lease before editing its section. Pin bookkeeping is synchronized separately.
pub const Lease = struct {
    owner: *Chunks,
    /// The client whose budget this lease counts against.
    client: u8,
    record: Record,

    pub const Record = struct {
        index: usize,
        generation: u64,
        version: u64,
        bytes: ?[]const u8,

        pub fn read(self: Record) ?[]const u8 {
            return self.bytes;
        }

        pub fn revision(self: Record) u64 {
            return self.version;
        }
    };

    fn cached(self: Lease) Cache.Lease {
        return .{ .cache = &self.owner.cache, .index = self.record.index, .generation = self.record.generation };
    }

    pub fn view(self: Lease) View {
        return View.fromBytes(self.record.read());
    }

    pub fn biomes(self: Lease) ?BiomeView {
        const bytes = self.record.read() orelse return null;
        return if (bytes[0] == 3) .{ .bytes = bytes[1..129] } else null;
    }

    pub fn get(self: Lease, index: u12) u16 {
        return self.view().get(index);
    }

    pub fn release(self: Lease) void {
        self.owner.releaseMany(&.{self});
    }
};

/// Borrows the section until its lease is released.
pub const BiomeView = struct {
    bytes: *const [128]u8,

    pub fn row(self: BiomeView, index: u2) [16]u16 {
        const values: @Vector(16, u16) = std.mem.bytesAsValue([16]u16, self.bytes[@as(usize, index) * 32 ..][0..32]).*;
        return if (builtin.cpu.arch.endian() == .little) values else @byteSwap(values);
    }

    pub fn get(self: BiomeView, index: u6) u16 {
        return std.mem.readInt(u16, self.bytes[@as(usize, index) * 2 ..][0..2], .little);
    }

    pub fn uniform(self: BiomeView) ?u16 {
        const cells: @Vector(64, u16) = std.mem.bytesAsValue([64]u16, self.bytes).*;
        return if (@reduce(.And, cells == @as(@Vector(64, u16), @splat(cells[0])))) self.get(0) else null;
    }
};

/// Borrows the section until its lease is released.
pub const View = union(enum) {
    uniform: u16,
    dense: *const [8192]u8,
    palette: encoding.Packed,

    fn fromBytes(value: ?[]const u8) View {
        const stored = value orelse return .{ .uniform = 0 };
        const bytes = stored[encoding.blockOffset(stored)..];
        assert(encoding.valid(stored));
        return switch (bytes[0]) {
            0 => .{ .uniform = std.mem.readInt(u16, bytes[1..3], .little) },
            1 => .{ .dense = bytes[1..8193] },
            2 => .{ .palette = .{ .bytes = bytes } },
            else => unreachable,
        };
    }

    pub fn get(self: View, index: u12) u16 {
        return switch (self) {
            .uniform => |state| state,
            .dense => |bytes| std.mem.readInt(u16, bytes[@as(usize, index) * 2 ..][0..2], .little),
            .palette => |palette| palette.get(index),
        };
    }

    /// Two consecutive rows, decoded together into place.
    pub fn pair(self: View, group: u7, first: *[16]u16, second: *[16]u16) void {
        switch (self) {
            .uniform => |state| {
                first.* = @splat(state);
                second.* = first.*;
            },
            .dense => |bytes| inline for (.{ first, second }, 0..) |row_, half| {
                const values: @Vector(16, u16) = std.mem.bytesAsValue([16]u16, bytes[@as(usize, group) * 64 + half * 32 ..][0..32]).*;
                row_.* = if (builtin.cpu.arch.endian() == .little) values else @byteSwap(values);
            },
            .palette => |palette| palette.pair(group, first, second),
        }
    }

    pub fn row(self: View, index: u8) [16]u16 {
        return switch (self) {
            .uniform => |state| @splat(state),
            .dense => |bytes| blk: {
                const values: @Vector(16, u16) = std.mem.bytesAsValue([16]u16, bytes[@as(usize, index) * 32 ..][0..32]).*;
                break :blk if (builtin.cpu.arch.endian() == .little) values else @byteSwap(values);
            },
            .palette => |palette| palette.row(index),
        };
    }
};

pub fn sectionAt(world: World, pos: Position) Section {
    return .{
        .world = world,
        .x = @divFloor(pos.x, 16),
        .y = @divFloor(pos.y, 16),
        .z = @divFloor(pos.z, 16),
    };
}

pub fn localIndex(pos: Position) u12 {
    return @intCast(@mod(pos.y, 16) * 256 + @mod(pos.z, 16) * 16 + @mod(pos.x, 16));
}

pub fn decodeKey(key: *const [16]u8) Section {
    return .{ .world = std.mem.readInt(u32, key[0..4], .big), .x = std.mem.readInt(i32, key[4..8], .big), .z = std.mem.readInt(i32, key[8..12], .big), .y = std.mem.readInt(i32, key[12..16], .big) };
}

pub fn encodeKey(section: Section) [16]u8 {
    var key: [16]u8 = undefined;
    std.mem.writeInt(u32, key[0..4], section.world, .big);
    std.mem.writeInt(i32, key[4..8], section.x, .big);
    std.mem.writeInt(i32, key[8..12], section.z, .big);
    std.mem.writeInt(i32, key[12..16], section.y, .big);
    return key;
}

pub fn uniform(state: u16, destination: []u8) usize {
    assert(destination.len >= 3);
    destination[0] = 0;
    std.mem.writeInt(u16, destination[1..3], state, .little);
    return 3;
}
