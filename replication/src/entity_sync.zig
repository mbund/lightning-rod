//! Vanilla's ServerEntity, once, for every kind: what clients that track an entity were last
//! sent of it, and every tick what changed since. A kind says what its entities synchronize, as
//! its Data and how each entry is written, what one is now, and how its clients move it between
//! what they are sent. This sends its spawns and removals as tracking asks, the whole of it to
//! whoever missed some, and what befell it before it goes; and its movement by how its clients
//! move it. Clients that cannot be predicted are sent it as ServerEntity.sendChanges sends it.
//! Clients that step it themselves are held to models of what they computed, and sent the
//! cheapest correction only where one would look apart from it.

const std = @import("std");
const entities = @import("entities");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const protocols = @import("minecraft_packets").protocols;
const support = @import("protocol_support");
const wire = @import("wire_1_21_5");
const packed_wire = @import("wire_1_21_9");
const Players = @import("players").players.Players;
const Tracking = @import("tracking.zig").Tracking;
const delivery_module = @import("delivery.zig");
const models_module = @import("models.zig");

const Delivery = delivery_module.Delivery;
const Visit = @import("visit.zig").Visit;
pub const Models = models_module.Models;
pub const Model = models_module.Model;
pub const Classes = models_module.Classes;
const Drift = models_module.Drift;
const IndexSet = lightning_rod.system.IndexSet;

const none = std.math.maxInt(u32);
/// Turns of the wheel kinds that visit are due on: more than the longest update interval.
const wheel_ticks = 64;
/// The most ticks an entity its clients step and that moves goes without being put right for
/// every viewer.
const backstop_ticks = 400;
/// How near the entity a model must be on every axis for its clients to be put right by its
/// motion alone.
const motion_reach = 1.0 / 4096.0;
const bit_sets = lightning_rod.system.bit_sets;
const assert = std.debug.assert;

/// How a kind's clients move its entities between what they are sent.
pub const Client = union(enum) {
    /// Clients step it themselves every tick, as an item or an arrow. It is sent only where a
    /// class of them would look apart from it, as their models say.
    simulates: Simulation,
    /// What clients make of it cannot be worked out here: mobs (their AI), players (their input),
    /// orbs (they ease toward what they are sent and chase their client's view of the nearest
    /// player). It goes on ServerEntity's schedule.
    unpredictable: Unpredictable,
};

pub const Simulation = struct {
    /// Where clients step it otherwise than the server does: its models, which its kind steps.
    /// Null where they step it as the server does, its spawn's rounded velocity all they differ
    /// by, which keeps them well within the tolerance for as long as the backstop lets it go.
    models: ?Models.Configuration = null,
};

pub const Unpredictable = struct {
    /// EntityType.updateInterval: how often it is looked at, as ServerEntity is.
    update_interval: u32,
    /// EntityType.trackDeltas: its velocity goes whenever it changes.
    track_deltas: bool = true,
};

/// How each protocol rounds the velocity its spawn and motion packets carry, as the writers this
/// sends them by choose for it: a short of eighths of a thousandth, or a packed vector from 1.21.9.
const Rounding = enum(u8) { short, packed_vector };

const roundings: Models.Roundings = .{ .count = @typeInfo(Rounding).@"enum".field_names.len, .of = roundingOf };

pub fn roundingOf(protocol: i32) u8 {
    inline for (protocols.implementations) |Version| {
        const spawn = comptime sessions.packet_api.select(Version, .{ spawnLegacy, spawnPacked });
        const motion = comptime sessions.packet_api.select(Version, .{ writeVelocityLegacy, writeVelocityPacked });
        comptime assert(spawn == motion);
        if (Version.protocol_number == protocol) return spawn;
    }
    unreachable;
}

