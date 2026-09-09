const std = @import("std");
const contracts = @import("runtime/contracts.zig");

pub const Backend = contracts.Backend;
pub const Sessions = contracts.Sessions;
pub const Core = contracts.Core;
pub const Reloader = contracts.Reloader;
pub const Operation = contracts.Operation;
pub const Shutdown = contracts.Shutdown;
pub const Readiness = contracts.Readiness;
pub const Wake = contracts.Wake;
pub const Outcome = contracts.Outcome;
pub const Progress = contracts.Progress;
pub const Completion = contracts.Completion;
pub const CheckpointCapture = contracts.CheckpointCapture;
pub const ControlRequest = contracts.ControlRequest;

pub const RuntimeError = error{
    InvalidLimits,
    ContractViolation,
    TransportFailed,
    PersistenceFailed,
    LoggingFailed,
    AuxiliaryBackendFailed,
    SessionsFailed,
    CoreFailed,
    ReloaderFailed,
    ShutdownFailed,
    ShutdownTimedOut,
    CoreTickDeadlineExceeded,
};
pub const RunError = RuntimeError || std.Io.Cancelable;
pub const maximum_tick_ns = contracts.maximum_tick_ns;

pub const Limits = struct {
    completion_budget: usize = 64,
    immediate_pass_limit: usize = 4,
    maximum_auxiliary_backends: usize = 8,
    tick_interval_ns: u64 = 50 * std.time.ns_per_ms,
    tick_deadline_ns: u64 = maximum_tick_ns,
    checkpoint_interval_ns: u64 = 5 * 60 * std.time.ns_per_s,
    shutdown_timeout_ns: u64 = 30 * std.time.ns_per_s,
    fail_on_tick_deadline: bool = false,
};

pub const Server = struct {
    io: std.Io,
    transport: Backend,
    persistence: Backend,
    logging: Backend,
    auxiliary_backends: []const Backend = &.{},
    shutdown: Shutdown,
    sessions: Sessions,
    core: Core,
    reloader: ?Reloader = null,
    limits: Limits = .{},
};

pub fn run(server: Server) RunError!void {
    var waits = Coalescing.init(server.io);
    var driver = try Driver.init(server, &waits);

    std.debug.assert(driver.server.limits.completion_budget > 0);
    std.debug.assert(driver.server.limits.immediate_pass_limit > 0);
    var immediate_passes: usize = 0;
    while (!driver.finished()) {
        driver.pass() catch |err| {
            driver.fatalShutdown(err);
            return err;
        };
        if (driver.finished()) return;
        if (driver.ready and immediate_passes < server.limits.immediate_pass_limit) {
            immediate_passes += 1;
            continue;
        }
        immediate_passes = 0;
        try driver.wait();
    }
}

const ShutdownPhase = enum {
    running,
    stop_accepting,
    final_detachments,
    checkpoint_close,
    submit_final,
    await_final,
    done,
};

const Coalescing = struct {
    io: std.Io,
    event: std.Io.Event = .unset,

    fn init(io: std.Io) Coalescing {
        return .{ .io = io };
    }

    fn attach(self: *Coalescing, source: Readiness) Outcome {
        return source.bind(.{ .context = self, .io = self.io, .signal_fn = signal });
    }

    fn reset(self: *Coalescing) void {
        self.event.reset();
    }

    fn wait(self: *Coalescing, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        self.event.waitTimeout(self.io, timeout) catch |err| switch (err) {
            error.Timeout => return,
            error.Canceled => return error.Canceled,
        };
    }

    fn signal(context: *anyopaque, io: std.Io) void {
        const self: *Coalescing = @ptrCast(@alignCast(context));
        self.event.set(io);
    }
};

