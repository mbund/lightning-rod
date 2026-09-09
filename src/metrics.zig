const std = @import("std");

pub const Plugin = struct {
    id_ptr: [*]const u8 = "".ptr,
    id_len: usize = 0,
    total_ns: u64 = 0,
    window_ns: u64 = 0,
    window_max_ns: u64 = 0,
    last_ns: u64 = 0,
    max_ns: u64 = 0,
    generation_bytes: u64 = 0,
    tick_memory_total_bytes: u64 = 0,
    tick_memory_window_bytes: u64 = 0,
    tick_memory_last_bytes: u64 = 0,
    tick_memory_max_bytes: u64 = 0,

    pub fn id(self: Plugin) []const u8 {
        return self.id_ptr[0..self.id_len];
    }
};

pub const Trace = struct {
    plugin_index: usize = 0,
    name_ptr: [*]const u8 = "".ptr,
    name_len: usize = 0,
    total_ns: u64 = 0,
    window_ns: u64 = 0,
    last_ns: u64 = 0,
    max_ns: u64 = 0,
    total_calls: u64 = 0,
    window_calls: u64 = 0,
    last_calls: u32 = 0,
    max_calls: u32 = 0,

    pub fn name(self: Trace) []const u8 {
        return self.name_ptr[0..self.name_len];
    }
};

pub const Snapshot = struct {
    revision: u64 = 0,
    tick_count: u64 = 0,
    tick_total_ns: u64 = 0,
    tick_window_ns: u64 = 0,
    tick_window_max_ns: u64 = 0,
    tick_last_ns: u64 = 0,
    tick_max_ns: u64 = 0,
    window_count: usize = 0,
    plugin_count: usize = 0,
    plugins: []Plugin = &.{},
    trace_count: usize = 0,
    traces: []Trace = &.{},
    world_tick: u64 = 0,
    living_entities: usize = 0,
    item_entities: usize = 0,
    players: usize = 0,
    player_capacity: usize = 0,
    connections: usize = 0,
    backpressured_connections: usize = 0,
    network_output_bytes: u64 = 0,
    network_output_capacity_bytes: u64 = 0,
    session_exchange_messages: usize = 0,
    session_direct_payload_bytes: u64 = 0,
    session_copied_payload_bytes: u64 = 0,
    session_fanout_payload_bytes: u64 = 0,
    session_fanout_deliveries: u64 = 0,
    session_prepared_frames: usize = 0,
    session_prepared_bytes: u64 = 0,
    session_delivery_bytes: u64 = 0,
    session_prepared_copy_bytes: u64 = 0,
    session_transport_direct_bytes: u64 = 0,
    session_transport_fallback_copy_bytes: u64 = 0,
    transient_chunks: usize = 0,
    transient_chunk_capacity: usize = 0,
    modified_sections: usize = 0,
    modified_section_capacity: usize = 0,
    modified_blocks: usize = 0,
    pending_terrain_chunks: usize = 0,
    gameplay_tickets: usize = 0,
    gameplay_ticket_capacity: usize = 0,
    admitted_chunks: usize = 0,
    admission_capacity: usize = 0,
    admission_transitions: usize = 0,
    admission_overflow: bool = false,
    projected_chunks: usize = 0,
    projected_chunk_capacity: usize = 0,
    projection_masks: usize = 0,
    projection_mask_capacity: usize = 0,
    projection_state_pages: usize = 0,
    projection_state_page_capacity: usize = 0,
    projection_overflow: bool = false,
    collision_chunks: usize = 0,
    collision_chunk_capacity: usize = 0,
    collision_exceptions: usize = 0,
    collision_exception_capacity: usize = 0,
    collision_fluid_spans: usize = 0,
    collision_fluid_span_capacity: usize = 0,
    collision_incomplete_chunks: usize = 0,
    collision_masks: usize = 0,
    collision_mask_capacity: usize = 0,
    deferred_block_inputs: usize = 0,
    deferred_dig_inputs: usize = 0,
    lighting_chunks: usize = 0,
    lighting_chunk_capacity: usize = 0,
    lighting_pages: usize = 0,
    lighting_page_capacity: usize = 0,
    memory_limit_bytes: u64 = 0,
    memory_planned_bytes: u64 = 0,
    resident_set_bytes: u64 = 0,
    memory_capacity_bytes: u64 = 0,
    generation_memory_bytes: u64 = 0,
    tick_memory_capacity_bytes: u64 = 0,
    host_memory_bytes: u64 = 0,
    transport_memory_bytes: u64 = 0,
    sessions_memory_bytes: u64 = 0,
    persistence_memory_bytes: u64 = 0,
    reload_memory_bytes: u64 = 0,
    reload_transition_bytes: u64 = 0,
    logging_memory_bytes: u64 = 0,
    materialization_free: usize = 0,
    materialization_reading: usize = 0,
    materialization_request_waiting: usize = 0,
    materialization_generating: usize = 0,
    materialization_dirty: usize = 0,
    materialization_read_capacity: usize = 0,
    materialization_generation_capacity: usize = 0,
    materialization_memory_bytes: u64 = 0,
    materialization_read_bytes: u64 = 0,
    materialization_read_byte_capacity: u64 = 0,
    materialization_read_hits: u64 = 0,
    materialization_read_misses: u64 = 0,
    materialization_generated: u64 = 0,
    materialization_persisted: u64 = 0,
    materialization_exact_reads: u64 = 0,
    materialization_exact_loader_reads: u64 = 0,
    materialization_exact_read_nanoseconds: u64 = 0,
    persistence_keys: usize = 0,
    persistence_key_capacity: usize = 0,
    persistence_read_submissions: u64 = 0,
    persistence_read_completions: u64 = 0,
    persistence_read_bytes: u64 = 0,
    persistence_write_submissions: u64 = 0,
    persistence_write_completions: u64 = 0,
    persistence_write_bytes: u64 = 0,
    disk_index_page_reads: u64 = 0,
    disk_index_cache_hits: u64 = 0,
    disk_index_pending_hits: u64 = 0,
    disk_index_page_writes: u64 = 0,
    disk_index_written_pages: u64 = 0,
    disk_index_cache_pages: usize = 0,
    disk_index_cache_capacity: usize = 0,
    persistence_submit_calls: u64 = 0,
    interval_ticks: u64 = 0,
    interval_session_direct_bytes: u64 = 0,
    interval_session_copied_bytes: u64 = 0,
    interval_session_fanout_bytes: u64 = 0,
    interval_session_prepared_copy_bytes: u64 = 0,
    interval_session_transport_direct_bytes: u64 = 0,
    interval_session_transport_fallback_copy_bytes: u64 = 0,
    interval_persistence_read_bytes: u64 = 0,
    interval_persistence_read_completions: u64 = 0,
    interval_persistence_write_bytes: u64 = 0,
    interval_persistence_write_completions: u64 = 0,
    interval_persistence_submit_calls: u64 = 0,
};

