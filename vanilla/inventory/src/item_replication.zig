const sparse_sets = @import("lightning_rod").system.sparse_sets;
const bit_sets = @import("lightning_rod").system.bit_sets;
const std = @import("std");
const Selection = @import("vanilla_item_entities").item_selection.Selection;
const Items = @import("vanilla_items").items.Items;
const inventories = @import("inventories");
const entities = @import("entities");
const records = @import("records");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const game_data = @import("game_data");
const item_packets = @import("vanilla_items").item_packets;
const packets = @import("minecraft_packets");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_9 = @import("wire_1_21_9");
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const ItemTick = @import("item_tick.zig").ItemTick;
const Players = @import("players").players.Players;
const Streaming = @import("terrain").streaming.Streaming;

const assert = std.debug.assert;

pub const ItemReplication = struct {
    pub const id = "minecraft:item_replication";

    pub const Configuration = struct {
        /// Ticks between an item's position updates. Vanilla tracks dropped items every 20 ticks, and
        /// clients move them by their velocity in between.
        position_interval: u8 = 20,
        /// Items clients are shown at once.
        views: usize = 65536,
        /// Items looked at in one tick before replication looks over all of them instead.
        work_ids: usize = 65536,
        /// Keep a hash of every packet queued, for runs to be compared by.
        trace_sends: bool = false,
    };

    const tracking_distance = 96;

    pub const Dependencies = struct {
        dropped: *ItemEntities,
        item_tick: *ItemTick,
        players: *Players,
        streaming: *Streaming,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
    };

    const Spawn = struct {
        entity_id: i32,
        uuid: u128,
        position: minecraft.Position,
        velocity: [3]f64,
    };

    /// What clients were last shown of an item, at the head of its view; the viewer rows follow
    /// it.
    const Header = extern struct {
        revision: u64 = 0,
        collection: u64 = 0,
        inventory_revision: u64 = 0,
        collecting: bool = false,
        /// Whether viewers were last shown it burning.
        burning: bool = false,
        padding: [6]u8 = @splat(0),
    };
    const row_count = 6;
    const record_align = @alignOf(Header);
    comptime {
        assert(@sizeOf(Header) % @alignOf(usize) == 0);
    }

    /// An item's view, where it lies, edited in place while in hand.
    const View = struct {
        entity: entities.Id,
        header: *Header,
        spawned: bit_sets.Row,
        dirty: bit_sets.Row,
        collected: bit_sets.Row,
        interested: bit_sets.Row,
        stacks: bit_sets.Row,
        pending: bit_sets.Row,
        /// Nothing more to do for it this tick.
        done: bool = false,
        /// Gone, and no client knows of it: it goes once it is let go.
        forget: bool = false,

        /// Whether it holds anything a later tick needs: a view of nothing is no view.
        fn holds(self: *const View) bool {
            inline for (.{ "spawned", "dirty", "collected", "interested", "stacks", "pending" }) |name| {
                if (@field(self, name).view().any()) return true;
            }
            return false;
        }
    };

    const Connection = struct {
        generation: u32 = 0,
        life: u32 = 0,
        world: u32 = 0,
        position: [2]f64 = @splat(0),
        ready: bool = false,
    };

    const Phase = enum { spawn, stack, position, collect, remove };

    const Batch = struct {
        const Delivery = struct { view: *View, phase: Phase, receipt: sessions.Service.Broadcast.Receipt };

        owner: *ItemReplication,
        audience: sparse_sets.Workspace.RowView,
        deliveries: [sessions.Service.batch_max]Delivery = undefined,
        count: usize = 0,

        fn prepare(self: *Batch, audience: bit_sets.Set, packets_per_group: usize) !bool {
            assert(audience.any() and packets_per_group > 0 and packets_per_group <= sessions.Service.batch_max);
            const owner = self.owner;
            const broadcast = &owner.broadcast;
            if (broadcast.active and (!self.audience.view().eql(audience) or self.count == self.deliveries.len or
                packets_per_group * owner.deps.sessions.config.protocols.len > broadcast.entries.len - broadcast.count)) self.flush();
            if (broadcast.active) return true;
            assert(self.count == 0);
            var remaining = audience.iterator();
            var count: usize = 0;
            while (remaining.next()) |index| {
                const player = owner.deps.players.records[index];
                owner.recipients[count] = .{ .handle = player.handle.?, .protocol = player.protocol };
                count += 1;
            }
            broadcast.begin(owner.recipients[0..count]) catch |err| switch (err) {
                error.Backpressured => return false,
                else => return err,
            };
            self.audience.copy(audience);
            return true;
        }

        fn append(self: *Batch, view: *View, phase: Phase, receipt: sessions.Service.Broadcast.Receipt) void {
            assert(self.owner.broadcast.active and self.count < self.deliveries.len);
            assert(receipt.owner == &self.owner.broadcast and receipt.generation == self.owner.broadcast.generation);
            self.deliveries[self.count] = .{ .view = view, .phase = phase, .receipt = receipt };
            self.count += 1;
        }

        fn flush(self: *Batch) void {
            const owner = self.owner;
            const broadcast = &owner.broadcast;
            if (!broadcast.active) {
                assert(self.count == 0);
                return;
            }
            assert(self.count > 0 and self.count <= self.deliveries.len);
            broadcast.commit();
            for (self.deliveries[0..self.count]) |delivery| {
                const delivered = broadcast.accepted(delivery.receipt);
                var unsupported = broadcast.unsupported(delivery.receipt).iterator();
                while (unsupported.next()) |index| {
                    owner.deps.sessions.disconnect(broadcast.handleAt(index));
                }
                const view = delivery.view;
                switch (delivery.phase) {
                    .spawn => {
                        view.spawned.unite(view.spawned.view(), delivered);
                        view.dirty.unite(view.dirty.view(), delivered);
                        view.stacks.subtract(view.stacks.view(), delivered);
                        view.collected.unite(view.collected.view(), delivered);
                    },
                    .stack => view.stacks.subtract(view.stacks.view(), delivered),
                    .position => view.dirty.subtract(view.dirty.view(), delivered),
                    .collect => view.collected.unite(view.collected.view(), delivered),
                    .remove => {
                        view.spawned.subtract(view.spawned.view(), delivered);
                        view.dirty.subtract(view.dirty.view(), delivered);
                        view.collected.subtract(view.collected.view(), delivered);
                        view.stacks.subtract(view.stacks.view(), delivered);
                    },
                }
            }
            broadcast.cancel();
            self.count = 0;
            self.audience.clear();
        }
    };

    /// What one tick looks at items with: who may be sent to, who was replaced, what changed.
    const Pass = struct {
        visibility: *const Streaming.Visibility,
        valid: sparse_sets.Workspace.RowView,
        reset: sparse_sets.Workspace.RowView,
        available: sparse_sets.Workspace.RowView,
        presentation_changed: bool,
        outgoing: *Batch,
    };

    deps: Dependencies,
    /// Room to copy ids into, for sweeps that change what they pass over.
    viewed: []entities.Id,
    found: []entities.Id,
    /// Views by item id: an item no client knows of has none.
    views: entities.Slab,
    record_bytes: usize,
    row_words: usize,
    presentation: u64 = 0,
    /// Items to look at this tick, and those some viewer is still owed something by.
    work: entities.IdSet,
    /// Items only due their turn: still where they were, so who is interested in each is as it
    /// was; anything that could change it puts the item in `work` instead.
    turns: entities.IdSet,
    retries: entities.IdSet,
    /// Viewers some retry is owed something by, as of the last tick.
    pending: sparse_sets.Workspace.RowView,
    selections: sparse_sets.Workspace,
    connections: []Connection,
    tracked_connections: lightning_rod.system.IndexSet,
    recipients: []sessions.Service.Target,
    listener: inventories.Inventories.Listener,
    broadcast: sessions.Service.Broadcast,
    selection: Selection,
    selection_candidates: lightning_rod.metrics.Counter,
    selection_nodes: lightning_rod.metrics.Counter,
    sweeps: lightning_rod.metrics.Counter,
    position_interval: u8,
    ticks: u64 = 0,
    /// A running hash of every packet asked to be sent, when tests trace it.
    traced: u64 = 0,
    tracing: bool,
    /// Views in hand until what was sent for them is known: a broadcast batch gathers many.
    held: [held_max]View = undefined,
    held_alive: [held_max]bool = undefined,
    held_count: usize = 0,
    const held_max = 64;

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ItemReplication {
        if (config.position_interval == 0) return error.InvalidConfiguration;
        const self = try allocator.create(ItemReplication);
        const connections = try allocator.alloc(Connection, deps.players.records.len);
        @memset(connections, .{});
        const selections = try sparse_sets.Workspace.init(allocator, 28, connections.len);
        const row_words = std.math.divCeil(usize, connections.len, @bitSizeOf(usize)) catch unreachable;
        const record_bytes = @sizeOf(Header) + row_count * row_words * @sizeOf(usize);
        self.* = .{
            .pending = selections.row(0),
            .selections = selections,
            .views = try .init(allocator, &deps.dropped.deps.entities.pool, record_bytes, config.views),
            .viewed = try allocator.alloc(entities.Id, config.views),
            .found = try allocator.alloc(entities.Id, deps.dropped.items.bound()),
            .record_bytes = record_bytes,
            .row_words = row_words,
            .broadcast = try sessions.Service.Broadcast.init(allocator, deps.sessions, sessions.Service.batch_max * deps.sessions.config.protocols.len),
            .deps = deps,
            .work = try entities.IdSet.init(allocator, &deps.dropped.deps.entities.pool, config.work_ids),
            .turns = try entities.IdSet.init(allocator, &deps.dropped.deps.entities.pool, config.work_ids),
            .retries = try entities.IdSet.init(allocator, &deps.dropped.deps.entities.pool, config.work_ids),
            .connections = connections,
            .tracked_connections = try lightning_rod.system.IndexSet.init(allocator, connections.len),
            .recipients = try allocator.alloc(sessions.Service.Target, connections.len),
            .listener = .{ .context = self, .function = slotChanged },
            // A connection selects at most six regions a tick: both views when its view resets,
            // and two strips for each axis it moves along.
            .selection = try Selection.init(allocator, connections.len * 6),
            .selection_candidates = try deps.dropped.deps.metrics.counter(.{ .name = "items.replication.selection.candidates", .description = "Indexed items examined by movement selection" }),
            .selection_nodes = try deps.dropped.deps.metrics.counter(.{ .name = "items.replication.selection.coverage_nodes", .description = "Coverage nodes updated or examined by batched movement selection" }),
            .sweeps = try deps.dropped.deps.metrics.counter(.{ .name = "items.replication.sweeps", .description = "Ticks that looked over every item, as more changed than could be noted" }),
            .position_interval = config.position_interval,
            .tracing = config.trace_sends,
        };
        deps.inventories.listen(&self.listener);
        deps.dropped.leaving = .{ .context = self, .function = itemLeaving };
        return self;
    }

    /// An item left memory, far from every player: no client keeps it, and its view goes.
    fn itemLeaving(context: *anyopaque, entity: entities.Id) void {
        const self: *ItemReplication = @ptrCast(@alignCast(context));
        self.views.remove(entity);
        self.retries.remove(entity);
        self.work.remove(entity);
        self.turns.remove(entity);
    }

    /// How many clients an item is spawned for, and how many are still owed something by it.
    pub const Known = struct { spawned: usize = 0, pending: usize = 0, stacks: usize = 0 };

    pub fn known(self: *ItemReplication, entity: entities.Id) !Known {
        const bytes = self.views.get(entity) orelse return .{};
        const view = self.viewOf(entity, bytes);
        return .{ .spawned = view.spawned.view().count(), .pending = view.pending.view().count(), .stacks = view.stacks.view().count() };
    }

    /// Whether a viewer is owed an item's position, for tests.
    pub fn dirtyFor(self: *ItemReplication, entity: entities.Id, viewer: usize) !bool {
        const bytes = self.views.get(entity) orelse return false;
        return self.viewOf(entity, bytes).dirty.view().contains(viewer);
    }

    /// Takes views in hand, a fresh one of nothing for an item without one.
    fn holdViews(self: *ItemReplication, ids: []const entities.Id, output: []View) !void {
        assert(ids.len == output.len and ids.len <= 16);
        for (ids, output) |entity, *view| view.* = self.viewOf(entity, try self.views.getOrCreate(entity));
    }

    fn viewOf(self: *ItemReplication, entity: entities.Id, bytes: []align(16) u8) View {
        const words: []usize = @alignCast(std.mem.bytesAsSlice(usize, bytes[@sizeOf(Header)..]));
        const capacity = self.connections.len;
        var rows: [row_count]bit_sets.Row = undefined;
        for (&rows, 0..) |*row, at| row.* = .{ .words = words[at * self.row_words ..][0..self.row_words], .capacity = capacity };
        return .{
            .entity = entity,
            .header = @ptrCast(bytes[0..@sizeOf(Header)]),
            .spawned = rows[0],
            .dirty = rows[1],
            .collected = rows[2],
            .interested = rows[3],
            .stacks = rows[4],
            .pending = rows[5],
        };
    }

    /// Lets go of a view: kept if it holds anything, gone if not.
    fn letGo(self: *ItemReplication, view: *View) void {
        if (!view.holds() or view.forget) self.views.remove(view.entity);
    }

    /// An item's stack changed: its viewers may be owed it.
    fn slotChanged(context: *anyopaque, slot: inventories.Slot) void {
        const self: *ItemReplication = @ptrCast(@alignCast(context));
        const entity = ItemEntities.entityOf(slot.owner) orelse return;
        self.work.insert(entity);
    }

    /// Items that only moved since last looked at: their viewers are owed a position, which goes
    /// out on the item's turn, when its revision is found changed. Off its turn nothing would
    /// come of looking at one.
    fn noteMoved(self: *ItemReplication) void {
        const dropped = self.deps.dropped;
        defer dropped.moved.clear();
        // A sleeper moves every tick as any resting item does: on its turn it is looked at in
        // full, which brings it up to date first.
        for (dropped.sleepers.keys(), dropped.sleepers.constItems()) |entity, sleep| {
            if (sleep.asleep and self.onTurn(entity)) self.turns.insert(entity);
        }
        for (dropped.moved.values()) |entity| {
            if (self.onTurn(entity)) self.turns.insert(entity);
        }
    }

    /// Items take turns by id, so a moving one goes out once per interval with all it moved.
    fn onTurn(self: *const ItemReplication, entity: entities.Id) bool {
        return (self.ticks + entity) % self.position_interval == 0;
    }

    pub fn tick(self: *ItemReplication) !void {
        assert(self.selection.count == 0);
        self.ticks += 1;
        const dropped = self.deps.dropped;
        if (dropped.count() == 0) {
            self.work.clear();
            self.turns.clear();
            self.retries.clear();
            self.pending.clear();
            dropped.moved.clear();
            dropped.changes.clear();
            return;
        }
        const service = self.deps.sessions;
        const visibility = self.deps.streaming.snapshotVisibility();
        const presentation_changed = self.presentation != self.deps.items.components.revision;
        self.presentation = self.deps.items.components.revision;
        const valid = self.selections.row(1);
        const reset = self.selections.row(2);
        const available = self.selections.row(3);
        valid.clear();
        reset.clear();
        available.clear();
        for (self.deps.players.activeSlots()) |index| self.tracked_connections.insert(index);
        var observer_index: usize = 0;
        while (observer_index < self.tracked_connections.count) {
            const index = self.tracked_connections.indices[observer_index];
            const player = self.deps.players.records[index];
            const connection = &self.connections[index];
            if (player.handle == null) self.tracked_connections.remove(index) else observer_index += 1;
            const current: Connection = .{ .generation = if (player.handle) |handle| handle.generation else 0, .life = player.life, .world = player.world, .position = .{ player.position.x, player.position.z }, .ready = player.stage == .ready };
            const changed = connection.generation != current.generation or connection.life != current.life or connection.world != current.world or connection.ready != current.ready;
            if (changed or visibility.reset.contains(index)) {
                if (connection.ready) self.selectBounds(connection.world, .{ connection.position[0] - tracking_distance, connection.position[1] - tracking_distance }, .{ connection.position[0] + tracking_distance, connection.position[1] + tracking_distance });
                if (current.ready) self.selectBounds(current.world, .{ current.position[0] - tracking_distance, current.position[1] - tracking_distance }, .{ current.position[0] + tracking_distance, current.position[1] + tracking_distance });
            }
            if (!changed and current.ready and !std.meta.eql(connection.position, current.position)) self.selectMovement(current.world, connection.position, current.position);
            const replaced = connection.generation != current.generation or connection.life != current.life;
            connection.* = current;
            const handle = player.handle orelse continue;
            valid.insert(index);
            if (service.outputCredit(handle) != 0) available.insert(index);
            if (replaced) reset.insert(index);
        }
        self.noteMoved();
        const selection = try self.selection.select(&dropped.places.space, ItemEntities.kinds, &self.work);
        self.selection_candidates.add(selection.candidates);
        self.selection_nodes.add(selection.coverage_nodes);
        try self.selectVisibility(visibility);
        for (dropped.changes.values()) |entity| self.work.insert(entity);
        // More changed than could be noted, or every stack shows differently: look at them all.
        const sweep = presentation_changed or dropped.changes.overflowed or dropped.moved.overflowed or self.work.overflowed or self.retries.overflowed or self.turns.overflowed;
        dropped.changes.clear();
        // Retries are looked at again when someone they owe may be sent to; their owed viewers
        // are gathered again as they are.
        if (self.pending.view().intersects(available.view())) {
            for (self.retries.values()) |entity| self.work.insert(entity);
            self.pending.clear();
        }
        defer self.turns.clear();
        if (self.work.count() == 0 and self.turns.count() == 0 and !sweep) return;
        var outgoing: Batch = .{ .owner = self, .audience = self.selections.row(4) };
        defer if (self.broadcast.active) self.broadcast.cancel();
        const pass: Pass = .{ .visibility = visibility, .valid = valid, .reset = reset, .available = available, .presentation_changed = presentation_changed, .outgoing = &outgoing };
        // The work set takes no more while it is gone over; what comes of it waits for the next.
        var cursor: usize = 0;
        while (cursor < self.work.count()) {
            const count = @min(16, self.work.count() - cursor);
            var ids: [16]entities.Id = undefined;
            @memcpy(ids[0..count], self.work.values()[cursor..][0..count]);
            cursor += count;
            try self.process(ids[0..count], pass, false);
        }
        // Those only due their turn, and looked at in full for nothing else.
        cursor = 0;
        while (cursor < self.turns.count()) {
            var ids: [16]entities.Id = undefined;
            var count: usize = 0;
            while (cursor < self.turns.count() and count < ids.len) : (cursor += 1) {
                const entity = self.turns.values()[cursor];
                if (self.work.contains(entity) or self.retries.contains(entity)) continue;
                ids[count] = entity;
                count += 1;
            }
            try self.process(ids[0..count], pass, true);
        }
        self.work.clear();
        if (sweep) {
            self.sweeps.add(1);
            self.retries.overflowed = false;
            try self.sweepAll(pass);
        }
        try self.settle(pass);
    }

    /// Learns what was sent for the views in hand, works out what each viewer is still owed,
    /// and lets them go; the gone no client knows of any more are forgotten.
    fn settle(self: *ItemReplication, pass: Pass) !void {
        pass.outgoing.flush();
        var forgotten: [held_max]entities.Id = undefined;
        var forgotten_count: usize = 0;
        defer self.held_count = 0;
        for (self.held[0..self.held_count], self.held_alive[0..self.held_count]) |*view, alive| {
            defer self.letGo(view);
            if (view.done) {
                if (view.forget) {
                    forgotten[forgotten_count] = view.entity;
                    forgotten_count += 1;
                }
                continue;
            }
            if (!alive and !view.spawned.view().any()) {
                self.retries.remove(view.entity);
                view.forget = true;
                forgotten[forgotten_count] = view.entity;
                forgotten_count += 1;
                continue;
            }
            const interested = view.interested.view();
            view.pending.difference(interested, view.spawned.view());
            const changed = self.selections.row(8);
            changed.unite(view.stacks.view(), view.dirty.view());
            changed.intersect(changed.view(), interested);
            view.pending.unite(view.pending.view(), changed.view());
            if (view.header.collecting) {
                changed.subtract(view.spawned.view(), view.collected.view());
                view.pending.unite(view.pending.view(), changed.view());
            }
            if (view.pending.view().any()) {
                self.retries.insert(view.entity);
                self.pending.unite(self.pending.view(), view.pending.view());
            } else self.retries.remove(view.entity);
        }
        self.held_count = 0;
        for (forgotten[0..forgotten_count]) |entity| try self.deps.dropped.forget(entity);
    }

    /// Looks at every item with a view, and every item within tracking distance of a player,
    /// each once while the work set, empty by now, has room to remember it.
    fn sweepAll(self: *ItemReplication, pass: Pass) !void {
        assert(self.work.count() == 0);
        defer self.work.clear();
        const viewed = self.views.ids(self.viewed);
        var at: usize = 0;
        while (at < viewed.len) {
            const count = @min(16, viewed.len - at);
            var ids: [16]entities.Id = undefined;
            @memcpy(ids[0..count], viewed[at..][0..count]);
            at += count;
            try self.process(self.unswept(ids[0..count]), pass, false);
        }
        const dropped = self.deps.dropped;
        const reach = tracking_distance / 16 + 1;
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            if (player.handle == null or player.stage != .ready) continue;
            const center: [2]i32 = .{ @intFromFloat(@floor(player.position.x / 16)), @intFromFloat(@floor(player.position.z / 16)) };
            var x = center[0] - reach;
            while (x <= center[0] + reach) : (x += 1) {
                var z = center[1] - reach;
                while (z <= center[1] + reach) : (z += 1) {
                    // Copied, as looking at items may forget some.
                    var found_count: usize = 0;
                    var walk = dropped.places.space.entries(.{ .world = player.world, .x = x, .z = z }, ItemEntities.kinds);
                    while (walk.next()) |entry| {
                        self.found[found_count] = entry.id;
                        found_count += 1;
                    }
                    var next: usize = 0;
                    while (next < found_count) {
                        const count = @min(16, found_count - next);
                        var ids: [16]entities.Id = undefined;
                        @memcpy(ids[0..count], self.found[next..][0..count]);
                        next += count;
                        try self.process(self.unswept(ids[0..count]), pass, false);
                    }
                }
            }
        }
    }

    /// Those of a sweep not looked at yet in it, which it now remembers.
    fn unswept(self: *ItemReplication, ids: []entities.Id) []const entities.Id {
        var count: usize = 0;
        for (ids) |entity| {
            if (self.work.contains(entity)) continue;
            self.work.insert(entity);
            ids[count] = entity;
            count += 1;
        }
        return ids[0..count];
    }

    /// Looks at up to 16 items: who is interested, what each viewer is owed, and sends it.
    fn process(self: *ItemReplication, given: []const entities.Id, pass: Pass, turn_only: bool) !void {
        assert(given.len <= 16);
        const dropped = self.deps.dropped;
        const service = self.deps.sessions;
        const outgoing = pass.outgoing;
        const valid = pass.valid;
        const reset = pass.reset;
        const available = pass.available;
        const presentation_changed = pass.presentation_changed;
        var ids: [16]entities.Id = undefined;
        var count: usize = 0;
        for (given) |entity| {
            // Looked at moments ago, as a sweep finds some twice: once is enough.
            const in_hand = for (self.held[0..self.held_count]) |view| {
                if (view.entity == entity) break true;
            } else for (ids[0..count]) |other| {
                if (other == entity) break true;
            } else false;
            if (in_hand) continue;
            ids[count] = entity;
            count += 1;
        }
        if (count == 0) return;
        if (count == 0) return;
        // Stacks are read a batch at a time, as many as the inventories hold at once.
        const limit = @min(16, self.deps.inventories.cache.entries.len, self.deps.inventories.items.entries.len);
        var batch_start: usize = 0;
        while (batch_start < count) {
            const batch_len = @min(limit, count - batch_start);
            const batch = ids[batch_start..][0..batch_len];
            batch_start += batch_len;
            if (self.held_count + batch.len > held_max) try self.settle(pass);
            const views = self.held[self.held_count..][0..batch.len];
            try self.holdViews(batch, views);
            for (self.held_alive[self.held_count..][0..batch.len]) |*alive| alive.* = true;
            self.held_count += batch.len;
            const alive_flags = self.held_alive[self.held_count - batch.len ..][0..batch.len];
            var metadata: [16]ItemEntities.Metadata = undefined;
            var bodies: [16]?entities.State = @splat(null);
            for (batch, views[0..batch.len], metadata[0..batch.len], bodies[0..batch.len], alive_flags) |entity, *view, *value, *body, *alive| {
                // Forgotten already, as one gone may be by the time a sweep comes to it.
                const read = (try dropped.read(entity)) orelse {
                    self.retries.remove(entity);
                    view.done = true;
                    alive.* = false;
                    continue;
                };
                value.* = read.metadata;
                alive.* = value.alive;
                if (value.alive) body.* = read.body;
                // Gone, or with no player near enough to view it, and no client knowing of it.
                const near = if (body.*) |at| near: {
                    var nearby = self.deps.players.nearby(at.world, .{ .x = @floor(at.position[0] / 16) * 16, .y = 0, .z = @floor(at.position[2] / 16) * 16 }, self.deps.players.config.render_distance);
                    break :near nearby.next() != null;
                } else false;
                if (!near and !view.spawned.view().any()) {
                    self.retries.remove(entity);
                    view.pending.clear();
                    view.interested.clear();
                    view.done = true;
                    view.forget = !value.alive;
                }
            }
            var interests: [16]sparse_sets.Workspace.RowView = undefined;
            for (&interests, 0..) |*row, at| {
                row.* = self.selections.row(11 + at);
                row.clear();
            }
            var slot_indices: [16]?usize = @splat(null);
            var slots: [16]inventories.Slot = undefined;
            var contents: [16]inventories.Contents = undefined;
            var slot_count: usize = 0;
            for (views[0..batch.len], bodies[0..batch.len], 0..) |*view, maybe_body, index| {
                if (view.done) continue;
                const body = maybe_body orelse continue;
                // Only its turn: no one's interest in it changed, and neither did its stack.
                if (turn_only) {
                    interests[index].copy(view.interested.view());
                    continue;
                }
                const position: minecraft.Position = .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] };
                var candidates = self.deps.players.nearby(body.world, position, tracking_distance / 16);
                while (candidates.next()) |player_index| {
                    const player = &self.deps.players.records[player_index];
                    if (player.handle == null or player.stage != .ready or body.world != player.world) continue;
                    if (@abs(body.position[0] - player.position.x) > tracking_distance or @abs(body.position[2] - player.position.z) > tracking_distance) continue;
                    if (pass.visibility.boundsVisible(player_index, player, body.world, .{
                        .minimum = .{ @intFromFloat(@floor(body.position[0] - 1)), @intFromFloat(@floor(body.position[1] - 1)), @intFromFloat(@floor(body.position[2] - 1)) },
                        .maximum = .{ @intFromFloat(@ceil(body.position[0] + 1)), @intFromFloat(@ceil(body.position[1] + 1)), @intFromFloat(@ceil(body.position[2] + 1)) },
                    })) interests[index].insert(player_index);
                }
                // Read for anyone interested, sendable now or not: a change unread would be lost.
                if (interests[index].view().any()) {
                    slot_indices[index] = slot_count;
                    slots[slot_count] = ItemEntities.slot(body);
                    slot_count += 1;
                }
            }
            try self.deps.inventories.getMany(slots[0..slot_count], contents[0..slot_count]);
            var definition_stacks: [16]inventories.Stack = undefined;
            var definition_records: [16]usize = undefined;
            var definitions: [16]Items.Prepared = undefined;
            var definition_lengths: [16]usize = @splat(0);
            var definition_views: [16]?Items.View = @splat(null);
            var definition_count: usize = 0;
            for (views[0..batch.len], metadata[0..batch.len], slot_indices[0..batch.len], 0..) |*view, value, slot_at, index| {
                if (view.done) continue;
                const at = slot_at orelse continue;
                const held = contents[at];
                const spawned = self.selections.row(8);
                spawned.intersect(view.spawned.view(), valid.view());
                spawned.subtract(spawned.view(), reset.view());
                const missing = self.selections.row(9);
                missing.subtract(interests[index].view(), spawned.view());
                // A fire lit or put out sends the stack again with the flags.
                const burning = value.fire_ticks > 0;
                if (!presentation_changed and held.revision == view.header.inventory_revision and burning == view.header.burning and
                    !view.stacks.view().intersects(interests[index].view()) and !missing.view().any()) continue;
                const stack = held.stack orelse return error.Corrupt;
                definition_stacks[definition_count] = stack;
                definition_records[definition_count] = index;
                definition_count += 1;
            }
            try self.deps.items.acquireMany(definition_stacks[0..definition_count], definitions[0..definition_count]);
            defer for (definitions[0..definition_count]) |definition| definition.release();
            for (definitions[0..definition_count], definition_records[0..definition_count]) |definition, index| {
                definition_lengths[index] = definition.lease.read().?.len;
                definition_views[index] = definition.view;
            }
            for (batch, views[0..batch.len], metadata[0..batch.len], bodies[0..batch.len], slot_indices[0..batch.len], 0..) |entity, *view, value, body, slot_at, record_index| {
                if (view.done) continue;
                const header = view.header;
                view.spawned.intersect(view.spawned.view(), valid.view());
                view.spawned.subtract(view.spawned.view(), reset.view());
                view.dirty.intersect(view.dirty.view(), view.spawned.view());
                view.collected.intersect(view.collected.view(), view.spawned.view());
                view.stacks.intersect(view.stacks.view(), view.spawned.view());
                if (header.revision != value.revision) {
                    view.dirty.unite(view.dirty.view(), view.spawned.view());
                    header.revision = value.revision;
                }
                if (header.collection != value.collection) {
                    header.collection = value.collection;
                    view.collected.clear();
                }
                const interested = interests[record_index].view();
                view.interested.copy(interested);
                header.collecting = value.collected > 0;
                // Stacks are read when anyone is interested: unread, they are as last.
                const held: ?inventories.Contents = if (slot_at) |at| contents[at] else null;
                if (held) |read| if (read.revision != header.inventory_revision) {
                    header.inventory_revision = read.revision;
                    view.stacks.unite(view.stacks.view(), view.spawned.view());
                };
                // Every stack shows differently: each viewer is owed it again, read now or not.
                if (presentation_changed) view.stacks.unite(view.stacks.view(), view.spawned.view());
                // The flags go with the stack, so a fire lit or put out sends both again.
                const burning = value.fire_ticks > 0;
                if (burning != header.burning) {
                    header.burning = burning;
                    view.stacks.unite(view.stacks.view(), view.spawned.view());
                }
                const entity_id = self.deps.dropped.networkId(entity);
                var queued = std.EnumSet(Phase).empty;
                for (std.enums.values(Phase)) |phase| {
                    // Later phases use the actual admission result of spawn, stack, and collection updates.
                    const dependencies = switch (phase) {
                        .stack => std.EnumSet(Phase).initOne(.spawn),
                        .position => std.EnumSet(Phase).initMany(&.{ .spawn, .stack }),
                        .remove => std.EnumSet(Phase).initOne(.collect),
                        else => std.EnumSet(Phase).empty,
                    };
                    if (queued.intersectWith(dependencies).count() != 0) {
                        outgoing.flush();
                        queued = .empty;
                    }
                    const wanted = self.selections.row(6);
                    switch (phase) {
                        .spawn => wanted.subtract(interested, view.spawned.view()),
                        .stack => {
                            wanted.intersect(interested, view.spawned.view());
                            wanted.intersect(wanted.view(), view.stacks.view());
                        },
                        .position => {
                            wanted.intersect(interested, view.spawned.view());
                            wanted.intersect(wanted.view(), view.dirty.view());
                            wanted.subtract(wanted.view(), view.stacks.view());
                            if (!self.onTurn(entity)) wanted.clear();
                        },
                        .collect => {
                            wanted.clear();
                            if (value.collected > 0) wanted.subtract(view.spawned.view(), view.collected.view());
                        },
                        .remove => {
                            wanted.subtract(view.spawned.view(), interested);
                            if (value.collected > 0) wanted.intersect(wanted.view(), view.collected.view());
                        },
                    }
                    wanted.intersect(wanted.view(), available.view());
                    if (!wanted.view().any()) continue;
                    var capacity: usize = 128;
                    if (phase == .spawn or phase == .stack) {
                        assert(definition_lengths[record_index] != 0);
                        capacity = @max(128, definition_lengths[record_index] + 16 + self.deps.items.components.extra_bytes);
                    }
                    const eligible = self.selections.row(5);
                    eligible.clear();
                    var candidates = wanted.view().iterator();
                    while (candidates.next()) |index| {
                        const player = &self.deps.players.records[index];
                        const handle = player.handle orelse continue;
                        if (capacity > service.config.page_bytes) {
                            service.disconnect(handle);
                            continue;
                        }
                        if (!service.canSend(handle, capacity)) continue;
                        eligible.insert(index);
                    }
                    const personalized = (phase == .spawn or phase == .stack) and self.deps.items.components.personalized;
                    while (eligible.view().any()) {
                        const audience = self.selections.row(7);
                        audience.clear();
                        if (personalized) audience.insert(eligible.view().firstFrom(0).?) else audience.copy(eligible.view());
                        eligible.subtract(eligible.view(), audience.view());
                        if (!try outgoing.prepare(audience.view(), if (phase == .spawn) 4 else 1)) continue;
                        const recipient = self.deps.players.records[audience.view().firstFrom(0).?].uuid;
                        const stack = if (held) |read| read.stack else null;
                        const receipt = switch (phase) {
                            .spawn => try self.deps.packets.broadcastGroup(&self.broadcast, .{ .{ writeSpawnLegacy, writeSpawnPacked }, writeItemStack }, null, null, .{
                                .{Spawn{
                                    .entity_id = entity_id,
                                    .uuid = body.?.uuid,
                                    .position = .{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                    .velocity = body.?.velocity,
                                }},
                                .{ self.deps.items, entity_id, stack, recipient, definition_views[record_index], value.fire_ticks > 0 },
                            }, &.{ 128, capacity }),
                            .stack => try self.deps.packets.broadcastGroup(&self.broadcast, .{writeItemStack}, null, null, .{.{ self.deps.items, entity_id, stack, recipient, definition_views[record_index], value.fire_ticks > 0 }}, &.{capacity}),
                            .position => try self.deps.packets.broadcast(&self.broadcast, writePosition, null, null, .{
                                entity_id,
                                minecraft.Position{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                minecraft.Position{ .x = body.?.velocity[0], .y = body.?.velocity[1], .z = body.?.velocity[2] },
                                minecraft.Rotation{ .yaw = 0, .pitch = 0 },
                                value.on_ground,
                            }, capacity),
                            .collect => try self.deps.packets.broadcast(&self.broadcast, writeCollect, null, null, .{ entity_id, value.collector, value.collected }, capacity),
                            .remove => try self.deps.packets.broadcast(&self.broadcast, writeRemove, null, null, .{entity_id}, capacity),
                        };
                        if (self.tracing) {
                            // What and of which item: who takes it waits on viewers' room, which wall time decides.
                            var hasher = std.hash.Wyhash.init(self.traced);
                            hasher.update(std.mem.asBytes(&self.ticks));
                            hasher.update(std.mem.asBytes(&entity_id));
                            hasher.update(&.{@backingInt(phase)});
                            self.traced = hasher.final();
                        }
                        outgoing.append(view, phase, receipt);
                        queued.insert(phase);
                    }
                }
            }
        }
    }

    fn selectVisibility(self: *ItemReplication, visibility: *const Streaming.Visibility) !void {
        for (visibility.changed_words.values()) |word| {
            const player_index = word / visibility.grid.words;
            if (visibility.reset.contains(player_index)) continue;
            const player = self.deps.players.records[player_index];
            if (player.handle == null or player.stage != .ready) continue;
            const center = visibility.viewCenter(player_index);
            const x = center.x - visibility.radius;
            const z = center.z - visibility.radius;
            var bits = visibility.changed[word];
            while (bits != 0) {
                const cell: i32 = @intCast((word % visibility.grid.words) * 64 + @ctz(bits));
                bits &= bits - 1;
                if (cell >= visibility.grid.columns) continue;
                const side: i32 = @intCast(visibility.grid.width);
                const column: [2]i32 = .{
                    x + @mod(@mod(cell, side) - @mod(x, side), side),
                    z + @mod(@divTrunc(cell, side) - @mod(z, side), side),
                };
                self.deps.dropped.selectColumns(player.world, column, column, &self.work);
            }
        }
    }

    fn selectMovement(self: *ItemReplication, world: u32, before: [2]f64, after: [2]f64) void {
        const minimum: [2]f64 = .{ @min(before[0], after[0]) - tracking_distance, @min(before[1], after[1]) - tracking_distance };
        const maximum: [2]f64 = .{ @max(before[0], after[0]) + tracking_distance, @max(before[1], after[1]) + tracking_distance };
        const crossed_column = @floor(before[0] / 16) != @floor(after[0] / 16) or @floor(before[1] / 16) != @floor(after[1] / 16);
        if (crossed_column) {
            self.selectBounds(world, .{ before[0] - tracking_distance, before[1] - tracking_distance }, .{ before[0] + tracking_distance, before[1] + tracking_distance });
            self.selectBounds(world, .{ after[0] - tracking_distance, after[1] - tracking_distance }, .{ after[0] + tracking_distance, after[1] + tracking_distance });
            return;
        }
        // Include both endpoints because the exact tracking boundary is inclusive.
        if (before[0] != after[0]) {
            self.selectBounds(world, minimum, .{ @max(before[0], after[0]) - tracking_distance, maximum[1] });
            self.selectBounds(world, .{ @min(before[0], after[0]) + tracking_distance, minimum[1] }, maximum);
        }
        if (before[1] != after[1]) {
            self.selectBounds(world, minimum, .{ maximum[0], @max(before[1], after[1]) - tracking_distance });
            self.selectBounds(world, .{ minimum[0], @min(before[1], after[1]) + tracking_distance }, maximum);
        }
    }

    fn selectBounds(self: *ItemReplication, world: u32, minimum: [2]f64, maximum: [2]f64) void {
        self.selection.append(world, minimum, maximum);
    }

    fn writeSpawnLegacy(packet: wire_1_21_5.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, value: Spawn) ![]u8 {
        const entity = try packet.entityId(value.entity_id);
        const uuid = try entity.objectUUID(value.uuid);
        const kind = try uuid.type(try registry.entityId(game_data.entities.item));
        const x = try kind.x(value.position.x);
        const y = try x.y(value.position.y);
        const z = try y.z(value.position.z);

        const pitch = try z.pitch(0);
        const yaw = try pitch.yaw(0);
        const head = try yaw.headPitch(0);
        const data = try head.objectData(0);
        var velocity = try data.velocity();
        return (try velocity.advance(try packets.nested(.{writeVelocity}).write(try velocity.begin(), value.velocity))).finish();
    }

    fn writeVelocity(packet: wire_1_21_5.vec3i16.Writer, motion: [3]f64) !wire_1_21_5.vec3i16.Writer.Done {
        const x = try packet.x(encodedVelocity(motion[0]));
        const y = try x.y(encodedVelocity(motion[1]));
        return y.z(encodedVelocity(motion[2]));
    }

    fn writeSpawnPacked(packet: wire_1_21_9.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, value: Spawn) ![]u8 {
        const entity = try packet.entityId(value.entity_id);
        const uuid = try entity.objectUUID(value.uuid);
        const kind = try uuid.type(try registry.entityId(game_data.entities.item));
        const x = try kind.x(value.position.x);
        const y = try x.y(value.position.y);
        const z = try y.z(value.position.z);
        const velocity = try z.velocity(.{
            .x = @as(f64, @floatFromInt(encodedVelocity(value.velocity[0]))) / 8000,
            .y = @as(f64, @floatFromInt(encodedVelocity(value.velocity[1]))) / 8000,
            .z = @as(f64, @floatFromInt(encodedVelocity(value.velocity[2]))) / 8000,
        });
        const pitch = try velocity.pitch(0);
        const yaw = try pitch.yaw(0);
        const head = try yaw.headPitch(0);
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

    fn writeCollect(packet: wire_1_21_5.play.toClient.packet_collect.Writer, item: i32, player: i32, count: i32) ![]u8 {
        const collected = try packet.collectedEntityId(item);
        const collector = try collected.collectorEntityId(player);
        return (try collector.pickupItemCount(count)).finish();
    }

    /// The item's stack, and its entity flags, which show it burning.
    pub fn writeItemStack(packet: wire_1_21_5.play.toClient.packet_entity_metadata.Writer, registry: packets.Registry, store: *Items, entity: i32, stack: ?inventories.Stack, recipient: u128, view: ?Items.View, burning: bool) ![]u8 {
        var metadata = try (try packet.entityId(entity)).metadata();
        const done = try packets.nested(.{writeStackMetadata}).write(try metadata.begin(), StackMetadata{ .slot = .{ .registry = registry, .items = store, .stack = stack, .recipient = recipient, .view = view }, .burning = burning });
        return (try metadata.advance(done)).finish();
    }

    const StackMetadata = struct { slot: item_packets.SlotArguments, burning: bool };

    fn writeStackMetadata(packet: wire_1_21_5.entityMetadata.Writer, args: StackMetadata) !wire_1_21_5.entityMetadata.Writer.Done {
        var entries = try packet.value(2);
        try entries.advance(try packets.nested(.{writeFlags}).write((try entries.next()).?, args.burning));
        try entries.advance(try packets.nested(.{writeStackEntry}).write((try entries.next()).?, args.slot));
        return entries.finish();
    }

    const FlagsEntry = wire_1_21_5.entityMetadataEntry.cases.value.byte.Writer;

    /// Entity.DATA_SHARED_FLAGS_ID, whose lowest bit is on fire.
    fn writeFlags(packet: FlagsEntry, burning: bool) !FlagsEntry.Done {
        return (try (try packet.key(0)).type()).value(if (burning) 1 else 0);
    }

    const StackEntry = wire_1_21_5.entityMetadataEntry.cases.value.item_stack.Writer;

    fn writeStackEntry(packet: StackEntry, args: item_packets.SlotArguments) !StackEntry.Done {
        const typed = try (try packet.key(8)).type();
        var item = try typed.value();
        return item.advance(try item_packets.writeSlot(try item.begin(), args));
    }
};

fn encodedVelocity(value: f64) i16 {
    assert(std.math.isFinite(value));
    return @intFromFloat(std.math.clamp(value, -3.9, 3.9) * 8000);
}
