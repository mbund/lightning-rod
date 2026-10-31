const std = @import("std");
const java = @import("java");
const PrivateKey = java.RsaPrivateKey;

fn readKey(buffer: []u8) ![]const u8 {
    return std.Io.Dir.cwd().readFile(std.testing.io, "tests/fixtures/rsa-key.der", buffer);
}

test "RSA decrypts Java PKCS1 ciphertexts and exports the same public key" {
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var key = try PrivateKey.init(try readKey(&buffer));
    defer key.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key.publicKey(), &digest, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "ab7e72e9bfbee10174008e5faca28b294a6dfe4a90478df8b63f5d209ed81020");
    try std.testing.expectEqualSlices(u8, &expected, &digest);

    // Generated independently with Java's RSA/ECB/PKCS1Padding cipher.
    const vectors = .{
        .{ "0123456789abcdef", "4e0da925ea717ed0cf49b2e06d63a99c9e5e1c2df940d305ce9b50561e93e59af04706b23b069fd0143f65cca37312d80a640e556a6e68d3d2518ac85f0be96f5199c810728347a422d4b1528b3b0fed1b0854048536fcebe61de23dcf01e291f1844abdecd3b6125a41b8c9144ac73090592fa940ccd90601197e02781bed32d156dc22bf172b09926583a9260863e4fb4b93eadd7fc8a880ae83ee85789fcc9c26e85e8fe12a620272914b4e88c7c1c6888f25c15c28e448bda4a64099e605d9ebac396f3a543800e72e61b95279d4bf939a93fde3587e06537e60afdb169f392b68d7082760934f8d4e27030d87ffb6202cd2ac636918716ddf48dcab331e" },
        .{ "test", "746929c4084a88d9deb1f2233421ceea8ce036cad2d521c0e3fee848261713e5ce60ba1c9f88e95c5e246fe9045a591af45c7a07343e1de0b506ee164bd66a3fa8e0ad4dc880bcdb3e03195b08982d805325bbdc760a27edc66cc26a60cafd896c8fa8376e09f8abfca95cb7afa0b773ce70dd7fc5186b5d1f52692e1fc62a7569823d43a8e60b31773ab5d7cb2f191703197d850b98853f3e070de4ce6c60737b849cd540c421c56d878cf4bb57c908b7c02f61b598671061dba0dcbd8a948ce57dc032d9b5213660f014eca9d2e27a06942223fc13e1c2f8789d677f67e60039ac75cea921ad717be96a578fb03a478c29171765dfea5f3ebeac1ecdaf5f92" },
    };
    inline for (vectors) |vector| {
        var ciphertext: [PrivateKey.ciphertext_bytes]u8 = undefined;
        _ = try std.fmt.hexToBytes(&ciphertext, vector[1]);
        var output: [vector[0].len]u8 = undefined;
        try key.decrypt(&ciphertext, &output);
        try std.testing.expectEqualSlices(u8, vector[0], &output);
    }
}

test "RSA rejects truncated, trailing and malformed key encodings" {
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const encoded = try readKey(&buffer);
    for (0..encoded.len) |length| {
        try std.testing.expectError(error.InvalidEncryptionKey, PrivateKey.init(encoded[0..length]));
    }
    buffer[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidEncryptionKey, PrivateKey.init(encoded));
    buffer[encoded.len - 1] ^= 1;
    buffer[encoded.len] = 0;
    try std.testing.expectError(error.InvalidEncryptionKey, PrivateKey.init(buffer[0 .. encoded.len + 1]));
    for ([_][]const u8{ "", "\x30\x00", "\x30\x03\x02\x01\x00", "\x30\x80", "\x30\x82\xff\xff" }) |invalid| {
        try std.testing.expectError(error.InvalidEncryptionKey, PrivateKey.init(invalid));
    }
    @memset(&buffer, 0);
    try std.testing.expectError(error.InvalidEncryptionKey, PrivateKey.init(&buffer));
}

