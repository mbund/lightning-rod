const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const persistence = lightning_rod.persistence;
const root_format = @import("local_pack_root.zig");
const local_index = @import("local_index.zig");
const disk_tree = lightning_rod.persistence_index;
const runtime = lightning_rod.runtime;
const linux = std.os.linux;

pub const Limits = struct {
    maximum_in_flight_reads: usize,
    maximum_packs: usize,
    maximum_path_bytes: usize,
};

pub fn Driver(comptime limits: Limits) type {
    if (limits.maximum_in_flight_reads == 0) @compileError("local packs needs one read task");
    if (limits.maximum_packs < 2) @compileError("local packs needs two pack generations");
    if (limits.maximum_path_bytes < 32) @compileError("local packs path buffer is too small");
    const Root = root_format.Root(limits.maximum_packs);
    const Publication = root_format.Publication(limits.maximum_packs);
    return struct {
        const Self = @This();
        const JobState = enum { free, submitted };
        const WritePhase = enum {
            idle,
            pack_data_pending,
            pack_publish_ready,
            pack_publish_pending,
            pack_ready,
            root_data_pending,
            root_publish_ready,
            root_publish_pending,
            root_ready,
        };
        const WriteOwner = enum { none, flush, checkpoint_root, compaction_pack, compaction_root };
        const maintenance_read_completion = std.math.maxInt(u64) - 10;
        const maintenance_unlink_completion = std.math.maxInt(u64) - 9;
        const maintenance_parent_sync_completion = std.math.maxInt(u64) - 8;
        const pack_write_completion = std.math.maxInt(u64) - 7;
        const pack_sync_completion = std.math.maxInt(u64) - 6;
        const pack_rename_completion = std.math.maxInt(u64) - 5;
        const pack_parent_sync_completion = std.math.maxInt(u64) - 4;
        const root_write_completion = std.math.maxInt(u64) - 3;
        const root_sync_completion = std.math.maxInt(u64) - 2;
        const root_rename_completion = std.math.maxInt(u64) - 1;
        const root_parent_sync_completion = std.math.maxInt(u64);
        const read_file_cache = @min(limits.maximum_packs, 256);
        const scratch_index_max_pages = 8 * 1024 * 1024; // 32 GiB per immutable page file.
        const maintenance_pack_threshold = @min(limits.maximum_packs - 1, 256);
        const ring_entries = std.math.ceilPowerOfTwo(u32, limits.maximum_in_flight_reads + 8) catch
            @compileError("local packs ring capacity is too large");
        const ReadFile = struct {
            pack: u32 = 0,
            file: ?std.Io.File = null,
            age: u64 = 0,
        };
        pub const TestFault = enum {
            pack_create,
            pack_write,
            pack_sync,
            pack_rename,
            pack_parent_sync,
            root_create,
            root_write,
            root_sync,
            root_rename,
            root_parent_sync,
        };
        const Job = struct {
            state: JobState = .free,
            read: persistence.ReadTask = undefined,
        };

        pub const Reservation = struct {
            driver_bytes: usize,
            recovery_bytes: usize,

            pub fn residentBytes(self: Reservation) usize {
                return self.driver_bytes;
            }
            pub fn startupBytes(self: Reservation) usize {
                return self.residentBytes() + self.recovery_bytes;
            }
            pub fn maximumBytes(self: Reservation) usize {
                return self.startupBytes();
            }
        };

        pub const Compaction = struct {
            source: *persistence.Store,
            output: *persistence.Store,
            value: []u8,
            captured: Root,
            next: Root,
            cursor: persistence.LiveCursor = .{},
            copied: usize = 0,

            pub fn init(driver: *Self, source: *persistence.Store, output: *persistence.Store, value: []u8) !Compaction {
                if (!std.meta.eql(driver.store.configuration, source.configuration) or
                    !std.meta.eql(driver.store.configuration, output.configuration))
                    return error.CompactionConfigurationMismatch;
                if (value.len < driver.store.configuration.maximum_value_bytes) return error.ValueScratchTooSmall;
                const captured = driver.root;
                return .{ .source = source, .output = output, .value = value, .captured = captured, .next = captured.newEpoch() };
            }
        };

        pub const Maintenance = struct {
            source: *persistence.Store,
            output: *persistence.Store,
            value: []u8,
            recovery: []u8,
            compaction: ?Compaction = null,
            captured: Root = Root.init(),
            rebuild_index: usize = 0,
            reclaim_index: usize = 0,
            live: ?persistence.LiveRecord = null,
        };
        const MaintenanceState = enum {
            idle,
            requested,
            recover,
            recover_pending,
            copy,
            copy_pending,
            copy_flush,
            publish_flush,
            publish,
            install,
            reclaim,
            reclaim_pending,
        };

        io: std.Io,
        read_ring: linux.IoUring = undefined,
        read_ring_initialized: bool = false,
        read_files: [read_file_cache]ReadFile = @splat(.{}),
        read_file_age: u64 = 0,
        root_file: std.Io.File,
        index_files: [2]local_index.File = undefined,
        index_ready: [2]bool = .{ false, false },
        index_pending: [2][8 * disk_tree.page_size]u8 = undefined,
        index_cache: [2][16]local_index.CachePage = undefined,
        retired_index_metrics: local_index.Metrics = .{},
        active_index_slot: u1 = 0,
        lock_file: ?std.Io.File = null,
        parent_file: ?std.Io.File = null,
        root_path: []const u8,
        store: *persistence.Store,
        root: Root = Root.init(),
        committed_root: Root = Root.init(),
        retired_root: ?Root = null,
        path_first: [limits.maximum_path_bytes]u8 = undefined,
        path_second: [limits.maximum_path_bytes]u8 = undefined,
        path_root: [limits.maximum_path_bytes]u8 = undefined,
        jobs: [limits.maximum_in_flight_reads]Job = @splat(.{}),
        read_staging: [limits.maximum_in_flight_reads]persistence.ReadTask = undefined,
        write_queued: bool = false,
        write_owner: WriteOwner = .none,
        write_phase: WritePhase = .idle,
        write_file: ?std.Io.File = null,
        write_pack: u32 = 0,
        write_bytes: []const u8 = &.{},
        write_pending: u8 = 0,
        write_succeeded: bool = true,
        write_next_root: Root = Root.init(),
        write_committed_root: Root = Root.init(),
        write_commits_checkpoint: bool = false,
        write_root_bytes: [Publication.maximum_bytes]u8 = undefined,
        write_root_length: usize = 0,
        shutdown: bool = false,
        failed: bool = false,
        maintenance_requested: bool = false,
        checkpoint_admission_wait_logged: bool = false,
        maintenance: ?Maintenance = null,
        maintenance_state: MaintenanceState = .idle,
        maintenance_pending: u8 = 0,
        maintenance_succeeded: bool = true,
        test_fault: if (builtin.is_test) ?TestFault else void = if (builtin.is_test) null else {},
        metrics: ?*lightning_rod.metrics.Runtime = null,

        pub fn reservation(configuration: persistence.Configuration) !Reservation {
            try configuration.validate();
            return .{
                .driver_bytes = @sizeOf(Self),
                .recovery_bytes = try persistence.maximumCheckpointBytes(configuration),
            };
        }

        pub fn init(
            self: *Self,
            io: std.Io,
            root_path: []const u8,
            store: *persistence.Store,
            recovery: []u8,
        ) !void {
            if (root_path.len == 0 or root_path.len >= limits.maximum_path_bytes) return error.InvalidRootPath;
            try validateCompactionCapacity(store);
            self.* = .{ .io = io, .root_file = undefined, .root_path = root_path, .store = store };
            const parent = std.Io.Dir.path.dirname(root_path) orelse return error.InvalidRootPath;
            self.parent_file = try std.Io.Dir.openFileAbsolute(io, parent, .{ .mode = .read_only, .allow_directory = true });
            errdefer if (self.parent_file) |file| file.close(io);
            const lock_path = try std.fmt.bufPrint(&self.path_first, "{s}.lock", .{root_path});
            self.lock_file = try std.Io.Dir.createFileAbsolute(io, lock_path, .{ .read = true, .truncate = false });
            errdefer self.lock_file.?.close(io);
            if (!try self.lock_file.?.tryLock(io, .exclusive)) return error.StoreAlreadyOpen;
            errdefer self.deinitIndexSlots();
            if (store.disk != null) {
                try self.initializeIndexSlot(0);
                try self.initializeIndexSlot(1);
            }
            self.root_file = try std.Io.Dir.createFileAbsolute(io, root_path, .{ .read = true, .truncate = false });
            errdefer self.root_file.close(io);
            self.read_ring = try linux.IoUring.init(ring_entries, 0);
            self.read_ring_initialized = true;
            errdefer self.read_ring.deinit();
            try store.bindCheckpointGate(self, checkpointAdmission);
            errdefer {
                store.checkpoint_gate = null;
                store.checkpoint_gate_context = null;
            }
            try store.bindReadGate(self, readAdmission);
            errdefer {
                store.read_gate = null;
                store.read_gate_context = null;
            }
            if (try self.recover(recovery)) try self.pruneAbandonedPacks();
            if (@as(usize, self.root.count) + 1 >= maintenance_pack_threshold) self.requestMaintenance();
            try store.bindDrain(self, drain);
        }

        /// This is safe before init: the returned context is the stable slot address.
        pub fn diskIndexIo(self: *Self) disk_tree.Io {
            return self.index_files[0].interface();
        }

        /// The compaction output always writes an independent scratch file.
        pub fn compactionIndexIo(self: *Self) disk_tree.Io {
            return self.index_files[1].interface();
        }

        fn maintenancePtr(self: *Self) ?*Maintenance {
            return if (self.maintenance) |*maintenance| maintenance else null;
        }

        fn compactionPtr(maintenance: *Maintenance) ?*Compaction {
            return if (maintenance.compaction) |*compaction| compaction else null;
        }

        fn initializeIndexSlot(self: *Self, slot: usize) !void {
            std.debug.assert(slot < self.index_files.len);
            const path = try std.fmt.bufPrint(&self.path_first, "{s}.index.{d}", .{ self.root_path, slot });
            const file = try std.Io.Dir.createFileAbsolute(self.io, path, .{ .read = true, .truncate = true });
            errdefer file.close(self.io);
            self.index_files[slot] = try local_index.File.init(
                self.io,
                file,
                scratch_index_max_pages,
                &self.index_pending[slot],
                &self.index_cache[slot],
            );
            self.index_ready[slot] = true;
        }

        fn resetIndexSlot(self: *Self, slot: usize) !void {
            if (self.index_ready[slot]) {
                const previous = self.index_files[slot].metrics;
                self.retired_index_metrics.reads += previous.reads;
                self.retired_index_metrics.hits += previous.hits;
                self.retired_index_metrics.staged_hits += previous.staged_hits;
                self.retired_index_metrics.writes += previous.writes;
                self.retired_index_metrics.written_pages += previous.written_pages;
                self.index_files[slot].file.close(self.io);
            }
            self.index_ready[slot] = false;
            try self.initializeIndexSlot(slot);
        }

        fn deinitIndexSlots(self: *Self) void {
            for (&self.index_files, &self.index_ready) |*file, *ready| {
                if (ready.*) file.file.close(self.io);
                ready.* = false;
            }
        }

        fn drain(context: *anyopaque, io: std.Io) persistence.DrainError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            while (true) {
                if (self.maintenance_state != .idle and self.maintenance == null) {
                    self.failed = true;
                    self.store.markFailed();
                    return error.Unavailable;
                }
                if (backendComplete(self, io, limits.maximum_in_flight_reads + 16).outcome == .failed) return error.Unavailable;
                switch (self.store.flush()) {
                    .ready, .pending, .backpressured => {},
                    else => return error.Unavailable,
                }
                if (backendSubmit(self, io) == .failed) return error.Unavailable;
                if (self.store.checkpointProgress() == .ready and checkpointAdmission(self)) return;
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
        }

        pub fn loader(self: *Self) persistence.Loader {
            return .{ .context = self, .read_fn = load };
        }

        pub fn bindMetrics(self: *Self, value: *lightning_rod.metrics.Runtime) void {
            std.debug.assert(self.metrics == null);
            self.metrics = value;
            self.publishDiskIndexMetrics();
        }

        fn publishDiskIndexMetrics(self: *Self) void {
            const metrics = self.metrics orelse return;
            var reads: u64 = 0;
            var hits: u64 = 0;
            var pending_hits: u64 = 0;
            var writes: u64 = 0;
            var written_pages: u64 = 0;
            var cached_pages: usize = 0;
            var cache_capacity: usize = 0;
            reads += self.retired_index_metrics.reads;
            hits += self.retired_index_metrics.hits;
            pending_hits += self.retired_index_metrics.staged_hits;
            writes += self.retired_index_metrics.writes;
            written_pages += self.retired_index_metrics.written_pages;
            for (&self.index_files, self.index_ready) |*file, ready| {
                if (!ready) continue;
                reads += file.metrics.reads;
                hits += file.metrics.hits;
                pending_hits += file.metrics.staged_hits;
                writes += file.metrics.writes;
                written_pages += file.metrics.written_pages;
                cached_pages += file.cachedPages();
                cache_capacity += file.cache.len;
            }
            metrics.setDiskIndex(reads, hits, pending_hits, writes, written_pages, cached_pages, cache_capacity);
        }

        pub fn interface(self: *Self) runtime.Backend {
            return .{ .context = self, .vtable = &vtable };
        }

        pub fn deinit(self: *Self) void {
            self.store.drain_fn = null;
            self.store.drain_context = null;
            self.store.checkpoint_gate = null;
            self.store.checkpoint_gate_context = null;
            self.store.read_gate = null;
            self.store.read_gate_context = null;
            if (self.write_file) |file| file.close(self.io);
            for (&self.read_files) |*entry| {
                if (entry.file) |file| file.close(self.io);
                entry.* = .{};
            }
            if (self.read_ring_initialized) self.read_ring.deinit();
            self.deinitIndexSlots();
            if (self.parent_file) |file| file.close(self.io);
            self.root_file.close(self.io);
            if (self.lock_file) |file| file.close(self.io);
            self.* = undefined;
        }

        pub fn configureMaintenance(self: *Self, source: *persistence.Store, output: *persistence.Store, value: []u8, recovery: []u8) !void {
            try validateCompactionCapacity(self.store);
            _ = try Compaction.init(self, source, output, value);
            if (recovery.len < try persistence.maximumCheckpointBytes(self.store.configuration)) return error.RecoveryCapacity;
            if (self.maintenance != null or (self.maintenance_state != .idle and self.maintenance_state != .requested)) return error.MaintenanceBusy;
            if (self.store.disk != null) {
                try source.rebindEmptyDiskIndex(self.diskIndexIo());
                try output.rebindEmptyDiskIndex(self.compactionIndexIo());
            }
            self.maintenance = .{ .source = source, .output = output, .value = value, .recovery = recovery };
        }

        pub fn setTestFault(self: *Self, fault: ?TestFault) void {
            if (comptime builtin.is_test) {
                self.test_fault = fault;
            }
        }

        fn recover(self: *Self, recovery: []u8) !bool {
            if (recovery.len < try persistence.maximumCheckpointBytes(self.store.configuration)) return error.RecoveryCapacity;
            const stat = try self.root_file.stat(self.io);
            if (stat.size == 0) {
                self.store.beginRecovery();
                return false;
            }
            if (stat.size > Publication.maximum_bytes) return error.RootTooLarge;
            const root_length: usize = @intCast(stat.size);
            var root_bytes: [Publication.maximum_bytes]u8 = undefined;
            const count = try self.root_file.readPositionalAll(self.io, root_bytes[0..root_length], 0);
            if (count != root_length) return error.TruncatedRoot;
            const publication = try Publication.decode(root_bytes[0..count]);
            self.committed_root = publication.committed;
            self.root = publication.committed;
            self.root.next_id = @max(self.root.next_id, publication.working.next_id);
            self.store.beginRecovery();
            for (self.root.slice()) |entry| {
                const path = try self.packPath(&self.path_first, entry.id, false);
                const pack = try std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only });
                defer pack.close(self.io);
                if (entry.bytes > @as(u64, @intCast(recovery.len))) return error.PackTooLarge;
                const length: usize = @intCast(entry.bytes);
                const bytes = try pack.readPositionalAll(self.io, recovery[0..length], 0);
                if (bytes != length or checksum(recovery[0..bytes]) != entry.checksum) return error.InvalidPack;
                const consumed = try self.store.recoverOneInPack(recovery[0..bytes], @intCast(entry.id), 0);
                if (consumed != bytes) return error.InvalidPack;
            }
            return true;
        }

        fn pruneAbandonedPacks(self: *Self) !void {
            const parent = std.Io.Dir.path.dirname(self.root_path) orelse return error.InvalidRootPath;
            var directory = try std.Io.Dir.openDirAbsolute(self.io, parent, .{ .iterate = true });
            defer directory.close(self.io);
            const basename = std.Io.Dir.path.basename(self.root_path);
            const prefix = try std.fmt.bufPrint(&self.path_first, "{s}.pack.", .{basename});
            const root_temporary = try std.fmt.bufPrint(&self.path_second, "{s}.next", .{basename});
            var iterator = directory.iterate();
            var removed: usize = 0;
            while (try iterator.next(self.io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.eql(u8, entry.name, root_temporary)) {
                    if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
                    var suffix = entry.name[prefix.len..];
                    const temporary = std.mem.endsWith(u8, suffix, ".next");
                    if (temporary) suffix = suffix[0 .. suffix.len - ".next".len];
                    if (suffix.len == 0 or suffix[0] == '0') continue;
                    var decimal = true;
                    for (suffix) |byte| if (byte < '0' or byte > '9') {
                        decimal = false;
                        break;
                    };
                    if (!decimal) continue;
                    const id = std.fmt.parseInt(u32, suffix, 10) catch continue;
                    if (id == std.math.maxInt(u32)) continue;
                    if (!temporary and self.committed_root.contains(id)) continue;
                }
                try directory.deleteFile(self.io, entry.name);
                removed += 1;
            }
            if (removed != 0) {
                try self.parent_file.?.sync(self.io);
                std.log.info("event=persistence_recovery_pruned files={d}", .{removed});
            }
        }

        fn load(context: *anyopaque, namespace: []const u8, key: []const u8, destination: []u8) persistence.LoadError!persistence.LoadResult {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.failed or self.store.poisoned()) return error.ReadFailed;
            if (namespace.len > self.store.configuration.maximum_namespace_bytes or key.len > self.store.configuration.maximum_key_bytes)
                return error.InvalidKey;
            switch (self.store.currentValue(namespace, key)) {
                .failed => return error.ReadFailed,
                .missing => return .missing,
                .staged => |bytes| {
                    if (destination.len < bytes.len) return error.DestinationTooSmall;
                    @memcpy(destination[0..bytes.len], bytes);
                    return .{ .value = bytes.len };
                },
                .persisted => |location| {
                    if (destination.len < location.length) return error.DestinationTooSmall;
                    const count = self.readLocationUncached(location, destination[0..location.length]) catch {
                        self.failed = true;
                        self.store.markFailed();
                        return error.ReadFailed;
                    };
                    if (count != location.length) {
                        self.failed = true;
                        self.store.markFailed();
                        return error.Corrupt;
                    }
                    return .{ .value = count };
                },
            }
        }

        fn backendComplete(context: *anyopaque, _: std.Io, limit: usize) runtime.Completion {
            const self: *Self = @ptrCast(@alignCast(context));
            var completed: usize = 0;
            var cqes: [limits.maximum_in_flight_reads + 4]linux.io_uring_cqe = undefined;
            const read_count = self.read_ring.copy_cqes(cqes[0..@min(limit, cqes.len)], 0) catch {
                self.failed = true;
                self.store.markFailed();
                return .{ .count = 0, .outcome = .failed };
            };
            if (self.failed) self.store.markFailed();
            for (cqes[0..read_count]) |cqe| {
                if (cqe.user_data == maintenance_read_completion or
                    cqe.user_data == maintenance_unlink_completion or
                    cqe.user_data == maintenance_parent_sync_completion)
                {
                    self.completeMaintenanceCqe(cqe);
                    completed += 1;
                    continue;
                }
                if (cqe.user_data >= pack_write_completion) {
                    self.completeWriteCqe(cqe);
                    completed += 1;
                    continue;
                }
                const index = cqe.user_data - 1;
                if (index >= self.jobs.len or self.jobs[index].state != .submitted) {
                    self.failed = true;
                    self.store.markFailed();
                    continue;
                }
                const job = &self.jobs[index];
                if (cqe.err() != .SUCCESS or cqe.res < 0 or cqe.res != job.read.location.length) {
                    self.failed = true;
                    self.store.markFailed();
                } else self.store.completeRead(job.read.request, job.read.destination[0..@intCast(cqe.res)]) catch {
                    self.failed = true;
                    self.store.markFailed();
                };
                job.* = .{};
                completed += 1;
                if (self.metrics) |value| {
                    _ = value.persistence_read_completions.fetchAdd(1, .monotonic);
                    _ = value.persistence_read_bytes.fetchAdd(@intCast(@max(cqe.res, 0)), .monotonic);
                }
            }
            self.startMaintenance() catch self.failMaintenance();
            self.installCompactedIndex();
            self.publishDiskIndexMetrics();
            return .{ .count = completed, .outcome = if (self.failed or self.store.poisoned()) .failed else .ok };
        }

        fn backendSubmit(context: *anyopaque, _: std.Io) runtime.Outcome {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.failed or self.store.poisoned()) return .failed;
            var submissions: usize = 0;
            var write_submissions: usize = 0;
            var maintenance_reads: usize = 0;
            if (self.write_phase == .pack_publish_ready) {
                self.beginPackPublish() catch {
                    self.failWrite();
                    return .failed;
                };
                submissions += 2;
                write_submissions += 2;
            } else if (self.write_phase == .pack_ready) {
                if (self.write_owner == .compaction_pack) {
                    self.finishCompactionPack() catch {
                        self.failMaintenance();
                        return .failed;
                    };
                } else {
                    self.beginRootWrite() catch {
                        self.failWrite();
                        return .failed;
                    };
                    submissions += 2;
                    write_submissions += 2;
                }
            } else if (self.write_phase == .root_publish_ready) {
                self.beginRootPublish() catch {
                    self.failWrite();
                    return .failed;
                };
                submissions += 2;
                write_submissions += 2;
            } else if (self.write_phase == .root_ready) {
                self.finishRootWrite() catch {
                    self.failWrite();
                    return .failed;
                };
            }
            if (!self.write_queued and self.write_phase == .idle and self.maintenance_state == .idle) {
                const bytes = self.store.checkpointBytes();
                if (bytes.len != 0) {
                    if (@as(usize, self.root.count) == limits.maximum_packs or self.root.next_id > std.math.maxInt(u32) - 1) return .failed;
                    self.beginPackWrite(@intCast(self.root.next_id), bytes, .flush) catch {
                        self.failWrite();
                        return .failed;
                    };
                    submissions += 2;
                    write_submissions += 2;
                } else if (self.store.checkpoint_requested) {
                    self.beginRootData(self.root, .checkpoint_root) catch {
                        self.failWrite();
                        return .failed;
                    };
                    submissions += 2;
                    write_submissions += 2;
                }
            }
            const vacant = self.freeReadCount();
            const count = self.store.takeReadTasks(self.read_staging[0..vacant]);
            for (self.read_staging[0..count]) |task| {
                const job = self.freeJob() orelse unreachable;
                const index: usize = @intFromPtr(job) - @intFromPtr(&self.jobs[0]);
                const job_index = index / @sizeOf(Job);
                const file = self.readFile(task.location.pack) catch {
                    self.failed = true;
                    self.store.markFailed();
                    return .failed;
                };
                job.* = .{ .state = .submitted, .read = task };
                _ = self.read_ring.read(job_index + 1, file.handle, .{ .buffer = task.destination[0..task.location.length] }, task.location.offset) catch {
                    job.* = .{};
                    self.failed = true;
                    self.store.markFailed();
                    return .failed;
                };
                submissions += 1;
            }
            if (self.write_phase == .idle) {
                const maintenance_submissions = self.advanceMaintenance() catch |err| {
                    std.log.err("event=persistence_maintenance_failed state={s} error={s}", .{ @tagName(self.maintenance_state), @errorName(err) });
                    self.failMaintenance();
                    return .failed;
                };
                submissions += maintenance_submissions;
                if (self.maintenance_state == .recover_pending or self.maintenance_state == .copy_pending)
                    maintenance_reads += maintenance_submissions
                else
                    write_submissions += maintenance_submissions;
            }
            if (submissions != 0) _ = self.read_ring.submit() catch {
                self.failed = true;
                self.store.markFailed();
                return .failed;
            };
            if (submissions != 0) if (self.metrics) |value| {
                _ = value.persistence_read_submissions.fetchAdd(count + maintenance_reads, .monotonic);
                _ = value.persistence_write_submissions.fetchAdd(write_submissions, .monotonic);
                _ = value.persistence_submit_calls.fetchAdd(1, .monotonic);
            };
            return .ok;
        }

        fn beginShutdown(context: *anyopaque, _: std.Io) runtime.Outcome {
            const self: *Self = @ptrCast(@alignCast(context));
            self.shutdown = true;
            return if (self.failed or self.store.poisoned()) .failed else .ok;
        }

        fn shutdownProgress(context: *anyopaque) runtime.Progress {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.failed or self.store.poisoned()) return .failed;
            if (!self.shutdown) return .pending;
            for (self.jobs) |job| if (job.state != .free) return .pending;
            if (self.write_phase != .idle) return .pending;
            if (self.maintenance_state != .idle or self.retired_root != null) return .pending;
            return switch (self.store.checkpointProgress()) {
                .ready => .complete,
                .failed => .failed,
                else => .pending,
            };
        }

        fn beginPackWrite(self: *Self, pack: u32, bytes: []const u8, owner: WriteOwner) !void {
            const target = switch (owner) {
                .flush => self.store,
                .compaction_pack => blk: {
                    const maintenance = self.maintenancePtr() orelse return error.MaintenanceUnavailable;
                    const compaction = compactionPtr(maintenance) orelse return error.MaintenanceUnavailable;
                    break :blk compaction.output;
                },
                else => return error.InvalidWriteState,
            };
            // Scratch pages are reconstructed at startup; only packs and their root need fsync.
            if (target.disk != null) _ = try target.prepareDiskIndex(pack, 0);
            const temporary = try self.packPath(&self.path_first, pack, true);
            try self.failAt(.pack_create);
            const file = try std.Io.Dir.createFileAbsolute(self.io, temporary, .{ .read = true });
            errdefer file.close(self.io);
            try self.failAt(.pack_write);
            const write = try self.read_ring.write(pack_write_completion, file.handle, bytes, 0);
            write.link_next();
            try self.failAt(.pack_sync);
            _ = try self.read_ring.fsync(pack_sync_completion, file.handle, 0);
            self.write_file = file;
            self.write_owner = owner;
            self.write_pack = pack;
            self.write_bytes = bytes;
            self.write_pending = 2;
            self.write_succeeded = true;
            self.write_phase = .pack_data_pending;
            self.write_queued = true;
        }

        fn beginPackPublish(self: *Self) !void {
            const temporary = try self.packPath(&self.path_first, self.write_pack, true);
            const final = try self.packPath(&self.path_second, self.write_pack, false);
            try self.failAt(.pack_rename);
            const rename = try self.read_ring.renameat(pack_rename_completion, linux.AT.FDCWD, temporary.ptr, linux.AT.FDCWD, final.ptr, 0);
            rename.link_next();
            try self.failAt(.pack_parent_sync);
            _ = try self.read_ring.fsync(pack_parent_sync_completion, self.parent_file.?.handle, 0);
            self.write_pending = 2;
            self.write_succeeded = true;
            self.write_phase = .pack_publish_pending;
        }

        fn beginRootWrite(self: *Self) !void {
            const file = self.write_file orelse return error.InvalidWriteState;
            file.close(self.io);
            self.write_file = null;
            var next = self.root;
            try next.append(.{
                .id = self.write_pack,
                .bytes = self.write_bytes.len,
                .generation = self.root.generation + 1,
                .checksum = checksum(self.write_bytes),
            });
            try self.beginRootData(next, .flush);
        }

        fn beginRootData(self: *Self, next: Root, owner: WriteOwner) !void {
            self.write_next_root = next;
            self.write_commits_checkpoint = self.store.checkpoint_requested;
            self.write_committed_root = if (self.write_commits_checkpoint) next else self.committed_root;
            const publication: Publication = .{ .working = next, .committed = self.write_committed_root };
            const root_bytes = try publication.encode(&self.write_root_bytes);
            self.write_root_length = root_bytes.len;
            const root_temporary = try self.rootTemporaryPath();
            try self.failAt(.root_create);
            const root_file = try std.Io.Dir.createFileAbsolute(self.io, root_temporary, .{ .read = true });
            errdefer root_file.close(self.io);
            try self.failAt(.root_write);
            const write = try self.read_ring.write(root_write_completion, root_file.handle, self.write_root_bytes[0..self.write_root_length], 0);
            write.link_next();
            try self.failAt(.root_sync);
            _ = try self.read_ring.fsync(root_sync_completion, root_file.handle, 0);
            self.write_file = root_file;
            self.write_owner = owner;
            self.write_pending = 2;
            self.write_succeeded = true;
            self.write_phase = .root_data_pending;
        }

        fn beginRootPublish(self: *Self) !void {
            const temporary = try self.rootTemporaryPath();
            const final = try std.fmt.bufPrintZ(&self.path_second, "{s}", .{self.root_path});
            try self.failAt(.root_rename);
            const rename = try self.read_ring.renameat(root_rename_completion, linux.AT.FDCWD, temporary.ptr, linux.AT.FDCWD, final.ptr, 0);
            rename.link_next();
            try self.failAt(.root_parent_sync);
            _ = try self.read_ring.fsync(root_parent_sync_completion, self.parent_file.?.handle, 0);
            self.write_pending = 2;
            self.write_succeeded = true;
            self.write_phase = .root_publish_pending;
        }

        fn finishRootWrite(self: *Self) !void {
            const file = self.write_file orelse return error.InvalidWriteState;
            self.root_file.close(self.io);
            self.root_file = file;
            self.write_file = null;
            self.root = self.write_next_root;
            const previous_checkpoint = self.committed_root;
            self.committed_root = self.write_committed_root;
            if (self.write_owner == .flush) {
                self.store.markDurableInPack(self.write_pack, 0);
                _ = self.store.complete(1);
            } else if (self.write_owner == .compaction_root) {
                const maintenance = self.maintenancePtr() orelse return error.MaintenanceUnavailable;
                const compaction = compactionPtr(maintenance) orelse return error.MaintenanceUnavailable;
                self.retired_root = compaction.captured;
                self.maintenance_state = .install;
            } else if (self.write_owner != .checkpoint_root) return error.InvalidWriteState;
            if (self.write_commits_checkpoint) {
                self.store.finishCheckpoint();
                if (self.maintenance) |*maintenance| {
                    std.debug.assert(self.maintenance_state == .idle);
                    std.debug.assert(self.retired_root == null);
                    self.retired_root = previous_checkpoint;
                    maintenance.reclaim_index = 0;
                    self.maintenance_state = .reclaim;
                }
            }
            self.write_phase = .idle;
            self.write_queued = false;
            self.write_owner = .none;
            self.write_bytes = &.{};
            self.write_pending = 0;
            if (self.maintenance_state == .idle and @as(usize, self.root.count) + 2 >= maintenance_pack_threshold)
                self.requestMaintenance();
        }

        fn completeWriteCqe(self: *Self, cqe: linux.io_uring_cqe) void {
            const expected: i32 = switch (cqe.user_data) {
                pack_write_completion => @intCast(self.write_bytes.len),
                root_write_completion => @intCast(self.write_root_length),
                pack_sync_completion,
                pack_rename_completion,
                pack_parent_sync_completion,
                root_sync_completion,
                root_rename_completion,
                root_parent_sync_completion,
                => 0,
                else => {
                    self.failWrite();
                    return;
                },
            };
            if (cqe.err() != .SUCCESS or cqe.res != expected) {
                std.log.err("event=persistence_write_completion_failed owner={s} phase={s} operation={d} result={d} expected={d} error={s}", .{ @tagName(self.write_owner), @tagName(self.write_phase), cqe.user_data, cqe.res, expected, @tagName(cqe.err()) });
                self.write_succeeded = false;
            }
            if (self.metrics) |value| {
                _ = value.persistence_write_completions.fetchAdd(1, .monotonic);
                if (cqe.user_data == pack_write_completion or cqe.user_data == root_write_completion)
                    _ = value.persistence_write_bytes.fetchAdd(@intCast(@max(cqe.res, 0)), .monotonic);
            }
            if (self.write_pending == 0) {
                self.failWrite();
                return;
            }
            self.write_pending -= 1;
            if (self.write_pending != 0) return;
            if (!self.write_succeeded) {
                self.failWrite();
                return;
            }
            self.write_phase = switch (self.write_phase) {
                .pack_data_pending => .pack_publish_ready,
                .pack_publish_pending => .pack_ready,
                .root_data_pending => .root_publish_ready,
                .root_publish_pending => .root_ready,
                else => {
                    self.failWrite();
                    return;
                },
            };
        }

        fn completeMaintenanceCqe(self: *Self, cqe: linux.io_uring_cqe) void {
            if (self.maintenance_pending == 0) return self.failMaintenance();
            const maintenance = self.maintenancePtr() orelse return self.failMaintenance();
            const expected: i32 = switch (self.maintenance_state) {
                .recover_pending => @intCast(maintenance.captured.entries[maintenance.rebuild_index].bytes),
                .copy_pending => @intCast((maintenance.live orelse return self.failMaintenance()).location.length),
                .reclaim_pending => 0,
                else => return self.failMaintenance(),
            };
            if (cqe.err() != .SUCCESS or cqe.res != expected) {
                std.log.err("event=persistence_maintenance_completion_failed state={s} operation={d} result={d} expected={d} error={s}", .{ @tagName(self.maintenance_state), cqe.user_data, cqe.res, expected, @tagName(cqe.err()) });
                self.maintenance_succeeded = false;
            }
            if (self.metrics) |value| {
                if (cqe.user_data == maintenance_read_completion) {
                    _ = value.persistence_read_completions.fetchAdd(1, .monotonic);
                    _ = value.persistence_read_bytes.fetchAdd(@intCast(@max(cqe.res, 0)), .monotonic);
                } else {
                    _ = value.persistence_write_completions.fetchAdd(1, .monotonic);
                }
            }
            self.maintenance_pending -= 1;
            if (self.maintenance_pending != 0) return;
            if (!self.maintenance_succeeded) return self.failMaintenance();
            switch (self.maintenance_state) {
                .recover_pending => {
                    const entry = maintenance.captured.entries[maintenance.rebuild_index];
                    const bytes = maintenance.recovery[0..@intCast(entry.bytes)];
                    if (checksum(bytes) != entry.checksum or
                        (maintenance.source.recoverOneInPack(bytes, @intCast(entry.id), 0) catch return self.failMaintenance()) != bytes.len)
                        return self.failMaintenance();
                    maintenance.rebuild_index += 1;
                    self.maintenance_state = .recover;
                },
                .copy_pending => {
                    const compaction = compactionPtr(maintenance) orelse return self.failMaintenance();
                    const live = maintenance.live orelse return self.failMaintenance();
                    const operation: persistence.CheckpointRecord = .{
                        .namespace = live.namespace,
                        .key = live.key,
                        .operation = .{ .put = compaction.value[0..live.location.length] },
                    };
                    if (compaction.output.stage(operation) == .ready) {
                        compaction.copied += 1;
                        maintenance.live = null;
                        self.maintenance_state = .copy;
                    } else {
                        if (compaction.output.flush() != .pending) return self.failMaintenance();
                        self.maintenance_state = .copy_flush;
                    }
                },
                .reclaim_pending => {
                    maintenance.reclaim_index += 1;
                    self.maintenance_state = .reclaim;
                },
                else => self.failMaintenance(),
            }
        }

        fn finishCompactionPack(self: *Self) !void {
            const file = self.write_file orelse return error.InvalidWriteState;
            file.close(self.io);
            self.write_file = null;
            const maintenance = self.maintenancePtr() orelse return error.MaintenanceUnavailable;
            const compaction = compactionPtr(maintenance) orelse return error.MaintenanceUnavailable;
            try compaction.next.append(.{
                .id = self.write_pack,
                .bytes = self.write_bytes.len,
                .generation = compaction.next.generation + 1,
                .checksum = checksum(self.write_bytes),
            });
            compaction.output.markDurableInPack(self.write_pack, 0);
            _ = compaction.output.complete(1);
            self.write_phase = .idle;
            self.write_queued = false;
            self.write_owner = .none;
            self.write_bytes = &.{};
            self.write_pending = 0;
            if (self.maintenance_state == .copy_flush) {
                const live = maintenance.live orelse return error.MaintenanceUnavailable;
                if (compaction.output.stage(.{
                    .namespace = live.namespace,
                    .key = live.key,
                    .operation = .{ .put = compaction.value[0..live.location.length] },
                }) != .ready) return error.CompactionStageFailed;
                compaction.copied += 1;
                maintenance.live = null;
                self.maintenance_state = .copy;
            } else if (self.maintenance_state == .publish_flush) {
                self.maintenance_state = .publish;
            } else return error.InvalidWriteState;
        }

        fn failWrite(self: *Self) void {
            if (self.write_file) |file| file.close(self.io);
            self.write_file = null;
            self.write_phase = .idle;
            self.write_queued = false;
            self.write_owner = .none;
            self.write_pending = 0;
            self.write_bytes = &.{};
            self.failed = true;
            self.store.markFailed();
        }

        fn readLocationUncached(self: *Self, location: persistence.Location, destination: []u8) !usize {
            if (location.pack == 0 or !self.rootContains(location.pack)) return error.UnknownPack;
            var path_storage: [limits.maximum_path_bytes]u8 = undefined;
            const path = try self.packPath(&path_storage, location.pack, false);
            const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only });
            defer file.close(self.io);
            return file.readPositionalAll(self.io, destination[0..@as(usize, location.length)], location.offset);
        }

        fn readFile(self: *Self, pack: u32) !std.Io.File {
            if (pack == 0 or !self.rootContains(pack)) return error.UnknownPack;
            self.read_file_age +%= 1;
            for (&self.read_files) |*entry| {
                if (entry.file != null and entry.pack == pack) {
                    entry.age = self.read_file_age;
                    return entry.file.?;
                }
            }
            var selected: usize = 0;
            for (self.read_files, 0..) |entry, index| {
                if (entry.file == null) {
                    selected = index;
                    break;
                }
                if (entry.age < self.read_files[selected].age) selected = index;
            }
            const entry = &self.read_files[selected];
            if (entry.file) |file| file.close(self.io);
            var path_storage: [limits.maximum_path_bytes]u8 = undefined;
            const path = try self.packPath(&path_storage, pack, false);
            entry.* = .{
                .pack = pack,
                .file = try std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only }),
                .age = self.read_file_age,
            };
            return entry.file.?;
        }

        fn rootContains(self: *const Self, pack: u32) bool {
            if (self.root.contains(pack)) return true;
            if (self.retired_root) |root| return root.contains(pack);
            return false;
        }

        fn requestMaintenance(self: *Self) void {
            self.maintenance_requested = true;
            if (self.maintenance_state == .idle) self.maintenance_state = .requested;
        }

        fn startMaintenance(self: *Self) !void {
            if (!self.maintenance_requested or self.write_queued) return;
            if (self.maintenance_state != .requested) return;
            if (!self.store.epochSwitchReady()) return;
            const maintenance = self.maintenancePtr() orelse return;
            maintenance.captured = self.root;
            if (self.store.disk != null) {
                const output_slot: u1 = 1 - self.active_index_slot;
                try self.resetIndexSlot(output_slot);
                try maintenance.source.rebindEmptyDiskIndex(self.index_files[self.active_index_slot].interface());
                try maintenance.output.rebindEmptyDiskIndex(self.index_files[output_slot].interface());
            }
            maintenance.source.beginRecovery();
            maintenance.output.beginRecovery();
            maintenance.compaction = null;
            maintenance.rebuild_index = 0;
            maintenance.reclaim_index = 0;
            maintenance.live = null;
            self.maintenance_state = .recover;
        }

        fn maintenanceRunnable(self: *const Self) bool {
            return self.maintenance_state != .idle and self.maintenance_state != .requested and
                self.maintenance_state != .install;
        }

        fn installCompactedIndex(self: *Self) void {
            if (self.maintenance_state != .install) return;
            if (!self.store.epochSwitchReady()) return;
            const maintenance = self.maintenancePtr() orelse {
                self.failed = true;
                self.store.markFailed();
                return;
            };
            const compacted = compactionPtr(maintenance) orelse {
                self.failed = true;
                self.store.markFailed();
                return;
            };
            self.store.installCompactedIndex(compacted.output) catch {
                self.failed = true;
                self.store.markFailed();
                return;
            };
            if (self.store.disk != null) self.active_index_slot = 1 - self.active_index_slot;
            maintenance.reclaim_index = 0;
            self.maintenance_state = .reclaim;
        }

        fn advanceMaintenance(self: *Self) !usize {
            try self.startMaintenance();
            while (true) switch (self.maintenance_state) {
                .idle,
                .requested,
                .install,
                .recover_pending,
                .copy_pending,
                .reclaim_pending,
                => return 0,
                .recover => {
                    const maintenance = self.maintenancePtr() orelse return error.MaintenanceUnavailable;
                    if (maintenance.rebuild_index == maintenance.captured.count) {
                        maintenance.compaction = try Compaction.init(self, maintenance.source, maintenance.output, maintenance.value);
                        self.maintenance_state = .copy;
                        continue;
                    }
                    const entry = maintenance.captured.entries[maintenance.rebuild_index];
                    if (entry.bytes > maintenance.recovery.len) return error.RecoveryCapacity;
                    const file = try self.readFile(@intCast(entry.id));
                    _ = try self.read_ring.read(maintenance_read_completion, file.handle, .{ .buffer = maintenance.recovery[0..@intCast(entry.bytes)] }, 0);
                    self.maintenance_pending = 1;
                    self.maintenance_succeeded = true;
                    self.maintenance_state = .recover_pending;
                    return 1;
                },
                .copy => {
                    const maintenance = self.maintenancePtr() orelse return error.MaintenanceUnavailable;
                    const compaction = compactionPtr(maintenance) orelse return error.MaintenanceUnavailable;
                    if (compaction.copied == compaction.source.liveRecords()) {
                        if (compaction.output.stagedRecords() == 0) {
                            self.maintenance_state = .publish;
                            continue;
                        }
                        if (compaction.output.flush() != .pending) return error.CompactionEncodeFailed;
                        self.maintenance_state = .publish_flush;
                        continue;
                    }
                    const live = try compaction.source.nextLive(&compaction.cursor) orelse return error.CompactionSourceCorrupt;
                    maintenance.live = live;
                    const file = try self.readFile(live.location.pack);
                    _ = try self.read_ring.read(maintenance_read_completion, file.handle, .{ .buffer = compaction.value[0..live.location.length] }, live.location.offset);
                    self.maintenance_pending = 1;
                    self.maintenance_succeeded = true;
                    self.maintenance_state = .copy_pending;
                    return 1;
                },
                .copy_flush, .publish_flush => {
                    const maintenance = self.maintenancePtr() orelse return error.MaintenanceUnavailable;
                    const compaction = compactionPtr(maintenance) orelse return error.MaintenanceUnavailable;
                    const bytes = compaction.output.checkpointBytes();
                    if (bytes.len == 0) return error.CompactionEncodeFailed;
                    try self.beginPackWrite(@intCast(compaction.next.next_id), bytes, .compaction_pack);
                    return 2;
                },
                .publish => {
                    const maintenance = self.maintenancePtr() orelse return error.MaintenanceUnavailable;
                    const compaction = compactionPtr(maintenance) orelse return error.MaintenanceUnavailable;
                    if (self.root.generation != compaction.captured.generation) return error.EpochChanged;
                    try self.beginRootData(compaction.next, .compaction_root);
                    return 2;
                },
                .reclaim => {
                    const retired = self.retired_root orelse return error.EpochSwitchBusy;
                    const maintenance = self.maintenancePtr() orelse return error.MaintenanceUnavailable;
                    if (maintenance.reclaim_index == retired.count) {
                        self.retired_root = null;
                        self.maintenance_requested = false;
                        self.maintenance_state = .idle;
                        maintenance.compaction = null;
                        maintenance.live = null;
                        if (@as(usize, self.root.count) + 2 >= maintenance_pack_threshold)
                            self.requestMaintenance();
                        continue;
                    }
                    const entry = retired.entries[maintenance.reclaim_index];
                    if (self.root.contains(entry.id) or self.committed_root.contains(entry.id)) {
                        maintenance.reclaim_index += 1;
                        continue;
                    }
                    const path = try self.packPath(&self.path_second, entry.id, false);
                    const unlink = try self.read_ring.unlinkat(maintenance_unlink_completion, linux.AT.FDCWD, path.ptr, 0);
                    unlink.link_next();
                    _ = try self.read_ring.fsync(maintenance_parent_sync_completion, self.parent_file.?.handle, 0);
                    self.maintenance_pending = 2;
                    self.maintenance_succeeded = true;
                    self.maintenance_state = .reclaim_pending;
                    return 2;
                },
            };
        }

        fn recoverPack(self: *Self, target: *persistence.Store, entry: root_format.Entry, recovery: []u8) !void {
            if (entry.bytes > @as(u64, @intCast(recovery.len))) return error.RecoveryCapacity;
            const path = try self.packPath(&self.path_first, entry.id, false);
            const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only });
            defer file.close(self.io);
            const length: usize = @intCast(entry.bytes);
            const bytes = try file.readPositionalAll(self.io, recovery[0..length], 0);
            if (bytes != length or checksum(recovery[0..bytes]) != entry.checksum) return error.InvalidPack;
            if (try target.recoverOneInPack(recovery[0..bytes], @intCast(entry.id), 0) != bytes) return error.InvalidPack;
        }

        fn failMaintenance(self: *Self) void {
            self.failed = true;
            self.store.markFailed();
        }

        inline fn failAt(self: *Self, boundary: TestFault) !void {
            if (comptime builtin.is_test) {
                if (self.test_fault != boundary) return;
                self.test_fault = null;
                return error.InjectedFault;
            }
        }

        /// RAM indexes can bound a compaction by key capacity. Disk indexes
        /// deliberately have no such bound; pack capacity is checked as packs
        /// are actually produced by the maintenance state machine.
        fn validateCompactionCapacity(store: *const persistence.Store) !void {
            if (store.disk != null) return;
            const configuration = store.configuration;
            const records = try persistence.guaranteedCheckpointRecords(configuration);
            const quotient = configuration.maximum_keys / records;
            const remainder = configuration.maximum_keys % records;
            const output_packs = quotient + @intFromBool(remainder != 0);
            if (output_packs >= limits.maximum_packs) return error.CompactionPackCapacity;
        }

        fn checkpointAdmission(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            const ready = self.maintenance_state == .idle and !self.maintenance_requested and !self.failed;
            if (!ready and !self.checkpoint_admission_wait_logged) {
                std.log.info("event=persistence_flush_wait maintenance={s} commit={s} epoch_ready={} checkpoint={}", .{
                    @tagName(self.maintenance_state), @tagName(self.store.commit), self.store.epochSwitchReady(), self.store.checkpoint_requested,
                });
            }
            self.checkpoint_admission_wait_logged = !ready;
            return ready;
        }

        fn readAdmission(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.maintenance_state != .install and !self.failed;
        }

        fn packPath(self: *const Self, storage: *[limits.maximum_path_bytes]u8, id: u64, temporary: bool) ![:0]const u8 {
            const suffix = if (temporary) ".next" else "";
            return std.fmt.bufPrintZ(storage, "{s}.pack.{d}{s}", .{ self.root_path, id, suffix });
        }

        fn rootTemporaryPath(self: *Self) ![:0]const u8 {
            return std.fmt.bufPrintZ(&self.path_root, "{s}.next", .{self.root_path});
        }

        fn freeJob(self: *Self) ?*Job {
            for (&self.jobs) |*job| if (job.state == .free) return job;
            return null;
        }
        fn freeReadCount(self: *Self) usize {
            var count: usize = 0;
            for (self.jobs) |job| {
                if (job.state == .free) count += 1;
            }
            return @min(count, limits.maximum_in_flight_reads);
        }

        fn pollInterval(context: *anyopaque) ?u64 {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.write_phase != .idle or self.maintenanceRunnable()) return std.time.ns_per_ms;
            for (self.jobs) |job| if (job.state != .free) return std.time.ns_per_ms;
            return null;
        }

        const vtable: runtime.Backend.VTable = .{
            .complete = backendComplete,
            .submit = backendSubmit,
            .begin_shutdown = beginShutdown,
            .shutdown_progress = shutdownProgress,
            .poll_interval_ns = pollInterval,
        };
    };
}

