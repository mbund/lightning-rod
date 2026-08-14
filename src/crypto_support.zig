const std = @import("std");
const server_key = @import("server_key.zig");

const rsa_bytes = 128;
const rsa_bits = rsa_bytes * 8;
const prime_bits = rsa_bits / 2;
const RsaInt = u1024;
const RsaWide = u2048;
const PrimeInt = u512;
const PrimeWide = u1024;
const public_exponent: u32 = 65537;

pub const Identity = struct {
    modulus: RsaInt,
    p: PrimeInt,
    q: PrimeInt,
    dp: PrimeInt,
    dq: PrimeInt,
    q_inverse: PrimeInt,
    public_key_der: [162]u8,

    pub fn init() Identity {
        return .{
            .modulus = server_key.modulus,
            .p = server_key.p,
            .q = server_key.q,
            .dp = server_key.dp,
            .dq = server_key.dq,
            .q_inverse = server_key.q_inverse,
            .public_key_der = encodePublicKey(server_key.modulus),
        };
    }

    pub fn deinit(self: *Identity) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&self.p));
        std.crypto.secureZero(u8, std.mem.asBytes(&self.q));
        std.crypto.secureZero(u8, std.mem.asBytes(&self.dp));
        std.crypto.secureZero(u8, std.mem.asBytes(&self.dq));
        std.crypto.secureZero(u8, std.mem.asBytes(&self.q_inverse));
    }

    pub fn publicKey(self: *const Identity) []const u8 {
        return &self.public_key_der;
    }

    pub fn decrypt(self: *const Identity, output: []u8, ciphertext: []const u8) ![]u8 {
        if (ciphertext.len != rsa_bytes or output.len == 0 or output.len > rsa_bytes - 11) return error.RsaDecryptFailed;
        const encoded = std.mem.readInt(RsaInt, ciphertext[0..rsa_bytes], .big);
        if (encoded >= self.modulus) return error.RsaDecryptFailed;
        const m1 = powModPrime(@intCast(encoded % self.p), self.dp, self.p) catch return error.RsaDecryptFailed;
        const m2 = powModPrime(@intCast(encoded % self.q), self.dq, self.q) catch return error.RsaDecryptFailed;
        const m2_mod_p = m2 % self.p;
        const difference = if (m1 >= m2_mod_p) m1 - m2_mod_p else self.p - (m2_mod_p - m1);
        const h = mulModPrime(self.q_inverse, difference, self.p) catch return error.RsaDecryptFailed;
        const message: RsaInt = @as(RsaInt, m2) + @as(RsaInt, self.q) * @as(RsaInt, h);
        var block: [rsa_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &block);
        std.mem.writeInt(RsaInt, &block, message, .big);

        const separator = rsa_bytes - output.len - 1;
        var valid = block[0] == 0 and block[1] == 2 and separator >= 10 and block[separator] == 0;
        for (block[2..separator]) |byte| valid = valid and byte != 0;
        if (!valid) return error.RsaDecryptFailed;
        @memcpy(output, block[separator + 1 ..]);
        return output;
    }
};

fn powModPrime(base_value: PrimeInt, exponent_value: PrimeInt, modulus: PrimeInt) !PrimeInt {
    const Field = std.crypto.ff.Modulus(prime_bits);
    var modulus_bytes: [prime_bits / 8]u8 = undefined;
    std.mem.writeInt(PrimeInt, &modulus_bytes, modulus, .big);
    const field = try Field.fromBytes(&modulus_bytes, .big);
    var base_bytes: [prime_bits / 8]u8 = undefined;
    std.mem.writeInt(PrimeInt, &base_bytes, base_value, .big);
    const base = try Field.Fe.fromBytes(field, &base_bytes, .big);
    var exponent_bytes: [prime_bits / 8]u8 = undefined;
    std.mem.writeInt(PrimeInt, &exponent_bytes, exponent_value, .big);
    const result = try field.powWithEncodedExponent(base, &exponent_bytes, .big);
    var result_bytes: [prime_bits / 8]u8 = undefined;
    try result.toBytes(&result_bytes, .big);
    return std.mem.readInt(PrimeInt, &result_bytes, .big);
}

fn mulModPrime(a: PrimeInt, b: PrimeInt, modulus: PrimeInt) !PrimeInt {
    const Field = std.crypto.ff.Modulus(prime_bits);
    var modulus_bytes: [prime_bits / 8]u8 = undefined;
    std.mem.writeInt(PrimeInt, &modulus_bytes, modulus, .big);
    const field = try Field.fromBytes(&modulus_bytes, .big);
    var a_bytes: [prime_bits / 8]u8 = undefined;
    var b_bytes: [prime_bits / 8]u8 = undefined;
    std.mem.writeInt(PrimeInt, &a_bytes, a, .big);
    std.mem.writeInt(PrimeInt, &b_bytes, b, .big);
    const a_fe = try Field.Fe.fromBytes(field, &a_bytes, .big);
    const b_fe = try Field.Fe.fromBytes(field, &b_bytes, .big);
    const result = field.mul(a_fe, b_fe);
    var result_bytes: [prime_bits / 8]u8 = undefined;
    try result.toBytes(&result_bytes, .big);
    return std.mem.readInt(PrimeInt, &result_bytes, .big);
}

