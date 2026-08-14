const std = @import("std");

pub const abi_version: u32 = 1;
pub const max_fields: usize = 8;

pub const Status = enum(u32) {
    ok,
    ignored,
    invalid_input,
    unsupported_version,
    buffer_too_small,
    out_of_memory,
    abi_mismatch,
    failed,
};

pub const Slice = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(value: []const u8) Slice {
        return .{ .ptr = value.ptr, .len = value.len };
    }

    pub fn bytes(self: Slice) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const Identity = extern struct {
    alias: Slice,
    entity_id: i32,
    position_known: u8,
    reserved: [3]u8 = .{ 0, 0, 0 },
    uuid_low: u64,
    uuid_high: u64,
    position_x: f64,
    position_y: f64,
    position_z: f64,
};

pub const Field = extern struct {
    name: Slice,
    value: Slice,
};

pub const Packet = extern struct {
    name: Slice,
    fields: ?[*]const Field,
    field_count: usize,
};

pub const CreateResult = extern struct {
    status: Status,
    handle: ?*Handle,
    detail: Slice,
};

pub const EncodeResult = extern struct {
    status: Status,
    written: usize,
    detail: Slice,
};

pub const CanonicalResult = extern struct {
    status: Status,
    packet: Packet,
    detail: Slice,
};

pub const Handle = opaque {};

fn mix(value: u64, next: usize) u64 {
    return (value ^ @as(u64, next)) *% 0x100000001b3;
}

pub const layout_fingerprint = fingerprint: {
    var value: u64 = 0xcbf29ce484222325;
    for (.{
        Slice,
        Identity,
        Field,
        Packet,
        CreateResult,
        EncodeResult,
        CanonicalResult,
    }) |T| {
        value = mix(value, @sizeOf(T));
        value = mix(value, @alignOf(T));
    }
    value = mix(value, @offsetOf(Identity, "entity_id"));
    value = mix(value, @offsetOf(Identity, "uuid_low"));
    value = mix(value, @offsetOf(Identity, "position_x"));
    value = mix(value, @offsetOf(Packet, "fields"));
    value = mix(value, @offsetOf(CanonicalResult, "packet"));
    break :fingerprint value ^ abi_version;
};

test "codec ABI has stable pointer-sized aggregate layout" {
    try std.testing.expectEqual(@sizeOf(usize) * 2, @sizeOf(Slice));
    try std.testing.expectEqual(@sizeOf(Slice) * 2, @sizeOf(Field));
    try std.testing.expect(@offsetOf(Identity, "uuid_low") % @alignOf(u64) == 0);
    try std.testing.expect(@offsetOf(Packet, "fields") % @alignOf(?[*]const Field) == 0);
    try std.testing.expect(layout_fingerprint != 0);
}
