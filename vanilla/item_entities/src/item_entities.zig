const game_data = @import("game_data");
const metrics = @import("metrics");
const std = @import("std");
const worlds = @import("worlds");
const lightning_rod = @import("lightning_rod");
const entities = @import("entities");
const inventories = @import("inventories");
const records = @import("records");
const chunks = @import("chunks");
const Players = @import("players").players.Players;
const Items = @import("vanilla_items").items.Items;
const spatial = @import("item_spatial.zig");
const item_physics = @import("item_physics.zig");

const assert = std.debug.assert;

pub const ItemEntities = struct {
    pub const id = "minecraft:item_entities";

    pub const Configuration = struct {
        cache_records: usize = 8192,
        /// Includes retired entities waiting for clients to accept their removal.
        maximum: usize = 1024,
        /// Whether resting items sleep. Off, every one ticks every tick, which sleeping must
        /// match.
        sleep: bool = true,
    };

    /// What the ticks of a sleeping item do to it, from how it was when it fell asleep: on the
    /// ground, still, with nothing around to change it. Its record stays as it was until someone
    /// reads it through these, which first brings it up to date.
    pub const Sleep = struct {
        /// The last tick its record is as of.
        since: u64 = 0,
        /// The last tick it ticks through: past it, it stopped ticking, as an item no player
        /// is near does.
        until: u64 = std.math.maxInt(u64),
        /// Its tick count and age when its record was last brought up to date, for knowing when
        /// it must wake without reading the record.
        ticks: u32 = 0,
        age: i32 = 0,
        /// The block it rests on slows and steadies it: Entity.getBlockSpeedFactor and the
        /// friction ItemEntity.tick applies, both as the doubles they become.
        speed: f64 = 1,
        friction: f64 = 1,
    };

    /// How far the item tick has gone, as it goes over items in a fixed order: from `start`
    /// up, then round from the lowest to before `start`.
    pub const Clock = struct {
        /// The tick under way, or done when not running.
        tick: u64 = 0,
        running: bool = false,
        start: entities.Id = 0,
        /// The last item ticked this tick, if any yet.
        last: entities.Id = 0,

        fn order(self: Clock, entity: entities.Id) u64 {
            return if (entity >= self.start) entity - self.start else entity + (std.math.maxInt(u32) - self.start);
        }

        /// The last tick an item has had.
        pub fn through(self: Clock, entity: entities.Id) u64 {
            if (!self.running) return self.tick;
            if (self.last != 0 and self.order(entity) <= self.order(self.last)) return self.tick;
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
        /// Version 2. Version 1 records, without fire, frost or what holds the item, are 54.
        pub const encoded_size = 61;
        const version_1_size = 54;
        pub fn encode(value: Metadata, output: []u8) void {
            assert(output.len == encoded_size);
            assert(value.pickup_delay <= 32767);
            var writer = std.Io.Writer.fixed(output);
            writer.writeByte(2) catch unreachable;
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
            writer.writeByte(@intFromEnum(value.stuck)) catch unreachable;
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
            inline for (.{ Stuck.none, Stuck.cobweb, Stuck.powder_snow }) |kind| {
                if (std.meta.eql(multiplier_value, kind.multiplier())) return kind;
            }
            unreachable;
        }
    };

    pub const Row = struct {
        id: entities.Id,
        metadata: Metadata,
    };

    pub const Cursor = struct {
        after: [9]u8 = undefined,
        after_len: usize = 0,
        more: bool = true,
        rows: [16]Row = undefined,
    };

    pub const Resident = spatial.Resident;

    const Region = struct {
        world: u32,
        x: i32,
        z: i32,

        fn less(_: void, a: Region, b: Region) bool {
            return a.world < b.world or (a.world == b.world and a.z < b.z);
        }
    };
    const Edge = struct {
        x: i64,
        region: usize,

        fn less(_: void, a: Edge, b: Edge) bool {
            return a.x < b.x;
        }
    };
    const SelectionWorkspace = struct {
        areas: []Region,
        edges: []Edge,
        active: lightning_rod.system.sparse_sets.Workspace,

        fn init(allocator: std.mem.Allocator, capacity: usize) !SelectionWorkspace {
            return .{
                .areas = try allocator.alloc(Region, capacity),
                .edges = try allocator.alloc(Edge, try std.math.mul(usize, capacity, 2)),
                .active = try lightning_rod.system.sparse_sets.Workspace.init(allocator, 1, capacity),
            };
        }
    };
    const Selection = struct { count: usize = 0, examined: usize = 0 };
    const StackProperties = struct { item: ?inventories.ItemId = null, maximum: u16 = 0, slots: [1]u16 = .{0}, dirty: u64 = 1, full: bool = false, watched: bool = false };
    deps: Dependencies,
    changes: lightning_rod.system.IndexSet,
    /// Slots asleep, and slots whose records are behind their ticks: asleep, or woken and not
    /// read since.
    sleeping: lightning_rod.system.IndexSet,
    behind: lightning_rod.system.IndexSet,
    sleeps: []Sleep,
    clock: Clock = .{},
    sleep: bool,
    /// Items whose only change since replication last looked is their revision, as a resting
    /// item's motion changes every tick, and the revision each slot holds now. Replication need
    /// only note them until they are due to send.
    moved: lightning_rod.system.IndexSet,
    revisions: []u64,
    active: lightning_rod.system.IndexSet,
    cache: records.Cache,
    residents: []Resident,
    stack_properties: []StackProperties,
    inventory_observer: *inventories.Inventories.Observer,
    ids: std.AutoHashMapUnmanaged(entities.Id, u32) = .empty,
    spatial: spatial.Index,
    free: []u32,
    free_count: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*ItemEntities {
        const self = try allocate(allocator, io, config, deps);
        var cursor: Cursor = .{};
        while (cursor.more) {
            const rows = try self.scan(&cursor);
            var begin: usize = 0;
            while (begin < rows.len) {
                const count = @min(rows.len - begin, deps.entities.cache.entries.len, deps.inventories.cache.entries.len);
                var ids: [16]entities.Id = undefined;
                var bodies: [16]entities.Entities.Lease = undefined;
                var states: [16]entities.State = undefined;
                var slots: [16]inventories.Slot = undefined;
                var contents: [16]inventories.Contents = undefined;
                var stacks: [16]inventories.Stack = undefined;
                var limits: [16]u16 = undefined;
                var alive: usize = 0;
                for (rows[begin..][0..count]) |row| {
                    if (!row.metadata.alive) {
                        try self.track(row.id, null);
                        continue;
                    }
                    ids[alive] = row.id;
                    alive += 1;
                }
                try deps.entities.acquireMany(ids[0..alive], bodies[0..alive]);
                defer for (bodies[0..alive]) |body| body.release();
                for (bodies[0..alive], states[0..alive], slots[0..alive]) |body, *state, *destination| {
                    state.* = (try body.read()) orelse return error.Corrupt;
                    destination.* = slot(state.*);
                }
                try deps.inventories.getMany(slots[0..alive], contents[0..alive]);
                for (contents[0..alive], stacks[0..alive]) |value, *stack| stack.* = value.stack orelse return error.Corrupt;
                try deps.items.stackLimits(stacks[0..alive], limits[0..alive]);
                for (ids[0..alive], states[0..alive], stacks[0..alive], limits[0..alive]) |entity, state, stack, limit| {
                    try self.track(entity, state);
                    const properties = &self.stack_properties[self.ids.get(entity).?];
                    properties.item = stack.item;
                    properties.maximum = limit;
                    properties.full = stack.count >= limit;
                    properties.dirty = 0;
                }
                begin += count;
            }
        }
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*ItemEntities {
        const table_resources = deps.record_workspaces.resources;
        if (deps.entities.cache.entries.len < 2 or config.cache_records < 4 or config.maximum == 0 or config.maximum > 65536) return error.InvalidConfiguration;

        const self = try allocator.create(ItemEntities);
        const residents = try allocator.alloc(Resident, config.maximum);
        @memset(residents, .{});
        const stack_properties = try allocator.alloc(StackProperties, config.maximum);
        @memset(stack_properties, .{});
        self.* = .{
            .deps = deps,
            .residents = residents,
            .stack_properties = stack_properties,
            .inventory_observer = try deps.inventories.observe(allocator, config.maximum),
            .changes = try lightning_rod.system.IndexSet.init(allocator, config.maximum),
            .moved = try lightning_rod.system.IndexSet.init(allocator, config.maximum),
            .sleeping = try lightning_rod.system.IndexSet.init(allocator, config.maximum),
            .behind = try lightning_rod.system.IndexSet.init(allocator, config.maximum),
            .sleeps = try allocator.alloc(Sleep, config.maximum),
            .sleep = config.sleep,
            .revisions = try allocator.alloc(u64, config.maximum),
            .active = try lightning_rod.system.IndexSet.init(allocator, config.maximum),
            .spatial = try spatial.Index.init(allocator, residents),
            .free = try allocator.alloc(u32, config.maximum),
            .free_count = config.maximum,
            .cache = try records.Cache.init(allocator, io, records.Table.init(deps.storage, table_resources), .{
                .metrics = deps.metrics,
                .metrics_namespace = "items.cache",
                .slots = config.cache_records,
                .key_bytes = 9,
                .value_bytes = Metadata.encoded_size,
                .scan_batch = 16,
            }),
        };
        for (self.free, 0..) |*free_slot, i| free_slot.* = @intCast(config.maximum - i - 1);
        try self.ids.ensureTotalCapacity(allocator, @intCast(config.maximum));
        return self;
    }

    pub fn canCreate(self: *const ItemEntities, count: usize) bool {
        assert(self.free_count <= self.residents.len);
        return count <= self.free_count;
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
        if (!self.canCreate(requests.len)) return error.ItemEntityCapacity;
        const maximum_id = std.math.maxInt(i32);
        if (requests.len != 0 and (self.deps.entities.next_id > maximum_id or requests.len - 1 > maximum_id - self.deps.entities.next_id)) return error.IdExhausted;
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
        errdefer self.deps.storage.fail();
        var begin: usize = 0;
        while (begin < requests.len) {
            const count = @min(128, self.cache.entries.len, self.deps.entities.cache.entries.len, self.deps.inventories.cache.entries.len, requests.len - begin);
            assert(count > 0);
            const batch = requests[begin..][0..count];
            const ids = output[begin..][0..count];
            var bodies: [128]entities.State = undefined;
            var edits: [128]inventories.Edit = undefined;
            var keys: [128][9]u8 = undefined;
            var slices: [128][]const u8 = undefined;
            var metadata: [128]records.Cache.Lease = undefined;
            for (batch, 0..) |request, index| {
                const entity = self.deps.entities.next_id + index;
                bodies[index] = .{ .uuid = @as(u128, 0x4c524954454d40008000000000000000) | entity, .kind = comptime game_data.registry.entityId("minecraft:item").?, .world = request.world, .position = request.position, .velocity = request.velocity };
                edits[index] = .{ .slot = slot(bodies[index]), .revision = 0, .stack = request.stack };
                keys[index] = keyFor(entity);
                slices[index] = &keys[index];
            }
            try self.deps.entities.createMany(bodies[0..count], ids);
            const stored = try self.deps.inventories.editMany(edits[0..count]);
            if (!stored) return error.Corrupt;
            try self.cache.acquireMany(slices[0..count], metadata[0..count]);
            defer for (metadata[0..count]) |lease| lease.release();
            for (metadata[0..count]) |lease| if (lease.read() != null) return error.Corrupt;
            for (batch, ids, bodies[0..count], metadata[0..count], limits[begin..][0..count]) |request, entity, body, lease, limit| {
                request.metadata.encode(lease.edit());
                lease.commit(Metadata.encoded_size);
                try self.track(entity, body);
                const properties = &self.stack_properties[self.ids.get(entity).?];
                properties.item = request.stack.item;
                properties.maximum = limit;
                properties.full = request.stack.count >= limit;
                properties.dirty = 0;
                assert(self.ids.contains(entity));
            }
            begin += count;
        }
    }

    pub const MetadataLease = struct {
        owner: *ItemEntities,
        record: records.Cache.Lease,
        index: u32,

        pub fn read(self: MetadataLease) !Metadata {
            return decode(self.record.read() orelse return error.UnknownItemEntity);
        }

        /// A write by anyone but catching up changes a sleeping item: it wakes.
        pub fn write(self: MetadataLease, metadata: Metadata) void {
            if (self.owner.sleeping.contains(self.index)) self.owner.wake(self.index, std.math.maxInt(u64));
            self.writeQuietly(metadata);
        }

        fn writeQuietly(self: MetadataLease, metadata: Metadata) void {
            const Change = enum { none, revision, other };
            const change: Change = if (self.record.read()) |bytes| changed: {
                const previous = decode(bytes) catch unreachable;
                if (previous.on_ground != metadata.on_ground or previous.alive != metadata.alive or
                    previous.collector != metadata.collector or previous.collected != metadata.collected or previous.collection != metadata.collection or
                    // Replication sends the stack again with the flags when a fire is lit or goes out.
                    (previous.fire_ticks > 0) != (metadata.fire_ticks > 0)) break :changed .other;
                break :changed if (previous.revision != metadata.revision) .revision else .none;
            } else .other;
            self.owner.revisions[self.index] = metadata.revision;
            switch (change) {
                .none => {},
                .revision => self.owner.moved.insert(self.index),
                .other => self.owner.changes.insert(self.index),
            }
            metadata.encode(self.record.edit());
            self.record.commit(Metadata.encoded_size);
        }

        pub fn release(self: MetadataLease) void {
            self.record.release();
        }
    };

    pub const Record = struct {
        id: entities.Id,
        metadata: MetadataLease,
        body: entities.Entities.Lease,

        pub fn read(self: Record) !Metadata {
            return self.metadata.read();
        }

        pub fn write(self: Record, metadata: Metadata) void {
            self.metadata.write(metadata);
        }

        pub fn release(self: Record) void {
            self.body.release();
            self.metadata.release();
        }
    };

    pub fn stackLimit(self: *ItemEntities, record: Record, stack: inventories.Stack) !u16 {
        assert(record.metadata.owner == self);
        const index = record.metadata.index;
        assert(self.residents[index].id == record.id);
        const properties = &self.stack_properties[index];
        if (properties.item == null or !std.mem.eql(u8, &properties.item.?, &stack.item)) {
            properties.item = stack.item;
            properties.maximum = try self.deps.items.stackLimit(stack);
        }
        assert(properties.maximum > 0);
        return properties.maximum;
    }

    pub fn fullStack(self: *const ItemEntities, record: Record) bool {
        assert(record.metadata.owner == self and self.residents[record.metadata.index].id == record.id);
        const properties = &self.stack_properties[record.metadata.index];
        assert(properties.watched);
        return properties.dirty == 0 and properties.full;
    }

    /// The stack must come from the current inventory contents, after any earlier merges.
    pub fn mergeLimit(self: *ItemEntities, record: Record, stack: inventories.Stack) !u16 {
        const maximum = try self.stackLimit(record, stack);
        const properties = &self.stack_properties[record.metadata.index];
        assert(properties.watched);
        properties.full = stack.count >= maximum;
        properties.dirty = 0;
        return maximum;
    }

    pub fn acquireMany(self: *ItemEntities, ids: []const entities.Id, output: []Record) !void {
        if (ids.len != output.len or ids.len > 16) return error.WorkingSetTooLarge;
        var metadata: [16]MetadataLease = undefined;
        var bodies: [16]entities.Entities.Lease = undefined;
        try self.acquireMetadataMany(ids, metadata[0..ids.len]);
        errdefer for (metadata[0..ids.len]) |lease| lease.release();
        try self.deps.entities.acquireMany(ids, bodies[0..ids.len]);
        for (ids, output, metadata[0..ids.len], bodies[0..ids.len]) |entity, *record, meta, body|
            record.* = .{ .id = entity, .metadata = meta, .body = body };
    }

    pub fn acquireMetadataMany(self: *ItemEntities, ids: []const entities.Id, output: []MetadataLease) !void {
        if (ids.len != output.len or ids.len > 16) return error.WorkingSetTooLarge;
        var keys: [16][9]u8 = undefined;
        var slices: [16][]const u8 = undefined;
        var metadata: [16]records.Cache.Lease = undefined;
        for (ids, 0..) |entity, i| {
            keys[i] = keyFor(entity);
            slices[i] = &keys[i];
        }
        try self.cache.acquireMany(slices[0..ids.len], metadata[0..ids.len]);
        for (output, metadata[0..ids.len], ids) |*lease, record, entity| lease.* = .{ .owner = self, .record = record, .index = self.ids.get(entity).? };
        errdefer for (output) |lease| lease.release();
        try self.catchUp(output);
    }

    /// Brings the records of items asleep, or behind, up to the tick they have had.
    fn catchUp(self: *ItemEntities, leases: []const MetadataLease) !void {
        if (self.behind.count == 0) return;
        var ids: [16]entities.Id = undefined;
        var at: [16]usize = undefined;
        var count: usize = 0;
        for (leases, 0..) |lease, index| {
            if (!self.behind.contains(lease.index)) continue;
            const sleep = &self.sleeps[lease.index];
            if (@min(self.clock.through(self.residents[lease.index].id), sleep.until) == sleep.since) {
                // Up to date: awake, it ticks for itself from here.
                if (!self.sleeping.contains(lease.index)) self.behind.remove(lease.index);
                continue;
            }
            ids[count] = self.residents[lease.index].id;
            at[count] = index;
            count += 1;
        }
        if (count == 0) return;
        var bodies: [16]entities.Entities.Lease = undefined;
        try self.deps.entities.acquireMany(ids[0..count], bodies[0..count]);
        defer for (bodies[0..count]) |body| body.release();
        for (ids[0..count], at[0..count], bodies[0..count]) |entity, index, body_lease| {
            const lease = leases[index];
            const sleep = &self.sleeps[lease.index];
            const target = @min(self.clock.through(entity), sleep.until);
            var metadata = try lease.read();
            var body = (try body_lease.read()) orelse return error.Corrupt;
            var tick = sleep.since;
            while (tick < target) : (tick += 1) rest(&body, &metadata, entity, sleep.speed, sleep.friction);
            try body_lease.write(body);
            self.residents[lease.index] = resident(entity, body);
            sleep.since = target;
            sleep.ticks = metadata.ticks;
            sleep.age = metadata.age;
            lease.writeQuietly(metadata);
            if (!self.sleeping.contains(lease.index)) self.behind.remove(lease.index);
        }
    }

    /// One tick of a resting item, as ItemTick and ItemPhysics.advance go with nothing to move
    /// it: its fall builds and stops, its slide wears off on its move ticks, and it ages.
    pub fn rest(body: *entities.State, metadata: *Metadata, entity: entities.Id, speed: f64, friction: f64) void {
        metadata.ticks +%= 1;
        if (metadata.pickup_delay > 0 and metadata.pickup_delay != 32767) metadata.pickup_delay -= 1;
        var next = body.*;
        next.velocity[1] -= 0.04;
        if (item_physics.movesOnPhase(metadata.ticks, @intCast(entity))) {
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

    /// Every item as it stands, sleepers as their ticks would have left them, read without
    /// writing anything, for a test to hold sleeping to ticking.
    pub fn digest(self: *ItemEntities) !u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (self.residents, 0..) |entry, index| {
            if (entry.id == 0) continue;
            const key = keyFor(entry.id);
            const lease = try self.cache.acquire(&key);
            defer lease.release();
            var metadata = decode(lease.read() orelse return error.UnknownItemEntity) catch return error.Corrupt;
            var bodies: [1]entities.Entities.Lease = undefined;
            try self.deps.entities.acquireMany(&.{entry.id}, &bodies);
            defer bodies[0].release();
            var body = (try bodies[0].read()) orelse continue;
            if (self.behind.contains(index)) {
                const sleep = self.sleeps[index];
                var tick = sleep.since;
                while (tick < @min(self.clock.through(entry.id), sleep.until)) : (tick += 1) rest(&body, &metadata, entry.id, sleep.speed, sleep.friction);
            }
            var encoded: [Metadata.encoded_size]u8 = undefined;
            metadata.encode(&encoded);
            hasher.update(&encoded);
            inline for (@typeInfo(entities.State).@"struct".field_names) |name| hasher.update(std.mem.asBytes(&@field(body, name)));
        }
        return hasher.final();
    }

    /// Lets an item sleep from the end of the tick it just had.
    pub fn lull(self: *ItemEntities, entity: entities.Id, metadata: Metadata, speed: f64, friction: f64) void {
        const index = self.ids.get(entity).?;
        assert(!self.sleeping.contains(index));
        self.sleeping.insert(index);
        self.behind.insert(index);
        self.sleeps[index] = .{ .since = self.clock.tick, .ticks = metadata.ticks, .age = metadata.age, .speed = speed, .friction = friction };
    }

    /// Wakes a sleeping item, to tick from now on; its record comes up to date when next read.
    /// One that stops ticking stops at `until`.
    pub fn wake(self: *ItemEntities, index: usize, until: u64) void {
        assert(self.sleeping.contains(index));
        self.sleeping.remove(index);
        self.sleeps[index].until = until;
    }

    /// Brings every sleeper's record up to date, as a checkpoint must save what their ticks did.
    fn catchUpAll(self: *ItemEntities) !void {
        // Each round brings some up to date, which leaves them out of the next.
        while (true) {
            var ids: [16]entities.Id = undefined;
            var count: usize = 0;
            for (self.behind.values()) |index| {
                const entity = self.residents[index].id;
                const sleep = self.sleeps[index];
                if (@min(self.clock.through(entity), sleep.until) == sleep.since) continue;
                ids[count] = entity;
                count += 1;
                if (count == ids.len) break;
            }
            if (count == 0) return;
            var leases: [16]MetadataLease = undefined;
            try self.acquireMetadataMany(ids[0..count], leases[0..count]);
            for (leases[0..count]) |lease| lease.release();
        }
    }

    pub const Iterator = struct {
        owner: *ItemEntities,
        ids: []const entities.Id,
        records: [16]Record = undefined,
        next_id: usize = 0,
        live: usize = 0,
        start: usize = 0,
        limit: usize = 16,

        pub fn next(self: *Iterator) !?[]Record {
            self.deinit();
            if (self.next_id == self.ids.len) return null;
            // Leave room for merge partners and spatial records while the batch is pinned.
            const count = @min(self.limit, self.records.len, self.owner.cache.entries.len / 4, self.owner.deps.entities.cache.entries.len / 2, self.ids.len - self.next_id);
            assert(count > 0);
            var ids: [16]entities.Id = undefined;
            for (ids[0..count], 0..) |*entity, i| entity.* = self.ids[(self.start + self.next_id + i) % self.ids.len];
            try self.owner.acquireMany(ids[0..count], self.records[0..count]);
            self.live = count;
            self.next_id += count;
            return self.records[0..count];
        }

        pub fn deinit(self: *Iterator) void {
            for (self.records[0..self.live]) |record| record.release();
            self.live = 0;
        }
    };

    pub fn iterate(self: *ItemEntities, ids: []const entities.Id) Iterator {
        return .{ .owner = self, .ids = ids };
    }

    pub fn get(self: *ItemEntities, entity: entities.Id) !Metadata {
        const key = keyFor(entity);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        return decode(lease.read() orelse return error.UnknownItemEntity);
    }

    pub fn put(self: *ItemEntities, entity: entities.Id, metadata: Metadata) !void {
        const key = keyFor(entity);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        self.changes.insert(self.ids.get(entity) orelse return error.UnknownItemEntity);
        metadata.encode(lease.edit());
        lease.commit(Metadata.encoded_size);
    }

    pub fn move(self: *ItemEntities, record: Record, before: entities.State, after: entities.State) !void {
        const entity = record.id;
        if (self.deps.worlds.get(after.world) == null) return error.UnknownWorld;

        errdefer self.deps.storage.fail();
        try record.body.write(after);
        const slot_index = self.ids.get(entity) orelse return error.UnknownItemEntity;
        // Motion alone, as a resting item's every tick, comes to replication as a new revision.
        if (before.world != after.world or !std.meta.eql(before.position, after.position)) self.changes.insert(slot_index);
        const previous = resident(entity, before);
        const next = resident(entity, after);
        assert(std.meta.eql(self.residents[slot_index], previous));
        if (previous.world != next.world or previous.x != next.x or previous.y != next.y or previous.z != next.z) {
            self.spatial.remove(slot_index);
            self.residents[slot_index] = next;
            self.spatial.insert(slot_index);
        } else self.residents[slot_index] = next;
    }

    pub fn retire(self: *ItemEntities, entity: entities.Id, body: entities.State, metadata: *Metadata) !void {
        assert(metadata.alive);
        errdefer self.deps.storage.fail();
        try self.deps.inventories.retire(slot(body));
        const properties = &self.stack_properties[self.ids.get(entity).?];
        assert(properties.watched);
        self.inventory_observer.unwatch(body.uuid);
        properties.watched = false;
        try self.deps.entities.remove(entity);
        const slot_index = self.ids.get(entity) orelse return error.UnknownItemEntity;
        // Gone, it neither sleeps nor needs catching up: whoever retired it read it first.
        self.sleeping.remove(slot_index);
        self.behind.remove(slot_index);
        self.spatial.remove(slot_index);
        self.residents[slot_index].alive = false;
        metadata.alive = false;
        metadata.revision += 1;
        try self.put(entity, metadata.*);
    }

    pub fn forget(self: *ItemEntities, entity: entities.Id) !void {
        const key = keyFor(entity);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        assert(!(try decode(lease.read().?)).alive);
        lease.remove();
        const slot_index = self.ids.get(entity) orelse return error.UnknownItemEntity;
        assert(!self.residents[slot_index].alive);
        const removed = self.ids.remove(entity);
        assert(removed);
        self.changes.remove(slot_index);
        self.active.remove(slot_index);
        self.residents[slot_index] = .{};
        self.free[self.free_count] = slot_index;
        self.free_count += 1;
    }

    pub const Query = struct {
        owner: *ItemEntities,
        players: *const Players,
        regions: []?Region,
        tracked: lightning_rod.system.IndexSet,
        workspace: SelectionWorkspace,
        values: []entities.Id,
        count: usize = 0,
        radius: i32 = 0,
        revision: ?u64 = null,
        rebuilds: metrics.Counter,
        regions_examined: metrics.Counter,

        pub fn init(allocator: std.mem.Allocator, owner: *ItemEntities, players: *const Players) !Query {
            assert(players.records.len > 0);
            const regions = try allocator.alloc(?Region, players.records.len);
            errdefer allocator.free(regions);
            @memset(regions, null);
            const values = try allocator.alloc(entities.Id, owner.residents.len);
            errdefer allocator.free(values);
            return .{
                .owner = owner,
                .players = players,
                .regions = regions,
                .tracked = try lightning_rod.system.IndexSet.init(allocator, regions.len),
                .workspace = try SelectionWorkspace.init(allocator, regions.len),
                .values = values,
                .rebuilds = try owner.deps.metrics.counter(.{ .name = "items.query.rebuilds", .description = "Rebuild item selection after spatial or player region changes" }),
                .regions_examined = try owner.deps.metrics.counter(.{ .name = "items.query.regions", .description = "Active item query regions examined across X strips" }),
            };
        }

        /// IDs belong to this query until its next read. Other queries cannot invalidate them.
        pub fn read(self: *Query, radius: i32) []const entities.Id {
            assert(radius >= 0 and self.regions.len == self.players.records.len);
            assert(self.values.len == self.owner.residents.len);
            var changed = self.revision == null or self.revision.? != self.owner.spatial.revision or self.radius != radius;
            for (self.players.activeSlots()) |index| self.tracked.insert(index);
            var at: usize = 0;
            while (at < self.tracked.count) {
                const index = self.tracked.indices[at];
                const player = self.players.records[index];
                const previous = &self.regions[index];
                if (player.handle == null) self.tracked.remove(index) else at += 1;
                const region: ?Region = if (player.inWorld()) .{
                    .world = player.world,
                    .x = @intFromFloat(@floor(player.position.x / 16)),
                    .z = @intFromFloat(@floor(player.position.z / 16)),
                } else null;
                changed = changed or !std.meta.eql(previous.*, region);
                previous.* = region;
            }
            if (changed) {
                for (self.tracked.values(), 0..) |index, position| self.workspace.areas[position] = self.regions[index].?;
                const selection = self.owner.selectAreas(&self.workspace, self.tracked.count, radius, self.values);
                self.count = selection.count;
                self.regions_examined.add(selection.examined);
                self.revision = self.owner.spatial.revision;
                self.radius = radius;
                self.rebuilds.add(1);
            }
            assert(self.count <= self.values.len and self.revision.? == self.owner.spatial.revision);
            return self.values[0..self.count];
        }
    };

    fn select(self: *ItemEntities, workspace: *SelectionWorkspace, regions: []const ?Region, radius: i32, output: []entities.Id) Selection {
        assert(radius >= 0 and output.len >= self.residents.len and regions.len <= workspace.areas.len);
        if (self.spatial.count == 0) return .{};
        const areas = workspace.areas;
        var populated: usize = 0;
        for (regions) |region| if (region) |area| {
            areas[populated] = area;
            populated += 1;
        };
        return self.selectAreas(workspace, populated, radius, output);
    }

    fn selectAreas(self: *ItemEntities, workspace: *SelectionWorkspace, populated: usize, radius: i32, output: []entities.Id) Selection {
        assert(radius >= 0 and populated <= workspace.areas.len and output.len >= self.residents.len);
        if (self.spatial.count == 0) return .{};
        const areas = workspace.areas;
        std.mem.sort(Region, areas[0..populated], {}, Region.less);
        var count: usize = 0;
        var examined: usize = 0;
        var begin: usize = 0;
        while (begin < populated) {
            var end = begin + 1;
            while (end < populated and areas[end].world == areas[begin].world) end += 1;
            const world = areas[begin].world;
            const group = areas[begin..end];
            const edges = workspace.edges;
            for (group, 0..) |area, index| {
                edges[index * 2] = .{ .x = @max(std.math.minInt(i32), @as(i64, area.x) - radius), .region = @intCast(index) };
                edges[index * 2 + 1] = .{ .x = @min(std.math.maxInt(i32), @as(i64, area.x) + radius) + 1, .region = @intCast(index) };
            }
            std.mem.sort(Edge, edges[0 .. group.len * 2], {}, Edge.less);
            const active = workspace.active.row(0);
            active.clear();
            var cursor: usize = 0;
            while (cursor < group.len * 2) {
                const left = edges[cursor].x;
                // Each region toggles at its inclusive start and exclusive end.
                while (cursor < group.len * 2 and edges[cursor].x == left) : (cursor += 1)
                    active.toggle(edges[cursor].region);
                if (cursor == group.len * 2) break;
                const right = edges[cursor].x;
                assert(left < right);
                var remaining = active.view().iterator();
                examined += active.view().count();
                var interval: ?[2]i64 = null;
                while (true) {
                    const next: ?[2]i64 = if (remaining.next()) |index| range: {
                        assert(index < group.len);
                        const area = group[index];
                        break :range .{
                            @max(std.math.minInt(i32), @as(i64, area.z) - radius),
                            @min(std.math.maxInt(i32), @as(i64, area.z) + radius),
                        };
                    } else null;
                    if (interval) |*previous| {
                        if (next) |range| if (range[0] <= previous[1] + 1) {
                            previous[1] = @max(previous[1], range[1]);
                            continue;
                        };
                        var candidates = self.spatial.rectangle(world, .{ @intCast(left), @intCast(previous[0]) }, .{ @intCast(right - 1), @intCast(previous[1]) });
                        while (candidates.next()) |slot_index| {
                            assert(count < output.len);
                            output[count] = self.residents[slot_index].id;
                            count += 1;
                        }
                    }
                    interval = next;
                    if (next == null) break;
                }
            }
            assert(!active.view().any());
            begin = end;
        }
        // Stable entity order makes scheduling independent of player query order.
        std.mem.sort(entities.Id, output[0..count], {}, std.sort.asc(entities.Id));
        return .{ .count = count, .examined = examined };
    }

    pub fn selectColumns(self: *const ItemEntities, world: u32, minimum: [2]i32, maximum: [2]i32, selected: *lightning_rod.system.IndexSet) void {
        assert(minimum[0] <= maximum[0] and minimum[1] <= maximum[1]);
        assert(selected.positions.len == self.residents.len);
        var candidates = self.spatial.rectangle(world, minimum, maximum);
        while (candidates.next()) |index| selected.insert(index);
    }

    /// Enumerates live residents in ascending ID order without touching storage.
    /// Resume after the last returned ID so movement and retirement cannot invalidate the cursor.
    pub fn inSection(self: *ItemEntities, section: chunks.Section, after: *entities.Id, output: []entities.Id) []const entities.Id {
        assert(output.len > 0);
        var at = self.spatial.lowerBound(.{ .world = section.world, .x = section.x, .z = section.z, .y = section.y, .id = after.* });
        var count: usize = 0;
        while (at) |slot_index| : (at = self.spatial.next(slot_index)) {
            if (count == output.len) break;
            const entry = self.residents[slot_index];
            if (entry.world != section.world or entry.x != section.x or entry.z != section.z or entry.y != section.y) break;
            assert(entry.alive);
            if (entry.id <= after.*) continue;
            output[count] = entry.id;
            count += 1;
            after.* = entry.id;
        }
        return output[0..count];
    }

    fn track(self: *ItemEntities, entity: entities.Id, body: ?entities.State) !void {
        if (self.free_count == 0) return error.ItemEntityCapacity;
        self.free_count -= 1;
        const slot_index = self.free[self.free_count];
        assert(!self.stack_properties[slot_index].watched);
        self.stack_properties[slot_index] = .{};
        self.residents[slot_index] = if (body) |value| resident(entity, value) else .{ .id = entity };
        assert(!self.sleeping.contains(slot_index) and !self.behind.contains(slot_index));
        self.changes.insert(slot_index);
        self.active.insert(slot_index);
        self.ids.putAssumeCapacityNoClobber(entity, slot_index);
        if (body) |value| {
            const properties = &self.stack_properties[slot_index];
            properties.slots[0] = slot(value).index;
            self.inventory_observer.watch(value.uuid, &properties.slots, .{ .dirty = &properties.dirty });
            properties.watched = true;
            self.spatial.insert(slot_index);
        }
    }

    fn resident(entity: entities.Id, body: entities.State) Resident {
        return .{ .id = entity, .world = body.world, .x = @intFromFloat(@floor(body.position[0] / 16)), .z = @intFromFloat(@floor(body.position[2] / 16)), .y = @intFromFloat(@floor(body.position[1] / 16)), .alive = true, .position = .{ body.position[0], body.position[2] } };
    }

    pub fn scan(self: *ItemEntities, cursor: *Cursor) ![]const Row {
        var entries: [16]records.BorrowedEntry = undefined;

        var position: records.ScanCursor = .{ .after = &cursor.after, .after_len = cursor.after_len };
        const batch = try self.cache.scanBorrowed(&position, &entries);
        cursor.after_len = position.after_len;
        cursor.more = batch.more;
        var count: usize = 0;

        for (entries[0..batch.count]) |entry| {
            if (entry.key.len != 9 or entry.key[0] != 0) return error.Corrupt;
            cursor.rows[count] = .{ .id = std.mem.readInt(u64, entry.key[1..9], .big), .metadata = try decode(entry.value) };
            count += 1;
        }

        return cursor.rows[0..count];
    }

    pub fn checkpoint(self: *ItemEntities, _: lightning_rod.storage.Space) !void {
        try self.catchUpAll();
        try self.cache.flush();
    }

    pub fn slot(body: entities.State) inventories.Slot {
        assert(body.kind == comptime game_data.registry.entityId("minecraft:item").?);
        return .{ .owner = body.uuid, .index = 0 };
    }

    pub fn networkId(entity: entities.Id) i32 {
        assert(entity > 0 and entity <= std.math.maxInt(i32));
        return -@as(i32, @intCast(entity));
    }
};

fn keyFor(entity: entities.Id) [9]u8 {
    assert(entity > 0);
    var key: [9]u8 = undefined;
    key[0] = 0;
    std.mem.writeInt(u64, key[1..9], entity, .big);
    return key;
}

fn decode(bytes: []const u8) !ItemEntities.Metadata {
    const version_1 = bytes.len == ItemEntities.Metadata.version_1_size and bytes[0] == 1;
    const version_2 = bytes.len == ItemEntities.Metadata.encoded_size and bytes[0] == 2;
    if (!version_1 and !version_2) return error.Corrupt;
    if (bytes[13] > 1 or bytes[14] > 1 or bytes[39] > 1) return error.Corrupt;
    if (version_2 and bytes[60] > @intFromEnum(ItemEntities.Stuck.powder_snow)) return error.Corrupt;

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
        .fire_ticks = if (version_2) std.mem.readInt(i32, bytes[54..58], .little) else 0,
        .ticks_frozen = if (version_2) std.mem.readInt(i16, bytes[58..60], .little) else 0,
        .stuck = if (version_2) @enumFromInt(bytes[60]) else .none,
    };
    if (value.pickup_delay > 32767 or value.revision == 0) return error.Corrupt;
    return value;
}

test "item query union matches direct selection across worlds boundaries and player order" {
    var residents: [257]ItemEntities.Resident = undefined;
    var random = std.Random.DefaultPrng.init(20261025);
    for (&residents, 0..) |*entry, at| entry.* = .{
        .id = at + 1,
        .world = random.random().uintLessThan(u32, 3),
        .x = random.random().intRangeAtMost(i32, -20, 20),
        .z = random.random().intRangeAtMost(i32, -20, 20),
        .y = 4,
        .alive = true,
    };
    residents[0].x = std.math.minInt(i32);
    residents[0].z = std.math.minInt(i32);
    residents[1].x = std.math.maxInt(i32);
    residents[1].z = std.math.maxInt(i32);
    var memory: [128 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    var owner: ItemEntities = undefined;
    owner.residents = &residents;
    owner.spatial = try spatial.Index.init(allocator.allocator(), &residents);
    for (0..residents.len) |at| owner.spatial.insert(@intCast(at));
    var workspace = try ItemEntities.SelectionWorkspace.init(allocator.allocator(), 513);
    const assigned = allocator.end_index;
    for (0..64) |trial| {
        var regions: [513]?ItemEntities.Region = undefined;
        for (&regions) |*region| region.* = if (random.random().boolean()) .{
            .world = random.random().uintLessThan(u32, 4),
            .x = random.random().intRangeAtMost(i32, -24, 24),
            .z = random.random().intRangeAtMost(i32, -24, 24),
        } else null;
        regions[0] = .{ .world = residents[0].world, .x = residents[0].x, .z = residents[0].z };
        regions[1] = .{ .world = residents[1].world, .x = residents[1].x, .z = residents[1].z };
        const radii = [_]i32{ 0, 1, 8, std.math.maxInt(i32) };
        const radius = radii[trial % radii.len];
        var expected: [257]entities.Id = undefined;
        var count: usize = 0;
        for (residents) |entry| {
            const selected = for (regions) |region| {
                const area = region orelse continue;
                if (entry.world == area.world and @abs(@as(i64, entry.x) - area.x) <= radius and @abs(@as(i64, entry.z) - area.z) <= radius) break true;
            } else false;
            if (selected) {
                expected[count] = entry.id;
                count += 1;
            }
        }
        var output: [257]entities.Id = undefined;
        const selected = owner.select(&workspace, &regions, radius, &output);
        try std.testing.expectEqualSlices(entities.Id, expected[0..count], output[0..selected.count]);
        std.mem.reverse(?ItemEntities.Region, &regions);
        const reversed = owner.select(&workspace, &regions, radius, &output);
        try std.testing.expectEqualSlices(entities.Id, expected[0..count], output[0..reversed.count]);
    }
    var absent: [513]?ItemEntities.Region = @splat(null);
    var output: [257]entities.Id = undefined;
    try std.testing.expectEqual(@as(usize, 0), owner.select(&workspace, &absent, 8, &output).count);
    try std.testing.expectEqual(assigned, allocator.end_index);
}

pub fn benchmarkQueryPlanning() !void {
    const columns = 8;
    const radius = 8;
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &output_buffer);
    try output.interface.writeAll("players | crowded | active region examinations | matching items | unchanged examinations\n");
    for ([_]usize{ 16, 64, 513 }) |count| for ([_]bool{ false, true }) |crowded| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 8 });
        defer registry.deinit();
        var residents = [_]ItemEntities.Resident{.{ .id = 1, .world = 0, .alive = true }};
        var owner: ItemEntities = undefined;
        owner.residents = &residents;
        owner.deps.metrics = &registry;
        owner.spatial = try spatial.Index.init(allocator, &residents);
        owner.spatial.insert(0);
        var rows: [513]Players.Player = undefined;
        for (rows[0..count], 0..) |*row, index| row.* = .{
            .handle = .{ .index = @intCast(index), .generation = 1 },
            .world = 0,
            .position = .{
                .x = @as(f64, @floatFromInt(if (crowded) @as(i32, @intCast(index % columns)) - 4 else @as(i32, @intCast(index * 128)))) * 16 + 0.5,
                .y = 65,
                .z = @as(f64, @floatFromInt(if (crowded) @as(i32, @intCast(index / columns)) - 4 else @as(i32, 0))) * 16 + 0.5,
            },
        };
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = rows[0..count], .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        var query = try ItemEntities.Query.init(allocator, &owner, &players);
        failing.fail_index = failing.alloc_index;
        const before = query.regions_examined.value();
        try std.testing.expectEqualSlices(entities.Id, &.{1}, query.read(radius));
        const examined = query.regions_examined.value() - before;
        try std.testing.expectEqual(count * @as(usize, if (crowded) columns else 1), examined);
        const unchanged = query.regions_examined.value();
        try std.testing.expectEqualSlices(entities.Id, &.{1}, query.read(radius));
        try std.testing.expectEqual(unchanged, query.regions_examined.value());
        try output.interface.print("{d:7} | {any:7} | {d:26} | {d:14} | {d}\n", .{ count, crowded, examined, query.count, query.regions_examined.value() - unchanged });
    };
    try output.interface.flush();
}

