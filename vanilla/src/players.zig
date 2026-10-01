const std = @import("std");
const wire_26_2 = @import("wire_26_2");
const wire_1_21_5 = @import("wire_1_21_5");
const worlds = @import("worlds");
const default_worlds = @import("default_worlds.zig");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const minecraft_packets = @import("minecraft_packets");
const lightning_rod = @import("lightning_rod");
const storage = lightning_rod.storage;

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
        storage: storage.Namespace,
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
        gamemode_sent: ?minecraft.GameMode = null,
        abilities_sent: ?u8 = null,
        flying: bool = false,
        health_sent: f32 = 20,
        life: u32 = 1,
        selected_slot: u4 = 0,
        saved: [44]u8 = @splat(0),

        pub fn inPlay(self: Player) bool {
            return self.handle != null and self.stage != .login and self.stage != .brand and self.stage != .tab;
        }
    };

    deps: Dependencies,
    config: Configuration,
    spawn_world: u32,
    records: []Player,
    ticks: u64 = 0,
    movement_context: ?*anyopaque = null,
    movement_handler: ?*const fn (*anyopaque, sessions.Handle, minecraft.Movement) void = null,
    dig_handlers: []DigHandler,
    dig_count: usize = 0,

    const DigHandler = struct {
        context: *anyopaque,
        call: *const fn (*anyopaque, sessions.Handle, minecraft.Dig, std.mem.Allocator) anyerror!void,
    };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Players {
        if (config.maximum == 0 or config.maximum > 256 or config.render_distance < 2 or config.render_distance > 32 or config.simulation_distance < 1 or config.dig_observers == 0 or config.dig_observers > 256)
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
        const namespace = self.deps.storage;
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
        }
    }

    pub fn observeMovement(self: *Players, context: anytype, comptime handler: anytype) !void {
        if (self.movement_handler != null) return error.DuplicateMovementObserver;
        self.movement_context = context;
        self.movement_handler = struct {
            fn call(raw: *anyopaque, handle: sessions.Handle, movement: minecraft.Movement) void {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                @call(.auto, handler, .{ typed, handle, movement });
            }
        }.call;
    }

    pub fn observeDig(self: *Players, context: anytype, comptime handler: anytype) !void {
        if (self.dig_count == self.dig_handlers.len) return error.DigObserverCapacity;
        self.dig_handlers[self.dig_count] = .{
            .context = context,
            .call = struct {
                fn call(raw: *anyopaque, handle: sessions.Handle, dig: minecraft.Dig, temporary: std.mem.Allocator) anyerror!void {
                    const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                    comptime if (@typeInfo(@TypeOf(handler)).@"fn".params.len != 3 and @typeInfo(@TypeOf(handler)).@"fn".params.len != 4)
                        @compileError("dig observer takes context, handle, Dig, and optionally temporary allocator");
                    if (comptime @typeInfo(@TypeOf(handler)).@"fn".params.len == 3)
                        try @call(.auto, handler, .{ typed, handle, dig })
                    else
                        try @call(.auto, handler, .{ typed, handle, dig, temporary });
                }
            }.call,
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
        for (self.dig_handlers[0..self.dig_count]) |listener| try listener.call(listener.context, handle, dig, temporary);
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
        if (movement.position) |position| {
            if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y) or !std.math.isFinite(position.z) or @abs(position.x) > 30_000_000 or @abs(position.y) > 30_000_000 or @abs(position.z) > 30_000_000) return;
            player.position = position;
        }
        if (movement.rotation) |rotation| {
            if (!std.math.isFinite(rotation.yaw) or !std.math.isFinite(rotation.pitch)) return;
            player.rotation = rotation;
        }
        player.on_ground = movement.on_ground;
        player.revision += 1;
        if (self.movement_handler) |handler| handler(self.movement_context.?, handle, movement);
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

    pub fn tick(self: *Players, namespace: storage.Namespace) !void {
        _ = namespace;
        self.ticks += 1;

        for (self.records, 0..) |*player, index| {
            const handle = player.handle orelse continue;

            while (player.stage != .ready) {
                if (player.stage == .awaiting_teleport) break;

                if (player.stage == .health) {
                    if (!self.sendHealth(player.protocol, &.{handle}, player.health)) break;
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
        for (self.records) |*player| if (player.inPlay() and player.uuid == uuid) return player;
        return null;
    }

    pub fn setGameMode(self: *Players, player: *Player, mode: minecraft.GameMode) bool {
        std.debug.assert(player.inPlay());
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
        if (!player.inPlay()) return error.PlayerNotReady;
        if (player.handle.?.index >= self.records.len or player != &self.records[player.handle.?.index]) return error.WrongSimulation;
        if (self.deps.worlds.get(world) == null) return error.UnknownWorld;

        inline for (.{ position.x, position.y, position.z, rotation.yaw, rotation.pitch }) |value|
            if (!std.math.isFinite(value) or @abs(value) > 30_000_000) return error.InvalidPosition;
        player.stage = if (player.stage == .respawn or player.world != world) .respawn else .teleport;
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
