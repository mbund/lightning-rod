const std = @import("std");

pub const block_size = 4096;
pub const page_size = block_size - 32;
pub const Page = [page_size]u8;
pub const Block = [block_size]u8;
pub const Frame = [block_size + 32]u8;
pub const header_size = 64;
pub const maximum_spaces = 48;
pub const maximum_name = 63;
pub const free_owner = std.math.maxInt(u32);
const checksum_seed = 0x4c52504147455231;
pub const PageId = enum(u64) { _ };
pub const SpaceId = enum(u32) { _ };
pub const CommitId = enum(u64) { _ };

pub const Error = error{ Timeout, InvalidArgument, BufferTooSmall, Corrupt, UnsupportedFormat, IoFailure, NoSpace, FailedTransaction, OutOfMemory };

pub fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
pub fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
pub fn checksum(bytes: []const u8) u64 {
    return std.hash.XxHash64.hash(checksum_seed, bytes);
}
pub fn seal(block: *Block, id: u64, owner: u32, sequence: u64, page: *const Page) void {
    @memcpy(block[0..4], "LRPG");
    put(u32, block, 4, owner);
    put(u64, block, 8, id);
    put(u64, block, 16, sequence);
    put(u64, block, 24, 0);
    @memcpy(block[32..], page);
    put(u64, block, 24, checksum(block));
}
pub fn validate(block: *Block, id: u64, owner: ?u32) Error!void {
    if (!std.mem.eql(u8, block[0..4], "LRPG") or get(u64, block, 8) != id) return error.Corrupt;
    if (owner) |expected| if (get(u32, block, 4) != expected) return error.Corrupt;
    const saved = get(u64, block, 24);
    put(u64, block, 24, 0);
    const actual = checksum(block);
    put(u64, block, 24, saved);
    if (saved != actual) return error.Corrupt;
}
pub fn transaction(previous: u64) std.hash.XxHash64 {
    var hash = std.hash.XxHash64.init(checksum_seed);
    var bytes: [8]u8 = undefined;
    put(u64, &bytes, 0, previous);
    hash.update(&bytes);
    return hash;
}

pub fn frame(output: *Frame, block: *const Block, offset: u64, digest: ?u64) u64 {
    @memset(output[0..32], 0);
    @memcpy(output[0..8], if (digest != null) "LRCOMMIT" else "LRFRAME2");
    put(u64, output, 8, offset);
    put(u64, output, 24, digest orelse 0);
    @memcpy(output[32..], block);
    const hash = checksum(output);
    put(u64, output, 16, hash);
    return hash;
}
pub fn validateFrame(bytes: *Frame, offset: u64) bool {
    const data = std.mem.eql(u8, bytes[0..8], "LRFRAME2");
    if (!data and !std.mem.eql(u8, bytes[0..8], "LRCOMMIT")) return false;
    if (get(u64, bytes, 8) != offset or (data and get(u64, bytes, 24) != 0)) return false;
    const saved = get(u64, bytes, 16);
    put(u64, bytes, 16, 0);
    const actual = checksum(bytes);
    put(u64, bytes, 16, saved);
    return saved == actual;
}

pub const Metadata = struct {
    identity: [16]u8,
    sequence: u64 = 0,
    tick: u64 = 0,
    pages: u64 = 1,
    free: u64 = 0,
    spaces: [maximum_spaces]Space = @splat(.{}),

    pub const Space = struct { name: [maximum_name]u8 = @splat(0), length: u8 = 0, root: u64 = 0 };

    pub fn encode(self: *const Metadata) Page {
        var bytes: Page = @splat(0);
        @memcpy(bytes[0..8], "LRMETA01");
        @memcpy(bytes[8..24], &self.identity);
        put(u64, &bytes, 24, self.sequence);
        put(u64, &bytes, 32, self.tick);
        put(u64, &bytes, 40, self.pages);
        put(u64, &bytes, 48, self.free);
        for (self.spaces, 0..) |space, index| {
            const at = 64 + index * 80;
            bytes[at] = space.length;
            @memcpy(bytes[at + 1 ..][0..maximum_name], &space.name);
            put(u64, &bytes, at + 64, space.root);
        }
        return bytes;
    }

    pub fn decode(bytes: *const Page) Error!Metadata {
        if (!std.mem.eql(u8, bytes[0..8], "LRMETA01")) return error.UnsupportedFormat;
        var self: Metadata = .{ .identity = bytes[8..24].*, .sequence = get(u64, bytes, 24), .tick = get(u64, bytes, 32), .pages = get(u64, bytes, 40), .free = get(u64, bytes, 48) };
        if (self.pages == 0 or self.free >= self.pages) return error.Corrupt;
        for (&self.spaces, 0..) |*space, index| {
            const at = 64 + index * 80;
            space.* = .{ .length = bytes[at], .name = bytes[at + 1 ..][0..maximum_name].*, .root = get(u64, bytes, at + 64) };
            if (space.length > maximum_name or space.root >= self.pages or (space.length == 0 and space.root != 0)) return error.Corrupt;
            if (space.length != 0) for (self.spaces[0..index]) |previous| {
                if (std.mem.eql(u8, previous.name[0..previous.length], space.name[0..space.length])) return error.Corrupt;
            };
        }
        return self;
    }
};

pub fn walHeader(identity: [16]u8, sequence: u64) [header_size]u8 {
    var bytes: [header_size]u8 = @splat(0);
    @memcpy(bytes[0..8], "LRWAL002");
    @memcpy(bytes[8..24], &identity);
    put(u64, &bytes, 24, sequence);
    put(u64, &bytes, 56, checksum(bytes[0..56]));
    return bytes;
}
