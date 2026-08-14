const std = @import("std");
const abi = @import("hot_reload_abi.zig");
const config = @import("config.zig").value;
const block_store = @import("world/blocks.zig");
const entity_store = @import("world/entities.zig");
const game_rules = @import("world/game_rules.zig");
const input_store = @import("world/inputs.zig");
const player_store = @import("world/players.zig");
const world_clock = @import("world/clock.zig");
const world_identity = @import("world/identity.zig");
const world_random = @import("world/random.zig");
const world_store = @import("world/worlds.zig");
const vanilla_time = @import("world/time.zig");
const tick_io = @import("tick_io.zig");

/// Direct fixture access for packet-level harnesses. This type is instantiated
/// by a configured tick runtime, but is not part of the reload C ABI or the
/// production reactor. Tests stage state and packets here, then exercise the
/// same tick entry point as a live server.
pub fn Harness(comptime RuntimeState: type, comptime Profile: type) type {
    return struct {
        pub const Stores = struct {
            worlds: *world_store.Worlds,
            clock: *world_clock.Clock,
            time: *vanilla_time.Time,
            rules: *game_rules.GameRules,
            random: *world_random.Random,
            inputs: *input_store.Inputs,
            containers: *player_store.Containers,
            blocks: *block_store.Blocks,
            living: *entity_store.LivingEntities,
            players: *player_store.Players,
            items: *entity_store.ItemEntities,
        };

        pub fn stores(raw_state: *anyopaque) Stores {
            const state = runtimeState(raw_state);
            const configured = Profile.stores(state.plugins);
            return .{
                .worlds = configured.worlds,
                .clock = configured.clock,
                .time = configured.time,
                .rules = configured.game_rules,
                .random = configured.random,
                .inputs = configured.inputs,
                .containers = configured.containers,
                .blocks = configured.blocks,
                .living = configured.living,
                .players = configured.players,
                .items = configured.items,
            };
        }

        pub fn reset(raw_state: *anyopaque, seed: u64) void {
            const state = runtimeState(raw_state);
            std.debug.assert(state.dynamic_storage.sealed);
            state.dynamic_storage.sealed = false;
            const state_stores = stores(raw_state);
            resetStores(state_stores, seed);
            state.dynamic_storage.seal();
        }

        pub fn connect(
            raw_state: *anyopaque,
            slot: u16,
            name: []const u8,
            protocol_number: i32,
        ) !void {
            const state = runtimeState(raw_state);
            if (slot >= state.connections.len or name.len > config.max_username_bytes)
                return error.InvalidFixtureConnection;
            if (state.connections[slot].active)
                return error.InvalidFixtureConnection;

            const state_stores = stores(raw_state);
            if (state_stores.players.records[slot].state == .free)
                state_stores.players.beginConnection(state_stores.random, slot);
            _ = try state_stores.players.login(state_stores.random, slot, name, @as(u128, slot) + 1);
            try preparePlayer(state_stores, slot);

            const handle = abi.ConnectionHandle{ .index = slot, .generation = 1 };
            state.connections[slot] = .{
                .handle = handle,
                .active = true,
                .protocol_number = protocol_number,
                .phase = .play,
                .player_reserved = true,
            };
            state.connection_handles[slot] = handle;
            try append(&state.active_play_slots, slot);
            state.replication.reset(slot);
            state.active_connection_count += 1;
        }

        pub fn stageJoin(raw_state: *anyopaque, slot: u16) !void {
            const state = runtimeState(raw_state);
            if (slot >= state.connections.len or !state.connections[slot].active)
                return error.InvalidFixtureConnection;
            const player = &stores(raw_state).players.records[slot];
            player.play_bootstrap_complete = false;
            player.play_join_terrain_ready = false;
            player.play_join_stage = 0;
            try append(&state.pending_play_joins, slot);
        }

        pub fn setProtocol(raw_state: *anyopaque, slot: u16, protocol_number: i32) !void {
            const state = runtimeState(raw_state);
            if (slot >= state.connections.len or !state.connections[slot].active)
                return error.InvalidFixtureConnection;
            state.connections[slot].protocol_number = protocol_number;
        }

        pub fn replication(raw_state: *anyopaque) *@import("replication.zig").State {
            return &runtimeState(raw_state).replication;
        }

        pub fn playSlots(raw_state: *anyopaque) []const u16 {
            const slots = &runtimeState(raw_state).active_play_slots;
            return slots.values[0..slots.len];
        }

        pub fn requestItemSync(raw_state: *anyopaque, slot: u16) void {
            runtimeState(raw_state).replication.clients[slot].item_sync_pending = true;
        }

        pub fn setChunkStreaming(raw_state: *anyopaque, enabled: bool) void {
            runtimeState(raw_state).chunk_streaming_enabled = enabled;
        }

        pub fn io(raw_state: *anyopaque) *tick_io.TickIo {
            return runtimeState(raw_state).services.io;
        }

        fn runtimeState(raw_state: *anyopaque) *RuntimeState {
            return @ptrCast(@alignCast(raw_state));
        }

        fn resetStores(state: Stores, seed: u64) void {
            state.clock.* = .{};
            state.time.* = .{};
            state.rules.* = .{};
            state.random.* = .{ .random = world_random.DeterministicRng.init(seed) };
            state.inputs.reset();
            state.containers.reset();
            state.players.reset();
            state.blocks.resetInPlace();
            for (state.living.entities.active_indices[0..state.living.entities.active_count]) |index|
                state.living.paths.clear(index);
            state.living.entities.resetInPlace();
            state.items.resetInPlace();
        }

        fn preparePlayer(state: Stores, slot: u16) !void {
            const player = &state.players.records[slot];
            if (!world_identity.valid(player.world) or state.worlds.getConst(player.world) == null) {
                player.world = state.worlds.find(Profile.configuration.server.spawn_world) orelse
                    return error.MissingFixtureWorld;
                const spawn = state.worlds.getConst(player.world) orelse
                    return error.MissingFixtureWorld;
                player.position = .{
                    .x = @floatFromInt(spawn.spawn_x),
                    .y = @floatFromInt(spawn.spawn_y),
                    .z = @floatFromInt(spawn.spawn_z),
                };
                player.needs_spawn_position = false;
            }
            state.players.transition(slot, .configuration);
            state.players.transition(slot, .play);
        }

        fn append(list: anytype, value: anytype) !void {
            if (list.len == list.values.len) return error.CapacityExceeded;
            list.values[list.len] = value;
            list.len += 1;
        }
    };
}
