const std = @import("std");
const light = @import("light.zig");
const deflate = @import("deflate");
const records = @import("records");
const assert = std.debug.assert;

pub const identity_bytes = 32;
pub const key_bytes = 13;
pub const header_bytes = 24;
/// Writers lay out one fixed entry per section, and `finish` packs the unique ones.
pub const work_entry_bytes = 76;
const reference_bytes = 12;
const entities_bytes = 10;
const digest_bytes = 6;
const entry_maximum = 1 + 3 * reference_bytes + entities_bytes + 2 * digest_bytes;
pub const maximum_bytes = header_bytes + light.maximum_sections * (work_entry_bytes + 1 + 4096 + 32768 + 1024 + 4096 * 10);

const flag_words: u8 = 1;
const flag_biome: u8 = 2;
const flag_entities: u8 = 4;

comptime {
    // Packing never needs more room than the working layout it replaces.
    assert(2 + entry_maximum <= work_entry_bytes);
}

pub const Source = struct {
    rules: [32]u8,
    revision: u64,
    minimum: i32,
    count: u8,

    pub fn fromHeader(header: *const light.Header) Source {
        return .{ .rules = header.rules, .revision = header.revision(), .minimum = header.minimum, .count = header.count };
    }

    /// Records live beside the frame they were compiled from, so one hash of that frame's
    /// identity is enough to reject a record carried over from an older frame.
    fn digest(self: Source) u64 {
        var hash = std.hash.Wyhash.init(0x4c5244454c495633);
        hash.update(&self.rules);
        hash.update(std.mem.asBytes(&self.revision));
        hash.update(std.mem.asBytes(&self.minimum));
        hash.update(&.{self.count});
        return hash.final();
    }
};

pub fn key(column: light.Column) [key_bytes]u8 {
    return column.key(.light);
}

