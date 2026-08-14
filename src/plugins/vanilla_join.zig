const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const player_store = lightning_rod.players;
const geometry = lightning_rod.geometry;
const Packets = lightning_rod.Packets;
const tick_host = lightning_rod.tick_host;
const config = lightning_rod.config.value;
const std = @import("std");

pub const PlayJoin = struct {
    pub const id = "minecraft:play_join";

    players: *player_store.Players,
    output: *Packets,

    pub fn create(allocator: std.mem.Allocator, players: *player_store.Players, output: *Packets) !*PlayJoin {
        const self = try allocator.create(PlayJoin);
        self.* = .{ .players = players, .output = output };
        return self;
    }

    pub fn tick(self: *PlayJoin, _: std.mem.Allocator) void {
        const players = self.players;
        const output = self.output;
        start(players, output);
        commands(players, output);
        state(players, output);
    }

    fn start(players: *player_store.Players, output: *Packets) void {
        const pending = output.pendingPlayJoins();
        if (pending.len == 0) return;
        for (pending) |slot| {
            const player = &players.records[slot];
            if (player.state != .play or player.play_join_stage != 0) continue;
            if (!output.preparePlayJoinTerrain(slot)) continue;
            _ = output.resetClientWorldView(slot, player.position);
            if (output.send(output.queue_play_login(slot))) player.play_join_stage = 1;
        }
    }

    fn commands(players: *player_store.Players, output: *Packets) void {
        const pending = output.pendingPlayJoins();
        if (pending.len == 0) return;
        for (pending) |slot| {
            const player = &players.records[slot];
            if (player.state != .play or player.play_join_stage != 1) continue;
            if (output.sendJoinCommands(slot)) player.play_join_stage = 2;
        }
    }

    fn state(players: *player_store.Players, output: *Packets) void {
        const pending = output.pendingPlayJoins();
        if (pending.len == 0) return;
        for (pending) |slot| advanceState(players, output, slot);
    }
};

fn advanceState(players: *player_store.Players, output: *Packets, slot: u16) void {
    const player = &players.records[slot];
    if (player.state != .play or player.play_join_stage < 2 or
        player.play_join_stage >= 13) return;
    for (0..11) |_| {
        if (player.play_join_stage >= 13) return;
        if (!sendStatePacket(output, player, slot)) return;
        player.play_join_stage += 1;
    }
    if (player.play_join_stage != 13) @panic("play join state exceeded its stage bound");
}

fn sendStatePacket(output: *Packets, player: *player_store.CorePlayer, slot: u16) bool {
    return switch (player.play_join_stage) {
        2 => output.send(output.queue_player_abilities(slot, player.gamemode)),
        3 => output.send(output.queue_player_inventory(slot)),
        4 => output.send(output.queue_selected_hotbar_slot(slot)),
        5 => output.send(output.queue_player_combat_attributes(slot)),
        6 => output.send(output.queue_update_health(slot)),
        7 => output.send(output.queue_update_time(slot)),
        8 => sendViewCenter(output, slot),
        9 => output.send(output.queue_spawn_position(slot)),
        10 => output.send(output.queue_start_waiting_for_chunks(slot)),
        11 => output.send(output.queue_player_position(slot)),
        12 => true,
        else => unreachable,
    };
}

fn sendViewCenter(output: *Packets, slot: u16) bool {
    const center = output.chunkViewCenter(slot);
    return output.send(output.queue_update_view_position(slot, center.x, center.z));
}

pub const PlayJoinMessage = struct {
    pub const id = "minecraft:play_join_message";

    players: *player_store.Players,
    output: *Packets,

    pub fn create(allocator: std.mem.Allocator, players: *player_store.Players, output: *Packets) !*PlayJoinMessage {
        const self = try allocator.create(PlayJoinMessage);
        self.* = .{ .players = players, .output = output };
        return self;
    }

    pub fn tick(self: *PlayJoinMessage, _: std.mem.Allocator) void {
        const players = self.players;
        const output = self.output;
        for (output.pendingPlayJoins()) |slot| {
            const player = &players.records[slot];
            if (player.state != .play or player.play_join_stage != 13) continue;
            if (player.announce_join) {
                for (output.activePlaySlots()) |target| {
                    if (target == slot or !output.playBootstrapComplete(target)) continue;
                    _ = output.send(output.queue_system_chat_format(
                        target,
                        "{s} joined the game",
                        .{player.name_slice()},
                    ));
                }
            }
            player.announce_join = false;
            player.play_join_stage = 14;
        }
    }
};

pub const PlayJoinProjection = struct {
    pub const id = "minecraft:play_join_projection";

    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    output: *Packets,

    pub fn create(allocator: std.mem.Allocator, players: *player_store.Players, living: *entity_store.LivingEntities, output: *Packets) !*PlayJoinProjection {
        const self = try allocator.create(PlayJoinProjection);
        self.* = .{ .players = players, .living = living, .output = output };
        return self;
    }

    pub fn tick(self: *PlayJoinProjection, _: std.mem.Allocator) void {
        const players = self.players;
        const living = self.living;
        const output = self.output;
        for (output.pendingPlayJoins()) |slot| {
            const joining = &players.records[slot];
            if (joining.state != .play or joining.play_join_stage < 14) continue;
            if (joining.play_join_stage == 14) {
                var subjects: [config.max_players]u16 = undefined;
                const subject_count = collectTabListSubjects(output, &subjects);
                if (!output.send(output.queue_player_info_add_batch(
                    slot,
                    subjects[0..subject_count],
                ))) continue;
                joining.play_join_stage = 15;
            }
            projectPlayers(players, output, slot);
            output.requestItemSync(slot);
            projectLiving(living, output, slot);
            output.markPlayBootstrapComplete(slot);
        }
        if (output.pendingPlayJoins().len != 0) output.finishPendingPlayJoins();
    }
};

