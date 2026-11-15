const std = @import("std");
const deflate = @import("deflate");

test "repetition fragments retain immutable results and bound literal fallbacks" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try deflate.fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    const patterns: [2][]const u8 = .{ "abcabcabcabcabcabc", "xxxxxxxxxxxxxxxxxx" };
    var cache = try deflate.fragments.Repetitions(64).init(bounded.allocator(), &patterns, 26, &baker);
    defer cache.deinit();
    var literal = try deflate.fragments.Repetitions(9).init(bounded.allocator(), &patterns, 26, &baker);
    defer literal.deinit();
    var decoder = try deflate.fragments.Decoder.init(bounded.allocator(), 1024);
    defer decoder.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var expected: [1024]u8 = undefined;
    var actual: [1024]u8 = undefined;
    const first = (try cache.get(0, 1)).?;
    for (patterns, 0..) |pattern, index| for (1..27) |count| {
        var writer: std.Io.Writer = .fixed(&expected);
        try writer.splatBytesAll(pattern, count);
        const fragment = (try cache.get(index, count)).?;
        try std.testing.expectEqualSlices(u8, writer.buffered(), try decoder.decode(fragment, &actual));
        try std.testing.expectEqual(fragment.bytes.ptr, (try cache.get(index, count)).?.bytes.ptr);
        try std.testing.expectEqual(null, try literal.get(index, count));
        try std.testing.expectEqual(null, try literal.get(index, count));
    };
    try std.testing.expectEqualSlices(u8, patterns[0], try decoder.decode(first, &actual));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "shared compression remains bounded after initialization" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var encoder = try deflate.Encoder.init(allocator.allocator(), 1);
    defer encoder.deinit();
    var decoder = try deflate.Decoder.init(allocator.allocator());
    defer decoder.deinit();
    allocator.fail_index = allocator.alloc_index;
    allocator.resize_fail_index = allocator.resize_index;
    var raw: [8192]u8 = undefined;
    var encoded: [16384]u8 = undefined;
    var decoded: [8192]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x8a661);
    for ([_]usize{ 0, 1, 127, 256, 4096, 8192 }) |length| {
        random.random().bytes(raw[0..length]);
        const frame = try encoder.encode(raw[0..length], &encoded);
        try std.testing.expectEqualSlices(u8, raw[0..length], try decoder.decode(frame, &decoded));
        try std.testing.expectError(error.InvalidData, decoder.decode(frame[0 .. frame.len - 1], &decoded));
        encoded[frame.len] = 0;
        try std.testing.expectError(error.InvalidData, decoder.decode(encoded[0 .. frame.len + 1], &decoded));
    }
    try std.testing.expect(!allocator.has_induced_failure);
}

test "fragments compose in arbitrary orders with independent literals and exact checksums" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try deflate.fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    var decoder = try deflate.Decoder.init(bounded.allocator());
    defer decoder.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var raw: [3][4096]u8 = undefined;
    var compressed: [3][8192]u8 = undefined;
    var fragments: [3]deflate.fragments.Fragment = undefined;
    var random = std.Random.DefaultPrng.init(0x71c09);
    for (&raw, &compressed, &fragments, 0..) |*input, *output, *fragment, index| {
        random.random().bytes(input);
        if (index == 0) @memset(input, 0);
        fragment.* = try baker.encode(input, output);
    }
    var expected: [200000]u8 = undefined;
    var actual: [200000]u8 = undefined;
    var output: [220000]u8 = undefined;
    var literal: [70000]u8 = undefined;
    random.random().bytes(&literal);
    for (0..64) |_| {
        var writer = try deflate.fragments.Stream.begin(&output);
        var plain: std.Io.Writer = .fixed(&expected);
        for (0..16) |_| {
            const selected = random.random().uintLessThan(usize, fragments.len + 1);
            if (selected == fragments.len) {
                const length = random.random().uintLessThan(usize, literal.len + 1);
                if (length > expected.len - plain.end) continue;
                try writer.writer.writeAll(literal[0..length]);
                try plain.writeAll(literal[0..length]);
            } else {
                if (raw[selected].len > expected.len - plain.end) continue;
                try writer.append(fragments[selected]);
                try plain.writeAll(&raw[selected]);
            }
        }
        const frame = try writer.finish();
        try std.testing.expectEqual(plain.end, writer.decoded);
        try std.testing.expectEqual(std.hash.Adler32.hash(plain.buffered()), writer.checksum);
        try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(frame, &actual));
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "accelerated fragment checksums match the independent scalar implementation" {
    var bytes: [65553]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x7d5c02);
    random.random().bytes(&bytes);
    for ([_]usize{ 0, 1, 2, 15, 16, 17, 31, 32, 63, 64, 127, 128, 255, 256, 5551, 5552, 5553, 65536 }) |length| for (0..17) |offset| {
        const input = bytes[offset..][0..length];
        try std.testing.expectEqual(std.hash.Adler32.hash(input), deflate.checksum(input));
    };
}

