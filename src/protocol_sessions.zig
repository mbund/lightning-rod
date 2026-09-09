const minecraft = @import("minecraft_session.zig");
const configuration = @import("configuration_plan.zig");
const light_projection = @import("light_projection.zig");
const protocol_support = @import("protocol_support");
const protocol_versions = @import("protocol_versions.zig");
const protocol_values = @import("protocol_values.zig");
const registry = @import("registry_data");
const session_api = @import("session_api.zig");
const std = @import("std");
const wire = @import("wire.zig");

pub fn Catalog(comptime selected: anytype) type {
    comptime _ = protocol_versions.numbers(selected);

    return struct {
        const Self = @This();

        pub const protocols = buildProtocols();
        pub const handshake_decoder: minecraft.HandshakeDecoder = .{
            .context = &Handshake.context,
            .decode = Handshake.decode,
        };

        pub fn install(table: anytype, configuration_plan: configuration.Plan) void {
            if (!table.setProtocols(&protocols)) @panic("Sessions protocol table exceeds its bounded batch capacity");
            table.setHandshakeDecoder(handshake_decoder);
            if (!table.setConfigurationPlan(configuration_plan)) @panic("Sessions rejected the application Configuration plan");
        }

        fn buildProtocols() [selected.len]minecraft.Protocol {
            var result: [selected.len]minecraft.Protocol = undefined;
            inline for (selected, 0..) |support, index| {
                result[index] = .{
                    .number = support.protocol_number,
                    .codec = Codec(support.version).value,
                };
            }
            return result;
        }

        const Handshake = struct {
            var context: u8 = 0;

            fn decode(_: *anyopaque, value: *minecraft.Session, bytes: []const u8) minecraft.Handshake {
                const read = switch (readOne(value, bytes)) {
                    .incomplete => |consumed| return .{ .progress = .{ .consumed = consumed, .value = null } },
                    .malformed => return .malformed,
                    .payload => |item| item,
                };
                const decoded = protocol_versions.decodeHandshake(read.bytes) catch return .malformed;
                const result: minecraft.HandshakeValue = switch (decoded.intent) {
                    1 => .{ .status = decoded.protocol_number },
                    2 => .{ .login = decoded.protocol_number },
                    else => return .malformed,
                };
                return .{ .progress = .{ .consumed = read.consumed, .value = result } };
            }
        };

        fn Codec(comptime version: protocol_versions.Version) type {
            const Generated = protocol_versions.PlayCodec(
                protocol_versions.Protocol(version),
                protocol_versions.Registry(version),
            );

            return struct {
                var context: u8 = 0;
                pub const value: minecraft.Codec = .{
                    .context = &context,
                    .vtable = &.{
                        .init = init,
                        .decode = decode,
                        .finish_input = finishInput,
                        .classify = classify,
                        .frame_payload = framePrepared,
                        .start_configuration = startConfiguration,
                        .configuration_entry = configurationEntry,
                        .finish_configuration = finishConfiguration,
                        .encryption_request = encryptionRequest,
                        .set_compression = setCompression,
                        .login_success = loginSuccess,
                        .encoded_capacity = encodedCapacity,
                        .encode = encode,
                        .status = status,
                    },
                };

                fn init(_: *anyopaque, item: *minecraft.Session) bool {
                    item.codec_state_len = 0;
                    item.codec_state_exposed = false;
                    return true;
                }

                fn finishInput(_: *anyopaque, item: *minecraft.Session) void {
                    if (item.codec_state_exposed) {
                        item.codec_state_len = 0;
                        item.codec_state_exposed = false;
                    }
                }

                fn decode(_: *anyopaque, item: *minecraft.Session, bytes: []const u8, output: []minecraft.Packet) minecraft.Codec.Decode {
                    if (item.codec_state_exposed) return .{ .progress = .{ .consumed = 0, .packets = 0, .needs_more = true } };
                    if (item.codec_state_len != 0) return decodeBuffered(item, bytes, output);
                    return decodePage(item, bytes, output);
                }

                fn classify(_: *anyopaque, phase: session_api.Phase, packet: minecraft.Packet) minecraft.Disposition {
                    return switch (phase) {
                        .status => classifyStatus(packet),
                        .login => classifyLogin(packet),
                        .configuration => classifyConfiguration(packet),
                        .play => .core,
                        .handshake => .invalid,
                    };
                }

                fn encodedCapacity(_: *anyopaque, item: *const minecraft.Session, id: i32, bytes: []const u8) ?usize {
                    const body_len = varIntLen(id) + bytes.len;
                    const total = if (item.compression_threshold == null)
                        varIntLen(@intCast(body_len)) + body_len
                    else
                        10 + body_len + ((body_len / 16_383) + 1) * 5 + 6;
                    if (body_len > max_packet_bytes or total > max_packet_bytes) return null;
                    return total;
                }

                fn encode(_: *anyopaque, item: *minecraft.Session, id: i32, bytes: []const u8, output: []u8) ?usize {
                    const len = if (item.phase == .status) status_packet: {
                        const command = Generated.decodeStatus(bytes) catch return null;
                        break :status_packet switch (command) {
                            .ping => |timestamp| frameGenerated(Generated.encodeStatusPong(output, timestamp) catch return null, output),
                            .request => null,
                        };
                    } else frameSession(item, id, bytes, output);
                    return len;
                }

                fn status(_: *anyopaque, _: i32, json: []const u8, output: []u8) ?usize {
                    return frameGenerated(Generated.encodeStatusResponse(output, json) catch return null, output);
                }

                fn framePrepared(_: *anyopaque, item: *minecraft.Session, payload: []const u8, output: []u8) ?usize {
                    return framePayloadSession(item, payload, output);
                }

                fn startConfiguration(_: *anyopaque, item: *minecraft.Session, output: []u8) ?usize {
                    const body = Generated.encodeStartConfiguration(item.decoded_state[0..]) catch return null;
                    return framePayloadSession(item, body, output);
                }

                fn configurationEntry(_: *anyopaque, item: *minecraft.Session, entry: configuration.Entry, output: []u8) ?usize {
                    const body = switch (entry) {
                        .feature_flags => |flags| Generated.encodeFeatureFlagList(item.decoded_state[0..], flags.values) catch return null,
                        .known_packs => |packs| Generated.encodeKnownPackList(item.decoded_state[0..], packs.values) catch return null,
                        .registry => |registry_data| Generated.encodeRegistryEntries(item.decoded_state[0..], registry_data) catch return null,
                        .tags => |tags| Generated.encodeConfigurationTags(item.decoded_state[0..], tags.payload) catch return null,
                        .resource_pack => |pack| Generated.encodeResourcePack(item.decoded_state[0..], pack) catch return null,
                    };
                    return framePayloadSession(item, body, output);
                }

                fn finishConfiguration(_: *anyopaque, item: *minecraft.Session, output: []u8) ?usize {
                    const body = Generated.encodeFinishConfiguration(item.decoded_state[0..]) catch return null;
                    return framePayloadSession(item, body, output);
                }

                fn encryptionRequest(_: *anyopaque, item: *minecraft.Session, public_key: []const u8, verify_token: []const u8, output: []u8) ?usize {
                    const body = Generated.encodeEncryptionRequest(item.decoded_state[0..], public_key, verify_token) catch return null;
                    return framePayloadSession(item, body, output);
                }

                fn setCompression(_: *anyopaque, item: *minecraft.Session, threshold: i32, output: []u8) ?usize {
                    const body = Generated.encodeSetCompression(item.decoded_state[0..], threshold) catch return null;
                    return frameGenerated(body, output);
                }

                fn loginSuccess(_: *anyopaque, item: *minecraft.Session, uuid: u128, username: []const u8, output: []u8) ?usize {
                    const body = Generated.encodeLoginSuccess(item.decoded_state[0..], uuid, username) catch return null;
                    return framePayloadSession(item, body, output);
                }

                fn classifyStatus(packet: minecraft.Packet) minecraft.Disposition {
                    const command = Generated.decodeStatus(packet.bytes) catch return .invalid;
                    return switch (command) {
                        .request => .status_request,
                        .ping => .{ .status_ping = packet.bytes },
                    };
                }

                fn classifyLogin(packet: minecraft.Packet) minecraft.Disposition {
                    const command = Generated.decodeLogin(packet.bytes) catch return .invalid;
                    return switch (command) {
                        .start => |start| .{ .begin_login = start.username },
                        .encryption_response => |response| .{ .encryption_response = minecraft.EncryptionResponse{
                            .shared_secret = response.shared_secret,
                            .verify_token = response.verify_token,
                        } },
                        .acknowledged => .login_acknowledged,
                    };
                }

                fn classifyConfiguration(packet: minecraft.Packet) minecraft.Disposition {
                    return switch (Generated.decodeConfiguration(packet.bytes) catch return .invalid) {
                        .finish => .finish_configuration,
                        .select_known_packs => .configuration_known_packs,
                        .ignore => .ignored,
                    };
                }
            };
        }
    };
}