/// The velocity a client of a rounding is given when sent `velocity`.
fn rounded(rounding: u8, velocity: [3]f64) [3]f64 {
    switch (@as(Rounding, @fromBackingInt(@intCast(rounding)))) {
        .short => return .{ @as(f64, @floatFromInt(shortVelocity(velocity[0]))) / 8000.0, @as(f64, @floatFromInt(shortVelocity(velocity[1]))) / 8000.0, @as(f64, @floatFromInt(shortVelocity(velocity[2]))) / 8000.0 },
        .packed_vector => {
            var buffer: [16]u8 = undefined;
            const rest = support.write_lpVec3(&buffer, .{ .x = velocity[0], .y = velocity[1], .z = velocity[2] }) catch unreachable;
            const read, _ = support.read_lpVec3(buffer[0 .. buffer.len - rest.len]) catch unreachable;
            return .{ read.x, read.y, read.z };
        },
    }
}

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
            /// How its clients move it between what they are sent. No default: every kind says.
            client: Client,
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
            /// Entity.hasImpulse: the server alone changed how it moves, as a hit, a knock or a
            /// push. A change of its data that changes how its clients step it is one too. It goes
            /// now, whatever its interval.
            impulse: bool = false,
            /// Entity.hurtMarked: its velocity goes now.
            hurt_marked: bool = false,
            /// Its clients step it against what they cannot know, as their own copies of the other
            /// entities it meets. Once it is no longer, it goes, where clients step it.
            uncertain: bool = false,
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
            /// Where clients step it: the tick every viewer was last put right, and whether its
            /// clients were stepping it against what they cannot know.
            corrected: u64 = 0,
            uncertain: bool = false,
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
        pub const Dependencies = struct { players: *const Players, sessions: *sessions.Service, packets: *packets.Packets, tracking: *Tracking, tracker: ?Tracking.TrackerId = null, pool: *entities.Pool, slots: usize = 0 };

        deps: Dependencies,
        /// What the kind supplies.
        spec: Spec,
        /// By slot, what its viewers were last sent: in the pool, not written out with it.
        views: entities.Array(View),
        /// Ticks this kind has sent.
        tick_count: u64 = 0,
        words: usize,
        /// Rows of players: spawned, removed, current, caught up, owed whole, one alone, and a
        /// class's viewers.
        rows: []usize,
        /// Players a delivery could not be queued for this entity, who then need it whole.
        missed: []usize,
        missed_any: bool = false,
        delivery: Delivery,
        /// Deltas of entities that go to the same players, admitted for all of them at once.
        /// Whatever goes out alone sends them first, so each player has its packets in order.
        batch: delivery_module.Batch(Queued),
        /// Whether the entity under way is being removed for some players this tick, whom row 1
        /// holds: they are sent nothing more of it, as their removal settles when the batch goes.
        leaving: bool = false,
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
        /// Where clients step its entities otherwise than the server: what each class of them has.
        models: ?Models,
        /// Where clients step its entities: whether each viewer's client stepped as the server
        /// did, and the entities whose clients stepped them against what they cannot know.
        drift: ?Drift,
        unsure: ?IndexSet,

        pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies, spec: Spec) !Self {
            if (config.visits) assert(spec.before != null);
            // A kind that visits is visited by its tracker's changes.
            if (config.visits and deps.tracker == null) return error.InvalidConfiguration;
            if (config.events == 0) return error.InvalidEventCapacity;
            const simulated = spec.client == .simulates;
            if (simulated) {
                // Visited only where something goes: no interval brings it back.
                if (!config.visits) return error.InvalidConfiguration;
                // Clients step every entity they have: one shown where the server does not tick it
                // would move on a client and stand still here.
                if (!deps.tracking.ticksWhereShown(deps.tracker.?, deps.players.config.simulation_distance)) return error.InvalidConfiguration;
            }
            const words = deps.tracking.row_words;
            const self: Self = .{
                .deps = deps,
                .spec = spec,
                .personal = try allocator.alloc(usize, deps.players.records.len),
                .views = try .init(allocator, deps.pool),
                .words = words,
                .rows = try allocator.alloc(usize, 7 * words),
                .missed = try allocator.alloc(usize, words),
                .delivery = try .init(allocator, deps.players, deps.packets, deps.sessions),
                .batch = try .init(allocator, deps.players, deps.packets, deps.sessions, words),
                .held = try allocator.alloc(Held, config.events),
                .held_rows = try allocator.alloc(usize, config.events * words),
                .tracing = config.trace_sends,
                .models = switch (spec.client) {
                    .simulates => |simulation| if (simulation.models) |models| try .init(allocator, models, .{ .players = deps.players, .tracking = deps.tracking, .pool = deps.pool, .slots = deps.slots, .roundings = roundings }) else null,
                    .unpredictable => null,
                },
                .drift = if (simulated) try .init(allocator, deps.players.records.len) else null,
                .unsure = if (simulated) try .init(allocator, @max(1, deps.slots)) else null,
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
            if (self.models) |*models| models.refresh();
            if (self.drift) |*drift| for (drift.check(self.deps.players, self.tick_count)) |moved| self.resync(moved);
            try self.sendHeld();
        }

        /// A viewer's client fell behind the server or ran ahead of it: what it computed of each
        /// entity is that many ticks off, and its tick counts in another phase. It is owed each
        /// whole, as its class has it.
        fn resync(self: *Self, moved: Drift.Shift) void {
            if (self.models) |*models| models.shift(moved.player, moved.ticks);
            const alone = self.row(5);
            @memset(alone, 0);
            put(alone, moved.player);
            for (0..self.views.len) |at| {
                const slot: u32 = @intCast(at);
                if (self.views.at(slot).id == 0 or !self.deps.tracking.known(slot).contains(moved.player)) continue;
                self.behind(slot, self.set(alone));
            }
            std.log.info("event=client_resync player={d} ticks={d}", .{ moved.player, moved.ticks });
        }

        /// A tick ends: what is queued goes.
        pub fn finish(self: *Self) !void {
            defer {
                self.tick_count += 1;
                if (self.models) |*models| models.advance();
            }
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
        pub fn collect(self: *Self) []const u32 {
            const visit = &self.visit.?;
            // Models judged apart from their entity this tick, or a viewer's class without one.
            if (self.models) |*models| for (models.owing.values()) |slot| visit.mark(@intCast(slot));
            // Those whose clients stepped them against what they cannot know: whether they still do.
            if (self.unsure) |*unsure| for (unsure.values()) |slot| visit.mark(@intCast(slot));
            var at = self.wheel[self.tick_count % wheel_ticks];
            while (at != none) {
                const due = self.dues.at(at);
                if (due.tick == self.tick_count) visit.mark(at);
                at = due.next;
            }
            return visit.collect(self.deps.tracking, self.deps.tracker.?, &self.spec, beforeBySpec);
        }

        fn beforeBySpec(spec: *const Spec, a: u32, b: u32) bool {
            return spec.before.?(spec.kind, a, b);
        }

        /// An entity visited: due again when its interval next falls, and owed while a viewer is.
        fn visited(self: *Self, slot: u32, view: *View, resting: bool) !void {
            const visit = &(self.visit orelse return);
            if (self.deps.tracking.stale(slot).any()) visit.owe(slot) else visit.settle(slot);
            // One no client has has nothing to send on its interval, and one at rest nothing new:
            // tracking's change, or its kind stirring it, brings it back.
            if (resting or !self.deps.tracking.known(slot).any()) {
                self.unschedule(slot);
                return;
            }
            // One its clients step has no interval: only its backstop is due.
            const next = switch (self.spec.client) {
                .simulates => @max(self.tick_count + 1, view.corrected + backstop_ticks),
                .unpredictable => |unpredictable| self.tick_count + unpredictable.update_interval - (self.tick_count -% view.started) % unpredictable.update_interval,
            };
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
            if (self.models) |*models| models.forget(slot);
            if (self.unsure) |*unsure| unsure.remove(slot);
        }

        /// Who has the entity and is not behind: who its deltas go to.
        fn current(self: *Self, slot: u32) bit_sets.Set {
            const known = self.deps.tracking.known(slot);
            const stale = self.deps.tracking.stale(slot);
            const words = self.row(2);
            for (words, 0..) |*word, at| word.* = known.wordAt(at) & ~stale.wordAt(at);
            if (self.leaving) for (words, self.row(1)) |*word, removing| {
                word.* &= ~removing;
            };
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

        /// Of `players`, those a delivery since the last note missed are behind on the entity in a
        /// slot. The rest of the misses go: they were of what `players` did not take.
        fn behindIn(self: *Self, slot: u32, players: []const usize) void {
            if (self.missed_any) {
                for (self.missed, players) |*word, taken| word.* &= taken;
                if (any(self.missed)) self.behind(slot, self.set(self.missed));
            }
            self.clearMissed();
        }

        fn clearMissed(self: *Self) void {
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
                view.corrected = self.tick_count;
            }
            // Removals first; spawns after its changes went to those who have it, so new viewers
            // are shown it as everyone now has it. Data written for each recipient apart pairs as
            // vanilla orders it, all of it first.
            const change: ?Tracking.Change = if (subject.changed) tracking.changed(slot).? else null;
            if (change) |value| {
                if (self.personalized()) try self.pairing(slot, self.spec.identity(self.spec.kind, slot), view, value, &body) else try self.leave(slot, value);
            }
            const known = self.current(slot);
            // Data known not to have changed is not compared.
            const now = subject.data orelse view.data;
            const changes: DataChanges = if (subject.data) |data| .between(view.data, data) else .{};
            switch (self.spec.client) {
                .simulates => try self.sendSimulated(slot, subject, &body, view, now, changes, known),
                .unpredictable => |unpredictable| {
                    // ServerEntity.sendChanges: on its interval, an impulse or changed data, its
                    // movement, velocity, data and head; a hurt entity's velocity at once.
                    if ((self.tick_count -% view.started) % unpredictable.update_interval == 0 or subject.impulse or changes.any()) {
                        try self.sendDue(slot, known, self.bodyOf(slot, &body), subject.impulse, unpredictable.track_deltas, view, now, changes);
                    }
                    if (subject.hurt_marked) {
                        try self.queue(slot, known, .{ .velocity = .{ .id = entities.Entities.networkOfSlot(slot), .velocity = self.bodyOf(slot, &body).velocity } });
                    }
                },
            }
            self.noteMissed(slot);
            if (change) |value| if (!self.personalized()) try self.join(slot, self.spec.identity(self.spec.kind, slot), view, value, &body);
            self.leaving = false;
            if (tracking.stale(slot).any()) try self.catchUp(slot, view, &body);
            if (self.visit != null) try self.visited(slot, view, subject.resting);
        }

        /// Where the entity in a slot is, asked of its kind once a tick at most.
        fn bodyOf(self: *Self, slot: u32, body: *?Body) Body {
            if (body.* == null) body.* = self.spec.body(self.spec.kind, slot);
            return body.*.?;
        }

        /// Every class of viewer a kind its clients step has.
        fn allClasses(self: *const Self) Classes {
            return if (self.models) |*models| models.all() else 1;
        }

        fn modelOfBody(body: Body) Model {
            return .{ .position = body.position, .velocity = body.velocity, .on_ground = body.on_ground };
        }

        fn exactOfModel(id: i32, model: Model, body: Body) Exact {
            return .{ .id = id, .position = model.position, .velocity = model.velocity, .yaw = body.yaw, .pitch = body.pitch, .on_ground = model.on_ground };
        }

        /// One its clients step: those of its classes that would look apart from it are put
        /// right, and every class is when the server alone changed it, when its clients were
        /// stepping it against what they cannot know and no longer are, or when its backstop is
        /// due; then its data, after what it changed. Kinds whose clients step them have no head
        /// of their own.
        fn sendSimulated(self: *Self, slot: u32, subject: Subject, body: *?Body, view: *View, now: Data, changes: DataChanges, known: bit_sets.Set) !void {
            const taken: Models.Owed = if (self.models) |*models| models.takeOwed(slot) else .{};
            var owed = taken.classes;
            const settled = view.uncertain and !subject.uncertain;
            view.uncertain = subject.uncertain;
            if (subject.uncertain) self.unsure.?.insert(slot) else self.unsure.?.remove(slot);
            const due = !subject.resting and self.tick_count -% view.corrected >= backstop_ticks;
            const forced = taken.forced or subject.impulse or subject.hurt_marked or settled or due;
            if (forced) owed = self.allClasses();
            if (owed != 0) try self.correct(slot, subject.id, known, self.bodyOf(slot, body), owed, forced, view);
            if (changes.any()) {
                try self.queue(slot, known, .{ .metadata = .{ .id = entities.Entities.networkOfSlot(slot), .data = now, .changes = changes } });
                view.data = now;
            }
        }

        /// How a class of clients is put right.
        const Fix = union(enum) {
            none,
            /// A motion packet: where it is stands, how it moves is the entity's, as the class's
            /// protocol rounds it.
            motion: [3]f64,
            /// The exact state, which is the entity to the bit.
            exact,
        };

        /// The cheapest packet that brings clients holding `held` within the tolerance of the
        /// entity, or `forced`, as near to it as a packet can. A class without a model, whose
        /// clients may hold anything, is sent it exactly.
        fn choose(held: ?Model, truth: Model, rounding: u8, forced: bool, tolerance: f64) Fix {
            const model = held orelse return .exact;
            const velocity = rounded(rounding, truth.velocity);
            if (forced) {
                if (model.on_ground != truth.on_ground or !std.mem.eql(u64, @ptrCast(&model.position), @ptrCast(&truth.position))) return .exact;
                return if (std.mem.eql(u64, @ptrCast(&model.velocity), @ptrCast(&velocity))) .none else .{ .motion = velocity };
            }
            if (!model.apart(truth, tolerance, false)) return .none;
            // Its motion alone only where it is already where the entity is, as after a landing its
            // client bounced from: a model off from its client would leave any place it is off by
            // until the next exact state, which puts both right.
            for (model.position, truth.position) |held_axis, actual| if (@abs(held_axis - actual) > motion_reach) return .exact;
            const moved: Model = .{ .position = model.position, .velocity = velocity, .on_ground = model.on_ground };
            if (model.on_ground == truth.on_ground and !moved.apart(truth, tolerance, false)) return .{ .motion = velocity };
            return .exact;
        }

        /// The viewers of the classes owed a correction are put right, those alike together: the
        /// same model and protocol rounding take the same packet. `forced`, every class is brought
        /// as near to the entity as a packet can.
        fn correct(self: *Self, slot: u32, id: u64, known: bit_sets.Set, body: Body, owed: Classes, forced: bool, view: *View) !void {
            const network = entities.Entities.networkOfSlot(slot);
            const truth = modelOfBody(body);
            const exact = exactOfModel(network, truth, body);
            if (forced) view.corrected = self.tick_count;
            const models = &(self.models orelse {
                // Its clients step it as the server does, from what they were sent.
                return self.queue(slot, known, .{ .exact = exact });
            });
            var left = owed & models.present(slot, known);
            while (left != 0) {
                const first: u8 = @ctz(left);
                const held = models.modelOf(slot, id, first);
                const rounding = models.roundingOf(first);
                var alike: Classes = 0;
                const viewers = self.row(6);
                @memset(viewers, 0);
                var each = left;
                while (each != 0) : (each &= each - 1) {
                    const class: u8 = @ctz(each);
                    if (models.roundingOf(class) != rounding) continue;
                    const other = models.modelOf(slot, id, class);
                    if ((other == null) != (held == null) or (other != null and !other.?.eql(held.?))) continue;
                    alike |= @as(Classes, 1) << @intCast(class);
                    const of_class = models.viewersOf(slot, class, known, self.row(5));
                    for (viewers, 0..) |*word, at| word.* |= of_class.wordAt(at);
                }
                left &= ~alike;
                switch (choose(held, truth, rounding, forced, models.config.tolerance)) {
                    .none => {},
                    .motion => |velocity| {
                        try self.queue(slot, self.set(viewers), .{ .velocity = .{ .id = network, .velocity = truth.velocity } });
                        try models.assign(slot, id, alike, .{ .position = held.?.position, .velocity = velocity, .on_ground = held.?.on_ground });
                    },
                    .exact => {
                        try self.queue(slot, self.set(viewers), .{ .exact = exact });
                        try models.assign(slot, id, alike, truth);
                    },
                }
            }
        }

        /// An entity gone from memory: only its removal is left, for whoever has it.
        pub fn gone(self: *Self, slot: u32) !void {
            const change = self.deps.tracking.changed(slot) orelse return;
            const removed = self.row(1);
            @memset(removed, 0);
            try self.remove(slot, change.remove, removed);
            self.deps.tracking.confirm(slot, self.deps.tracking.nobody(), self.set(removed));
            // Whom the removal missed still have it, and tracking offers it them again.
            self.clearMissed();
            // Its view goes once no client has it: until then it is what they were last sent.
            if (!self.deps.tracking.known(slot).any()) self.drop(slot);
        }

        /// The slot is let go: what is queued of it goes first, as it settles by its slot.
        pub fn forget(self: *Self, slot: u32) !void {
            try self.flushQueued();
            self.drop(slot);
        }

        /// Removals and spawns sent at once, as data written for each recipient apart needs.
        fn pairing(self: *Self, slot: u32, identity: Identity, view: *const View, change: Tracking.Change, body: *?Body) !void {
            const spawned = self.row(0);
            const removed = self.row(1);
            @memset(spawned, 0);
            @memset(removed, 0);
            try self.remove(slot, change.remove, removed);
            if (change.spawn.any()) switch (self.spec.client) {
                .unpredictable => try self.pair(slot, identity, view, change.spawn, spawned, null, false),
                .simulates => {
                    var groups = try self.spawnGroups(slot, view.id, change.spawn, self.bodyOf(slot, body));
                    while (try groups.next()) |group| try self.pair(slot, identity, view, group.viewers, spawned, group.shown, group.exact);
                },
            };
            self.deps.tracking.confirm(slot, self.set(spawned), self.set(removed));
            // One that took the spawn but missed what came with it has it, not whole: behind.
            self.behindIn(slot, spawned);
        }

        /// Removals, but not before an event a client is owed of it, in the batch: tracking hears
        /// who took each when the batch goes.
        fn leave(self: *Self, slot: u32, change: Tracking.Change) !void {
            const leaving = self.row(1);
            @memcpy(leaving, self.withoutOwed(slot, change.remove));
            if (!any(leaving)) return;
            try self.queueControl(slot, self.set(leaving), .remove, .{ .remove = entities.Entities.networkOfSlot(slot) });
            self.leaving = true;
        }

        /// Spawns in the batch, so many entities spawning for the same players go at once, each
        /// as its viewers were just sent it.
        fn join(self: *Self, slot: u32, identity: Identity, view: *const View, change: Tracking.Change, body: *?Body) !void {
            const spawned = self.row(0);
            for (spawned, 0..) |*word, at| word.* = change.spawn.wordAt(at);
            if (!any(spawned)) return;
            switch (self.spec.client) {
                .unpredictable => try self.queueSpawn(slot, identity, view, self.set(spawned), null, false),
                .simulates => {
                    var groups = try self.spawnGroups(slot, view.id, self.set(spawned), self.bodyOf(slot, body));
                    while (try groups.next()) |group| try self.queueSpawn(slot, identity, view, group.viewers, group.shown, group.exact);
                },
            }
        }

        /// The new viewers of one its clients step, by what each is to be sent. A class whose
        /// clients have it already is joined as they have it, which an exact state after the
        /// spawn gives; one that has none is sent it as it is, which the spawn alone gives but for
        /// its protocol's rounding of the velocity, and that is what the class then has. Without
        /// models it is sent as it is. Their tick counts begin now, so they are all in this tick's
        /// phase.
        const SpawnGroups = struct {
            sync: *Self,
            slot: u32,
            id: u64,
            recipients: bit_sets.Set,
            body: Body,
            set: u8 = 0,
            done: bool = false,

            const Group = struct { viewers: bit_sets.Set, shown: Exact, exact: bool };

            fn next(self: *SpawnGroups) !?Group {
                const sync = self.sync;
                const network = entities.Entities.networkOfSlot(self.slot);
                const truth = modelOfBody(self.body);
                const models = &(sync.models orelse {
                    if (self.done) return null;
                    self.done = true;
                    return .{ .viewers = self.recipients, .shown = exactOfModel(network, truth, self.body), .exact = false };
                });
                while (self.set < models.sets) {
                    const class = models.startingClass(self.set);
                    self.set += 1;
                    const viewers = models.viewersOf(self.slot, class, self.recipients, sync.row(6));
                    if (!viewers.any()) continue;
                    if (models.modelOf(self.slot, self.id, class)) |model| return .{ .viewers = viewers, .shown = exactOfModel(network, model, self.body), .exact = true };
                    // What the spawn gives: where it is, its velocity rounded, and in the air.
                    try models.assign(self.slot, self.id, @as(Classes, 1) << @intCast(class), .{ .position = truth.position, .velocity = rounded(models.roundingOf(class), truth.velocity), .on_ground = false });
                    return .{ .viewers = viewers, .shown = exactOfModel(network, truth, self.body), .exact = false };
                }
                return null;
            }
        };

        fn spawnGroups(self: *Self, slot: u32, id: u64, recipients: bit_sets.Set, body: Body) !SpawnGroups {
            if (self.models) |*models| try models.began(slot, recipients);
            return .{ .sync = self, .slot = slot, .id = id, .recipients = recipients, .body = body };
        }

        /// Of the players an entity leaves, those not owed an event of it first: row 4.
        fn withoutOwed(self: *Self, slot: u32, players: bit_sets.Set) []usize {
            const pending = self.row(4);
            for (pending, 0..) |*word, at| word.* = players.wordAt(at);
            for (0..self.held_count) |offset| {
                const at = (self.held_first + offset) % self.held.len;
                if (self.held[at].slot != slot) continue;
                for (pending, self.heldRow(at)) |*word, owed| word.* &= ~owed;
            }
            return pending;
        }

        fn remove(self: *Self, slot: u32, players: bit_sets.Set, removed: []usize) !void {
            const pending = self.withoutOwed(slot, players);
            try self.deliver(self.set(pending), .{ .remove = entities.Entities.networkOfSlot(slot) });
            self.delivery.markReached(removed);
        }

        /// ServerEntity.sendPairingData, batched: the entity as last sent and its data that
        /// differs from the defaults, one group each player takes whole or not at all.
        /// One its clients step is shown as `shown`, with that exact state after it when `exact`.
        fn queueSpawn(self: *Self, slot: u32, identity: Identity, view: *const View, recipients: bit_sets.Set, shown: ?Exact, exact_after: bool) !void {
            const id = entities.Entities.networkOfSlot(slot);
            const spawn = spawnOf(id, identity, view, shown);
            const changes = DataChanges.fromDefaults(view.data);
            if (self.tracing) self.traceSend(recipients, .{ .spawn = spawn });
            if (!changes.any() and !exact_after) return self.queueControl(slot, recipients, .spawn, .{ .spawn = spawn });
            if (self.tracing and changes.any()) self.traceSend(recipients, .{ .metadata = .{ .id = id, .data = view.data, .changes = changes } });
            const exact = shown orelse exactOf(id, view);
            if (self.tracing and exact_after) self.traceSend(recipients, .{ .exact = exact });
            const queued: Queued = .{ .slot = slot, .purpose = .spawn };
            const data = .{ id, view.data, changes, &self.spec, @as(?u128, null) };
            for (0..2) |_| {
                // The packets and the bundle around them.
                const count: usize = 1 + @as(usize, @intFromBool(changes.any())) + @intFromBool(exact_after);
                switch (try self.batch.prepare(recipients, count + 2, self, settleQueued)) {
                    .ready => {},
                    // No one to take it now: tracking offers it again next tick.
                    .nobody, .backpressured => return,
                }
                const sent = if (!exact_after)
                    try self.batch.sendGroup(queued, .{ .{ spawnLegacy, spawnPacked }, writeMetadata }, .{ .{spawn}, data }, &.{ 128, self.dataBytes(slot) })
                else if (changes.any())
                    try self.batch.sendGroup(queued, .{ .{ spawnLegacy, spawnPacked }, writeMetadata, writeExact }, .{ .{spawn}, data, .{exact} }, &.{ 128, self.dataBytes(slot), 128 })
                else
                    try self.batch.sendGroup(queued, .{ .{ spawnLegacy, spawnPacked }, writeExact }, .{ .{spawn}, .{exact} }, &.{ 128, 128 });
                if (sent) return;
                try self.flushQueued();
            }
        }

        /// The entity as last sent, to the bit but for its turn, which views keep packed.
        fn exactOf(id: i32, view: *const View) Exact {
            return .{ .id = id, .position = view.base, .velocity = view.velocity, .yaw = unpack(view.yaw), .pitch = unpack(view.pitch), .on_ground = view.was_on_ground };
        }

        /// ClientboundAddEntityPacket of the entity as last sent, or as `shown`.
        fn spawnOf(id: i32, identity: Identity, view: *const View, shown: ?Exact) Spawn {
            const exact = shown orelse return .{ .id = id, .uuid = identity.uuid, .kind = identity.entity_type, .data = identity.object_data, .position = view.base, .velocity = view.velocity, .yaw = view.yaw, .pitch = view.pitch, .head_yaw = view.head_yaw };
            return .{ .id = id, .uuid = identity.uuid, .kind = identity.entity_type, .data = identity.object_data, .position = exact.position, .velocity = exact.velocity, .yaw = packDegrees(exact.yaw), .pitch = packDegrees(exact.pitch), .head_yaw = view.head_yaw };
        }

        /// A spawn without data, or a removal, in the batch: tracking hears who took it when the
        /// batch goes, and offers it again next tick to whoever did not.
        fn queueControl(self: *Self, slot: u32, recipients: bit_sets.Set, purpose: Purpose, outgoing: Outgoing) !void {
            if (self.tracing and purpose == .remove) self.traceSend(recipients, outgoing);
            const queued: Queued = .{ .slot = slot, .purpose = purpose };
            for (0..2) |_| {
                switch (try self.batch.prepare(recipients, 1, self, settleQueued)) {
                    .ready => {},
                    .nobody, .backpressured => break,
                }
                const sent = switch (outgoing) {
                    .spawn => |value| try self.batch.send(queued, .{ spawnLegacy, spawnPacked }, .{value}, 128),
                    .remove => |value| try self.batch.send(queued, writeRemove, .{value}, 32),
                    else => unreachable,
                };
                if (sent) return;
                try self.flushQueued();
            }
            // A removal that could not go leaves its players with the entity, sent nothing more of it.
            if (purpose == .remove) {
                const owed = self.row(4);
                @memset(owed, 0);
                var each = recipients.iterator();
                while (each.next()) |player| if (self.deps.players.records[player].handle != null) put(owed, player);
                self.behind(slot, self.set(owed));
            }
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
        fn pair(self: *Self, slot: u32, identity: Identity, view: *const View, recipients: bit_sets.Set, spawned: []usize, shown: ?Exact, exact_after: bool) !void {
            const id = entities.Entities.networkOfSlot(slot);
            try self.deliver(recipients, .{ .spawn = spawnOf(id, identity, view, shown) });
            self.delivery.markReached(spawned);
            const changes = DataChanges.fromDefaults(view.data);
            if (changes.any()) try self.deliver(recipients, .{ .metadata = .{ .id = id, .data = view.data, .changes = changes } });
            if (exact_after) try self.deliver(recipients, .{ .exact = shown orelse exactOf(id, view) });
        }

        /// Players that missed a delta get the entity as last sent to everyone: where it is, its
        /// data and its head. One its clients step goes exactly, as each class has it, or as it is.
        fn catchUp(self: *Self, slot: u32, view: *const View, body: *?Body) !void {
            const stale = self.deps.tracking.stale(slot);
            if (!stale.any()) return;
            const id = entities.Entities.networkOfSlot(slot);
            const caught = self.row(3);
            @memset(caught, 0);
            if (self.spec.client == .unpredictable) {
                try self.deliver(stale, .{ .sync = .{ .id = id, .position = view.base, .velocity = view.velocity, .yaw = unpack(view.yaw), .pitch = unpack(view.pitch), .on_ground = view.was_on_ground } });
                self.delivery.markReached(caught);
            } else {
                const now = self.bodyOf(slot, body);
                // Removals queued go first, so those they reached are no longer behind, nor sent this.
                try self.flushQueued();
                if (self.models) |*models| {
                    var classes = models.present(slot, stale);
                    while (classes != 0) : (classes &= classes - 1) {
                        const class: u8 = @ctz(classes);
                        // As its class has it, unless that is not known or would look apart, as the
                        // correction it was owed reached none of its viewers: then as it is.
                        const held = models.modelOf(slot, view.id, class);
                        const model = if (held != null and !held.?.apart(modelOfBody(now), models.config.tolerance, false)) held.? else fresh: {
                            try models.assign(slot, view.id, @as(Classes, 1) << @intCast(class), modelOfBody(now));
                            break :fresh modelOfBody(now);
                        };
                        try self.deliver(models.viewersOf(slot, class, stale, self.row(6)), .{ .exact = exactOfModel(id, model, now) });
                        self.delivery.markReached(caught);
                    }
                } else {
                    try self.deliver(stale, .{ .exact = exactOfModel(id, modelOfBody(now), now) });
                    self.delivery.markReached(caught);
                }
            }
            const changes = DataChanges.fromDefaults(view.data);
            if (changes.any()) try self.deliver(self.set(caught), .{ .metadata = .{ .id = id, .data = view.data, .changes = changes } });
            try self.deliver(self.set(caught), .{ .head = .{ .id = id, .yaw = view.head_yaw } });
            // One that took where it is but missed its data or head is not caught up: still stale.
            for (caught, self.missed) |*word, missed| word.* &= ~missed;
            self.deps.tracking.caughtUp(slot, self.set(caught));
            self.clearMissed();
        }

        fn unpack(angle: i8) f32 {
            return @as(f32, @floatFromInt(angle)) * 360.0 / 256.0;
        }

        fn sendDue(self: *Self, slot: u32, known: bit_sets.Set, subject: Body, impulse: bool, track_deltas: bool, view: *View, now: Data, changes: DataChanges) !void {
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
            var velocity_due = false;
            if (impulse or track_deltas) {
                const difference: [3]f64 = .{ subject.velocity[0] - view.velocity[0], subject.velocity[1] - view.velocity[1], subject.velocity[2] - view.velocity[2] };
                const squared = difference[0] * difference[0] + difference[1] * difference[1] + difference[2] * difference[2];
                const length = subject.velocity[0] * subject.velocity[0] + subject.velocity[1] * subject.velocity[1] + subject.velocity[2] * subject.velocity[2];
                velocity_due = squared > 1.0e-7 or (squared > 0 and length == 0);
            }
            if (velocity_due) {
                view.velocity = subject.velocity;
                try self.queue(slot, known, .{ .velocity = .{ .id = id, .velocity = view.velocity } });
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
            // Whose it is, as the slot may be another's by the time it goes.
            self.held[at] = .{ .slot = slot, .id = self.views.at(slot).id, .event = event };
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
                // Its entity is gone and its slot another's: no one is owed it now.
                if (self.views.at(held.slot).id != held.id) {
                    @memset(owed, 0);
                    continue;
                }
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
            // Whom an event missed stay owed it in its row.
            self.clearMissed();
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
                .exact => |value| try delivery.send(recipients, writeExact, .{value}, 128),
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
                const queued: Queued = .{ .slot = slot, .purpose = .delta };
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
                    } else try self.batch.send(queued, writeMetadata, .{ value.id, value.data, value.changes, &self.spec, @as(?u128, null) }, self.dataBytes(slot)),
                    .velocity => |value| try self.batch.send(queued, .{ writeVelocityLegacy, writeVelocityPacked }, .{ value.id, value.velocity }, 64),
                    .sync => |value| try self.batch.send(queued, writeSync, .{ value.id, value.position, value.velocity, value.yaw, value.pitch, value.on_ground }, 128),
                    .exact => |value| try self.batch.send(queued, writeExact, .{value}, 128),
                    .relative => |value| try self.batch.send(queued, writeRelative, .{ value.id, value.delta, value.on_ground }, 32),
                    .look => |value| try self.batch.send(queued, writeLook, .{ value.id, value.yaw, value.pitch, value.on_ground }, 32),
                    .move_look => |value| try self.batch.send(queued, writeMoveLook, .{ value.id, value.delta, value.yaw, value.pitch, value.on_ground }, 32),
                    .head => |value| try self.batch.send(queued, writeHead, .{ value.id, value.yaw }, 32),
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

        /// What a packet the batch held is for, and of which entity.
        const Purpose = enum { delta, spawn, remove };
        const Queued = struct { slot: u32, purpose: Purpose };

        /// What a queued packet reached: whom a delta missed are behind; tracking hears who took a
        /// spawn or a removal.
        fn settleQueued(self: *Self, queued: Queued, accepted: bit_sets.Set, _: usize) !void {
            const tracking = self.deps.tracking;
            switch (queued.purpose) {
                .delta => {
                    const missed = self.batch.missedOf(accepted);
                    if (missed.any()) self.behind(queued.slot, missed);
                },
                .spawn => tracking.confirm(queued.slot, accepted, tracking.nobody()),
                .remove => {
                    tracking.confirm(queued.slot, tracking.nobody(), accepted);
                    // Those it missed still have the entity and were sent nothing more of it: behind.
                    const missed = self.batch.missedOf(accepted);
                    if (missed.any()) self.behind(queued.slot, missed);
                },
            }
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
            exact: Exact,
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
            const slot: u32 = entities.Entities.slotOfNetwork(id);
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
            const done = try packets.nested(.{writeEntries}).write(try metadata.begin(), Values{ .data = data, .changes = changes, .protocol = packet.layoutProtocol(), .spec = spec, .slot = entities.Entities.slotOfNetwork(id), .recipient = recipient, .registry = registry });
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

/// An entity's exact state: ClientboundTeleportEntityPacket, which sets where it is and how it
/// moves to the bit, and whether it is on the ground.
const Exact = struct { id: i32, position: [3]f64, velocity: [3]f64, yaw: f32, pitch: f32, on_ground: bool };

fn writeExact(packet: wire.play.toClient.packet_entity_teleport.Writer, exact: Exact) ![]u8 {
    const positioned = try (try (try (try packet.entityId(exact.id)).x(exact.position[0])).y(exact.position[1])).z(exact.position[2]);
    const moving = try (try (try positioned.dx(exact.velocity[0])).dy(exact.velocity[1])).dz(exact.velocity[2]);
    return (try (try (try (try moving.yaw(exact.yaw)).pitch(exact.pitch)).flags(.{})).onGround(exact.on_ground)).finish();
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
