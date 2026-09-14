const std = @import("std");
const sessions = @import("sessions");

pub const Encryption = struct {
    key: *Key,
    reject: bool,
    der: [512]u8,
    length: usize,

    pub fn init(reject: bool) !Encryption {
        const generator = EVP_PKEY_CTX_new_from_name(null, "RSA", null) orelse return error.CryptoFailure;
        defer EVP_PKEY_CTX_free(generator);
        if (EVP_PKEY_keygen_init(generator) <= 0 or EVP_PKEY_CTX_set_rsa_keygen_bits(generator, 2048) <= 0) return error.CryptoFailure;

        var key: ?*Key = null;
        if (EVP_PKEY_keygen(generator, &key) <= 0) return error.CryptoFailure;
        errdefer EVP_PKEY_free(key.?);
        var der: [512]u8 = undefined;
        const length = i2d_PUBKEY(key.?, null);
        if (length <= 0 or length > der.len) return error.CryptoFailure;

        var cursor: [*]u8 = &der;
        const written = i2d_PUBKEY(key.?, &cursor);
        std.debug.assert(written == length);
        return .{ .key = key.?, .reject = reject, .der = der, .length = @intCast(length) };
    }

    pub fn deinit(self: *Encryption) void {
        EVP_PKEY_free(self.key);
    }

    pub fn interface(self: *Encryption) sessions.Encryption {
        return .{ .context = self, .public_key_der = self.der[0..self.length], .decrypt = decrypt };
    }
};

fn decrypt(raw: *anyopaque, _: std.Io, ciphertext: []const u8, output: []u8) error{ InvalidCiphertext, CryptoFailure }!void {
    const provider: *Encryption = @ptrCast(@alignCast(raw));
    const context = EVP_PKEY_CTX_new(provider.key, null) orelse return error.CryptoFailure;
    defer EVP_PKEY_CTX_free(context);
    if (EVP_PKEY_decrypt_init(context) <= 0 or EVP_PKEY_CTX_set_rsa_padding(context, 1) <= 0) return error.CryptoFailure;

    var plaintext: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &plaintext);
    var length: usize = plaintext.len;
    if (EVP_PKEY_decrypt(context, &plaintext, &length, ciphertext.ptr, ciphertext.len) <= 0 or length != output.len)
        return error.InvalidCiphertext;
    @memcpy(output, plaintext[0..length]);

    if (provider.reject and output.len == 4) output[0] ^= 1;
}

const Key = opaque {};
const Context = opaque {};
extern "crypto" fn EVP_PKEY_CTX_new_from_name(?*anyopaque, [*:0]const u8, ?[*:0]const u8) ?*Context;
extern "crypto" fn EVP_PKEY_CTX_new(*Key, ?*anyopaque) ?*Context;
extern "crypto" fn EVP_PKEY_CTX_free(*Context) void;
extern "crypto" fn EVP_PKEY_free(*Key) void;
extern "crypto" fn EVP_PKEY_keygen_init(*Context) c_int;
extern "crypto" fn EVP_PKEY_CTX_set_rsa_keygen_bits(*Context, c_int) c_int;
extern "crypto" fn EVP_PKEY_keygen(*Context, *?*Key) c_int;
extern "crypto" fn i2d_PUBKEY(*Key, ?*[*]u8) c_int;
extern "crypto" fn EVP_PKEY_decrypt_init(*Context) c_int;
extern "crypto" fn EVP_PKEY_CTX_set_rsa_padding(*Context, c_int) c_int;
extern "crypto" fn EVP_PKEY_decrypt(*Context, [*]u8, *usize, [*]const u8, usize) c_int;