pub const Column = struct {
    pub const header_size = light.cache_header_bytes;
    pub const entry_size = identity_bytes + 8;
    bytes: []const u8,
    frame: []const u8,
    variants: usize,
    slots: usize,
    column: light.Column,

    pub fn bound(variants: usize) !usize {
        return std.math.add(usize, header_size + light.maximum_bytes, try std.math.mul(usize, variants, entry_size + maximum_bytes));
    }

    pub fn common(bytes: []const u8) ![]const u8 {
        if (bytes.len < header_size) return error.Corrupt;
        if (!std.mem.eql(u8, bytes[0..4], "LRC3")) return error.Outdated;
        const length = std.mem.readInt(u32, bytes[4..8], .little);
        if (length > light.maximum_bytes or length > bytes.len - header_size) return error.Corrupt;
        const frame = bytes[header_size..][0..length];
        if (std.mem.readInt(u64, bytes[28..36], .little) != frameChecksum(bytes[16..28], frame)) return error.Corrupt;
        return frame;
    }

    pub fn read(bytes: []const u8) !Column {
        const frame = try common(bytes);
        const variants = std.mem.readInt(u32, bytes[8..12], .little);
        const length = std.mem.readInt(u32, bytes[12..16], .little);
        if (length > bytes.len) return error.Incomplete;
        if (std.mem.readInt(u64, bytes[36..44], .little) != checksum(bytes)) return error.Corrupt;
        if (length != bytes.len or variants > (bytes.len - header_size - frame.len) / entry_size) return error.Corrupt;
        const end = header_size + frame.len + @as(usize, variants) * entry_size;
        var position = end;
        var count: usize = 0;
        for (0..variants) |index| {
            const entry = bytes[header_size + frame.len + index * entry_size ..][0..entry_size];
            const offset = std.mem.readInt(u32, entry[32..36], .little);
            const size = std.mem.readInt(u32, entry[36..40], .little);
            if (size == 0) {
                if (!std.mem.allEqual(u8, entry, 0)) return error.Corrupt;
                continue;
            }
            if (offset != position or size < header_bytes or size > maximum_bytes or size > bytes.len - position) return error.Corrupt;
            position += size;
            count += 1;
        }
        if (position != bytes.len) return error.Corrupt;
        return .{ .bytes = bytes, .frame = frame, .variants = count, .slots = variants, .column = .{ .world = std.mem.readInt(u32, bytes[16..20], .little), .x = std.mem.readInt(i32, bytes[20..24], .little), .z = std.mem.readInt(i32, bytes[24..28], .little) } };
    }

    fn frameChecksum(coordinates: []const u8, frame: []const u8) u64 {
        return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0x4c52434f4c554d4e, coordinates), frame);
    }

    fn checksum(bytes: []const u8) u64 {
        var hash = std.hash.Wyhash.init(0x4c5244454c495645);
        hash.update(bytes[0..36]);
        hash.update(bytes[44..]);
        return hash.final();
    }

    pub fn find(self: Column, identity: [identity_bytes]u8) ?[]const u8 {
        for (0..self.slots) |index| {
            const entry = self.bytes[header_size + self.frame.len + index * entry_size ..][0..entry_size];
            if (std.mem.readInt(u32, entry[36..40], .little) == 0) continue;
            if (!std.mem.eql(u8, entry[0..32], &identity)) continue;
            const offset = std.mem.readInt(u32, entry[32..36], .little);
            const length = std.mem.readInt(u32, entry[36..40], .little);
            return self.bytes[offset..][0..length];
        }
        return null;
    }

    pub const Builder = struct {
        bytes: []u8,
        cursor: usize,
        directory: usize,
        variants: usize,
        written: usize = 0,

        pub fn begin(bytes: []u8, column: light.Column, frame: []const u8, variants: usize) !Builder {
            assert(frame.len <= light.maximum_bytes);
            const directory = header_size + frame.len;
            const start = try std.math.add(usize, directory, try std.math.mul(usize, variants, entry_size));
            if (bytes.len < start) return error.NoSpaceLeft;
            bytes[0..4].* = "LRC3".*;
            std.mem.writeInt(u32, bytes[4..8], @intCast(frame.len), .little);
            std.mem.writeInt(u32, bytes[8..12], @intCast(variants), .little);
            std.mem.writeInt(u32, bytes[12..16], 0, .little);
            std.mem.writeInt(u32, bytes[16..20], column.world, .little);
            std.mem.writeInt(i32, bytes[20..24], column.x, .little);
            std.mem.writeInt(i32, bytes[24..28], column.z, .little);
            std.mem.writeInt(u64, bytes[28..36], frameChecksum(bytes[16..28], frame), .little);
            @memcpy(bytes[header_size..][0..frame.len], frame);
            @memset(bytes[directory..start], 0);
            return .{ .bytes = bytes, .cursor = start, .directory = directory, .variants = variants };
        }

        pub fn destination(self: *Builder) []u8 {
            assert(self.written < self.variants and self.cursor <= self.bytes.len);
            return self.bytes[self.cursor..];
        }

        pub fn append(self: *Builder, identity: [identity_bytes]u8, bytes: []const u8) void {
            assert(self.written < self.variants and bytes.ptr == self.bytes[self.cursor..].ptr);
            assert(bytes.len >= header_bytes and bytes.len <= maximum_bytes and bytes.len <= self.bytes.len - self.cursor);
            const entry = self.bytes[self.directory + self.written * entry_size ..][0..entry_size];
            entry[0..32].* = identity;
            std.mem.writeInt(u32, entry[32..36], @intCast(self.cursor), .little);
            std.mem.writeInt(u32, entry[36..40], @intCast(bytes.len), .little);
            self.cursor += bytes.len;
            self.written += 1;
        }

        pub fn finish(self: *Builder) []const u8 {
            assert(self.written <= self.variants and self.cursor <= self.bytes.len);
            std.mem.writeInt(u32, self.bytes[12..16], @intCast(self.cursor), .little);
            const encoded = self.bytes[0..self.cursor];
            std.mem.writeInt(u64, self.bytes[36..44], checksum(encoded), .little);
            return encoded;
        }
    };
};

pub const Component = enum { header, words, biome };
pub const ReadBatch = struct { keys: []const [key_bytes]u8, output: *records.PackedRead, submitted: bool = false };

pub const Section = struct {
    header: deflate.fragments.Fragment,
    words: ?deflate.fragments.Fragment,
    biome: ?deflate.fragments.Fragment,
    entities: []const u8,
    entity_count: u16,
    terrain_digest: deflate.fragments.Digest,
    full_digest: deflate.fragments.Digest,
};

