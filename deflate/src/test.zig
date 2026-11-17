const std = @import("std");
const deflate = @import("deflate");
const fragments = deflate.fragments;

/// Inflates with std, an implementation independent of the libdeflate decoder.
fn inflateStd(frame: []const u8, output: []u8) ![]u8 {
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var input: std.Io.Reader = .fixed(frame);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &history);
    const length = try decompress.reader.readSliceShort(output);
    return output[0..length];
}

test "repetition fragments retain immutable results and bound literal fallbacks" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    const patterns: [2][]const u8 = .{ "abcabcabcabcabcabc", "xxxxxxxxxxxxxxxxxx" };
    var cache = try fragments.Repetitions(64).init(bounded.allocator(), &patterns, 26, &baker);
    defer cache.deinit();
    // Bytes without repeats code longer than nine bytes at every count.
    const noise: [1][]const u8 = .{"q8Z!x#k2@Lp9&mW0^r"};
    var literal = try fragments.Repetitions(9).init(bounded.allocator(), &noise, 26, &baker);
    defer literal.deinit();
    var decoder = try fragments.Decoder.init(bounded.allocator(), 1024);
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
        try std.testing.expectEqual(null, try literal.get(0, count));
        try std.testing.expectEqual(null, try literal.get(0, count));
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

test "the shared table forms complete codes and every builder length fits its limit" {
    try std.testing.expect(fragments.shared.valid());
    var random = std.Random.DefaultPrng.init(0x5ab1e);
    for (0..200) |round| {
        var counts: [fragments.literal_symbols]u64 = undefined;
        // Skewed counts force the limit, and zeros leave symbols without codes.
        for (&counts) |*count| count.* = if (random.random().uintLessThan(u8, 5) == 0) 0 else @as(u64, 1) << random.random().uintLessThan(u6, if (round % 2 == 0) 40 else 8);
        counts[0] = 1;
        counts[1] = 1;
        var lengths: [fragments.literal_symbols]u8 = undefined;
        fragments.huffmanLengths(&counts, &lengths, 13);
        var space: u64 = 0;
        for (counts, lengths) |count, length| {
            try std.testing.expectEqual(count == 0, length == 0);
            try std.testing.expect(length <= 13);
            if (length != 0) space += @as(u64, 1) << @intCast(15 - length);
        }
        try std.testing.expectEqual(@as(u64, 1 << 15), space);
    }
}

test "fragments decode exactly under both inflaters at every size up to the maximum" {
    var baker = try fragments.Baker.init(std.testing.allocator);
    defer baker.deinit();
    var decoder = try fragments.Decoder.init(std.testing.allocator, fragments.bound(fragments.Baker.maximum_input));
    defer decoder.deinit();
    const input = try std.testing.allocator.alloc(u8, fragments.Baker.maximum_input + 1);
    defer std.testing.allocator.free(input);
    const encoded = try std.testing.allocator.alloc(u8, fragments.bound(input.len));
    defer std.testing.allocator.free(encoded);
    const framed = try std.testing.allocator.alloc(u8, encoded.len + fragments.stream_overhead);
    defer std.testing.allocator.free(framed);
    const decoded = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(decoded);
    var random = std.Random.DefaultPrng.init(0xf1a7);
    for (0..120) |round| {
        const length = switch (round) {
            0 => 1,
            1 => fragments.Baker.maximum_input,
            else => 1 + random.random().uintLessThan(usize, fragments.Baker.maximum_input),
        };
        // Noise, small alphabets, and runs with long repeats far back.
        const alphabet = if (round % 5 == 0) 256 else 1 + random.random().uintLessThan(usize, 24);
        var value: u8 = 0;
        for (input[0..length], 0..) |*byte, at| {
            if (round % 3 == 1 and at >= 3000) {
                byte.* = input[at - 3000 + random.random().uintLessThan(usize, 2)];
                continue;
            }
            if (random.random().uintLessThan(u8, 4) == 0) value = @intCast(random.random().uintLessThan(usize, alphabet));
            byte.* = value;
        }
        const fragment = try baker.encode(input[0..length], encoded);
        try std.testing.expect(fragment.bytes.len <= fragments.bound(length));
        try std.testing.expect(fragment.bytes[fragment.bytes.len - 1] != 0);
        try std.testing.expectEqualSlices(u8, input[0..length], try decoder.decode(fragment, decoded));
        var stream = try fragments.Stream.begin(framed);
        try stream.append(fragment);
        try std.testing.expectEqualSlices(u8, input[0..length], try inflateStd(try stream.finish(), decoded));
        // One byte short of the exact size fails, and nothing is written past it.
        try std.testing.expectError(error.NoSpaceLeft, baker.encode(input[0..length], encoded[0 .. fragment.bytes.len - 1]));
    }
    // Noise at the limit fits the bound.
    random.random().bytes(input);
    const noise = try baker.encode(input[0..fragments.Baker.maximum_input], encoded[0..fragments.bound(fragments.Baker.maximum_input)]);
    try std.testing.expectEqualSlices(u8, input[0..fragments.Baker.maximum_input], try decoder.decode(noise, decoded));
    try std.testing.expectError(error.InputTooLarge, baker.encode(input, encoded));
}

