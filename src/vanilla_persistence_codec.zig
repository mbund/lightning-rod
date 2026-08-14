const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const chunk_storage = lightning_rod.chunk_storage;
const geometry = lightning_rod.geometry;
const vanilla_time = lightning_rod.time;
const world_random = lightning_rod.random;
const world_clock = lightning_rod.clock;
const std = @import("std");
const registry = lightning_rod.registry_data;
const test_state = lightning_rod.test_support.state;
const config = lightning_rod.config.value;
const game_data = lightning_rod.game_data;
const world_store = lightning_rod.worlds;
const world_identity = lightning_rod.world_identity;

const metadata_magic = "LRMETA04";
const metadata_header_len = metadata_magic.len + @sizeOf(u64) + @sizeOf(u32);
const living_encoded_size = 226;

pub const PersistedState = struct {
    worlds: *world_store.Worlds,
    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    living: *entity_store.LivingEntities,
    players: *player_store.Players,
    items: *entity_store.ItemEntities,
};

pub fn metadataStateEncodedSize(state: *const PersistedState) usize {
    var size: usize = metadata_header_len + 8 + 8 + 8 + 8 + 8;
    for (state.players.saved[0..state.players.saved_count]) |player| {
        size += 16 + 16 + 1 + player.name_len + 3 * 8 + 2 * 4 + 1 + 1 + 1 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 42 * (4 + 4 + 2 + 1);
    }
    size += state.items.active_count * (16 + 3 * 8 + 3 * 8 + 16 + 4 + 2 + 4 + 4 + 2 + 1);
    size += 8 + state.living.entities.active_count * living_encoded_size;
    return size;
}

pub fn encodeMetadataState(buffer: []u8, state: *const PersistedState) ![]u8 {
    const required = metadataStateEncodedSize(state);
    if (buffer.len < required) return error.EndOfStream;
    var writer = Writer{ .buffer = buffer[0..required] };
    try writer.bytes(metadata_magic);
    const payload_len_offset = writer.index;
    try writer.int(u64, 0);
    const checksum_offset = writer.index;
    try writer.int(u32, 0);
    const payload_start = writer.index;

    try writer.int(u64, state.clock.tick);
    try writer.int(u64, state.time.day_time);
    try writer.int(u64, state.random.random.entropy);
    try writer.int(u64, state.players.saved_count);
    for (state.players.saved[0..state.players.saved_count]) |player| try writePlayer(&writer, state.worlds, player);

    try writer.int(u64, state.items.active_count);
    for (state.items.active_indices[0..state.items.active_count]) |index|
        try writeItem(&writer, state.worlds, state.items.value(index));

    try writer.int(u64, state.living.entities.active_count);
    for (state.living.entities.active_indices[0..state.living.entities.active_count]) |index|
        try writeLiving(&writer, state.worlds, state.living, index);

    std.debug.assert(writer.index == required);
    const payload = buffer[payload_start..writer.index];
    std.mem.writeInt(u64, buffer[payload_len_offset..][0..8], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buffer[checksum_offset..][0..4], std.hash.crc.Crc32.hash(payload), .little);
    return buffer[0..writer.index];
}

