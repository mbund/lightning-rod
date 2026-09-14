const std = @import("std");
const worlds = @import("worlds");
const default_worlds = @import("default_worlds.zig");
const sessions = @import("sessions");
const minecraft = @import("minecraft");
const protocols = @import("protocols");
const storage = @import("lightning_rod").storage;

const Generated = minecraft.Generated(protocols.wire);
const Input = @import("input.zig").Input;

pub const Players = struct {
    pub const id = "minecraft:players";

    pub const Configuration = struct {
        maximum: usize = 32,
        render_distance: i32 = 32,
        simulation_distance: i32 = 8,
        world: ?u32 = null,
        brand: []const u8 = "Lightning Rod v0.1.0 (Vanilla)",
        gamemode: minecraft.GameMode = .creative,
        spawn: minecraft.Position = .{ .x = 0.5, .y = 65, .z = 0.5 },
    };

    pub const Stage = enum {
        login,
        brand,
        tab,
        teleport,
        awaiting_teleport,
        health,
        ready,
        respawn,
    };

    pub const Dependencies = struct {
        sessions: *sessions.Service,
        input: *Input,
        worlds: *worlds.Worlds,
        vanilla_worlds: *default_worlds.VanillaWorlds,
    };

    pub const Player = struct {
        handle: ?sessions.Handle = null,
        uuid: u128 = 0,
        world: u32 = 0,
        teleport_id: i32 = 1,
        keep_respawn_data: bool = false,
        protocol: i32 = 0,
        name: [16]u8 = undefined,
        name_len: u8 = 0,
        position: minecraft.Position = .{ .x = 0.5, .y = 65, .z = 0.5 },
        rotation: minecraft.Rotation = .{ .yaw = 0, .pitch = 0 },
        stage: Stage = .login,
        loaded: bool = false,
        on_ground: bool = false,
        flags: minecraft.EntityFlags = .{},
        revision: u64 = 0,
        gamemode: minecraft.GameMode = .creative,
        health: f32 = 20,
        health_sent: f32 = 20,
        life: u32 = 1,
        selected_slot: u4 = 0,
        saved: [44]u8 = @splat(0),
    };

    deps: Dependencies,
    config: Configuration,
    spawn_world: u32,
    records: []Player,
    ticks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Players {
        if (config.maximum == 0 or config.maximum > 256 or config.render_distance < 2 or config.render_distance > 32 or config.simulation_distance < 1)
            return error.InvalidConfiguration;
        if (config.brand.len == 0 or config.brand.len > 256) return error.InvalidConfiguration;

        inline for (.{ config.spawn.x, config.spawn.y, config.spawn.z }) |coordinate| {
            if (!std.math.isFinite(coordinate) or @abs(coordinate) > 30_000_000) return error.InvalidConfiguration;
        }

        const self = try allocator.create(Players);
        const spawn_world = config.world orelse deps.vanilla_worlds.overworld;
        if (deps.worlds.get(spawn_world) == null) return error.UnknownWorld;
        if (config.maximum != deps.sessions.config.connections) return error.PlayerCapacityMismatch;

        const records = try allocator.alloc(Player, deps.sessions.config.connections);

        for (records) |*player| player.* = .{};

        self.* = .{ .deps = deps, .config = config, .spawn_world = spawn_world, .records = records };
        return self;
    }

    pub fn tick(self: *Players, namespace: storage.Namespace) !void {
        self.ticks += 1;

        for (self.deps.sessions.input_events) |event| switch (event) {
            .joined => |joined| {
                std.debug.assert(joined.handle.index < self.records.len);
                const player = &self.records[joined.handle.index];
                std.debug.assert(player.handle == null);
                player.* = .{
                    .handle = joined.handle,
                    .uuid = joined.uuid,
                    .protocol = joined.protocol,
                    .name = joined.name,
                    .name_len = joined.name_len,
                    .position = self.config.spawn,
                    .gamemode = self.config.gamemode,
                };
                player.world = self.spawn_world;
                var key: [16]u8 = undefined;
                std.mem.writeInt(u128, &key, player.uuid, .little);
                if (try namespace.get(&key, &player.saved)) |length| {
                    if (length != 40 and length != 44) return error.CorruptPlayer;

                    var reader = std.Io.Reader.fixed(player.saved[0..length]);
                    const version = try reader.takeByte();
                    if ((version != 1 or length != 40) and (version != 2 or length != 44)) return error.CorruptPlayer;
                    player.position = .{
                        .x = @bitCast(try reader.takeInt(u64, .little)),
                        .y = @bitCast(try reader.takeInt(u64, .little)),
                        .z = @bitCast(try reader.takeInt(u64, .little)),
                    };
                    player.rotation = .{ .yaw = @bitCast(try reader.takeInt(u32, .little)), .pitch = @bitCast(try reader.takeInt(u32, .little)) };
                    player.health = @bitCast(try reader.takeInt(u32, .little));
                    player.health_sent = player.health;
                    player.gamemode = std.enums.fromInt(minecraft.GameMode, try reader.takeByte()) orelse return error.CorruptPlayer;
                    player.flags = @bitCast(try reader.takeByte());
                    const ground = try reader.takeByte();
                    if (ground > 1 or !std.math.isFinite(player.health) or player.health < 0 or player.health > 20) return error.CorruptPlayer;

                    inline for (.{ player.position.x, player.position.y, player.position.z, player.rotation.yaw, player.rotation.pitch }) |value| {
                        if (!std.math.isFinite(value) or @abs(value) > 30_000_000) return error.CorruptPlayer;
                    }

                    player.on_ground = ground == 1;

                    if (version == 2) player.world = try reader.takeInt(u32, .little);
                    if (self.deps.worlds.get(player.world) == null) return error.UnknownWorld;
                }
            },
            .left => |handle| {
                const player = &self.records[handle.index];
                std.debug.assert(player.handle != null and std.meta.eql(player.handle.?, handle));
                player.* = .{};
            },
            .input => {},
        };

        for (self.records, 0..) |*player, index| {
            const handle = player.handle orelse continue;
            const inputs = self.deps.input.values(handle);
            var discard_input: usize = if (player.stage != .ready) inputs.len else 0;

            for (inputs, 0..) |decoded, input_index| {
                switch (decoded) {
                    .teleport_confirm => |teleport_id| {
                        if (player.stage == .awaiting_teleport and teleport_id == player.teleport_id) {
                            player.stage = .health;
                            discard_input = input_index + 1;
                        }
                    },
                    .respawn => {
                        if (player.health != 0 or player.stage != .ready) continue;
                        player.life += 1;
                        player.keep_respawn_data = false;
                        player.teleport_id = if (player.teleport_id == std.math.maxInt(i32)) 1 else player.teleport_id + 1;
                        player.world = self.spawn_world;
                        player.position = self.config.spawn;
                        player.health = 20;
                        player.health_sent = 20;
                        player.flags = .{};
                        player.on_ground = false;
                        player.loaded = false;
                        player.stage = .respawn;
                        player.revision += 1;
                    },
                    .player_loaded => {
                        if (!player.loaded) std.log.info("event=player_render_ready player={d}", .{handle.index});
                        player.loaded = true;
                    },
                    .movement => |movement| {
                        if (player.stage != .ready) continue;
                        if (movement.position) |position| {
                            if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y) or !std.math.isFinite(position.z) or @abs(position.x) > 30_000_000 or @abs(position.z) > 30_000_000 or @abs(position.y) > 30_000_000)
                                continue;
                            player.position = position;
                        }

                        if (movement.rotation) |rotation| {
                            if (!std.math.isFinite(rotation.yaw) or !std.math.isFinite(rotation.pitch)) continue;
                            player.rotation = rotation;
                        }

                        player.on_ground = movement.on_ground;
                        player.revision += 1;
                    },
                    .entity_action => |action| {
                        if (action.entity_id != handle.index + 1) continue;

                        switch (action.action) {
                            .start_sprinting => player.flags.sprinting = true,
                            .stop_sprinting => player.flags.sprinting = false,
                            else => {},
                        }

                        player.revision += 1;
                    },
                    .held_slot => |slot| {
                        if (slot < 0 or slot > 8) continue;
                        player.selected_slot = @intCast(slot);
                    },
                    .controls => |controls| {
                        player.flags.sneaking = controls.shift;
                        player.revision += 1;
                    },
                    else => {},
                }
            }

            while (player.stage != .ready) {
                if (player.stage == .awaiting_teleport) break;

                const world = self.deps.worlds.get(player.world).?;
                const value: minecraft.Output = switch (player.stage) {
                    .respawn => .{ .respawn = .{
                        .dimension_type = world.dimension.typeId(),
                        .world_name = world.name,
                        .hashed_seed = 0,
                        .gamemode = @intFromEnum(player.gamemode),
                        .sea_level = 63,
                        .keep_data = if (player.keep_respawn_data) 3 else 0,
                    } },
                    .login => .{ .login = .{
                        .entity_id = @intCast(index + 1),
                        .world_names = self.deps.worlds.names,
                        .dimension_type = world.dimension.typeId(),
                        .world_name = world.name,
                        .max_players = @intCast(self.config.maximum),
                        .view_distance = self.config.render_distance,
                        .simulation_distance = self.config.simulation_distance,
                        .hashed_seed = 0,
                        .gamemode = @intFromEnum(player.gamemode),
                        .sea_level = 63,
                    } },
                    .brand => .{ .brand = self.config.brand },
                    .tab => .{ .player_add = .{
                        .uuid = player.uuid,
                        .name = player.name[0..player.name_len],
                        .gamemode = @intFromEnum(player.gamemode),
                    } },
                    .teleport => .{ .teleport = .{
                        .id = player.teleport_id,
                        .position = player.position,
                        .velocity = .{ .x = 0, .y = 0, .z = 0 },
                        .rotation = player.rotation,
                    } },
                    .health => .{ .health = .{ .health = player.health, .food = 20, .saturation = 5 } },
                    .ready, .awaiting_teleport => unreachable,
                };
                if (!self.send(player.protocol, &.{handle}, value)) break;
                player.stage = if (player.stage == .respawn) .teleport else @enumFromInt(@intFromEnum(player.stage) + 1);
            }

            if (discard_input != 0) self.deps.input.discard(handle, discard_input);
        }
    }

    pub fn checkpoint(self: *Players, namespace: storage.Namespace) !void {
        var keys: [256][16]u8 = undefined;
        var writes: [256]storage.Write = undefined;
        var count: usize = 0;

        for (self.records) |*player| {
            if (player.handle == null) continue;

            var bytes: [44]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            try writer.writeByte(2);

            inline for (.{ player.position.x, player.position.y, player.position.z }) |value| try writer.writeInt(u64, @bitCast(value), .little);

            inline for (.{ player.rotation.yaw, player.rotation.pitch, player.health }) |value| try writer.writeInt(u32, @bitCast(value), .little);
            try writer.writeByte(@intCast(@intFromEnum(player.gamemode)));
            try writer.writeByte(@bitCast(player.flags));
            try writer.writeByte(@intFromBool(player.on_ground));
            try writer.writeInt(u32, player.world, .little);
            std.debug.assert(writer.end == bytes.len);
            if (std.mem.eql(u8, &bytes, &player.saved)) continue;
            player.saved = bytes;
            std.mem.writeInt(u128, &keys[count], player.uuid, .little);
            writes[count] = .{ .key = &keys[count], .value = &player.saved };
            count += 1;
        }

        if (count != 0) try namespace.putBatch(writes[0..count]);
    }

    pub fn send(self: *Players, protocol: i32, recipients: []const sessions.Handle, value: minecraft.Output) bool {
        self.deps.sessions.send(Generated.write, protocol, recipients, &value, 2048) catch |err| switch (err) {
            error.Backpressured, error.Closed => return false,
            else => std.debug.panic("invalid server packet: {s}", .{@errorName(err)}),
        };
        return true;
    }

    pub fn find(self: *Players, uuid: u128) ?*Player {
        for (self.records) |*player| if (player.handle != null and player.uuid == uuid and player.stage == .ready) return player;
        return null;
    }

    pub fn teleport(self: *Players, player: *Player, world: u32, position: minecraft.Position, rotation: minecraft.Rotation) !void {
        if (player.handle == null or player.stage != .ready) return error.PlayerNotReady;
        if (player.handle.?.index >= self.records.len or player != &self.records[player.handle.?.index]) return error.WrongSimulation;
        if (self.deps.worlds.get(world) == null) return error.UnknownWorld;

        inline for (.{ position.x, position.y, position.z, rotation.yaw, rotation.pitch }) |value|
            if (!std.math.isFinite(value) or @abs(value) > 30_000_000) return error.InvalidPosition;
        player.stage = if (player.world != world) .respawn else .teleport;
        player.keep_respawn_data = true;

        if (player.world != world) {
            player.loaded = false;
            player.life += 1;
        }

        player.world = world;
        player.position = position;
        player.rotation = rotation;
        player.on_ground = false;
        player.revision += 1;
        player.teleport_id = if (player.teleport_id == std.math.maxInt(i32)) 1 else player.teleport_id + 1;
    }
};
