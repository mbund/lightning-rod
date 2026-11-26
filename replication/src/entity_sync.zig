//! Vanilla's ServerEntity, once, for every kind: what clients that track an entity were last
//! sent of it, and every tick what changed since. A kind says what its entities synchronize, as
//! its Data and how each entry is written, and what one is now. This sends its spawns and
//! removals as tracking asks, its movement, rotation, head and data as ServerEntity.sendChanges
//! does, the whole of it to whoever missed a delta, and what befell it before it goes.

const std = @import("std");
const entities = @import("entities");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const wire = @import("wire_1_21_5");
const packed_wire = @import("wire_1_21_9");
const Players = @import("players").players.Players;
const Tracking = @import("tracking.zig").Tracking;
const delivery_module = @import("delivery.zig");

const Delivery = delivery_module.Delivery;
const Visit = @import("visit.zig").Visit;

const none = std.math.maxInt(u32);
/// Turns of the wheel kinds that visit are due on: more than the longest update interval.
const wheel_ticks = 64;
const bit_sets = lightning_rod.system.bit_sets;
const assert = std.debug.assert;

/// Which of a kind's Data entries differ between two of its values: a set of its fields.
pub fn Changes(comptime Data: type) type {
    return struct {
        const Self = @This();
        pub const Field = std.meta.FieldEnum(Data);
        set: std.EnumSet(Field) = .empty,

        pub fn between(before: Data, after: Data) Self {
            var result: Self = .{};
            inline for (comptime std.enums.values(Field)) |field| {
                if (!std.meta.eql(@field(before, @tagName(field)), @field(after, @tagName(field)))) result.set.insert(field);
            }
            return result;
        }

        /// What differs from a fresh entity's data: what pairing sends.
        pub fn fromDefaults(data: Data) Self {
            return between(.{}, data);
        }

        pub fn contains(self: Self, field: Field) bool {
            return self.set.contains(field);
        }

        pub fn any(self: Self) bool {
            return self.set.count() != 0;
        }

        pub fn count(self: Self) usize {
            return self.set.count();
        }
    };
}

/// An entity data packet's list of entries, as the protocol writes it.
const MetadataList = @typeInfo(@typeInfo(@TypeOf(wire.entityMetadata.Writer.value)).@"fn".return_type.?).error_union.payload;

/// An item stack written into an entry: the kind's own writer and what it reads, as a stack's
/// encoding is the items' affair.
pub const StackWriter = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, destination: wire.Slot.Destination, registry: packets.Registry, recipient: ?u128) anyerror!wire.Slot.Completion,
};

/// The entries of one entity data packet as a kind writes them, in their keys' order, each with
/// the method of its serializer. `protocol` is the layout written, for keys a release moved;
/// `slot` the entity's; and `recipient` the player it is written for, when the kind writes its
/// data for each.
pub const Entries = struct {
    list: *MetadataList,
    protocol: i32,
    slot: u32,
    recipient: ?u128,
    registry: packets.Registry,

    pub fn putByte(self: *Entries, key: u8, value: i8) !void {
        try self.put("byte", i8, key, value);
    }

    pub fn putInt(self: *Entries, key: u8, value: i32) !void {
        try self.put("int", i32, key, value);
    }

    pub fn putFloat(self: *Entries, key: u8, value: f32) !void {
        try self.put("float", f32, key, value);
    }

    pub fn putBoolean(self: *Entries, key: u8, value: bool) !void {
        try self.put("boolean", bool, key, value);
    }

    /// Entity.DATA_POSE, as the pose's index.
    pub fn putPose(self: *Entries, key: u8, value: i32) !void {
        try self.put("pose", i32, key, value);
    }

    /// A cow's variant, as its registry index.
    pub fn putCowVariant(self: *Entries, key: u8, value: i32) !void {
        try self.put("cow_variant", i32, key, value);
    }

    pub fn putItemStack(self: *Entries, key: u8, stack: StackWriter) !void {
        const Writer = wire.entityMetadataEntry.cases.value.item_stack.Writer;
        const write = struct {
            fn write(packet: Writer, entry: StackEntry) !Writer.Done {
                var value = try (try (try packet.key(entry.key)).type()).value();
                return value.advance(try entry.stack.write(entry.stack.context, try value.begin(), entry.registry, entry.recipient));
            }
        }.write;
        try self.list.advance(try packets.nested(.{write}).write((try self.list.next()).?, StackEntry{ .key = key, .stack = stack, .registry = self.registry, .recipient = self.recipient }));
    }

    const StackEntry = struct { key: u8, stack: StackWriter, registry: packets.Registry, recipient: ?u128 };

    fn put(self: *Entries, comptime serializer: []const u8, comptime Value: type, key: u8, value: Value) !void {
        const Writer = @field(wire.entityMetadataEntry.cases.value, serializer).Writer;
        const write = struct {
            fn write(packet: Writer, entry: Entry(Value)) !Writer.Done {
                return (try (try packet.key(entry.key)).type()).value(entry.value);
            }
        }.write;
        try self.list.advance(try packets.nested(.{write}).write((try self.list.next()).?, Entry(Value){ .key = key, .value = value }));
    }
};

fn Entry(comptime Value: type) type {
    return struct { key: u8, value: Value };
}

/// What befell an entity, sent to whoever has it as it is in memory, before anything after.
pub const Event = union(enum) {
    /// ClientboundEntityEventPacket.
    status: u8,
    /// ClientboundAnimatePacket.
    animation: u8,
    /// ClientboundDamageEventPacket: the cause and direct cause the same, with no position.
    damage: struct { type_id: i32, cause: i32 },
    /// ClientboundTakeItemEntityPacket: a player took it, or `count` of its stack.
    collect: struct { collector: i32, count: i32 },
};