fn checksum(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6c6f63616c2d7061, bytes);
}

const FaultDriver = Driver(.{ .maximum_in_flight_reads = 1, .maximum_packs = 4, .maximum_path_bytes = 256 });

test "every local publish boundary has a deterministic failure seam" {
    var driver: FaultDriver = undefined;
    const boundaries = [_]FaultDriver.TestFault{
        .pack_create, .pack_write, .pack_sync, .pack_rename, .pack_parent_sync,
        .root_create, .root_write, .root_sync, .root_rename, .root_parent_sync,
    };
    for (boundaries) |boundary| {
        driver.setTestFault(boundary);
        try std.testing.expectError(error.InjectedFault, driver.failAt(boundary));
        try std.testing.expect(driver.test_fault == null);
    }
}

test "every interrupted publication recovers one whole epoch" {
    for ([_]bool{ false, true }) |commit| {
        for ([_]FaultDriver.TestFault{ .pack_create, .pack_write, .pack_sync, .pack_rename, .pack_parent_sync, .root_create, .root_write, .root_sync, .root_rename, .root_parent_sync }) |fault|
            try restartAfterFault(fault, commit);
    }
}

test "a missing committed pack is a storage failure rather than an absent record" {
    for ([_]enum { missing, truncated, asynchronous }{ .missing, .truncated, .asynchronous }) |failure| {
        const configuration: persistence.Configuration = .{
            .maximum_keys = 2,
            .maximum_checkpoint_records = 2,
            .maximum_requests = 1,
            .maximum_namespace_bytes = 8,
            .maximum_key_bytes = 8,
            .maximum_value_bytes = 16,
            .maximum_checkpoint_bytes = 128,
        };
        var memory: [64 * 1024]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&memory);
        const store = try persistence.Store.initIndex(allocator.allocator(), configuration);
        const io = std.Io.Threaded.global_single_threaded.io();
        var path: [256]u8 = undefined;
        var recovery: [128]u8 = undefined;
        const file = try std.Io.Dir.cwd().createFile(io, "local-packs-missing-test.root", .{ .read = true, .truncate = true });
        const path_len = try file.realPath(io, &path);
        file.close(io);
        defer cleanupTestPacks(io, path[0..path_len]);
        var driver: FaultDriver = undefined;
        try driver.init(io, path[0..path_len], store, &recovery);
        defer driver.deinit();
        try writePairPack(&driver, store, 1, "left", "right");
        var value: [16]u8 = undefined;
        try std.testing.expectEqualStrings("left", try loadValue(driver.loader(), "left", &value));
        try std.testing.expectError(error.InvalidKey, driver.loader().read("namespace-too-long", "left", &value));
        try std.testing.expectError(error.InvalidKey, driver.loader().read("n", "key-too-long", &value));
        try std.testing.expectError(error.DestinationTooSmall, driver.loader().read("n", "left", value[0..1]));
        try std.testing.expect(!store.poisoned());
        try std.testing.expectEqual(persistence.LoadResult.missing, try driver.loader().read("n", "absent", &value));
        var pack_path: [256]u8 = undefined;
        const removed = try driver.packPath(&pack_path, 1, false);
        switch (failure) {
            .truncated => {
                const pack = try std.Io.Dir.openFileAbsolute(io, removed, .{ .mode = .read_write });
                defer pack.close(io);
                try pack.setLength(io, 0);
                try std.testing.expectError(error.Corrupt, driver.loader().read("n", "left", &value));
            },
            .missing, .asynchronous => {
                try std.Io.Dir.deleteFileAbsolute(io, removed);
                if (failure == .missing) {
                    try std.testing.expectError(error.ReadFailed, driver.loader().read("n", "left", &value));
                } else {
                    const request = store.read("n", "left", &value);
                    try std.testing.expect(request != persistence.no_request);
                    try std.testing.expectEqual(runtime.Outcome.failed, FaultDriver.backendSubmit(&driver, io));
                }
            },
        }
        try std.testing.expectError(error.ReadFailed, driver.loader().read("n", "absent", &value));
        try std.testing.expectError(error.ReadFailed, driver.loader().read("n", "right", &value));
        try std.testing.expectEqual(persistence.no_request, store.read("n", "left", &value));
        try std.testing.expectEqual(runtime.Outcome.failed, FaultDriver.backendSubmit(&driver, io));
        try std.testing.expect(store.poisoned());
        try std.testing.expectEqual(persistence.Status.failed, store.flush());
    }
}

