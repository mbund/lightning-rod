const std = @import("std");
const networking = @import("networking");
pub const headroom = 6;

/// The bytes a packet of `length` takes in the pool: itself, the headroom before it its frame
/// header goes in, and room to compress into, which incompressible bytes outgrow by a few bytes
/// a block. A packet compresses in place of itself, as it waits there for every recipient.
pub fn storedBytes(length: usize) usize {
    return length + headroom + 16 + 5 * (length / 5000 + 1);
}

pub const PageId = u16;

pub const Configuration = struct {
    pages: usize,
    page_bytes: usize,
    unit_bytes: usize = 16 * 1024,
    recipients_per_page: usize,
    /// Recipients the publications of this source hold between them until the worker takes
    /// them. Each recipient of each packet charges at least the bound of the smallest frame,
    /// so credit bounds them: see `Service`.
    recipient_handles: usize = 0,
    pool: ?*Pool = null,
};

pub const Frame = struct {
    id: i32,
    payload: []const u8,
    body: []const u8,
    length: usize,
};

pub const max_frame_bytes: usize = (1 << 21) - 1;

pub fn frame(bytes: []const u8, max_packet: usize) error{ Incomplete, Malformed }!Frame {
    const length, const rest = try readVarint(bytes);
    if (length < 0 or length > @min(max_packet, max_frame_bytes) or bytes.len - rest.len > 3) return error.Malformed;

    const n: usize = @intCast(length);
    if (rest.len < n) return error.Incomplete;
    const id, const payload = try readVarint(rest[0..n]);
    return .{ .id = id, .payload = payload, .body = rest[0..n], .length = bytes.len - rest.len + n };
}

pub fn readVarint(bytes: []const u8) error{ Incomplete, Malformed }!struct { i32, []const u8 } {
    var value: u32 = 0;

    for (0..5) |i| {
        if (i >= bytes.len) return error.Incomplete;

        const b = bytes[i];
        if (i == 4 and b > 15) return error.Malformed;
        value |= @as(u32, b & 0x7f) << @intCast(i * 7);
        if (b & 0x80 == 0) return .{ @bitCast(value), bytes[i + 1 ..] };
    }

    return error.Malformed;
}

pub const Reservation = struct {
    decoded_length: usize = 0,
    page: PageId,
    generation: u64,
    bytes: []u8,
};

pub const Group = struct {
    protocol: ?i32 = null,
    generation: u64 = 0,
    bytes: u32 = 0,
    first: PageId = 0,
    index: u8 = 0,
    count: u8 = 1,
};

pub const Recipients = struct {
    handles: []const networking.Handle,
    mask: []const usize = &.{},
    len: usize,

    pub fn all(handles: []const networking.Handle) Recipients {
        return .{ .handles = handles, .len = handles.len };
    }

    // Slots address the retained audience. They are stable across different selection masks.
    pub fn at(self: Recipients, slot: usize) networking.Handle {
        std.debug.assert(slot < self.handles.len);
        return self.handles[slot];
    }

    pub fn iterator(self: Recipients) Iterator {
        return .{ .recipients = self };
    }

    pub fn first(self: Recipients) ?networking.Handle {
        var selected = self.iterator();
        return selected.next();
    }

    pub fn eqlSlice(self: Recipients, handles: []const networking.Handle) bool {
        if (self.len != handles.len) return false;
        var selected = self.iterator();
        for (handles) |handle| if (!std.meta.eql(selected.next().?, handle)) return false;
        return true;
    }

    pub const Iterator = struct {
        recipients: Recipients,
        slot: usize = 0,
        word: usize = 0,
        pending: usize = 0,

        pub fn next(self: *Iterator) ?networking.Handle {
            if (self.recipients.mask.len == 0) {
                if (self.slot == self.recipients.handles.len) return null;
                const handle = self.recipients.handles[self.slot];
                self.slot += 1;
                return handle;
            }
            while (self.pending == 0) {
                if (self.word == self.recipients.mask.len) return null;
                self.pending = self.recipients.mask[self.word];
                self.word += 1;
            }
            const slot = (self.word - 1) * @bitSizeOf(usize) + @ctz(self.pending);
            self.pending &= self.pending - 1;
            return self.recipients.at(slot);
        }
    };
};

pub const RawPacket = struct {
    decoded_length: usize = 0,

    page: PageId,
    units: usize,
    generation: u64,
    bytes: []const u8,
    recipients: Recipients,
    /// Where its source's ring of recipients ends after this packet's, which the worker
    /// releases once it took the packet.
    recipient_end: usize = 0,
    group: Group = .{},
    // Mask storage belongs to this packet's page until it is recycled.
    selection: ?struct { pool: *const Pool, audience: usize, generation: u64, mask: []const usize } = null,

    pub fn boundLength(self: RawPacket) usize {
        return @max(self.bytes.len, self.decoded_length);
    }

    pub fn sameAudience(a: RawPacket, b: RawPacket) bool {
        if (a.selection) |left| if (b.selection) |right|
            return left.pool == right.pool and left.audience == right.audience and left.generation == right.generation;
        return a.selection == null and b.selection == null and a.sameRecipients(b);
    }

    pub fn sameRecipients(a: RawPacket, b: RawPacket) bool {
        if (a.recipients.len != b.recipients.len) return false;
        if (a.selection) |left| if (b.selection) |right| {
            if (left.pool == right.pool and left.audience == right.audience and left.generation == right.generation)
                return std.mem.eql(usize, left.mask, right.mask);
        };
        var left = a.recipients.iterator();
        var right = b.recipients.iterator();
        while (left.next()) |handle| if (!std.meta.eql(handle, right.next().?)) return false;
        return true;
    }
};

pub const Audience = struct {
    pool: *Pool,
    index: usize,
    generation: u64,

    pub fn release(self: Audience, io: std.Io) void {
        const slot = &self.pool.audiences[self.index];
        std.debug.assert(slot.generation == self.generation);
        const previous = slot.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        self.pool.mutex.lockUncancelable(io);
        defer self.pool.mutex.unlock(io);
        std.debug.assert(!self.pool.free_audiences.isSet(self.index));
        self.pool.free_audiences.set(self.index);
    }
};

