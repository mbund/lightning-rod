const std = @import("std");
const chunks = @import("chunks.zig");
const storage = @import("storage");
const metrics = @import("metrics");

const assert = std.debug.assert;
const section_bytes = 8193;

pub const Priority = struct {
    urgency: enum { required, occupied, streaming } = .streaming,
    distance: u32 = 0,
    player: usize = 0,
};

pub const Interest = struct { world: chunks.World, x: i32, z: i32, radius: u32 };

pub const Generation = struct {
    const batch_max = chunks.Source.batch_max;
    const State = enum { free, queued, running, ready, consuming };
    const Slot = struct {
        state: State = .free,
        owner_previous: ?usize = null,
        owner_next: ?usize = null,
        previous: ?usize = null,
        next: ?usize = null,
        children: [2]?usize = .{ null, null },
        parent: ?usize = null,
        height: u8 = 1,
        // Least valuable queued prefetch in this subtree.
        prefetch: ?usize = null,
        section: chunks.Section = undefined,
        priority: Priority = .{},
        sequence: u64 = 0,
        result: anyerror!usize = 0,
        obsolete: bool = false,
        destination: []u8 = &.{},
        token: usize = 0,
    };
    const List = struct { head: ?usize = null, tail: ?usize = null };

    /// Keep the destination pinned until completion, including canceled requests.
    pub const Request = struct { section: chunks.Section, destination: []u8, token: usize };
    pub const Update = struct { player: usize, interest: ?Interest };

    pub const Completion = struct {
        token: usize,
        sequence: u64,
        index: usize,
        section: chunks.Section,
        result: anyerror![]const u8,
    };

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    slots: []Slot,
    free: []usize,
    free_count: usize,
    queued_count: usize = 0,
    waiting: ?usize = null,
    finished: List = .{},
    index: std.AutoHashMapUnmanaged(chunks.Section, usize) = .empty,
    owners: std.AutoHashMapUnmanaged(usize, List) = .empty,
    sequence: u64 = 0,
    last_player: usize = std.math.maxInt(usize),
    next_worker: usize = 0,
    ready_count: std.atomic.Value(usize) = .init(0),
    source: ?chunks.Source = null,
    work_events: [65]?*std.Io.Event = @splat(null),
    completed: std.Io.Event = .unset,
    completion: std.Io.Condition = .init,
    completion_version: u64 = 0,
    notify: *std.Io.Event,
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    parallel: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    generated: metrics.Counter,
    queued: metrics.Gauge,
    duration: metrics.Timer,
    cpu: metrics.Timer,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize, notify: *std.Io.Event, registry: *metrics.Registry) !*Generation {
        if (capacity == 0 or capacity > 65536) return error.InvalidGenerationCapacity;
        const self = try allocator.create(Generation);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        const free_slots = try allocator.alloc(usize, capacity);
        errdefer allocator.free(free_slots);
        var index: std.AutoHashMapUnmanaged(chunks.Section, usize) = .empty;
        try index.ensureTotalCapacity(allocator, @intCast(capacity));
        errdefer index.deinit(allocator);
        var owners: std.AutoHashMapUnmanaged(usize, List) = .empty;
        try owners.ensureTotalCapacity(allocator, @intCast(capacity));
        errdefer owners.deinit(allocator);
        self.* = .{
            .owners = owners,
            .io = io,
            .slots = slots,
            .free = free_slots,
            .free_count = capacity,
            .index = index,
            .notify = notify,
            .generated = try registry.counter(.{ .name = "generation.sections", .description = "Completed terrain generation requests" }),
            .queued = try registry.gauge(.{ .name = "generation.pending", .description = "Owned generation requests and results" }),
            .duration = try registry.timer(.{ .name = "generation.batch", .description = "Process a generation batch" }),
            .cpu = try registry.timer(.{ .name = "generation.batch.cpu", .description = "Generation batch CPU time on the worker thread", .clock = .thread_cpu }),
        };
        for (self.slots, self.free, 0..) |*slot, *free, i| {
            slot.* = .{};
            free.* = capacity - i - 1;
        }
        return self;
    }

    pub fn setSource(self: *Generation, source: chunks.Source) void {
        assert(self.owner.load(.acquire) == 0 and self.source == null);
        self.source = source;
    }

    pub fn promote(self: *Generation, sections: []const chunks.Section) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (sections) |section| if (self.index.get(section)) |index| {
            var priority = self.slots[index].priority;
            priority.urgency = .required;
            self.prioritize(index, priority);
            self.slots[index].obsolete = false;
        };
    }

    pub fn update(self: *Generation, player: usize, interest: ?Interest) void {
        self.updateMany(&.{.{ .player = player, .interest = interest }});
    }

    pub fn updateMany(self: *Generation, updates: []const Update) void {
        if (updates.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var canceled = false;
        for (updates) |change| {
            const owned = self.owners.get(change.player) orelse continue;
            var current = owned.head;
            while (current) |index| {
                const slot = &self.slots[index];
                current = slot.owner_next;
                assert(slot.state != .free and slot.priority.player == change.player);
                if (slot.state == .consuming or slot.priority.urgency == .required) continue;
                if (change.interest) |view| {
                    const distance: u32 = @intCast(@max(@abs(@as(i64, slot.section.x) - view.x), @abs(@as(i64, slot.section.z) - view.z)));
                    if (view.world == slot.section.world and distance <= view.radius) {
                        slot.obsolete = false;
                        var priority = slot.priority;
                        priority.distance = distance;
                        priority.urgency = if (distance == 0) .occupied else .streaming;
                        self.prioritize(index, priority);
                        continue;
                    }
                }
                if (slot.state == .running) {
                    slot.obsolete = true;
                    slot.priority = .{ .player = change.player, .distance = std.math.maxInt(u32) };
                } else {
                    self.cancelLocked(index);
                    canceled = true;
                }
            }
        }
        if (canceled) self.signalCompletions();
        self.queued.set(self.slots.len - self.free_count);
    }

    fn linkOwner(self: *Generation, index: usize) void {
        const slot = &self.slots[index];
        assert(slot.state != .free and slot.owner_previous == null and slot.owner_next == null);
        const owned = self.owners.getOrPutAssumeCapacity(slot.priority.player);
        if (!owned.found_existing) owned.value_ptr.* = .{};
        const list = owned.value_ptr;
        slot.owner_previous = list.tail;
        if (list.tail) |tail| self.slots[tail].owner_next = index else list.head = index;
        list.tail = index;
    }

    fn unlinkOwner(self: *Generation, index: usize) void {
        const slot = &self.slots[index];
        const list = self.owners.getPtr(slot.priority.player).?;
        if (slot.owner_previous) |previous| self.slots[previous].owner_next = slot.owner_next else {
            assert(list.head == index);
            list.head = slot.owner_next;
        }
        if (slot.owner_next) |following| self.slots[following].owner_previous = slot.owner_previous else {
            assert(list.tail == index);
            list.tail = slot.owner_previous;
        }
        slot.owner_previous = null;
        slot.owner_next = null;
        if (list.head == null) {
            assert(list.tail == null);
            const removed = self.owners.remove(slot.priority.player);
            assert(removed);
        }
    }

    pub fn submit(self: *Generation, requests: []const Request, priority: Priority) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var submitted: usize = 0;
        for (requests) |request| {
            const section = request.section;
            assert(request.destination.len == section_bytes);
            if (self.index.get(section)) |index| {
                const slot = &self.slots[index];
                assert(slot.destination.ptr == request.destination.ptr and slot.token == request.token);
                if (slot.obsolete or @intFromEnum(priority.urgency) < @intFromEnum(slot.priority.urgency) or (priority.urgency == slot.priority.urgency and priority.distance < slot.priority.distance)) self.prioritize(index, priority);
                slot.obsolete = false;
                submitted += 1;
                continue;
            }
            if (self.free_count == 0) break;
            self.free_count -= 1;
            const index = self.free[self.free_count];
            assert(self.slots[index].state == .free);
            self.slots[index] = .{ .state = .queued, .section = section, .priority = priority, .sequence = self.sequence, .destination = request.destination, .token = request.token };
            self.linkOwner(index);
            self.enqueue(index);
            self.queued_count += 1;
            self.sequence += 1;
            self.index.putAssumeCapacity(section, index);
            submitted += 1;
        }
        self.queued.set(self.slots.len - self.free_count);
        if (submitted != 0) self.signalWork();
        return submitted;
    }

    /// Cancel at most limit queued requests, preserving running, completed, and required work.
    pub fn cancelPrefetch(self: *Generation, limit: usize) usize {
        assert(limit > 0 and limit <= 192);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        while (count < limit) : (count += 1) {
            const root = self.waiting orelse break;
            const index = self.slots[root].prefetch orelse break;
            assert(self.slots[index].state == .queued and self.slots[index].priority.urgency != .required);
            self.cancelLocked(index);
        }
        if (count != 0) self.signalCompletions();
        self.queued.set(self.slots.len - self.free_count);
        assert(count <= limit);
        return count;
    }

    fn reclaimLess(self: *const Generation, a: usize, b: usize) bool {
        const first = &self.slots[a];
        const second = &self.slots[b];
        if (first.priority.urgency != second.priority.urgency) return @intFromEnum(first.priority.urgency) < @intFromEnum(second.priority.urgency);
        if (first.priority.distance != second.priority.distance) return first.priority.distance < second.priority.distance;
        return first.sequence < second.sequence;
    }

    fn cancelLocked(self: *Generation, index: usize) void {
        const slot = &self.slots[index];
        assert(slot.state == .queued or slot.state == .ready);
        if (slot.state == .queued) {
            self.dequeue(index);
            self.append(&self.finished, index);
            self.queued_count -= 1;
            _ = self.ready_count.fetchAdd(1, .release);
        }
        slot.state = .ready;
        slot.result = error.Obsolete;
    }

    fn signalCompletions(self: *Generation) void {
        self.completion_version += 1;
        self.completion.broadcast(self.io);
        self.completed.set(self.io);
        self.notify.set(self.io);
    }

    pub fn take(self: *Generation, section: chunks.Section) ?Completion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.index.get(section) orelse return null;
        if (self.slots[index].state != .ready) return null;
        return self.claim(index);
    }

    pub fn next(self: *Generation) ?Completion {
        var completions: [1]Completion = undefined;
        return if (self.nextMany(&completions) == 0) null else completions[0];
    }

    pub fn nextMany(self: *Generation, completions: []Completion) usize {
        if (self.ready_count.load(.acquire) == 0) return 0;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        while (count < completions.len) : (count += 1) {
            const index = self.finished.head orelse break;
            completions[count] = self.claim(index);
        }
        assert(count <= completions.len);
        return count;
    }

    fn claim(self: *Generation, index: usize) Completion {
        const slot = &self.slots[index];
        assert(slot.state == .ready);
        self.remove(&self.finished, index);
        slot.state = .consuming;
        _ = self.ready_count.fetchSub(1, .release);
        return .{ .index = index, .token = slot.token, .sequence = slot.sequence, .section = slot.section, .result = if (slot.result) |length| slot.destination[0..length] else |err| err };
    }

    pub fn release(self: *Generation, completion: Completion) void {
        self.releaseMany(&.{completion});
    }

    pub fn releaseMany(self: *Generation, completions: []const Completion) void {
        if (completions.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (completions) |completion| {
            assert(completion.index < self.slots.len);
            const slot = &self.slots[completion.index];
            assert(slot.state == .consuming);
            assert(slot.sequence == completion.sequence and slot.token == completion.token);
            assert(std.meta.eql(slot.section, completion.section));
            self.releaseLocked(completion.index);
        }
        self.queued.set(self.slots.len - self.free_count);
    }

    fn append(self: *Generation, list: *List, index: usize) void {
        const slot = &self.slots[index];
        assert(slot.previous == null and slot.next == null);
        slot.previous = list.tail;
        if (list.tail) |tail| self.slots[tail].next = index else list.head = index;
        list.tail = index;
    }

    fn remove(self: *Generation, list: *List, index: usize) void {
        const slot = &self.slots[index];
        if (slot.previous) |previous| self.slots[previous].next = slot.next else {
            assert(list.head == index);
            list.head = slot.next;
        }
        if (slot.next) |following| self.slots[following].previous = slot.previous else {
            assert(list.tail == index);
            list.tail = slot.previous;
        }
        slot.previous = null;
        slot.next = null;
    }

    fn prioritize(self: *Generation, index: usize, priority: Priority) void {
        assert(self.slots[index].state != .free);
        if (std.meta.eql(self.slots[index].priority, priority)) return;
        const queued = self.slots[index].state == .queued;
        if (queued) self.dequeue(index);
        const moved = self.slots[index].priority.player != priority.player;
        if (moved) self.unlinkOwner(index);
        self.slots[index].priority = priority;
        if (moved) self.linkOwner(index);
        if (queued) self.enqueue(index);
    }

    fn height(self: *const Generation, index: ?usize) u8 {
        return if (index) |at| self.slots[at].height else 0;
    }

    fn refresh(self: *Generation, index: usize) void {
        const slot = &self.slots[index];
        assert(slot.state == .queued);
        slot.height = 1 + @max(self.height(slot.children[0]), self.height(slot.children[1]));
        slot.prefetch = if (slot.priority.urgency == .required) null else index;
        for (slot.children) |child| {
            const candidate = self.slots[child orelse continue].prefetch orelse continue;
            if (slot.prefetch == null or self.reclaimLess(slot.prefetch.?, candidate)) slot.prefetch = candidate;
        }
        assert(slot.height <= 32);
    }

    fn replace(self: *Generation, index: usize, replacement: ?usize) void {
        const parent = self.slots[index].parent;
        if (parent) |at| {
            const side: usize = @intFromBool(self.slots[at].children[1] == index);
            assert(self.slots[at].children[side] == index);
            self.slots[at].children[side] = replacement;
        } else {
            assert(self.waiting == index);
            self.waiting = replacement;
        }
        if (replacement) |at| self.slots[at].parent = parent;
    }

    fn rotate(self: *Generation, index: usize, side: u1) usize {
        const pivot = self.slots[index].children[side ^ 1].?;
        self.replace(index, pivot);
        self.slots[index].children[side ^ 1] = self.slots[pivot].children[side];
        if (self.slots[pivot].children[side]) |child| self.slots[child].parent = index;
        self.slots[pivot].children[side] = index;
        self.slots[index].parent = pivot;
        self.refresh(index);
        self.refresh(pivot);
        return pivot;
    }

    fn balance(self: *Generation, changed: ?usize) void {
        var current = changed;
        while (current) |index| {
            self.refresh(index);
            const children = self.slots[index].children;
            var root = index;
            if (self.height(children[0]) > self.height(children[1]) + 1) {
                const left = children[0].?;
                if (self.height(self.slots[left].children[1]) > self.height(self.slots[left].children[0])) _ = self.rotate(left, 0);
                root = self.rotate(index, 1);
            } else if (self.height(children[1]) > self.height(children[0]) + 1) {
                const right = children[1].?;
                if (self.height(self.slots[right].children[0]) > self.height(self.slots[right].children[1])) _ = self.rotate(right, 1);
                root = self.rotate(index, 0);
            }
            current = self.slots[root].parent;
        }
    }

    fn minimum(self: *const Generation, root: usize) usize {
        var index = root;
        while (self.slots[index].children[0]) |left| index = left;
        return index;
    }

    fn enqueue(self: *Generation, index: usize) void {
        const slot = &self.slots[index];
        assert(slot.state == .queued and self.waiting != index and slot.parent == null and slot.children[0] == null and slot.children[1] == null and slot.prefetch == null);
        var parent: ?usize = null;
        var current = self.waiting;
        var side: usize = 0;
        while (current) |at| {
            parent = at;
            side = @intFromBool(!ordered(slot, &self.slots[at]));
            current = self.slots[at].children[side];
        }
        slot.parent = parent;
        self.refresh(index);
        if (parent) |at| self.slots[at].children[side] = index else self.waiting = index;
        self.balance(parent);
    }

    fn dequeue(self: *Generation, index: usize) void {
        const slot = &self.slots[index];
        assert(slot.state == .queued);
        var changed = slot.parent;
        if (slot.children[0] == null or slot.children[1] == null) {
            self.replace(index, slot.children[@intFromBool(slot.children[0] == null)]);
        } else {
            const successor = self.minimum(slot.children[1].?);
            if (self.slots[successor].parent != index) {
                changed = self.slots[successor].parent;
                self.replace(successor, self.slots[successor].children[1]);
                self.slots[successor].children[1] = slot.children[1];
                self.slots[slot.children[1].?].parent = successor;
            } else changed = successor;
            self.replace(index, successor);
            self.slots[successor].children[0] = slot.children[0];
            self.slots[slot.children[0].?].parent = successor;
        }
        slot.children = .{ null, null };
        slot.parent = null;
        slot.height = 1;
        slot.prefetch = null;
        self.balance(changed);
    }

    fn ordered(a: *const Slot, b: *const Slot) bool {
        if (a.priority.urgency != b.priority.urgency) return @intFromEnum(a.priority.urgency) < @intFromEnum(b.priority.urgency);
        if (a.priority.player != b.priority.player) return a.priority.player < b.priority.player;
        if (a.priority.distance != b.priority.distance) return a.priority.distance < b.priority.distance;
        return a.sequence < b.sequence;
    }

    fn pick(self: *const Generation, required_only: bool) ?usize {
        const first = self.minimum(self.waiting orelse return null);
        const urgency = self.slots[first].priority.urgency;
        if (required_only and urgency != .required) return null;
        var current = self.waiting;
        var candidate: ?usize = null;
        while (current) |index| {
            const priority = self.slots[index].priority;
            if (@intFromEnum(priority.urgency) < @intFromEnum(urgency) or (priority.urgency == urgency and priority.player <= self.last_player)) {
                current = self.slots[index].children[1];
            } else {
                if (priority.urgency == urgency) candidate = index;
                current = self.slots[index].children[0];
            }
        }
        const selected = candidate orelse first;
        assert(self.slots[selected].state == .queued and self.slots[selected].priority.urgency == urgency);
        return selected;
    }

    fn releaseLocked(self: *Generation, index: usize) void {
        assert(self.slots[index].state != .free and self.slots[index].state != .running);
        const removed = self.index.remove(self.slots[index].section);
        assert(removed);
        if (self.slots[index].state == .ready) {
            self.remove(&self.finished, index);
            _ = self.ready_count.fetchSub(1, .release);
        }
        if (self.slots[index].state == .queued) {
            self.dequeue(index);
            self.queued_count -= 1;
        }
        self.unlinkOwner(index);
        self.slots[index].state = .free;
        self.free[self.free_count] = index;
        self.free_count += 1;
    }

    pub fn processOne(self: *Generation, io: std.Io) !bool {
        return try self.process(io, false, 1, null) != 0;
    }

    pub fn processBatch(self: *Generation, io: std.Io) !usize {
        return self.process(io, false, batch_max, null);
    }

    fn process(self: *Generation, io: std.Io, required_only: bool, maximum: usize, observed: ?u64) !usize {
        assert(maximum > 0 and maximum <= batch_max);
        var count: usize = 0;
        var generated: usize = 0;
        var timing: metrics.Span = .{};
        var cpu: metrics.Span = .{};
        defer {
            cpu.end();
            timing.end();
            if (generated != 0) self.generated.add(generated);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (observed) |expected| if (self.completion_version != expected) return 0;
        var workers: usize = 0;
        for (self.work_events) |event| workers += @intFromBool(event != null);
        const share = std.math.divCeil(usize, self.queued_count, @max(workers, 1)) catch unreachable;
        const limit = @min(maximum, share);
        if (limit == 0) return 0;
        var requests: [batch_max]chunks.Source.Request = undefined;
        while (count < limit and self.queued_count != 0) {
            const index = self.pick(required_only) orelse break;
            const slot = &self.slots[index];
            self.dequeue(index);
            slot.state = .running;
            self.queued_count -= 1;
            self.last_player = slot.priority.player;
            requests[count] = .{ .section = slot.section, .output = slot.destination, .token = index };
            count += 1;
        }
        if (count == 0) return 0;
        self.mutex.unlock(self.io);
        timing = self.duration.start();
        cpu = self.cpu.start();
        self.source.?.readMany(io, .{ .requests = requests[0..count], .owner = self });
        self.mutex.lockUncancelable(self.io);
        var canceled = false;
        for (requests[0..count]) |request| {
            assert(request.completed);
            if (request.result) |_| {
                generated += 1;
            } else |err| if (err == error.Canceled) {
                canceled = true;
            }
        }
        if (canceled) return error.Canceled;
        return count;
    }

    pub fn publish(self: *Generation, requests: []chunks.Source.Request) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var changed = false;
        for (requests) |*request| {
            if (request.completed) continue;
            request.completed = true;
            const index = request.token;
            const slot = &self.slots[index];
            assert(slot.state == .running);
            changed = true;
            if (slot.obsolete) {
                self.cancelLockedRunning(index);
                continue;
            }
            slot.result = request.result;
            slot.state = .ready;
            self.append(&self.finished, index);
            _ = self.ready_count.fetchAdd(1, .release);
            if (request.result) |length| {
                if (length != 3 and length != section_bytes) {
                    slot.result = error.InvalidSection;
                } else {
                    const kind = slot.destination[0];
                    if ((kind == 0 and length != 3) or (kind == 1 and length != section_bytes) or kind > 1) slot.result = error.InvalidSection;
                }
            } else |err| {
                assert(err != error.GenerationIncomplete);
                if (err == error.Canceled) {
                    self.remove(&self.finished, index);
                    slot.state = .queued;
                    self.enqueue(index);
                    self.queued_count += 1;
                    _ = self.ready_count.fetchSub(1, .release);
                    self.signalWork();
                }
            }
        }
        if (!changed) return;
        self.queued.set(self.slots.len - self.free_count);
        self.completion_version += 1;
        self.completion.broadcast(self.io);
        self.completed.set(self.io);
        self.notify.set(self.io);
    }

    fn cancelLockedRunning(self: *Generation, index: usize) void {
        self.slots[index].state = .ready;
        self.append(&self.finished, index);
        self.slots[index].result = error.Obsolete;
        _ = self.ready_count.fetchAdd(1, .release);
    }

    pub fn version(self: *Generation) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.completion_version;
    }

    pub fn wait(self: *Generation, io: std.Io, expected: u64) !void {
        if (try self.process(io, true, chunks.Source.batch_max, expected) != 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.completion_version == expected and self.ready_count.load(.acquire) == 0) {
            if (self.failure) |err| return err;
            if (self.stopping.load(.acquire) or self.owner.load(.acquire) == 0 or !self.parallel.load(.acquire)) return error.GenerationStalled;
            self.completion.waitUncancelable(self.io, &self.mutex);
        }
    }

    pub fn start(self: *Generation, parallel: bool) void {
        assert(self.owner.load(.acquire) == 0);
        self.failure = null;
        self.stopping.store(false, .release);
        self.parallel.store(parallel, .release);
        self.owner.store(std.Thread.getCurrentId(), .release);
    }

    pub fn finish(self: *Generation) void {
        assert(self.owner.load(.acquire) == std.Thread.getCurrentId());
        self.stop();
        self.owner.store(0, .release);
        self.parallel.store(false, .release);
    }

    pub fn fail(self: *Generation, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failure == null) self.failure = err;
        self.stopLocked();
        self.completed.set(self.io);
        self.notify.set(self.io);
    }

    pub fn subscribe(self: *Generation, event: *std.Io.Event) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.work_events) |*slot| if (slot.* == null) {
            slot.* = event;
            if (self.queued_count != 0) event.set(self.io);
            return;
        };
        return error.GenerationWorkerCapacity;
    }

    pub fn unsubscribe(self: *Generation, event: *std.Io.Event) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.work_events) |*slot| if (slot.* == event) {
            slot.* = null;
            return;
        };
        unreachable;
    }

    fn signalWork(self: *Generation) void {
        if (!self.parallel.load(.acquire)) {
            self.notify.set(self.io);
            return;
        }
        var left = self.queued_count;
        for (0..self.work_events.len) |offset| {
            const index = (self.next_worker + offset) % self.work_events.len;
            const event = self.work_events[index] orelse continue;
            if (left == 0) break;
            event.set(self.io);
            left -= 1;
        }
        self.next_worker = (self.next_worker + 1) % self.work_events.len;
    }

    pub fn stop(self: *Generation) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopLocked();
    }

    fn stopLocked(self: *Generation) void {
        self.stopping.store(true, .release);
        self.completion.broadcast(self.io);
        for (self.work_events) |event| if (event) |ready| ready.set(self.io);
    }
};

