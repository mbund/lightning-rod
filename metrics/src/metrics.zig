const std = @import("std");

const assert = std.debug.assert;

pub const Counter = enum {
    bytes,
    records,
    misses,
    waits,
};

pub const Options = struct {
    enabled: bool = true,
    cpu: bool = false,
};

pub const Record = struct {
    name: []const u8 = "",
    parent: ?usize = null,
    calls: u64 = 0,
    last_ns: u64 = 0,
    max_ns: u64 = 0,
    total_ns: u64 = 0,
    exclusive_ns: u64 = 0,
    cpu_ns: u64 = 0,
    exclusive_cpu_ns: u64 = 0,
    child_ns: u64 = 0,
    child_cpu_ns: u64 = 0,
    counters: [4]u64 = @splat(0),
    persistent_bytes: u64 = 0,
    temporary_bytes: u64 = 0,
};

/// One owner thread. Read snapshots only at a quiescent boundary, or copy them
/// through the owner's existing message channel. Async jobs own separate records.
pub const Recorder = struct {
    io: std.Io,
    records: []Record,
    enabled: bool = true,
    cpu: bool = false,
    current: ?usize = null,
    depth: usize = 0,

    pub fn begin(self: *Recorder, index: usize) Scope {
        assert(index < self.records.len);
        if (!self.enabled)
            return .{};

        const record = &self.records[index];
        var ancestor = self.current;

        while (ancestor) |id| {
            assert(id != index);
            ancestor = self.records[id].parent;
        }

        assert(record.calls == 0 or record.parent == self.current);
        record.parent = self.current;
        const scope: Scope = .{
            .owner = self,
            .index = index,
            .parent = self.current,
            .depth = self.depth,
            .started = std.Io.Clock.now(.awake, self.io).nanoseconds,
            .cpu_started = if (self.cpu) std.Io.Clock.now(.cpu_thread, self.io).nanoseconds else 0,
            .children = record.child_ns,
            .children_cpu = record.child_cpu_ns,
        };
        self.current = index;
        self.depth += 1;
        return scope;
    }

    pub fn snapshot(self: *const Recorder, destination: []Record) void {
        assert(self.current == null and self.depth == 0);
        assert(destination.len == self.records.len);
        @memcpy(destination, self.records);
    }

    pub fn merge(self: *Recorder, source: []const Record) void {
        assert(self.current == null and self.depth == 0);
        assert(source.len == self.records.len);

        for (self.records, source) |*target, record| {
            assert(std.mem.eql(u8, target.name, record.name));
            if (record.calls == 0)
                continue;

            assert(target.calls == 0 or target.parent == record.parent);
            target.parent = record.parent;
            target.calls +|= record.calls;
            target.last_ns = record.last_ns;
            target.max_ns = @max(target.max_ns, record.max_ns);
            target.total_ns +|= record.total_ns;
            target.exclusive_ns +|= record.exclusive_ns;
            target.cpu_ns +|= record.cpu_ns;
            target.exclusive_cpu_ns +|= record.exclusive_cpu_ns;
            target.child_ns +|= record.child_ns;
            target.child_cpu_ns +|= record.child_cpu_ns;

            for (&target.counters, record.counters) |*value, addend|
                value.* +|= addend;
        }
    }

    pub fn log(self: *const Recorder, subsystem: []const u8) void {
        assert(self.current == null and self.depth == 0);

        for (self.records) |record| {
            if (record.calls == 0)
                continue;

            std.log.info("event=scope subsystem={s} name={s} parent={s} calls={d} ns={d} exclusive_ns={d} cpu_ns={d} max_ns={d} bytes={d} records={d} misses={d} waits={d}", .{
                subsystem,
                record.name,
                if (record.parent) |p| self.records[p].name else "-",
                record.calls,
                record.total_ns,
                record.exclusive_ns,
                record.cpu_ns,
                record.max_ns,
                record.counters[0],
                record.counters[1],
                record.counters[2],
                record.counters[3],
            });
        }
    }
};

