const std = @import("std");
const lightning_rod = @import("lightning_rod");

test "in-memory Host contract consumer covers lifecycle, checkpoint, and protocol selection" {
    var fixture: State = .{};
    try lightning_rod.run(server(&fixture));

    try std.testing.expectEqual(@as(usize, 3), fixture.readiness_attached);
    try std.testing.expect(fixture.player_attached);
    try std.testing.expect(fixture.player_detached);
    try std.testing.expectEqual(@as(usize, 1), fixture.checkpoints);
    try std.testing.expectEqual(lightning_rod.protocol_versions.descriptor(.version_1).protocol_number, fixture.projected_protocol);
    try std.testing.expect(fixture.persistence_committed and fixture.logging_flushed);
}

const State = struct {
    readiness_attached: usize = 0,
    player_attached: bool = false,
    player_detached: bool = false,
    detachment_staged: bool = false,
    checkpoints: usize = 0,
    ticks: usize = 0,
    projected_protocol: i32 = 0,
    shutdown_requested: bool = false,
    persistence_committed: bool = false,
    logging_flushed: bool = false,
};

fn state(raw: *anyopaque) *State {
    return @ptrCast(@alignCast(raw));
}

fn backendComplete(_: *anyopaque, _: std.Io, _: usize) lightning_rod.runtime.Completion {
    return .{ .count = 0 };
}

fn backendSubmit(_: *anyopaque, _: std.Io) lightning_rod.runtime.Outcome {
    return .ok;
}

fn backendBegin(raw: *anyopaque, _: std.Io) lightning_rod.runtime.Outcome {
    state(raw).persistence_committed = true;
    state(raw).logging_flushed = true;
    return .ok;
}

fn backendProgress(_: *anyopaque) lightning_rod.runtime.Progress {
    return .complete;
}

const backend_vtable: lightning_rod.runtime.Backend.VTable = .{
    .complete = backendComplete,
    .submit = backendSubmit,
    .begin_shutdown = backendBegin,
    .shutdown_progress = backendProgress,
};

fn bindReadiness(raw: *anyopaque, _: lightning_rod.runtime.Wake) lightning_rod.runtime.Outcome {
    state(raw).readiness_attached += 1;
    return .ok;
}

fn sessionsAdvance(_: *anyopaque) lightning_rod.runtime.Outcome {
    return .ok;
}

fn takeInput(_: *anyopaque) lightning_rod.runtime.Outcome {
    return .ok;
}

fn finishInput(_: *anyopaque) lightning_rod.runtime.Outcome {
    return .ok;
}

fn stopAccepting(_: *anyopaque) lightning_rod.runtime.Outcome {
    return .ok;
}

fn stageDetachments(raw: *anyopaque) lightning_rod.runtime.Outcome {
    state(raw).detachment_staged = true;
    return .ok;
}

fn sessionsProgress(_: *anyopaque) lightning_rod.runtime.Progress {
    return .complete;
}

const sessions_vtable: lightning_rod.runtime.Sessions.VTable = .{
    .advance = sessionsAdvance,
    .take_input = takeInput,
    .finish_input = finishInput,
    .stop_accepting = stopAccepting,
    .stage_final_detachments = stageDetachments,
    .shutdown_progress = sessionsProgress,
};

fn coreService(raw: *anyopaque) lightning_rod.runtime.Outcome {
    const item = state(raw);
    if (item.detachment_staged) item.player_detached = true else item.player_attached = true;
    item.projected_protocol = lightning_rod.protocol_versions.descriptor(.version_1).protocol_number;
    return .ok;
}

fn coreTick(raw: *anyopaque) lightning_rod.runtime.Outcome {
    const item = state(raw);
    item.ticks += 1;
    if (item.ticks == 1) item.shutdown_requested = true;
    return .ok;
}

fn captureCheckpoint(raw: *anyopaque) lightning_rod.runtime.CheckpointCapture {
    state(raw).checkpoints += 1;
    return .captured;
}

fn coreProgress(_: *anyopaque) lightning_rod.runtime.Progress {
    return .complete;
}

fn beginClose(_: *anyopaque, _: i128) lightning_rod.runtime.Outcome {
    return .ok;
}

fn noControl(_: *anyopaque) ?lightning_rod.runtime.ControlRequest {
    return null;
}

fn controlResult(_: *anyopaque, _: lightning_rod.runtime.ControlRequest, _: bool) void {}

const core_vtable: lightning_rod.runtime.Core.VTable = .{
    .service = coreService,
    .tick = coreTick,
    .capture_checkpoint = captureCheckpoint,
    .checkpoint_progress = coreProgress,
    .begin_close = beginClose,
    .close_progress = coreProgress,
    .take_control = noControl,
    .control_result = controlResult,
};

fn requested(raw: *anyopaque) bool {
    return state(raw).shutdown_requested;
}

fn beginShutdown(_: *anyopaque) lightning_rod.runtime.Outcome {
    return .ok;
}

const shutdown_vtable: lightning_rod.runtime.Shutdown.VTable = .{ .requested = requested, .begin = beginShutdown };

fn server(item: *State) lightning_rod.runtime.Server {
    const backend: lightning_rod.runtime.Backend = .{
        .context = item,
        .vtable = &backend_vtable,
        .readiness = .{ .context = item, .bind_fn = bindReadiness },
    };
    return .{
        .io = std.testing.io,
        .transport = backend,
        .persistence = backend,
        .logging = backend,
        .shutdown = .{ .context = item, .vtable = &shutdown_vtable },
        .sessions = .{ .context = item, .vtable = &sessions_vtable },
        .core = .{ .context = item, .vtable = &core_vtable },
        .limits = .{ .tick_interval_ns = 1, .checkpoint_interval_ns = std.time.ns_per_s },
    };
}