/// The writable slice expires at finish or cancel. Published audiences are immutable.
pub const AudienceWriter = struct {
    audience: Audience,
    handles: []networking.Handle,
    active: bool = true,

    pub fn finish(self: *AudienceWriter) Audience {
        std.debug.assert(self.active and self.handles.len > 0);
        const slot = &self.audience.pool.audiences[self.audience.index];
        std.debug.assert(slot.generation == self.audience.generation and slot.length == 0 and slot.references.load(.acquire) == 1);
        for (self.handles) |handle| std.debug.assert(handle.generation != 0);
        slot.length = self.handles.len;
        self.handles = &.{};
        self.active = false;
        return self.audience;
    }

    pub fn cancel(self: *AudienceWriter, io: std.Io) void {
        if (!self.active) return;
        const slot = &self.audience.pool.audiences[self.audience.index];
        std.debug.assert(slot.generation == self.audience.generation and slot.length == 0 and slot.references.load(.acquire) == 1);
        self.audience.release(io);
        self.handles = &.{};
        self.active = false;
    }
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    unit_bytes: usize,
    recipients_per_page: usize,
    bytes: []align(64) u8,
    pages: []SharedPages.Page,
    free_units: std.DynamicBitSetUnmanaged,
    /// A copy of the free units on which `fit` tries reservations without making them.
    trial_units: std.DynamicBitSetUnmanaged,
    audiences: []AudienceSlot,
    audience_handles: []networking.Handle,
    recipient_masks: []usize,
    free_audiences: std.DynamicBitSetUnmanaged,
    next_owner: u32 = 0,
    cursor: usize = 0,
    /// Where the next reservation of one unit is looked for in the small region.
    small_cursor: usize = 0,
    /// Reservations of one unit that are held.
    small_units: usize = 0,
    active_units: usize = 0,
    peak_units: usize = 0,
    largest_reservation: usize = 0,
    payload_bytes: usize = 0,
    peak_payload_bytes: usize = 0,

    const AudienceSlot = struct {
        references: std.atomic.Value(usize) = .init(0),
        generation: u64 = 0,
        length: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !Pool {
        if (config.pages == 0 or config.page_bytes == 0 or config.unit_bytes == 0 or config.recipients_per_page == 0) return error.InvalidConfiguration;
        // A unit holds the largest packet that fits one, with room to compress.
        const unit_bytes = storedBytes(@min(config.page_bytes, config.unit_bytes));
        const packet_bytes = storedBytes(config.page_bytes);
        const per_packet = try std.math.divCeil(usize, packet_bytes, unit_bytes);
        const units = try std.math.mul(usize, config.pages, per_packet);
        if (units > std.math.maxInt(PageId)) return error.InvalidConfiguration;
        const bytes = try allocator.alignedAlloc(u8, .@"64", try std.math.mul(usize, units, unit_bytes));
        errdefer allocator.free(bytes);
        const pages = try allocator.alloc(SharedPages.Page, units);
        errdefer allocator.free(pages);
        const audiences = try allocator.alloc(AudienceSlot, units);
        errdefer allocator.free(audiences);
        const audience_handles = try allocator.alloc(networking.Handle, try std.math.mul(usize, units, config.recipients_per_page));
        errdefer allocator.free(audience_handles);
        const words = try std.math.divCeil(usize, config.recipients_per_page, @bitSizeOf(usize));
        const recipient_masks = try allocator.alloc(usize, units * words);
        errdefer allocator.free(recipient_masks);
        var free_audiences = try std.DynamicBitSetUnmanaged.initFull(allocator, units);
        errdefer free_audiences.deinit(allocator);
        var free_units = try std.DynamicBitSetUnmanaged.initFull(allocator, units);
        errdefer free_units.deinit(allocator);
        const trial_units = try std.DynamicBitSetUnmanaged.initFull(allocator, units);
        for (audiences) |*slot| slot.* = .{};
        for (pages) |*page| page.* = .{};
        return .{ .allocator = allocator, .unit_bytes = unit_bytes, .recipients_per_page = config.recipients_per_page, .bytes = bytes, .pages = pages, .free_units = free_units, .trial_units = trial_units, .audiences = audiences, .audience_handles = audience_handles, .recipient_masks = recipient_masks, .free_audiences = free_audiences };
    }

    fn findRun(self: *const Pool, start: usize, end: usize, units: usize) ?usize {
        return self.findRunIn(&self.free_units, start, end, units);
    }

    /// The highest free unit in `[start, end)`.
    fn lastFreeIn(self: *const Pool, free_units: *const std.DynamicBitSetUnmanaged, start: usize, end: usize) ?usize {
        std.debug.assert(start <= end and end <= self.pages.len);
        const width = @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
        var at = end;
        while (at > start) {
            const word = (at - 1) / width;
            const low = @max(start, word * width);
            var bits = free_units.masks[word] >> @intCast(low - word * width);
            const span = at - low;
            if (span < width) bits &= (@as(std.DynamicBitSetUnmanaged.MaskInt, 1) << @intCast(span)) - 1;
            if (bits != 0) return low + (width - 1 - @clz(bits));
            at = low;
        }
        return null;
    }

    fn findRunIn(self: *const Pool, free_units: *const std.DynamicBitSetUnmanaged, start: usize, end: usize, units: usize) ?usize {
        std.debug.assert(start <= end and end <= self.pages.len and units > 0);
        const Mask = std.DynamicBitSetUnmanaged.MaskInt;
        const Shift = std.DynamicBitSetUnmanaged.ShiftInt;
        const width = @bitSizeOf(Mask);
        var at = start;
        var first = start;
        var free: usize = 0;
        while (at < end) {
            const word = at / width;
            const bits = free_units.masks[word] & (~@as(Mask, 0) << @as(Shift, @intCast(at % width)));
            if (bits == 0) {
                free = 0;
                at = @min(end, (word + 1) * width);
                continue;
            }
            const next_bit = word * width + @ctz(bits);
            if (next_bit >= end) return null;
            if (next_bit != at) free = 0;
            if (free == 0) first = next_bit;
            const run = @min(@as(usize, @ctz(~(bits >> @as(Shift, @intCast(next_bit % width))))), end - next_bit);
            std.debug.assert(run > 0);
            free += run;
            if (free >= units) {
                std.debug.assert(first >= start and first + units <= end);
                return first;
            }
            at = next_bit + run;
        }
        return null;
    }

    pub fn reserveAudience(self: *Pool, io: std.Io, length: usize) ?AudienceWriter {
        std.debug.assert(length > 0 and length <= self.recipients_per_page);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const index = self.free_audiences.findFirstSet() orelse return null;
        self.free_audiences.unset(index);
        const slot = &self.audiences[index];
        std.debug.assert(slot.references.load(.acquire) == 0);
        slot.generation += 1;
        slot.length = 0;
        slot.references.store(1, .release);
        return .{ .audience = .{ .pool = self, .index = index, .generation = slot.generation }, .handles = self.audience_handles[index * self.recipients_per_page ..][0..length] };
    }

    pub fn deinit(self: *Pool) void {
        std.debug.assert(self.active_units == 0 and self.payload_bytes == 0);
        for (self.pages) |*page| std.debug.assert(page.status.load(.acquire) & 255 == @backingInt(SharedPages.State.free));
        for (self.audiences) |*slot| std.debug.assert(slot.references.load(.acquire) == 0);
        self.free_audiences.deinit(self.allocator);
        self.allocator.free(self.recipient_masks);
        self.allocator.free(self.audience_handles);
        self.allocator.free(self.audiences);
        self.free_units.deinit(self.allocator);
        self.trial_units.deinit(self.allocator);
        self.allocator.free(self.pages);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Pool) usize {
        const masks = std.math.divCeil(usize, self.pages.len, @bitSizeOf(usize)) catch unreachable;
        return @sizeOf(Pool) + self.bytes.len + self.pages.len * @sizeOf(SharedPages.Page) + self.audience_handles.len * @sizeOf(networking.Handle) +
            self.audiences.len * @sizeOf(AudienceSlot) + self.recipient_masks.len * @sizeOf(usize) + 2 * (masks + 1) * @sizeOf(usize);
    }
};

pub const SharedPages = struct {
    producer: *std.Io.Mutex,
    producer_io: std.Io,
    allocator: std.mem.Allocator,
    pool: *Pool,
    owns_pool: bool,
    owner: u32,
    page_bytes: usize,
    unit_bytes: usize,
    recipients_per_page: usize,
    bytes: []align(64) u8,
    pages: []Page,
    /// The recipients of every publication not yet taken, in publication order, which the
    /// worker takes them in, so they are released from the front as they are appended at the
    /// back. A list never wraps: one that would starts at the beginning, past the end left
    /// unused. `recipient_tail` moves under the producer lock, `recipient_head` on the worker.
    recipient_ring: []networking.Handle,
    recipient_tail: usize = 0,
    recipient_head: std.atomic.Value(usize) = .init(0),
    ready: Ring,

    const State = enum(u8) { free, reserved, published, taken };

    const Page = struct {
        status: std.atomic.Value(u64) = .init(0),
        units: usize = 0,
        len: usize = 0,
        decoded_length: usize = 0,
        recipient_count: usize = 0,
        /// Where its recipients start in the ring, and where the ring ends after them.
        recipient_start: usize = 0,
        recipient_end: usize = 0,
        owner: u32 = 0,
        group: Group = .{},
        audience: ?Audience = null,
        /// The reservation was one unit when it was made, and counts toward the cap on those.
        small: bool = false,
    };

    fn status(state: State, generation: u64) u64 {
        std.debug.assert(generation <= std.math.maxInt(u56));
        return (generation << 8) | @backingInt(state);
    }

    const Ring = struct {
        slots: []PageId,
        head: std.atomic.Value(usize) = .init(0),
        tail: std.atomic.Value(usize) = .init(0),

        fn push(r: *Ring, value: PageId) bool {
            const tail = r.tail.load(.monotonic);
            if (tail -% r.head.load(.acquire) == r.slots.len) return false;
            r.slots[tail % r.slots.len] = value;
            r.tail.store(tail +% 1, .release);
            return true;
        }

        fn pop(r: *Ring) ?PageId {
            const head = r.head.load(.monotonic);
            if (head == r.tail.load(.acquire)) return null;

            const value = r.slots[head % r.slots.len];
            r.head.store(head +% 1, .release);
            return value;
        }
    };

    pub fn init(a: std.mem.Allocator, io: std.Io, c: Configuration) !SharedPages {
        if (c.pages == 0 or c.pages > std.math.maxInt(PageId) or c.page_bytes == 0 or c.recipients_per_page == 0) return error.InvalidConfiguration;

        const pool = c.pool orelse try a.create(Pool);
        if (c.pool == null) {
            errdefer a.destroy(pool);
            pool.* = try Pool.init(a, c);
        }
        errdefer if (c.pool == null) {
            pool.deinit();
            a.destroy(pool);
        };
        if (c.page_bytes + headroom > pool.bytes.len or c.recipients_per_page > pool.recipients_per_page) return error.InvalidConfiguration;
        pool.next_owner += 1;
        const ring_capacity = try std.math.ceilPowerOfTwo(usize, pool.pages.len);
        const ready = try a.alloc(PageId, ring_capacity);
        errdefer a.free(ready);
        // What credit bounds, and one more list for the end of the ring a list skips. Without
        // a bound, every unit holding a packet with every recipient.
        const handles = if (c.recipient_handles != 0) try std.math.add(usize, c.recipient_handles, c.recipients_per_page) else try std.math.mul(usize, pool.pages.len, c.recipients_per_page);
        const recipient_ring = try a.alloc(networking.Handle, handles);
        errdefer a.free(recipient_ring);

        return .{
            .allocator = a,
            .pool = pool,
            .owns_pool = c.pool == null,
            .owner = pool.next_owner,
            .producer = &pool.mutex,
            .producer_io = io,
            .page_bytes = c.page_bytes,
            .unit_bytes = pool.unit_bytes,
            .recipients_per_page = pool.recipients_per_page,
            .bytes = pool.bytes,
            .pages = pool.pages,
            .recipient_ring = recipient_ring,
            .ready = .{ .slots = ready },
        };
    }

    pub fn deinit(s: *SharedPages) void {
        s.producer.lockUncancelable(s.producer_io);
        for (s.pages) |*page| if (page.owner == s.owner) std.debug.assert(page.status.load(.acquire) & 255 == @backingInt(State.free));
        s.producer.unlock(s.producer_io);
        s.allocator.free(s.ready.slots);
        s.allocator.free(s.recipient_ring);
        if (s.owns_pool) {
            s.pool.deinit();
            s.allocator.destroy(s.pool);
        }
        s.* = undefined;
    }

    pub fn memoryBytes(s: *const SharedPages) usize {
        return @sizeOf(SharedPages) + s.ready.slots.len * @sizeOf(PageId) + s.recipient_ring.len * @sizeOf(networking.Handle) + if (s.owns_pool) s.pool.memoryBytes() else @as(usize, 0);
    }

    pub fn reserve(s: *SharedPages, len: usize) ?Reservation {
        var reservations: [1]Reservation = undefined;
        if (s.reserveMany(len, &reservations) == 0) return null;
        return reservations[0];
    }

    pub fn reserveMany(s: *SharedPages, len: usize, reservations: []Reservation) usize {
        s.producer.lockUncancelable(s.producer_io);
        defer s.producer.unlock(s.producer_io);
        var count: usize = 0;
        for (reservations) |*reservation| {
            reservation.* = s.reserveLocked(len) orelse break;
            count += 1;
        }
        return count;
    }

    /// How many of these reservations, taken in order, the pool has room for now. Nothing
    /// is reserved. Free units alone do not answer this, since a reservation needs its
    /// units in one run.
    pub fn fit(s: *SharedPages, lengths: []const usize) usize {
        s.producer.lockUncancelable(s.producer_io);
        defer s.producer.unlock(s.producer_io);
        const trial = &s.pool.trial_units;
        const width = @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
        const masks = (trial.bit_length + width - 1) / width;
        std.debug.assert(trial.bit_length == s.pool.free_units.bit_length);
        @memcpy(trial.masks[0..masks], s.pool.free_units.masks[0..masks]);
        var cursors: Cursors = .{ .large = s.pool.cursor, .small = s.pool.small_cursor };
        var small = s.pool.small_units;
        var count: usize = 0;
        for (lengths) |len| {
            if (len == 0 or len > s.page_bytes) break;
            const units = std.math.divCeil(usize, storedBytes(len), s.unit_bytes) catch unreachable;
            const first = s.place(trial, &cursors, units, small) orelse break;
            trial.setRangeValue(.{ .start = first, .end = first + units }, false);
            small += @intFromBool(units == 1);
            count += 1;
        }
        return count;
    }

    pub fn reserveBatch(s: *SharedPages, lengths: []const usize, reservations: []Reservation) usize {
        std.debug.assert(lengths.len == reservations.len);
        s.producer.lockUncancelable(s.producer_io);
        defer s.producer.unlock(s.producer_io);
        var count: usize = 0;
        for (lengths, reservations) |length, *reservation| {
            reservation.* = s.reserveLocked(length) orelse break;
            count += 1;
        }
        return count;
    }

    const Cursors = struct { large: usize, small: usize };

    /// Small packets, such as entity movement in a crowd, are kept from breaking up the
    /// runs that larger ones, such as terrain, need. Reservations of one unit start at
    /// this unit, on a page boundary, and spill below it from the top down. Larger ones
    /// start at the bottom. A small pool, or one whose every packet fits one unit, keeps
    /// a single region.
    fn smallStart(s: *const SharedPages) usize {
        const per_page = std.math.divCeil(usize, storedBytes(s.page_bytes), s.unit_bytes) catch unreachable;
        if (s.pages.len < 64 or per_page == 1) return s.pages.len;
        return s.pages.len / per_page / 2 * per_page;
    }

    /// Reservations of one unit may hold no more of the pool than this, so that a flood
    /// of them always leaves room for a full page.
    fn smallCap(s: *const SharedPages) usize {
        return s.pages.len - s.pages.len / 4;
    }

    /// Where a reservation of `units` goes in `free`.
    fn place(s: *const SharedPages, free: *const std.DynamicBitSetUnmanaged, cursors: *Cursors, units: usize, small_held: usize) ?usize {
        const total = s.pages.len;
        const split = s.smallStart();
        if (units == 1 and split < total) {
            if (small_held >= s.smallCap()) return null;
            const at = @max(cursors.small, split);
            if (s.pool.findRunIn(free, at, total, 1) orelse s.pool.findRunIn(free, split, at, 1)) |first| {
                cursors.small = if (first + 1 == total) split else first + 1;
                return first;
            }
            return s.pool.lastFreeIn(free, 0, split);
        }
        const end = split;
        const cursor = if (cursors.large < end) cursors.large else 0;
        const overlap_end = cursor + @min(units - 1, end - cursor);
        if (s.pool.findRunIn(free, cursor, end, units) orelse s.pool.findRunIn(free, 0, overlap_end, units)) |first| {
            cursors.large = (first + units) % end;
            return first;
        }
        if (units == 1 or split == total) return null;
        return s.pool.findRunIn(free, split, total, units);
    }

    fn reserveLocked(s: *SharedPages, len: usize) ?Reservation {
        if (len == 0 or len > s.page_bytes) return null;
        const units = std.math.divCeil(usize, storedBytes(len), s.unit_bytes) catch unreachable;
        var cursors: Cursors = .{ .large = s.pool.cursor, .small = s.pool.small_cursor };
        const first = s.place(&s.pool.free_units, &cursors, units, s.pool.small_units) orelse return null;
        s.pool.cursor = cursors.large;
        s.pool.small_cursor = cursors.small;
        s.pool.free_units.setRangeValue(.{ .start = first, .end = first + units }, false);
        s.pool.active_units += units;
        s.pool.peak_units = @max(s.pool.peak_units, s.pool.active_units);
        s.pool.largest_reservation = @max(s.pool.largest_reservation, len);
        std.debug.assert(s.pool.active_units <= s.pool.pages.len);

        for (s.pages[first..][0..units]) |*part| {
            const old = part.status.load(.monotonic);
            std.debug.assert(old & 255 == @backingInt(State.free));
            part.status.store(status(.reserved, (old >> 8) + 1), .release);
            part.owner = s.owner;
        }

        const first_page = &s.pages[first];
        first_page.units = units;
        first_page.small = units == 1;
        s.pool.small_units += @intFromBool(units == 1);
        first_page.len = 0;
        first_page.recipient_count = 0;
        return .{
            .page = @intCast(first),
            .generation = first_page.status.load(.monotonic) >> 8,
            .bytes = s.pagePayload(@intCast(first))[0..len],
        };
    }

    pub fn publish(s: *SharedPages, r: Reservation, to: []const networking.Handle) bool {
        s.producer.lockUncancelable(s.producer_io);
        defer s.producer.unlock(s.producer_io);
        return s.publishLocked(r, to, .{}, null, &.{}, null);
    }

    pub const Publication = struct { reservation: Reservation, recipients: []const networking.Handle = &.{}, group: Group = .{}, audience: ?Audience = null, mask: []const usize = &.{}, excluded: ?usize = null };

    pub fn publishMany(s: *SharedPages, publications: []const Publication) void {
        s.producer.lockUncancelable(s.producer_io);
        defer s.producer.unlock(s.producer_io);
        for (publications) |publication| {
            const published = s.publishLocked(publication.reservation, publication.recipients, publication.group, publication.audience, publication.mask, publication.excluded);
            std.debug.assert(published);
        }
    }

    fn publishLocked(s: *SharedPages, r: Reservation, to: []const networking.Handle, group: Group, selected: ?Audience, mask: []const usize, excluded: ?usize) bool {
        if (r.page >= s.pages.len or (selected == null and to.len == 0) or to.len > s.recipients_per_page) return false;

        const p = &s.pages[r.page];
        if (p.owner != s.owner or p.status.load(.acquire) != status(.reserved, r.generation) or r.bytes.ptr != s.pagePayload(r.page).ptr or r.bytes.len == 0 or r.bytes.len > @min(s.page_bytes, p.units * s.unit_bytes - headroom))
            return false;

        // Where its recipients go in the ring, checked before anything changes. Credit bounds
        // what waits to be taken, so the ring always has room.
        var recipient_start = s.recipient_tail;
        if (selected == null) {
            const capacity = s.recipient_ring.len;
            if (recipient_start % capacity + to.len > capacity) recipient_start += capacity - recipient_start % capacity;
            if (recipient_start + to.len - s.recipient_head.load(.acquire) > capacity) return false;
        }
        const units = std.math.divCeil(usize, storedBytes(r.bytes.len), s.unit_bytes) catch unreachable;
        s.freeRange(@as(usize, r.page) + units, p.units - units);
        // Pack following reservations into the tail released by framing.
        if (units < p.units) s.pool.cursor = @as(usize, r.page) + units;
        p.units = units;
        var recipient_count = to.len;
        p.audience = selected;
        if (selected) |audience| {
            std.debug.assert(audience.pool == s.pool);
            const slot = &s.pool.audiences[audience.index];
            std.debug.assert(slot.generation == audience.generation);
            const references = slot.references.fetchAdd(1, .monotonic);
            std.debug.assert(references > 0);
            const words = std.math.divCeil(usize, s.recipients_per_page, @bitSizeOf(usize)) catch unreachable;
            const used = std.math.divCeil(usize, slot.length, @bitSizeOf(usize)) catch unreachable;
            std.debug.assert(slot.length > 0 and mask.len == used);
            const destination = s.pool.recipient_masks[@as(usize, r.page) * words ..][0..used];
            @memcpy(destination, mask);
            if (excluded) |index| {
                std.debug.assert(index < slot.length);
                destination[index / @bitSizeOf(usize)] &= ~(@as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(index % @bitSizeOf(usize))));
            }
            recipient_count = 0;
            for (destination, 0..) |bits, word| {
                const start = word * @bitSizeOf(usize);
                const valid = @min(@bitSizeOf(usize), slot.length -| start);
                if (valid < @bitSizeOf(usize)) std.debug.assert(bits >> @as(std.math.Log2Int(usize), @intCast(valid)) == 0);
                recipient_count += @popCount(bits);
            }
            std.debug.assert(recipient_count > 0 and recipient_count <= slot.length);
        } else {
            const capacity = s.recipient_ring.len;
            @memcpy(s.recipient_ring[recipient_start % capacity ..][0..to.len], to);
            s.recipient_tail = recipient_start + to.len;
            p.recipient_start = recipient_start % capacity;
        }
        p.recipient_end = s.recipient_tail;
        std.debug.assert(group.count > 0 and group.index < group.count);
        std.debug.assert(group.count == 1 or (group.protocol != null and group.bytes > 0));
        p.group = group;
        p.len = r.bytes.len;
        p.decoded_length = r.decoded_length;
        s.pool.payload_bytes += p.len;
        s.pool.peak_payload_bytes = @max(s.pool.peak_payload_bytes, s.pool.payload_bytes);
        p.recipient_count = recipient_count;
        p.status.store(status(.published, r.generation), .release);
        const queued = s.ready.push(r.page);
        std.debug.assert(queued);
        return true;
    }

    pub fn cancel(s: *SharedPages, r: Reservation) void {
        s.cancelMany(&.{r});
    }

    pub fn cancelMany(s: *SharedPages, reservations: []const Reservation) void {
        s.producer.lockUncancelable(s.producer_io);
        defer s.producer.unlock(s.producer_io);
        for (reservations) |r| s.cancelLocked(r);
    }

    fn cancelLocked(s: *SharedPages, r: Reservation) void {
        if (r.page >= s.pages.len or s.pages[r.page].owner != s.owner or s.pages[r.page].status.load(.acquire) != status(.reserved, r.generation)) return;
        if (r.bytes.ptr != s.pagePayload(r.page).ptr or r.bytes.len > s.page_bytes) return;
        s.endSmall(r.page);
        s.freeRange(r.page, s.pages[r.page].units);
    }

    pub fn takeReady(s: *SharedPages) ?RawPacket {
        const id = s.ready.pop() orelse return null;
        const p = &s.pages[id];
        std.debug.assert(p.owner == s.owner);
        const generation = p.status.load(.acquire) >> 8;
        const previous = p.status.cmpxchgStrong(status(.published, generation), status(.taken, generation), .acq_rel, .acquire);
        std.debug.assert(previous == null);
        var result: RawPacket = .{ .page = id, .units = p.units, .generation = generation, .bytes = s.pagePayload(id)[0..p.len], .decoded_length = p.decoded_length, .recipients = Recipients.all(s.recipient_ring[p.recipient_start..][0..p.recipient_count]), .recipient_end = p.recipient_end, .group = p.group };
        if (p.audience) |audience| {
            const slot = &s.pool.audiences[audience.index];
            std.debug.assert(slot.generation == audience.generation);
            const handles = s.pool.audience_handles[audience.index * s.recipients_per_page ..][0..slot.length];
            const words = std.math.divCeil(usize, s.recipients_per_page, @bitSizeOf(usize)) catch unreachable;
            const used = std.math.divCeil(usize, slot.length, @bitSizeOf(usize)) catch unreachable;
            const mask = s.pool.recipient_masks[@as(usize, id) * words ..][0..used];
            result.selection = .{ .pool = s.pool, .audience = audience.index, .generation = audience.generation, .mask = mask };
            result.recipients = .{ .handles = handles, .mask = mask, .len = p.recipient_count };
        }
        std.debug.assert(p.len > 0 and p.len <= s.page_bytes);
        std.debug.assert(p.recipient_count > 0 and p.recipient_count <= s.recipients_per_page);
        return result;
    }

    /// Lets the ring reuse the recipients of a packet the worker took and everything before
    /// it, as packets are taken in the order they were published. A packet released again,
    /// as it is when it goes back to the pool, or late, after one taken since, moves nothing.
    /// Only the thread that takes packets calls this.
    pub fn releaseRecipients(s: *SharedPages, packet: RawPacket) void {
        if (packet.recipient_end > s.recipient_head.load(.monotonic)) s.recipient_head.store(packet.recipient_end, .release);
    }

    pub fn releaseReady(s: *SharedPages, id: PageId, generation: u64) bool {
        s.producer.lockUncancelable(s.producer_io);
        defer s.producer.unlock(s.producer_io);
        return s.releaseLocked(id, generation);
    }

    pub fn releaseMany(s: *SharedPages, packets: []const RawPacket) void {
        s.producer.lockUncancelable(s.producer_io);
        defer s.producer.unlock(s.producer_io);
        for (packets) |packet| {
            const released = s.releaseLocked(packet.page, packet.generation);
            std.debug.assert(released);
        }
    }

    fn releaseLocked(s: *SharedPages, id: PageId, generation: u64) bool {
        if (id >= s.pages.len or generation > std.math.maxInt(u56)) return false;
        if (s.pages[id].owner != s.owner or s.pages[id].status.load(.acquire) != status(.taken, generation)) return false;
        std.debug.assert(s.pages[id].len <= s.pool.payload_bytes);
        s.pool.payload_bytes -= s.pages[id].len;
        if (s.pages[id].audience) |audience| {
            const slot = &s.pool.audiences[audience.index];
            std.debug.assert(slot.generation == audience.generation);
            const previous = slot.references.fetchSub(1, .acq_rel);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                std.debug.assert(!s.pool.free_audiences.isSet(audience.index));
                s.pool.free_audiences.set(audience.index);
            }
            s.pages[id].audience = null;
        }
        // Its recipients were released when it was taken, unless it went back unread.
        if (s.pages[id].recipient_end > s.recipient_head.load(.monotonic)) s.recipient_head.store(s.pages[id].recipient_end, .release);
        s.endSmall(id);
        s.freeRange(id, s.pages[id].units);
        return true;
    }

    fn endSmall(s: *SharedPages, id: usize) void {
        if (!s.pages[id].small) return;
        std.debug.assert(s.pool.small_units > 0);
        s.pool.small_units -= 1;
        s.pages[id].small = false;
    }

    fn freeRange(s: *SharedPages, first: usize, units: usize) void {
        std.debug.assert(units <= s.pool.active_units);
        s.pool.active_units -= units;
        for (s.pages[first..][0..units]) |*p| {
            const old = p.status.load(.monotonic);
            std.debug.assert(old & 255 == @backingInt(State.reserved) or old & 255 == @backingInt(State.taken));
            p.status.store(status(.free, old >> 8), .release);
        }
        s.pool.free_units.setRangeValue(.{ .start = first, .end = first + units }, true);
        if (s.pool.active_units == 0) {
            s.pool.cursor = 0;
            s.pool.small_cursor = 0;
        }
    }

    pub fn framingHeadroom(s: *SharedPages, id: PageId) []u8 {
        return s.pageStorage(id)[0..headroom];
    }

    /// All a taken packet's storage: the headroom, the packet, and the room after it to grow into.
    pub fn packetStorage(s: *SharedPages, packet: RawPacket) []u8 {
        std.debug.assert(s.pages[packet.page].status.load(.acquire) == status(.taken, packet.generation));
        return s.pageStorage(packet.page);
    }

    pub fn framingStorage(s: *SharedPages, packet: RawPacket) []u8 {
        std.debug.assert(s.pages[packet.page].status.load(.acquire) == status(.taken, packet.generation));
        return s.pageStorage(packet.page)[0 .. headroom + packet.bytes.len];
    }

    fn pagePayload(s: *SharedPages, id: PageId) []u8 {
        return s.pageStorage(id)[headroom..];
    }

    fn pageStorage(s: *SharedPages, id: PageId) []u8 {
        std.debug.assert(s.pages[id].units != 0);
        return s.bytes[@as(usize, id) * s.unit_bytes ..][0 .. s.pages[id].units * s.unit_bytes];
    }
};

