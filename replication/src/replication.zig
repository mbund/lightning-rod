const BatchIndex = @import("lightning_rod").system.BatchIndex;
const audience_storage = @import("players").audience;
const sparse_sets = @import("lightning_rod").system.sparse_sets;
const Lifecycle = @import("lifecycle.zig").Lifecycle;
const bit_sets = @import("lightning_rod").system.bit_sets;
const IndexSet = @import("lightning_rod").system.IndexSet;
const Visibility = @import("visibility.zig").Visibility;
const Streaming = @import("terrain").streaming.Streaming;
const geometry_bounds = @import("occlusion").bounds;
const std = @import("std");
const protocols = @import("minecraft_packets").protocols;
const sessions = @import("sessions");
const Players = @import("players").players.Players;
const ChatSession = @import("players").chat_session.ChatSession;
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const packets = @import("minecraft_packets");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_9 = @import("wire_1_21_9");

const SpatialIndex = @import("players").player_spatial.Index;
const SpatialGroups = @import("players").player_spatial.Groups;

const assert = std.debug.assert;

pub const Replication = struct {
    pub const id = "minecraft:player_replication";

    pub const Configuration = struct {
        /// Pairs of players whose view of each other differs from what most pairs of
        /// their row share. Null lets every player differ with up to 255 others, which
        /// is every pair there is up to 256 players. A fixed count ran out when more
        /// than 64 players met in one place, and the player with the most in view was
        /// disconnected to make room.
        lifecycle_exceptions: ?usize = null,
        audience_words: usize = 4096,
        /// Ticks between a player's movement updates. Vanilla tracks players every second tick.
        update_interval: u8 = 2,
    };

    pub const Dependencies = struct { players: *Players, visibility: *Visibility, streaming: ?*Streaming = null };

    const Spawn = struct {
        entity_id: i32,
        uuid: u128,
        position: minecraft.Position,
        pitch: i8,
        yaw: i8,
        head_yaw: i8,
    };

    const Seen = Lifecycle.State;

    const Baseline = struct {
        position: [3]i64 = @splat(0),
        yaw: i8 = 0,
        pitch: i8 = 0,
        head: ?i8 = null,
        flags: ?Appearance = null,
        on_ground: bool = false,
    };

    const AudienceGroups = BatchIndex(bit_sets.Set, usize, bit_sets.Set.HashContext);
    const SubjectList = struct {
        head: usize = std.math.maxInt(usize),
        tail: usize = std.math.maxInt(usize),
        next: []usize,
        owners: []u64,
        epoch: *const u64,
        fn clear(self: *SubjectList) void {
            self.head = std.math.maxInt(usize);
            self.tail = std.math.maxInt(usize);
        }
        fn insert(self: *SubjectList, index: usize) void {
            assert(self.owners[index] != self.epoch.*);
            self.owners[index] = self.epoch.*;
            self.next[index] = std.math.maxInt(usize);
            if (self.tail == std.math.maxInt(usize)) self.head = index else self.next[self.tail] = index;
            self.tail = index;
        }
        fn iterator(self: SubjectList) Iterator {
            return .{ .index = self.head, .links = self.next };
        }
        const Iterator = struct {
            index: usize,
            links: []usize,
            fn next(self: *Iterator) ?usize {
                if (self.index == std.math.maxInt(usize)) return null;
                const index = self.index;
                self.index = self.links[index];
                return index;
            }
        };
    };
    const BroadcastGroup = struct { members: sparse_sets.Row, subjects: SubjectList };

    const Phase = enum { movement, head, flags };
    const Common = struct {
        value: Baseline = .{},
        members: [3]audience_storage.Row = @splat(.{}),
    };

    const Observer = struct {
        generation: u32 = 0,
        world: u32 = 0,
        spawned: audience_storage.Row = .{},
        pending: audience_storage.Row = .{},
        nearby: audience_storage.Row = .{},
        /// The observer's view distance the nearby set was found for.
        view_distance: i32 = 0,
        ready: bool = false,
        pending_dirty: bool = false,
    };

    deps: Dependencies,
    actors: IndexSet,
    spatial_changes: SpatialIndex,
    neighborhoods: SpatialGroups,
    lifecycle: Lifecycle,
    rejected: []u32,
    baselines: []CachedBaseline,
    observers: []Observer,
    subjects: []Subject,
    /// Movement and head turns since a subject's last update tick. Vanilla tracks players every
    /// second tick, so moves in between go out together.
    motion: []Motion,
    ticks: u64 = 0,
    update_interval: u8,
    viewer_revisions: []u64,
    viewer_masks: audience_storage.Matrix,
    pending_updates: audience_storage.Matrix,
    pending_subjects: IndexSet,
    work_masks: audience_storage.Matrix,
    dirty_work: IndexSet,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,
    movement_targets: []Target,
    receipts: [][3]?sessions.Service.Broadcast.Receipt,
    common: []Common,
    scratch: sparse_sets.Workspace,
    broadcast: sessions.Service.Broadcast,
    audience_groups: AudienceGroups,
    group_epoch: u64 = 0,
    last_group_count: usize = 0,
    broadcast_groups: []BroadcastGroup,
    render_distance: i32 = 0,

    /// The entity data a player's flags packet carries: its entity flags, the pose they imply,
    /// its living entity flags, and the skin layers its client shows.
    const Appearance = struct { flags: minecraft.EntityFlags = .{}, living: minecraft.LivingFlags = .{}, skin_parts: u8 = 0 };
    const Motion = packed struct(u8) { moved: bool = false, turned: bool = false, _: u6 = 0 };
    const Subject = struct {
        generation: u32 = 0,
        gamemode: minecraft.GameMode = .survival,
        world: u32 = 0,
        cell: [2]i64 = @splat(0),
        position: [3]i64 = @splat(0),
        yaw: i8 = 0,
        pitch: i8 = 0,
        flags: Appearance = .{},
        on_ground: bool = false,
        entity_visibility: u64 = 0,
        tab_visibility: u64 = 0,
        /// The player's chat key revision, so observers hear of a new key.
        chat: u32 = 0,
    };

    const CachedBaseline = struct {
        key: [4]usize = @splat(0),
        value: Baseline = .{},
        known: u3 = 0,
    };

    const Observation = struct {
        state: Seen,
        value: Baseline = .{},
        known: u3 = 0,
    };

    /// What a relative movement update carries: vanilla sends the position, the look or both,
    /// whichever changed.
    const Move = enum(u2) {
        both,
        position,
        look,

        fn of(position: [3]i64, yaw: i8, pitch: i8, base: Baseline) Move {
            const moved = !std.meta.eql(position, base.position);
            const turned = yaw != base.yaw or pitch != base.pitch;
            return if (moved and turned) .both else if (turned) .look else .position;
        }
    };
    const Group = struct { protocol: i32, absolute: bool, baseline: [3]i64, move: Move = .both };
    const Target = struct {
        group: Group,
        handle: sessions.Handle,

        fn less(_: void, a: Target, b: Target) bool {
            const protocol = std.math.order(a.group.protocol, b.group.protocol);
            const absolute = std.math.order(@intFromBool(a.group.absolute), @intFromBool(b.group.absolute));
            const baseline = std.mem.order(i64, &a.group.baseline, &b.group.baseline);
            const move = std.math.order(@intFromEnum(a.group.move), @intFromEnum(b.group.move));
            return protocol == .lt or (protocol == .eq and (absolute == .lt or (absolute == .eq and (baseline == .lt or (baseline == .eq and move == .lt)))));
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Replication {
        if (config.update_interval == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Replication);
        const slots = deps.players.records.len;
        const lifecycle = try Lifecycle.init(allocator, slots, config.lifecycle_exceptions orelse slots * @min(slots -| 1, 255));
        const rejected = try allocator.alloc(u32, deps.players.records.len);
        @memset(rejected, 0);
        const baselines = try allocator.alloc(CachedBaseline, deps.players.records.len);
        @memset(baselines, .{});
        const observers = try allocator.alloc(Observer, deps.players.records.len);
        @memset(observers, .{});
        const subjects = try allocator.alloc(Subject, deps.players.records.len);
        @memset(subjects, .{});
        const motion = try allocator.alloc(Motion, deps.players.records.len);
        @memset(motion, .{});
        const viewer_revisions = try allocator.alloc(u64, subjects.len);
        @memset(viewer_revisions, 0);
        const viewer_masks = try audience_storage.Matrix.init(allocator, deps.players, deps.players.records.len, config.audience_words, .recipients);
        const pending_updates = try audience_storage.Matrix.init(allocator, deps.players, deps.players.records.len, config.audience_words, .recipients);
        const common = try allocator.alloc(Common, deps.players.records.len);
        @memset(common, .{});
        const broadcast = try sessions.Service.Broadcast.init(allocator, deps.players.deps.sessions, 3 * deps.players.records.len * deps.players.deps.sessions.config.protocols.len);
        const audience_groups = try AudienceGroups.init(allocator, deps.players.records.len);
        const broadcast_groups = try allocator.alloc(BroadcastGroup, deps.players.records.len);
        const observer_sets = try audience_storage.Matrix.init(allocator, deps.players, try std.math.mul(usize, 3, observers.len), config.audience_words, .{ .subjects = 3 });
        for (observers, 0..) |*observer, index| observer.* = .{ .spawned = observer_sets.row(index * 3), .pending = observer_sets.row(index * 3 + 1), .nearby = observer_sets.row(index * 3 + 2) };
        const common_sets = try audience_storage.Matrix.init(allocator, deps.players, try std.math.mul(usize, 3, common.len), config.audience_words, .recipients);
        for (common, 0..) |*value, index| for (&value.members, 0..) |*members, phase| {
            members.* = common_sets.row(index * 3 + phase);
        };
        const group_sets = try sparse_sets.Matrix.init(allocator, broadcast_groups.len, broadcast_groups.len, config.audience_words);
        const group_links = try allocator.alloc(usize, broadcast_groups.len);
        const group_owners = try allocator.alloc(u64, broadcast_groups.len);
        @memset(group_owners, 0);
        for (broadcast_groups, 0..) |*group, index| group.* = .{ .members = group_sets.row(index), .subjects = .{ .next = group_links, .owners = group_owners, .epoch = &self.group_epoch } };
        self.* = .{
            .spatial_changes = try SpatialIndex.init(allocator, try std.math.mul(usize, 2, subjects.len)),
            .neighborhoods = try SpatialGroups.init(allocator, subjects.len),
            .work_masks = try audience_storage.Matrix.init(allocator, deps.players, try std.math.mul(usize, 3, deps.players.records.len), config.audience_words, .recipients),
            .dirty_work = try IndexSet.init(allocator, try std.math.mul(usize, 3, deps.players.records.len)),
            .scratch = try sparse_sets.Workspace.init(allocator, std.enums.values(Scratch).len, deps.players.records.len),
            .targets = try allocator.alloc(sessions.Service.Target, deps.players.records.len),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, deps.players.records.len),
            .movement_targets = try allocator.alloc(Target, deps.players.records.len),
            .receipts = try allocator.alloc([3]?sessions.Service.Broadcast.Receipt, deps.players.records.len),
            .audience_groups = audience_groups,
            .broadcast_groups = broadcast_groups,
            .common = common,
            .broadcast = broadcast,
            .deps = deps,
            .actors = try IndexSet.init(allocator, deps.players.records.len),
            .lifecycle = lifecycle,
            .rejected = rejected,
            .baselines = baselines,
            .observers = observers,
            .subjects = subjects,
            .motion = motion,
            .update_interval = config.update_interval,
            .viewer_revisions = viewer_revisions,
            .viewer_masks = viewer_masks,
            .pending_updates = pending_updates,
            .pending_subjects = try IndexSet.init(allocator, deps.players.records.len),
        };
        return self;
    }

    const Work = enum { updates, interested, audience };
    const Scratch = enum { changed, movement_changed, head_changed, flags_changed, connected, spatial_changed, ready_observers, selected, nearby, difference, listed, lifecycle_remove_entity, lifecycle_remove_player, lifecycle_add_player, lifecycle_mode, lifecycle_chat, lifecycle_spawn, spawned, eligible, retry, previous, members, force, candidates, outstanding, group, delivered, failed, displaced, filtered, entity_audience, terrain_changed };

    fn workMask(self: *const Replication, index: usize, comptime kind: Work) bit_sets.Set {
        assert(index < self.subjects.len);
        return self.work_masks.row(index * 3 + @backingInt(kind)).view();
    }

    fn editWorkMask(self: *Replication, index: usize, comptime kind: Work) audience_storage.Row {
        assert(index < self.subjects.len);
        const row = index * 3 + @backingInt(kind);
        self.dirty_work.insert(row);
        return self.work_masks.row(row);
    }

    fn temp(self: *const Replication, comptime kind: Scratch) sparse_sets.Workspace.RowView {
        return self.scratch.row(@backingInt(kind));
    }

    fn queueUpdates(self: *Replication, subject: usize, audience: bit_sets.Set) void {
        if (!audience.any()) return;
        self.pending_updates.row(subject).unite(self.pending_updates.row(subject).view(), audience);
        self.pending_subjects.insert(subject);
    }

    fn spatialPosition(subject: Subject) SpatialIndex.Position {
        assert(subject.generation != 0);
        return .{ .world = subject.world, .x = @intCast(subject.cell[0]), .z = @intCast(subject.cell[1]) };
    }

    fn orderObservers(self: *Replication, spatial: bool) []const usize {
        self.neighborhoods.clear();
        if (!spatial) return self.actors.values();
        for (self.actors.values()) |index| {
            const subject = self.subjects[index];
            self.neighborhoods.add(index, .{ .world = subject.world, .x = @intCast(subject.cell[0]), .z = @intCast(subject.cell[1]) });
        }
        assert(self.neighborhoods.members == self.actors.count);
        return self.neighborhoods.ordered();
    }

    pub fn tick(self: *Replication) void {
        const players = self.deps.players;
        const terrain = if (self.deps.streaming) |streaming| streaming.snapshotVisibility() else null;
        const terrain_changed = self.temp(.terrain_changed);
        terrain_changed.clear();
        if (terrain) |snapshot| {
            for (snapshot.reset.values()) |index| terrain_changed.insert(index);
            for (snapshot.changed_words.values()) |word| terrain_changed.insert(word / snapshot.grid.words);
        }
        for (players.activeSlots()) |index| self.actors.insert(index);
        const changed = self.temp(.changed);
        changed.clear();
        const movement_changed = self.temp(.movement_changed);
        movement_changed.clear();
        const head_changed = self.temp(.head_changed);
        head_changed.clear();
        const flags_changed = self.temp(.flags_changed);
        flags_changed.clear();
        const connected = self.temp(.connected);
        connected.clear();
        const spatial_changed = self.temp(.spatial_changed);
        spatial_changed.clear();
        var appeared = false;
        const distance_changed = self.render_distance != players.config.render_distance;
        self.render_distance = players.config.render_distance;
        while (self.spatial_changes.active.count != 0) {
            self.spatial_changes.update(self.spatial_changes.active.indices[self.spatial_changes.active.count - 1], null);
        }
        for (self.actors.values()) |index| {
            const player = players.records[index];
            const subject = &self.subjects[index];
            const generation = if (player.handle) |handle| (if (self.rejected[index] == handle.generation) @as(u32, 0) else handle.generation) else 0;
            if (generation == 0) {
                if (subject.generation != 0) {
                    changed.insert(index);
                    spatial_changed.insert(index);
                    self.spatial_changes.update(index * 2, spatialPosition(subject.*));
                    subject.* = .{};
                }
                continue;
            }
            appeared = appeared or (player.stage == .ready and !self.observers[index].ready);
            const next: Subject = .{
                .generation = generation,
                .gamemode = players.gameMode(index),
                .world = player.world,
                .cell = .{ @intFromFloat(@floor(player.position.x / 16)), @intFromFloat(@floor(player.position.z / 16)) },
                .position = .{ fixed(player.position.x), fixed(player.position.y), fixed(player.position.z) },
                .yaw = angle(player.rotation.yaw),
                .pitch = angle(player.rotation.pitch),
                .flags = .{ .flags = player.flags, .living = player.living_flags, .skin_parts = player.skin_parts },
                .on_ground = player.on_ground,
                .entity_visibility = self.deps.visibility.player_entity.revision(index),
                .tab_visibility = self.deps.visibility.tab_list.revision(index),
                .chat = player.chat_revision,
            };
            if (generation != 0) connected.insert(index);
            if (generation != subject.generation or next.gamemode != subject.gamemode or next.entity_visibility != subject.entity_visibility or next.tab_visibility != subject.tab_visibility or next.chat != subject.chat) changed.insert(index);
            const moved = !std.meta.eql(next.position, subject.position);
            if (terrain != null and moved and !std.meta.eql(terrainSections(next.position), terrainSections(subject.position))) changed.insert(index);
            if (generation != subject.generation or next.world != subject.world or !std.meta.eql(next.cell, subject.cell)) {
                spatial_changed.insert(index);
                if (subject.generation != 0) self.spatial_changes.update(index * 2, spatialPosition(subject.*));
                self.spatial_changes.update(index * 2 + 1, spatialPosition(next));
            }
            const motion = &self.motion[index];
            if (moved or next.yaw != subject.yaw or next.pitch != subject.pitch or next.on_ground != subject.on_ground) motion.moved = true;
            if (next.yaw != subject.yaw) motion.turned = true;
            // Subjects take turns, so half of them update on each tick.
            if ((self.ticks + index) % self.update_interval == 0) {
                if (motion.moved) movement_changed.insert(index);
                if (motion.turned) head_changed.insert(index);
                motion.* = .{};
            }
            if (!std.meta.eql(next.flags, subject.flags)) flags_changed.insert(index);
            subject.* = next;
        }
        self.ticks += 1;
        for (self.dirty_work.values()) |row| self.work_masks.row(row).clear();
        self.dirty_work.clear();
        const lifecycle_changed = changed.view().any();
        const moved_cells = spatial_changed.view().any();
        const ready_observers = self.temp(.ready_observers);
        ready_observers.clear();
        var neighborhood: ?SpatialIndex.Position = null;
        var neighborhood_distance: i32 = 0;
        var affected = false;
        var captured = false;
        for (self.orderObservers(moved_cells or distance_changed or appeared)) |other| {
            const observer = players.records[other];
            const watching = &self.observers[other];
            const generation = if (observer.handle) |handle| (if (self.rejected[other] == handle.generation) @as(u32, 0) else handle.generation) else 0;
            if (watching.generation != generation or (watching.ready and observer.stage != .ready)) {
                var spawned = watching.spawned.view().iterator();
                while (spawned.next()) |index| {
                    self.detach(index, other);
                    self.viewer_masks.row(index).remove(other);
                    self.viewer_revisions[index] += 1;
                }
            }
            if (watching.generation != generation) {
                self.lifecycle.deactivate(other);
                const spawned = watching.spawned;
                const pending = watching.pending;
                const nearby = watching.nearby;
                spawned.clear();
                if (generation == 0) pending.clear() else pending.copy(connected.view());
                nearby.clear();
                watching.* = .{ .generation = generation, .world = observer.world, .spawned = spawned, .pending = pending, .nearby = nearby, .pending_dirty = true };
            }
            if (generation == 0) continue;
            if (lifecycle_changed) {
                watching.pending.unite(watching.pending.view(), changed.view());
                watching.pending_dirty = true;
            }
            if (terrain_changed.view().contains(other)) {
                watching.pending.unite(watching.pending.view(), watching.nearby.view());
                watching.pending.unite(watching.pending.view(), watching.spawned.view());
                watching.pending_dirty = true;
            }
            if (observer.stage != .ready) {
                watching.ready = false;
                continue;
            }
            if (!self.lifecycle.active.contains(other)) self.lifecycle.activate(other);
            ready_observers.insert(other);
            // Each observer sees subjects within its own view distance.
            const reach = players.viewDistanceOf(observer);
            const reached = watching.view_distance != reach;
            watching.view_distance = reach;
            if (watching.ready and watching.world == observer.world and !distance_changed and !reached and !watching.pending_dirty and !moved_cells) continue;
            const selected = self.temp(.selected);
            selected.copy(watching.pending.view());
            if (watching.world != observer.world) {
                selected.unite(selected.view(), watching.spawned.view());
                var spawned = watching.spawned.view().iterator();
                while (spawned.next()) |index| self.detach(index, other);
                watching.spawned.clear();
                watching.world = observer.world;
            }
            const center = spatialPosition(self.subjects[other]);
            if (!std.meta.eql(neighborhood, @as(?SpatialIndex.Position, center)) or neighborhood_distance != reach) {
                neighborhood = center;
                neighborhood_distance = reach;
                captured = false;
                affected = false;
                if (moved_cells) {
                    var changes = self.spatial_changes.query(center, self.render_distance);
                    affected = changes.next() != null;
                }
            }
            if (distance_changed or reached or spatial_changed.view().contains(other) or !watching.ready or affected) {
                const nearby = self.temp(.nearby);
                if (!captured) {
                    nearby.clear();
                    var candidates = players.nearby(observer.world, observer.position, reach);
                    while (candidates.next()) |index| nearby.insert(index);
                    captured = true;
                }
                const difference = self.temp(.difference);
                difference.difference(watching.nearby.view(), nearby.view());
                selected.unite(selected.view(), difference.view());
                watching.nearby.copy(nearby.view());
            }
            if (!watching.ready) {
                selected.unite(selected.view(), connected.view());
                selected.unite(selected.view(), watching.spawned.view());
            }
            watching.ready = true;
            watching.pending.clear();
            watching.pending_dirty = false;
            var changed_subjects = selected.view().iterator();
            while (changed_subjects.next()) |index| {
                self.editWorkMask(index, .audience).insert(other);
                if (watching.nearby.view().contains(index)) self.editWorkMask(index, .interested).insert(other);
            }
        }
        for (self.actors.values()) |index| {
            const moving = movement_changed.view().contains(index) or head_changed.view().contains(index) or flags_changed.view().contains(index);
            if (!moving and !self.pending_subjects.contains(index)) continue;
            const update = self.editWorkMask(index, .updates);
            update.copy(self.pending_updates.row(index).view());
            if (moving) update.unite(update.view(), self.viewer_masks.row(index).view());
            update.intersect(update.view(), ready_observers.view());
        }
        for (self.actors.values()) |index| {
            const subject = players.records[index];
            if (!self.dirty_work.contains(index * 3 + @backingInt(Work.audience))) continue;
            const audience = self.workMask(index, .audience);
            if (!audience.any()) continue;
            while (!self.lifecycle.begin(index, audience)) self.evictObserver(ready_observers);
            defer self.lifecycle.commit();
            var selected_observers = audience.iterator();
            while (selected_observers.next()) |other| self.lifecycle.edit(other).spawned = self.observers[other].spawned.view().contains(index);
            self.viewer_revisions[index] += 1;
            const generation = self.subjects[index].generation;
            const entity_row = self.editWorkMask(index, .interested);
            const listed_row = self.temp(.listed);
            if (subject.handle) |handle| {
                const filtered = self.temp(.entity_audience);
                _ = self.deps.visibility.player_entity.filter(handle, entity_row.view(), filtered);
                entity_row.copy(filtered.view());
                if (terrain) |snapshot| {
                    const bounds = terrainBounds(self.subjects[index].position);
                    var observers = entity_row.view().iterator();
                    while (observers.next()) |other| {
                        if (!snapshot.boundsVisible(other, &players.records[other], subject.world, bounds)) entity_row.remove(other);
                    }
                }
                _ = self.deps.visibility.tab_list.filter(handle, ready_observers.view(), listed_row);
            } else {
                entity_row.clear();
                listed_row.clear();
            }
            const entity_audience = entity_row.view();
            const listed_audience = listed_row.view();
            const Action = enum { remove_entity, remove_player, add_player, mode, chat, spawn };
            const needed = [6]sparse_sets.Workspace.RowView{ self.temp(.lifecycle_remove_entity), self.temp(.lifecycle_remove_player), self.temp(.lifecycle_add_player), self.temp(.lifecycle_mode), self.temp(.lifecycle_chat), self.temp(.lifecycle_spawn) };
            for (needed) |row| row.clear();
            var selected = audience.iterator();
            while (selected.next()) |other| {
                const seen = self.lifecycle.edit(other);
                if (seen.generation != generation and !seen.known) seen.* = .{ .generation = generation, .uuid = subject.uuid };
                const wants_spawn = other != index and entity_audience.contains(other);
                const wants_known = generation != 0 and (other == index or wants_spawn or listed_audience.contains(other));
                if (other == index and !seen.known) {
                    seen.known = true;
                    seen.listed = true;
                }
                const stale = seen.generation != generation;
                if (seen.spawned and (stale or !wants_spawn)) needed[@backingInt(Action.remove_entity)].insert(other);
                if (seen.known and (stale or !wants_known)) {
                    if (!seen.spawned) needed[@backingInt(Action.remove_player)].insert(other);
                    continue;
                }
                if (!wants_known) continue;
                if (!seen.known) {
                    needed[@backingInt(Action.add_player)].insert(other);
                    continue;
                }
                if (seen.gamemode != self.subjects[index].gamemode or seen.listed != (listed_audience.contains(other))) needed[@backingInt(Action.mode)].insert(other);
                if (seen.chat != self.subjects[index].chat) needed[@backingInt(Action.chat)].insert(other);
                if (!seen.spawned and wants_spawn) needed[@backingInt(Action.spawn)].insert(other);
            }
            const yaw = self.subjects[index].yaw;
            const pitch = self.subjects[index].pitch;
            const entity_id: i32 = @intCast(index + 1);
            inline for (std.enums.values(Action)) |phase| {
                const remaining = needed[@backingInt(phase)];
                while (remaining.view().any()) {
                    const first = remaining.view().firstFrom(0).?;
                    const old_uuid = self.lifecycle.get(index, first).uuid;
                    const targets = self.targets;
                    const deliveries = self.deliveries;
                    var count: usize = 0;
                    var pending = remaining.view().iterator();
                    while (pending.next()) |other| {
                        const seen = self.lifecycle.edit(other);
                        if (phase == .remove_player and seen.uuid != old_uuid) continue;
                        if ((phase == .add_player or phase == .mode) and (listed_audience.contains(other)) != (listed_audience.contains(first))) continue;
                        remaining.remove(other);
                        const observer = players.records[other];
                        targets[count] = .{ .handle = observer.handle.?, .protocol = observer.protocol };
                        count += 1;
                    }
                    const result = switch (phase) {
                        .remove_entity => players.deps.packets.fanout(writeRemove, targets[0..count], .{entity_id}, 2048, deliveries[0..count]),
                        .remove_player => players.deps.packets.fanout(writePlayerRemove, targets[0..count], .{old_uuid}, 2048, deliveries[0..count]),
                        .add_player => players.deps.packets.fanout(Players.writePlayerProfile, targets[0..count], .{ subject.uuid, subject.name[0..subject.name_len], players.deps.sessions.profile(subject.handle.?).textures(), players.chatSession(index), @as(i32, @backingInt(self.subjects[index].gamemode)), listed_audience.contains(first) }, Players.profilePacketBytes(players.deps.sessions.profile(subject.handle.?).textures(), players.chatSession(index)), deliveries[0..count]),
                        .mode => players.deps.packets.fanout(writeInfo, targets[0..count], .{ subject.uuid, self.subjects[index].gamemode, listed_audience.contains(first) }, 2048, deliveries[0..count]),
                        .chat => players.deps.packets.fanout(writeChatInfo, targets[0..count], .{ subject.uuid, players.chatSession(index) }, 2048, deliveries[0..count]),
                        .spawn => players.deps.packets.fanoutGroup(.{ .{ writeSpawnLegacy, writeSpawnPacked }, writeFlags, writeHeadRotation }, targets[0..count], .{
                            .{Spawn{ .entity_id = entity_id, .uuid = subject.uuid, .position = subject.position, .pitch = pitch, .yaw = yaw, .head_yaw = yaw }},
                            .{ entity_id, self.subjects[index].flags },
                            .{ entity_id, yaw },
                        }, &.{ 2048, 32, 16 }, deliveries[0..count]),
                    };
                    result catch |err| {
                        std.log.warn("event=player_replication_failed reason={t}", .{err});
                        continue;
                    };
                    const spawned = self.temp(.spawned);
                    spawned.clear();
                    for (targets[0..count], deliveries[0..count]) |target, delivery| {
                        const other = target.handle.index;
                        if (delivery != .queued) continue;
                        const seen = self.lifecycle.edit(other);
                        switch (phase) {
                            .remove_entity => {
                                self.detach(index, other);
                                seen.spawned = false;
                                if (seen.generation != generation or (other != index and !listed_audience.contains(other) and !entity_audience.contains(other))) needed[@backingInt(Action.remove_player)].insert(other);
                            },
                            .remove_player => {
                                self.detach(index, other);
                                seen.* = .{ .generation = generation, .uuid = subject.uuid };
                                if (generation != 0 and (other == index or listed_audience.contains(other) or entity_audience.contains(other))) needed[@backingInt(Action.add_player)].insert(other);
                            },
                            .add_player => {
                                seen.known = true;
                                seen.listed = listed_audience.contains(other);
                                seen.spawned = false;
                                // The entry carries the key.
                                seen.chat = self.subjects[index].chat;
                                seen.gamemode = self.subjects[index].gamemode;
                                if (self.workMask(index, .interested).contains(other) and subject.inWorld()) needed[@backingInt(Action.spawn)].insert(other);
                            },
                            .mode => {
                                seen.gamemode = self.subjects[index].gamemode;
                                seen.listed = listed_audience.contains(other);
                            },
                            .chat => seen.chat = self.subjects[index].chat,
                            .spawn => {
                                spawned.insert(other);
                                seen.spawned = true;
                            },
                        }
                    }
                    if (spawned.view().any()) inline for (std.enums.values(Phase)) |update| self.advance(index, update, spawned.view());
                }
            }
            selected = audience.iterator();
            while (selected.next()) |other| {
                const seen = self.lifecycle.get(index, other);
                const watching = &self.observers[other];
                const wants_spawn = other != index and generation != 0 and self.workMask(index, .interested).contains(other) and subject.inWorld();
                const wants_listed = listed_audience.contains(other);
                const wants_known = generation != 0 and (other == index or wants_spawn or wants_listed);
                if (seen.generation != generation or seen.known != wants_known or
                    (wants_known and (seen.gamemode != self.subjects[index].gamemode or seen.listed != wants_listed or seen.chat != self.subjects[index].chat)) or
                    (seen.spawned != wants_spawn))
                {
                    watching.pending.insert(index);
                    watching.pending_dirty = true;
                }
                if (seen.spawned) {
                    watching.spawned.insert(index);
                    self.viewer_masks.row(index).insert(other);
                    if (seen.generation == generation and self.workMask(index, .interested).contains(other) and subject.inWorld()) {
                        self.editWorkMask(index, .updates).insert(other);
                    } else self.editWorkMask(index, .updates).remove(other);
                } else {
                    watching.spawned.remove(index);
                    self.viewer_masks.row(index).remove(other);
                    self.editWorkMask(index, .updates).remove(other);
                }
            }
        }

        self.audience_groups.clear();
        for (self.broadcast_groups[0..self.last_group_count]) |group| group.members.clear();
        self.group_epoch += 1;
        var group_count: usize = 0;
        for (self.actors.values()) |index| {
            const subject = players.records[index];
            if (!self.dirty_work.contains(index * 3 + @backingInt(Work.updates))) continue;
            const watching = self.workMask(index, .updates);
            if (!watching.any()) continue;
            const previous_pending = self.temp(.previous);
            previous_pending.copy(self.pending_updates.row(index).view());
            self.pending_updates.row(index).subtract(self.pending_updates.row(index).view(), ready_observers.view());
            if (!self.pending_updates.row(index).view().any()) self.pending_subjects.remove(index);
            const position = self.subjects[index].position;
            const yaw = self.subjects[index].yaw;
            const pitch = self.subjects[index].pitch;
            const entity_id: i32 = @intCast(index + 1);
            const eligible = self.temp(.eligible);
            eligible.intersect(watching, self.viewers(index));
            const retry = self.temp(.retry);
            retry.clear();
            const common = self.common[index];
            if (eligible.view().any() and common.members[0].view().includes(eligible.view()) and
                common.members[1].view().includes(eligible.view()) and common.members[2].view().includes(eligible.view()))
            {
                const needed = !std.meta.eql(position, common.value.position) or yaw != common.value.yaw or pitch != common.value.pitch or subject.on_ground != common.value.on_ground or
                    common.value.head == null or common.value.head.? != yaw or common.value.flags == null or !std.meta.eql(common.value.flags.?, self.subjects[index].flags);
                if (!needed) continue;
                const members = self.temp(.members);
                members.copy(eligible.view());
                if (ready_observers.view().contains(index)) members.insert(index);
                if (self.audience_groups.get(members.view())) |group| {
                    self.broadcast_groups[group].subjects.insert(index);
                    continue;
                }
                const owned = &self.broadcast_groups[group_count];
                if (owned.members.apply(.copy, members.view(), members.view()).changed == null) {
                    const group = self.audience_groups.getOrPut(owned.members.view());
                    assert(!group.found_existing);
                    group.value_ptr.* = group_count;
                    owned.subjects.clear();
                    owned.subjects.insert(index);
                    group_count += 1;
                    continue;
                }
            }
            inline for (std.enums.values(Phase)) |phase| {
                const targets = self.movement_targets;
                var target_count: usize = 0;
                var uniform = true;
                const changed_phase = switch (phase) {
                    .movement => movement_changed,
                    .head => head_changed,
                    .flags => flags_changed,
                };
                const force = self.temp(.force);
                force.unite(previous_pending.view(), self.workMask(index, .audience));
                const candidates = self.temp(.candidates);
                candidates.intersect(eligible.view(), if (changed_phase.view().contains(index)) watching else force.view());
                const outstanding = self.temp(.outstanding);
                outstanding.clear();
                var selecting = candidates.view().iterator();
                while (selecting.next()) |other| {
                    const observer = players.records[other];
                    const seen = self.observed(index, other);
                    assert(seen.state.spawned and seen.state.generation == self.subjects[index].generation);
                    assert(observer.stage == .ready and observer.world == subject.world);
                    const known = seen.known & (@as(u3, 1) << @backingInt(phase)) != 0;
                    const needed = !known or switch (phase) {
                        .movement => !std.meta.eql(position, seen.value.position) or yaw != seen.value.yaw or pitch != seen.value.pitch or subject.on_ground != seen.value.on_ground,
                        .head => seen.value.head == null or seen.value.head.? != yaw,
                        .flags => seen.value.flags == null or !std.meta.eql(seen.value.flags.?, self.subjects[index].flags),
                    };
                    if (!needed) continue;
                    outstanding.insert(other);
                    const absolute = phase == .movement and (!known or !relative(position, seen.value.position));
                    const group: Group = .{
                        .protocol = observer.protocol,
                        .absolute = absolute,
                        .baseline = if (phase == .movement and !absolute) seen.value.position else @splat(0),
                        .move = if (phase == .movement and !absolute) Move.of(position, yaw, pitch, seen.value) else .both,
                    };
                    if (target_count != 0) uniform = uniform and std.meta.eql(targets[0].group, group);
                    targets[target_count] = .{ .group = group, .handle = observer.handle.? };
                    target_count += 1;
                }
                if (!uniform) std.mem.sort(Target, targets[0..target_count], {}, Target.less);
                var start: usize = 0;
                while (start < target_count) {
                    const key = targets[start].group;
                    const protocol = key.protocol;
                    const absolute = key.absolute;
                    var stop = start + 1;
                    while (stop < target_count and std.meta.eql(targets[stop].group, key)) : (stop += 1) {}
                    const recipients = self.targets;
                    const deliveries = self.deliveries;
                    const count = stop - start;
                    const group = self.temp(.group);
                    group.clear();
                    for (targets[start..stop], recipients[0..count]) |target, *recipient| {
                        recipient.* = .{ .handle = target.handle, .protocol = protocol };
                        group.insert(target.handle.index);
                    }
                    start = stop;
                    const result = switch (phase) {
                        .movement => if (absolute)
                            players.deps.packets.fanout(writePosition, recipients[0..count], .{ entity_id, subject.position, minecraft.Position{ .x = 0, .y = 0, .z = 0 }, subject.rotation, subject.on_ground }, 128, deliveries[0..count])
                        else switch (key.move) {
                            .both => players.deps.packets.fanout(writeMove, recipients[0..count], .{
                                entity_id, @as(i16, @intCast(position[0] - key.baseline[0])), @as(i16, @intCast(position[1] - key.baseline[1])), @as(i16, @intCast(position[2] - key.baseline[2])), yaw, pitch, subject.on_ground,
                            }, 32, deliveries[0..count]),
                            .position => players.deps.packets.fanout(writeShift, recipients[0..count], .{
                                entity_id, @as(i16, @intCast(position[0] - key.baseline[0])), @as(i16, @intCast(position[1] - key.baseline[1])), @as(i16, @intCast(position[2] - key.baseline[2])), subject.on_ground,
                            }, 32, deliveries[0..count]),
                            .look => players.deps.packets.fanout(writeLook, recipients[0..count], .{ entity_id, yaw, pitch, subject.on_ground }, 32, deliveries[0..count]),
                        },
                        .head => players.deps.packets.fanout(writeHeadRotation, recipients[0..count], .{ entity_id, yaw }, 16, deliveries[0..count]),
                        .flags => players.deps.packets.fanout(writeFlags, recipients[0..count], .{ entity_id, self.subjects[index].flags }, 32, deliveries[0..count]),
                    };
                    result catch |err| std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
                    const delivered = self.temp(.delivered);
                    delivered.clear();
                    for (recipients[0..count], deliveries[0..count]) |target, delivery| {
                        if (delivery != .queued) continue;
                        const handle = target.handle;
                        delivered.insert(handle.index);
                        outstanding.remove(handle.index);
                    }
                    self.advance(index, phase, delivered.view());
                    const failed = self.temp(.failed);
                    failed.subtract(group.view(), delivered.view());
                    eligible.subtract(eligible.view(), failed.view());
                }
                retry.unite(retry.view(), outstanding.view());
            }
            self.queueUpdates(index, retry.view());
        }
        self.last_group_count = group_count;
        for (self.broadcast_groups[0..group_count]) |group| {
            const targets = self.targets;
            var target_count: usize = 0;
            var members = group.members.view().iterator();
            while (members.next()) |index| {
                const player = players.records[index];
                targets[target_count] = .{ .handle = player.handle.?, .protocol = player.protocol };
                target_count += 1;
            }
            self.broadcast.begin(targets[0..target_count]) catch {
                var pending = group.subjects.iterator();
                while (pending.next()) |index| {
                    self.queueUpdates(index, self.workMask(index, .updates));
                }
                continue;
            };
            const receipts = self.receipts;
            var subjects = group.subjects.iterator();
            while (subjects.next()) |index| {
                const subject = players.records[index];
                const common = self.common[index];
                const position = self.subjects[index].position;
                const yaw = self.subjects[index].yaw;
                const pitch = self.subjects[index].pitch;
                const entity_id: i32 = @intCast(index + 1);
                const excluded = if (ready_observers.view().contains(index)) subject.handle else null;
                receipts[index] = @splat(null);
                var required: ?sessions.Service.Broadcast.Receipt = null;
                inline for (std.enums.values(Phase)) |phase| {
                    const phase_needed = switch (phase) {
                        .movement => !std.meta.eql(position, common.value.position) or yaw != common.value.yaw or pitch != common.value.pitch or subject.on_ground != common.value.on_ground,
                        .head => common.value.head == null or common.value.head.? != yaw,
                        .flags => common.value.flags == null or !std.meta.eql(common.value.flags.?, self.subjects[index].flags),
                    };
                    if (phase_needed) {
                        const receipt = switch (phase) {
                            .movement => if (!relative(position, common.value.position))
                                players.deps.packets.broadcast(&self.broadcast, writePosition, excluded, required, .{ entity_id, subject.position, minecraft.Position{ .x = 0, .y = 0, .z = 0 }, subject.rotation, subject.on_ground }, 128)
                            else switch (Move.of(position, yaw, pitch, common.value)) {
                                .both => players.deps.packets.broadcast(&self.broadcast, writeMove, excluded, required, .{
                                    entity_id, @as(i16, @intCast(position[0] - common.value.position[0])), @as(i16, @intCast(position[1] - common.value.position[1])), @as(i16, @intCast(position[2] - common.value.position[2])), yaw, pitch, subject.on_ground,
                                }, 32),
                                .position => players.deps.packets.broadcast(&self.broadcast, writeShift, excluded, required, .{
                                    entity_id, @as(i16, @intCast(position[0] - common.value.position[0])), @as(i16, @intCast(position[1] - common.value.position[1])), @as(i16, @intCast(position[2] - common.value.position[2])), subject.on_ground,
                                }, 32),
                                .look => players.deps.packets.broadcast(&self.broadcast, writeLook, excluded, required, .{ entity_id, yaw, pitch, subject.on_ground }, 32),
                            },
                            .head => players.deps.packets.broadcast(&self.broadcast, writeHeadRotation, excluded, required, .{ entity_id, yaw }, 16),
                            .flags => players.deps.packets.broadcast(&self.broadcast, writeFlags, excluded, required, .{ entity_id, self.subjects[index].flags }, 32),
                        } catch |err| std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
                        receipts[index][@backingInt(phase)] = receipt;
                        required = receipt;
                    }
                }
            }
            self.broadcast.commit();
            var batched = group.subjects.iterator();
            while (batched.next()) |index| {
                const eligible = self.temp(.eligible);
                eligible.intersect(self.workMask(index, .updates), self.viewer_masks.row(index).view());
                inline for (std.enums.values(Phase)) |phase| {
                    if (receipts[index][@backingInt(phase)]) |receipt| {
                        const accepted = self.broadcast.accepted(receipt);
                        self.advance(index, phase, accepted);
                        const failed = self.temp(.failed);
                        failed.subtract(eligible.view(), accepted);
                        self.queueUpdates(index, failed.view());
                    }
                }
            }
            self.broadcast.cancel();
        }
        var retiring: usize = 0;
        while (retiring < self.actors.count) {
            const index = self.actors.indices[retiring];
            if (players.records[index].handle == null and self.subjects[index].generation == 0 and self.observers[index].generation == 0) {
                self.pending_updates.row(index).intersect(self.pending_updates.row(index).view(), connected.view());
                if (!self.pending_updates.row(index).view().any()) self.pending_subjects.remove(index);
                if (self.lifecycle.prune(index) and !self.pending_subjects.contains(index)) {
                    self.viewer_masks.row(index).clear();
                    for (self.common[index].members) |members| members.clear();
                    self.actors.remove(index);
                    continue;
                }
            }
            retiring += 1;
        }
    }

    fn assign(destination: *Baseline, value: Baseline, phase: Phase) void {
        switch (phase) {
            .movement => {
                destination.position = value.position;
                destination.yaw = value.yaw;
                destination.pitch = value.pitch;
                destination.on_ground = value.on_ground;
            },
            .head => destination.head = value.head,
            .flags => destination.flags = value.flags,
        }
    }

    fn state(self: *const Replication, subject: usize, observer: usize) Seen {
        var value = self.lifecycle.get(subject, observer);
        if (self.lifecycle.working != subject) value.spawned = self.observers[observer].spawned.view().contains(subject);
        return value;
    }

    fn evictObserver(self: *Replication, ready: sparse_sets.Workspace.RowView) void {
        const other = self.lifecycle.largestObserver();
        const watching = &self.observers[other];
        const handle = self.deps.players.records[other].handle.?;
        self.rejected[other] = handle.generation;
        self.deps.players.deps.sessions.disconnect(handle);
        var spawned = watching.spawned.view().iterator();
        while (spawned.next()) |subject| {
            self.detach(subject, other);
            self.viewer_masks.row(subject).remove(other);
            self.viewer_revisions[subject] += 1;
        }
        watching.spawned.clear();
        watching.pending.clear();
        watching.nearby.clear();
        watching.ready = false;
        watching.pending_dirty = false;
        self.lifecycle.deactivate(other);
        ready.remove(other);
        for (self.dirty_work.values()) |row| self.work_masks.row(row).remove(other);
        std.log.warn("event=replication_capacity_exceeded player={d}", .{handle.index});
    }

    fn baselineKey(self: *const Replication, subject: usize, observer: usize) [4]usize {
        return .{ subject, observer, self.state(subject, observer).generation, self.observers[observer].generation };
    }

    fn baselineSlot(self: *const Replication, key: [4]usize) usize {
        return @intCast(std.hash.Wyhash.hash(0, std.mem.asBytes(&key)) % self.baselines.len);
    }

    fn observed(self: *const Replication, subject: usize, observer: usize) Observation {
        var result: Observation = .{ .state = self.state(subject, observer) };
        const common = &self.common[subject];
        var cached: ?*const CachedBaseline = null;
        var checked_cache = false;
        inline for (std.enums.values(Phase)) |phase| {
            const flag = @as(u3, 1) << @backingInt(phase);
            if (common.members[@backingInt(phase)].view().contains(observer)) {
                assign(&result.value, common.value, phase);
                result.known |= flag;
            } else {
                if (!checked_cache) {
                    checked_cache = true;
                    const key = self.baselineKey(subject, observer);
                    const entry = &self.baselines[self.baselineSlot(key)];
                    if (std.meta.eql(key, entry.key)) cached = entry;
                }
                if (cached) |entry| if (entry.known & flag != 0) {
                    assign(&result.value, entry.value, phase);
                    result.known |= flag;
                };
            }
        }
        return result;
    }

    // Eviction loses only delta encoding opportunities. Unknown baselines use absolute updates.
    fn remember(self: *Replication, subject: usize, observer: usize, value: Baseline, phase: Phase) void {
        const key = self.baselineKey(subject, observer);
        assert(key[2] != 0 and key[3] != 0);
        const entry = &self.baselines[self.baselineSlot(key)];
        if (!std.meta.eql(key, entry.key)) entry.* = .{ .key = key };
        assign(&entry.value, value, phase);
        entry.known |= @as(u3, 1) << @backingInt(phase);
    }

    fn detach(self: *Replication, subject: usize, observer: usize) void {
        const observed_state = self.observed(subject, observer);
        inline for (std.enums.values(Phase)) |phase| {
            if (observed_state.known & (@as(u3, 1) << @backingInt(phase)) != 0) self.remember(subject, observer, observed_state.value, phase);
        }
        for (self.common[subject].members) |members| members.remove(observer);
    }

    fn advance(self: *Replication, index: usize, phase: Phase, accepted: bit_sets.Set) void {
        if (!accepted.any()) return;
        const subject = self.subjects[index];
        const next: Baseline = .{ .position = subject.position, .yaw = subject.yaw, .pitch = subject.pitch, .on_ground = subject.on_ground, .head = subject.yaw, .flags = subject.flags };
        const common = &self.common[index];
        var before: Baseline = .{};
        var after: Baseline = .{};
        assign(&before, common.value, phase);
        assign(&after, next, phase);
        if (!std.meta.eql(before, after)) {
            const displaced = self.temp(.displaced);
            displaced.subtract(common.members[@backingInt(phase)].view(), accepted);
            var previous = displaced.view().iterator();
            while (previous.next()) |observer| {
                self.remember(index, observer, common.value, phase);
            }
            common.members[@backingInt(phase)].clear();
            assign(&common.value, next, phase);
        }
        common.members[@backingInt(phase)].unite(common.members[@backingInt(phase)].view(), accepted);
        assert(common.members[@backingInt(phase)].view().includes(accepted));
    }

    /// The view expires at the next viewers call or tick.
    pub fn viewers(self: *const Replication, subject: usize) bit_sets.Set {
        const output = self.temp(.filtered);
        const handle = self.deps.players.records[subject].handle orelse {
            output.clear();
            return output.view();
        };
        return self.deps.visibility.player_entity.filter(handle, self.viewer_masks.row(subject).view(), output);
    }

    pub const AudienceRevision = struct { entities: u64, visibility: u64 };

    pub fn viewerRevision(self: *const Replication, subject: usize) AudienceRevision {
        assert(subject < self.subjects.len);
        return .{ .entities = self.viewer_revisions[subject], .visibility = self.deps.visibility.player_entity.revision(subject) };
    }

    fn writeSpawnLegacy(packet: wire_1_21_5.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, value: Spawn) ![]u8 {
        const entity = try packet.entityId(value.entity_id);
        const uuid = try entity.objectUUID(value.uuid);
        const kind = try uuid.type(try registry.entityId(game_data.entities.player));
        const x = try kind.x(value.position.x);
        const y = try x.y(value.position.y);
        const z = try y.z(value.position.z);

        const pitch = try z.pitch(value.pitch);
        const yaw = try pitch.yaw(value.yaw);
        const head = try yaw.headPitch(value.head_yaw);
        const data = try head.objectData(0);
        var velocity = try data.velocity();
        return (try velocity.advance(try packets.nested(.{writeVelocity}).write(try velocity.begin(), {}))).finish();
    }

    fn writeVelocity(packet: wire_1_21_5.vec3i16.Writer, _: void) !wire_1_21_5.vec3i16.Writer.Done {
        return (try (try packet.x(0)).y(0)).z(0);
    }

    fn writeSpawnPacked(packet: wire_1_21_9.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, value: Spawn) ![]u8 {
        const entity = try packet.entityId(value.entity_id);
        const uuid = try entity.objectUUID(value.uuid);
        const kind = try uuid.type(try registry.entityId(game_data.entities.player));
        const x = try kind.x(value.position.x);
        const y = try x.y(value.position.y);
        const z = try y.z(value.position.z);
        const velocity = try z.velocity(.{
            .x = 0,
            .y = 0,
            .z = 0,
        });
        const pitch = try velocity.pitch(value.pitch);
        const yaw = try pitch.yaw(value.yaw);
        const head = try yaw.headPitch(value.head_yaw);
        return (try head.objectData(0)).finish();
    }

    fn writeRemove(packet: wire_1_21_5.play.toClient.packet_entity_destroy.Writer, entity_id: i32) ![]u8 {
        const ids = try packet.entityIds(1);
        const entry = try ids.element(entity_id);
        return (try entry.finish()).finish();
    }

    fn writePosition(packet: wire_1_21_5.play.toClient.packet_sync_entity_position.Writer, entity_id: i32, at: minecraft.Position, motion: minecraft.Position, rotation: minecraft.Rotation, on_ground: bool) ![]u8 {
        const entity = try packet.entityId(entity_id);
        const x = try entity.x(at.x);
        const y = try x.y(at.y);
        const z = try y.z(at.z);
        const vx = try z.dx(motion.x);
        const vy = try vx.dy(motion.y);
        const vz = try vy.dz(motion.z);
        const yaw = try vz.yaw(rotation.yaw);
        return (try (try yaw.pitch(rotation.pitch)).onGround(on_ground)).finish();
    }

    fn writeInfo(packet: wire_1_21_5.play.toClient.packet_player_info.Writer, uuid: u128, mode: minecraft.GameMode, is_listed: bool) ![]u8 {
        const action = try packet.action(.{ .update_game_mode = true, .update_listed = true });
        var entries = try action.data(1);
        const entry = (try entries.next()).?;
        var player = try (try entry.uuid(uuid)).player();
        const absent_player = try player.advance(try (try player.begin()).case_default());
        var chat = try absent_player.chatSession();
        const absent_chat = try chat.advance(try (try chat.begin()).case_default());
        var gamemode = try absent_chat.gamemode();
        const selected = try gamemode.advance(try (try gamemode.begin()).case_true(@backingInt(mode)));
        var listed = try selected.listed();
        const absent_listed = try listed.advance(try (try listed.begin()).case_true(@intFromBool(is_listed)));
        var latency = try absent_listed.latency();
        const absent_latency = try latency.advance(try (try latency.begin()).case_default());
        var display = try absent_latency.displayName();
        const absent_display = try display.advance(try (try display.begin()).case_default());
        var priority = try absent_display.listPriority();
        const absent_priority = try priority.advance(try (try priority.begin()).case_default());
        var hat = try absent_priority.showHat();
        try entries.advance(try hat.advance(try (try hat.begin()).case_default()));
        return (try entries.finish()).finish();
    }

    /// A player's new chat key, as vanilla tells everyone when it takes one.
    fn writeChatInfo(packet: wire_1_21_5.play.toClient.packet_player_info.Writer, uuid: u128, session: ?*const ChatSession) ![]u8 {
        const action = try packet.action(.{ .initialize_chat = true });
        var entries = try action.data(1);
        const entry = (try entries.next()).?;
        var player = try (try entry.uuid(uuid)).player();
        const absent_player = try player.advance(try (try player.begin()).case_default());
        var chat = try absent_player.chatSession();
        var present = try (try chat.begin()).case_true();
        const key = try packets.nested(.{Players.writeChatSession}).write(try present.begin(), session);
        const chatted = try chat.advance(try present.advance(key));
        var gamemode = try chatted.gamemode();
        const absent_gamemode = try gamemode.advance(try (try gamemode.begin()).case_default());
        var listed = try absent_gamemode.listed();
        const absent_listed = try listed.advance(try (try listed.begin()).case_default());
        var latency = try absent_listed.latency();
        const absent_latency = try latency.advance(try (try latency.begin()).case_default());
        var display = try absent_latency.displayName();
        const absent_display = try display.advance(try (try display.begin()).case_default());
        var priority = try absent_display.listPriority();
        const absent_priority = try priority.advance(try (try priority.begin()).case_default());
        var hat = try absent_priority.showHat();
        try entries.advance(try hat.advance(try (try hat.begin()).case_default()));
        return (try entries.finish()).finish();
    }

    fn writePlayerRemove(packet: wire_1_21_5.play.toClient.packet_player_remove.Writer, uuid: u128) ![]u8 {
        const players = try packet.players(1);
        const entry = try players.element(uuid);
        return (try entry.finish()).finish();
    }

    fn writeMove(packet: wire_1_21_5.play.toClient.packet_entity_move_look.Writer, entity_id: i32, dx: i16, dy: i16, dz: i16, yaw: i8, pitch: i8, on_ground: bool) ![]u8 {
        const entity = try packet.entityId(entity_id);
        const x = try entity.dX(dx);
        const y = try x.dY(dy);
        const z = try y.dZ(dz);
        const facing = try z.yaw(yaw);
        return (try (try facing.pitch(pitch)).onGround(on_ground)).finish();
    }

    fn writeShift(packet: wire_1_21_5.play.toClient.packet_rel_entity_move.Writer, entity_id: i32, dx: i16, dy: i16, dz: i16, on_ground: bool) ![]u8 {
        const entity = try packet.entityId(entity_id);
        const x = try entity.dX(dx);
        const y = try x.dY(dy);
        return (try (try y.dZ(dz)).onGround(on_ground)).finish();
    }

    fn writeLook(packet: wire_1_21_5.play.toClient.packet_entity_look.Writer, entity_id: i32, yaw: i8, pitch: i8, on_ground: bool) ![]u8 {
        return (try (try (try (try packet.entityId(entity_id)).yaw(yaw)).pitch(pitch)).onGround(on_ground)).finish();
    }

    fn writeHeadRotation(packet: wire_1_21_5.play.toClient.packet_entity_head_rotation.Writer, entity_id: i32, yaw: i8) ![]u8 {
        return (try (try packet.entityId(entity_id)).headYaw(yaw)).finish();
    }

    fn writeFlags(packet: wire_1_21_5.play.toClient.packet_entity_metadata.Writer, entity_id: i32, appearance: Appearance) ![]u8 {
        const entity = try packet.entityId(entity_id);
        var metadata = try entity.metadata();
        // 1.21.9 put Avatar between living entities and players, whose main hand and skin
        // layers come first, which moved the skin layers from 17 to 16.
        const skin_key: u8 = if (packet.layoutProtocol() >= 773) 16 else 17;
        return (try metadata.advance(try packets.nested(.{writeFlagMetadata}).write(try metadata.begin(), .{ .appearance = appearance, .skin_key = skin_key }))).finish();
    }

    const FlagMetadata = struct { appearance: Appearance, skin_key: u8 };

    fn writeFlagMetadata(packet: wire_1_21_5.entityMetadata.Writer, value: FlagMetadata) !wire_1_21_5.entityMetadata.Writer.Done {
        var entries = try packet.value(4);
        try entries.advance(try packets.nested(.{writeFlagEntry}).write((try entries.next()).?, value.appearance.flags));
        try entries.advance(try packets.nested(.{writePoseEntry}).write((try entries.next()).?, value.appearance.flags));
        try entries.advance(try packets.nested(.{writeLivingEntry}).write((try entries.next()).?, value.appearance.living));
        try entries.advance(try packets.nested(.{writeSkinEntry}).write((try entries.next()).?, value));
        return entries.finish();
    }

    fn writeSkinEntry(packet: FlagEntry, value: FlagMetadata) !FlagEntry.Done {
        return (try (try packet.key(value.skin_key)).type()).value(@bitCast(value.appearance.skin_parts));
    }

    const FlagEntry = wire_1_21_5.entityMetadataEntry.cases.value.byte.Writer;
    const PoseEntry = wire_1_21_5.entityMetadataEntry.cases.value.pose.Writer;

    fn writeFlagEntry(packet: FlagEntry, flags: minecraft.EntityFlags) !FlagEntry.Done {
        return (try (try packet.key(0)).type()).value(@bitCast(flags));
    }

    /// LivingEntity.DATA_LIVING_ENTITY_FLAGS, the first living entity field in every release.
    fn writeLivingEntry(packet: FlagEntry, flags: minecraft.LivingFlags) !FlagEntry.Done {
        return (try (try packet.key(8)).type()).value(@bitCast(flags));
    }

    fn writePoseEntry(packet: PoseEntry, flags: minecraft.EntityFlags) !PoseEntry.Done {
        return (try (try packet.key(6)).type()).value(if (flags.sneaking) 5 else 0);
    }
};

fn angle(value: f32) i8 {
    return @bitCast(@as(u8, @intFromFloat(@mod(@floor(@as(f64, value) * 256.0 / 360.0), 256.0))));
}

fn relative(position: [3]i64, baseline: [3]i64) bool {
    const dx = position[0] - baseline[0];
    const dy = position[1] - baseline[1];
    const dz = position[2] - baseline[2];
    return dx >= -32768 and dx <= 32767 and dy >= -32768 and dy <= 32767 and dz >= -32768 and dz <= 32767;
}

fn terrainBounds(position: [3]i64) geometry_bounds.Box {
    var bounds: geometry_bounds.Box = undefined;
    for (0..3) |axis| {
        const coordinate: i32 = @intCast(@divFloor(position[axis], 4096));
        bounds.minimum[axis] = coordinate - 1;
        bounds.maximum[axis] = coordinate + (if (axis == 1) @as(i32, 3) else 2);
    }
    return bounds;
}

fn terrainSections(position: [3]i64) geometry_bounds.Box {
    var bounds = terrainBounds(position);
    for (0..3) |axis| {
        bounds.minimum[axis] = @divFloor(bounds.minimum[axis], 16);
        bounds.maximum[axis] = @divFloor(bounds.maximum[axis] - 1, 16) + 1;
    }
    return bounds;
}

fn fixed(value: f64) i64 {
    return @intFromFloat(@floor(value * 4096.0));
}

test "movement fanout preserves independent admission and observer baselines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selected = comptime definitions: {
        var result: [protocols.implementations.len]sessions.Protocol = undefined;
        for (protocols.implementations, 0..) |Version, i| result[i] = .{ .number = Version.protocol_number };
        break :definitions result;
    };
    const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{
        .connections = 3,
        .pages = 128,
        .page_bytes = 4096,
        .credit_bytes = 32768,
        .protocols = &selected,
    });
    const packet_service = try packets.Packets.init(allocator, .{ .sessions = service });
    var records: [3]Players.Player = undefined;
    for (&records, 0..) |*player, i| {
        player.* = .{ .handle = .{ .index = @intCast(i), .generation = 1 }, .uuid = i + 1, .protocol = selected[0].number, .name = @splat(0), .name_len = 1, .stage = .ready };
        player.name[0] = @intCast('a' + i);
        service.credit[i].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
    }
    var players: Players = .{
        .deps = .{ .sessions = service, .packets = packet_service, .input = undefined, .storage = undefined, .worlds = undefined, .record_workspaces = undefined },
        .config = .{ .maximum = 3, .render_distance = 2 },
        .spawn_world = 0,
        .records = &records,
        .dig_handlers = &.{},
    };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const replication = try Replication.init(allocator, .{ .update_interval = 1 }, .{ .players = &players, .visibility = try Visibility.init(allocator, .{}, .{ .players = &players }) });
    const Drain = struct {
        fn run(endpoint: *sessions.Service, recipients: usize) !usize {
            var count: usize = 0;
            while (endpoint.output.takeReady()) |packet| {
                if (recipients != 0) try std.testing.expectEqual(recipients, packet.recipients.len);
                if (packet.group.count > 1) {
                    const Client = protocols.implementations[0].Protocol.play.toClient;
                    const expected: i32 = switch (packet.group.index) {
                        0, 4 => Client.packetId(.bundle_delimiter),
                        1 => Client.packetId(.spawn_entity),
                        2 => Client.packetId(.entity_metadata),
                        3 => Client.packetId(.entity_head_rotation),
                        else => return error.UnexpectedSpawnMember,
                    };
                    try std.testing.expectEqual(@as(u8, 5), packet.group.count);
                    try std.testing.expectEqual(expected, (try Client.readHeader(packet.bytes)).id);
                }
                try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
                _ = endpoint.preparing.fetchSub(1, .release);
                count += 1;
            }
            return count;
        }
    };
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    const statuses = try allocator.alloc(u64, service.output.slots.len);
    for (service.output.slots, statuses) |*slot, *status| status.* = slot.status.load(.acquire);
    for (0..3) |i| service.credit[i].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    for (0..64) |_| {
        records[0].position.x += 0.01;
        players.rebuildIndexes();
        replication.deps.visibility.tick();
        replication.tick();
        try std.testing.expectEqual(@as(usize, 0), try Drain.run(service, 0));
    }
    for (service.output.slots, statuses) |*slot, status| try std.testing.expectEqual(status, slot.status.load(.acquire));
    for (0..3) |i| service.credit[i].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
    replication.deps.visibility.tick();
    replication.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service, 2));
    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    records[0].position.x += 1;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service, 1));
    try std.testing.expect(replication.observed(0, 1).value.position[0] != replication.observed(0, 2).value.position[0]);
    @memset(replication.baselines, .{});
    try std.testing.expectEqual(@as(u3, 0), replication.observed(0, 2).known & 1);
    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
    records[0].position.x += 1;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    var fallback_packets: usize = 0;
    var absolute_updates: usize = 0;
    while (service.output.takeReady()) |packet| {
        try std.testing.expectEqual(@as(usize, 1), packet.recipients.len);
        if (packet.recipients.first().?.index == 2) {
            const Client = protocols.implementations[0].Protocol.play.toClient;
            try std.testing.expectEqual(Client.packetId(.sync_entity_position), (try Client.readHeader(packet.bytes)).id);
            absolute_updates += 1;
        }
        try std.testing.expect(service.output.releaseReady(packet.page, packet.generation));
        _ = service.preparing.fetchSub(1, .release);
        fallback_packets += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fallback_packets);
    try std.testing.expectEqual(@as(usize, 1), absolute_updates);
    try std.testing.expectEqual(replication.observed(0, 1).value.position[0], replication.observed(0, 2).value.position[0]);
    records[0].position.x += 16;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service, 2));
    if (comptime selected.len > 1) {
        records[2].protocol = selected[1].number;
        records[0].position.x += 1;
        players.rebuildIndexes();
        replication.deps.visibility.tick();
        replication.tick();
        try std.testing.expectEqual(@as(usize, 2), try Drain.run(service, 1));
    }

    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    records[0].rotation.yaw = 90;
    records[0].flags.sneaking = true;
    records[0].on_ground = true;
    replication.deps.visibility.tick();
    replication.tick();
    try std.testing.expectEqual(@as(usize, 3), try Drain.run(service, 1));
    try std.testing.expectEqual(@as(usize, 4), replication.pending_updates.row(0).view().wordAt(0));
    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
    replication.deps.visibility.tick();
    replication.tick();
    try std.testing.expectEqual(@as(usize, 3), try Drain.run(service, 1));
    try std.testing.expectEqual(@as(usize, 0), replication.pending_updates.row(0).view().wordAt(0));
    try std.testing.expectEqual(replication.observed(0, 1), replication.observed(0, 2));

    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    records[2].position.x = 1000;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 3), replication.observers[2].pending.view().wordAt(0));
    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
    replication.deps.visibility.tick();
    replication.tick();
    try std.testing.expectEqual(@as(usize, 2), try Drain.run(service, 1));
    try std.testing.expectEqual(@as(usize, 0), replication.observers[2].pending.view().wordAt(0));
    try std.testing.expectEqual(@as(usize, 2), replication.viewers(0).words[0]);
    try std.testing.expectEqual(@as(usize, 1), replication.viewers(1).words[0]);
    try std.testing.expectEqual(@as(usize, 0), replication.viewers(2).words[0]);

    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    records[2].position = records[1].position;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 3), replication.observers[2].pending.view().wordAt(0));
    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 0), replication.observers[2].pending.view().wordAt(0));
    try std.testing.expectEqual(@as(usize, 6), replication.viewers(0).words[0]);
    try std.testing.expectEqual(@as(usize, 5), replication.viewers(1).words[0]);
    try std.testing.expectEqual(@as(usize, 3), replication.viewers(2).words[0]);
    for (service.output.slots, statuses) |*slot, *status| status.* = slot.status.load(.acquire);
    for (0..64) |_| {
        replication.deps.visibility.tick();
        replication.tick();
        try std.testing.expectEqual(@as(usize, 0), try Drain.run(service, 0));
    }
    for (service.output.slots, statuses) |*slot, status| try std.testing.expectEqual(status, slot.status.load(.acquire));

    records[2].handle = null;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 2), replication.viewers(0).words[0]);
    try std.testing.expectEqual(@as(usize, 1), replication.viewers(1).words[0]);
    try std.testing.expectEqual(@as(usize, 0), replication.viewers(2).words[0]);
    records[2].handle = .{ .index = 2, .generation = 2 };
    players.rebuildIndexes();
    service.credit[2].store(@as(u64, 2) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 6), replication.viewers(0).words[0]);
    try std.testing.expectEqual(@as(usize, 5), replication.viewers(1).words[0]);
    try std.testing.expectEqual(@as(usize, 3), replication.viewers(2).words[0]);
    try std.testing.expectEqual(@as(u32, 2), replication.state(2, 0).generation);
    try std.testing.expectEqual(@as(u32, 2), replication.state(2, 1).generation);

    records[2].stage = .respawn;
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 2), replication.viewers(0).words[0]);
    records[0].position.x += 1;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service, 1));
    records[2].stage = .ready;
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 6), replication.viewers(0).words[0]);
    try std.testing.expectEqual(replication.observed(0, 1).value.position, replication.observed(0, 2).value.position);

    records[2].world = 1;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 2), replication.viewers(0).words[0]);
    try std.testing.expectEqual(@as(usize, 0), replication.viewers(2).words[0]);
    records[2].world = 0;
    players.rebuildIndexes();
    replication.deps.visibility.tick();
    replication.tick();
    _ = try Drain.run(service, 0);
    try std.testing.expectEqual(@as(usize, 6), replication.viewers(0).words[0]);
    try std.testing.expectEqual(@as(usize, 3), replication.viewers(2).words[0]);
    for (0..2) |_| {
        replication.deps.visibility.tick();
        replication.tick();
        try std.testing.expectEqual(@as(usize, 0), try Drain.run(service, 0));
    }
    try std.testing.expectEqual(@as(usize, 0), replication.dirty_work.count);
    try std.testing.expectEqual(@as(usize, 0), replication.pending_subjects.count);
}

