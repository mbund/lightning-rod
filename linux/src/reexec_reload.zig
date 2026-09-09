const lightning_rod = @import("lightning_rod");
const contracts = lightning_rod.runtime;
const handoff = @import("restart_handoff.zig");
const std = @import("std");
const connection = lightning_rod.connection;
const exchange = lightning_rod.transport;

pub const Error = error{InvalidResume};

pub const TransportConnection = struct {
    fd: std.posix.fd_t,
    handle: connection.Handle,
    unread: []const u8,
    output: []const u8,
};

pub const Continuation = struct {
    id: u32,
    version: u16,
    bytes: []const u8,
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        begin_quiesce: *const fn (*anyopaque) contracts.Outcome,
        quiesce_progress: *const fn (*anyopaque) contracts.Progress,
        abort_quiesce: *const fn (*anyopaque) contracts.Outcome,
        maximum_resume_bytes: *const fn (*anyopaque) usize,
        listener: *const fn (*anyopaque) ?std.posix.fd_t,
        connection_count: *const fn (*anyopaque) usize,
        connection: *const fn (*anyopaque, usize) ?TransportConnection,
        prepare_for_exec: *const fn (*anyopaque, connection.Handle) contracts.Outcome,
        prepare_listener_for_exec: *const fn (*anyopaque) contracts.Outcome,
        restore: *const fn (*anyopaque, TransportConnection) contracts.Outcome,
    };
};

pub const Sessions = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        validate_resume: *const fn (*anyopaque, usize) contracts.Outcome,
        begin_reconfiguration: *const fn (*anyopaque) contracts.Outcome,
        reconfiguration_progress: *const fn (*anyopaque) contracts.Progress,
        abort_reconfiguration: *const fn (*anyopaque) contracts.Outcome,
        encode: *const fn (*anyopaque, connection.Handle, []u8) ?Continuation,
        restore: *const fn (*anyopaque, connection.Handle, u32, u16, []const u8) contracts.Outcome,
    };
};

pub fn TableSessions(comptime TableType: type) type {
    return struct {
        const Self = @This();

        table: *TableType,
        transport: exchange.Transport,

        pub fn sessions(self: *Self) Sessions {
            return .{ .context = self, .vtable = &vtable };
        }

        fn from(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }
        fn validate(raw: *anyopaque, capacity: usize) contracts.Outcome {
            return if (from(raw).table.validateResume(capacity)) .ok else .failed;
        }
        fn begin(raw: *anyopaque) contracts.Outcome {
            const self = from(raw);
            return switch (self.table.beginReconfigurationWithTransport(self.transport)) {
                .accepted, .full => .ok,
                .unsupported => .failed,
            };
        }
        fn progress(raw: *anyopaque) contracts.Progress {
            const self = from(raw);
            if (self.table.advanceReconfigurationWithTransport(self.transport) == .unsupported) return .failed;
            return if (self.table.configurationBarrierStaged()) .complete else .pending;
        }
        fn abort(raw: *anyopaque) contracts.Outcome {
            const self = from(raw);
            self.table.abortReconfigurationWithTransport(self.transport);
            return .ok;
        }
        fn encode(raw: *anyopaque, handle: connection.Handle, output: []u8) ?Continuation {
            const bytes = from(raw).table.encodeResume(handle, output) orelse return null;
            return .{ .id = TableType.resume_id, .version = TableType.resume_version, .bytes = bytes };
        }
        fn restore(raw: *anyopaque, handle: connection.Handle, id: u32, version: u16, bytes: []const u8) contracts.Outcome {
            return if (from(raw).table.restoreResume(handle, id, version, bytes)) .ok else .failed;
        }

        const vtable: Sessions.VTable = .{
            .validate_resume = validate,
            .begin_reconfiguration = begin,
            .reconfiguration_progress = progress,
            .abort_reconfiguration = abort,
            .encode = encode,
            .restore = restore,
        };
    };
}

pub const Candidate = struct {
    context: *anyopaque,
    validate: *const fn (*anyopaque) contracts.Outcome,
    release: ?*const fn (*anyopaque) void = null,
};

pub const Executor = struct {
    context: *anyopaque,
    replace: *const fn (*anyopaque, []const u8) contracts.Outcome,
};