/// Header: magic, source digest, section count, unique entries, zero pad, packet bound and
/// entity mask. A slot byte per section and a u16 offset per unique entry follow, then the
/// packed entries and the fragment bytes they reference.
pub const View = struct {
    bytes: []const u8,
    count: u8,
    maximum_size: u32,
    entity_sections: u32,

    /// The packet bound a stored record declares, read before its source is known so output
    /// can be reserved first. `read` still validates the record before any byte is used.
    pub fn declaredMaximum(bytes: []const u8) ?u32 {
        if (bytes.len < header_bytes or bytes.len > maximum_bytes) return null;
        if (!std.mem.eql(u8, bytes[0..4], "LRD3")) return null;
        const maximum_size = std.mem.readInt(u32, bytes[16..20], .little);
        if (maximum_size == 0 or maximum_size >= 1 << 21) return null;
        return maximum_size;
    }

    pub fn read(bytes: []const u8, source: Source) !View {
        if (bytes.len < header_bytes or bytes.len > maximum_bytes) return error.Corrupt;
        if (!std.mem.eql(u8, bytes[0..4], "LRD3")) return error.Outdated;
        if (std.mem.readInt(u64, bytes[4..12], .little) != source.digest() or bytes[12] != source.count) return error.Outdated;
        const count: usize = source.count;
        const slots: usize = bytes[13];
        if (count == 0 or count > light.maximum_sections or slots == 0 or slots > count or bytes[14] != 0 or bytes[15] != 0) return error.Corrupt;
        const maximum_size = std.mem.readInt(u32, bytes[16..20], .little);
        if (maximum_size == 0 or maximum_size >= 1 << 21) return error.Corrupt;
        const entities = std.mem.readInt(u32, bytes[20..24], .little);
        if (count < 32 and entities >> @intCast(count) != 0) return error.Corrupt;
        const table = header_bytes + count;
        var cursor = table + slots * 2;
        if (cursor > bytes.len) return error.Corrupt;
        var entity_slots: u32 = 0;
        for (0..slots) |slot| {
            if (std.mem.readInt(u16, bytes[table + slot * 2 ..][0..2], .little) != cursor) return error.Corrupt;
            cursor += try entrySize(bytes, cursor);
        }
        const data = cursor;
        for (0..slots) |slot| {
            const entry = try Entry.parse(bytes, std.mem.readInt(u16, bytes[table + slot * 2 ..][0..2], .little));
            if (!entry.header.within(data, bytes.len) or entry.header.length == 0 or entry.header.decoded == 0 or entry.header.decoded > 4096) return error.Corrupt;
            if (entry.words) |words| if (!words.within(data, bytes.len) or words.length == 0 or words.decoded == 0 or words.decoded > 32768) return error.Corrupt;
            if (entry.biome) |biome| if (!biome.within(data, bytes.len) or biome.length == 0 or biome.decoded == 0 or biome.decoded > 1024) return error.Corrupt;
            if (entry.entity_count > 4096 or (entry.entity_count == 0) != (entry.entity_length == 0)) return error.Corrupt;
            if (entry.entity_count != 0 and (entry.entity_offset < data or entry.entity_offset > bytes.len or entry.entity_length > bytes.len - entry.entity_offset)) return error.Corrupt;
            const inline_words: u32 = if (entry.words) |words| words.decoded else 0;
            if (entry.terrain.decoded < @as(u32, entry.header.decoded) + inline_words) return error.Corrupt;
            const biome: u32 = if (entry.biome) |value| value.decoded else 0;
            if (entry.full.decoded != entry.terrain.decoded + biome) return error.Corrupt;
            if (entry.entity_count != 0) entity_slots |= @as(u32, 1) << @intCast(slot);
        }
        for (0..count) |index| {
            const slot = bytes[header_bytes + index];
            if (slot >= slots) return error.Corrupt;
            if ((entities & (@as(u32, 1) << @intCast(index)) != 0) != (entity_slots & (@as(u32, 1) << @intCast(slot)) != 0)) return error.Corrupt;
        }
        return .{ .bytes = bytes, .count = source.count, .maximum_size = maximum_size, .entity_sections = entities };
    }

    pub fn section(self: View, index: usize) Section {
        assert(index < self.count);
        const slot = self.bytes[header_bytes + index];
        assert(slot < self.bytes[13]);
        const offset = std.mem.readInt(u16, self.bytes[header_bytes + @as(usize, self.count) + @as(usize, slot) * 2 ..][0..2], .little);
        const entry = Entry.parse(self.bytes, offset) catch unreachable;
        return .{
            .header = entry.header.fragment(self.bytes),
            .words = if (entry.words) |words| words.fragment(self.bytes) else null,
            .biome = if (entry.biome) |biome| biome.fragment(self.bytes) else null,
            .entities = self.bytes[entry.entity_offset..][0..entry.entity_length],
            .entity_count = entry.entity_count,
            .terrain_digest = entry.terrain,
            .full_digest = entry.full,
        };
    }
};