const Driver = struct {
    server: Server,
    waits: *Coalescing,
    next_tick: std.Io.Clock.Timestamp,
    next_checkpoint: std.Io.Clock.Timestamp,
    phase: ShutdownPhase = .running,
    shutdown_deadline: ?std.Io.Clock.Timestamp = null,
    ready: bool = false,
    tick_samples: [100]u64 = @splat(0),
    tick_sample_count: usize = 0,
    tick_sample_cursor: usize = 0,

    fn init(server: Server, waits: *Coalescing) RuntimeError!Driver {
        if (server.limits.completion_budget == 0) return error.InvalidLimits;
        if (server.limits.immediate_pass_limit == 0) return error.InvalidLimits;
        if (server.auxiliary_backends.len > server.limits.maximum_auxiliary_backends)
            return error.InvalidLimits;
        if (server.limits.tick_interval_ns == 0) return error.InvalidLimits;
        if (server.limits.tick_deadline_ns == 0) return error.InvalidLimits;
        if (server.limits.checkpoint_interval_ns == 0) return error.InvalidLimits;
        if (server.limits.shutdown_timeout_ns == 0) return error.InvalidLimits;
        const now = std.Io.Clock.Timestamp.now(server.io, .awake);
        const result: Driver = .{
            .server = server,
            .waits = waits,
            .next_tick = now,
            .next_checkpoint = now.addDuration(checkpointInterval(server.limits)),
        };
        try attachReadiness(waits, server);
        return result;
    }

    fn pass(self: *Driver) RuntimeError!void {
        self.waits.reset();
        try self.drain();
        if (self.phase != .running) return self.driveShutdown();
        try require(self.server.sessions.advance(), error.SessionsFailed);
        try self.advanceOptional();
        if (self.server.shutdown.requested()) {
            self.phase = .stop_accepting;
            return self.driveShutdown();
        }
        if (self.server.reloader) |item| {
            if (item.blocksCore()) return self.submitAll();
        }
        try self.tickDue();
        try self.dispatchControl();
        try self.checkpointDue();
        try self.submitAll();
    }

    fn drain(self: *Driver) RuntimeError!void {
        const budget = self.server.limits.completion_budget;
        self.ready = false;
        try self.drainBackend(self.server.transport, error.TransportFailed, budget);
        try self.drainBackend(self.server.persistence, error.PersistenceFailed, budget);
        try self.drainBackend(self.server.logging, error.LoggingFailed, budget);
        for (self.server.auxiliary_backends) |backend|
            try self.drainBackend(backend, error.AuxiliaryBackendFailed, budget);
        if (self.server.reloader) |item| {
            try self.drainOperation(item, error.ReloaderFailed, budget);
        }
    }

    fn drainBackend(self: *Driver, backend: Backend, failure: RuntimeError, budget: usize) RuntimeError!void {
        const completion = backend.complete(self.server.io, budget);
        try self.recordCompletion(completion, failure, budget);
    }

    fn drainOperation(self: *Driver, operation: contracts.Operation, failure: RuntimeError, budget: usize) RuntimeError!void {
        const completion = operation.complete(budget);
        try self.recordCompletion(completion, failure, budget);
    }

    fn recordCompletion(self: *Driver, completion: Completion, failure: RuntimeError, budget: usize) RuntimeError!void {
        if (completion.outcome == .failed) return failure;
        if (completion.count > budget) return error.ContractViolation;
        self.ready = completion.count == budget or self.ready;
    }

    fn advanceOptional(self: *Driver) RuntimeError!void {
        if (self.server.reloader) |item| {
            try require(item.advance(), error.ReloaderFailed);
        }
    }

    fn beginCoreTick(self: *Driver) RuntimeError!void {
        try require(self.server.sessions.takeInput(), error.SessionsFailed);
        try require(self.server.core.service(), error.CoreFailed);
    }

    fn finishCoreTick(self: *Driver) RuntimeError!void {
        try require(self.server.sessions.finishInput(), error.SessionsFailed);
    }

    fn tickDue(self: *Driver) RuntimeError!void {
        const now = std.Io.Clock.Timestamp.now(self.server.io, .awake);
        if (std.Io.Clock.Timestamp.compare(now, .lt, self.next_tick)) return;
        const started_at = now;
        try self.beginCoreTick();
        try require(self.server.core.tick(), error.CoreFailed);
        try self.finishCoreTick();
        const scheduled = self.next_tick.addDuration(tickInterval(self.server.limits));
        const completed_at = std.Io.Clock.Timestamp.now(self.server.io, .awake);
        const elapsed_ns = completed_at.raw.nanoseconds - started_at.raw.nanoseconds;
        self.tick_samples[self.tick_sample_cursor] = @intCast(elapsed_ns);
        self.tick_sample_cursor = (self.tick_sample_cursor + 1) % self.tick_samples.len;
        self.tick_sample_count = @min(self.tick_sample_count + 1, self.tick_samples.len);
        if (self.tick_sample_cursor == 0) {
            var total: u64 = 0;
            var maximum: u64 = 0;
            for (self.tick_samples[0..self.tick_sample_count]) |sample| {
                total += sample;
                maximum = @max(maximum, sample);
            }
            std.log.info("event=core_tick_profile samples={d} avg_us={d} max_us={d}", .{
                self.tick_sample_count,
                total / self.tick_sample_count / std.time.ns_per_us,
                maximum / std.time.ns_per_us,
            });
        }
        if (elapsed_ns > self.server.limits.tick_deadline_ns) {
            std.log.err("event=core_tick_deadline_exceeded elapsed_us={d} deadline_us={d}", .{
                @divTrunc(elapsed_ns, std.time.ns_per_us),
                @divTrunc(self.server.limits.tick_deadline_ns, std.time.ns_per_us),
            });
            if (self.server.limits.fail_on_tick_deadline) return error.CoreTickDeadlineExceeded;
        }
        self.next_tick = if (std.Io.Clock.Timestamp.compare(scheduled, .lt, completed_at)) completed_at else scheduled;
    }

    fn checkpointDue(self: *Driver) RuntimeError!void {
        const now = std.Io.Clock.Timestamp.now(self.server.io, .awake);
        if (std.Io.Clock.Timestamp.compare(now, .lt, self.next_checkpoint)) return;
        switch (self.server.core.captureCheckpoint()) {
            .captured => self.next_checkpoint = now.addDuration(checkpointInterval(self.server.limits)),
            .busy => {},
            .failed => return error.CoreFailed,
        }
    }

    fn dispatchControl(self: *Driver) RuntimeError!void {
        const request = self.server.core.takeControl() orelse return;
        const accepted = switch (request) {
            .reload => if (self.server.reloader) |reloader| reloader.request() == .ok else false,
        };
        self.server.core.controlResult(request, accepted);
    }

    fn submitAll(self: *Driver) RuntimeError!void {
        var failure: ?RuntimeError = null;
        recordOutcome(self.server.transport.submit(self.server.io), error.TransportFailed, &failure);
        recordOutcome(self.server.persistence.submit(self.server.io), error.PersistenceFailed, &failure);
        recordOutcome(self.server.logging.submit(self.server.io), error.LoggingFailed, &failure);
        for (self.server.auxiliary_backends) |backend|
            recordOutcome(backend.submit(self.server.io), error.AuxiliaryBackendFailed, &failure);
        if (failure) |err| return err;
    }

    fn driveShutdown(self: *Driver) RuntimeError!void {
        const deadline = self.shutdown_deadline;
        if (deadline) |value| {
            const now = std.Io.Clock.Timestamp.now(self.server.io, .awake);
            if (!std.Io.Clock.Timestamp.compare(now, .lt, value))
                return error.ShutdownTimedOut;
        }
        for (0..5) |_| {
            const advance = switch (self.phase) {
                .stop_accepting => try self.stopAccepting(),
                .final_detachments => try self.detachPlayers(),
                .checkpoint_close => try self.checkpointAndClose(),
                .submit_final => return self.submitFinal(),
                .await_final => return self.awaitFinal(),
                .done => return,
                .running => unreachable,
            };
            if (!advance) return;
        }
        return error.ContractViolation;
    }

    fn fatalShutdown(self: *Driver, failure: RuntimeError) void {
        std.log.err("event=fatal_shutdown error={s} checkpoint=false", .{@errorName(failure)});
        const deadline = std.Io.Clock.Timestamp.now(self.server.io, .awake).addDuration(.{
            .clock = .awake,
            .raw = .{ .nanoseconds = self.server.limits.shutdown_timeout_ns },
        });
        _ = self.server.sessions.stopAccepting();
        while (std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(self.server.io, .awake), .lt, deadline)) {
            const transport = self.server.transport.complete(self.server.io, self.server.limits.completion_budget);
            const progress = self.server.sessions.fatalDisconnect();
            const submitted = self.server.transport.submit(self.server.io);
            _ = self.server.logging.complete(self.server.io, self.server.limits.completion_budget);
            _ = self.server.logging.submit(self.server.io);
            if (progress != .pending or transport.outcome == .failed or submitted == .failed) return;
            std.Io.sleep(self.server.io, .fromMilliseconds(1), .awake) catch return;
        }
        std.log.err("event=fatal_disconnect_timeout", .{});
        _ = self.server.logging.submit(self.server.io);
    }

    fn stopAccepting(self: *Driver) RuntimeError!bool {
        std.log.info("event=shutdown_started", .{});
        std.debug.assert(self.shutdown_deadline == null);
        self.shutdown_deadline = std.Io.Clock.Timestamp.now(self.server.io, .awake).addDuration(.{
            .clock = .awake,
            .raw = .{ .nanoseconds = self.server.limits.shutdown_timeout_ns },
        });
        var failure: ?RuntimeError = null;
        recordOutcome(self.server.shutdown.begin(), error.ShutdownFailed, &failure);
        recordOutcome(self.server.sessions.stopAccepting(), error.SessionsFailed, &failure);
        if (failure) |err| return err;
        self.phase = .final_detachments;
        return true;
    }

    fn detachPlayers(self: *Driver) RuntimeError!bool {
        try require(self.server.sessions.stageFinalDetachments(), error.SessionsFailed);
        try self.beginCoreTick();
        try require(self.server.core.tick(), error.CoreFailed);
        try self.finishCoreTick();
        self.phase = .checkpoint_close;
        std.log.info("event=shutdown_final_tick_complete", .{});
        return true;
    }

    fn checkpointAndClose(self: *Driver) RuntimeError!bool {
        switch (self.server.core.captureCheckpoint()) {
            .captured => {},
            .busy => {
                try self.submitAll();
                return false;
            },
            .failed => return error.CoreFailed,
        }
        std.log.info("event=shutdown_checkpoint_captured", .{});
        try require(self.server.core.beginClose(self.shutdown_deadline.?.raw.nanoseconds), error.CoreFailed);
        var failure: ?RuntimeError = null;
        recordOutcome(self.server.transport.beginShutdown(self.server.io), error.TransportFailed, &failure);
        recordOutcome(self.server.persistence.beginShutdown(self.server.io), error.PersistenceFailed, &failure);
        recordOutcome(self.server.logging.beginShutdown(self.server.io), error.LoggingFailed, &failure);
        for (self.server.auxiliary_backends) |backend|
            recordOutcome(backend.beginShutdown(self.server.io), error.AuxiliaryBackendFailed, &failure);
        self.beginOptionalShutdown(&failure);
        if (failure) |err| return err;
        self.phase = .submit_final;
        return true;
    }

    fn beginOptionalShutdown(self: *Driver, failure: *?RuntimeError) void {
        if (self.server.reloader) |item| {
            recordOutcome(item.beginShutdown(), error.ReloaderFailed, failure);
        }
    }

    fn submitFinal(self: *Driver) RuntimeError!void {
        try require(self.server.sessions.advance(), error.SessionsFailed);
        try self.submitAll();
        self.phase = .await_final;
        self.ready = true;
    }

    fn awaitFinal(self: *Driver) RuntimeError!void {
        try require(self.server.sessions.advance(), error.SessionsFailed);
        try self.submitAll();
        if (try self.finalWorkComplete()) {
            self.phase = .done;
            std.log.info("event=shutdown_complete", .{});
        }
    }

    fn finalWorkComplete(self: *Driver) RuntimeError!bool {
        var complete = true;
        try recordProgress(self.server.sessions.shutdownProgress(), error.SessionsFailed, &complete);
        try recordProgress(self.server.core.closeProgress(), error.CoreFailed, &complete);
        try recordProgress(self.server.core.checkpointProgress(), error.CoreFailed, &complete);
        try recordProgress(self.server.transport.shutdownProgress(), error.TransportFailed, &complete);
        try recordProgress(self.server.persistence.shutdownProgress(), error.PersistenceFailed, &complete);
        try recordProgress(self.server.logging.shutdownProgress(), error.LoggingFailed, &complete);
        for (self.server.auxiliary_backends) |backend|
            try recordProgress(backend.shutdownProgress(), error.AuxiliaryBackendFailed, &complete);
        if (self.server.reloader) |item| {
            try recordProgress(item.shutdownProgress(), error.ReloaderFailed, &complete);
        }
        return complete;
    }

    fn finished(self: *const Driver) bool {
        return self.phase == .done;
    }

    fn wait(self: *Driver) std.Io.Cancelable!void {
        var deadline = if (self.phase == .running) self.next_tick else self.shutdown_deadline.?;
        const now = std.Io.Clock.Timestamp.now(self.server.io, .awake);
        // submit() may finish the previous write without leaving an IO wake pending.
        if (self.phase == .checkpoint_close) {
            const retry = now.addDuration(.{ .clock = .awake, .raw = .{ .nanoseconds = std.time.ns_per_ms } });
            if (std.Io.Clock.Timestamp.compare(retry, .lt, deadline)) deadline = retry;
        }
        self.applyBackendPollDeadline(self.server.transport, now, &deadline);
        self.applyBackendPollDeadline(self.server.persistence, now, &deadline);
        self.applyBackendPollDeadline(self.server.logging, now, &deadline);
        for (self.server.auxiliary_backends) |backend| self.applyBackendPollDeadline(backend, now, &deadline);
        const timeout: std.Io.Timeout = .{ .deadline = deadline };
        try self.waits.wait(timeout);
    }

    fn applyBackendPollDeadline(_: *Driver, backend: Backend, now: std.Io.Clock.Timestamp, deadline: *std.Io.Clock.Timestamp) void {
        const interval = backend.pollIntervalNs() orelse return;
        const candidate = now.addDuration(.{ .clock = .awake, .raw = .{ .nanoseconds = interval } });
        if (std.Io.Clock.Timestamp.compare(candidate, .lt, deadline.*)) deadline.* = candidate;
    }
};