test "draining packet extents restores the configured maximum packet capacity" {
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 8, .page_bytes = 32768, .recipients_per_page = 1 });
    defer pool.deinit();
    for ([_]usize{ 1, 16384, 16385, 32768 }) |length| {
        const transient = pool.reserve(length).?;
        pool.cancel(transient);
        try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
        var reservations: [8]Reservation = undefined;
        const count = pool.reserveMany(32768, &reservations);
        defer pool.cancelMany(reservations[0..count]);
        try std.testing.expectEqual(reservations.len, count);
        try std.testing.expectEqual(null, pool.reserve(1));
    }
}

test "a trial of reservations answers what the pool would take without taking it" {
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 4, .page_bytes = 131072, .recipients_per_page = 1 });
    defer pool.deinit();
    const total = pool.pool.pages.len;
    const page_units = total / 4;
    try std.testing.expect(page_units > 2);
    // Small packets take one unit each and a full page takes several.
    const ones: [64]usize = @splat(1);
    const pages: [8]usize = @splat(131072);
    try std.testing.expectEqual(total, pool.fit(ones[0..total]));
    try std.testing.expectEqual(total, pool.fit(ones[0 .. total + 1]));
    try std.testing.expectEqual(@as(usize, 4), pool.fit(&pages));
    // A length the pool can never hold ends the trial where it stands.
    try std.testing.expectEqual(@as(usize, 1), pool.fit(&.{ 1, 131073, 1 }));
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);

    // One unit held in the middle of each page leaves most units free and no run long
    // enough for a page. Counting free units would promise room that is not there.
    var held: [4]Reservation = undefined;
    var filler: [64]Reservation = undefined;
    var filled: usize = 0;
    for (&held) |*middle| {
        for (0..page_units / 2) |_| {
            filler[filled] = pool.reserve(1).?;
            filled += 1;
        }
        middle.* = pool.reserve(1).?;
        for (0..page_units - page_units / 2 - 1) |_| {
            filler[filled] = pool.reserve(1).?;
            filled += 1;
        }
    }
    pool.cancelMany(filler[0..filled]);
    try std.testing.expectEqual(total - 4, total - pool.pool.active_units);
    try std.testing.expectEqual(@as(usize, 0), pool.fit(&pages));
    try std.testing.expectEqual(null, pool.reserve(131072));
    // The trial takes what the reservations themselves then take, no more and no fewer.
    const mixed = [_]usize{ 1, 1, 30000, 1, 60000, 1, 1, 90000, 1, 1, 1, 120000, 1, 1 };
    const promised = pool.fit(&mixed);
    var reservations: [mixed.len]Reservation = undefined;
    const taken = pool.reserveBatch(&mixed, &reservations);
    try std.testing.expectEqual(promised, taken);
    try std.testing.expect(taken != 0 and taken != mixed.len);
    pool.cancelMany(reservations[0..taken]);
    pool.cancelMany(&held);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
    try std.testing.expectEqual(@as(usize, 4), pool.fit(&pages));
}