test "loader reads the current staged value before a checkpoint" {
    const configuration: persistence.Configuration = .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 16,
        .maximum_checkpoint_bytes = 128,
    };
    var memory: [64 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    const store = try persistence.Store.initIndex(allocator.allocator(), configuration);
    const io = std.Io.Threaded.global_single_threaded.io();
    var path: [256]u8 = undefined;
    var recovery: [128]u8 = undefined;
    const file = try std.Io.Dir.cwd().createFile(io, "local-packs-current-value-test.root", .{ .read = true, .truncate = true });
    const path_len = try file.realPath(io, &path);
    file.close(io);
    defer cleanupTestPacks(io, path[0..path_len]);
    var driver: FaultDriver = undefined;
    try driver.init(io, path[0..path_len], store, &recovery);
    defer driver.deinit();
    try writePairPack(&driver, store, 1, "committed-a", "right");

    var value: [16]u8 = undefined;
    try std.testing.expectEqualStrings("committed-a", try loadValue(driver.loader(), "left", &value));
    try std.testing.expectEqual(persistence.Status.ready, store.stage(.{ .namespace = "n", .key = "left", .operation = .{ .put = "staged-b" } }));
    try std.testing.expectEqualStrings("staged-b", try loadValue(driver.loader(), "left", &value));
    try std.testing.expectEqual(persistence.Status.ready, store.stage(.{ .namespace = "n", .key = "left", .operation = .delete }));
    try std.testing.expectEqual(persistence.LoadResult.missing, try driver.loader().read("n", "left", &value));
    store.markFailed();
    try std.testing.expectError(error.ReadFailed, driver.loader().read("n", "left", &value));
}

