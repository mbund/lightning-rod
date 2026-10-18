const persistent_records = @import("records");
const std = @import("std");
const wire_26_2 = @import("wire_26_2");
const wire_1_21_5 = @import("wire_1_21_5");
const worlds = @import("worlds");
const default_worlds = @import("default_worlds.zig");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const minecraft_packets = @import("minecraft_packets");
const lightning_rod = @import("lightning_rod");
const Input = @import("input.zig").Input;
const storage = lightning_rod.storage;

pub const Players = struct {
    pub const id = "minecraft:players";
    pub const maximum_players = 256;

    pub const Configuration = struct {
        maximum: usize = 32,
        render_distance: i32 = 32,
        simulation_distance: i32 = 8,
        world: ?u32 = null,
        brand: []const u8 = "Lightning Rod v0.1.0 (Vanilla)",
        gamemode: minecraft.GameMode = .creative,
        spawn: minecraft.Position = .{ .x = 0.5, .y = 65, .z = 0.5 },
        dig_observers: usize = 16,
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
        packets: *minecraft_packets.Packets,
        input: *Input,
        storage: storage.Space,
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
        configuring: bool = false,
        loaded: bool = false,
        on_ground: bool = false,
        flags: minecraft.EntityFlags = .{},
        revision: u64 = 0,
        gamemode: minecraft.GameMode = .creative,
        health: f32 = 20,
        gamemode_sent: ?minecraft.GameMode = null,
        abilities_sent: ?u8 = null,
        flying: bool = false,
        health_sent: f32 = 20,
        life: u32 = 1,
        selected_slot: u4 = 0,
        saved: [44]u8 = @splat(0),

        pub fn inWorld(self: Player) bool {
            return self.handle != null;
        }

        pub fn inPlay(self: Player) bool {
            return self.handle != null and !self.configuring and self.stage != .login and self.stage != .brand and self.stage != .tab;
        }
    };

    deps: Dependencies,
    config: Configuration,
    spawn_world: u32,
    records: []Player,
    ticks: u64 = 0,
    spatial: [maximum_players]u8 = undefined,
    spatial_count: usize = 0,
    spatial_keys: [maximum_players]SpatialKey = @splat(.{}),
    movement_observer: ?MovementObserver = null,

    dig_handlers: []DigHandler,
    dig_count: usize = 0,

    const MovementObserver = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct { call: *const fn (*anyopaque, sessions.Handle, minecraft.Movement) void };
    };
    const DigHandler = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct { call: *const fn (*anyopaque, sessions.Handle, minecraft.Dig, std.mem.Allocator) anyerror!void };
    };

    const SpatialKey = struct {
        ready: bool = false,
        world: u32 = 0,
        column: f64 = 0,
    };

    /// Refresh once before a batch of nearby queries. Records are public, so compare
    /// the sorting keys rather than relying on every writer to invalidate the index.
    pub fn refreshSpatial(self: *Players) void {
        var changed = false;
        for (self.records, self.spatial_keys[0..self.records.len]) |player, *previous| {
            const key: SpatialKey = if (player.inWorld())
                .{ .ready = true, .world = player.world, .column = @floor(player.position.x / 16) }
            else
                .{};
            changed = changed or !std.meta.eql(key, previous.*);
            previous.* = key;
        }
        if (!changed) return;
        self.spatial_count = 0;
        for (self.records, 0..) |player, index| {
            if (!player.inWorld()) continue;
            self.spatial[self.spatial_count] = @intCast(index);
            self.spatial_count += 1;
        }
        std.mem.sort(u8, self.spatial[0..self.spatial_count], self, struct {
            fn less(players: *Players, a: u8, b: u8) bool {
                const left = players.spatial_keys[a];
                const right = players.spatial_keys[b];
                if (left.world != right.world) return left.world < right.world;
                return if (left.column != right.column) left.column < right.column else a < b;
            }
        }.less);
    }

    /// Candidates in a chunk-column square, using the current spatial snapshot.
    pub fn nearby(self: *Players, world: u32, position: minecraft.Position, radius: i32) u256 {
        const x = @floor(position.x / 16);
        const z = @floor(position.z / 16);
        const distance: f64 = @floatFromInt(radius);
        var low: usize = 0;
        var high = self.spatial_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const player = self.records[self.spatial[middle]];
            if (player.world < world or (player.world == world and @floor(player.position.x / 16) < x - distance)) low = middle + 1 else high = middle;
        }
        var found: u256 = 0;
        for (self.spatial[low..self.spatial_count]) |index| {
            const player = self.records[index];
            if (player.world != world or @floor(player.position.x / 16) > x + distance) break;
            if (@abs(@floor(player.position.z / 16) - z) <= distance) found |= @as(u256, 1) << index;
        }
        return found;
    }

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Players {
        if (config.maximum == 0 or config.maximum > maximum_players or config.render_distance < 2 or config.render_distance > 32 or config.simulation_distance < 1 or config.dig_observers == 0 or config.dig_observers > 256)
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

        self.* = .{ .deps = deps, .config = config, .spawn_world = spawn_world, .records = records, .dig_handlers = try allocator.alloc(DigHandler, config.dig_observers) };
        try deps.input.onLifecycle(self, onLifecycle);
        try deps.input.on(.teleport_confirm, self, onTeleportConfirm);
        try deps.input.on(.client_command, self, onClientCommand);
        try deps.input.on(.player_loaded, self, onPlayerLoaded);
        try deps.input.on(.position, self, onPosition);
        try deps.input.on(.position_look, self, onPositionLook);
        try deps.input.on(.look, self, onLook);
        try deps.input.on(.flying, self, onGround);
        try deps.input.on(.entity_action, self, onEntityAction);
        try deps.input.on(.held_item_slot, self, onHeldSlot);
        try deps.input.on(.abilities, self, onAbilities);
        try deps.input.on(.player_input, self, onControls);
        try deps.input.on(.block_dig, self, onDig);
        return self;
    }

    fn onLifecycle(self: *Players, event: sessions.Event) !void {
        const space = self.deps.storage;
        switch (event) {
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
                    .configuring = !joined.ready,
                    .position = self.config.spawn,
                    .gamemode = self.config.gamemode,
                };
                player.world = self.spawn_world;
                var key: [16]u8 = undefined;
                std.mem.writeInt(u128, &key, player.uuid, .little);
                if (try persistent_records.Table.init(space).get(&key, &player.saved)) |length| {
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

                    inline for (.{ player.position.x, player.position.y, player.position.z }) |value| {
                        if (!std.math.isFinite(value) or @abs(value) > 30_000_000) return error.CorruptPlayer;
                    }
                    player.rotation = normalizeRotation(player.rotation) catch return error.CorruptPlayer;

                    player.on_ground = ground == 1;

                    if (version == 2) player.world = try reader.takeInt(u32, .little);
                    if (self.deps.worlds.get(player.world) == null) return error.UnknownWorld;
                }
            },
            .ready => |handle| {
                const player = &self.records[handle.index];
                std.debug.assert(player.handle != null and std.meta.eql(player.handle.?, handle));
                std.debug.assert(player.configuring);
                player.configuring = false;
                player.stage = .login;
            },
            .left => |handle| {
                const player = &self.records[handle.index];
                std.debug.assert(player.handle != null and std.meta.eql(player.handle.?, handle));
                const bytes = encodePlayer(player);
                if (!std.mem.eql(u8, &bytes, &player.saved)) {
                    var key: [16]u8 = undefined;
                    std.mem.writeInt(u128, &key, player.uuid, .little);
                    try persistent_records.Table.init(space).put(&key, &bytes);
                }
                player.* = .{};
            },
            .input => {},
        }
    }

    pub fn observeMovement(self: *Players, context: anytype, comptime handler: anytype) !void {
        if (self.movement_observer != null) return error.DuplicateMovementObserver;
        const Adapter = struct {
            const vtable: MovementObserver.VTable = .{ .call = @This().invoke };
            fn invoke(raw: *anyopaque, handle: sessions.Handle, movement: minecraft.Movement) void {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                handler(typed, handle, movement);
            }
        };
        self.movement_observer = .{ .context = context, .vtable = &Adapter.vtable };
    }

    pub fn observeDig(self: *Players, context: anytype, comptime handler: anytype) !void {
        if (self.dig_count == self.dig_handlers.len) return error.DigObserverCapacity;
        const Adapter = struct {
            const vtable: DigHandler.VTable = .{ .call = @This().invoke };
            fn invoke(raw: *anyopaque, handle: sessions.Handle, dig: minecraft.Dig, temporary: std.mem.Allocator) anyerror!void {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                comptime if (@typeInfo(@TypeOf(handler)).@"fn".params.len != 3 and @typeInfo(@TypeOf(handler)).@"fn".params.len != 4)
                    @compileError("dig observer takes context, handle, Dig, and optionally temporary allocator");
                if (comptime @typeInfo(@TypeOf(handler)).@"fn".params.len == 3)
                    try @call(.auto, handler, .{ typed, handle, dig })
                else
                    try @call(.auto, handler, .{ typed, handle, dig, temporary });
            }
        };
        self.dig_handlers[self.dig_count] = .{
            .context = context,
            .vtable = &Adapter.vtable,
        };
        self.dig_count += 1;
    }

    fn onDig(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_block_dig.Reader, temporary: std.mem.Allocator) !void {
        const action_id, const a = body.status() catch return error.InvalidPacket;
        const position, const b = a.location() catch return error.InvalidPacket;
        const face, const c = b.face() catch return error.InvalidPacket;
        const sequence, const done = c.sequence() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const dig: minecraft.Dig = .{
            .action = std.enums.fromInt(minecraft.DigAction, action_id) orelse return error.InvalidPacket,
            .position = .{ .x = position.x, .y = position.y, .z = position.z },
            .face = face,
            .sequence = sequence,
        };
        for (self.dig_handlers[0..self.dig_count]) |listener| try listener.vtable.call(listener.context, handle, dig, temporary);
    }

    fn onTeleportConfirm(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_teleport_confirm.Reader) !void {
        const teleport_id, const done = body.teleportId() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const player = &self.records[handle.index];
        if (player.stage == .awaiting_teleport and teleport_id == player.teleport_id) player.stage = .health;
    }

    fn onClientCommand(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_client_command.Reader) !void {
        const action, const done = body.actionId() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const player = &self.records[handle.index];
        if (action != 0 or player.health != 0 or player.stage != .ready) return;
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
    }

    fn onPlayerLoaded(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_player_loaded.Reader) !void {
        body.finish() catch return error.InvalidPacket;
        const player = &self.records[handle.index];
        if (!player.loaded) std.log.info("event=player_render_ready player={d}", .{handle.index});
        player.loaded = true;
    }

    fn onPosition(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_position.Reader) !void {
        const x, const a = body.x() catch return error.InvalidPacket;
        const y, const b = a.y() catch return error.InvalidPacket;
        const z, const c = b.z() catch return error.InvalidPacket;
        const flags, const done = c.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        self.applyMovement(handle, .{ .position = .{ .x = x, .y = y, .z = z }, .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision });
    }

    fn onPositionLook(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_position_look.Reader) !void {
        const x, const a = body.x() catch return error.InvalidPacket;
        const y, const b = a.y() catch return error.InvalidPacket;
        const z, const c = b.z() catch return error.InvalidPacket;
        const yaw, const d = c.yaw() catch return error.InvalidPacket;
        const pitch, const e = d.pitch() catch return error.InvalidPacket;
        const flags, const done = e.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        self.applyMovement(handle, .{ .position = .{ .x = x, .y = y, .z = z }, .rotation = .{ .yaw = yaw, .pitch = pitch }, .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision });
    }

    fn onLook(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_look.Reader) !void {
        const yaw, const a = body.yaw() catch return error.InvalidPacket;
        const pitch, const b = a.pitch() catch return error.InvalidPacket;
        const flags, const done = b.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        self.applyMovement(handle, .{ .rotation = .{ .yaw = yaw, .pitch = pitch }, .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision });
    }

    fn onGround(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_flying.Reader) !void {
        const flags, const done = body.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        self.applyMovement(handle, .{ .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision });
    }

    fn applyMovement(self: *Players, handle: sessions.Handle, movement: minecraft.Movement) void {
        const player = &self.records[handle.index];
        if (player.stage != .ready) return;
        var accepted = movement;
        if (movement.position) |position| {
            if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y) or !std.math.isFinite(position.z) or @abs(position.x) > 30_000_000 or @abs(position.y) > 30_000_000 or @abs(position.z) > 30_000_000) return;
        }
        if (movement.rotation) |rotation| accepted.rotation = normalizeRotation(rotation) catch return;
        if (accepted.position) |position| player.position = position;
        if (accepted.rotation) |rotation| player.rotation = rotation;
        player.on_ground = movement.on_ground;
        player.revision += 1;
        if (self.movement_observer) |observer| observer.vtable.call(observer.context, handle, accepted);
    }

    fn onEntityAction(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_entity_action.Reader) !void {
        const entity_id, const a = body.entityId() catch return error.InvalidPacket;
        const action_id, const b = a.actionId() catch return error.InvalidPacket;
        _, const done = b.jumpBoost() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        if (entity_id != handle.index + 1) return;
        const player = &self.records[handle.index];
        switch (std.enums.fromInt(minecraft.Action, action_id) orelse return error.InvalidPacket) {
            .start_sprinting => player.flags.sprinting = true,
            .stop_sprinting => player.flags.sprinting = false,
            else => {},
        }
        player.revision += 1;
    }

    fn onHeldSlot(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_held_item_slot.Reader) !void {
        const slot, const done = body.slotId() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        if (slot >= 0 and slot <= 8) self.records[handle.index].selected_slot = @intCast(slot);
    }

    fn onAbilities(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_abilities.Reader) !void {
        const flags, const done = body.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const player = &self.records[handle.index];
        player.flying = player.gamemode == .spectator or (player.gamemode == .creative and flags & 2 != 0);
    }

    fn onControls(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_player_input.Reader) !void {
        const controls, const done = body.inputs() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const player = &self.records[handle.index];
        player.flags.sneaking = controls.shift;
        player.revision += 1;
    }

    pub fn tick(self: *Players) !void {
        self.ticks += 1;

        for (self.records, 0..) |*player, index| {
            const handle = player.handle orelse continue;
            if (player.configuring) continue;

            while (player.stage != .ready) {
                if (player.stage == .awaiting_teleport) break;

                if (player.stage == .health) {
                    if (!self.sendHealth(player.protocol, &.{handle}, player.health)) break;
                    player.health_sent = player.health;
                    player.stage = .ready;
                    continue;
                }

                if (player.stage == .brand) {
                    if (!self.sendPacket(writeBrand, player.protocol, &.{handle}, .{self.config.brand})) break;
                    player.stage = .tab;
                    continue;
                }

                if (player.stage == .tab) {
                    if (!self.sendPlayerAdd(player.protocol, &.{handle}, player.uuid, player.name[0..player.name_len], player.gamemode)) break;
                    player.stage = .teleport;
                    continue;
                }

                if (player.stage == .teleport) {
                    if (!self.sendPacket(writeTeleport, player.protocol, &.{handle}, .{ player.teleport_id, player.position, player.rotation })) break;
                    player.stage = .awaiting_teleport;
                    continue;
                }

                const world = self.deps.worlds.get(player.world).?;
                const selected = self.deps.packets.definition(player.protocol) catch unreachable;

                if (player.stage == .respawn) {
                    if (!self.sendPacket(writeRespawn, player.protocol, &.{handle}, .{ selected, world.dimension.name, world.name, @as(i8, @intFromEnum(player.gamemode)), @as(u8, if (player.keep_respawn_data) 3 else 0) })) break;
                    player.stage = .teleport;
                    continue;
                }

                std.debug.assert(player.stage == .login);
                if (!self.sendPacket(writeLogin, player.protocol, &.{handle}, .{ selected, minecraft.Login{
                    .entity_id = @intCast(index + 1),
                    .world_names = self.deps.worlds.names,
                    .dimension_type = world.dimension.name,
                    .world_name = world.name,
                    .max_players = @intCast(self.config.maximum),
                    .view_distance = self.config.render_distance,
                    .simulation_distance = self.config.simulation_distance,
                    .hashed_seed = 0,
                    .gamemode = @intFromEnum(player.gamemode),
                    .sea_level = 63,
                } })) break;
                player.stage = .brand;
            }

            if (player.stage != .ready) continue;
            if (player.gamemode == .spectator) player.flying = true;
            if (player.gamemode == .survival or player.gamemode == .adventure) player.flying = false;
            const abilities: u8 = switch (player.gamemode) {
                .creative => 13 | (@as(u8, @intFromBool(player.flying)) << 1),
                .spectator => 7,
                .survival, .adventure => 0,
            };
            if (player.abilities_sent != abilities) {
                if (!self.sendPacket(writeAbilities, player.protocol, &.{handle}, .{abilities})) continue;
                player.abilities_sent = abilities;
            }
            if (player.gamemode_sent != player.gamemode) {
                if (!self.sendPacket(writeGameMode, player.protocol, &.{handle}, .{player.gamemode})) continue;
                player.gamemode_sent = player.gamemode;
            }
        }
    }

    pub fn checkpoint(self: *Players, space: storage.Space) !void {
        var keys: [256][16]u8 = undefined;
        var writes: [256]persistent_records.Write = undefined;
        var count: usize = 0;

        for (self.records) |*player| {
            if (player.handle == null) continue;

            const bytes = encodePlayer(player);
            if (std.mem.eql(u8, &bytes, &player.saved)) continue;
            player.saved = bytes;
            std.mem.writeInt(u128, &keys[count], player.uuid, .little);
            writes[count] = .{ .key = &keys[count], .value = &player.saved };
            count += 1;
        }

        if (count != 0) try persistent_records.Table.init(space).putBatch(writes[0..count]);
    }

    pub fn sendPacket(self: *Players, comptime encode_packet: anytype, protocol: i32, recipients: []const sessions.Handle, arguments: anytype) bool {
        self.deps.packets.sendPacket(encode_packet, protocol, recipients, arguments, 2048) catch |err| switch (err) {
            error.Backpressured, error.Closed => return false,
            else => std.debug.panic("invalid server packet: {s}", .{@errorName(err)}),
        };
        return true;
    }

    pub fn sendHealth(self: *Players, protocol: i32, recipients: []const sessions.Handle, health: f32) bool {
        return self.sendPacket(writeHealth, protocol, recipients, .{health});
    }

    pub fn sendBlockAck(self: *Players, protocol: i32, recipients: []const sessions.Handle, sequence: i32) bool {
        return self.sendPacket(writeBlockAck, protocol, recipients, .{sequence});
    }

    pub fn sendPlayerAdd(self: *Players, protocol: i32, recipients: []const sessions.Handle, uuid: u128, name: []const u8, mode: minecraft.GameMode) bool {
        return self.sendPacket(writePlayerAdd, protocol, recipients, .{ uuid, name, @as(i32, @intFromEnum(mode)) });
    }

    fn writeHealth(packet: wire_1_21_5.play.toClient.packet_update_health.Writer, health: f32) ![]u8 {
        const value = try packet.health(health);
        const food = try value.food(20);
        return (try food.foodSaturation(5)).finish();
    }

    fn writeBlockAck(packet: wire_1_21_5.play.toClient.packet_acknowledge_player_digging.Writer, sequence: i32) ![]u8 {
        return (try packet.sequenceId(sequence)).finish();
    }

    fn writeAbilities(packet: wire_1_21_5.play.toClient.packet_abilities.Writer, flags: u8) ![]u8 {
        const enabled = try packet.flags(@bitCast(flags));
        const flying = try enabled.flyingSpeed(0.05);
        return (try flying.walkingSpeed(0.1)).finish();
    }

    fn writeGameMode(packet: wire_1_21_5.play.toClient.packet_game_state_change.Writer, mode: minecraft.GameMode) ![]u8 {
        const reason = try packet.reason(3);
        return (try reason.gameMode(@floatFromInt(@intFromEnum(mode)))).finish();
    }

    fn writeBrand(packet: wire_1_21_5.play.toClient.packet_custom_payload.Writer, brand: []const u8) ![]u8 {
        if (brand.len > std.math.maxInt(i32)) return error.InvalidBrand;
        var length = brand.len;
        var prefix_bytes: usize = 1;
        while (length >= 128) : (length >>= 7) prefix_bytes += 1;

        const channel = try packet.channel("minecraft:brand");
        const payload, const done = try channel.dataUninitialized(prefix_bytes + brand.len);
        var writer = std.Io.Writer.fixed(payload);
        try writer.writeUleb128(@as(u32, @intCast(brand.len)));
        try writer.writeAll(brand);
        std.debug.assert(writer.buffered().len == payload.len);
        return done.finish();
    }

    fn writePlayerAdd(packet: wire_1_21_5.play.toClient.packet_player_info.Writer, uuid: u128, name: []const u8, mode: i32) ![]u8 {
        const action = try packet.action(.{
            .add_player = true,
            .initialize_chat = true,
            .update_game_mode = true,
            .update_listed = true,
            .update_latency = true,
            .update_display_name = true,
            .update_hat = true,
            .update_list_order = true,
        });
        var entries = try action.data(1);
        const entry = (try entries.next()).?;
        var player = try (try entry.uuid(uuid)).player();
        var present = try (try player.begin()).case_true();
        const profile = try minecraft_packets.nested(.{writeProfile}).write(try present.begin(), name);
        const named = try player.advance(try present.advance(profile));
        var chat_session = try named.chatSession();
        var chat_present = try (try chat_session.begin()).case_true();
        const chat_data = try minecraft_packets.nested(.{writeChatSession}).write(try chat_present.begin(), {});
        const chat = try chat_session.advance(try chat_present.advance(chat_data));
        var gamemode = try chat.gamemode();
        const game = try gamemode.advance(try (try gamemode.begin()).case_true(mode));
        var listed = try game.listed();
        const listing = try listed.advance(try (try listed.begin()).case_true(1));
        var latency = try listing.latency();
        const latency_value = try latency.advance(try (try latency.begin()).case_true(0));
        var display = try latency_value.displayName();
        var display_present = try (try display.begin()).case_true();
        const display_value = try display.advance(try display_present.advance(try (try display_present.begin()).none()));
        var priority = try display_value.listPriority();
        const priority_value = try priority.advance(try (try priority.begin()).case_true(0));
        var hat = try priority_value.showHat();
        try entries.advance(try hat.advance(try (try hat.begin()).case_true(true)));
        return (try entries.finish()).finish();
    }

    fn writeTeleport(packet: wire_1_21_5.play.toClient.packet_position.Writer, teleport_id: i32, position: minecraft.Position, rotation: minecraft.Rotation) ![]u8 {
        const target = try packet.teleportId(teleport_id);
        const x = try target.x(position.x);
        const y = try x.y(position.y);
        const z = try y.z(position.z);
        const vx = try z.dx(0);
        const vy = try vx.dy(0);
        const vz = try vy.dz(0);
        const yaw = try vz.yaw(rotation.yaw);
        return (try (try yaw.pitch(rotation.pitch)).flags(.{})).finish();
    }

    const writeLogin = .{ writeLogin_1_21_5, writeLogin_26_2 };

    fn writeLogin_1_21_5(packet: wire_1_21_5.play.toClient.packet_login.Writer, selected: *const sessions.Protocol, login: minecraft.Login) ![]u8 {
        return writeLoginBody(packet, selected, login, false);
    }

    fn writeLogin_26_2(packet: wire_26_2.play.toClient.packet_login.Writer, selected: *const sessions.Protocol, login: minecraft.Login) ![]u8 {
        return writeLoginBody(packet, selected, login, true);
    }

    fn writeLoginBody(packet: anytype, selected: *const sessions.Protocol, login: minecraft.Login, comptime online_mode: bool) ![]u8 {
        const dimension = try selected.registryId("minecraft:dimension_type", login.dimension_type);
        const entity = try packet.entityId(login.entity_id);
        const hardcore = try entity.isHardcore(false);
        var world_names = try hardcore.worldNames(login.world_names.len);

        for (login.world_names) |name| world_names = try world_names.element(name);
        const names = try world_names.finish();
        const maximum = try names.maxPlayers(login.max_players);
        const view = try maximum.viewDistance(login.view_distance);
        const simulation = try view.simulationDistance(login.simulation_distance);
        const debug = try simulation.reducedDebugInfo(false);
        const respawn = try debug.enableRespawnScreen(true);
        const crafting = try respawn.doLimitedCrafting(false);
        var world_state = try crafting.worldState();
        const spawn = try minecraft_packets.nested(.{writeSpawnInfo}).write(try world_state.begin(), .{ .dimension = dimension, .name = login.world_name, .seed = login.hashed_seed, .mode = login.gamemode, .sea_level = login.sea_level });
        const world_done = try world_state.advance(spawn);
        const chat_policy = if (comptime online_mode) try world_done.onlineMode(false) else world_done;
        return (try chat_policy.enforcesSecureChat(false)).finish();
    }

    fn writeRespawn(packet: wire_1_21_5.play.toClient.packet_respawn.Writer, selected: *const sessions.Protocol, dimension_name: []const u8, world_name: []const u8, mode: i8, keep_data: u8) ![]u8 {
        const dimension = try selected.registryId("minecraft:dimension_type", dimension_name);
        var world_state = try packet.worldState();
        const spawn = try minecraft_packets.nested(.{writeSpawnInfo}).write(try world_state.begin(), .{ .dimension = dimension, .name = world_name, .mode = mode });
        return (try (try world_state.advance(spawn)).copyMetadata(keep_data)).finish();
    }

    fn writeProfile(packet: wire_1_21_5.game_profile.Writer, name: []const u8) !wire_1_21_5.game_profile.Writer.Done {
        return (try (try packet.name(name)).properties(0)).finish();
    }

    fn writeChatSession(packet: wire_1_21_5.chat_session.Writer, _: void) !wire_1_21_5.chat_session.Writer.Done {
        return packet.none();
    }

    const SpawnInfo = struct { dimension: i32, name: []const u8, mode: i8, seed: i64 = 0, sea_level: i32 = 63 };

    fn writeSpawnInfo(packet: wire_1_21_5.play.toClient.SpawnInfo.Writer, args: SpawnInfo) !wire_1_21_5.play.toClient.SpawnInfo.Writer.Done {
        const identified = try packet.dimension(args.dimension);
        const named = try identified.name(args.name);
        const seeded = try named.hashedSeed(args.seed);
        const game = try seeded.gamemode(args.mode);
        const previous = try game.previousGamemode(255);
        const debug = try previous.isDebug(false);
        const flat = try debug.isFlat(false);
        var death = try flat.death();
        const none = try death.advance(try (try death.begin()).none());
        const cooldown = try none.portalCooldown(0);
        return cooldown.seaLevel(args.sea_level);
    }

    pub fn find(self: *Players, uuid: u128) ?*Player {
        for (self.records) |*player| if (player.inWorld() and player.uuid == uuid) return player;
        return null;
    }

    pub fn setGameMode(self: *Players, player: *Player, mode: minecraft.GameMode) bool {
        std.debug.assert(player.inWorld());
        std.debug.assert(player == &self.records[player.handle.?.index]);
        if (player.gamemode == mode) return false;

        player.gamemode = mode;
        player.flying = mode == .spectator or (mode == .creative and player.flying);
        player.flags.invisible = mode == .spectator;
        player.revision += 1;
        std.debug.assert(player.gamemode == mode);
        return true;
    }

    pub fn teleport(self: *Players, player: *Player, world: u32, position: minecraft.Position, rotation: minecraft.Rotation) !void {
        if (!player.inWorld()) return error.PlayerNotReady;
        if (player.handle.?.index >= self.records.len or player != &self.records[player.handle.?.index]) return error.WrongSimulation;
        if (self.deps.worlds.get(world) == null) return error.UnknownWorld;

        inline for (.{ position.x, position.y, position.z }) |value|
            if (!std.math.isFinite(value) or @abs(value) > 30_000_000) return error.InvalidPosition;
        const normalized = normalizeRotation(rotation) catch return error.InvalidPosition;
        player.stage = if (player.stage == .respawn or player.world != world) .respawn else .teleport;
        player.keep_respawn_data = true;

        if (player.world != world) {
            player.loaded = false;
            player.life += 1;
        }

        player.world = world;
        player.position = position;
        player.rotation = normalized;
        player.on_ground = false;
        player.revision += 1;
        player.teleport_id = if (player.teleport_id == std.math.maxInt(i32)) 1 else player.teleport_id + 1;
    }
};