test "fragments stay independent when the baker keeps its match tables" {
    var baker = try fragments.Baker.init(std.testing.allocator);
    defer baker.deinit();
    var decoder = try fragments.Decoder.init(std.testing.allocator, fragments.bound(12000));
    defer decoder.deinit();
    var random = std.Random.DefaultPrng.init(0x7ab1e5);
    var input: [12000]u8 = undefined;
    var previous: [12000]u8 = undefined;
    var encoded: [fragments.bound(12000)]u8 = undefined;
    var decoded: [12000]u8 = undefined;
    var previous_length: usize = 0;
    for (0..400) |round| {
        // Near the end of the head positions, the tables clear and start over.
        if (round == 200) baker.state.base = std.math.maxInt(u32) - 2 * fragments.Baker.maximum_input - 20000;
        const length = 8 + random.random().uintLessThan(usize, input.len - 8);
        // Repeating the previous input makes any stale head an attractive match.
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
        const fragment = try baker.encode(input[0..length], &encoded);
        try std.testing.expectEqualSlices(u8, input[0..length], try decoder.decode(fragment, decoded[0..length]));
        @memcpy(previous[0..length], input[0..length]);
        previous_length = length;
    }
    try std.testing.expect(baker.state.base < 1 << 30);
}

test "fragments compose in arbitrary orders with independent literals and exact checksums" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    var decoder = try deflate.Decoder.init(bounded.allocator());
    defer decoder.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var raw: [3][4096]u8 = undefined;
    var compressed: [3][fragments.bound(4096)]u8 = undefined;
    var pieces: [3]fragments.Fragment = undefined;
    var random = std.Random.DefaultPrng.init(0x71c09);
    for (&raw, &compressed, &pieces, 0..) |*input, *output, *fragment, index| {
        random.random().bytes(input);
        if (index == 0) @memset(input, 0);
        fragment.* = try baker.encode(input, output);
    }
    var expected: [200000]u8 = undefined;
    var actual: [200000]u8 = undefined;
    var output: [340000]u8 = undefined;
    var literal: [70000]u8 = undefined;
    random.random().bytes(&literal);
    for (0..64) |_| {
        var writer = try fragments.Stream.begin(&output);
        var plain: std.Io.Writer = .fixed(&expected);
        for (0..16) |_| {
            const selected = random.random().uintLessThan(usize, pieces.len + 1);
            if (selected == pieces.len) {
                const length = random.random().uintLessThan(usize, literal.len + 1);
                if (length > expected.len - plain.end) continue;
                try writer.writer.writeAll(literal[0..length]);
                try plain.writeAll(literal[0..length]);
            } else {
                if (raw[selected].len > expected.len - plain.end) continue;
                try writer.append(pieces[selected]);
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

test "direct fragment streams preserve large literals and writer rebasing" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try fragments.Baker.init(bounded.allocator());
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
    var encoded: [fragments.bound(4096)]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x62b194);
    random.random().bytes(&raw);
    const fragment = try baker.encode(&raw, &encoded);
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    for (0..64) |pass| {
        var plain: std.Io.Writer = .fixed(expected);
        var stream = try fragments.Stream.begin(output);
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
        try std.testing.expectEqual(plain.end, stream.count());
        try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(try stream.finish(), actual));
    }
    var stream = try fragments.Stream.begin(output);
    try stream.append(fragment);
    try stream.writer.writeAll(&raw);
    var plain: std.Io.Writer = .fixed(expected);
    try plain.writeAll(&raw);
    try plain.writeAll(&raw);
    try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(try stream.finish(), actual));
    // A few bytes past the overhead hold one literal.
    var room: usize = 0;
    var exact: [fragments.stream_overhead + 16]u8 = undefined;
    while (room <= 16) : (room += 1) {
        var exact_stream = try fragments.Stream.begin(exact[0 .. fragments.stream_overhead + room]);
        exact_stream.writer.writeByte(0x61) catch continue;
        try exact_stream.writer.flush();
        try std.testing.expectEqualSlices(u8, "a", try decoder.decode(try exact_stream.finish(), actual));
        break;
    }
    try std.testing.expect(room <= 8);
    try std.testing.expectError(error.WriteFailed, fragments.Stream.begin(exact[0 .. fragments.stream_overhead - 1]));
    var short = try fragments.Stream.begin(exact[0..fragments.stream_overhead]);
    try std.testing.expectError(error.WriteFailed, short.writer.writeByte(1));
    try std.testing.expectError(error.WriteFailed, short.append(fragment));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "batched fragments match independent decoding without allocation" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    var decoder = try deflate.Decoder.init(bounded.allocator());
    defer decoder.deinit();
    var encoded: [3][fragments.bound(4096)]u8 = undefined;
    var raw: [3][4096]u8 = undefined;
    var pieces: [3]fragments.Fragment = undefined;
    var digest: fragments.Digest = .{};
    var random = std.Random.DefaultPrng.init(0x7631);
    for (&raw, &encoded, &pieces) |*input, *output, *fragment| {
        random.random().bytes(input);
        fragment.* = try baker.encode(input, output);
        digest.append(fragment.*);
    }
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var output: [32768]u8 = undefined;
    var plain: [16384]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&plain);
    var stream = try fragments.Stream.begin(&output);
    try stream.writer.writeAll("before");
    try expected.writeAll("before");
    try stream.appendMany(&pieces, digest);
    for (&raw) |*bytes| try expected.writeAll(bytes);
    try stream.writer.writeAll("after");
    try expected.writeAll("after");
    var actual: [16384]u8 = undefined;
    try std.testing.expectEqualSlices(u8, expected.buffered(), try decoder.decode(try stream.finish(), &actual));
    var tiny: [fragments.stream_overhead + 16]u8 = undefined;
    var limited = try fragments.Stream.begin(&tiny);
    try std.testing.expectError(error.WriteFailed, limited.appendMany(&pieces, digest));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "fragments join at the bit their data ends, among literals, and decode exactly" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baker = try fragments.Baker.init(bounded.allocator());
    defer baker.deinit();
    var decoder = try deflate.Decoder.init(bounded.allocator());
    defer decoder.deinit();
    var random = std.Random.DefaultPrng.init(0xb17);
    // Small inputs end their data at every bit position across the set.
    var sources: [24][96]u8 = undefined;
    var lengths: [24]usize = undefined;
    var encoded: [24][fragments.bound(96)]u8 = undefined;
    var pieces: [24]fragments.Fragment = undefined;
    var ends: u8 = 0;
    for (&sources, &lengths, &encoded, &pieces, 0..) |*source, *length, *output, *fragment, index| {
        length.* = 8 + index * 3;
        for (source[0..length.*], 0..) |*byte, at| byte.* = if (index % 3 == 0) random.random().int(u8) else @truncate(at % (index + 2) * 7);
        fragment.* = try baker.encode(source[0..length.*], output);
        ends |= @as(u8, 1) << @intCast(7 - @clz(fragment.bytes[fragment.bytes.len - 1]));
    }
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var output: [32768]u8 = undefined;
    var expected: [32768]u8 = undefined;
    var actual: [32768]u8 = undefined;
    for (0..400) |round| {
        var stream = try fragments.Stream.begin(&output);
        var plain: std.Io.Writer = .fixed(&expected);
        for (0..14) |_| {
            const pick = random.random().uintLessThan(usize, sources.len);
            if (random.random().uintLessThan(u8, 5) < 3) {
                try stream.append(pieces[pick]);
                try plain.writeAll(sources[pick][0..lengths[pick]]);
                continue;
            }
            // Runs of one byte, as light masks and uniform arrays are, or noise.
            const length = random.random().intRangeAtMost(usize, 1, 700);
            const value = random.random().int(u8);
            for (0..length) |at| {
                const byte: u8 = if (round % 4 == 0) random.random().int(u8) else if (at % 50 < 40) value else @truncate(at);
                try stream.writer.writeByte(byte);
                try plain.writeByte(byte);
            }
        }
        try std.testing.expectEqual(plain.end, stream.count());
        const frame = try stream.finish();
        try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(frame, &actual));
        try std.testing.expectEqualSlices(u8, plain.buffered(), try inflateStd(frame, &actual));
    }
    // The fragments end at many different bits, so joins land at every offset.
    try std.testing.expect(@popCount(ends) >= 6);
    // Joined fragments cost their data and the one header, nothing per join.
    var stream = try fragments.Stream.begin(&output);
    var data: usize = 0;
    for (pieces) |fragment| {
        try stream.append(fragment);
        data += fragment.bytes.len;
    }
    try std.testing.expect((try stream.finish()).len <= fragments.stream_overhead + data);
    // A run of one byte is a literal and a few matches.
    stream = try fragments.Stream.begin(&output);
    try stream.writer.splatByteAll(0xff, 4000);
    try std.testing.expect((try stream.finish()).len < 40);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "small streams end as fixed codes when those are shorter and large ones keep the shared table" {
    var baker = try fragments.Baker.init(std.testing.allocator);
    defer baker.deinit();
    var decoder = try deflate.Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    var random = std.Random.DefaultPrng.init(0xf1ed);
    var source: [6000]u8 = undefined;
    var encoded: [fragments.bound(6000)]u8 = undefined;
    var output: [16384]u8 = undefined;
    var expected: [16384]u8 = undefined;
    var actual: [16384]u8 = undefined;
    var fixed: usize = 0;
    var dynamic: usize = 0;
    for (0..300) |round| {
        // Sizes from a few bytes to well past where the shared header pays for itself.
        const length = if (round % 2 == 0) 1 + random.random().uintLessThan(usize, 300) else random.random().intRangeAtMost(usize, 2000, source.len);
        for (source[0..length], 0..) |*byte, at| byte.* = if (round % 3 == 0) random.random().int(u8) else if (round % 2 == 1) random.random().uintLessThan(u8, 64) else @truncate(at / 7 * 13);
        var stream = try fragments.Stream.begin(&output);
        var plain: std.Io.Writer = .fixed(&expected);
        if (round % 2 == 0) {
            try stream.writer.writeAll(source[0..length]);
        } else try stream.append(try baker.encode(source[0..length], &encoded));
        try plain.writeAll(source[0..length]);
        const frame = try stream.finish();
        try std.testing.expectEqualSlices(u8, plain.buffered(), try decoder.decode(frame, &actual));
        try std.testing.expectEqualSlices(u8, plain.buffered(), try inflateStd(frame, &actual));
        switch (frame[2] >> 1 & 3) {
            1 => {
                fixed += 1;
                // Kilobytes of noise always carry the header.
                try std.testing.expect(length < 2000);
            },
            2 => {
                dynamic += 1;
                // A handful of bytes never carries the header.
                try std.testing.expect(length > 16);
            },
            else => return error.UnexpectedBlock,
        }
    }
    try std.testing.expect(fixed > 100 and dynamic > 100);
}