test "runtime spills recover only after an explicit completed checkpoint" {
    const TestDriver = Driver(.{ .maximum_in_flight_reads = 1, .maximum_packs = 8, .maximum_path_bytes = 256 });
    for ([_]bool{ false, true }) |commit| {
        const configuration: persistence.Configuration = .{
            .maximum_keys = 2,
            .maximum_checkpoint_records = 2,
            .maximum_requests = 1,
            .maximum_namespace_bytes = 8,
            .maximum_key_bytes = 8,
            .maximum_value_bytes = 16,
            .maximum_checkpoint_bytes = 128,
        };
        var memory: [64 * 1024]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&memory);
        const store = try persistence.Store.initIndex(allocator.allocator(), configuration);
        const io = std.Io.Threaded.global_single_threaded.io();
        var path: [256]u8 = undefined;
        var recovery: [128]u8 = undefined;
        const file = try std.Io.Dir.cwd().createFile(io, "local-packs-checkpoint-test.root", .{ .read = true, .truncate = true });
        const path_len = try file.realPath(io, &path);
        file.close(io);
        defer cleanupTestPacks(io, path[0..path_len]);
        var driver: TestDriver = undefined;
        try driver.init(io, path[0..path_len], store, &recovery);
        {
            defer driver.deinit();
            try writePairPack(&driver, store, 1, "old-left", "old-right");
            _ = try preparePair(store, "new-left", "new-right");
            try drainTestWrites(&driver);
            var value: [16]u8 = undefined;
            try std.testing.expectEqualStrings("new-left", try loadValue(driver.loader(), "left", &value));
            try std.testing.expectEqual(@as(u16, 1), driver.committed_root.count);
            const contender = try persistence.Store.initIndex(allocator.allocator(), configuration);
            var other: TestDriver = undefined;
            try std.testing.expectError(error.StoreAlreadyOpen, other.init(io, path[0..path_len], contender, &recovery));
            if (commit) {
                try std.testing.expectEqual(persistence.Status.pending, store.requestCheckpoint());
                try drainTestWrites(&driver);
                try std.testing.expectEqual(@as(u16, 2), driver.committed_root.count);
            }
        }
        var abandoned_path: [256]u8 = undefined;
        for ([_][]const u8{ ".next", ".pack.3", ".pack.3.next", ".pack.03", ".pack.3.bak" }) |suffix| {
            const name = try std.fmt.bufPrint(&abandoned_path, "{s}{s}", .{ path[0..path_len], suffix });
            const abandoned = try std.Io.Dir.createFileAbsolute(io, name, .{});
            abandoned.close(io);
        }
        const reopened = try persistence.Store.initIndex(allocator.allocator(), configuration);
        var recovered: TestDriver = undefined;
        try recovered.init(io, path[0..path_len], reopened, &recovery);
        defer recovered.deinit();
        var value: [16]u8 = undefined;
        try std.testing.expectEqualStrings(if (commit) "new-left" else "old-left", try loadValue(recovered.loader(), "left", &value));
        try std.testing.expectEqualStrings(if (commit) "new-right" else "old-right", try loadValue(recovered.loader(), "right", &value));
        try std.testing.expectEqual(@as(u64, 3), recovered.root.next_id);
        for ([_][]const u8{ ".next", ".pack.3", ".pack.3.next" }) |suffix| {
            const name = try std.fmt.bufPrint(&abandoned_path, "{s}{s}", .{ path[0..path_len], suffix });
            try std.testing.expect(!try fileExists(io, name));
        }
        for ([_][]const u8{ ".pack.03", ".pack.3.bak" }) |suffix| {
            const name = try std.fmt.bufPrint(&abandoned_path, "{s}{s}", .{ path[0..path_len], suffix });
            try std.testing.expect(try fileExists(io, name));
        }
        const second_pack = try recovered.packPath(&abandoned_path, 2, false);
        try std.testing.expectEqual(commit, try fileExists(io, second_pack));
    }
}

