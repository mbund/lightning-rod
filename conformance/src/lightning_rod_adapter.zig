const std = @import("std");
const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const registry = lightning_rod.registry_data;
const BlackBox = @import("black_box").BlackBox;
const mcc = @import("minecraft_conformance");

/// Lightning Rod's conformance boundary is deliberately opaque: stage raw
/// serverbound packet bodies by connection, advance the production server one
/// tick, and return the raw clientbound bodies actually queued by production.
/// No gameplay-emitter method or canonical packet is visible through this adapter.
pub const LightningRodAdapter = struct {
    allocator: std.mem.Allocator,
    server: ?BlackBox = null,
    outputs: [1152]mcc.Adapter.Output = undefined,
    identities: [64]mcc.Identity = undefined,
    identity_count: usize = 0,
    clients: []const mcc.Client = &.{},
    step_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) LightningRodAdapter {
        return .{ .allocator = allocator };
    }

    pub fn targetInfo() mcc.TargetInfo {
        return .{
            .name = "lightning-rod-in-process",
            .kind = .lightning_rod,
            .minecraft = mcc.minecraft_version,
            .capabilities = .{
                .fixture_restore = true,
                .stage_serverbound_packets = true,
                .controlled_tick = true,
                .capture_clientbound_packets = true,
                .stable_connection_identities = true,
                .persistent_restart = true,
            },
        };
    }

    pub fn deinit(self: *LightningRodAdapter) void {
        if (self.server) |*server| server.deinit();
        self.* = undefined;
    }

    pub fn adapter(self: *LightningRodAdapter) mcc.Adapter {
        return .{ .context = self, .vtable = &.{ .restore = restore, .restart = restart, .stage = stage, .control = control, .step = step } };
    }

    fn from(context: *anyopaque) *LightningRodAdapter {
        return @ptrCast(@alignCast(context));
    }

    fn restore(context: *anyopaque, definition: mcc.fixture.Definition, clients: []const mcc.Client) ![]const mcc.Identity {
        const self = from(context);
        if (self.server) |*server| {
            server.reset(definition.seed);
        } else {
            self.server = try BlackBox.init(self.allocator, definition.seed);
        }
        if (clients.len > self.identities.len) return error.TooManyClients;
        if (definition.frozen_time < 0) return error.InvalidFixtureTime;
        self.step_count = 0;
        self.server.?.setDayTime(@intCast(definition.frozen_time));
        self.clients = clients;
        for (clients, 0..) |client, slot| {
            if (slot > std.math.maxInt(u16)) return error.TooManyClients;
            try self.server.?.connectPlayer(@intCast(slot), client.name);
        }
        self.identity_count = clients.len;
        for (definition.setup) |setup| try self.applySetup(setup);
        for (clients, 0..) |client, slot| {
            self.server.?.requestItemSync(@intCast(slot));
            const player = self.server.?.player(@intCast(slot));
            self.identities[slot] = .{
                .alias = client.name,
                .entity_id = player.entity_id,
                .uuid = player.uuid,
                .position = .{ player.position.x, player.position.y, player.position.z },
                .position_known = true,
            };
        }
        return self.identities[0..self.identity_count];
    }

    fn applySetup(self: *LightningRodAdapter, setup: mcc.fixture.Setup) !void {
        const server = &self.server.?;
        switch (setup) {
            .set_block => |block| {
                const state = fixtureBlockState(block.state) orelse return error.UnknownFixtureBlockState;
                try server.setBlock(.{ .x = block.x, .y = block.y, .z = block.z }, state);
            },
            .fill_box => |box| {
                const state = fixtureBlockState(box.state) orelse return error.UnknownFixtureBlockState;
                try server.fillBox(
                    .{ .x = box.min_x, .y = box.min_y, .z = box.min_z },
                    .{ .x = box.max_x, .y = box.max_y, .z = box.max_z },
                    state,
                );
            },
            .spawn_player => |player| {
                const slot = self.findSlot(player.id) orelse return error.UnknownFixturePlayer;
                server.setPlayerPosition(slot, .{ .x = player.x, .y = player.y, .z = player.z });
            },
            .spawn_entity => |entity| {
                const entity_type: living_entities.EntityType = if (std.mem.eql(u8, entity.kind, "minecraft:zombie"))
                    .zombie
                else if (std.mem.eql(u8, entity.kind, "minecraft:cow"))
                    .cow
                else if (std.mem.eql(u8, entity.kind, "minecraft:pig"))
                    .pig
                else
                    return error.UnknownFixtureEntity;
                if (self.identity_count == self.identities.len) return error.TooManyFixtureEntities;
                const handle = try server.spawnLiving(entity_type, .{ .x = entity.x, .y = entity.y, .z = entity.z }, entity.baby, true);
                const living = &server.gameplayStores().living.entities;
                living.on_ground[handle.index] = entity.on_ground;
                self.identities[self.identity_count] = .{
                    .alias = entity.id,
                    .entity_id = living.entity_ids[handle.index],
                    .uuid = living.uuids[handle.index],
                    .position = .{ entity.x, entity.y, entity.z },
                    .position_known = true,
                };
                self.identity_count += 1;
            },
            .spawn_item => |item| {
                if (self.identity_count == self.identities.len) return error.TooManyFixtureEntities;
                const stack = player_store.stackForItem(fixtureItemId(item.item) orelse return error.UnknownFixtureItem, item.count);
                const index = try server.spawnItem(
                    .{ .x = item.x, .y = item.y, .z = item.z },
                    .{ .x = item.velocity_x, .y = item.velocity_y, .z = item.velocity_z },
                    stack,
                    item.pickup_delay,
                    item.age,
                );
                const items = server.gameplayStores().items;
                self.identities[self.identity_count] = .{
                    .alias = item.id,
                    .entity_id = items.entity_ids[index],
                    .uuid = items.uuids[index],
                    .position = .{ item.x, item.y, item.z },
                    .position_known = true,
                };
                self.identity_count += 1;
            },
            .set_player_health => |entry| {
                const slot = self.findSlot(entry.id) orelse return error.UnknownFixturePlayer;
                server.setPlayerHealth(slot, entry.health);
            },
            .set_entity_health => |entry| {
                const identity = self.findIdentity(entry.id) orelse return error.UnknownFixtureEntity;
                try server.setLivingHealth(identity.entity_id, entry.health);
            },
            .set_player_gamemode => |entry| {
                const slot = self.findSlot(entry.id) orelse return error.UnknownFixturePlayer;
                const gamemode: player_store.GameMode = if (std.mem.eql(u8, entry.gamemode, "survival"))
                    .survival
                else if (std.mem.eql(u8, entry.gamemode, "creative"))
                    .creative
                else if (std.mem.eql(u8, entry.gamemode, "adventure"))
                    .adventure
                else if (std.mem.eql(u8, entry.gamemode, "spectator"))
                    .spectator
                else
                    return error.UnknownFixtureGamemode;
                server.setPlayerGamemode(slot, gamemode);
            },
            .set_held_stack => |held| {
                const slot = self.findSlot(held.id) orelse return error.UnknownFixturePlayer;
                const item_id = fixtureItemId(held.item) orelse return error.UnknownFixtureItem;
                const stack = player_store.stackForItem(item_id, held.count);
                server.setPlayerHeldStack(slot, 3, stack);
            },
            .set_inventory_stack => |entry| {
                const slot = self.findSlot(entry.id) orelse return error.UnknownFixturePlayer;
                const protocol_slot = try canonicalInventorySlot(entry.slot);
                const stack: player_store.HotbarStack = if (entry.count == 0) .{} else player_store.stackForItem(fixtureItemId(entry.item) orelse return error.UnknownFixtureItem, entry.count);
                try server.setPlayerInventoryStack(slot, protocol_slot, stack);
            },
            .set_selected_hotbar_slot => |entry| {
                const slot = self.findSlot(entry.id) orelse return error.UnknownFixturePlayer;
                server.setPlayerSelectedHotbarSlot(slot, entry.slot);
            },
            .set_gamerule => |rule| {
                if (std.mem.eql(u8, rule.name, "randomTickSpeed")) {
                    server.setRandomTickSpeed(try std.fmt.parseInt(u16, rule.value, 10));
                    return;
                }
                const enabled = if (std.mem.eql(u8, rule.value, "true")) true else if (std.mem.eql(u8, rule.value, "false")) false else return error.InvalidFixtureGamerule;
                if (std.mem.eql(u8, rule.name, "doRandomTicks"))
                    server.setRandomTicks(enabled)
                else if (std.mem.eql(u8, rule.name, "doMobSpawning"))
                    server.setMobSpawning(enabled)
                else if (std.mem.eql(u8, rule.name, "naturalRegeneration"))
                    server.setNaturalRegeneration(enabled)
                else if (std.mem.eql(u8, rule.name, "doDaylightCycle"))
                    server.setDaylightCycle(enabled)
                else
                    return error.UnknownFixtureGamerule;
            },
            .set_time => |value| {
                if (value < 0) return error.InvalidFixtureTime;
                server.setDayTime(@intCast(value));
            },
            .enable_chunk_streaming => server.enableChunkStreaming(),
        }
    }

    fn stage(context: *anyopaque, client: []const u8, packet_body: []const u8) !void {
        const self = from(context);
        try self.server.?.stage(self.findSlot(client) orelse return error.UnknownClient, packet_body);
    }

    fn restart(context: *anyopaque) ![]const mcc.Identity {
        const self = from(context);
        try self.server.?.persistentRestart();
        for (self.clients, 0..) |client, slot| {
            try self.server.?.connectPlayer(@intCast(slot), client.name);
            try self.server.?.reconnectPlayerBootstrap(@intCast(slot));
            const player = self.server.?.player(@intCast(slot));
            self.identities[slot] = .{
                .alias = client.name,
                .entity_id = player.entity_id,
                .uuid = player.uuid,
                .position = .{ player.position.x, player.position.y, player.position.z },
                .position_known = true,
            };
        }
        const living = &self.server.?.gameplayStores().living.entities;
        for (self.identities[self.clients.len..self.identity_count]) |*identity| {
            const index = for (living.active_indices[0..living.active_count]) |index| {
                if (living.uuids[index] == identity.uuid) break index;
            } else return error.PersistedFixtureEntityMissing;
            identity.entity_id = living.entity_ids[index];
            identity.position = .{ living.position_x[index], living.position_y[index], living.position_z[index] };
            identity.position_known = true;
        }
        return self.identities[0..self.identity_count];
    }

    fn control(context: *anyopaque, client: []const u8, kind: mcc.Control) !void {
        const self = from(context);
        const slot = self.findSlot(client) orelse return error.UnknownClient;
        switch (kind) {
            .disconnect => try self.server.?.disconnectPlayer(slot),
            .reconnect => try self.server.?.reconnectPlayer(slot, client),
        }
    }

    fn step(context: *anyopaque) ![]const mcc.Adapter.Output {
        const self = from(context);
        const captured = try self.server.?.tick();
        self.step_count += 1;
        if (captured.len > self.outputs.len) return error.OutputCapacity;
        for (captured, 0..) |packet, index| {
            self.outputs[index] = .{
                .recipient = self.clients[packet.recipient_slot].name,
                .payload = packet.payload,
            };
        }
        return self.outputs[0..captured.len];
    }

    fn findSlot(self: *const LightningRodAdapter, name: []const u8) ?u16 {
        const server = &self.server.?;
        for (self.clients, 0..) |client, slot| if (std.mem.eql(u8, client.name, name)) return @intCast(slot);
        // During fixture application identities have not been materialized yet.
        for (0..self.identities.len) |slot| {
            const player = server.player(@intCast(slot));
            if (player.state == .play and std.mem.eql(u8, player.name_slice(), name)) return @intCast(slot);
        }
        return null;
    }

    fn findIdentity(self: *const LightningRodAdapter, name: []const u8) ?mcc.Identity {
        for (self.identities[0..self.identity_count]) |identity|
            if (std.mem.eql(u8, identity.alias, name)) return identity;
        return null;
    }
};

fn fixtureItemId(name: []const u8) ?i32 {
    return registry.itemId(name);
}

fn fixtureBlockState(name: []const u8) ?i32 {
    if (registry.blockStateId(name)) |state| return state;
    if (std.mem.indexOfScalar(u8, name, '[') != null) return null;
    for (registry.blocks) |block| {
        const state_name = registry.blockStateName(block.default_state) orelse continue;
        const properties = std.mem.indexOfScalar(u8, state_name, '[') orelse state_name.len;
        if (std.mem.eql(u8, name, state_name[0..properties])) return block.default_state;
    }
    return null;
}

fn canonicalInventorySlot(value: []const u8) !i16 {
    if (value.len < 2) return error.InvalidFixtureInventorySlot;
    const index = std.fmt.parseInt(i16, value[1..], 10) catch return error.InvalidFixtureInventorySlot;
    return switch (value[0]) {
        'h' => if (index >= 0 and index < 9) 36 + index else error.InvalidFixtureInventorySlot,
        'm' => if (index >= 0 and index < 27) 9 + index else error.InvalidFixtureInventorySlot,
        'g' => if (index >= 0 and index < 4) 1 + index else error.InvalidFixtureInventorySlot,
        else => error.InvalidFixtureInventorySlot,
    };
}