const TestSource = struct {
    order: [16]i32 = undefined,
    count: usize = 0,

    fn read(self: *@This(), io: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests, 0..) |*request, index| {
            request.result = self.readOne(io, request.section, request.output);
            batch.complete(batch.requests[index..][0..1]);
        }
    }

    fn readOne(self: *@This(), _: std.Io, section: chunks.Section, destination: []u8) !usize {
        self.order[self.count] = section.x;
        self.count += 1;
        return chunks.uniform(@intCast(section.x), destination);
    }
};

fn testSection(x: i32) chunks.Section {
    return .{ .world = 0, .x = x, .y = 0, .z = 0 };
}

test "generation writes into caller slots and serves priorities fairly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var notified: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 8, &notified, &registry);
    var source: TestSource = .{};
    queue.setSource(chunks.Source.init(&source, TestSource.read));
    var destinations: [7][section_bytes]u8 = undefined;
    var requests: [7]Generation.Request = undefined;
    for (&requests, &destinations, 0..) |*request, *destination, index| request.* = .{ .section = testSection(@intCast(index)), .destination = destination, .token = index };
    try std.testing.expectEqual(@as(usize, 2), queue.submit(requests[0..2], .{ .player = 0, .distance = 1 }));
    try std.testing.expectEqual(@as(usize, 2), queue.submit(requests[2..4], .{ .player = 1, .distance = 3 }));
    _ = queue.submit(requests[4..5], .{ .player = 0, .distance = 8 });
    _ = queue.submit(requests[5..6], .{ .urgency = .occupied, .player = 3 });
    _ = queue.submit(requests[6..7], .{ .urgency = .required });
    while (try queue.processOne(std.testing.io)) {}
    try std.testing.expectEqualSlices(i32, &.{ 6, 5, 0, 2, 1, 3, 4 }, source.order[0..source.count]);
    var completions: [8]Generation.Completion = undefined;
    const count = queue.nextMany(&completions);
    try std.testing.expectEqual(@as(usize, 7), count);
    for (completions[0..count]) |completion| {
        const bytes = try completion.result;
        try std.testing.expectEqual(destinations[completion.token][0..].ptr, bytes.ptr);
        try std.testing.expectEqual(@as(usize, 3), bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 0), queue.nextMany(completions[count..]));
    queue.releaseMany(completions[0..count]);
    try std.testing.expectEqual(queue.slots.len, queue.free_count);
}

