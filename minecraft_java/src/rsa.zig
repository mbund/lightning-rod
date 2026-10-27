const std = @import("std");
const modulus_bits = 2048;
const Modulus = std.crypto.ff.Modulus(modulus_bits);
const Prime = std.crypto.ff.Modulus(modulus_bits / 2);

const rsa_algorithm = "\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00";
const public_exponent = "\x01\x00\x01";
// SubjectPublicKeyInfo for a 2048-bit RSA modulus and exponent 65537.
const public_key_prefix = "\x30\x82\x01\x22\x30\x0d" ++ rsa_algorithm ++ "\x03\x82\x01\x0f\x00\x30\x82\x01\x0a\x02\x82\x01\x01";
const public_key_suffix = "\x02\x03" ++ public_exponent;

pub const PrivateKey = struct {
    pub const ciphertext_bytes = modulus_bits / 8;
    pub const DecryptError = error{ InvalidCiphertext, CryptoFailure };

    modulus: Modulus,
    p: Prime,
    q: Prime,
    exponent_p: [ciphertext_bytes / 2]u8,
    exponent_q: [ciphertext_bytes / 2]u8,
    inverse_q: Prime.Fe,
    value_q: Modulus.Fe,
    public_key: [public_key_prefix.len + ciphertext_bytes + 1 + public_key_suffix.len]u8,

    pub fn read(io: std.Io, path: []const u8) !PrivateKey {
        var buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        const encoded = try std.Io.Dir.cwd().readFile(io, path, &buffer);
        if (encoded.len == buffer.len) return error.InvalidEncryptionKey;
        return init(encoded);
    }

    pub fn init(encoded: []const u8) error{InvalidEncryptionKey}!PrivateKey {
        return parse(encoded) catch return error.InvalidEncryptionKey;
    }

    fn parse(encoded: []const u8) !PrivateKey {
        if (encoded.len == 0 or encoded.len > 4096) return error.InvalidEncryptionKey;
        var document: std.crypto.codecs.asn1.der.Decoder = .{ .bytes = encoded };
        var envelope: std.crypto.codecs.asn1.der.Decoder = .{ .bytes = try element(&document, .sequence) };
        if (document.index != encoded.len) return error.InvalidEncryptionKey;
        if (!std.mem.eql(u8, try integer(&envelope), &.{0})) return error.InvalidEncryptionKey;
        if (!std.mem.eql(u8, try element(&envelope, .sequence), rsa_algorithm)) return error.InvalidEncryptionKey;
        var private: std.crypto.codecs.asn1.der.Decoder = .{ .bytes = try element(&envelope, .octetstring) };
        if (envelope.index != envelope.bytes.len) return error.InvalidEncryptionKey;
        var fields: std.crypto.codecs.asn1.der.Decoder = .{ .bytes = try element(&private, .sequence) };
        if (private.index != private.bytes.len) return error.InvalidEncryptionKey;
        if (!std.mem.eql(u8, try integer(&fields), &.{0})) return error.InvalidEncryptionKey;
        const n = try integer(&fields);
        const e = try integer(&fields);
        const d = try unsignedInteger(&fields);
        const p = try unsignedInteger(&fields);
        const q = try unsignedInteger(&fields);
        const dp = try unsignedInteger(&fields);
        const dq = try unsignedInteger(&fields);
        const inverse = try unsignedInteger(&fields);
        if (fields.index != fields.bytes.len) return error.InvalidEncryptionKey;
        if (n.len != ciphertext_bytes + 1 or n[0] != 0 or n[1] & 0x80 == 0) return error.InvalidEncryptionKey;
        if (!std.mem.eql(u8, e, public_exponent)) return error.InvalidEncryptionKey;
        if (d.len > ciphertext_bytes or d[d.len - 1] & 1 == 0) return error.InvalidEncryptionKey;
        if (p.len != ciphertext_bytes / 2 or q.len != ciphertext_bytes / 2 or p[0] & 0x80 == 0 or q[0] & 0x80 == 0) return error.InvalidEncryptionKey;
        if (dp.len > ciphertext_bytes / 2 or dq.len > ciphertext_bytes / 2 or dp[dp.len - 1] & 1 == 0 or dq[dq.len - 1] & 1 == 0) return error.InvalidEncryptionKey;
        const modulus = try Modulus.fromBytes(n[1..], .big);
        _ = try Modulus.Fe.fromBytes(modulus, d, .big);
        const prime_p = try Prime.fromBytes(p, .big);
        const prime_q = try Prime.fromBytes(q, .big);
        _ = try Prime.Fe.fromBytes(prime_p, dp, .big);
        _ = try Prime.Fe.fromBytes(prime_q, dq, .big);
        const value_p = try Modulus.Fe.fromBytes(modulus, p, .big);
        const value_q = try Modulus.Fe.fromBytes(modulus, q, .big);
        const inverse_q = try Prime.Fe.fromBytes(prime_p, inverse, .big);
        if (!modulus.mul(value_p, value_q).isZero()) return error.InvalidEncryptionKey;
        if (!prime_p.mul(prime_p.reduce(value_q.v), inverse_q).eql(prime_p.one())) return error.InvalidEncryptionKey;

        var result: PrivateKey = .{
            .modulus = modulus,
            .p = prime_p,
            .q = prime_q,
            .exponent_p = @splat(0),
            .exponent_q = @splat(0),
            .inverse_q = inverse_q,
            .value_q = value_q,
            .public_key = undefined,
        };
        @memcpy(result.exponent_p[result.exponent_p.len - dp.len ..], dp);
        @memcpy(result.exponent_q[result.exponent_q.len - dq.len ..], dq);
        @memcpy(result.public_key[0..public_key_prefix.len], public_key_prefix);
        @memcpy(result.public_key[public_key_prefix.len..][0..n.len], n);
        @memcpy(result.public_key[public_key_prefix.len + n.len ..], public_key_suffix);
        return result;
    }

    pub fn deinit(self: *PrivateKey) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    pub fn publicKey(self: *const PrivateKey) []const u8 {
        return &self.public_key;
    }

    pub fn decrypt(self: *const PrivateKey, ciphertext: []const u8, output: []u8) DecryptError!void {
        if (ciphertext.len != ciphertext_bytes or output.len == 0 or output.len > ciphertext_bytes - 11) return error.InvalidCiphertext;
        const encrypted = Modulus.Fe.fromBytes(self.modulus, ciphertext, .big) catch return error.InvalidCiphertext;
        var left = self.p.powWithEncodedExponent(self.p.reduce(encrypted.v), &self.exponent_p, .big) catch return error.CryptoFailure;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&left));
        var right = self.q.powWithEncodedExponent(self.q.reduce(encrypted.v), &self.exponent_q, .big) catch return error.CryptoFailure;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&right));
        var coefficient = self.p.mul(self.inverse_q, self.p.sub(left, self.p.reduce(right.v)));
        defer std.crypto.secureZero(u8, std.mem.asBytes(&coefficient));
        var plaintext: [ciphertext_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &plaintext);
        right.toBytes(&plaintext, .big) catch return error.CryptoFailure;
        var right_wide = Modulus.Fe.fromBytes(self.modulus, &plaintext, .big) catch return error.CryptoFailure;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&right_wide));
        coefficient.toBytes(&plaintext, .big) catch return error.CryptoFailure;
        var coefficient_wide = Modulus.Fe.fromBytes(self.modulus, &plaintext, .big) catch return error.CryptoFailure;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&coefficient_wide));
        var decrypted = self.modulus.add(right_wide, self.modulus.mul(self.value_q, coefficient_wide));
        defer std.crypto.secureZero(u8, std.mem.asBytes(&decrypted));
        const verified = self.modulus.powWithEncodedPublicExponent(decrypted, public_exponent, .big) catch return error.CryptoFailure;
        if (!verified.eql(encrypted)) return error.CryptoFailure;
        decrypted.toBytes(&plaintext, .big) catch return error.CryptoFailure;

        // The expected plaintext length fixes the separator position and all padding checks.
        const separator = ciphertext_bytes - output.len - 1;
        var invalid = plaintext[0] | (plaintext[1] ^ 2) | plaintext[separator];
        for (plaintext[2..separator]) |byte| invalid |= @intFromBool(byte == 0);
        if (invalid != 0) return error.InvalidCiphertext;
        @memcpy(output, plaintext[separator + 1 ..]);
    }
};

fn element(decoder: *std.crypto.codecs.asn1.der.Decoder, tag: std.crypto.codecs.asn1.Tag.Number) ![]const u8 {
    const value = try decoder.element(.init(tag, tag == .sequence, .universal));
    decoder.index = value.slice.end;
    return decoder.view(value);
}

fn integer(decoder: *std.crypto.codecs.asn1.der.Decoder) ![]const u8 {
    const bytes = try element(decoder, .integer);
    if (bytes.len == 0 or bytes[0] & 0x80 != 0) return error.InvalidEncryptionKey;
    if (bytes.len > 1 and bytes[0] == 0 and bytes[1] & 0x80 == 0) return error.InvalidEncryptionKey;
    return bytes;
}

fn unsignedInteger(decoder: *std.crypto.codecs.asn1.der.Decoder) ![]const u8 {
    const bytes = try integer(decoder);
    return if (bytes.len > 1 and bytes[0] == 0) bytes[1..] else bytes;
}