const Phase = enum { idle, validate, capture, commit, reconfigure, quiesce, serialize };

pub const Reloader = struct {
    candidate: Candidate,
    core: contracts.Core,
    sessions: Sessions,
    transport: Transport,
    executor: Executor,
    image: []u8,
    continuation: []u8,
    phase: Phase = .idle,
    requested: bool = false,
    candidate_live: bool = false,
    failed_attempts: u64 = 0,

    pub fn request(self: *Reloader) bool {
        if (self.phase != .idle or self.requested) return false;
        self.requested = true;
        self.candidate_live = true;
        return true;
    }

    pub fn operation(self: *Reloader) contracts.Reloader {
        return .{ .context = self, .vtable = &operation_vtable };
    }

    pub fn restoreConnections(self: *Reloader, bytes: []const u8) Error!void {
        var decoder = handoff.Decoder.init(bytes) catch return error.InvalidResume;
        try self.restoreRecords(&decoder);
    }

    fn restoreRecords(self: *Reloader, decoder: *handoff.Decoder) Error!void {
        const count = decoder.remaining;
        for (0..count) |_| {
            const record = (decoder.next() catch return error.InvalidResume) orelse return error.InvalidResume;
            if (self.sessions.vtable.restore(self.sessions.context, record.connection, record.session_id, record.session_version, record.continuation) != .ok)
                return error.InvalidResume;
            if (self.transport.vtable.restore(self.transport.context, .{
                .fd = record.fd,
                .handle = record.connection,
                .unread = record.unread,
                .output = record.output,
            }) != .ok) return error.InvalidResume;
        }
        if ((decoder.next() catch return error.InvalidResume) != null) return error.InvalidResume;
    }

    fn from(raw: *anyopaque) *Reloader {
        return @ptrCast(@alignCast(raw));
    }

    fn advanceOperation(raw: *anyopaque) contracts.Outcome {
        return from(raw).advance();
    }

    fn blocksCore(raw: *anyopaque) bool {
        const self = from(raw);
        return self.requested or self.phase != .idle;
    }

    fn requestOperation(raw: *anyopaque) contracts.Outcome {
        return if (from(raw).request()) .ok else .failed;
    }

    fn complete(_: *anyopaque, _: usize) contracts.Completion {
        return .{ .count = 0 };
    }
    fn beginShutdown(raw: *anyopaque) contracts.Outcome {
        const self = from(raw);
        var result: contracts.Outcome = .ok;
        if (self.phase == .reconfigure or self.phase == .quiesce or self.phase == .serialize) {
            if (self.sessions.vtable.abort_reconfiguration(self.sessions.context) != .ok) {
                result = .failed;
            }
        }
        if (self.phase == .quiesce or self.phase == .serialize) {
            if (self.transport.vtable.abort_quiesce(self.transport.context) != .ok) {
                result = .failed;
            }
        }
        self.phase = .idle;
        self.requested = false;
        self.releaseCandidate();
        return result;
    }
    fn shutdownProgress(_: *anyopaque) contracts.Progress {
        return .complete;
    }

    fn advance(self: *Reloader) contracts.Outcome {
        if (!self.requested) return .ok;
        return switch (self.phase) {
            .idle => self.beginValidation(),
            .validate => self.beginCapture(),
            .capture => self.awaitCapture(),
            .commit => self.beginReconfiguration(),
            .reconfigure => self.awaitReconfiguration(),
            .quiesce => self.awaitQuiescence(),
            .serialize => self.exportAndReplace(),
        };
    }

    fn beginValidation(self: *Reloader) contracts.Outcome {
        if (self.image.len < self.transport.vtable.maximum_resume_bytes(self.transport.context) or
            self.candidate.validate(self.candidate.context) != .ok or
            self.sessions.vtable.validate_resume(self.sessions.context, self.continuation.len) != .ok) return self.fail();
        self.phase = .validate;
        return .ok;
    }

    fn beginCapture(self: *Reloader) contracts.Outcome {
        switch (self.core.captureCheckpoint()) {
            .captured => self.phase = .capture,
            .busy => {},
            .failed => return self.fail(),
        }
        return .ok;
    }

    fn awaitCapture(self: *Reloader) contracts.Outcome {
        switch (self.core.checkpointProgress()) {
            .pending => {},
            .complete => self.phase = .commit,
            .failed => return self.fail(),
        }
        return .ok;
    }

    fn beginReconfiguration(self: *Reloader) contracts.Outcome {
        if (self.sessions.vtable.begin_reconfiguration(self.sessions.context) != .ok) return self.fail();
        self.phase = .reconfigure;
        return .ok;
    }

    fn awaitReconfiguration(self: *Reloader) contracts.Outcome {
        switch (self.sessions.vtable.reconfiguration_progress(self.sessions.context)) {
            .pending => return .ok,
            .failed => return self.fail(),
            .complete => {},
        }
        if (self.sessions.vtable.validate_resume(self.sessions.context, self.continuation.len) != .ok)
            return self.fail();
        if (self.transport.vtable.begin_quiesce(self.transport.context) != .ok) return self.fail();
        self.phase = .quiesce;
        return .ok;
    }

    fn awaitQuiescence(self: *Reloader) contracts.Outcome {
        switch (self.transport.vtable.quiesce_progress(self.transport.context)) {
            .pending => {},
            .complete => self.phase = .serialize,
            .failed => return self.fail(),
        }
        return .ok;
    }

    fn exportAndReplace(self: *Reloader) contracts.Outcome {
        const listener = self.transport.vtable.listener(self.transport.context) orelse return self.fail();
        var encoder = handoff.Encoder.init(self.image, listener) catch return self.fail();
        const count = self.transport.vtable.connection_count(self.transport.context);
        for (0..count) |index| {
            const item = self.transport.vtable.connection(self.transport.context, index) orelse return self.fail();
            const continuation = self.sessions.vtable.encode(self.sessions.context, item.handle, self.continuation) orelse return self.fail();
            encoder.append(.{ .fd = item.fd, .connection = item.handle, .unread = item.unread, .output = item.output, .session_id = continuation.id, .session_version = continuation.version, .continuation = continuation.bytes }) catch return self.fail();
            if (self.transport.vtable.prepare_for_exec(self.transport.context, item.handle) != .ok) return self.fail();
        }
        if (self.transport.vtable.prepare_listener_for_exec(self.transport.context) != .ok) return self.fail();
        const image = encoder.finish() catch return self.fail();
        if (self.executor.replace(self.executor.context, image) != .ok) return self.fail();
        return .ok;
    }

    fn fail(self: *Reloader) contracts.Outcome {
        var result: contracts.Outcome = .ok;
        if (self.phase == .reconfigure or self.phase == .quiesce or self.phase == .serialize) {
            if (self.sessions.vtable.abort_reconfiguration(self.sessions.context) != .ok) result = .failed;
        }
        if (self.phase == .quiesce or self.phase == .serialize) {
            if (self.transport.vtable.abort_quiesce(self.transport.context) != .ok) result = .failed;
        }
        self.phase = .idle;
        self.requested = false;
        self.releaseCandidate();
        self.failed_attempts +%= 1;
        return result;
    }

    fn releaseCandidate(self: *Reloader) void {
        if (!self.candidate_live) return;
        self.candidate_live = false;
        if (self.candidate.release) |release| release(self.candidate.context);
    }

    const operation_vtable: contracts.Operation.VTable = .{
        .complete = complete,
        .advance = advanceOperation,
        .blocks_core = blocksCore,
        .request = requestOperation,
        .begin_shutdown = beginShutdown,
        .shutdown_progress = shutdownProgress,
    };
};