test "demand generation progresses without a parallel worker reply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var notified: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 1, &notified, &registry);
    var source: TestSource = .{};
    queue.setSource(chunks.Source.init(&source, TestSource.read));
    queue.start(true);
    defer queue.finish();
    var destination: [section_bytes]u8 = undefined;
    const section = testSection(7);
    try std.testing.expectEqual(@as(usize, 1), queue.submit(&.{.{ .section = section, .destination = &destination, .token = 0 }}, .{ .urgency = .required }));
    try queue.wait(std.testing.io, queue.version());
    const completion = queue.take(section).?;
    defer queue.release(completion);
    try std.testing.expectEqual(destination[0..].ptr, (try completion.result).ptr);
    try std.testing.expectEqualSlices(i32, &.{7}, source.order[0..source.count]);
}

test "bounded reclamation chooses distant queued work and preserves completed running and required work" {
    const Source = struct {
        queue: *Generation,
        reclaim: bool = false,
        canceled: usize = 0,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            if (self.reclaim) self.canceled = self.queue.cancelPrefetch(2);
            for (batch.requests) |*request| request.result = chunks.uniform(7, request.output);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var notify: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 8, &notify, &registry);
    var source: Source = .{ .queue = queue };
    queue.setSource(chunks.Source.init(&source, Source.read));
    var destinations: [8][section_bytes]u8 = undefined;
    var requests: [8]Generation.Request = undefined;
    for (&requests, &destinations, 0..) |*request, *destination, index| request.* = .{ .section = testSection(@intCast(index)), .destination = destination, .token = index };
    _ = queue.submit(requests[7..8], .{ .distance = 1000 });
    try std.testing.expect(try queue.processOne(std.testing.io));
    _ = queue.submit(requests[0..1], .{ .urgency = .required });
    _ = queue.submit(requests[1..2], .{ .urgency = .occupied, .distance = 1000 });
    _ = queue.submit(requests[2..3], .{ .distance = 1 });
    _ = queue.submit(requests[3..4], .{ .distance = 20 });
    _ = queue.submit(requests[4..5], .{ .distance = 30 });
    _ = queue.submit(requests[5..6], .{ .urgency = .required });
    _ = queue.submit(requests[6..7], .{ .distance = 10 });
    source.reclaim = true;
    try std.testing.expect(try queue.processOne(std.testing.io));
    source.reclaim = false;
    try std.testing.expectEqual(@as(usize, 2), source.canceled);
    var canceled: u8 = 0;
    while (queue.next()) |completion| {
        if (completion.result) |_| {
            try std.testing.expect(completion.token == 7 or completion.token == 0);
        } else |err| {
            try std.testing.expectEqual(error.Obsolete, err);
            canceled |= @as(u8, 1) << @intCast(completion.token);
        }
        queue.release(completion);
    }
    try std.testing.expectEqual(@as(u8, (1 << 3) | (1 << 4)), canceled);
    while (try queue.processOne(std.testing.io)) {}
    while (queue.next()) |completion| {
        _ = try completion.result;
        queue.release(completion);
    }
    try std.testing.expectEqual(queue.slots.len, queue.free_count);
}

