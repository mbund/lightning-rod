const builtin = @import("builtin");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const contracts = lightning_rod.runtime;
const handoff = @import("restart_handoff.zig");
const handoff_fd = @import("reexec_handoff_fd.zig");
const manifest = @import("reexec_manifest.zig");
const reload = @import("reexec_reload.zig");
const executor = @import("reexec_executor.zig");
const host_reexec = @import("reexec.zig");
const connection = lightning_rod.connection;

pub export const lightning_rod_resume_manifest linksection(manifest.section_name) = manifest.make(
    &.{772},
    session_id,
    session_version,
    1,
    continuation_capacity,
    handoff_capacity,
);

const session_id = 0x5245_4558;
const session_version = 1;
const continuation_capacity = 64;
const handoff_capacity = 512;
const child_flag = "--lightning-rod-reexec-integration-child";
const returning_flag = "--lightning-rod-reexec-integration-returning";

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .linux) return;
    bindLifetimeToParent();
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (!has(arguments, child_flag)) return parent(init, arguments);
    if (hasHandoff(arguments)) return verifySuccessor(init, arguments);
    try triggerReplacement(init, arguments, has(arguments, returning_flag));
}

fn parent(init: std.process.Init, arguments: []const [:0]const u8) !void {
    if (arguments.len == 0) return error.MissingExecutable;
    try runChild(init, &.{ arguments[0], child_flag });
    try runChild(init, &.{ arguments[0], child_flag, returning_flag });
}

fn runChild(init: std.process.Init, arguments: []const []const u8) !void {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = arguments,
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = std.time.ns_per_s } } },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.ChildFailed;
    if (hasSlice(arguments, returning_flag)) {
        if (!std.mem.eql(u8, result.stderr, "reexec-returning-rollback-ok\n")) return error.InvalidRollbackReport;
    } else if (!std.mem.eql(u8, result.stdout, "reexec-success configuration-complete\n")) return error.InvalidSuccessorReport;
}

fn triggerReplacement(init: std.process.Init, arguments: []const [:0]const u8, returning: bool) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var image: [handoff_capacity]u8 = undefined;
    var continuation: [continuation_capacity]u8 = undefined;
    var candidate = host_reexec.SelfCandidate(4){
        .executable = arguments[0],
        .arguments = arguments,
        .expected = &lightning_rod_resume_manifest,
    };
    var actual_executor = executor.Execve(4){
        .arguments = arguments,
        .environment = init.minimal.environ.block.slice,
        .candidate_fd = &candidate.validated_fd,
    };
    const selected_executor = if (returning) fixture.returningExecutor() else actual_executor.executor();
    var item = fixture.reloader(candidate.candidate(), selected_executor, &image, &continuation);
    if (!item.request()) return error.RequestRejected;
    const operation = item.operation();
    for (0..7) |_| if (operation.advance() != .ok) return error.ReloadFailed;
    if (returning) try verifyReturning(&fixture, &candidate, &item);
}

fn verifySuccessor(init: std.process.Init, arguments: []const [:0]const u8) !void {
    var storage: [handoff_capacity]u8 = undefined;
    var inherited = (try host_reexec.inherited(arguments, &storage)) orelse return error.MissingHandoff;
    defer inherited.close();
    var decoder = try handoff.Decoder.init(inherited.bytes);
    try expectOpen(decoder.listenerFd());
    const record = (try decoder.next()) orelse return error.MissingConnection;
    try expectOpen(record.fd);
    if (!record.connection.eql(.{ .index = 0, .generation = 1 }) or
        !std.mem.eql(u8, record.unread, "wire") or
        !std.mem.eql(u8, record.output, "queued") or
        record.session_id != session_id or record.session_version != session_version or
        !std.mem.eql(u8, record.continuation, "configuration-complete")) return error.InvalidHandoff;
    if ((try decoder.next()) != null) return error.InvalidHandoff;
    try std.Io.File.stdout().writeStreamingAll(init.io, "reexec-success configuration-complete\n");
}

