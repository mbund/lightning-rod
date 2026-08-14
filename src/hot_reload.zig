const std = @import("std");
const abi = @import("hot_reload_abi.zig");
const reload_memory = @import("reload_memory.zig");
const posix = std.posix;

const maximum_module_bytes = 256 * 1024 * 1024;
const image_copy_bytes = 16 * 1024 * 1024;

pub const Manager = struct {
    const Self = @This();

    module_path: []const u8,
    state_arena: reload_memory.Arena,
    storage_mode: abi.StorageMode,
    next_generation: u64 = 1,
    active: ?Generation = null,
    profiling_enabled: bool = false,
    pending: ?Generation = null,

    const Generation = struct {
        number: u64,
        library: ReloadLibrary,
        functions: Functions,
        descriptor: abi.Descriptor,
        state: ?reload_memory.Arena.Region,
    };

    const Functions = struct {
        initialize: abi.InitializeFn,
        tick: abi.TickFn,
        save: abi.SaveFn,
        load: abi.LoadFn,
        begin_reconfiguration: abi.BeginReconfigurationFn,
        deinitialize: abi.DeinitializeFn,
        set_profiling: abi.SetProfilingFn,
        metrics: abi.MetricsFn,
    };

    pub fn init(
        io: std.Io,
        module_path: []const u8,
        virtual_bytes: usize,
        storage_mode: abi.StorageMode,
    ) !Self {
        _ = io;
        return .{
            .module_path = module_path,
            .state_arena = try reload_memory.Arena.init(virtual_bytes),
            .storage_mode = storage_mode,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.pending) |*generation|
            self.abandonCandidate(generation, generation.state != null);
        if (self.active) |*generation| self.destroyGeneration(generation) catch {};
        self.state_arena.deinit();
        self.* = undefined;
    }

    pub fn loadInitial(self: *Self, reactor_memory_bytes: usize) !void {
        std.debug.assert(self.active == null);
        var candidate = try self.loadLibraryGeneration();
        var initialized = false;
        errdefer self.abandonCandidate(&candidate, initialized);
        try self.initializeGeneration(&candidate, reactor_memory_bytes);
        initialized = true;
        try validateGenerationMemory(&candidate, reactor_memory_bytes);
        try setGenerationProfiling(&candidate, self.profiling_enabled);
        try lifecycle(candidate.functions.load, &candidate);
        self.active = candidate;
    }

    pub fn tick(self: *Self, invocation: *const abi.TickInvocation) !void {
        const generation = if (self.active) |*value| value else return error.TickModuleNotLoaded;
        const status = generation.functions.tick(generation.state.?.bytes.ptr, invocation);
        if (status != .ok) return statusError(status);
    }

    fn beginReload(self: *Self, required_protocols: []const i32) !void {
        if (self.pending != null) return error.TickModuleReloadAlreadyPending;
        const started_ns = monotonicNanoseconds();
        var candidate = try self.loadLibraryGeneration();
        const loaded_ns = monotonicNanoseconds();
        errdefer self.abandonCandidate(&candidate, false);
        if (self.active) |active| {
            if (@intFromPtr(active.functions.tick) == @intFromPtr(candidate.functions.tick))
                return error.TickModuleImageReused;
        }
        for (required_protocols) |protocol_number| {
            if (!descriptorSupportsProtocol(&candidate.descriptor, protocol_number))
                return error.TickModuleMissingConnectedProtocol;
        }
        self.pending = candidate;
        std.log.info(
            "event=tick_module_prepared image_ms={d:.3}",
            .{milliseconds(loaded_ns - started_ns)},
        );
    }

    pub fn prepareReload(
        self: *Self,
        required_protocols: []const i32,
    ) !void {
        try self.beginReload(required_protocols);
    }

    pub fn save(self: *Self) !void {
        const generation = if (self.active) |*value| value else return error.TickModuleNotLoaded;
        const started_ns = monotonicNanoseconds();
        try lifecycle(generation.functions.save, generation);
        const completed_ns = monotonicNanoseconds();
        std.log.info("event=tick_module_save_complete elapsed_ms={d:.3}", .{
            milliseconds(completed_ns - started_ns),
        });
    }

    pub fn beginReconfiguration(self: *Self, exchange: *abi.TickExchange) !void {
        const generation = if (self.active) |*value| value else return error.TickModuleNotLoaded;
        const status = generation.functions.begin_reconfiguration(
            generation.state.?.bytes.ptr,
            exchange,
        );
        if (status != .ok) return statusError(status);
    }

    pub fn transitionPreparedReload(
        self: *Self,
        reactor_memory_bytes: usize,
        rollback_reactor_memory_bytes: usize,
    ) !void {
        var candidate = self.pending orelse return error.TickModuleReloadNotPending;
        var previous = self.active orelse return error.TickModuleNotLoaded;
        self.pending = null;
        const started_ns = monotonicNanoseconds();
        self.retireGenerationState(&previous);
        const retired_ns = monotonicNanoseconds();
        self.initializeAndLoad(&candidate, reactor_memory_bytes) catch |candidate_error| {
            self.abandonCandidate(&candidate, candidate.state != null);
            self.restorePrevious(&previous, rollback_reactor_memory_bytes) catch {
                self.closeLibrary(&previous);
                self.active = null;
                return error.TickModuleRollbackFailed;
            };
            self.active = previous;
            return candidate_error;
        };
        const initialized_ns = monotonicNanoseconds();
        self.closeLibrary(&previous);
        self.active = candidate;
        const completed_ns = monotonicNanoseconds();
        std.log.info(
            "event=tick_module_activated retire_ms={d:.3} initialize_restore_ms={d:.3} unload_ms={d:.3}",
            .{
                milliseconds(retired_ns - started_ns),
                milliseconds(initialized_ns - retired_ns),
                milliseconds(completed_ns - initialized_ns),
            },
        );
    }

    fn initializeAndLoad(
        self: *Self,
        generation: *Generation,
        reactor_memory_bytes: usize,
    ) !void {
        try self.initializeGeneration(generation, reactor_memory_bytes);
        errdefer {
            _ = deinitializeGeneration(generation);
            if (generation.state) |state| self.state_arena.retire(state) catch {};
            generation.state = null;
        }
        try validateGenerationMemory(generation, reactor_memory_bytes);
        try setGenerationProfiling(generation, self.profiling_enabled);
        try lifecycle(generation.functions.load, generation);
    }

    fn restorePrevious(
        self: *Self,
        generation: *Generation,
        reactor_memory_bytes: usize,
    ) !void {
        try self.initializeAndLoad(generation, reactor_memory_bytes);
        std.log.warn("event=tick_module_reload_rolled_back generation={}", .{generation.number});
    }

    pub fn cancelPendingReload(self: *Self) void {
        if (self.pending) |*candidate|
            self.abandonCandidate(candidate, candidate.state != null);
        self.pending = null;
    }

    pub fn activeGenerationNumber(self: *const Self) u64 {
        return if (self.active) |active| active.number else 0;
    }

    pub fn supportsProtocol(self: *const Self, protocol_number: i32) bool {
        const generation = self.active orelse return false;
        return descriptorSupportsProtocol(&generation.descriptor, protocol_number);
    }

    pub fn pendingSupportsProtocol(self: *const Self, protocol_number: i32) bool {
        const generation = self.pending orelse return false;
        return descriptorSupportsProtocol(&generation.descriptor, protocol_number);
    }

    pub fn pendingMaximumPlayers(self: *const Self) usize {
        return if (self.pending) |generation| generation.descriptor.maximum_players else 0;
    }

    pub fn generationMemoryBytes(self: *const Self) usize {
        const generation = self.active orelse return 0;
        return if (generation.state) |state| state.mapped.len else 0;
    }

    pub fn maximumMemoryBytes(self: *const Self) usize {
        return if (self.active) |generation|
            generation.descriptor.maximum_memory_bytes
        else
            0;
    }

    pub fn validateActiveMemory(self: *const Self, reactor_memory_bytes: usize) !void {
        const generation = self.active orelse return error.TickModuleNotLoaded;
        try validateGenerationMemory(&generation, reactor_memory_bytes);
    }

    pub fn pendingMaximumMemoryBytes(self: *const Self) usize {
        return if (self.pending) |generation|
            generation.descriptor.maximum_memory_bytes
        else
            0;
    }

    pub fn setProfilingEnabled(self: *Self, enabled: bool) void {
        self.profiling_enabled = enabled;
        if (self.active) |*generation|
            setGenerationProfiling(generation, enabled) catch |err|
                std.log.err("event=tick_module_profiling_failed err={}", .{err});
    }

    pub fn metricsSnapshot(self: *const Self) abi.MetricsSnapshot {
        var snapshot: abi.MetricsSnapshot = .{};
        if (self.active) |generation| {
            generation.functions.metrics(generation.state.?.bytes.ptr, &snapshot);
        }
        return snapshot;
    }

    pub fn supportedProtocols(self: *const Self) []const i32 {
        const generation = self.active orelse return &.{};
        return generation.descriptor.supported_protocols[0..generation.descriptor.supported_protocol_count];
    }

    pub fn maximumPlayers(self: *const Self) u32 {
        return if (self.active) |generation| generation.descriptor.maximum_players else 0;
    }

    pub fn defaultGamemode(self: *const Self) u8 {
        return if (self.active) |generation| generation.descriptor.default_gamemode else 0;
    }

    fn loadLibraryGeneration(self: *Self) !Generation {
        const number = self.next_generation;
        if (number == std.math.maxInt(u64)) return error.TickModuleGenerationExhausted;
        self.next_generation = number + 1;
        var library = try ReloadLibrary.open(self.module_path, number);
        errdefer library.close();
        const describe = library.lookup(abi.DescribeFn, abi.Symbol.describe) orelse
            return error.MissingTickModuleDescribe;
        const functions = Functions{
            .initialize = library.lookup(abi.InitializeFn, abi.Symbol.initialize) orelse return error.MissingTickModuleInitialize,
            .tick = library.lookup(abi.TickFn, abi.Symbol.tick) orelse return error.MissingTickModuleTick,
            .save = library.lookup(abi.SaveFn, abi.Symbol.save) orelse return error.MissingTickModuleSave,
            .load = library.lookup(abi.LoadFn, abi.Symbol.load) orelse return error.MissingTickModuleLoad,
            .begin_reconfiguration = library.lookup(abi.BeginReconfigurationFn, abi.Symbol.begin_reconfiguration) orelse return error.MissingTickModuleBeginReconfiguration,
            .deinitialize = library.lookup(abi.DeinitializeFn, abi.Symbol.deinitialize) orelse return error.MissingTickModuleDeinitialize,
            .set_profiling = library.lookup(abi.SetProfilingFn, abi.Symbol.set_profiling) orelse return error.MissingTickModuleProfiling,
            .metrics = library.lookup(abi.MetricsFn, abi.Symbol.metrics) orelse return error.MissingTickModuleMetrics,
        };
        const module_descriptor = describe();
        const descriptor = module_descriptor.*;
        try validateDescriptor(&descriptor);
        std.log.info("event=tick_module_loaded generation={} path={s}", .{ number, self.module_path });
        return .{
            .number = number,
            .library = library,
            .functions = functions,
            .descriptor = descriptor,
            .state = null,
        };
    }

    fn validateDescriptor(descriptor: *const abi.Descriptor) !void {
        if (!descriptor.header.supports(abi.descriptor_size)) {
            std.log.err(
                "event=tick_module_abi_mismatch expected_size={} actual_size={} expected_major={} actual_major={} actual_minor={}",
                .{ abi.descriptor_size, descriptor.header.size, abi.major_version, descriptor.header.major, descriptor.header.minor },
            );
            return error.TickModuleAbiVersionMismatch;
        }
        const supported_kernel_capabilities =
            abi.KernelCapability.output_leases |
            abi.KernelCapability.entropy |
            abi.KernelCapability.wire_transport;
        if (descriptor.required_kernel_capabilities & ~supported_kernel_capabilities != 0)
            return error.TickModuleRequiresUnsupportedKernelCapabilities;
        if (!std.mem.allEqual(u8, &descriptor._descriptor_reserved, 0))
            return error.InvalidTickModuleDescriptorReservedBytes;
        if (!std.mem.allEqual(u8, &descriptor._configuration_reserved, 0))
            return error.InvalidTickModuleDescriptorReservedBytes;
        if (descriptor.maximum_players == 0) return error.InvalidTickModuleMaximumPlayers;
        if (descriptor.default_gamemode > 3) return error.InvalidTickModuleDefaultGamemode;
        if (descriptor.state_size == 0 or descriptor.state_alignment == 0 or !std.math.isPowerOfTwo(descriptor.state_alignment))
            return error.InvalidModuleStateLayout;
        if (descriptor.state_capacity < descriptor.state_size)
            return error.InvalidModuleStateLayout;
        if (descriptor.maximum_memory_bytes == 0)
            return error.InvalidTickModuleMemoryMaximum;
        if (descriptor.supported_protocol_count == 0) return error.TickModuleHasNoProtocols;
        const protocols = descriptor.supported_protocols[0..descriptor.supported_protocol_count];
        for (protocols, 0..) |protocol_number, index| {
            for (protocols[index + 1 ..]) |other|
                if (protocol_number == other) return error.TickModuleHasDuplicateProtocol;
        }
    }

    fn abandonCandidate(self: *Self, candidate: *Generation, initialized: bool) void {
        if (initialized and candidate.state != null and
            deinitializeGeneration(candidate) != .ok)
            std.log.err("event=tick_module_candidate_deinitialize_failed generation={}", .{candidate.number});
        if (candidate.state) |state| self.state_arena.retire(state) catch |err|
            std.log.err("event=tick_module_candidate_retire_failed generation={} err={}", .{ candidate.number, err });
        self.closeLibrary(candidate);
    }

    fn retireGenerationState(self: *Self, generation: *Generation) void {
        const started_ns = monotonicNanoseconds();
        if (deinitializeGeneration(generation) != .ok)
            std.log.err("event=tick_module_retired_deinitialize_failed generation={}", .{generation.number});
        const deinitialized_ns = monotonicNanoseconds();
        self.state_arena.retire(generation.state.?) catch
            @panic("failed to revoke retired tick-module memory");
        const revoked_ns = monotonicNanoseconds();
        generation.state = null;
        std.log.info(
            "event=tick_module_retire_profile deinit_ms={d:.3} revoke_ms={d:.3} total_ms={d:.3}",
            .{
                milliseconds(deinitialized_ns - started_ns),
                milliseconds(revoked_ns - deinitialized_ns),
                milliseconds(revoked_ns - started_ns),
            },
        );
    }

    fn destroyGeneration(self: *Self, generation_value: *Generation) !void {
        if (generation_value.state) |state| {
            if (deinitializeGeneration(generation_value) != .ok)
                std.log.err("event=tick_module_deinitialize_failed generation={}", .{generation_value.number});
            try self.state_arena.retire(state);
        }
        self.closeLibrary(generation_value);
    }

    fn closeLibrary(self: *Self, generation: *Generation) void {
        _ = self;
        generation.library.close();
    }

    fn initializeGeneration(
        self: *Self,
        generation: *Generation,
        reactor_memory_bytes: usize,
    ) !void {
        const available = std.math.sub(
            usize,
            generation.descriptor.maximum_memory_bytes,
            reactor_memory_bytes,
        ) catch return error.ConfiguredMemoryMaximumExceeded;
        const capacity = @min(
            generation.descriptor.state_capacity,
            std.mem.alignBackward(usize, available, std.heap.pageSize()),
        );
        if (capacity < generation.descriptor.state_size)
            return error.ConfiguredMemoryMaximumExceeded;
        generation.state = self.state_arena.allocate(
            capacity,
            generation.descriptor.state_alignment,
        ) catch return error.TickModuleInitializationFailed;
        var used_bytes = generation.state.?.bytes.len;
        const input = abi.Initialize{
            .panic_fn = hostPanic,
            .state_bytes = generation.state.?.bytes.len,
            .state_used_bytes = &used_bytes,
            .storage_mode = self.storage_mode,
        };
        const status = generation.functions.initialize(generation.state.?.bytes.ptr, &input);
        if (status != .ok) {
            self.state_arena.retire(generation.state.?) catch {};
            generation.state = null;
            if (capacity < generation.descriptor.state_capacity and
                status == .initialization_failed)
                return error.ConfiguredMemoryMaximumExceeded;
            return statusError(status);
        }
        const trimmed = self.state_arena.trim(generation.state.?, used_bytes) catch {
            _ = deinitializeGeneration(generation);
            self.state_arena.retire(generation.state.?) catch {};
            generation.state = null;
            return error.TickModuleInitializationFailed;
        };
        generation.state = trimmed;
        std.log.info(
            "event=generation_memory configured_max_bytes={} calculated_generation_bytes={}",
            .{
                generation.descriptor.maximum_memory_bytes,
                generation.state.?.mapped.len,
            },
        );
    }

    fn deinitializeGeneration(generation: *Generation) abi.Status {
        generation.functions.deinitialize(generation.state.?.bytes.ptr);
        return .ok;
    }

    fn setGenerationProfiling(generation: *Generation, enabled: bool) !void {
        generation.functions.set_profiling(
            generation.state.?.bytes.ptr,
            @intFromBool(enabled),
        );
    }
};