test "cancellation returns each caller slot before reuse and preserves required work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var notified: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 3, &notified, &registry);
    var source: TestSource = .{};
    queue.setSource(chunks.Source.init(&source, TestSource.read));
    var destinations: [3][section_bytes]u8 = undefined;
    var requests: [3]Generation.Request = undefined;
    for (&requests, &destinations, 0..) |*request, *destination, index| request.* = .{ .section = testSection(@intCast(index)), .destination = destination, .token = index };
    _ = queue.submit(requests[0..2], .{ .player = 0 });
    _ = queue.submit(requests[2..3], .{ .urgency = .required });
    queue.update(0, null);
    try std.testing.expectEqual(@as(usize, 0), queue.free_count);
    var canceled: usize = 0;
    while (queue.next()) |completion| {
        try std.testing.expectError(error.Obsolete, completion.result);
        canceled += 1;
        queue.release(completion);
    }
    try std.testing.expectEqual(@as(usize, 2), canceled);
    try std.testing.expect(try queue.processOne(std.testing.io));
    const required = queue.take(requests[2].section).?;
    try std.testing.expectEqual(destinations[2][0..].ptr, (try required.result).ptr);
    queue.release(required);
    try std.testing.expectEqual(queue.slots.len, queue.free_count);
}

test "a generated section is available while the next section is blocked" {
    const Source = struct {
        entered: std.Io.Event = .unset,
        proceed: std.Io.Event = .unset,
        fn read(self: *@This(), io: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests, 0..) |*request, index| {
                request.result = self.readOne(io, request.section, request.output);
                batch.complete(batch.requests[index..][0..1]);
            }
        }

        fn readOne(self: *@This(), io: std.Io, section: chunks.Section, destination: []u8) !usize {
            if (section.x == 1) {
                self.entered.set(io);
                self.proceed.waitUncancelable(io);
            }
            @memcpy(destination[0..3], &[_]u8{ 0, 7, 0 });
            return 3;
        }
    };
    const Worker = struct {
        queue: *Generation,
        result: anyerror!usize = 0,
        fn run(self: *@This()) void {
            self.result = self.queue.processBatch(std.testing.io);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var notified: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 2, &notified, &registry);
    var source: Source = .{};
    queue.setSource(chunks.Source.init(&source, Source.read));
    var destinations: [2][section_bytes]u8 = undefined;
    for (&destinations, 0..) |*destination, index| {
        try std.testing.expectEqual(@as(usize, 1), queue.submit(&.{.{ .section = testSection(@intCast(index)), .destination = destination, .token = index }}, .{}));
    }
    var worker: Worker = .{ .queue = queue };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    {
        defer {
            source.proceed.set(std.testing.io);
            thread.join();
        }
        source.entered.waitUncancelable(std.testing.io);
        const first = queue.take(testSection(0)) orelse return error.CompletedSectionUnavailable;
        try std.testing.expectEqualSlices(u8, &.{ 0, 7, 0 }, try first.result);
        queue.release(first);
    }
    try std.testing.expectEqual(@as(usize, 2), try worker.result);
    const second = queue.take(testSection(1)).?;
    queue.release(second);
}