/// A kind's ServerEntity. `Data` is what the kind synchronizes, with a fresh entity's values as
/// its defaults, and `Kind` the kind itself, which its `Spec` says the rest of.
pub fn EntitySync(comptime Data: type, comptime Kind: type) type {
    return struct {
        const Self = @This();
        pub const DataChanges = Changes(Data);

        /// What a kind supplies.
        pub const Spec = struct {
            kind: *Kind,
            /// Writes the entries `changes` names, in key order.
            write_data: *const fn (kind: *Kind, entries: *Entries, data: Data, changes: DataChanges) anyerror!void,
            /// Where the entity in a slot is: asked only on the ticks something of it goes.
            body: *const fn (kind: *Kind, slot: u32) Body,
            /// What the entity in a slot is: asked only to spawn it.
            identity: *const fn (kind: *Kind, slot: u32) Identity,
            /// EntityType.updateInterval and trackDeltas.
            update_interval: u32,
            track_deltas: bool = true,
            /// Room for one entity's data packet, when it can be more than 256 bytes.
            data_bytes: ?*const fn (kind: *Kind, slot: u32) usize = null,
            /// Whether the data is written for each recipient apart, as `entries.recipient` says.
            personalized: ?*const fn (kind: *const Kind) bool = null,
            /// The order `collect` gives a tick's visits in, for a kind that visits.
            before: ?*const fn (kind: *Kind, a: u32, b: u32) bool = null,
        };

        /// What decides whether an entity has anything to send this tick, read every tick.
        pub const Subject = struct {
            /// Its entity id, which a slot holds until it is let go.
            id: u64,
            /// Entity.hasImpulse: its next send goes now, whatever the interval.
            has_impulse: bool = false,
            /// Entity.hurtMarked: its velocity goes now.
            hurt_marked: bool = false,
            /// Null when it is known not to have changed since it was last sent.
            data: ?Data,
            /// Whether tracking changed its audience this tick, as `Tracking.changed` says.
            changed: bool,
            /// Nothing of it changes until its kind says so, as a sleeping item or a stuck arrow: it
            /// is not visited on its interval, so the move of nothing ServerEntity sends every 60
            /// ticks and its resync every 400 updates, which tell a client nothing, are left out.
            /// Its kind calls `stir` when it moves again.
            resting: bool = false,
            /// Ticks since the entity began, which ServerEntity.tickCount counts from as vanilla
            /// makes one when the entity is added: its interval falls on these ticks. Read only when
            /// its view begins.
            age: u64 = 0,
        };

        /// What an entity is: read only to spawn it.
        pub const Identity = struct {
            uuid: u128,
            /// Its type, as the registry numbers it.
            entity_type: u32,
            /// The spawn packet's data field.
            object_data: i32 = 0,
        };

        /// Where an entity is: read only on the ticks something of it goes.
        pub const Body = struct {
            position: [3]f64,
            velocity: [3]f64,
            yaw: f32,
            pitch: f32,
            head_yaw: f32 = 0,
            on_ground: bool,
        };

        /// ServerEntity's state for one entity.
        const View = struct {
            id: u64 = 0,
            /// VecDeltaCodec's base, the position deltas are measured from.
            base: [3]f64 = .{ 0, 0, 0 },
            yaw: i8 = 0,
            pitch: i8 = 0,
            head_yaw: i8 = 0,
            velocity: [3]f64 = .{ 0, 0, 0 },
            /// The tick ServerEntity.tickCount counts from: the ticks since it, wrapping, are the
            /// entity's age when its view began and every tick since.
            started: u64 = 0,
            teleport_delay: u32 = 0,
            was_on_ground: bool = false,
            data: Data = .{},
        };

        /// For kinds that visit only what has something to send: the next tick an entity's interval
        /// falls on, and its place in that turn of the wheel. Beside the views, which every kind
        /// reads, so those that walk all they have carry none of it.
        const Due = struct { tick: u64 = 0, next: u32 = none, previous: u32 = none, scheduled: bool = false };

        const Held = struct { slot: u32 = 0, id: u64 = 0, event: Event = .{ .status = 0 } };

        pub const Configuration = struct {
            /// Events held at once for viewers not yet sent them; past it the oldest is let go.
            events: usize = 1024,
            /// Keep a hash of every packet asked to be sent and whom to, for runs to be compared by.
            trace_sends: bool = false,
            /// Whether the kind visits only what has something to send, through `collect`, rather
            /// than walking every entity it has each tick.
            visits: bool = false,
        };
        pub const Dependencies = struct { players: *const Players, sessions: *sessions.Service, packets: *packets.Packets, tracking: *Tracking, pool: *entities.Pool, slots: usize = 0 };

        deps: Dependencies,
        /// What the kind supplies.
        spec: Spec,
        /// By slot, what its viewers were last sent: in the pool, not written out with it.
        views: entities.Array(View),
        /// Ticks this kind has sent.
        tick_count: u64 = 0,
        words: usize,
        /// Rows of players: spawned, removed, current, caught up, owed whole, and one alone.
        rows: []usize,
        /// Players a delivery could not be queued for this entity, who then need it whole.
        missed: []usize,
        missed_any: bool = false,
        delivery: Delivery,
        /// Deltas of entities that go to the same players, admitted for all of them at once.
        /// Whatever goes out alone sends them first, so each player has its packets in order.
        batch: delivery_module.Batch(u32),
        /// Events in the order they befell, each with the players still owed it: a ring.
        held: []Held,
        held_rows: []usize,
        held_first: usize = 0,
        held_count: usize = 0,
        /// For kinds that visit: what changed, who is owed whole, and by turn of the wheel the
        /// entities whose interval falls then.
        visit: ?Visit,
        dues: entities.Array(Due),
        wheel: [wheel_ticks]u32 = @splat(none),
        /// Whom a data packet written for each recipient apart reached and missed, gathered.
        personal: []usize,
        /// A running hash of every packet asked to be sent and whom to, when tests trace it.
        traced: u64 = 0,
        tracing: bool,

        pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies, spec: Spec) !Self {
            if (config.visits) assert(spec.before != null);
            if (config.events == 0) return error.InvalidEventCapacity;
            const words = deps.tracking.row_words;
            const self: Self = .{
                .deps = deps,
                .spec = spec,
                .personal = try allocator.alloc(usize, deps.players.records.len),
                .views = try .init(allocator, deps.pool),
                .words = words,
                .rows = try allocator.alloc(usize, 6 * words),
                .missed = try allocator.alloc(usize, words),
                .delivery = try .init(allocator, deps.players, deps.packets, deps.sessions),
                .batch = try .init(allocator, deps.players, deps.packets, deps.sessions, words),
                .held = try allocator.alloc(Held, config.events),
                .held_rows = try allocator.alloc(usize, config.events * words),
                .tracing = config.trace_sends,
                .visit = if (config.visits) try .init(allocator, deps.slots) else null,
                .dues = try .init(allocator, deps.pool),
            };
            @memset(self.missed, 0);
            @memset(self.held_rows, 0);
            return self;
        }

        fn row(self: *Self, at: usize) []usize {
            return self.rows[at * self.words ..][0..self.words];
        }

        fn heldRow(self: *Self, at: usize) []usize {
            return self.held_rows[at * self.words ..][0..self.words];
        }

        fn set(self: *const Self, words: []const usize) bit_sets.Set {
            return .{ .words = words, .capacity = self.deps.players.records.len };
        }

        fn put(words: []usize, player: usize) void {
            words[player / 64] |= @as(usize, 1) << @intCast(player % 64);
        }

        fn any(words: []const usize) bool {
            for (words) |word| if (word != 0) return true;
            return false;
        }

        /// A tick begins: what befell entities since the last goes first, in order.
        pub fn begin(self: *Self) !void {
            errdefer self.batch.abandon();
            try self.sendHeld();
        }

        /// A tick ends: what is queued goes.
        pub fn finish(self: *Self) !void {
            defer self.tick_count += 1;
            errdefer self.batch.abandon();
            try self.flushQueued();
        }

        /// Gives up what is queued, as a failed tick does.
        pub fn abandon(self: *Self) void {
            self.batch.abandon();
        }

        /// The view of a slot, in memory until let go, made empty if it had none.
        fn viewOf(self: *Self, slot: u32) !*View {
            try self.views.ensureFilled(@as(usize, slot) + 1, .{});
            return self.views.at(slot);
        }

        /// What its viewers were last sent of an entity's data, for a kind that read only part of
        /// it anew.
        pub fn sentData(self: *const Self, slot: u32) Data {
            if (slot >= self.views.len) return .{};
            return self.views.at(slot).data;
        }

        /// The tick the entity's view began, which its interval counts from: ServerEntity.tickCount
        /// is the ticks since.
        pub fn started(self: *const Self, slot: u32) u64 {
            return self.views.at(slot).started;
        }

        // Visits.

        /// What clients have of the entity in a slot changed, its data or an impulse: it is visited
        /// next tick whatever its interval says.
        pub fn mark(self: *Self, slot: u32) void {
            self.visit.?.mark(slot);
        }

        /// An entity at rest moves again: it is visited next tick, and on its interval after.
        pub fn stir(self: *Self, slot: u32) void {
            const visit = &(self.visit orelse return);
            if (slot < self.dues.len and self.dues.at(slot).scheduled) return;
            visit.mark(slot);
        }

        /// Every entity with a view is visited next tick, as when how all of them show changed.
        pub fn markAll(self: *Self) void {
            for (0..self.views.len) |at| if (self.views.at(at).id != 0) self.visit.?.mark(@intCast(at));
        }

        /// The slots to send this tick, each once, in the order `before` puts them: those tracking
        /// changed an audience of, those marked, those a viewer is owed whole, and those whose
        /// interval falls now. Nothing else has anything to send. Good until the next collect.
        pub fn collect(self: *Self, tracker: Tracking.TrackerId) []const u32 {
            const visit = &self.visit.?;
            var at = self.wheel[self.tick_count % wheel_ticks];
            while (at != none) {
                const due = self.dues.at(at);
                if (due.tick == self.tick_count) visit.mark(at);
                at = due.next;
            }
            return visit.collect(self.deps.tracking, tracker, &self.spec, beforeBySpec);
        }

        fn beforeBySpec(spec: *const Spec, a: u32, b: u32) bool {
            return spec.before.?(spec.kind, a, b);
        }

        /// An entity visited: due again when its interval next falls, and owed while a viewer is.
        fn visited(self: *Self, slot: u32, view: *View, interval: u32, resting: bool) !void {
            const visit = &(self.visit orelse return);
            if (self.deps.tracking.stale(slot).any()) visit.owe(slot) else visit.settle(slot);
            // One no client has has nothing to send on its interval, and one at rest nothing new:
            // tracking's change, or its kind stirring it, brings it back.
            if (resting or !self.deps.tracking.known(slot).any()) {
                self.unschedule(slot);
                return;
            }
            const since = self.tick_count -% view.started;
            const next = self.tick_count + interval - since % interval;
            try self.dues.ensureFilled(@as(usize, slot) + 1, .{});
            const due = self.dues.at(slot);
            if (!due.scheduled or due.tick != next) {
                self.unschedule(slot);
                due.tick = next;
                const turn = &self.wheel[next % wheel_ticks];
                due.next = turn.*;
                due.previous = none;
                if (turn.* != none) self.dues.at(turn.*).previous = slot;
                turn.* = slot;
                due.scheduled = true;
            }
        }

        fn unschedule(self: *Self, slot: u32) void {
            if (self.visit == null or slot >= self.dues.len) return;
            const due = self.dues.at(slot);
            if (!due.scheduled) return;
            if (due.previous != none) self.dues.at(due.previous).next = due.next else self.wheel[due.tick % wheel_ticks] = due.next;
            if (due.next != none) self.dues.at(due.next).previous = due.previous;
            due.scheduled = false;
        }

        /// The view of a slot goes, its place in the wheel and what it was owed with it.
        fn drop(self: *Self, slot: u32) void {
            if (slot >= self.views.len) return;
            self.unschedule(slot);
            if (self.visit) |*visit| visit.settle(slot);
            self.views.at(slot).* = .{};
        }

        /// Who has the entity and is not behind: who its deltas go to.
        fn current(self: *Self, slot: u32) bit_sets.Set {
            const known = self.deps.tracking.known(slot);
            const stale = self.deps.tracking.stale(slot);
            const words = self.row(2);
            for (words, 0..) |*word, at| word.* = known.wordAt(at) & ~stale.wordAt(at);
            return self.set(words);
        }

        /// Players missed something of an entity: they are owed it whole, and a kind that visits
        /// comes back to it, however late the miss is found.
        fn behind(self: *Self, slot: u32, players: bit_sets.Set) void {
            self.deps.tracking.missed(slot, players);
            if (self.visit) |*visit| visit.owe(slot);
        }

        /// Deltas some players could not take: they need the entity whole.
        fn noteMissed(self: *Self, slot: u32) void {
            if (!self.missed_any) return;
            self.behind(slot, self.set(self.missed));
            @memset(self.missed, 0);
            self.missed_any = false;
        }

        /// One entity's tick of ChunkMap.TrackedEntity and ServerEntity: removals and spawns as
        /// tracking asks, then what changed, then the whole of it to whoever missed some.
        /// The spec's `body` is asked only on the ticks something of it goes, and its `identity`
        /// only to spawn it.
        pub fn update(self: *Self, slot: u32, subject: Subject) !void {
            const tracking = self.deps.tracking;
            const view = try self.viewOf(slot);
            var body: ?Body = null;
            if (view.id != subject.id) {
                assert(!tracking.known(slot).any());
                self.unschedule(slot);
                body = self.spec.body(self.spec.kind, slot);
                view.* = start(subject, body.?);
                view.started = self.tick_count -% subject.age;
            }
            if (subject.changed) try self.pairing(slot, self.spec.identity(self.spec.kind, slot), view, tracking.changed(slot).?);
            const known = self.current(slot);
            // Data known not to have changed is not compared.
            const now = subject.data orelse view.data;
            const changes: DataChanges = if (subject.data) |data| .between(view.data, data) else .{};
            // ServerEntity.sendChanges: on its interval, an impulse or changed data, its movement,
            // velocity, data and head; a hurt entity's velocity at once.
            if ((self.tick_count -% view.started) % self.spec.update_interval == 0 or subject.has_impulse or changes.any()) {
                if (body == null) body = self.spec.body(self.spec.kind, slot);
                try self.sendDue(slot, known, body.?, subject.has_impulse, view, now, changes);
            }
            if (subject.hurt_marked) {
                if (body == null) body = self.spec.body(self.spec.kind, slot);
                try self.queue(slot, known, .{ .velocity = .{ .id = entities.Entities.networkOfSlot(slot), .velocity = body.?.velocity } });
            }
            self.noteMissed(slot);
            if (tracking.stale(slot).any()) try self.catchUp(slot, view);
            if (self.visit != null) try self.visited(slot, view, self.spec.update_interval, subject.resting);
        }

        /// An entity gone from memory: only its removal is left, for whoever has it.
        pub fn gone(self: *Self, slot: u32) !void {
            const change = self.deps.tracking.changed(slot) orelse return;
            const removed = self.row(1);
            @memset(removed, 0);
            try self.remove(slot, change.remove, removed);
            self.deps.tracking.confirm(slot, self.deps.tracking.nobody(), self.set(removed));
            // Its view goes once no client has it: until then it is what they were last sent.
            if (!self.deps.tracking.known(slot).any()) self.drop(slot);
        }

        /// The slot is let go: what is queued of it goes first, as it settles by its slot.
        pub fn forget(self: *Self, slot: u32) !void {
            try self.flushQueued();
            self.drop(slot);
        }

        /// Removals, but not before an event a client is owed of it; then spawns.
        fn pairing(self: *Self, slot: u32, identity: Identity, view: *const View, change: Tracking.Change) !void {
            const spawned = self.row(0);
            const removed = self.row(1);
            @memset(spawned, 0);
            @memset(removed, 0);
            try self.remove(slot, change.remove, removed);
            try self.pair(slot, identity, view, change.spawn, spawned);
            self.deps.tracking.confirm(slot, self.set(spawned), self.set(removed));
            @memset(self.missed, 0);
            self.missed_any = false;
        }

        fn remove(self: *Self, slot: u32, players: bit_sets.Set, removed: []usize) !void {
            const pending = self.row(4);
            for (pending, 0..) |*word, at| word.* = players.wordAt(at);
            for (0..self.held_count) |offset| {
                const at = (self.held_first + offset) % self.held.len;
                if (self.held[at].slot != slot) continue;
                for (pending, self.heldRow(at)) |*word, owed| word.* &= ~owed;
            }
            try self.deliver(self.set(pending), .{ .remove = entities.Entities.networkOfSlot(slot) });
            self.delivery.markReached(removed);
        }

        fn start(subject: Subject, body: Body) View {
            return .{
                .id = subject.id,
                .base = body.position,
                .yaw = packDegrees(body.yaw),
                .pitch = packDegrees(body.pitch),
                .head_yaw = packDegrees(body.head_yaw),
                .velocity = body.velocity,
                .was_on_ground = body.on_ground,
                .data = subject.data orelse .{},
            };
        }

        /// ServerEntity.sendPairingData: the entity as last sent, and its data that differs from
        /// the defaults. Those the spawn was queued for go into `spawned`.
        fn pair(self: *Self, slot: u32, identity: Identity, view: *const View, recipients: bit_sets.Set, spawned: []usize) !void {
            const id = entities.Entities.networkOfSlot(slot);
            try self.deliver(recipients, .{ .spawn = .{ .id = id, .uuid = identity.uuid, .kind = identity.entity_type, .data = identity.object_data, .position = view.base, .velocity = view.velocity, .yaw = view.yaw, .pitch = view.pitch, .head_yaw = view.head_yaw } });
            self.delivery.markReached(spawned);
            const changes = DataChanges.fromDefaults(view.data);
            if (changes.any()) try self.deliver(recipients, .{ .metadata = .{ .id = id, .data = view.data, .changes = changes } });
        }

        /// Players that missed a delta get the entity as last sent to everyone: where it is, its
        /// data and its head.
        fn catchUp(self: *Self, slot: u32, view: *const View) !void {
            const stale = self.deps.tracking.stale(slot);
            if (!stale.any()) return;
            const id = entities.Entities.networkOfSlot(slot);
            try self.deliver(stale, .{ .sync = .{ .id = id, .position = view.base, .velocity = view.velocity, .yaw = unpack(view.yaw), .pitch = unpack(view.pitch), .on_ground = view.was_on_ground } });
            const caught = self.row(3);
            @memset(caught, 0);
            self.delivery.markReached(caught);
            const changes = DataChanges.fromDefaults(view.data);
            if (changes.any()) try self.deliver(self.set(caught), .{ .metadata = .{ .id = id, .data = view.data, .changes = changes } });
            try self.deliver(self.set(caught), .{ .head = .{ .id = id, .yaw = view.head_yaw } });
            self.deps.tracking.caughtUp(slot, self.set(caught));
            @memset(self.missed, 0);
            self.missed_any = false;
        }

        fn unpack(angle: i8) f32 {
            return @as(f32, @floatFromInt(angle)) * 360.0 / 256.0;
        }

        fn sendDue(self: *Self, slot: u32, known: bit_sets.Set, subject: Body, has_impulse: bool, view: *View, now: Data, changes: DataChanges) !void {
            const yaw = packDegrees(subject.yaw);
            const pitch = packDegrees(subject.pitch);
            const turned = @abs(@as(i32, yaw) - view.yaw) >= 1 or @abs(@as(i32, pitch) - view.pitch) >= 1;
            view.teleport_delay += 1;
            // One where it was last sent moved by nothing, which spares the rounding.
            const encoded: [3]i64 = if (std.meta.eql(subject.position, view.base)) .{ 0, 0, 0 } else .{ encode(subject.position[0]) - encode(view.base[0]), encode(subject.position[1]) - encode(view.base[1]), encode(subject.position[2]) - encode(view.base[2]) };
            const delta: [3]f64 = .{ @as(f64, @floatFromInt(encoded[0])) / 4096.0, @as(f64, @floatFromInt(encoded[1])) / 4096.0, @as(f64, @floatFromInt(encoded[2])) / 4096.0 };
            const moved = delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] >= @as(f64, @as(f32, 7.6293945e-6));
            const position_due = moved or (self.tick_count -% view.started) % 60 == 0;
            var sent_position = false;
            var sent_rotation = false;
            const far = for (encoded) |component| {
                if (component < -32768 or component > 32767) break true;
            } else false;
            const Movement = enum { none, sync, position, rotation, both };
            var movement: Movement = .none;
            if (far or view.teleport_delay > 400 or view.was_on_ground != subject.on_ground) {
                view.was_on_ground = subject.on_ground;
                view.teleport_delay = 0;
                movement = .sync;
                sent_position = true;
                sent_rotation = true;
            } else if (!position_due or !turned) {
                if (position_due) {
                    movement = .position;
                    sent_position = true;
                } else if (turned) {
                    movement = .rotation;
                    sent_rotation = true;
                }
            } else {
                movement = .both;
                sent_position = true;
                sent_rotation = true;
            }
            const id = entities.Entities.networkOfSlot(slot);
            if (has_impulse or self.spec.track_deltas) {
                const difference: [3]f64 = .{ subject.velocity[0] - view.velocity[0], subject.velocity[1] - view.velocity[1], subject.velocity[2] - view.velocity[2] };
                const squared = difference[0] * difference[0] + difference[1] * difference[1] + difference[2] * difference[2];
                const length = subject.velocity[0] * subject.velocity[0] + subject.velocity[1] * subject.velocity[1] + subject.velocity[2] * subject.velocity[2];
                if (squared > 1.0e-7 or (squared > 0 and length == 0)) {
                    view.velocity = subject.velocity;
                    try self.queue(slot, known, .{ .velocity = .{ .id = id, .velocity = view.velocity } });
                }
            }
            const short: [3]i16 = .{ @truncate(encoded[0]), @truncate(encoded[1]), @truncate(encoded[2]) };
            switch (movement) {
                .none => {},
                .sync => try self.queue(slot, known, .{ .sync = .{ .id = id, .position = subject.position, .velocity = subject.velocity, .yaw = subject.yaw, .pitch = subject.pitch, .on_ground = subject.on_ground } }),
                .position => try self.queue(slot, known, .{ .relative = .{ .id = id, .delta = short, .on_ground = subject.on_ground } }),
                .rotation => try self.queue(slot, known, .{ .look = .{ .id = id, .yaw = yaw, .pitch = pitch, .on_ground = subject.on_ground } }),
                .both => try self.queue(slot, known, .{ .move_look = .{ .id = id, .delta = short, .yaw = yaw, .pitch = pitch, .on_ground = subject.on_ground } }),
            }
            if (changes.any()) {
                try self.queue(slot, known, .{ .metadata = .{ .id = id, .data = now, .changes = changes } });
                view.data = now;
            }
            if (sent_position) view.base = subject.position;
            if (sent_rotation) {
                view.yaw = yaw;
                view.pitch = pitch;
            }
            const head = packDegrees(subject.head_yaw);
            if (@abs(@as(i32, head) - view.head_yaw) >= 1) {
                try self.queue(slot, known, .{ .head = .{ .id = id, .yaw = head } });
                view.head_yaw = head;
            }
        }

        // Events.

        /// What befell the entity in a slot, for whoever has it now: sent at the next tick's
        /// beginning, before its removal, and again to whoever had no room for it. Past the
        /// events held, what is held goes now, and then the oldest is let go.
        pub fn hold(self: *Self, slot: u32, event: Event) !void {
            const known = self.deps.tracking.known(slot);
            if (!known.any()) return;
            if (self.held_count == self.held.len) try self.sendHeld();
            if (self.held_count == self.held.len) {
                self.held_first = (self.held_first + 1) % self.held.len;
                self.held_count -= 1;
            }
            const at = (self.held_first + self.held_count) % self.held.len;
            self.held_count += 1;
            for (self.heldRow(at), 0..) |*word, index| word.* = known.wordAt(index);
            self.held[at] = .{ .slot = slot, .event = event };
        }

        /// Held events to whoever is owed them, in order: one with no room for an event gets no
        /// later one until it has room.
        fn sendHeld(self: *Self) !void {
            if (self.held_count == 0) return;
            try self.flushQueued();
            const blocked = self.row(4);
            @memset(blocked, 0);
            const pending = self.row(3);
            for (0..self.held_count) |offset| {
                const at = (self.held_first + offset) % self.held.len;
                const held = self.held[at];
                const owed = self.heldRow(at);
                // Only those who still have it: one that reconnected since never saw it.
                const known = self.deps.tracking.known(held.slot);
                for (owed, 0..) |*word, index| word.* &= known.wordAt(index);
                for (pending, owed, blocked) |*word, value, stop| word.* = value & ~stop;
                if (!any(pending)) continue;
                const id = entities.Entities.networkOfSlot(held.slot);
                try self.deliver(self.set(pending), switch (held.event) {
                    .status => |status| .{ .status = .{ .id = id, .status = status } },
                    .animation => |animation| .{ .animation = .{ .id = id, .animation = animation } },
                    .damage => |damage| .{ .damage = .{ .id = id, .type_id = damage.type_id, .cause = damage.cause } },
                    .collect => |taken| .{ .collect = .{ .id = id, .collector = taken.collector, .count = taken.count } },
                });
                for (self.delivery.reachedPlayers()) |player| owed[player / 64] &= ~(@as(usize, 1) << @intCast(player % 64));
                for (self.delivery.missedPlayers()) |player| put(blocked, player);
                // Whoever left has nothing owed.
                var each = self.set(owed).iterator();
                while (each.next()) |player| if (self.deps.players.records[player].handle == null) {
                    owed[player / 64] &= ~(@as(usize, 1) << @intCast(player % 64));
                };
            }
            // Those sent to everyone leave from the front.
            while (self.held_count > 0 and !any(self.heldRow(self.held_first))) {
                self.held_first = (self.held_first + 1) % self.held.len;
                self.held_count -= 1;
            }
        }

        // Sending.

        /// Sends a packet to a set of players now, noting who got it and who missed it: what was
        /// queued goes first.
        fn deliver(self: *Self, recipients: bit_sets.Set, outgoing: Outgoing) !void {
            try self.flushQueued();
            const delivery = &self.delivery;
            if (!recipients.any()) {
                delivery.reached_count = 0;
                delivery.missed_count = 0;
                return;
            }
            if (self.tracing) self.traceSend(recipients, outgoing);
            switch (outgoing) {
                .status => |value| try delivery.send(recipients, writeStatus, .{ value.id, value.status }, 32),
                .remove => |value| try delivery.send(recipients, writeRemove, .{value}, 32),
                .spawn => |value| try delivery.send(recipients, .{ spawnLegacy, spawnPacked }, .{value}, 128),
                .metadata => |value| try self.deliverData(recipients, value.id, value.data, value.changes),
                .velocity => |value| try delivery.send(recipients, .{ writeVelocityLegacy, writeVelocityPacked }, .{ value.id, value.velocity }, 64),
                .sync => |value| try delivery.send(recipients, writeSync, .{ value.id, value.position, value.velocity, value.yaw, value.pitch, value.on_ground }, 128),
                .relative => |value| try delivery.send(recipients, writeRelative, .{ value.id, value.delta, value.on_ground }, 32),
                .look => |value| try delivery.send(recipients, writeLook, .{ value.id, value.yaw, value.pitch, value.on_ground }, 32),
                .move_look => |value| try delivery.send(recipients, writeMoveLook, .{ value.id, value.delta, value.yaw, value.pitch, value.on_ground }, 32),
                .head => |value| try delivery.send(recipients, writeHead, .{ value.id, value.yaw }, 32),
                .damage => |value| try delivery.send(recipients, writeDamage, .{ value.id, value.type_id, value.cause }, 32),
                .animation => |value| try delivery.send(recipients, writeAnimation, .{ value.id, value.animation }, 32),
                .collect => |value| try delivery.send(recipients, writeCollect, .{ value.id, value.collector, value.count }, 32),
            }
            for (delivery.missedPlayers()) |player| {
                put(self.missed, player);
                self.missed_any = true;
            }
        }

        /// Folds a packet asked to be sent, and whom to, into the trace when tests ask for one.
        fn traceSend(self: *Self, recipients: bit_sets.Set, outgoing: Outgoing) void {
            if (!self.tracing) return;
            var hasher = std.hash.Wyhash.init(self.traced);
            hasher.update(std.mem.asBytes(&self.tick_count));
            hasher.update(&.{@backingInt(outgoing)});
            switch (outgoing) {
                inline else => |value| trace(&hasher, value),
            }
            var who = recipients.iterator();
            while (who.next()) |player| hasher.update(std.mem.asBytes(&player));
            self.traced = hasher.final();
        }

        /// Queues a delta of the entity in a slot for a set of players, with others for the same
        /// players: whom it misses learn so when the batch goes, and are owed it whole.
        fn queue(self: *Self, slot: u32, recipients: bit_sets.Set, outgoing: Outgoing) !void {
            if (!recipients.any()) return;
            if (self.tracing) self.traceSend(recipients, outgoing);
            // Room the batch lacks sends what it holds; a second miss means its players have none.
            for (0..2) |_| {
                switch (try self.batch.prepare(recipients, 1, self, settleQueued)) {
                    .ready => {},
                    // None of them playing yet, or none with room: they are owed it all the same.
                    .nobody, .backpressured => break,
                }
                const sent = switch (outgoing) {
                    .metadata => |value| if (self.personalized()) {
                        // Written for each recipient apart: it goes alone, so the batch takes the rest.
                        try self.flushQueued();
                        try self.deliverData(recipients, value.id, value.data, value.changes);
                        if (self.delivery.missed_count == 0) return;
                        const late = self.row(4);
                        @memset(late, 0);
                        for (self.delivery.missedPlayers()) |player| put(late, player);
                        self.behind(slot, self.set(late));
                        return;
                    } else try self.batch.send(slot, writeMetadata, .{ value.id, value.data, value.changes, &self.spec, @as(?u128, null) }, self.dataBytes(slot)),
                    .velocity => |value| try self.batch.send(slot, .{ writeVelocityLegacy, writeVelocityPacked }, .{ value.id, value.velocity }, 64),
                    .sync => |value| try self.batch.send(slot, writeSync, .{ value.id, value.position, value.velocity, value.yaw, value.pitch, value.on_ground }, 128),
                    .relative => |value| try self.batch.send(slot, writeRelative, .{ value.id, value.delta, value.on_ground }, 32),
                    .look => |value| try self.batch.send(slot, writeLook, .{ value.id, value.yaw, value.pitch, value.on_ground }, 32),
                    .move_look => |value| try self.batch.send(slot, writeMoveLook, .{ value.id, value.delta, value.yaw, value.pitch, value.on_ground }, 32),
                    .head => |value| try self.batch.send(slot, writeHead, .{ value.id, value.yaw }, 32),
                    else => unreachable,
                };
                if (sent) return;
                try self.flushQueued();
            }
            // Nothing went: those in a session are owed it whole.
            const owed = self.row(4);
            @memset(owed, 0);
            var each = recipients.iterator();
            while (each.next()) |player| if (self.deps.players.records[player].handle != null) put(owed, player);
            self.behind(slot, self.set(owed));
        }

        /// What a queued delta of the entity in a slot reached: whom it missed are behind.
        fn settleQueued(self: *Self, slot: u32, accepted: bit_sets.Set, _: usize) !void {
            const missed = self.batch.missedOf(accepted);
            if (missed.any()) self.behind(slot, missed);
        }

        fn flushQueued(self: *Self) !void {
            try self.batch.flush(self, settleQueued);
        }

        /// A packet to some of an entity's viewers.
        const Outgoing = union(enum) {
            status: struct { id: i32, status: u8 },
            remove: i32,
            spawn: Spawn,
            metadata: struct { id: i32, data: Data, changes: DataChanges },
            velocity: struct { id: i32, velocity: [3]f64 },
            sync: struct { id: i32, position: [3]f64, velocity: [3]f64, yaw: f32, pitch: f32, on_ground: bool },
            relative: struct { id: i32, delta: [3]i16, on_ground: bool },
            look: struct { id: i32, yaw: i8, pitch: i8, on_ground: bool },
            move_look: struct { id: i32, delta: [3]i16, yaw: i8, pitch: i8, on_ground: bool },
            head: struct { id: i32, yaw: i8 },
            damage: struct { id: i32, type_id: i32, cause: i32 },
            animation: struct { id: i32, animation: u8 },
            collect: struct { id: i32, collector: i32, count: i32 },
        };

        /// Room for one entity's data packet, as its kind says.
        fn dataBytes(self: *Self, slot: u32) usize {
            const bytes = self.spec.data_bytes orelse return 256;
            return bytes(self.spec.kind, slot);
        }

        fn personalized(self: *const Self) bool {
            const personal = self.spec.personalized orelse return false;
            return personal(self.spec.kind);
        }

        /// An entity's data to a set of players: to all at once, or written for each apart, the
        /// delivery then saying whom all of them reached and missed.
        fn deliverData(self: *Self, recipients: bit_sets.Set, id: i32, data: Data, changes: DataChanges) !void {
            const slot: u32 = @intCast(-id - 1);
            const delivery = &self.delivery;
            if (!self.personalized()) return delivery.send(recipients, writeMetadata, .{ id, data, changes, &self.spec, @as(?u128, null) }, self.dataBytes(slot));
            const reached = self.personal;
            var reached_count: usize = 0;
            var missed_count: usize = 0;
            const alone = self.row(5);
            var each = recipients.iterator();
            while (each.next()) |player| {
                @memset(alone, 0);
                put(alone, player);
                try delivery.send(self.set(alone), writeMetadata, .{ id, data, changes, &self.spec, @as(?u128, self.deps.players.records[player].uuid) }, self.dataBytes(slot));
                // Reached from the front, missed from the back of the same room.
                for (delivery.reachedPlayers()) |at| {
                    reached[reached_count] = at;
                    reached_count += 1;
                }
                for (delivery.missedPlayers()) |at| {
                    missed_count += 1;
                    reached[reached.len - missed_count] = at;
                }
            }
            @memcpy(delivery.reached[0..reached_count], reached[0..reached_count]);
            delivery.reached_count = reached_count;
            @memcpy(delivery.missed[0..missed_count], reached[reached.len - missed_count ..]);
            delivery.missed_count = missed_count;
        }

        fn writeMetadata(packet: wire.play.toClient.packet_entity_metadata.Writer, registry: packets.Registry, id: i32, data: Data, changes: DataChanges, spec: *const Spec, recipient: ?u128) ![]u8 {
            var metadata = try (try packet.entityId(id)).metadata();
            const done = try packets.nested(.{writeEntries}).write(try metadata.begin(), Values{ .data = data, .changes = changes, .protocol = packet.layoutProtocol(), .spec = spec, .slot = @intCast(-id - 1), .recipient = recipient, .registry = registry });
            return (try metadata.advance(done)).finish();
        }

        const Values = struct { data: Data, changes: DataChanges, protocol: i32, spec: *const Spec, slot: u32, recipient: ?u128, registry: packets.Registry };

        fn writeEntries(packet: wire.entityMetadata.Writer, values: Values) !wire.entityMetadata.Writer.Done {
            var list = try packet.value(values.changes.count());
            var entries: Entries = .{ .list = &list, .protocol = values.protocol, .slot = values.slot, .recipient = values.recipient, .registry = values.registry };
            try values.spec.write_data(values.spec.kind, &entries, values.data, values.changes);
            return list.finish();
        }
    };
}