fn require(outcome: Outcome, failure: RuntimeError) RuntimeError!void {
    if (outcome == .failed) return failure;
}

fn attachReadiness(waits: *Coalescing, server: Server) RuntimeError!void {
    try attachBackendReadiness(waits, server.transport, error.TransportFailed);
    try attachBackendReadiness(waits, server.persistence, error.PersistenceFailed);
    try attachBackendReadiness(waits, server.logging, error.LoggingFailed);
    for (server.auxiliary_backends) |backend|
        try attachBackendReadiness(waits, backend, error.AuxiliaryBackendFailed);
    if (server.sessions.readiness) |source|
        try require(waits.attach(source), error.SessionsFailed);
    if (server.core.readiness) |source|
        try require(waits.attach(source), error.CoreFailed);
    if (server.reloader) |item| {
        if (item.readiness) |source|
            try require(waits.attach(source), error.ReloaderFailed);
    }
    if (server.shutdown.readiness) |source|
        try require(waits.attach(source), error.ShutdownFailed);
}

fn attachBackendReadiness(waits: *Coalescing, backend: Backend, failure: RuntimeError) RuntimeError!void {
    if (backend.readiness) |source|
        try require(waits.attach(source), failure);
}

fn recordOutcome(outcome: Outcome, value: RuntimeError, failure: *?RuntimeError) void {
    if (outcome == .failed and failure.* == null) failure.* = value;
}

