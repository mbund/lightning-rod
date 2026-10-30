const EnchantmentRegistry = @import("enchantment_registry.zig").EnchantmentRegistry;
const Dimensions = @import("dimensions.zig").Dimensions;
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const storage = @import("storage");
const records = @import("records");
const entities = @import("entities");
const game_data = @import("game_data");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const inventories = @import("inventories");
const Players = @import("players.zig").Players;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const ItemPhysics = @import("item_physics.zig").ItemPhysics;
const spatial = @import("item_spatial.zig");
const Random = @import("random.zig").Random;
const item_data = @import("item_data.zig");
const encoding = @import("protocol_support");
const xp = @import("experience_state.zig");
const assert = std.debug.assert;

pub const Experience = struct {
    pub const id = "minecraft:experience";
    pub const Configuration = struct { maximum_orbs: usize = 1024, seed: u64 = 0x657870657269656e, keep_inventory: bool = false };
    pub const Dependencies = struct {
        enchantments: *EnchantmentRegistry,
        dimensions: *Dimensions,
        players: *Players,
        entities: *entities.Entities,
        physics: *ItemPhysics,
        inventories: *inventories.Inventories,
        inventory: *PlayerInventory,
        storage: storage.Space,
        record_workspaces: *records.Workspaces,
    };
    pub const Orb = struct {
        value: i32 = 0,
        count: i32 = 1,
        age: u16 = 0,
        health: i16 = 5,
        fire: i16 = 0,
        ticks: u32 = 0,
        following: ?sessions.Handle = null,
        alive: bool = false,
        on_ground: bool = false,
        stuck: [3]f64 = .{ 0, 0, 0 },
        revision: u64 = 0,
        viewers: usize = 0,
        body: entities.State = .{ .uuid = 0, .kind = 0, .world = 0, .position = .{ 0, 0, 0 } },
    };
    pub const Pickup = struct { entity: u64, collector: i32 };
    const Death = struct { handle: ?sessions.Handle = null, life: u32 = 0 };
    pub const Sound = struct { handle: ?sessions.Handle = null, life: u32 = 0, ticks: u32 = 0, last: u32 = 0, volume: ?f32 = null, seed: i64 = 0 };
    const encoded_size = 16;
    deps: Dependencies,
    config: Configuration,
    orbs: []Orb,
    residents: []spatial.Resident,
    spatial: spatial.Index,
    ids: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    active: lightning_rod.system.IndexSet,
    free: []usize,
    free_count: usize,
    candidates: []usize,
    saved: []u64,
    saved_count: usize = 0,
    random: Random,
    table: records.Table,
    deaths: []Death,
    pickups: []Pickup,
    sounds: []Sound,
    pickup_count: usize = 0,

    pub fn allocate(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Experience {
        if (deps.inventories.items.entries.len < 2) return error.InventoryCacheTooSmall;
        if (config.maximum_orbs == 0 or config.maximum_orbs > 65536) return error.InvalidExperienceCapacity;
        const self = try allocator.create(Experience);
        const residents = try allocator.alloc(spatial.Resident, config.maximum_orbs);
        @memset(residents, .{});
        self.* = .{
            .deps = deps,
            .config = config,
            .orbs = try allocator.alloc(Orb, config.maximum_orbs),
            .residents = residents,
            .spatial = try .init(allocator, residents),
            .active = try .init(allocator, config.maximum_orbs),
            .free = try allocator.alloc(usize, config.maximum_orbs),
            .free_count = config.maximum_orbs,
            .candidates = try allocator.alloc(usize, config.maximum_orbs),
            .saved = try allocator.alloc(u64, config.maximum_orbs),
            .deaths = try allocator.alloc(Death, deps.players.records.len),
            .pickups = try allocator.alloc(Pickup, deps.players.records.len),
            .sounds = try allocator.alloc(Sound, deps.players.records.len),
            .random = .{ .source = .init(config.seed) },
            .table = records.Table.init(deps.storage, deps.record_workspaces.resources),
        };
        @memset(self.orbs, .{});
        @memset(self.deaths, .{});
        @memset(self.sounds, .{});
        for (self.free, 0..) |*slot, index| slot.* = self.free.len - index - 1;
        try self.ids.ensureTotalCapacity(allocator, @intCast(config.maximum_orbs));
        return self;
    }

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Experience {
        const self = try allocate(allocator, config, deps);
        if (try self.table.get(&.{0}, &self.random.saved)) |length| try self.random.restore(self.random.saved[0..length]);
        var after: [9]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        var keys: [16][9]u8 = undefined;
        var values: [16][32]u8 = undefined;
        var entries: [16]records.ScanEntry = undefined;
        for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
        while (true) {
            const batch = try self.table.scan(&cursor, &entries);
            for (entries[0..batch.count]) |entry| {
                if (entry.key_len == 1 and entry.key[0] == 0) continue;
                if (entry.key_len != 9 or entry.key[0] != 1 or entry.value_len != encoded_size) return error.CorruptExperienceOrb;
                const entity = std.mem.readInt(u64, entry.key[1..9], .big);
                const value = entry.value;
                if (value[0] != 1 or value[13] > 1) return error.CorruptExperienceOrb;
                const orb: Orb = .{
                    .value = std.mem.readInt(i32, value[1..5], .little),
                    .count = std.mem.readInt(i32, value[5..9], .little),
                    .age = std.mem.readInt(u16, value[9..11], .little),
                    .health = std.mem.readInt(i16, value[11..13], .little),
                    .fire = std.mem.readInt(i16, value[14..16], .little),
                    .alive = true,
                    .on_ground = value[13] != 0,
                };
                if (orb.value <= 0 or orb.count <= 0 or orb.age >= 6000 or orb.health <= 0 or self.ids.contains(entity)) return error.CorruptExperienceOrb;
                if (self.free_count == 0) return error.ExperienceCapacity;
                const body = (try deps.entities.get(entity)) orelse return error.CorruptExperienceOrb;
                if (entity > std.math.maxInt(i32) or body.kind != game_data.registry.entityId("minecraft:experience_orb").? or deps.players.deps.worlds.get(body.world) == null) return error.CorruptExperienceOrb;
                const index = self.insert(entity, body, orb);
                self.saved[self.saved_count] = self.residents[index].id;
                self.saved_count += 1;
            }
            if (!batch.more) break;
        }
        return self;
    }

    fn insert(self: *Experience, entity: u64, body: entities.State, orb: Orb) usize {
        assert(self.free_count > 0 and !self.ids.contains(entity));
        assert(self.active.values().len + self.free_count == self.orbs.len);
        assert(self.ids.count() == self.active.values().len);
        self.free_count -= 1;
        const index = self.free[self.free_count];
        self.orbs[index] = orb;
        self.orbs[index].body = body;
        self.ids.putAssumeCapacityNoClobber(entity, index);
        self.active.insert(index);
        self.residents[index].id = entity;
        self.locate(index, body);
        return index;
    }

    fn locate(self: *Experience, index: usize, body: entities.State) void {
        const x: i32 = @intFromFloat(@floor(body.position[0] / 16));
        const y: i32 = @intFromFloat(@floor(body.position[1] / 16));
        const z: i32 = @intFromFloat(@floor(body.position[2] / 16));
        const resident = &self.residents[index];
        if (resident.alive and resident.world == body.world and resident.x == x and resident.y == y and resident.z == z) {
            resident.position = .{ body.position[0], body.position[2] };
            return;
        }
        if (self.residents[index].alive) self.spatial.remove(@intCast(index));
        self.residents[index] = .{ .id = self.residents[index].id, .world = body.world, .x = @intFromFloat(@floor(body.position[0] / 16)), .y = @intFromFloat(@floor(body.position[1] / 16)), .z = @intFromFloat(@floor(body.position[2] / 16)), .position = .{ body.position[0], body.position[2] }, .alive = self.orbs[index].alive };
        if (self.orbs[index].alive) self.spatial.insert(@intCast(index));
    }

    pub fn canAward(self: *const Experience, amount: i32) bool {
        return self.canAwardMany(&.{amount});
    }

    pub fn canAwardMany(self: *const Experience, amounts: []const i32) bool {
        var needed: usize = 0;
        for (amounts) |amount| {
            if (amount < 0) return false;
            var left = amount;
            for (xp.denominations) |value| {
                const count: usize = @intCast(@divTrunc(left, value));
                if (count > self.free_count - needed) return false;
                needed += count;
                left = @rem(left, value);
            }
        }
        return needed == 0 or (self.deps.entities.next_id <= std.math.maxInt(i32) and needed - 1 <= std.math.maxInt(i32) - self.deps.entities.next_id);
    }

    pub fn award(self: *Experience, world: u32, position: [3]f64, amount: i32) !void {
        return self.awardWithDirection(world, position, .{ 0, 0, 0 }, amount);
    }

    pub fn networkId(entity: u64) i32 {
        assert(entity > 0 and entity <= std.math.maxInt(i32));
        return -@as(i32, @intCast(entity));
    }

    pub fn awardWithDirection(self: *Experience, world: u32, position: [3]f64, direction: [3]f64, amount: i32) !void {
        for (position) |component| assert(std.math.isFinite(component) and @abs(component) <= 30_000_000);
        for (direction) |component| assert(std.math.isFinite(component));
        if (self.deps.players.deps.worlds.get(world) == null) return error.UnknownWorld;
        if (amount < 0) return error.InvalidExperience;
        if (!self.canAward(amount)) return error.ExperienceCapacity;
        errdefer self.deps.storage.fail();
        var window = self.deps.physics.readWindow();
        defer window.deinit();
        var bodies: [64]entities.State = undefined;
        var body_count: usize = 0;
        const capacity = @min(bodies.len, self.deps.entities.cache.entries.len);
        var left = amount;
        while (left > 0) {
            const value = xp.denomination(left);
            left -= value;
            const bucket = self.random.random().uintLessThan(u32, 40);
            var nearby = self.spatial.rectangle(world, .{ @intFromFloat(@floor((position[0] - 0.75) / 16)), @intFromFloat(@floor((position[2] - 0.75) / 16)) }, .{ @intFromFloat(@floor((position[0] + 0.75) / 16)), @intFromFloat(@floor((position[2] + 0.75) / 16)) });
            const merged = while (nearby.next()) |at| {
                const index: usize = at;
                const entity = self.residents[index].id;
                const orb = &self.orbs[index];
                if (orb.value != value or @mod(@as(i64, networkId(entity)) - bucket, 40) != 0 or orb.count == std.math.maxInt(i32)) continue;
                const body = self.orbs[index].body;
                if (@abs(body.position[0] - position[0]) >= 0.75 or @abs(body.position[2] - position[2]) >= 0.75 or body.position[1] >= position[1] + 0.5 or body.position[1] <= position[1] - 1) continue;
                orb.count += 1;
                orb.age = 0;
                break true;
            } else false;
            if (merged) continue;
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
            const expected = self.deps.entities.next_id + body_count;
            var body: entities.State = .{ .uuid = @as(u128, expected) | (@as(u128, 0xe000) << 64), .kind = @intCast(game_data.registry.entityId("minecraft:experience_orb").?), .world = world, .position = origin, .velocity = velocity, .yaw = yaw };
            try self.deps.physics.placeOrb(&window, &body);
            // Later denominations may merge into this batch before its bodies reach storage.
            _ = self.insert(expected, body, .{ .value = value, .alive = true });
            bodies[body_count] = body;
            body_count += 1;
            if (body_count == capacity) {
                try self.createBodies(bodies[0..body_count]);
                body_count = 0;
            }
        }
        if (body_count > 0) try self.createBodies(bodies[0..body_count]);
    }

    fn createBodies(self: *Experience, bodies: []const entities.State) !void {
        assert(bodies.len > 0 and bodies.len <= 64);
        var created: [64]entities.Id = undefined;
        const first = self.deps.entities.next_id;
        try self.deps.entities.createMany(bodies, created[0..bodies.len]);
        for (created[0..bodies.len], 0..) |entity, index| assert(entity == first + index);
    }

    pub fn snapshot(self: *const Experience, index: usize) entities.State {
        assert(self.active.contains(index));
        return self.orbs[index].body;
    }

    pub fn retire(self: *Experience, index: usize) !void {
        assert(self.orbs[index].alive and self.residents[index].alive and self.active.contains(index));
        errdefer self.deps.storage.fail();
        try self.deps.entities.remove(self.residents[index].id);
        self.orbs[index].alive = false;
        self.spatial.remove(@intCast(index));
        self.residents[index].alive = false;
    }

    pub fn damage(self: *Experience, entity: u64, amount: f32) !bool {
        assert(std.math.isFinite(amount) and amount >= 0);
        const index = self.ids.get(entity) orelse return false;
        const orb = &self.orbs[index];
        if (!orb.alive) return false;
        orb.health = @intFromFloat(@max(@as(f32, std.math.minInt(i16)), @as(f32, @floatFromInt(orb.health)) - amount));
        if (orb.health <= 0) try self.retire(index);
        return true;
    }

    fn forget(self: *Experience, index: usize) void {
        assert(!self.orbs[index].alive and !self.residents[index].alive and self.orbs[index].viewers == 0);
        assert(self.active.contains(index));
        const entity = self.residents[index].id;
        const removed = self.ids.remove(entity);
        assert(removed);
        self.active.remove(index);
        self.residents[index] = .{};
        self.orbs[index] = .{};
        self.free[self.free_count] = index;
        self.free_count += 1;
        assert(self.free_count + self.active.values().len == self.orbs.len);
        assert(self.ids.count() == self.active.values().len);
    }

    pub fn tick(self: *Experience) !void {
        errdefer self.deps.storage.fail();
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            if (!std.meta.eql(self.sounds[index].handle, player.handle) or self.sounds[index].life != player.life) self.sounds[index] = .{ .handle = player.handle, .life = player.life };
            self.sounds[index].ticks +%= 1;
        }
        self.pickup_count = 0;
        var offset: usize = 0;
        var window = self.deps.physics.readWindow();
        defer window.deinit();
        while (offset < self.active.values().len) {
            const index = self.active.values()[offset];
            const orb = &self.orbs[index];
            if (!orb.alive) {
                if (orb.viewers == 0) {
                    self.forget(index);
                    continue;
                }
                offset += 1;
                continue;
            }
            offset += 1;
            const entity = self.residents[index].id;
            var body = orb.body;
            var nearby = self.deps.players.nearby(body.world, .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] }, self.deps.players.config.simulation_distance);
            if (nearby.next() == null) continue;
            const world = self.deps.players.deps.worlds.get(body.world) orelse return error.CorruptExperienceOrb;
            if (body.position[1] < @as(f64, @floatFromInt(world.dimension.minimum_section * 16)) - 64) {
                try self.retire(index);
                continue;
            }
            orb.ticks +%= 1;
            try self.deps.physics.pushOrb(&window, &body, if (self.deps.dimensions.get(world.dimension.name)) |dimension| dimension.ultrawarm else false);
            const environment = try self.deps.physics.orbEnvironment(&window, body);
            if (orb.fire > 0) {
                if (@mod(orb.fire, 20) == 0 and (try self.deps.physics.orbEffects(&window, body)).lava == 0) {
                    _ = try self.damage(entity, 1);
                    if (!orb.alive) continue;
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
            if (orb.ticks % 20 == 1) try self.merge(index, body);
            var target: ?usize = null;
            if (orb.following) |handle| {
                const player = self.deps.players.records[handle.index];
                if (std.meta.eql(player.handle, @as(?sessions.Handle, handle)) and player.world == body.world and player.gamemode != .spectator and distance(body.position, player.position) <= 64) target = handle.index;
            }
            if (target == null) {
                var closest: f64 = 64;
                var candidates = self.deps.players.nearby(body.world, .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] }, 1);
                while (candidates.next()) |player_index| {
                    const player = self.deps.players.records[player_index];
                    if (player.gamemode == .spectator or player.health <= 0) continue;
                    const squared = distance(body.position, player.position);
                    if (squared < closest) {
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
                if (try self.deps.physics.orbCollides(&window, moved)) {
                    try self.deps.physics.escapeOrb(&window, &body, self.random.random());
                    orb.revision +%= 1;
                }
            }
            const advanced = try self.deps.physics.advanceOrb(&window, @intCast(entity), orb.ticks, body, orb.on_ground, orb.stuck);
            orb.on_ground = advanced.on_ground;
            orb.body = advanced.body;
            self.locate(index, advanced.body);
            const hazards = advanced.effects;
            orb.stuck = hazards.stuck;
            if (hazards.lava > 0) {
                orb.fire = @max(orb.fire, 300);
                _ = try self.damage(entity, @as(f32, @floatFromInt(hazards.lava)) * 4);
            }
            if (orb.alive and hazards.fire > 0) {
                orb.fire = @max(orb.fire, 160);
                _ = try self.damage(entity, @floatFromInt(hazards.fire));
            }
            if (orb.alive and hazards.cactus > 0) _ = try self.damage(entity, @floatFromInt(hazards.cactus));
            if (!orb.alive) continue;
            if (hazards.extinguish) orb.fire = 0;
            if (orb.fire == 0) orb.fire = -1;
            if (orb.ticks % 20 == 0) orb.revision +%= 1;
            orb.age += 1;
            if (orb.age >= 6000) try self.retire(index);
        }
        for (self.deps.players.activeSlots()) |player_index| {
            const player = &self.deps.players.records[player_index];
            if (player.experience_delay > 0) player.experience_delay -= 1;
            if (player.health <= 0) {
                if (self.deaths[player_index].life != player.life or !std.meta.eql(self.deaths[player_index].handle, player.handle)) {
                    if (!self.config.keep_inventory and player.gamemode != .spectator) {
                        try self.award(player.world, .{ player.position.x, player.position.y, player.position.z }, player.experience.deathReward());
                        player.experience = .{};
                    }
                    self.deaths[player_index] = .{ .handle = player.handle, .life = player.life };
                }
                continue;
            }
            if (player.stage != .ready or player.gamemode == .spectator or player.experience_delay != 0) continue;
            const reach = 1.25 + @as(f64, @as(f32, 0.6)) / 2;
            var nearby = self.spatial.rectangle(player.world, .{ @intFromFloat(@floor((player.position.x - reach) / 16)), @intFromFloat(@floor((player.position.z - reach) / 16)) }, .{ @intFromFloat(@floor((player.position.x + reach) / 16)), @intFromFloat(@floor((player.position.z + reach) / 16)) });
            var count: usize = 0;
            while (nearby.next()) |index| {
                const body = self.orbs[index].body;
                if (@abs(body.position[0] - player.position.x) >= reach or @abs(body.position[2] - player.position.z) >= reach or body.position[1] + 0.5 <= player.position.y - 0.5 or body.position[1] >= player.position.y + @as(f64, @as(f32, if (player.flags.sneaking) 1.5 else 1.8)) + 0.5) continue;
                self.candidates[count] = index;
                count += 1;
            }
            if (count == 0) continue;
            const index = self.candidates[self.random.random().uintLessThan(usize, count)];
            const orb = &self.orbs[index];
            player.experience_delay = 2;
            self.givePoints(player_index, try self.repair(player_index, orb.value));
            orb.count -= 1;
            self.pickups[self.pickup_count] = .{ .entity = self.residents[index].id, .collector = @intCast(player_index + 1) };
            self.pickup_count += 1;
            if (orb.count == 0) try self.retire(index);
        }
    }

    pub fn givePoints(self: *Experience, player: usize, amount: i32) void {
        assert(player < self.deps.players.records.len and self.deps.players.records[player].inWorld());
        if (self.deps.players.records[player].experience.pointsWithSound(amount)) |level| self.levelSound(player, level);
    }

    pub fn giveLevels(self: *Experience, player: usize, amount: i32) void {
        assert(player < self.deps.players.records.len and self.deps.players.records[player].inWorld());
        const state = &self.deps.players.records[player].experience;
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
        for ([_]u16{ 36 + @as(u16, player.selected_slot), 45, 8, 7, 6, 5 }, &slots) |at, *slot| slot.* = .{ .owner = player.uuid, .index = at };
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

    fn merge(self: *Experience, index: usize, body: entities.State) !void {
        var nearby = self.spatial.rectangle(body.world, .{ @intFromFloat(@floor((body.position[0] - 1) / 16)), @intFromFloat(@floor((body.position[2] - 1) / 16)) }, .{ @intFromFloat(@floor((body.position[0] + 1) / 16)), @intFromFloat(@floor((body.position[2] + 1) / 16)) });
        var count: usize = 0;
        while (nearby.next()) |candidate| {
            const other = self.orbs[candidate];
            if (candidate == index or other.value != self.orbs[index].value or @mod(@as(i64, @intCast(self.residents[candidate].id)) - @as(i64, @intCast(self.residents[index].id)), 40) != 0) continue;
            const at = self.orbs[candidate].body.position;
            if (@abs(at[0] - body.position[0]) >= 1 or @abs(at[1] - body.position[1]) >= 1 or @abs(at[2] - body.position[2]) >= 1) continue;
            self.candidates[count] = candidate;
            count += 1;
        }
        for (self.candidates[0..count]) |candidate| {
            const orb = &self.orbs[index];
            if (self.orbs[candidate].count > std.math.maxInt(i32) - orb.count) continue;
            orb.count += self.orbs[candidate].count;
            orb.age = @min(orb.age, self.orbs[candidate].age);
            try self.retire(candidate);
        }
    }

    pub fn checkpoint(self: *Experience, space: storage.Space) !void {
        errdefer space.fail();
        var cursor: usize = 0;
        const capacity = @min(128, self.deps.entities.cache.entries.len);
        while (cursor < self.active.values().len) {
            var ids: [128]u64 = undefined;
            var indices: [128]usize = undefined;
            var leases: [128]entities.Entities.Lease = undefined;
            var count: usize = 0;
            while (cursor < self.active.values().len and count < capacity) : (cursor += 1) {
                const index = self.active.values()[cursor];
                if (!self.orbs[index].alive) continue;
                ids[count] = self.residents[index].id;
                indices[count] = index;
                count += 1;
            }
            try self.deps.entities.acquireMany(ids[0..count], leases[0..count]);
            defer for (leases[0..count]) |lease| lease.release();
            for (indices[0..count], leases[0..count]) |index, lease| {
                if (!std.meta.eql((try lease.read()).?, self.orbs[index].body)) try lease.write(self.orbs[index].body);
            }
        }
        // Live bodies belong to this array. Their store may already have checkpointed.
        try self.deps.entities.checkpoint(self.deps.entities.deps.storage);
        var keys: [records.Table.write_batch_size][9]u8 = undefined;
        var values: [records.Table.write_batch_size][encoded_size]u8 = undefined;
        var writes: [records.Table.write_batch_size]records.Write = undefined;
        var count: usize = 0;
        for (self.saved[0..self.saved_count]) |entity| {
            if (self.ids.get(entity)) |index| if (self.orbs[index].alive) continue;
            keys[count][0] = 1;
            std.mem.writeInt(u64, keys[count][1..9], entity, .big);
            writes[count] = .{ .key = &keys[count], .value = null };
            count += 1;
            if (count == writes.len) {
                try self.table.putBatch(writes[0..count]);
                count = 0;
            }
        }
        for (self.active.values()) |index| {
            const orb = self.orbs[index];
            if (!orb.alive) continue;
            keys[count][0] = 1;
            std.mem.writeInt(u64, keys[count][1..9], self.residents[index].id, .big);
            values[count] = @splat(0);
            values[count][0] = 1;
            std.mem.writeInt(i32, values[count][1..5], orb.value, .little);
            std.mem.writeInt(i32, values[count][5..9], orb.count, .little);
            std.mem.writeInt(u16, values[count][9..11], orb.age, .little);
            std.mem.writeInt(i16, values[count][11..13], orb.health, .little);
            values[count][13] = @intFromBool(orb.on_ground);
            std.mem.writeInt(i16, values[count][14..16], orb.fire, .little);
            writes[count] = .{ .key = &keys[count], .value = &values[count] };
            count += 1;
            if (count == writes.len) {
                try self.table.putBatch(writes[0..count]);
                count = 0;
            }
        }
        if (count > 0) try self.table.putBatch(writes[0..count]);
        const random_bytes = self.random.encode();
        if (!std.mem.eql(u8, &random_bytes, &self.random.saved)) {
            try self.table.put(&.{0}, &random_bytes);
            self.random.saved = random_bytes;
        }
        self.saved_count = 0;
        for (self.active.values()) |index| if (self.orbs[index].alive) {
            self.saved[self.saved_count] = self.residents[index].id;
            self.saved_count += 1;
        };
    }
};

fn distance(position: [3]f64, player: minecraft.Position) f64 {
    return (position[0] - player.x) * (position[0] - player.x) + (position[1] - player.y) * (position[1] - player.y) + (position[2] - player.z) * (position[2] - player.z);
}