test "direct fragment streams preserve patched prefixes large literals and writer rebasing" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try deflate.fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    var decoder = try deflate.Decoder.init(bounded.allocator());
    defer decoder.deinit();
    const expected = try bounded.allocator().alloc(u8, 256 * 1024);
    defer bounded.allocator().free(expected);
    const actual = try bounded.allocator().alloc(u8, expected.len);
    defer bounded.allocator().free(actual);
    const output = try bounded.allocator().alloc(u8, expected.len + 1024);
    defer bounded.allocator().free(output);
    var raw: [4096]u8 = undefined;
    var encoded: [8192]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x62b194);
    random.random().bytes(&raw);
    const fragment = try baker.encode(&raw, &encoded);
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    for (0..64) |pass| {
        var plain: std.Io.Writer = .fixed(expected);
        var stream = try deflate.fragments.Stream.begin(output);
        const field = try stream.placeholder(&.{ 0, 0, 0 });
        try plain.splatByteAll(0, 3);
        const length = if (pass == 0) 65527 else random.random().uintLessThan(usize, 70000);
        try stream.writer.splatByteAll(0x37, length);
        try plain.splatByteAll(0x37, length);
        const tail = try stream.writer.writableSlicePreserve(8, 16);
        @memset(tail, 0x41);
        try plain.splatByteAll(0x41, 16);
        try stream.append(fragment);
        try plain.writeAll(&raw);
        try stream.writer.splatBytesAll(&.{ 0x61, 0x62, 0x63 }, 23000);
        try plain.splatBytesAll(&.{ 0x61, 0x62, 0x63 }, 23000);
        try stream.writer.writeAll(&raw);
        try plain.writeAll(&raw);
        stream.patch(field, &.{ 1, 2, 3 });
        expected[0..3].* = .{ 1, 2, 3 };
        try std.testing.expectEqual(plain.end, stream.count());
        try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(try stream.finish(), actual));
    }
    var stream = try deflate.fragments.Stream.begin(output);
    try stream.append(fragment);
    try stream.writer.writeAll(&raw);
    var plain: std.Io.Writer = .fixed(expected);
    try plain.writeAll(&raw);
    try plain.writeAll(&raw);
    try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(try stream.finish(), actual));
    var exact: [17]u8 = undefined;
    var exact_stream = try deflate.fragments.Stream.begin(&exact);
    try exact_stream.writer.writeByte(0x61);
    try exact_stream.writer.flush();
    try std.testing.expectEqualSlices(u8, "a", try decoder.decode(try exact_stream.finish(), actual));
    var small: [12]u8 = undefined;
    var short = try deflate.fragments.Stream.begin(&small);
    try std.testing.expectError(error.WriteFailed, short.writer.writeByte(1));
    try std.testing.expectError(error.WriteFailed, short.append(fragment));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "literal patch handles remain stable between fragments and across rebasing" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try deflate.fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    var decoder = try deflate.Decoder.init(bounded.allocator());
    defer decoder.deinit();
    const output = try bounded.allocator().alloc(u8, 128 * 1024);
    defer bounded.allocator().free(output);
    const expected = try bounded.allocator().alloc(u8, output.len);
    defer bounded.allocator().free(expected);
    const actual = try bounded.allocator().alloc(u8, output.len);
    defer bounded.allocator().free(actual);
    var source: [4096]u8 = undefined;
    var encoded: [8192]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x712b);
    random.random().bytes(&source);
    const fragment = try baker.encode(&source, &encoded);
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var stream = try deflate.fragments.Stream.begin(output);
    var plain: std.Io.Writer = .fixed(expected);
    var patches: [8]deflate.fragments.Stream.Patch = undefined;
    var positions: [8]usize = undefined;
    for (&patches, &positions, 0..) |*field, *position, index| {
        try stream.append(fragment);
        try plain.writeAll(&source);
        const length: usize = if (index == 4) 65534 else index * 8;
        try stream.writer.splatByteAll(0x37, length);
        try plain.splatByteAll(0x37, length);
        position.* = plain.end;
        field.* = try stream.placeholder(&.{ 127, 128, 255 });
        try plain.writeAll(&.{ 127, 128, 255 });
        const tail = try stream.writer.writableSlicePreserve(8, 16);
        @memset(tail, 0x41);
        try plain.splatByteAll(0x41, 16);
    }
    for (0..16) |_| {
        for (patches, positions) |field, position| {
            var value: [3]u8 = undefined;
            random.random().bytes(&value);
            stream.patch(field, &value);
            @memcpy(expected[position..][0..3], &value);
        }
    }
    try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(try stream.finish(), actual));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "batched fragments match independent decoding without allocation" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try deflate.fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    var decoder = try deflate.Decoder.init(bounded.allocator());
    defer decoder.deinit();
    var encoded: [3][8192]u8 = undefined;
    var raw: [3][4096]u8 = undefined;
    var fragments: [3]deflate.fragments.Fragment = undefined;
    var digest: deflate.fragments.Digest = .{};
    var random = std.Random.DefaultPrng.init(0x7631);
    for (&raw, &encoded, &fragments) |*input, *output, *fragment| {
        random.random().bytes(input);
        fragment.* = try baker.encode(input, output);
        digest.append(fragment.*);
    }
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var output: [32768]u8 = undefined;
    var plain: [16384]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&plain);
    var stream = try deflate.fragments.Stream.begin(&output);
    try stream.writer.writeAll("before");
    try expected.writeAll("before");
    try stream.appendMany(&fragments, digest);
    for (&raw) |*bytes| try expected.writeAll(bytes);
    try stream.writer.writeAll("after");
    try expected.writeAll("after");
    var actual: [16384]u8 = undefined;
    try std.testing.expectEqualSlices(u8, expected.buffered(), try decoder.decode(try stream.finish(), &actual));
    var tiny: [16]u8 = undefined;
    var limited = try deflate.fragments.Stream.begin(&tiny);
    try std.testing.expectError(error.WriteFailed, limited.appendMany(&fragments, digest));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "fragment baker reset matches a fresh compressor" {
    var baker = try deflate.fragments.Baker.init(std.testing.allocator);
    defer baker.deinit();
    const fresh = try std.testing.allocator.create(std.compress.flate.Compress);
    defer std.testing.allocator.destroy(fresh);
    const history = try std.testing.allocator.alloc(u8, std.compress.flate.max_window_len);
    defer std.testing.allocator.free(history);
    var random = std.Random.DefaultPrng.init(7);
    var input: [6000]u8 = undefined;
    var expected: [8192]u8 = undefined;
    var actual: [8192]u8 = undefined;
    for (0..64) |round| {
        const length = 1 + random.random().uintLessThan(usize, input.len);
        const alphabet = 1 + random.random().uintLessThan(u8, 255);
        for (input[0..length]) |*byte| byte.* = random.random().uintLessThan(u8, alphabet);
        baker.options = if (round % 2 == 0) .level_5 else .level_1;
        var writer: std.Io.Writer = .fixed(&expected);
        fresh.* = try .init(&writer, history, .raw, baker.options);
        try fresh.writer.writeAll(input[0..length]);
        try fresh.writer.flush();
        const fragment = try baker.encodeStd(input[0..length], &actual);
        try std.testing.expectEqualSlices(u8, writer.buffered(), fragment.bytes);
    }
}