test "packet extents shrink without reusing outstanding consumer bytes" {
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 2, .page_bytes = 192 * 1024, .recipients_per_page = 1 });
    defer pool.deinit();
    var packets: [3]RawPacket = undefined;
    const lengths = [_]usize{ 70 * 1024, 1, 192 * 1024 };

    for (lengths, 0..) |length, i| {
        var reservation = pool.reserve(192 * 1024) orelse return error.TestUnexpectedResult;
        @memset(reservation.bytes, @intCast(i + 1));
        reservation.bytes = reservation.bytes[0..length];
        try std.testing.expect(pool.publish(reservation, &.{.{ .index = 0, .generation = 1 }}));
        packets[i] = pool.takeReady() orelse return error.TestUnexpectedResult;
    }

    try std.testing.expect(pool.reserve(192 * 1024) == null);
    try std.testing.expectEqual(@as(usize, 262 * 1024 + 1), pool.pool.peak_payload_bytes);

    for (packets, 0..) |packet, i| {
        try std.testing.expectEqual(lengths[i], packet.bytes.len);

        for (packet.bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(i + 1)), byte);
    }

    for ([_]usize{ 1, 0, 2 }) |i| try std.testing.expect(pool.releaseReady(packets[i].page, packets[i].generation));
    try std.testing.expectEqual(@as(usize, 0), pool.pool.payload_bytes);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
    const replacement = pool.reserve(192 * 1024) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pool.releaseReady(packets[0].page, packets[0].generation));
    pool.cancel(replacement);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
}

