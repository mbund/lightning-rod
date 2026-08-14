const std = @import("std");
const abi = @import("codec_abi.zig");
const canonicalizer = @import("canonicalizer.zig");
const input_encoder = @import("input_encoder.zig");
const packet_model = @import("packet.zig");
const raw_packet = @import("raw_packet.zig");

const allocator = std.heap.page_allocator;
const empty = abi.Slice.init("");

const Codec = struct {
    minecraft: []u8,
    identities: []raw_packet.Identity,
    normalizer: canonicalizer.Canonicalizer,
    input_fields: [abi.max_fields]packet_model.Field = undefined,
    output_fields: [abi.max_fields]abi.Field = undefined,

    fn create(minecraft: []const u8, identities: []const abi.Identity) !*Codec {
        const self = try allocator.create(Codec);
        errdefer allocator.destroy(self);
        const owned_minecraft = try allocator.dupe(u8, minecraft);
        errdefer allocator.free(owned_minecraft);
        const owned_identities = try allocator.alloc(raw_packet.Identity, identities.len);
        errdefer allocator.free(owned_identities);
        var initialized: usize = 0;
        errdefer for (owned_identities[0..initialized]) |identity|
            allocator.free(identity.alias);
        for (identities, 0..) |identity, index| {
            const alias = try allocator.dupe(u8, identity.alias.bytes());
            owned_identities[index] = .{
                .alias = alias,
                .entity_id = identity.entity_id,
                .uuid = @as(u128, identity.uuid_low) | (@as(u128, identity.uuid_high) << 64),
                .position = .{ identity.position_x, identity.position_y, identity.position_z },
                .position_known = identity.position_known != 0,
            };
            initialized += 1;
        }
        self.* = .{
            .minecraft = owned_minecraft,
            .identities = owned_identities,
            .normalizer = try canonicalizer.Canonicalizer.initForMinecraftWithAllocator(
                owned_identities,
                minecraft,
                allocator,
            ),
        };
        return self;
    }

    fn destroy(self: *Codec) void {
        self.normalizer.deinit();
        allocator.free(self.minecraft);
        for (self.identities) |identity| allocator.free(identity.alias);
        allocator.free(self.identities);
        allocator.destroy(self);
    }

    fn packet(self: *Codec, input: abi.Packet) !packet_model.Packet {
        if (input.field_count > self.input_fields.len) return error.TooManyCanonicalFields;
        const fields = if (input.field_count == 0)
            &.{}
        else
            (input.fields orelse return error.MissingCanonicalFields)[0..input.field_count];
        for (fields, 0..) |field, index| {
            self.input_fields[index] = .{
                .name = field.name.bytes(),
                .value = .{ .literal = field.value.bytes() },
            };
        }
        return .{
            .name = input.name.bytes(),
            .fields = self.input_fields[0..input.field_count],
        };
    }

    fn resultPacket(self: *Codec, value: packet_model.Packet) !abi.Packet {
        if (value.fields.len > self.output_fields.len) return error.TooManyCanonicalFields;
        for (value.fields, 0..) |field, index| {
            self.output_fields[index] = .{
                .name = .init(field.name),
                .value = .init(field.value.literal),
            };
        }
        return .{
            .name = .init(value.name),
            .fields = if (value.fields.len == 0) null else &self.output_fields,
            .field_count = value.fields.len,
        };
    }
};

fn codec(raw: *abi.Handle) *Codec {
    return @ptrCast(@alignCast(raw));
}

fn detail(err: anyerror) abi.Slice {
    return .init(@errorName(err));
}

fn status(err: anyerror) abi.Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.EndOfStream => .buffer_too_small,
        error.UnsupportedMinecraftVersion => .unsupported_version,
        error.MissingCanonicalFields,
        error.TooManyCanonicalFields,
        => .invalid_input,
        else => .failed,
    };
}

export fn mcc_codec_abi_fingerprint() callconv(.c) u64 {
    return abi.layout_fingerprint;
}

export fn mcc_codec_create(
    minecraft: abi.Slice,
    identities_ptr: ?[*]const abi.Identity,
    identity_count: usize,
    output: *abi.CreateResult,
) callconv(.c) void {
    const identities = if (identity_count == 0)
        &.{}
    else
        (identities_ptr orelse {
            output.* = .{ .status = .invalid_input, .handle = null, .detail = .init("MissingIdentities") };
            return;
        })[0..identity_count];
    const created = Codec.create(minecraft.bytes(), identities) catch |err| {
        output.* = .{ .status = status(err), .handle = null, .detail = detail(err) };
        return;
    };
    output.* = .{ .status = .ok, .handle = @ptrCast(created), .detail = empty };
}

export fn mcc_codec_destroy(handle: *abi.Handle) callconv(.c) void {
    codec(handle).destroy();
}

export fn mcc_codec_encode(
    handle: *abi.Handle,
    packet: *const abi.Packet,
    output_bytes: [*]u8,
    output_capacity: usize,
    output: *abi.EncodeResult,
) callconv(.c) void {
    const self = codec(handle);
    const typed_packet = self.packet(packet.*) catch |err| {
        output.* = .{ .status = status(err), .written = 0, .detail = detail(err) };
        return;
    };
    const encoded = input_encoder.encodeForMinecraftWithIdentities(
        output_bytes[0..output_capacity],
        typed_packet,
        self.identities,
        self.minecraft,
    ) catch |err| {
        output.* = .{ .status = status(err), .written = 0, .detail = detail(err) };
        return;
    };
    output.* = .{ .status = .ok, .written = encoded.len, .detail = empty };
}

export fn mcc_codec_canonicalize_clientbound(
    handle: *abi.Handle,
    recipient: abi.Slice,
    payload: abi.Slice,
    output: *abi.CanonicalResult,
) callconv(.c) void {
    const self = codec(handle);
    const canonical = self.normalizer.canonicalize(.{
        .recipient = recipient.bytes(),
        .payload = payload.bytes(),
    }) catch |err| {
        output.* = .{
            .status = status(err),
            .packet = .{ .name = empty, .fields = null, .field_count = 0 },
            .detail = detail(err),
        };
        return;
    };
    const value = canonical orelse {
        output.* = .{
            .status = .ignored,
            .packet = .{ .name = empty, .fields = null, .field_count = 0 },
            .detail = empty,
        };
        return;
    };
    const packet = self.resultPacket(value.packet) catch |err| {
        output.* = .{
            .status = status(err),
            .packet = .{ .name = empty, .fields = null, .field_count = 0 },
            .detail = detail(err),
        };
        return;
    };
    output.* = .{ .status = .ok, .packet = packet, .detail = empty };
}

export fn mcc_codec_canonicalize_serverbound(
    handle: *abi.Handle,
    payload: abi.Slice,
    output: *abi.CanonicalResult,
) callconv(.c) void {
    const self = codec(handle);
    const canonical = self.normalizer.canonicalizeServerbound(payload.bytes()) catch |err| {
        output.* = .{
            .status = status(err),
            .packet = .{ .name = empty, .fields = null, .field_count = 0 },
            .detail = detail(err),
        };
        return;
    };
    const value = canonical orelse {
        output.* = .{
            .status = .ignored,
            .packet = .{ .name = empty, .fields = null, .field_count = 0 },
            .detail = empty,
        };
        return;
    };
    const packet = self.resultPacket(value) catch |err| {
        output.* = .{
            .status = status(err),
            .packet = .{ .name = empty, .fields = null, .field_count = 0 },
            .detail = detail(err),
        };
        return;
    };
    output.* = .{ .status = .ok, .packet = packet, .detail = empty };
}