/// Hashes a value field by field, so padding and an empty optional's payload are left out.
fn trace(hasher: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |info| inline for (info.field_names) |name| trace(hasher, @field(value, name)),
        .array => for (value) |item| trace(hasher, item),
        .optional => if (value) |inner| {
            hasher.update(&.{1});
            trace(hasher, inner);
        } else hasher.update(&.{0}),
        .@"union" => switch (value) {
            inline else => |inner, tag| {
                hasher.update(&.{@backingInt(tag)});
                trace(hasher, inner);
            },
        },
        .bool => hasher.update(&.{@intFromBool(value)}),
        else => hasher.update(std.mem.asBytes(&value)),
    }
}

/// MathHelper.packDegrees.
pub fn packDegrees(value: f32) i8 {
    return @truncate(floorFloat(value * 256.0 / 360.0));
}

/// MathHelper.floor of a float, as Java's int conversion takes it.
fn floorFloat(value: f32) i32 {
    const truncated: i32 = if (std.math.isNan(value)) 0 else if (value >= 2147483647.0) std.math.maxInt(i32) else if (value <= -2147483648.0) std.math.minInt(i32) else @intFromFloat(value);
    return if (value < @as(f32, @floatFromInt(truncated))) truncated - 1 else truncated;
}

/// VecDeltaCodec.encode.
fn encode(value: f64) i64 {
    return @intFromFloat(@round(value * 4096.0));
}