const vanilla_known_packs = knownVanillaPacks();

fn knownVanillaPacks() [protocol_versions.minecraft_names.len]configuration.KnownPack {
    var packs: [protocol_versions.minecraft_names.len]configuration.KnownPack = undefined;
    for (protocol_versions.minecraft_names, 0..) |name, index| packs[index] = .{
        .namespace = "minecraft",
        .id = "core",
        .version = name,
    };
    return packs;
}

const test_configuration_plan: configuration.Plan = .{ .entries = &.{
    .{ .feature_flags = .{ .values = &.{"minecraft:vanilla"} } },
    .{ .known_packs = .{ .values = &vanilla_known_packs } },
} };

fn angle(value: f32) i8 {
    if (!std.math.isFinite(value)) return 0;
    const wrapped = @mod(value, 360.0);
    const encoded = @floor(wrapped * (256.0 / 360.0));
    std.debug.assert(encoded >= 0 and encoded < 256);
    return @bitCast(@as(u8, @intFromFloat(encoded)));
}

test "entity angles wrap and reject non-finite output" {
    try std.testing.expectEqual(@as(i8, 0), angle(0));
    try std.testing.expectEqual(@as(i8, 64), angle(450));
    try std.testing.expectEqual(@as(i8, -64), angle(-90));
    try std.testing.expectEqual(@as(i8, 0), angle(std.math.nan(f32)));
    try std.testing.expectEqual(@as(i8, 0), angle(std.math.inf(f32)));
}

