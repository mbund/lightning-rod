const std = @import("std");
const sessions = @import("sessions");
const lightning_rod = @import("lightning_rod");
const Players = @import("players.zig").Players;
const bit_sets = lightning_rod.system.bit_sets;
const sparse_sets = lightning_rod.system.sparse_sets;
const IndexSet = lightning_rod.system.IndexSet;
const assert = std.debug.assert;
const absent = std.math.maxInt(usize);

pub const Visibility = struct {
    pub const id = "minecraft:visibility";
    pub const Configuration = struct { channels: usize = 8, layers: usize = 4, exceptions: usize = 4096 };
    pub const Dependencies = struct { players: *Players };
    const Rows = struct { name: [96]u8 = undefined, name_len: usize, revisions: []u64 };
    const Rule = struct { defaults: [2]bool = @splat(false), heads: [2]usize = @splat(absent) };
    const Policy = struct { channels: []?[]Rule = &.{} };
    const Exception = struct {
        key: [5]usize = @splat(0),
        historical: bool = false,
        bucket_next: usize = absent,
        row_next: usize = absent,
        row_previous: usize = absent,
    };
    const State = struct {
        layers: []Policy,
        entries: []Exception,
        buckets: []usize,
        free: usize,
        count: usize = 0,

        fn init(allocator: std.mem.Allocator, config: Configuration) !State {
            const layers = try allocator.alloc(Policy, config.layers);
            @memset(layers, .{});
            return .{ .layers = layers, .entries = &.{}, .buckets = &.{}, .free = absent };
        }

        fn allocateExceptions(self: *State, allocator: std.mem.Allocator, capacity: usize) !void {
            assert(self.buckets.len == 0 and self.count == 0);
            const entries = try allocator.alloc(Exception, capacity);
            for (entries, 0..) |*entry, index| entry.* = .{ .bucket_next = if (index + 1 == entries.len) absent else index + 1 };
            const size = try std.math.ceilPowerOfTwo(usize, @max(1, try std.math.mul(usize, capacity, 2)));
            const buckets = try allocator.alloc(usize, size);
            @memset(buckets, absent);
            self.entries = entries;
            self.buckets = buckets;
            self.free = if (entries.len == 0) absent else 0;
        }

        fn bucket(self: *const State, key: [5]usize) usize {
            return @intCast(std.hash.Wyhash.hash(0, std.mem.asBytes(&key)) & (self.buckets.len - 1));
        }

        fn find(self: *const State, key: [5]usize) ?usize {
            var index = self.buckets[self.bucket(key)];
            while (index != absent) : (index = self.entries[index].bucket_next) {
                if (std.meta.eql(self.entries[index].key, key)) return index;
            }
            return null;
        }

        fn remove(self: *State, index: usize) void {
            const entry = self.entries[index];
            assert(entry.key[4] != 0 and self.count != 0);
            const row = &self.layers[entry.key[2]].channels[entry.key[3]].?[entry.key[0]];
            const history = @intFromBool(entry.historical);
            if (entry.row_previous == absent) row.heads[history] = entry.row_next else self.entries[entry.row_previous].row_next = entry.row_next;
            if (entry.row_next != absent) self.entries[entry.row_next].row_previous = entry.row_previous;
            var link = &self.buckets[self.bucket(entry.key)];
            while (link.* != index) link = &self.entries[link.*].bucket_next;
            link.* = entry.bucket_next;
            self.entries[index] = .{ .bucket_next = self.free };
            self.free = index;
            self.count -= 1;
            assert(self.find(entry.key) == null);
        }

        fn clearRow(self: *State, row: *Rule, history: usize) void {
            while (row.heads[history] != absent) self.remove(row.heads[history]);
        }

        fn set(self: *State, key: [5]usize, excluded: bool) !void {
            const row = &self.layers[key[2]].channels[key[3]].?[key[0]];
            const existing = self.find(key);
            if (excluded == row.defaults[0]) {
                if (existing) |index| self.remove(index);
                return;
            }
            if (existing != null) return;
            if (self.free == absent) return error.VisibilityCapacity;
            const index = self.free;
            self.free = self.entries[index].bucket_next;
            const at = self.bucket(key);
            self.entries[index] = .{ .key = key, .bucket_next = self.buckets[at], .row_next = row.heads[0] };
            if (row.heads[0] != absent) self.entries[row.heads[0]].row_previous = index;
            row.heads[0] = index;
            self.buckets[at] = index;
            self.count += 1;
            assert(self.find(key).? == index);
        }

        fn copyRows(self: *State, source: *const State, layer: usize, work: sparse_sets.Workspace, channels: usize) void {
            assert(self != source and layer < self.layers.len and layer < source.layers.len);
            assert(self.entries.len == source.entries.len);
            // Release all replaced exceptions before restoring rows so rollback cannot exhaust storage.
            for (0..channels) |channel_index| {
                var dirty = work.row(4 + channel_index).view().iterator();
                while (dirty.next()) |subject| self.clearRow(&self.layers[layer].channels[channel_index].?[subject], 0);
            }
            for (0..channels) |channel_index| {
                var dirty = work.row(4 + channel_index).view().iterator();
                while (dirty.next()) |subject| {
                    const original = source.layers[layer].channels[channel_index].?[subject];
                    self.layers[layer].channels[channel_index].?[subject].defaults[0] = original.defaults[0];
                    var entry = original.heads[0];
                    while (entry != absent) : (entry = source.entries[entry].row_next) {
                        self.set(source.entries[entry].key, !original.defaults[0]) catch unreachable;
                    }
                }
            }
            assert(self.count == source.count);
        }
    };

    pub const Audience = bit_sets.Selection;
    pub const Channel = struct {
        owner: *Visibility,
        index: usize,

        pub fn filter(self: Channel, subject: sessions.Handle, audience: bit_sets.Set, output: sparse_sets.Workspace.RowView) bit_sets.Set {
            const owner = self.owner;
            assert(self.index < owner.channel_count and subject.index < owner.generations.len and subject.generation != 0);
            assert(audience.capacity == owner.generations.len and output.view().capacity == audience.capacity);
            const history = owner.historyOf(subject) orelse {
                output.clear();
                return output.view();
            };
            output.copy(audience);
            owner.restrict(&owner.states[owner.active], self.index, subject.index, history, output);
            return output.view();
        }

        pub fn allows(self: Channel, subject: sessions.Handle, observer: usize) bool {
            const owner = self.owner;
            assert(self.index < owner.channel_count and subject.index < owner.generations.len and subject.generation != 0 and observer < owner.generations.len);
            const historical = owner.historyOf(subject) orelse return false;
            const state = &owner.states[owner.active];
            for (state.layers[0..owner.layer_count], 0..) |layer, index| {
                const row = layer.channels[self.index].?[subject.index];
                const exception = row.heads[historical] != absent and state.find(.{ subject.index, observer, index, self.index, subject.generation }) != null;
                if (row.defaults[historical] != exception) return false;
            }
            return true;
        }

        pub fn revision(self: Channel, subject: usize) u64 {
            assert(self.index < self.owner.channel_count and subject < self.owner.generations.len);
            return self.owner.channels[self.index].revisions[subject];
        }
    };

    pub const Change = struct {
        subjects: []const sessions.Handle,
        // The all audience also covers future joins. Explicit exceptions expire with the connection.
        observers: Audience = .all,
        channels: []const Channel,
        excluded: bool,
    };

    pub const Layer = struct {
        owner: *Visibility,
        index: usize,

        pub fn updateMany(self: Layer, changes: []const Change) !void {
            const owner = self.owner;
            assert(self.index < owner.layer_count);
            owner.synchronize();
            if (changes.len == 0) return;
            for (changes) |change| {
                if (change.observers == .players) {
                    if (change.observers.players.capacity != owner.generations.len) return error.InvalidAudience;
                    var observers = change.observers.players.iterator();
                    while (observers.next()) |index| if (owner.generations[index] == 0) return error.InvalidAudience;
                }
                for (change.channels) |selection| if (selection.owner != owner or selection.index >= owner.channel_count) return error.InvalidChannel;
                for (change.subjects) |subject| if (subject.index >= owner.generations.len or subject.generation == 0 or owner.generations[subject.index] != subject.generation) return error.StaleHandle;
            }
            const previous = &owner.states[owner.active];
            const next = &owner.states[owner.active ^ 1];
            for (0..owner.channel_count) |index| owner.work.row(4 + index).clear();
            errdefer next.copyRows(previous, self.index, owner.work, owner.channel_count);
            for (changes) |change| for (change.channels) |selection| {
                for (change.subjects) |subject| {
                    owner.work.row(4 + selection.index).insert(subject.index);
                    const row = &next.layers[self.index].channels[selection.index].?[subject.index];
                    switch (change.observers) {
                        .all => {
                            next.clearRow(row, 0);
                            row.defaults[0] = change.excluded;
                        },
                        .players => |audience| {
                            var observers = audience.iterator();
                            while (observers.next()) |observer| try next.set(.{ subject.index, observer, self.index, selection.index, subject.generation }, change.excluded);
                        },
                    }
                }
            };
            for (0..owner.channel_count) |index| {
                var dirty = owner.work.row(4 + index).view().iterator();
                while (dirty.next()) |subject| {
                    const before = owner.work.row(2);
                    const after = owner.work.row(3);
                    before.fill();
                    after.fill();
                    owner.restrict(previous, index, subject, 0, before);
                    owner.restrict(next, index, subject, 0, after);
                    if (!before.view().eql(after.view())) owner.channels[index].revisions[subject] += 1;
                }
            }
            previous.copyRows(next, self.index, owner.work, owner.channel_count);
            owner.active ^= 1;
        }
    };

    allocator: std.mem.Allocator,
    deps: Dependencies,
    channels: []Rows,
    states: [2]State,
    active: u1 = 0,
    exception_capacity: usize,
    work: sparse_sets.Workspace,
    channel_count: usize = 0,
    layer_count: usize = 0,
    generations: []u32,
    tracked: IndexSet,
    departed: []u32,
    sealed: bool = false,
    player_entity: Channel = undefined,
    tab_list: Channel = undefined,
    announcements: Channel = undefined,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Visibility {
        if (config.channels < 3 or config.channels > 64 or config.layers > 64 or deps.players.records.len == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Visibility);
        self.* = .{
            .allocator = allocator,
            .deps = deps,
            .channels = try allocator.alloc(Rows, config.channels),
            .states = .{ try State.init(allocator, config), try State.init(allocator, config) },
            .exception_capacity = config.exceptions,
            .work = try sparse_sets.Workspace.init(allocator, config.channels + 4, deps.players.records.len),
            .generations = try allocator.alloc(u32, deps.players.records.len),
            .tracked = try IndexSet.init(allocator, deps.players.records.len),
            .departed = try allocator.alloc(u32, deps.players.records.len),
        };
        for (self.generations, deps.players.records) |*generation, player| generation.* = if (player.handle) |handle| handle.generation else 0;
        @memset(self.departed, 0);
        for (deps.players.activeSlots()) |index| self.tracked.insert(index);
        self.player_entity = try self.channel("minecraft:player_entity");
        self.tab_list = try self.channel("minecraft:tab_list");
        self.announcements = try self.channel("minecraft:announcements");
        return self;
    }

    pub fn channel(self: *Visibility, name: []const u8) !Channel {
        for (self.channels[0..self.channel_count], 0..) |rows, index| if (std.mem.eql(u8, rows.name[0..rows.name_len], name)) return .{ .owner = self, .index = index };
        if (self.sealed) return error.Sealed;
        if (name.len == 0 or name.len > 96) return error.InvalidChannel;
        if (self.channel_count == self.channels.len) return error.VisibilityCapacity;
        const index = self.channel_count;
        var rows: Rows = .{ .revisions = try self.allocator.alloc(u64, self.generations.len), .name_len = name.len };
        @memcpy(rows.name[0..name.len], name);
        @memset(rows.revisions, 0);
        for (&self.states) |*state| for (state.layers[0..self.layer_count]) |layer| {
            const rules = try self.allocator.alloc(Rule, self.generations.len);
            @memset(rules, .{});
            layer.channels[index] = rules;
        };
        self.channels[index] = rows;
        self.channel_count += 1;
        return .{ .owner = self, .index = index };
    }

    pub fn createLayer(self: *Visibility) !Layer {
        if (self.sealed) return error.Sealed;
        if (self.layer_count == self.states[0].layers.len) return error.VisibilityCapacity;
        for (&self.states) |*state| {
            if (self.layer_count == 0) try state.allocateExceptions(self.allocator, self.exception_capacity);
            const channels = try self.allocator.alloc(?[]Rule, self.channels.len);
            @memset(channels, null);
            for (channels[0..self.channel_count]) |*entry| {
                const rules = try self.allocator.alloc(Rule, self.generations.len);
                @memset(rules, .{});
                entry.* = rules;
            }
            state.layers[self.layer_count] = .{ .channels = channels };
        }
        const index = self.layer_count;
        self.layer_count += 1;
        return .{ .owner = self, .index = index };
    }

    pub fn tick(self: *Visibility) void {
        self.sealed = true;
        self.synchronize();
    }

    fn historyOf(self: *const Visibility, subject: sessions.Handle) ?usize {
        if (self.generations[subject.index] == subject.generation) return 0;
        if (self.departed[subject.index] == subject.generation) return 1;
        return null;
    }

    fn restrict(self: *Visibility, state: *const State, channel_index: usize, subject: usize, historical: usize, output: sparse_sets.Workspace.RowView) void {
        const allowed = self.work.row(0);
        assert(output.view().sparse != null or output.view().words.ptr != allowed.view().words.ptr);
        for (state.layers[0..self.layer_count]) |layer| {
            const row = layer.channels[channel_index].?[subject];
            var index = row.heads[historical];
            if (row.defaults[historical]) allowed.clear();
            while (index != absent) : (index = state.entries[index].row_next) {
                const observer = state.entries[index].key[1];
                if (row.defaults[historical]) allowed.insert(observer) else output.remove(observer);
            }
            if (row.defaults[historical]) output.intersect(output.view(), allowed.view());
        }
    }

    fn synchronize(self: *Visibility) void {
        const changed = self.work.row(1);
        changed.clear();
        for (self.deps.players.activeSlots()) |index| self.tracked.insert(index);
        var at: usize = 0;
        while (at < self.tracked.count) {
            const index = self.tracked.indices[at];
            const previous = &self.generations[index];
            const player = self.deps.players.records[index];
            at += 1;
            const generation = if (player.handle) |handle| handle.generation else 0;
            if (previous.* == generation) continue;
            changed.insert(index);
            if (previous.* != 0) {
                self.departed[index] = previous.*;
                for (&self.states, 0..) |*state, state_index| for (state.layers[0..self.layer_count]) |layer| for (layer.channels[0..self.channel_count], 0..) |rules, channel_index| {
                    const row = &rules.?[index];
                    state.clearRow(row, 1);
                    row.heads[1] = row.heads[0];
                    row.heads[0] = absent;
                    row.defaults[1] = row.defaults[0];
                    row.defaults[0] = false;
                    var entry = row.heads[1];
                    while (entry != absent) : (entry = state.entries[entry].row_next) state.entries[entry].historical = true;
                    if (state_index == self.active) self.channels[channel_index].revisions[index] += 1;
                };
            }
            previous.* = generation;
            if (generation == 0) {
                self.tracked.remove(index);
                at -= 1;
            }
        }
        if (!changed.view().any()) return;
        for (&self.states, 0..) |*state, state_index| for (state.entries, 0..) |entry, index| {
            if (entry.key[4] == 0 or !changed.view().contains(entry.key[1])) continue;
            if (state_index == self.active and !entry.historical) self.channels[entry.key[3]].revisions[entry.key[0]] += 1;
            state.remove(index);
        };
    }
};