fn verifyReturning(fixture: *const Fixture, candidate: *const host_reexec.SelfCandidate(4), item: *const reload.Reloader) !void {
    if (fixture.configuration_starts != 1 or fixture.configuration_completes != 1 or fixture.abort_count != 2 or
        candidate.validated_fd != null or item.requested or item.phase != .idle or
        !closeOnExec(fixture.listener_fd) or !closeOnExec(fixture.client_fd)) return error.RollbackFailed;
    std.debug.print("reexec-returning-rollback-ok\n", .{});
}

const Fixture = struct {
    listener_fd: std.posix.fd_t,
    client_fd: std.posix.fd_t,
    configuration_starts: u8 = 0,
    configuration_completes: u8 = 0,
    abort_count: u8 = 0,

    fn init() !Fixture {
        return .{ .listener_fd = try descriptor("reexec-listener"), .client_fd = try descriptor("reexec-client") };
    }

    fn deinit(self: *Fixture) void {
        _ = std.os.linux.close(self.listener_fd);
        _ = std.os.linux.close(self.client_fd);
    }

    fn reloader(self: *Fixture, candidate: reload.Candidate, selected_executor: reload.Executor, image: []u8, continuation: []u8) reload.Reloader {
        return .{
            .candidate = candidate,
            .core = .{ .context = self, .vtable = &core_vtable },
            .sessions = .{ .context = self, .vtable = &sessions_vtable },
            .transport = .{ .context = self, .vtable = &transport_vtable },
            .executor = selected_executor,
            .image = image,
            .continuation = continuation,
        };
    }

    fn returningExecutor(self: *Fixture) reload.Executor {
        return .{ .context = self, .replace = returningReplace };
    }

    fn from(raw: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(raw));
    }

    fn coreOk(_: *anyopaque) contracts.Outcome {
        return .ok;
    }
    fn capture(_: *anyopaque) contracts.CheckpointCapture {
        return .captured;
    }
    fn complete(_: *anyopaque) contracts.Progress {
        return .complete;
    }
    fn noControl(_: *anyopaque) ?contracts.ControlRequest {
        return null;
    }
    fn controlResult(_: *anyopaque, _: contracts.ControlRequest, _: bool) void {}

    fn validate(_: *anyopaque, capacity: usize) contracts.Outcome {
        return if (capacity >= continuation_capacity) .ok else .failed;
    }
    fn beginConfiguration(raw: *anyopaque) contracts.Outcome {
        from(raw).configuration_starts += 1;
        return .ok;
    }
    fn configurationProgress(raw: *anyopaque) contracts.Progress {
        from(raw).configuration_completes += 1;
        return .complete;
    }
    fn abort(raw: *anyopaque) contracts.Outcome {
        from(raw).abort_count += 1;
        return .ok;
    }
    fn encode(_: *anyopaque, _: connection.Handle, output: []u8) ?reload.Continuation {
        const bytes = "configuration-complete";
        if (output.len < bytes.len) return null;
        @memcpy(output[0..bytes.len], bytes);
        return .{ .id = session_id, .version = session_version, .bytes = output[0..bytes.len] };
    }
    fn restore(_: *anyopaque, _: connection.Handle, _: u32, _: u16, _: []const u8) contracts.Outcome {
        return .ok;
    }

    fn quiesce(_: *anyopaque) contracts.Outcome {
        return .ok;
    }
    fn quiescence(_: *anyopaque) contracts.Progress {
        return .complete;
    }
    fn maximum(_: *anyopaque) usize {
        return handoff_capacity;
    }
    fn listener(raw: *anyopaque) ?std.posix.fd_t {
        return from(raw).listener_fd;
    }
    fn connectionCount(_: *anyopaque) usize {
        return 1;
    }
    fn connectionAt(raw: *anyopaque, ordinal: usize) ?reload.TransportConnection {
        if (ordinal != 0) return null;
        return .{ .fd = from(raw).client_fd, .handle = .{ .index = 0, .generation = 1 }, .unread = "wire", .output = "queued" };
    }
    fn prepareConnection(raw: *anyopaque, _: connection.Handle) contracts.Outcome {
        handoff_fd.HandoffFd.prepareForExec(from(raw).client_fd) catch return .failed;
        return .ok;
    }
    fn prepareListener(raw: *anyopaque) contracts.Outcome {
        handoff_fd.HandoffFd.prepareForExec(from(raw).listener_fd) catch return .failed;
        return .ok;
    }
    fn abortQuiesce(raw: *anyopaque) contracts.Outcome {
        const self = from(raw);
        handoff_fd.HandoffFd.restoreCloseOnExec(self.listener_fd) catch return .failed;
        handoff_fd.HandoffFd.restoreCloseOnExec(self.client_fd) catch return .failed;
        self.abort_count += 1;
        return .ok;
    }
    fn restoreTransport(_: *anyopaque, _: reload.TransportConnection) contracts.Outcome {
        return .ok;
    }
    fn returningReplace(_: *anyopaque, _: []const u8) contracts.Outcome {
        return .failed;
    }

    const core_vtable: contracts.Core.VTable = .{
        .service = coreOk,
        .tick = coreOk,
        .capture_checkpoint = capture,
        .checkpoint_progress = complete,
        .begin_close = coreOkWithDeadline,
        .close_progress = complete,
        .take_control = noControl,
        .control_result = controlResult,
    };
    const sessions_vtable: reload.Sessions.VTable = .{
        .validate_resume = validate,
        .begin_reconfiguration = beginConfiguration,
        .reconfiguration_progress = configurationProgress,
        .abort_reconfiguration = abort,
        .encode = encode,
        .restore = restore,
    };
    const transport_vtable: reload.Transport.VTable = .{
        .begin_quiesce = quiesce,
        .quiesce_progress = quiescence,
        .abort_quiesce = abortQuiesce,
        .maximum_resume_bytes = maximum,
        .listener = listener,
        .connection_count = connectionCount,
        .connection = connectionAt,
        .prepare_for_exec = prepareConnection,
        .prepare_listener_for_exec = prepareListener,
        .restore = restoreTransport,
    };
};