fn recordProgress(progress: Progress, failure: RuntimeError, complete: *bool) RuntimeError!void {
    switch (progress) {
        .pending => complete.* = false,
        .complete => {},
        .failed => return failure,
    }
}

fn tickInterval(limits: Limits) std.Io.Clock.Duration {
    return .{ .clock = .awake, .raw = .{ .nanoseconds = limits.tick_interval_ns } };
}

fn checkpointInterval(limits: Limits) std.Io.Clock.Duration {
    return .{ .clock = .awake, .raw = .{ .nanoseconds = limits.checkpoint_interval_ns } };
}

test "driver enforces service and graceful shutdown order" {
    var state: TestState = .{};
    const server = testServer(&state);
    var waits = Coalescing.init(server.io);
    var driver = try Driver.init(server, &waits);
    try driver.pass();
    try std.testing.expectEqual(@as(usize, 1), state.ticks);
    try std.testing.expectEqual(@as(usize, 1), state.services);

    state.requested = true;
    try driver.pass();
    try std.testing.expectEqual(ShutdownPhase.await_final, driver.phase);
    try std.testing.expectEqual(@as(usize, 1), state.stop_accepting);
    try std.testing.expectEqual(@as(usize, 1), state.detachments);
    try std.testing.expectEqual(@as(usize, 1), state.checkpoints);
    try std.testing.expectEqual(@as(usize, 1), state.closes);
    try std.testing.expectEqual(@as(usize, 2), state.ticks);
    try driver.pass();
    try std.testing.expect(driver.finished());
}

