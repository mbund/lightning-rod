const connection = @import("connection_api.zig");
const configuration = @import("configuration_plan.zig");
const crypto = @import("crypto_support.zig");
const session = @import("session_api.zig");
const std = @import("std");

pub const Codec = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const max_state_bytes = 64 * 1024;
    pub const max_packet_bytes = 384 * 1024;
    pub const Progress = struct { consumed: usize, packets: usize, needs_more: bool = false };
    pub const Decode = union(enum) { malformed, progress: Progress };
    pub const VTable = struct {
        init: *const fn (*anyopaque, *Session) bool,
        decode: *const fn (*anyopaque, *Session, []const u8, []Packet) Decode,
        finish_input: *const fn (*anyopaque, *Session) void,
        classify: *const fn (*anyopaque, session.Phase, Packet) Disposition,
        frame_payload: *const fn (*anyopaque, *Session, []const u8, []u8) ?usize = framePayloadUnavailable,
        start_configuration: *const fn (*anyopaque, *Session, []u8) ?usize,
        configuration_entry: ?*const fn (*anyopaque, *Session, configuration.Entry, []u8) ?usize = null,
        finish_configuration: ?*const fn (*anyopaque, *Session, []u8) ?usize = null,
        encryption_request: ?*const fn (*anyopaque, *Session, session.Authentication.EncryptionRequest, []u8) ?usize = null,
        set_compression: ?*const fn (*anyopaque, *Session, i32, []u8) ?usize = null,
        login_success: ?*const fn (*anyopaque, *Session, u128, []const u8, []u8) ?usize = null,
        disconnect: ?*const fn (*anyopaque, *Session, []u8) ?usize = null,
        encoded_capacity: *const fn (*anyopaque, *const Session, i32, []const u8) ?usize,
        encode: *const fn (*anyopaque, *Session, i32, []const u8, []u8) ?usize,
        status: *const fn (*anyopaque, i32, []const u8, []u8) ?usize,
    };
};

fn framePayloadUnavailable(_: *anyopaque, _: *Session, _: []const u8, _: []u8) ?usize {
    return null;
}

pub const Continuation = struct {
    pub const fixed_bytes = 1 + 1 + 4 + 16 + 1 + 1 + 1 + 8 + 1 + (1 + 16 + 16) * 2 + 1 + 4 + 2;
    pub const maximum_bytes = fixed_bytes + 16 + 16 + Codec.max_state_bytes;
};

pub const PacketStorage = enum(u8) { input_page, session };
pub const Packet = struct { id: i32, bytes: []const u8, storage: PacketStorage };
pub const EncryptionResponse = struct { shared_secret: []const u8, verify_token: []const u8 };
pub const Protocol = struct { number: i32, codec: Codec };
pub const HandshakeValue = union(enum) { status: i32, login: i32 };
pub const Handshake = union(enum) { malformed, progress: struct { consumed: usize, value: ?HandshakeValue } };
pub const HandshakeDecoder = struct {
    context: *anyopaque,
    decode: *const fn (*anyopaque, *Session, []const u8) Handshake,
};
pub const Disposition = union(enum) {
    core,
    ignored,
    begin_login: []const u8,
    encryption_response: EncryptionResponse,
    login_acknowledged,
    configuration_known_packs,
    status_request,
    status_ping: []const u8,
    finish_configuration,
    invalid,
};

pub const Name = struct {
    bytes: [16]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Workspace = struct {
    decompression_window: [std.compress.flate.max_window_len]u8 = undefined,
    compression_window: [std.compress.flate.max_window_len]u8 = undefined,
    compression_scratch: [Codec.max_state_bytes]u8 = undefined,
};

pub const Session = struct {
    connection: connection.Handle,
    phase: session.Phase = .handshake,
    protocol: i32 = 0,
    uuid: u128 = 0,
    name: Name = .{},
    attached: bool = false,
    authentication_pending: bool = false,
    status_revision: u64 = 0,
    status_response_pending: bool = false,
    status_ping: [16]u8 = @splat(0),
    status_ping_len: u8 = 0,
    codec: ?Codec = null,
    codec_state: [Codec.max_state_bytes]u8 = undefined,
    codec_state_len: u16 = 0,
    codec_state_exposed: bool = false,
    decoded_state: [Codec.max_state_bytes]u8 = undefined,
    workspace: ?*Workspace = null,
    auth_deadline_ns: u64 = 0,
    authentication_challenged: bool = false,
    closing: ?connection.DisconnectReason = null,
    retained_page: ?connection.Page = null,
    retained_offset: u32 = 0,
    compression_threshold: ?i32 = null,
    configuration_step: u8 = 0,
    configuration_barrier: bool = false,
    encryptor: ?crypto.Cfb8 = null,
    decryptor: ?crypto.Cfb8 = null,

    pub fn enterConfiguration(self: *Session) void {
        self.phase = .configuration;
        self.configuration_step = 0;
        self.configuration_barrier = false;
    }

    pub fn finishConfiguration(self: *Session) bool {
        if (self.phase != .configuration) return false;
        self.phase = .play;
        const attaching = !self.attached;
        self.attached = true;
        return attaching;
    }

    pub fn reconfigure(self: *Session) bool {
        if (self.phase != .play) return false;
        self.enterConfiguration();
        return true;
    }

    pub fn enableEncryption(self: *Session, secret: [16]u8) void {
        self.encryptor = crypto.Cfb8.init(secret);
        self.decryptor = crypto.Cfb8.init(secret);
    }

    pub fn decrypt(self: *Session, bytes: []u8) void {
        if (self.decryptor) |*cipher| cipher.decrypt(bytes);
    }

    pub fn encrypt(self: *Session, bytes: []u8) void {
        if (self.encryptor) |*cipher| cipher.encrypt(bytes);
    }
};

test "play may return to configuration without losing session identity" {
    var value = Session{ .connection = .{ .index = 2, .generation = 4 }, .phase = .play, .protocol = 769, .uuid = 9, .attached = true };
    try @import("std").testing.expect(value.reconfigure());
    try @import("std").testing.expectEqual(session.Phase.configuration, value.phase);
    try @import("std").testing.expectEqual(@as(u128, 9), value.uuid);
}

test "encrypted input remains a single CFB8 stream across fragments" {
    const secret = [_]u8{0x37} ** 16;
    var session_value = Session{ .connection = .{ .index = 0, .generation = 1 } };
    session_value.enableEncryption(secret);
    var expected = [_]u8{ 1, 0, 127, 128, 3, 9, 22 };
    var ciphertext = expected;
    var peer = crypto.Cfb8.init(secret);
    peer.encrypt(&ciphertext);
    session_value.decrypt(ciphertext[0..2]);
    session_value.decrypt(ciphertext[2..5]);
    session_value.decrypt(ciphertext[5..]);
    try std.testing.expectEqualSlices(u8, &expected, &ciphertext);
}