fn encodePlayer(player: *const Players.Player) [44]u8 {
    var bytes: [44]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    writer.writeByte(2) catch unreachable;
    inline for (.{ player.position.x, player.position.y, player.position.z }) |value|
        writer.writeInt(u64, @bitCast(value), .little) catch unreachable;
    inline for (.{ player.rotation.yaw, player.rotation.pitch, player.health }) |value|
        writer.writeInt(u32, @bitCast(value), .little) catch unreachable;
    writer.writeByte(@intCast(@intFromEnum(player.gamemode))) catch unreachable;
    writer.writeByte(@bitCast(player.flags)) catch unreachable;
    writer.writeByte(@intFromBool(player.on_ground)) catch unreachable;
    writer.writeInt(u32, player.world, .little) catch unreachable;
    std.debug.assert(writer.end == bytes.len);
    return bytes;
}

fn normalizeRotation(rotation: minecraft.Rotation) error{InvalidRotation}!minecraft.Rotation {
    if (!std.math.isFinite(rotation.yaw) or !std.math.isFinite(rotation.pitch)) return error.InvalidRotation;
    const yaw = @mod(@as(f64, rotation.yaw), 360);
    return .{
        .yaw = @floatCast(if (yaw >= 180) yaw - 360 else yaw),
        .pitch = std.math.clamp(rotation.pitch, -90, 90),
    };
}

