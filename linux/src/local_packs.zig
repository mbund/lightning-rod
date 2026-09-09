const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const persistence = lightning_rod.persistence;
const root_format = @import("local_pack_root.zig");
const runtime = lightning_rod.runtime;

pub const Limits = struct {
    maximum_in_flight_reads: usize,
    maximum_packs: usize,
    maximum_path_bytes: usize,
};

pub fn Driver(comptime limits: Limits) type {
    if (limits.maximum_in_flight_reads == 0) @compileError("local packs needs one read task");
    if (limits.maximum_path_bytes < 32) @compileError("local packs path buffer is too small");
    const Root = root_format.Root(limits.maximum_packs);
    return struct {
        const Self = @This();
        const JobKind = enum { write, read };
        const JobState = enum { free, queued, running, complete };
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
            kind: JobKind = .read,
            bytes: []const u8 = &.{},
            pack: u32 = 0,
            read: persistence.ReadTask = undefined,
            count: usize = 0,
            succeeded: bool = false,
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
            driver: *Self,
            source: *persistence.Store,
            output: *persistence.Store,
            value: []u8,
            captured: Root,
            next: Root,
            cursor: usize = 0,
            copied: usize = 0,

            pub fn init(driver: *Self, source: *persistence.Store, output: *persistence.Store, value: []u8) !Compaction {
                if (!std.meta.eql(driver.store.configuration, source.configuration) or
                    !std.meta.eql(driver.store.configuration, output.configuration))
                    return error.CompactionConfigurationMismatch;
                if (value.len < driver.store.configuration.maximum_value_bytes) return error.ValueScratchTooSmall;
                driver.mutex.lockUncancelable(driver.io);
                defer driver.mutex.unlock(driver.io);
                const captured = driver.root;
                return .{ .driver = driver, .source = source, .output = output, .value = value, .captured = captured, .next = captured.newEpoch() };
            }

            pub fn copyStep(self: *Compaction, limit: usize) !bool {
                if (limit == 0 or limit > self.source.configuration.maximum_keys)
                    return error.InvalidCompactionBudget;
                std.debug.assert(self.copied <= self.source.liveRecords());
                if (self.copied == self.source.liveRecords()) return true;
                var count: usize = 0;
                while (count < limit) : (count += 1) {
                    const live = self.source.nextLive(&self.cursor) orelse return error.CompactionSourceCorrupt;
                    const length: usize = live.location.length;
                    const read = try self.driver.readLocation(live.location, self.value[0..length]);
                    if (read != length) return error.TruncatedPack;
                    if (self.output.stage(.{ .namespace = live.namespace, .key = live.key, .operation = .{ .put = self.value[0..length] } }) != .ready) {
                        try self.flush();
                        if (self.output.stage(.{ .namespace = live.namespace, .key = live.key, .operation = .{ .put = self.value[0..length] } }) != .ready)
                            return error.CompactionStageFailed;
                    }
                    self.copied += 1;
                    if (self.copied == self.source.liveRecords()) return true;
                }
                return false;
            }

            pub fn flush(self: *Compaction) !void {
                if (self.output.stagedRecords() == 0) return;
                if (self.output.beginCheckpoint() != .pending) return error.CompactionEncodeFailed;
                const pack: u32 = @intCast(self.next.next_id);
                const bytes = self.output.checkpointBytes();
                try self.driver.writeUnpublished(pack, bytes);
                try self.next.append(.{ .id = pack, .bytes = bytes.len, .generation = self.next.generation + 1, .checksum = checksum(bytes) });
                self.output.markDurableInPack(pack, 0);
                _ = self.output.complete(1);
            }

            pub fn publish(self: *Compaction) !void {
                try self.flush();
                try self.driver.publishEpoch(self.captured, self.next);
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
        };
        const MaintenanceState = enum { idle, requested, recover, copy, publish, install, reclaim };

        io: std.Io,
        root_file: std.Io.File,
        root_path: []const u8,
        store: *persistence.Store,
        root: Root = Root.init(),
        retired_root: ?Root = null,
        path_first: [limits.maximum_path_bytes]u8 = undefined,
        path_second: [limits.maximum_path_bytes]u8 = undefined,
        path_root: [limits.maximum_path_bytes]u8 = undefined,
        mutex: std.Io.Mutex = .init,
        wake: std.Io.Condition = .init,
        runtime_wake: ?runtime.Wake = null,
        worker: ?std.Thread = null,
        jobs: [limits.maximum_in_flight_reads + 1]Job = @splat(.{}),
        read_staging: [limits.maximum_in_flight_reads]persistence.ReadTask = undefined,
        stopping: bool = false,
        write_queued: bool = false,
        shutdown: bool = false,
        failed: bool = false,
        maintenance_requested: bool = false,
        maintenance: ?Maintenance = null,
        maintenance_state: MaintenanceState = .idle,
        foreground_jobs_since_maintenance: u8 = 0,
        test_fault: if (builtin.is_test) ?TestFault else void = if (builtin.is_test) null else {},

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
            root_file: std.Io.File,
            root_path: []const u8,
            store: *persistence.Store,
            recovery: []u8,
        ) !void {
            if (root_path.len == 0 or root_path.len >= limits.maximum_path_bytes) return error.InvalidRootPath;
            try validateCompactionCapacity(store.configuration);
            self.* = .{ .io = io, .root_file = root_file, .root_path = root_path, .store = store };
            errdefer self.root_file.close(io);
            try store.bindCheckpointGate(self, checkpointAdmission);
            try store.bindReadGate(self, readAdmission);
            try self.recover(recovery);
            self.mutex.lockUncancelable(self.io);
            if (@as(usize, self.root.count) + 1 >= limits.maximum_packs) self.requestMaintenanceLocked();
            self.mutex.unlock(self.io);
            self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
        }

        pub fn loader(self: *Self) persistence.Loader {
            return .{ .context = self, .read_fn = load };
        }

        pub fn interface(self: *Self) runtime.Backend {
            return .{ .context = self, .vtable = &vtable, .readiness = .{ .context = self, .bind_fn = bindReadiness } };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            self.wake.broadcast(self.io);
            self.mutex.unlock(self.io);
            if (self.worker) |worker| worker.join();
            self.root_file.close(self.io);
            self.* = undefined;
        }

        pub fn configureMaintenance(self: *Self, source: *persistence.Store, output: *persistence.Store, value: []u8, recovery: []u8) !void {
            try validateCompactionCapacity(self.store.configuration);
            _ = try Compaction.init(self, source, output, value);
            if (recovery.len < try persistence.maximumCheckpointBytes(self.store.configuration)) return error.RecoveryCapacity;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.maintenance != null or self.maintenance_state != .idle) return error.MaintenanceBusy;
            self.maintenance = .{ .source = source, .output = output, .value = value, .recovery = recovery };
        }

        pub fn setTestFault(self: *Self, fault: ?TestFault) void {
            if (comptime builtin.is_test) {
                self.test_fault = fault;
            }
        }

        fn recover(self: *Self, recovery: []u8) !void {
            if (recovery.len < try persistence.maximumCheckpointBytes(self.store.configuration)) return error.RecoveryCapacity;
            const stat = try self.root_file.stat(self.io);
            if (stat.size == 0) {
                self.store.beginRecovery();
                return;
            }
            if (stat.size > Root.maximum_bytes) return error.RootTooLarge;
            const root_length: usize = @intCast(stat.size);
            var root_bytes: [Root.maximum_bytes]u8 = undefined;
            const count = try self.root_file.readPositionalAll(self.io, root_bytes[0..root_length], 0);
            if (count != root_length) return error.TruncatedRoot;
            self.root = try Root.decode(root_bytes[0..count]);
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
        }

        fn load(context: *anyopaque, namespace: []const u8, key: []const u8, destination: []u8) persistence.LoadError!persistence.LoadResult {
            const self: *Self = @ptrCast(@alignCast(context));
            const location = self.store.startupLocation(namespace, key) orelse return .missing;
            if (destination.len < location.length) return error.DestinationTooSmall;
            const count = self.readLocation(location, destination[0..location.length]) catch return error.ReadFailed;
            if (count != location.length) return error.Corrupt;
            return .{ .value = count };
        }

        fn backendComplete(context: *anyopaque, _: std.Io, limit: usize) runtime.Completion {
            const self: *Self = @ptrCast(@alignCast(context));
            var completed: usize = 0;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.failed) self.store.markFailed();
            for (&self.jobs) |*job| {
                if (completed == limit) break;
                if (job.state != .complete) continue;
                if (!job.succeeded) {
                    self.failed = true;
                    self.store.markFailed();
                } else switch (job.kind) {
                    .write => {
                        self.store.markDurableInPack(job.pack, 0);
                        _ = self.store.complete(1);
                        self.write_queued = false;
                        if (@as(usize, self.root.count) + 2 >= limits.maximum_packs) self.requestMaintenanceLocked();
                    },
                    .read => self.store.completeRead(job.read.request, job.read.destination[0..job.count]) catch {
                        self.failed = true;
                        self.store.markFailed();
                    },
                }
                job.* = .{};
                completed += 1;
            }
            self.startMaintenanceLocked();
            self.installCompactedIndexLocked();
            return .{ .count = completed, .outcome = if (self.failed or self.store.poisoned()) .failed else .ok };
        }

        fn backendSubmit(context: *anyopaque, _: std.Io) runtime.Outcome {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.failed or self.store.poisoned()) return .failed;
            if (!self.write_queued) {
                const bytes = self.store.checkpointBytes();
                if (bytes.len != 0) {
                    if (@as(usize, self.root.count) == limits.maximum_packs or self.root.next_id > std.math.maxInt(u32) - 1) return .failed;
                    const job = self.freeJobLocked() orelse return .ok;
                    job.* = .{ .state = .queued, .kind = .write, .bytes = bytes, .pack = @intCast(self.root.next_id) };
                    self.write_queued = true;
                    self.wake.signal(self.io);
                }
            }
            const vacant = self.freeReadCountLocked();
            const count = self.store.takeReadTasks(self.read_staging[0..vacant]);
            for (self.read_staging[0..count]) |task| {
                const job = self.freeJobLocked() orelse unreachable;
                job.* = .{ .state = .queued, .kind = .read, .read = task };
            }
            if (count != 0) self.wake.broadcast(self.io);
            return .ok;
        }

        fn beginShutdown(context: *anyopaque, _: std.Io) runtime.Outcome {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.shutdown = true;
            return if (self.failed or self.store.poisoned()) .failed else .ok;
        }

        fn shutdownProgress(context: *anyopaque) runtime.Progress {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.failed or self.store.poisoned()) return .failed;
            if (!self.shutdown) return .pending;
            for (self.jobs) |job| if (job.state != .free) return .pending;
            return switch (self.store.checkpointProgress()) {
                .ready => .complete,
                .failed => .failed,
                else => .pending,
            };
        }

        fn workerMain(self: *Self) void {
            std.debug.assert(self.jobs.len == limits.maximum_in_flight_reads + 1);
            std.debug.assert(self.read_staging.len == limits.maximum_in_flight_reads);
            while (true) {
                self.mutex.lockUncancelable(self.io);
                while (!self.stopping and self.nextQueuedLocked() == null and !self.maintenanceRunnableLocked()) self.wake.waitUncancelable(self.io, &self.mutex);
                if (self.stopping and self.nextQueuedLocked() == null and !self.maintenanceRunnableLocked()) {
                    self.mutex.unlock(self.io);
                    return;
                }
                const queued = self.nextQueuedLocked();
                if (self.maintenanceRunnableLocked() and
                    (queued == null or self.foreground_jobs_since_maintenance >= 32))
                {
                    self.foreground_jobs_since_maintenance = 0;
                    self.mutex.unlock(self.io);
                    self.runMaintenanceStep() catch self.failMaintenance();
                    continue;
                }
                const job = &self.jobs[queued.?];
                job.state = .running;
                self.foreground_jobs_since_maintenance +|= 1;
                self.mutex.unlock(self.io);
                const result = switch (job.kind) {
                    .write => self.writePack(job.pack, job.bytes),
                    .read => self.readLocation(job.read.location, job.read.destination),
                } catch 0;
                self.mutex.lockUncancelable(self.io);
                job.count = result;
                job.succeeded = switch (job.kind) {
                    .write => result == job.bytes.len,
                    .read => result == @as(usize, job.read.location.length),
                };
                job.state = .complete;
                const runtime_wake = self.runtime_wake;
                self.mutex.unlock(self.io);
                if (runtime_wake) |wake| wake.signal();
            }
        }

        fn writePack(self: *Self, pack_id: u32, bytes: []const u8) !usize {
            try self.writeUnpublished(pack_id, bytes);
            try self.publish(pack_id, bytes);
            return bytes.len;
        }

        fn writeUnpublished(self: *Self, pack_id: u32, bytes: []const u8) !void {
            const temporary = try self.packPath(&self.path_first, pack_id, true);
            const final = try self.packPath(&self.path_second, pack_id, false);
            try self.failAt(.pack_create);
            const pack = try std.Io.Dir.createFileAbsolute(self.io, temporary, .{ .read = true });
            defer pack.close(self.io);
            try self.failAt(.pack_write);
            try pack.writePositionalAll(self.io, bytes, 0);
            try self.failAt(.pack_sync);
            try pack.sync(self.io);
            try self.failAt(.pack_rename);
            try std.Io.Dir.renameAbsolute(temporary, final, self.io);
            try self.failAt(.pack_parent_sync);
            try self.syncParent(final);
        }

        fn publish(self: *Self, pack_id: u32, bytes: []const u8) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var next = self.root;
            try next.append(.{ .id = pack_id, .bytes = bytes.len, .generation = self.root.generation + 1, .checksum = checksum(bytes) });
            try self.publishRoot(next);
        }

        fn publishRoot(self: *Self, next: Root) !void {
            var encoded: [Root.maximum_bytes]u8 = undefined;
            const root_bytes = try next.encode(&encoded);
            const temporary = try self.rootPath(true);
            try self.failAt(.root_create);
            const file = try std.Io.Dir.createFileAbsolute(self.io, temporary, .{ .read = true });
            defer file.close(self.io);
            try self.failAt(.root_write);
            try file.writePositionalAll(self.io, root_bytes, 0);
            try self.failAt(.root_sync);
            try file.sync(self.io);
            try self.failAt(.root_rename);
            try std.Io.Dir.renameAbsolute(temporary, self.root_path, self.io);
            try self.failAt(.root_parent_sync);
            try self.syncParent(self.root_path);
            self.root_file.close(self.io);
            self.root_file = try std.Io.Dir.openFileAbsolute(self.io, self.root_path, .{ .mode = .read_write });
            self.root = next;
        }

        fn publishEpoch(self: *Self, captured: Root, next: Root) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.root.generation != captured.generation) return error.EpochChanged;
            try self.publishRoot(next);
            self.retired_root = captured;
        }

        fn readLocation(self: *Self, location: persistence.Location, destination: []u8) !usize {
            if (location.pack == 0 or !self.rootContains(location.pack)) return error.UnknownPack;
            const path = try self.packPath(&self.path_first, location.pack, false);
            const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only });
            defer file.close(self.io);
            return file.readPositionalAll(self.io, destination[0..@as(usize, location.length)], location.offset);
        }

        fn rootContains(self: *const Self, pack: u32) bool {
            for (self.root.slice()) |entry| if (entry.id == pack) return true;
            if (self.retired_root) |root| for (root.slice()) |entry| if (entry.id == pack) return true;
            return false;
        }

        fn requestMaintenanceLocked(self: *Self) void {
            self.maintenance_requested = true;
            if (self.maintenance_state == .idle) self.maintenance_state = .requested;
            self.wake.signal(self.io);
        }

        fn startMaintenanceLocked(self: *Self) void {
            if (!self.maintenance_requested or self.write_queued) return;
            if (self.maintenance_state != .requested) return;
            if (!self.store.epochSwitchReady()) return;
            const maintenance = &(self.maintenance orelse return);
            maintenance.captured = self.root;
            maintenance.source.beginRecovery();
            maintenance.output.beginRecovery();
            maintenance.compaction = null;
            maintenance.rebuild_index = 0;
            maintenance.reclaim_index = 0;
            self.maintenance_state = .recover;
            self.wake.signal(self.io);
        }

        fn maintenanceRunnableLocked(self: *const Self) bool {
            return switch (self.maintenance_state) {
                .recover, .copy, .publish, .reclaim => true,
                .idle, .requested, .install => false,
            };
        }

        fn installCompactedIndexLocked(self: *Self) void {
            if (self.maintenance_state != .install) return;
            if (!self.store.epochSwitchReady()) return;
            const maintenance = &(self.maintenance orelse {
                self.failed = true;
                self.store.markFailed();
                return;
            });
            const compacted = &(maintenance.compaction orelse {
                self.failed = true;
                self.store.markFailed();
                return;
            });
            self.store.installCompactedIndex(compacted.output) catch {
                self.failed = true;
                self.store.markFailed();
                return;
            };
            maintenance.reclaim_index = 0;
            self.maintenance_state = .reclaim;
            self.wake.signal(self.io);
        }

        fn runMaintenanceStep(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            const state = self.maintenance_state;
            self.mutex.unlock(self.io);
            switch (state) {
                .recover => try self.recoverCompactionStep(),
                .copy => try self.copyCompactionStep(),
                .publish => try self.publishCompaction(),
                .reclaim => try self.reclaimCompactionStep(),
                .idle, .requested, .install => {},
            }
        }

        fn recoverCompactionStep(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            const maintenance = &(self.maintenance orelse {
                self.mutex.unlock(self.io);
                return error.MaintenanceUnavailable;
            });
            if (maintenance.rebuild_index == maintenance.captured.count) {
                maintenance.rebuild_index = 0;
                const source = maintenance.source;
                const output = maintenance.output;
                const value = maintenance.value;
                self.mutex.unlock(self.io);
                const compaction = try Compaction.init(self, source, output, value);
                self.mutex.lockUncancelable(self.io);
                maintenance.compaction = compaction;
                self.maintenance_state = .copy;
                self.mutex.unlock(self.io);
                return;
            }
            const entry = maintenance.captured.entries[maintenance.rebuild_index];
            try self.recoverPack(maintenance.source, entry, maintenance.recovery);
            maintenance.rebuild_index += 1;
            self.mutex.unlock(self.io);
        }

        fn copyCompactionStep(self: *Self) !void {
            const maintenance = &(self.maintenance orelse return error.MaintenanceUnavailable);
            const compaction = &(maintenance.compaction orelse return error.MaintenanceUnavailable);
            const limit = @min(@as(usize, 32), self.store.configuration.maximum_keys);
            if (try compaction.copyStep(limit)) self.maintenance_state = .publish;
        }

        fn publishCompaction(self: *Self) !void {
            const maintenance = &(self.maintenance orelse return error.MaintenanceUnavailable);
            const compaction = &(maintenance.compaction orelse return error.MaintenanceUnavailable);
            try compaction.publish();
            self.mutex.lockUncancelable(self.io);
            self.maintenance_state = .install;
            const runtime_wake = self.runtime_wake;
            self.mutex.unlock(self.io);
            if (runtime_wake) |wake| wake.signal();
        }

        fn reclaimCompactionStep(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const retired = self.retired_root orelse return error.EpochSwitchBusy;
            const maintenance = &(self.maintenance orelse return error.MaintenanceUnavailable);
            if (maintenance.reclaim_index == retired.count) {
                self.retired_root = null;
                self.maintenance_requested = false;
                self.maintenance_state = .idle;
                maintenance.compaction = null;
                return;
            }
            const entry = retired.entries[maintenance.reclaim_index];
            const path = try self.packPath(&self.path_second, entry.id, false);
            try std.Io.Dir.deleteFileAbsolute(self.io, path);
            try self.syncParent(path);
            maintenance.reclaim_index += 1;
            if (maintenance.reclaim_index != retired.count) return;
            self.retired_root = null;
            self.maintenance_requested = false;
            self.maintenance_state = .idle;
            maintenance.compaction = null;
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
            self.mutex.lockUncancelable(self.io);
            self.failed = true;
            self.mutex.unlock(self.io);
            if (self.runtime_wake) |wake| wake.signal();
        }

        fn syncParent(self: *Self, path: []const u8) !void {
            const parent = std.Io.Dir.path.dirname(path) orelse return error.InvalidRootPath;
            const directory = try std.Io.Dir.openFileAbsolute(self.io, parent, .{ .mode = .read_only, .allow_directory = true });
            defer directory.close(self.io);
            try directory.sync(self.io);
        }

        inline fn failAt(self: *Self, boundary: TestFault) !void {
            if (comptime builtin.is_test) {
                if (self.test_fault != boundary) return;
                self.test_fault = null;
                return error.InjectedFault;
            }
        }

        fn validateCompactionCapacity(configuration: persistence.Configuration) !void {
            const quotient = configuration.maximum_keys / configuration.maximum_checkpoint_records;
            const remainder = configuration.maximum_keys % configuration.maximum_checkpoint_records;
            const output_packs = quotient + @intFromBool(remainder != 0);
            if (output_packs >= limits.maximum_packs) return error.CompactionPackCapacity;
        }

        fn checkpointAdmission(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return !self.maintenance_requested and !self.failed;
        }

        fn readAdmission(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.maintenance_state != .install and !self.failed;
        }

        fn packPath(self: *const Self, storage: *[limits.maximum_path_bytes]u8, id: u64, temporary: bool) ![]const u8 {
            const suffix = if (temporary) ".next" else "";
            return std.fmt.bufPrint(storage, "{s}.pack.{d}{s}", .{ self.root_path, id, suffix });
        }

        fn rootPath(self: *Self, temporary: bool) ![]const u8 {
            if (!temporary) return self.root_path;
            return std.fmt.bufPrint(&self.path_root, "{s}.next", .{self.root_path});
        }

        fn bindReadiness(context: *anyopaque, wake: runtime.Wake) runtime.Outcome {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.runtime_wake != null) return .failed;
            self.runtime_wake = wake;
            return .ok;
        }
        fn nextQueuedLocked(self: *Self) ?usize {
            for (self.jobs, 0..) |job, index| if (job.state == .queued) return index;
            return null;
        }
        fn freeJobLocked(self: *Self) ?*Job {
            for (&self.jobs) |*job| if (job.state == .free) return job;
            return null;
        }
        fn freeReadCountLocked(self: *Self) usize {
            var count: usize = 0;
            for (self.jobs) |job| {
                if (job.state == .free) count += 1;
            }
            return @min(count, limits.maximum_in_flight_reads);
        }

        const vtable: runtime.Backend.VTable = .{
            .complete = backendComplete,
            .submit = backendSubmit,
            .begin_shutdown = beginShutdown,
            .shutdown_progress = shutdownProgress,
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
    for ([_]FaultDriver.TestFault{ .pack_create, .pack_write, .pack_sync, .pack_rename, .pack_parent_sync, .root_create, .root_write, .root_sync, .root_rename, .root_parent_sync }) |fault|
        try restartAfterFault(fault);
}