test "generation observes CPU time once per nonempty batch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{});
    defer registry.deinit();
    var notified: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 8, &notified, &registry);
    var source: TestSource = .{};
    queue.setSource(chunks.Source.init(&source, TestSource.read));
    var destinations: [7][section_bytes]u8 = undefined;
    var requests: [7]Generation.Request = undefined;
    for (&requests, &destinations, 0..) |*request, *destination, index| request.* = .{ .section = testSection(@intCast(index)), .destination = destination, .token = index };
    try std.testing.expectEqual(@as(usize, 7), queue.submit(&requests, .{}));
    try std.testing.expectEqual(@as(usize, 7), try queue.processBatch(std.testing.io));
    try std.testing.expectEqual(@as(u64, 7), queue.generated.value());
    try std.testing.expectEqual(@as(u64, 1), queue.cpu.read().?.count);
    try std.testing.expectEqual(@as(u64, 1), queue.duration.read().?.count);
    try std.testing.expect(!try queue.processOne(std.testing.io));
    try std.testing.expectEqual(@as(u64, 1), queue.cpu.read().?.count);
    while (queue.next()) |completion| queue.release(completion);
}

const ScheduleModel = struct {
    fn reclaim(queue: *Generation) ?usize {
        var worst: ?usize = null;
        for (queue.slots, 0..) |slot, index| {
            if (slot.state != .queued or slot.priority.urgency == .required) continue;
            if (worst) |previous| {
                const other = queue.slots[previous];
                if (slot.priority.urgency != other.priority.urgency) {
                    if (@intFromEnum(slot.priority.urgency) < @intFromEnum(other.priority.urgency)) continue;
                } else if (slot.priority.distance != other.priority.distance) {
                    if (slot.priority.distance < other.priority.distance) continue;
                } else if (slot.sequence < other.sequence) continue;
            }
            worst = index;
        }
        return worst;
    }

    fn before(a: Generation.Slot, b: Generation.Slot, last_player: usize) bool {
        if (a.priority.urgency != b.priority.urgency) return @intFromEnum(a.priority.urgency) < @intFromEnum(b.priority.urgency);
        if (a.priority.player != b.priority.player) {
            const a_wrap = a.priority.player <= last_player;
            const b_wrap = b.priority.player <= last_player;
            if (a_wrap != b_wrap) return !a_wrap;
            return a.priority.player < b.priority.player;
        }
        if (a.priority.distance != b.priority.distance) return a.priority.distance < b.priority.distance;
        return a.sequence < b.sequence;
    }

    fn pick(queue: *Generation, required_only: bool) ?usize {
        var best: ?usize = null;
        for (queue.slots, 0..) |slot, index| {
            if (slot.state != .queued or (required_only and slot.priority.urgency != .required)) continue;
            if (best == null or before(slot, queue.slots[best.?], queue.last_player)) best = index;
        }
        return best;
    }

    fn inspect(queue: *Generation, index: ?usize, parent: ?usize, depth: usize) !usize {
        const at = index orelse return 0;
        try std.testing.expect(depth < 32 and at < queue.slots.len);
        const slot = queue.slots[at];
        try std.testing.expect(slot.state == .queued and slot.parent == parent);
        var count: usize = 1;
        for (slot.children, 0..) |child, side| {
            if (child) |id| try std.testing.expect(if (side == 0) Generation.ordered(&queue.slots[id], &slot) else Generation.ordered(&slot, &queue.slots[id]));
            count += try inspect(queue, child, at, depth + 1);
        }
        const left = queue.height(slot.children[0]);
        const right = queue.height(slot.children[1]);
        try std.testing.expectEqual(1 + @max(left, right), slot.height);
        try std.testing.expect(@max(left, right) - @min(left, right) <= 1);
        var prefetch: ?usize = if (slot.priority.urgency == .required) null else at;
        for (slot.children) |child| {
            const candidate = queue.slots[child orelse continue].prefetch orelse continue;
            if (prefetch == null or queue.reclaimLess(prefetch.?, candidate)) prefetch = candidate;
        }
        try std.testing.expectEqual(prefetch, slot.prefetch);
        return count;
    }
};