/// ClientboundAddEntityPacket's fields, as last sent.
const Spawn = struct {
    id: i32,
    uuid: u128,
    kind: u32,
    data: i32,
    position: [3]f64,
    velocity: [3]f64,
    yaw: i8,
    pitch: i8,
    head_yaw: i8,
};

fn spawnLegacy(packet: wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, spawn: Spawn) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(spawn.id)).objectUUID(spawn.uuid)).type(try registry.entityId(@intCast(spawn.kind)))).x(spawn.position[0])).y(spawn.position[1])).z(spawn.position[2]);
    const data = try (try (try (try positioned.pitch(spawn.pitch)).yaw(spawn.yaw)).headPitch(spawn.head_yaw)).objectData(spawn.data);
    var velocity = try data.velocity();
    return (try velocity.advance(try packets.nested(.{writeShortVelocity}).write(try velocity.begin(), spawn.velocity))).finish();
}

fn writeShortVelocity(packet: wire.vec3i16.Writer, motion: [3]f64) !wire.vec3i16.Writer.Done {
    return (try (try packet.x(shortVelocity(motion[0]))).y(shortVelocity(motion[1]))).z(shortVelocity(motion[2]));
}

fn shortVelocity(value: f64) i16 {
    return @intFromFloat(std.math.clamp(value, -3.9, 3.9) * 8000);
}