fn testFilter(channel: Visibility.Channel, subject: sessions.Handle, audience: usize) usize {
    const input = [_]usize{audience};
    var output: [1]usize = undefined;
    const capacity = channel.owner.generations.len;
    assert(capacity <= @bitSizeOf(usize));
    return channel.filter(subject, .{ .words = &input, .capacity = capacity }, (bit_sets.Row{ .words = &output, .capacity = capacity }).workspace()).words[0];
}

test "visibility layers compose independently and reset both sides of reused connections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var records: [3]Players.Player = undefined;
    for (&records, 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 } };
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const visibility = try Visibility.init(allocator, .{}, .{ .players = &players });
    const vanish = try visibility.createLayer();
    const minigame = try visibility.createLayer();
    const custom = try visibility.channel("test:scores");
    try std.testing.expectEqual(custom.index, (try visibility.channel("test:scores")).index);
    failing.fail_index = failing.alloc_index;
    visibility.tick();
    try std.testing.expectError(error.Sealed, visibility.createLayer());
    try std.testing.expectError(error.Sealed, visibility.channel("test:new"));
    const subject = records[0].handle.?;
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{ visibility.player_entity, visibility.tab_list, visibility.announcements }, .excluded = true }});
    try minigame.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{2}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = true }});
    try std.testing.expectEqual(@as(usize, 1), testFilter(visibility.player_entity, subject, 7));
    try std.testing.expectEqual(@as(usize, 7), testFilter(custom, subject, 7));
    const revision = visibility.player_entity.revision(0);
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{2}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = false }});
    try std.testing.expectEqual(revision, visibility.player_entity.revision(0));
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{ visibility.player_entity, visibility.tab_list, visibility.announcements }, .excluded = false }});
    try std.testing.expectEqual(@as(usize, 5), testFilter(visibility.player_entity, subject, 7));
    try std.testing.expectEqual(@as(usize, 7), testFilter(visibility.tab_list, subject, 7));
    try std.testing.expectError(error.StaleHandle, minigame.updateMany(&.{
        .{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{4}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = true },
        .{ .subjects = &.{.{ .index = 0, .generation = 9 }}, .observers = .{ .players = .{ .words = &.{4}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = true },
    }));
    try std.testing.expectEqual(@as(usize, 5), testFilter(visibility.player_entity, subject, 7));
    records[1].handle.?.generation = 2;
    visibility.tick();
    try std.testing.expectEqual(@as(usize, 7), testFilter(visibility.player_entity, subject, 7));
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{4}, .capacity = records.len } }, .channels = &.{visibility.announcements}, .excluded = true }});
    records[0].handle = null;
    visibility.tick();
    try std.testing.expectEqual(@as(usize, 3), testFilter(visibility.announcements, subject, 7));
    records[0].handle = .{ .index = 0, .generation = 2 };
    visibility.tick();
    try std.testing.expectEqual(@as(usize, 7), testFilter(visibility.announcements, records[0].handle.?, 7));
    try std.testing.expectEqual(@as(usize, 3), testFilter(visibility.announcements, subject, 7));
    try std.testing.expectError(error.StaleHandle, vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{4}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = true }}));
}

