const chat_batch = @import("chat.zig");
const command_batch = @import("commands.zig");
const core_exchange = @import("core_exchange.zig");
const entity_store = @import("world/entities.zig");
const block_store = @import("world/blocks.zig");
const geometry = @import("world/geometry.zig");
const input_state = @import("world/inputs.zig");
const packet_args = @import("packet_args.zig");
const players = @import("world/players.zig");
const protocol_versions = @import("protocol_versions.zig");
const protocol_support = @import("protocol_support");
const protocol_values = @import("protocol_values.zig");
const registry = @import("registry_data");
const session_settings = @import("sessions.zig");
const std = @import("std");
const world_identity = @import("world/identity.zig");
const worlds = @import("world/worlds.zig");
const version = @import("version.zig");

pub const Packets = struct {
    pub const id = "lightning_rod:packets";
    pub const BootstrapAction = enum(u8) {
        play_login,
        respawn,
        abilities,
        held_item,
        combat_attributes,
        view_center,
        spawn_position,
        start_waiting_for_chunks,
    };
    const EntityClass = enum(u8) { player, living, item };
    const EntityUpdate = enum { spawn, move, metadata, equipment };
    const Failure = enum { input_full, temporary_full };
    const Acknowledgement = struct { slot: u16, sequence: i32 };
    pub const Configuration = struct {
        maximum_input_packets: usize = 4096,
        input_byte_capacity: usize = 256 * 1024,
        maximum_player_messages: usize = 256,
        maximum_sounds: u16 = 255,
        view_distance_chunks: i32 = 32,
        simulation_distance_chunks: i32 = 12,
        brand: []const u8 = version.brand,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_input_packets == 0 or self.maximum_input_packets > std.math.maxInt(u16) or
                self.input_byte_capacity == 0 or self.maximum_player_messages == 0 or self.maximum_sounds == 0 or self.maximum_sounds > 255 or
                self.view_distance_chunks < 0 or self.simulation_distance_chunks < 0 or self.brand.len == 0 or self.brand.len > 240)
                return error.InvalidPacketCapacity;
        }
    };
    pub const Dependencies = struct {
        inputs: *input_state.Inputs,
        blocks: *block_store.Blocks,
        players: *players.Players,
        containers: *players.Containers,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        worlds: *worlds.Worlds,
        sessions: *session_settings.Sessions,
    };

    deps: Dependencies,
    config: Configuration,
    input: core_exchange.InputBatch,
    chats: chat_batch.Batch,
    commands: command_batch.Batch,
    packet_views: []const core_exchange.PacketView = &.{},
    packet_claimed: []bool = &.{},
    player_protocols: []i32 = &.{},
    acknowledgements: []Acknowledgement = &.{},
    acknowledgement_count: usize = 0,
    sound_count: u16 = 0,
    overflow: ?Failure = null,
    reload_request: ?u16 = null,
    temporary: ?std.mem.Allocator = null,

    pub const profiles_living = false;

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Packets {
        try configuration.validate();
        const self = try allocator.create(Packets);
        errdefer allocator.destroy(self);
        var input = try core_exchange.InputBatch.init(
            allocator,
            configuration.maximum_input_packets,
            configuration.input_byte_capacity,
        );
        errdefer input.deinit(allocator);
        const player_protocols = try allocator.alloc(i32, deps.players.records.len);
        errdefer allocator.free(player_protocols);
        const acknowledgements = try allocator.alloc(Acknowledgement, configuration.maximum_input_packets);
        errdefer allocator.free(acknowledgements);
        const chats = try chat_batch.Batch.init(allocator, configuration.maximum_player_messages);
        const commands = try command_batch.Batch.init(allocator, configuration.maximum_player_messages);
        self.* = .{
            .deps = deps,
            .config = configuration,
            .input = input,
            .chats = chats,
            .commands = commands,
            .player_protocols = player_protocols,
            .acknowledgements = acknowledgements,
        };
        @memset(self.player_protocols, 0);
        return self;
    }

    pub fn bindRuntime(self: *Packets, runtime: session_settings.Runtime) void {
        self.deps.sessions.bindRuntime(runtime);
    }

    pub fn flush(self: *Packets) void {
        self.deps.sessions.flush();
    }

    pub fn beginTick(self: *Packets) void {
        self.chats.clear();
        self.commands.clear();
        self.sound_count = 0;
        self.overflow = null;
    }

    pub fn requestReload(self: *Packets, slot: u16) void {
        if (self.reload_request == null) self.reload_request = slot;
    }

    pub fn takeReloadRequest(self: *Packets) ?u16 {
        const value = self.reload_request;
        self.reload_request = null;
        return value;
    }

    pub fn tick(self: *Packets, temporary: std.mem.Allocator) void {
        self.temporary = temporary;
        self.beginTick();
    }

    pub fn inputs(self: *const Packets) *const core_exchange.InputBatch {
        return &self.input;
    }

    pub fn packetViews(self: *const Packets) []const core_exchange.PacketView {
        return self.packet_views;
    }

    pub fn playerSession(self: *const Packets, slot: u16) ?players.Session {
        return self.deps.players.session(slot);
    }

    pub fn sessionProtocol(self: *const Packets, value: players.Session) ?session_settings.Protocol {
        if (!self.deps.players.validSession(value)) return null;
        const protocol = self.playerProtocol(value.slot) orelse return null;
        return .{ .value = protocol };
    }

    pub fn claimPacket(self: *Packets, value: core_exchange.PacketView) session_settings.Claim {
        const ticket: usize = value.ticket;
        if (ticket >= self.packet_views.len or ticket >= self.packet_claimed.len) return .unavailable;
        const current = self.packet_views[ticket];
        if (current.ticket != value.ticket or current.connection.eql(value.connection) == false or
            current.protocol != value.protocol or current.id != value.id or current.bytes.ptr != value.bytes.ptr or
            current.bytes.len != value.bytes.len)
            return .unavailable;
        self.packet_claimed[ticket] = true;
        return .claimed;
    }

    pub fn playerProtocol(self: *const Packets, slot: u16) ?i32 {
        if (slot >= self.player_protocols.len) return null;
        const protocol = self.player_protocols[slot];
        return if (protocol == 0) null else protocol;
    }

    pub fn setPacketViews(self: *Packets, views: []const core_exchange.PacketView, claimed: []bool) void {
        std.debug.assert(self.packet_views.len == 0);
        std.debug.assert(views.len == claimed.len);
        self.packet_views = views;
        self.packet_claimed = claimed;
    }

    pub fn clearPacketViews(self: *Packets) void {
        self.packet_views = &.{};
        self.packet_claimed = &.{};
    }

    pub fn setPlayerProtocol(self: *Packets, slot: u16, protocol: i32) void {
        std.debug.assert(slot < self.player_protocols.len and protocol != 0);
        self.player_protocols[slot] = protocol;
    }

    pub fn clearPlayerProtocol(self: *Packets, slot: u16) void {
        std.debug.assert(slot < self.player_protocols.len);
        self.player_protocols[slot] = 0;
    }

    pub fn applyInputs(self: *Packets) void {
        for (self.input.items()) |input| switch (input) {
            .teleport_confirm => |value| self.confirmTeleport(value.player, value.id),
            .player_loaded => |value| self.markPlayerLoaded(value.player),
            .use_item => |value| self.deps.inputs.requestUseItem(
                self.deps.players,
                value.player,
                value.hand,
                value.sequence,
                value.rotation,
            ) catch self.fail(.input_full),
            .chunk_batch_received => |value| self.deps.inputs.queueChunkBatchReceived(value.player, value.chunks_per_tick),
            .movement => |value| if (self.deps.players.records[value.player].pending_teleport_id == 0)
                self.deps.inputs.queueMovement(value.player, value.position, value.rotation, value.on_ground),
            .player_input => |value| self.deps.inputs.queuePlayerInput(value.player, value.shift, value.sprint),
            .sprint => |value| self.deps.inputs.queueSprintAction(value.player, value.sprinting),
            .dig => |value| self.applyDig(value),
            .place => |value| self.applyPlace(value),
            .held_item => |value| self.deps.players.setSelectedHotbarSlot(value.player, value.selected),
            .keep_alive_response => |value| self.applyKeepAliveResponse(value.player, value.id),
            .arm_animation => |value| self.deps.inputs.requestArmSwing(self.deps.players, value.player, value.hand) catch self.fail(.input_full),
            .attack_entity => |value| self.deps.inputs.requestEntityAttack(self.deps.players, value.player, value.entity_id) catch self.fail(.input_full),
            .interact_entity => |value| self.deps.inputs.requestLivingInteraction(self.deps.players, value.player, value.entity_id, value.hand) catch self.fail(.input_full),
            .respawn => |value| self.deps.inputs.requestRespawn(self.deps.players, value.player) catch self.fail(.input_full),
            .window_click => |value| self.deps.inputs.enqueueInventoryClick(self.deps.players, .{
                .slot = value.player,
                .window_id = value.window_id,
                .state_id = value.state_id,
                .protocol_slot = value.protocol_slot,
                .mouse_button = value.mouse_button,
                .mode = value.mode,
            }) catch self.fail(.input_full),
            .creative_slot => |value| self.deps.inputs.requestCreativeSlot(self.deps.players, value.player, value.inventory_slot, value.item_id, value.count) catch self.fail(.input_full),
            .close_window => |value| self.deps.inputs.requestContainerClose(value.player, value.window_id),
            .chat => |value| {
                _ = self.chats.append(value.player, self.input.text(value.text)) catch self.fail(.input_full);
            },
            .command => |value| {
                _ = self.commands.append(value.player, self.input.text(value.text)) catch self.fail(.input_full);
            },
        };
        self.input.clear();
    }

    pub fn failure(self: *const Packets) ?Failure {
        return self.overflow;
    }

    pub fn movement(self: *Packets, slot: u16, position: ?geometry.Vec3, rotation: ?geometry.Rotation, on_ground: bool) !void {
        if (self.input.append(.{ .movement = .{ .player = slot, .position = position, .rotation = rotation, .on_ground = on_ground } }) == .full)
            return error.InputBatchFull;
    }

    pub fn playerInput(self: *Packets, slot: u16, shift: bool, sprint: bool) void {
        if (self.input.append(.{ .player_input = .{ .player = slot, .shift = shift, .sprint = sprint } }) == .full)
            self.overflow = .input_full;
    }

    pub fn playerSprint(self: *Packets, slot: u16, sprinting: bool) void {
        if (self.input.append(.{ .sprint = .{ .player = slot, .sprinting = sprinting } }) == .full)
            self.overflow = .input_full;
    }

    pub fn keepAliveResponse(self: *Packets, slot: u16, value: i64) void {
        if (self.input.append(.{ .keep_alive_response = .{ .player = slot, .id = value } }) == .full) self.fail(.input_full);
    }

    pub fn keep_alive_response(self: *Packets, slot: u16, value: i64) void {
        self.keepAliveResponse(slot, value);
    }

    pub fn blockDig(self: *Packets, slot: u16, status: i32, position: geometry.BlockPos, face: i32, sequence: i32) !void {
        if (self.input.append(.{ .dig = .{ .player = slot, .status = status, .position = position, .face = face, .sequence = sequence } }) == .full)
            return error.InputBatchFull;
        try self.deferAcknowledgement(slot, sequence);
    }

    pub fn blockPlace(self: *Packets, request: input_state.BlockRequest) !void {
        const input: core_exchange.PlaceInput = .{
            .world = request.world,
            .player = request.slot,
            .kind = @enumFromInt(@intFromEnum(request.kind)),
            .position = request.pos,
            .against_position = request.against_pos,
            .face = request.face,
            .cursor = request.cursor,
            .sequence = request.sequence,
        };
        if (self.input.append(.{ .place = input }) == .full) return error.InputBatchFull;
        try self.deferAcknowledgement(request.slot, request.sequence);
    }

    pub fn heldItemSlot(self: *Packets, slot: u16, selected: i16) void {
        if (self.input.append(.{ .held_item = .{ .player = slot, .selected = selected } }) == .full) self.fail(.input_full);
        _ = self.emitPlayerInventory(slot);
    }

    pub fn chat(self: *Packets, slot: u16, text: []const u8) !void {
        const stored = try self.input.copyText(text);
        if (self.input.append(.{ .chat = .{ .player = slot, .text = stored } }) == .full) return error.InputBatchFull;
    }

    pub fn command(self: *Packets, slot: u16, text: []const u8) !void {
        const stored = try self.input.copyText(text);
        if (self.input.append(.{ .command = .{ .player = slot, .text = stored } }) == .full) return error.InputBatchFull;
    }

    pub fn blockChanged(self: *Packets, change: packet_args.BlockChanged) void {
        self.sendBlock(.{ .world = change.world, .position = change.pos, .state = change.block_state }, .other);
    }

    pub fn blocksChanged(self: *Packets, changes: []const packet_args.BlockChanged) void {
        var first: usize = 0;
        while (first < changes.len) {
            const origin = changes[first];
            const chunk_x = @divFloor(origin.pos.x, 16);
            const section_y = @divFloor(@as(i32, origin.pos.y), 16);
            const chunk_z = @divFloor(origin.pos.z, 16);
            var end = first + 1;
            while (end < changes.len) : (end += 1) {
                const change = changes[end];
                if (!change.world.eql(origin.world) or @divFloor(change.pos.x, 16) != chunk_x or
                    @divFloor(@as(i32, change.pos.y), 16) != section_y or @divFloor(change.pos.z, 16) != chunk_z) break;
            }
            if (end - first == 1)
                self.blockChanged(origin)
            else
                self.sendSectionBlocks(origin.world, chunk_x, section_y, chunk_z, changes[first..end]);
            first = end;
        }
    }

    pub fn block_changed(self: *Packets, change: packet_args.BlockChanged) void {
        self.blockChanged(change);
    }

    pub fn acknowledgeDig(self: *Packets, slot: u16, sequence: i32) bool {
        const Arguments = struct { sequence: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const payload = protocol_versions.staticCall("encodeAcknowledgeSequence", protocol.value, .{ output, arguments.sequence }) catch return null;
                return generatedPacket(payload);
            }
        };
        const arguments = Arguments{ .sequence = sequence };
        return self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode });
    }

    pub fn deferAcknowledgement(self: *Packets, slot: u16, sequence: i32) !void {
        if (self.acknowledgement_count == self.acknowledgements.len) return error.InputBatchFull;
        self.acknowledgements[self.acknowledgement_count] = .{ .slot = slot, .sequence = sequence };
        self.acknowledgement_count += 1;
    }

    pub fn flushAcknowledgements(self: *Packets) void {
        var sent: usize = 0;
        while (sent < self.acknowledgement_count) : (sent += 1) {
            const acknowledgement = self.acknowledgements[sent];
            if (self.playerSession(acknowledgement.slot) == null) continue;
            if (!self.acknowledgeDig(acknowledgement.slot, acknowledgement.sequence)) break;
        }
        if (sent != 0) {
            std.mem.copyForwards(
                Acknowledgement,
                self.acknowledgements[0 .. self.acknowledgement_count - sent],
                self.acknowledgements[sent..self.acknowledgement_count],
            );
            self.acknowledgement_count -= sent;
        }
    }

    pub fn keepAlive(self: *Packets, slot: u16, value: i64) bool {
        const Arguments = struct { value: i64 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const payload = protocol_versions.staticCall("encodeKeepAlive", protocol.value, .{ output, arguments.value }) catch return null;
                return generatedPacket(payload);
            }
        };
        const arguments = Arguments{ .value = value };
        return self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode });
    }

    pub fn hotbarChanged(self: *Packets, change: packet_args.HotbarChanged) void {
        _ = self.emitPlayerInventory(change.slot);
    }

    pub fn hotbar_changed(self: *Packets, change: packet_args.HotbarChanged) void {
        self.hotbarChanged(change);
    }

    pub fn emitPlayerPosition(self: *Packets, slot: u16, previous: ?input_state.PreviousMovement) void {
        if (slot >= self.deps.players.records.len) return;
        const player = self.deps.players.records[slot];
        for (self.deps.players.activeSlots()) |target| {
            if (target == slot or !self.deps.players.records[target].world.eql(player.world)) continue;
            if (previous) |value|
                self.sendPlayerMove(target, slot, value)
            else {
                self.sendEntityMove(target, .player, slot);
                self.sendEntityHeadRotation(target, player.entity_id, player.rotation.yaw);
            }
        }
    }

    pub fn emitPlayerState(self: *Packets, slot: u16) void {
        if (slot >= self.deps.players.records.len) return;
        const player = self.deps.players.records[slot];
        const flags = playerEntityFlags(player.sneaking, player.sprinting);
        const Arguments = struct { id: i32, flags: i8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                var rest = protocol_versions.staticCall("startEntityMetadata", protocol.value, .{ output, arguments.id }) catch return null;
                rest = protocol_support.write_u8(rest, 0) catch return null;
                rest = protocol_support.write_varint(rest, 0) catch return null;
                rest = protocol_support.write_i8(rest, arguments.flags) catch return null;
                rest = protocol_support.write_u8(rest, 0xff) catch return null;
                return generatedPacket(output[0 .. output.len - rest.len]);
            }
        };
        const arguments = Arguments{ .id = player.entity_id, .flags = flags };
        const temporary = self.temporary orelse return;
        const recipients = self.worldRecipients(temporary, player.world) orelse return;
        _ = self.deps.sessions.tryFanout(temporary, recipients, .entities, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    pub fn emitPlayerInventory(self: *Packets, slot: u16) bool {
        if (slot >= self.deps.players.records.len) return false;
        const player = &self.deps.players.records[slot];
        const state_id = player.inventory_state_id +% 1;
        const Arguments = struct { player: players.CorePlayer, state_id: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                var rest = protocol_versions.staticCall("startWindowItems", protocol.value, .{ output, @as(i32, 0), arguments.state_id }) catch return null;
                const snapshot = arguments.player;
                const count = 1 + snapshot.crafting_grid.len + snapshot.armor.len + snapshot.main_inventory.len + snapshot.hotbar.len + 1;
                rest = protocol_support.write_count(rest, i32, count) catch return null;
                for (0..46) |protocol_slot|
                    rest = writeWireStack(protocol.value, rest, playerWindowStack(&snapshot, protocol_slot)) orelse return null;
                rest = writeWireStack(protocol.value, rest, snapshot.cursor_stack) orelse return null;
                return generatedPacket(output[0 .. output.len - rest.len]);
            }
        };
        const arguments = Arguments{ .player = player.*, .state_id = state_id };
        if (!self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 16 * 1024, .context = &arguments, .encode = Encoder.encode })) return false;
        player.inventory_state_id = state_id;
        return true;
    }

    pub fn emitPlayerHealth(self: *Packets, slot: u16) bool {
        if (slot >= self.deps.players.records.len) return false;
        const player = self.deps.players.records[slot];
        const Arguments = struct { health: f32, food: i32, saturation: f32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeUpdateHealth", protocol.value, .{ output, arguments.health, arguments.food, arguments.saturation }) catch return null);
            }
        };
        const arguments = Arguments{ .health = player.health, .food = player.food, .saturation = player.saturation };
        return self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 24, .context = &arguments, .encode = Encoder.encode });
    }

    pub fn emitPlayerGamemode(self: *Packets, slot: u16) void {
        if (slot >= self.deps.players.records.len) return;
        const Arguments = struct { gamemode: u8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeGameStateChange", protocol.value, .{ output, @as(u8, 3), @as(f32, @floatFromInt(arguments.gamemode)) }) catch return null);
            }
        };
        const arguments = Arguments{ .gamemode = @intFromEnum(self.deps.players.records[slot].gamemode) };
        _ = self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode });
    }

    pub fn emitPlayerAbilities(self: *Packets, slot: u16) void {
        if (slot >= self.deps.players.records.len) return;
        const Arguments = struct { flags: i8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeAbilities", protocol.value, .{ output, arguments.flags, @as(f32, 0.05), @as(f32, 0.1) }) catch return null);
            }
        };
        const arguments = Arguments{ .flags = abilityFlags(self.deps.players.records[slot].gamemode) };
        _ = self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode });
    }

    pub fn emitPlayerInfoGamemode(self: *Packets, slot: u16) void {
        if (slot >= self.deps.players.records.len) return;
        const player = self.deps.players.records[slot];
        const temporary = self.temporary orelse return;
        const recipients = self.allRecipients(temporary) orelse return;
        const Arguments = struct { uuid: u128, gamemode: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodePlayerInfoGamemode", protocol.value, .{ output, arguments.uuid, arguments.gamemode }) catch return null);
            }
        };
        const arguments = Arguments{ .uuid = player.uuid, .gamemode = @intFromEnum(player.gamemode) };
        _ = self.deps.sessions.fanout(temporary, recipients, .control, .{ .phase = .play, .maximum_payload_bytes = 64, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    pub fn emitPlayerCorrection(self: *Packets, slot: u16) bool {
        if (slot >= self.deps.players.records.len) return false;
        const player = &self.deps.players.records[slot];
        const teleport_id = player.next_teleport_id;
        const Arguments = struct {
            teleport_id: i32,
            position: geometry.Vec3,
            rotation: geometry.Rotation,
        };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodePlayerPosition", protocol.value, .{ output, protocol_values.PlayerPosition{
                    .teleport_id = arguments.teleport_id,
                    .x = arguments.position.x,
                    .y = arguments.position.y,
                    .z = arguments.position.z,
                    .yaw = arguments.rotation.yaw,
                    .pitch = arguments.rotation.pitch,
                    .velocity_x = 0,
                    .velocity_y = 0,
                    .velocity_z = 0,
                } }) catch return null);
            }
        };
        const arguments = Arguments{ .teleport_id = teleport_id, .position = player.position, .rotation = player.rotation };
        if (!self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 64, .context = &arguments, .encode = Encoder.encode })) return false;
        player.next_teleport_id +%= 1;
        if (player.next_teleport_id <= 0) player.next_teleport_id = 1;
        player.pending_teleport_id = teleport_id;
        return true;
    }

    pub fn emitArmSwing(self: *Packets, slot: u16, hand: i32) void {
        if (slot >= self.deps.players.records.len) return;
        const player = self.deps.players.records[slot];
        const temporary = self.temporary orelse return;
        const recipients = self.worldRecipientsExcept(temporary, player.world, slot) orelse return;
        self.sendArmSwing(recipients, player.entity_id, hand);
    }

    pub fn emitRespawn(self: *Packets, slot: u16) void {
        _ = self.bootstrap(slot, .respawn);
        _ = self.emitPlayerCorrection(slot);
        _ = self.emitPlayerHealth(slot);
        _ = self.emitPlayerInventory(slot);
    }

    pub fn emitTime(self: *Packets, game_time: u64, day_time: u64) void {
        const temporary = self.temporary orelse return;
        const recipients = temporary.alloc(players.Session, self.deps.players.activeSlots().len) catch return self.fail(.temporary_full);
        var count: usize = 0;
        for (self.deps.players.activeSlots()) |slot| {
            if (!self.deps.players.records[slot].presentation_ready) continue;
            recipients[count] = self.deps.players.session(slot) orelse continue;
            count += 1;
        }
        const Arguments = struct { game_time: u64, day_time: u64 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const payload = protocol_versions.staticCall("encodeUpdateTime", protocol.value, .{ output, @as(i64, @bitCast(arguments.game_time)), @as(i64, @bitCast(arguments.day_time)), true }) catch return null;
                return generatedPacket(payload);
            }
        };
        const arguments = Arguments{ .game_time = game_time, .day_time = day_time };
        _ = self.deps.sessions.tryFanout(temporary, recipients[0..count], .other, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    pub fn entityDestroyed(self: *Packets, entity: i32) void {
        const temporary = self.temporary orelse return;
        const recipients = self.allRecipients(temporary) orelse return;
        const Arguments = struct { entity: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeEntityDestroy", protocol.value, .{ output, arguments.entity }) catch return null);
            }
        };
        const arguments = Arguments{ .entity = entity };
        _ = self.deps.sessions.fanout(temporary, recipients, .entities, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    pub fn chatRecipient(self: *Packets, slot: u16, draft: *const chat_batch.Draft) void {
        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{f}", .{chat_batch.Line{ .draft = draft }}) catch
            return self.fail(.temporary_full);
        _ = self.sendSystemText(slot, text);
    }

    pub fn input_failed(self: *Packets, _: anyerror) void {
        self.fail(.input_full);
    }
    pub fn time_changed(self: *Packets) void {
        self.emitTime(0, 0);
    }
    pub fn gamemode_changed(self: *Packets, change: packet_args.GamemodeChanged) void {
        if (change.slot >= self.deps.players.records.len) return;
        std.debug.assert(self.deps.players.records[change.slot].gamemode == change.value);
        self.emitPlayerGamemode(change.slot);
        self.emitPlayerAbilities(change.slot);
        self.emitPlayerInfoGamemode(change.slot);
    }
    pub fn inventory_changed(self: *Packets, slot: u16) void {
        _ = self.emitPlayerInventory(slot);
    }
    pub fn inventory_slot_changed(self: *Packets, change: packet_args.InventorySlotChanged) void {
        _ = self.emitPlayerInventory(change.slot);
    }
    pub fn player_screen_slot_changed(self: *Packets, change: packet_args.PlayerScreenSlotChanged) void {
        _ = self.emitPlayerInventory(change.slot);
    }
    pub fn container_opened(self: *Packets, slot: u16) void {
        self.sendOpenContainer(slot, "Crafting");
        self.sendContainer(slot);
    }
    pub fn container_closed(self: *Packets, closed: packet_args.ContainerClosed) void {
        self.sendCloseContainer(closed.slot, closed.window_id);
        _ = self.emitPlayerInventory(closed.slot);
    }
    pub fn menu_opened(self: *Packets, opened: packet_args.ContainerOpened) void {
        self.sendOpenContainer(opened.slot, opened.title);
        self.sendContainer(opened.slot);
        self.sendContainerProperties(opened.slot, opened.properties);
    }
    pub fn menu_changed(self: *Packets, slot: u16, properties: []const packet_args.ContainerProperty) void {
        self.sendContainer(slot);
        self.sendContainerProperties(slot, properties);
    }
    pub fn menu_player_inventory_changed(self: *Packets, slot: u16, properties: []const packet_args.ContainerProperty) void {
        self.sendContainer(slot);
        self.sendContainerProperties(slot, properties);
    }
    pub fn menu_properties_changed(self: *Packets, slot: u16, properties: []const packet_args.ContainerProperty) void {
        self.sendContainerProperties(slot, properties);
    }
    pub fn block_correction(self: *Packets, correction: packet_args.BlockCorrection) void {
        const world = self.deps.players.records[correction.slot].world;
        const state = self.deps.blocks.blockAtIfMaterialized(world, correction.pos) orelse return;
        self.sendBlockToPlayer(correction.slot, .{ .position = correction.pos, .state = state }, .control);
    }
    pub fn block_break_animation(self: *Packets, animation: packet_args.BlockBreakAnimation) void {
        const temporary = self.temporary orelse return;
        const recipients = temporary.alloc(players.Session, self.deps.players.activeSlots().len) catch return self.fail(.temporary_full);
        var recipient_count: usize = 0;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (slot == animation.slot or !player.world.eql(animation.world)) continue;
            if (!player.presentation_ready) continue;
            const dx = @as(f64, @floatFromInt(animation.pos.x)) - player.position.x;
            const dy = @as(f64, @floatFromInt(animation.pos.y)) - player.position.y;
            const dz = @as(f64, @floatFromInt(animation.pos.z)) - player.position.z;
            if (dx * dx + dy * dy + dz * dz >= 32.0 * 32.0) continue;
            recipients[recipient_count] = self.deps.players.session(slot) orelse continue;
            recipient_count += 1;
        }
        const entity_id = self.deps.players.records[animation.slot].entity_id;
        const Arguments = struct { entity_id: i32, position: geometry.BlockPos, stage: i8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeBlockBreakAnimation", protocol.value, .{ output, arguments.entity_id, arguments.position.x, arguments.position.y, arguments.position.z, arguments.stage }) catch return null);
            }
        };
        const arguments = Arguments{ .entity_id = entity_id, .position = animation.pos, .stage = animation.stage };
        _ = self.deps.sessions.fanout(temporary, recipients[0..recipient_count], .entities, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }
    pub fn item_spawned(self: *Packets, index: u16) void {
        self.stageEntity(.spawn, .item, index);
        self.stageEntity(.metadata, .item, index);
    }
    pub fn item_moved(self: *Packets, index: u16) void {
        self.stageEntity(.move, .item, index);
    }
    pub fn item_metadata_changed(self: *Packets, index: u16) void {
        self.stageEntity(.metadata, .item, index);
    }
    pub fn living_spawned(self: *Packets, index: u16) void {
        self.stageEntity(.spawn, .living, index);
    }
    pub fn living_moved(self: *Packets, index: u16) void {
        self.stageEntity(.move, .living, index);
    }
    pub fn living_stepped(self: *Packets, value: packet_args.LivingMoved) void {
        const world = if (value.index < self.deps.living.entities.active.len and self.deps.living.entities.active[value.index])
            self.deps.living.entities.worlds[value.index]
        else
            return;
        for (self.deps.players.activeSlots()) |slot| {
            if (!self.deps.players.records[slot].world.eql(world)) continue;
            self.sendLivingStep(slot, value);
        }
    }
    pub fn living_metadata_changed(self: *Packets, index: u16) void {
        self.stageEntity(.metadata, .living, index);
    }
    pub fn living_passengers(self: *Packets, vehicle: u16, passenger: ?u16) void {
        if (vehicle >= self.deps.living.entities.active.len) return;
        if (!self.deps.living.entities.active[vehicle]) return;
        const world = self.deps.living.entities.worlds[vehicle];
        self.stageLivingPassengersWorld(world, vehicle, passenger);
    }

    pub fn livingPassengersFor(self: *Packets, target: u16, vehicle: u16, passenger: ?u16) void {
        self.stageLivingPassengersPlayer(target, vehicle, passenger);
    }
    pub fn living_destroyed(self: *Packets, value: packet_args.LivingDestroyed) void {
        self.entityDestroyed(value.entity_id);
    }
    pub fn living_arm_swing(self: *Packets, index: u16) void {
        const entity = self.entitySnapshot(.living, index) orelse return;
        const temporary = self.temporary orelse return;
        const recipients = self.worldRecipients(temporary, self.deps.living.entities.worlds[index]) orelse return;
        self.sendArmSwing(recipients, entity.id, 0);
    }
    pub fn living_status(self: *Packets, value: packet_args.LivingStatus) void {
        self.stageEntityStatus(.living, value.index, value.status);
    }
    pub fn living_burned(self: *Packets, index: u16) void {
        self.stageEntityStatus(.living, index, 2);
    }
    pub fn living_fell(self: *Packets, index: u16) void {
        self.stageEntityStatus(.living, index, 2);
    }
    pub fn living_died(self: *Packets, value: packet_args.LivingDied) void {
        self.stageEntityStatus(.living, value.index, 3);
    }
    pub fn living_damaged(self: *Packets, value: packet_args.LivingDamaged) void {
        self.stageEntityStatus(.living, value.index, 2);
    }
    pub fn living_equipment_changed(self: *Packets, value: packet_args.LivingEquipmentChanged) void {
        self.stageEntity(.equipment, .living, value.index);
    }
    pub fn living_velocity_changed(self: *Packets, value: packet_args.LivingVelocityChanged) void {
        const entity = self.entitySnapshot(.living, value.index) orelse return;
        const temporary = self.temporary orelse return;
        const recipients = self.allRecipients(temporary) orelse return;
        const Arguments = struct { id: i32, x: f64, y: f64, z: f64 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeEntityVelocity", protocol.value, .{ output, arguments.id, velocity(arguments.x), velocity(arguments.y), velocity(arguments.z) }) catch return null);
            }
        };
        const arguments = Arguments{ .id = entity.id, .x = value.x, .y = value.y, .z = value.z };
        _ = self.deps.sessions.tryFanout(temporary, recipients, .entities, .{ .phase = .play, .maximum_payload_bytes = 24, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }
    pub fn item_collected(self: *Packets, value: packet_args.ItemCollected) void {
        const temporary = self.temporary orelse return;
        const recipients = self.allRecipients(temporary) orelse return;
        const Arguments = struct { item: i32, collector: i32, count: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeCollectItem", protocol.value, .{ output, arguments.item, arguments.collector, arguments.count }) catch return null);
            }
        };
        const arguments = Arguments{ .item = value.item_entity_id, .collector = value.collector_entity_id, .count = value.count };
        _ = self.deps.sessions.tryFanout(temporary, recipients, .entities, .{ .phase = .play, .maximum_payload_bytes = 24, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }
    pub fn player_health_changed(self: *Packets, slot: u16) void {
        _ = self.emitPlayerHealth(slot);
    }
    pub fn player_damaged(self: *Packets, value: packet_args.PlayerDamaged) void {
        _ = self.emitPlayerHealth(value.slot);
    }
    pub fn player_fell(self: *Packets, value: packet_args.PlayerFell) void {
        _ = self.emitPlayerHealth(value.slot);
    }
    pub fn player_respawned(self: *Packets, slot: u16) void {
        self.emitRespawn(slot);
    }
    pub fn playerWorldChanged(self: *Packets, slot: u16, previous_world: world_identity.Handle) void {
        const player = &self.deps.players.records[slot];
        self.destroyInWorld(previous_world, player.entity_id);
        for (self.deps.players.activeSlots()) |target| {
            if (target != slot and self.deps.players.records[target].world.eql(player.world)) self.sendEntitySpawn(target, .player, slot);
        }
        self.emitRespawn(slot);
    }
    pub fn player_teleported(self: *Packets, slot: u16) void {
        _ = self.emitPlayerCorrection(slot);
    }

    pub fn livingTransferred(self: *Packets, index: u16, previous_world: world_identity.Handle) void {
        if (index >= self.deps.living.entities.active.len or !self.deps.living.entities.active[index]) return;
        const entity_id = self.deps.living.entities.entity_ids[index];
        self.destroyInWorld(previous_world, entity_id);
        self.stageEntity(.spawn, .living, index);
    }

    pub fn itemTransferred(self: *Packets, index: u16, previous_world: world_identity.Handle) void {
        if (index >= self.deps.items.active.len or !self.deps.items.active[index]) return;
        const entity_id = self.deps.items.entity_ids[index];
        self.destroyInWorld(previous_world, entity_id);
        self.stageEntity(.spawn, .item, index);
        self.stageEntity(.metadata, .item, index);
    }
    pub fn hotbar_selected(self: *Packets, slot: u16) void {
        _ = self.emitPlayerInventory(slot);
    }
    pub fn chest_viewers_changed(self: *Packets, value: packet_args.ChestViewersChanged) void {
        const state = self.deps.blocks.blockAtIfMaterialized(value.world, value.position) orelse return;
        self.sendBlock(.{ .world = value.world, .position = value.position, .state = state }, .other);
    }
    pub fn living_sound(self: *Packets, value: packet_args.LivingSound) void {
        if (self.sound_count == self.config.maximum_sounds) return;
        const entity = self.entitySnapshot(.living, value.index) orelse return;
        const temporary = self.temporary orelse return;
        const recipients = self.allRecipients(temporary) orelse return;
        const Arguments = struct { position: geometry.Vec3, sound: @TypeOf(value.sound), volume: f32, pitch: f32, seed: i64 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const sound = protocol_versions.staticWireSound(protocol.value, arguments.sound);
                return generatedPacket(protocol_versions.staticCall("encodeSoundEffect", protocol.value, .{ output, sound, @as(i32, @intFromFloat(@floor(arguments.position.x * 8))), @as(i32, @intFromFloat(@floor(arguments.position.y * 8))), @as(i32, @intFromFloat(@floor(arguments.position.z * 8))), arguments.volume, arguments.pitch, arguments.seed }) catch return null);
            }
        };
        const arguments = Arguments{ .position = entity.position, .sound = value.sound, .volume = value.volume, .pitch = value.pitch, .seed = value.seed };
        const result = self.deps.sessions.tryFanout(temporary, recipients, .other, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode }) catch return self.fail(.temporary_full);
        if (result.delivered.len != 0) self.sound_count += 1;
    }

    fn stageEntity(self: *Packets, update: EntityUpdate, class: EntityClass, index: u16) void {
        const world = switch (class) {
            .player => return,
            .living => if (index < self.deps.living.entities.active.len and self.deps.living.entities.active[index]) self.deps.living.entities.worlds[index] else return,
            .item => if (index < self.deps.items.active.len and self.deps.items.active[index]) self.deps.items.worlds[index] else return,
        };
        for (self.deps.players.activeSlots()) |slot| {
            if (!self.deps.players.records[slot].world.eql(world)) continue;
            switch (update) {
                .spawn => self.sendEntitySpawn(slot, class, index),
                .move => self.sendEntityMove(slot, class, index),
                .metadata => if (self.entitySnapshot(class, index)) |entity| self.sendEntityMetadata(slot, class, index, entity.id),
                .equipment => self.sendEntityEquipment(slot, class, index),
            }
        }
    }

    fn stageLivingPassengersWorld(self: *Packets, world: world_identity.Handle, vehicle: u16, passenger: ?u16) void {
        const vehicle_entity = self.entitySnapshot(.living, vehicle) orelse return;
        const passenger_id = if (passenger) |index| (self.entitySnapshot(.living, index) orelse return).id else null;
        const temporary = self.temporary orelse return;
        const recipients = self.worldRecipients(temporary, world) orelse return;
        const Arguments = struct { vehicle: i32, passenger: ?i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeSetPassengers", protocol.value, .{ output, arguments.vehicle, arguments.passenger }) catch return null);
            }
        };
        const arguments = Arguments{ .vehicle = vehicle_entity.id, .passenger = passenger_id };
        _ = self.deps.sessions.fanout(temporary, recipients, .entities, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    fn stageLivingPassengersPlayer(self: *Packets, slot: u16, vehicle: u16, passenger: ?u16) void {
        const vehicle_entity = self.entitySnapshot(.living, vehicle) orelse return;
        const passenger_id = if (passenger) |index| (self.entitySnapshot(.living, index) orelse return).id else null;
        const Arguments = struct { vehicle: i32, passenger: ?i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeSetPassengers", protocol.value, .{ output, arguments.vehicle, arguments.passenger }) catch return null);
            }
        };
        const arguments = Arguments{ .vehicle = vehicle_entity.id, .passenger = passenger_id };
        _ = self.sendPlayer(slot, .entities, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode });
    }

    fn stageEntityStatus(self: *Packets, class: EntityClass, index: u16, status: i8) void {
        const entity = self.entitySnapshot(class, index) orelse return;
        const temporary = self.temporary orelse return;
        const recipients = self.allRecipients(temporary) orelse return;
        const Arguments = struct { id: i32, status: i8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeEntityStatus", protocol.value, .{ output, arguments.id, arguments.status }) catch return null);
            }
        };
        const arguments = Arguments{ .id = entity.id, .status = status };
        _ = self.deps.sessions.tryFanout(temporary, recipients, .entities, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    fn applyDig(self: *Packets, value: core_exchange.DigInput) void {
        switch (value.status) {
            0 => self.deps.inputs.stageDigStart(value.player, value.position, value.face, value.sequence) catch self.fail(.input_full),
            1 => self.deps.inputs.stageDigCancel(value.player, value.position, value.sequence) catch self.fail(.input_full),
            2 => self.deps.inputs.stageDigFinish(value.player, value.position, value.sequence) catch self.fail(.input_full),
            3, 4 => self.deps.inputs.requestItemDrop(value.player, if (value.status == 3) 64 else 1),
            else => {},
        }
    }

    fn applyPlace(self: *Packets, value: core_exchange.PlaceInput) void {
        self.deps.inputs.stageBlockRequest(self.deps.players, .{
            .world = value.world,
            .slot = value.player,
            .kind = @enumFromInt(@intFromEnum(value.kind)),
            .pos = value.position,
            .against_pos = value.against_position,
            .face = value.face,
            .cursor = .{ .x = value.cursor.x, .y = value.cursor.y, .z = value.cursor.z },
            .sequence = value.sequence,
        }) catch self.fail(.input_full);
    }

    fn applyKeepAliveResponse(self: *Packets, slot: u16, value: i64) void {
        if (slot >= self.deps.inputs.keep_alive_responses.len) return self.fail(.input_full);
        self.deps.inputs.keep_alive_responses[slot] = value;
    }

    fn confirmTeleport(self: *Packets, slot: u16, teleport_id: i32) void {
        if (slot >= self.deps.players.records.len) return;
        const player = &self.deps.players.records[slot];
        if (player.pending_teleport_id == teleport_id) player.pending_teleport_id = 0;
    }

    fn markPlayerLoaded(self: *Packets, slot: u16) void {
        if (slot < self.deps.players.records.len) self.deps.players.records[slot].client_loaded = true;
    }

    pub fn system(self: *Packets, slot: u16, comptime format: []const u8, args: anytype) void {
        var scratch: [512]u8 = undefined;
        const rendered = std.fmt.bufPrint(&scratch, format, args) catch return;
        _ = self.sendSystemText(slot, rendered);
    }

    pub fn activePlaySlots(self: *const Packets) []const u16 {
        return self.deps.players.activeSlots();
    }

    pub fn bootstrap(self: *Packets, slot: u16, action: BootstrapAction) bool {
        if (slot >= self.deps.players.records.len) return false;
        const temporary = self.temporary orelse return false;
        var world_names: []const []const u8 = &.{};
        if (action == .play_login) {
            const active = self.deps.worlds.active();
            if (active.len == 0) return false;
            const names = temporary.alloc([]const u8, active.len) catch {
                self.fail(.temporary_full);
                return false;
            };
            for (active, names) |handle, *name| name.* = (self.deps.worlds.getConst(handle) orelse return false).nameSlice();
            world_names = names;
        }
        const Arguments = struct { packets: *const Packets, slot: u16, action: BootstrapAction, world_names: []const []const u8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const packets = arguments.packets;
                const player = packets.deps.players.records[arguments.slot];
                const world = packets.deps.worlds.getConst(player.world) orelse return null;
                const dimensions = packets.deps.worlds.dimensionRegistry() orelse return null;
                const dimension_type = dimensions.protocolIndex(world.dimension) orelse return null;
                const payload = switch (arguments.action) {
                    .play_login => protocol_versions.staticCall("encodePlayLogin", protocol.value, .{ output, protocol_values.PlayLogin{
                        .entity_id = player.entity_id,
                        .world_names = arguments.world_names,
                        .dimension_type = dimension_type,
                        .world_name = world.nameSlice(),
                        .max_players = @as(i32, @intCast(packets.deps.players.records.len)),
                        .view_distance = packets.config.view_distance_chunks,
                        .simulation_distance = packets.config.simulation_distance_chunks,
                        .hashed_seed = @as(i64, @bitCast(world.seed)),
                        .gamemode = @as(i8, @bitCast(@intFromEnum(player.gamemode))),
                        .sea_level = 63,
                    } }) catch return null,
                    .respawn => protocol_versions.staticCall("encodeRespawn", protocol.value, .{ output, protocol_values.Respawn{ .dimension_type = dimension_type, .world_name = world.nameSlice(), .hashed_seed = @as(i64, @bitCast(world.seed)), .gamemode = @as(i8, @bitCast(@intFromEnum(player.gamemode))), .sea_level = 63 } }) catch return null,
                    .abilities => protocol_versions.staticCall("encodeAbilities", protocol.value, .{ output, abilityFlags(player.gamemode), @as(f32, 0.05), @as(f32, 0.1) }) catch return null,
                    .held_item => protocol_versions.staticCall("encodeHeldItemSlot", protocol.value, .{ output, player.selected_hotbar_slot }) catch return null,
                    .combat_attributes => protocol_versions.staticCall("encodeCombatAttributes", protocol.value, .{ output, player.entity_id, @as(f64, 1.0), @as(f64, 4.0) }) catch return null,
                    .view_center => protocol_versions.staticCall("encodeUpdateViewPosition", protocol.value, .{ output, geometry.chunkCoord(geometry.blockCoord(player.position.x)), geometry.chunkCoord(geometry.blockCoord(player.position.z)) }) catch return null,
                    .spawn_position => protocol_versions.staticCall("encodeSpawnPosition", protocol.value, .{ output, world.spawn_x, world.spawn_y, world.spawn_z, @as(f32, 0) }) catch return null,
                    .start_waiting_for_chunks => protocol_versions.staticCall("encodeGameStateChange", protocol.value, .{ output, @as(u8, 13), @as(f32, 0) }) catch return null,
                };
                return generatedPacket(payload);
            }
        };
        const arguments = Arguments{ .packets = self, .slot = slot, .action = action, .world_names = world_names };
        const encoder: session_settings.PacketEncoder = .{ .phase = .play, .maximum_payload_bytes = 4096, .context = &arguments, .encode = Encoder.encode };
        const sent = if (action == .play_login)
            self.sendPlayerBeforeLogin(slot, .control, encoder)
        else
            self.sendPlayer(slot, .control, encoder);
        if (sent and action == .play_login) self.deps.players.records[slot].presentation_ready = true;
        return sent;
    }

    pub fn brand(self: *Packets, slot: u16) bool {
        const Arguments = struct { value: []const u8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const payload = protocol_versions.staticCall("encodeBrand", protocol.value, .{ output, arguments.value }) catch return null;
                return generatedPacket(payload);
            }
        };
        const arguments = Arguments{ .value = self.config.brand };
        return self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = self.config.brand.len + 16, .context = &arguments, .encode = Encoder.encode });
    }

    pub fn tabAdd(self: *Packets, target: u16, player: protocol_values.PlayerInfo) bool {
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const protocol_values.PlayerInfo = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodePlayerInfoAdd", protocol.value, .{ output, arguments.uuid, arguments.name, arguments.gamemode }) catch return null);
            }
        };
        return self.sendPlayer(target, .control, .{ .phase = .play, .maximum_payload_bytes = player.name.len + 64, .context = &player, .encode = Encoder.encode });
    }

    pub fn tabRemove(self: *Packets, target: u16, uuid: u128) bool {
        const Arguments = struct { uuid: u128 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodePlayerRemove", protocol.value, .{ output, arguments.uuid }) catch return null);
            }
        };
        const arguments = Arguments{ .uuid = uuid };
        return self.sendPlayer(target, .control, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode });
    }

    pub fn playerLatency(self: *Packets, subject: u16, latency_ms: i32) void {
        if (subject >= self.deps.players.records.len) return;
        const uuid = self.deps.players.records[subject].uuid;
        const temporary = self.temporary orelse return;
        const recipients = self.allRecipients(temporary) orelse return;
        const Arguments = struct { uuid: u128, latency: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodePlayerInfoLatency", protocol.value, .{ output, arguments.uuid, arguments.latency }) catch return null);
            }
        };
        const arguments = Arguments{ .uuid = uuid, .latency = latency_ms };
        _ = self.deps.sessions.tryFanout(temporary, recipients, .other, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    pub fn playerSpawn(self: *Packets, target: u16, subject: u16) void {
        self.sendEntitySpawn(target, .player, subject);
    }

    pub fn livingSpawn(self: *Packets, target: u16, index: u16) void {
        self.sendEntitySpawn(target, .living, index);
    }

    pub fn itemSpawnFor(self: *Packets, target: u16, index: u16) void {
        self.sendEntitySpawn(target, .item, index);
    }

    pub fn entityDestroyFor(self: *Packets, target: u16, entity_id: i32) void {
        const Arguments = struct { entity: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeEntityDestroy", protocol.value, .{ output, arguments.entity }) catch return null);
            }
        };
        const arguments = Arguments{ .entity = entity_id };
        _ = self.sendPlayer(target, .entities, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode });
    }

    fn sendPlayer(self: *Packets, slot: u16, class: session_settings.DeliveryClass, encoder: session_settings.PacketEncoder) bool {
        if (slot >= self.deps.players.records.len or !self.deps.players.records[slot].presentation_ready) return false;
        return self.sendPlayerBeforeLogin(slot, class, encoder);
    }

    fn sendPlayerBeforeLogin(self: *Packets, slot: u16, class: session_settings.DeliveryClass, encoder: session_settings.PacketEncoder) bool {
        const temporary = self.temporary orelse return false;
        const player = self.deps.players.session(slot) orelse return false;
        const admission = self.deps.sessions.fanoutOne(temporary, player, class, encoder, .reliable) catch |err| {
            std.log.err("event=packet_admission_failed slot={d} error={s}", .{ slot, @errorName(err) });
            return false;
        };
        if (admission == .wrong_protocol or admission == .wrong_phase)
            std.log.err("event=packet_admission_rejected slot={d} reason={s} phase={s}", .{ slot, @tagName(admission), @tagName(encoder.phase) });
        return admission == .accepted;
    }

    fn allRecipients(self: *const Packets, temporary: std.mem.Allocator) ?[]players.Session {
        const recipients = temporary.alloc(players.Session, self.deps.players.activeSlots().len) catch return null;
        var count: usize = 0;
        for (self.deps.players.activeSlots()) |slot| {
            if (!self.deps.players.records[slot].presentation_ready) continue;
            recipients[count] = self.deps.players.session(slot) orelse continue;
            count += 1;
        }
        return recipients[0..count];
    }

    fn worldRecipients(self: *const Packets, temporary: std.mem.Allocator, world: world_identity.Handle) ?[]players.Session {
        const recipients = temporary.alloc(players.Session, self.deps.players.activeSlots().len) catch return null;
        var count: usize = 0;
        for (self.deps.players.activeSlots()) |slot| {
            if (!self.deps.players.records[slot].world.eql(world)) continue;
            if (!self.deps.players.records[slot].presentation_ready) continue;
            recipients[count] = self.deps.players.session(slot) orelse continue;
            count += 1;
        }
        return recipients[0..count];
    }

    fn worldRecipientsExcept(self: *const Packets, temporary: std.mem.Allocator, world: world_identity.Handle, excluded: u16) ?[]players.Session {
        const recipients = temporary.alloc(players.Session, self.deps.players.activeSlots().len) catch return null;
        var count: usize = 0;
        for (self.deps.players.activeSlots()) |slot| {
            if (slot == excluded or !self.deps.players.records[slot].world.eql(world)) continue;
            if (!self.deps.players.records[slot].presentation_ready) continue;
            recipients[count] = self.deps.players.session(slot) orelse continue;
            count += 1;
        }
        return recipients[0..count];
    }

    fn sendEntitySpawn(self: *Packets, target: u16, class: EntityClass, index: u16) void {
        const entity = self.entitySnapshot(class, index) orelse return;
        const Arguments = struct {
            id: i32,
            uuid: u128,
            canonical_type: i32,
            position: geometry.Vec3,
            yaw: f32,
            pitch: f32,
        };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const entity_type = protocol_versions.staticWireEntity(protocol.value, arguments.canonical_type) catch return null;
                return generatedPacket(protocol_versions.staticCall("encodeSpawnEntity", protocol.value, .{ output, protocol_values.SpawnEntity{
                    .entity_id = arguments.id,
                    .uuid = arguments.uuid,
                    .entity_type = entity_type,
                    .x = arguments.position.x,
                    .y = arguments.position.y,
                    .z = arguments.position.z,
                    .pitch = angle(arguments.pitch),
                    .yaw = angle(arguments.yaw),
                    .head_yaw = angle(arguments.yaw),
                    .data = 0,
                    .velocity_x = 0,
                    .velocity_y = 0,
                    .velocity_z = 0,
                } }) catch return null);
            }
        };
        const arguments = Arguments{
            .id = entity.id,
            .uuid = entity.uuid,
            .canonical_type = entity.canonical_type,
            .position = entity.position,
            .yaw = entity.yaw,
            .pitch = entity.pitch,
        };
        _ = self.sendPlayer(target, .entities, .{ .phase = .play, .maximum_payload_bytes = 80, .context = &arguments, .encode = Encoder.encode });
        self.sendEntityMetadata(target, class, index, entity.id);
    }

    fn sendEntityMetadata(self: *Packets, target: u16, class: EntityClass, index: u16, entity_id: i32) void {
        const item_stack = switch (class) {
            .item => if (index < self.deps.items.active.len and self.deps.items.active[index]) self.deps.items.stacks[index] else return,
            .player, .living => null,
        };
        const Arguments = struct { entity_id: i32, stack: ?players.HotbarStack };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                var rest = protocol_versions.staticCall("startEntityMetadata", protocol.value, .{ output, arguments.entity_id }) catch return null;
                if (arguments.stack) |value| {
                    rest = protocol_support.write_u8(rest, 8) catch return null;
                    rest = protocol_support.write_varint(rest, 7) catch return null;
                    rest = writeWireStack(protocol.value, rest, value) orelse return null;
                }
                rest = protocol_support.write_u8(rest, 0xff) catch return null;
                return generatedPacket(output[0 .. output.len - rest.len]);
            }
        };
        const arguments = Arguments{ .entity_id = entity_id, .stack = item_stack };
        _ = self.sendPlayer(target, .entities, .{ .phase = .play, .maximum_payload_bytes = 96, .context = &arguments, .encode = Encoder.encode });
    }

    fn sendEntityMove(self: *Packets, target: u16, class: EntityClass, index: u16) void {
        const entity = self.entitySnapshot(class, index) orelse return;
        const Arguments = struct { entity: EntitySnapshot };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const snapshot = arguments.entity;
                return generatedPacket(protocol_versions.staticCall("encodeSyncEntityPosition", protocol.value, .{ output, snapshot.id, snapshot.position.x, snapshot.position.y, snapshot.position.z, 0, 0, 0, snapshot.yaw, snapshot.pitch, snapshot.on_ground }) catch return null);
            }
        };
        const arguments = Arguments{ .entity = entity };
        _ = self.sendPlayer(target, .entities, .{ .phase = .play, .maximum_payload_bytes = 64, .context = &arguments, .encode = Encoder.encode });
    }

    fn sendPlayerMove(self: *Packets, target: u16, index: u16, previous: input_state.PreviousMovement) void {
        const entity = self.entitySnapshot(.player, index) orelse return;
        const dx = relativeMoveDelta(previous.position.x, entity.position.x);
        const dy = relativeMoveDelta(previous.position.y, entity.position.y);
        const dz = relativeMoveDelta(previous.position.z, entity.position.z);
        if (dx == null or dy == null or dz == null) {
            self.sendEntityMove(target, .player, index);
            if (entity.yaw != previous.rotation.yaw) self.sendEntityHeadRotation(target, entity.id, entity.yaw);
            return;
        }
        const Arguments = struct { id: i32, dx: i16, dy: i16, dz: i16, yaw: i8, pitch: i8, on_ground: bool };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeEntityMoveLook", protocol.value, .{ output, arguments.id, arguments.dx, arguments.dy, arguments.dz, arguments.yaw, arguments.pitch, arguments.on_ground }) catch return null);
            }
        };
        const arguments = Arguments{ .id = entity.id, .dx = dx.?, .dy = dy.?, .dz = dz.?, .yaw = angle(entity.yaw), .pitch = angle(entity.pitch), .on_ground = entity.on_ground };
        _ = self.sendPlayer(target, .entities, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode });
        if (entity.yaw != previous.rotation.yaw) self.sendEntityHeadRotation(target, entity.id, entity.yaw);
    }

    fn sendLivingStep(self: *Packets, target: u16, value: packet_args.LivingMoved) void {
        const entity = self.entitySnapshot(.living, value.index) orelse return;
        const dx = relativeMoveDelta(value.previous.x, entity.position.x);
        const dy = relativeMoveDelta(value.previous.y, entity.position.y);
        const dz = relativeMoveDelta(value.previous.z, entity.position.z);
        if (dx == null or dy == null or dz == null) return self.sendEntityMove(target, .living, value.index);
        const Arguments = struct { id: i32, dx: i16, dy: i16, dz: i16, yaw: i8, pitch: i8, on_ground: bool };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeEntityMoveLook", protocol.value, .{ output, arguments.id, arguments.dx, arguments.dy, arguments.dz, arguments.yaw, arguments.pitch, arguments.on_ground }) catch return null);
            }
        };
        const arguments = Arguments{ .id = entity.id, .dx = dx.?, .dy = dy.?, .dz = dz.?, .yaw = angle(entity.yaw), .pitch = angle(entity.pitch), .on_ground = entity.on_ground };
        _ = self.sendPlayer(target, .entities, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &arguments, .encode = Encoder.encode });
        self.sendEntityHeadRotation(target, entity.id, entity.yaw);
    }

    fn sendEntityHeadRotation(self: *Packets, target: u16, entity_id: i32, yaw: f32) void {
        const Arguments = struct { id: i32, yaw: i8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeEntityHeadRotation", protocol.value, .{ output, arguments.id, arguments.yaw }) catch return null);
            }
        };
        const arguments = Arguments{ .id = entity_id, .yaw = angle(yaw) };
        _ = self.sendPlayer(target, .entities, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode });
    }

    fn sendEntityEquipment(self: *Packets, target: u16, class: EntityClass, index: u16) void {
        const entity = self.entitySnapshot(class, index) orelse return;
        const stack: players.HotbarStack = switch (class) {
            .item => self.deps.items.stacks[index],
            .player, .living => .{},
        };
        const Arguments = struct { entity_id: i32, stack: players.HotbarStack };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                var rest = protocol_versions.staticCall("startEntityEquipment", protocol.value, .{ output, arguments.entity_id }) catch return null;
                rest = protocol_support.write_i8(rest, 0) catch return null;
                rest = writeWireStack(protocol.value, rest, arguments.stack) orelse return null;
                return generatedPacket(output[0 .. output.len - rest.len]);
            }
        };
        const arguments = Arguments{ .entity_id = entity.id, .stack = stack };
        _ = self.sendPlayer(target, .entities, .{ .phase = .play, .maximum_payload_bytes = 64, .context = &arguments, .encode = Encoder.encode });
    }

    fn sendArmSwing(self: *Packets, recipients: []const players.Session, entity_id: i32, hand: i32) void {
        const temporary = self.temporary orelse return;
        const Arguments = struct { entity_id: i32, hand: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeArmSwing", protocol.value, .{ output, arguments.entity_id, arguments.hand }) catch return null);
            }
        };
        const arguments = Arguments{ .entity_id = entity_id, .hand = hand };
        _ = self.deps.sessions.tryFanout(temporary, recipients, .entities, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    fn destroyInWorld(self: *Packets, world: world_identity.Handle, entity_id: i32) void {
        const temporary = self.temporary orelse return;
        const recipients = self.worldRecipients(temporary, world) orelse return;
        const Arguments = struct { entity: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeEntityDestroy", protocol.value, .{ output, arguments.entity }) catch return null);
            }
        };
        const arguments = Arguments{ .entity = entity_id };
        _ = self.deps.sessions.fanout(temporary, recipients, .entities, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    const EntitySnapshot = struct {
        id: i32,
        uuid: u128,
        canonical_type: i32,
        position: geometry.Vec3,
        yaw: f32,
        pitch: f32,
        on_ground: bool,
    };

    fn entitySnapshot(self: *const Packets, class: EntityClass, index: u16) ?EntitySnapshot {
        switch (class) {
            .player => {
                if (index >= self.deps.players.records.len) return null;
                const player = self.deps.players.records[index];
                if (player.state != .play) return null;
                return .{ .id = player.entity_id, .uuid = player.uuid, .canonical_type = registry.entity_player_type_id, .position = player.position, .yaw = player.rotation.yaw, .pitch = player.rotation.pitch, .on_ground = player.on_ground };
            },
            .living => {
                if (index >= self.deps.living.entities.active.len or !self.deps.living.entities.active[index]) return null;
                const store = self.deps.living.entities;
                return .{ .id = store.entity_ids[index], .uuid = store.uuids[index], .canonical_type = entity_store.livingEntityCanonicalTypeId(store.entity_types[index]), .position = .{ .x = store.position_x[index], .y = store.position_y[index], .z = store.position_z[index] }, .yaw = store.yaw[index], .pitch = store.pitch[index], .on_ground = store.on_ground[index] };
            },
            .item => {
                if (index >= self.deps.items.active.len or !self.deps.items.active[index]) return null;
                return .{ .id = self.deps.items.entity_ids[index], .uuid = self.deps.items.uuids[index], .canonical_type = registry.entity_item_type_id, .position = .{ .x = self.deps.items.position_x[index], .y = self.deps.items.position_y[index], .z = self.deps.items.position_z[index] }, .yaw = 0, .pitch = 0, .on_ground = self.deps.items.on_ground[index] };
            },
        }
    }

    pub fn sendSystemText(self: *Packets, slot: u16, text: []const u8) bool {
        const Arguments = struct { text: []const u8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                var rest = protocol_versions.staticCall("startSystemChat", protocol.value, .{output}) catch return null;
                rest = protocol_support.write_u8(rest, 10) catch return null;
                rest = protocol_support.write_u8(rest, 8) catch return null;
                rest = protocol_support.write_u16(rest, 4) catch return null;
                rest = protocol_support.write_bytes(rest, "text") catch return null;
                rest = protocol_support.write_u16(rest, @intCast(arguments.text.len)) catch return null;
                rest = protocol_support.write_bytes(rest, arguments.text) catch return null;
                rest = protocol_support.write_u8(rest, 0) catch return null;
                rest = protocol_support.write_bool(rest, false) catch return null;
                return generatedPacket(output[0 .. output.len - rest.len]);
            }
        };
        if (text.len > std.math.maxInt(u16)) return false;
        const arguments = Arguments{ .text = text };
        return self.sendPlayer(slot, .other, .{
            .phase = .play,
            .maximum_payload_bytes = text.len + 16,
            .context = &arguments,
            .encode = Encoder.encode,
        });
    }

    fn sendContainer(self: *Packets, slot: u16) void {
        if (slot >= self.deps.players.records.len or slot >= self.deps.containers.open.len) return;
        if (self.deps.containers.open[slot].kind == .none) return;
        const state_id = self.deps.containers.nextStateId(self.deps.players, slot);
        const Arguments = struct { player: *const players.CorePlayer, open: *const players.OpenContainer, state_id: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                const container = arguments.open.*;
                var rest = protocol_versions.staticCall("startWindowItems", protocol.value, .{ output, container.id, arguments.state_id }) catch return null;
                const snapshot = arguments.player.*;
                const top_count: usize = if (container.kind == .crafting_table) 10 else container.top_slot_count;
                const count = top_count + snapshot.main_inventory.len + snapshot.hotbar.len;
                rest = protocol_support.write_count(rest, i32, count) catch return null;
                if (container.kind == .crafting_table) {
                    rest = writeWireStack(protocol.value, rest, container.crafting_result) orelse return null;
                    for (container.crafting_grid) |stack| rest = writeWireStack(protocol.value, rest, stack) orelse return null;
                } else {
                    for (container.top_slots[0..container.top_slot_count]) |stack| rest = writeWireStack(protocol.value, rest, stack) orelse return null;
                }
                for (snapshot.main_inventory) |stack| rest = writeWireStack(protocol.value, rest, stack) orelse return null;
                for (snapshot.hotbar) |stack| rest = writeWireStack(protocol.value, rest, stack) orelse return null;
                rest = writeWireStack(protocol.value, rest, snapshot.cursor_stack) orelse return null;
                return generatedPacket(output[0 .. output.len - rest.len]);
            }
        };
        const arguments = Arguments{ .player = &self.deps.players.records[slot], .open = &self.deps.containers.open[slot], .state_id = state_id };
        _ = self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 32 * 1024, .context = &arguments, .encode = Encoder.encode });
    }

    fn sendOpenContainer(self: *Packets, slot: u16, title: []const u8) void {
        if (slot >= self.deps.containers.open.len) return;
        const container = self.deps.containers.open[slot];
        if (container.kind == .none) return;
        const Arguments = struct { id: i32, menu_type: i32, title: []const u8 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeOpenWindow", protocol.value, .{ output, arguments.id, arguments.menu_type, arguments.title }) catch return null);
            }
        };
        const arguments = Arguments{ .id = container.id, .menu_type = container.menu_type, .title = title };
        _ = self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = title.len + 64, .context = &arguments, .encode = Encoder.encode });
    }

    fn sendCloseContainer(self: *Packets, slot: u16, window_id: i32) void {
        const Arguments = struct { id: i32 };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                return generatedPacket(protocol_versions.staticCall("encodeCloseWindow", protocol.value, .{ output, arguments.id }) catch return null);
            }
        };
        const arguments = Arguments{ .id = window_id };
        _ = self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode });
    }

    fn sendContainerProperties(self: *Packets, slot: u16, properties: []const packet_args.ContainerProperty) void {
        if (slot >= self.deps.containers.open.len) return;
        const window_id = self.deps.containers.open[slot].id;
        for (properties) |property| {
            const Arguments = struct { window_id: i32, property: packet_args.ContainerProperty };
            const Encoder = struct {
                fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                    const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                    return generatedPacket(protocol_versions.staticCall("encodeContainerProperty", protocol.value, .{ output, arguments.window_id, arguments.property.id, arguments.property.value }) catch return null);
                }
            };
            const arguments = Arguments{ .window_id = window_id, .property = property };
            _ = self.sendPlayer(slot, .control, .{ .phase = .play, .maximum_payload_bytes = 16, .context = &arguments, .encode = Encoder.encode });
        }
    }

    const BlockPacket = struct {
        position: geometry.BlockPos,
        state: i32,
    };

    fn sendBlock(self: *Packets, value: struct { world: world_identity.Handle, position: geometry.BlockPos, state: i32 }, class: session_settings.DeliveryClass) void {
        const temporary = self.temporary orelse return;
        const recipients = self.worldRecipients(temporary, value.world) orelse return self.fail(.temporary_full);
        self.sendBlockRecipients(temporary, recipients, .{ .position = value.position, .state = value.state }, class);
    }

    fn sendBlockToPlayer(self: *Packets, slot: u16, value: BlockPacket, class: session_settings.DeliveryClass) void {
        const temporary = self.temporary orelse return;
        const player = self.deps.players.session(slot) orelse return;
        self.sendBlockRecipients(temporary, &.{player}, value, class);
    }

    fn sendBlockRecipients(self: *Packets, temporary: std.mem.Allocator, recipients: []const players.Session, value: BlockPacket, class: session_settings.DeliveryClass) void {
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const BlockPacket = @ptrCast(@alignCast(raw));
                const state = protocol_versions.staticWireBlockState(protocol.value, arguments.state) catch return null;
                const payload = protocol_versions.staticCall("encodeBlockChange", protocol.value, .{ output, arguments.position.x, arguments.position.y, arguments.position.z, state }) catch return null;
                return generatedPacket(payload);
            }
        };
        _ = self.deps.sessions.fanout(temporary, recipients, class, .{ .phase = .play, .maximum_payload_bytes = 32, .context = &value, .encode = Encoder.encode }) catch self.fail(.temporary_full);
    }

    fn sendSectionBlocks(self: *Packets, world: world_identity.Handle, chunk_x: i32, section_y: i32, chunk_z: i32, changes: []const packet_args.BlockChanged) void {
        const temporary = self.temporary orelse return;
        const recipients = self.worldRecipients(temporary, world) orelse return self.fail(.temporary_full);
        const Arguments = struct {
            chunk_x: i32,
            section_y: i32,
            chunk_z: i32,
            changes: []const packet_args.BlockChanged,
        };
        const Encoder = struct {
            fn encode(raw: *const anyopaque, protocol: session_settings.Protocol, output: []u8) ?session_settings.EncodedPacket {
                const arguments: *const Arguments = @ptrCast(@alignCast(raw));
                var records: [@import("world/mutations.zig").maximum_writes]i32 = undefined;
                if (arguments.changes.len > records.len) return null;
                for (arguments.changes, records[0..arguments.changes.len]) |change, *record| {
                    const state = protocol_versions.staticWireBlockState(protocol.value, change.block_state) catch return null;
                    const local = (@as(i32, change.pos.x & 15) << 8) |
                        (@as(i32, change.pos.z & 15) << 4) |
                        @as(i32, change.pos.y & 15);
                    record.* = (state << 12) | local;
                }
                return generatedPacket(protocol_versions.staticCall(
                    "encodeSectionBlockChanges",
                    protocol.value,
                    .{ output, arguments.chunk_x, arguments.section_y, arguments.chunk_z, records[0..arguments.changes.len] },
                ) catch return null);
            }
        };
        const arguments = Arguments{ .chunk_x = chunk_x, .section_y = section_y, .chunk_z = chunk_z, .changes = changes };
        _ = self.deps.sessions.fanout(temporary, recipients, .other, .{
            .phase = .play,
            .maximum_payload_bytes = 24 + changes.len * 5,
            .context = &arguments,
            .encode = Encoder.encode,
        }) catch self.fail(.temporary_full);
    }

    fn fail(self: *Packets, value: Failure) void {
        if (self.overflow == null) self.overflow = value;
    }
};