test "checkpoint writer spills bounded batches without publishing a partial checkpoint" {
    const TestDriver = Driver(.{ .maximum_in_flight_reads = 1, .maximum_packs = 8, .maximum_path_bytes = 256 });
    const Result = enum { abandoned, committed, write_failed, maintenance_unavailable };
    for ([_]Result{ .abandoned, .committed, .write_failed, .maintenance_unavailable }) |result| {
        const configuration: persistence.Configuration = .{
            .maximum_keys = 2,
            .maximum_checkpoint_records = 2,
            .maximum_requests = 1,
            .maximum_namespace_bytes = 8,
            .maximum_key_bytes = 8,
            .maximum_value_bytes = 16,
            .maximum_checkpoint_bytes = 128,
        };
        var memory: [64 * 1024]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&memory);
        const store = try persistence.Store.initIndex(allocator.allocator(), configuration);
        const io = std.testing.io;
        var path: [256]u8 = undefined;
        var recovery: [128]u8 = undefined;
        const file = try std.Io.Dir.cwd().createFile(io, "local-packs-writer-spill.root", .{ .read = true, .truncate = true });
        const path_len = try file.realPath(io, &path);
        file.close(io);
        defer cleanupTestPacks(io, path[0..path_len]);
        var driver: TestDriver = undefined;
        try driver.init(io, path[0..path_len], store, &recovery);
        {
            defer driver.deinit();
            const source = try persistence.Store.initRecoveryIndex(allocator.allocator(), configuration);
            const output = try persistence.Store.initCompactionIndex(allocator.allocator(), configuration);
            var compaction_value: [16]u8 = undefined;
            if (result != .maintenance_unavailable)
                try driver.configureMaintenance(source, output, &compaction_value, &recovery);
            try writePairPack(&driver, store, 1, "old-left", "old-right");
            var writer = lightning_rod.plugin_lifecycle.Checkpoint.Writer.init(store.interface(), io);
            var namespace = try writer.bind("n");
            try namespace.put("left", "mid-left");
            try namespace.put("right", "mid-right");
            if (result == .maintenance_unavailable) {
                var rejected = false;
                for (0..12) |_| {
                    namespace.batch(&.{
                        .{ .key = "left", .operation = .{ .put = "new-left" } },
                        .{ .key = "right", .operation = .{ .put = "new-right" } },
                    }) catch |err| {
                        try std.testing.expectEqual(error.Unavailable, err);
                        rejected = true;
                        break;
                    };
                }
                try std.testing.expect(rejected);
                try std.testing.expect(store.poisoned());
            } else if (result == .write_failed) {
                driver.setTestFault(.pack_sync);
                try std.testing.expectError(error.Unavailable, namespace.put("left", "new-left"));
                try std.testing.expect(store.poisoned());
            } else {
                for (0..12) |_| {
                    try namespace.put("left", "mid-left");
                    try namespace.put("right", "mid-right");
                }
                try namespace.put("left", "new-left");
                try namespace.put("right", "new-right");
                try store.interface().drain(io);
                try std.testing.expect(driver.root.count < 8);
                try std.testing.expect(driver.root.next_id > 8);
                try std.testing.expectEqual(@as(u16, 1), driver.committed_root.count);
                if (result == .committed) {
                    try std.testing.expectEqual(persistence.Status.pending, store.requestCheckpoint());
                    try store.interface().drain(io);
                }
            }
        }
        const restored = try persistence.Store.initIndex(allocator.allocator(), configuration);
        try driver.init(io, path[0..path_len], restored, &recovery);
        defer driver.deinit();
        var value: [16]u8 = undefined;
        try std.testing.expectEqualStrings(if (result == .committed) "new-left" else "old-left", try loadValue(driver.loader(), "left", &value));
        try std.testing.expectEqualStrings(if (result == .committed) "new-right" else "old-right", try loadValue(driver.loader(), "right", &value));
    }
}