test "indexed scheduling matches linear priority and fairness through updates cancellation and reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(arena.allocator(), std.testing.io, .{ .enabled = false });
    var notify: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 257, &notify, &registry);
    const Source = struct {
        fn read(self: *@This(), io: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests, 0..) |*request, index| {
                request.result = self.readOne(io, request.section, request.output);
                batch.complete(batch.requests[index..][0..1]);
            }
        }

        fn readOne(_: *@This(), _: std.Io, _: chunks.Section, destination: []u8) !usize {
            return chunks.uniform(1, destination);
        }
    };
    var source: Source = .{};
    queue.setSource(chunks.Source.init(&source, Source.read));
    const destinations = try arena.allocator().alloc([section_bytes]u8, queue.slots.len);
    var random = std.Random.DefaultPrng.init(0x5c4ed01e);
    for (0..10000) |step| {
        switch (random.random().uintLessThan(u8, 6)) {
            0, 1 => if (queue.free_count != 0) {
                const slot = queue.free[queue.free_count - 1];
                const player = random.random().uintLessThan(usize, 13);
                const priority: Priority = .{ .player = player, .distance = random.random().uintLessThan(u32, 65), .urgency = @enumFromInt(random.random().uintLessThan(u8, 3)) };
                try std.testing.expectEqual(@as(usize, 1), queue.submit(&.{.{ .section = testSection(@intCast(step)), .destination = &destinations[slot], .token = slot }}, priority));
            },
            2 => {
                _ = try queue.processOne(std.testing.io);
                var completions: [8]Generation.Completion = undefined;
                const count = queue.nextMany(&completions);
                queue.releaseMany(completions[0..count]);
            },
            3 => if (queue.pick(false)) |slot| queue.promote(&.{queue.slots[slot].section}),
            4 => queue.update(random.random().uintLessThan(usize, 13), .{ .world = 0, .x = @intCast(step / 2), .z = 0, .radius = 100 }),
            5 => {
                const worst = ScheduleModel.reclaim(queue);
                const count = queue.cancelPrefetch(1);
                try std.testing.expectEqual(@as(usize, @intFromBool(worst != null)), count);
                if (worst) |index| {
                    try std.testing.expectEqual(Generation.State.ready, queue.slots[index].state);
                    try std.testing.expectError(error.Obsolete, queue.slots[index].result);
                }
            },
            else => unreachable,
        }
        try std.testing.expectEqual(ScheduleModel.pick(queue, false), queue.pick(false));
        try std.testing.expectEqual(ScheduleModel.pick(queue, true), queue.pick(true));
        try std.testing.expectEqual(ScheduleModel.reclaim(queue), if (queue.waiting) |root| queue.slots[root].prefetch else null);
        try std.testing.expectEqual(queue.queued_count, try ScheduleModel.inspect(queue, queue.waiting, null, 0));
        var completions: [257]Generation.Completion = undefined;
        const count = queue.nextMany(&completions);
        queue.releaseMany(completions[0..count]);
    }
}

