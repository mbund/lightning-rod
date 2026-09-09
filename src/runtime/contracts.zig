const std = @import("std");

pub const maximum_tick_ns: u64 = 50 * std.time.ns_per_ms;

pub const Outcome = enum { ok, failed };
pub const Progress = enum { pending, complete, failed };
pub const CheckpointCapture = enum { captured, busy, failed };
pub const ControlRequest = union(enum) { reload: u16 };

pub const Completion = struct {
    count: usize,
    outcome: Outcome = .ok,
};

pub const Wake = struct {
    context: *anyopaque,
    io: std.Io,
    signal_fn: *const fn (*anyopaque, std.Io) void,

    pub inline fn signal(self: Wake) void {
        self.signal_fn(self.context, self.io);
    }
};

pub const Readiness = struct {
    context: *anyopaque,
    bind_fn: *const fn (*anyopaque, Wake) Outcome,

    pub inline fn bind(self: Readiness, wake: Wake) Outcome {
        return self.bind_fn(self.context, wake);
    }
};

pub const Backend = struct {
    context: *anyopaque,
    vtable: *const VTable,
    readiness: ?Readiness = null,

    pub const VTable = struct {
        complete: *const fn (*anyopaque, std.Io, usize) Completion,
        submit: *const fn (*anyopaque, std.Io) Outcome,
        begin_shutdown: *const fn (*anyopaque, std.Io) Outcome,
        shutdown_progress: *const fn (*anyopaque) Progress,
        poll_interval_ns: ?*const fn (*anyopaque) ?u64 = null,
    };

    pub inline fn complete(self: Backend, io: std.Io, limit: usize) Completion {
        return self.vtable.complete(self.context, io, limit);
    }
    pub inline fn submit(self: Backend, io: std.Io) Outcome {
        return self.vtable.submit(self.context, io);
    }
    pub inline fn beginShutdown(self: Backend, io: std.Io) Outcome {
        return self.vtable.begin_shutdown(self.context, io);
    }
    pub inline fn shutdownProgress(self: Backend) Progress {
        return self.vtable.shutdown_progress(self.context);
    }
    pub inline fn pollIntervalNs(self: Backend) ?u64 {
        const callback = self.vtable.poll_interval_ns orelse return null;
        return callback(self.context);
    }
};

pub const Sessions = struct {
    context: *anyopaque,
    vtable: *const VTable,
    readiness: ?Readiness = null,

    pub const VTable = struct {
        advance: *const fn (*anyopaque) Outcome,
        take_input: *const fn (*anyopaque) Outcome,
        finish_input: *const fn (*anyopaque) Outcome,
        stop_accepting: *const fn (*anyopaque) Outcome,
        stage_final_detachments: *const fn (*anyopaque) Outcome,
        fatal_disconnect: *const fn (*anyopaque) Progress,
        shutdown_progress: *const fn (*anyopaque) Progress,
    };

    pub inline fn advance(self: Sessions) Outcome {
        return self.vtable.advance(self.context);
    }
    pub inline fn takeInput(self: Sessions) Outcome {
        return self.vtable.take_input(self.context);
    }
    pub inline fn finishInput(self: Sessions) Outcome {
        return self.vtable.finish_input(self.context);
    }
    pub inline fn stopAccepting(self: Sessions) Outcome {
        return self.vtable.stop_accepting(self.context);
    }
    pub inline fn stageFinalDetachments(self: Sessions) Outcome {
        return self.vtable.stage_final_detachments(self.context);
    }
    pub inline fn fatalDisconnect(self: Sessions) Progress {
        return self.vtable.fatal_disconnect(self.context);
    }
    pub inline fn shutdownProgress(self: Sessions) Progress {
        return self.vtable.shutdown_progress(self.context);
    }
};

pub const Core = struct {
    context: *anyopaque,
    vtable: *const VTable,
    readiness: ?Readiness = null,

    pub const VTable = struct {
        service: *const fn (*anyopaque) Outcome,
        tick: *const fn (*anyopaque) Outcome,
        capture_checkpoint: *const fn (*anyopaque) CheckpointCapture,
        checkpoint_progress: *const fn (*anyopaque) Progress,
        begin_close: *const fn (*anyopaque, i128) Outcome,
        close_progress: *const fn (*anyopaque) Progress,
        take_control: *const fn (*anyopaque) ?ControlRequest,
        control_result: *const fn (*anyopaque, ControlRequest, bool) void,
    };

    pub inline fn service(self: Core) Outcome {
        return self.vtable.service(self.context);
    }
    pub inline fn tick(self: Core) Outcome {
        return self.vtable.tick(self.context);
    }
    pub inline fn captureCheckpoint(self: Core) CheckpointCapture {
        return self.vtable.capture_checkpoint(self.context);
    }
    pub inline fn checkpointProgress(self: Core) Progress {
        return self.vtable.checkpoint_progress(self.context);
    }
    pub inline fn beginClose(self: Core, deadline_ns: i128) Outcome {
        return self.vtable.begin_close(self.context, deadline_ns);
    }
    pub inline fn closeProgress(self: Core) Progress {
        return self.vtable.close_progress(self.context);
    }
    pub inline fn takeControl(self: Core) ?ControlRequest {
        return self.vtable.take_control(self.context);
    }
    pub inline fn controlResult(self: Core, request: ControlRequest, accepted: bool) void {
        self.vtable.control_result(self.context, request, accepted);
    }
};

pub const Reloader = Operation;

pub const Operation = struct {
    context: *anyopaque,
    vtable: *const VTable,
    readiness: ?Readiness = null,

    pub const VTable = struct {
        complete: *const fn (*anyopaque, usize) Completion,
        advance: *const fn (*anyopaque) Outcome,
        blocks_core: ?*const fn (*anyopaque) bool = null,
        request: ?*const fn (*anyopaque) Outcome = null,
        begin_shutdown: *const fn (*anyopaque) Outcome,
        shutdown_progress: *const fn (*anyopaque) Progress,
    };

    pub inline fn complete(self: Operation, limit: usize) Completion {
        return self.vtable.complete(self.context, limit);
    }
    pub inline fn advance(self: Operation) Outcome {
        return self.vtable.advance(self.context);
    }
    pub inline fn blocksCore(self: Operation) bool {
        const callback = self.vtable.blocks_core orelse return false;
        return callback(self.context);
    }
    pub inline fn request(self: Operation) Outcome {
        const callback = self.vtable.request orelse return .failed;
        return callback(self.context);
    }
    pub inline fn beginShutdown(self: Operation) Outcome {
        return self.vtable.begin_shutdown(self.context);
    }
    pub inline fn shutdownProgress(self: Operation) Progress {
        return self.vtable.shutdown_progress(self.context);
    }
};

pub const Shutdown = struct {
    context: *anyopaque,
    vtable: *const VTable,
    readiness: ?Readiness = null,

    pub const VTable = struct {
        requested: *const fn (*anyopaque) bool,
        begin: *const fn (*anyopaque) Outcome,
    };

    pub inline fn requested(self: Shutdown) bool {
        return self.vtable.requested(self.context);
    }
    pub inline fn begin(self: Shutdown) Outcome {
        return self.vtable.begin(self.context);
    }
};