fn velocity(value: f64) i16 {
    return @intFromFloat(std.math.clamp(value * 8000.0, @as(f64, std.math.minInt(i16)), @as(f64, std.math.maxInt(i16))));
}

const max_packet_bytes = minecraft.Codec.max_state_bytes - @sizeOf(u16);
const max_server_packet_bytes = minecraft.Codec.max_packet_bytes;

fn decodePage(value: *minecraft.Session, bytes: []const u8, output: []minecraft.Packet) minecraft.Codec.Decode {
    var consumed: usize = 0;
    var count: usize = 0;
    while (consumed != bytes.len and count != output.len) {
        const remaining = bytes[consumed..];
        if (!validFramePrefix(remaining)) return .malformed;
        const framed = wire.nextPacket(remaining) catch return .malformed;
        const packet = framed orelse {
            if (!storePartial(value, remaining)) return .malformed;
            return .{ .progress = .{ .consumed = bytes.len, .packets = count, .needs_more = true } };
        };
        const decoded = decodePayload(value, packet.payload, .input_page) orelse return .malformed;
        const id, _ = protocol_support.read_varint(decoded.bytes) catch return .malformed;
        output[count] = .{ .id = id, .bytes = decoded.bytes, .storage = decoded.storage };
        count += 1;
        consumed += packet.total_len;
        if (decoded.storage == .session) {
            value.codec_state_exposed = true;
            break;
        }
    }
    return .{ .progress = .{ .consumed = consumed, .packets = count, .needs_more = consumed != bytes.len } };
}