fn playerEntityFlags(sneaking: bool, sprinting: bool) i8 {
    const value = (@as(u8, @intFromBool(sneaking)) << 1) |
        (@as(u8, @intFromBool(sprinting)) << 3);
    return @bitCast(value);
}

fn abilityFlags(gamemode: players.GameMode) i8 {
    return @bitCast(@as(u8, switch (gamemode) {
        .survival, .adventure => 0,
        .creative => 0x0d,
        .spectator => 0x07,
    }));
}

fn playerWindowStack(player: *const players.CorePlayer, protocol_slot: usize) players.HotbarStack {
    std.debug.assert(protocol_slot < 46);
    return if (protocol_slot == 0)
        player.crafting_result
    else if (protocol_slot <= 4)
        player.crafting_grid[protocol_slot - 1]
    else if (protocol_slot <= 8)
        player.armor[protocol_slot - 5]
    else if (protocol_slot <= 35)
        player.main_inventory[protocol_slot - 9]
    else if (protocol_slot <= 44)
        player.hotbar[protocol_slot - 36]
    else
        player.offhand;
}

fn generatedPacket(payload: []const u8) ?session_settings.EncodedPacket {
    if (payload.len == 0) return null;
    return .{ .payload = payload };
}

fn angle(value: f32) i8 {
    if (!std.math.isFinite(value)) return 0;
    const encoded = @floor(@mod(value, 360.0) * (256.0 / 360.0));
    std.debug.assert(encoded >= 0 and encoded < 256);
    return @bitCast(@as(u8, @intFromFloat(encoded)));
}