test "small packets retain burst capacity after maximum sized reservations shrink" {
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 2, .page_bytes = 192 * 1024, .recipients_per_page = 1 });
    defer pool.deinit();
    var packets: [8]RawPacket = undefined;
    for (&packets, 0..) |*packet, index| {
        var reservation = pool.reserve(192 * 1024) orelse return error.TestUnexpectedResult;
        reservation.bytes = reservation.bytes[0..32];
        @memset(reservation.bytes, @intCast(index));
        try std.testing.expect(pool.publish(reservation, &.{.{ .index = 0, .generation = 1 }}));
        packet.* = pool.takeReady().?;
        try std.testing.expectEqual(reservation.bytes.ptr, packet.bytes.ptr);
    }
    for (packets, 0..) |packet, index| {
        try std.testing.expect(std.mem.allEqual(u8, packet.bytes, @intCast(index)));
        try std.testing.expect(pool.releaseReady(packet.page, packet.generation));
    }
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
}

test "endpoints share output capacity without sharing ownership or delayed reclamation" {
    var backing = try Pool.init(std.testing.allocator, .{ .pages = 1, .page_bytes = 64 * 1024, .recipients_per_page = 2 });
    defer backing.deinit();
    var alice = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 1, .page_bytes = 64 * 1024, .recipients_per_page = 1, .pool = &backing });
    defer alice.deinit();
    var bob = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 1, .page_bytes = 64 * 1024, .recipients_per_page = 1, .pool = &backing });
    defer bob.deinit();
    const first = alice.reserve(64 * 1024) orelse return error.TestUnexpectedResult;
    @memset(first.bytes, 1);
    try std.testing.expect(!bob.publish(first, &.{.{ .index = 0, .generation = 1 }}));
    try std.testing.expect(alice.publish(first, &.{.{ .index = 0, .generation = 1 }}));
    const previous = alice.takeReady() orelse return error.TestUnexpectedResult;
    try std.testing.expect(bob.reserve(1) == null);
    try std.testing.expect(alice.releaseReady(previous.page, previous.generation));
    const second = bob.reserve(64 * 1024) orelse return error.TestUnexpectedResult;
    @memset(second.bytes, 2);
    try std.testing.expect(bob.publish(second, &.{.{ .index = 0, .generation = 1 }}));
    const current = bob.takeReady() orelse return error.TestUnexpectedResult;
    try std.testing.expect(!alice.releaseReady(current.page, current.generation));
    try std.testing.expect(!alice.releaseReady(previous.page, previous.generation));
    for (current.bytes) |byte| try std.testing.expectEqual(@as(u8, 2), byte);
    try std.testing.expect(bob.releaseReady(current.page, current.generation));
    const replacement = alice.reserve(64 * 1024) orelse return error.TestUnexpectedResult;
    alice.cancel(replacement);
}