test "disconnect stages player state until the next complete checkpoint" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |previous_save| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_bytes: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/disconnect", .{directory.sub_path});
        const options: storage.Store.Options = .{ .path = path };
        var store = try storage.Store.init(std.testing.allocator, io, options);
        var open = true;
        defer if (open) store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const first = store.transaction();
        const space = try first.openSpace(Players.id);
        const dimensions = try worlds.Worlds.init(arena.allocator(), .{ .maximum = 1 }, .{ .storage = try first.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        var records: [1]Players.Player = @splat(.{});
        var players: Players = .{
            .deps = .{ .sessions = undefined, .packets = undefined, .input = undefined, .storage = space, .worlds = dimensions, .vanilla_worlds = undefined },
            .config = .{},
            .spawn_world = world,
            .records = &records,
            .dig_handlers = &.{},
        };
        const handle: sessions.Handle = .{ .index = 0, .generation = 1 };
        const joined: sessions.Event = .{ .joined = .{ .handle = handle, .uuid = 1, .protocol = 0, .name = @splat(0), .name_len = 1 } };
        try players.onLifecycle(joined);
        records[0].stage = .ready;
        if (previous_save) try players.checkpoint(space);
        _ = try store.commit(1);
        try store.waitDurable(store.lastCommit());

        const position: minecraft.Position = .{ .x = 100, .y = 70, .z = -32 };
        const rotation: minecraft.Rotation = .{ .yaw = 45, .pitch = 30 };
        players.applyMovement(handle, .{ .position = position, .rotation = rotation, .on_ground = true, .horizontal_collision = false });
        records[0].health = 7;
        records[0].gamemode = .survival;
        try players.onLifecycle(.{ .left = handle });
        try std.testing.expect(records[0].handle == null);
        try std.testing.expectEqual(@as(u64, 1), store.lastTick());
        try std.testing.expectEqual(@as(u64, 1), store.durableTick());
        try players.onLifecycle(joined);
        try std.testing.expectEqualDeep(position, records[0].position);
        try std.testing.expectEqualDeep(rotation, records[0].rotation);
        try std.testing.expectEqual(@as(f32, 7), records[0].health);
        try std.testing.expectEqual(.survival, records[0].gamemode);
        try std.testing.expect(records[0].on_ground);
        try players.onLifecycle(.{ .left = handle });
        try players.checkpoint(space);
        _ = try store.commit(2);
        try store.waitDurable(store.lastCommit());

        store.deinit();
        open = false;
        store = try storage.Store.init(std.testing.allocator, io, options);
        open = true;
        try std.testing.expectEqual(@as(u64, 2), store.durableTick());
        const reading = store.transaction();
        defer reading.fail();
        players.deps.storage = try reading.openSpace(Players.id);
        try players.onLifecycle(joined);
        try std.testing.expectEqualDeep(position, records[0].position);
        try std.testing.expectEqualDeep(rotation, records[0].rotation);
        try std.testing.expectEqual(@as(f32, 7), records[0].health);
        try std.testing.expectEqual(.survival, records[0].gamemode);
        try std.testing.expect(records[0].on_ground);
    }
}