fn collectTabListSubjects(output: *Packets, subjects: *[config.max_players]u16) usize {
    return mergeTabListSubjects(
        output.activePlaySlots(),
        output.pendingPlayJoins(),
        subjects,
    );
}

fn mergeTabListSubjects(active: []const u16, pending: []const u16, subjects: []u16) usize {
    var count: usize = 0;
    for (active) |slot| {
        if (count == subjects.len) @panic("player tab-list capacity exhausted");
        subjects[count] = slot;
        count += 1;
    }
    for (pending) |slot| {
        var duplicate = false;
        for (subjects[0..count]) |existing| duplicate = duplicate or existing == slot;
        if (duplicate) continue;
        if (count == subjects.len) @panic("player tab-list capacity exhausted");
        subjects[count] = slot;
        count += 1;
    }
    return count;
}

test "simultaneous play starts share one complete tab-list snapshot" {
    var subjects: [4]u16 = undefined;
    const count = mergeTabListSubjects(&.{}, &.{ 2, 5, 7 }, &subjects);
    try std.testing.expectEqualSlices(u16, &.{ 2, 5, 7 }, subjects[0..count]);
}

fn projectPlayers(players: *player_store.Players, output: *Packets, joining: u16) void {
    for (output.activePlaySlots()) |existing| {
        if (existing == joining) continue;
        if (!output.playBootstrapComplete(existing)) continue;
        projectPlayer(players, output, joining, existing);
        if (!output.send(output.queue_player_info_add(existing, joining))) return;
        projectPlayer(players, output, existing, joining);
        output.requestItemSync(existing);
    }
}

fn projectPlayer(players: *player_store.Players, output: *Packets, target: u16, subject: u16) void {
    const player = &players.records[subject];
    if (!output.hasSentChunkAtPosition(target, player.world, player.position)) return;
    if (!output.send(output.queue_spawn_player_entity(target, subject))) return;
    output.setPlayerVisible(target, subject, true);
    if (!output.send(output.queue_player_state_metadata(target, subject))) return;
    if (player.hotbar[player.selected_hotbar_slot].count != 0 and
        !output.send(output.queue_entity_equipment(target, subject)))
        output.requestItemSync(target);
    _ = output.send(output.queue_player_entity_position(target, subject));
}

fn projectLiving(living: *entity_store.LivingEntities, output: *Packets, slot: u16) void {
    const entities = &living.entities;
    for (entities.active_indices[0..entities.active_count]) |index| {
        const position = geometry.Vec3{
            .x = entities.position_x[index],
            .y = entities.position_y[index],
            .z = entities.position_z[index],
        };
        if (!output.hasSentChunkAtPosition(slot, entities.worlds[index], position) or
            !output.send(output.queue_spawn_living_entity(slot, index))) continue;
        output.setLivingVisible(slot, index, true);
        _ = output.send(output.queue_living_entity_metadata(slot, index));
        for (0..6) |equipment_slot| {
            if (entities.equipment[index][equipment_slot].count == 0) continue;
            _ = output.send(output.queue_living_equipment(slot, index, @intCast(equipment_slot)));
        }
    }
}

pub const PlayDisconnectMessage = struct {
    pub const id = "minecraft:play_disconnect_message";

    output: *Packets,

    pub fn create(allocator: std.mem.Allocator, output: *Packets) !*PlayDisconnectMessage {
        const self = try allocator.create(PlayDisconnectMessage);
        self.* = .{ .output = output };
        return self;
    }

    pub fn tick(self: *PlayDisconnectMessage, _: std.mem.Allocator) void {
        const output = self.output;
        for (output.pendingPlayDisconnects()) |disconnect| {
            for (output.activePlaySlots()) |target| {
                _ = output.send(output.queue_system_chat_format(
                    target,
                    "{s} left the game",
                    .{disconnect.nameSlice()},
                ));
            }
        }
    }
};

pub const PlayDisconnectProjection = struct {
    pub const id = "minecraft:play_disconnect_projection";

    output: *Packets,

    pub fn create(allocator: std.mem.Allocator, output: *Packets) !*PlayDisconnectProjection {
        const self = try allocator.create(PlayDisconnectProjection);
        self.* = .{ .output = output };
        return self;
    }

    pub fn tick(self: *PlayDisconnectProjection, _: std.mem.Allocator) void {
        const output = self.output;
        const pending = output.pendingPlayDisconnects();
        if (pending.len == 0) return;
        for (pending) |disconnect| projectDisconnect(output, disconnect);
        output.finishPendingPlayDisconnects();
    }
};

fn projectDisconnect(output: *Packets, disconnect: tick_host.PendingPlayDisconnect) void {
    for (output.activePlaySlots()) |target| {
        if (disconnect.dig_position) |position| {
            if (output.canSeeBlock(target, disconnect.world, position))
                _ = output.send(output.queue_block_break_animation(
                    target,
                    disconnect.entity_id,
                    position,
                    -1,
                ));
        }
        if (!output.send(output.queue_entity_destroy(target, disconnect.entity_id))) continue;
        _ = output.send(output.queue_player_remove(target, disconnect.uuid));
    }
}
