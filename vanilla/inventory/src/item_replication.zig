//! What clients know of dropped items, through the shared entity sync: tracking says who is to
//! have each item, and the sync sends its spawns and removals, corrects what its clients step of
//! it where they would look apart from it, sends its stack and flags as they change, and its
//! pickups before it goes. Stacks are read in batches,
//! only for the items whose stack something is to be sent of.

const std = @import("std");
const Items = @import("vanilla_items").items.Items;
const inventories = @import("inventories");
const entities = @import("entities");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const game_data = @import("game_data");
const item_packets = @import("vanilla_items").item_packets;
const packets = @import("minecraft_packets");
const wire = @import("wire_1_21_5");
const replication = @import("replication");
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const ItemTick = @import("item_tick.zig").ItemTick;
const Players = @import("players").players.Players;
const Tracking = replication.tracking.Tracking;
const IndexSet = lightning_rod.system.IndexSet;

const entity_sync = replication.entity_sync;

/// What an item synchronizes: its flags, of which only burning changes, and its stack, which is
/// resent when it changes or every stack shows differently.
const StackData = struct {
    burning: bool = false,
    /// The stack's revision, one more than the inventories', and how stacks show.
    stack: [2]u64 = .{ 0, 0 },
};

const Sync = entity_sync.EntitySync(StackData, ItemReplication);

