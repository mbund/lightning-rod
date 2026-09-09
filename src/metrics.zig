pub const Plugin = struct {
    id_ptr: [*]const u8 = "".ptr,
    id_len: usize = 0,
    total_ns: u64 = 0,
    window_ns: u64 = 0,
    last_ns: u64 = 0,
    max_ns: u64 = 0,
    generation_bytes: u64 = 0,
    tick_memory_total_bytes: u64 = 0,
    tick_memory_window_bytes: u64 = 0,
    tick_memory_last_bytes: u64 = 0,
    tick_memory_max_bytes: u64 = 0,

    pub fn id(self: Plugin) []const u8 {
        return self.id_ptr[0..self.id_len];
    }
};

pub const Trace = struct {
    plugin_index: usize = 0,
    name_ptr: [*]const u8 = "".ptr,
    name_len: usize = 0,
    total_ns: u64 = 0,
    window_ns: u64 = 0,
    last_ns: u64 = 0,
    max_ns: u64 = 0,
    total_calls: u64 = 0,
    window_calls: u64 = 0,
    last_calls: u32 = 0,
    max_calls: u32 = 0,

    pub fn name(self: Trace) []const u8 {
        return self.name_ptr[0..self.name_len];
    }
};

pub const Snapshot = struct {
    revision: u64 = 0,
    tick_count: u64 = 0,
    tick_total_ns: u64 = 0,
    tick_window_ns: u64 = 0,
    tick_last_ns: u64 = 0,
    tick_max_ns: u64 = 0,
    window_count: usize = 0,
    plugin_count: usize = 0,
    plugins: []Plugin = &.{},
    trace_count: usize = 0,
    traces: []Trace = &.{},
    world_tick: u64 = 0,
    living_entities: usize = 0,
    item_entities: usize = 0,
    resident_sections: usize = 0,
    modified_blocks: usize = 0,
    pending_terrain_chunks: usize = 0,
    terrain_last_ns: u64 = 0,
    terrain_max_ns: u64 = 0,
    generation_memory_bytes: u64 = 0,
    tick_memory_capacity_bytes: u64 = 0,
};

pub const Source = struct {
    context: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        snapshot: *const fn (*const anyopaque) *const Snapshot,
    };

    pub inline fn snapshot(self: Source) *const Snapshot {
        return self.vtable.snapshot(self.context);
    }
};

pub fn static(snapshot: *const Snapshot) Source {
    return .{ .context = snapshot, .vtable = &static_vtable };
}

fn staticSnapshot(context: *const anyopaque) *const Snapshot {
    return @ptrCast(@alignCast(context));
}

const static_vtable: Source.VTable = .{ .snapshot = staticSnapshot };

test "a static source returns its immutable snapshot" {
    const snapshot: Snapshot = .{ .revision = 7, .tick_count = 42 };
    const source = static(&snapshot);
    try @import("std").testing.expectEqual(@as(u64, 7), source.snapshot().revision);
    try @import("std").testing.expectEqual(@as(u64, 42), source.snapshot().tick_count);
}