pub fn decodeMetadataState(state: *PersistedState, bytes: []const u8) !void {
    const started_ns = monotonicNanoseconds();
    if (bytes.len < metadata_header_len) return error.TruncatedWorldFile;
    if (!std.mem.eql(u8, bytes[0..metadata_magic.len], metadata_magic)) return error.InvalidWorldMagic;
    var reader = Reader{ .buffer = bytes, .index = metadata_magic.len };
    const payload_len = try reader.int(u64);
    const expected_checksum = try reader.int(u32);
    if (payload_len != bytes.len - metadata_header_len) return error.InvalidWorldLength;
    const payload = bytes[metadata_header_len..];
    if (std.hash.crc.Crc32.hash(payload) != expected_checksum) return error.WorldChecksumMismatch;

    const tick = try reader.int(u64);
    const day_time = try reader.int(u64);
    const entropy = try reader.int(u64);
    assertEmptyPersistedState(state);
    state.clock.tick = tick;
    state.time.day_time = day_time;
    const prepared_ns = monotonicNanoseconds();

    const player_count = try reader.int(u64);
    const player_count_usize = try countToUsize(player_count);
    if (player_count_usize > state.players.saved.len) return error.SavedPlayerCapacity;
    for (0..player_count_usize) |index| {
        state.players.saved[index] = try readPlayer(&reader, state.worlds);
        const player = &state.players.saved[index];
        player_store.returnCraftingGridToInventory(player);
        for (&player.crafting_grid) |*stack| {
            if (stack.isEmpty()) continue;
            if (state.items.active_count == config.max_item_entities) return error.ItemEntityCapacity;
            state.blocks.ensureChunkAt(player.world, geometry.blockCoord(player.position.x), geometry.blockCoord(player.position.z), tick);
            _ = try state.items.spawn(state.random, state.blocks, player.world, player.position, .{}, stack.*, entity_store.block_drop_pickup_delay_ticks);
            stack.* = .{};
        }
    }
    state.players.saved_count = player_count_usize;
    const players_ns = monotonicNanoseconds();

    const item_count = try reader.int(u64);
    const item_count_usize = try countToUsize(item_count);
    if (item_count_usize > config.max_item_entities - state.items.active_count) return error.ItemEntityCapacity;
    for (0..item_count_usize) |_| {
        const item = try readItem(&reader, state.worlds);
        state.blocks.ensureChunkAt(item.world, geometry.blockCoord(item.position.x), geometry.blockCoord(item.position.z), tick);
        _ = try state.items.restoreEntity(state.random, state.blocks, item);
    }
    const items_ns = monotonicNanoseconds();
    const living_count = try countToUsize(try reader.int(u64));
    if (living_count > config.max_living_entities) return error.LivingEntityCapacity;
    for (0..living_count) |_| try readLiving(&reader, state.worlds, state.living);
    if (reader.index != bytes.len) return error.ExtraWorldData;
    state.random.random.entropy = entropy & ((@as(u64, 1) << 48) - 1);
    assertPersistedState(state);
    const completed_ns = monotonicNanoseconds();
    std.log.info(
        "event=persistence_decode_profile players={} items={} living={} prepare_ms={d:.3} players_ms={d:.3} items_ms={d:.3} living_ms={d:.3} total_ms={d:.3}",
        .{
            player_count_usize,
            item_count_usize,
            living_count,
            milliseconds(prepared_ns -| started_ns),
            milliseconds(players_ns -| prepared_ns),
            milliseconds(items_ns -| players_ns),
            milliseconds(completed_ns -| items_ns),
            milliseconds(completed_ns -| started_ns),
        },
    );
}

fn assertEmptyPersistedState(state: *const PersistedState) void {
    std.debug.assert(state.blocks.resident_chunk_count == 0);
    std.debug.assert(state.living.entities.active_count == 0);
    std.debug.assert(state.items.active_count == 0);
    std.debug.assert(state.players.active_count == 0);
    std.debug.assert(state.players.saved_count == 0);
}

fn assertPersistedState(state: *const PersistedState) void {
    std.debug.assert(state.items.active_count <= config.max_item_entities);
    std.debug.assert(state.items.free_count <= config.max_item_entities);
    std.debug.assert(state.players.saved_count <= config.max_saved_players);
    std.debug.assert(state.players.active_count <= config.max_players);
    std.debug.assert(state.blocks.modified_section_count <= config.max_modified_sections);
    state.living.entities.assertInvariants();
}

fn countToUsize(value: u64) !usize {
    return std.math.cast(usize, value) orelse error.LengthOverflow;
}

fn monotonicNanoseconds() u64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS)
        return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(now.nsec));
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn writeWorld(writer: *Writer, worlds: *const world_store.Worlds, handle: world_identity.Handle) !void {
    const value = worlds.getConst(handle) orelse return error.StaleWorldHandle;
    try writer.int(u128, value.key.value);
}

fn readWorld(reader: *Reader, worlds: *const world_store.Worlds) !world_identity.Handle {
    return worlds.find(.{ .value = try reader.int(u128) }) orelse error.UnknownWorldKey;
}

