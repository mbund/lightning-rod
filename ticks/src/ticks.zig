//! Scheduled block ticks: systems schedule an event at a block for a later game tick, and their
//! handler runs then, in vanilla's order. Ticks run only in the ticking domain. A column that
//! leaves it parks its ticks, which are saved with the delay they had left and dropped from
//! memory at the next checkpoint, and loaded again when the column ticks once more. Memory holds
//! the ticks of ticking columns and of columns that left since the last checkpoint.

const std = @import("std");
const records = @import("records");
const storage = @import("storage");
const Domains = @import("domains").domains.Domains;
const DomainColumn = @import("domains").domains.Column;
const queue = @import("queue.zig");

const assert = std.debug.assert;

pub const Column = queue.Column;
pub const Position = queue.Position;
pub const Priority = queue.Priority;
pub const Kind = queue.Kind;
pub const Event = queue.Event;
pub const Scheduler = queue.Scheduler;

pub const Ticks = struct {
    pub const id = "lightning_rod:ticks";

    pub const Configuration = struct {
        /// Ticks scheduled or parked at once.
        events: u32 = 1 << 16,
        /// Columns kept in memory past ticking, waiting for a checkpoint. Room for every column that
        /// may tick comes from Domains.
        columns: u32 = 1 << 12,
        /// Ticks run in one game tick. Vanilla runs at most 65536.
        per_tick: u32 = 1 << 16,
        /// Ticks one column may save.
        column_events: u32 = 1 << 14,
        /// Kinds of tick that may be registered.
        kinds: u16 = 64,
    };

    pub const Dependencies = struct {
        domains: *Domains,
        record_workspaces: *records.Workspaces,
        storage: storage.Space,
    };

    pub const Handler = struct {
        context: *anyopaque,
        run: *const fn (*anyopaque, Event) anyerror!void,

        pub fn init(comptime Context: type, context: *Context, comptime run: fn (*Context, Event) anyerror!void) Handler {
            const Adapter = struct {
                fn call(raw: *anyopaque, event: Event) anyerror!void {
                    return run(@ptrCast(@alignCast(raw)), event);
                }
            };
            return .{ .context = context, .run = Adapter.call };
        }
    };

    const KindEntry = struct { name: []const u8, scheduler: Scheduler, handler: Handler, saved: ?u16 = null };

    /// Saved bytes per tick: local x and z, y, saved kind, priority and delay.
    const entry_bytes = 1 + 4 + 2 + 1 + 4;
    const record_version = 1;
    /// The key of the record naming saved kinds. Column keys are twelve bytes.
    const kinds_key = "kinds";
    const names_max = 64 * 64;

    deps: Dependencies,
    config: Configuration,
    queue: queue.Queue,
    kinds: []KindEntry,
    kind_count: u16 = 0,
    /// By saved kind index, the registered kind it names, if any.
    saved_kinds: []?Kind,
    saved_kind_count: u16 = 0,
    names_loaded: bool = false,
    /// The saved kind names, each a length byte and the name, then names new to this world.
    names: [names_max]u8 = undefined,
    names_length: usize = 0,
    names_dirty: bool = false,
    /// Columns that began ticking and whose saved ticks are not read yet.
    loading: []Column,
    loading_count: u32 = 0,
    overflow: bool = false,
    due: []Event,
    record: []u8,
    pending: []queue.Pending,
    started: bool = false,
    dropped: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Ticks {
        if (config.per_tick == 0 or config.column_events == 0 or config.kinds == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Ticks);
        errdefer allocator.destroy(self);
        // Every column Domains may tick can enter in one tick, as when players spread out join.
        const ticking = deps.domains.capacity();
        if (ticking + config.columns > std.math.maxInt(u32)) return error.InvalidConfiguration;
        self.* = .{
            .deps = deps,
            .config = config,
            .queue = try queue.Queue.init(allocator, .{ .events = config.events, .columns = @intCast(ticking + config.columns) }),
            .kinds = try allocator.alloc(KindEntry, config.kinds),
            .saved_kinds = try allocator.alloc(?Kind, config.kinds),
            .loading = try allocator.alloc(Column, ticking),
            .due = try allocator.alloc(Event, config.per_tick),
            .record = try allocator.alloc(u8, 1 + 4 + @as(usize, config.column_events) * entry_bytes),
            .pending = try allocator.alloc(queue.Pending, config.column_events),
        };
        try deps.domains.observe(.init(Ticks, self, changed));
        return self;
    }

    /// Storage is read only as columns load, so allocating is initializing.
    pub fn allocate(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Ticks {
        return init(allocator, config, deps);
    }

    /// Registers a kind of tick while the server starts. The name keeps saved ticks of the kind
    /// across restarts that register kinds in another order.
    pub fn register(self: *Ticks, name: []const u8, scheduler: Scheduler, handler: Handler) !Kind {
        assert(!self.started);
        if (name.len == 0 or name.len > 64) return error.InvalidName;
        for (self.kinds[0..self.kind_count]) |entry| if (std.mem.eql(u8, entry.name, name)) return error.DuplicateKind;
        if (self.kind_count == self.kinds.len) return error.KindCapacity;
        self.kinds[self.kind_count] = .{ .name = name, .scheduler = scheduler, .handler = handler };
        self.kind_count += 1;
        return self.kind_count - 1;
    }

    /// Schedules a tick `delay` game ticks from now. A tick of the same kind already scheduled
    /// at the block keeps its time, as in vanilla. Ticks in columns that do not tick wait for
    /// them to.
    pub fn schedule(self: *Ticks, event: Event, delay: u32) !void {
        assert(event.kind < self.kind_count);
        const column = Column.of(event.world, event.position);
        if (self.queue.columnState(column) == null) {
            // Ticks may be scheduled at the edge of the domain, where vanilla's chunks are
            // loaded but do not tick. The column's saved ticks come first.
            try self.loadColumns(&.{column}, true);
        }
        var queued = event;
        queued.scheduler = self.kinds[event.kind].scheduler;
        _ = self.queue.schedule(queued, delay) catch |err| switch (err) {
            error.EventCapacity => {
                self.dropped += 1;
                return error.TickCapacity;
            },
            error.Untracked => unreachable,
        };
    }

    pub fn scheduled(self: *const Ticks, event: Event) bool {
        return self.queue.scheduled(event);
    }

    pub fn now(self: *const Ticks) u64 {
        return self.queue.now;
    }

    fn changed(self: *Ticks, entered: []const DomainColumn, left: []const DomainColumn) void {
        for (left) |at| self.queue.park(.{ .world = at.world, .x = at.x, .z = at.z });
        for (entered) |at| {
            const column: Column = .{ .world = at.world, .x = at.x, .z = at.z };
            if (self.queue.columnState(column) != null) {
                self.queue.unpark(column);
                continue;
            }
            if (self.loading_count == self.loading.len) {
                self.overflow = true;
                continue;
            }
            self.loading[self.loading_count] = column;
            self.loading_count += 1;
        }
    }

    /// Ticks after Domains, so the domain is current, and before what reacts to block changes.
    pub fn tick(self: *Ticks) !void {
        self.started = true;
        if (self.overflow) return error.ColumnCapacity;
        if (self.loading_count != 0) {
            // A column may have left again before its ticks were read.
            var kept: u32 = 0;
            for (self.loading[0..self.loading_count]) |column| {
                if (!self.deps.domains.ticks(.{ .world = column.world, .x = column.x, .z = column.z }) or self.queue.columnState(column) != null) continue;
                self.loading[kept] = column;
                kept += 1;
            }
            try self.loadColumns(self.loading[0..kept], false);
            self.loading_count = 0;
        }
        self.queue.advance();
        // ServerWorld.tick runs the block scheduler and then the fluid one, each taking what is
        // due before it runs any, at most 65536 by default.
        for ([_]Scheduler{ .block, .fluid }) |scheduler| {
            const count = self.queue.takeDue(scheduler, self.due);
            for (self.due[0..count]) |event| try self.kinds[event.kind].handler.run(self.kinds[event.kind].handler.context, event);
        }
    }

    fn loadColumns(self: *Ticks, columns: []const Column, parked: bool) !void {
        try self.loadNames();
        const table = records.Table.init(self.deps.storage, self.deps.record_workspaces.resources);
        for (columns) |column| {
            const state = try self.queue.track(column, parked);
            const key = columnKey(column);
            const length = try table.get(&key, self.record) orelse continue;
            try self.decode(column, self.record[0..length]);
            // What was just read is what is saved.
            state.dirty = false;
        }
    }

    fn decode(self: *Ticks, column: Column, bytes: []const u8) !void {
        if (bytes.len < 5 or bytes[0] != record_version) return error.CorruptTicks;
        const count = std.mem.readInt(u32, bytes[1..5], .little);
        if (bytes.len != 5 + @as(usize, count) * entry_bytes) return error.CorruptTicks;
        for (0..count) |index| {
            const entry = bytes[5 + index * entry_bytes ..][0..entry_bytes];
            const saved = std.mem.readInt(u16, entry[5..7], .little);
            if (saved >= self.saved_kind_count) return error.CorruptTicks;
            // Ticks of a kind no plugin registers any more are dropped.
            const kind = self.saved_kinds[saved] orelse continue;
            const priority: i8 = @bitCast(entry[7]);
            if (priority < -3 or priority > 3) return error.CorruptTicks;
            const event: Event = .{
                .world = column.world,
                .position = .{ .x = column.x * 16 + (entry[0] & 15), .y = std.mem.readInt(i32, entry[1..5], .little), .z = column.z * 16 + (entry[0] >> 4) },
                .kind = kind,
                .priority = @fromBackingInt(@intCast(priority)),
                .scheduler = self.kinds[kind].scheduler,
            };
            _ = self.queue.schedule(event, std.mem.readInt(u32, entry[8..12], .little)) catch |err| switch (err) {
                error.EventCapacity => return error.TickCapacity,
                error.Untracked => unreachable,
            };
        }
    }

    /// Reads the names of saved kinds once, and gives each registered kind its saved index.
    fn loadNames(self: *Ticks) !void {
        if (self.names_loaded) return;
        self.names_loaded = true;
        @memset(self.saved_kinds, null);
        const table = records.Table.init(self.deps.storage, self.deps.record_workspaces.resources);
        const bytes = &self.names;
        if (try table.get(kinds_key, bytes)) |length| {
            self.names_length = length;
            var at: usize = 0;
            while (at < length) {
                const size = bytes[at];
                if (size == 0 or at + 1 + size > length or self.saved_kind_count == self.saved_kinds.len) return error.CorruptTicks;
                const name = bytes[at + 1 ..][0..size];
                for (self.kinds[0..self.kind_count], 0..) |*entry, kind| if (std.mem.eql(u8, entry.name, name)) {
                    entry.saved = self.saved_kind_count;
                    self.saved_kinds[self.saved_kind_count] = @intCast(kind);
                };
                self.saved_kind_count += 1;
                at += 1 + size;
            }
        }
        // Kinds new to this world are named after the saved ones.
        for (self.kinds[0..self.kind_count], 0..) |*entry, kind| if (entry.saved == null) {
            if (self.saved_kind_count == self.saved_kinds.len) return error.KindCapacity;
            entry.saved = self.saved_kind_count;
            self.saved_kinds[self.saved_kind_count] = @intCast(kind);
            self.saved_kind_count += 1;
            if (self.names_length + 1 + entry.name.len > self.names.len) return error.KindCapacity;
            self.names[self.names_length] = @intCast(entry.name.len);
            @memcpy(self.names[self.names_length + 1 ..][0..entry.name.len], entry.name);
            self.names_length += 1 + entry.name.len;
            self.names_dirty = true;
        };
    }

    pub fn checkpoint(self: *Ticks, space: storage.Space) !void {
        try self.loadNames();
        const table = records.Table.init(space, self.deps.record_workspaces.resources);
        // Names of kinds no plugin registers any more stay, so their saved ticks keep their kind.
        if (self.names_dirty) {
            try table.put(kinds_key, self.names[0..self.names_length]);
            self.names_dirty = false;
        }
        // Every tracked column with changes, ticking or parked, is written. Parked columns are
        // then dropped, as their ticks are saved, so memory holds ticking columns only.
        for (self.queue.column_states) |*state| {
            if (!state.live) continue;
            if (state.dirty) try self.save(table, state.column);
            state.dirty = false;
            if (state.parked) self.queue.forget(state.column);
        }
    }

    fn save(self: *Ticks, table: records.Table, column: Column) !void {
        const count = self.queue.pending(column, self.pending);
        if (count > self.pending.len) return error.ColumnTickCapacity;
        const key = columnKey(column);
        if (count == 0) return table.put(&key, null);
        self.record[0] = record_version;
        std.mem.writeInt(u32, self.record[1..5], @intCast(count), .little);
        for (self.pending[0..count], 0..) |item, index| {
            const entry = self.record[5 + index * entry_bytes ..][0..entry_bytes];
            const event = item.event;
            entry[0] = @intCast((event.position.x & 15) | ((event.position.z & 15) << 4));
            std.mem.writeInt(i32, entry[1..5], event.position.y, .little);
            std.mem.writeInt(u16, entry[5..7], self.kinds[event.kind].saved.?, .little);
            entry[7] = @bitCast(@backingInt(event.priority));
            std.mem.writeInt(u32, entry[8..12], std.math.cast(u32, item.delay) orelse std.math.maxInt(u32), .little);
        }
        try table.put(&key, self.record[0 .. 5 + count * entry_bytes]);
    }

    fn columnKey(column: Column) [12]u8 {
        var key: [12]u8 = undefined;
        std.mem.writeInt(u32, key[0..4], column.world, .big);
        std.mem.writeInt(i32, key[4..8], column.x, .big);
        std.mem.writeInt(i32, key[8..12], column.z, .big);
        return key;
    }
};
