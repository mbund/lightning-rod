const EnchantmentRegistry = @import("vanilla_items").enchantment_registry.EnchantmentRegistry;
const Dimensions = @import("vanilla_content").dimensions.Dimensions;
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const storage = @import("storage");
const records = @import("records");
const entities = @import("entities");
const game_data = @import("game_data");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const inventories = @import("inventories");
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const WorldBorder = @import("vanilla_world").world_border.WorldBorder;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const Random = @import("vanilla_content").random.Random;
const item_data = @import("vanilla_items").item_data;
const encoding = @import("protocol_support");
const xp = @import("vanilla_player").experience_state;
const assert = std.debug.assert;

/// Experience orbs, each a record of its own beside its body, streamed through caches of any
/// size: none is ever refused for want of room. They tick in the tick list's order where the
/// domains tick, and are found by the area index, as items are.
pub const Experience = struct {
    pub const id = "minecraft:experience";
    pub const Configuration = struct {
        seed: u64 = 0x657870657269656e,
        keep_inventory: bool = false,
        /// The columns holding orbs, and the columns they tick in.
        columns: usize = 16384,
    };
    pub const Dependencies = struct {
        enchantments: *EnchantmentRegistry,
        dimensions: *Dimensions,
        players: *Players,
        player_states: *PlayerStates,
        world_border: *WorldBorder,
        entities: *entities.Entities,
        physics: *ItemPhysics,
        inventories: *inventories.Inventories,
        inventory: *PlayerInventory,
        storage: storage.Space,
        record_workspaces: *records.Workspaces,
    };

    /// What holds an orb back on its next move: the blocks whose makeStuckInBlock reaches it.
    pub const Stuck = enum(u8) {
        none,
        cobweb,
        powder_snow,

        pub fn multiplier(self: Stuck) [3]f64 {
            return switch (self) {
                .none => .{ 0, 0, 0 },
                .cobweb => .{ 0.25, 0.05, 0.25 },
                .powder_snow => .{ 0.9, 1.5, 0.9 },
            };
        }

        pub fn of(multiplier_value: [3]f64) Stuck {
            inline for (.{ Stuck.none, Stuck.cobweb, Stuck.powder_snow }) |each| {
                if (std.meta.eql(multiplier_value, each.multiplier())) return each;
            }
            unreachable;
        }
    };

    pub const Orb = struct {
        pub const encoded_size = 39;

        pub fn encode(orb: Orb) [encoded_size]u8 {
            var bytes: [encoded_size]u8 = @splat(0);
            bytes[0] = 3;
            std.mem.writeInt(i32, bytes[1..5], orb.value, .little);
            std.mem.writeInt(i32, bytes[5..9], orb.count, .little);
            std.mem.writeInt(u16, bytes[9..11], orb.age, .little);
            std.mem.writeInt(i16, bytes[11..13], orb.health, .little);
            bytes[13] = @intFromBool(orb.on_ground);
            std.mem.writeInt(i16, bytes[14..16], orb.fire, .little);
            std.mem.writeInt(u32, bytes[16..20], orb.ticks, .little);
            bytes[20] = @backingInt(orb.stuck);
            bytes[21] = @intFromBool(orb.following != null);
            if (orb.following) |handle| {
                std.mem.writeInt(u32, bytes[22..26], @intCast(handle.index), .little);
                std.mem.writeInt(u32, bytes[26..30], handle.generation, .little);
            }
            std.mem.writeInt(u64, bytes[30..38], orb.revision, .little);
            bytes[38] = @intFromBool(orb.alive);
            return bytes;
        }

        pub fn decode(bytes: []const u8) !Orb {
            if (bytes.len != encoded_size or bytes[0] != 3) return error.CorruptExperienceOrb;
            if (bytes[13] > 1) return error.CorruptExperienceOrb;
            var orb: Orb = .{
                .value = std.mem.readInt(i32, bytes[1..5], .little),
                .count = std.mem.readInt(i32, bytes[5..9], .little),
                .age = std.mem.readInt(u16, bytes[9..11], .little),
                .health = std.mem.readInt(i16, bytes[11..13], .little),
                .on_ground = bytes[13] != 0,
                .fire = std.mem.readInt(i16, bytes[14..16], .little),
                .alive = true,
            };
            if (bytes[20] > @backingInt(Stuck.powder_snow) or bytes[21] > 1 or bytes[38] > 1) return error.CorruptExperienceOrb;
            orb.ticks = std.mem.readInt(u32, bytes[16..20], .little);
            orb.stuck = @fromBackingInt(@intCast(bytes[20]));
            if (bytes[21] == 1) orb.following = .{ .index = std.mem.readInt(u32, bytes[22..26], .little), .generation = std.mem.readInt(u32, bytes[26..30], .little) };
            orb.revision = std.mem.readInt(u64, bytes[30..38], .little);
            orb.alive = bytes[38] == 1;
            if (orb.alive and (orb.value <= 0 or orb.count <= 0 or orb.age >= 6000 or orb.health <= 0)) return error.CorruptExperienceOrb;
            return orb;
        }

        value: i32 = 0,
        count: i32 = 1,
        age: u16 = 0,
        health: i16 = 5,
        fire: i16 = 0,
        ticks: u32 = 0,
        following: ?sessions.Handle = null,
        alive: bool = true,
        on_ground: bool = false,
        stuck: Stuck = .none,
        /// Grows whenever viewers are owed the orb's motion again.
        revision: u64 = 0,
    };

    /// An orb in hand: copies of its state and body, written back when let go.
    pub const Held = struct {
        id: entities.Id,
        /// Its directory slot, found once by its id: the rest of its holding goes by it.
        slot: u32,
        orb: Orb,
        body: ?entities.State,
        /// Where its body was when taken, for its place to follow it.
        was: ?entities.State,
    };

    /// An orb in memory, and where its record in the store lies.
    pub const Stored = struct {
        orb: Orb,
        stored: ?entities.Column = null,
        dirty: bool = true,
    };

    pub const kind = game_data.registry.entityId("minecraft:experience_orb").?;
    /// ExperienceOrb's size, 0.5 by 0.5.
    pub const shape: entities.Shape = .{ .kind = kind, .half_width = 0.25, .height = 0.5 };
    /// What lookups of orbs are after, among every kind in the space.
    pub const kinds: entities.Kinds = .of(&.{kind});
    const record_prefix = 0x30;
    pub const record_bytes = entities.encoded_bytes + Orb.encoded_size;

    /// An orb as the store keeps it, for tools that write worlds: its key under its column,
    /// and its body and state.
    pub fn storeRecord(entity: entities.Id, body: entities.State, orb: Orb, value: *[record_bytes]u8) entities.durable.Key {
        entities.encode(body, value[0..entities.encoded_bytes]);
        @memcpy(value[entities.encoded_bytes..], &orb.encode());
        return entities.durable.key(record_prefix, entities.space.columnOf(body.world, body.position), entity);
    }

    /// A pickup and where the orb was, as the pickup that takes its last point takes its body.
    pub const Pickup = struct { entity: u64, slot: u32, collector: i32, body: entities.State, value: i32 };
    const Death = struct { handle: ?sessions.Handle = null, life: u32 = 0 };
    pub const Sound = struct { handle: ?sessions.Handle = null, life: u32 = 0, ticks: u32 = 0, last: u32 = 0, volume: ?f32 = null, seed: i64 = 0 };
    deps: Dependencies,
    config: Configuration,
    allocator: std.mem.Allocator,
    /// Every orb near players, gone ones not yet forgotten included.
    orbs: entities.BodyTable(Stored),
    /// Where every entity in memory is, and the order they tick in, shared by every kind.
    places: *entities.Places,
    residency: entities.Residency,
    /// Room to copy ids and name columns into, for passes that change what they pass over.
    scratch: []entities.Id,
    centers: []entities.residency.Center,
    /// What the last refresh went by: while all of it stands, so does what is in memory.
    last_centers: []entities.residency.Center,
    last_center_count: usize = 0,
    last_radius: i32 = 0,
    last_ticking: u64 = std.math.maxInt(u64),
    last_held: u64 = std.math.maxInt(u64),
    random: Random,
    table: records.Table,
    deaths: []Death,
    pickups: []Pickup,
    sounds: []Sound,
    pickup_count: usize = 0,
    /// Orbs gone since their records were last let go.
    retired: []entities.Id,
    /// Orbs whose replicated state changed since replication last looked: their motion's
    /// revision, or whether they burn. Replication visits these, not every orb.
    replicated: lightning_rod.system.IndexSet,
    retired_count: usize = 0,
    nearby: []entities.space.Entry,
    /// While entities tick: the blocks orbs read, shared by them all.
    window: ?ItemPhysics.Window = null,

    pub fn allocate(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Experience {
        if (deps.inventories.items.entries.len < 2) return error.InventoryCacheTooSmall;
        const self = try allocator.create(Experience);
        const table = records.Table.init(deps.storage, deps.record_workspaces.resources);
        const bound = deps.entities.directory.capacity();
        self.* = .{
            .deps = deps,
            .config = config,
            .allocator = allocator,
            .orbs = try .init(allocator, deps.entities, kind),
            .places = &deps.entities.places,
            .residency = try .init(allocator, config.columns),
            .scratch = try allocator.alloc(entities.Id, bound),
            .centers = try allocator.alloc(entities.residency.Center, deps.players.records.len),
            .last_centers = try allocator.alloc(entities.residency.Center, deps.players.records.len),
            .deaths = try allocator.alloc(Death, deps.players.records.len),
            .pickups = try allocator.alloc(Pickup, deps.players.records.len),
            .sounds = try allocator.alloc(Sound, deps.players.records.len),
            .random = .{ .source = .init(config.seed) },
            .table = table,
            .nearby = try allocator.alloc(entities.space.Entry, 1024),
            .retired = try allocator.alloc(entities.Id, bound),
            .replicated = try .init(allocator, deps.entities.directory.capacity()),
        };
        @memset(self.deaths, .{});
        @memset(self.sounds, .{});
        try deps.entities.declare(.{ .kinds = kinds, .tracking_range = 6 * 16 });
        try deps.entities.addTicker(.init(Experience, self, kinds, batch_max));
        try deps.entities.addColumnHolder(.init(Experience, self, columnLoaded, columnUnloaded));
        // Items and orbs collide with the world border.
        deps.physics.border = &deps.world_border.shared;
        try self.orbs.register();
        return self;
    }

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Experience {
        const self = try allocate(allocator, config, deps);
        if (try self.table.get(&.{0}, &self.random.saved)) |length| try self.random.restore(self.random.saved[0..length]);
        // Orbs kept before they were kept by column are refused, not converted.
        var after: [1]u8 = .{1};
        var cursor: records.ScanCursor = .{ .after = &after, .after_len = 0, .before = &.{record_prefix} };
        var key: [32]u8 = undefined;
        var found: [2]records.ScanKey = .{ .{ .key = &key }, .{ .key = &key } };
        const result = try self.table.scanKeys(&cursor, &found);
        for (found[0..result.count]) |entry| if (!(entry.key_len == 1 and entry.key[0] == 0)) return error.OldExperienceRecords;
        return self;
    }

    /// How many orbs are in memory, gone ones not yet forgotten included.
    pub fn orbCount(self: *const Experience) usize {
        return self.orbs.count();
    }

    /// The ids of the orbs near players, gone ones not yet forgotten included, by id. Good
    /// until an orb comes or goes, or this is asked again.
    pub fn ids(self: *Experience) []const entities.Id {
        return self.orbs.ids(self.scratch);
    }

    /// Takes orbs in hand, at most 16: copies, written back as each is let go.
    pub fn hold(self: *Experience, wanted: []const entities.Id, output: []Held, _: bool) !void {
        assert(wanted.len == output.len and wanted.len <= 16);
        for (wanted, output) |entity, *held| {
            const at = self.orbs.slotOf(entity) orelse return error.UnknownExperienceOrb;
            const stored = self.orbs.ptrAt(at);
            const body: ?entities.State = if (self.deps.entities.bodyAt(at)) |found| found.* else null;
            held.* = .{ .id = entity, .slot = at, .orb = stored.orb, .body = body, .was = body };
        }
    }

    /// Writes back what changed of an orb in hand and lets it go.
    pub fn settle(self: *Experience, held: *Held) !void {
        const stored = self.orbs.ptrAt(held.slot);
        assert(self.deps.entities.directory.entry(held.slot).id == held.id);
        if (!std.meta.eql(stored.orb, held.orb)) {
            if (stored.orb.revision != held.orb.revision or (stored.orb.fire > 0) != (held.orb.fire > 0)) self.replicated.insert(held.slot);
            stored.orb = held.orb;
            stored.dirty = true;
        }
        if (held.body) |body| if (held.was) |was| if (!std.meta.eql(body, was)) {
            const kept = self.deps.entities.bodyAt(held.slot) orelse return error.UnknownExperienceOrb;
            kept.* = body;
            stored.dirty = true;
            try self.places.moveSlot(held.slot, body.world, body.position);
        };
    }

    /// An orb as it is, for tests and for whoever looks at one at a time.
    pub fn get(self: *Experience, entity: entities.Id) !?struct { orb: Orb, body: ?entities.State } {
        const stored = try self.orbs.get(entity) orelse return null;
        return .{ .orb = stored.orb, .body = try self.deps.entities.get(entity) };
    }

    /// Changes an orb as given: its body moves its place with it.
    pub fn put(self: *Experience, entity: entities.Id, orb: Orb, body: ?entities.State) !void {
        var held: [1]Held = undefined;
        try self.hold(&.{entity}, &held, false);
        held[0].orb = orb;
        if (body) |value| held[0].body = value;
        try self.settle(&held[0]);
    }

    /// What the orbs not gone are worth together.
    pub fn totalValue(self: *Experience) !i64 {
        var total: i64 = 0;
        for (self.ids()) |entity| {
            const stored = (try self.orbs.get(entity)).?;
            if (stored.orb.alive) total += @as(i64, stored.orb.value) * stored.orb.count;
        }
        return total;
    }

    /// Every orb's state and body, for telling two runs apart.
    /// Each with the encoding orbs were kept in before, so digests compare across that change.
    pub fn digest(self: *Experience) !u64 {
        var sum: u64 = 0;
        for (self.ids()) |entity| {
            const stored = (try self.orbs.get(entity)).?;
            var hasher = std.hash.Wyhash.init(entity);
            var encoded = stored.orb.encode();
            encoded[0] = 2;
            hasher.update(&encoded);
            if (try self.deps.entities.get(entity)) |body| inline for (@typeInfo(entities.State).@"struct".field_names) |name| hasher.update(std.mem.asBytes(&@field(body, name)));
            sum +%= hasher.final();
        }
        return sum;
    }

    /// The orbs not gone, by id, as many as `output` holds.
    pub fn live(self: *Experience, output: []entities.Id) ![]entities.Id {
        var live_count: usize = 0;
        for (self.ids()) |entity| {
            const stored = (try self.orbs.get(entity)).?;
            if (!stored.orb.alive) continue;
            if (live_count == output.len) return error.WorkingSetTooLarge;
            output[live_count] = entity;
            live_count += 1;
        }
        const found = output[0..live_count];
        std.sort.pdq(entities.Id, found, {}, std.sort.asc(entities.Id));
        return found;
    }

    pub fn canAward(_: *const Experience, amount: i32) bool {
        return amount >= 0;
    }

    pub fn canAwardMany(_: *const Experience, amounts: []const i32) bool {
        for (amounts) |amount| if (amount < 0) return false;
        return true;
    }

    pub fn award(self: *Experience, world: u32, position: [3]f64, amount: i32) !void {
        return self.awardWithDirection(world, position, .{ 0, 0, 0 }, amount);
    }

    /// The id clients know an orb in memory by.
    pub fn networkId(self: *const Experience, entity: u64) i32 {
        return self.deps.entities.networkOf(entity).?;
    }

    /// The id it was given, which the wire's negates: what vanilla's getId gives.
    pub fn givenId(self: *const Experience, entity: u64) u32 {
        return @intCast(-@as(i64, self.networkId(entity)));
    }

    /// Orbs of a box's columns in vanilla's order: x up, z from 0 up then the negative ones,
    /// and in each column its sections' order, as getEntitiesByType goes; `visit` returns
    /// whether to stop.
    fn eachNear(self: *Experience, world: u32, low: [3]f64, high: [3]f64, context: anytype, comptime visit: fn (@TypeOf(context), entities.space.Entry) anyerror!bool) !void {
        // Every visit here takes only orbs within the box.
        try self.places.space.eachWithin(world, .{ .low = low, .high = high }, kinds, self.nearby, context, visit);
    }

    pub fn awardWithDirection(self: *Experience, world: u32, position: [3]f64, direction: [3]f64, amount: i32) !void {
        for (position) |component| assert(std.math.isFinite(component) and @abs(component) <= 30_000_000);
        for (direction) |component| assert(std.math.isFinite(component));
        if (self.deps.players.deps.worlds.get(world) == null) return error.UnknownWorld;
        if (amount < 0) return error.InvalidExperience;
        errdefer self.deps.storage.fail();
        var window = self.deps.physics.readWindow();
        defer window.deinit();
        var left = amount;
        while (left > 0) {
            const value = xp.denomination(left);
            left -= value;
            const bucket = self.random.random().uintLessThan(u32, 40);
            // ExperienceOrb.tryMerge: the first orb nearby of the value and bucket takes it.
            const Search = struct {
                owner: *Experience,
                value: i32,
                bucket: u32,
                position: [3]f64,
                found: ?entities.Id = null,
                fn visit(search: *@This(), entry: entities.space.Entry) !bool {
                    const at = entry.position;
                    if (@abs(at[0] - search.position[0]) >= 0.75 or @abs(at[2] - search.position[2]) >= 0.75 or at[1] >= search.position[1] + 0.5 or at[1] <= search.position[1] - 1) return false;
                    if (@mod(@as(i64, entities.Entities.networkOfSlot(entry.slot)) - search.bucket, 40) != 0) return false;
                    const found = (try search.owner.get(entry.id)) orelse return false;
                    if (!found.orb.alive or found.orb.value != search.value or found.orb.count == std.math.maxInt(i32)) return false;
                    search.found = entry.id;
                    return true;
                }
            };
            var search: Search = .{ .owner = self, .value = value, .bucket = bucket, .position = position };
            try self.eachNear(world, .{ position[0] - 0.75, position[1] - 1, position[2] - 0.75 }, .{ position[0] + 0.75, position[1] + 0.5, position[2] + 0.75 }, &search, Search.visit);
            if (search.found) |entity| {
                const found = (try self.get(entity)).?;
                var orb = found.orb;
                orb.count += 1;
                orb.age = 0;
                try self.put(entity, orb, null);
                continue;
            }
            const random = self.random.random();
            const yaw = random.float(f32) * 360;
            var velocity: [3]f64 = .{ (random.float(f64) * 0.2 - 0.1) * 2, random.float(f64) * 0.2 * 2, (random.float(f64) * 0.2 - 0.1) * 2 };
            const length = @sqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
            var origin = position;
            if (length > 0) {
                const dot = direction[0] * velocity[0] + direction[1] * velocity[1] + direction[2] * velocity[2];
                for (&origin, &velocity, direction) |*component, *motion, axis| {
                    if (length >= 1e-4) component.* += axis / length * 0.25;
                    if (dot < 0) motion.* = -motion.*;
                }
            }
            try self.create(&window, world, origin, velocity, yaw, value);
        }
    }

    /// One orb of the whole value, as `new ExperienceOrb(level, x, y, z, value)` makes it, where
    /// award would split the value and merge into orbs nearby. Animals bred drop one this way.
    pub fn spawnOrb(self: *Experience, world: u32, position: [3]f64, value: i32) !void {
        for (position) |component| assert(std.math.isFinite(component) and @abs(component) <= 30_000_000);
        if (self.deps.players.deps.worlds.get(world) == null) return error.UnknownWorld;
        if (value <= 0) return error.InvalidExperience;
        errdefer self.deps.storage.fail();
        var window = self.deps.physics.readWindow();
        defer window.deinit();
        const random = self.random.random();
        const yaw = random.float(f32) * 360;
        const velocity: [3]f64 = .{ (random.float(f64) * 0.2 - 0.1) * 2, random.float(f64) * 0.2 * 2, (random.float(f64) * 0.2 - 0.1) * 2 };
        try self.create(&window, world, position, velocity, yaw, value);
    }

    fn create(self: *Experience, window: *ItemPhysics.Window, world: u32, position: [3]f64, velocity: [3]f64, yaw: f32, value: i32) !void {
        const expected = self.deps.entities.next_id;
        var body: entities.State = .{ .uuid = @as(u128, expected) | (@as(u128, 0xe000) << 64), .kind = kind, .world = world, .position = position, .velocity = velocity, .yaw = yaw };
        try self.deps.physics.placeOrb(window, &body);
        if (!entities.valid(body)) return error.InvalidEntity;
        const created = try self.deps.entities.reserveIds(1);
        assert(created == expected);
        try self.orbs.add(expected, body, .{ .orb = .{ .value = value } }, shape);
        try self.residency.hold(entities.space.columnOf(world, body.position));
    }

    /// An orb went: its body and place go now, its record when no client knows of it.
    fn retire(self: *Experience, held: *Held) !void {
        assert(held.orb.alive);
        errdefer self.deps.storage.fail();
        self.orbs.dropBody(held.id);
        self.places.remove(held.id);
        held.orb.alive = false;
        held.body = null;
        held.was = null;
        self.retired[self.retired_count] = held.id;
        self.retired_count += 1;
    }

    pub fn damage(self: *Experience, entity: u64, amount: f32) !bool {
        assert(std.math.isFinite(amount) and amount >= 0);
        var held: [1]Held = undefined;
        self.hold(&.{entity}, &held, false) catch return false;
        defer self.settle(&held[0]) catch self.deps.storage.fail();
        return self.hurt(&held[0], amount);
    }

    fn hurt(self: *Experience, held: *Held, amount: f32) !bool {
        if (!held.orb.alive) return false;
        held.orb.health = @intFromFloat(@max(@as(f32, std.math.minInt(i16)), @as(f32, @floatFromInt(held.orb.health)) - amount));
        if (held.orb.health <= 0) try self.retire(held);
        return true;
    }

    /// Lets go of a gone orb's record. Its slot, and with it the id clients know it by, stays
    /// until every client that had it was told it went.
    pub fn forget(self: *Experience, entity: entities.Id) !void {
        const stored = try self.orbs.take(entity) orelse return error.UnknownExperienceOrb;
        assert(!stored.orb.alive);
        if (stored.stored) |column| try self.table.putBatch(&.{.{ .key = &entities.durable.key(record_prefix, column, entity), .value = null }});
        self.places.remove(entity);
    }

    /// Before entities tick: players' pickup sounds count on, and orbs near players come into
    /// memory.
    pub fn prepareTick(self: *Experience) !void {
        errdefer self.deps.storage.fail();
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            if (!std.meta.eql(self.sounds[index].handle, player.handle) or self.sounds[index].life != player.life) self.sounds[index] = .{ .handle = player.handle, .life = player.life };
            self.sounds[index].ticks +%= 1;
        }
        self.pickup_count = 0;
        // Orbs hurt to death between ticks.
        try self.forgetRetired();
        // Where nothing follows the loaded domain, orbs follow the players themselves.
        if (!self.deps.entities.columns_followed) try self.refresh();
        self.window = self.deps.physics.readWindow();
    }

    /// Orbs next in the tick order, held together as they tick, as a merge may take another.
    pub fn tickRun(self: *Experience, run: []const entities.order.Entry) !void {
        errdefer self.deps.storage.fail();
        var batch: [batch_max]entities.Id = undefined;
        for (run, batch[0..run.len]) |entry, *entity| entity.* = entry.id;
        var held: [batch_max]Held = undefined;
        try self.hold(batch[0..run.len], held[0..run.len], true);
        var settled: usize = 0;
        defer for (held[settled..run.len]) |*orb| self.settle(orb) catch self.deps.storage.fail();
        for (held[0..run.len]) |*orb| try self.tickOne(&self.window.?, orb, held[0..run.len]);
        for (held[0..run.len]) |*orb| {
            try self.settle(orb);
            settled += 1;
        }
    }

    /// After entities tick: what players took goes.
    pub fn finishTick(self: *Experience) !void {
        errdefer self.deps.storage.fail();
        defer {
            if (self.window) |*window| window.deinit();
            self.window = null;
        }
        try self.collect();
        try self.forgetRetired();
    }

    /// The records of orbs that went go too.
    fn forgetRetired(self: *Experience) !void {
        for (self.retired[0..self.retired_count]) |entity| try self.forget(entity);
        self.retired_count = 0;
    }

    /// Orbs a run holds at once.
    const batch_max = 16;

    /// Orbs in memory are those near players, out to their view and one more, and those of
    /// the columns that tick.
    pub fn refresh(self: *Experience) !void {
        var center_count: usize = 0;
        var radius: i32 = 1;
        for (self.deps.players.activeSlots()) |at| {
            const player = self.deps.players.records[at];
            if (player.stage != .ready) continue;
            const column = entities.space.columnOf(player.world, .{ player.position.x, player.position.y, player.position.z });
            self.centers[center_count] = .{ .world = column.world, .x = column.x, .z = column.z };
            center_count += 1;
            radius = @max(radius, self.deps.players.viewDistanceOf(player) + 1);
        }
        const centers = self.centers[0..center_count];
        if (radius == self.last_radius and self.places.ticking_revision == self.last_ticking and self.residency.held == self.last_held and
            std.mem.eql(u8, std.mem.sliceAsBytes(centers), std.mem.sliceAsBytes(self.last_centers[0..self.last_center_count]))) return;
        @memcpy(self.last_centers[0..center_count], centers);
        self.last_center_count = center_count;
        self.last_radius = radius;
        self.last_ticking = self.places.ticking_revision;
        try self.residency.refresh(centers, radius, self.places.tickingColumns(), self, unloadColumn, loadColumn);
        self.last_held = self.residency.held;
    }

    /// The loaded domain brought a column in: its orbs come back from the store.
    fn columnLoaded(self: *Experience, column: entities.Column) anyerror!void {
        if (try self.residency.enter(column)) try self.loadColumn(column);
    }

    /// The loaded domain let a column go: its orbs go to the store.
    fn columnUnloaded(self: *Experience, column: entities.Column) anyerror!void {
        if (!self.residency.holds(column)) return;
        try self.unloadColumn(column);
        _ = self.residency.leave(column);
    }

    fn unloadColumn(self: *Experience, column: entities.Column) anyerror!void {
        var batch: entities.durable.Batch(record_bytes) = .{ .table = self.table };
        var leaving_count: usize = 0;
        var walk = self.places.space.entries(column, kinds);
        while (walk.next()) |entry| {
            self.scratch[leaving_count] = entry.id;
            leaving_count += 1;
        }
        for (self.scratch[0..leaving_count]) |entity| {
            const body = (try self.deps.entities.get(entity)).?;
            const stored = (try self.orbs.take(entity)).?;
            try save(&batch, entity, body, stored);
            self.places.remove(entity);
        }
        try batch.flush();
    }

    fn loadColumn(self: *Experience, column: entities.Column) anyerror!void {
        var reader = entities.durable.ColumnReader(record_bytes).init(self.table, record_prefix, column);
        var rows: [16]entities.durable.ColumnReader(record_bytes).Row = undefined;
        while (true) {
            const found = try reader.next(&rows);
            if (found.len == 0) break;
            for (found) |row| {
                if (row.value.len != record_bytes) return error.CorruptExperienceOrb;
                const body = try entities.decode(row.value[0..entities.encoded_bytes]);
                const orb = try Orb.decode(row.value[entities.encoded_bytes..]);
                if (self.orbs.contains(row.id) or body.kind != kind) return error.CorruptExperienceOrb;
                if (!entities.valid(body)) return error.InvalidEntity;
                try self.orbs.add(row.id, body, .{ .orb = orb, .stored = column, .dirty = false }, shape);
            }
        }
    }

    fn save(batch: *entities.durable.Batch(record_bytes), entity: entities.Id, body: entities.State, stored: Stored) !void {
        const here = entities.space.columnOf(body.world, body.position);
        if (stored.stored) |was| if (!std.meta.eql(was, here)) try batch.delete(entities.durable.key(record_prefix, was, entity));
        var value: [record_bytes]u8 = undefined;
        entities.encode(body, value[0..entities.encoded_bytes]);
        @memcpy(value[entities.encoded_bytes..], &stored.orb.encode());
        try batch.put(entities.durable.key(record_prefix, here, entity), &value);
    }

    fn tickOne(self: *Experience, window: *ItemPhysics.Window, held: *Held, batch: []Held) !void {
        const orb = &held.orb;
        if (!orb.alive) return;
        var body = held.body orelse return error.CorruptExperienceOrb;
        // Visited but not ticked: moved this tick where nothing ticks.
        if (!self.places.ticks(entities.space.columnOf(body.world, body.position))) return;
        const world = self.deps.players.deps.worlds.get(body.world) orelse return error.CorruptExperienceOrb;
        if (body.position[1] < @as(f64, @floatFromInt(world.dimension.minimum_section * 16)) - 64) {
            try self.retire(held);
            return;
        }
        orb.ticks +%= 1;
        try self.deps.physics.pushOrb(window, &body, if (self.deps.dimensions.get(world.dimension.name)) |dimension| dimension.ultrawarm else false);
        const environment = try self.deps.physics.orbEnvironment(window, body);
        if (orb.fire > 0) {
            if (@mod(orb.fire, 20) == 0 and (try self.deps.physics.orbEffects(window, body)).lava == 0) {
                held.body = body;
                _ = try self.hurt(held, 1);
                if (!orb.alive) return;
            }
            orb.fire -= 1;
        }
        if (environment.water) {
            body.velocity[0] *= @as(f64, @as(f32, 0.99));
            body.velocity[1] = @min(body.velocity[1] + @as(f64, @as(f32, 0.0005)), @as(f64, @as(f32, 0.06)));
            body.velocity[2] *= @as(f64, @as(f32, 0.99));
        } else if (!environment.solid) body.velocity[1] -= 0.03;
        if (environment.lava) {
            const random = self.random.random();
            body.velocity = .{ (random.float(f32) - random.float(f32)) * @as(f32, 0.2), @as(f64, @as(f32, 0.2)), (random.float(f32) - random.float(f32)) * @as(f32, 0.2) };
        }
        held.body = body;
        if (orb.ticks % 20 == 1) try self.merge(held, batch);
        var target: ?usize = null;
        if (orb.following) |handle| {
            const player = self.deps.players.records[handle.index];
            if (std.meta.eql(player.handle, @as(?sessions.Handle, handle)) and player.world == body.world and self.deps.player_states.of(&player).gamemode != .spectator and distance(body.position, player.position) <= 64) target = handle.index;
        }
        if (target == null) {
            var closest: f64 = 64;
            var candidates = self.deps.players.nearby(body.world, .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] }, 1);
            while (candidates.next()) |player_index| {
                const player = self.deps.players.records[player_index];
                const state = self.deps.player_states.of(&player);
                if (state.gamemode == .spectator or state.health <= 0) continue;
                const squared = distance(body.position, player.position);
                // ExperienceOrb.tick: Level.getNearestPlayer over the level's players in the order
                // they came, the first of equals.
                if (squared < closest or (squared == closest and target != null and self.deps.players.joinedBefore(player_index, target.?))) {
                    closest = squared;
                    target = player_index;
                }
            }
        }
        orb.following = if (target) |player_index| self.deps.players.records[player_index].handle else null;
        if (target) |player_index| {
            const player = self.deps.players.records[player_index];
            const delta: [3]f64 = .{ player.position.x - body.position[0], player.position.y + @as(f64, @as(f32, if (player.flags.sneaking) 1.27 else 1.62)) / 2 - body.position[1], player.position.z - body.position[2] };
            const length = @sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]);
            if (length >= 1e-4) {
                const strength = (1 - length / 8) * (1 - length / 8) * 0.1 / length;
                for (&body.velocity, 0..) |*component, axis| component.* += delta[axis] * strength;
            }
        }
        if (target == null and environment.solid) {
            var moved = body;
            for (&moved.position, moved.velocity) |*position, velocity| position.* += velocity;
            if (try self.deps.physics.orbCollides(window, moved)) {
                try self.deps.physics.escapeOrb(window, &body, self.random.random());
                orb.revision +%= 1;
            }
        }
        const advanced = try self.deps.physics.advanceOrb(window, self.givenId(held.id), orb.ticks, body, orb.on_ground, orb.stuck.multiplier());
        orb.on_ground = advanced.on_ground;
        held.body = advanced.body;
        const hazards = advanced.effects;
        orb.stuck = Stuck.of(hazards.stuck);
        if (hazards.lava > 0) {
            orb.fire = @max(orb.fire, 300);
            _ = try self.hurt(held, @as(f32, @floatFromInt(hazards.lava)) * 4);
        }
        if (orb.alive and hazards.fire > 0) {
            orb.fire = @max(orb.fire, 160);
            _ = try self.hurt(held, @floatFromInt(hazards.fire));
        }
        if (orb.alive and hazards.cactus > 0) _ = try self.hurt(held, @floatFromInt(hazards.cactus));
        if (!orb.alive) return;
        if (hazards.extinguish) orb.fire = 0;
        if (orb.fire == 0) orb.fire = -1;
        if (orb.ticks % 20 == 0) orb.revision +%= 1;
        orb.age += 1;
        if (orb.age >= 6000) try self.retire(held);
    }

    /// ExperienceOrb.scanForMerges: orbs of its value within a block, in the bucket of its id,
    /// in the order found, fold into it; one of the batch in hand is folded where it lies.
    fn merge(self: *Experience, held: *Held, batch: []Held) !void {
        const body = held.body.?;
        const Fold = struct {
            owner: *Experience,
            held: *Held,
            batch: []Held,
            fn visit(fold: *@This(), entry: entities.space.Entry) !bool {
                if (entry.id == fold.held.id) return false;
                const at = entry.position;
                const here = fold.held.body.?.position;
                if (@abs(at[0] - here[0]) >= 1 or @abs(at[1] - here[1]) >= 1 or @abs(at[2] - here[2]) >= 1) return false;
                if (@mod(@as(i64, entities.Entities.networkOfSlot(entry.slot)) - @as(i64, fold.owner.networkId(fold.held.id)), 40) != 0) return false;
                const in_batch = for (fold.batch) |*other| {
                    if (other.id == entry.id) break other;
                } else null;
                var separate: [1]Held = undefined;
                const other = in_batch orelse other: {
                    try fold.owner.hold(&.{entry.id}, &separate, false);
                    break :other &separate[0];
                };
                defer if (in_batch == null) fold.owner.settle(other) catch fold.owner.deps.storage.fail();
                if (!other.orb.alive or other.orb.value != fold.held.orb.value) return false;
                if (other.orb.count > std.math.maxInt(i32) - fold.held.orb.count) return false;
                fold.held.orb.count += other.orb.count;
                fold.held.orb.age = @min(fold.held.orb.age, other.orb.age);
                try fold.owner.retire(other);
                return false;
            }
        };
        var fold: Fold = .{ .owner = self, .held = held, .batch = batch };
        try self.eachNear(body.world, .{ body.position[0] - 1, body.position[1] - 1, body.position[2] - 1 }, .{ body.position[0] + 1, body.position[1] + 1, body.position[2] + 1 }, &fold, Fold.visit);
    }

    /// Players take what orbs they touch, one each tick of their delay; and those dying leave
    /// theirs.
    fn collect(self: *Experience) !void {
        for (self.deps.players.activeSlots()) |player_index| {
            const player = &self.deps.players.records[player_index];
            const state = self.deps.player_states.of(player);
            if (state.experience_delay > 0) state.experience_delay -= 1;
            if (state.health <= 0) {
                if (self.deaths[player_index].life != player.life or !std.meta.eql(self.deaths[player_index].handle, player.handle)) {
                    if (!self.config.keep_inventory and state.gamemode != .spectator) {
                        try self.award(player.world, .{ player.position.x, player.position.y, player.position.z }, state.experience.deathReward());
                        state.experience = .{};
                    }
                    self.deaths[player_index] = .{ .handle = player.handle, .life = player.life };
                }
                continue;
            }
            if (player.stage != .ready or state.gamemode == .spectator or state.experience_delay != 0) continue;
            // Player.aiStep: of the orbs touched, one at random, Util.getRandom over them in
            // the order they are found: counted first, then the chosen one found again.
            const reach = 1.25 + @as(f64, @as(f32, 0.6)) / 2;
            const top = player.position.y + @as(f64, @as(f32, if (player.flags.sneaking) 1.5 else 1.8)) + 0.5;
            const Touch = struct {
                owner: *Experience,
                player: minecraft.Position,
                reach: f64,
                top: f64,
                count: usize = 0,
                wanted: ?usize = null,
                found: ?entities.Id = null,
                fn visit(touch: *@This(), entry: entities.space.Entry) !bool {
                    const at = entry.position;
                    if (@abs(at[0] - touch.player.x) >= touch.reach or @abs(at[2] - touch.player.z) >= touch.reach or at[1] + 0.5 <= touch.player.y - 0.5 or at[1] >= touch.top) return false;
                    if (touch.wanted) |wanted| if (touch.count == wanted) {
                        touch.found = entry.id;
                        return true;
                    };
                    touch.count += 1;
                    return false;
                }
            };
            const low: [3]f64 = .{ player.position.x - reach, player.position.y - 1, player.position.z - reach };
            const high: [3]f64 = .{ player.position.x + reach, top, player.position.z + reach };
            var counting: Touch = .{ .owner = self, .player = player.position, .reach = reach, .top = top };
            try self.eachNear(player.world, low, high, &counting, Touch.visit);
            if (counting.count == 0) continue;
            var choosing: Touch = .{ .owner = self, .player = player.position, .reach = reach, .top = top, .wanted = self.random.random().uintLessThan(usize, counting.count) };
            try self.eachNear(player.world, low, high, &choosing, Touch.visit);
            const entity = choosing.found orelse return error.CorruptExperienceOrb;
            var held: [1]Held = undefined;
            try self.hold(&.{entity}, &held, false);
            defer self.settle(&held[0]) catch self.deps.storage.fail();
            state.experience_delay = 2;
            self.givePoints(player_index, try self.repair(player_index, held[0].orb.value));
            held[0].orb.count -= 1;
            self.pickups[self.pickup_count] = .{ .entity = entity, .slot = self.deps.entities.directory.slotOf(entity).?, .collector = @intCast(player_index + 1), .body = held[0].body.?, .value = held[0].orb.value };
            self.pickup_count += 1;
            if (held[0].orb.count == 0) try self.retire(&held[0]);
        }
    }

    pub fn givePoints(self: *Experience, player: usize, amount: i32) void {
        assert(player < self.deps.players.records.len and self.deps.players.records[player].inWorld());
        if (self.deps.player_states.records[player].experience.pointsWithSound(amount)) |level| self.levelSound(player, level);
    }

    pub fn giveLevels(self: *Experience, player: usize, amount: i32) void {
        assert(player < self.deps.players.records.len and self.deps.players.records[player].inWorld());
        const state = &self.deps.player_states.records[player].experience;
        state.levels(amount);
        if (amount > 0 and @mod(state.level, 5) == 0) self.levelSound(player, state.level);
    }

    fn levelSound(self: *Experience, player: usize, level: i32) void {
        const sound = &self.sounds[player];
        if (@as(f32, @floatFromInt(sound.last)) >= @as(f32, @floatFromInt(sound.ticks)) - 100) return;
        sound.last = sound.ticks;
        sound.volume = @min(@as(f32, @floatFromInt(level)) / 30, 1) * 0.75;
        sound.seed = self.random.random().int(i64);
    }

    pub fn repair(self: *Experience, player_index: usize, amount: i32) !i32 {
        assert(amount > 0);
        assert(player_index < self.deps.players.records.len and self.deps.players.records[player_index].inWorld());
        const player = self.deps.players.records[player_index];
        var slots: [6]inventories.Slot = undefined;
        for ([_]u16{ 36 + @as(u16, self.deps.player_states.of(&player).selected_slot), 45, 8, 7, 6, 5 }, &slots) |at, *slot| slot.* = .{ .owner = player.uuid, .index = at };
        var contents: [6]inventories.Contents = undefined;
        try self.deps.inventories.getMany(&slots, &contents);
        var damages: [6]i32 = @splat(0);
        var default_damage: [6]bool = @splat(false);
        var repaired: [6]?inventories.Stack = undefined;
        const effects = &self.deps.enchantments.effects;
        const equipment_slots = [_]u3{ 0, 1, 5, 4, 3, 2 };
        for (contents, &repaired, 0..) |entry, *stack, index| {
            stack.* = entry.stack;
            const held = entry.stack orelse continue;
            const lease = try self.deps.inventories.acquireItem(held.item);
            defer lease.release();
            const view = try item_data.View.parse(lease.read().?);
            if (view.kind >= game_data.registry.items.len) return error.Corrupt;
            if (view.value(.unbreakable) != null or !try effects.hasRepair(view, equipment_slots[index])) continue;
            var maximum: i32 = @intCast(self.deps.inventory.deps.items.deps.definitions.properties[view.kind].durability);
            default_damage[index] = maximum > 0;
            if (view.get(item_data.key(.max_damage))) |value| maximum = if (value.value) |bytes| (try encoding.read_varint(bytes))[0] else 0;
            if (maximum <= 0) continue;
            if (view.value(.damage)) |bytes| damages[index] = (try encoding.read_varint(bytes))[0];
        }
        var left = amount;
        while (left > 0) {
            var candidates: [6]usize = undefined;
            var count: usize = 0;
            for (damages, 0..) |value, index| if (value > 0) {
                candidates[count] = index;
                count += 1;
            };
            if (count == 0) break;
            const index = candidates[self.random.random().uintLessThan(usize, count)];
            const repairable = blk: {
                const lease = try self.deps.inventories.acquireItem(repaired[index].?.item);
                defer lease.release();
                self.deps.inventory.scratch.reset();
                break :blk @max(0, try effects.modify(.{
                    .item = try item_data.View.parse(lease.read().?),
                    .slot = equipment_slots[index],
                    .amount = @floatFromInt(left),
                    .channel = .repair,
                    .random = self.random.random(),
                    .player = player.uuid,
                    .actor = &player,
                    .location = .{ .world = player.world, .position = player.position },
                    .scratch = &self.deps.inventory.scratch,
                }));
            };
            if (repairable == 0) {
                left = 0;
                break;
            }
            const durability = @min(@as(i64, repairable), damages[index]);
            damages[index] -= @intCast(durability);
            if (damages[index] == 0 and default_damage[index]) {
                repaired[index] = try item_data.clearOverride(self.deps.inventories, repaired[index].?, item_data.key(.damage));
            } else {
                var bytes: [5]u8 = undefined;
                const rest = try encoding.write_varint(&bytes, damages[index]);
                repaired[index] = try item_data.replace(self.deps.inventories, repaired[index].?, .{ .key = item_data.key(.damage), .value = bytes[0 .. bytes.len - rest.len] });
            }
            left -= @intCast(@divTrunc(durability * left, repairable));
        }
        var edits: [6]inventories.Edit = undefined;
        var count: usize = 0;
        var changed: u64 = 0;
        for (slots, contents, repaired) |slot, previous, next| {
            if (std.meta.eql(previous.stack, next)) continue;
            edits[count] = .{ .slot = slot, .revision = previous.revision, .stack = next };
            changed |= @as(u64, 1) << @intCast(slot.index);
            count += 1;
        }
        if (count > 0) {
            const committed = try self.deps.inventories.editMany(edits[0..count]);
            assert(committed);
            self.deps.inventory.changedSlots(player_index, changed);
        }
        return left;
    }

    pub fn checkpoint(self: *Experience, space: storage.Space) !void {
        errdefer space.fail();
        var batch: entities.durable.Batch(record_bytes) = .{ .table = self.table };
        for (self.ids()) |entity| {
            var stored = (try self.orbs.get(entity)).?;
            if (!stored.orb.alive) {
                // Gone but not yet forgotten: its record goes now, and nothing comes back.
                if (stored.stored) |column| try batch.delete(entities.durable.key(record_prefix, column, entity));
                stored.stored = null;
                try self.orbs.put(entity, stored);
                continue;
            }
            if (!stored.dirty) continue;
            const body = (try self.deps.entities.get(entity)).?;
            try save(&batch, entity, body, stored);
            stored.stored = entities.space.columnOf(body.world, body.position);
            stored.dirty = false;
            try self.orbs.put(entity, stored);
        }
        try batch.flush();
        const random_bytes = self.random.encode();
        if (!std.mem.eql(u8, &random_bytes, &self.random.saved)) {
            try self.table.put(&.{0}, &random_bytes);
            self.random.saved = random_bytes;
        }
    }
};

fn distance(position: [3]f64, player: minecraft.Position) f64 {
    return (position[0] - player.x) * (position[0] - player.x) + (position[1] - player.y) * (position[1] - player.y) + (position[2] - player.z) * (position[2] - player.z);
}