fn decodeBuffered(value: *minecraft.Session, bytes: []const u8, output: []minecraft.Packet) minecraft.Codec.Decode {
    if (output.len == 0) return .malformed;
    var used: usize = value.codec_state_len;
    var consumed: usize = 0;
    const packet = packet: {
        for (0..max_packet_bytes + 1) |_| {
            if (!validFramePrefix(value.codec_state[0..used])) return .malformed;
            const framed = wire.nextPacket(value.codec_state[0..used]) catch return .malformed;
            if (framed) |complete| {
                break :packet complete;
            }
            if (consumed == bytes.len or used == max_packet_bytes) {
                value.codec_state_len = @intCast(used);
                return if (used == max_packet_bytes) .malformed else .{ .progress = .{ .consumed = consumed, .packets = 0, .needs_more = true } };
            }
            value.codec_state[used] = bytes[consumed];
            used += 1;
            consumed += 1;
        }
        unreachable;
    };
    const decoded = decodePayload(value, packet.payload, .session) orelse return .malformed;
    const id, _ = protocol_support.read_varint(decoded.bytes) catch return .malformed;
    output[0] = .{ .id = id, .bytes = decoded.bytes, .storage = .session };
    value.codec_state_len = @intCast(used);
    value.codec_state_exposed = true;
    return .{ .progress = .{ .consumed = consumed, .packets = 1, .needs_more = consumed != bytes.len } };
}

const ReadOne = union(enum) { incomplete: usize, malformed, payload: struct { consumed: usize, bytes: []const u8 } };

fn readOne(value: *minecraft.Session, bytes: []const u8) ReadOne {
    const used: usize = value.codec_state_len;
    var total = used;
    var consumed: usize = 0;
    const packet = packet: {
        for (0..max_packet_bytes + 1) |_| {
            if (!validFramePrefix(value.codec_state[0..total])) return .malformed;
            const framed = wire.nextPacket(value.codec_state[0..total]) catch return .malformed;
            if (framed) |complete| {
                break :packet complete;
            }
            if (consumed == bytes.len or total == max_packet_bytes) {
                value.codec_state_len = @intCast(total);
                return if (total == max_packet_bytes) .malformed else .{ .incomplete = consumed };
            }
            value.codec_state[total] = bytes[consumed];
            total += 1;
            consumed += 1;
        }
        unreachable;
    };
    value.codec_state_len = 0;
    return .{ .payload = .{ .consumed = consumed, .bytes = packet.payload } };
}

fn storePartial(value: *minecraft.Session, bytes: []const u8) bool {
    if (bytes.len > max_packet_bytes) return false;
    @memcpy(value.codec_state[0..bytes.len], bytes);
    value.codec_state_len = @intCast(bytes.len);
    return true;
}

fn validFramePrefix(bytes: []const u8) bool {
    const len, _ = protocol_support.read_varint(bytes) catch |err| return switch (err) {
        error.EndOfStream => true,
        else => false,
    };
    return len >= 0 and len <= max_packet_bytes;
}

const DecodedPayload = struct { bytes: []const u8, storage: minecraft.PacketStorage };

fn decodePayload(value: *minecraft.Session, framed: []const u8, storage: minecraft.PacketStorage) ?DecodedPayload {
    const threshold = value.compression_threshold orelse return .{ .bytes = framed, .storage = storage };
    const data_len, const compressed = protocol_support.read_varint(framed) catch return null;
    if (data_len < 0) return null;
    if (data_len == 0) {
        if (compressed.len >= threshold) return null;
        return .{ .bytes = compressed, .storage = storage };
    }
    if (data_len < threshold or data_len > max_packet_bytes) return null;
    const output_len: usize = @intCast(data_len);
    var source: std.Io.Reader = .fixed(compressed);
    var decompressor = std.compress.flate.Decompress.init(&source, .zlib, &value.decompression_window);
    decompressor.reader.readSliceAll(value.decoded_state[0..output_len]) catch return null;
    return .{ .bytes = value.decoded_state[0..output_len], .storage = .session };
}

fn frame(id: i32, bytes: []const u8, output: []u8) ?usize {
    const body_len = varIntLen(id) + bytes.len;
    const prefix_len = varIntLen(@intCast(body_len));
    const total = prefix_len + body_len;
    if (body_len > max_packet_bytes or total > output.len) return null;
    var rest = output;
    rest = protocol_support.write_varint(rest, @intCast(body_len)) catch return null;
    rest = protocol_support.write_varint(rest, id) catch return null;
    if (rest.len < bytes.len) return null;
    @memcpy(rest[0..bytes.len], bytes);
    return total;
}

