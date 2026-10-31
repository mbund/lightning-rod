const player_state = @import("player_state.zig");
const SpatialIndex = @import("player_spatial.zig").Index;
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
const IndexSet = lightning_rod.system.IndexSet;
const experience = @import("experience_state.zig");
const Input = @import("input.zig").Input;

pub const Players = struct {
    pub const id = "minecraft:players";
    const saved_size = player_state.encoded_size;

    pub const Configuration = struct {
        maximum: usize = 32,
        render_distance: i32 = 32,
        simulation_distance: i32 = 8,
        world: ?u32 = null,
        brand: []const u8 = "Lightning Rod v0.1.0 (Vanilla)",
        gamemode: minecraft.GameMode = .creative,
        spawn: minecraft.Position = .{ .x = 0.5, .y = 65, .z = 0.5 },
        spawn_for_player: ?*const fn (*const Player) minecraft.Position = null,
        dig_observers: usize = 16,
        world_border: ?f64 = null,
    };

    pub const Stage = player_state.Stage;

    pub const Dependencies = struct {
        record_workspaces: *persistent_records.Workspaces,
        sessions: *sessions.Service,
        packets: *minecraft_packets.Packets,
        input: *Input,
        storage: lightning_rod.storage.Space,
        worlds: *worlds.Worlds,
        vanilla_worlds: *default_worlds.VanillaWorlds,
    };

    pub const Player = player_state.Player;

    deps: Dependencies,
    config: Configuration,
    spawn_world: u32,
    records: []Player,
    ticks: u64 = 0,
    connected: IndexSet = .{ .indices = &.{}, .positions = &.{} },
    spatial: SpatialIndex = .{},
    movement_observer: ?MovementObserver = null,

    dig_handlers: []DigHandler,
    dig_count: usize = 0,

    const MovementObserver = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct { call: *const fn (*anyopaque, sessions.Handle, minecraft.Movement) anyerror!void };
    };
    const DigHandler = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct { call: *const fn (*anyopaque, sessions.Handle, minecraft.Dig, std.mem.Allocator) anyerror!void };
    };

    pub fn initIndexes(self: *Players, allocator: std.mem.Allocator) !void {
        std.debug.assert(self.spatial.nodes.len == 0);
        if (self.records.len != 0) self.connected = try IndexSet.init(allocator, self.records.len);
        self.spatial = try SpatialIndex.init(allocator, self.records.len);
    }

    pub fn rebuildIndexes(self: *Players) void {
        for (0..self.records.len) |index| self.updateIndexes(index);
    }

    fn updateIndexes(self: *Players, index: usize) void {
        std.debug.assert(index < self.records.len);
        self.track(index);
        const player = self.records[index];
        self.spatial.update(index, if (player.inWorld()) .{
            .world = player.world,
            .x = @intFromFloat(@floor(player.position.x / 16)),
            .z = @intFromFloat(@floor(player.position.z / 16)),
        } else null);
    }

    pub const Nearby = SpatialIndex.Query;

    pub fn nearby(self: *const Players, world: u32, position: minecraft.Position, radius: i32) Nearby {
        return self.spatial.query(.{ .world = world, .x = @intFromFloat(@floor(position.x / 16)), .z = @intFromFloat(@floor(position.z / 16)) }, radius);
    }

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Players {
        if (config.maximum == 0 or config.render_distance < 2 or config.render_distance > 32 or config.simulation_distance < 1 or config.dig_observers == 0 or config.dig_observers > 256)
            return error.InvalidConfiguration;
        if (config.brand.len == 0 or config.brand.len > 256) return error.InvalidConfiguration;
        if (config.world_border) |diameter| {
            if (!std.math.isFinite(diameter) or diameter < 1 or diameter > 60_000_000 or @abs(config.spawn.x) > diameter / 2 - 0.3 or @abs(config.spawn.z) > diameter / 2 - 0.3) return error.InvalidConfiguration;
        }

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
        try self.initIndexes(allocator);
        self.rebuildIndexes();
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

    pub const allocate = init;

    fn onLifecycle(self: *Players, events: []const sessions.Event) !void {
        const table = persistent_records.Table.init(self.deps.storage, self.deps.record_workspaces.resources);
        var keys: [64][17]u8 = undefined;
        var values: [64][saved_size]u8 = undefined;
        var reads: [64]persistent_records.Get = undefined;
        var writes: [64]persistent_records.Write = undefined;
        var lengths: [64]?usize = undefined;
        var begin: usize = 0;
        while (begin < events.len) {
            const kind = std.meta.activeTag(events[begin]);
            std.debug.assert(kind != .input);
            var end = begin;
            while (end < events.len and end - begin < keys.len / 2 and std.meta.activeTag(events[end]) == kind) end += 1;
            const batch = events[begin..end];
            if (kind == .joined) {
                for (batch, 0..) |event, index| {
                    const joined = event.joined;
                    std.debug.assert(joined.handle.index < self.records.len and self.records[joined.handle.index].handle == null);
                    std.mem.writeInt(u128, keys[index * 2][0..16], joined.uuid, .little);
                    keys[index * 2 + 1] = experienceKey(joined.uuid);
                    reads[index * 2] = .{ .key = keys[index * 2][0..16], .destination = &values[index * 2] };
                    reads[index * 2 + 1] = .{ .key = &keys[index * 2 + 1], .destination = &values[index * 2 + 1] };
                }
                try table.getBatch(reads[0 .. batch.len * 2], lengths[0 .. batch.len * 2]);
            }
            if (kind == .left) {
                var count: usize = 0;
                for (batch) |event| {
                    const handle = event.left;
                    const player = &self.records[handle.index];
                    std.debug.assert(std.meta.eql(player.handle, @as(?sessions.Handle, handle)));
                    const body = encodePlayer(player);
                    if (!std.mem.eql(u8, &body, &player.saved)) {
                        values[count] = body;
                        std.mem.writeInt(u128, keys[count][0..16], player.uuid, .little);
                        writes[count] = .{ .key = keys[count][0..16], .value = &values[count] };
                        count += 1;
                    }
                    const points = player.experience.encode();
                    if (!std.mem.eql(u8, &points, &player.saved_experience)) {
                        @memcpy(values[count][0..points.len], &points);
                        keys[count] = experienceKey(player.uuid);
                        writes[count] = .{ .key = &keys[count], .value = values[count][0..points.len] };
                        count += 1;
                    }
                }
                try table.putBatch(writes[0..count]);
            }
            for (batch, 0..) |event, index| {
                var saved: ?[]const u8 = null;
                var points: ?[]const u8 = null;
                if (kind == .joined) {
                    if (lengths[index * 2]) |length| saved = values[index * 2][0..length];
                    if (lengths[index * 2 + 1]) |length| points = values[index * 2 + 1][0..length];
                }
                try self.applyLifecycle(event, saved, points);
            }
            begin = end;
        }
    }

    fn applyLifecycle(self: *Players, event: sessions.Event, saved: ?[]const u8, points: ?[]const u8) !void {
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
                if (saved) |bytes| {
                    if (bytes.len != player.saved.len) return error.CorruptPlayer;
                    @memcpy(&player.saved, bytes);

                    var reader = std.Io.Reader.fixed(&player.saved);
                    const version = try reader.takeByte();
                    if (version != 3) return error.CorruptPlayer;
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

                    player.world = try reader.takeInt(u32, .little);
                    const selected_slot = try reader.takeByte();
                    if (selected_slot > 8) return error.CorruptPlayer;
                    player.selected_slot = @intCast(selected_slot);
                    if (self.deps.worlds.get(player.world) == null) return error.UnknownWorld;
                } else if (self.config.spawn_for_player) |spawn| {
                    player.position = spawn(player);
                    if (!self.insideBorder(player.position)) return error.InvalidSpawnPosition;
                    inline for (.{ player.position.x, player.position.y, player.position.z }) |value| {
                        if (!std.math.isFinite(value) or @abs(value) > 30_000_000) return error.InvalidSpawnPosition;
                    }
                }
                if (points) |bytes| {
                    player.experience = try experience.State.decode(bytes);
                    @memcpy(&player.saved_experience, bytes);
                }
                self.updateIndexes(joined.handle.index);
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
                player.* = .{};
                self.updateIndexes(handle.index);
            },
            .input => {},
        }
    }

    pub fn observeMovement(self: *Players, context: anytype, comptime handler: anytype) !void {
        if (self.movement_observer != null) return error.DuplicateMovementObserver;
        const Adapter = struct {
            const vtable: MovementObserver.VTable = .{ .call = @This().invoke };
            fn invoke(raw: *anyopaque, handle: sessions.Handle, movement: minecraft.Movement) anyerror!void {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                try handler(typed, handle, movement);
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
                comptime if (@typeInfo(@TypeOf(handler)).@"fn".param_types.len != 3 and @typeInfo(@TypeOf(handler)).@"fn".param_types.len != 4)
                    @compileError("dig observer takes context, handle, Dig, and optionally temporary allocator");
                if (comptime @typeInfo(@TypeOf(handler)).@"fn".param_types.len == 3)
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
        self.updateIndexes(handle.index);
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
        try self.applyMovement(handle, .{ .position = .{ .x = x, .y = y, .z = z }, .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision });
    }

    fn onPositionLook(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_position_look.Reader) !void {
        const x, const a = body.x() catch return error.InvalidPacket;
        const y, const b = a.y() catch return error.InvalidPacket;
        const z, const c = b.z() catch return error.InvalidPacket;
        const yaw, const d = c.yaw() catch return error.InvalidPacket;
        const pitch, const e = d.pitch() catch return error.InvalidPacket;
        const flags, const done = e.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        try self.applyMovement(handle, .{ .position = .{ .x = x, .y = y, .z = z }, .rotation = .{ .yaw = yaw, .pitch = pitch }, .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision });
    }

    fn onLook(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_look.Reader) !void {
        const yaw, const a = body.yaw() catch return error.InvalidPacket;
        const pitch, const b = a.pitch() catch return error.InvalidPacket;
        const flags, const done = b.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        try self.applyMovement(handle, .{ .rotation = .{ .yaw = yaw, .pitch = pitch }, .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision });
    }

    fn onGround(self: *Players, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_flying.Reader) !void {
        const flags, const done = body.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        try self.applyMovement(handle, .{ .on_ground = flags.onGround, .horizontal_collision = flags.hasHorizontalCollision });
    }

    fn applyMovement(self: *Players, handle: sessions.Handle, movement: minecraft.Movement) !void {
        const player = &self.records[handle.index];
        if (player.stage != .ready) return;
        var accepted = movement;
        if (movement.position) |position| {
            if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y) or !std.math.isFinite(position.z) or @abs(position.x) > 30_000_000 or @abs(position.y) > 30_000_000 or @abs(position.z) > 30_000_000) return;
            if (!self.insideBorder(position)) return;
        }
        if (movement.rotation) |rotation| accepted.rotation = normalizeRotation(rotation) catch return;
        if (accepted.position) |position| {
            player.position = position;
            self.updateIndexes(handle.index);
        }
        if (accepted.rotation) |rotation| player.rotation = rotation;
        player.on_ground = movement.on_ground;
        player.revision += 1;
        if (self.movement_observer) |observer| try observer.vtable.call(observer.context, handle, accepted);
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

    fn track(self: *Players, index: usize) void {
        std.debug.assert(self.connected.positions.len == self.records.len);
        if (self.records[index].inWorld()) {
            self.connected.insert(index);
        } else self.connected.remove(index);
    }

    pub fn activeSlots(self: *const Players) []const usize {
        return self.connected.values();
    }

    pub fn tick(self: *Players) !void {
        self.ticks += 1;
        for (self.activeSlots()) |index| {
            const player = &self.records[index];
            const handle = player.handle orelse continue;
            if (player.configuring) continue;

            while (player.stage != .ready) {
                if (player.stage == .awaiting_teleport) break;

                if (player.stage == .health) {
                    if (!self.sendHealth(player.protocol, handle, player.health)) break;
                    player.health_sent = player.health;
                    player.stage = .selection;
                    continue;
                }

                if (player.stage == .selection) {
                    if (!self.sendPacket(writeSelectedSlot, player.protocol, handle, .{player.selected_slot})) break;
                    player.stage = .ready;
                    continue;
                }

                if (player.stage == .brand) {
                    if (!self.sendPacket(writeBrand, player.protocol, handle, .{self.config.brand})) break;
                    player.stage = .tab;
                    continue;
                }

                if (player.stage == .tab) {
                    if (!self.sendPlayerAdd(player.protocol, handle, player.uuid, player.name[0..player.name_len], player.gamemode)) break;
                    player.stage = .border;
                    continue;
                }

                if (player.stage == .border) {
                    if (self.config.world_border) |diameter| {
                        if (!self.sendPacket(writeBorder, player.protocol, handle, .{diameter})) break;
                    }
                    player.stage = .teleport;
                    continue;
                }

                if (player.stage == .teleport) {
                    if (!self.sendPacket(writeTeleport, player.protocol, handle, .{ player.teleport_id, player.position, player.rotation })) break;
                    player.stage = .awaiting_teleport;
                    continue;
                }

                const world = self.deps.worlds.get(player.world).?;
                const selected = self.deps.packets.definition(player.protocol) catch unreachable;

                if (player.stage == .respawn) {
                    const targets = [_]sessions.Service.Target{.{ .handle = handle, .protocol = player.protocol }};
                    var delivered: [1]sessions.Service.Delivery = undefined;
                    const respawn = .{ selected, world.dimension.name, world.name, @as(i8, @backingInt(player.gamemode)), @as(u8, if (player.keep_respawn_data) 3 else 0) };
                    const position = .{ player.teleport_id, player.position, player.rotation };
                    if (self.config.world_border) |diameter| {
                        try self.deps.packets.fanoutGroup(.{ writeRespawn, writeBorder, writeTeleport }, &targets, .{ respawn, .{diameter}, position }, &.{ 2048, 128, 128 }, &delivered);
                    } else {
                        try self.deps.packets.fanoutGroup(.{ writeRespawn, writeTeleport }, &targets, .{ respawn, position }, &.{ 2048, 128 }, &delivered);
                    }
                    if (delivered[0] != .queued) break;
                    player.stage = .awaiting_teleport;
                    continue;
                }

                std.debug.assert(player.stage == .login);
                if (!self.sendPacket(writeLogin, player.protocol, handle, .{ selected, minecraft.Login{
                    .entity_id = @intCast(index + 1),
                    .world_names = self.deps.worlds.names,
                    .dimension_type = world.dimension.name,
                    .world_name = world.name,
                    .max_players = @intCast(self.config.maximum),
                    .view_distance = self.config.render_distance,
                    .simulation_distance = self.config.simulation_distance,
                    .hashed_seed = 0,
                    .gamemode = @backingInt(player.gamemode),
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
            if (player.gamemode_sent != player.gamemode) {
                const targets = [_]sessions.Service.Target{.{ .handle = handle, .protocol = player.protocol }};
                var delivered: [1]sessions.Service.Delivery = undefined;
                try self.deps.packets.fanoutGroup(.{ writeAbilities, writeGameMode }, &targets, .{ .{abilities}, .{player.gamemode} }, &.{ 32, 16 }, &delivered);
                if (delivered[0] != .queued) continue;
                player.abilities_sent = abilities;
                player.gamemode_sent = player.gamemode;
            } else if (player.abilities_sent != abilities) {
                if (!self.sendPacket(writeAbilities, player.protocol, handle, .{abilities})) continue;
                player.abilities_sent = abilities;
            }
        }
    }

    pub fn checkpoint(self: *Players, space: lightning_rod.storage.Space) !void {
        const table = persistent_records.Table.init(space, self.deps.record_workspaces.resources);
        var keys: [256][17]u8 = undefined;
        var writes: [256]persistent_records.Write = undefined;
        var count: usize = 0;
        errdefer space.fail();
        for (self.activeSlots()) |index| {
            const player = &self.records[index];
            if (writes.len - count < 2) {
                try table.putBatch(writes[0..count]);
                count = 0;
            }
            const bytes = encodePlayer(player);
            if (!std.mem.eql(u8, &bytes, &player.saved)) {
                player.saved = bytes;
                std.mem.writeInt(u128, keys[count][0..16], player.uuid, .little);
                writes[count] = .{ .key = keys[count][0..16], .value = &player.saved };
                count += 1;
            }
            const points = player.experience.encode();
            if (!std.mem.eql(u8, &points, &player.saved_experience)) {
                player.saved_experience = points;
                keys[count] = experienceKey(player.uuid);
                writes[count] = .{ .key = &keys[count], .value = &player.saved_experience };
                count += 1;
            }
        }
        if (count != 0) try table.putBatch(writes[0..count]);
    }

    pub fn sendPacket(self: *Players, comptime encode_packet: anytype, protocol: i32, recipient: sessions.Handle, arguments: anytype) bool {
        self.deps.packets.sendPacket(encode_packet, protocol, recipient, arguments, 2048) catch |err| switch (err) {
            error.Backpressured, error.Closed => return false,
            else => std.debug.panic("invalid server packet: {s}", .{@errorName(err)}),
        };
        return true;
    }

    pub fn sendHealth(self: *Players, protocol: i32, recipient: sessions.Handle, health: f32) bool {
        return self.sendPacket(writeHealth, protocol, recipient, .{health});
    }

    pub fn sendBlockAck(self: *Players, protocol: i32, recipient: sessions.Handle, sequence: i32) bool {
        return self.sendPacket(writeBlockAck, protocol, recipient, .{sequence});
    }

    pub fn sendPlayerAdd(self: *Players, protocol: i32, recipient: sessions.Handle, uuid: u128, name: []const u8, mode: minecraft.GameMode) bool {
        return self.sendPacket(writePlayerAdd, protocol, recipient, .{ uuid, name, @as(i32, @backingInt(mode)) });
    }

    fn writeSelectedSlot(packet: wire_1_21_5.play.toClient.packet_held_item_slot.Writer, slot: u4) ![]u8 {
        std.debug.assert(slot <= 8);
        return (try packet.slot(slot)).finish();
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
        return (try reason.gameMode(@floatFromInt(@backingInt(mode)))).finish();
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

    pub fn writePlayerAdd(packet: wire_1_21_5.play.toClient.packet_player_info.Writer, uuid: u128, name: []const u8, mode: i32) ![]u8 {
        return writePlayerProfile(packet, uuid, name, mode, true);
    }

    pub fn writePlayerProfile(packet: wire_1_21_5.play.toClient.packet_player_info.Writer, uuid: u128, name: []const u8, mode: i32, is_listed: bool) ![]u8 {
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
        const listing = try listed.advance(try (try listed.begin()).case_true(@intFromBool(is_listed)));
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
        if (!self.insideBorder(position)) return error.InvalidPosition;
        const normalized = normalizeRotation(rotation) catch return error.InvalidPosition;
        player.stage = if (player.stage == .respawn or player.world != world) .respawn else .teleport;
        player.keep_respawn_data = true;

        if (player.world != world) {
            player.loaded = false;
            player.life += 1;
        }

        player.world = world;
        player.position = position;
        self.updateIndexes(player.handle.?.index);
        player.rotation = normalized;
        player.on_ground = false;
        player.revision += 1;
        player.teleport_id = if (player.teleport_id == std.math.maxInt(i32)) 1 else player.teleport_id + 1;
    }

    pub fn insideBorder(self: *const Players, position: minecraft.Position) bool {
        const diameter = self.config.world_border orelse return true;
        return @abs(position.x) <= diameter / 2 - 0.3 and @abs(position.z) <= diameter / 2 - 0.3;
    }

    fn writeBorder(packet: wire_1_21_5.play.toClient.packet_initialize_world_border.Writer, diameter: f64) ![]u8 {
        const x = try packet.x(0);
        const z = try x.z(0);
        const old = try z.oldDiameter(diameter);
        const next = try old.newDiameter(diameter);
        const speed = try next.speed(0);
        const boundary = try speed.portalTeleportBoundary(29_999_984);
        const blocks = try boundary.warningBlocks(5);
        return (try blocks.warningTime(15)).finish();
    }
};

fn encodePlayer(player: *const Players.Player) [Players.saved_size]u8 {
    std.debug.assert(player.selected_slot <= 8);
    var bytes: [Players.saved_size]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    writer.writeByte(3) catch unreachable;
    inline for (.{ player.position.x, player.position.y, player.position.z }) |value|
        writer.writeInt(u64, @bitCast(value), .little) catch unreachable;
    inline for (.{ player.rotation.yaw, player.rotation.pitch, player.health }) |value|
        writer.writeInt(u32, @bitCast(value), .little) catch unreachable;
    writer.writeByte(@intCast(@backingInt(player.gamemode))) catch unreachable;
    writer.writeByte(@bitCast(player.flags)) catch unreachable;
    writer.writeByte(@intFromBool(player.on_ground)) catch unreachable;
    writer.writeInt(u32, player.world, .little) catch unreachable;
    writer.writeByte(player.selected_slot) catch unreachable;
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
    const record_workspaces = try persistent_records.Workspaces.init(std.testing.allocator, std.testing.io, .{});
    defer {
        record_workspaces.resources.deinit();
        std.testing.allocator.destroy(record_workspaces);
    }
    const Spawn = struct {
        fn select(player: *const Players.Player) minecraft.Position {
            return .{ .x = @floatFromInt(player.uuid), .y = 65, .z = -32 };
        }
    };
    const io = std.testing.io;
    for ([_]bool{ false, true }) |previous_save| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_bytes: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/disconnect", .{directory.sub_path});
        const options: lightning_rod.storage.Store.Options = .{ .path = path };
        var store = try lightning_rod.storage.Store.init(std.testing.allocator, io, options);
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
            .deps = .{ .sessions = undefined, .packets = undefined, .input = undefined, .storage = space, .worlds = dimensions, .vanilla_worlds = undefined, .record_workspaces = record_workspaces },
            .config = .{ .spawn_for_player = if (previous_save) Spawn.select else null },
            .spawn_world = world,
            .records = &records,
            .dig_handlers = &.{},
        };
        try players.initIndexes(arena.allocator());
        players.rebuildIndexes();
        const handle: sessions.Handle = .{ .index = 0, .generation = 1 };
        const joined: sessions.Event = .{ .joined = .{ .handle = handle, .uuid = 1, .protocol = 0, .name = @splat(0), .name_len = 1 } };
        try players.onLifecycle(&.{joined});
        try std.testing.expectEqualDeep(if (previous_save) Spawn.select(&records[0]) else players.config.spawn, records[0].position);
        records[0].stage = .ready;
        if (previous_save) try players.checkpoint(space);
        _ = try store.commit(1);
        try store.waitDurable(store.lastCommit());

        const position: minecraft.Position = .{ .x = 100, .y = 70, .z = -32 };
        const rotation: minecraft.Rotation = .{ .yaw = 45, .pitch = 30 };
        try players.applyMovement(handle, .{ .position = position, .rotation = rotation, .on_ground = true, .horizontal_collision = false });
        records[0].health = 7;
        records[0].selected_slot = 8;
        records[0].experience = .{ .progress = 0.5, .level = 7, .total = 101, .score = 101 };
        records[0].gamemode = .survival;
        try players.onLifecycle(&.{.{ .left = handle }});
        try std.testing.expect(records[0].handle == null);
        try std.testing.expectEqual(@as(u64, 1), store.lastTick());
        try std.testing.expectEqual(@as(u64, 1), store.durableTick());
        try players.onLifecycle(&.{joined});
        try std.testing.expectEqualDeep(position, records[0].position);
        try std.testing.expectEqualDeep(rotation, records[0].rotation);
        try std.testing.expectEqual(@as(f32, 7), records[0].health);
        try std.testing.expectEqual(.survival, records[0].gamemode);
        try std.testing.expectEqual(@as(u4, 8), records[0].selected_slot);
        try std.testing.expectEqualDeep(experience.State{ .progress = 0.5, .level = 7, .total = 101, .score = 101 }, records[0].experience);
        try std.testing.expect(records[0].on_ground);
        try players.onLifecycle(&.{.{ .left = handle }});
        try players.checkpoint(space);
        _ = try store.commit(2);
        try store.waitDurable(store.lastCommit());

        store.deinit();
        open = false;
        store = try lightning_rod.storage.Store.init(std.testing.allocator, io, options);
        open = true;
        try std.testing.expectEqual(@as(u64, 2), store.durableTick());
        const reading = store.transaction();
        defer reading.fail();
        players.deps.storage = try reading.openSpace(Players.id);
        try players.onLifecycle(&.{joined});
        try std.testing.expectEqualDeep(position, records[0].position);
        try std.testing.expectEqualDeep(rotation, records[0].rotation);
        try std.testing.expectEqual(@as(f32, 7), records[0].health);
        try std.testing.expectEqual(.survival, records[0].gamemode);
        try std.testing.expectEqual(@as(u4, 8), records[0].selected_slot);
        try std.testing.expectEqualDeep(experience.State{ .progress = 0.5, .level = 7, .total = 101, .score = 101 }, records[0].experience);
        try std.testing.expect(records[0].on_ground);
    }
}

test "rotation validation precedes movement and normalizes movement teleports and saved players" {
    const table_resources = try persistent_records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    var record_workspaces: persistent_records.Workspaces = .{ .resources = table_resources };
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/rotation", .{directory.sub_path});
    var store = try lightning_rod.storage.Store.init(std.testing.allocator, io, .{ .path = path });
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
        .deps = .{ .sessions = undefined, .packets = undefined, .input = undefined, .storage = space, .worlds = dimensions, .vanilla_worlds = undefined, .record_workspaces = &record_workspaces },
        .config = .{},
        .spawn_world = world,
        .records = &records,
        .dig_handlers = &.{},
    };
    try players.initIndexes(arena.allocator());
    players.rebuildIndexes();
    const Observer = struct {
        calls: usize = 0,
        last: minecraft.Movement = undefined,

        fn moved(self: *@This(), _: sessions.Handle, movement: minecraft.Movement) !void {
            self.calls += 1;
            self.last = movement;
        }
    };
    var observer: Observer = .{};
    try players.observeMovement(&observer, Observer.moved);
    const before = records[0];
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |invalid| {
        for ([_]minecraft.Rotation{ .{ .yaw = invalid, .pitch = 0 }, .{ .yaw = 0, .pitch = invalid } }) |rotation| {
            try players.applyMovement(handle, .{ .position = .{ .x = 100, .y = 70, .z = -32 }, .rotation = rotation, .on_ground = true, .horizontal_collision = false });
            try std.testing.expectEqualDeep(before, records[0]);
            try std.testing.expectEqual(@as(usize, 0), observer.calls);
        }
    }
    for ([_]f32{ -std.math.floatMax(f32), -40_000_000, -540, -180, 0, 180, 540, 40_000_000, std.math.floatMax(f32) }) |yaw| {
        try players.applyMovement(handle, .{ .rotation = .{ .yaw = yaw, .pitch = 1000 }, .on_ground = true, .horizontal_collision = false });
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
    try players.onLifecycle(&.{.{ .left = handle }});
    const joined: sessions.Event = .{ .joined = .{ .handle = handle, .uuid = 1, .protocol = 0, .name = @splat(0), .name_len = 1 } };
    try players.onLifecycle(&.{joined});
    try std.testing.expectEqualDeep(normalized, records[0].rotation);

    records[0].rotation = .{ .yaw = 40_000_000, .pitch = -1000 };
    const saved = encodePlayer(&records[0]);
    var key: [16]u8 = undefined;
    std.mem.writeInt(u128, &key, 1, .little);
    try persistent_records.Table.init(space, table_resources).put(&key, &saved);
    records[0] = .{};
    try players.onLifecycle(&.{joined});
    try std.testing.expectEqualDeep(normalized, records[0].rotation);

    var invalid = saved;
    invalid[invalid.len - 1] = 9;
    try persistent_records.Table.init(space, table_resources).put(&key, &invalid);
    records[0] = .{};
    try std.testing.expectError(error.CorruptPlayer, players.onLifecycle(&.{joined}));
}

test "lifecycle batches preserve saved state and leave rejoin ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/lifecycle-batch", .{temporary.sub_path});
    var store = try lightning_rod.storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer store.deinit();
    const resources = try persistent_records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 });
    defer resources.deinit();
    var workspaces: persistent_records.Workspaces = .{ .resources = resources };
    const space = try store.openSpace(Players.id);
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
    const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
    var rows: [3]Players.Player = @splat(.{});
    var players: Players = .{
        .deps = .{ .sessions = undefined, .packets = undefined, .input = undefined, .storage = space, .worlds = dimensions, .vanilla_worlds = undefined, .record_workspaces = &workspaces },
        .config = .{},
        .spawn_world = world,
        .records = &rows,
        .dig_handlers = &.{},
    };
    try players.initIndexes(arena.allocator());
    players.rebuildIndexes();
    var joins: [3]sessions.Event = undefined;
    var departures: [3]sessions.Event = undefined;
    for (&joins, &departures, 0..) |*join, *departure, index| {
        const handle: sessions.Handle = .{ .index = @intCast(index), .generation = 1 };
        join.* = .{ .joined = .{ .handle = handle, .uuid = index + 1, .protocol = 0, .name = @splat(0), .name_len = 1 } };
        departure.* = .{ .left = handle };
    }
    try players.onLifecycle(&joins);
    for (&rows, 0..) |*row, index| {
        row.selected_slot = @intCast(index + 1);
        row.position.x = @floatFromInt(index * 10);
    }
    try players.onLifecycle(&departures);
    try players.onLifecycle(&joins);
    for (rows, 0..) |row, index| {
        try std.testing.expectEqual(index + 1, row.selected_slot);
        try std.testing.expectEqual(@as(f64, @floatFromInt(index * 10)), row.position.x);
    }
    rows[0].selected_slot = 8;
    rows[1].selected_slot = 7;
    try players.onLifecycle(&.{ departures[0], joins[0], departures[1], joins[1] });
    try std.testing.expectEqual(@as(u4, 8), rows[0].selected_slot);
    try std.testing.expectEqual(@as(u4, 7), rows[1].selected_slot);
}