fn entrySize(bytes: []const u8, offset: usize) !usize {
    if (offset >= bytes.len) return error.Corrupt;
    const flags = bytes[offset];
    if (flags & ~(flag_words | flag_biome | flag_entities) != 0) return error.Corrupt;
    const size = 1 + reference_bytes + digest_bytes +
        @as(usize, @intFromBool(flags & flag_words != 0)) * reference_bytes +
        @as(usize, @intFromBool(flags & flag_biome != 0)) * (reference_bytes + digest_bytes) +
        @as(usize, @intFromBool(flags & flag_entities != 0)) * entities_bytes;
    if (size > bytes.len - offset) return error.Corrupt;
    return size;
}

const Reference = struct {
    offset: u32,
    length: u16,
    decoded: u16,
    checksum: u32,

    fn decode(bytes: *const [reference_bytes]u8) Reference {
        return .{ .offset = std.mem.readInt(u32, bytes[0..4], .little), .length = std.mem.readInt(u16, bytes[4..6], .little), .decoded = std.mem.readInt(u16, bytes[6..8], .little), .checksum = std.mem.readInt(u32, bytes[8..12], .little) };
    }

    fn within(self: Reference, start: usize, end: usize) bool {
        return self.offset >= start and self.offset <= end and self.length <= end - self.offset;
    }

    fn fragment(self: Reference, bytes: []const u8) deflate.fragments.Fragment {
        return .{ .bytes = bytes[self.offset..][0..self.length], .decoded = self.decoded, .checksum = self.checksum };
    }
};

/// Fields in packed order: flags, header reference, then the words, biome and entity parts
/// the flags select, the terrain digest, and the full digest when a biome is present.
const Entry = struct {
    header: Reference,
    words: ?Reference,
    biome: ?Reference,
    entity_offset: u32,
    entity_length: u32,
    entity_count: u16,
    terrain: deflate.fragments.Digest,
    full: deflate.fragments.Digest,

    fn parse(bytes: []const u8, offset: usize) !Entry {
        _ = try entrySize(bytes, offset);
        const flags = bytes[offset];
        var cursor = offset + 1;
        var result: Entry = .{ .header = Reference.decode(bytes[cursor..][0..reference_bytes]), .words = null, .biome = null, .entity_offset = 0, .entity_length = 0, .entity_count = 0, .terrain = undefined, .full = undefined };
        cursor += reference_bytes;
        if (flags & flag_words != 0) {
            result.words = Reference.decode(bytes[cursor..][0..reference_bytes]);
            cursor += reference_bytes;
        }
        if (flags & flag_biome != 0) {
            result.biome = Reference.decode(bytes[cursor..][0..reference_bytes]);
            cursor += reference_bytes;
        }
        if (flags & flag_entities != 0) {
            result.entity_offset = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
            result.entity_length = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .little);
            result.entity_count = std.mem.readInt(u16, bytes[cursor + 8 ..][0..2], .little);
            if (result.entity_count == 0) return error.Corrupt;
            cursor += entities_bytes;
        }
        result.terrain = readDigest(bytes[cursor..][0..digest_bytes]);
        cursor += digest_bytes;
        result.full = if (flags & flag_biome != 0) readDigest(bytes[cursor..][0..digest_bytes]) else result.terrain;
        return result;
    }
};

fn readDigest(bytes: *const [digest_bytes]u8) deflate.fragments.Digest {
    return .{ .decoded = std.mem.readInt(u16, bytes[0..2], .little), .checksum = std.mem.readInt(u32, bytes[2..6], .little) };
}

fn writeDigest(bytes: *[digest_bytes]u8, decoded: u32, checksum: u32) void {
    std.mem.writeInt(u16, bytes[0..2], @intCast(decoded), .little);
    std.mem.writeInt(u32, bytes[2..6], checksum, .little);
}

