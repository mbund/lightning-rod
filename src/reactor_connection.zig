const std = @import("std");
const config = @import("config.zig").value;
const abi = @import("hot_reload_abi.zig");
const crypto = @import("crypto_support.zig");
const virtual_array = @import("virtual_array.zig");

pub const virtual_capacity: usize = std.math.maxInt(u16);

pub const Phase = enum(u8) {
    free,
    handshaking,
    status,
    login,
    configuration,
    play,
};

pub const OutputSegment = struct {
    buffer_index: u16,
    offset: usize = 0,
    len: usize = 0,
};

pub const Connection = struct {
    fd: std.posix.socket_t = -1,
    protocol_number: i32 = 0,
    player_uuid: u128 = 0,
    player_name: [16]u8 = @splat(0),
    player_name_len: u8 = 0,
    generation: u32 = 0,
    phase: Phase = .free,
    in_play_slots: bool = false,
    output_lease_active: bool = false,
    scratch_lease_active: bool = false,
    send_pending: bool = false,
    player_reserved: bool = false,
    reload_transition_pending: bool = false,
    close_after_send: bool = false,
    close_after_send_reason: abi.DisconnectReason = .kicked,
    release_pending: bool = false,
    compression_threshold: ?i32 = null,
    encryptor: ?crypto.Cfb8 = null,
    decryptor: ?crypto.Cfb8 = null,
    read_buffer: [config.player_read_buffer_size]u8 = undefined,
    read_len: usize = 0,
    output_segment_start: usize = 0,
    output_segment_count: usize = 0,
    send_segment_count: usize = 0,
    send_completed_bytes: usize = 0,
    output_lease_segment: usize = 0,
    output_lease_start: usize = 0,
    output_segments: [config.max_client_output_segments]OutputSegment = undefined,
    send_iovecs: [config.max_send_iovecs]std.posix.iovec_const = undefined,
    send_msg: std.os.linux.msghdr_const = undefined,

    pub fn initInPlace(self: *Connection) void {
        self.* = .{};
    }

    pub fn reset(self: *Connection) void {
        const next_generation = self.generation +% 1;
        self.* = .{ .generation = next_generation };
    }

    pub fn hasQueuedOutput(self: *const Connection) bool {
        return self.output_segment_count != 0;
    }

    pub fn outputSegment(self: *Connection, logical_index: usize) *OutputSegment {
        std.debug.assert(logical_index < self.output_segment_count);
        return &self.output_segments[(self.output_segment_start + logical_index) % self.output_segments.len];
    }

    pub fn constOutputSegment(self: *const Connection, logical_index: usize) *const OutputSegment {
        std.debug.assert(logical_index < self.output_segment_count);
        return &self.output_segments[(self.output_segment_start + logical_index) % self.output_segments.len];
    }

    pub fn canReuseSlot(self: *const Connection) bool {
        return self.phase == .free and !self.release_pending and
            !self.send_pending and self.output_segment_count == 0;
    }
};