test "compaction retires packs only after root publication and installs in one step" {
    const configuration: persistence.Configuration = .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 16,
    };
    var memory: [128 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    const live = try persistence.Store.initIndex(allocator.allocator(), configuration);
    const source = try persistence.Store.initIndex(allocator.allocator(), configuration);
    const output = try persistence.Store.initIndex(allocator.allocator(), configuration);
    var path: [256]u8 = undefined;
    var recovery: [128]u8 = undefined;
    var value: [16]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, "local-packs-compaction-test.root", .{ .read = true, .truncate = true });
    const path_len = try file.realPath(io, &path);
    defer cleanupTestPacks(io, path[0..path_len]);
    var driver: FaultDriver = .{ .io = io, .root_file = file, .root_path = path[0..path_len], .store = live };
    defer driver.root_file.close(io);
    try writePairPack(&driver, live, 1, "old-left", "old-right");
    try writePairPack(&driver, live, 2, "new-left", "new-right");
    try driver.recoverPack(source, driver.root.entries[0], &recovery);
    try driver.recoverPack(source, driver.root.entries[1], &recovery);
    var compaction = try FaultDriver.Compaction.init(&driver, source, output, &value);
    try std.testing.expectError(
        error.InvalidCompactionBudget,
        compaction.copyStep(source.configuration.maximum_keys + 1),
    );
    try std.testing.expect(try compaction.copyStep(source.configuration.maximum_keys));
    driver.setTestFault(.root_parent_sync);
    try std.testing.expectError(error.InjectedFault, compaction.publish());
    try std.testing.expect(driver.retired_root == null);
    try std.testing.expect(try fileExists(io, try driver.packPath(&driver.path_first, 1, false)));
    try std.testing.expect(try fileExists(io, try driver.packPath(&driver.path_first, 2, false)));
    try compaction.publish();
    try std.testing.expectEqual(@as(u16, 1), driver.root.count);
    try std.testing.expectEqual(@as(u64, 3), driver.root.entries[0].id);
    try std.testing.expectEqual(@as(u16, 2), driver.retired_root.?.count);
    driver.maintenance = .{ .source = source, .output = output, .value = &value, .recovery = &recovery, .compaction = compaction };
    driver.maintenance_state = .install;
    driver.installCompactedIndexLocked();
    try std.testing.expectEqual(.reclaim, driver.maintenance_state);
    try std.testing.expectEqual(@as(u32, 3), live.startupLocation("n", "left").?.pack);
    try std.testing.expect(try fileExists(io, try driver.packPath(&driver.path_first, 1, false)));
    try driver.reclaimCompactionStep();
    try std.testing.expect(!(try fileExists(io, try driver.packPath(&driver.path_first, 1, false))));
    try std.testing.expect(try fileExists(io, try driver.packPath(&driver.path_first, 2, false)));
    try driver.reclaimCompactionStep();
    try std.testing.expect(driver.retired_root == null);
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
    };
    var memory: [32 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    const store = try persistence.Store.initIndex(allocator.allocator(), configuration);
    var path: [256]u8 = undefined;
    var recovery: [128]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, "local-packs-capacity-test.root", .{ .read = true, .truncate = true });
    const path_len = try file.realPath(io, &path);
    defer cleanupTestPacks(io, path[0..path_len]);
    var driver: Small = undefined;
    try std.testing.expectError(error.CompactionPackCapacity, driver.init(io, file, path[0..path_len], store, &recovery));
    file.close(io);
}