fn relativeMoveDelta(previous: f64, current: f64) ?i16 {
    const scaled = @round((current - previous) * 4096.0);
    if (!std.math.isFinite(scaled) or scaled < std.math.minInt(i16) or scaled > std.math.maxInt(i16)) return null;
    return @intFromFloat(scaled);
}

fn velocity(value: f64) i16 {
    return @intFromFloat(std.math.clamp(value * 8000.0, @as(f64, std.math.minInt(i16)), @as(f64, std.math.maxInt(i16))));
}

fn writeWireStack(protocol: i32, buffer: []u8, stack: players.HotbarStack) ?[]u8 {
    var rest = protocol_support.write_varint(buffer, if (stack.count == 0) 0 else @as(i32, stack.count)) catch return null;
    if (stack.count == 0) return rest;
    const item = protocol_versions.staticWireItem(protocol, stack.item_id) catch return null;
    rest = protocol_support.write_varint(rest, item) catch return null;
    rest = protocol_support.write_varint(rest, @intFromBool(stack.damage != 0)) catch return null;
    rest = protocol_support.write_varint(rest, 0) catch return null;
    if (stack.damage != 0) {
        rest = protocol_support.write_varint(rest, protocol_versions.staticDamageComponentId(protocol)) catch return null;
        rest = protocol_support.write_varint(rest, stack.damage) catch return null;
    }
    return rest;
}