fn writePlayer(writer: *Writer, worlds: *const world_store.Worlds, player: player_store.CorePlayer) !void {
    std.debug.assert(player.name_len <= config.max_username_bytes);
    try writeWorld(writer, worlds, player.world);
    try writer.int(u128, player.uuid);
    try writer.int(u8, @intCast(player.name_len));
    try writer.bytes(player.name_slice());
    try writeVec3(writer, player.position);
    try writer.int(u32, @bitCast(player.rotation.yaw));
    try writer.int(u32, @bitCast(player.rotation.pitch));
    try writer.int(u8, @intFromBool(player.on_ground));
    try writer.int(u8, player.selected_hotbar_slot);
    try writer.int(u8, @intFromEnum(player.gamemode));
    try writer.int(i32, player.inventory_state_id);
    try writer.int(u32, @bitCast(player.health));
    try writer.int(i32, player.food);
    try writer.int(u32, @bitCast(player.saturation));
    try writer.int(u32, @bitCast(player.exhaustion));
    try writer.int(u32, @bitCast(player.last_damage_taken));
    try writer.int(i32, player.time_until_regen);
    try writer.int(i32, player.food_tick_timer);
    for (player.hotbar) |stack| try writeStack(writer, stack);
    for (player.main_inventory) |stack| try writeStack(writer, stack);
    for (player.armor) |stack| try writeStack(writer, stack);
    try writeStack(writer, player.offhand);
    try writeStack(writer, player.cursor_stack);
}

fn readPlayer(reader: *Reader, worlds: *const world_store.Worlds) !player_store.CorePlayer {
    var player: player_store.CorePlayer = .{};
    player.world = try readWorld(reader, worlds);
    player.uuid = try reader.int(u128);
    const name_len = try reader.int(u8);
    if (name_len > player.name.len) return error.UsernameTooLong;
    @memcpy(player.name[0..name_len], try reader.bytes(name_len));
    player.name_len = name_len;
    player.position = try readVec3(reader);
    player.rotation.yaw = @bitCast(try reader.int(u32));
    player.rotation.pitch = @bitCast(try reader.int(u32));
    player.on_ground = try readBool(reader);
    const selected = try reader.int(u8);
    if (selected >= 9) return error.InvalidHotbarSlot;
    player.selected_hotbar_slot = @intCast(selected);
    player.gamemode = switch (try reader.int(u8)) {
        0 => .survival,
        1 => .creative,
        2 => .adventure,
        3 => .spectator,
        else => return error.InvalidGameMode,
    };
    player.inventory_state_id = try reader.int(i32);
    player.health = @bitCast(try reader.int(u32));
    player.food = try reader.int(i32);
    player.saturation = @bitCast(try reader.int(u32));
    player.exhaustion = @bitCast(try reader.int(u32));
    player.last_damage_taken = @bitCast(try reader.int(u32));
    player.time_until_regen = try reader.int(i32);
    player.food_tick_timer = try reader.int(i32);
    for (&player.hotbar) |*stack| stack.* = try readStack(reader);
    for (&player.main_inventory) |*stack| stack.* = try readStack(reader);
    for (&player.armor) |*stack| stack.* = try readStack(reader);
    player.offhand = try readStack(reader);
    player.cursor_stack = try readStack(reader);
    return player;
}

fn writeItem(writer: *Writer, worlds: *const world_store.Worlds, item: entity_store.ItemEntity) !void {
    try writeWorld(writer, worlds, item.world);
    try writeVec3(writer, item.position);
    try writeVec3(writer, item.velocity);
    try writer.int(u128, item.uuid);
    try writer.int(u32, item.age_ticks);
    try writer.int(u16, item.pickup_delay_ticks);
    try writeStack(writer, item.stack);
}

fn readItem(reader: *Reader, worlds: *const world_store.Worlds) !entity_store.ItemEntity {
    return .{
        .world = try readWorld(reader, worlds),
        .position = try readVec3(reader),
        .velocity = try readVec3(reader),
        .uuid = try reader.int(u128),
        .age_ticks = try reader.int(u32),
        .pickup_delay_ticks = try reader.int(u16),
        .stack = try readStack(reader),
        .active = true,
    };
}

