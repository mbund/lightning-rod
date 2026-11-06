const std = @import("std");

const assert = std.debug.assert;

pub const maximum = 12 + 8192 + 128;
pub const Change = struct { position: u16, state: u16 };

pub const Patch = struct {
    words: [64]u64 = @splat(0),
    count: u16 = 0,
    biomes: bool = false,

    pub fn preferCompression(self: *const Patch) bool {
        return @as(usize, self.count) * 4 > 512 + @as(usize, self.count) * 2;
    }

    pub fn apply(self: *Patch, blocks: *[4096]u16, changes: []const Change) void {
        for (changes) |change| {
            assert(change.position < blocks.len);
            if (blocks[change.position] == change.state) continue;
            const word = &self.words[change.position / 64];
            const bit = @as(u64, 1) << @intCast(change.position % 64);
            self.count += @intFromBool(word.* & bit == 0);
            word.* |= bit;
            blocks[change.position] = change.state;
        }
        assert(self.count <= blocks.len);
    }

    pub fn encode(self: *const Patch, blocks: *const [4096]u16, biomes: *const [64]u16, base: u64, output: []u8) ![]const u8 {
        var count: usize = 0;
        for (self.words) |word| count += @popCount(word);
        assert(count == self.count);
        const kind: u8 = if (count * 4 <= 512 + count * 2) 0 else if (512 + count * 2 < 8192) 1 else 2;
        const body = switch (kind) {
            0 => count * 4,
            1 => 512 + count * 2,
            2 => 8192,
            else => unreachable,
        };
        const length = 12 + body + @as(usize, if (self.biomes) 128 else 0);
        if (output.len < length) return error.BufferTooSmall;
        std.mem.writeInt(u64, output[0..8], base, .little);
        output[8] = kind;
        std.mem.writeInt(u16, output[9..11], if (kind == 2) 4096 else self.count, .little);
        output[11] = @intFromBool(self.biomes);
        var offset: usize = 12;
        if (kind == 1) {
            for (self.words) |word| {
                std.mem.writeInt(u64, output[offset..][0..8], word, .little);
                offset += 8;
            }
        }
        if (kind == 2) {
            for (blocks) |state| {
                std.mem.writeInt(u16, output[offset..][0..2], state, .little);
                offset += 2;
            }
        } else for (self.words, 0..) |word, index| {
            var remaining = word;
            while (remaining != 0) : (remaining &= remaining - 1) {
                const position = index * 64 + @ctz(remaining);
                if (kind == 0) {
                    std.mem.writeInt(u16, output[offset..][0..2], @intCast(position), .little);
                    offset += 2;
                }
                std.mem.writeInt(u16, output[offset..][0..2], blocks[position], .little);
                offset += 2;
            }
        }
        if (self.biomes) for (biomes) |biome| {
            std.mem.writeInt(u16, output[offset..][0..2], biome, .little);
            offset += 2;
        };
        assert(offset == length);
        return output[0..length];
    }

    // Validate the entire record before changing the destination.
    pub fn decode(bytes: []const u8, base: u64, blocks: *[4096]u16, biomes: *[64]u16) !Patch {
        if (bytes.len < 12) return error.Corrupt;
        if (std.mem.readInt(u64, bytes[0..8], .little) != base) return error.StaleBase;
        const kind = bytes[8];
        const count = std.mem.readInt(u16, bytes[9..11], .little);
        if (count > 4096 or bytes[11] > 1) return error.Corrupt;
        const body: usize = switch (kind) {
            0 => @as(usize, count) * 4,
            1 => 512 + @as(usize, count) * 2,
            2 => if (count == 4096) 8192 else return error.Corrupt,
            else => return error.Corrupt,
        };
        const length = 12 + body + @as(usize, if (bytes[11] == 1) 128 else 0);
        if (bytes.len != length) return error.Corrupt;
        var result: Patch = .{ .count = count, .biomes = bytes[11] == 1 };
        var offset: usize = 12;
        switch (kind) {
            0 => {
                var previous: ?u16 = null;
                for (0..count) |_| {
                    const position = std.mem.readInt(u16, bytes[offset..][0..2], .little);
                    if (position >= 4096) return error.Corrupt;
                    if (previous) |last| if (position <= last) return error.Corrupt;
                    result.words[position / 64] |= @as(u64, 1) << @intCast(position % 64);
                    previous = position;
                    offset += 4;
                }
                offset = 12;
            },
            1 => {
                var actual: usize = 0;
                for (&result.words) |*word| {
                    word.* = std.mem.readInt(u64, bytes[offset..][0..8], .little);
                    actual += @popCount(word.*);
                    offset += 8;
                }
                if (actual != count) return error.Corrupt;
            },
            2 => result.words = @splat(std.math.maxInt(u64)),
            else => unreachable,
        }
        for (result.words, 0..) |word, index| {
            var remaining = word;
            while (remaining != 0) : (remaining &= remaining - 1) {
                const position = index * 64 + @ctz(remaining);
                if (kind == 0) offset += 2;
                blocks[position] = std.mem.readInt(u16, bytes[offset..][0..2], .little);
                offset += 2;
            }
        }
        if (result.biomes) for (biomes) |*biome| {
            biome.* = std.mem.readInt(u16, bytes[offset..][0..2], .little);
            offset += 2;
        };
        assert(offset == length);
        return result;
    }
};
