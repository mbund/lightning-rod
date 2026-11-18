const std = @import("std");

pub const Cipher = struct {
    key: std.crypto.core.aes.AesEncryptCtx(std.crypto.core.aes.Aes128),
    feedback: [16]u8,
    secret: [16]u8,

    pub const Encryption = struct { cipher: *Cipher, first: []u8, second: []u8 = &.{} };
    pub const batch_size = if (std.crypto.core.aes.has_hardware_support)
        std.math.ceilPowerOfTwo(usize, std.crypto.core.aes.Block.parallel.optimal_parallel_blocks) catch unreachable
    else
        1;

    /// Destinations are exclusive and disjoint from the shared plaintext. Each cipher occurs once.
    pub fn encryptBatch(source: []const u8, targets: []const Encryption) void {
        std.debug.assert(targets.len <= batch_size);
        for (targets, 0..) |target, index| {
            std.debug.assert(target.first.len + target.second.len == source.len);
            assertDisjoint(target.first, target.second);
            for ([_][]u8{ target.first, target.second }) |destination| {
                assertDisjoint(source, destination);
                for (targets[0..index]) |previous| {
                    assertDisjoint(previous.first, destination);
                    assertDisjoint(previous.second, destination);
                }
            }
            for (targets[0..index]) |previous| std.debug.assert(previous.cipher != target.cipher);
        }
        if (source.len == 0 or targets.len == 0) return;
        if (comptime std.crypto.core.aes.has_hardware_support) {
            inline for (1..batch_size + 1) |count| {
                if (targets.len == count) {
                    encryptParallel(count, source, targets[0..count].*);
                    return;
                }
            }
            unreachable;
        }
        for (targets) |target| {
            target.cipher.transform(.encrypt, source[0..target.first.len], target.first);
            target.cipher.transform(.encrypt, source[target.first.len..], target.second);
        }
    }

    fn assertDisjoint(a: []const u8, b: []const u8) void {
        std.debug.assert(a.len == 0 or b.len == 0 or @intFromPtr(a.ptr) + a.len <= @intFromPtr(b.ptr) or @intFromPtr(b.ptr) + b.len <= @intFromPtr(a.ptr));
    }

    fn encryptParallel(comptime count: usize, source: []const u8, targets: [count]Encryption) void {
        const lanes = comptime std.math.ceilPowerOfTwo(usize, count) catch unreachable;
        const Blocks = std.crypto.core.aes.BlockVec(lanes);
        var keys: [std.crypto.core.aes.Aes128.rounds + 1]Blocks = undefined;
        inline for (0..keys.len) |round| {
            var bytes: [lanes * 16]u8 = undefined;
            // Inactive SIMD lanes repeat the first stream without writing output or cipher state.
            inline for (0..lanes) |lane| bytes[lane * 16 ..][0..16].* = targets[if (lane < count) lane else 0].cipher.key.key_schedule.round_keys[round].toBytes();
            keys[round] = Blocks.fromBytes(&bytes);
        }
        var registers: [lanes * 16]u8 = undefined;
        inline for (0..lanes) |lane| registers[lane * 16 ..][0..16].* = targets[if (lane < count) lane else 0].cipher.feedback;
        var feedback: @Vector(lanes * 16, u8) = registers;
        const shift = comptime shift: {
            var indices: [lanes * 16]i32 = undefined;
            for (&indices, 0..) |*index, at| index.* = if (at % 16 == 15) ~@as(i32, @intCast(at - 15)) else @intCast(at + 1);
            break :shift indices;
        };
        var offset: usize = 0;
        while (offset < source.len) {
            var end = source.len;
            var output: [count][]u8 = undefined;
            inline for (targets, 0..) |target, lane| {
                output[lane] = if (offset < target.first.len) target.first[offset..] else target.second[offset - target.first.len ..];
                end = @min(end, offset + output[lane].len);
            }
            std.debug.assert(end > offset);
            for (source[offset..end], 0..) |byte, index| {
                const bytes: [lanes * 16]u8 = feedback;
                var blocks = Blocks.fromBytes(&bytes).xorBlocks(keys[0]);
                // Independent connections overlap AES latency without changing either CFB8 stream.
                inline for (1..std.crypto.core.aes.Aes128.rounds) |round| {
                    blocks = blocks.encrypt(keys[round]);
                }
                const mask: @Vector(lanes * 16, u8) = blocks.encryptLast(keys[std.crypto.core.aes.Aes128.rounds]).toBytes();
                const encrypted = mask ^ @as(@Vector(lanes * 16, u8), @splat(byte));
                feedback = @shuffle(u8, feedback, encrypted, shift);
                inline for (0..count) |lane| output[lane][index] = encrypted[lane * 16];
            }
            offset = end;
        }
        const result: [lanes * 16]u8 = feedback;
        inline for (targets, 0..) |target, lane| target.cipher.feedback = result[lane * 16 ..][0..16].*;
    }

    /// One connection's bytes to encrypt in place, in order, through its own stream.
    pub const Stream = struct { cipher: *Cipher, bytes: []u8 };

    /// Connections whose streams run side by side. A CFB8 stream needs a whole AES block for
    /// every byte, each waiting on the byte before, so one stream leaves the AES units idle
    /// for most of each block's latency, and only other connections can fill them. Eight
    /// registers of blocks in flight measured best with VAES, 16 lanes, where more spill
    /// registers and fewer leave the units waiting.
    pub const stream_lanes = 8 * std.crypto.core.aes.BlockVec(4).native_vector_size;

    /// Encrypts each stream's bytes in place, as `transform` would one stream after another, with
    /// up to `stream_lanes` streams side by side. A lane takes the next stream as its own ends.
    pub fn encryptStreams(streams: []const Stream) void {
        encryptStreamsWith(stream_lanes, streams);
    }

    pub fn encryptStreamsWith(comptime lanes: usize, streams: []const Stream) void {
        for (streams, 0..) |stream, index| {
            for (streams[0..index]) |previous| {
                std.debug.assert(previous.cipher != stream.cipher);
                assertDisjoint(previous.bytes, stream.bytes);
            }
        }
        if (comptime !std.crypto.core.aes.has_hardware_support) {
            for (streams) |stream| stream.cipher.transform(.encrypt, stream.bytes, stream.bytes);
            return;
        }
        const width = lanes * 16;
        const Bytes = @Vector(width, u8);
        const Blocks = std.crypto.core.aes.BlockVec(lanes);
        const rounds = std.crypto.core.aes.Aes128.rounds;
        const masks = comptime masks: {
            @setEvalBranchQuota(64 * width);
            var result: struct { broadcast: [16][width]i32, shift: [width]i32, position: [16][width]bool, first: [width]i32, rotate: [16][width]i32, shift_first: [width]i32 } = undefined;
            for (0..width) |at| {
                const lane = at / 16;
                for (0..16) |byte| {
                    result.broadcast[byte][at] = @intCast(lane * 16 + byte);
                    result.position[byte][at] = at % 16 == byte;
                    // Byte `byte` of each lane at its first position.
                    result.rotate[byte][at] = @intCast(lane * 16 + (at % 16 + byte) % 16);
                }
                result.first[at] = @intCast(lane * 16);
                // The register drops its oldest byte and takes the ciphertext byte, which the
                // second operand holds in every byte of the lane.
                result.shift[at] = if (at % 16 == 15) ~@as(i32, @intCast(at)) else @intCast(at + 1);
                // As `shift`, the ciphertext byte taken from the first position of its lane.
                result.shift_first[at] = if (at % 16 == 15) ~@as(i32, @intCast(lane * 16)) else @intCast(at + 1);
            }
            break :masks result;
        };
        var key_bytes: [rounds + 1][width]u8 = @splat(@splat(0));
        var keys: [rounds + 1]Blocks = undefined;
        var feedback_bytes: [width]u8 = @splat(0);
        var assigned: [lanes]?*const Stream = @splat(null);
        var offsets: [lanes]usize = @splat(0);
        var next: usize = 0;
        while (true) {
            var refilled = false;
            var any = false;
            for (&assigned, &offsets, 0..) |*lane_stream, *offset, lane| {
                if (lane_stream.* == null) {
                    while (next < streams.len and streams[next].bytes.len == 0) next += 1;
                    if (next < streams.len) {
                        const stream = &streams[next];
                        next += 1;
                        lane_stream.* = stream;
                        offset.* = 0;
                        feedback_bytes[lane * 16 ..][0..16].* = stream.cipher.feedback;
                        for (&key_bytes, 0..) |*round, index| round[lane * 16 ..][0..16].* = stream.cipher.key.key_schedule.round_keys[index].toBytes();
                        refilled = true;
                    }
                }
                any = any or lane_stream.* != null;
            }
            if (!any) break;
            if (refilled) {
                for (&keys, &key_bytes) |*round, *bytes| round.* = Blocks.fromBytes(bytes);
            }
            // Each lane takes up to 16 bytes of its stream, all of them encrypted in 16 steps.
            var input_bytes: [width]u8 = @splat(0);
            var counts: [width]u8 = @splat(0);
            var full = true;
            for (assigned, offsets, 0..) |lane_stream, offset, lane| {
                const stream = lane_stream orelse continue;
                const count = @min(16, stream.bytes.len - offset);
                @memcpy(input_bytes[lane * 16 ..][0..count], stream.bytes[offset..][0..count]);
                @memset(counts[lane * 16 ..][0..16], @intCast(count));
                full = full and count == 16;
            }
            const input: Bytes = input_bytes;
            var feedback: Bytes = feedback_bytes;
            var output: Bytes = undefined;
            if (full) {
                feedback = whole(lanes, Blocks, &keys, input, feedback);
                output = feedback;
            } else output = partial(width, rounds, Blocks, masks, &keys, input, counts, &feedback);
            feedback_bytes = feedback;
            const output_bytes: [width]u8 = output;
            for (&assigned, &offsets, 0..) |*lane_stream, *offset, lane| {
                const stream = lane_stream.* orelse continue;
                const taken = @min(16, stream.bytes.len - offset.*);
                @memcpy(stream.bytes[offset.*..][0..taken], output_bytes[lane * 16 ..][0..taken]);
                offset.* += taken;
                if (offset.* == stream.bytes.len) {
                    stream.cipher.feedback = feedback_bytes[lane * 16 ..][0..16].*;
                    lane_stream.* = null;
                }
            }
        }
    }

    /// A chunk in which every lane takes a whole 16 bytes, after which each lane's register holds
    /// just the ciphertext it made, so the steps keep nothing else. Each step works a register of
    /// the AES units' width at a time, whose byte moves stay within 16-byte lanes, as one
    /// instruction each.
    fn whole(comptime lanes: usize, comptime Blocks: type, keys: *const [std.crypto.core.aes.Aes128.rounds + 1]Blocks, input: @Vector(lanes * 16, u8), start: @Vector(lanes * 16, u8)) @Vector(lanes * 16, u8) {
        const rounds = std.crypto.core.aes.Aes128.rounds;
        const word = Blocks.native_word_size;
        const words = lanes * 16 / word;
        const Word = @Vector(word, u8);
        const Repr = @typeInfo(@FieldType(Blocks, "repr")).array.child;
        const masks = comptime masks: {
            var result: struct { rotate: [16][word]i32, shift: [word]i32 } = undefined;
            for (0..word) |at| {
                const lane = at / 16;
                for (0..16) |step| result.rotate[step][at] = @intCast(lane * 16 + (at % 16 + step) % 16);
                result.shift[at] = if (at % 16 == 15) ~@as(i32, @intCast(lane * 16)) else @intCast(at + 1);
            }
            break :masks result;
        };
        const input_array: [lanes * 16]u8 = input;
        const start_array: [lanes * 16]u8 = start;
        var inputs: [words]Word = undefined;
        var feedback: [words]Word = undefined;
        inline for (0..words) |index| {
            inputs[index] = input_array[index * word ..][0..word].*;
            feedback[index] = start_array[index * word ..][0..word].*;
        }
        inline for (0..16) |step| {
            var blocks: Blocks = undefined;
            inline for (0..words) |index| blocks.repr[index] = @as(Repr, @bitCast(feedback[index])) ^ keys[0].repr[index];
            inline for (1..rounds) |round| blocks = blocks.encrypt(keys[round]);
            blocks = blocks.encryptLast(keys[rounds]);
            inline for (0..words) |index| {
                const keystream: Word = @bitCast(blocks.repr[index]);
                const ciphertext = keystream ^ @shuffle(u8, inputs[index], undefined, masks.rotate[step]);
                feedback[index] = @shuffle(u8, feedback[index], ciphertext, masks.shift);
            }
        }
        var result: [lanes * 16]u8 = undefined;
        inline for (0..words) |index| result[index * word ..][0..word].* = feedback[index];
        return result;
    }

    /// A chunk in which some lane takes fewer than 16 bytes: the end of its stream. Each lane's
    /// register stops at its last byte, and its ciphertext collects apart.
    fn partial(comptime width: usize, comptime rounds: usize, comptime Blocks: type, comptime masks: anytype, keys: *const [rounds + 1]Blocks, input: @Vector(width, u8), counts: [width]u8, feedback_vector: *@Vector(width, u8)) @Vector(width, u8) {
        const Bytes = @Vector(width, u8);
        const count: Bytes = counts;
        var feedback = feedback_vector.*;
        var output: Bytes = @splat(0);
        inline for (0..16) |step| {
            const register: [width]u8 = feedback;
            var blocks = Blocks.fromBytes(&register).xorBlocks(keys[0]);
            inline for (1..rounds) |round| blocks = blocks.encrypt(keys[round]);
            const keystream: Bytes = blocks.encryptLast(keys[rounds]).toBytes();
            // The first byte of each lane's keystream masks that lane's byte at this step.
            const ciphertext = keystream ^ @shuffle(u8, input, undefined, masks.broadcast[step]);
            const spread = @shuffle(u8, ciphertext, undefined, masks.first);
            const active = count > @as(Bytes, @splat(step));
            feedback = @select(u8, active, @shuffle(u8, feedback, spread, masks.shift), feedback);
            output = @select(u8, masks.position[step], spread, output);
        }
        feedback_vector.* = feedback;
        return output;
    }

    pub fn init(secret: [16]u8) Cipher {
        return .{ .key = std.crypto.core.aes.Aes128.initEnc(secret), .feedback = secret, .secret = secret };
    }

    /// Each connection has independent receive and send streams. Packet and
    /// transport boundaries do not reset either stream.
    pub fn transform(self: *Cipher, comptime direction: enum { encrypt, decrypt }, input: []const u8, output: []u8) void {
        std.debug.assert(input.len == output.len);
        if (input.len == 0) return;

        if (input.ptr != output.ptr) assertDisjoint(input, output);

        if (comptime direction == .encrypt and std.crypto.core.aes.has_hardware_support) {
            encryptParallel(1, input, .{.{ .cipher = self, .first = output }});
            return;
        }

        var offset: usize = 0;
        if (comptime direction == .decrypt and std.crypto.core.aes.has_hardware_support) {
            const lanes = 8;
            while (input.len - offset >= lanes) : (offset += lanes) {
                var blocks: [16 * lanes]u8 = undefined;
                var masks: [16 * lanes]u8 = undefined;
                // Decryption feedback uses ciphertext already present in this batch.
                inline for (0..lanes) |lane| {
                    @memcpy(blocks[lane * 16 ..][0 .. 16 - lane], self.feedback[lane..]);
                    @memcpy(blocks[lane * 16 + 16 - lane ..][0..lane], input[offset..][0..lane]);
                }
                self.key.encryptWide(lanes, &masks, &blocks);
                var feedback: [16]u8 = undefined;
                @memcpy(feedback[0 .. 16 - lanes], self.feedback[lanes..]);
                @memcpy(feedback[16 - lanes ..], input[offset..][0..lanes]);
                self.feedback = feedback;
                inline for (0..lanes) |lane| output[offset + lane] = input[offset + lane] ^ masks[lane * 16];
            }
        }
        for (input[offset..], output[offset..]) |source, *destination| {
            var mask: [16]u8 = undefined;
            self.key.encrypt(&mask, &self.feedback);
            const result = source ^ mask[0];
            // CFB8 shifts its 128-bit feedback register by one ciphertext byte.
            const feedback = std.mem.readInt(u128, &self.feedback, .big);
            std.mem.writeInt(u128, &self.feedback, (feedback << 8) | (if (direction == .encrypt) result else source), .big);
            destination.* = result;
        }
    }
};