test "incremental player spatial updates match direct neighborhood queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var records: [64]Players.Player = @splat(.{});
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(arena.allocator());
    players.rebuildIndexes();
    var random = std.Random.DefaultPrng.init(0);
    for (0..2048) |_| {
        const index = random.random().uintLessThan(usize, records.len);
        records[index].handle = if (random.random().boolean()) .{ .index = @intCast(index), .generation = 1 } else null;
        records[index].world = random.random().uintLessThan(u32, 3);
        records[index].position = .{ .x = @as(f64, @floatFromInt(random.random().uintLessThan(u32, 64))) - 32, .y = 65, .z = @as(f64, @floatFromInt(random.random().uintLessThan(u32, 64))) - 32 };
        players.updateIndexes(index);
        const world = random.random().uintLessThan(u32, 3);
        const position = records[random.random().uintLessThan(usize, records.len)].position;
        var expected: [64]bool = @splat(false);
        for (records, 0..) |player, at| {
            if (!player.inWorld() or player.world != world) continue;
            if (@abs(@floor(player.position.x / 16) - @floor(position.x / 16)) <= 1 and @abs(@floor(player.position.z / 16) - @floor(position.z / 16)) <= 1)
                expected[at] = true;
        }
        var actual: [64]bool = @splat(false);
        var nearby = players.nearby(world, position, 1);
        while (nearby.next()) |at| {
            try std.testing.expect(!actual[at]);
            actual[at] = true;
        }
        try std.testing.expectEqualSlices(bool, &expected, &actual);
        try std.testing.expectEqual(players.activeSlots().len, players.spatial.active.count);
    }
}