fn spawnPacked(packet: packed_wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, spawn: Spawn) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(spawn.id)).objectUUID(spawn.uuid)).type(try registry.entityId(@intCast(spawn.kind)))).x(spawn.position[0])).y(spawn.position[1])).z(spawn.position[2]);
    const rotated = try (try (try (try positioned.velocity(.{ .x = spawn.velocity[0], .y = spawn.velocity[1], .z = spawn.velocity[2] })).pitch(spawn.pitch)).yaw(spawn.yaw)).headPitch(spawn.head_yaw);
    return (try rotated.objectData(spawn.data)).finish();
}

fn writeRelative(packet: wire.play.toClient.packet_rel_entity_move.Writer, id: i32, delta: [3]i16, on_ground: bool) ![]u8 {
    return (try (try (try (try (try packet.entityId(id)).dX(delta[0])).dY(delta[1])).dZ(delta[2])).onGround(on_ground)).finish();
}

fn writeLook(packet: wire.play.toClient.packet_entity_look.Writer, id: i32, yaw: i8, pitch: i8, on_ground: bool) ![]u8 {
    return (try (try (try (try packet.entityId(id)).yaw(yaw)).pitch(pitch)).onGround(on_ground)).finish();
}

fn writeMoveLook(packet: wire.play.toClient.packet_entity_move_look.Writer, id: i32, delta: [3]i16, yaw: i8, pitch: i8, on_ground: bool) ![]u8 {
    return (try (try (try (try (try (try (try packet.entityId(id)).dX(delta[0])).dY(delta[1])).dZ(delta[2])).yaw(yaw)).pitch(pitch)).onGround(on_ground)).finish();
}