pub const Scope = struct {
    owner: ?*Recorder = null,
    index: usize = 0,
    parent: ?usize = null,
    depth: usize = 0,
    started: i96 = 0,
    cpu_started: i96 = 0,
    children: u64 = 0,
    children_cpu: u64 = 0,

    pub fn add(self: Scope, counter: Counter, amount: u64) void {
        const owner = self.owner orelse return;
        assert(owner.current == self.index and owner.depth == self.depth + 1);
        owner.records[self.index].counters[@intFromEnum(counter)] +|= amount;
    }

    pub fn end(self: Scope) void {
        const owner = self.owner orelse return;
        assert(owner.current == self.index and owner.depth == self.depth + 1);
        const elapsed: u64 = @intCast(std.Io.Clock.now(.awake, owner.io).nanoseconds - self.started);
        const cpu: u64 = if (owner.cpu) @intCast(std.Io.Clock.now(.cpu_thread, owner.io).nanoseconds - self.cpu_started) else 0;
        const record = &owner.records[self.index];
        assert(elapsed >= record.child_ns - self.children);
        assert(cpu >= record.child_cpu_ns - self.children_cpu);
        record.last_ns = elapsed;
        record.max_ns = @max(record.max_ns, elapsed);
        record.total_ns +|= elapsed;
        record.exclusive_ns +|= elapsed - (record.child_ns - self.children);
        record.cpu_ns +|= cpu;
        record.exclusive_cpu_ns +|= cpu - (record.child_cpu_ns - self.children_cpu);
        record.calls +|= 1;

        if (self.parent) |parent| {
            owner.records[parent].child_ns +|= elapsed;
            owner.records[parent].child_cpu_ns +|= cpu;
        }

        owner.current = self.parent;
        owner.depth -= 1;
    }
};

pub fn Metrics(comptime Names: type) type {
    const fields = @typeInfo(Names).@"enum".fields;

    for (fields, 0..) |field, i|
        if (field.value != i)
            @compileError("metric scope enum must be contiguous from zero");

    return struct {
        const Self = @This();
        records: [fields.len]Record = initRecords(),
        recorder: Recorder = undefined,

        pub fn init(io: std.Io, options: Options) Self {
            return .{
                .recorder = .{
                    .io = io,
                    .records = &.{},
                    .enabled = options.enabled,
                    .cpu = options.cpu,
                },
            };
        }

        pub fn begin(self: *Self, name: Names) TypedScope {
            self.recorder.records = &self.records;
            return .{
                .owner = self,
                .scope = self.recorder.begin(@intFromEnum(name)),
            };
        }

        pub fn get(self: *const Self, name: Names) *const Record {
            return &self.records[@intFromEnum(name)];
        }

        pub fn merge(self: *Self, records: []const Record) void {
            self.recorder.records = &self.records;
            self.recorder.merge(records);
        }

        pub fn snapshot(self: *Self, destination: []Record) void {
            self.recorder.records = &self.records;
            self.recorder.snapshot(destination);
        }

        pub fn log(self: *Self, subsystem: []const u8) void {
            self.recorder.records = &self.records;
            self.recorder.log(subsystem);
        }

        pub const TypedScope = struct {
            owner: *Self,
            scope: Scope,

            pub fn begin(self: TypedScope, name: Names) TypedScope {
                assert(!self.owner.recorder.enabled or self.owner.recorder.current == self.scope.index);
                return self.owner.begin(name);
            }

            pub fn add(self: TypedScope, counter: Counter, amount: u64) void {
                self.scope.add(counter, amount);
            }

            pub fn end(self: TypedScope) void {
                self.scope.end();
            }
        };

        fn initRecords() [fields.len]Record {
            var result: [fields.len]Record = undefined;

            for (&result, fields) |*record, field|
                record.* = .{ .name = field.name };

            return result;
        }
    };
}