test "shutdown retries a busy checkpoint without requiring another IO completion" {
    var state: TestState = .{ .requested = true, .checkpoint_busy_once = true };
    var server = testServer(&state);
    server.limits.shutdown_timeout_ns = 40 * std.time.ns_per_ms;
    try run(server);
    try std.testing.expectEqual(@as(usize, 1), state.ticks);
    try std.testing.expectEqual(@as(usize, 2), state.checkpoints);
    try std.testing.expectEqual(@as(usize, 1), state.closes);
}

test "driver rejects zero limits and surfaces backend failure" {
    var state: TestState = .{};
    var invalid = testServer(&state);
    var waits = Coalescing.init(invalid.io);
    invalid.limits.completion_budget = 0;
    try std.testing.expectError(error.InvalidLimits, Driver.init(invalid, &waits));

    invalid = testServer(&state);
    invalid.limits.immediate_pass_limit = 0;
    try std.testing.expectError(error.InvalidLimits, Driver.init(invalid, &waits));

    invalid = testServer(&state);
    invalid.limits.tick_deadline_ns = 0;
    try std.testing.expectError(error.InvalidLimits, Driver.init(invalid, &waits));

    state.backend_failed = true;
    try std.testing.expectError(error.TransportFailed, run(testServer(&state)));
}