fn writeSync(packet: wire.play.toClient.packet_sync_entity_position.Writer, id: i32, position: [3]f64, velocity: [3]f64, yaw: f32, pitch: f32, on_ground: bool) ![]u8 {
    const positioned = try (try (try (try packet.entityId(id)).x(position[0])).y(position[1])).z(position[2]);
    const moving = try (try (try positioned.dx(velocity[0])).dy(velocity[1])).dz(velocity[2]);
    return (try (try (try moving.yaw(yaw)).pitch(pitch)).onGround(on_ground)).finish();
}

fn writeVelocityLegacy(packet: wire.play.toClient.packet_entity_velocity.Writer, id: i32, velocity: [3]f64) ![]u8 {
    var value = try (try packet.entityId(id)).velocity();
    return (try value.advance(try packets.nested(.{writeShortVelocity}).write(try value.begin(), velocity))).finish();
}

fn writeVelocityPacked(packet: packed_wire.play.toClient.packet_entity_velocity.Writer, id: i32, velocity: [3]f64) ![]u8 {
    return (try (try packet.entityId(id)).velocity(.{ .x = velocity[0], .y = velocity[1], .z = velocity[2] })).finish();
}

fn writeHead(packet: wire.play.toClient.packet_entity_head_rotation.Writer, id: i32, head: i8) ![]u8 {
    return (try (try packet.entityId(id)).headYaw(head)).finish();
}