fn lifecycle(
    function: anytype,
    generation: *Manager.Generation,
) !void {
    const status = function(generation.state.?.bytes.ptr);
    if (status != .ok) return statusError(status);
}

fn validateGenerationMemory(
    generation: *const Manager.Generation,
    reactor_memory_bytes: usize,
) !void {
    const state = generation.state orelse return error.TickModuleNotInitialized;
    const calculated = std.math.add(
        usize,
        reactor_memory_bytes,
        state.mapped.len,
    ) catch return error.ConfiguredMemoryMaximumExceeded;
    std.log.info(
        "event=memory_budget configured_max_bytes={} reactor_bytes={} generation_bytes={} calculated_bytes={}",
        .{
            generation.descriptor.maximum_memory_bytes,
            reactor_memory_bytes,
            state.mapped.len,
            calculated,
        },
    );
    if (calculated > generation.descriptor.maximum_memory_bytes)
        return error.ConfiguredMemoryMaximumExceeded;
}

const ReloadLibrary = struct {
    handle: *anyopaque,
    image_fd: posix.fd_t,

    fn open(source_path: []const u8, generation: u64) !ReloadLibrary {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrintZ(
            &name_buffer,
            "lightning-rod-tick-{d}",
            .{generation},
        );
        const image_fd = try posix.memfd_createZ(
            name,
            std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
        );
        errdefer closeImage(image_fd);
        const source_fd = try posix.openat(
            std.os.linux.AT.FDCWD,
            source_path,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            0,
        );
        defer closeImage(source_fd);
        try copyImage(source_fd, image_fd);
        try sealImage(image_fd);
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrintZ(
            &path_buffer,
            "/proc/self/fd/{d}",
            .{image_fd},
        );
        const handle = std.c.dlopen(path, .{ .NOW = true }) orelse {
            if (std.c.dlerror()) |message|
                std.log.err("event=tick_module_dlopen_failed detail={s}", .{std.mem.span(message)});
            return error.TickModuleDynamicLoadFailed;
        };
        return .{ .handle = handle, .image_fd = image_fd };
    }

    fn close(self: *ReloadLibrary) void {
        std.debug.assert(std.c.dlclose(self.handle) == 0);
        closeImage(self.image_fd);
        self.* = undefined;
    }

    fn lookup(self: *ReloadLibrary, comptime T: type, name: [:0]const u8) ?T {
        const symbol = @call(.never_tail, std.c.dlsym, .{ self.handle, name.ptr }) orelse
            return null;
        return @ptrCast(@alignCast(symbol));
    }
};