pub const Runtime = struct {
    memory_limit_bytes: std.atomic.Value(u64) = .init(0),
    memory_planned_bytes: std.atomic.Value(u64) = .init(0),
    resident_set_bytes: std.atomic.Value(u64) = .init(0),
    host_memory_bytes: std.atomic.Value(u64) = .init(0),
    transport_memory_bytes: std.atomic.Value(u64) = .init(0),
    sessions_memory_bytes: std.atomic.Value(u64) = .init(0),
    persistence_memory_bytes: std.atomic.Value(u64) = .init(0),
    reload_memory_bytes: std.atomic.Value(u64) = .init(0),
    reload_transition_bytes: std.atomic.Value(u64) = .init(0),
    logging_memory_bytes: std.atomic.Value(u64) = .init(0),
    materialization_free: std.atomic.Value(u64) = .init(0),
    materialization_reading: std.atomic.Value(u64) = .init(0),
    materialization_request_waiting: std.atomic.Value(u64) = .init(0),
    materialization_generating: std.atomic.Value(u64) = .init(0),
    materialization_dirty: std.atomic.Value(u64) = .init(0),
    materialization_read_capacity: std.atomic.Value(u64) = .init(0),
    materialization_generation_capacity: std.atomic.Value(u64) = .init(0),
    materialization_memory_bytes: std.atomic.Value(u64) = .init(0),
    materialization_read_bytes: std.atomic.Value(u64) = .init(0),
    materialization_read_byte_capacity: std.atomic.Value(u64) = .init(0),
    materialization_read_hits: std.atomic.Value(u64) = .init(0),
    materialization_read_misses: std.atomic.Value(u64) = .init(0),
    materialization_generated: std.atomic.Value(u64) = .init(0),
    materialization_persisted: std.atomic.Value(u64) = .init(0),
    materialization_exact_reads: std.atomic.Value(u64) = .init(0),
    materialization_exact_loader_reads: std.atomic.Value(u64) = .init(0),
    materialization_exact_read_nanoseconds: std.atomic.Value(u64) = .init(0),
    persistence_keys: std.atomic.Value(u64) = .init(0),
    persistence_key_capacity: std.atomic.Value(u64) = .init(0),
    connections: std.atomic.Value(u64) = .init(0),
    backpressured_connections: std.atomic.Value(u64) = .init(0),
    network_output_bytes: std.atomic.Value(u64) = .init(0),
    network_output_capacity_bytes: std.atomic.Value(u64) = .init(0),
    session_exchange_messages: std.atomic.Value(u64) = .init(0),
    session_direct_payload_bytes: std.atomic.Value(u64) = .init(0),
    session_copied_payload_bytes: std.atomic.Value(u64) = .init(0),
    session_fanout_payload_bytes: std.atomic.Value(u64) = .init(0),
    session_fanout_deliveries: std.atomic.Value(u64) = .init(0),
    session_prepared_frames: std.atomic.Value(u64) = .init(0),
    session_prepared_bytes: std.atomic.Value(u64) = .init(0),
    session_delivery_bytes: std.atomic.Value(u64) = .init(0),
    session_prepared_copy_bytes: std.atomic.Value(u64) = .init(0),
    session_transport_direct_bytes: std.atomic.Value(u64) = .init(0),
    session_transport_fallback_copy_bytes: std.atomic.Value(u64) = .init(0),
    gameplay_tickets: std.atomic.Value(u64) = .init(0),
    gameplay_ticket_capacity: std.atomic.Value(u64) = .init(0),
    admitted_chunks: std.atomic.Value(u64) = .init(0),
    admission_capacity: std.atomic.Value(u64) = .init(0),
    admission_transitions: std.atomic.Value(u64) = .init(0),
    admission_overflow: std.atomic.Value(u64) = .init(0),
    projected_chunks: std.atomic.Value(u64) = .init(0),
    projected_chunk_capacity: std.atomic.Value(u64) = .init(0),
    projection_masks: std.atomic.Value(u64) = .init(0),
    projection_mask_capacity: std.atomic.Value(u64) = .init(0),
    projection_state_pages: std.atomic.Value(u64) = .init(0),
    projection_state_page_capacity: std.atomic.Value(u64) = .init(0),
    projection_overflow: std.atomic.Value(u64) = .init(0),
    collision_chunks: std.atomic.Value(u64) = .init(0),
    collision_chunk_capacity: std.atomic.Value(u64) = .init(0),
    collision_exceptions: std.atomic.Value(u64) = .init(0),
    collision_exception_capacity: std.atomic.Value(u64) = .init(0),
    collision_fluid_spans: std.atomic.Value(u64) = .init(0),
    collision_fluid_span_capacity: std.atomic.Value(u64) = .init(0),
    collision_incomplete_chunks: std.atomic.Value(u64) = .init(0),
    collision_masks: std.atomic.Value(u64) = .init(0),
    collision_mask_capacity: std.atomic.Value(u64) = .init(0),
    deferred_block_inputs: std.atomic.Value(u64) = .init(0),
    deferred_dig_inputs: std.atomic.Value(u64) = .init(0),
    lighting_chunks: std.atomic.Value(u64) = .init(0),
    lighting_chunk_capacity: std.atomic.Value(u64) = .init(0),
    lighting_pages: std.atomic.Value(u64) = .init(0),
    lighting_page_capacity: std.atomic.Value(u64) = .init(0),
    persistence_read_submissions: std.atomic.Value(u64) = .init(0),
    persistence_read_completions: std.atomic.Value(u64) = .init(0),
    persistence_read_bytes: std.atomic.Value(u64) = .init(0),
    persistence_write_submissions: std.atomic.Value(u64) = .init(0),
    persistence_write_completions: std.atomic.Value(u64) = .init(0),
    persistence_write_bytes: std.atomic.Value(u64) = .init(0),
    persistence_submit_calls: std.atomic.Value(u64) = .init(0),
    disk_index_page_reads: std.atomic.Value(u64) = .init(0),
    disk_index_cache_hits: std.atomic.Value(u64) = .init(0),
    disk_index_pending_hits: std.atomic.Value(u64) = .init(0),
    disk_index_page_writes: std.atomic.Value(u64) = .init(0),
    disk_index_written_pages: std.atomic.Value(u64) = .init(0),
    disk_index_cache_pages: std.atomic.Value(u64) = .init(0),
    disk_index_cache_capacity: std.atomic.Value(u64) = .init(0),

    pub const Memory = struct {
        limit: usize,
        planned: usize,
        host: usize,
        transport: usize,
        sessions: usize,
        persistence: usize,
        reload: usize,
        reload_transition: usize,
        logging: usize,
    };

    pub fn setMemory(self: *Runtime, value: Memory) void {
        self.memory_limit_bytes.store(@intCast(value.limit), .release);
        self.memory_planned_bytes.store(@intCast(value.planned), .release);
        self.host_memory_bytes.store(@intCast(value.host), .release);
        self.transport_memory_bytes.store(@intCast(value.transport), .release);
        self.sessions_memory_bytes.store(@intCast(value.sessions), .release);
        self.persistence_memory_bytes.store(@intCast(value.persistence), .release);
        self.reload_memory_bytes.store(@intCast(value.reload), .release);
        self.reload_transition_bytes.store(@intCast(value.reload_transition), .release);
        self.logging_memory_bytes.store(@intCast(value.logging), .release);
    }

    pub fn apply(self: *const Runtime, snapshot: *Snapshot) void {
        snapshot.memory_limit_bytes = self.memory_limit_bytes.load(.acquire);
        snapshot.memory_planned_bytes = self.memory_planned_bytes.load(.acquire);
        snapshot.resident_set_bytes = self.resident_set_bytes.load(.acquire);
        snapshot.host_memory_bytes = self.host_memory_bytes.load(.acquire);
        snapshot.transport_memory_bytes = self.transport_memory_bytes.load(.acquire);
        snapshot.sessions_memory_bytes = self.sessions_memory_bytes.load(.acquire);
        snapshot.persistence_memory_bytes = self.persistence_memory_bytes.load(.acquire);
        snapshot.reload_memory_bytes = self.reload_memory_bytes.load(.acquire);
        snapshot.reload_transition_bytes = self.reload_transition_bytes.load(.acquire);
        snapshot.logging_memory_bytes = self.logging_memory_bytes.load(.acquire);
        snapshot.materialization_free = @intCast(self.materialization_free.load(.acquire));
        snapshot.materialization_reading = @intCast(self.materialization_reading.load(.acquire));
        snapshot.materialization_request_waiting = @intCast(self.materialization_request_waiting.load(.acquire));
        snapshot.materialization_generating = @intCast(self.materialization_generating.load(.acquire));
        snapshot.materialization_dirty = @intCast(self.materialization_dirty.load(.acquire));
        snapshot.materialization_read_capacity = @intCast(self.materialization_read_capacity.load(.acquire));
        snapshot.materialization_generation_capacity = @intCast(self.materialization_generation_capacity.load(.acquire));
        snapshot.materialization_memory_bytes = self.materialization_memory_bytes.load(.acquire);
        snapshot.materialization_read_bytes = self.materialization_read_bytes.load(.acquire);
        snapshot.materialization_read_byte_capacity = self.materialization_read_byte_capacity.load(.acquire);
        snapshot.materialization_read_hits = self.materialization_read_hits.load(.acquire);
        snapshot.materialization_read_misses = self.materialization_read_misses.load(.acquire);
        snapshot.materialization_generated = self.materialization_generated.load(.acquire);
        snapshot.materialization_persisted = self.materialization_persisted.load(.acquire);
        snapshot.materialization_exact_reads = self.materialization_exact_reads.load(.acquire);
        snapshot.materialization_exact_loader_reads = self.materialization_exact_loader_reads.load(.acquire);
        snapshot.materialization_exact_read_nanoseconds = self.materialization_exact_read_nanoseconds.load(.acquire);
        snapshot.persistence_keys = @intCast(self.persistence_keys.load(.acquire));
        snapshot.persistence_key_capacity = @intCast(self.persistence_key_capacity.load(.acquire));
        snapshot.connections = @intCast(self.connections.load(.acquire));
        snapshot.backpressured_connections = @intCast(self.backpressured_connections.load(.acquire));
        snapshot.network_output_bytes = self.network_output_bytes.load(.acquire);
        snapshot.network_output_capacity_bytes = self.network_output_capacity_bytes.load(.acquire);
        snapshot.session_exchange_messages = @intCast(self.session_exchange_messages.load(.acquire));
        snapshot.session_direct_payload_bytes = self.session_direct_payload_bytes.load(.acquire);
        snapshot.session_copied_payload_bytes = self.session_copied_payload_bytes.load(.acquire);
        snapshot.session_fanout_payload_bytes = self.session_fanout_payload_bytes.load(.acquire);
        snapshot.session_fanout_deliveries = self.session_fanout_deliveries.load(.acquire);
        snapshot.session_prepared_frames = @intCast(self.session_prepared_frames.load(.acquire));
        snapshot.session_prepared_bytes = self.session_prepared_bytes.load(.acquire);
        snapshot.session_delivery_bytes = self.session_delivery_bytes.load(.acquire);
        snapshot.session_prepared_copy_bytes = self.session_prepared_copy_bytes.load(.acquire);
        snapshot.session_transport_direct_bytes = self.session_transport_direct_bytes.load(.acquire);
        snapshot.session_transport_fallback_copy_bytes = self.session_transport_fallback_copy_bytes.load(.acquire);
        snapshot.gameplay_tickets = @intCast(self.gameplay_tickets.load(.acquire));
        snapshot.gameplay_ticket_capacity = @intCast(self.gameplay_ticket_capacity.load(.acquire));
        snapshot.admitted_chunks = @intCast(self.admitted_chunks.load(.acquire));
        snapshot.admission_capacity = @intCast(self.admission_capacity.load(.acquire));
        snapshot.admission_transitions = @intCast(self.admission_transitions.load(.acquire));
        snapshot.admission_overflow = self.admission_overflow.load(.acquire) != 0;
        snapshot.projected_chunks = @intCast(self.projected_chunks.load(.acquire));
        snapshot.projected_chunk_capacity = @intCast(self.projected_chunk_capacity.load(.acquire));
        snapshot.projection_masks = @intCast(self.projection_masks.load(.acquire));
        snapshot.projection_mask_capacity = @intCast(self.projection_mask_capacity.load(.acquire));
        snapshot.projection_state_pages = @intCast(self.projection_state_pages.load(.acquire));
        snapshot.projection_state_page_capacity = @intCast(self.projection_state_page_capacity.load(.acquire));
        snapshot.projection_overflow = self.projection_overflow.load(.acquire) != 0;
        snapshot.collision_chunks = @intCast(self.collision_chunks.load(.acquire));
        snapshot.collision_chunk_capacity = @intCast(self.collision_chunk_capacity.load(.acquire));
        snapshot.collision_exceptions = @intCast(self.collision_exceptions.load(.acquire));
        snapshot.collision_exception_capacity = @intCast(self.collision_exception_capacity.load(.acquire));
        snapshot.collision_fluid_spans = @intCast(self.collision_fluid_spans.load(.acquire));
        snapshot.collision_fluid_span_capacity = @intCast(self.collision_fluid_span_capacity.load(.acquire));
        snapshot.collision_incomplete_chunks = @intCast(self.collision_incomplete_chunks.load(.acquire));
        snapshot.collision_masks = @intCast(self.collision_masks.load(.acquire));
        snapshot.collision_mask_capacity = @intCast(self.collision_mask_capacity.load(.acquire));
        snapshot.deferred_block_inputs = @intCast(self.deferred_block_inputs.load(.acquire));
        snapshot.deferred_dig_inputs = @intCast(self.deferred_dig_inputs.load(.acquire));
        snapshot.lighting_chunks = @intCast(self.lighting_chunks.load(.acquire));
        snapshot.lighting_chunk_capacity = @intCast(self.lighting_chunk_capacity.load(.acquire));
        snapshot.lighting_pages = @intCast(self.lighting_pages.load(.acquire));
        snapshot.lighting_page_capacity = @intCast(self.lighting_page_capacity.load(.acquire));
        snapshot.persistence_read_submissions = self.persistence_read_submissions.load(.acquire);
        snapshot.persistence_read_completions = self.persistence_read_completions.load(.acquire);
        snapshot.persistence_read_bytes = self.persistence_read_bytes.load(.acquire);
        snapshot.persistence_write_submissions = self.persistence_write_submissions.load(.acquire);
        snapshot.persistence_write_completions = self.persistence_write_completions.load(.acquire);
        snapshot.persistence_write_bytes = self.persistence_write_bytes.load(.acquire);
        snapshot.persistence_submit_calls = self.persistence_submit_calls.load(.acquire);
        snapshot.disk_index_page_reads = self.disk_index_page_reads.load(.acquire);
        snapshot.disk_index_cache_hits = self.disk_index_cache_hits.load(.acquire);
        snapshot.disk_index_pending_hits = self.disk_index_pending_hits.load(.acquire);
        snapshot.disk_index_page_writes = self.disk_index_page_writes.load(.acquire);
        snapshot.disk_index_written_pages = self.disk_index_written_pages.load(.acquire);
        snapshot.disk_index_cache_pages = @intCast(self.disk_index_cache_pages.load(.acquire));
        snapshot.disk_index_cache_capacity = @intCast(self.disk_index_cache_capacity.load(.acquire));
    }

    pub fn setPersistenceKeys(self: *Runtime, count: usize, capacity: usize) void {
        self.persistence_keys.store(@intCast(count), .release);
        self.persistence_key_capacity.store(@intCast(capacity), .release);
    }

    pub fn setDiskIndex(
        self: *Runtime,
        page_reads: u64,
        cache_hits: u64,
        pending_hits: u64,
        page_writes: u64,
        written_pages: u64,
        cache_pages: usize,
        cache_capacity: usize,
    ) void {
        self.disk_index_page_reads.store(page_reads, .release);
        self.disk_index_cache_hits.store(cache_hits, .release);
        self.disk_index_pending_hits.store(pending_hits, .release);
        self.disk_index_page_writes.store(page_writes, .release);
        self.disk_index_written_pages.store(written_pages, .release);
        self.disk_index_cache_pages.store(@intCast(cache_pages), .release);
        self.disk_index_cache_capacity.store(@intCast(cache_capacity), .release);
    }

    pub fn setResidentSet(self: *Runtime, bytes: usize) void {
        self.resident_set_bytes.store(@intCast(bytes), .release);
    }

    pub fn setSessions(self: *Runtime, connections: usize, backpressured: usize, queued: usize, capacity: usize) void {
        self.connections.store(@intCast(connections), .release);
        self.backpressured_connections.store(@intCast(backpressured), .release);
        self.network_output_bytes.store(@intCast(queued), .release);
        self.network_output_capacity_bytes.store(@intCast(capacity), .release);
    }

    pub fn setSessionExchange(self: *Runtime, messages: usize, direct: u64, copied: u64, fanout: u64, deliveries: u64) void {
        self.session_exchange_messages.store(@intCast(messages), .release);
        self.session_direct_payload_bytes.store(direct, .release);
        self.session_copied_payload_bytes.store(copied, .release);
        self.session_fanout_payload_bytes.store(fanout, .release);
        self.session_fanout_deliveries.store(deliveries, .release);
    }

    pub fn setSessionCopies(self: *Runtime, prepared: u64, direct: u64, fallback: u64) void {
        self.session_prepared_copy_bytes.store(prepared, .release);
        self.session_transport_direct_bytes.store(direct, .release);
        self.session_transport_fallback_copy_bytes.store(fallback, .release);
    }

    pub fn setSessionQueue(self: *Runtime, frames: usize, prepared: usize, deliveries: usize) void {
        self.session_prepared_frames.store(@intCast(frames), .release);
        self.session_prepared_bytes.store(@intCast(prepared), .release);
        self.session_delivery_bytes.store(@intCast(deliveries), .release);
    }

    pub fn setGameplayTickets(self: *Runtime, count: usize, capacity: usize) void {
        self.gameplay_tickets.store(@intCast(count), .release);
        self.gameplay_ticket_capacity.store(@intCast(capacity), .release);
    }

    pub fn setSimulationAdmission(self: *Runtime, admitted: usize, capacity: usize, transitions: usize, overflow: bool) void {
        self.admitted_chunks.store(@intCast(admitted), .release);
        self.admission_capacity.store(@intCast(capacity), .release);
        self.admission_transitions.store(@intCast(transitions), .release);
        self.admission_overflow.store(@intFromBool(overflow), .release);
    }

    pub fn setWorldProjections(self: *Runtime, chunks: usize, chunk_capacity: usize, masks: usize, mask_capacity: usize, state_pages: usize, state_page_capacity: usize, overflow: bool) void {
        self.projected_chunks.store(@intCast(chunks), .release);
        self.projected_chunk_capacity.store(@intCast(chunk_capacity), .release);
        self.projection_masks.store(@intCast(masks), .release);
        self.projection_mask_capacity.store(@intCast(mask_capacity), .release);
        self.projection_state_pages.store(@intCast(state_pages), .release);
        self.projection_state_page_capacity.store(@intCast(state_page_capacity), .release);
        self.projection_overflow.store(@intFromBool(overflow), .release);
    }

    pub fn setLightingProjections(self: *Runtime, chunks: usize, chunk_capacity: usize, pages: usize, page_capacity: usize) void {
        self.lighting_chunks.store(@intCast(chunks), .release);
        self.lighting_chunk_capacity.store(@intCast(chunk_capacity), .release);
        self.lighting_pages.store(@intCast(pages), .release);
        self.lighting_page_capacity.store(@intCast(page_capacity), .release);
    }

    pub fn setCollisionProjections(self: *Runtime, chunks: usize, chunk_capacity: usize, exceptions: usize, exception_capacity: usize, fluid_spans: usize, fluid_span_capacity: usize, incomplete_chunks: usize, masks: usize, mask_capacity: usize) void {
        self.collision_chunks.store(@intCast(chunks), .release);
        self.collision_chunk_capacity.store(@intCast(chunk_capacity), .release);
        self.collision_exceptions.store(@intCast(exceptions), .release);
        self.collision_exception_capacity.store(@intCast(exception_capacity), .release);
        self.collision_fluid_spans.store(@intCast(fluid_spans), .release);
        self.collision_fluid_span_capacity.store(@intCast(fluid_span_capacity), .release);
        self.collision_incomplete_chunks.store(@intCast(incomplete_chunks), .release);
        self.collision_masks.store(@intCast(masks), .release);
        self.collision_mask_capacity.store(@intCast(mask_capacity), .release);
    }

    pub fn setDeferredInputs(self: *Runtime, blocks: usize, digs: usize) void {
        self.deferred_block_inputs.store(@intCast(blocks), .release);
        self.deferred_dig_inputs.store(@intCast(digs), .release);
    }

    pub fn setMaterialization(
        self: *Runtime,
        free: usize,
        reading: usize,
        request_waiting: usize,
        generating: usize,
        dirty: usize,
        read_capacity: usize,
        generation_capacity: usize,
        memory_bytes: usize,
        read_bytes: usize,
        read_byte_capacity: usize,
        read_hits: u64,
        read_misses: u64,
        generated: u64,
        persisted: u64,
        exact_reads: u64,
        exact_loader_reads: u64,
        exact_read_nanoseconds: u64,
    ) void {
        self.materialization_free.store(@intCast(free), .release);
        self.materialization_reading.store(@intCast(reading), .release);
        self.materialization_request_waiting.store(@intCast(request_waiting), .release);
        self.materialization_generating.store(@intCast(generating), .release);
        self.materialization_dirty.store(@intCast(dirty), .release);
        self.materialization_read_capacity.store(@intCast(read_capacity), .release);
        self.materialization_generation_capacity.store(@intCast(generation_capacity), .release);
        self.materialization_memory_bytes.store(@intCast(memory_bytes), .release);
        self.materialization_read_bytes.store(@intCast(read_bytes), .release);
        self.materialization_read_byte_capacity.store(@intCast(read_byte_capacity), .release);
        self.materialization_read_hits.store(read_hits, .release);
        self.materialization_read_misses.store(read_misses, .release);
        self.materialization_generated.store(generated, .release);
        self.materialization_persisted.store(persisted, .release);
        self.materialization_exact_reads.store(exact_reads, .release);
        self.materialization_exact_loader_reads.store(exact_loader_reads, .release);
        self.materialization_exact_read_nanoseconds.store(exact_read_nanoseconds, .release);
    }
};