/// Working entries hold three 16 byte fragment references (offset, length, decoded,
/// checksum), entity offset, length and count, then the terrain and full digests.
pub const Writer = struct {
    bytes: []u8,
    cursor: usize,
    count: u8,
    finished: bool = false,

    pub fn begin(bytes: []u8, source: Source, maximum_size: usize) !Writer {
        assert(source.count > 0 and source.count <= light.maximum_sections and maximum_size > 0 and maximum_size < 1 << 21);
        const start = header_bytes + @as(usize, source.count) * work_entry_bytes + source.count;
        if (bytes.len < start) return error.NoSpaceLeft;
        @memset(bytes[0..start], 0);
        bytes[0..4].* = "LRD3".*;
        std.mem.writeInt(u64, bytes[4..12], source.digest(), .little);
        bytes[12] = source.count;
        std.mem.writeInt(u32, bytes[16..20], @intCast(maximum_size), .little);
        return .{ .bytes = bytes, .cursor = start, .count = source.count };
    }

    fn work(self: *Writer, index: usize) *[work_entry_bytes]u8 {
        assert(index < self.count);
        return self.bytes[header_bytes + index * work_entry_bytes ..][0..work_entry_bytes];
    }

    fn workFragment(self: *const Writer, ref: *const [16]u8) ?deflate.fragments.Fragment {
        const length = std.mem.readInt(u32, ref[4..8], .little);
        if (length == 0) return null;
        const offset = std.mem.readInt(u32, ref[0..4], .little);
        return .{ .bytes = self.bytes[offset..][0..length], .decoded = std.mem.readInt(u32, ref[8..12], .little), .checksum = std.mem.readInt(u32, ref[12..16], .little) };
    }

    pub fn append(self: *Writer, index: usize, component: Component, fragment: deflate.fragments.Fragment) !void {
        assert(!self.finished and index < self.count and fragment.bytes.len > 0 and fragment.decoded > 0);
        assert(fragment.bytes.len <= std.math.maxInt(u16) and fragment.decoded <= std.math.maxInt(u16));
        if (fragment.bytes.len > self.bytes.len - self.cursor) return error.NoSpaceLeft;
        const ref = self.work(index)[@as(usize, @backingInt(component)) * 16 ..][0..16];
        assert(std.mem.allEqual(u8, ref, 0));
        std.mem.writeInt(u32, ref[0..4], @intCast(self.cursor), .little);
        std.mem.writeInt(u32, ref[4..8], @intCast(fragment.bytes.len), .little);
        std.mem.writeInt(u32, ref[8..12], fragment.decoded, .little);
        std.mem.writeInt(u32, ref[12..16], fragment.checksum, .little);
        @memcpy(self.bytes[self.cursor..][0..fragment.bytes.len], fragment.bytes);
        self.cursor += fragment.bytes.len;
    }

    pub fn reuse(self: *Writer, index: usize, component: Component, previous: usize) bool {
        assert(!self.finished and previous < index and index < self.count);
        const field = @as(usize, @backingInt(component)) * 16;
        const from = self.work(previous)[field..][0..16];
        if (std.mem.readInt(u32, from[4..8], .little) == 0) return false;
        const to = self.work(index)[field..][0..16];
        assert(std.mem.allEqual(u8, to, 0));
        to.* = from.*;
        return true;
    }

    /// Shared words stay in the frame, so only their length and checksum join the digests.
    pub fn aggregate(self: *Writer, index: usize, shared_words: ?deflate.fragments.Fragment) void {
        assert(!self.finished and index < self.count);
        const entry = self.work(index);
        var digest: deflate.fragments.Digest = .{};
        digest.append(self.workFragment(entry[0..16]).?);
        if (self.workFragment(entry[16..32]) orelse shared_words) |words| {
            assert(shared_words == null or std.mem.allEqual(u8, entry[16..32], 0));
            digest.append(words);
        }
        std.mem.writeInt(u32, entry[60..64], digest.decoded, .little);
        std.mem.writeInt(u32, entry[64..68], digest.checksum, .little);
        if (self.workFragment(entry[32..48])) |biome| digest.append(biome);
        std.mem.writeInt(u32, entry[68..72], digest.decoded, .little);
        std.mem.writeInt(u32, entry[72..76], digest.checksum, .little);
    }

    pub fn entities(self: *Writer, index: usize, bytes: []const u8, count: u16) !void {
        assert(!self.finished and index < self.count and count <= 4096 and (bytes.len == 0) == (count == 0));
        if (count == 0) return;
        if (bytes.len > self.bytes.len - self.cursor) return error.NoSpaceLeft;
        const ref = self.work(index)[48..60];
        assert(std.mem.allEqual(u8, ref, 0));
        std.mem.writeInt(u32, ref[0..4], @intCast(self.cursor), .little);
        std.mem.writeInt(u32, ref[4..8], @intCast(bytes.len), .little);
        std.mem.writeInt(u16, ref[8..10], count, .little);
        const mask = std.mem.readInt(u32, self.bytes[20..24], .little);
        std.mem.writeInt(u32, self.bytes[20..24], mask | (@as(u32, 1) << @intCast(index)), .little);
        @memcpy(self.bytes[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
    }

    /// Packs unique working entries, then moves the fragment bytes down behind them.
    pub fn finish(self: *Writer) []const u8 {
        assert(!self.finished and self.cursor <= self.bytes.len and self.cursor <= maximum_bytes);
        var entries: [light.maximum_sections][work_entry_bytes]u8 = undefined;
        var indices: [light.maximum_sections]u8 = undefined;
        var unique: usize = 0;
        var packed_bytes: usize = 0;
        for (0..self.count) |index| {
            const entry = self.work(index);
            assert(std.mem.readInt(u32, entry[4..8], .little) != 0);
            indices[index] = for (entries[0..unique], 0..) |*previous, slot| {
                if (std.mem.eql(u8, entry, previous)) break @intCast(slot);
            } else new: {
                entries[unique] = entry.*;
                packed_bytes += packedSize(entry);
                unique += 1;
                break :new @intCast(unique - 1);
            };
        }
        const before = header_bytes + @as(usize, self.count) * work_entry_bytes + self.count;
        const after = header_bytes + @as(usize, self.count) + unique * 2 + packed_bytes;
        const length = self.cursor - before;
        assert(after <= before);
        std.mem.copyForwards(u8, self.bytes[after..][0..length], self.bytes[before..][0..length]);
        self.bytes[13] = @intCast(unique);
        @memcpy(self.bytes[header_bytes..][0..self.count], indices[0..self.count]);
        var cursor = header_bytes + @as(usize, self.count) + unique * 2;
        for (entries[0..unique], 0..) |*entry, slot| {
            std.mem.writeInt(u16, self.bytes[header_bytes + @as(usize, self.count) + slot * 2 ..][0..2], @intCast(cursor), .little);
            cursor += writePacked(self.bytes[cursor..], entry, after, before);
        }
        assert(cursor == after);
        self.cursor = after + length;
        self.finished = true;
        return self.bytes[0..self.cursor];
    }

    fn packedSize(entry: *const [work_entry_bytes]u8) usize {
        const words = std.mem.readInt(u32, entry[20..24], .little) != 0;
        const biome = std.mem.readInt(u32, entry[36..40], .little) != 0;
        const entity = std.mem.readInt(u16, entry[56..58], .little) != 0;
        return 1 + reference_bytes + digest_bytes + @as(usize, @intFromBool(words)) * reference_bytes +
            @as(usize, @intFromBool(biome)) * (reference_bytes + digest_bytes) + @as(usize, @intFromBool(entity)) * entities_bytes;
    }

    fn writePacked(output: []u8, entry: *const [work_entry_bytes]u8, after: usize, before: usize) usize {
        const words = std.mem.readInt(u32, entry[20..24], .little) != 0;
        const biome = std.mem.readInt(u32, entry[36..40], .little) != 0;
        const entity = std.mem.readInt(u16, entry[56..58], .little) != 0;
        output[0] = (if (words) flag_words else 0) | (if (biome) flag_biome else 0) | (if (entity) flag_entities else 0);
        var cursor: usize = 1;
        for ([_]usize{ 0, 16, 32 }, [_]bool{ true, words, biome }) |field, present| {
            if (!present) continue;
            const ref = entry[field..][0..16];
            const offset = std.mem.readInt(u32, ref[0..4], .little);
            assert(offset >= before);
            std.mem.writeInt(u32, output[cursor..][0..4], @intCast(offset - before + after), .little);
            std.mem.writeInt(u16, output[cursor + 4 ..][0..2], @intCast(std.mem.readInt(u32, ref[4..8], .little)), .little);
            std.mem.writeInt(u16, output[cursor + 6 ..][0..2], @intCast(std.mem.readInt(u32, ref[8..12], .little)), .little);
            @memcpy(output[cursor + 8 ..][0..4], ref[12..16]);
            cursor += reference_bytes;
        }
        if (entity) {
            const offset = std.mem.readInt(u32, entry[48..52], .little);
            assert(offset >= before);
            std.mem.writeInt(u32, output[cursor..][0..4], @intCast(offset - before + after), .little);
            @memcpy(output[cursor + 4 ..][0..6], entry[52..58]);
            cursor += entities_bytes;
        }
        writeDigest(output[cursor..][0..digest_bytes], std.mem.readInt(u32, entry[60..64], .little), std.mem.readInt(u32, entry[64..68], .little));
        cursor += digest_bytes;
        if (biome) {
            writeDigest(output[cursor..][0..digest_bytes], std.mem.readInt(u32, entry[68..72], .little), std.mem.readInt(u32, entry[72..76], .little));
            cursor += digest_bytes;
        }
        return cursor;
    }
};

test "delivery columns keep common data once and validate protocol directory ranges" {
    var bytes: [1024]u8 = undefined;
    const at: light.Column = .{ .world = 3, .x = -8, .z = 12 };
    var builder = try Column.Builder.begin(&bytes, at, "shared", 2);
    const first = builder.destination()[0..header_bytes];
    @memset(first, 1);
    builder.append(@splat(1), first);
    const second = builder.destination()[0..header_bytes];
    @memset(second, 2);
    builder.append(@splat(2), second);
    const encoded = builder.finish();
    const column = try Column.read(encoded);
    try std.testing.expectEqualDeep(at, column.column);
    try std.testing.expectEqualSlices(u8, "shared", column.frame);
    try std.testing.expectEqualSlices(u8, first, column.find(@splat(1)).?);
    try std.testing.expectEqualSlices(u8, second, column.find(@splat(2)).?);
    try std.testing.expect(column.find(@splat(3)) == null);
    try std.testing.expectEqualSlices(u8, "shared", try Column.common(encoded[0 .. Column.header_size + 6]));
    try std.testing.expectError(error.Incomplete, Column.read(encoded[0 .. encoded.len - 1]));
    bytes[Column.header_size] ^= 1;
    try std.testing.expectError(error.Corrupt, Column.common(encoded[0 .. Column.header_size + 6]));
    bytes[Column.header_size] ^= 1;
    bytes[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.Corrupt, Column.read(encoded));
    try std.testing.expectEqualSlices(u8, "shared", try Column.common(encoded[0 .. Column.header_size + 6]));
    bytes[encoded.len - 1] ^= 1;
    std.mem.writeInt(u32, bytes[Column.header_size + 6 + 32 ..][0..4], @intCast(encoded.len), .little);
    try std.testing.expectError(error.Corrupt, Column.read(encoded));
    builder = try Column.Builder.begin(&bytes, at, "shared", 2);
    const only = builder.destination()[0..header_bytes];
    @memset(only, 3);
    builder.append(@splat(3), only);
    const partial = try Column.read(builder.finish());
    try std.testing.expectEqual(@as(usize, 1), partial.variants);
    try std.testing.expectEqual(@as(usize, 2), partial.slots);
    try std.testing.expectEqualSlices(u8, only, partial.find(@splat(3)).?);
    try std.testing.expect(partial.find(@splat(0)) == null);
}

test "delivery records share fragments and reject stale sources and invalid ranges" {
    var baker = try deflate.fragments.Baker.init(std.testing.allocator);
    defer baker.deinit();
    var encoded: [128]u8 = undefined;
    const fragment = try baker.encode("section-header", &encoded);
    var bytes: [2048]u8 = undefined;
    const source: Source = .{ .rules = @splat(3), .revision = 90, .minimum = -4, .count = 2 };
    var writer = try Writer.begin(&bytes, source, 4096);
    try writer.append(0, .header, fragment);
    writer.aggregate(0, null);
    try std.testing.expect(writer.reuse(1, .header, 0));
    const shared: deflate.fragments.Fragment = .{ .bytes = "shared packed indices", .decoded = 2048, .checksum = 17 };
    try writer.entities(1, "entity", 1);
    writer.aggregate(1, shared);
    const record = writer.finish();
    // Section 0 packs flags, a header reference and a digest. Section 1 adds entities.
    try std.testing.expectEqual(header_bytes + 2 + 2 * 2 + 19 + 29 + fragment.bytes.len + 6, record.len);
    const view = try View.read(record, source);
    try std.testing.expectEqual(view.section(0).header.bytes.ptr, view.section(1).header.bytes.ptr);
    try std.testing.expectEqualSlices(u8, fragment.bytes, view.section(0).header.bytes);
    try std.testing.expectEqual(fragment.checksum, view.section(1).header.checksum);
    try std.testing.expect(view.section(1).words == null);
    try std.testing.expectEqual(2048 + fragment.decoded, view.section(1).terrain_digest.decoded);
    try std.testing.expectEqual(view.section(1).terrain_digest, view.section(1).full_digest);
    try std.testing.expectEqualStrings("entity", view.section(1).entities);
    try std.testing.expectEqual(@as(u16, 1), view.section(1).entity_count);
    try std.testing.expectEqual(@as(u32, 2), view.entity_sections);
    try std.testing.expectEqual(@as(?u32, 4096), View.declaredMaximum(record));
    var changed = source;
    changed.revision += 1;
    try std.testing.expectError(error.Outdated, View.read(record, changed));
    changed = source;
    changed.rules[0] ^= 1;
    try std.testing.expectError(error.Outdated, View.read(record, changed));
    for ([_]usize{ 0, header_bytes - 1, header_bytes + 2, record.len - 1 }) |length| {
        try std.testing.expectError(error.Corrupt, View.read(record[0..length], source));
    }
    const saved = bytes[header_bytes + 2 ..][0..2].*;
    std.mem.writeInt(u16, bytes[header_bytes + 2 ..][0..2], 0xffff, .little);
    try std.testing.expectError(error.Corrupt, View.read(record, source));
    bytes[header_bytes + 2 ..][0..2].* = saved;
    _ = try View.read(record, source);
    var tiny: [header_bytes]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, Writer.begin(&tiny, source, 4096));
}

test "packed entries keep inline words biomes and both digests" {
    var bytes: [4096]u8 = undefined;
    const source: Source = .{ .rules = @splat(1), .revision = 5, .minimum = 0, .count = 3 };
    var writer = try Writer.begin(&bytes, source, 2000);
    const header: deflate.fragments.Fragment = .{ .bytes = "header", .decoded = 40, .checksum = 0x01020304 };
    const words: deflate.fragments.Fragment = .{ .bytes = "direct words", .decoded = 8192, .checksum = 0x0a0b0c0d };
    const biome: deflate.fragments.Fragment = .{ .bytes = "biome", .decoded = 64, .checksum = 0x11121314 };
    for (0..3) |index| {
        if (index == 0) try writer.append(0, .header, header) else try std.testing.expect(writer.reuse(index, .header, 0));
        if (index == 1) try writer.append(1, .words, words);
        if (index == 2) try writer.append(2, .biome, biome);
        writer.aggregate(index, null);
    }
    const view = try View.read(writer.finish(), source);
    try std.testing.expectEqual(@as(u8, 3), view.bytes[13]);
    const plain = view.section(0);
    const direct = view.section(1);
    const shaded = view.section(2);
    try std.testing.expect(plain.words == null and plain.biome == null);
    try std.testing.expectEqualStrings("direct words", direct.words.?.bytes);
    try std.testing.expectEqual(words.checksum, direct.words.?.checksum);
    try std.testing.expectEqual(@as(u32, 8192 + 40), direct.terrain_digest.decoded);
    try std.testing.expectEqualStrings("biome", shaded.biome.?.bytes);
    try std.testing.expectEqual(@as(u32, 40), shaded.terrain_digest.decoded);
    try std.testing.expectEqual(@as(u32, 104), shaded.full_digest.decoded);
    var expected: deflate.fragments.Digest = .{};
    expected.append(header);
    expected.append(biome);
    try std.testing.expectEqual(expected, shaded.full_digest);
}

test "repeated sections use one shared directory entry" {
    var bytes: [4096]u8 = undefined;
    const source: Source = .{ .rules = @splat(0), .revision = 1, .minimum = 0, .count = 24 };
    var writer = try Writer.begin(&bytes, source, 1000);
    try writer.append(0, .header, .{ .bytes = &.{ 0, 0, 0, 255, 255 }, .decoded = 1, .checksum = 1 });
    writer.aggregate(0, null);
    for (1..24) |index| {
        try std.testing.expect(writer.reuse(index, .header, 0));
        writer.aggregate(index, null);
    }
    const record = writer.finish();
    try std.testing.expectEqual(header_bytes + 24 + 2 + 19 + 5, record.len);
    const view = try View.read(record, source);
    for (0..24) |index| try std.testing.expectEqual(view.section(0).header.bytes.ptr, view.section(index).header.bytes.ptr);
}