fn writeLiving(writer: *Writer, worlds: *const world_store.Worlds, living: *const entity_store.LivingEntities, index: u16) !void {
    const before = writer.index;
    const entities = &living.entities;
    try writeWorld(writer, worlds, entities.worlds[index]);
    try writer.int(u8, @intFromEnum(entities.entity_types[index]));
    try writer.int(u128, entities.uuids[index]);
    try writeVec3(writer, .{ .x = entities.position_x[index], .y = entities.position_y[index], .z = entities.position_z[index] });
    try writeVec3(writer, .{ .x = entities.velocity_x[index], .y = entities.velocity_y[index], .z = entities.velocity_z[index] });
    try writer.int(u32, @bitCast(entities.yaw[index]));
    try writer.int(u32, @bitCast(entities.pitch[index]));
    try writer.int(u32, @bitCast(entities.body_yaw[index]));
    try writer.int(u32, @bitCast(entities.head_yaw[index]));
    try writer.int(u32, @bitCast(entities.health[index]));
    try writer.int(i32, entities.fire_ticks[index]);
    try writer.int(u32, entities.despawn_counter[index]);
    try writer.int(u8, @intFromBool(entities.baby[index]));
    try writer.int(i32, entities.breeding_age[index]);
    try writer.int(u16, entities.love_ticks[index]);
    try writer.int(u16, entities.loving_player[index]);
    try writer.int(u8, @intFromBool(entities.persistent[index]));
    try writer.int(u8, @intFromBool(entities.on_ground[index]));
    try writer.int(u32, entities.age[index]);
    try writer.int(i32, entities.ambient_sound_chance[index]);
    try writer.int(u64, entities.random[index].seed);
    try writer.int(u64, @bitCast(entities.random[index].gaussian));
    try writer.int(u8, @intFromBool(entities.random[index].has_gaussian));
    try writer.int(u32, @bitCast(entities.max_health[index]));
    try writer.int(u32, @bitCast(entities.last_damage_taken[index]));
    try writer.int(u64, @bitCast(entities.armor_toughness[index]));
    try writer.int(i32, entities.time_until_regen[index]);
    try writer.int(u8, entities.death_time[index]);
    try writer.int(u8, @intFromBool(entities.dead[index]));
    try writer.int(u8, @intFromBool(entities.can_pick_up_loot[index]));
    try writer.int(u8, @intFromBool(entities.can_break_doors[index]));
    try writer.int(u8, @intFromBool(entities.leader[index]));
    try writer.int(u64, @bitCast(entities.reinforcement_chance[index]));
    for (0..6) |equipment_slot| {
        const stack = entities.equipment[index][equipment_slot];
        try writer.int(i32, stack.item_id);
        try writer.int(u16, stack.damage);
        try writer.int(u8, stack.count);
        try writer.int(u8, @intFromBool(entities.equipment_drop_guaranteed[index][equipment_slot]));
    }
    std.debug.assert(writer.index - before == living_encoded_size);
}

const LivingRecord = struct {
    world: world_identity.Handle,
    entity_type: living_entities.EntityType,
    uuid: u128,
    position: geometry.Vec3,
    velocity: geometry.Vec3,
    yaw: f32,
    pitch: f32,
    body_yaw: f32,
    head_yaw: f32,
    health: f32,
    fire_ticks: i32,
    despawn_counter: u32,
    baby: bool,
    breeding_age: i32,
    love_ticks: u16,
    loving_player: u16,
    persistent: bool,
    on_ground: bool,
    age: u32,
    ambient_sound_chance: i32,
    random_seed: u64,
    gaussian: f64,
    has_gaussian: bool,
    max_health: f32,
    last_damage_taken: f32,
    armor_toughness: f64,
    time_until_regen: i32,
    death_time: u8,
    dead: bool,
    can_pick_up_loot: bool,
    can_break_doors: bool,
    leader: bool,
    reinforcement_chance: f64,
    equipment: [6]living_entities.EquipmentStack,
    equipment_drop_guaranteed: [6]bool,
};

