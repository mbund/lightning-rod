const std = @import("std");
const lightning_rod = @import("lightning_rod");
const Runtime = lightning_rod.tick_module_runtime.Runtime(@import("vanilla_plus_profile"));

pub const panic = Runtime.panic;
pub const std_options: std.Options = .{ .logFn = Runtime.logFn };

export const lightning_rod_tick_describe = Runtime.moduleDescribe;
export const lightning_rod_tick_initialize = Runtime.moduleInitialize;
export const lightning_rod_tick = Runtime.moduleTick;
export const lightning_rod_tick_save = Runtime.moduleSave;
export const lightning_rod_tick_load = Runtime.moduleLoad;
export const lightning_rod_tick_begin_reconfiguration = Runtime.moduleBeginReconfiguration;
export const lightning_rod_tick_deinitialize = Runtime.moduleDeinitialize;
export const lightning_rod_tick_set_profiling = Runtime.moduleSetProfiling;
export const lightning_rod_tick_metrics = Runtime.moduleMetrics;
