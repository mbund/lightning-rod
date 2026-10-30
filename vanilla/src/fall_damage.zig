const std = @import("std");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const Players = @import("players.zig").Players;
const inventories = @import("inventories");
const storage = @import("storage");
const Items = @import("items.zig").Items;
const EnchantmentRegistry = @import("enchantment_registry.zig").EnchantmentRegistry;
const ClientRegistries = @import("client_registries.zig").ClientRegistries;
const EquipmentAttributes = @import("equipment_attributes.zig").EquipmentAttributes;
const Random = @import("random.zig").Random;

pub const FallDamage = struct {
    pub const id = "minecraft:fall_damage";

    pub const Configuration = struct { scratch_bytes: usize = 16 * 1024, seed: u64 = 0 };

    pub const Dependencies = struct {
        players: *Players,
        inventories: *inventories.Inventories,
        items: *Items,
        enchantments: *EnchantmentRegistry,
        attributes: *EquipmentAttributes,
        client: *ClientRegistries,
        storage: storage.Space,
    };

    const Fall = struct {
        generation: u32 = 0,
        life: u32 = 0,
        teleport_id: i32 = 0,
        y: f64 = 0,
        distance: f64 = 0,
    };

    deps: Dependencies,
    falls: []Fall,
    random: Random,
    scratch: std.heap.FixedBufferAllocator,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*FallDamage {
        if (configuration.scratch_bytes == 0) return error.InvalidConfiguration;
        const self = try allocator.create(FallDamage);
        const falls = try allocator.alloc(Fall, deps.players.records.len);
        @memset(falls, .{});
        self.* = .{ .deps = deps, .falls = falls, .random = try Random.init(configuration.seed, deps.storage), .scratch = .init(try allocator.alloc(u8, configuration.scratch_bytes)) };
        try deps.players.observeMovement(self, onMovement);
        return self;
    }

    fn onMovement(self: *FallDamage, handle: sessions.Handle, movement: minecraft.Movement) !void {
        const player = &self.deps.players.records[handle.index];
        const fall = &self.falls[handle.index];
        if (fall.generation != handle.generation or fall.life != player.life or fall.teleport_id != player.teleport_id)
            fall.* = .{ .generation = handle.generation, .life = player.life, .teleport_id = player.teleport_id, .y = player.position.y };

        const y = if (movement.position) |position| position.y else fall.y;
        if (!std.math.isFinite(y) or @abs(y) > 30_000_000) return;
        if (player.gamemode == .creative or player.gamemode == .spectator) {
            fall.distance = 0;
        } else if (y < fall.y) fall.distance += fall.y - y;
        fall.y = y;

        if (movement.on_ground) {
            const safe_distance = try self.deps.attributes.value(handle.index, "minecraft:safe_fall_distance");
            const fall_damage = @max(0, @ceil((fall.distance - safe_distance) * try self.deps.attributes.value(handle.index, "minecraft:fall_damage_multiplier")));
            if (fall_damage > 0) try self.damage(handle.index, @floatCast(fall_damage));
            fall.distance = 0;
        }
    }

    pub fn damage(self: *FallDamage, player_index: usize, amount: f32) !void {
        std.debug.assert(std.math.isFinite(amount) and amount > 0);
        const player = &self.deps.players.records[player_index];
        if (player.gamemode == .creative or player.gamemode == .spectator or player.health == 0) return;
        const registry = self.deps.client.client.get("minecraft:damage_type") orelse return error.MissingDamageRegistry;
        const source = registry.id("minecraft:fall") orelse return error.MissingFallDamage;
        var slots: [4]inventories.Slot = undefined;
        for (&slots, 0..) |*slot, index| slot.* = .{ .owner = player.uuid, .index = @intCast(5 + index) };
        var contents: [4]inventories.Contents = undefined;
        try self.deps.inventories.getMany(&slots, &contents);
        var protection: f32 = 0;
        var random = self.random.source;
        for (contents, 0..) |entry, index| {
            const stack = entry.stack orelse continue;
            const pinned = try self.deps.items.acquire(stack);
            defer pinned.release();
            self.scratch.reset();
            protection = try self.deps.enchantments.effects.modifyFloat(.{
                .item = pinned.view,
                .slot = @intCast(2 + index),
                .amount = protection,
                .channel = .damage_protection,
                .random = random.random(),
                .player = player.uuid,
                .actor = player,
                .location = .{ .world = player.world, .position = player.position },
                .scratch = &self.scratch,
                .item_tags = &self.deps.items.deps.definitions.tags,
                .damage_source = .{ .registry = registry, .id = source },
            });
        }
        const damage_value = amount * (1 - std.math.clamp(protection, 0, 20) / 25);
        self.random.source = random;
        player.health = @max(0, player.health - damage_value);
    }

    pub fn checkpoint(self: *FallDamage, space: storage.Space) !void {
        try self.random.checkpoint(space);
    }

    pub fn tick(self: *FallDamage) void {
        for (self.deps.players.activeSlots()) |index| {
            const player = &self.deps.players.records[index];
            const fall = &self.falls[index];
            const handle = player.handle orelse continue;
            if (fall.generation != handle.generation or fall.life != player.life or fall.teleport_id != player.teleport_id) {
                fall.* = .{ .generation = handle.generation, .life = player.life, .teleport_id = player.teleport_id, .y = player.position.y };
                continue;
            }

            if (!player.inWorld()) continue;

            if (player.stage != .ready or player.health == player.health_sent) continue;

            if (self.deps.players.sendHealth(player.protocol, handle, player.health))
                player.health_sent = player.health;
        }
    }
};