pub const ItemReplication = struct {
    pub const id = "minecraft:item_replication";

    pub const Configuration = struct {
        /// Pickups owed to clients at once; past it the oldest is let go.
        pickup_events: usize = 1024,
        /// Keep a hash of every packet queued, for runs to be compared by.
        trace_sends: bool = false,
    };

    pub const Dependencies = struct {
        dropped: *ItemEntities,
        players: *Players,
        tracking: *Tracking,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
        /// What steps the items, and beside each its clients' models of it. Without it, as where
        /// replication alone is measured, nothing steps them, so nothing but what tracking, data
        /// and the backstop send goes.
        item_tick: ?*ItemTick = null,
    };

    /// A stack read this tick, for the item in a slot, while its definition is held.
    const Read = struct { slot: u32, stack: ?inventories.Stack, revision: u64, view: ?Items.View, length: usize };
    const batch_max = 16;

    deps: Dependencies,
    tracker: Tracking.TrackerId,
    /// The item being sent, as its body and identity are read, and the one whose stack is written.
    reading: ItemEntities.View = undefined,
    writing: u32 = 0,
    sync: Sync,
    /// Items whose stack changed since it was sent.
    stacks_changed: IndexSet,
    /// By slot, the pickup count an item was last seen at, so each pickup is told once.
    collections: entities.Array(u64),
    presentation: u64 = 0,
    /// How every stack shows changed this tick: each item visited sends its stack again.
    restyled: bool = false,
    listener: inventories.Inventories.Listener,
    /// The batch of items in hand: their stacks, read for those that send one.
    reads: [batch_max]Read = undefined,
    read_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ItemReplication {
        const self = try allocator.create(ItemReplication);
        self.* = .{
            .deps = deps,
            .tracker = try deps.tracking.register(.{ .kinds = ItemEntities.kinds }),
            .sync = undefined,
            .stacks_changed = try .init(allocator, deps.entities.directory.capacity()),
            .collections = try .init(allocator, &deps.entities.pool),
            .listener = .{ .context = self, .function = slotChanged },
        };
        self.sync = try .init(allocator, .{ .events = config.pickup_events, .trace_sends = config.trace_sends, .visits = true }, .{ .players = deps.players, .sessions = deps.sessions, .packets = deps.packets, .tracking = deps.tracking, .tracker = self.tracker, .pool = &deps.entities.pool, .slots = deps.entities.directory.capacity() }, .{
            .kind = self,
            .write_data = writeData,
            .body = body,
            .identity = identity,
            .before = byId,
            // A client steps an item itself: otherwise than the server where it lands, by its
            // release's drag and stops, and at rest on its own tick count.
            .client = .{ .simulates = .{ .models = .{ .phases = 4, .rule_sets = ItemPhysics.rule_sets, .rules = ItemPhysics.rulesOf } } },
            .data_bytes = dataBytes,
            .personalized = personalized,
        });
        if (deps.item_tick) |item_tick| item_tick.client_models = &self.sync.models.?;
        deps.inventories.listen(&self.listener);
        return self;
    }

    /// A running hash of every packet asked to be sent and whom to, when tests trace it.
    pub fn traced(self: *const ItemReplication) u64 {
        return self.sync.traced;
    }

    /// How many clients an item is spawned for, and how many are behind on it.
    pub const Known = struct { spawned: usize = 0, pending: usize = 0, stacks: usize = 0 };

    pub fn known(self: *ItemReplication, entity: entities.Id) !Known {
        const slot = self.deps.entities.directory.slotOf(entity) orelse return .{};
        return .{ .spawned = self.deps.tracking.known(slot).count(), .pending = self.deps.tracking.stale(slot).count() };
    }

    /// Whether a viewer is behind on an item, owed it whole, for tests.
    pub fn dirtyFor(self: *ItemReplication, entity: entities.Id, viewer: usize) !bool {
        const slot = self.deps.entities.directory.slotOf(entity) orelse return false;
        return self.deps.tracking.stale(slot).contains(viewer);
    }

    /// An item's stack changed: its viewers are owed it.
    fn slotChanged(context: *anyopaque, slot: inventories.Slot) void {
        const self: *ItemReplication = @ptrCast(@alignCast(context));
        const entity = ItemEntities.entityOf(slot.owner) orelse return;
        const at = self.deps.dropped.items.slotOf(entity) orelse return;
        self.stacks_changed.insert(at);
        self.sync.mark(at);
    }

    /// The stack read this tick for the item in a slot.
    fn readOf(self: *const ItemReplication, slot: u32) ?Read {
        for (self.reads[0..self.read_count]) |read| if (read.slot == slot) return read;
        return null;
    }

    pub fn tick(self: *ItemReplication) !void {
        const dropped = self.deps.dropped;
        errdefer self.sync.abandon();
        // Pickups since last tick, held for those who have the item, before it goes for them.
        for (dropped.changes.values()) |at| {
            const slot: u32 = @intCast(at);
            self.sync.mark(slot);
            const item = dropped.items.ptr(slot);
            try self.collections.ensureFilled(@as(usize, slot) + 1, 0);
            const seen = self.collections.at(slot);
            if (item.metadata.collection != seen.*) {
                seen.* = item.metadata.collection;
                if (item.metadata.collected > 0) try self.sync.hold(slot, .{ .collect = .{ .collector = item.metadata.collector, .count = item.metadata.collected } });
            }
        }
        dropped.changes.clear();
        // Items that moved, a sleeper woken among them, are visited on their interval again.
        for (dropped.moved.values()) |slot| self.sync.stir(@intCast(slot));
        dropped.moved.clear();
        try self.sync.begin();
        // Every stack shows differently: each viewer is owed each again.
        self.restyled = self.presentation != self.deps.items.components.revision;
        if (self.restyled) {
            self.presentation = self.deps.items.components.revision;
            self.sync.markAll();
        }
        // Items gone from memory, and gone items no client has any more, let go.
        var changes = self.deps.tracking.changesOf(self.tracker);
        while (changes.next()) |change| {
            if (self.deps.entities.directory.entry(change.slot).retired) try self.sync.gone(change.slot);
        }
        const visited = self.sync.collect();
        // As many as the inventories hold at once.
        const limit = @min(batch_max, self.deps.inventories.cache.entries.len, self.deps.inventories.items.entries.len);
        var at: usize = 0;
        while (at < visited.len) {
            const count = @min(limit, visited.len - at);
            try self.visit(visited[at..][0..count]);
            at += count;
        }
        try self.sync.finish();
    }

    /// Items in id order, the order they were walked by.
    fn byId(self: *ItemReplication, a: u32, b: u32) bool {
        const directory = &self.deps.entities.directory;
        return directory.entry(a).id < directory.entry(b).id;
    }

    /// Up to a batch of items: the stacks of those that send one read at once, then each sent.
    fn visit(self: *ItemReplication, slots: []const u32) !void {
        const dropped = self.deps.dropped;
        const tracking = self.deps.tracking;
        var stack_slots: [batch_max]inventories.Slot = undefined;
        var contents: [batch_max]inventories.Contents = undefined;
        var reading: [batch_max]u32 = undefined;
        var count: usize = 0;
        var views: [batch_max]?ItemEntities.View = @splat(null);
        for (slots, 0..) |slot, index| {
            const entry = self.deps.entities.directory.entry(slot);
            if (entry.id == 0 or entry.retired or dropped.items.slotOf(entry.id) != slot) continue;
            const view = try dropped.readAt(entry.id, slot);
            views[index] = view;
            if (!view.metadata.alive) continue;
            // A stack is read only for an item that may send one: changed, newly seen or owed.
            if (!self.restyled and !self.stacks_changed.contains(slot) and tracking.changed(slot) == null and !tracking.stale(slot).any()) continue;
            stack_slots[count] = ItemEntities.slot(view.body);
            reading[count] = slot;
            count += 1;
        }
        try self.deps.inventories.getMany(stack_slots[0..count], contents[0..count]);
        var definition_stacks: [batch_max]inventories.Stack = undefined;
        var definition_of: [batch_max]?usize = @splat(null);
        var definitions: [batch_max]Items.Prepared = undefined;
        var definition_count: usize = 0;
        for (contents[0..count], 0..) |held, index| {
            const stack = held.stack orelse continue;
            definition_stacks[definition_count] = stack;
            definition_of[index] = definition_count;
            definition_count += 1;
        }
        try self.deps.items.acquireMany(definition_stacks[0..definition_count], definitions[0..definition_count]);
        defer for (definitions[0..definition_count]) |definition| definition.release();
        defer self.read_count = 0;
        for (reading[0..count], contents[0..count], definition_of[0..count]) |slot, held, maybe| {
            const definition = if (maybe) |index| definitions[index] else null;
            self.reads[self.read_count] = .{ .slot = slot, .stack = held.stack, .revision = held.revision, .view = if (definition) |prepared| prepared.view else null, .length = if (definition) |prepared| prepared.lease.read().?.len else 0 };
            self.read_count += 1;
        }
        for (slots, views[0..slots.len]) |slot, maybe_view| {
            const view = maybe_view orelse continue;
            if (!view.metadata.alive) {
                // Taken or gone: only its removal is left, then it is let go once no one has it.
                try self.sync.gone(slot);
                if (!tracking.known(slot).any()) {
                    try self.sync.forget(slot);
                    try self.deps.dropped.forget(self.deps.entities.directory.entry(slot).id);
                }
                continue;
            }
            // Its flags as they are, and its stack as read, or as last sent when unread.
            const data: StackData = .{
                .burning = view.metadata.fire_ticks > 0,
                .stack = if (self.readOf(slot)) |found| .{ found.revision +% 1, self.presentation } else self.sync.sentData(slot).stack,
            };
            self.stacks_changed.remove(slot);
            self.reading = view;
            try self.sync.update(slot, .{
                .id = self.deps.entities.directory.entry(slot).id,
                .data = data,
                .changed = tracking.changed(slot) != null,
                // A sleeper moves only when it wakes, which stirs it.
                .resting = dropped.asleep_ids.contains(self.deps.entities.directory.entry(slot).id),
            });
        }
    }

    fn identity(self: *ItemReplication, _: u32) Sync.Identity {
        return .{ .uuid = self.reading.body.uuid, .entity_type = game_data.entities.item };
    }

    fn body(self: *ItemReplication, _: u32) Sync.Body {
        return .{
            .position = self.reading.body.position,
            .velocity = self.reading.body.velocity,
            .yaw = 0,
            .pitch = 0,
            .on_ground = self.reading.metadata.on_ground,
        };
    }

    fn writeData(self: *ItemReplication, entries: *entity_sync.Entries, data: StackData, changes: Sync.DataChanges) !void {
        if (changes.contains(.burning)) try entries.putByte(0, if (data.burning) 1 else 0);
        if (changes.contains(.stack)) {
            self.writing = entries.slot;
            try entries.putItemStack(8, .{ .context = self, .write = writeStack });
        }
    }

    /// The stack read this tick for the item being written.
    fn writeStack(context: *anyopaque, destination: wire.Slot.Destination, registry: packets.Registry, recipient: ?u128) anyerror!wire.Slot.Completion {
        const self: *ItemReplication = @ptrCast(@alignCast(context));
        const read = self.readOf(self.writing) orelse return error.Corrupt;
        return item_packets.writeSlot(destination, .{ .registry = registry, .items = self.deps.items, .stack = read.stack, .recipient = recipient orelse 0, .view = read.view });
    }

    /// Room for an item's data: its stack's definition and what components add.
    fn dataBytes(self: *ItemReplication, slot: u32) usize {
        const read = self.readOf(slot) orelse return 128;
        return @max(128, read.length + 16 + self.deps.items.components.extra_bytes);
    }

    /// Components written for each player show each their own stack.
    fn personalized(self: *const ItemReplication) bool {
        return self.deps.items.components.personalized;
    }
};