test "failed recovery preserves abandoned files and releases ownership" {
    const configuration: persistence.Configuration = .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 16,
        .maximum_checkpoint_bytes = 128,
    };
    for ([_]bool{ false, true }) |corrupt_root| {
        var memory: [64 * 1024]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&memory);
        const store = try persistence.Store.initIndex(allocator.allocator(), configuration);
        const io = std.Io.Threaded.global_single_threaded.io();
        var path: [256]u8 = undefined;
        var recovery: [128]u8 = undefined;
        const file = try std.Io.Dir.cwd().createFile(io, "local-packs-corrupt-test.root", .{ .read = true, .truncate = true });
        const length = try file.realPath(io, &path);
        file.close(io);
        defer cleanupTestPacks(io, path[0..length]);
        var driver: FaultDriver = undefined;
        try driver.init(io, path[0..length], store, &recovery);
        {
            defer driver.deinit();
            try writePairPack(&driver, store, 1, "left", "right");
        }
        var abandoned_path: [256]u8 = undefined;
        const abandoned_name = try std.fmt.bufPrint(&abandoned_path, "{s}.pack.3", .{path[0..length]});
        const abandoned = try std.Io.Dir.createFileAbsolute(io, abandoned_name, .{});
        abandoned.close(io);
        if (corrupt_root) {
            const root = try std.Io.Dir.openFileAbsolute(io, path[0..length], .{ .mode = .read_write });
            defer root.close(io);
            try root.writePositionalAll(io, &.{0}, 0);
        } else {
            var missing_path: [256]u8 = undefined;
            const missing = try std.fmt.bufPrint(&missing_path, "{s}.pack.1", .{path[0..length]});
            try std.Io.Dir.deleteFileAbsolute(io, missing);
        }
        const restored = try persistence.Store.initIndex(allocator.allocator(), configuration);
        try std.testing.expectError(if (corrupt_root) error.InvalidMagic else error.FileNotFound, driver.init(io, path[0..length], restored, &recovery));
        try std.testing.expect(try fileExists(io, abandoned_name));
        var lock_path: [256]u8 = undefined;
        const lock_name = try std.fmt.bufPrint(&lock_path, "{s}.lock", .{path[0..length]});
        const lock = try std.Io.Dir.openFileAbsolute(io, lock_name, .{ .mode = .read_write });
        defer lock.close(io);
        try std.testing.expect(try lock.tryLock(io, .exclusive));
    }
}