test "nearby queries bound candidate work along either axis and retain inclusive boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows: [513]Players.Player = undefined;
    for (0..2) |axis| {
        for (&rows, 0..) |*player, index| player.* = .{
            .handle = .{ .index = @intCast(index), .generation = 1 },
            .uuid = index + 1,
            .position = .{ .x = if (axis == 0) @as(f64, @floatFromInt(index * 128)) else 0, .y = 65, .z = if (axis == 1) @as(f64, @floatFromInt(index * 128)) else 0 },
        };
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &rows, .dig_handlers = &.{} };
        try players.initIndexes(arena.allocator());
        players.rebuildIndexes();
        var visited: usize = 0;
        for (0..1024) |number| {
            const index = number % rows.len;
            var query = players.nearby(0, rows[index].position, 1);
            try std.testing.expectEqual(index, query.next().?);
            try std.testing.expectEqual(null, query.next());
            visited += query.visited;
        }
        try std.testing.expect(visited <= 4096);
        try expectNearby(players.nearby(1, rows[0].position, 32), &.{});
        const boundary: minecraft.Position = .{ .x = if (axis == 0) -16 else 0, .y = 65, .z = if (axis == 1) -16 else 0 };
        try expectNearby(players.nearby(0, boundary, 1), &.{0});
        try expectNearby(players.nearby(0, boundary, 0), &.{});
    }
}