test "rotation validation precedes movement and normalizes movement teleports and saved players" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/rotation", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const transaction = store.transaction();
    defer transaction.fail();
    const space = try transaction.openSpace(Players.id);
    const dimensions = try worlds.Worlds.init(arena.allocator(), .{ .maximum = 1 }, .{ .storage = try transaction.openSpace("worlds") });
    const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
    const handle: sessions.Handle = .{ .index = 0, .generation = 1 };
    var records: [1]Players.Player = .{.{ .handle = handle, .uuid = 1, .world = world, .name = @splat(0), .stage = .ready }};
    var players: Players = .{
        .deps = .{ .sessions = undefined, .packets = undefined, .input = undefined, .storage = space, .worlds = dimensions, .vanilla_worlds = undefined },
        .config = .{},
        .spawn_world = world,
        .records = &records,
        .dig_handlers = &.{},
    };
    const Observer = struct {
        calls: usize = 0,
        last: minecraft.Movement = undefined,

        fn moved(self: *@This(), _: sessions.Handle, movement: minecraft.Movement) void {
            self.calls += 1;
            self.last = movement;
        }
    };
    var observer: Observer = .{};
    try players.observeMovement(&observer, Observer.moved);
    const before = records[0];
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |invalid| {
        for ([_]minecraft.Rotation{ .{ .yaw = invalid, .pitch = 0 }, .{ .yaw = 0, .pitch = invalid } }) |rotation| {
            players.applyMovement(handle, .{ .position = .{ .x = 100, .y = 70, .z = -32 }, .rotation = rotation, .on_ground = true, .horizontal_collision = false });
            try std.testing.expectEqualDeep(before, records[0]);
            try std.testing.expectEqual(@as(usize, 0), observer.calls);
        }
    }
    for ([_]f32{ -std.math.floatMax(f32), -40_000_000, -540, -180, 0, 180, 540, 40_000_000, std.math.floatMax(f32) }) |yaw| {
        players.applyMovement(handle, .{ .rotation = .{ .yaw = yaw, .pitch = 1000 }, .on_ground = true, .horizontal_collision = false });
        try std.testing.expect(records[0].rotation.yaw >= -180 and records[0].rotation.yaw < 180);
        try std.testing.expectEqual(@as(f32, 90), records[0].rotation.pitch);
        try std.testing.expectEqualDeep(records[0].rotation, observer.last.rotation.?);
    }
    const position = records[0].position;
    try players.teleport(&records[0], world, position, .{ .yaw = 40_000_000, .pitch = -1000 });
    const normalized: minecraft.Rotation = .{ .yaw = 40, .pitch = -90 };
    try std.testing.expectEqualDeep(normalized, records[0].rotation);
    const teleported = records[0];
    try std.testing.expectError(error.InvalidPosition, players.teleport(&records[0], world, position, .{ .yaw = std.math.nan(f32), .pitch = 0 }));
    try std.testing.expectEqualDeep(teleported, records[0]);
    try players.checkpoint(space);
    try players.onLifecycle(.{ .left = handle });
    const joined: sessions.Event = .{ .joined = .{ .handle = handle, .uuid = 1, .protocol = 0, .name = @splat(0), .name_len = 1 } };
    try players.onLifecycle(joined);
    try std.testing.expectEqualDeep(normalized, records[0].rotation);

    records[0].rotation = .{ .yaw = 40_000_000, .pitch = -1000 };
    const saved = encodePlayer(&records[0]);
    var key: [16]u8 = undefined;
    std.mem.writeInt(u128, &key, 1, .little);
    try persistent_records.Table.init(space).put(&key, &saved);
    records[0] = .{};
    try players.onLifecycle(joined);
    try std.testing.expectEqualDeep(normalized, records[0].rotation);
}