test "libdeflate fragments concatenate into one stream at every level" {
    var decoder = try deflate.Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    var random = std.Random.DefaultPrng.init(11);
    const inputs = try std.testing.allocator.alloc(u8, 16 * 9000);
    defer std.testing.allocator.free(inputs);
    const encoded = try std.testing.allocator.alloc(u8, 16 * 9100);
    defer std.testing.allocator.free(encoded);
    var stream_bytes: [16 * 9200]u8 = undefined;
    var decoded: [16 * 9000]u8 = undefined;
    for (1..10) |level| {
        var baker = try deflate.fragments.Baker.initLevel(std.testing.allocator, @intCast(level));
        defer baker.deinit();
        var fragments: [16]deflate.fragments.Fragment = undefined;
        var input_end: usize = 0;
        var output_end: usize = 0;
        for (&fragments, 0..) |*fragment, index| {
            // Short inputs take the stored path, and inputs past 5000 bytes may need std.
            const length = if (index == 0) 1 else 1 + random.random().uintLessThan(usize, 9000);
            const alphabet = 1 + random.random().uintLessThan(u8, 255);
            const input = inputs[input_end..][0..length];
            for (input) |*byte| byte.* = if (random.random().boolean()) 0 else random.random().uintLessThan(u8, alphabet);
            fragment.* = try baker.encode(input, encoded[output_end..][0..9100]);
            try std.testing.expectEqual(0, fragment.bytes[0] & 1);
            input_end += length;
            output_end += fragment.bytes.len;
        }
        var digest: deflate.fragments.Digest = .{};
        for (fragments) |fragment| digest.append(fragment);
        var stream = try deflate.fragments.Stream.begin(&stream_bytes);
        try stream.appendMany(&fragments, digest);
        const frame = try stream.finish();
        try std.testing.expectEqualSlices(u8, inputs[0..input_end], try decoder.decode(frame, decoded[0..input_end]));
    }
}