test "full capacity spatial updates preserve neighborhoods through movement removal and rejoin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows: [513]Players.Player = undefined;
    for (&rows, 0..) |*row, index| row.* = .{
        .handle = .{ .index = @intCast(index), .generation = 1 },
        .uuid = index + 1,
        .position = .{ .x = @as(f64, @floatFromInt(index)) * 16 + 15.9, .y = 65, .z = 8 },
    };
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &rows, .dig_handlers = &.{} };
    try players.initIndexes(arena.allocator());
    players.rebuildIndexes();
    for (&rows, 0..) |*row, index| {
        row.position.x += 0.2;
        players.updateIndexes(index);
    }
    for (rows, 0..) |row, index| try expectNearby(players.nearby(row.world, row.position, 0), &.{index});
    rows[255].handle = null;
    players.updateIndexes(255);
    rows[255].handle = .{ .index = 255, .generation = 2 };
    players.updateIndexes(255);
    var random = std.Random.DefaultPrng.init(20261025);
    for (0..2048) |step| {
        const index = random.random().uintLessThan(usize, rows.len);
        rows[index].handle = if (random.random().boolean()) .{ .index = @intCast(index), .generation = 3 } else null;
        rows[index].world = random.random().uintLessThan(u32, 3);
        rows[index].position.x = @floatFromInt(random.random().intRangeAtMost(i32, -512, 512));
        rows[index].position.z = @floatFromInt(random.random().intRangeAtMost(i32, -512, 512));
        players.updateIndexes(index);
        if (step % 16 == 0) {
            var rebuilt: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &rows, .dig_handlers = &.{} };
            try rebuilt.initIndexes(arena.allocator());
            rebuilt.rebuildIndexes();
            for (rows) |row| {
                var expected: [513]bool = @splat(false);
                var actual: [513]bool = @splat(false);
                var before = rebuilt.nearby(row.world, row.position, 1);
                var after = players.nearby(row.world, row.position, 1);
                while (before.next()) |slot| expected[slot] = true;
                while (after.next()) |slot| actual[slot] = true;
                try std.testing.expectEqualSlices(bool, &expected, &actual);
            }
        }
    }
}