const ReloadFixture = struct {
    const Event = enum {
        candidate,
        session_validate,
        capture,
        checkpoint,
        reconfigure,
        reconfiguration_progress,
        quiesce,
        quiescence_progress,
        encode,
        prepare_connection,
        prepare_listener,
        replace,
        abort,
        core_close,
        release,
    };

    events: [16]Event = undefined,
    event_count: usize = 0,
    candidate_result: contracts.Outcome = .ok,
    executor_result: contracts.Outcome = .ok,
    inheritable: bool = false,
    aborted: usize = 0,
    image: [256]u8 = undefined,
    image_len: usize = 0,

    fn push(self: *ReloadFixture, event: Event) void {
        std.debug.assert(self.event_count < self.events.len);
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    fn from(raw: *anyopaque) *ReloadFixture {
        return @ptrCast(@alignCast(raw));
    }

    fn candidate(raw: *anyopaque) contracts.Outcome {
        const self = from(raw);
        self.push(.candidate);
        return self.candidate_result;
    }

    fn release(raw: *anyopaque) void {
        from(raw).push(.release);
    }

    fn capture(raw: *anyopaque) contracts.CheckpointCapture {
        from(raw).push(.capture);
        return .captured;
    }

    fn checkpoint(raw: *anyopaque) contracts.Progress {
        from(raw).push(.checkpoint);
        return .complete;
    }

    fn coreOk(_: *anyopaque) contracts.Outcome {
        return .ok;
    }

    fn close(raw: *anyopaque, _: i128) contracts.Outcome {
        from(raw).push(.core_close);
        return .ok;
    }

    fn validate(raw: *anyopaque, _: usize) contracts.Outcome {
        from(raw).push(.session_validate);
        return .ok;
    }

    fn reconfigure(raw: *anyopaque) contracts.Outcome {
        from(raw).push(.reconfigure);
        return .ok;
    }

    fn reconfigurationProgress(raw: *anyopaque) contracts.Progress {
        from(raw).push(.reconfiguration_progress);
        return .complete;
    }

    fn encode(raw: *anyopaque, _: connection.Handle, output: []u8) ?Continuation {
        const self = from(raw);
        self.push(.encode);
        if (output.len < 6) return null;
        @memcpy(output[0..6], "resume");
        return .{ .id = 41, .version = 3, .bytes = output[0..6] };
    }

    fn beginQuiesce(raw: *anyopaque) contracts.Outcome {
        from(raw).push(.quiesce);
        return .ok;
    }

    fn quiesceProgress(raw: *anyopaque) contracts.Progress {
        from(raw).push(.quiescence_progress);
        return .complete;
    }

    fn abort(raw: *anyopaque) contracts.Outcome {
        const self = from(raw);
        self.push(.abort);
        self.inheritable = false;
        self.aborted += 1;
        return .ok;
    }

    fn maximum(_: *anyopaque) usize {
        return 0;
    }

    fn listener(_: *anyopaque) ?std.posix.fd_t {
        return 17;
    }

    fn connectionCount(_: *anyopaque) usize {
        return 1;
    }

    fn lookupConnection(_: *anyopaque, ordinal: usize) ?TransportConnection {
        if (ordinal != 0) return null;
        return .{ .fd = 19, .handle = .{ .index = 2, .generation = 7 }, .unread = "input", .output = "output" };
    }

    fn prepare(raw: *anyopaque, _: connection.Handle) contracts.Outcome {
        const self = from(raw);
        self.push(.prepare_connection);
        self.inheritable = true;
        return .ok;
    }

    fn prepareListener(raw: *anyopaque) contracts.Outcome {
        const self = from(raw);
        self.push(.prepare_listener);
        self.inheritable = true;
        return .ok;
    }

    fn restoreSession(_: *anyopaque, _: connection.Handle, _: u32, _: u16, _: []const u8) contracts.Outcome {
        return .ok;
    }

    fn restoreTransport(_: *anyopaque, _: TransportConnection) contracts.Outcome {
        return .ok;
    }

    fn replace(raw: *anyopaque, bytes: []const u8) contracts.Outcome {
        const self = from(raw);
        self.push(.replace);
        if (bytes.len > self.image.len) return .failed;
        @memcpy(self.image[0..bytes.len], bytes);
        self.image_len = bytes.len;
        return self.executor_result;
    }

    fn reloader(self: *ReloadFixture, image: []u8, continuation: []u8) Reloader {
        return .{
            .candidate = .{ .context = self, .validate = candidate, .release = release },
            .core = .{ .context = self, .vtable = &.{ .service = coreOk, .tick = coreOk, .capture_checkpoint = capture, .checkpoint_progress = checkpoint, .begin_close = close, .close_progress = checkpoint, .take_control = noControlRequest, .control_result = ignoreControlResult } },
            .sessions = .{ .context = self, .vtable = &.{ .validate_resume = validate, .begin_reconfiguration = reconfigure, .reconfiguration_progress = reconfigurationProgress, .abort_reconfiguration = abort, .encode = encode, .restore = restoreSession } },
            .transport = .{ .context = self, .vtable = &.{ .begin_quiesce = beginQuiesce, .quiesce_progress = quiesceProgress, .abort_quiesce = abort, .maximum_resume_bytes = maximum, .listener = listener, .connection_count = connectionCount, .connection = lookupConnection, .prepare_for_exec = prepare, .prepare_listener_for_exec = prepareListener, .restore = restoreTransport } },
            .executor = .{ .context = self, .replace = replace },
            .image = image,
            .continuation = continuation,
        };
    }
};

fn noControlRequest(_: *anyopaque) ?contracts.ControlRequest {
    return null;
}

fn ignoreControlResult(_: *anyopaque, _: contracts.ControlRequest, _: bool) void {}

test "reload orders capture configuration quiescence and exact envelope" {
    var fixture = ReloadFixture{};
    var image: [256]u8 = undefined;
    var continuation: [16]u8 = undefined;
    var item = fixture.reloader(&image, &continuation);
    try std.testing.expect(item.request());
    for (0..7) |_| try std.testing.expectEqual(contracts.Outcome.ok, item.advance());
    const expected = [_]ReloadFixture.Event{ .candidate, .session_validate, .capture, .checkpoint, .reconfigure, .reconfiguration_progress, .session_validate, .quiesce, .quiescence_progress, .encode, .prepare_connection, .prepare_listener, .replace };
    try std.testing.expectEqualSlices(ReloadFixture.Event, &expected, fixture.events[0..fixture.event_count]);
    var decoder = try handoff.Decoder.init(fixture.image[0..fixture.image_len]);
    try std.testing.expectEqual(@as(std.posix.fd_t, 17), decoder.listenerFd());
    const record = (try decoder.next()).?;
    try std.testing.expectEqual(@as(std.posix.fd_t, 19), record.fd);
    try std.testing.expect(record.connection.eql(.{ .index = 2, .generation = 7 }));
    try std.testing.expectEqualStrings("input", record.unread);
    try std.testing.expectEqualStrings("output", record.output);
    try std.testing.expectEqual(@as(u32, 41), record.session_id);
    try std.testing.expectEqual(@as(u16, 3), record.session_version);
    try std.testing.expectEqualStrings("resume", record.continuation);
}

test "candidate validation failure leaves transport active" {
    var fixture = ReloadFixture{ .candidate_result = .failed };
    var image: [128]u8 = undefined;
    var continuation: [16]u8 = undefined;
    var item = fixture.reloader(&image, &continuation);
    try std.testing.expect(item.request());
    try std.testing.expectEqual(contracts.Outcome.ok, item.advance());
    try std.testing.expect(!item.requested);
    try std.testing.expect(!fixture.inheritable);
    try std.testing.expectEqual(@as(usize, 0), fixture.aborted);
    try std.testing.expectEqualSlices(ReloadFixture.Event, &.{ .candidate, .release }, fixture.events[0..fixture.event_count]);
    try std.testing.expectEqual(contracts.Outcome.ok, item.operation().beginShutdown());
    try std.testing.expectEqualSlices(ReloadFixture.Event, &.{ .candidate, .release }, fixture.events[0..fixture.event_count]);
}

test "returning executor rolls back prepared descriptors" {
    var fixture = ReloadFixture{ .executor_result = .failed, .inheritable = false };
    var image: [256]u8 = undefined;
    var continuation: [16]u8 = undefined;
    var item = fixture.reloader(&image, &continuation);
    item.phase = .serialize;
    item.requested = true;
    item.candidate_live = true;
    try std.testing.expectEqual(contracts.Outcome.ok, item.advance());
    try std.testing.expect(!item.requested);
    try std.testing.expect(!fixture.inheritable);
    try std.testing.expectEqual(@as(usize, 2), fixture.aborted);
    try std.testing.expectEqual(ReloadFixture.Event.release, fixture.events[fixture.event_count - 1]);
    for (fixture.events[0..fixture.event_count]) |event|
        try std.testing.expect(event != .core_close);
}

test "shutdown supersedes a quiescing reload" {
    var fixture = ReloadFixture{ .inheritable = true };
    var image: [128]u8 = undefined;
    var continuation: [16]u8 = undefined;
    var item = fixture.reloader(&image, &continuation);
    item.phase = .quiesce;
    item.requested = true;
    item.candidate_live = true;
    try std.testing.expectEqual(contracts.Outcome.ok, item.operation().beginShutdown());
    try std.testing.expectEqual(@as(usize, 2), fixture.aborted);
    try std.testing.expect(!fixture.inheritable);
    try std.testing.expect(!item.requested);
    try std.testing.expectEqual(Phase.idle, item.phase);
    try std.testing.expectEqual(ReloadFixture.Event.release, fixture.events[fixture.event_count - 1]);
}

test "shutdown releases a requested candidate before validation" {
    var fixture = ReloadFixture{};
    var image: [128]u8 = undefined;
    var continuation: [16]u8 = undefined;
    var item = fixture.reloader(&image, &continuation);
    try std.testing.expect(item.request());
    try std.testing.expectEqual(contracts.Outcome.ok, item.operation().beginShutdown());
    try std.testing.expectEqualSlices(ReloadFixture.Event, &.{.release}, fixture.events[0..fixture.event_count]);
    try std.testing.expect(!item.candidate_live);
}

test "reload failure before quiescence leaves transport unmodified" {
    const State = struct { quiesced: usize = 0 };
    const Stub = struct {
        fn state(raw: *anyopaque) *State {
            return @ptrCast(@alignCast(raw));
        }
        fn no(_: *anyopaque) contracts.Outcome {
            return .failed;
        }
        fn validate(_: *anyopaque, _: usize) contracts.Outcome {
            return .failed;
        }
        fn capture(_: *anyopaque) contracts.CheckpointCapture {
            return .captured;
        }
        fn progress(_: *anyopaque) contracts.Progress {
            return .complete;
        }
        fn close(_: *anyopaque, _: i128) contracts.Outcome {
            return .ok;
        }
        fn quiesce(raw: *anyopaque) contracts.Outcome {
            state(raw).quiesced += 1;
            return .ok;
        }
        fn abort(_: *anyopaque) contracts.Outcome {
            return .ok;
        }
        fn count(_: *anyopaque) usize {
            return 0;
        }
        fn maximum(_: *anyopaque) usize {
            return 0;
        }
        fn listener(_: *anyopaque) ?std.posix.fd_t {
            return 3;
        }
        fn lookup(_: *anyopaque, _: usize) ?TransportConnection {
            return null;
        }
        fn prepare(_: *anyopaque, _: connection.Handle) contracts.Outcome {
            return .ok;
        }
        fn prepareListener(_: *anyopaque) contracts.Outcome {
            return .ok;
        }
        fn restoreTransport(_: *anyopaque, _: TransportConnection) contracts.Outcome {
            return .ok;
        }
        fn encode(_: *anyopaque, _: connection.Handle, _: []u8) ?Continuation {
            return null;
        }
        fn restoreSession(_: *anyopaque, _: connection.Handle, _: u32, _: u16, _: []const u8) contracts.Outcome {
            return .ok;
        }
        fn exec(_: *anyopaque, _: []const u8) contracts.Outcome {
            return .ok;
        }
    };
    var state = State{};
    var image: [64]u8 = undefined;
    var continuation: [16]u8 = undefined;
    var item = Reloader{
        .candidate = .{ .context = &state, .validate = Stub.no },
        .core = .{ .context = &state, .vtable = &.{ .service = Stub.no, .tick = Stub.no, .capture_checkpoint = Stub.capture, .checkpoint_progress = Stub.progress, .begin_close = Stub.close, .close_progress = Stub.progress, .take_control = noControlRequest, .control_result = ignoreControlResult } },
        .sessions = .{ .context = &state, .vtable = &.{ .validate_resume = Stub.validate, .begin_reconfiguration = Stub.no, .reconfiguration_progress = Stub.progress, .abort_reconfiguration = Stub.no, .encode = Stub.encode, .restore = Stub.restoreSession } },
        .transport = .{ .context = &state, .vtable = &.{ .begin_quiesce = Stub.quiesce, .quiesce_progress = Stub.progress, .abort_quiesce = Stub.abort, .maximum_resume_bytes = Stub.maximum, .listener = Stub.listener, .connection_count = Stub.count, .connection = Stub.lookup, .prepare_for_exec = Stub.prepare, .prepare_listener_for_exec = Stub.prepareListener, .restore = Stub.restoreTransport } },
        .executor = .{ .context = &state, .replace = Stub.exec },
        .image = &image,
        .continuation = &continuation,
    };
    try std.testing.expect(item.request());
    try std.testing.expectEqual(contracts.Outcome.ok, item.advance());
    try std.testing.expectEqual(@as(usize, 0), state.quiesced);
    try std.testing.expectEqual(@as(u64, 1), item.failed_attempts);
}

test "quiesce failure resumes the active transport" {
    const State = struct { aborted: usize = 0 };
    const Stub = struct {
        fn state(raw: *anyopaque) *State {
            return @ptrCast(@alignCast(raw));
        }
        fn ok(_: *anyopaque) contracts.Outcome {
            return .ok;
        }
        fn failed(_: *anyopaque) contracts.Progress {
            return .failed;
        }
        fn abort(raw: *anyopaque) contracts.Outcome {
            state(raw).aborted += 1;
            return .ok;
        }
        fn maximum(_: *anyopaque) usize {
            return 0;
        }
        fn listener(_: *anyopaque) ?std.posix.fd_t {
            return 3;
        }
        fn count(_: *anyopaque) usize {
            return 0;
        }
        fn lookup(_: *anyopaque, _: usize) ?TransportConnection {
            return null;
        }
        fn prepare(_: *anyopaque, _: connection.Handle) contracts.Outcome {
            return .ok;
        }
        fn prepareListener(_: *anyopaque) contracts.Outcome {
            return .ok;
        }
        fn restoreTransport(_: *anyopaque, _: TransportConnection) contracts.Outcome {
            return .ok;
        }
        fn validate(_: *anyopaque, _: usize) contracts.Outcome {
            return .ok;
        }
        fn encode(_: *anyopaque, _: connection.Handle, _: []u8) ?Continuation {
            return null;
        }
        fn restoreSession(_: *anyopaque, _: connection.Handle, _: u32, _: u16, _: []const u8) contracts.Outcome {
            return .ok;
        }
        fn replace(_: *anyopaque, _: []const u8) contracts.Outcome {
            return .ok;
        }
        fn capture(_: *anyopaque) contracts.CheckpointCapture {
            return .captured;
        }
        fn close(_: *anyopaque, _: i128) contracts.Outcome {
            return .ok;
        }
    };
    var state = State{};
    var image: [64]u8 = undefined;
    var continuation: [16]u8 = undefined;
    var item = Reloader{
        .candidate = .{ .context = &state, .validate = Stub.ok },
        .core = .{ .context = &state, .vtable = &.{ .service = Stub.ok, .tick = Stub.ok, .capture_checkpoint = Stub.capture, .checkpoint_progress = Stub.failed, .begin_close = Stub.close, .close_progress = Stub.failed, .take_control = noControlRequest, .control_result = ignoreControlResult } },
        .sessions = .{ .context = &state, .vtable = &.{ .validate_resume = Stub.validate, .begin_reconfiguration = Stub.ok, .reconfiguration_progress = Stub.failed, .abort_reconfiguration = Stub.ok, .encode = Stub.encode, .restore = Stub.restoreSession } },
        .transport = .{ .context = &state, .vtable = &.{ .begin_quiesce = Stub.ok, .quiesce_progress = Stub.failed, .abort_quiesce = Stub.abort, .maximum_resume_bytes = Stub.maximum, .listener = Stub.listener, .connection_count = Stub.count, .connection = Stub.lookup, .prepare_for_exec = Stub.prepare, .prepare_listener_for_exec = Stub.prepareListener, .restore = Stub.restoreTransport } },
        .executor = .{ .context = &state, .replace = Stub.replace },
        .image = &image,
        .continuation = &continuation,
        .phase = .quiesce,
        .requested = true,
    };
    try std.testing.expectEqual(contracts.Outcome.ok, item.awaitQuiescence());
    try std.testing.expectEqual(@as(usize, 1), state.aborted);
    try std.testing.expect(!item.requested);
    try std.testing.expectEqual(@as(u64, 1), item.failed_attempts);
}

test "failed exec aborts a fully serialized reload and releases the candidate" {
    const State = struct { aborted: usize = 0, prepared: usize = 0, released: usize = 0 };
    const Stub = struct {
        fn state(raw: *anyopaque) *State {
            return @ptrCast(@alignCast(raw));
        }
        fn ok(_: *anyopaque) contracts.Outcome {
            return .ok;
        }
        fn capture(_: *anyopaque) contracts.CheckpointCapture {
            return .captured;
        }
        fn complete(_: *anyopaque) contracts.Progress {
            return .complete;
        }
        fn close(_: *anyopaque, _: i128) contracts.Outcome {
            return .ok;
        }
        fn abort(raw: *anyopaque) contracts.Outcome {
            state(raw).aborted += 1;
            return .ok;
        }
        fn release(raw: *anyopaque) void {
            state(raw).released += 1;
        }
        fn maximum(_: *anyopaque) usize {
            return handoff.header_bytes + handoff.record_bytes + 8;
        }
        fn listener(_: *anyopaque) ?std.posix.fd_t {
            return 3;
        }
        fn count(_: *anyopaque) usize {
            return 1;
        }
        fn transportConnection(_: *anyopaque, ordinal: usize) ?TransportConnection {
            if (ordinal != 0) return null;
            return .{ .fd = 4, .handle = .{ .index = 0, .generation = 1 }, .unread = "in", .output = "out" };
        }
        fn prepare(raw: *anyopaque, _: connection.Handle) contracts.Outcome {
            state(raw).prepared += 1;
            return .ok;
        }
        fn prepareListener(_: *anyopaque) contracts.Outcome {
            return .ok;
        }
        fn restoreTransport(_: *anyopaque, _: TransportConnection) contracts.Outcome {
            return .ok;
        }
        fn validate(_: *anyopaque, _: usize) contracts.Outcome {
            return .ok;
        }
        fn begin(_: *anyopaque) contracts.Outcome {
            return .ok;
        }
        fn encode(_: *anyopaque, _: connection.Handle, output: []u8) ?Continuation {
            if (output.len == 0) return null;
            output[0] = 9;
            return .{ .id = 7, .version = 1, .bytes = output[0..1] };
        }
        fn restoreSession(_: *anyopaque, _: connection.Handle, _: u32, _: u16, _: []const u8) contracts.Outcome {
            return .ok;
        }
        fn replace(_: *anyopaque, _: []const u8) contracts.Outcome {
            return .failed;
        }
    };
    var state = State{};
    var image: [128]u8 = undefined;
    var continuation: [8]u8 = undefined;
    var item = Reloader{
        .candidate = .{ .context = &state, .validate = Stub.ok, .release = Stub.release },
        .core = .{ .context = &state, .vtable = &.{ .service = Stub.ok, .tick = Stub.ok, .capture_checkpoint = Stub.capture, .checkpoint_progress = Stub.complete, .begin_close = Stub.close, .close_progress = Stub.complete, .take_control = noControlRequest, .control_result = ignoreControlResult } },
        .sessions = .{ .context = &state, .vtable = &.{ .validate_resume = Stub.validate, .begin_reconfiguration = Stub.begin, .reconfiguration_progress = Stub.complete, .abort_reconfiguration = Stub.ok, .encode = Stub.encode, .restore = Stub.restoreSession } },
        .transport = .{ .context = &state, .vtable = &.{ .begin_quiesce = Stub.ok, .quiesce_progress = Stub.complete, .abort_quiesce = Stub.abort, .maximum_resume_bytes = Stub.maximum, .listener = Stub.listener, .connection_count = Stub.count, .connection = Stub.transportConnection, .prepare_for_exec = Stub.prepare, .prepare_listener_for_exec = Stub.prepareListener, .restore = Stub.restoreTransport } },
        .executor = .{ .context = &state, .replace = Stub.replace },
        .image = &image,
        .continuation = &continuation,
    };
    try std.testing.expect(item.request());
    for (0..7) |_| try std.testing.expectEqual(contracts.Outcome.ok, item.advance());
    try std.testing.expectEqual(@as(usize, 1), state.prepared);
    try std.testing.expectEqual(@as(usize, 1), state.aborted);
    try std.testing.expectEqual(@as(usize, 1), state.released);
    try std.testing.expect(!item.requested);
    try std.testing.expect(!item.candidate_live);
}
