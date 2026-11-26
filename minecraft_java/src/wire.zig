const std = @import("std");
const sessions = @import("sessions");
const Cipher = @import("cipher.zig").Cipher;
const compression = @import("compression.zig");
const fields = sessions.fields;

pub const Wire = struct {
    pub const Workspace = compression.Workspace;
    pub const always_copy = false;
    /// A frame that does not compress adds its length, three bytes at most, and the zero length
    /// that says it is not compressed; encryption keeps every length.
    pub const frame_bound: sessions.protocol.Protocol.FrameBound = .{ .plain_overhead = 4 };
    pub const Encryption = Cipher.Encryption;
    pub const encryption_batch_size = Cipher.batch_size;
    pub const encryptBatch = Cipher.encryptBatch;

    compressed: bool = false,
    receive_cipher: ?Cipher = null,
    send_cipher: ?Cipher = null,

    pub fn encrypted(self: *const Wire) bool {
        return self.receive_cipher != null;
    }

    pub fn install(self: *Wire, secret: [16]u8) void {
        std.debug.assert(self.receive_cipher == null and self.send_cipher == null);
        self.receive_cipher = Cipher.init(secret);
        self.send_cipher = Cipher.init(secret);
    }

    pub fn receive(self: *Wire, bytes: []u8) void {
        if (self.receive_cipher) |*cipher| cipher.transform(.decrypt, bytes, bytes);
    }

    pub fn send(self: *Wire, bytes: []u8) void {
        if (self.send_cipher) |*cipher| cipher.transform(.encrypt, bytes, bytes);
    }

    pub fn encrypt(self: *Wire, source: []const u8, destination: []u8) void {
        self.send_cipher.?.transform(.encrypt, source, destination);
    }

    pub const Stream = Cipher.Stream;
    pub const encryptStreams = Cipher.encryptStreams;

    /// Bytes to encrypt in place as the send stream continues, unless sends are not encrypted.
    pub fn sendStream(self: *Wire, bytes: []u8) ?Stream {
        const cipher = if (self.send_cipher) |*value| value else return null;
        return .{ .cipher = cipher, .bytes = bytes };
    }

    pub fn encryption(self: *Wire, first: []u8, second: []u8) Encryption {
        return .{ .cipher = &self.send_cipher.?, .first = first, .second = second };
    }

    // Released tags of the wire in a saved connection; the connection's phase is tag 1.
    const compressed_tag: fields.Tag = 2;
    const secret_tag: fields.Tag = 3;
    const receive_feedback_tag: fields.Tag = 4;
    const send_feedback_tag: fields.Tag = 5;

    /// Compression, and for an encrypted wire the shared secret and where each direction's cipher
    /// stream stands, which the next process must continue from exactly.
    pub fn writeFields(self: *const Wire, writer: *std.Io.Writer) !void {
        if (self.compressed) try fields.writeInt(writer, compressed_tag, u8, 1);
        if (self.receive_cipher) |cipher| {
            try fields.writeBytes(writer, secret_tag, &cipher.secret);
            try fields.writeBytes(writer, receive_feedback_tag, &cipher.feedback);
            try fields.writeBytes(writer, send_feedback_tag, &self.send_cipher.?.feedback);
        }
    }

    /// A wire's fields as they are read, in whatever list holds them.
    pub const Saved = struct {
        compressed: bool = false,
        secret: ?[16]u8 = null,
        receive_feedback: ?[16]u8 = null,
        send_feedback: ?[16]u8 = null,

        /// Whether the field was the wire's, and so read.
        pub fn read(self: *Saved, list: *fields.Reader, field: fields.Field) !bool {
            switch (field.tag) {
                compressed_tag => self.compressed = switch (try list.int(field, u8)) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidResume,
                },
                secret_tag => self.secret = try block(list, field),
                receive_feedback_tag => self.receive_feedback = try block(list, field),
                send_feedback_tag => self.send_feedback = try block(list, field),
                else => return false,
            }
            return true;
        }

        fn block(list: *fields.Reader, field: fields.Field) ![16]u8 {
            var value: [16]u8 = undefined;
            if (field.len != value.len) return error.InvalidResume;
            _ = try list.bytes(field, &value);
            return value;
        }

        pub fn restore(self: Saved) !Wire {
            var wire: Wire = .{ .compressed = self.compressed };
            if (self.secret) |secret| {
                wire.install(secret);
                wire.receive_cipher.?.feedback = self.receive_feedback orelse return error.InvalidResume;
                wire.send_cipher.?.feedback = self.send_feedback orelse return error.InvalidResume;
            } else if (self.receive_feedback != null or self.send_feedback != null) return error.InvalidResume;
            return wire;
        }
    };

    /// The most `save` writes.
    pub const saved_max = fields.intBytes(u8) + 3 * fields.fieldBytes(16) + fields.end_bytes;

    /// The wire on its own as a tagged list.
    pub fn save(self: *const Wire, bytes: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(bytes);
        self.writeFields(&writer) catch return error.BufferTooSmall;
        fields.writeEnd(&writer) catch return error.BufferTooSmall;
        return writer.buffered();
    }

    pub fn restore(bytes: []const u8) !Wire {
        var reader: std.Io.Reader = .fixed(bytes);
        var list: fields.Reader = .init(&reader);
        var saved: Saved = .{};
        while (try list.next()) |field| if (!try saved.read(&list, field)) try list.skip(field);
        if (reader.seek != bytes.len) return error.InvalidResume;
        return saved.restore();
    }

    pub fn clear(self: *Wire) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    pub fn frame(bytes: []const u8, maximum: usize) !sessions.protocol.Frame {
        const parsed = try sessions.frame(bytes, maximum);
        return .{ .body = parsed.body, .length = parsed.length };
    }

    pub fn decode(self: *Wire, input: []const u8, destination: []u8, workspace: *Workspace, threshold: ?usize) ![]const u8 {
        return if (self.compressed) try workspace.decode(input, threshold, destination) else input;
    }

    pub fn control(self: *Wire, packet: sessions.protocol.Packet, output: []u8, workspace: *Workspace, threshold: ?usize) !sessions.protocol.Fragments {
        const source = switch (packet) {
            .buffered => |value| value.storage[compression.headroom..][0..value.length],
            .borrowed => |bytes| bytes,
        };
        if (source.len == 0 or source.len > compression.maximum) return error.InvalidPacket;
        if (threshold != null and source.len >= threshold.?) {
            const result = try workspace.compress(source, output);
            self.send(result);
            return .{ .first = result };
        }
        if (packet == .buffered) {
            const value = packet.buffered;
            const result = try workspace.encode(value.storage, value.length, threshold, output);
            self.send(result);
            return .{ .first = result };
        }
        const zero: usize = @intFromBool(threshold != null);
        const body_length = source.len + zero;
        if (body_length > compression.maximum or output.len < compression.headroom) return error.BufferTooSmall;
        const width: usize = if (body_length < 128) 1 else if (body_length < 16384) 2 else 3;
        for (output[0..width], 0..) |*byte, index| {
            byte.* = @as(u8, @intCast((body_length >> @intCast(index * 7)) & 127)) | (@as(u8, @intFromBool(index + 1 < width)) << 7);
        }
        if (threshold != null) output[width] = 0;
        const prefix = width + zero;
        if (self.encrypted()) {
            if (source.len > output.len - prefix) return error.BufferTooSmall;
            self.send(output[0..prefix]);
            self.encrypt(source, output[prefix..][0..source.len]);
            return .{ .first = output[0 .. prefix + source.len] };
        }
        return .{ .first = output[0..prefix], .second = source };
    }

    pub fn prepared(workspace: *Workspace, storage: []u8, length: usize, decoded_length: usize, threshold: ?usize, destination: []u8) ![]const u8 {
        return workspace.prepared(storage, length, decoded_length, threshold, destination);
    }

    pub fn shared(workspace: *Workspace, storage: []u8, length: usize, threshold: ?usize, destination: []u8) ![]const u8 {
        return workspace.encode(storage, length, threshold, destination);
    }
};
