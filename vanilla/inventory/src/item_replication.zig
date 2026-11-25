const sparse_sets = @import("lightning_rod").system.sparse_sets;
const bit_sets = @import("lightning_rod").system.bit_sets;
const std = @import("std");
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
const Tracking = @import("replication").tracking.Tracking;
const shared_delivery = @import("replication").delivery;

const assert = std.debug.assert;

pub const ItemReplication = struct {
    pub const id = "minecraft:item_replication";

    pub const Configuration = struct {
        /// Ticks between an item's position updates. Vanilla tracks dropped items every 20 ticks, and
        /// clients move them by their velocity in between.
        position_interval: u8 = 20,
        /// Items clients are shown at once.
        views: usize = 65536,
        /// Items looked at in one tick before replication looks over all it has views of instead.
        work_ids: usize = 65536,
        /// Keep a hash of every packet queued, for runs to be compared by.
        trace_sends: bool = false,
    };

    pub const Dependencies = struct {
        dropped: *ItemEntities,
        item_tick: *ItemTick,
        players: *Players,
        tracking: *Tracking,
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
    const row_count = 5;
    const record_align = @alignOf(Header);
    comptime {
        assert(@sizeOf(Header) % @alignOf(usize) == 0);
    }

    /// An item's view, where it lies, edited in place while in hand.
    const View = struct {
        entity: entities.Id,
        slot: u32,
        header: *Header,
        /// Who has it spawned, as tracking keeps it.
        known: bit_sets.Set,
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
            if (self.known.any()) return true;
            inline for (.{ "dirty", "collected", "interested", "stacks", "pending" }) |name| {
                if (@field(self, name).view().any()) return true;
            }
            return false;
        }
    };

    const Phase = enum { spawn, stack, position, collect, remove };

    /// One packet of an item's, as the batch keeps it until it goes: whom it reached then says
    /// what its viewers have.
    const ItemSend = struct { view: *View, phase: Phase };
    const Batch = shared_delivery.Batch(ItemSend);

    /// What a packet's viewers have once it went to `delivered`.
    fn settleSend(self: *ItemReplication, sent: ItemSend, delivered: bit_sets.Set, _: usize) !void {
        const view = sent.view;
        switch (sent.phase) {
            .spawn => {
                self.deps.tracking.confirm(view.slot, delivered, self.deps.tracking.nobody());
                view.dirty.unite(view.dirty.view(), delivered);
                view.stacks.subtract(view.stacks.view(), delivered);
                view.collected.unite(view.collected.view(), delivered);
            },
            .stack => view.stacks.subtract(view.stacks.view(), delivered),
            .position => view.dirty.subtract(view.dirty.view(), delivered),
            .collect => view.collected.unite(view.collected.view(), delivered),
            .remove => {
                self.deps.tracking.confirm(view.slot, self.deps.tracking.nobody(), delivered);
                view.dirty.subtract(view.dirty.view(), delivered);
                view.collected.subtract(view.collected.view(), delivered);
                view.stacks.subtract(view.stacks.view(), delivered);
            },
        }
    }

    /// What one tick looks at items with: who may be sent to, who was replaced, what changed.
    const Pass = struct {
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
    listener: inventories.Inventories.Listener,
    /// Items' packets for one audience at a time, as every kind batches its broadcasts.
    batch: Batch,
    tracker: Tracking.TrackerId,
    /// Room to tell players of items that left memory.
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,
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
        const players = deps.players.records.len;
        const selections = try sparse_sets.Workspace.init(allocator, 28, players);
        const row_words = std.math.divCeil(usize, players, @bitSizeOf(usize)) catch unreachable;
        const record_bytes = @sizeOf(Header) + row_count * row_words * @sizeOf(usize);
        self.* = .{
            .pending = selections.row(0),
            .selections = selections,
            .views = try .init(allocator, &deps.dropped.deps.entities.pool, record_bytes, config.views),
            .viewed = try allocator.alloc(entities.Id, config.views),
            .found = try allocator.alloc(entities.Id, deps.dropped.items.bound()),
            .record_bytes = record_bytes,
            .row_words = row_words,
            .batch = try Batch.init(allocator, deps.players, deps.packets, deps.sessions, row_words),
            .deps = deps,
            .work = try entities.IdSet.init(allocator, &deps.dropped.deps.entities.pool, config.work_ids),
            .turns = try entities.IdSet.init(allocator, &deps.dropped.deps.entities.pool, config.work_ids),
            .retries = try entities.IdSet.init(allocator, &deps.dropped.deps.entities.pool, config.work_ids),
            .targets = try allocator.alloc(sessions.Service.Target, players),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, players),
            .tracker = undefined,
            .listener = .{ .context = self, .function = slotChanged },
            .sweeps = try deps.dropped.deps.metrics.counter(.{ .name = "items.replication.sweeps", .description = "Ticks that looked over every item, as more changed than could be noted" }),
            .position_interval = config.position_interval,
            .tracing = config.trace_sends,
        };
        deps.inventories.listen(&self.listener);
        deps.dropped.leaving = .{ .context = self, .function = itemLeaving };
        self.tracker = try deps.tracking.register(.{ .kinds = ItemEntities.kinds });
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
        return .{ .spawned = view.known.count(), .pending = view.pending.view().count(), .stacks = view.stacks.view().count() };
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
        const capacity = self.deps.players.records.len;
        const slot = self.deps.entities.directory.slotOf(entity).?;
        var rows: [row_count]bit_sets.Row = undefined;
        for (&rows, 0..) |*row, at| row.* = .{ .words = words[at * self.row_words ..][0..self.row_words], .capacity = capacity };
        return .{
            .entity = entity,
            .slot = slot,
            .header = @ptrCast(bytes[0..@sizeOf(Header)]),
            .known = self.deps.tracking.known(slot),
            .dirty = rows[0],
            .collected = rows[1],
            .interested = rows[2],
            .stacks = rows[3],
            .pending = rows[4],
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
        for (dropped.asleep_ids.values()) |entity| {
            if (self.onTurn(entity)) self.turns.insert(entity);
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
        self.ticks += 1;
        const dropped = self.deps.dropped;
        // Items whose audience changed: those that left memory are told gone here, the rest
        // looked at below.
        var changes = self.deps.tracking.changesOf(self.tracker);
        while (changes.next()) |change| {
            const entry = self.deps.entities.directory.entry(change.slot);
            if (entry.retired) try self.removeLeft(change) else self.work.insert(entry.id);
        }
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
        const presentation_changed = self.presentation != self.deps.items.components.revision;
        self.presentation = self.deps.items.components.revision;
        const available = self.selections.row(3);
        available.clear();
        for (self.deps.players.activeSlots()) |index| {
            const handle = self.deps.players.records[index].handle orelse continue;
            if (service.outputCredit(handle) != 0) available.insert(index);
        }
        self.noteMoved();
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
        const outgoing = &self.batch;
        defer outgoing.abandon();
        const pass: Pass = .{ .available = available, .presentation_changed = presentation_changed, .outgoing = outgoing };
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
        try pass.outgoing.flush(self, settleSend);
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
            if (!alive and !view.known.any()) {
                self.retries.remove(view.entity);
                view.forget = true;
                forgotten[forgotten_count] = view.entity;
                forgotten_count += 1;
                continue;
            }
            const interested = view.interested.view();
            view.pending.difference(interested, view.known);
            const changed = self.selections.row(8);
            changed.unite(view.stacks.view(), view.dirty.view());
            changed.intersect(changed.view(), interested);
            view.pending.unite(view.pending.view(), changed.view());
            if (view.header.collecting) {
                changed.subtract(view.known, view.collected.view());
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

    /// Looks at every item with a view, and every item whose audience changed,
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
        // And every item whose audience changed, as the work could not hold them all.
        var found_count: usize = 0;
        var changes = self.deps.tracking.changesOf(self.tracker);
        while (changes.next()) |change| {
            const entry = self.deps.entities.directory.entry(change.slot);
            if (entry.retired) continue;
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
    /// Items looked at: their audience as tracking has it, their stacks read for anyone interested,
    /// and what each viewer is owed sent. `turn_only` when nothing but their turn brought them,
    /// so a stack read is owed only where tracking changed who sees one.
    fn process(self: *ItemReplication, given: []const entities.Id, pass: Pass, turn_only: bool) !void {
        assert(given.len <= 16);
        const dropped = self.deps.dropped;
        const service = self.deps.sessions;
        const outgoing = pass.outgoing;
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
                // No client has it, nor is any to have it.
                if (!view.known.any() and self.deps.tracking.changed(view.slot) == null) {
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
                // Who is to have it: who has it, as tracking changes that.
                interests[index].copy(view.known);
                const changed = self.deps.tracking.changed(view.slot);
                if (changed) |change| {
                    interests[index].subtract(interests[index].view(), change.remove);
                    interests[index].unite(interests[index].view(), change.spawn);
                }
                if (maybe_body == null) continue;
                // Only its turn: no one's interest in it changed, and neither did its stack.
                if (turn_only and changed == null) continue;
                const body = maybe_body.?;
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
                const missing = self.selections.row(9);
                missing.subtract(interests[index].view(), view.known);
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
                view.dirty.intersect(view.dirty.view(), view.known);
                view.collected.intersect(view.collected.view(), view.known);
                view.stacks.intersect(view.stacks.view(), view.known);
                if (header.revision != value.revision) {
                    view.dirty.unite(view.dirty.view(), view.known);
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
                    view.stacks.unite(view.stacks.view(), view.known);
                };
                // Every stack shows differently: each viewer is owed it again, read now or not.
                if (presentation_changed) view.stacks.unite(view.stacks.view(), view.known);
                // The flags go with the stack, so a fire lit or put out sends both again.
                const burning = value.fire_ticks > 0;
                if (burning != header.burning) {
                    header.burning = burning;
                    view.stacks.unite(view.stacks.view(), view.known);
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
                        try outgoing.flush(self, settleSend);
                        queued = .empty;
                    }
                    const wanted = self.selections.row(6);
                    switch (phase) {
                        .spawn => wanted.subtract(interested, view.known),
                        .stack => {
                            wanted.intersect(interested, view.known);
                            wanted.intersect(wanted.view(), view.stacks.view());
                        },
                        .position => {
                            wanted.intersect(interested, view.known);
                            wanted.intersect(wanted.view(), view.dirty.view());
                            wanted.subtract(wanted.view(), view.stacks.view());
                            if (!self.onTurn(entity)) wanted.clear();
                        },
                        .collect => {
                            wanted.clear();
                            if (value.collected > 0) wanted.subtract(view.known, view.collected.view());
                        },
                        .remove => {
                            wanted.subtract(view.known, interested);
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
                        if (try outgoing.prepare(audience.view(), if (phase == .spawn) 4 else 1, self, settleSend) != .ready) continue;
                        const recipient = self.deps.players.records[audience.view().firstFrom(0).?].uuid;
                        const stack = if (held) |read| read.stack else null;
                        const sending: ItemSend = .{ .view = view, .phase = phase };
                        const sent = switch (phase) {
                            .spawn => try outgoing.sendGroup(sending, .{ .{ writeSpawnLegacy, writeSpawnPacked }, writeItemStack }, .{
                                .{Spawn{
                                    .entity_id = entity_id,
                                    .uuid = body.?.uuid,
                                    .position = .{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                    .velocity = body.?.velocity,
                                }},
                                .{ self.deps.items, entity_id, stack, recipient, definition_views[record_index], value.fire_ticks > 0 },
                            }, &.{ 128, capacity }),
                            .stack => try outgoing.sendGroup(sending, .{writeItemStack}, .{.{ self.deps.items, entity_id, stack, recipient, definition_views[record_index], value.fire_ticks > 0 }}, &.{capacity}),
                            .position => try outgoing.send(sending, writePosition, .{
                                entity_id,
                                minecraft.Position{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                minecraft.Position{ .x = body.?.velocity[0], .y = body.?.velocity[1], .z = body.?.velocity[2] },
                                minecraft.Rotation{ .yaw = 0, .pitch = 0 },
                                value.on_ground,
                            }, capacity),
                            .collect => try outgoing.send(sending, writeCollect, .{ entity_id, value.collector, value.collected }, capacity),
                            .remove => try outgoing.send(sending, writeRemove, .{entity_id}, capacity),
                        };
                        if (self.tracing) {
                            // What and of which item: who takes it waits on viewers' room, which wall time decides.
                            var hasher = std.hash.Wyhash.init(self.traced);
                            hasher.update(std.mem.asBytes(&self.ticks));
                            hasher.update(std.mem.asBytes(&entity_id));
                            hasher.update(&.{@backingInt(phase)});
                            self.traced = hasher.final();
                        }
                        if (!sent) continue;
                        queued.insert(phase);
                    }
                }
            }
        }
    }

    /// An item that left memory, which those who had it are told is gone.
    fn removeLeft(self: *ItemReplication, change: Tracking.Change) !void {
        var count: usize = 0;
        var recipients = change.remove.iterator();
        while (recipients.next()) |player| {
            const record = self.deps.players.records[player];
            const handle = record.handle orelse continue;
            self.targets[count] = .{ .handle = handle, .protocol = record.protocol };
            count += 1;
        }
        const removed = self.selections.row(10);
        removed.clear();
        if (count > 0) {
            const entity_id = entities.Entities.networkOfSlot(change.slot);
            try self.deps.packets.fanout(writeRemove, self.targets[0..count], .{entity_id}, 32, self.deliveries[0..count]);
            if (self.tracing) {
                var hasher = std.hash.Wyhash.init(self.traced);
                hasher.update(std.mem.asBytes(&self.ticks));
                hasher.update(std.mem.asBytes(&entity_id));
                hasher.update(&.{@backingInt(Phase.remove)});
                self.traced = hasher.final();
            }
            for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| switch (delivery) {
                .queued, .closed => removed.insert(target.handle.index),
                .unsupported => self.deps.sessions.disconnect(target.handle),
                .backpressured => {},
            };
        }
        self.deps.tracking.confirm(change.slot, self.deps.tracking.nobody(), removed.view());
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