fn coreOkWithDeadline(_: *anyopaque, _: i128) contracts.Outcome {
    return .ok;
}

fn descriptor(name: [:0]const u8) !std.posix.fd_t {
    return std.posix.memfd_create(name, 0x0001) catch error.DescriptorFailed;
}

fn expectOpen(fd: std.posix.fd_t) !void {
    const result = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    if (std.os.linux.errno(result) != .SUCCESS) return error.MissingInheritedDescriptor;
}

fn closeOnExec(fd: std.posix.fd_t) bool {
    const result = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    return std.os.linux.errno(result) == .SUCCESS and (@as(usize, @intCast(result)) & std.os.linux.FD_CLOEXEC) != 0;
}

fn has(arguments: []const [:0]const u8, value: []const u8) bool {
    for (arguments) |argument| if (std.mem.eql(u8, argument, value)) return true;
    return false;
}

fn hasSlice(arguments: []const []const u8, value: []const u8) bool {
    for (arguments) |argument| if (std.mem.eql(u8, argument, value)) return true;
    return false;
}

fn hasHandoff(arguments: []const [:0]const u8) bool {
    for (arguments) |argument| if (std.mem.startsWith(u8, argument, handoff_fd.HandoffFd.argument_prefix)) return true;
    return false;
}

fn bindLifetimeToParent() void {
    const parent_pid = std.posix.getppid();
    _ = std.posix.prctl(.SET_PDEATHSIG, .{@intFromEnum(std.posix.SIG.KILL)}) catch std.process.exit(1);
    if (std.posix.getppid() != parent_pid) std.process.exit(1);
}
