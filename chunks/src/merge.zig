const std = @import("std");
const records = @import("records");
const zstandard = @import("zstandard");
const encoding = @import("encoding.zig");
const patch = @import("patch.zig");
const Store = @import("store.zig").Store;

pub const Merger = struct {
    pub const State = enum { free, preparing, ready, publishing };
    pub const Slot = struct {
        state: State = .free,
        key: [16]u8 = undefined,
        invalidated: bool = false,
        length: usize = 0,
    };
    const scan_batch = 64;
    slots: []Slot,
    frames: []u8,
    stride: usize,
    raw: []u8,
    sections: []u8,
    codec: zstandard.Compressor,
    active: std.atomic.Value(bool) = .init(false),
    after: [16]u8 = undefined,
    after_len: usize = 0,
    scan_keys: [scan_batch][16]u8 = undefined,
    scan_entries: [scan_batch]records.ScanKey = undefined,
    groups: [scan_batch][16]u8 = undefined,
    group_count: usize = 0,
    next_group: usize = 0,
    scan_more: bool = false,
    round_revision: u64 = 0,
    scanned_revision: ?u64 = null,
    keys: [64][16]u8 = undefined,
    requests: [64]records.Get = undefined,
    lengths: [64]?usize = undefined,
    generations: [64]u64 = undefined,

    pub fn init(allocator: std.mem.Allocator, maximum: usize, section_count: usize, capacity: usize) !*Merger {
        const self = try allocator.create(Merger);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, @min(capacity, 32));
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const stride = zstandard.bound(maximum);
        const frames = try allocator.alloc(u8, slots.len * stride);
        errdefer allocator.free(frames);
        const raw = try allocator.alloc(u8, maximum);
        errdefer allocator.free(raw);
        const sections = try allocator.alloc(u8, section_count * (patch.maximum + 1));
        errdefer allocator.free(sections);
        self.* = .{ .slots = slots, .frames = frames, .stride = stride, .raw = raw, .sections = sections, .codec = try zstandard.Compressor.init(allocator, 6, maximum) };
        for (&self.scan_entries, &self.scan_keys) |*entry, *key| entry.* = .{ .key = key };
        return self;
    }

    /// The store mutex protects slot ownership and invalidation across I/O waits.
    pub fn invalidate(self: *Merger, keys: []const []const u8) void {
        for (self.slots) |*slot| {
            if (slot.state != .preparing and slot.state != .ready) continue;
            for (keys) |key| if (std.mem.eql(u8, &slot.key, key)) {
                slot.invalidated = true;
                break;
            };
        }
    }

    /// Discover one key batch and prepare at most one group on the background owner.
    pub fn prepare(self: *Merger, store: *Store) !bool {
        const already_active = self.active.swap(true, .acq_rel);
        std.debug.assert(!already_active);
        defer {
            const was_active = self.active.swap(false, .release);
            std.debug.assert(was_active);
        }
        const revision = store.discoveryRevision() orelse return false;
        if (self.next_group == self.group_count) {
            if (!self.scan_more) {
                if (self.scanned_revision == revision) return false;
                self.round_revision = revision;
            }
            var cursor: records.ScanCursor = .{ .after = &self.after, .after_len = self.after_len };
            store.table_lock.lockSharedUncancelable(store.io);
            const scanned = store.overlays.scanKeys(&cursor, &self.scan_entries);
            store.table_lock.unlockShared(store.io);
            const result = try scanned;
            store.discovery_scans.add(1);
            std.debug.assert(result.count <= scan_batch);
            self.after_len = if (result.more) cursor.after_len else 0;
            self.scan_more = result.more;
            self.group_count = 0;
            self.next_group = 0;
            var buckets: [scan_batch * 2]u8 = @splat(scan_batch);
            for (self.scan_entries[0..result.count]) |entry| {
                if (entry.key_len != 16) return error.Corrupt;
                const key = try store.groupKey(entry.key[0..entry.key_len]);
                var bucket = std.hash.Wyhash.hash(0, &key) & (buckets.len - 1);
                for (0..buckets.len) |_| {
                    const index = buckets[bucket];
                    if (index == scan_batch) {
                        self.groups[self.group_count] = key;
                        buckets[bucket] = @intCast(self.group_count);
                        self.group_count += 1;
                        break;
                    }
                    if (std.mem.eql(u8, &self.groups[index], &key)) break;
                    bucket = (bucket + 1) & (buckets.len - 1);
                } else unreachable;
            }
        }
        defer if (self.next_group == self.group_count and !self.scan_more) {
            self.scanned_revision = self.round_revision;
        };
        const slot_index = claim: while (self.next_group < self.group_count) {
            const key = self.groups[self.next_group];
            store.mutex.lockUncancelable(store.io);
            if (store.writing or store.draining) {
                store.mutex.unlock(store.io);
                return false;
            }
            for (self.slots) |*slot| if (slot.state == .ready and slot.invalidated) {
                slot.state = .free;
            };
            const duplicate = for (self.slots) |slot| {
                if (slot.state != .free and std.mem.eql(u8, &slot.key, &key)) break true;
            } else false;
            if (duplicate) {
                self.next_group += 1;
                store.mutex.unlock(store.io);
                continue;
            }
            const index = for (self.slots, 0..) |slot, index| {
                if (slot.state == .free) break index;
            } else {
                store.mutex.unlock(store.io);
                return false;
            };
            self.slots[index] = .{ .state = .preparing, .key = key };
            self.next_group += 1;
            store.mutex.unlock(store.io);
            break :claim index;
        } else return self.scan_more;
        const slot = &self.slots[slot_index];
        var ready = false;
        defer if (!ready) {
            store.mutex.lockUncancelable(store.io);
            std.debug.assert(slot.state == .preparing);
            slot.state = .free;
            store.mutex.unlock(store.io);
        };
        store.sectionKeys(&slot.key, self.keys[0..store.section_count]);
        for (self.keys[0..store.section_count], self.requests[0..store.section_count], 0..) |*key, *request, index| request.* = .{
            .key = key,
            .destination = self.sections[index * (patch.maximum + 1) ..][0..encoding.maximum_decoded_bytes],
        };
        var snapshot: Store.Snapshot = .{ .generations = self.generations[0..store.section_count] };
        try store.readSnapshot(self.requests[0..store.section_count], self.lengths[0..store.section_count], &snapshot);
        store.mutex.lockUncancelable(store.io);
        const invalidated = slot.invalidated;
        store.mutex.unlock(store.io);
        if (invalidated) return self.next_group < self.group_count or self.scan_more;
        const generation = self.generations[0];
        if (generation == 0) return self.next_group < self.group_count or self.scan_more;
        for (self.generations[0..store.section_count]) |value| if (value != generation) return error.Corrupt;
        if (generation == std.math.maxInt(u64)) return error.NoSpace;
        std.mem.writeInt(u64, self.raw[0..8], generation + 1, .little);
        var offset = store.header_bytes;
        for (self.lengths[0..store.section_count], 0..) |length, index| {
            const size = length orelse 0;
            std.mem.writeInt(u16, self.raw[8 + index * 2 ..][0..2], @intCast(size), .little);
            @memcpy(self.raw[offset..][0..size], self.sections[index * (patch.maximum + 1) ..][0..size]);
            offset += size;
        }
        std.debug.assert(offset <= self.raw.len);
        const frame = self.frames[slot_index * self.stride ..][0..self.stride];
        store.table_lock.lockSharedUncancelable(store.io);
        const old_length = store.bases.backend.table.get(&slot.key, frame);
        store.table_lock.unlockShared(store.io);
        const previous = (try old_length) orelse return self.next_group < self.group_count or self.scan_more;
        const encoded = if (offset == store.header_bytes) frame[0..0] else try self.codec.encode(self.raw[0..offset], frame);
        if (encoded.len >= previous + snapshot.overlay_bytes) return self.next_group < self.group_count or self.scan_more;
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        std.debug.assert(slot.state == .preparing);
        if (slot.invalidated) return self.next_group < self.group_count or self.scan_more;
        slot.length = encoded.len;
        slot.state = .ready;
        store.prepared.add(1);
        ready = true;
        return true;
    }
};
