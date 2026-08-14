const std = @import("std");
const server_options = @import("server_options");

pub const Config = struct {
    seed: u64 = 0x6d_62_75_6e_64_00_00_01,
    max_players: usize = server_options.max_players,
    status_connection_reserve: usize = server_options.status_connection_reserve,
    ring_entries: u16 = 4096,
    completion_batch: usize = 256,
    recv_buffer_group: u16 = 7,
    recv_buffer_size: u32 = 8192,
    recv_buffer_count: u16 = 256,
    player_read_buffer_size: usize = 16 * 1024,
    tick_input_arena_bytes: usize = 4 * 1024 * 1024,
    tick_input_memory_guards: bool = server_options.tick_input_memory_guards,
    tick_input_virtual_bytes: usize = server_options.tick_input_virtual_bytes,
    tick_module_path: []const u8 = server_options.tick_module_path,
    reload_state_virtual_bytes: usize = server_options.reload_state_virtual_bytes,
    tick_state_bytes: usize = server_options.tick_state_bytes,
    max_tick_input_packets: usize = 4096,
    tick_event_buffer_bytes: usize = 4 * 1024 * 1024,
    tick_command_buffer_bytes: usize = 64 * 1024,
    player_write_buffer_size: usize = 384 * 1024,
    output_buffer_size: usize = 64 * 1024,
    output_buffer_count: usize = server_options.output_buffer_count,
    max_client_output_segments: usize = @min(server_options.output_buffer_count, 192),
    chunk_output_high_water_segments: usize = @max(
        2,
        @min(server_options.output_buffer_count - 1, 128),
    ),
    max_concurrent_chunk_loads: usize = 64,
    max_send_iovecs: usize = 16,
    compression_threshold: i32 = 256,
    listen_backlog: u32 = 256,
    port: u16 = server_options.port,
    ticks_per_second: u64 = 20,
    bulk_work_reserve_ns: u64 = 2 * std.time.ns_per_ms,
    max_bulk_terrain_jobs: u32 = 64,
    keep_alive_interval_ticks: u64 = 20 * 10,
    checkpoint_interval_ticks: u64 = server_options.checkpoint_interval_ticks,
    max_modified_sections: usize = server_options.max_modified_sections,
    max_player_block_overlays: usize = 256,
    max_tick_player_messages: usize = 256,
    tick_block_request_capacity: usize = 1024,
    tick_inventory_click_capacity: usize = 1024,
    tick_creative_slot_capacity: usize = 1024,
    max_chests: usize = 128,
    max_furnaces: usize = 256,
    random_tick_speed: u8 = server_options.random_tick_speed,
    max_random_tick_block_changes_per_tick: usize = 1024,
    max_block_mutation_history: usize = 16 * 1024,
    max_item_entities: usize = server_options.max_item_entities,
    max_living_entities: usize = server_options.max_living_entities,
    max_path_search_nodes: usize = server_options.max_path_search_nodes,
    max_path_nodes: usize = server_options.max_path_nodes,
    max_saved_players: usize = 256,
    max_worlds: usize = server_options.max_worlds,
    max_plugin_data_entries: usize = 64,
    max_plugin_data_bytes: usize = 64 * 1024,
    max_plugin_id_bytes: usize = 96,
    max_file_resources: usize = 512,
    max_file_resource_bytes: usize = 512 * 1024,
    max_resource_path_bytes: usize = 192,
    item_spatial_bucket_count: usize = 256,
    max_cached_chunks: usize = 64,
    chunk_cache_lookup_slots: usize = 128,
    max_resident_chunks: usize = server_options.max_resident_chunks,
    max_username_bytes: usize = 32,
    max_world_name_bytes: usize = 128,
    max_chat_message_bytes: usize = 256,
    max_chat_component_bytes: usize = 512,
    view_distance_chunks: i32 = server_options.view_distance_chunks,
    simulation_distance_chunks: i32 = server_options.simulation_distance_chunks,
    world_min_y: i16 = -64,
    overworld_section_count: usize = 24,
    spawn_y: i16 = 64,
    status_motd: []const u8 = "lightning-rod",
    world_directory_path: []const u8 = "world",
    world_chunks_path: []const u8 = "world/chunks",
    world_plugins_path: []const u8 = "world/plugins",
    world_metadata_path: []const u8 = "world/metadata.lrm",
    world_metadata_temp_path: []const u8 = "world/metadata.lrm.tmp",

    pub fn connectionCapacity(self: Config) usize {
        return self.max_players + self.status_connection_reserve;
    }

    pub fn verify(comptime self: Config) void {
        self.verifyNetwork();
        self.verifyTickMemory();
        self.verifyWorld();
        self.verifyEntities();
        self.verifyStorage();
    }

    fn verifyNetwork(comptime self: Config) void {
        if (self.max_players == 0) @compileError("max_players must be positive");
        if (self.max_players > std.math.maxInt(u16)) @compileError("max_players must fit in u16");
        if (self.status_connection_reserve < 2) @compileError("at least two non-player connections are required for status and full-server responses");
        if (self.connectionCapacity() > std.math.maxInt(u16)) @compileError("connection capacity must fit in u16");
        if (self.ring_entries == 0) @compileError("ring_entries must be positive");
        if (self.completion_batch == 0) @compileError("completion_batch must be positive");
        if (self.recv_buffer_count == 0) @compileError("recv_buffer_count must be positive");
        if (!std.math.isPowerOfTwo(self.recv_buffer_count)) @compileError("recv_buffer_count must be a power of two");
        if (self.recv_buffer_size == 0) @compileError("recv_buffer_size must be positive");
        if (self.player_read_buffer_size < self.recv_buffer_size) @compileError("per-player read buffer must hold at least one recv buffer");
        if (self.player_write_buffer_size < 1024) @compileError("per-player write buffer is too small");
        if (self.output_buffer_size < 1024) @compileError("output buffers are too small");
        if (self.output_buffer_count < self.status_connection_reserve) @compileError("output buffer pool must cover reserved status connections");
        if (self.output_buffer_count > std.math.maxInt(u16)) @compileError("output buffer indices must fit in u16");
        if (self.max_client_output_segments == 0) @compileError("client output segment limit must be positive");
        if (self.chunk_output_high_water_segments == 0 or self.chunk_output_high_water_segments >= self.max_client_output_segments) @compileError("chunk output high-water mark must leave room for gameplay packets");
        if (self.max_send_iovecs == 0) @compileError("send iovec limit must be positive");
        if (self.compression_threshold < 0) @compileError("compression threshold must be non-negative");
    }

    fn verifyTickMemory(comptime self: Config) void {
        if (self.tick_input_arena_bytes == 0 or self.tick_input_arena_bytes > std.math.maxInt(u32)) @compileError("tick input arena capacity must be positive and fit in u32 offsets");
        if (self.tick_input_memory_guards and self.tick_input_virtual_bytes < self.tick_input_arena_bytes * 2) @compileError("guarded tick input must reserve substantially more than one arena");
        if (self.max_tick_input_packets == 0) @compileError("tick input packet capacity must be positive");
        if (self.tick_event_buffer_bytes < 1024) @compileError("tick event buffer is too small");
        if (self.tick_state_bytes < 64 * 1024 * 1024) @compileError("tick state capacity is too small");
        if (self.tick_command_buffer_bytes < 1024) @compileError("tick command buffer is too small");
        if (self.max_concurrent_chunk_loads == 0 or self.max_concurrent_chunk_loads > std.math.maxInt(u16)) @compileError("chunk load concurrency must be positive and fit in a completion tag");
        if (self.bulk_work_reserve_ns >= std.time.ns_per_s / self.ticks_per_second)
            @compileError("bulk work reserve must be smaller than one tick interval");
        if (self.max_bulk_terrain_jobs == 0)
            @compileError("bulk terrain job limit must be positive");
    }

    fn verifyWorld(comptime self: Config) void {
        if (self.max_world_name_bytes == 0 or self.max_world_name_bytes > std.math.maxInt(u8))
            @compileError("world names must fit in a non-empty u8-length buffer");
        if (self.max_worlds < 3 or self.max_worlds > std.math.maxInt(u16))
            @compileError("world capacity must hold Vanilla dimensions and fit in u16");
        if (!std.math.isPowerOfTwo(self.max_worlds))
            @compileError("world capacity must be a power of two");
        if (self.max_modified_sections == 0 or self.max_modified_sections >= std.math.maxInt(u16)) @compileError("modified section pages must fit in u16");
        if (!std.math.isPowerOfTwo(self.max_modified_sections)) @compileError("modified section capacity must be a power of two");
        if (self.max_player_block_overlays == 0) @compileError("player overlay capacity must be positive");
        if (!std.math.isPowerOfTwo(self.max_player_block_overlays)) @compileError("player overlay lookup size must be a power of two");
        if (self.max_tick_player_messages == 0) @compileError("tick player message capacity must be positive");
        if (self.tick_block_request_capacity == 0) @compileError("tick_block_request_capacity must be positive");
        if (self.tick_inventory_click_capacity == 0) @compileError("tick_inventory_click_capacity must be positive");
        if (self.tick_creative_slot_capacity == 0) @compileError("tick_creative_slot_capacity must be positive");
        if (self.max_chests == 0 or self.max_chests > std.math.maxInt(u16)) @compileError("chest capacity must fit u16 indices");
        if (self.max_furnaces == 0 or self.max_furnaces > std.math.maxInt(u16)) @compileError("furnace capacity must fit u16 indices");
        if (self.random_tick_speed == 0) @compileError("random_tick_speed must be positive");
        if (self.max_random_tick_block_changes_per_tick == 0) @compileError("random tick change budget must be positive");
        if (self.max_block_mutation_history < self.max_random_tick_block_changes_per_tick + self.tick_block_request_capacity)
            @compileError("block mutation history must cover every bounded block mutation source in one tick");
        if (!std.math.isPowerOfTwo(self.max_resident_chunks) or self.max_resident_chunks < 4) @compileError("resident chunk capacity must be a power of two with at least four entries");
        if (self.max_resident_chunks >= std.math.maxInt(u16)) @compileError("resident chunk indices must fit in u16");
        if (self.view_distance_chunks < 0) @compileError("view_distance_chunks must be non-negative");
        if (self.simulation_distance_chunks < 0) @compileError("simulation_distance_chunks must be non-negative");
        const view_diameter: usize = @intCast(self.view_distance_chunks * 2 + 1);
        if (view_diameter * view_diameter > std.math.maxInt(u16)) @compileError("view distance exceeds the u16 radial chunk index");
        if (self.overworld_section_count > 31) @compileError("chunk section dirty masks currently use u32 bits");
    }

    fn verifyEntities(comptime self: Config) void {
        if (self.max_item_entities == 0) @compileError("max_item_entities must be positive");
        if (self.max_item_entities >= std.math.maxInt(u16)) @compileError("item entity indices must fit in u16 sentinel range");
        if (self.max_living_entities == 0 or self.max_living_entities >= std.math.maxInt(u16)) @compileError("living entity capacity must fit in u16 indices");
        if (self.max_path_search_nodes < 128 or self.max_path_search_nodes >= std.math.maxInt(u16)) @compileError("path search capacity must fit in non-sentinel u16 indices");
        if (!std.math.isPowerOfTwo(self.max_path_search_nodes)) @compileError("path search capacity must be a power of two");
        if (self.max_path_nodes == 0 or self.max_path_nodes >= std.math.maxInt(u8)) @compileError("retained path length must fit in u8 indices");
        if (!std.math.isPowerOfTwo(self.item_spatial_bucket_count)) @compileError("item_spatial_bucket_count must be a power of two");
    }

    fn verifyStorage(comptime self: Config) void {
        if (self.max_saved_players == 0 or self.max_saved_players > std.math.maxInt(u16)) @compileError("saved player capacity must fit in u16");
        if (self.max_plugin_data_entries == 0 or self.max_plugin_data_entries > std.math.maxInt(u16)) @compileError("plugin data entry capacity must fit in u16");
        if (self.max_plugin_data_bytes == 0) @compileError("plugin data buffers must not be empty");
        if (self.max_plugin_id_bytes == 0) @compileError("plugin ids must not be empty");
        if (self.max_file_resources == 0 or self.max_file_resources > std.math.maxInt(u16)) @compileError("file resource capacity must fit in a completion tag");
        if (!std.math.isPowerOfTwo(self.max_file_resources))
            @compileError("file resource capacity must be a power of two");
        if (self.max_file_resources * 4 > std.math.maxInt(u13))
            @compileError("tick-module storage ring exceeds io_uring entry capacity");
        if (self.max_file_resource_bytes == 0) @compileError("file resource buffers must not be empty");
        if (self.world_directory_path.len == 0 or self.world_chunks_path.len == 0 or self.world_plugins_path.len == 0)
            @compileError("world storage paths must not be empty");
        if (self.max_resource_path_bytes == 0 or self.max_resource_path_bytes > std.math.maxInt(u16)) @compileError("resource paths must fit in u16 lengths");
        if (self.max_cached_chunks == 0) @compileError("max_cached_chunks must be positive");
        if (self.max_cached_chunks >= std.math.maxInt(u16) - 1) @compileError("chunk cache indices must fit in table slot sentinel range");
        if (!std.math.isPowerOfTwo(self.chunk_cache_lookup_slots)) @compileError("chunk_cache_lookup_slots must be a power of two");
        if (self.chunk_cache_lookup_slots < self.max_cached_chunks * 2) @compileError("chunk cache lookup table must keep load factor below 50%");
        if (self.max_username_bytes == 0) @compileError("max_username_bytes must be positive");
        if (self.ticks_per_second == 0) @compileError("ticks_per_second must be positive");
        if (self.keep_alive_interval_ticks == 0) @compileError("keep_alive_interval_ticks must be positive");
        if (self.checkpoint_interval_ticks == 0) @compileError("checkpoint_interval_ticks must be positive");
    }
};

pub const value = Config{};
pub const connection_capacity = value.connectionCapacity();

comptime {
    value.verify();
}

test "tick connection capacity includes status reserve" {
    const small = Config{ .max_players = 1 };
    comptime small.verify();
    try std.testing.expectEqual(
        small.max_players + small.status_connection_reserve,
        small.connectionCapacity(),
    );
}