fn drainTestWrites(driver: anytype) !void {
    const deadline = std.Io.Clock.Timestamp.now(driver.io, .awake).raw.nanoseconds + 5 * std.time.ns_per_s;
    const T = @typeInfo(@TypeOf(driver)).pointer.child;
    while (std.Io.Clock.Timestamp.now(driver.io, .awake).raw.nanoseconds < deadline) {
        try std.testing.expectEqual(runtime.Outcome.ok, T.backendComplete(driver, driver.io, 16).outcome);
        try std.testing.expectEqual(runtime.Outcome.ok, T.backendSubmit(driver, driver.io));
        if (driver.store.checkpointProgress() == .ready and driver.write_phase == .idle and driver.maintenance_state == .idle) return;
        try std.Io.sleep(driver.io, .fromMilliseconds(1), .awake);
    }
    return error.CheckpointDidNotComplete;
}

test "automatic compaction advances entirely through io_uring completions" {
    const AsyncDriver = Driver(.{ .maximum_in_flight_reads = 4, .maximum_packs = 8, .maximum_path_bytes = 256 });
    for ([_]bool{ false, true }) |commit| {
        const configuration: persistence.Configuration = .{
            .maximum_keys = 4,
            .maximum_checkpoint_records = 2,
            .maximum_requests = 2,
            .maximum_namespace_bytes = 8,
            .maximum_key_bytes = 8,
            .maximum_value_bytes = 16,
            .maximum_checkpoint_bytes = 128,
        };
        var memory: [256 * 1024]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&memory);
        const live = try persistence.Store.initIndex(allocator.allocator(), configuration);
        const source = try persistence.Store.initRecoveryIndex(allocator.allocator(), configuration);
        const output = try persistence.Store.initCompactionIndex(allocator.allocator(), configuration);
        var recovery: [128]u8 = undefined;
        var value: [16]u8 = undefined;
        var path: [256]u8 = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io, "local-packs-async-compaction.root", .{ .read = true, .truncate = true });
        const path_len = try file.realPath(io, &path);
        file.close(io);
        defer cleanupTestPacks(io, path[0..path_len]);
        var driver: AsyncDriver = undefined;
        try driver.init(io, path[0..path_len], live, &recovery);
        var driver_live = true;
        defer if (driver_live) driver.deinit();
        try driver.configureMaintenance(source, output, &value, &recovery);
        try writePairPack(&driver, live, 1, "old-left", "old-right");
        try writePairPack(&driver, live, 2, "new-left", "new-right");
        var retained: [16]u8 = undefined;
        const retained_request = live.interface().read("n", "left", &retained);
        try std.testing.expect(!live.epochSwitchReady());
        driver.requestMaintenance();
        for (0..256) |_| {
            _ = AsyncDriver.backendComplete(&driver, io, 16);
            driver.installCompactedIndex();
            if (driver.maintenance_state == .idle) break;
            try std.testing.expectEqual(runtime.Outcome.ok, AsyncDriver.backendSubmit(&driver, io));
            if (driver.maintenance_pending != 0 or driver.write_pending != 0)
                _ = try driver.read_ring.submit_and_wait(1);
        } else return error.CompactionDidNotConverge;
        try std.testing.expectEqual(@as(u16, 1), driver.root.count);
        const retained_result = live.pollRead(retained_request);
        try std.testing.expectEqual(persistence.Status.ready, retained_result.status);
        try std.testing.expectEqualStrings("new-left", retained[0..retained_result.bytes]);
        try std.testing.expectEqual(@as(u32, 3), live.startupLocation("n", "left").?.pack);
        var left: [16]u8 = undefined;
        var right: [16]u8 = undefined;
        try std.testing.expectEqualStrings("new-left", try loadValue(driver.loader(), "left", &left));
        try std.testing.expectEqualStrings("new-right", try loadValue(driver.loader(), "right", &right));
        var pack_path: [256]u8 = undefined;
        const protected_path = try driver.packPath(&pack_path, 1, false);
        const protected_file = try std.Io.Dir.openFileAbsolute(io, protected_path, .{});
        protected_file.close(io);
        try std.testing.expectEqual(@as(u16, 2), driver.committed_root.count);
        if (!commit) {
            driver.deinit();
            driver_live = false;
            const restored = try persistence.Store.initIndex(allocator.allocator(), configuration);
            try driver.init(io, path[0..path_len], restored, &recovery);
            driver_live = true;
            try std.testing.expectEqualStrings("new-left", try loadValue(driver.loader(), "left", &left));
            try std.testing.expectEqual(@as(u16, 2), driver.root.count);
            const abandoned = try driver.packPath(&pack_path, 3, false);
            try std.testing.expect(!try fileExists(io, abandoned));
            continue;
        }
        try std.testing.expectEqual(persistence.Status.pending, live.requestCheckpoint());
        try drainTestWrites(&driver);
        try std.testing.expectEqual(@as(u16, 1), driver.committed_root.count);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, protected_path, .{}));
    }
}

