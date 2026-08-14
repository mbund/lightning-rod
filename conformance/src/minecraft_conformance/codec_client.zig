const std = @import("std");
const abi = @import("codec_abi.zig");
const packet_model = @import("packet.zig");
const raw_packet = @import("raw_packet.zig");

extern fn mcc_codec_abi_fingerprint() callconv(.c) u64;
extern fn mcc_codec_create(
    abi.Slice,
    ?[*]const abi.Identity,
    usize,
    *abi.CreateResult,
) callconv(.c) void;
extern fn mcc_codec_destroy(*abi.Handle) callconv(.c) void;
extern fn mcc_codec_encode(
    *abi.Handle,
    *const abi.Packet,
    [*]u8,
    usize,
    *abi.EncodeResult,
) callconv(.c) void;
extern fn mcc_codec_canonicalize_clientbound(
    *abi.Handle,
    abi.Slice,
    abi.Slice,
    *abi.CanonicalResult,
) callconv(.c) void;
extern fn mcc_codec_canonicalize_serverbound(
    *abi.Handle,
    abi.Slice,
    *abi.CanonicalResult,
) callconv(.c) void;

/// Typed, lightweight owner for one cached protocol-codec context.
pub const Canonicalizer = struct {
    identities: []const raw_packet.Identity,
    minecraft: []const u8 = "",
    allocator: std.mem.Allocator = std.heap.page_allocator,
    handle: ?*abi.Handle = null,
    abi_identities: []abi.Identity = &.{},
    input_fields: [abi.max_fields]abi.Field = undefined,
    output_fields: [abi.max_fields]packet_model.Field = undefined,

    pub const Output = struct {
        recipient: []const u8,
        packet: packet_model.Packet,
    };

    pub fn init(identities: []const raw_packet.Identity) Canonicalizer {
        return .{ .identities = identities };
    }

    pub fn initWithAllocator(identities: []const raw_packet.Identity, allocator: std.mem.Allocator) Canonicalizer {
        return .{ .identities = identities, .allocator = allocator };
    }

    pub fn initForMinecraft(identities: []const raw_packet.Identity, minecraft: []const u8) !Canonicalizer {
        return initForMinecraftWithAllocator(identities, minecraft, std.heap.page_allocator);
    }

    pub fn initForMinecraftWithAllocator(
        identities: []const raw_packet.Identity,
        minecraft: []const u8,
        allocator: std.mem.Allocator,
    ) !Canonicalizer {
        return .{
            .identities = identities,
            .minecraft = minecraft,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Canonicalizer) void {
        if (self.handle) |handle| mcc_codec_destroy(handle);
        if (self.abi_identities.len != 0) self.allocator.free(self.abi_identities);
        self.handle = null;
        self.abi_identities = &.{};
    }

    pub fn canonicalize(self: *Canonicalizer, raw: raw_packet.Clientbound) !?Output {
        const handle = try self.ensureHandle();
        var result: abi.CanonicalResult = undefined;
        mcc_codec_canonicalize_clientbound(
            handle,
            .init(raw.recipient),
            .init(raw.payload),
            &result,
        );
        if (result.status == .ignored) return null;
        try check(result.status, result.detail);
        return .{
            .recipient = raw.recipient,
            .packet = try self.packet(result.packet),
        };
    }

    pub fn canonicalizeServerbound(self: *Canonicalizer, payload: []const u8) !?packet_model.Packet {
        const handle = try self.ensureHandle();
        var result: abi.CanonicalResult = undefined;
        mcc_codec_canonicalize_serverbound(handle, .init(payload), &result);
        if (result.status == .ignored) return null;
        try check(result.status, result.detail);
        return try self.packet(result.packet);
    }

    pub fn encodePacket(self: *Canonicalizer, buffer: []u8, value: packet_model.Packet) ![]const u8 {
        const handle = try self.ensureHandle();
        if (value.fields.len > self.input_fields.len) return error.TooManyCanonicalFields;
        for (value.fields, 0..) |field, index| {
            self.input_fields[index] = .{
                .name = .init(field.name),
                .value = .init(field.value.literal),
            };
        }
        const packet_view = abi.Packet{
            .name = .init(value.name),
            .fields = if (value.fields.len == 0) null else &self.input_fields,
            .field_count = value.fields.len,
        };
        var result: abi.EncodeResult = undefined;
        mcc_codec_encode(handle, &packet_view, buffer.ptr, buffer.len, &result);
        try check(result.status, result.detail);
        return buffer[0..result.written];
    }

    fn ensureHandle(self: *Canonicalizer) !*abi.Handle {
        if (self.handle) |handle| return handle;
        if (mcc_codec_abi_fingerprint() != abi.layout_fingerprint)
            return error.ConformanceCodecAbiMismatch;
        self.abi_identities = try self.allocator.alloc(abi.Identity, self.identities.len);
        errdefer {
            self.allocator.free(self.abi_identities);
            self.abi_identities = &.{};
        }
        for (self.identities, 0..) |identity, index| {
            self.abi_identities[index] = .{
                .alias = .init(identity.alias),
                .entity_id = identity.entity_id,
                .position_known = @intFromBool(identity.position_known),
                .uuid_low = @truncate(identity.uuid),
                .uuid_high = @truncate(identity.uuid >> 64),
                .position_x = identity.position[0],
                .position_y = identity.position[1],
                .position_z = identity.position[2],
            };
        }
        var result: abi.CreateResult = undefined;
        mcc_codec_create(
            .init(self.minecraft),
            if (self.abi_identities.len == 0) null else self.abi_identities.ptr,
            self.abi_identities.len,
            &result,
        );
        try check(result.status, result.detail);
        self.handle = result.handle orelse return error.ConformanceCodecMissingHandle;
        return self.handle.?;
    }

    fn packet(self: *Canonicalizer, packet_view: abi.Packet) !packet_model.Packet {
        if (packet_view.field_count > self.output_fields.len) return error.TooManyCanonicalFields;
        const fields = if (packet_view.field_count == 0)
            &.{}
        else
            (packet_view.fields orelse return error.MissingCanonicalFields)[0..packet_view.field_count];
        for (fields, 0..) |field, index| {
            self.output_fields[index] = .{
                .name = field.name.bytes(),
                .value = .{ .literal = field.value.bytes() },
            };
        }
        return .{
            .name = packet_view.name.bytes(),
            .fields = self.output_fields[0..packet_view.field_count],
        };
    }
};

fn check(status: abi.Status, detail: abi.Slice) !void {
    if (status == .ok) return;
    const message = detail.bytes();
    if (message.len != 0)
        std.log.err("conformance codec failure status={s} detail={s}", .{ @tagName(status), message });
    return switch (status) {
        .ok => unreachable,
        .ignored => error.UnexpectedIgnoredCanonicalPacket,
        .invalid_input => error.InvalidConformanceCodecInput,
        .unsupported_version => error.UnsupportedMinecraftVersion,
        .buffer_too_small => error.EndOfStream,
        .out_of_memory => error.OutOfMemory,
        .abi_mismatch => error.ConformanceCodecAbiMismatch,
        .failed => error.ConformanceCodecFailure,
    };
}

pub const input_encoder = struct {
    pub fn encode(buffer: []u8, packet: packet_model.Packet) ![]const u8 {
        var normalizer = Canonicalizer.init(&.{});
        defer normalizer.deinit();
        return normalizer.encodePacket(buffer, packet);
    }

    pub fn encodeWithIdentities(
        buffer: []u8,
        packet: packet_model.Packet,
        identities: []const raw_packet.Identity,
    ) ![]const u8 {
        var normalizer = Canonicalizer.init(identities);
        defer normalizer.deinit();
        return normalizer.encodePacket(buffer, packet);
    }

    pub fn encodeForMinecraft(buffer: []u8, packet: packet_model.Packet, minecraft: []const u8) ![]const u8 {
        var normalizer = try Canonicalizer.initForMinecraft(&.{}, minecraft);
        defer normalizer.deinit();
        return normalizer.encodePacket(buffer, packet);
    }
};