fn frameSession(value: *minecraft.Session, id: i32, bytes: []const u8, output: []u8) ?usize {
    var rest: []u8 = value.compression_scratch[0..];
    rest = protocol_support.write_varint(rest, id) catch return null;
    if (rest.len < bytes.len) return null;
    const body_len = value.compression_scratch.len - rest.len + bytes.len;
    @memcpy(rest[0..bytes.len], bytes);
    return framePayloadSession(value, value.compression_scratch[0..body_len], output);
}

fn framePayloadSession(value: *minecraft.Session, body: []const u8, output: []u8) ?usize {
    if (body.len > max_server_packet_bytes) return null;
    const threshold = value.compression_threshold orelse return framePayload(body, output);
    if (body.len < threshold) return frameUncompressed(body, output);
    return frameCompressed(value, body, output);
}

fn framePayload(body: []const u8, output: []u8) ?usize {
    const prefix_len = varIntLen(@intCast(body.len));
    const total = prefix_len + body.len;
    if (body.len > max_server_packet_bytes or total > output.len) return null;
    var rest = protocol_support.write_varint(output, @intCast(body.len)) catch return null;
    if (rest.len < body.len) return null;
    @memcpy(rest[0..body.len], body);
    return total;
}

fn frameUncompressed(body: []const u8, output: []u8) ?usize {
    const inner_len = varIntLen(0) + body.len;
    const total = varIntLen(@intCast(inner_len)) + inner_len;
    if (total > output.len) return null;
    var rest = protocol_support.write_varint(output, @intCast(inner_len)) catch return null;
    rest = protocol_support.write_varint(rest, 0) catch return null;
    if (rest.len < body.len) return null;
    @memcpy(rest[0..body.len], body);
    return total;
}

fn frameCompressed(value: *minecraft.Session, body: []const u8, output: []u8) ?usize {
    if (body.len > max_server_packet_bytes) return null;
    const reserve = 10;
    if (output.len <= reserve) return null;
    var writer: std.Io.Writer = .fixed(output[reserve..]);
    var compressor = std.compress.flate.Compress.init(&writer, &value.compression_window, .zlib, .level_1) catch return null;
    compressor.writer.writeAll(body) catch return null;
    compressor.finish() catch return null;
    const compressed_len = writer.buffered().len;
    const data_prefix = varIntLen(@intCast(body.len));
    const outer_len = data_prefix + compressed_len;
    const outer_prefix = varIntLen(@intCast(outer_len));
    const total = outer_prefix + outer_len;
    if (total > output.len) return null;
    @memmove(output[outer_prefix + data_prefix ..][0..compressed_len], output[reserve..][0..compressed_len]);
    const rest = protocol_support.write_varint(output, @intCast(outer_len)) catch return null;
    _ = protocol_support.write_varint(rest, @intCast(body.len)) catch return null;
    return total;
}

fn frameGenerated(body: []const u8, output: []u8) ?usize {
    const prefix_len = varIntLen(@intCast(body.len));
    const total = prefix_len + body.len;
    if (body.len > max_packet_bytes or total > output.len) return null;
    if (prefix_len != 0) @memmove(output[prefix_len..][0..body.len], body);
    _ = protocol_support.write_varint(output[0..prefix_len], @intCast(body.len)) catch return null;
    return total;
}

fn varIntLen(value: i32) usize {
    var bits: u32 = @bitCast(value);
    var result: usize = 1;
    while (bits >= 0x80) : (bits >>= 7) result += 1;
    return result;
}

test "selected catalog has one protocol entry per selected wire protocol" {
    const catalog = Catalog(protocol_versions.all);
    try std.testing.expectEqual(protocol_versions.all.len, catalog.protocols.len);
    inline for (protocol_versions.all, 0..) |selected, index|
        try std.testing.expectEqual(selected.protocol_number, catalog.protocols[index].number);
}

