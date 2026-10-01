const std = @import("std");

const Aes = std.crypto.core.aes;

pub const Cipher = struct {
    key: Aes.AesEncryptCtx(Aes.Aes128),
    feedback: [16]u8,
    secret: [16]u8,

    pub fn init(secret: [16]u8) Cipher {
        return .{ .key = Aes.Aes128.initEnc(secret), .feedback = secret, .secret = secret };
    }

    /// Each connection has independent receive and send streams. Packet and
    /// transport boundaries do not reset either stream.
    pub fn transform(self: *Cipher, comptime direction: enum { encrypt, decrypt }, input: []const u8, output: []u8) void {
        std.debug.assert(input.len == output.len);

        if (input.len != 0 and input.ptr != output.ptr) {
            std.debug.assert(@intFromPtr(input.ptr) + input.len <= @intFromPtr(output.ptr) or @intFromPtr(output.ptr) + output.len <= @intFromPtr(input.ptr));
        }

        for (input, output) |source, *destination| {
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
