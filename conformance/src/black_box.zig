const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const config = lightning_rod.config.value;
const tick_host = lightning_rod.tick_host;
const world_generation = lightning_rod.world_generation;
const abi = lightning_rod.hot_reload_abi;
const protocol_versions = lightning_rod.protocol_versions;
const replication_store = lightning_rod.replication;
const world_state = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const players = lightning_rod.players;
const entities = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const wire = lightning_rod.wire;
const protocol_support = lightning_rod.protocol_support;

const TickRuntime = lightning_rod.tick_module_runtime.Runtime(vanilla);
const RuntimeHarness = TickRuntime.Harness;
const Stores = RuntimeHarness.Stores;
const CorePlayer = players.CorePlayer;
const Vec3 = geometry.Vec3;
const BlockPos = geometry.BlockPos;
const ChunkPos = geometry.ChunkPos;
const GameMode = players.GameMode;
const HotbarStack = players.HotbarStack;

fn chunkPosForPosition(position: Vec3) ChunkPos {
    return .{
        .x = @intFromFloat(@floor(position.x / 16.0)),
        .z = @intFromFloat(@floor(position.z / 16.0)),
    };
}

pub const BlackBox = struct {
    const max_staged_packets = 128;
    // Dense conformance fixtures can legitimately emit a block update plus
    // several item-entity packets for hundreds of changes in one tick. This
    // is a harness capture bound, not a production gameplay limit.
    const max_captured_packets = 8192;
    const max_packet_body = 4096;
    const captured_storage_capacity = 256 * 1024 * 1024;
    const frame_storage_capacity = config.player_write_buffer_size + 6;

    pub const CapturedPacket = struct {
        recipient_slot: u16,
        payload: []const u8,
    };

    allocator: std.mem.Allocator,
    storage_allocator: std.mem.Allocator,
    state_bytes: []align(64) u8,
    stores: Stores,
    kernel_api: abi.KernelApi,
    event_storage: []align(8) u8,
    event_bytes_written: usize = 0,
    command_storage: []align(8) u8,
    protocol_numbers: []i32,
    connected: []bool,
    staged_slots: []u16,
    staged_lengths: []u16,
    staged_bodies: []align(64) [max_packet_body]u8,
    staged_count: usize = 0,
    captured: []CapturedPacket,
    frame_storage: []u8,
    captured_storage: []u8,
    captured_storage_len: usize = 0,
    captured_wire_bytes: usize = 0,
    captured_count: usize = 0,
    chunk_streaming_radius: ?i32 = null,
    lease_slot: u16 = 0,
    lease_active: bool = false,
    input_connection: ?abi.ConnectionHandle = null,
    input_bytes: []const u8 = &.{},
    capture_failed: bool = false,
    runtime_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, seed: u64) !BlackBox {
        const storage_allocator = std.heap.page_allocator;
        const state_bytes = try storage_allocator.alignedAlloc(u8, .@"64", config.tick_state_bytes);
        errdefer storage_allocator.free(state_bytes);
        const captured_storage = try storage_allocator.alloc(u8, captured_storage_capacity);
        errdefer storage_allocator.free(captured_storage);
        const frame_storage = try storage_allocator.alloc(u8, frame_storage_capacity);
        errdefer storage_allocator.free(frame_storage);
        const staged_slots = try storage_allocator.alloc(u16, max_staged_packets);
        errdefer storage_allocator.free(staged_slots);
        const staged_lengths = try storage_allocator.alloc(u16, max_staged_packets);
        errdefer storage_allocator.free(staged_lengths);
        const staged_bodies = try storage_allocator.alignedAlloc([max_packet_body]u8, .@"64", max_staged_packets);
        errdefer storage_allocator.free(staged_bodies);
        const captured = try storage_allocator.alloc(CapturedPacket, max_captured_packets);
        errdefer storage_allocator.free(captured);
        const event_storage = try storage_allocator.alignedAlloc(u8, .@"8", config.tick_event_buffer_bytes);
        errdefer storage_allocator.free(event_storage);
        const command_storage = try storage_allocator.alignedAlloc(u8, .@"8", config.tick_command_buffer_bytes);
        errdefer storage_allocator.free(command_storage);
        const protocol_numbers = try storage_allocator.alloc(i32, config.connectionCapacity());
        errdefer storage_allocator.free(protocol_numbers);
        const connected = try storage_allocator.alloc(bool, config.connectionCapacity());
        errdefer storage_allocator.free(connected);
        var self = BlackBox{
            .allocator = allocator,
            .storage_allocator = storage_allocator,
            .state_bytes = state_bytes,
            .stores = undefined,
            .kernel_api = undefined,
            .event_storage = event_storage,
            .command_storage = command_storage,
            .protocol_numbers = protocol_numbers,
            .connected = connected,
            .staged_slots = staged_slots,
            .staged_lengths = staged_lengths,
            .staged_bodies = staged_bodies,
            .captured = captured,
            .frame_storage = frame_storage,
            .captured_storage = captured_storage,
        };
        self.initializeApis();
        self.initialize(seed);
        return self;
    }

    pub fn reset(self: *BlackBox, seed: u64) void {
        self.initialize(seed);
    }

    pub fn gameplayStores(self: *BlackBox) *Stores {
        return &self.stores;
    }

    fn replication(self: *BlackBox) *replication_store.State {
        return RuntimeHarness.replication(self.state_bytes.ptr);
    }

    fn initializeApis(self: *BlackBox) void {
        self.kernel_api = .{
            .capabilities = abi.KernelCapability.output_leases |
                abi.KernelCapability.wire_transport,
            .context = self,
            .reserve_output = reserveOutput,
            .commit_output = commitOutput,
            .cancel_output = cancelOutput,
            .fill_random = fillRandom,
            .output_backpressured = outputBackpressured,
            .append_input = appendInput,
            .next_packet = nextPacket,
            .set_compression = setCompression,
            .set_encryption = setEncryption,
        };
    }

    fn initialize(self: *BlackBox, seed: u64) void {
        if (self.runtime_initialized)
            TickRuntime.moduleDeinitialize(self.state_bytes.ptr);
        var state_used_bytes = self.state_bytes.len;
        const status = TickRuntime.moduleInitialize(self.state_bytes.ptr, &.{
            .panic_fn = fixturePanic,
            .state_bytes = self.state_bytes.len,
            .state_used_bytes = &state_used_bytes,
            .storage_mode = .memory,
        });
        if (status != .ok) @panic("failed to initialize black-box tick runtime");
        self.runtime_initialized = true;
        if (TickRuntime.moduleLoad(self.state_bytes.ptr) != .ok)
            @panic("failed to load black-box tick runtime");
        RuntimeHarness.reset(self.state_bytes.ptr, seed);
        self.stores = RuntimeHarness.stores(self.state_bytes.ptr);
        self.stores.rules.do_random_ticks = false;
        self.stores.rules.do_mob_spawning = false;
        for (self.stores.worlds.active()) |world|
            self.stores.worlds.get(world).?.generator =
                world_generation.Default.generatorId(world_generation.Flat);
        RuntimeHarness.setChunkStreaming(self.state_bytes.ptr, false);
        @memset(self.connected, false);
        @memset(self.protocol_numbers, protocol_versions.default.protocolNumber());
        self.event_bytes_written = 0;
        self.staged_count = 0;
        self.captured_count = 0;
        self.captured_storage_len = 0;
        self.chunk_streaming_radius = null;
    }

    pub fn deinit(self: *BlackBox) void {
        if (self.runtime_initialized)
            TickRuntime.moduleDeinitialize(self.state_bytes.ptr);
        self.storage_allocator.free(self.connected);
        self.storage_allocator.free(self.protocol_numbers);
        self.storage_allocator.free(self.command_storage);
        self.storage_allocator.free(self.event_storage);
        self.storage_allocator.free(self.frame_storage);
        self.storage_allocator.free(self.captured_storage);
        self.storage_allocator.free(self.captured);
        self.storage_allocator.free(self.staged_bodies);
        self.storage_allocator.free(self.staged_lengths);
        self.storage_allocator.free(self.staged_slots);
        self.storage_allocator.free(self.state_bytes);
        self.* = undefined;
    }

    pub fn connectPlayer(self: *BlackBox, slot: u16, name: []const u8) !void {
        if (slot >= config.max_players or self.connected[slot]) return error.TooManyPlayers;
        try RuntimeHarness.connect(
            self.state_bytes.ptr,
            slot,
            name,
            protocol_versions.default.protocolNumber(),
        );
        self.connected[slot] = true;
        self.protocol_numbers[slot] = protocol_versions.default.protocolNumber();
        self.stores.players.records[slot].play_bootstrap_complete = true;
        const projections = RuntimeHarness.replication(self.state_bytes.ptr);
        const center = chunkPosForPosition(self.stores.players.records[slot].position);
        projections.clients[slot].chunks.reset(center);
        if (self.chunk_streaming_radius) |radius|
            projections.clients[slot].chunks
                .setRadius(center, radius);
        for (RuntimeHarness.playSlots(self.state_bytes.ptr)) |other_slot| {
            projections.clients[slot].setPlayerVisible(other_slot, true);
            projections.clients[other_slot].setPlayerVisible(slot, true);
        }
    }

    pub fn reconnectPlayer(self: *BlackBox, slot: u16, name: []const u8) !void {
        try self.connectPlayer(slot, name);
        try RuntimeHarness.stageJoin(self.state_bytes.ptr, slot);
    }

    pub fn reconnectPlayerBootstrap(self: *BlackBox, slot: u16) !void {
        try RuntimeHarness.stageJoin(self.state_bytes.ptr, slot);
    }

    pub fn persistentRestart(self: *BlackBox) !void {
        if (TickRuntime.moduleSave(self.state_bytes.ptr) != .ok)
            return error.PersistentSaveFailed;
        var paths: [config.max_file_resources][]const u8 = undefined;
        var values: [config.max_file_resources][]const u8 = undefined;
        var record_count: usize = 0;
        const memory = RuntimeHarness.io(self.state_bytes.ptr);
        for (0..config.max_file_resources) |index| {
            const record = memory.memoryRecord(index) orelse continue;
            paths[record_count] = try self.allocator.dupe(u8, record.path);
            values[record_count] = try self.allocator.dupe(u8, record.bytes);
            record_count += 1;
        }
        TickRuntime.moduleDeinitialize(self.state_bytes.ptr);
        self.runtime_initialized = false;
        var state_used_bytes = self.state_bytes.len;
        const status = TickRuntime.moduleInitialize(self.state_bytes.ptr, &.{
            .panic_fn = fixturePanic,
            .state_bytes = self.state_bytes.len,
            .state_used_bytes = &state_used_bytes,
            .storage_mode = .memory,
        });
        if (status != .ok) return error.PersistentRestartInitializationFailed;
        self.runtime_initialized = true;
        const restored_memory = RuntimeHarness.io(self.state_bytes.ptr);
        for (paths[0..record_count], values[0..record_count]) |path, value|
            if (restored_memory.write(path, value) != .complete)
                return error.PersistentResourceRestoreFailed;
        self.stores = RuntimeHarness.stores(self.state_bytes.ptr);
        if (TickRuntime.moduleLoad(self.state_bytes.ptr) != .ok)
            return error.PersistentRestoreFailed;
        RuntimeHarness.setChunkStreaming(
            self.state_bytes.ptr,
            self.chunk_streaming_radius != null,
        );
        @memset(self.connected, false);
    }

    pub fn disconnectPlayer(self: *BlackBox, slot: u16) !void {
        if (slot >= config.max_players or !self.connected[slot]) return error.UnknownPlayer;
        const events = abi.EventWriter{
            .buffer = self.event_storage,
            .written = &self.event_bytes_written,
        };
        if (!events.disconnected(.{ .index = slot, .generation = 1 }, .peer_closed))
            return error.TickEventCapacity;
    }

    pub fn setProtocolVersion(self: *BlackBox, slot: u16, version: protocol_versions.Version) !void {
        if (slot >= config.max_players or !self.connected[slot]) return error.UnknownPlayer;
        try RuntimeHarness.setProtocol(self.state_bytes.ptr, slot, version.protocolNumber());
        self.protocol_numbers[slot] = version.protocolNumber();
    }

    pub fn requestItemSync(self: *BlackBox, slot: u16) void {
        RuntimeHarness.requestItemSync(self.state_bytes.ptr, slot);
    }

    pub fn player(self: *const BlackBox, slot: u16) *const CorePlayer {
        return &self.stores.players.records[slot];
    }

    pub fn setBlock(self: *BlackBox, pos: BlockPos, block_state: i32) !void {
        const world = self.stores.worlds.find(vanilla.overworld_key) orelse return error.MissingFixtureWorld;
        self.ensureFixtureChunkNeighborhood(world, geometry.chunkForBlock(pos));
        _ = try self.stores.blocks.setBlock(world, pos, block_state);
    }

    fn ensureFixtureChunkNeighborhood(
        self: *BlackBox,
        world: lightning_rod.world_identity.Handle,
        center: ChunkPos,
    ) void {
        var chunk_z = center.z - 1;
        while (chunk_z <= center.z + 1) : (chunk_z += 1) {
            var chunk_x = center.x - 1;
            while (chunk_x <= center.x + 1) : (chunk_x += 1)
                self.stores.blocks.ensureChunkAt(world, chunk_x * 16, chunk_z * 16, 0);
        }
    }

    pub fn fillBox(self: *BlackBox, min: BlockPos, max: BlockPos, block_state: i32) !void {
        if (min.x > max.x or min.y > max.y or min.z > max.z) return error.InvalidFixtureBox;
        const first_section = world_state.sectionIndexForY(min.y) orelse return error.InvalidFixtureBox;
        const last_section = world_state.sectionIndexForY(max.y) orelse return error.InvalidFixtureBox;
        const first_chunk_x = @divFloor(min.x, 16);
        const last_chunk_x = @divFloor(max.x, 16);
        const first_chunk_z = @divFloor(min.z, 16);
        const last_chunk_z = @divFloor(max.z, 16);
        const world = self.stores.worlds.find(vanilla.overworld_key) orelse
            return error.MissingFixtureWorld;
        var blocks: [world_state.blocks_per_section]i32 = undefined;

        var chunk_z = first_chunk_z;
        while (chunk_z <= last_chunk_z) : (chunk_z += 1) {
            var chunk_x = first_chunk_x;
            while (chunk_x <= last_chunk_x) : (chunk_x += 1) {
                const chunk = ChunkPos{ .x = chunk_x, .z = chunk_z };
                self.ensureFixtureChunkNeighborhood(world, chunk);
                var section = first_section;
                while (section <= last_section) : (section += 1) {
                    if (self.stores.blocks.findModifiedSection(world, chunk, section)) |table_index|
                        self.stores.blocks.copySectionBlocks(table_index, &blocks)
                    else
                        self.stores.blocks.fillGeneratedSection(world, chunk, section, &blocks);

                    const section_min_y = @as(i32, config.world_min_y) + @as(i32, @intCast(section * 16));
                    const min_y = @max(@as(i32, min.y), section_min_y);
                    const max_y = @min(@as(i32, max.y), section_min_y + 15);
                    const min_z = @max(min.z, chunk_z * 16);
                    const max_z = @min(max.z, chunk_z * 16 + 15);
                    const min_x = @max(min.x, chunk_x * 16);
                    const max_x = @min(max.x, chunk_x * 16 + 15);
                    var y = min_y;
                    while (y <= max_y) : (y += 1) {
                        var z = min_z;
                        while (z <= max_z) : (z += 1) {
                            var x = min_x;
                            while (x <= max_x) : (x += 1) {
                                const local_index = world_state.localBlockIndexForPosition(.{
                                    .x = x,
                                    .y = @intCast(y),
                                    .z = z,
                                });
                                blocks[local_index] = block_state;
                            }
                        }
                    }
                    try self.stores.blocks.loadSection(world, chunk, section, &blocks);
                }
            }
        }
    }

    pub fn setPlayerPosition(self: *BlackBox, slot: u16, position: Vec3) void {
        self.stores.players.records[slot].position = position;
        const center = chunkPosForPosition(position);
        self.replication().clients[slot].chunks.reset(center);
        self.ensureFixtureChunkNeighborhood(self.stores.players.records[slot].world, center);
    }

    pub fn setPlayerHealth(self: *BlackBox, slot: u16, health: f32) void {
        self.stores.players.records[slot].health = health;
    }

    pub fn setPlayerGamemode(self: *BlackBox, slot: u16, gamemode: GameMode) void {
        self.stores.players.records[slot].gamemode = gamemode;
    }

    pub fn setLivingHealth(self: *BlackBox, entity_id: i32, health: f32) !void {
        const index = self.stores.living.entities.indexForEntityId(entity_id) orelse return error.UnknownLivingEntity;
        self.stores.living.entities.health[index] = health;
    }

    pub fn setPlayerHeldStack(self: *BlackBox, slot: u16, hotbar_slot: u4, stack: HotbarStack) void {
        self.stores.players.records[slot].hotbar[hotbar_slot] = stack;
        self.stores.players.records[slot].selected_hotbar_slot = hotbar_slot;
    }

    pub fn setPlayerSelectedHotbarSlot(self: *BlackBox, slot: u16, hotbar_slot: u4) void {
        self.stores.players.records[slot].selected_hotbar_slot = hotbar_slot;
    }

    pub fn setPlayerInventoryStack(self: *BlackBox, slot: u16, protocol_slot: i16, stack: HotbarStack) !void {
        const destination = players.inventoryStack(&self.stores.players.records[slot], protocol_slot) orelse return error.InvalidInventorySlot;
        destination.* = stack;
    }

    pub fn spawnZombie(self: *BlackBox, position: Vec3, baby: bool, persistent: bool) !living_entities.Handle {
        return self.spawnLiving(.zombie, position, baby, persistent);
    }

    pub fn spawnLiving(self: *BlackBox, entity_type: living_entities.EntityType, position: Vec3, baby: bool, persistent: bool) !living_entities.Handle {
        const world = self.stores.worlds.find(vanilla.overworld_key) orelse return error.MissingFixtureWorld;
        return self.stores.living.spawn(
            self.stores.random,
            self.stores.blocks,
            world,
            entity_type,
            position,
            baby,
            persistent,
        );
    }

    pub fn spawnItem(
        self: *BlackBox,
        position: Vec3,
        velocity: Vec3,
        stack: HotbarStack,
        pickup_delay: u16,
        age: u32,
    ) !usize {
        const world = self.stores.worlds.find(vanilla.overworld_key) orelse return error.MissingFixtureWorld;
        const index = try self.stores.items.spawn(
            self.stores.random,
            self.stores.blocks,
            world,
            position,
            velocity,
            stack,
            pickup_delay,
        );
        self.stores.items.age_ticks[index] = age;
        return index;
    }

    pub fn setRandomTicks(self: *BlackBox, enabled: bool) void {
        self.stores.rules.do_random_ticks = enabled;
        if (!enabled) return;
        const radius = @min(config.simulation_distance_chunks + 2, 33);
        for (RuntimeHarness.playSlots(self.state_bytes.ptr)) |slot| {
            const record = &self.stores.players.records[slot];
            const center = chunkPosForPosition(record.position);
            var chunk_z = center.z - radius;
            while (chunk_z <= center.z + radius) : (chunk_z += 1) {
                var chunk_x = center.x - radius;
                while (chunk_x <= center.x + radius) : (chunk_x += 1)
                    self.stores.blocks.ensureChunkAt(
                        record.world,
                        chunk_x * 16,
                        chunk_z * 16,
                        0,
                    );
            }
        }
    }

    pub fn setRandomTickSpeed(self: *BlackBox, speed: u16) void {
        self.stores.rules.random_tick_speed = speed;
        self.setRandomTicks(speed != 0);
    }

    pub fn setMobSpawning(self: *BlackBox, enabled: bool) void {
        self.stores.rules.do_mob_spawning = enabled;
    }

    pub fn setNaturalRegeneration(self: *BlackBox, enabled: bool) void {
        self.stores.rules.natural_regeneration = enabled;
    }

    pub fn setDaylightCycle(self: *BlackBox, enabled: bool) void {
        self.stores.rules.do_daylight_cycle = enabled;
    }

    pub fn setDayTime(self: *BlackBox, value: u64) void {
        self.stores.time.day_time = value;
    }

    pub fn enableChunkStreaming(self: *BlackBox) void {
        self.enableChunkStreamingAtRadius(1);
    }

    pub fn enableChunkStreamingAtRadius(
        self: *BlackBox,
        radius: i32,
    ) void {
        std.debug.assert(radius >= 0 and radius <= config.view_distance_chunks);
        RuntimeHarness.setChunkStreaming(self.state_bytes.ptr, true);
        self.chunk_streaming_radius = radius;
        for (RuntimeHarness.playSlots(self.state_bytes.ptr)) |slot| {
            const position = self.stores.players.records[slot].position;
            self.replication().clients[slot].chunks.setRadius(.{
                .x = geometry.chunkCoord(geometry.blockCoord(position.x)),
                .z = geometry.chunkCoord(geometry.blockCoord(position.z)),
            }, radius);
        }
    }

    pub fn stage(self: *BlackBox, slot: u16, packet_body: []const u8) !void {
        if (slot >= config.max_players or !self.connected[slot]) return error.UnknownPlayer;
        if (self.staged_count == self.staged_slots.len) return error.TooManyStagedPackets;
        if (packet_body.len > max_packet_body) return error.StagedPacketTooLarge;
        const index = self.staged_count;
        self.staged_count += 1;
        self.staged_slots[index] = slot;
        self.staged_lengths[index] = @intCast(packet_body.len);
        @memcpy(self.staged_bodies[index][0..packet_body.len], packet_body);
    }

    pub fn tick(self: *BlackBox) ![]const CapturedPacket {
        // BlackBox is returned by value from init. Bind callback context only
        // after the caller has placed it at its stable address.
        self.initializeApis();
        self.captured_count = 0;
        self.captured_storage_len = 0;
        self.captured_wire_bytes = 0;
        self.capture_failed = false;
        const events = abi.EventWriter{
            .buffer = self.event_storage,
            .written = &self.event_bytes_written,
        };
        for (0..self.staged_count) |index| {
            const body = self.staged_bodies[index][0..self.staged_lengths[index]];
            var framed: [max_packet_body + 5]u8 = undefined;
            var rest = try protocol_support.write_varint(&framed, @intCast(body.len));
            const prefix_len = framed.len - rest.len;
            @memcpy(rest[0..body.len], body);
            const connection = abi.ConnectionHandle{
                .index = self.staged_slots[index],
                .generation = 1,
            };
            if (!events.rawInput(connection, framed[0 .. prefix_len + body.len]))
                return error.TickEventCapacity;
        }
        self.staged_count = 0;
        var exchange = abi.TickExchange{
            .sequence = self.stores.clock.tick,
            .monotonic_ns = 0,
            .deadline_ns = std.math.maxInt(u64),
            .events = .{ .ptr = self.event_storage.ptr, .len = self.event_bytes_written },
            .commands = .{ .ptr = self.command_storage.ptr, .len = self.command_storage.len },
            .kernel = &self.kernel_api,
        };
        const status = TickRuntime.moduleTick(self.state_bytes.ptr, &.{ .exchange = &exchange });
        if (status != .ok) return error.TickFailed;
        for (self.connected, 0..) |connected, slot| {
            if (connected and self.stores.players.records[slot].state == .free)
                self.connected[slot] = false;
        }
        self.event_bytes_written = 0;
        if (self.capture_failed) return error.OutputCaptureFailed;
        try self.consumeCommands(&exchange);
        return self.captured[0..self.captured_count];
    }

    pub fn capturedWireBytes(self: *const BlackBox) usize {
        return self.captured_wire_bytes;
    }

    fn consumeCommands(self: *BlackBox, exchange: *const abi.TickExchange) !void {
        var commands = try abi.CommandIterator.init(exchange);
        while (try commands.next()) |command| switch (command.header.kind) {
            abi.CommandKind.close_connection => {
                const close = try command.closeConnection();
                if (close.connection.index < self.connected.len)
                    self.connected[close.connection.index] = false;
            },
            abi.CommandKind.release_connection => {
                const release = try command.releaseConnection();
                if (release.connection.index < self.connected.len)
                    self.connected[release.connection.index] = false;
            },
            abi.CommandKind.log,
            abi.CommandKind.close_after_output,
            abi.CommandKind.request_reload,
            => {},
            else => return error.UnexpectedTickCommand,
        };
    }

    fn captureBytes(self: *BlackBox, bytes: []const u8) ![]const u8 {
        const output = try self.reserveCapture(bytes.len);
        @memcpy(output, bytes);
        return output;
    }

    fn reserveCapture(self: *BlackBox, len: usize) ![]u8 {
        if (len > self.captured_storage.len -| self.captured_storage_len)
            return error.CapturedPacketStorageFull;
        const start = self.captured_storage_len;
        self.captured_storage_len += len;
        return self.captured_storage[start..self.captured_storage_len];
    }

    fn reserveOutput(
        raw: *anyopaque,
        connection: abi.ConnectionHandle,
        minimum_capacity: usize,
        output: *abi.OutputLease,
    ) callconv(.c) abi.KernelStatus {
        const self: *BlackBox = @ptrCast(@alignCast(raw));
        if (connection.index >= self.connected.len or
            connection.generation != 1 or
            !self.connected[connection.index])
            return .invalid_connection;
        const body_offset = 6;
        if (self.lease_active or minimum_capacity > self.frame_storage.len - body_offset)
            return .backpressured;
        self.lease_active = true;
        self.lease_slot = @intCast(connection.index);
        output.* = .{
            .id = connection.value(),
            .bytes = .{ .ptr = self.frame_storage[body_offset..].ptr, .len = self.frame_storage.len - body_offset },
            .protocol_number = self.protocol_numbers[connection.index],
        };
        return .ok;
    }

    fn commitOutput(raw: *anyopaque, lease: u64, byte_count: usize) callconv(.c) abi.KernelStatus {
        const self: *BlackBox = @ptrCast(@alignCast(raw));
        if (!self.lease_active or lease != (@as(u64, 1) << 32) | self.lease_slot)
            return .invalid_lease;
        defer self.lease_active = false;
        const body_offset = 6;
        if (byte_count > self.frame_storage.len - body_offset or self.captured_count == self.captured.len) {
            self.capture_failed = true;
            return .rejected;
        }
        const payload = self.captureBytes(self.frame_storage[body_offset..][0..byte_count]) catch {
            self.capture_failed = true;
            return .backpressured;
        };
        self.captured[self.captured_count] = .{
            .recipient_slot = self.lease_slot,
            .payload = payload,
        };
        self.captured_count += 1;
        self.captured_wire_bytes += byte_count + varIntBytes(byte_count);
        return .ok;
    }

    fn appendInput(raw: *anyopaque, connection: abi.ConnectionHandle, bytes: abi.Bytes) callconv(.c) abi.KernelStatus {
        const self: *BlackBox = @ptrCast(@alignCast(raw));
        if (connection.index >= self.connected.len or connection.generation != 1)
            return .invalid_connection;
        if (self.input_bytes.len != 0) return .rejected;
        self.input_connection = connection;
        self.input_bytes = bytes.slice();
        return .ok;
    }

    fn nextPacket(raw: *anyopaque, connection: abi.ConnectionHandle, packet: *abi.Bytes) callconv(.c) abi.KernelStatus {
        const self: *BlackBox = @ptrCast(@alignCast(raw));
        if (self.input_connection == null or self.input_connection.?.value() != connection.value())
            return .invalid_connection;
        if (self.input_bytes.len == 0) return .incomplete;
        const framed = (wire.nextPacket(self.input_bytes) catch return .rejected) orelse return .incomplete;
        packet.* = .{ .ptr = framed.payload.ptr, .len = framed.payload.len };
        self.input_bytes = self.input_bytes[framed.total_len..];
        return .ok;
    }

    fn setCompression(_: *anyopaque, _: abi.ConnectionHandle, _: i32) callconv(.c) abi.KernelStatus {
        return .unsupported;
    }

    fn setEncryption(_: *anyopaque, _: abi.ConnectionHandle, _: abi.Bytes) callconv(.c) abi.KernelStatus {
        return .unsupported;
    }

    fn varIntBytes(value: usize) usize {
        if (value < 1 << 7) return 1;
        if (value < 1 << 14) return 2;
        if (value < 1 << 21) return 3;
        if (value < 1 << 28) return 4;
        return 5;
    }

    fn cancelOutput(raw: *anyopaque, _: u64) callconv(.c) void {
        const self: *BlackBox = @ptrCast(@alignCast(raw));
        self.lease_active = false;
    }

    fn fillRandom(_: *anyopaque, output: abi.MutableBytes) callconv(.c) abi.KernelStatus {
        @memset(output.slice(), 0x5a);
        return .ok;
    }

    fn outputBackpressured(raw: *anyopaque, connection: abi.ConnectionHandle) callconv(.c) bool {
        const self: *BlackBox = @ptrCast(@alignCast(raw));
        return self.lease_active or connection.index >= self.connected.len or
            !self.connected[connection.index];
    }

    fn fixturePanic(context: *const abi.PanicContext) callconv(.c) noreturn {
        std.debug.panic("black-box tick panic: {s}", .{context.message()});
    }
};