test "fragments stay independent when the compressor keeps its match tables" {
    var decoder = try deflate.Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    var random = std.Random.DefaultPrng.init(0x7ab1e5);
    var input: [12000]u8 = undefined;
    var previous: [12000]u8 = undefined;
    var encoded: [13000]u8 = undefined;
    var framed: [13100]u8 = undefined;
    var decoded: [12000]u8 = undefined;
    for ([_]u4{ 2, 6, 9 }) |level| {
        var encoder = try deflate.Encoder.init(std.testing.allocator, level);
        defer encoder.deinit();
        var previous_length: usize = 0;
        for (0..400) |round| {
            // Most inputs are small enough to keep the tables. Larger ones force a full clear.
            const length = if (round % 9 == 8) 4097 + random.random().uintLessThan(usize, 7000) else 8 + random.random().uintLessThan(usize, 4089);
            // Repeating the previous input makes any stale table entry an attractive match.
            if (round % 3 == 1 and previous_length != 0) {
                for (input[0..length], 0..) |*byte, index| byte.* = previous[index % previous_length];
            } else {
                const alphabet = 1 + random.random().uintLessThan(u8, 40);
                var value: u8 = 0;
                for (input[0..length]) |*byte| {
                    if (random.random().uintLessThan(u8, 6) == 0) value = random.random().uintLessThan(u8, alphabet);
                    byte.* = value;
                }
            }
            // Ordinary compression uses the same tables and must not inherit the shortcut.
            if (round % 7 == 3) _ = try encoder.encode(input[0..length], &encoded);
            const bytes = encoder.fragment(input[0..length], &encoded) orelse continue;
            var stream = try deflate.fragments.Stream.begin(&framed);
            try stream.append(.{ .bytes = bytes, .decoded = @intCast(length), .checksum = deflate.checksum(input[0..length]) });
            try std.testing.expectEqualSlices(u8, input[0..length], try decoder.decode(try stream.finish(), decoded[0..length]));
            @memcpy(previous[0..length], input[0..length]);
            previous_length = length;
        }
    }
}
