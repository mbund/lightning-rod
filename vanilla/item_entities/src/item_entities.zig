//! Dropped items: each one's state beside its body, in memory for the columns near players,
//! and in the store, under its column, for the rest. Reads go by id and give copies, so what
//! one item's tick does to others never leaves it holding a stale pointer.

const game_data = @import("game_data");
const metrics = @import("metrics");
const std = @import("std");
const worlds = @import("worlds");
const lightning_rod = @import("lightning_rod");
const entities = @import("entities");
const inventories = @import("inventories");
const records = @import("records");
const chunks = @import("chunks");
const Items = @import("vanilla_items").items.Items;
const item_physics = @import("item_physics.zig");

const assert = std.debug.assert;

pub const ItemEntities = struct {
    pub const id = "minecraft:item_entities";

    pub const Configuration = struct {
        /// Whether resting items sleep. Off, every one ticks every tick, which sleeping must
        /// match.
        sleep: bool = true,
        /// The columns holding items, and the columns they tick in.
        columns: usize = 16384,
    };

    pub const Column = entities.Column;
    pub const kind = game_data.registry.entityId("minecraft:item").?;
    /// ItemEntity's size, 0.25 by 0.25.
    pub const shape: entities.Shape = .{ .kind = kind, .half_width = 0.125, .height = 0.25 };
    /// What lookups of items are after, among every kind in the space.
    pub const kinds: entities.Kinds = .of(&.{kind});

    pub fn columnOf(body: entities.State) Column {
        return entities.space.columnOf(body.world, body.position);
    }

    fn sectionOf(body: entities.State) i32 {
        return entities.space.coordinate(body.position[1]);
    }

    /// What the ticks of a sleeping item do to it, from how it was when it fell asleep: on the
    /// ground, still, with nothing around to change it. Its state stays as it was until someone
    /// reads it, which first brings it up to date.
    pub const Sleep = struct {
        /// Whether it sleeps; awake, it is only behind until next read.
        asleep: bool = true,
        /// A block edit near it asked it to wake on the next tick.
        asked: bool = false,
        /// The last tick its state is as of.
        since: u64 = 0,
        /// The last tick it ticks through: past it, it stopped ticking, as an item no player
        /// is near does.
        until: u64 = std.math.maxInt(u64),
        /// Its tick count and age when its state was last brought up to date, for knowing when
        /// it must wake without reading it.
        ticks: u32 = 0,
        age: i32 = 0,
        /// The block it rests on slows and steadies it: Entity.getBlockSpeedFactor and the
        /// friction ItemEntity.tick applies, both as the doubles they become.
        speed: f64 = 1,
        friction: f64 = 1,
        /// Its place in the tick order, which says whether the tick under way has reached it.
        sequence: u64 = 0,
        /// The section it rests in, for block edits to find it by.
        section: chunks.Section,
        /// Where it rests, for its merge checks to look around without waking it.
        position: [3]f64,
        /// Whether another item was in its merge box when last looked, and the columns' change
        /// counts then: while they stand, so does the answer.
        near: bool = false,
        near_revision: ?u64 = null,
        /// The tick it is due to look again at its turn, which tells its schedule entry from
        /// those it left behind.
        due: u64 = 0,
    };

    /// How far the item tick has gone, as it goes over the tick order.
    pub const Clock = struct {
        /// The tick under way, or done when not running.
        tick: u64 = 0,
        running: bool = false,
        /// The place of the last item ticked this tick, none yet at zero.
        last: u64 = 0,

        /// The last tick the item at a place in the tick order has had.
        pub fn through(self: Clock, sequence: u64) u64 {
            if (!self.running) return self.tick;
            if (sequence <= self.last) return self.tick;
            return self.tick - 1;
        }
    };

    pub const Dependencies = struct {
        record_workspaces: *records.Workspaces,
        metrics: *metrics.Registry,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
        worlds: *worlds.Worlds,
        storage: lightning_rod.storage.Space,
    };

    pub const Metadata = struct {
        pub const encoded_size = 61;
        pub fn encode(value: Metadata, output: []u8) void {
            assert(output.len == encoded_size);
            assert(value.pickup_delay <= 32767);
            var writer = std.Io.Writer.fixed(output);
            writer.writeByte(3) catch unreachable;
            writer.writeInt(u32, value.ticks, .little) catch unreachable;
            writer.writeInt(i32, value.age, .little) catch unreachable;
            writer.writeInt(u16, value.pickup_delay, .little) catch unreachable;
            writer.writeInt(i16, value.health, .little) catch unreachable;
            writer.writeByte(@intFromBool(value.on_ground)) catch unreachable;
            writer.writeByte(@intFromBool(value.owner != null)) catch unreachable;
            writer.writeInt(u128, value.owner orelse 0, .little) catch unreachable;
            writer.writeInt(u64, value.revision, .little) catch unreachable;
            writer.writeByte(@intFromBool(value.alive)) catch unreachable;
            writer.writeInt(i32, value.collector, .little) catch unreachable;
            writer.writeInt(u16, value.collected, .little) catch unreachable;
            writer.writeInt(u64, value.collection, .little) catch unreachable;
            writer.writeInt(i32, value.fire_ticks, .little) catch unreachable;
            writer.writeInt(i16, value.ticks_frozen, .little) catch unreachable;
            writer.writeByte(@backingInt(value.stuck)) catch unreachable;
            assert(writer.end == output.len);
        }

        ticks: u32 = 0,
        age: i32 = 0,
        pickup_delay: u16 = 10,
        health: i16 = 5,
        on_ground: bool = false,
        owner: ?u128 = null,
        revision: u64 = 1,
        alive: bool = true,
        collector: i32 = 0,
        collected: u16 = 0,
        collection: u64 = 0,
        /// Entity.remainingFireTicks: burning while above zero.
        fire_ticks: i32 = 0,
        /// Entity.ticksFrozen, which only powder snow raises for an item and nothing lowers.
        ticks_frozen: i16 = 0,
        /// Entity.stuckSpeedMultiplier, which the next move takes and clears.
        stuck: Stuck = .none,
    };

    /// What can hold back an item's next move: the blocks whose makeStuckInBlock reaches what
    /// is not living.
    pub const Stuck = enum(u8) {
        none,
        cobweb,
        powder_snow,

        pub fn multiplier(self: Stuck) [3]f64 {
            return switch (self) {
                .none => .{ 0, 0, 0 },
                .cobweb => .{ 0.25, @as(f32, 0.05), 0.25 },
                .powder_snow => .{ @as(f32, 0.9), 1.5, @as(f32, 0.9) },
            };
        }

        pub fn of(multiplier_value: [3]f64) Stuck {
            inline for (.{ Stuck.none, Stuck.cobweb, Stuck.powder_snow }) |each| {
                if (std.meta.eql(multiplier_value, each.multiplier())) return each;
            }
            unreachable;
        }
    };

    /// An item in memory: its state, and where its record in the store lies, which a move to
    /// another column leaves behind until the next save.
    pub const Item = struct {
        metadata: Metadata,
        stored: ?Column = null,
        dirty: bool = true,
        /// While its state is behind its ticks: how to bring it up to date. Its schedule is the
        /// space's rest; this is only what its replay needs.
        sleep: ?Sleep = null,
    };

    /// An item as it is: its body and its state, both copies.
    pub const View = struct { body: entities.State, metadata: Metadata };

    /// Told as an item leaves memory, for those who keep anything of it.
    pub const Leaving = struct {
        context: *anyopaque,
        function: *const fn (*anyopaque, entities.Id) void,
    };

    deps: Dependencies,
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Every item near players, gone ones not yet forgotten included.
    items: entities.BodyTable(Item),
    /// The slots of items replication must look at in full, and of those whose only change is
    /// their revision, as a resting item's motion changes every tick: replication need only
    /// note them until they are due to send. Room for every slot, so none goes unnoted.
    changes: lightning_rod.system.IndexSet,
    moved: lightning_rod.system.IndexSet,
    /// Items whose tick set Entity.hasImpulse: replication sends them that tick, whatever their
    /// interval, and takes the set.
    impulses: lightning_rod.system.IndexSet,
    /// Where every entity in memory is, the order they tick in, and the columns that tick,
    /// shared by every kind.
    places: *entities.Places,
    residency: entities.Residency,
    /// The items asleep, their ids side by side: what walks over sleepers each tick reads.
    asleep_ids: entities.IdSet,
    /// Room for the slots of sleepers due at once, which the space's wheel gives.
    due_slots: []u32,
    /// Room to copy ids into, for passes that change what they pass over.
    scratch: []entities.Id,
    clock: Clock = .{},
    sleep: bool,
    limits: [limit_slots]Limit = @splat(.{}),
    /// The store: each item kept under its column.
    table: records.Table,
    /// Items read, for measuring what each system looks at.
    reads: u64 = 0,
    leaving: ?Leaving = null,

    const record_prefix = 0x30;
    pub const record_bytes = entities.encoded_bytes + Metadata.encoded_size;

    /// An item as the store keeps it, for tools that write worlds: its key under its column,
    /// and its body and state.
    pub fn storeRecord(entity: entities.Id, body: entities.State, metadata: Metadata, value: *[record_bytes]u8) entities.durable.Key {
        entities.encode(body, value[0..entities.encoded_bytes]);
        metadata.encode(value[entities.encoded_bytes..]);
        return entities.durable.key(record_prefix, columnOf(body), entity);
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*ItemEntities {
        const self = try allocate(allocator, io, config, deps);
        try self.refuseOldRecords();
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*ItemEntities {
        const self = try allocator.create(ItemEntities);
        const bound = deps.entities.directory.capacity();
        self.* = .{
            .deps = deps,
            .allocator = allocator,
            .io = io,
            .changes = try .init(allocator, bound),
            .moved = try .init(allocator, bound),
            .impulses = try .init(allocator, bound),
            .items = try .init(allocator, deps.entities, kind),
            .asleep_ids = try .init(allocator, &deps.entities.pool, bound),
            .due_slots = try allocator.alloc(u32, bound),
            .scratch = try allocator.alloc(entities.Id, bound),
            .places = &deps.entities.places,
            .residency = try .init(allocator, config.columns),
            .sleep = config.sleep,
            .table = records.Table.init(deps.storage, deps.record_workspaces.resources),
        };
        try deps.entities.declare(.{ .kinds = kinds, .sleeps = true, .tracking_range = 6 * 16 });
        try self.places.watchStopping(kinds, .{ .context = self, .function = stoppedTicking });
        try deps.entities.addColumnHolder(.init(ItemEntities, self, columnLoaded, columnUnloaded));
        try self.items.register();
        return self;
    }

    /// Items kept before they were kept by column are refused, not converted: a world from
    /// before must lose its items to start.
    fn refuseOldRecords(self: *ItemEntities) !void {
        var after: [1]u8 = .{0};
        var cursor: records.ScanCursor = .{ .after = &after, .after_len = 0, .before = &.{record_prefix} };
        var key: [32]u8 = undefined;
        var found: [1]records.ScanKey = .{.{ .key = &key }};
        const result = try self.table.scanKeys(&cursor, &found);
        if (result.count > 0) return error.OldItemRecords;
    }

    /// An item stopped ticking: a sleeper stops where its last tick left it.
    fn stoppedTicking(context: *anyopaque, entity: entities.Id) void {
        const self: *ItemEntities = @ptrCast(@alignCast(context));
        if (self.sleepOf(entity)) |sleep| {
            if (sleep.asleep) {
                _ = self.places.space.unrest(self.deps.entities.directory.slotOf(entity).?);
                self.asleep_ids.remove(entity);
            }
            sleep.asleep = false;
            sleep.until = @min(sleep.until, self.clock.tick);
        }
    }

    pub const Spawn = struct {
        world: u32,
        position: [3]f64,
        velocity: [3]f64 = @splat(0),
        stack: inventories.Stack,
        metadata: Metadata = .{},
    };

    pub fn create(self: *ItemEntities, world: u32, position: [3]f64, velocity: [3]f64, stack: inventories.Stack) !entities.Id {
        var output: [1]entities.Id = undefined;
        try self.createMany(&.{.{ .world = world, .position = position, .velocity = velocity, .stack = stack }}, &output);
        return output[0];
    }

    pub fn createMany(self: *ItemEntities, requests: []const Spawn, output: []entities.Id) !void {
        if (requests.len != output.len or requests.len > 128) return error.WorkingSetTooLarge;
        var stacks: [128]inventories.Stack = undefined;
        var limits: [128]u16 = undefined;
        for (requests, stacks[0..requests.len]) |request, *stack| {
            if (self.deps.worlds.get(request.world) == null) return error.UnknownWorld;
            if (!request.metadata.alive or request.metadata.revision == 0 or request.metadata.pickup_delay > 32767) return error.InvalidArgument;
            for (request.position) |value| if (!std.math.isFinite(value) or @abs(value) > 30_000_000) return error.InvalidEntity;
            for (request.velocity) |value| if (!std.math.isFinite(value)) return error.InvalidEntity;
            stack.* = request.stack;
        }
        try self.deps.items.stackLimits(stacks[0..requests.len], limits[0..requests.len]);
        for (stacks[0..requests.len], limits[0..requests.len]) |stack, limit| if (stack.count == 0 or stack.count > limit) return error.InvalidStack;
        for (stacks[0..requests.len], limits[0..requests.len]) |stack, limit| self.limits[std.hash.Wyhash.hash(0, &stack.item) % limit_slots] = .{ .item = stack.item, .maximum = limit };
        errdefer self.deps.storage.fail();
        var edits: [128]inventories.Edit = undefined;
        const first = self.deps.entities.next_id;
        for (requests, 0..) |request, index| {
            const entity = first + index;
            const body: entities.State = .{ .uuid = @as(u128, 0x4c524954454d40008000000000000000) | entity, .kind = kind, .world = request.world, .position = request.position, .velocity = request.velocity };
            edits[index] = .{ .slot = slot(body), .revision = 0, .stack = request.stack };
        }
        const stored = try self.deps.inventories.editMany(edits[0..requests.len]);
        if (!stored) return error.Corrupt;
        for (requests, output, 0..) |request, *entity, index| {
            const body: entities.State = .{ .uuid = @as(u128, 0x4c524954454d40008000000000000000) | (first + index), .kind = kind, .world = request.world, .position = request.position, .velocity = request.velocity };
            if (!entities.valid(body)) return error.InvalidEntity;
            entity.* = try self.deps.entities.reserveIds(1);
            assert(entity.* == first + index);
            // Made in a ticking chunk, it ticks from the next tick on.
            try self.items.add(entity.*, body, .{ .metadata = request.metadata }, shape);
            try self.residency.hold(entities.space.columnOf(request.world, request.position));
            self.changes.insert(self.items.slotOf(entity.*).?);
        }
    }

    /// Stack limits by item, as merging asks again and again: a limit follows from the item's
    /// definition alone, so a remembered one is never wrong, and one forgotten is read again.
    const Limit = struct { item: inventories.ItemId = @splat(0), maximum: u16 = 0 };
    const limit_slots = 256;

    pub fn stackLimit(self: *ItemEntities, stack: inventories.Stack) !u16 {
        const slot_index = std.hash.Wyhash.hash(0, &stack.item) % limit_slots;
        const known = &self.limits[slot_index];
        if (known.maximum != 0 and std.mem.eql(u8, &known.item, &stack.item)) return known.maximum;
        const maximum = try self.deps.items.stackLimit(stack);
        assert(maximum > 0);
        known.* = .{ .item = stack.item, .maximum = maximum };
        return maximum;
    }

    /// Whether an item's stack is full, as merging passes over one that is.
    pub fn fullStack(self: *ItemEntities, body: entities.State) !bool {
        const held = (try self.deps.inventories.get(slot(body))).stack orelse return error.Corrupt;
        return held.count >= try self.stackLimit(held);
    }

    pub fn count(self: *const ItemEntities) usize {
        return self.items.count();
    }

    pub const Row = struct { id: entities.Id, metadata: Metadata };

    /// Every item near players and its state as last written, gone ones not yet forgotten
    /// included, in id order, for tests and tools to look over. Good until an item comes or
    /// goes.
    pub fn rows(self: *ItemEntities) Rows {
        return .{ .owner = self, .ids = self.items.ids(self.scratch) };
    }

    pub const Rows = struct {
        owner: *ItemEntities,
        ids: []const entities.Id,
        at: usize = 0,

        pub fn next(self: *Rows) !?Row {
            if (self.at == self.ids.len) return null;
            defer self.at += 1;
            const entity = self.ids[self.at];
            return .{ .id = entity, .metadata = (try self.owner.items.getById(entity)).?.metadata };
        }
    };

    /// An item near players as it is now, a sleeper first brought up to the tick it has had.
    pub fn read(self: *ItemEntities, entity: entities.Id) !?View {
        // Found by its id once: the rest by its slot.
        return try self.readAt(entity, self.items.slotOf(entity) orelse return null);
    }

    /// As `read`, for an item whose slot is known, as an entry of the space gives it.
    pub fn readAt(self: *ItemEntities, entity: entities.Id, at: u32) !View {
        self.reads += 1;
        try self.catchUpAt(entity, at);
        const item = self.items.ptr(at).*;
        const body = self.deps.entities.body(at) orelse return .{ .body = undefined, .metadata = item.metadata };
        return .{ .body = body.*, .metadata = item.metadata };
    }

    pub fn get(self: *ItemEntities, entity: entities.Id) !Metadata {
        const view = (try self.read(entity)) orelse return error.UnknownItemEntity;
        return view.metadata;
    }

    /// Writes an item's state. A write by anyone but catching up changes a sleeping item: it
    /// wakes. What changed decides what replication hears.
    pub fn put(self: *ItemEntities, entity: entities.Id, metadata: Metadata) !void {
        if (!self.items.contains(entity)) return error.UnknownItemEntity;
        try self.catchUp(entity);
        if (self.sleepOf(entity)) |sleep| if (sleep.asleep) try self.wake(entity, std.math.maxInt(u64));
        try self.writeQuietly(entity, metadata);
    }

    fn writeQuietly(self: *ItemEntities, entity: entities.Id, metadata: Metadata) !void {
        var item = (try self.items.getById(entity)).?;
        const previous = item.metadata;
        const Change = enum { none, revision, other };
        const change: Change = if (previous.on_ground != metadata.on_ground or previous.alive != metadata.alive or
            previous.collector != metadata.collector or previous.collected != metadata.collected or previous.collection != metadata.collection or
            // Replication sends the stack again with the flags when a fire is lit or goes out.
            (previous.fire_ticks > 0) != (metadata.fire_ticks > 0)) .other else if (previous.revision != metadata.revision) .revision else .none;
        switch (change) {
            .none => {},
            .revision => self.moved.insert(self.items.slotOf(entity).?),
            .other => self.changes.insert(self.items.slotOf(entity).?),
        }
        item.metadata = metadata;
        item.dirty = true;
        try self.items.putById(entity, item);
    }

    /// Brings an item's state up to the tick it has had, if it slept behind.
    fn catchUp(self: *ItemEntities, entity: entities.Id) !void {
        return self.catchUpAt(entity, self.items.slotOf(entity) orelse return);
    }

    /// As `catchUp`, for an item whose slot is known.
    fn catchUpAt(self: *ItemEntities, entity: entities.Id, at: u32) !void {
        const sleep = self.sleepAt(at) orelse return;
        const target = @min(self.clock.through(sleep.sequence), sleep.until);
        if (target != sleep.since) {
            const item = self.items.ptr(at);
            const body = self.deps.entities.body(at) orelse return error.Corrupt;
            var tick = sleep.since;
            while (tick < target) : (tick += 1) rest(body, &item.metadata, self.givenId(entity), sleep.speed, sleep.friction);
            item.dirty = true;
            sleep.since = target;
            sleep.ticks = item.metadata.ticks;
            sleep.age = item.metadata.age;
        }
        // Up to date and awake, it ticks for itself from here.
        if (!sleep.asleep) self.forgetSleep(at);
    }

    /// One tick of a resting item, as ItemTick and ItemPhysics.advance go with nothing to move
    /// it: its fall builds and stops, its slide wears off on its move ticks, and it ages.
    pub fn rest(body: *entities.State, metadata: *Metadata, given: u32, speed: f64, friction: f64) void {
        metadata.ticks +%= 1;
        if (metadata.pickup_delay > 0 and metadata.pickup_delay != 32767) metadata.pickup_delay -= 1;
        var next = body.*;
        next.velocity[1] -= 0.04;
        if (item_physics.movesOnPhase(metadata.ticks, given)) {
            // Its fall stops on the block: Block.onEntityLand.
            next.velocity[1] *= 0;
            next.velocity[0] *= speed;
            next.velocity[2] *= speed;
            next.velocity[0] *= friction;
            next.velocity[1] *= 0.98;
            next.velocity[2] *= friction;
        }
        // As ItemTick, a body that compares equal, -0.0 and 0.0 alike, keeps its bits and its
        // revision.
        if (!std.meta.eql(body.*, next)) {
            body.* = next;
            metadata.revision += 1;
        }
        if (metadata.alive and metadata.age != -32768) metadata.age += 1;
    }

    /// Every item in memory as it stands, sleepers as their ticks would have left them, read
    /// without writing anything, for a test to hold sleeping to nothing.
    /// In id order, each with the state's encoding as it was kept before, so digests compare
    /// across that change.
    pub fn digest(self: *ItemEntities) !u64 {
        const listed = self.rows();
        var hasher = std.hash.Wyhash.init(0);
        for (listed.ids) |entity| {
            var metadata = (try self.items.getById(entity)).?.metadata;
            var body = try self.deps.entities.getById(entity) orelse continue;
            if (self.sleepOf(entity)) |sleep| {
                var tick = sleep.since;
                while (tick < @min(self.clock.through(sleep.sequence), sleep.until)) : (tick += 1) rest(&body, &metadata, self.givenId(entity), sleep.speed, sleep.friction);
            }
            var encoded: [Metadata.encoded_size]u8 = undefined;
            metadata.encode(&encoded);
            encoded[0] = 2;
            hasher.update(std.mem.asBytes(&entity));
            hasher.update(&encoded);
            inline for (@typeInfo(entities.State).@"struct".field_names) |name| hasher.update(std.mem.asBytes(&@field(body, name)));
        }
        return hasher.final();
    }

    /// How many items sleep.
    pub fn asleepCount(self: *const ItemEntities) usize {
        return self.asleep_ids.count();
    }

    /// The sleep of the item in a slot, while its state is behind.
    fn sleepAt(self: *const ItemEntities, at: u32) ?*Sleep {
        const item = self.items.ptr(at);
        return if (item.sleep) |*sleep| sleep else null;
    }

    fn sleepOf(self: *const ItemEntities, entity: entities.Id) ?*Sleep {
        return self.sleepAt(self.items.slotOf(entity) orelse return null);
    }

    /// Up to date, or gone: nothing of a sleep is left.
    fn forgetSleep(self: *ItemEntities, at: u32) void {
        self.items.ptr(at).sleep = null;
        self.asleep_ids.remove(self.deps.entities.directory.entry(at).id);
    }

    pub fn asleep(self: *const ItemEntities, entity: entities.Id) ?Sleep {
        const sleep = self.sleepOf(entity) orelse return null;
        return if (sleep.asleep) sleep.* else null;
    }

    /// As `asleep`, for the item in a slot.
    pub fn asleepAt(self: *const ItemEntities, at: u32) ?Sleep {
        const sleep = self.sleepAt(at) orelse return null;
        return if (sleep.asleep) sleep.* else null;
    }

    /// Lets an item sleep from the end of the tick it just had: it leaves the awake order and
    /// looks again when due to merge or to despawn.
    pub fn lull(self: *ItemEntities, entity: entities.Id, sequence: u64, body: entities.State, metadata: Metadata, speed: f64, friction: f64) !void {
        const at = self.items.slotOf(entity).?;
        assert(self.sleepAt(at) == null);
        const section: chunks.Section = .{ .world = body.world, .x = columnOf(body).x, .y = sectionOf(body), .z = columnOf(body).z };
        self.items.ptr(at).sleep = .{ .since = self.clock.tick, .ticks = metadata.ticks, .age = metadata.age, .speed = speed, .friction = friction, .sequence = sequence, .section = section, .position = body.position };
        self.asleep_ids.insert(entity);
        self.places.order.sleep(entity);
        try self.schedule(entity, metadata.ticks, metadata.age);
    }

    /// The next tick a sleeper must be met at its turn: its next merge check, or its despawn,
    /// whichever comes first.
    fn schedule(self: *ItemEntities, entity: entities.Id, ticks: u32, age: i32) !void {
        const to_merge: u64 = 40 - @as(u64, ticks % 40);
        const to_despawn: u64 = @intCast(@max(1, 6000 - @as(i64, age)));
        const due_tick = self.clock.tick + @min(to_merge, to_despawn);
        self.sleepOf(entity).?.due = due_tick;
        // The space's wheel meets it then, as every kind's sleepers are met.
        try self.places.space.rest(self.deps.entities.directory.slotOf(entity).?, self.clock.tick, due_tick);
    }

    /// Before a tick's pass: sleepers due this tick are met at their turn, to look again. What
    /// they find near is what earlier turns this tick left there, so they look at their turn.
    pub fn wakeDue(self: *ItemEntities, tick: u64) !void {
        var found: usize = 0;
        self.places.space.takeDue(tick, kinds, self.due_slots, &found);
        for (self.due_slots[0..found]) |due| try self.places.order.wakeSlot(due);
    }

    /// A sleeper met at its turn with nothing to do but what its replay does: back to sleep,
    /// due again at its next look.
    pub fn sleepOn(self: *ItemEntities, entity: entities.Id, tick: u64) !void {
        const sleep = self.sleepOf(entity).?;
        const elapsed: u32 = @intCast(tick - sleep.since);
        self.places.order.sleep(entity);
        try self.schedule(entity, sleep.ticks +% elapsed, sleep.age +% @as(i32, @intCast(elapsed)));
    }

    /// The change counts of the items of the columns within `reach` of a place, summed: counts
    /// only grow, so the same sum is the same items there. What other kinds do leaves it.
    pub fn revisionAround(self: *const ItemEntities, world: u32, position: [3]f64, reach: f64) u64 {
        return self.places.space.revisionAround(world, position, reach, kinds);
    }

    /// Whether a sleeper has another item in its merge box, looked again only once something
    /// near it changed.
    pub fn sleeperNearOthers(self: *ItemEntities, entity: entities.Id) bool {
        const sleep = self.sleepOf(entity).?;
        const revision = self.revisionAround(sleep.section.world, sleep.position, 0.75);
        if (sleep.near_revision) |known| if (known == revision) return sleep.near;
        sleep.near = self.anyNear(entity, sleep.section.world, sleep.position);
        sleep.near_revision = revision;
        return sleep.near;
    }

    /// Whether any other item lies where an item at `position` would merge with it:
    /// ItemEntity.mergeWithNeighbours' box, its own grown by 0.5 sideways.
    pub fn anyNear(self: *ItemEntities, entity: entities.Id, world: u32, position: [3]f64) bool {
        const Other = struct {
            entity: entities.Id,
            position: [3]f64,
            fn accept(context: @This(), entry: entities.space.Entry) bool {
                const at = entry.position;
                return entry.id != context.entity and @abs(context.position[0] - at[0]) < 0.75 and @abs(context.position[1] - at[1]) < 0.25 and @abs(context.position[2] - at[2]) < 0.75;
            }
        };
        const reach: [3]f64 = .{ 0.75, 0.25, 0.75 };
        const within: entities.Feet = .{ .low = .{ position[0] - reach[0], position[1] - reach[1], position[2] - reach[2] }, .high = .{ position[0] + reach[0], position[1] + reach[1], position[2] + reach[2] } };
        return self.places.space.anyWithin(world, within, kinds, Other{ .entity = entity, .position = position }, Other.accept);
    }

    /// Wakes a sleeping item, to tick from now on; its state comes up to date when next read.
    /// One that stops ticking stops at `until`.
    pub fn wake(self: *ItemEntities, entity: entities.Id, until: u64) !void {
        const sleep = self.sleepOf(entity).?;
        assert(sleep.asleep);
        _ = self.places.space.unrest(self.deps.entities.directory.slotOf(entity).?);
        sleep.asleep = false;
        sleep.asked = false;
        self.asleep_ids.remove(entity);
        sleep.until = until;
        try self.places.order.wake(entity);
    }

    /// Asks a sleeper to wake at its next turn, as a block edit near it does.
    pub fn ask(self: *ItemEntities, entity: entities.Id) !void {
        const sleep = self.sleepOf(entity) orelse return;
        if (!sleep.asleep) return;
        sleep.asked = true;
        try self.places.order.wake(entity);
    }

    /// Moves an item's body: its place follows, and replication hears of a new place.
    pub fn move(self: *ItemEntities, entity: entities.Id, before: entities.State, after: entities.State) !void {
        if (self.deps.worlds.get(after.world) == null) return error.UnknownWorld;
        // Found once: the rest goes by its slot.
        const at = self.items.slotOf(entity) orelse return error.UnknownItemEntity;
        (self.deps.entities.body(at) orelse return error.UnknownItemEntity).* = after;
        self.items.ptr(at).dirty = true;
        if (before.world == after.world and std.meta.eql(before.position, after.position)) return;
        // Motion alone, as a resting item's every tick, comes to replication as a new revision.
        self.changes.insert(at);
        try self.places.move(at, after.world, after.position);
    }

    pub fn retire(self: *ItemEntities, entity: entities.Id, body: entities.State, metadata: *Metadata) !void {
        assert(metadata.alive);
        errdefer self.deps.storage.fail();
        try self.deps.inventories.retire(slot(body));
        // Gone, it neither sleeps nor needs catching up: whoever retired it read it first.
        if (self.items.slotOf(entity)) |at| self.forgetSleep(at);
        // Removed, it leaves its section at once, as vanilla's does: no lookup finds it.
        self.places.remove(entity);
        self.items.dropBodyById(entity);
        metadata.alive = false;
        metadata.revision += 1;
        try self.writeQuietly(entity, metadata.*);
    }

    /// Lets go of a gone item, once no client knows of it.
    pub fn forget(self: *ItemEntities, entity: entities.Id) !void {
        const at = self.items.slotOf(entity) orelse return error.UnknownItemEntity;
        self.changes.remove(at);
        self.moved.remove(at);
        self.impulses.remove(at);
        const item = try self.items.takeById(entity) orelse return error.UnknownItemEntity;
        assert(!item.metadata.alive);
        if (item.stored) |column| try self.table.putBatch(&.{.{ .key = &entities.durable.key(record_prefix, column, entity), .value = null }});
    }

    /// Keeps in memory the items of the columns near the centers, out to `radius`, and of the
    /// others named; the rest go to the store, and come back as they come near.
    pub fn refresh(self: *ItemEntities, centers: []const entities.residency.Center, radius: i32, also: anytype) !void {
        try self.residency.refresh(centers, radius, also, self, unloadColumn, loadColumn);
    }

    /// The loaded domain brought a column in: its items come back from the store.
    fn columnLoaded(self: *ItemEntities, column: entities.Column) anyerror!void {
        if (try self.residency.enter(column)) try self.loadColumn(column);
    }

    /// The loaded domain let a column go: its items go to the store.
    fn columnUnloaded(self: *ItemEntities, column: entities.Column) anyerror!void {
        if (!self.residency.holds(column)) return;
        try self.unloadColumn(column);
        _ = self.residency.leave(column);
    }

    fn unloadColumn(self: *ItemEntities, column: Column) anyerror!void {
        var batch: entities.durable.Batch(record_bytes) = .{ .table = self.table };
        // Copied, as each leaving changes the column.
        var leaving_count: usize = 0;
        var walk = self.places.space.entries(column, kinds);
        while (walk.next()) |entry| {
            self.scratch[leaving_count] = entry.id;
            leaving_count += 1;
        }
        for (self.scratch[0..leaving_count]) |entity| {
            try self.catchUp(entity);
            if (self.leaving) |hook| hook.function(hook.context, entity);
            const body = (try self.deps.entities.getById(entity)).?;
            const at = self.items.slotOf(entity).?;
            self.forgetSleep(at);
            self.changes.remove(at);
            self.moved.remove(at);
            const item = (try self.items.takeById(entity)).?;
            try save(&batch, entity, body, item);
            self.places.remove(entity);
        }
        try batch.flush();
    }

    fn loadColumn(self: *ItemEntities, column: Column) anyerror!void {
        var reader = entities.durable.ColumnReader(record_bytes).init(self.table, record_prefix, column);
        var found_rows: [16]entities.durable.ColumnReader(record_bytes).Row = undefined;
        while (true) {
            const found = try reader.next(&found_rows);
            if (found.len == 0) break;
            for (found) |row| {
                if (row.value.len != record_bytes) return error.Corrupt;
                const body = try entities.decode(row.value[0..entities.encoded_bytes]);
                const metadata = try decode(row.value[entities.encoded_bytes..]);
                if (self.items.contains(row.id)) return error.Corrupt;
                if (!entities.valid(body)) return error.InvalidEntity;
                try self.items.add(row.id, body, .{ .metadata = metadata, .stored = column, .dirty = false }, shape);
                self.changes.insert(self.items.slotOf(row.id).?);
            }
        }
    }

    /// An item's record put where it is now, and the one it left behind removed.
    fn save(batch: *entities.durable.Batch(record_bytes), entity: entities.Id, body: entities.State, item: Item) !void {
        const here = columnOf(body);
        if (item.stored) |was| if (!std.meta.eql(was, here)) try batch.delete(entities.durable.key(record_prefix, was, entity));
        var value: [record_bytes]u8 = undefined;
        entities.encode(body, value[0..entities.encoded_bytes]);
        item.metadata.encode(value[entities.encoded_bytes..]);
        try batch.put(entities.durable.key(record_prefix, here, entity), &value);
    }

    pub fn checkpoint(self: *ItemEntities, _: lightning_rod.storage.Space) !void {
        var batch: entities.durable.Batch(record_bytes) = .{ .table = self.table };
        const listed = self.rows();
        for (listed.ids) |entity| {
            try self.catchUp(entity);
            var item = (try self.items.getById(entity)).?;
            if (!item.metadata.alive) {
                // Gone but not yet forgotten: its record goes now, and nothing comes back.
                if (item.stored) |column| try batch.delete(entities.durable.key(record_prefix, column, entity));
                item.stored = null;
                try self.items.putById(entity, item);
                continue;
            }
            if (!item.dirty) continue;
            const body = (try self.deps.entities.getById(entity)).?;
            try save(&batch, entity, body, item);
            item.stored = columnOf(body);
            item.dirty = false;
            try self.items.putById(entity, item);
        }
        try batch.flush();
    }

    pub fn slot(body: entities.State) inventories.Slot {
        assert(body.kind == kind);
        return .{ .owner = body.uuid, .index = 0 };
    }

    /// The item an inventory owner is, when it is one: items own their slot by their uuid.
    pub fn entityOf(owner: u128) ?entities.Id {
        const prefix: u128 = 0x4c524954454d40008000000000000000;
        if (owner & ~@as(u128, std.math.maxInt(u63)) != prefix) return null;
        const entity: entities.Id = @truncate(owner & std.math.maxInt(u63));
        return if (entity == 0) null else entity;
    }

    /// The id clients know an item in memory by.
    pub fn networkId(self: *const ItemEntities, entity: entities.Id) i32 {
        return self.deps.entities.networkOf(entity).?;
    }

    /// The id it was given, the wire's: what vanilla's getId gives.
    pub fn givenId(self: *const ItemEntities, entity: entities.Id) u32 {
        return @intCast(self.networkId(entity));
    }
};

fn decode(bytes: []const u8) !ItemEntities.Metadata {
    if (bytes.len != ItemEntities.Metadata.encoded_size or bytes[0] != 3) return error.Corrupt;
    if (bytes[13] > 1 or bytes[14] > 1 or bytes[39] > 1) return error.Corrupt;
    if (bytes[60] > @backingInt(ItemEntities.Stuck.powder_snow)) return error.Corrupt;
    const value: ItemEntities.Metadata = .{
        .ticks = std.mem.readInt(u32, bytes[1..5], .little),
        .age = std.mem.readInt(i32, bytes[5..9], .little),
        .pickup_delay = std.mem.readInt(u16, bytes[9..11], .little),
        .health = std.mem.readInt(i16, bytes[11..13], .little),
        .on_ground = bytes[13] == 1,
        .owner = if (bytes[14] == 0) null else std.mem.readInt(u128, bytes[15..31], .little),
        .revision = std.mem.readInt(u64, bytes[31..39], .little),
        .alive = bytes[39] == 1,
        .collector = std.mem.readInt(i32, bytes[40..44], .little),
        .collected = std.mem.readInt(u16, bytes[44..46], .little),
        .collection = std.mem.readInt(u64, bytes[46..54], .little),
        .fire_ticks = std.mem.readInt(i32, bytes[54..58], .little),
        .ticks_frozen = std.mem.readInt(i16, bytes[58..60], .little),
        .stuck = @fromBackingInt(@intCast(bytes[60])),
    };
    if (value.pickup_delay > 32767 or value.revision == 0) return error.Corrupt;
    return value;
}

test "item records round trip" {
    const value: ItemEntities.Metadata = .{ .ticks = 7, .age = 40, .health = 3, .owner = 9, .revision = 5, .fire_ticks = 298, .ticks_frozen = 2, .stuck = .cobweb };
    var bytes: [ItemEntities.Metadata.encoded_size]u8 = undefined;
    ItemEntities.Metadata.encode(value, &bytes);
    try std.testing.expectEqual(value, try decode(&bytes));
    try std.testing.expectError(error.Corrupt, decode(bytes[0 .. bytes.len - 1]));
}
