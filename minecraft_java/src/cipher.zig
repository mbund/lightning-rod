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