fn closeImage(fd: posix.fd_t) void {
    _ = std.os.linux.close(fd);
}

fn sealImage(fd: posix.fd_t) !void {
    const seals = std.os.linux.F.SEAL_SEAL |
        std.os.linux.F.SEAL_SHRINK |
        std.os.linux.F.SEAL_GROW |
        std.os.linux.F.SEAL_WRITE;
    const result = std.os.linux.fcntl(fd, std.os.linux.F.ADD_SEALS, seals);
    switch (std.os.linux.errno(result)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn copyImage(source_fd: posix.fd_t, image_fd: posix.fd_t) !void {
    var source_offset: i64 = 0;
    var copied: usize = 0;
    for (0..maximum_module_bytes / image_copy_bytes + 1) |_| {
        const remaining = maximum_module_bytes - copied;
        if (remaining == 0) return error.TickModuleImageTooLarge;
        const result = std.os.linux.sendfile(
            image_fd,
            source_fd,
            &source_offset,
            @min(image_copy_bytes, remaining),
        );
        switch (std.os.linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) {
                    if (copied == 0) return error.EmptyTickModuleImage;
                    return;
                }
                copied += result;
            },
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
    return error.TickModuleImageTooLarge;
}

fn hostPanic(context: *const abi.PanicContext) callconv(.c) noreturn {
    if (context.has_plugin != 0) {
        std.debug.print(
            "\n=== LIGHTNING ROD PLUGIN PANIC ===\n" ++
                "panic:  {s}\n" ++
                "phase:  {s}\n" ++
                "plugin: {s} (profile index {d})\n" ++
                "system: {s} (plugin system index {d})\n",
            .{
                context.message(),
                context.phase_ptr[0..context.phase_len],
                context.plugin_id_ptr[0..context.plugin_id_len],
                context.plugin_index,
                context.system_type_ptr[0..context.system_type_len],
                context.system_index,
            },
        );
        if (context.has_tick != 0) std.debug.print("tick:    {d}\n", .{context.tick});
        if (context.has_subject != 0) std.debug.print("subject: connection/player slot {d}\n", .{context.subject});
        std.debug.print("module:  reload generation shared object\n==================================\n\n", .{});
    }
    std.debug.defaultPanic(context.message(), if (context.return_address == 0) null else context.return_address);
}

fn descriptorSupportsProtocol(descriptor: *const abi.Descriptor, protocol_number: i32) bool {
    for (descriptor.supported_protocols[0..descriptor.supported_protocol_count]) |supported|
        if (supported == protocol_number) return true;
    return false;
}

fn monotonicNanoseconds() u64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS)
        return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(now.nsec));
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn statusError(status: abi.Status) anyerror {
    return switch (status) {
        .ok => error.UnexpectedSuccessfulModuleStatus,
        .initialization_failed => error.TickModuleInitializationFailed,
        .tick_failed => error.TickModuleTickFailed,
        .connection_failed => error.TickModuleConnectionFailed,
        .invalid_request => error.TickModuleInvalidRequest,
        .save_failed => error.TickModuleSaveFailed,
        .pending => error.TickModuleOperationPending,
    };
}