pub const Table = struct {
    item_storage: virtual_array.Array(Connection),
    play_slot_storage: virtual_array.Array(u16),
    play_position_storage: virtual_array.Array(u16),
    items: []align(64) Connection = &.{},
    play_slots: []u16 = &.{},
    play_positions: []u16 = &.{},
    play_count: usize = 0,
    connected_count: usize = 0,
    reserved_player_count: usize = 0,

    pub fn allocate(self: *Table, _: std.mem.Allocator) !void {
        self.items = &.{};
        self.play_slots = &.{};
        self.play_positions = &.{};
        self.play_count = 0;
        self.connected_count = 0;
        self.reserved_player_count = 0;
        self.item_storage = try virtual_array.Array(Connection).init(virtual_capacity);
        errdefer self.item_storage.deinit();
        self.play_slot_storage = try virtual_array.Array(u16).init(virtual_capacity);
        errdefer self.play_slot_storage.deinit();
        self.play_position_storage = try virtual_array.Array(u16).init(virtual_capacity);
        errdefer self.play_position_storage.deinit();
        try self.ensureCapacity(config.connectionCapacity());
        self.reset();
    }

    pub fn deinit(self: *Table) void {
        self.play_position_storage.deinit();
        self.play_slot_storage.deinit();
        self.item_storage.deinit();
        self.* = undefined;
    }

    pub fn ensurePlayerCapacity(self: *Table, players: usize) !void {
        const capacity = std.math.add(
            usize,
            players,
            config.status_connection_reserve,
        ) catch return error.ConnectionCapacityExceeded;
        try self.ensureCapacity(capacity);
    }

    pub fn committedBytes(self: *const Table) usize {
        return self.item_storage.committedBytes() +
            self.play_slot_storage.committedBytes() +
            self.play_position_storage.committedBytes();
    }

    pub fn shrinkCapacity(self: *Table, capacity: usize) !void {
        if (capacity > self.items.len) return error.ConnectionCapacityCannotGrowByShrinking;
        for (self.items[capacity..]) |*item|
            if (!item.canReuseSlot()) return error.ConnectionCapacityInUse;
        for (self.play_slots[0..self.play_count]) |slot|
            if (slot >= capacity) return error.ConnectionCapacityInUse;
        const items = try self.item_storage.shrink(capacity);
        const play_slots = try self.play_slot_storage.shrink(capacity);
        const play_positions = try self.play_position_storage.shrink(capacity);
        self.items = @alignCast(items);
        self.play_slots = play_slots;
        self.play_positions = play_positions;
    }

    fn ensureCapacity(self: *Table, capacity: usize) !void {
        if (capacity > virtual_capacity) return error.ConnectionCapacityExceeded;
        const previous = self.items.len;
        errdefer {
            _ = self.item_storage.shrink(previous) catch
                @panic("failed to roll back connection storage growth");
            _ = self.play_slot_storage.shrink(previous) catch
                @panic("failed to roll back play-slot storage growth");
            _ = self.play_position_storage.shrink(previous) catch
                @panic("failed to roll back play-position storage growth");
        }
        const items = try self.item_storage.ensure(capacity);
        const play_slots = try self.play_slot_storage.ensure(capacity);
        const play_positions = try self.play_position_storage.ensure(capacity);
        self.items = @alignCast(items);
        self.play_slots = play_slots;
        self.play_positions = play_positions;
        for (self.items[previous..]) |*item| item.initInPlace();
    }

    pub fn reset(self: *Table) void {
        for (self.items) |*item| item.initInPlace();
        self.play_count = 0;
        self.connected_count = 0;
        self.reserved_player_count = 0;
    }

    pub fn handle(self: *const Table, slot: u16) abi.ConnectionHandle {
        return .{ .index = slot, .generation = self.items[slot].generation };
    }

    pub fn lookup(self: *const Table, handle_value: abi.ConnectionHandle) ?usize {
        const index: usize = handle_value.index;
        if (index >= self.items.len) return null;
        const item = &self.items[index];
        if (item.phase == .free or item.generation != handle_value.generation)
            return null;
        return index;
    }

    pub fn freeSlot(self: *Table) ?usize {
        for (self.items, 0..) |*item, index|
            if (item.canReuseSlot()) return index;
        return null;
    }

    pub fn markPlaying(self: *Table, slot: u16) void {
        const item = &self.items[slot];
        if (item.in_play_slots) return;
        std.debug.assert(item.phase == .play);
        std.debug.assert(self.play_count < self.play_slots.len);
        self.play_slots[self.play_count] = slot;
        self.play_positions[slot] = @intCast(self.play_count);
        item.in_play_slots = true;
        self.play_count += 1;
    }

    pub fn removePlaying(self: *Table, slot: u16) void {
        const item = &self.items[slot];
        if (!item.in_play_slots) return;
        const position = self.play_positions[slot];
        std.debug.assert(position < self.play_count);
        std.debug.assert(self.play_slots[position] == slot);
        self.play_count -= 1;
        const moved = self.play_slots[self.play_count];
        self.play_slots[position] = moved;
        self.play_positions[moved] = position;
        item.in_play_slots = false;
    }

    pub fn playing(self: *const Table) []const u16 {
        return self.play_slots[0..self.play_count];
    }

    pub fn release(self: *Table, handle_value: abi.ConnectionHandle) void {
        const slot: usize = handle_value.index;
        if (slot >= self.items.len) return;
        const item = &self.items[slot];
        if (item.generation != handle_value.generation or
            !item.release_pending)
            return;
        if (item.player_reserved) {
            std.debug.assert(self.reserved_player_count != 0);
            self.reserved_player_count -= 1;
            item.player_reserved = false;
        }
        item.release_pending = false;
        if (!item.send_pending and item.output_segment_count == 0) item.reset();
    }

    pub fn reservePlayer(
        self: *Table,
        handle_value: abi.ConnectionHandle,
        player_uuid: u128,
        name: [16]u8,
        name_len: u8,
    ) void {
        const slot = self.lookup(handle_value) orelse return;
        const item = &self.items[slot];
        if (item.player_reserved) return;
        item.player_reserved = true;
        item.player_uuid = player_uuid;
        item.player_name = name;
        item.player_name_len = name_len;
        self.reserved_player_count += 1;
    }

    pub fn enterConfiguration(self: *Table, handle_value: abi.ConnectionHandle) ?u16 {
        const slot = self.lookup(handle_value) orelse return null;
        if (self.items[slot].phase != .login and self.items[slot].phase != .play)
            return null;
        self.removePlaying(@intCast(slot));
        self.items[slot].phase = .configuration;
        self.items[slot].reload_transition_pending = false;
        return @intCast(slot);
    }

    pub fn enterPlay(self: *Table, handle_value: abi.ConnectionHandle) ?u16 {
        const slot = self.lookup(handle_value) orelse return null;
        if (self.items[slot].phase != .configuration) return null;
        self.items[slot].phase = .play;
        self.markPlaying(@intCast(slot));
        return @intCast(slot);
    }

    pub fn selectProtocol(
        self: *Table,
        handle_value: abi.ConnectionHandle,
        protocol_number: i32,
        intent: u8,
    ) ?u16 {
        const slot = self.lookup(handle_value) orelse return null;
        const item = &self.items[slot];
        if (item.phase != .handshaking) return null;
        item.protocol_number = protocol_number;
        item.phase = switch (intent) {
            1 => .status,
            2 => .login,
            else => return null,
        };
        return @intCast(slot);
    }
};

test "reset preserves storage and advances generation" {
    var connection: Connection = .{};
    connection.phase = .play;
    connection.reset();
    try std.testing.expectEqual(Phase.free, connection.phase);
    try std.testing.expectEqual(@as(u32, 1), connection.generation);
}

test "connection table grows without moving existing slots" {
    var table: Table = undefined;
    try table.allocate(std.testing.allocator);
    defer table.deinit();
    const address = @intFromPtr(table.items.ptr);
    table.items[0].generation = 19;
    try table.ensurePlayerCapacity(config.max_players + 17);
    try std.testing.expectEqual(address, @intFromPtr(table.items.ptr));
    try std.testing.expectEqual(@as(u32, 19), table.items[0].generation);
    try table.shrinkCapacity(config.connectionCapacity());
    try std.testing.expectEqual(config.connectionCapacity(), table.items.len);
    try std.testing.expectEqual(address, @intFromPtr(table.items.ptr));
}