test "a generation batch reaches the source and publishes completions together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(arena.allocator(), std.testing.io, .{ .enabled = false });
    var notified: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 8, &notified, &registry);
    const Source = struct {
        calls: usize = 0,
        count: usize = 0,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            self.calls += 1;
            self.count += batch.requests.len;
            for (batch.requests) |*request| request.result = chunks.uniform(1, request.output);
        }
    };
    var source: Source = .{};
    queue.setSource(chunks.Source.init(&source, Source.read));
    var destinations: [8][section_bytes]u8 = undefined;
    var requests: [8]Generation.Request = undefined;
    for (&requests, &destinations, 0..) |*request, *destination, index| {
        request.* = .{ .section = testSection(@intCast(index)), .destination = destination, .token = index };
    }
    try std.testing.expectEqual(requests.len, queue.submit(&requests, .{}));
    const version = queue.version();
    try std.testing.expectEqual(requests.len, try queue.processBatch(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(requests.len, source.count);
    try std.testing.expectEqual(version + 1, queue.version());
    var completed: [8]Generation.Completion = undefined;
    try std.testing.expectEqual(completed.len, queue.nextMany(&completed));
    for (completed) |completion| {
        try std.testing.expectEqual(destinations[completion.token][0..].ptr, (try completion.result).ptr);
    }
    queue.releaseMany(&completed);
    try std.testing.expectEqual(queue.slots.len, queue.free_count);
}

test "generation view batches follow request ownership through promotion and release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(arena.allocator(), std.testing.io, .{ .enabled = false });
    var notify: std.Io.Event = .unset;
    const queue = try Generation.init(arena.allocator(), std.testing.io, 6144, &notify, &registry);
    var destination: [section_bytes]u8 = undefined;
    const request: Generation.Request = .{ .section = testSection(3), .destination = &destination, .token = 7 };
    try std.testing.expectEqual(@as(usize, 1), queue.submit(&.{request}, .{ .player = 0, .distance = 10 }));
    try std.testing.expectEqual(@as(usize, 1), queue.submit(&.{request}, .{ .player = 1, .distance = 3 }));
    try std.testing.expect(!queue.owners.contains(0));
    try std.testing.expectEqual(@as(usize, 1), queue.owners.count());
    var changes: [256]Generation.Update = undefined;
    for (&changes, 0..) |*change, player| change.* = .{ .player = player, .interest = if (player == 1) .{ .world = 0, .x = 3, .z = 0, .radius = 32 } else null };
    queue.updateMany(&changes);
    const index = queue.index.get(request.section).?;
    try std.testing.expectEqual(.queued, queue.slots[index].state);
    try std.testing.expectEqual(@as(u32, 0), queue.slots[index].priority.distance);
    queue.updateMany(&.{.{ .player = 1, .interest = null }});
    const completed = queue.next().?;
    try std.testing.expectError(error.Obsolete, completed.result);
    queue.release(completed);
    try std.testing.expectEqual(@as(usize, 0), queue.owners.count());
    try std.testing.expectEqual(queue.slots.len, queue.free_count);
}