test "all-observer exclusions include future joins while connection-specific exceptions expire" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var records: [3]Players.Player = undefined;
    for (&records, 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 } };
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const visibility = try Visibility.init(allocator, .{}, .{ .players = &players });
    const layer = try visibility.createLayer();
    const subject = records[0].handle.?;
    try layer.updateMany(&.{.{ .subjects = &.{subject}, .channels = &.{ visibility.player_entity, visibility.announcements }, .excluded = true }});
    records[2].handle = null;
    visibility.tick();
    records[2].handle = .{ .index = 2, .generation = 2 };
    visibility.tick();
    try std.testing.expectEqual(@as(usize, 0), testFilter(visibility.player_entity, subject, 7));
    try layer.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{4}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = false }});
    try std.testing.expectEqual(@as(usize, 4), testFilter(visibility.player_entity, subject, 7));
    records[2].handle.?.generation = 3;
    visibility.tick();
    try std.testing.expectEqual(@as(usize, 0), testFilter(visibility.player_entity, subject, 7));
    records[0].handle = .{ .index = 0, .generation = 2 };
    visibility.tick();
    try std.testing.expectEqual(@as(usize, 7), testFilter(visibility.player_entity, records[0].handle.?, 7));
    try std.testing.expectEqual(@as(usize, 0), testFilter(visibility.announcements, subject, 7));
}