test "item wire IDs stay disjoint from positive player IDs beyond the old slot boundary" {
    const ids = [_]entities.Id{ 1, 255, 256, 257, 65_535, 65_536, std.math.maxInt(i32) };
    for (ids, 0..) |id, index| {
        const wire_id = ItemEntities.networkId(id);
        try std.testing.expect(wire_id < 0);
        for (ids[0..index]) |previous| try std.testing.expect(wire_id != ItemEntities.networkId(previous));
    }
}

test "item records written before fire was kept read as not burning, and new ones round trip" {
    const value: ItemEntities.Metadata = .{ .ticks = 7, .age = 40, .health = 3, .owner = 9, .revision = 5, .fire_ticks = 298, .ticks_frozen = 2, .stuck = .cobweb };
    var bytes: [ItemEntities.Metadata.encoded_size]u8 = undefined;
    ItemEntities.Metadata.encode(value, &bytes);
    try std.testing.expectEqual(value, try decode(&bytes));
    // Version 1 was the same fields up to the collection, under its own version byte.
    var old = bytes[0..ItemEntities.Metadata.version_1_size].*;
    old[0] = 1;
    var expected = value;
    expected.fire_ticks = 0;
    expected.ticks_frozen = 0;
    expected.stuck = .none;
    try std.testing.expectEqual(expected, try decode(&old));
    try std.testing.expectError(error.Corrupt, decode(bytes[0 .. bytes.len - 1]));
}