test "rotating extent search matches exhaustive contiguous fits including cursor crossings" {
    var pool = try Pool.init(std.testing.allocator, .{ .pages = 10, .page_bytes = 1, .recipients_per_page = 1 });
    defer pool.deinit();
    for (0..1024) |mask| {
        for (0..10) |bit| pool.free_units.setValue(bit, mask & (@as(usize, 1) << @intCast(bit)) != 0);
        for (0..10) |cursor| {
            for (1..11) |units| {
                var expected: ?usize = null;
                for (0..10) |offset| {
                    const first = (cursor + offset) % 10;
                    if (units > 10 - first) continue;
                    const fits = for (first..first + units) |bit| {
                        if (!pool.free_units.isSet(bit)) break false;
                    } else true;
                    if (fits) {
                        expected = first;
                        break;
                    }
                }
                const overlap_end = cursor + @min(units - 1, 10 - cursor);
                const actual = pool.findRun(cursor, 10, units) orelse pool.findRun(0, overlap_end, units);
                try std.testing.expectEqual(expected, actual);
            }
        }
    }
}

test "masked packets retain audience loans without materializing recipients" {
    for ([_]usize{ 32, 128, 256 }) |players| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var output = try SharedPages.init(allocator, std.testing.io, .{ .pages = 2 * players, .page_bytes = 64, .recipients_per_page = players });
        defer output.deinit();
        const handles = try allocator.alloc(networking.Handle, players);
        for (handles, 0..) |*handle, index| handle.* = .{ .index = index, .generation = 1 };
        var writer = output.pool.reserveAudience(std.testing.io, handles.len).?;
        @memcpy(writer.handles, handles);
        const audience = writer.finish();
        const retained = output.pool.audience_handles[audience.index * output.recipients_per_page ..].ptr;
        @memset(output.recipient_ring, .{ .index = std.math.maxInt(usize), .generation = 0 });
        const words = try allocator.alloc(usize, (players + 63) / 64);
        @memset(words, std.math.maxInt(usize));
        if (players % 64 != 0) words[words.len - 1] = (@as(usize, 1) << @intCast(players % 64)) - 1;
        for (0..2 * players) |packet| {
            var reservation = output.reserve(1).?;
            reservation.bytes[0] = 7;
            output.publishMany(&.{.{ .reservation = reservation, .audience = audience, .mask = words, .excluded = packet % players }});
        }
        audience.release(std.testing.io);
        var consumed: usize = 0;
        while (output.takeReady()) |packet| {
            try std.testing.expect(packet.selection != null);
            try std.testing.expectEqual(players - 1, packet.recipients.len);
            try std.testing.expect(packet.recipients.handles.ptr == retained);
            try std.testing.expect(!output.pool.free_audiences.isSet(audience.index));
            var recipients = packet.recipients.iterator();
            while (recipients.next()) |handle| {
                try std.testing.expect(handle.index != consumed % players);
                try std.testing.expectEqual(@as(u32, 1), handle.generation);
            }
            consumed += 1;
            try std.testing.expect(output.releaseReady(packet.page, packet.generation));
        }
        try std.testing.expectEqual(players * 2, consumed);
        try std.testing.expect(output.pool.free_audiences.isSet(audience.index));
        for (output.recipient_ring) |handle| try std.testing.expectEqual(@as(u32, 0), handle.generation);
    }
}

