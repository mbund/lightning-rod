const std = @import("std");
const lightning_rod = @import("lightning_rod");
const worldguard = @import("worldguard");

const storage_magic = "LRSKY003";
const persistence_key = "state";
const island_y: i16 = 80;
pub const WorldGeneration = lightning_rod.world_generation.Registry(.{
    lightning_rod.world_generation.Void{},
});

pub const hub_key = lightning_rod.world_identity.Key{ .value = 0x6c696768746e696e675f726f645f6875 };

pub fn hubDescription(seed: u64) lightning_rod.worlds.Description {
    return .{
        .key = hub_key,
        .name = "lightning_rod:skyblock_hub",
        .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.Overworld),
        .generator = WorldGeneration.generatorId(lightning_rod.world_generation.Void),
        .seed = seed,
        .spawn_x = 0,
        .spawn_y = island_y,
        .spawn_z = 0,
        .border = .{ .diameter = 1_024 },
    };
}

const Island = struct {
    owner: u128 = 0,
    owner_name: [lightning_rod.players.maximum_name_bytes]u8 = undefined,
    owner_name_len: u8 = 0,
    key: lightning_rod.world_identity.Key = .{ .value = 0 },
    handle: lightning_rod.world_identity.Handle = lightning_rod.world_identity.invalid,

    fn ownerName(self: *const Island) []const u8 {
        std.debug.assert(self.owner_name_len <= self.owner_name.len);
        return self.owner_name[0..self.owner_name_len];
    }
};

const Operation = union(enum) {
    hub,
    island,
    create,
    visit: []const u8,
    invalid,
};