test "a counting stream counts what a stream decodes to" {
    var baker = try fragments.Baker.init(std.testing.allocator);
    defer baker.deinit();
    var random = std.Random.DefaultPrng.init(0xc0de);
    var source: [3000]u8 = undefined;
    random.random().bytes(&source);
    var encoded: [fragments.bound(3000)]u8 = undefined;
    const fragment = try baker.encode(&source, &encoded);
    var digest: fragments.Digest = .{};
    digest.append(fragment);
    var output: [65536]u8 = undefined;
    var scratch: [64]u8 = undefined;
    for (0..50) |_| {
        var stream = try fragments.Stream.begin(&output);
        var counter = fragments.Stream.counter(&scratch);
        const seed = random.random().int(u64);
        for ([_]*fragments.Stream{ &stream, &counter }) |target| {
            var copy = std.Random.DefaultPrng.init(seed);
            var steps = copy.random().uintLessThan(usize, 12);
            while (steps > 0) : (steps -= 1) switch (copy.random().uintLessThan(u8, 5)) {
                0 => try target.append(fragment),
                1 => try target.appendMany(&.{fragment}, digest),
                2 => try target.writer.splatByteAll(7, copy.random().uintLessThan(usize, 500)),
                3 => @memset(try target.writer.writableSlicePreserve(8, 40), 1),
                else => try target.writer.writeAll(source[0..copy.random().uintLessThan(usize, source.len)]),
            };
        }
        try std.testing.expectEqual(stream.count(), counter.count());
        const frame = try stream.finish();
        var actual: [65536]u8 = undefined;
        try std.testing.expectEqual(@as(usize, counter.count()), (try inflateStd(frame, &actual)).len);
    }
}