test "operation counts for shared player neighborhoods and local spatial invalidation" {
    for ([_]usize{ 16, 64, 256 }) |count| for ([_]bool{ false, true }) |clustered| for ([_]usize{ count, count / 2, 0 }) |moving| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        const selected = comptime definitions: {
            var result: [protocols.implementations.len]sessions.Protocol = undefined;
            for (protocols.implementations, 0..) |Version, i| result[i] = .{ .number = Version.protocol_number };
            break :definitions result;
        };
        const endpoint = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = count, .pages = 16 * count, .page_bytes = 4096, .credit_bytes = 1024 * 1024, .protocols = &selected });
        const encoding = try packets.Packets.init(allocator, .{ .sessions = endpoint });
        const rows = try allocator.alloc(Players.Player, count);
        for (rows, 0..) |*player, index| player.* = .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .protocol = selected[0].number, .name = @splat('a'), .name_len = 1, .stage = .ready, .loaded = true, .on_ground = true, .position = .{ .x = (if (clustered) 0 else @as(f64, @floatFromInt(index * 128))) + 15.9, .y = 65, .z = 8 } };
        var players: Players = .{ .deps = .{ .sessions = endpoint, .packets = encoding, .input = undefined, .storage = undefined, .worlds = undefined, .record_workspaces = undefined }, .config = .{ .maximum = count, .render_distance = 2 }, .spawn_world = 0, .records = rows, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const visibility = try Visibility.init(allocator, .{}, .{ .players = &players });
        const replication = try Replication.init(allocator, .{ .update_interval = 1 }, .{ .players = &players, .visibility = visibility });
        failing.fail_index = failing.alloc_index;
        for (0..3) |_| {
            for (endpoint.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active | endpoint.config.credit_bytes, .release);
            visibility.tick();
            replication.tick();
            while (endpoint.output.takeReady()) |packet| {
                try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
                _ = endpoint.preparing.fetchSub(1, .release);
            }
        }
        for (endpoint.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active | endpoint.config.credit_bytes, .release);
        for (rows[0..moving]) |*row| row.position.x += 0.2;
        players.rebuildIndexes();

        visibility.tick();
        replication.tick();
        var outgoing: usize = 0;
        var receivers: usize = 0;
        while (endpoint.output.takeReady()) |packet| {
            outgoing += 1;
            receivers += packet.recipients.len;
            try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
            _ = endpoint.preparing.fetchSub(1, .release);
        }
        if (clustered and moving > 0) {
            try std.testing.expectEqual(@as(usize, if (moving == count) 1 else 2), replication.neighborhoods.count());
            try std.testing.expectEqual(moving, outgoing);
            try std.testing.expectEqual(moving * (count - 1), receivers);
        }
        if (!clustered) try std.testing.expectEqual(@as(usize, 0), outgoing);
        for (0..if (count == 16) @as(usize, 8) else 1) |step| {
            if (step > 0) {
                for (rows, 0..) |*row, index| switch (step) {
                    1 => {
                        if (index % 2 == 0) row.position.x += 1024;
                    },
                    2 => {
                        row.world = @intCast(index % 3);
                    },
                    3 => {
                        if (index % 3 == 0) row.handle = null;
                    },
                    4 => {
                        if (index % 3 == 0) {
                            row.handle = .{ .index = index, .generation = 2 };
                            row.position.x = 16.1;
                        }
                    },
                    5 => {
                        if (index % 2 == 0) row.stage = .awaiting_teleport;
                    },
                    6 => {
                        row.stage = .ready;
                        row.world = 0;
                        row.position.x = -16.1;
                    },
                    7 => {
                        players.config.render_distance = 4;
                        if (index < count / 2) row.position.x = 64.1;
                    },
                    else => unreachable,
                };
                players.rebuildIndexes();
                for (rows, endpoint.credit) |row, *credit| credit.store((@as(u64, if (row.handle) |handle| handle.generation else 0) << 32) | sessions.Service.active | endpoint.config.credit_bytes, .release);
                visibility.tick();
                replication.tick();
                while (endpoint.output.takeReady()) |packet| {
                    try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
                    _ = endpoint.preparing.fetchSub(1, .release);
                }
            }
            for (rows, 0..) |observer, other| {
                if (observer.handle == null or observer.stage != .ready) continue;
                const nearby = replication.observers[other].nearby.view();
                for (rows, 0..) |subject, index| {
                    const expected = subject.handle != null and subject.world == observer.world and
                        @abs(@floor(subject.position.x / 16) - @floor(observer.position.x / 16)) <= @as(f64, @floatFromInt(players.config.render_distance)) and
                        @abs(@floor(subject.position.z / 16) - @floor(observer.position.z / 16)) <= @as(f64, @floatFromInt(players.config.render_distance));
                    try std.testing.expectEqual(expected, nearby.contains(index));
                }
            }
        }
    };
}