pub const Skyblock = struct {
    pub const id = "example:skyblock";
    pub const Dependencies = struct {
        persistence: lightning_rod.persistence.PluginAccess,
        worlds: *lightning_rod.worlds.Worlds,
        blocks: *lightning_rod.blocks.Blocks,
        players: *lightning_rod.players.Players,
        teleportation: *lightning_rod.teleportation.Teleportation,
        outputs: *lightning_rod.Packets,
        guard: *worldguard.WorldGuard,
    };
    pub const Configuration = struct {
        seed: u64,
        maximum_islands: usize,
        maximum_key_attempts: usize,

        fn validate(self: Configuration) !void {
            if (self.maximum_islands == 0) return error.InvalidIslandCapacity;
            if (self.maximum_key_attempts == 0) return error.InvalidIslandKeyAttempts;
        }
    };
    pub const command_declarations = [_]lightning_rod.commands.Declaration{
        .{ .name = "hub" },
        .{ .name = "island", .alternatives = &.{"create"}, .greedy_argument = "operation", .executable_without_arguments = true },
        .{ .name = "is", .alternatives = &.{"create"}, .greedy_argument = "operation", .executable_without_arguments = true },
    };

    islands: []Island = &.{},
    persistence_buffer: []u8 = &.{},
    island_count: usize = 0,
    dirty: bool = false,
    deps: Dependencies,
    config: Configuration,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, settings: Configuration) !*Skyblock {
        try settings.validate();
        const self = try allocator.create(Skyblock);
        self.* = .{ .deps = deps, .config = settings };
        self.islands = try allocator.alloc(Island, settings.maximum_islands);
        self.persistence_buffer = try allocator.alloc(u8, encodedCapacity(settings.maximum_islands));
        @memset(self.islands, .{});
        const handle = self.deps.worlds.find(hub_key) orelse return error.MissingHubWorld;
        try self.deps.guard.protectWorld("skyblock_lobby", handle);
        try self.buildHub(handle);
        try self.restore();
        return self;
    }

    pub fn tick(self: *Skyblock, _: std.mem.Allocator) void {
        for (self.deps.outputs.commands.items()) |*entry| {
            if (entry.handled) continue;
            switch (parseOperation(entry.text)) {
                .hub => self.goHub(entry),
                .island => self.goIsland(entry),
                .create => self.createIsland(entry),
                .visit => |name| self.visitIsland(entry, name),
                .invalid => {},
            }
        }
    }

    pub fn checkpoint(self: *Skyblock, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        if (!self.dirty) return;
        const bytes = try self.encode();
        try writer.put(persistence_key, bytes);
        self.dirty = false;
    }

    fn markDirty(self: *Skyblock) void {
        self.dirty = true;
    }

    fn restore(self: *Skyblock) !void {
        const loaded = self.deps.persistence.load(persistence_key, self.persistence_buffer) catch |err| switch (err) {
            error.ReadFailed => return,
            else => return err,
        };
        switch (loaded) {
            .missing => {},
            .value => |length| {
                try self.decode(self.persistence_buffer[0..length]);
                try self.materialize();
            },
        }
    }

    fn goHub(self: *Skyblock, entry: *lightning_rod.commands.Entry) void {
        entry.handled = true;
        const handle = self.deps.worlds.find(hub_key) orelse
            return self.deps.outputs.system(entry.sender, "The hub is unavailable", .{});
        self.deps.teleportation.player(self.deps.outputs, entry.sender, .{
            .world = handle,
            .position = hubSpawnPosition,
        }) catch return self.deps.outputs.system(entry.sender, "Unable to teleport to the hub", .{});
        self.deps.outputs.system(entry.sender, "Teleported to the hub", .{});
    }

    fn goIsland(self: *Skyblock, entry: *lightning_rod.commands.Entry) void {
        entry.handled = true;
        const player = &self.deps.players.records[entry.sender];
        const island = self.find(player.uuid) orelse
            return self.deps.outputs.system(entry.sender, "You do not have an island. Use /island create", .{});
        self.updateOwnerName(island, player.name_slice());
        self.deps.teleportation.player(self.deps.outputs, entry.sender, islandDestination(island.*)) catch
            return self.deps.outputs.system(entry.sender, "Unable to teleport to your island", .{});
        self.deps.outputs.system(entry.sender, "Teleported to your island", .{});
    }

    fn createIsland(self: *Skyblock, entry: *lightning_rod.commands.Entry) void {
        entry.handled = true;
        const player = &self.deps.players.records[entry.sender];
        if (self.find(player.uuid)) |island| {
            self.updateOwnerName(island, player.name_slice());
            self.deps.teleportation.player(self.deps.outputs, entry.sender, islandDestination(island.*)) catch
                return self.deps.outputs.system(entry.sender, "Unable to teleport to your island", .{});
            return self.deps.outputs.system(entry.sender, "You already have an island", .{});
        }
        const island = self.reserve(player.uuid, player.name_slice()) catch |err|
            return self.deps.outputs.system(entry.sender, "Unable to create island: {s}", .{@errorName(err)});
        self.buildIsland(island.*) catch |err| {
            self.deps.worlds.destroy(island.handle) catch {};
            self.island_count -= 1;
            island.* = .{};
            return self.deps.outputs.system(entry.sender, "Unable to build island: {s}", .{@errorName(err)});
        };
        self.markDirty();
        self.deps.teleportation.player(self.deps.outputs, entry.sender, islandDestination(island.*)) catch
            return self.deps.outputs.system(entry.sender, "Island created, but teleportation failed", .{});
        self.deps.outputs.system(entry.sender, "Created your island", .{});
    }

    fn visitIsland(self: *Skyblock, entry: *lightning_rod.commands.Entry, owner_name: []const u8) void {
        entry.handled = true;
        const island = self.findByName(owner_name) orelse
            return self.deps.outputs.system(entry.sender, "No island belongs to {s}", .{owner_name});
        self.deps.teleportation.player(self.deps.outputs, entry.sender, islandDestination(island.*)) catch
            return self.deps.outputs.system(entry.sender, "Unable to visit {s}'s island", .{owner_name});
        self.deps.outputs.system(entry.sender, "Visiting {s}'s island", .{island.ownerName()});
    }

    fn reserve(self: *Skyblock, owner: u128, owner_name: []const u8) !*Island {
        if (self.island_count == self.islands.len) return error.IslandCapacity;
        if (owner_name.len > lightning_rod.players.maximum_name_bytes) return error.InvalidOwnerName;
        const index = self.island_count;
        const key = self.uniqueIslandKey(owner);
        const handle = try self.createIslandWorld(key);
        const island = &self.islands[index];
        island.* = .{
            .owner = owner,
            .key = key,
            .handle = handle,
        };
        @memcpy(island.owner_name[0..owner_name.len], owner_name);
        island.owner_name_len = @intCast(owner_name.len);
        self.island_count += 1;
        return island;
    }

    fn find(self: *Skyblock, owner: u128) ?*Island {
        for (self.islands[0..self.island_count]) |*island|
            if (island.owner == owner) return island;
        return null;
    }

    fn findByName(self: *Skyblock, name: []const u8) ?*Island {
        for (self.islands[0..self.island_count]) |*island|
            if (std.ascii.eqlIgnoreCase(island.ownerName(), name)) return island;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!std.ascii.eqlIgnoreCase(player.name_slice(), name)) continue;
            return self.find(player.uuid);
        }
        return null;
    }

    fn updateOwnerName(self: *Skyblock, island: *Island, name: []const u8) void {
        if (std.mem.eql(u8, island.ownerName(), name)) return;
        std.debug.assert(name.len <= island.owner_name.len);
        @memcpy(island.owner_name[0..name.len], name);
        island.owner_name_len = @intCast(name.len);
        self.markDirty();
    }

    fn materialize(self: *Skyblock) !void {
        for (self.islands[0..self.island_count]) |*island| {
            island.handle = self.deps.worlds.find(island.key) orelse
                try self.createIslandWorld(island.key);
            try self.buildIsland(island.*);
        }
    }

    fn uniqueIslandKey(self: *const Skyblock, owner: u128) lightning_rod.world_identity.Key {
        var value = owner ^ 0x736b79626c6f636b5f69736c616e6400;
        for (0..self.config.maximum_key_attempts) |attempt| {
            const key = lightning_rod.world_identity.Key{ .value = value };
            if (self.deps.worlds.find(key) == null) return key;
            value +%= @as(u128, attempt) + 0x9e3779b97f4a7c15;
        }
        @panic("configured island key attempts exhausted");
    }

    fn createIslandWorld(self: *Skyblock, key: lightning_rod.world_identity.Key) !lightning_rod.world_identity.Handle {
        var name_buffer: [lightning_rod.worlds.maximum_name_bytes]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "lightning_rod:skyblock/{x}", .{key.value});
        return self.deps.worlds.add(islandDescription(key, name, self.config.seed));
    }

    fn buildHub(self: *Skyblock, world: lightning_rod.world_identity.Handle) !void {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) {
            var x: i32 = -8;
            while (x <= 8) : (x += 1) {
                _ = try self.deps.blocks.setBlock(world, .{ .x = x, .y = island_y - 1, .z = z }, lightning_rod.registry_data.block_stone_default_state);
            }
        }
    }

    fn buildIsland(self: *Skyblock, island: Island) !void {
        var z: i32 = -2;
        while (z <= 2) : (z += 1) {
            var x: i32 = -2;
            while (x <= 2) : (x += 1) {
                const surface = lightning_rod.geometry.BlockPos{ .x = x, .y = island_y - 1, .z = z };
                _ = try self.deps.blocks.setBlock(island.handle, surface, lightning_rod.registry_data.block_grass_block_default_state);
                _ = try self.deps.blocks.setBlock(island.handle, .{ .x = surface.x, .y = surface.y - 1, .z = surface.z }, lightning_rod.registry_data.block_dirt_default_state);
            }
        }
        try self.buildTree(island);
    }

    fn buildTree(self: *Skyblock, island: Island) !void {
        const x = 1;
        const z = 1;
        for (island_y..island_y + 4) |y|
            _ = try self.deps.blocks.setBlock(island.handle, .{ .x = x, .y = @intCast(y), .z = z }, lightning_rod.registry_data.block_oak_log_default_state);
        const leaf = lightning_rod.registry_data.block_oak_leaves_default_state;
        for (island_y + 3..island_y + 6) |y| {
            const radius: i32 = if (y == island_y + 5) 1 else 2;
            var dz: i32 = -radius;
            while (dz <= radius) : (dz += 1) {
                var dx: i32 = -radius;
                while (dx <= radius) : (dx += 1) {
                    if (dx == 0 and dz == 0 and y < island_y + 4) continue;
                    _ = try self.deps.blocks.setBlock(island.handle, .{ .x = x + dx, .y = @intCast(y), .z = z + dz }, leaf);
                }
            }
        }
    }

    fn encode(self: *Skyblock) ![]const u8 {
        return encodeIslands(self.persistence_buffer, self.islands[0..self.island_count]);
    }

    fn decode(self: *Skyblock, bytes: []const u8) !void {
        self.island_count = try decodeIslands(self.islands, bytes);
        self.dirty = false;
    }
};