test "visibility exhaustion preserves the complete previous policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var records: [3]Players.Player = undefined;
    for (&records, 0..) |*player, index| player.* = .{ .handle = .{ .index = index, .generation = 1 } };
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const visibility = try Visibility.init(allocator, .{ .exceptions = 1 }, .{ .players = &players });
    const layer = try visibility.createLayer();
    failing.fail_index = failing.alloc_index;
    visibility.tick();
    const subject = records[0].handle.?;
    try layer.updateMany(&.{.{ .subjects = &.{subject}, .channels = &.{visibility.player_entity}, .excluded = true }});
    try layer.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{2}, .capacity = 3 } }, .channels = &.{visibility.player_entity}, .excluded = false }});
    const revision = visibility.player_entity.revision(0);
    try std.testing.expectError(error.VisibilityCapacity, layer.updateMany(&.{
        .{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{2}, .capacity = 3 } }, .channels = &.{visibility.player_entity}, .excluded = true },
        .{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = 3 } }, .channels = &.{visibility.player_entity}, .excluded = false },
    }));
    try std.testing.expectEqual(@as(usize, 2), testFilter(visibility.player_entity, subject, 7));
    try std.testing.expectEqual(revision, visibility.player_entity.revision(0));
    try std.testing.expectEqual(@as(usize, 1), visibility.states[visibility.active].count);
}