test "audience reservations cancel and freeze without retaining writable views" {
    var output = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 1, .page_bytes = 64, .recipients_per_page = 2 });
    defer output.deinit();
    var writer = output.pool.reserveAudience(std.testing.io, 2).?;
    writer.cancel(std.testing.io);
    try std.testing.expectEqual(output.pool.audiences.len, output.pool.free_audiences.count());
    writer = output.pool.reserveAudience(std.testing.io, 1).?;
    writer.handles[0] = .{ .index = 100, .generation = 7 };
    const audience = writer.finish();
    try std.testing.expect(!writer.active and writer.handles.len == 0);
    writer.cancel(std.testing.io);
    try std.testing.expectEqual(output.pool.audiences.len - 1, output.pool.free_audiences.count());
    try std.testing.expectEqual(@as(usize, 1), output.pool.audiences[audience.index].length);
    audience.release(std.testing.io);
    try std.testing.expectEqual(output.pool.audiences.len, output.pool.free_audiences.count());
}

test "a flood of small packets leaves room for a full page" {
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 8, .page_bytes = 128 * 1024, .recipients_per_page = 1 });
    defer pool.deinit();
    const total = pool.pool.pages.len;
    try std.testing.expect(total >= 64 and pool.smallStart() < total);
    var small: [256]Reservation = undefined;
    var count: usize = 0;
    while (count < small.len) : (count += 1) small[count] = pool.reserve(1) orelse break;
    // Small packets stopped where a full page still fits.
    try std.testing.expectEqual(pool.smallCap(), count);
    // A full page still finds its run of units.
    const page = pool.reserve(128 * 1024).?;
    try std.testing.expectEqual(@as(usize, 0), pool.fit(&.{1}));
    pool.cancel(page);
    pool.cancelMany(small[0..count]);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
    // Without the flood, the whole pool takes full pages.
    var pages: [16]Reservation = undefined;
    var full: usize = 0;
    while (full < pages.len) : (full += 1) pages[full] = pool.reserve(128 * 1024) orelse break;
    try std.testing.expectEqual(@as(usize, 8), full);
    pool.cancelMany(pages[0..full]);
}

test "small packets take a page freed among full ones and the split keeps whole pages" {
    // An odd number of pages: each region holds whole pages and none is lost.
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 9, .page_bytes = 128 * 1024, .recipients_per_page = 1 });
    defer pool.deinit();
    const per_page = pool.pool.pages.len / 9;
    try std.testing.expectEqual(@as(usize, 0), pool.smallStart() % per_page);
    var pages: [9]Reservation = undefined;
    for (&pages) |*page| page.* = pool.reserve(128 * 1024).?;
    try std.testing.expectEqual(@as(?Reservation, null), pool.reserve(1));
    // A freed page in the lower region takes small packets once the upper one is full.
    pool.cancel(pages[0]);
    try std.testing.expectEqual(@as(usize, 1), pool.fit(&.{1}));
    const small = pool.reserve(1).?;
    try std.testing.expect(small.page < pool.smallStart());
    // It came from the top of what was freed, so the rest of that run stays whole.
    try std.testing.expectEqual(pages[0].page + per_page - 1, small.page);
    pool.cancel(small);
    for (pages[1..]) |page| pool.cancel(page);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.small_units);
}