fn encodeIslands(buffer: []u8, islands: []const Island) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll(storage_magic);
    try writer.writeInt(u16, @intCast(islands.len), .little);
    for (islands) |island| {
        try writer.writeInt(u128, island.owner, .little);
        try writer.writeInt(u128, island.key.value, .little);
        try writer.writeByte(island.owner_name_len);
        try writer.writeAll(island.ownerName());
    }
    return writer.buffered();
}

fn decodeIslands(islands: []Island, bytes: []const u8) !usize {
    var reader = std.Io.Reader.fixed(bytes);
    var magic: [storage_magic.len]u8 = undefined;
    try reader.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, storage_magic)) return error.InvalidSkyblockData;
    const count = try reader.takeInt(u16, .little);
    if (count > islands.len) return error.InvalidSkyblockData;
    for (islands[0..count]) |*island| {
        island.* = .{};
        island.owner = try reader.takeInt(u128, .little);
        island.key.value = try reader.takeInt(u128, .little);
        island.owner_name_len = try reader.takeByte();
        if (island.owner_name_len > island.owner_name.len) return error.InvalidSkyblockData;
        try reader.readSliceAll(island.owner_name[0..island.owner_name_len]);
    }
    if (reader.seek != bytes.len) return error.InvalidSkyblockData;
    return count;
}