test "large server packets fit the bounded session output buffer" {
    var session = minecraft.Session{
        .connection = .{ .index = 0, .generation = 1 },
        .compression_threshold = 256,
    };
    var body: [128 * 1024]u8 = @splat(0x4a);
    var framed: [minecraft.Codec.max_state_bytes]u8 = undefined;
    const length = framePayloadSession(&session, &body, &framed) orelse return error.CompressionFailed;
    const packet = (try wire.nextPacket(framed[0..length])).?;
    const decoded_len, const compressed = try @import("protocol_support").read_varint(packet.payload);
    try std.testing.expectEqual(@as(i32, body.len), decoded_len);
    var source: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&source, .zlib, &window);
    var decoded: [body.len]u8 = undefined;
    try decompressor.reader.readSliceAll(&decoded);
    try std.testing.expectEqualSlices(u8, &body, &decoded);
}

test "Configuration codec fixture advertises every compiled Minecraft core pack" {
    const packs = switch (test_configuration_plan.entries[1]) {
        .known_packs => |value| value.values,
        else => return error.UnexpectedConfigurationStep,
    };
    try std.testing.expectEqual(protocol_versions.minecraft_names.len, packs.len);
    for (packs, protocol_versions.minecraft_names) |pack, name| {
        try std.testing.expectEqualStrings("minecraft", pack.namespace);
        try std.testing.expectEqualStrings("core", pack.id);
        try std.testing.expectEqualStrings(name, pack.version);
    }
}

test "configuration schedule is ordered and generated for every selected wire protocol" {
    inline for (protocol_versions.all) |selected| {
        const version = selected.version;
        const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(version)});
        const codec = catalog.protocols[0].codec;
        const Generated = protocol_versions.PlayCodec(
            protocol_versions.Protocol(version),
            protocol_versions.Registry(version),
        );
        const plan = test_configuration_plan;
        var session = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 }, .phase = .configuration, .protocol = protocol_versions.support(version).protocol_number };
        var output: [512]u8 = undefined;
        var expected: [512]u8 = undefined;

        const encode_entry = codec.vtable.configuration_entry orelse return error.UnexpectedConfigurationStep;
        const encode_finish = codec.vtable.finish_configuration orelse return error.UnexpectedConfigurationStep;
        const flags = encode_entry(codec.context, &session, plan.entries[0], &output) orelse return error.UnexpectedConfigurationStep;
        const expected_flags = try Generated.encodeFeatureFlags(&expected);
        const flags_packet = (try wire.nextPacket(output[0..flags])).?;
        try std.testing.expectEqualSlices(u8, expected_flags, flags_packet.payload);

        session.configuration_step = 1;
        const known = encode_entry(codec.context, &session, plan.entries[1], &output) orelse return error.UnexpectedConfigurationStep;
        const expected_known = switch (plan.entries[1]) {
            .known_packs => |packs| try Generated.encodeKnownPackList(&expected, packs.values),
            else => return error.UnexpectedConfigurationStep,
        };
        const known_packet = (try wire.nextPacket(output[0..known])).?;
        try std.testing.expectEqualSlices(u8, expected_known, known_packet.payload);

        session.configuration_step = 2;
        const finish = encode_finish(codec.context, &session, &output) orelse return error.UnexpectedConfigurationStep;
        const expected_finish = try Generated.encodeFinishConfiguration(&expected);
        const finish_packet = (try wire.nextPacket(output[0..finish])).?;
        try std.testing.expectEqualSlices(u8, expected_finish, finish_packet.payload);
    }
}

