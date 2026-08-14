const builtin = @import("builtin");
const std = @import("std");
const abi = @import("lightning_rod").hot_reload_abi;

const State = struct { initialized: bool = false };
const supported_protocols = [_]i32{772};
var threaded: std.Io.Threaded = undefined;
var workers: std.Io.Group = .init;

fn runWorker() std.Io.Cancelable!void {
    while (true) try std.Io.sleep(threaded.io(), .fromSeconds(1), .awake);
}

fn initialize(raw: *anyopaque, _: *const abi.Initialize) callconv(.c) abi.Status {
    const state: *State = @ptrCast(@alignCast(raw));
    threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    workers.async(threaded.io(), runWorker, .{});
    state.* = .{ .initialized = true };
    return .ok;
}

fn tick(_: *anyopaque, _: *const abi.TickInvocation) callconv(.c) abi.Status {
    return .ok;
}

fn lifecycle(_: *anyopaque) callconv(.c) abi.Status {
    return .ok;
}

fn beginReconfiguration(_: *anyopaque, _: *abi.TickExchange) callconv(.c) abi.Status {
    return .ok;
}

fn deinitialize(raw: *anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(raw));
    std.debug.assert(state.initialized);
    workers.cancel(threaded.io());
    threaded.deinit();
    state.initialized = false;
}

fn setProfiling(_: *anyopaque, _: u8) callconv(.c) void {}

fn metrics(_: *const anyopaque, output: *abi.MetricsSnapshot) callconv(.c) void {
    output.* = .{};
}

const descriptor = abi.Descriptor{
    .header = abi.Header.init(abi.Descriptor),
    .optimize_mode = @intFromEnum(builtin.mode),
    .state_size = @sizeOf(State),
    .state_alignment = @alignOf(State),
    .state_capacity = @sizeOf(State),
    .maximum_memory_bytes = 64 * 1024 * 1024,
    .maximum_players = 1024,
    .default_gamemode = 0,
    .supported_protocols = &supported_protocols,
    .supported_protocol_count = supported_protocols.len,
};

export fn lightning_rod_tick_describe() callconv(.c) *const abi.Descriptor {
    return &descriptor;
}

export const lightning_rod_tick_initialize = initialize;
export const lightning_rod_tick = tick;
export const lightning_rod_tick_save = lifecycle;
export const lightning_rod_tick_load = lifecycle;
export const lightning_rod_tick_begin_reconfiguration = beginReconfiguration;
export const lightning_rod_tick_deinitialize = deinitialize;
export const lightning_rod_tick_set_profiling = setProfiling;
export const lightning_rod_tick_metrics = metrics;
