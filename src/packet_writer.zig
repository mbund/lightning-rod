const block_store = @import("world/blocks.zig");
const player_store = @import("world/players.zig");
const geometry = @import("world/geometry.zig");
const std = @import("std");
const config = @import("config.zig").value;
const play_decode = @import("play_decode.zig");
const packet_input = @import("packet_input.zig");
const chat_batch = @import("chat.zig");
const command_batch = @import("commands.zig");
const packet_events = @import("packet_args.zig");
const plugin_api = @import("plugin_api.zig");
const registry = @import("registry_data");
const light_projection = @import("light_projection.zig");
const world_identity = @import("world/identity.zig");
const tick_host = @import("tick_host.zig");

pub const Packets = struct {
    backend: *tick_host.Host,
    command_declarations: []const command_batch.Declaration = &.{},
    first_error: ?anyerror = null,
    first_error_system: ?plugin_api.ActiveSystem = null,

    chats: chat_batch.Batch = .{},
    commands: command_batch.Batch = .{},
    pending_block_changes: [
        config.tick_block_request_capacity +
            config.max_random_tick_block_changes_per_tick
    ]packet_events.BlockChanged =
        undefined,
    pending_block_change_count: usize = 0,
    pending_equipment: [(config.connectionCapacity() + 63) / 64]u64 =
        [_]u64{0} ** ((config.connectionCapacity() + 63) / 64),

    const Self = @This();
    pub const production_packet_writer = true;
    pub const profiles_living = false;
    const player_tracking_range: f64 = 128;
    const living_tracking_range: f64 = 80;
    const item_tracking_range: f64 = 64;

    pub fn init(backend: *tick_host.Host) Self {
        return .{ .backend = backend };
    }

    pub fn initWithCommands(
        backend: *tick_host.Host,
        declarations: []const command_batch.Declaration,
    ) Self {
        return .{ .backend = backend, .command_declarations = declarations };
    }

    fn trackable(
        self: *const Self,
        target_slot: u16,
        world: world_identity.Handle,
        position: geometry.Vec3,
        range: f64,
    ) bool {
        const player = &self.backend.players.records[target_slot];
        if (!player.world.eql(world)) return false;
        const observer = player.position;
        const dx = observer.x - position.x;
        const dy = observer.y - position.y;
        const dz = observer.z - position.z;
        return dx * dx + dy * dy + dz * dz <= range * range and
            self.backend.hasSentChunkAtPosition(target_slot, world, position);
    }

    pub fn inputHandler(self: *Self) play_decode.Handler {
        return packet_input.handler(self);
    }

    pub fn input_failed(self: *Self, err: anyerror) void {
        self.recordError(err);
    }

    fn recordError(self: *Self, err: anyerror) void {
        if (self.first_error != null) return;
        self.first_error = err;
        self.first_error_system = plugin_api.activeSystem();
    }

    inline fn bestEffort(self: *Self, result: anyerror!void) void {
        result catch |err| switch (err) {
            error.PlayerWriteBackpressure, error.OutputKernelUnavailable => {},
            else => self.recordError(err),
        };
    }

    pub fn send(self: *Self, result: anyerror!void) bool {
        result catch |err| switch (err) {
            error.PlayerWriteBackpressure => return false,
            else => {
                self.recordError(err);
                return false;
            },
        };
        return true;
    }

    fn broadcastPlayerEquipment(self: *Self, subject_slot: u16) void {
        if (self.pending_block_change_count != 0) {
            self.pending_equipment[subject_slot >> 6] |=
                @as(u64, 1) << @intCast(subject_slot & 63);
            return;
        }
        self.broadcastPlayerEquipmentNow(subject_slot);
    }

    fn broadcastPlayerEquipmentNow(self: *Self, subject_slot: u16) void {
        for (self.backend.activePlaySlots()) |target_slot| {
            if (target_slot == subject_slot) continue;
            if (!self.backend.playerVisible(target_slot, subject_slot)) continue;
            _ = self.send(self.backend.queue_entity_equipment(target_slot, subject_slot));
        }
    }

    fn syncInventory(self: *Self, slot: u16) void {
        switch (self.backend.containers.open[slot].kind) {
            .none => self.bestEffort(self.backend.queue_player_inventory(slot)),
            .crafting_table => self.bestEffort(self.backend.queue_crafting_table_inventory(slot)),
            .chest, .furnace => self.bestEffort(self.backend.queue_container_inventory(slot)),
        }
    }

    fn livingPosition(self: *const Self, index: u16) geometry.Vec3 {
        return .{
            .x = self.backend.living.entities.position_x[index],
            .y = self.backend.living.entities.position_y[index],
            .z = self.backend.living.entities.position_z[index],
        };
    }

    pub fn sendLivingSpawn(self: *Self, target_slot: u16, index: u16) bool {
        if (!self.send(self.backend.queue_spawn_living_entity(target_slot, index))) return false;
        self.backend.setLivingVisible(target_slot, index, true);
        if (!self.send(self.backend.queue_living_entity_metadata(target_slot, index))) return false;
        for (0..6) |equipment_slot| {
            if (self.backend.living.entities.equipment[index][equipment_slot].count == 0) continue;
            if (!self.send(self.backend.queue_living_equipment(target_slot, index, @intCast(equipment_slot)))) return false;
        }
        return true;
    }

    fn sendPlayerSpawn(self: *Self, target_slot: u16, subject_slot: u16) bool {
        if (!self.send(self.backend.queue_spawn_player_entity(target_slot, subject_slot))) return false;
        self.backend.setPlayerVisible(target_slot, subject_slot, true);
        if (!self.send(self.backend.queue_player_state_metadata(target_slot, subject_slot))) return false;
        if (self.backend.players.selectedHotbarStack(subject_slot).count != 0)
            if (!self.send(self.backend.queue_entity_equipment(target_slot, subject_slot))) return false;
        return self.send(self.backend.queue_player_entity_position(target_slot, subject_slot));
    }

    pub fn teleport_confirm(_: *Self, _: u16, _: i32) void {}

    pub fn keep_alive_response(self: *Self, slot: u16, id: i64) void {
        self.backend.completePlayKeepAlive(slot, id);
    }

    pub fn movement(self: *Self, slot: u16, position: ?play_decode.Position, rotation: ?play_decode.Rotation, on_ground: bool) !void {
        self.backend.inputs.queueMovement(
            slot,
            if (position) |value| .{ .x = value.x, .y = value.y, .z = value.z } else null,
            if (rotation) |value| .{ .yaw = value.yaw, .pitch = value.pitch } else null,
            on_ground,
        );
    }

    pub fn player_input(self: *Self, slot: u16, shift: bool, sprint: bool) void {
        self.backend.inputs.queuePlayerInput(slot, shift, sprint);
    }

    pub fn player_sprint(self: *Self, slot: u16, sprinting: bool) void {
        self.backend.inputs.queueSprintAction(slot, sprinting);
    }

    pub fn player_loaded(_: *Self, _: u16) void {}

    pub fn chat(self: *Self, slot: u16, message: []const u8) !void {
        if (message.len > config.max_chat_message_bytes) return error.ChatMessageTooLong;
        _ = try self.chats.append(slot, message);
    }

    pub fn command(self: *Self, slot: u16, text: []const u8) !void {
        if (text.len > config.max_chat_message_bytes) return error.ChatMessageTooLong;
        _ = try self.commands.append(slot, text);
    }

    pub fn block_dig(self: *Self, slot: u16, status: i32, location: play_decode.BlockPosition, face: i32, sequence: i32) !void {
        const pos = geometry.BlockPos{ .x = location.x, .y = location.y, .z = location.z };
        switch (status) {
            0 => self.backend.inputs.stageDigStart(slot, pos, face, sequence),
            1 => self.backend.inputs.stageDigCancel(slot),
            2 => self.backend.inputs.stageDigFinish(slot, pos, sequence),
            3, 4 => self.backend.inputs.requestItemDrop(slot, if (status == 3) 64 else 1),
            else => {},
        }
        self.acknowledge_dig(.{ .slot = slot, .sequence = sequence });
    }

    pub fn block_place(
        self: *Self,
        slot: u16,
        against: play_decode.BlockPosition,
        direction: i32,
        cursor_x: f32,
        cursor_y: f32,
        cursor_z: f32,
        sequence: i32,
    ) !void {
        const against_pos = geometry.BlockPos{ .x = against.x, .y = against.y, .z = against.z };
        try self.backend.inputs.stageBlockRequest(self.backend.players, .{
            .world = self.backend.players.records[slot].world,
            .slot = slot,
            .kind = .use_item_on,
            .pos = offsetBlockPos(against_pos, direction),
            .against_pos = against_pos,
            .face = direction,
            .cursor = .{ .x = cursor_x, .y = cursor_y, .z = cursor_z },
            .sequence = sequence,
        });
        self.acknowledge_dig(.{ .slot = slot, .sequence = sequence });
    }

    pub fn held_item_slot(self: *Self, slot: u16, selected: i16) !void {
        self.backend.players.setSelectedHotbarSlot(slot, selected);
        self.hotbar_selected(slot);
    }

    pub fn arm_animation(self: *Self, slot: u16, hand: i32) !void {
        try self.backend.inputs.requestArmSwing(self.backend.players, slot, hand);
    }

    pub fn attack_entity(self: *Self, slot: u16, entity_id: i32) !void {
        try self.backend.inputs.requestEntityAttack(self.backend.players, slot, entity_id);
    }

    pub fn interact_entity(self: *Self, slot: u16, entity_id: i32, hand: i32) !void {
        try self.backend.inputs.requestLivingInteraction(self.backend.players, slot, entity_id, hand);
    }

    pub fn respawn(self: *Self, slot: u16) !void {
        try self.backend.inputs.requestRespawn(self.backend.players, slot);
    }

    pub fn use_item(self: *Self, slot: u16, sequence: i32) !void {
        self.acknowledge_dig(.{ .slot = slot, .sequence = sequence });
    }

    pub fn window_click(self: *Self, slot: u16, window_id: i32, state_id: i32, protocol_slot: i16, mouse_button: i8, mode: i32) !void {
        try self.backend.inputs.enqueueInventoryClick(self.backend.players, .{
            .slot = slot,
            .window_id = window_id,
            .state_id = state_id,
            .protocol_slot = protocol_slot,
            .mouse_button = mouse_button,
            .mode = mode,
        });
    }

    pub fn creative_slot(self: *Self, slot: u16, inventory_slot: i16, item_id: i32, count: u8) !void {
        try self.backend.inputs.requestCreativeSlot(self.backend.players, slot, inventory_slot, item_id, count);
    }

    pub fn close_window(self: *Self, slot: u16, window_id: i32) !void {
        self.backend.inputs.requestContainerClose(slot, window_id);
    }

    pub fn ignored(_: *Self, _: u16) void {}

    pub fn sendJoinCommands(self: *Self, slot: u16) bool {
        return self.send(self.backend.queue_declare_commands(slot, self.command_declarations));
    }

    pub fn request_reload(self: *Self, slot: u16) void {
        self.backend.requestReload(slot);
    }

    pub fn player_moved(self: *Self, change: packet_events.PlayerMoved) void {
        const moving = &self.backend.players.records[change.slot];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (target_slot == change.slot) continue;
            const was_visible = self.backend.playerVisible(target_slot, change.slot);
            const is_visible = self.trackable(
                target_slot,
                moving.world,
                moving.position,
                player_tracking_range,
            );
            if (!is_visible) {
                if (was_visible and self.send(self.backend.queue_entity_destroy(target_slot, moving.entity_id)))
                    self.backend.setPlayerVisible(target_slot, change.slot, false);
                continue;
            }
            if (!was_visible) {
                _ = self.sendPlayerSpawn(target_slot, change.slot);
                continue;
            }
            if (!self.send(self.backend.queue_entity_move_look(target_slot, change.slot, change.previous))) continue;
            if (moving.rotation.yaw != change.previous.rotation.yaw)
                _ = self.send(self.backend.queue_entity_head_rotation(target_slot, change.slot));
        }
    }
    pub fn player_flags_changed(self: *Self, slot: u16) void {
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.playerVisible(target_slot, slot)) continue;
            _ = self.send(self.backend.queue_player_state_metadata(target_slot, slot));
        }
    }
    pub fn player_movement_rejected(self: *Self, slot: u16) void {
        if (self.first_error == null) self.bestEffort(self.backend.queue_player_position(slot));
    }
    pub fn arm_swing(self: *Self, swing: packet_events.ArmSwing) void {
        if (!self.backend.claimArmSwing(swing.slot)) return;
        const player = &self.backend.players.records[swing.slot];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (target_slot == swing.slot) continue;
            if (!self.backend.playerVisible(target_slot, swing.slot)) continue;
            _ = self.send(self.backend.queue_arm_swing(target_slot, player.entity_id, swing.hand));
        }
    }
    pub fn block_break_animation(self: *Self, animation: packet_events.BlockBreakAnimation) void {
        const breaker = &self.backend.players.records[animation.slot];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (target_slot == animation.slot) continue;
            if (!self.backend.canSeeBlock(target_slot, animation.world, animation.pos)) continue;
            _ = self.send(self.backend.queue_block_break_animation(target_slot, breaker.entity_id, animation.pos, animation.stage));
        }
    }
    pub fn acknowledge_dig(self: *Self, ack: packet_events.AcknowledgeDig) void {
        if (self.first_error == null) self.bestEffort(self.backend.queue_acknowledge_player_digging(ack.slot, ack.sequence));
    }
    pub fn block_changed(self: *Self, change: packet_events.BlockChanged) void {
        if (self.pending_block_change_count == self.pending_block_changes.len) {
            self.input_failed(error.TickBlockChangeCapacity);
            return;
        }
        self.pending_block_changes[self.pending_block_change_count] = change;
        self.pending_block_change_count += 1;
    }
    pub fn flushBlockChanges(self: *Self) void {
        if (self.first_error != null) return;
        for (self.pending_block_changes[0..self.pending_block_change_count]) |change| {
            for (self.backend.activePlaySlots()) |target_slot| {
                if (!self.backend.canSeeBlockChange(target_slot, change.world, change.pos)) continue;
                const visible_state =
                    self.backend.visibleBlockChangeState(target_slot, change.world, change.pos);
                _ = self.send(self.backend.queue_block_change(
                    target_slot,
                    change.pos.x,
                    change.pos.z,
                    change.pos.y,
                    visible_state,
                ));
            }
        }
        self.pending_block_change_count = 0;
        for (&self.pending_equipment, 0..) |*word, word_index| {
            var remaining = word.*;
            word.* = 0;
            while (remaining != 0) {
                const bit: usize = @intCast(@ctz(remaining));
                remaining &= remaining - 1;
                self.broadcastPlayerEquipmentNow(
                    @intCast(word_index * 64 + bit),
                );
            }
        }
    }
    pub fn light_changed(self: *Self, world: world_identity.Handle, update: light_projection.Update) void {
        if (!self.backend.chunkStreamingEnabled()) return;
        const chunk = geometry.ChunkPos{
            .x = update.chunk.chunk_x,
            .z = update.chunk.chunk_z,
        };
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!lightUpdateVisible(self.backend.players.records[target_slot].world, world)) continue;
            if (!self.backend.hasSentChunk(target_slot, chunk)) continue;
            _ = self.send(self.backend.queue_update_light(target_slot, update));
        }
    }
    pub fn block_correction(self: *Self, correction: packet_events.BlockCorrection) void {
        if (self.first_error != null) return;
        const visible_state = self.backend.visibleBlockState(correction.slot, correction.pos);
        self.bestEffort(self.backend.queue_block_change(correction.slot, correction.pos.x, correction.pos.z, correction.pos.y, visible_state));
    }
    pub fn hotbar_changed(self: *Self, change: packet_events.HotbarChanged) void {
        if (self.first_error != null) return;
        self.bestEffort(self.backend.queue_player_inventory_slot(change.slot, change.hotbar_slot));
        if (self.first_error == null and self.backend.players.records[change.slot].selected_hotbar_slot == change.hotbar_slot) {
            self.broadcastPlayerEquipment(change.slot);
            if (self.first_error == null) self.bestEffort(self.backend.queue_player_combat_attributes(change.slot));
        }
    }
    pub fn hotbar_selected(self: *Self, slot: u16) void {
        if (self.first_error != null) return;
        self.broadcastPlayerEquipment(slot);
        if (self.first_error == null) self.bestEffort(self.backend.queue_player_combat_attributes(slot));
    }
    pub fn gamemode_changed(self: *Self, change: packet_events.GamemodeChanged) void {
        if (self.first_error != null) return;
        self.bestEffort(self.backend.queue_gamemode_change(change.slot, change.value));
        if (self.first_error == null) self.bestEffort(self.backend.queue_player_abilities(change.slot, change.value));
        if (self.first_error == null) {
            for (self.backend.activePlaySlots()) |target_slot|
                _ = self.send(self.backend.queue_player_info_gamemode(target_slot, change.slot));
        }
    }
    pub fn time_changed(self: *Self) void {
        if (self.first_error != null) return;
        for (self.backend.activePlaySlots()) |slot| {
            _ = self.send(self.backend.queue_update_time(slot));
        }
    }
    pub fn chat_recipient(self: *Self, target_slot: u16, draft: *const chat_batch.Draft) void {
        _ = self.send(self.backend.queue_system_chat_format(target_slot, "{f}", .{chat_batch.Line{ .draft = draft }}));
    }
    /// Plugin-facing system message API. Callers use ordinary Zig format
    /// strings and arguments; the formatted slice is consumed immediately
    /// by the recipient's version-specific packet encoder.
    pub fn system(self: *Self, slot: u16, comptime format: []const u8, args: anytype) void {
        if (comptime @typeInfo(@TypeOf(args)).@"struct".fields.len == 0) {
            _ = comptime std.fmt.count(format, args);
            self.bestEffort(self.backend.queue_system_chat_text(slot, format));
            return;
        }
        self.bestEffort(self.backend.queue_system_chat_format(slot, format, args));
    }

    fn itemShouldBeVisible(self: *const Self, target_slot: u16, index: u16) bool {
        return self.backend.items.active[index] and
            self.trackable(
                target_slot,
                self.backend.items.worlds[index],
                self.backend.items.position(index),
                item_tracking_range,
            );
    }

    fn sendPendingItemMetadata(self: *Self, target_slot: u16, index: u16) bool {
        if (!self.backend.itemMetadataPending(target_slot, index)) return true;
        if (!self.send(self.backend.queue_item_entity_metadata(target_slot, index))) {
            self.backend.requestItemSync(target_slot);
            return false;
        }
        self.backend.setItemMetadataPending(target_slot, index, false);
        return true;
    }

    fn ensureItemVisible(self: *Self, target_slot: u16, index: u16) bool {
        if (!self.itemShouldBeVisible(target_slot, index)) return false;
        if (self.backend.itemVisible(target_slot, index))
            return self.sendPendingItemMetadata(target_slot, index);
        if (!self.send(self.backend.queue_spawn_item_entity(target_slot, index))) {
            self.backend.requestItemSync(target_slot);
            return false;
        }
        self.backend.setItemVisible(target_slot, index, true);
        self.backend.setItemMetadataPending(target_slot, index, true);
        return self.sendPendingItemMetadata(target_slot, index);
    }

    pub fn item_spawned(self: *Self, index: u16) void {
        for (self.backend.activePlaySlots()) |target_slot| {
            if (self.backend.itemVisible(target_slot, index)) {
                if (!self.send(self.backend.queue_entity_destroy(target_slot, self.backend.items.entity_ids[index]))) {
                    self.backend.requestItemSync(target_slot);
                    continue;
                }
                self.backend.setItemVisible(target_slot, index, false);
            }
            _ = self.ensureItemVisible(target_slot, index);
        }
    }
    pub fn item_moved(self: *Self, index: u16) void {
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.itemShouldBeVisible(target_slot, index)) {
                if (!self.backend.itemVisible(target_slot, index)) continue;
                if (self.send(self.backend.queue_entity_destroy(target_slot, self.backend.items.entity_ids[index])))
                    self.backend.setItemVisible(target_slot, index, false)
                else
                    self.backend.requestItemSync(target_slot);
                continue;
            }
            const was_visible = self.backend.itemVisible(target_slot, index);
            if (!self.ensureItemVisible(target_slot, index)) continue;
            if (was_visible)
                _ = self.send(self.backend.queue_item_entity_position_sync(target_slot, index));
        }
    }
    pub fn item_metadata_changed(self: *Self, index: u16) void {
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.itemShouldBeVisible(target_slot, index)) continue;
            if (!self.ensureItemVisible(target_slot, index)) continue;
            self.backend.setItemMetadataPending(target_slot, index, true);
            _ = self.sendPendingItemMetadata(target_slot, index);
        }
    }
    pub fn entity_destroyed(self: *Self, entity_id: i32) void {
        const first_item_entity_id: i32 = @intCast(config.connectionCapacity() + 1);
        const raw_index = entity_id - first_item_entity_id;
        if (raw_index < 0 or raw_index >= config.max_item_entities) return;
        const index: u16 = @intCast(raw_index);
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.itemVisible(target_slot, index)) continue;
            if (self.send(self.backend.queue_entity_destroy(target_slot, entity_id)))
                self.backend.setItemVisible(target_slot, index, false)
            else
                self.backend.requestItemSync(target_slot);
        }
    }
    pub fn item_collected(self: *Self, collected: packet_events.ItemCollected) void {
        const first_item_entity_id: i32 =
            @intCast(config.connectionCapacity() + 1);
        const raw_index = collected.item_entity_id - first_item_entity_id;
        if (raw_index < 0 or raw_index >= config.max_item_entities) return;
        const index: u16 = @intCast(raw_index);
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.itemVisible(target_slot, index)) continue;
            _ = self.send(self.backend.queue_collect_item(target_slot, collected.item_entity_id, collected.collector_entity_id, collected.count));
        }
    }
    pub fn inventory_changed(self: *Self, slot: u16) void {
        if (self.first_error != null) return;
        self.syncInventory(slot);
        if (self.first_error == null) self.broadcastPlayerEquipment(slot);
        if (self.first_error == null) self.bestEffort(self.backend.queue_player_combat_attributes(slot));
    }
    pub fn inventory_slot_changed(self: *Self, change: packet_events.InventorySlotChanged) void {
        if (self.first_error != null) return;
        self.bestEffort(self.backend.queue_player_inventory_slot(change.slot, change.inventory_slot));
        const player = &self.backend.players.records[change.slot];
        if (self.first_error == null and change.inventory_slot == player.selected_hotbar_slot) {
            self.broadcastPlayerEquipment(change.slot);
            if (self.first_error == null) self.bestEffort(self.backend.queue_player_combat_attributes(change.slot));
        }
    }
    pub fn player_screen_slot_changed(self: *Self, change: packet_events.PlayerScreenSlotChanged) void {
        if (self.first_error != null) return;
        self.bestEffort(self.backend.queue_player_screen_slot(change.slot, change.screen_slot));
    }
    pub fn container_opened(self: *Self, slot: u16) void {
        if (self.first_error != null) return;
        if (self.send(self.backend.queue_open_crafting_table(slot))) self.syncInventory(slot);
    }
    pub fn menu_opened(self: *Self, opened: packet_events.ContainerOpened) void {
        if (self.first_error != null) return;
        if (!self.send(self.backend.queue_open_container(opened.slot, opened.title))) return;
        if (!self.send(self.backend.queue_container_inventory(opened.slot))) return;
        for (opened.properties) |property|
            self.bestEffort(self.backend.queue_container_property(opened.slot, property.id, property.value));
    }
    pub fn menu_changed(self: *Self, slot: u16, properties: []const packet_events.ContainerProperty) void {
        if (self.first_error != null) return;
        if (!self.send(self.backend.queue_container_inventory(slot))) return;
        for (properties) |property|
            self.bestEffort(self.backend.queue_container_property(slot, property.id, property.value));
    }
    pub fn menu_player_inventory_changed(self: *Self, slot: u16, properties: []const packet_events.ContainerProperty) void {
        self.menu_changed(slot, properties);
        if (self.first_error == null) self.broadcastPlayerEquipment(slot);
        if (self.first_error == null) self.bestEffort(self.backend.queue_player_combat_attributes(slot));
    }
    pub fn menu_properties_changed(self: *Self, slot: u16, properties: []const packet_events.ContainerProperty) void {
        if (self.first_error != null) return;
        for (properties) |property|
            self.bestEffort(self.backend.queue_container_property(slot, property.id, property.value));
    }
    pub fn chest_viewers_changed(self: *Self, change: packet_events.ChestViewersChanged) void {
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.canSeeBlock(target_slot, change.world, change.position)) continue;
            _ = self.send(self.backend.queue_block_action(
                target_slot,
                change.position,
                1,
                change.viewers,
                registry.block_chest_id,
            ));
        }
    }
    pub fn container_closed(self: *Self, closed: packet_events.ContainerClosed) void {
        if (self.first_error == null) self.bestEffort(self.backend.queue_close_window(closed.slot, closed.window_id));
    }
    pub fn living_spawned(self: *Self, index: u16) void {
        if (!self.backend.living.entities.active[index]) return;
        const position = self.livingPosition(index);
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.trackable(target_slot, self.backend.living.entities.worlds[index], position, living_tracking_range)) continue;
            if (self.backend.livingVisible(target_slot, index)) continue;
            _ = self.sendLivingSpawn(target_slot, index);
        }
    }
    pub fn living_moved(self: *Self, index: u16) void {
        if (!self.backend.living.entities.active[index]) return;
        const position = self.livingPosition(index);
        for (self.backend.activePlaySlots()) |target_slot| {
            const was_visible = self.backend.livingVisible(target_slot, index);
            const is_visible = self.trackable(
                target_slot,
                self.backend.living.entities.worlds[index],
                position,
                living_tracking_range,
            );
            if (!is_visible) {
                if (was_visible and self.send(self.backend.queue_entity_destroy(target_slot, self.backend.living.entities.entity_ids[index])))
                    self.backend.setLivingVisible(target_slot, index, false);
                continue;
            }
            if (!was_visible and !self.sendLivingSpawn(target_slot, index)) continue;
            if (self.backend.livingVisible(target_slot, index)) {
                _ = self.send(self.backend.queue_living_entity_position(target_slot, index));
                _ = self.send(self.backend.queue_living_entity_head_rotation(target_slot, index));
            }
        }
    }
    pub fn living_metadata_changed(self: *Self, index: u16) void {
        if (!self.backend.living.entities.active[index]) return;
        for (self.backend.activePlaySlots()) |target_slot| {
            if (self.backend.livingVisible(target_slot, index))
                _ = self.send(self.backend.queue_living_entity_metadata(target_slot, index));
        }
    }
    pub fn living_destroyed(self: *Self, destroyed: packet_events.LivingDestroyed) void {
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.livingVisible(target_slot, destroyed.index)) continue;
            if (self.send(self.backend.queue_entity_destroy(target_slot, destroyed.entity_id)))
                self.backend.setLivingVisible(target_slot, destroyed.index, false);
        }
    }
    pub fn living_arm_swing(self: *Self, index: u16) void {
        if (!self.backend.living.entities.active[index]) return;
        const position = self.livingPosition(index);
        const entity_id = self.backend.living.entities.entity_ids[index];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (self.backend.canSeePosition(target_slot, self.backend.living.entities.worlds[index], position))
                _ = self.send(self.backend.queue_arm_swing(target_slot, entity_id, 0));
        }
    }
    pub fn living_status(self: *Self, value: packet_events.LivingStatus) void {
        if (!self.backend.living.entities.active[value.index]) return;
        const entity_id = self.backend.living.entities.entity_ids[value.index];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (self.backend.livingVisible(target_slot, value.index))
                _ = self.send(self.backend.queue_entity_status(target_slot, entity_id, value.status));
        }
    }
    pub fn living_sound(self: *Self, value: packet_events.LivingSound) void {
        if (!self.backend.living.entities.active[value.index]) return;
        const position = self.livingPosition(value.index);
        for (self.backend.activePlaySlots()) |target_slot| {
            if (self.backend.canSeePosition(target_slot, self.backend.living.entities.worlds[value.index], position))
                _ = self.send(self.backend.queue_sound_effect(target_slot, value.sound, position, value.volume, value.pitch, value.seed));
        }
    }
    pub fn living_damaged(self: *Self, damage: packet_events.LivingDamaged) void {
        if (!self.backend.living.entities.active[damage.index]) return;
        const position = self.livingPosition(damage.index);
        const entity_id = self.backend.living.entities.entity_ids[damage.index];
        const attacker_id = self.backend.players.records[damage.attacker_slot].entity_id;
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.canSeePosition(target_slot, self.backend.living.entities.worlds[damage.index], position)) continue;
            if (!self.send(self.backend.queue_player_attack_damage(target_slot, entity_id, attacker_id))) continue;
            _ = self.send(self.backend.queue_living_entity_velocity(target_slot, damage.index));
        }
    }
    pub fn living_burned(self: *Self, index: u16) void {
        if (!self.backend.living.entities.active[index]) return;
        const position = self.livingPosition(index);
        const entity_id = self.backend.living.entities.entity_ids[index];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.canSeePosition(target_slot, self.backend.living.entities.worlds[index], position)) continue;
            _ = self.send(self.backend.queue_on_fire_damage(target_slot, entity_id));
        }
    }
    pub fn living_fell(self: *Self, index: u16) void {
        if (!self.backend.living.entities.active[index]) return;
        const position = self.livingPosition(index);
        const entity_id = self.backend.living.entities.entity_ids[index];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.canSeePosition(target_slot, self.backend.living.entities.worlds[index], position)) continue;
            _ = self.send(self.backend.queue_fall_damage(target_slot, entity_id));
        }
    }
    pub fn living_velocity_changed(self: *Self, velocity: packet_events.LivingVelocityChanged) void {
        if (!self.backend.living.entities.active[velocity.index]) return;
        const position = self.livingPosition(velocity.index);
        for (self.backend.activePlaySlots()) |target_slot| {
            if (self.backend.canSeePosition(target_slot, self.backend.living.entities.worlds[velocity.index], position))
                _ = self.send(self.backend.queue_living_entity_velocity_values(target_slot, velocity.index, velocity.x, velocity.y, velocity.z));
        }
    }
    pub fn living_died(self: *Self, death: packet_events.LivingDied) void {
        _ = death.attacker_slot;
        if (!self.backend.living.entities.active[death.index]) return;
        const entity_id = self.backend.living.entities.entity_ids[death.index];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (self.backend.livingVisible(target_slot, death.index))
                _ = self.send(self.backend.queue_entity_status(target_slot, entity_id, 3));
        }
    }
    pub fn living_equipment_changed(self: *Self, change: packet_events.LivingEquipmentChanged) void {
        if (!self.backend.living.entities.active[change.index]) return;
        for (self.backend.activePlaySlots()) |target_slot| {
            if (self.backend.livingVisible(target_slot, change.index))
                _ = self.send(self.backend.queue_living_equipment(target_slot, change.index, change.equipment_slot));
        }
    }
    pub fn player_damaged(self: *Self, damage: packet_events.PlayerDamaged) void {
        if (self.first_error != null) return;
        self.bestEffort(self.backend.queue_update_health(damage.slot));
        const player = &self.backend.players.records[damage.slot];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.canSeePosition(target_slot, player.world, player.position)) continue;
            const projected = switch (damage.source) {
                .mob => |attacker_entity_id| self.backend.queue_mob_attack_damage(target_slot, player.entity_id, attacker_entity_id),
                .player => |attacker_slot| self.backend.queue_player_attack_damage(
                    target_slot,
                    player.entity_id,
                    self.backend.players.records[attacker_slot].entity_id,
                ),
            };
            if (!self.send(projected)) continue;
            if (damage.fatal)
                _ = self.send(self.backend.queue_entity_status(target_slot, player.entity_id, 3));
        }
        _ = self.send(self.backend.queue_hurt_animation(damage.slot, player.entity_id, player.rotation.yaw));
        if (damage.knockback) |velocity|
            _ = self.send(self.backend.queue_player_velocity_values(damage.slot, damage.slot, velocity.x, velocity.y, velocity.z));
        if (damage.fatal) {
            switch (damage.source) {
                .mob => {
                    if (!self.send(self.backend.queue_player_death(damage.slot, damage.slot))) return;
                    for (self.backend.activePlaySlots()) |target_slot|
                        _ = self.send(self.backend.queue_system_chat_format(target_slot, "{s} was slain by Zombie", .{player.name_slice()}));
                },
                .player => |attacker_slot| {
                    if (!self.send(self.backend.queue_player_pvp_death(damage.slot, damage.slot, attacker_slot))) return;
                    const attacker = &self.backend.players.records[attacker_slot];
                    for (self.backend.activePlaySlots()) |target_slot|
                        _ = self.send(self.backend.queue_system_chat_format(
                            target_slot,
                            "{s} was slain by {s}",
                            .{ player.name_slice(), attacker.name_slice() },
                        ));
                },
            }
        }
    }
    pub fn player_fell(self: *Self, damage: packet_events.PlayerFell) void {
        if (self.first_error != null) return;
        self.bestEffort(self.backend.queue_update_health(damage.slot));
        const player = &self.backend.players.records[damage.slot];
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.canSeePosition(target_slot, player.world, player.position)) continue;
            if (!self.send(self.backend.queue_fall_damage(target_slot, player.entity_id))) continue;
            if (damage.fatal)
                _ = self.send(self.backend.queue_entity_status(target_slot, player.entity_id, 3));
        }
        if (damage.fatal) {
            if (!self.send(self.backend.queue_player_fall_death(damage.slot, damage.slot))) return;
            for (self.backend.activePlaySlots()) |target_slot| {
                _ = self.send(self.backend.queue_system_chat_format(target_slot, "{s} fell from a high place", .{player.name_slice()}));
            }
        }
    }
    pub fn player_health_changed(self: *Self, slot: u16) void {
        if (self.first_error == null) self.bestEffort(self.backend.queue_update_health(slot));
    }
    pub fn player_respawned(self: *Self, slot: u16) void {
        const player = &self.backend.players.records[slot];
        const center = geometry.ChunkPos{
            .x = geometry.chunkCoord(geometry.blockCoord(player.position.x)),
            .z = geometry.chunkCoord(geometry.blockCoord(player.position.z)),
        };
        self.backend.recenterChunkView(slot, center);
        self.synchronizePlayerWorld(slot, center);
    }
    pub fn player_world_changed(self: *Self, slot: u16) void {
        const player = &self.backend.players.records[slot];
        if (!self.retirePlayerProjection(slot)) return;
        const center = self.backend.resetClientWorldView(slot, player.position);
        self.synchronizePlayerWorld(slot, center);
    }

    pub fn player_teleported(self: *Self, slot: u16) void {
        if (!self.send(self.backend.queue_player_position(slot))) return;
        const player = &self.backend.players.records[slot];
        self.backend.requestItemSync(slot);
        for (self.backend.activePlaySlots()) |target_slot| {
            if (target_slot == slot) continue;
            const was_visible = self.backend.playerVisible(target_slot, slot);
            const is_visible = self.trackable(
                target_slot,
                player.world,
                player.position,
                player_tracking_range,
            );
            if (!is_visible) {
                if (was_visible and self.send(self.backend.queue_entity_destroy(target_slot, player.entity_id)))
                    self.backend.setPlayerVisible(target_slot, slot, false);
                continue;
            }
            if (!was_visible) {
                _ = self.sendPlayerSpawn(target_slot, slot);
                continue;
            }
            _ = self.send(self.backend.queue_player_entity_position(target_slot, slot));
        }
    }

    fn retirePlayerProjection(self: *Self, slot: u16) bool {
        for (self.backend.activePlaySlots()) |subject_slot| {
            if (subject_slot == slot or !self.backend.playerVisible(slot, subject_slot)) continue;
            const entity_id = self.backend.players.records[subject_slot].entity_id;
            if (!self.send(self.backend.queue_entity_destroy(slot, entity_id))) return false;
            self.backend.setPlayerVisible(slot, subject_slot, false);
        }
        for (self.backend.living.entities.active_indices[0..self.backend.living.entities.active_count]) |index| {
            if (!self.backend.livingVisible(slot, index)) continue;
            const entity_id = self.backend.living.entities.entity_ids[index];
            if (!self.send(self.backend.queue_entity_destroy(slot, entity_id))) return false;
            self.backend.setLivingVisible(slot, index, false);
        }
        var first: u16 = 0;
        while (self.backend.nextVisibleItem(slot, first)) |index| {
            first = index + 1;
            const entity_id = self.backend.items.entity_ids[index];
            if (!self.send(self.backend.queue_entity_destroy(slot, entity_id))) return false;
            self.backend.setItemVisible(slot, index, false);
        }
        return true;
    }

    fn synchronizePlayerWorld(self: *Self, slot: u16, center: geometry.ChunkPos) void {
        const player = &self.backend.players.records[slot];
        if (!self.send(self.backend.queue_respawn(slot))) return;
        if (!self.send(self.backend.queue_player_abilities(slot, player.gamemode))) return;
        if (!self.send(self.backend.queue_update_health(slot))) return;
        if (!self.send(self.backend.queue_player_inventory(slot))) return;
        if (!self.send(self.backend.queue_selected_hotbar_slot(slot))) return;
        if (!self.send(self.backend.queue_player_combat_attributes(slot))) return;
        if (!self.send(self.backend.queue_update_view_position(slot, center.x, center.z))) return;
        if (!self.send(self.backend.queue_spawn_position(slot))) return;
        if (!self.send(self.backend.queue_start_waiting_for_chunks(slot))) return;
        if (!self.send(self.backend.queue_player_position(slot))) return;

        self.backend.requestItemSync(slot);
        for (self.backend.living.entities.active_indices[0..self.backend.living.entities.active_count]) |living_index| {
            if (!self.trackable(
                slot,
                self.backend.living.entities.worlds[living_index],
                self.livingPosition(living_index),
                living_tracking_range,
            )) continue;
            if (!self.sendLivingSpawn(slot, living_index)) return;
        }
        for (self.backend.activePlaySlots()) |target_slot| {
            if (target_slot == slot) continue;
            if (self.backend.playerVisible(target_slot, slot)) {
                if (!self.send(self.backend.queue_entity_destroy(target_slot, player.entity_id))) return;
                self.backend.setPlayerVisible(target_slot, slot, false);
            }
            if (!self.trackable(target_slot, player.world, player.position, player_tracking_range)) continue;
            if (!self.sendPlayerSpawn(target_slot, slot)) return;
        }
    }

    pub inline fn pendingPlayJoins(self: *Self) []const u16 {
        return self.backend.pendingPlayJoins();
    }

    pub inline fn preparePlayJoinTerrain(self: *Self, slot: u16) bool {
        return self.backend.preparePlayJoinTerrain(slot);
    }

    pub inline fn resetClientWorldView(self: *Self, slot: u16, position: geometry.Vec3) geometry.ChunkPos {
        return self.backend.resetClientWorldView(slot, position);
    }

    pub inline fn queue_play_login(self: *Self, slot: u16) !void {
        return self.backend.queue_play_login(slot);
    }

    pub inline fn queue_player_abilities(self: *Self, slot: u16, mode: player_store.GameMode) !void {
        return self.backend.queue_player_abilities(slot, mode);
    }

    pub inline fn queue_player_inventory(self: *Self, slot: u16) !void {
        return self.backend.queue_player_inventory(slot);
    }

    pub inline fn queue_selected_hotbar_slot(self: *Self, slot: u16) !void {
        return self.backend.queue_selected_hotbar_slot(slot);
    }

    pub inline fn queue_player_combat_attributes(self: *Self, slot: u16) !void {
        return self.backend.queue_player_combat_attributes(slot);
    }

    pub inline fn queue_update_health(self: *Self, slot: u16) !void {
        return self.backend.queue_update_health(slot);
    }

    pub inline fn queue_update_time(self: *Self, slot: u16) !void {
        return self.backend.queue_update_time(slot);
    }

    pub inline fn chunkViewCenter(self: *Self, slot: u16) geometry.ChunkPos {
        return self.backend.chunkViewCenter(slot);
    }

    pub inline fn queue_update_view_position(self: *Self, slot: u16, x: i32, z: i32) !void {
        return self.backend.queue_update_view_position(slot, x, z);
    }

    pub inline fn queue_spawn_position(self: *Self, slot: u16) !void {
        return self.backend.queue_spawn_position(slot);
    }

    pub inline fn queue_start_waiting_for_chunks(self: *Self, slot: u16) !void {
        return self.backend.queue_start_waiting_for_chunks(slot);
    }

    pub inline fn queue_player_position(self: *Self, slot: u16) !void {
        return self.backend.queue_player_position(slot);
    }

    pub inline fn activePlaySlots(self: *Self) []const u16 {
        return self.backend.activePlaySlots();
    }

    pub inline fn playBootstrapComplete(self: *Self, slot: u16) bool {
        return self.backend.playBootstrapComplete(slot);
    }

    pub inline fn queue_system_chat_format(self: *Self, slot: u16, comptime format: []const u8, args: anytype) !void {
        return self.backend.queue_system_chat_format(slot, format, args);
    }

    pub inline fn queue_player_info_add(self: *Self, target: u16, subject: u16) !void {
        return self.backend.queue_player_info_add(target, subject);
    }

    pub inline fn queue_player_info_add_batch(self: *Self, target: u16, subjects: []const u16) !void {
        return self.backend.queue_player_info_add_batch(target, subjects);
    }

    pub inline fn hasSentChunkAtPosition(self: *Self, slot: u16, world: world_identity.Handle, position: geometry.Vec3) bool {
        return self.backend.hasSentChunkAtPosition(slot, world, position);
    }

    pub inline fn queue_spawn_player_entity(self: *Self, target: u16, subject: u16) !void {
        return self.backend.queue_spawn_player_entity(target, subject);
    }

    pub inline fn setPlayerVisible(self: *Self, target: u16, subject: u16, visible: bool) void {
        self.backend.setPlayerVisible(target, subject, visible);
    }

    pub inline fn queue_player_state_metadata(self: *Self, target: u16, subject: u16) !void {
        return self.backend.queue_player_state_metadata(target, subject);
    }

    pub inline fn queue_entity_equipment(self: *Self, target: u16, subject: u16) !void {
        return self.backend.queue_entity_equipment(target, subject);
    }

    pub inline fn requestItemSync(self: *Self, slot: u16) void {
        self.backend.requestItemSync(slot);
    }

    pub inline fn queue_player_entity_position(self: *Self, target: u16, subject: u16) !void {
        return self.backend.queue_player_entity_position(target, subject);
    }

    pub inline fn queue_spawn_living_entity(self: *Self, target: u16, index: u16) !void {
        return self.backend.queue_spawn_living_entity(target, index);
    }

    pub inline fn setLivingVisible(self: *Self, slot: u16, index: u16, visible: bool) void {
        self.backend.setLivingVisible(slot, index, visible);
    }

    pub inline fn queue_living_entity_metadata(self: *Self, target: u16, index: u16) !void {
        return self.backend.queue_living_entity_metadata(target, index);
    }

    pub inline fn queue_living_equipment(self: *Self, target: u16, index: u16, equipment: u8) !void {
        return self.backend.queue_living_equipment(target, index, equipment);
    }

    pub inline fn markPlayBootstrapComplete(self: *Self, slot: u16) void {
        self.backend.markPlayBootstrapComplete(slot);
    }

    pub inline fn finishPendingPlayJoins(self: *Self) void {
        self.backend.finishPendingPlayJoins();
    }

    pub inline fn pendingPlayDisconnects(self: *Self) @TypeOf(self.backend.pendingPlayDisconnects()) {
        return self.backend.pendingPlayDisconnects();
    }

    pub inline fn canSeeBlock(self: *Self, slot: u16, world: world_identity.Handle, position: geometry.BlockPos) bool {
        return self.backend.canSeeBlock(slot, world, position);
    }

    pub inline fn queue_block_break_animation(self: *Self, slot: u16, entity: i32, position: geometry.BlockPos, stage: i8) !void {
        return self.backend.queue_block_break_animation(slot, entity, position, stage);
    }

    pub inline fn queue_entity_destroy(self: *Self, target: u16, entity: i32) !void {
        return self.backend.queue_entity_destroy(target, entity);
    }

    pub inline fn queue_player_remove(self: *Self, target: u16, uuid: u128) !void {
        return self.backend.queue_player_remove(target, uuid);
    }

    pub inline fn finishPendingPlayDisconnects(self: *Self) void {
        self.backend.finishPendingPlayDisconnects();
    }

    pub inline fn keepAliveDue(self: *Self, slot: u16, tick: u64) bool {
        return self.backend.keepAliveDue(slot, tick);
    }

    pub inline fn bootstrapComplete(self: *Self, slot: u16) bool {
        return self.backend.playBootstrapComplete(slot);
    }

    pub inline fn latencyDirty(self: *Self, slot: u16) bool {
        return self.backend.playerLatencyDirty(slot);
    }

    pub inline fn sendLatency(self: *Self, target: u16, subject: u16) bool {
        return self.send(self.backend.queue_player_info_latency(target, subject));
    }

    pub inline fn finishLatency(self: *Self, slot: u16) void {
        self.backend.finishPlayerLatency(slot);
    }

    pub inline fn sendKeepAlive(self: *Self, slot: u16) void {
        _ = self.send(self.backend.queue_keep_alive(slot));
    }

    pub inline fn chunkStreamingEnabled(self: *Self) bool {
        return self.backend.chunkStreamingEnabled();
    }

    pub inline fn prunePlaySlots(self: *Self) void {
        self.backend.prunePlaySlots();
    }

    pub inline fn playerPosition(self: *Self, slot: u16) geometry.Vec3 {
        return self.backend.players.records[slot].position;
    }

    pub inline fn chunkStreamCursor(self: *Self) usize {
        return self.backend.chunkStreamCursor();
    }

    pub inline fn prefetchChunkData(self: *Self, slot: u16, maximum: usize) usize {
        return self.backend.prefetchChunkData(slot, maximum);
    }

    pub inline fn playerWorld(self: *Self, slot: u16) world_identity.Handle {
        return self.backend.playerWorld(slot);
    }

    pub inline fn recenterChunkView(self: *Self, slot: u16, center: geometry.ChunkPos) void {
        self.backend.recenterChunkView(slot, center);
    }

    pub inline fn chunkOutputBackpressured(self: *Self, slot: u16) bool {
        return self.backend.chunkOutputBackpressured(slot);
    }

    pub inline fn nextMissingChunk(self: *Self, slot: u16, cursor: *usize) ?geometry.ChunkPos {
        return self.backend.nextMissingChunk(slot, cursor);
    }

    pub inline fn beginChunkBatch(self: *Self, slot: u16) u16 {
        return self.backend.beginChunkBatch(slot);
    }

    pub inline fn chunk_batch_received(self: *Self, slot: u16, chunks_per_tick: f32) void {
        self.backend.acknowledgeChunkBatch(slot, chunks_per_tick);
    }

    pub inline fn prepareChunkData(self: *Self, slot: u16, pos: geometry.ChunkPos) @TypeOf(self.backend.prepareChunkData(slot, pos)) {
        return self.backend.prepareChunkData(slot, pos);
    }

    pub inline fn generateChunkData(self: *Self, slot: u16, pos: geometry.ChunkPos) bool {
        return self.backend.generateChunkData(slot, pos);
    }

    pub inline fn queueChunkBatchStart(self: *Self, slot: u16) !void {
        return self.backend.queueChunkBatchStart(slot);
    }

    pub inline fn queueChunkPacket(self: *Self, slot: u16, pos: geometry.ChunkPos, lighting: *const light_projection.Chunk) !void {
        return self.backend.queueChunkPacket(slot, pos, lighting);
    }

    pub inline fn markChunkSent(self: *Self, slot: u16, pos: geometry.ChunkPos) void {
        self.backend.markChunkSent(slot, pos);
    }

    pub inline fn releaseStreamedChunk(self: *Self, slot: u16, pos: geometry.ChunkPos) ?u16 {
        return self.backend.releaseStreamedChunk(slot, pos);
    }

    pub inline fn advanceChunkStreamCursor(self: *Self) void {
        self.backend.advanceChunkStreamCursor();
    }

    pub inline fn queueChunkBatchFinished(self: *Self, slot: u16, count: u16) !void {
        return self.backend.queueChunkBatchFinished(slot, count);
    }

    pub inline fn finishChunkBatch(self: *Self, slot: u16, count: u16) void {
        self.backend.finishChunkBatch(slot, count);
    }

    pub fn reconcile_item_entities(self: *Self) void {
        for (self.backend.activePlaySlots()) |target_slot| {
            if (!self.backend.claimItemSync(target_slot)) continue;

            for (self.backend.activePlaySlots()) |subject_slot| {
                if (subject_slot == target_slot) continue;
                const subject = &self.backend.players.records[subject_slot];
                const should_be_visible = self.backend.playBootstrapComplete(subject_slot) and
                    self.trackable(
                        target_slot,
                        subject.world,
                        subject.position,
                        player_tracking_range,
                    );
                const was_visible = self.backend.playerVisible(target_slot, subject_slot);
                if (should_be_visible == was_visible) continue;
                if (should_be_visible) {
                    if (!self.sendPlayerSpawn(target_slot, subject_slot))
                        self.backend.requestItemSync(target_slot);
                } else if (self.send(self.backend.queue_entity_destroy(target_slot, subject.entity_id))) {
                    self.backend.setPlayerVisible(target_slot, subject_slot, false);
                } else {
                    self.backend.requestItemSync(target_slot);
                }
            }

            for (self.backend.living.entities.active_indices[0..self.backend.living.entities.active_count]) |index| {
                const should_be_visible = self.trackable(
                    target_slot,
                    self.backend.living.entities.worlds[index],
                    self.livingPosition(index),
                    living_tracking_range,
                );
                const was_visible = self.backend.livingVisible(target_slot, index);
                if (should_be_visible == was_visible) continue;
                if (should_be_visible) {
                    if (!self.sendLivingSpawn(target_slot, index))
                        self.backend.requestItemSync(target_slot);
                } else if (self.send(self.backend.queue_entity_destroy(
                    target_slot,
                    self.backend.living.entities.entity_ids[index],
                ))) {
                    self.backend.setLivingVisible(target_slot, index, false);
                } else {
                    self.backend.requestItemSync(target_slot);
                }
            }

            var first: u16 = 0;
            while (self.backend.nextVisibleItem(target_slot, first)) |index| {
                first = index + 1;
                if (self.itemShouldBeVisible(target_slot, index)) {
                    _ = self.sendPendingItemMetadata(target_slot, index);
                    continue;
                }
                if (self.send(self.backend.queue_entity_destroy(target_slot, self.backend.items.entity_ids[index])))
                    self.backend.setItemVisible(target_slot, index, false)
                else
                    self.backend.requestItemSync(target_slot);
            }

            for (self.backend.items.active_indices[0..self.backend.items.active_count]) |index|
                _ = self.ensureItemVisible(target_slot, index);
        }
    }
};

fn offsetBlockPos(pos: geometry.BlockPos, face: i32) geometry.BlockPos {
    var result = pos;
    switch (face) {
        0 => result.y -|= 1,
        1 => result.y +|= 1,
        2 => result.z -= 1,
        3 => result.z += 1,
        4 => result.x -= 1,
        5 => result.x += 1,
        else => {},
    }
    return result;
}

fn lightUpdateVisible(player_world: world_identity.Handle, update_world: world_identity.Handle) bool {
    return player_world.eql(update_world);
}

test "light updates are isolated by world" {
    const hub = world_identity.Handle{ .index = 1, .generation = 1 };
    const island = world_identity.Handle{ .index = 2, .generation = 1 };
    try std.testing.expect(lightUpdateVisible(hub, hub));
    try std.testing.expect(!lightUpdateVisible(hub, island));
}