test "fatal partial tick disconnects without another tick or checkpoint" {
    var state: TestState = .{ .tick_failed = true };
    try std.testing.expectError(error.CoreFailed, run(testServer(&state)));
    try std.testing.expectEqual(@as(usize, 1), state.ticks);
    try std.testing.expectEqual(@as(usize, 1), state.fatal_disconnects);
    try std.testing.expectEqual(@as(usize, 0), state.checkpoints);
    try std.testing.expectEqual(@as(usize, 0), state.closes);
    try std.testing.expectEqual(@as(usize, 0), state.detachments);
}

test "test profiles can turn the absolute tick deadline into a failure" {
    var state: TestState = .{};
    var server = testServer(&state);
    server.limits.tick_deadline_ns = 1;
    server.limits.fail_on_tick_deadline = true;
    var waits = Coalescing.init(server.io);
    var driver = try Driver.init(server, &waits);
    try std.testing.expectError(error.CoreTickDeadlineExceeded, driver.pass());
}

test "only a full completion drain requests an immediate pass" {
    var state: TestState = .{ .completion_count = 1 };
    const server = testServer(&state);
    var waits = Coalescing.init(server.io);
    var driver = try Driver.init(server, &waits);
    try driver.drain();
    try std.testing.expect(!driver.ready);

    state.completion_count = driver.server.limits.completion_budget;
    try driver.drain();
    try std.testing.expect(driver.ready);
}

test "a busy backend cannot starve another completion source" {
    var state: TestState = .{};
    const server = testServer(&state);
    var waits = Coalescing.init(server.io);
    var driver = try Driver.init(server, &waits);
    var transport = FairSource{ .count = driver.server.limits.completion_budget };
    var persistence = FairSource{ .count = 1 };
    var logging = FairSource{};
    driver.server.transport = fairBackend(&transport);
    driver.server.persistence = fairBackend(&persistence);
    driver.server.logging = fairBackend(&logging);

    try driver.drain();

    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), persistence.calls);
    try std.testing.expectEqual(@as(usize, 1), logging.calls);
    try std.testing.expect(driver.ready);
}