test "visibility staged rows match a model through overlapping batches and capacity failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var records: [6]Players.Player = undefined;
    var handles: [records.len]sessions.Handle = undefined;
    for (&records, &handles, 0..) |*player, *handle, index| {
        handle.* = .{ .index = index, .generation = 1 };
        player.* = .{ .handle = handle.*, .stage = .ready, .loaded = true };
    }
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const visibility = try Visibility.init(allocator, .{ .exceptions = 8 }, .{ .players = &players });
    const layers = [_]Visibility.Layer{ try visibility.createLayer(), try visibility.createLayer() };
    const channels = [_]Visibility.Channel{ visibility.player_entity, visibility.tab_list, visibility.announcements };
    failing.fail_index = failing.alloc_index;
    var random = std.Random.DefaultPrng.init(4917);
    var model: [layers.len][channels.len][records.len][records.len]bool = @splat(@splat(@splat(@splat(false))));
    var failures: usize = 0;
    for (0..300) |_| {
        const original = model;
        var revisions: [channels.len][records.len]u64 = undefined;
        for (channels, &revisions) |channel, *values| for (values, 0..) |*value, subject| {
            value.* = channel.revision(subject);
        };
        const selected = random.random().uintLessThan(usize, layers.len);
        var changes: [3]Visibility.Change = undefined;
        var subjects: [3][1]sessions.Handle = undefined;
        var selections: [3][1]Visibility.Channel = undefined;
        var masks: [3][1]usize = undefined;
        for (&changes, &subjects, &selections, &masks) |*change, *subject, *selection, *mask| {
            const who = random.random().uintLessThan(usize, records.len);
            const channel = random.random().uintLessThan(usize, channels.len);
            const all = random.random().boolean();
            const excluded = random.random().boolean();
            subject.* = .{handles[who]};
            selection.* = .{channels[channel]};
            mask.* = .{random.random().int(u6)};
            change.* = .{ .subjects = subject, .channels = selection, .excluded = excluded, .observers = if (all) .all else .{ .players = .{ .words = mask, .capacity = records.len } } };
            for (&model[selected][channel][who], 0..) |*value, observer| {
                if (all or mask[0] & (@as(usize, 1) << @intCast(observer)) != 0) value.* = excluded;
            }
        }
        layers[selected].updateMany(&changes) catch |err| {
            try std.testing.expectEqual(error.VisibilityCapacity, err);
            model = original;
            failures += 1;
        };
        for (channels, revisions, 0..) |channel, previous, index| for (handles, previous) |subject, revision| {
            var changed = false;
            for (handles) |observer| {
                const expected = !(model[0][index][subject.index][observer.index] or model[1][index][subject.index][observer.index]);
                const before = !(original[0][index][subject.index][observer.index] or original[1][index][subject.index][observer.index]);
                try std.testing.expectEqual(expected, channel.allows(subject, observer.index));
                changed = changed or before != expected;
            }
            try std.testing.expectEqual(revision + @intFromBool(changed), channel.revision(subject.index));
        };
        try std.testing.expectEqual(visibility.states[0].count, visibility.states[1].count);
    }
    try std.testing.expect(failures > 0);
}