fn writeAnimation(packet: wire.play.toClient.packet_animation.Writer, id: i32, animation: u8) ![]u8 {
    return (try (try packet.entityId(id)).animation(animation)).finish();
}

fn writeStatus(packet: wire.play.toClient.packet_entity_status.Writer, id: i32, status: u8) ![]u8 {
    return (try (try packet.entityId(id)).entityStatus(@bitCast(status))).finish();
}

fn writeRemove(packet: wire.play.toClient.packet_entity_destroy.Writer, id: i32) ![]u8 {
    const ids = try packet.entityIds(1);
    const entry = try ids.element(id);
    return (try entry.finish()).finish();
}

fn writeCollect(packet: wire.play.toClient.packet_collect.Writer, id: i32, collector: i32, count: i32) ![]u8 {
    return (try (try (try packet.collectedEntityId(id)).collectorEntityId(collector)).pickupItemCount(count)).finish();
}

/// ClientboundDamageEventPacket. The cause and the direct cause are the same here, and no damage
/// has a position of its own.
fn writeDamage(packet: wire.play.toClient.packet_damage_event.Writer, id: i32, type_id: i32, cause: i32) ![]u8 {
    const typed = try (try (try (try packet.entityId(id)).sourceTypeId(type_id)).sourceCauseId(cause)).sourceDirectId(cause);
    var position = try typed.sourcePosition();
    return (try position.advance(try (try position.begin()).none())).finish();
}