fn parseOperation(text: []const u8) Operation {
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    const command = words.next() orelse return .invalid;
    if (std.mem.eql(u8, command, "hub"))
        return if (words.next() == null) .hub else .invalid;
    if (!std.mem.eql(u8, command, "island") and !std.mem.eql(u8, command, "is"))
        return .invalid;
    const argument = words.next() orelse return .island;
    if (std.mem.eql(u8, argument, "create"))
        return if (words.next() == null) .create else .invalid;
    if (!std.mem.eql(u8, argument, "visit")) return .invalid;
    const owner_name = words.next() orelse return .invalid;
    return if (words.next() == null) .{ .visit = owner_name } else .invalid;
}

fn islandDescription(key: lightning_rod.world_identity.Key, name: []const u8, seed: u64) lightning_rod.worlds.Description {
    return .{
        .key = key,
        .name = name,
        .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.Overworld),
        .generator = WorldGeneration.generatorId(lightning_rod.world_generation.Void),
        .seed = seed ^ @as(u64, @truncate(key.value ^ (key.value >> 64))),
        .spawn_x = 0,
        .spawn_y = island_y,
        .spawn_z = 0,
        .border = .{ .diameter = 512 },
    };
}

fn islandDestination(island: Island) lightning_rod.teleportation.Destination {
    return .{
        .world = island.handle,
        .position = .{
            .x = 0.5,
            .y = @floatFromInt(island_y),
            .z = 0.5,
        },
    };
}

const hubSpawnPosition = lightning_rod.geometry.Vec3{ .x = 0.5, .y = island_y, .z = 0.5 };

fn encodedCapacity(maximum_islands: usize) usize {
    return storage_magic.len + @sizeOf(u16) +
        maximum_islands *
            (@sizeOf(u128) * 2 + @sizeOf(u8) + lightning_rod.players.maximum_name_bytes);
}

test "Skyblock commands have one unambiguous operation" {
    try expectOperation(.hub, parseOperation("hub"));
    try expectOperation(.island, parseOperation("island"));
    try expectOperation(.island, parseOperation("is"));
    try expectOperation(.create, parseOperation("island create"));
    try expectOperation(.visit, parseOperation("is visit Steve"));
    try expectOperation(.invalid, parseOperation("island create extra"));
    const visit = parseOperation("is visit Steve");
    try std.testing.expectEqualStrings("Steve", visit.visit);
}

test "every island uses local origin coordinates" {
    const first = islandDescription(.{ .value = 10 }, "test:first", 1);
    const second = islandDescription(.{ .value = 11 }, "test:second", 1);
    try std.testing.expectEqual(@as(i32, 0), first.spawn_x);
    try std.testing.expectEqual(@as(i32, 0), first.spawn_z);
    try std.testing.expectEqual(@as(i32, 0), second.spawn_x);
    try std.testing.expectEqual(@as(i32, 0), second.spawn_z);
}

test "island ownership survives persistence encoding" {
    var source_islands: [4]Island = [_]Island{.{}} ** 4;
    var restored_islands: [4]Island = [_]Island{.{}} ** 4;
    var bytes: [encodedCapacity(source_islands.len)]u8 = undefined;
    source_islands[0] = .{
        .owner = 42,
        .key = .{ .value = 91 },
    };
    @memcpy(source_islands[0].owner_name[0..5], "Steve");
    source_islands[0].owner_name_len = 5;
    const encoded = try encodeIslands(&bytes, source_islands[0..1]);
    const count = try decodeIslands(&restored_islands, encoded);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u128, 42), restored_islands[0].owner);
    try std.testing.expectEqual(@as(u128, 91), restored_islands[0].key.value);
    try std.testing.expectEqualStrings("Steve", restored_islands[0].ownerName());
}

fn expectOperation(expected: std.meta.Tag(Operation), actual: Operation) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(actual));
}