test "players update every second tick with the movement that changed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selected = comptime definitions: {
        var result: [protocols.implementations.len]sessions.Protocol = undefined;
        for (protocols.implementations, 0..) |Version, i| result[i] = .{ .number = Version.protocol_number };
        break :definitions result;
    };
    const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = 2, .pages = 64, .page_bytes = 4096, .credit_bytes = 32768, .protocols = &selected });
    const packet_service = try packets.Packets.init(allocator, .{ .sessions = service });
    var records: [2]Players.Player = undefined;
    for (&records, 0..) |*player, i| {
        player.* = .{ .handle = .{ .index = @intCast(i), .generation = 1 }, .uuid = i + 1, .protocol = selected[0].number, .name = @splat(0), .name_len = 1, .stage = .ready };
        player.name[0] = @intCast('a' + i);
        service.credit[i].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
    }
    var players: Players = .{
        .deps = .{ .sessions = service, .packets = packet_service, .input = undefined, .storage = undefined, .worlds = undefined, .record_workspaces = undefined },
        .config = .{ .maximum = 2, .render_distance = 2 },
        .spawn_world = 0,
        .records = &records,
        .dig_handlers = &.{},
    };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const replication = try Replication.init(allocator, .{}, .{ .players = &players, .visibility = try Visibility.init(allocator, .{}, .{ .players = &players }) });
    const Client = protocols.implementations[0].Protocol.play.toClient;
    const Seen = struct { shift: usize = 0, look: usize = 0, both: usize = 0 };
    const drain = struct {
        fn run(endpoint: *sessions.Service) Seen {
            var seen: Seen = .{};
            while (endpoint.output.takeReady()) |packet| {
                const id = (Client.readHeader(packet.bytes) catch unreachable).id;
                if (id == Client.packetId(.rel_entity_move)) seen.shift += 1;
                if (id == Client.packetId(.entity_look)) seen.look += 1;
                if (id == Client.packetId(.entity_move_look)) seen.both += 1;
                _ = endpoint.output.releaseReady(packet.page, packet.generation);
                _ = endpoint.preparing.fetchSub(1, .release);
            }
            return seen;
        }
    }.run;
    replication.deps.visibility.tick();
    replication.tick();
    _ = drain(service);
    // Moving every tick for ten ticks: five updates per watcher, each carrying only the position.
    var total: Seen = .{};
    for (0..10) |_| {
        records[0].position.x += 0.1;
        players.rebuildIndexes();
        replication.deps.visibility.tick();
        replication.tick();
        const seen = drain(service);
        total.shift += seen.shift;
        total.look += seen.look;
        total.both += seen.both;
    }
    try std.testing.expectEqual(Seen{ .shift = 5 }, total);
    // Turning alone sends the look alone, and moving while turning sends both.
    total = .{};
    for (0..4) |tick| {
        records[0].rotation.yaw += 30;
        if (tick >= 2) records[0].position.z += 0.1;
        players.rebuildIndexes();
        replication.deps.visibility.tick();
        replication.tick();
        const seen = drain(service);
        total.shift += seen.shift;
        total.look += seen.look;
        total.both += seen.both;
    }
    try std.testing.expectEqual(Seen{ .look = 1, .both = 1 }, total);
}