fn encryptBlock(key: *const PrivateKey, plaintext: *const [PrivateKey.ciphertext_bytes]u8) ![PrivateKey.ciphertext_bytes]u8 {
    const Modulus = std.crypto.ff.Modulus(2048);
    const value = try Modulus.Fe.fromBytes(key.modulus, plaintext, .big);
    const encrypted = try key.modulus.powWithEncodedPublicExponent(value, &.{ 1, 0, 1 }, .big);
    var ciphertext: [PrivateKey.ciphertext_bytes]u8 = undefined;
    try encrypted.toBytes(&ciphertext, .big);
    return ciphertext;
}

test "RSA rejects malformed PKCS1 padding without modifying output" {
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var key = try PrivateKey.init(try readKey(&buffer));
    defer key.deinit();
    const message = "test";
    var block: [PrivateKey.ciphertext_bytes]u8 = @splat(0x55);
    const separator = block.len - message.len - 1;
    block[0] = 0;
    block[1] = 2;
    block[separator] = 0;
    @memcpy(block[separator + 1 ..], message);
    var output: [message.len]u8 = undefined;
    const valid = try encryptBlock(&key, &block);
    try key.decrypt(&valid, &output);
    try std.testing.expectEqualSlices(u8, message, &output);

    var corrupted = key;
    defer corrupted.deinit();
    corrupted.exponent_p[corrupted.exponent_p.len - 1] ^= 1;
    @memset(&output, 0xa5);
    try std.testing.expectError(error.CryptoFailure, corrupted.decrypt(&valid, &output));
    try std.testing.expectEqualSlices(u8, &@as([message.len]u8, @splat(0xa5)), &output);

    for ([_]usize{ 0, 1, 2, separator / 2, separator - 1, separator }) |offset| {
        var invalid = block;
        invalid[offset] ^= if (offset == 0 or offset == separator) @as(u8, 1) else invalid[offset];
        const ciphertext = try encryptBlock(&key, &invalid);
        @memset(&output, 0xa5);
        try std.testing.expectError(error.InvalidCiphertext, key.decrypt(&ciphertext, &output));
        try std.testing.expectEqualSlices(u8, &@as([message.len]u8, @splat(0xa5)), &output);
    }
    var wrong_length: [message.len + 1]u8 = undefined;
    try std.testing.expectError(error.InvalidCiphertext, key.decrypt(&valid, &wrong_length));
    var too_long: [PrivateKey.ciphertext_bytes - 10]u8 = undefined;
    try std.testing.expectError(error.InvalidCiphertext, key.decrypt(&valid, &too_long));
    try std.testing.expectError(error.InvalidCiphertext, key.decrypt(&valid, &.{}));
    try std.testing.expectError(error.InvalidCiphertext, key.decrypt(valid[0 .. valid.len - 1], &output));
    var oversized: [PrivateKey.ciphertext_bytes + 1]u8 = @splat(0);
    try std.testing.expectError(error.InvalidCiphertext, key.decrypt(&oversized, &output));
    var modulus: [PrivateKey.ciphertext_bytes]u8 = undefined;
    try key.modulus.toBytes(&modulus, .big);
    try std.testing.expectError(error.InvalidCiphertext, key.decrypt(&modulus, &output));
    const zero: [PrivateKey.ciphertext_bytes]u8 = @splat(0);
    try std.testing.expectError(error.InvalidCiphertext, key.decrypt(&zero, &output));
    var maximum_message: [PrivateKey.ciphertext_bytes - 11]u8 = undefined;
    var minimum_padding: [PrivateKey.ciphertext_bytes]u8 = @splat(0x55);
    minimum_padding[0] = 0;
    minimum_padding[1] = 2;
    minimum_padding[10] = 0;
    const boundary = try encryptBlock(&key, &minimum_padding);
    try key.decrypt(&boundary, &maximum_message);
    try std.testing.expectEqualSlices(u8, minimum_padding[11..], &maximum_message);
    const short_padding = try encryptBlock(&key, &(.{ 0, 2 } ++ @as([7]u8, @splat(0x55)) ++ .{0} ++ @as([PrivateKey.ciphertext_bytes - 10]u8, @splat(0x55))));
    try std.testing.expectError(error.InvalidCiphertext, key.decrypt(&short_padding, &output));
}

test "RSA destruction erases the private key" {
    var key = try PrivateKey.read(std.testing.io, "tests/fixtures/rsa-key.der");
    key.deinit();
    for (std.mem.asBytes(&key)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
