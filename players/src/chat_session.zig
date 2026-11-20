const std = @import("std");
const RsaPublicKey = @import("minecraft_java").RsaPublicKey;
const assert = std.debug.assert;

/// The key a player's client signs chat with, as it tells the server: a session id, the key and
/// when Mojang lets it lapse, and Mojang's signature over the player's UUID, the expiry and the
/// key. The server never checks Mojang's signature, and needs no keys of Mojang's: every client
/// checks it of every other player against its own copy of them, as vanilla's
/// ClientPacketListener.initializeChatSession does. The server checks the key is one Mojang
/// issues and, with it, each message the player signs.
pub const ChatSession = struct {
    pub const key_bytes = RsaPublicKey.encoded_bytes;
    /// Mojang signs with a 4096-bit key. Vanilla takes up to 4096 bytes; nothing it issues is longer.
    pub const key_signature_max = 512;
    /// What a player info entry carries of one: the session id, the expiry, and the key and its
    /// signature with their two-byte length prefixes.
    pub const encoded_max = 16 + 8 + 2 + key_bytes + 2 + key_signature_max;

    id: u128,
    /// When Mojang lets the key lapse, in milliseconds since the epoch.
    expires_at: i64,
    key: [key_bytes]u8,
    key_signature: [key_signature_max]u8,
    key_signature_len: u16,
    public_key: RsaPublicKey,

    pub fn init(id: u128, expires_at: i64, key: []const u8, key_signature: []const u8) error{InvalidPublicKey}!ChatSession {
        if (key_signature.len == 0 or key_signature.len > key_signature_max) return error.InvalidPublicKey;
        var session: ChatSession = .{
            .id = id,
            .expires_at = expires_at,
            .key = undefined,
            .key_signature = undefined,
            .key_signature_len = @intCast(key_signature.len),
            .public_key = try RsaPublicKey.init(key),
        };
        // A key RsaPublicKey takes is exactly the encoding Mojang issues.
        assert(key.len == key_bytes);
        @memcpy(&session.key, key);
        @memcpy(session.key_signature[0..key_signature.len], key_signature);
        assert(session.key_signature_len > 0 and session.key_signature_len <= key_signature_max);
        return session;
    }

    pub fn keySignature(self: *const ChatSession) []const u8 {
        assert(self.key_signature_len > 0 and self.key_signature_len <= key_signature_max);
        return self.key_signature[0..self.key_signature_len];
    }

    /// Whether a session update names this key again. Vanilla takes that as nothing new, even
    /// under another session id, so the chain goes on.
    pub fn sameKey(self: *const ChatSession, expires_at: i64, key: []const u8, key_signature: []const u8) bool {
        return self.expires_at == expires_at and std.mem.eql(u8, &self.key, key) and std.mem.eql(u8, self.keySignature(), key_signature);
    }

    pub fn expired(self: *const ChatSession, now_ms: i64) bool {
        return self.expires_at < now_ms;
    }
};