test "driver initialization rejects a compaction that cannot fit" {
    const Small = Driver(.{ .maximum_in_flight_reads = 1, .maximum_packs = 2, .maximum_path_bytes = 256 });
    const configuration: persistence.Configuration = .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 128,
    };
    var memory: [32 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    const store = try persistence.Store.initIndex(allocator.allocator(), configuration);
    var path: [256]u8 = undefined;
    var recovery: [128]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, "local-packs-capacity-test.root", .{ .read = true, .truncate = true });
    const path_len = try file.realPath(io, &path);
    file.close(io);
    defer cleanupTestPacks(io, path[0..path_len]);
    var driver: Small = undefined;
    try std.testing.expectError(error.CompactionPackCapacity, driver.init(io, path[0..path_len], store, &recovery));
}

fn restartAfterFault(fault: FaultDriver.TestFault, commit: bool) !void {
    const configuration: persistence.Configuration = .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 16,
        .maximum_checkpoint_bytes = 128,
    };
    var memory: [64 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    const source = try persistence.Store.initIndex(allocator.allocator(), configuration);
    var old: [128]u8 = undefined;
    const old_source = try checkpointPair(source, "old-left", "old-right");
    @memcpy(old[0..old_source.len], old_source);
    const old_bytes = old[0..old_source.len];
    const next = try checkpointPair(source, "new-left", "new-right");
    var path: [256]u8 = undefined;
    var recovery: [128]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const name = "local-packs-fault-test.root";
    const file = try std.Io.Dir.cwd().createFile(io, name, .{ .read = true, .truncate = true });
    const path_len = try file.realPath(io, &path);
    file.close(io);
    defer cleanupTestPacks(io, path[0..path_len]);
    var driver: FaultDriver = undefined;
    try driver.init(io, path[0..path_len], source, &recovery);
    _ = try writePackSync(&driver, 1, old_bytes, true);
    driver.setTestFault(fault);
    try std.testing.expectError(error.InjectedFault, writePackSync(&driver, 2, next, commit));
    driver.deinit();
    const reopened = try persistence.Store.initIndex(allocator.allocator(), configuration);
    var recovered: FaultDriver = undefined;
    try recovered.init(io, path[0..path_len], reopened, &recovery);
    defer recovered.deinit();
    try expectRecoveredPair(recovered.loader());
    if (!commit) {
        var value: [16]u8 = undefined;
        try std.testing.expectEqualStrings("old-left", try loadValue(recovered.loader(), "left", &value));
        try std.testing.expectEqualStrings("old-right", try loadValue(recovered.loader(), "right", &value));
    }
}

fn writePairPack(driver: anytype, store: *persistence.Store, pack: u32, left: []const u8, right: []const u8) !void {
    const bytes = try preparePair(store, left, right);
    _ = try writePackSync(driver, pack, bytes, true);
    store.markDurableInPack(pack, 0);
    _ = store.complete(1);
}

fn checkpointPair(store: *persistence.Store, left: []const u8, right: []const u8) ![]const u8 {
    const bytes = try preparePair(store, left, right);
    store.markDurableInPack(0, 0);
    _ = store.complete(1);
    return bytes;
}

fn writePackSync(driver: anytype, pack_id: u32, bytes: []const u8, commit: bool) !usize {
    const temporary = try driver.packPath(&driver.path_first, pack_id, true);
    const final = try driver.packPath(&driver.path_second, pack_id, false);
    try driver.failAt(.pack_create);
    const pack = try std.Io.Dir.createFileAbsolute(driver.io, temporary, .{ .read = true });
    defer pack.close(driver.io);
    try driver.failAt(.pack_write);
    try pack.writePositionalAll(driver.io, bytes, 0);
    try driver.failAt(.pack_sync);
    try pack.sync(driver.io);
    try driver.failAt(.pack_rename);
    try std.Io.Dir.renameAbsolute(temporary, final, driver.io);
    try driver.failAt(.pack_parent_sync);
    try syncParent(driver.io, final);
    var next = driver.root;
    try next.append(.{ .id = pack_id, .bytes = bytes.len, .generation = driver.root.generation + 1, .checksum = checksum(bytes) });
    const Publication = root_format.Publication(@typeInfo(@TypeOf(driver.root.entries)).array.len);
    var encoded: [Publication.maximum_bytes]u8 = undefined;
    const publication: Publication = .{ .working = next, .committed = if (commit) next else driver.committed_root };
    const root_bytes = try publication.encode(&encoded);
    const root_temporary = try driver.rootTemporaryPath();
    try driver.failAt(.root_create);
    const root_file = try std.Io.Dir.createFileAbsolute(driver.io, root_temporary, .{ .read = true });
    defer root_file.close(driver.io);
    try driver.failAt(.root_write);
    try root_file.writePositionalAll(driver.io, root_bytes, 0);
    try driver.failAt(.root_sync);
    try root_file.sync(driver.io);
    try driver.failAt(.root_rename);
    try std.Io.Dir.renameAbsolute(root_temporary, driver.root_path, driver.io);
    try driver.failAt(.root_parent_sync);
    try syncParent(driver.io, driver.root_path);
    driver.root_file.close(driver.io);
    driver.root_file = try std.Io.Dir.openFileAbsolute(driver.io, driver.root_path, .{ .mode = .read_write });
    driver.root = next;
    driver.committed_root = publication.committed;
    return bytes.len;
}

fn syncParent(io: std.Io, path: []const u8) !void {
    const parent = std.Io.Dir.path.dirname(path) orelse return error.InvalidRootPath;
    const directory = try std.Io.Dir.openFileAbsolute(io, parent, .{ .mode = .read_only, .allow_directory = true });
    defer directory.close(io);
    try directory.sync(io);
}

fn preparePair(store: *persistence.Store, left: []const u8, right: []const u8) ![]const u8 {
    if (store.stage(.{ .namespace = "n", .key = "left", .operation = .{ .put = left } }) != .ready)
        return error.TestCheckpoint;
    if (store.stage(.{ .namespace = "n", .key = "right", .operation = .{ .put = right } }) != .ready)
        return error.TestCheckpoint;
    if (store.flush() != .pending) return error.TestCheckpoint;
    return store.checkpointBytes();
}

fn expectRecoveredPair(loader: persistence.Loader) !void {
    var left: [16]u8 = undefined;
    var right: [16]u8 = undefined;
    const left_value = try loadValue(loader, "left", &left);
    const right_value = try loadValue(loader, "right", &right);
    const old = std.mem.eql(u8, left_value, "old-left") and std.mem.eql(u8, right_value, "old-right");
    const next = std.mem.eql(u8, left_value, "new-left") and std.mem.eql(u8, right_value, "new-right");
    try std.testing.expect(old or next);
}

fn loadValue(loader: persistence.Loader, key: []const u8, destination: []u8) ![]const u8 {
    return switch (try loader.read("n", key, destination)) {
        .missing => error.MissingTestValue,
        .value => |count| destination[0..count],
    };
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return false;
    file.close(io);
    return true;
}

fn cleanupTestPacks(io: std.Io, root: []const u8) void {
    var path: [256]u8 = undefined;
    for ([_][]const u8{ "", ".lock", ".next", ".pack.1", ".pack.2", ".pack.2.next", ".pack.3", ".pack.3.next", ".pack.03", ".pack.3.bak" }) |suffix| {
        const full = std.fmt.bufPrint(&path, "{s}{s}", .{ root, suffix }) catch continue;
        std.Io.Dir.deleteFileAbsolute(io, full) catch {};
    }
}