test "driver dispatches one reload request after its core tick" {
    var state: TestState = .{ .tick_control_slot = 17 };
    var server = testServer(&state);
    server.reloader = .{ .context = &state, .vtable = &test_reloader_vtable };
    var waits = Coalescing.init(server.io);
    var driver = try Driver.init(server, &waits);

    try driver.pass();
    try std.testing.expectEqual(@as(usize, 1), state.ticks);
    try std.testing.expectEqual(@as(usize, 1), state.reloader_requests);
    try std.testing.expectEqual(@as(usize, 1), state.control_results);
    try std.testing.expectEqual(@as(?u16, 17), state.control_result_slot);
    try std.testing.expect(state.control_accepted);

    try driver.pass();
    try std.testing.expectEqual(@as(usize, 1), state.reloader_requests);
    try std.testing.expectEqual(@as(usize, 1), state.control_results);
}

test "driver rejects a reload request without a reloader" {
    var state: TestState = .{ .control_slot = 23 };
    const server = testServer(&state);
    var waits = Coalescing.init(server.io);
    var driver = try Driver.init(server, &waits);

    try driver.pass();
    try std.testing.expectEqual(@as(usize, 1), state.control_results);
    try std.testing.expectEqual(@as(?u16, 23), state.control_result_slot);
    try std.testing.expect(!state.control_accepted);
}

test "driver reports a busy reloader once without retrying it" {
    var state: TestState = .{ .control_slot = 29, .reloader_accepts = false };
    var server = testServer(&state);
    server.reloader = .{ .context = &state, .vtable = &test_reloader_vtable };
    var waits = Coalescing.init(server.io);
    var driver = try Driver.init(server, &waits);

    try driver.pass();
    try std.testing.expectEqual(@as(usize, 1), state.reloader_requests);
    try std.testing.expectEqual(@as(usize, 1), state.control_results);
    try std.testing.expect(!state.control_accepted);

    try driver.pass();
    try std.testing.expectEqual(@as(usize, 1), state.reloader_requests);
    try std.testing.expectEqual(@as(usize, 1), state.control_results);
}

const TestState = struct {
    requested: bool = false,
    backend_failed: bool = false,
    tick_failed: bool = false,
    fatal_disconnects: usize = 0,
    completion_count: usize = 0,
    ticks: usize = 0,
    services: usize = 0,
    stop_accepting: usize = 0,
    detachments: usize = 0,
    checkpoints: usize = 0,
    checkpoint_busy_once: bool = false,
    closes: usize = 0,
    control_slot: ?u16 = null,
    tick_control_slot: ?u16 = null,
    control_results: usize = 0,
    control_result_slot: ?u16 = null,
    control_accepted: bool = false,
    reloader_requests: usize = 0,
    reloader_accepts: bool = true,
};

const FairSource = struct {
    count: usize = 0,
    calls: usize = 0,
};

fn testServer(state: *TestState) Server {
    const backend: Backend = .{ .context = state, .vtable = &test_backend_vtable };
    return .{
        .io = std.Io.Threaded.global_single_threaded.io(),
        .transport = backend,
        .persistence = backend,
        .logging = backend,
        .shutdown = .{ .context = state, .vtable = &test_shutdown_vtable },
        .sessions = .{ .context = state, .vtable = &test_sessions_vtable },
        .core = .{ .context = state, .vtable = &test_core_vtable },
    };
}

fn testState(context: *anyopaque) *TestState {
    return @ptrCast(@alignCast(context));
}

fn testComplete(context: *anyopaque, _: std.Io, _: usize) Completion {
    const state = testState(context);
    return .{ .count = state.completion_count, .outcome = if (state.backend_failed) .failed else .ok };
}
fn fairSource(context: *anyopaque) *FairSource {
    return @ptrCast(@alignCast(context));
}
fn fairComplete(context: *anyopaque, _: std.Io, _: usize) Completion {
    const source = fairSource(context);
    source.calls += 1;
    return .{ .count = source.count };
}
fn fairBackend(source: *FairSource) Backend {
    return .{ .context = source, .vtable = &fair_backend_vtable };
}
fn testBackendOk(_: *anyopaque, _: std.Io) Outcome {
    return .ok;
}
fn testOk(_: *anyopaque) Outcome {
    return .ok;
}
fn testCompleteProgress(_: *anyopaque) Progress {
    return .complete;
}
fn testRequested(context: *anyopaque) bool {
    return testState(context).requested;
}
const test_backend_vtable: Backend.VTable = .{
    .complete = testComplete,
    .submit = testBackendOk,
    .begin_shutdown = testBackendOk,
    .shutdown_progress = testCompleteProgress,
};