fn readLivingRecord(reader: *Reader, worlds: *const world_store.Worlds) !LivingRecord {
    const world = try readWorld(reader, worlds);
    const entity_type: living_entities.EntityType = switch (try reader.int(u8)) {
        0 => .zombie,
        1 => .zombified_piglin,
        2 => .turtle,
        3 => .cow,
        4 => .pig,
        else => return error.InvalidLivingEntityType,
    };
    var equipment = [_]living_entities.EquipmentStack{.{}} ** 6;
    var guaranteed = [_]bool{false} ** 6;
    var result = LivingRecord{
        .world = world,
        .entity_type = entity_type,
        .uuid = try reader.int(u128),
        .position = try readVec3(reader),
        .velocity = try readVec3(reader),
        .yaw = @bitCast(try reader.int(u32)),
        .pitch = @bitCast(try reader.int(u32)),
        .body_yaw = @bitCast(try reader.int(u32)),
        .head_yaw = @bitCast(try reader.int(u32)),
        .health = @bitCast(try reader.int(u32)),
        .fire_ticks = try reader.int(i32),
        .despawn_counter = try reader.int(u32),
        .baby = try readBool(reader),
        .breeding_age = try reader.int(i32),
        .love_ticks = try reader.int(u16),
        .loving_player = try reader.int(u16),
        .persistent = try readBool(reader),
        .on_ground = try readBool(reader),
        .age = try reader.int(u32),
        .ambient_sound_chance = try reader.int(i32),
        .random_seed = try reader.int(u64),
        .gaussian = @bitCast(try reader.int(u64)),
        .has_gaussian = try readBool(reader),
        .max_health = @bitCast(try reader.int(u32)),
        .last_damage_taken = @bitCast(try reader.int(u32)),
        .armor_toughness = @bitCast(try reader.int(u64)),
        .time_until_regen = try reader.int(i32),
        .death_time = try reader.int(u8),
        .dead = try readBool(reader),
        .can_pick_up_loot = try readBool(reader),
        .can_break_doors = try readBool(reader),
        .leader = try readBool(reader),
        .reinforcement_chance = @bitCast(try reader.int(u64)),
        .equipment = undefined,
        .equipment_drop_guaranteed = undefined,
    };
    for (&equipment, &guaranteed) |*stack, *drop_guaranteed| {
        stack.* = .{
            .item_id = try reader.int(i32),
            .damage = try reader.int(u16),
            .count = try reader.int(u8),
        };
        drop_guaranteed.* = try readBool(reader);
    }
    result.equipment = equipment;
    result.equipment_drop_guaranteed = guaranteed;
    return result;
}

fn readLiving(reader: *Reader, worlds: *const world_store.Worlds, living: *entity_store.LivingEntities) !void {
    const before = reader.index;
    const record = try readLivingRecord(reader, worlds);
    const handle = try living.entities.spawn(.{
        .world = record.world,
        .entity_type = record.entity_type,
        .position = .{ .x = record.position.x, .y = record.position.y, .z = record.position.z },
        .velocity = .{ .x = record.velocity.x, .y = record.velocity.y, .z = record.velocity.z },
        .yaw = record.yaw,
        .pitch = record.pitch,
        .uuid = record.uuid,
        .random_seed = 0,
        .baby = record.baby,
        .persistent = record.persistent,
    });
    applyLivingRecord(&living.entities, handle.index, record);
    living.paths.clear(handle.index);
    std.debug.assert(reader.index - before == living_encoded_size);
}

fn applyLivingRecord(entities: *living_entities.Pool, index: usize, record: LivingRecord) void {
    entities.body_yaw[index] = record.body_yaw;
    entities.head_yaw[index] = record.head_yaw;
    entities.health[index] = record.health;
    entities.breeding_age[index] = record.breeding_age;
    entities.love_ticks[index] = record.love_ticks;
    entities.loving_player[index] = record.loving_player;
    entities.max_health[index] = record.max_health;
    entities.last_damage_taken[index] = record.last_damage_taken;
    entities.armor_toughness[index] = record.armor_toughness;
    entities.time_until_regen[index] = record.time_until_regen;
    entities.death_time[index] = record.death_time;
    entities.dead[index] = record.dead;
    entities.can_pick_up_loot[index] = record.can_pick_up_loot;
    entities.can_break_doors[index] = record.can_break_doors;
    entities.leader[index] = record.leader;
    entities.reinforcement_chance[index] = record.reinforcement_chance;
    entities.equipment[index] = record.equipment;
    entities.equipment_drop_guaranteed[index] = record.equipment_drop_guaranteed;
    for (record.equipment[2..]) |stack| {
        entities.armor[index] += game_data.armor(stack.item_id);
        entities.armor_toughness[index] += game_data.armorToughness(stack.item_id);
    }
    entities.attack_damage[index] += game_data.playerAttackDamage(record.equipment[0].item_id) - 1;
    entities.fire_ticks[index] = record.fire_ticks;
    entities.despawn_counter[index] = record.despawn_counter;
    entities.on_ground[index] = record.on_ground;
    entities.age[index] = record.age;
    entities.ambient_sound_chance[index] = record.ambient_sound_chance;
    entities.random[index].seed = record.random_seed;
    entities.random[index].gaussian = record.gaussian;
    entities.random[index].has_gaussian = record.has_gaussian;
}