fn expectNearby(query: Players.Nearby, expected: []const usize) !void {
    var iterator = query;
    for (expected) |index| try std.testing.expectEqual(index, iterator.next().?);
    try std.testing.expectEqual(null, iterator.next());
}

test "player spatial indexes preserve slots beyond sixteen bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const records = try allocator.alloc(Players.Player, 65_537);
    @memset(records, .{});
    records[65_536] = .{ .handle = .{ .index = 65_536, .generation = 1 }, .world = 4, .position = .{ .x = 8, .y = 65, .z = 8 } };
    var players: Players = .{ .deps = undefined, .config = .{ .maximum = records.len }, .spawn_world = 4, .records = records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    try expectNearby(players.nearby(4, records[65_536].position, 0), &.{65_536});
    records[65_536].position.x = 1024;
    players.updateIndexes(65_536);
    try expectNearby(players.nearby(4, records[65_536].position, 0), &.{65_536});
    records[65_536].handle = null;
    players.updateIndexes(65_536);
    try expectNearby(players.nearby(4, records[65_536].position, 0), &.{});
}

fn experienceKey(uuid: u128) [17]u8 {
    var key: [17]u8 = undefined;
    key[0] = 1;
    std.mem.writeInt(u128, key[1..17], uuid, .little);
    return key;
}