test "generated configuration entries preserve fields for every selected wire protocol" {
    const entries = [_]configuration.Entry{
        .{ .feature_flags = .{ .values = &.{ "minecraft:vanilla", "minecraft:test" } } },
        .{ .known_packs = .{ .values = &.{.{ .namespace = "example", .id = "pack", .version = "9" }} } },
        .{ .registry = .{ .id = "example:registry", .entries = &.{.{ .id = "example:empty" }} } },
        .{ .tags = .{ .payload = &.{ 0, 0 } } },
        .{ .resource_pack = .{ .uuid = 0x0102_0304_0506_0708_1112_1314_1516_1718, .url = "https://example.invalid/pack.zip", .hash = "abc", .required = true } },
    };
    inline for (protocol_versions.all) |selected| {
        const version = selected.version;
        const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(version)});
        const codec = catalog.protocols[0].codec;
        const Generated = protocol_versions.PlayCodec(
            protocol_versions.Protocol(version),
            protocol_versions.Registry(version),
        );
        var session = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 }, .phase = .configuration, .protocol = protocol_versions.support(version).protocol_number };
        const encode_entry = codec.vtable.configuration_entry orelse return error.UnexpectedConfigurationStep;
        inline for (entries) |entry| {
            var output: [512]u8 = undefined;
            var expected: [512]u8 = undefined;
            const encoded = encode_entry(codec.context, &session, entry, &output) orelse return error.UnexpectedConfigurationStep;
            const expected_body = switch (entry) {
                .feature_flags => |flags| try Generated.encodeFeatureFlagList(&expected, flags.values),
                .known_packs => |packs| try Generated.encodeKnownPackList(&expected, packs.values),
                .registry => |registry_data| try Generated.encodeRegistryEntries(&expected, registry_data),
                .tags => |tags| try Generated.encodeConfigurationTags(&expected, tags.payload),
                .resource_pack => |pack| try Generated.encodeResourcePack(&expected, pack),
            };
            const packet = (try wire.nextPacket(output[0..encoded])).?;
            try std.testing.expectEqualSlices(u8, expected_body, packet.payload);
        }
    }
}

test "codec frames a canonical packet without transport state" {
    const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(protocol_versions.default)});
    var value = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 }, .phase = .play };
    var output: [16]u8 = undefined;
    const codec = catalog.protocols[0].codec;
    const len = codec.vtable.encode(codec.context, &value, 42, "abc", &output).?;
    const framed = (try wire.nextPacket(output[0..len])).?;
    const id, const payload = try protocol_support.read_varint(framed.payload);
    try std.testing.expectEqual(@as(i32, 42), id);
    try std.testing.expectEqualStrings("abc", payload);
}

test "catalog handshake uses the generated protocol decoder after framing" {
    const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(protocol_versions.default)});
    const Protocol = protocol_versions.Protocol(protocol_versions.default);
    var body: [128]u8 = undefined;
    const packet = Protocol.handshaking.toServer.write(&body);
    const set_protocol = try packet.set_protocol();
    const version = try set_protocol.protocolVersion(772);
    const host = try version.serverHost("localhost");
    const port = try host.serverPort(25565);
    const payload = (try port.nextState(2)).finish();
    var framed_bytes: [160]u8 = undefined;
    const len = frameGenerated(payload, &framed_bytes).?;
    var value = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 } };
    const decoded = catalog.handshake_decoder.decode(catalog.handshake_decoder.context, &value, framed_bytes[0..len]);
    try std.testing.expectEqual(minecraft.Handshake{ .progress = .{ .consumed = len, .value = .{ .login = 772 } } }, decoded);
}

test "stream decoder handles split header and split body" {
    const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(protocol_versions.default)});
    const codec = catalog.protocols[0].codec;
    var value = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 } };
    try std.testing.expect(codec.vtable.init(codec.context, &value));
    var payload: [127]u8 = @splat(3);
    var framed: [160]u8 = undefined;
    const len = frame(1, &payload, &framed).?;
    var packets: [2]minecraft.Packet = undefined;
    try expectProgress(codec.vtable.decode(codec.context, &value, framed[0..1], &packets), 1, 0, true);
    try expectProgress(codec.vtable.decode(codec.context, &value, framed[1..len], &packets), len - 1, 1, false);
    codec.vtable.finish_input(codec.context, &value);
    const short_len = frame(2, "abc", &framed).?;
    try expectProgress(codec.vtable.decode(codec.context, &value, framed[0..2], &packets), 2, 0, true);
    try expectProgress(codec.vtable.decode(codec.context, &value, framed[2..short_len], &packets), short_len - 2, 1, false);
}

