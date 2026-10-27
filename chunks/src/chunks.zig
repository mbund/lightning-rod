const ChunkStore = @import("store.zig").Store;
const metrics = @import("metrics");
const std = @import("std");
const records = @import("records");
const storage = @import("storage");
pub const encoding = @import("encoding.zig");
pub const Generation = @import("generation.zig").Generation;
pub const GenerationPriority = @import("generation.zig").Priority;
pub const ReadWindow = @import("read_window.zig").ReadWindow;

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

pub const BlockEdit = struct {
    index: u12,
    state: u16,
};

pub const SectionEdits = struct {
    section: Section,
    edits: []const BlockEdit,
};

pub const Observer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        changed: *const fn (*anyopaque, Section, []const BlockEdit) void,
    };

    pub fn init(owner: anytype, comptime handler: anytype) Observer {
        const Adapter = struct {
            const vtable: VTable = .{ .changed = @This().invoke };

            fn invoke(raw: *anyopaque, section: Section, edits: []const BlockEdit) void {
                const typed: @TypeOf(owner) = @ptrCast(@alignCast(raw));
                return handler(typed, section, edits);
            }
        };
        return .{ .context = owner, .vtable = &Adapter.vtable };
    }

    /// Edits are borrowed. Record invalidation without changing the world.
    pub fn changed(self: Observer, section: Section, edits: []const BlockEdit) void {
        return self.vtable.changed(self.context, section, edits);
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

pub const Chunks = struct {
    pub const id = "lightning_rod:chunks";

    pub const Configuration = struct {
        wakeup: ?*std.Io.Event = null,
        cache_sections: usize = 192,
        /// Background fills leave this capacity available for synchronous demand.
        demand_sections: usize = 24,
        cache_tiles: usize = 32,
        observers: usize = 8,
    };

    pub const Dependencies = struct {
        record_workspaces: *records.Workspaces,
        metrics: *metrics.Registry,
        storage: storage.Space,
    };

    generating: []?Cache.Fill,
    generating_count: usize = 0,
    borrowed_count: usize = 0,
    cache: Cache,
    demand_sections: usize,
    mutex: std.Io.Mutex = .init,
    writeback_mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    writing: []bool,
    writing_count: usize = 0,
    checkpoint_leases: []Cache.Lease,
    checkpointing: bool = false,
    background_owner: std.atomic.Value(std.Thread.Id) = .init(0),
    work_ready: std.Io.Event = .unset,
    io: std.Io,
    wakeup: ?*std.Io.Event = null,

    generation: *Generation,
    observers: []Observer,
    ready_observers: []*std.Io.Event,
    ready_count: usize = 0,
    observer_count: usize = 0,
    notifying: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Chunks {
        const self = try allocate(allocator, io, configuration, deps);
        try self.cache.backend.store.open();
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Chunks {
        if (configuration.demand_sections > configuration.cache_sections) return error.InvalidConfiguration;
        const self = try allocator.create(Chunks);
        self.* = .{
            .io = io,
            .wakeup = configuration.wakeup,
            .demand_sections = configuration.demand_sections,
            .cache = try Cache.init(allocator, io, .{ .store = try ChunkStore.allocate(allocator, io, deps.storage, configuration.cache_tiles, deps.metrics, deps.record_workspaces.resources) }, .{
                .metrics = deps.metrics,
                .metrics_namespace = "chunks.cache",
                .slots = configuration.cache_sections,
                .key_bytes = 16,
                .value_bytes = std.mem.alignForward(usize, encoding.decoded_bytes, 64),
                .codec = .{ .encode = encoding.encode },
            }),
            .observers = try allocator.alloc(Observer, configuration.observers),
            .ready_observers = try allocator.alloc(*std.Io.Event, configuration.observers),
            .generation = undefined,
            .generating = try allocator.alloc(?Cache.Fill, configuration.cache_sections),
            .writing = try allocator.alloc(bool, configuration.cache_sections),
            .checkpoint_leases = try allocator.alloc(Cache.Lease, configuration.cache_sections),
        };
        @memset(self.generating, null);
        @memset(self.writing, false);
        self.generation = try Generation.init(allocator, io, configuration.cache_sections, self.ready(), deps.metrics);
        return self;
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
    pub fn getBlock(self: *Chunks, world: World, pos: Position) !u16 {
        const lease = try self.acquire(sectionAt(world, pos));
        defer lease.release();
        return lease.get(localIndex(pos));
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
    pub fn setSections(self: *Chunks, sections: []const SectionEdits) !void {
        assert(!self.notifying);
        var changed: [192]bool = undefined;
        var start: usize = 0;
        while (start < sections.len) {
            const count = @min(changed.len, self.cache.entries.len, sections.len - start);
            const batch = sections[start..][0..count];
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                try self.applySections(batch, changed[0..count]);
            }
            self.notifying = true;
            for (batch, changed[0..count]) |section, did_change| {
                if (!did_change) continue;
                for (self.observers[0..self.observer_count]) |observer| observer.changed(section.section, section.edits);
            }
            self.notifying = false;
            start += count;
        }
    }

    fn applySections(self: *Chunks, sections: []const SectionEdits, changed: []bool) !void {
        assert(sections.len <= 192 and sections.len == changed.len);
        var positions: [192]Section = undefined;
        var leases: [192]Lease = undefined;
        for (sections, positions[0..sections.len]) |section, *position| {
            if (section.edits.len > 4096) return error.WorkingSetTooLarge;
            position.* = section.section;
        }
        var indices: [192]usize = undefined;
        while (true) {
            try self.acquireLocked(positions[0..sections.len], leases[0..sections.len], null);
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
        for (sections, leases[0..sections.len], changed) |section, lease, *did_change| {
            const view = View.fromBytes(lease.cached().read());
            did_change.* = false;
            for (section.edits) |edit| did_change.* = did_change.* or view.get(edit.index) != edit.state;
            if (!did_change.*) continue;
            const bytes = lease.cached().edit();
            if (view == .uniform) for (0..4096) |index|
                std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], view.uniform, .little);
            bytes[0] = 1;
            for (section.edits) |edit|
                std.mem.writeInt(u16, bytes[1 + @as(usize, edit.index) * 2 ..][0..2], edit.state, .little);
            lease.cached().commit(8193);
        }
    }

    pub fn acquire(self: *Chunks, section: Section) !Lease {
        var out: [1]Lease = undefined;
        try self.acquireMany(&.{section}, &out);
        return out[0];
    }

    pub fn acquireMany(self: *Chunks, sections: []const Section, output: []Lease) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.acquireLocked(sections, output, null);
    }

    pub const Retention = struct { leases: []Lease, limit: usize };

    /// Optional leases may be released to fit the window or before waiting for cache space.
    /// The caller owns the remaining slice on both success and failure.
    pub fn acquireManyRetaining(self: *Chunks, sections: []const Section, output: []Lease, retention: *Retention) !void {
        assert(sections.len == output.len and sections.len <= 192);
        assert(retention.limit <= self.cache.entries.len -| sections.len);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.releaseRetained(retention, @min(retention.limit, retention.leases.len));
        try self.acquireLocked(sections, output, retention);
    }

    fn releaseRetained(self: *Chunks, retention: *Retention, keep: usize) void {
        assert(keep <= retention.leases.len);
        if (keep == retention.leases.len) return;
        self.releaseLocked(retention.leases[keep..]);
        retention.leases = retention.leases[0..keep];
        self.available.broadcast(self.io);
        if (self.background_owner.load(.acquire) != std.Thread.getCurrentId()) self.ready().set(self.io);
    }

    fn acquireLocked(self: *Chunks, sections: []const Section, output: []Lease, retention: ?*Retention) !void {
        assert(sections.len == output.len);
        if (sections.len > self.cache.entries.len) return error.WorkingSetTooLarge;
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
                        if (retention) |optional| if (optional.leases.len != 0) {
                            self.releaseRetained(optional, 0);
                            continue;
                        };
                        const writing = std.mem.indexOfScalar(bool, self.writing, true) != null;
                        const loading = for (self.cache.entries) |entry| {
                            if (entry.filling and !entry.loaded) break true;
                        } else false;
                        if (writing or loading) {
                            self.waitAvailableLocked();
                            continue;
                        }
                        if (self.generating_count == 0) return error.CachePinned;
                        _ = self.generation.cancelPrefetch(shortfall);
                        try self.waitGenerated();
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
                .record = .{ .index = lease.index, .generation = lease.generation, .version = lease.revision(), .bytes = lease.read() },
            };
            self.borrowed_count += count;
            done += count;
        }
    }

    fn submitGenerated(self: *Chunks, sections: []const Section, leases: []const Cache.Lease, priority: GenerationPriority) void {
        var requests: [192]Generation.Request = undefined;
        var held: [192]Cache.Fill = undefined;
        var count: usize = 0;
        for (sections, leases) |section, lease| {
            if (self.generating[lease.index] != null or lease.read() != null) continue;
            held[count] = lease.reserve();
            self.generating[lease.index] = held[count];
            requests[count] = .{ .section = section, .destination = held[count].bytes[0..encoding.decoded_bytes], .token = lease.index };
            count += 1;
        }
        const accepted = self.generation.submit(requests[0..count], priority);
        for (held[0..count], 0..) |fill, index| {
            if (index < accepted) {
                self.generating_count += 1;
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
            var requests: [192]records.Get = undefined;
            var fills: [192]Cache.Fill = undefined;
            var lengths: [192]?usize = undefined;
            var count: usize = 0;
            var waiting = false;
            for (leases) |lease| {
                const entry = &self.cache.entries[lease.index];
                if (entry.loaded) continue;
                if (entry.filling) {
                    waiting = true;
                    continue;
                }
                fills[count] = lease.reserve();
                requests[count] = .{ .key = lease.key(), .destination = fills[count].bytes };
                count += 1;
            }
            if (count == 0) {
                if (!waiting) return;
                self.waitAvailableLocked();
                continue;
            }
            self.mutex.unlock(self.io);
            const result: anyerror!void = blk: {
                const reading = self.cache.metrics.storage.start();
                defer reading.end();
                self.cache.backend.store.decodeBatch(requests[0..count], lengths[0..count]) catch |err| {
                    self.cache.backend.fail();
                    break :blk err;
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
                self.available.broadcast(self.io);
                return err;
            }
            self.available.broadcast(self.io);
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
            self.submitGenerated(sections, leases, .{ .urgency = .required });
            for (leases) |lease| {
                if (self.generating[lease.index] != null) break;
                if (lease.read() == null) break;
            } else return;
            try self.waitGenerated();
        }
    }

    pub const Preparation = struct { sections: []const Section, leases: []Lease, priority: GenerationPriority };

    pub fn backgroundCapacity(self: *const Chunks) usize {
        return self.cache.entries.len - self.demand_sections;
    }

    /// Complete results transfer their leases to the caller. Incomplete outputs remain untouched.
    pub fn prepareMany(self: *Chunks, requests: []const Preparation, completed: []bool) !void {
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
        if (count > self.backgroundCapacity()) return error.WorkingSetTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.collectGenerated();
        var keys: [192][16]u8 = undefined;
        var slices: [192][]const u8 = undefined;
        var leases: [192]Cache.Lease = undefined;
        for (sections[0..count], 0..) |section, index| {
            keys[index] = encodeKey(section);
            slices[index] = &keys[index];
        }
        var victims: [192]Cache.Lease = undefined;
        const reservation = try self.cache.reserveMany(slices[0..count], leases[0..count], &victims, self.backgroundCapacity());
        switch (reservation) {
            .blocked => return,
            .ready => {},
            .writeback => |held| {
                try self.writebackLocked(held);
                self.ready().set(self.io);
                return;
            },
        }
        assert(self.cache.pinned_entries <= self.backgroundCapacity());
        defer for (leases[0..count]) |lease| lease.release();
        try self.loadLocked(leases[0..count]);
        var begin: usize = 0;
        for (requests, completed) |request, *complete| {
            const held = leases[begin..][0..request.sections.len];
            complete.* = true;
            for (held) |lease| if (self.generating[lease.index] != null or lease.read() == null) {
                complete.* = false;
            };
            if (!complete.* and self.generation.source != null) self.submitGenerated(request.sections, held, request.priority);
            if (self.generation.source == null) complete.* = true;
            if (complete.*) {
                for (held, request.leases) |lease, *out| {
                    _ = lease.retain();
                    out.* = .{ .owner = self, .record = .{ .index = lease.index, .generation = lease.generation, .version = lease.revision(), .bytes = lease.read() } };
                }
                self.borrowed_count += held.len;
            }
            begin += held.len;
        }
        assert(begin == count);
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
                const bytes = completion.result catch |err| {
                    fill.cancel();
                    if (err != error.Obsolete and failure == null) failure = err;
                    continue;
                };
                assert(bytes.ptr == fill.bytes.ptr);
                fill.publish(bytes.len);
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
        self.available.broadcast(self.io);
        // The background owner schedules retries only when it makes progress.
        if (self.background_owner.load(.acquire) != std.Thread.getCurrentId()) self.ready().set(self.io);
    }

    fn releaseLocked(self: *Chunks, leases: []const Lease) void {
        for (leases) |lease| {
            assert(lease.owner == self);
            lease.cached().release();
        }
        assert(self.borrowed_count >= leases.len);
        self.borrowed_count -= leases.len;
    }

    pub const Iterator = struct {
        chunks: *Chunks,
        sections: []const Section,
        leases: []Lease,
        live: usize = 0,
        next_section: usize = 0,

        /// The previous batch expires here. Defer deinit when exiting early.
        pub fn next(self: *Iterator) !?[]Lease {
            self.deinit();
            if (self.next_section == self.sections.len)
                return null;

            const count = @min(self.leases.len, self.chunks.cache.entries.len, self.sections.len - self.next_section);
            assert(count > 0);
            try self.chunks.acquireMany(self.sections[self.next_section..][0..count], self.leases[0..count]);
            self.live = count;
            self.next_section += count;
            assert(self.next_section <= self.sections.len);
            return self.leases[0..count];
        }

        pub fn deinit(self: *Iterator) void {
            self.chunks.releaseMany(self.leases[0..self.live]);

            self.live = 0;
        }
    };

    pub fn iterate(self: *Chunks, sections: []const Section, leases: []Lease) Iterator {
        assert(leases.len > 0);
        return .{
            .chunks = self,
            .sections = sections,
            .leases = leases,
        };
    }

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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.collectGenerated();
    }
};

/// Release a read lease before editing its section. Pin bookkeeping is synchronized separately.
pub const Lease = struct {
    owner: *Chunks,
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

    pub fn get(self: Lease, index: u12) u16 {
        return self.view().get(index);
    }

    pub fn release(self: Lease) void {
        self.owner.releaseMany(&.{self});
    }
};

/// Borrows the section until its lease is released.
pub const View = union(enum) {
    uniform: u16,
    dense: *const [8192]u8,

    fn fromBytes(value: ?[]const u8) View {
        const bytes = value orelse return .{ .uniform = 0 };
        assert((bytes[0] == 0 and bytes.len == 3) or (bytes[0] == 1 and bytes.len == 8193));
        return if (bytes[0] == 0) .{ .uniform = std.mem.readInt(u16, bytes[1..3], .little) } else .{ .dense = bytes[1..8193] };
    }

    pub fn get(self: View, index: u12) u16 {
        return switch (self) {
            .uniform => |state| state,
            .dense => |bytes| std.mem.readInt(u16, bytes[@as(usize, index) * 2 ..][0..2], .little),
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