fn powModRsa(base_value: RsaInt, exponent_value: RsaInt, modulus: RsaInt) RsaInt {
    var result: RsaInt = 1;
    var base = base_value % modulus;
    var exponent = exponent_value;
    while (exponent != 0) : (exponent >>= 1) {
        if (exponent & 1 != 0) result = mulModRsa(result, base, modulus);
        base = mulModRsa(base, base, modulus);
    }
    return result;
}

fn mulModRsa(a: RsaInt, b: RsaInt, modulus: RsaInt) RsaInt {
    return @intCast((@as(RsaWide, a) * @as(RsaWide, b)) % modulus);
}

fn encodePublicKey(modulus: RsaInt) [162]u8 {
    var der: [162]u8 = undefined;
    const prefix = [_]u8{
        0x30, 0x81, 0x9f,
        0x30, 0x0d, 0x06,
        0x09, 0x2a, 0x86,
        0x48, 0x86, 0xf7,
        0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00,
        0x03, 0x81, 0x8d,
        0x00, 0x30, 0x81,
        0x89, 0x02, 0x81,
        0x81, 0x00,
    };
    @memcpy(der[0..prefix.len], &prefix);
    std.mem.writeInt(RsaInt, der[prefix.len..][0..rsa_bytes], modulus, .big);
    const suffix = [_]u8{ 0x02, 0x03, 0x01, 0x00, 0x01 };
    @memcpy(der[prefix.len + rsa_bytes ..], &suffix);
    return der;
}

pub const Cfb8 = struct {
    aes: std.crypto.core.aes.AesEncryptCtx(std.crypto.core.aes.Aes128),
    feedback: [16]u8,

    pub fn init(secret: [16]u8) Cfb8 {
        return .{ .aes = std.crypto.core.aes.Aes128.initEnc(secret), .feedback = secret };
    }

    pub fn encrypt(self: *Cfb8, bytes: []u8) void {
        for (bytes) |*byte| {
            var stream: [16]u8 = undefined;
            self.aes.encrypt(&stream, &self.feedback);
            const ciphertext = byte.* ^ stream[0];
            shiftFeedback(&self.feedback, ciphertext);
            byte.* = ciphertext;
        }
    }

    pub fn decrypt(self: *Cfb8, bytes: []u8) void {
        for (bytes) |*byte| {
            var stream: [16]u8 = undefined;
            self.aes.encrypt(&stream, &self.feedback);
            const ciphertext = byte.*;
            byte.* = ciphertext ^ stream[0];
            shiftFeedback(&self.feedback, ciphertext);
        }
    }
};

fn shiftFeedback(feedback: *[16]u8, byte: u8) void {
    var register: u128 = @bitCast(feedback.*);
    register = (register >> 8) | (@as(u128, byte) << 120);
    feedback.* = @bitCast(register);
}

test "CFB8 streams round trip across arbitrary boundaries" {
    const secret = [_]u8{0x42} ** 16;
    var encryptor = Cfb8.init(secret);
    var decryptor = Cfb8.init(secret);
    var bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 };
    const expected = bytes;
    encryptor.encrypt(bytes[0..3]);
    encryptor.encrypt(bytes[3..]);
    decryptor.decrypt(bytes[0..11]);
    decryptor.decrypt(bytes[11..]);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}

test "RSA public key uses the Minecraft 1024-bit DER shape" {
    var identity = Identity.init();
    defer identity.deinit();
    try std.testing.expectEqual(@as(usize, 162), identity.publicKey().len);
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x81, 0x9f }, identity.publicKey()[0..3]);

    const secret = [_]u8{0xa5} ** 16;
    var encoded = [_]u8{0x7f} ** rsa_bytes;
    encoded[0] = 0;
    encoded[1] = 2;
    encoded[rsa_bytes - secret.len - 1] = 0;
    @memcpy(encoded[rsa_bytes - secret.len ..], &secret);
    const message = std.mem.readInt(RsaInt, &encoded, .big);
    const ciphertext_value = powModRsa(message, public_exponent, identity.modulus);
    var ciphertext: [rsa_bytes]u8 = undefined;
    std.mem.writeInt(RsaInt, &ciphertext, ciphertext_value, .big);
    var decrypted: [secret.len]u8 = undefined;
    _ = try identity.decrypt(&decrypted, &ciphertext);
    try std.testing.expectEqualSlices(u8, &secret, &decrypted);
}