fn restartAfterFault(fault: FaultDriver.TestFault) !void {
    const configuration: persistence.Configuration = .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 16,
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
    defer cleanupTestPacks(io, path[0..path_len]);
    var driver: FaultDriver = undefined;
    try driver.init(io, file, path[0..path_len], source, &recovery);
    _ = try driver.writePack(1, old_bytes);
    driver.setTestFault(fault);
    try std.testing.expectError(error.InjectedFault, driver.writePack(2, next));
    driver.deinit();
    const reopened = try persistence.Store.initIndex(allocator.allocator(), configuration);
    const root = try std.Io.Dir.openFileAbsolute(io, path[0..path_len], .{ .mode = .read_write });
    var recovered: FaultDriver = undefined;
    try recovered.init(io, root, path[0..path_len], reopened, &recovery);
    defer recovered.deinit();
    try expectRecoveredPair(recovered.loader());
}

fn writePairPack(driver: *FaultDriver, store: *persistence.Store, pack: u32, left: []const u8, right: []const u8) !void {
    const bytes = try preparePair(store, left, right);
    _ = try driver.writePack(pack, bytes);
    store.markDurableInPack(pack, 0);
    _ = store.complete(1);
}

fn checkpointPair(store: *persistence.Store, left: []const u8, right: []const u8) ![]const u8 {
    const bytes = try preparePair(store, left, right);
    store.markDurableInPack(0, 0);
    _ = store.complete(1);
    return bytes;
}

fn preparePair(store: *persistence.Store, left: []const u8, right: []const u8) ![]const u8 {
    if (store.stage(.{ .namespace = "n", .key = "left", .operation = .{ .put = left } }) != .ready)
        return error.TestCheckpoint;
    if (store.stage(.{ .namespace = "n", .key = "right", .operation = .{ .put = right } }) != .ready)
        return error.TestCheckpoint;
    if (store.beginCheckpoint() != .pending) return error.TestCheckpoint;
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
    for ([_][]const u8{ "", ".next", ".pack.1", ".pack.2", ".pack.2.next", ".pack.3", ".pack.3.next" }) |suffix| {
        const full = std.fmt.bufPrint(&path, "{s}{s}", .{ root, suffix }) catch continue;
        std.Io.Dir.deleteFileAbsolute(io, full) catch {};
    }
}