const fair_backend_vtable: Backend.VTable = .{
    .complete = fairComplete,
    .submit = testBackendOk,
    .begin_shutdown = testBackendOk,
    .shutdown_progress = testCompleteProgress,
};

fn testAdvance(_: *anyopaque) Outcome {
    return .ok;
}
fn testTakeInput(_: *anyopaque) Outcome {
    return .ok;
}
fn testFinishInput(_: *anyopaque) Outcome {
    return .ok;
}
fn testStopAccepting(context: *anyopaque) Outcome {
    testState(context).stop_accepting += 1;
    return .ok;
}
fn testDetachments(context: *anyopaque) Outcome {
    testState(context).detachments += 1;
    return .ok;
}
fn testFatalDisconnect(context: *anyopaque) Progress {
    testState(context).fatal_disconnects += 1;
    return .complete;
}

const test_sessions_vtable: Sessions.VTable = .{
    .advance = testAdvance,
    .take_input = testTakeInput,
    .finish_input = testFinishInput,
    .stop_accepting = testStopAccepting,
    .stage_final_detachments = testDetachments,
    .fatal_disconnect = testFatalDisconnect,
    .shutdown_progress = testCompleteProgress,
};

fn testService(context: *anyopaque) Outcome {
    testState(context).services += 1;
    return .ok;
}
fn testTick(context: *anyopaque) Outcome {
    const state = testState(context);
    state.ticks += 1;
    if (state.tick_failed) return .failed;
    if (state.control_slot == null) {
        state.control_slot = state.tick_control_slot;
        state.tick_control_slot = null;
    }
    return .ok;
}
fn testCheckpoint(context: *anyopaque) CheckpointCapture {
    const state = testState(context);
    state.checkpoints += 1;
    if (state.checkpoint_busy_once) {
        state.checkpoint_busy_once = false;
        return .busy;
    }
    return .captured;
}
fn testClose(context: *anyopaque, _: i128) Outcome {
    testState(context).closes += 1;
    return .ok;
}
fn testTakeControl(context: *anyopaque) ?contracts.ControlRequest {
    const state = testState(context);
    const slot = state.control_slot orelse return null;
    state.control_slot = null;
    return .{ .reload = slot };
}
fn testControlResult(context: *anyopaque, request: contracts.ControlRequest, accepted: bool) void {
    const state = testState(context);
    state.control_results += 1;
    state.control_accepted = accepted;
    switch (request) {
        .reload => |slot| state.control_result_slot = slot,
    }
}

fn testReloaderRequest(context: *anyopaque) Outcome {
    const state = testState(context);
    state.reloader_requests += 1;
    return if (state.reloader_accepts) .ok else .failed;
}

fn testOperationComplete(context: *anyopaque, _: usize) Completion {
    const state = testState(context);
    return .{ .count = state.completion_count, .outcome = if (state.backend_failed) .failed else .ok };
}

const test_reloader_vtable: Reloader.VTable = .{
    .complete = testOperationComplete,
    .advance = testAdvance,
    .request = testReloaderRequest,
    .begin_shutdown = testOk,
    .shutdown_progress = testCompleteProgress,
};

const test_core_vtable: Core.VTable = .{
    .service = testService,
    .tick = testTick,
    .capture_checkpoint = testCheckpoint,
    .checkpoint_progress = testCompleteProgress,
    .begin_close = testClose,
    .close_progress = testCompleteProgress,
    .take_control = testTakeControl,
    .control_result = testControlResult,
};

const test_shutdown_vtable: Shutdown.VTable = .{
    .requested = testRequested,
    .begin = testOk,
};
