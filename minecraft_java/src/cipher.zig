const std = @import("std");

pub const Cipher = struct {
    key: std.crypto.core.aes.AesEncryptCtx(std.crypto.core.aes.Aes128),
    feedback: [16]u8,
    secret: [16]u8,

    pub fn init(secret: [16]u8) Cipher {
        return .{ .key = std.crypto.core.aes.Aes128.initEnc(secret), .feedback = secret, .secret = secret };
    }

    /// Each connection has independent receive and send streams. Packet and
    /// transport boundaries do not reset either stream.
    pub fn transform(self: *Cipher, comptime direction: enum { encrypt, decrypt }, input: []const u8, output: []u8) void {
        std.debug.assert(input.len == output.len);

        if (input.len != 0 and input.ptr != output.ptr) {
            std.debug.assert(@intFromPtr(input.ptr) + input.len <= @intFromPtr(output.ptr) or @intFromPtr(output.ptr) + output.len <= @intFromPtr(input.ptr));
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