fn writeVec3(writer: *Writer, value: geometry.Vec3) !void {
    try writer.int(u64, @bitCast(value.x));
    try writer.int(u64, @bitCast(value.y));
    try writer.int(u64, @bitCast(value.z));
}

fn readVec3(reader: *Reader) !geometry.Vec3 {
    return .{ .x = @bitCast(try reader.int(u64)), .y = @bitCast(try reader.int(u64)), .z = @bitCast(try reader.int(u64)) };
}

fn writeStack(writer: *Writer, stack: player_store.HotbarStack) !void {
    try writer.int(i32, stack.block_state);
    try writer.int(i32, stack.item_id);
    try writer.int(u16, stack.damage);
    try writer.int(u8, stack.count);
}

fn readStack(reader: *Reader) !player_store.HotbarStack {
    const block_state = try reader.int(i32);
    const item_id = try reader.int(i32);
    const damage = try reader.int(u16);
    return .{ .block_state = block_state, .item_id = item_id, .damage = damage, .count = try reader.int(u8) };
}

fn readBool(reader: *Reader) !bool {
    return switch (try reader.int(u8)) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

const Writer = struct {
    buffer: []u8,
    index: usize = 0,

    fn int(self: *Writer, comptime T: type, value: T) !void {
        const size = @sizeOf(T);
        if (self.index + size > self.buffer.len) return error.EndOfStream;
        std.mem.writeInt(T, self.buffer[self.index..][0..size], value, .little);
        self.index += size;
    }

    fn bytes(self: *Writer, value: []const u8) !void {
        if (self.index + value.len > self.buffer.len) return error.EndOfStream;
        @memcpy(self.buffer[self.index..][0..value.len], value);
        self.index += value.len;
    }
};

const Reader = struct {
    buffer: []const u8,
    index: usize = 0,

    fn int(self: *Reader, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.index + size > self.buffer.len) return error.TruncatedWorldFile;
        const value = std.mem.readInt(T, self.buffer[self.index..][0..size], .little);
        self.index += size;
        return value;
    }

    fn bytes(self: *Reader, len: usize) ![]const u8 {
        if (self.index + len > self.buffer.len) return error.TruncatedWorldFile;
        const value = self.buffer[self.index..][0..len];
        self.index += len;
        return value;
    }
};

fn persistedTestState(state: *test_state.State) PersistedState {
    return .{
        .worlds = &state.worlds,
        .clock = &state.clock,
        .time = &state.time,
        .random = &state.random,
        .blocks = &state.blocks,
        .living = &state.living,
        .players = &state.players,
        .items = &state.items,
    };
}