test "stream decoder handles coalesced and complete plus partial frames" {
    const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(protocol_versions.default)});
    const codec = catalog.protocols[0].codec;
    var value = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 } };
    try std.testing.expect(codec.vtable.init(codec.context, &value));
    var bytes: [64]u8 = undefined;
    const first = frame(3, "a", &bytes).?;
    const second = frame(4, "bc", bytes[first..]).?;
    var packets: [4]minecraft.Packet = undefined;
    try expectProgress(codec.vtable.decode(codec.context, &value, bytes[0 .. first + second], &packets), first + second, 2, false);
    codec.vtable.finish_input(codec.context, &value);
    var one: [1]minecraft.Packet = undefined;
    try expectProgress(codec.vtable.decode(codec.context, &value, bytes[0 .. first + second], &one), first, 1, true);
    codec.vtable.finish_input(codec.context, &value);
    try expectProgress(codec.vtable.decode(codec.context, &value, bytes[first .. first + second], &one), second, 1, false);
    codec.vtable.finish_input(codec.context, &value);
    const third = frame(5, "def", bytes[first + second ..]).?;
    const partial = first + second + 2;
    try expectProgress(codec.vtable.decode(codec.context, &value, bytes[0..partial], &packets), partial, 2, true);
    codec.vtable.finish_input(codec.context, &value);
    try expectProgress(codec.vtable.decode(codec.context, &value, bytes[partial .. first + second + third], &packets), third - 2, 1, false);
}

test "stream decoder rejects malformed and oversized frames" {
    const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(protocol_versions.default)});
    const codec = catalog.protocols[0].codec;
    var value = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 } };
    var packets: [1]minecraft.Packet = undefined;
    try std.testing.expectEqual(minecraft.Codec.Decode.malformed, codec.vtable.decode(codec.context, &value, &.{ 0xff, 0xff, 0xff, 0xff, 0x7f }, &packets));
    try std.testing.expectEqual(minecraft.Codec.Decode.malformed, codec.vtable.decode(codec.context, &value, &.{ 0xff, 0xff, 0x03 }, &packets));
}

test "encrypted fragmented stream decrypts in place before framing" {
    const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(protocol_versions.default)});
    const codec = catalog.protocols[0].codec;
    const secret = [_]u8{0x29} ** 16;
    var value = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 } };
    value.enableEncryption(secret);
    var bytes: [32]u8 = undefined;
    const len = frame(7, "fragment", &bytes).?;
    var peer = @import("crypto_support.zig").Cfb8.init(secret);
    peer.encrypt(bytes[0..len]);
    var packets: [1]minecraft.Packet = undefined;
    value.decrypt(bytes[0..2]);
    try expectProgress(codec.vtable.decode(codec.context, &value, bytes[0..2], &packets), 2, 0, true);
    value.decrypt(bytes[2..len]);
    try expectProgress(codec.vtable.decode(codec.context, &value, bytes[2..len], &packets), len - 2, 1, false);
    try std.testing.expectEqualStrings("\x07fragment", packets[0].bytes);
}

test "compression action state round trips framed packets" {
    const catalog = Catalog([_]protocol_versions.Support{protocol_versions.support(protocol_versions.default)});
    const codec = catalog.protocols[0].codec;
    var value = minecraft.Session{ .connection = .{ .index = 0, .generation = 1 }, .compression_threshold = 0 };
    var encoded: [256]u8 = undefined;
    const len = codec.vtable.encode(codec.context, &value, 9, "compress me compress me", &encoded).?;
    var packets: [1]minecraft.Packet = undefined;
    const progress = switch (codec.vtable.decode(codec.context, &value, encoded[0..len], &packets)) {
        .malformed => return error.UnexpectedMalformed,
        .progress => |item| item,
    };
    try std.testing.expectEqual(@as(usize, 1), progress.packets);
    try std.testing.expectEqualStrings("\x09compress me compress me", packets[0].bytes);
}

fn expectProgress(result: minecraft.Codec.Decode, consumed: usize, packets: usize, needs_more: bool) !void {
    const progress = switch (result) {
        .malformed => return error.UnexpectedMalformed,
        .progress => |value| value,
    };
    try std.testing.expectEqual(consumed, progress.consumed);
    try std.testing.expectEqual(packets, progress.packets);
    try std.testing.expectEqual(needs_more, progress.needs_more);
}
