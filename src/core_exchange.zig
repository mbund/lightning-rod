const geometry = @import("world/geometry.zig");
const connection = @import("connection_api.zig");
const std = @import("std");
const world_identity = @import("world/identity.zig");

pub const Phase = enum(u8) { handshake, status, login, configuration, play };

pub const InputAdmission = enum { accepted, full };
pub const Text = struct { offset: u32, len: u16 };

pub const Input = union(enum) {
    teleport_confirm: struct { player: u16, id: i32 },
    movement: struct {
        player: u16,
        position: ?geometry.Vec3,
        rotation: ?geometry.Rotation,
        on_ground: bool,
    },
    player_input: struct { player: u16, shift: bool, sprint: bool },
    sprint: struct { player: u16, sprinting: bool },
    dig: DigInput,
    place: PlaceInput,
    held_item: struct { player: u16, selected: i16 },
    keep_alive_response: struct { player: u16, id: i64 },
    chunk_batch_received: struct { player: u16, chunks_per_tick: f32 },
    player_loaded: struct { player: u16 },
    chat: struct { player: u16, text: Text },
    command: struct { player: u16, text: Text },
    arm_animation: struct { player: u16, hand: i32 },
    attack_entity: struct { player: u16, entity_id: i32 },
    interact_entity: struct { player: u16, entity_id: i32, hand: i32 },
    respawn: struct { player: u16 },
    use_item: struct { player: u16, hand: i32, sequence: i32, rotation: geometry.Rotation },
    window_click: WindowClickInput,
    creative_slot: CreativeSlotInput,
    close_window: struct { player: u16, window_id: i32 },
};

pub const DigInput = struct { player: u16, status: i32, position: geometry.BlockPos, face: i32, sequence: i32 };
pub const PlaceKind = enum(u8) { break_block, use_item_on };
pub const PlaceInput = struct {
    world: world_identity.Handle,
    player: u16,
    kind: PlaceKind,
    position: geometry.BlockPos,
    against_position: geometry.BlockPos,
    face: i32,
    cursor: struct { x: f32, y: f32, z: f32 },
    sequence: i32,
};
pub const WindowClickInput = struct {
    player: u16,
    window_id: i32,
    state_id: i32,
    protocol_slot: i16,
    mouse_button: i8,
    mode: i32,
};
pub const CreativeSlotInput = struct { player: u16, inventory_slot: i16, item_id: i32, count: u8 };

pub const InputBatch = struct {
    records: []Input,
    count: usize = 0,
    bytes: []u8,
    byte_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, byte_capacity: usize) !InputBatch {
        if (capacity == 0 or byte_capacity == 0) return error.InvalidCapacity;
        const records = try allocator.alloc(Input, capacity);
        errdefer allocator.free(records);
        return .{ .records = records, .bytes = try allocator.alloc(u8, byte_capacity) };
    }

    pub fn deinit(self: *InputBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn clear(self: *InputBatch) void {
        self.count = 0;
        self.byte_count = 0;
    }

    pub fn append(self: *InputBatch, input: Input) InputAdmission {
        if (self.count == self.records.len) return .full;
        self.records[self.count] = input;
        self.count += 1;
        return .accepted;
    }

    pub fn items(self: *const InputBatch) []const Input {
        return self.records[0..self.count];
    }

    pub fn copyText(self: *InputBatch, value: []const u8) error{ByteFull}!Text {
        if (value.len > std.math.maxInt(u16) or value.len > self.bytes.len - self.byte_count) return error.ByteFull;
        const offset = self.byte_count;
        @memcpy(self.bytes[offset..][0..value.len], value);
        self.byte_count += value.len;
        return .{ .offset = @intCast(offset), .len = @intCast(value.len) };
    }

    pub fn text(self: *const InputBatch, value: Text) []const u8 {
        const start: usize = value.offset;
        const end = start + value.len;
        std.debug.assert(end <= self.byte_count);
        return self.bytes[start..end];
    }
};

pub const PacketView = struct {
    connection: connection.Handle,
    protocol: i32,
    phase: Phase = .play,
    id: i32,
    bytes: []const u8,
    player: ?u16 = null,
    ticket: u16 = 0,
};

test "canonical input is bounded and ordered" {
    var storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var batch = try InputBatch.init(fixed.allocator(), 2, 64);
    try std.testing.expectEqual(InputAdmission.accepted, batch.append(.{ .sprint = .{ .player = 1, .sprinting = true } }));
    try std.testing.expectEqual(InputAdmission.accepted, batch.append(.{ .player_input = .{ .player = 1, .shift = false, .sprint = false } }));
    try std.testing.expectEqual(InputAdmission.full, batch.append(.{ .sprint = .{ .player = 2, .sprinting = false } }));
    try std.testing.expectEqual(@as(u16, 1), batch.items()[0].sprint.player);
}

test "canonical input owns bounded text until Core consumes it" {
    var storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var batch = try InputBatch.init(fixed.allocator(), 2, 8);
    const text = try batch.copyText("hello");
    try std.testing.expectEqual(InputAdmission.accepted, batch.append(.{ .chat = .{ .player = 7, .text = text } }));
    try std.testing.expectEqualStrings("hello", batch.text(batch.items()[0].chat.text));
    try std.testing.expectError(error.ByteFull, batch.copyText("more"));
}