test "world state round trips with blocks players and item entities" {
    const source = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(source);
    try source.init(std.testing.allocator, 0x8877_6655);
    defer source.deinit();
    source.clock.tick = 12_345;
    source.time.day_time = 6_789;
    _ = source.random.random.next();

    _ = source.blocks.generatedHeightChunkRef(source.world, .{ .x = -2, .z = 2 }, source.clock.tick);
    const removed = geometry.BlockPos{ .x = -17, .y = source.blocks.surfaceHeightAt(source.world, -17, 33), .z = 33 };
    try std.testing.expect(try source.blocks.setBlock(source.world, removed, registry.block_air_default_state));
    const placed = geometry.BlockPos{ .x = 42, .y = 120, .z = -9 };
    try std.testing.expect(try source.blocks.setBlock(source.world, placed, registry.block_dirt_default_state));

    source.players.beginConnection(&source.random, 0);
    _ = try source.players.login(&source.random, 0, "persistent-player", 0x1234);
    source.players.records[0].position = .{ .x = 123.5, .y = 91, .z = -44.25 };
    source.players.records[0].world = source.world;
    source.players.records[0].rotation = .{ .yaw = 37, .pitch = -12 };
    source.players.records[0].gamemode = .creative;
    // Occupy h0-h2 explicitly so the returned crafting stack below lands in
    source.players.records[0].hotbar[0] = player_store.stackForItem(registry.item_diamond_shovel_id, 1);
    source.players.records[0].hotbar[1] = player_store.stackForItem(registry.item_diamond_pickaxe_id, 1);
    source.players.records[0].hotbar[2] = player_store.stackForItem(registry.item_diamond_axe_id, 1);
    source.players.records[0].hotbar[4] = .{ .block_state = registry.block_dirt_default_state, .item_id = 99, .damage = 7, .count = 17 };
    source.players.records[0].main_inventory[8] = player_store.stackForItem(1, 12);
    source.players.records[0].armor[1] = player_store.stackForItem(1, 1);
    source.players.records[0].offhand = player_store.stackForItem(1, 2);
    source.players.records[0].crafting_grid[2] = player_store.stackForItem(1, 3);
    source.players.records[0].cursor_stack = player_store.stackForItem(1, 2);
    player_store.returnCraftingGridToInventory(&source.players.records[0]);
    try source.players.saveAll();
    source.players.records[0].state = .free;

    source.blocks.ensureChunkAt(source.world, 2, 3, source.clock.tick);
    const item_index = try source.items.spawn(&source.random, &source.blocks, source.world, .{ .x = 2, .y = 100, .z = 3 }, .{ .x = 0.1, .y = -0.2, .z = 0.3 }, .{ .block_state = registry.block_stone_default_state, .item_id = 1, .count = 5 }, entity_store.block_drop_pickup_delay_ticks);
    source.items.age_ticks[item_index] = 88;
    source.items.pickup_delay_ticks[item_index] = 3;
    source.blocks.ensureChunkAt(source.world, -9, 12, source.clock.tick);
    const zombie = try source.living.spawn(&source.random, &source.blocks, source.world, .zombie, .{ .x = -8.5, .y = 64, .z = 12.25 }, true, true);
    source.living.entities.velocity_x[zombie.index] = 0.125;
    source.living.entities.health[zombie.index] = 13.5;
    source.living.entities.age[zombie.index] = 77;
    source.living.entities.on_ground[zombie.index] = true;
    source.living.entities.can_pick_up_loot[zombie.index] = true;
    source.living.entities.can_break_doors[zombie.index] = true;
    source.living.entities.leader[zombie.index] = true;
    source.living.entities.reinforcement_chance[zombie.index] = 0.625;
    source.living.entities.equipment[zombie.index][0] = .{ .item_id = 1, .damage = 4, .count = 1 };
    source.living.entities.equipment_drop_guaranteed[zombie.index][0] = true;
    _ = source.living.entities.random[zombie.index].nextGaussian();

    var source_state = persistedTestState(source);
    const buffer = try std.testing.allocator.alloc(u8, metadataStateEncodedSize(&source_state));
    defer std.testing.allocator.free(buffer);
    const encoded = try encodeMetadataState(buffer, &source_state);
    const removed_chunk_buffer = try std.testing.allocator.alloc(u8, chunk_storage.encoded_size);
    defer std.testing.allocator.free(removed_chunk_buffer);
    const removed_chunk = geometry.chunkForBlock(removed);
    const encoded_removed_chunk = try chunk_storage.encode(removed_chunk_buffer, &source.blocks, source.world, removed_chunk);
    const placed_chunk_buffer = try std.testing.allocator.alloc(u8, chunk_storage.encoded_size);
    defer std.testing.allocator.free(placed_chunk_buffer);
    const placed_chunk = geometry.chunkForBlock(placed);
    const encoded_placed_chunk = try chunk_storage.encode(placed_chunk_buffer, &source.blocks, source.world, placed_chunk);
    try std.testing.expect(encoded_removed_chunk.len > chunk_storage.minimum_encoded_size + @sizeOf(u16) + block_store.blocks_per_section * @sizeOf(i32));
    try std.testing.expect(encoded_placed_chunk.len > chunk_storage.minimum_encoded_size + @sizeOf(u16) + block_store.blocks_per_section * @sizeOf(i32));

    const restored = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(restored);
    try restored.init(std.testing.allocator, 0);
    defer restored.deinit();
    var restored_state = persistedTestState(restored);
    try decodeMetadataState(&restored_state, encoded);
    try chunk_storage.decode(&restored.blocks, restored.world, removed_chunk, encoded_removed_chunk);
    try chunk_storage.decode(&restored.blocks, restored.world, placed_chunk, encoded_placed_chunk);
    try std.testing.expectEqual(source.clock.tick, restored.clock.tick);
    try std.testing.expectEqual(source.time.day_time, restored.time.day_time);
    try std.testing.expectEqual(source.random.random.entropy, restored.random.random.entropy);
    try std.testing.expectEqual(registry.block_air_default_state, restored.blocks.blockAt(restored.world, removed));
    try std.testing.expectEqual(registry.block_dirt_default_state, restored.blocks.blockAt(restored.world, placed));
    try std.testing.expectEqual(@as(usize, 1), restored.players.saved_count);
    try std.testing.expectEqualStrings("persistent-player", restored.players.saved[0].name_slice());
    try std.testing.expectEqual(@as(f64, 123.5), restored.players.saved[0].position.x);
    try std.testing.expectEqual(player_store.GameMode.creative, restored.players.saved[0].gamemode);
    try std.testing.expectEqual(@as(u8, 3), restored.players.saved[0].hotbar[3].count);
    try std.testing.expectEqual(@as(u8, 17), restored.players.saved[0].hotbar[4].count);
    try std.testing.expectEqual(@as(u16, 7), restored.players.saved[0].hotbar[4].damage);
    try std.testing.expectEqual(@as(u8, 12), restored.players.saved[0].main_inventory[8].count);
    try std.testing.expectEqual(@as(u8, 1), restored.players.saved[0].armor[1].count);
    try std.testing.expectEqual(@as(u8, 2), restored.players.saved[0].offhand.count);
    try std.testing.expect(restored.players.saved[0].crafting_grid[2].isEmpty());
    try std.testing.expectEqual(@as(u8, 2), restored.players.saved[0].cursor_stack.count);
    try std.testing.expectEqual(@as(usize, 1), restored.items.active_count);
    const restored_item = restored.items.value(restored.items.active_indices[0]);
    try std.testing.expect(restored_item.entity_id != 0);
    try std.testing.expectEqual(@as(u32, 88), restored_item.age_ticks);
    try std.testing.expectEqual(@as(u8, 5), restored_item.stack.count);
    try std.testing.expectEqual(@as(usize, 1), restored.living.entities.active_count);
    const restored_zombie = restored.living.entities.active_indices[0];
    try std.testing.expect(restored.living.entities.baby[restored_zombie]);
    try std.testing.expect(restored.living.entities.persistent[restored_zombie]);
    try std.testing.expectEqual(@as(f64, -8.5), restored.living.entities.position_x[restored_zombie]);
    try std.testing.expectEqual(@as(f64, 0.125), restored.living.entities.velocity_x[restored_zombie]);
    try std.testing.expectEqual(@as(f32, 13.5), restored.living.entities.health[restored_zombie]);
    try std.testing.expectEqual(@as(u32, 77), restored.living.entities.age[restored_zombie]);
    try std.testing.expectEqual(source.living.entities.random[zombie.index].seed, restored.living.entities.random[restored_zombie].seed);
    try std.testing.expectEqual(source.living.entities.random[zombie.index].has_gaussian, restored.living.entities.random[restored_zombie].has_gaussian);
    try std.testing.expect(restored.living.entities.can_pick_up_loot[restored_zombie]);
    try std.testing.expect(restored.living.entities.can_break_doors[restored_zombie]);
    try std.testing.expect(restored.living.entities.leader[restored_zombie]);
    try std.testing.expectEqual(@as(f64, 0.625), restored.living.entities.reinforcement_chance[restored_zombie]);
    try std.testing.expectEqual(@as(i32, 1), restored.living.entities.equipment[restored_zombie][0].item_id);
    try std.testing.expect(restored.living.entities.equipment_drop_guaranteed[restored_zombie][0]);

    const second_buffer = try std.testing.allocator.alloc(u8, metadataStateEncodedSize(&restored_state));
    defer std.testing.allocator.free(second_buffer);
    const second = try encodeMetadataState(second_buffer, &restored_state);
    try std.testing.expectEqualSlices(u8, encoded, second);
}

test "world state rejects truncation and corruption" {
    const source = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(source);
    try source.init(std.testing.allocator, 9);
    defer source.deinit();
    var source_state = persistedTestState(source);
    const buffer = try std.testing.allocator.alloc(u8, metadataStateEncodedSize(&source_state));
    defer std.testing.allocator.free(buffer);
    const encoded = try encodeMetadataState(buffer, &source_state);
    const restored = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(restored);
    try restored.init(std.testing.allocator, 0);
    defer restored.deinit();
    var restored_state = persistedTestState(restored);
    try std.testing.expectError(error.InvalidWorldLength, decodeMetadataState(&restored_state, encoded[0 .. encoded.len - 1]));
    encoded[encoded.len - 1] ^= 0x80;
    try std.testing.expectError(error.WorldChecksumMismatch, decodeMetadataState(&restored_state, encoded));
}
