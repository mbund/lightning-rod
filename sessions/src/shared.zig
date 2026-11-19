const std = @import("std");
const networking = @import("networking");
pub const headroom = 6;

/// The bytes a packet of `length` takes in the pool: itself, the headroom before it its frame
/// header goes in, and room to compress into, which incompressible bytes outgrow by a few bytes
/// a block. A packet compresses in place of itself, as it waits there for every recipient.
pub fn storedBytes(length: usize) usize {
    return length + headroom + 16 + 5 * (length / 5000 + 1);
}

/// Names a packet in the pool from reservation until release.
pub const SlotId = u16;

pub const Configuration = struct {
    /// Packets of the largest size the pool holds, which sizes it when `arena_bytes` does not.
    pages: usize,
    page_bytes: usize,
    /// Storage goes out in units of this many bytes, so a packet takes about what it holds.
    unit_bytes: usize = 128,
    /// The pool's storage. Without it, room for `pages` packets of the largest size.
    arena_bytes: usize = 0,
    /// Packets held at once, from reservation until release. Without a count, one for every
    /// unit, up to 64 for each page and what a slot id names.
    slots: usize = 0,
    recipients_per_page: usize,
    /// Recipients the publications of this source hold between them until the worker takes
    /// them. Each recipient of each packet charges at least the bound of the smallest frame,
    /// so credit bounds them: see `Service`.
    recipient_handles: usize = 0,
    /// Audiences held at once, by broadcasts and the packets selecting from them until the
    /// worker takes them. A broadcast that finds none free is backpressured. Without a count,
    /// one for every slot.
    audiences: usize = 0,
    pool: ?*Pool = null,
    /// Prepared packets of this source go out decoded below it, or always without one, so they
    /// keep room to be decoded into.
    compression_threshold: ?usize = null,
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
    page: SlotId,
    generation: u64,
    bytes: []u8,
};

pub const Group = struct {
    protocol: ?i32 = null,
    generation: u64 = 0,
    bytes: u32 = 0,
    first: SlotId = 0,
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

    page: SlotId,
    units: usize,
    generation: u64,
    bytes: []const u8,
    recipients: Recipients,
    /// Where its source's ring of recipients ends after this packet's, which the worker
    /// releases once it took the packet.
    recipient_end: usize = 0,
    group: Group = .{},
    // Mask storage belongs to this packet's slot until it is recycled.
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
        self.pool.audiences_in_use -= 1;
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

/// Output storage every endpoint shares: an arena handed out in small units, so a packet takes
/// about what it holds, and a slot for each packet held, which names it from reservation until
/// it is released.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    unit_bytes: usize,
    /// Units the largest packet takes, with its headroom and room to compress.
    packet_units: usize,
    recipients_per_page: usize,
    bytes: []align(64) u8,
    slots: []SharedPages.Slot,
    /// Slots holding no packet, taken from the end.
    free_slots: []SlotId,
    free_slot_count: usize,
    free_units: std.DynamicBitSetUnmanaged,
    /// A copy of the free units on which `fit` tries reservations without making them.
    trial_units: std.DynamicBitSetUnmanaged,
    audiences: []AudienceSlot,
    audience_handles: []networking.Handle,
    recipient_masks: []usize,
    free_audiences: std.DynamicBitSetUnmanaged,
    next_owner: u32 = 0,
    cursor: usize = 0,
    /// Where the next small reservation is looked for in the small region.
    small_cursor: usize = 0,
    /// Units small reservations hold.
    small_units: usize = 0,
    active_units: usize = 0,
    peak_units: usize = 0,
    /// Units small reservations held when the most units were.
    small_at_peak: usize = 0,
    peak_slots: usize = 0,
    largest_reservation: usize = 0,
    payload_bytes: usize = 0,
    peak_payload_bytes: usize = 0,
    /// Audiences held at once, by producers and the packets selecting from them.
    audiences_in_use: usize = 0,
    peak_audiences: usize = 0,

    const AudienceSlot = struct {
        references: std.atomic.Value(usize) = .init(0),
        generation: u64 = 0,
        length: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !Pool {
        if (config.pages == 0 or config.page_bytes == 0 or config.unit_bytes == 0 or config.recipients_per_page == 0) return error.InvalidConfiguration;
        const unit_bytes = config.unit_bytes;
        const packet_units = try std.math.divCeil(usize, storedBytes(config.page_bytes), unit_bytes);
        const arena_bytes = if (config.arena_bytes != 0) config.arena_bytes else try std.math.mul(usize, config.pages, packet_units * unit_bytes);
        const unit_count = try std.math.divCeil(usize, arena_bytes, unit_bytes);
        if (unit_count < packet_units or unit_count > std.math.maxInt(u32)) return error.InvalidConfiguration;
        const slot_count = if (config.slots != 0) config.slots else @min(unit_count, try std.math.mul(usize, config.pages, 64), std.math.maxInt(SlotId));
        if (slot_count == 0 or slot_count > std.math.maxInt(SlotId)) return error.InvalidConfiguration;
        const bytes = try allocator.alignedAlloc(u8, .@"64", try std.math.mul(usize, unit_count, unit_bytes));
        errdefer allocator.free(bytes);
        const slots = try allocator.alloc(SharedPages.Slot, slot_count);
        errdefer allocator.free(slots);
        const free_slots = try allocator.alloc(SlotId, slot_count);
        errdefer allocator.free(free_slots);
        // Taken from the end, so the first slots go first.
        for (free_slots, 0..) |*slot, index| slot.* = @intCast(slot_count - 1 - index);
        const audience_count = if (config.audiences != 0) config.audiences else slot_count;
        const audiences = try allocator.alloc(AudienceSlot, audience_count);
        errdefer allocator.free(audiences);
        const audience_handles = try allocator.alloc(networking.Handle, try std.math.mul(usize, audience_count, config.recipients_per_page));
        errdefer allocator.free(audience_handles);
        const words = try std.math.divCeil(usize, config.recipients_per_page, @bitSizeOf(usize));
        const recipient_masks = try allocator.alloc(usize, try std.math.mul(usize, slot_count, words));
        errdefer allocator.free(recipient_masks);
        var free_audiences = try std.DynamicBitSetUnmanaged.initFull(allocator, audience_count);
        errdefer free_audiences.deinit(allocator);
        var free_units = try std.DynamicBitSetUnmanaged.initFull(allocator, unit_count);
        errdefer free_units.deinit(allocator);
        const trial_units = try std.DynamicBitSetUnmanaged.initFull(allocator, unit_count);
        for (audiences) |*slot| slot.* = .{};
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .unit_bytes = unit_bytes, .packet_units = packet_units, .recipients_per_page = config.recipients_per_page, .bytes = bytes, .slots = slots, .free_slots = free_slots, .free_slot_count = slot_count, .free_units = free_units, .trial_units = trial_units, .audiences = audiences, .audience_handles = audience_handles, .recipient_masks = recipient_masks, .free_audiences = free_audiences };
    }

    /// Units of storage in the arena.
    pub fn units(self: *const Pool) usize {
        return self.free_units.bit_length;
    }

    fn findRun(self: *const Pool, start: usize, end: usize, count: usize) ?usize {
        return self.findRunIn(&self.free_units, start, end, count);
    }

    /// The highest free unit in `[start, end)`.
    fn lastFreeIn(self: *const Pool, free_units: *const std.DynamicBitSetUnmanaged, start: usize, end: usize) ?usize {
        std.debug.assert(start <= end and end <= self.units());
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

    /// The highest run of `count` free units in `[start, end)`, by its first unit.
    fn lastRunIn(self: *const Pool, free_units: *const std.DynamicBitSetUnmanaged, start: usize, end: usize, count: usize) ?usize {
        std.debug.assert(count > 0);
        var at = end;
        var run: usize = 0;
        while (self.lastFreeIn(free_units, start, at)) |unit| {
            run = if (unit + 1 == at) run + 1 else 1;
            if (run == count) return unit;
            at = unit;
        }
        return null;
    }

    fn findRunIn(self: *const Pool, free_units: *const std.DynamicBitSetUnmanaged, start: usize, end: usize, count: usize) ?usize {
        std.debug.assert(start <= end and end <= self.units() and count > 0);
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
            if (free >= count) {
                std.debug.assert(first >= start and first + count <= end);
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
        self.audiences_in_use += 1;
        self.peak_audiences = @max(self.peak_audiences, self.audiences_in_use);
        return .{ .audience = .{ .pool = self, .index = index, .generation = slot.generation }, .handles = self.audience_handles[index * self.recipients_per_page ..][0..length] };
    }

    pub fn deinit(self: *Pool) void {
        std.debug.assert(self.active_units == 0 and self.payload_bytes == 0 and self.free_slot_count == self.slots.len);
        for (self.slots) |*slot| std.debug.assert(slot.status.load(.acquire) & 255 == @backingInt(SharedPages.State.free));
        for (self.audiences) |*slot| std.debug.assert(slot.references.load(.acquire) == 0);
        self.free_audiences.deinit(self.allocator);
        self.allocator.free(self.recipient_masks);
        self.allocator.free(self.audience_handles);
        self.allocator.free(self.audiences);
        self.free_units.deinit(self.allocator);
        self.trial_units.deinit(self.allocator);
        self.allocator.free(self.free_slots);
        self.allocator.free(self.slots);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Pool) usize {
        const masks = std.math.divCeil(usize, self.units(), @bitSizeOf(usize)) catch unreachable;
        return @sizeOf(Pool) + self.bytes.len + self.slots.len * (@sizeOf(SharedPages.Slot) + @sizeOf(SlotId)) + self.audience_handles.len * @sizeOf(networking.Handle) +
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
    slots: []Slot,
    compression_threshold: ?usize,
    /// The recipients of every publication not yet taken, in publication order, which the
    /// worker takes them in, so they are released from the front as they are appended at the
    /// back. A list never wraps: one that would starts at the beginning, past the end left
    /// unused. `recipient_tail` moves under the producer lock, `recipient_head` on the worker.
    recipient_ring: []networking.Handle,
    recipient_tail: usize = 0,
    recipient_head: std.atomic.Value(usize) = .init(0),
    /// The most of the ring publications held at once.
    peak_recipients: usize = 0,
    ready: Ring,

    const State = enum(u8) { free, reserved, published, taken };

    /// A packet from reservation until release: where its bytes are, and what goes with them.
    const Slot = struct {
        status: std.atomic.Value(u64) = .init(0),
        first: u32 = 0,
        units: u32 = 0,
        len: usize = 0,
        decoded_length: usize = 0,
        recipient_count: usize = 0,
        /// Where its recipients start in the ring, and where the ring ends after them.
        recipient_start: usize = 0,
        recipient_end: usize = 0,
        owner: u32 = 0,
        group: Group = .{},
        audience: ?Audience = null,
        /// Small when reserved, so its units count toward the cap on those.
        small: bool = false,
    };

    fn status(state: State, generation: u64) u64 {
        std.debug.assert(generation <= std.math.maxInt(u56));
        return (generation << 8) | @backingInt(state);
    }

    const Ring = struct {
        slots: []SlotId,
        head: std.atomic.Value(usize) = .init(0),
        tail: std.atomic.Value(usize) = .init(0),

        fn push(r: *Ring, value: SlotId) bool {
            const tail = r.tail.load(.monotonic);
            if (tail -% r.head.load(.acquire) == r.slots.len) return false;
            r.slots[tail % r.slots.len] = value;
            r.tail.store(tail +% 1, .release);
            return true;
        }

        fn pop(r: *Ring) ?SlotId {
            const head = r.head.load(.monotonic);
            if (head == r.tail.load(.acquire)) return null;

            const value = r.slots[head % r.slots.len];
            r.head.store(head +% 1, .release);
            return value;
        }
    };

    pub fn init(a: std.mem.Allocator, io: std.Io, c: Configuration) !SharedPages {
        if (c.pages == 0 or c.page_bytes == 0 or c.recipients_per_page == 0) return error.InvalidConfiguration;

        const pool = c.pool orelse try a.create(Pool);
        if (c.pool == null) {
            errdefer a.destroy(pool);
            pool.* = try Pool.init(a, c);
        }
        errdefer if (c.pool == null) {
            pool.deinit();
            a.destroy(pool);
        };
        if (storedBytes(c.page_bytes) > pool.bytes.len or c.recipients_per_page > pool.recipients_per_page) return error.InvalidConfiguration;
        pool.next_owner += 1;
        const ring_capacity = try std.math.ceilPowerOfTwo(usize, pool.slots.len);
        const ready = try a.alloc(SlotId, ring_capacity);
        errdefer a.free(ready);
        // What credit bounds, and one more list for the end of the ring a list skips. Without
        // a bound, every slot holding a packet with every recipient.
        const handles = if (c.recipient_handles != 0) try std.math.add(usize, c.recipient_handles, c.recipients_per_page) else try std.math.mul(usize, pool.slots.len, c.recipients_per_page);
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
            .compression_threshold = c.compression_threshold,
            .recipients_per_page = pool.recipients_per_page,
            .bytes = pool.bytes,
            .slots = pool.slots,
            .recipient_ring = recipient_ring,
            .ready = .{ .slots = ready },
        };
    }

    pub fn deinit(s: *SharedPages) void {
        s.producer.lockUncancelable(s.producer_io);
        for (s.slots) |*slot| if (slot.owner == s.owner) std.debug.assert(slot.status.load(.acquire) & 255 == @backingInt(State.free));
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
        return @sizeOf(SharedPages) + s.ready.slots.len * @sizeOf(SlotId) + s.recipient_ring.len * @sizeOf(networking.Handle) + if (s.owns_pool) s.pool.memoryBytes() else @as(usize, 0);
    }

    /// The bytes a packet takes before framing: as stored, or decoded when a prepared packet
    /// goes out decoded, below the compression threshold or without one. As `Service.chargedLength`.
    fn framedLength(s: *const SharedPages, length: usize, decoded_length: usize) usize {
        if (decoded_length == 0) return length;
        if (s.compression_threshold) |threshold| if (decoded_length >= threshold) return length;
        return @max(length, decoded_length);
    }

    /// Units a packet of `len` bytes takes.
    pub fn unitsFor(s: *const SharedPages, len: usize) usize {
        return std.math.divCeil(usize, storedBytes(len), s.unit_bytes) catch unreachable;
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
            if (len == 0 or len > s.page_bytes or count == s.pool.free_slot_count) break;
            const units = s.unitsFor(len);
            const first = s.place(trial, &cursors, units, small) orelse break;
            trial.setRangeValue(.{ .start = first, .end = first + units }, false);
            if (s.isSmall(units)) small += units;
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

    /// Packets of up to a kilobyte, such as entity movement in a crowd, are small.
    fn smallLimit(s: *const SharedPages) usize {
        return s.unitsFor(1024);
    }

    fn isSmall(s: *const SharedPages, units: usize) bool {
        return units <= s.smallLimit() and s.smallStart() < s.pool.units();
    }

    /// Small packets are kept from breaking up the runs that larger ones, such as terrain,
    /// need. They start in the upper half and spill below it from the top down. Larger ones
    /// start at the bottom. The split falls where a whole number of the largest packets ends,
    /// so neither region strands part of one. A pool of a few of them keeps a single region.
    fn smallStart(s: *const SharedPages) usize {
        const total = s.pool.units();
        const packet = s.pool.packet_units;
        if (total < 4 * packet or s.smallLimit() >= packet) return total;
        return total / packet / 2 * packet;
    }

    /// Small packets may hold no more of the pool than this, so that a flood of them always
    /// leaves room for the largest.
    fn smallCap(s: *const SharedPages) usize {
        const total = s.pool.units();
        return total - @max(total / 4, s.pool.packet_units);
    }

    /// Where a reservation of `units` goes in `free`.
    fn place(s: *const SharedPages, free: *const std.DynamicBitSetUnmanaged, cursors: *Cursors, units: usize, small_held: usize) ?usize {
        const total = s.pool.units();
        const split = s.smallStart();
        if (s.isSmall(units)) {
            if (small_held + units > s.smallCap()) return null;
            const at = @max(cursors.small, split);
            if (s.pool.findRunIn(free, at, total, units) orelse s.pool.findRunIn(free, split, @min(total, at + units - 1), units)) |first| {
                cursors.small = if (first + units >= total) split else first + units;
                return first;
            }
            return s.pool.lastRunIn(free, 0, split, units);
        }
        const end = split;
        const cursor = if (cursors.large < end) cursors.large else 0;
        const overlap_end = cursor + @min(units - 1, end - cursor);
        if (s.pool.findRunIn(free, cursor, end, units) orelse s.pool.findRunIn(free, 0, overlap_end, units)) |first| {
            cursors.large = (first + units) % end;
            return first;
        }
        if (split == total) return null;
        return s.pool.findRunIn(free, split, total, units);
    }

    fn reserveLocked(s: *SharedPages, len: usize) ?Reservation {
        if (len == 0 or len > s.page_bytes or s.pool.free_slot_count == 0) return null;
        const units = s.unitsFor(len);
        const small = s.isSmall(units);
        var cursors: Cursors = .{ .large = s.pool.cursor, .small = s.pool.small_cursor };
        const first = s.place(&s.pool.free_units, &cursors, units, s.pool.small_units) orelse return null;
        s.pool.cursor = cursors.large;
        s.pool.small_cursor = cursors.small;
        s.pool.free_units.setRangeValue(.{ .start = first, .end = first + units }, false);
        s.pool.active_units += units;
        if (small) s.pool.small_units += units;
        if (s.pool.active_units > s.pool.peak_units) {
            s.pool.peak_units = s.pool.active_units;
            s.pool.small_at_peak = s.pool.small_units;
        }
        s.pool.largest_reservation = @max(s.pool.largest_reservation, len);
        std.debug.assert(s.pool.active_units <= s.pool.units());

        s.pool.free_slot_count -= 1;
        const id = s.pool.free_slots[s.pool.free_slot_count];
        s.pool.peak_slots = @max(s.pool.peak_slots, s.slots.len - s.pool.free_slot_count);
        const slot = &s.slots[id];
        const old = slot.status.load(.monotonic);
        std.debug.assert(old & 255 == @backingInt(State.free));
        slot.* = .{ .status = .init(old), .first = @intCast(first), .units = @intCast(units), .owner = s.owner, .small = small };
        slot.status.store(status(.reserved, (old >> 8) + 1), .release);
        return .{
            .page = id,
            .generation = (old >> 8) + 1,
            .bytes = s.payload(id)[0..len],
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
        if (r.page >= s.slots.len or (selected == null and to.len == 0) or to.len > s.recipients_per_page) return false;

        const p = &s.slots[r.page];
        if (p.owner != s.owner or p.status.load(.acquire) != status(.reserved, r.generation) or r.bytes.ptr != s.payload(r.page).ptr or r.bytes.len == 0 or r.bytes.len > @min(s.page_bytes, p.units * s.unit_bytes - headroom))
            return false;

        // Where its recipients go in the ring, checked before anything changes. Credit bounds
        // what waits to be taken, so the ring always has room.
        var recipient_start = s.recipient_tail;
        if (selected == null) {
            const capacity = s.recipient_ring.len;
            if (recipient_start % capacity + to.len > capacity) recipient_start += capacity - recipient_start % capacity;
            if (recipient_start + to.len - s.recipient_head.load(.acquire) > capacity) return false;
        }
        // What the packet did not use goes back, and following reservations pack into it. A
        // prepared packet the worker sends decoded keeps room to be decoded into.
        const units = @min(p.units, s.unitsFor(s.framedLength(r.bytes.len, r.decoded_length)));
        s.freeUnits(p.first + units, p.units - units, p.small);
        if (units < p.units and !p.small) s.pool.cursor = p.first + units;
        p.units = @intCast(units);
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
            s.peak_recipients = @max(s.peak_recipients, s.recipient_tail - s.recipient_head.load(.monotonic));
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
        if (r.page >= s.slots.len or s.slots[r.page].owner != s.owner or s.slots[r.page].status.load(.acquire) != status(.reserved, r.generation)) return;
        if (r.bytes.ptr != s.payload(r.page).ptr or r.bytes.len > s.page_bytes) return;
        s.freeSlot(r.page);
    }

    pub fn takeReady(s: *SharedPages) ?RawPacket {
        const id = s.ready.pop() orelse return null;
        const p = &s.slots[id];
        std.debug.assert(p.owner == s.owner);
        const generation = p.status.load(.acquire) >> 8;
        const previous = p.status.cmpxchgStrong(status(.published, generation), status(.taken, generation), .acq_rel, .acquire);
        std.debug.assert(previous == null);
        var result: RawPacket = .{ .page = id, .units = p.units, .generation = generation, .bytes = s.payload(id)[0..p.len], .decoded_length = p.decoded_length, .recipients = undefined, .recipient_end = p.recipient_end, .group = p.group };
        // A packet selecting from an audience has no recipients in the ring.
        if (p.audience == null) result.recipients = Recipients.all(s.recipient_ring[p.recipient_start..][0..p.recipient_count]);
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

    pub fn releaseReady(s: *SharedPages, id: SlotId, generation: u64) bool {
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

    fn releaseLocked(s: *SharedPages, id: SlotId, generation: u64) bool {
        if (id >= s.slots.len or generation > std.math.maxInt(u56)) return false;
        const p = &s.slots[id];
        if (p.owner != s.owner or p.status.load(.acquire) != status(.taken, generation)) return false;
        std.debug.assert(p.len <= s.pool.payload_bytes);
        s.pool.payload_bytes -= p.len;
        if (p.audience) |audience| {
            const slot = &s.pool.audiences[audience.index];
            std.debug.assert(slot.generation == audience.generation);
            const previous = slot.references.fetchSub(1, .acq_rel);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                std.debug.assert(!s.pool.free_audiences.isSet(audience.index));
                s.pool.free_audiences.set(audience.index);
                s.pool.audiences_in_use -= 1;
            }
            p.audience = null;
        }
        // Its recipients were released when it was taken, unless it went back unread.
        if (p.recipient_end > s.recipient_head.load(.monotonic)) s.recipient_head.store(p.recipient_end, .release);
        s.freeSlot(id);
        return true;
    }

    /// Gives a reserved or taken packet's units and slot back.
    fn freeSlot(s: *SharedPages, id: SlotId) void {
        const p = &s.slots[id];
        const old = p.status.load(.monotonic);
        std.debug.assert(old & 255 == @backingInt(State.reserved) or old & 255 == @backingInt(State.taken));
        s.freeUnits(p.first, p.units, p.small);
        p.units = 0;
        p.small = false;
        p.status.store(status(.free, old >> 8), .release);
        std.debug.assert(s.pool.free_slot_count < s.slots.len);
        s.pool.free_slots[s.pool.free_slot_count] = id;
        s.pool.free_slot_count += 1;
    }

    fn freeUnits(s: *SharedPages, first: usize, units: usize, small: bool) void {
        std.debug.assert(units <= s.pool.active_units);
        s.pool.active_units -= units;
        if (small) {
            std.debug.assert(units <= s.pool.small_units);
            s.pool.small_units -= units;
        }
        s.pool.free_units.setRangeValue(.{ .start = first, .end = first + units }, true);
        if (s.pool.active_units == 0) {
            s.pool.cursor = 0;
            s.pool.small_cursor = 0;
        }
    }

    pub fn framingHeadroom(s: *SharedPages, id: SlotId) []u8 {
        return s.storage(id)[0..headroom];
    }

    /// All a taken packet's storage: the headroom, the packet, and the room after it to grow into.
    pub fn packetStorage(s: *SharedPages, packet: RawPacket) []u8 {
        std.debug.assert(s.slots[packet.page].status.load(.acquire) == status(.taken, packet.generation));
        return s.storage(packet.page);
    }

    pub fn framingStorage(s: *SharedPages, packet: RawPacket) []u8 {
        std.debug.assert(s.slots[packet.page].status.load(.acquire) == status(.taken, packet.generation));
        return s.storage(packet.page)[0 .. headroom + packet.bytes.len];
    }

    fn payload(s: *SharedPages, id: SlotId) []u8 {
        return s.storage(id)[headroom..];
    }

    fn storage(s: *SharedPages, id: SlotId) []u8 {
        const p = &s.slots[id];
        std.debug.assert(p.units != 0);
        return s.bytes[@as(usize, p.first) * s.unit_bytes ..][0 .. @as(usize, p.units) * s.unit_bytes];
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

test "small packets take about what they hold" {
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 1, .page_bytes = 384 * 1024, .recipients_per_page = 1 });
    defer pool.deinit();
    // A movement update of twenty bytes takes one unit, not a page.
    try std.testing.expectEqual(@as(usize, 1), pool.unitsFor(20));
    var held: [64]Reservation = undefined;
    for (&held) |*reservation| reservation.* = pool.reserve(20).?;
    try std.testing.expectEqual(held.len * pool.unit_bytes, pool.pool.active_units * pool.unit_bytes);
    try std.testing.expect(pool.pool.active_units * pool.unit_bytes < 16 * 1024);
    pool.cancelMany(&held);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
}

test "a pool out of slots backpressures until one is released" {
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 1, .page_bytes = 4096, .slots = 4, .recipients_per_page = 1 });
    defer pool.deinit();
    var held: [4]Reservation = undefined;
    for (&held) |*reservation| reservation.* = pool.reserve(1).?;
    // Units are free, but no slot names another packet.
    try std.testing.expect(pool.pool.active_units < pool.pool.units());
    try std.testing.expectEqual(null, pool.reserve(1));
    try std.testing.expectEqual(@as(usize, 0), pool.fit(&.{1}));
    try std.testing.expect(pool.publish(held[0], &.{.{ .index = 0, .generation = 1 }}));
    const packet = pool.takeReady().?;
    try std.testing.expect(pool.releaseReady(packet.page, packet.generation));
    try std.testing.expectEqual(@as(usize, 1), pool.fit(&.{ 1, 1 }));
    const replacement = pool.reserve(1).?;
    try std.testing.expectEqual(@as(usize, 4), pool.pool.peak_slots);
    pool.cancelMany(&.{ replacement, held[1], held[2], held[3] });
    try std.testing.expectEqual(pool.slots.len, pool.pool.free_slot_count);
}

test "a trial of reservations answers what the pool would take without taking it" {
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 4, .page_bytes = 131072, .slots = 4096, .recipients_per_page = 1 });
    defer pool.deinit();
    const pages: [8]usize = @splat(131072);
    try std.testing.expectEqual(@as(usize, 4), pool.fit(&pages));
    // A length the pool can never hold ends the trial where it stands.
    try std.testing.expectEqual(@as(usize, 1), pool.fit(&.{ 1, 131073, 1 }));
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);

    // Packets of a few kilobytes fill the pool, and one of every few is kept: most units are
    // free again, but no run is long enough for a page. Counting free units would promise
    // room that is not there.
    const medium = 4096;
    var filler: [4096]Reservation = undefined;
    var filled: usize = 0;
    while (pool.reserve(medium)) |reservation| : (filled += 1) filler[filled] = reservation;
    const stride = pool.pool.packet_units / pool.unitsFor(medium) / 2;
    var kept: [4096]Reservation = undefined;
    var kept_count: usize = 0;
    for (filler[0..filled], 0..) |reservation, index| {
        if (index % stride == 0) {
            kept[kept_count] = reservation;
            kept_count += 1;
        } else pool.cancel(reservation);
    }
    try std.testing.expect(pool.pool.active_units < pool.pool.units() / 4);
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
    pool.cancelMany(kept[0..kept_count]);
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
    try std.testing.expectEqual(@as(usize, 10), pool.units());
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
                // The highest run, as small packets spilling into the lower region take it.
                var highest: ?usize = null;
                var first: usize = 0;
                while (first + units <= 10) : (first += 1) {
                    const fits = for (first..first + units) |bit| {
                        if (!pool.free_units.isSet(bit)) break false;
                    } else true;
                    if (fits) highest = first;
                }
                try std.testing.expectEqual(highest, pool.lastRunIn(&pool.free_units, 0, 10, units));
            }
        }
    }
    pool.free_units.setRangeValue(.{ .start = 0, .end = 10 }, true);
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
    var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 8, .page_bytes = 128 * 1024, .slots = 8192, .recipients_per_page = 1 });
    defer pool.deinit();
    try std.testing.expect(pool.smallStart() < pool.pool.units());
    const small_units = pool.unitsFor(1024);
    var small: [8192]Reservation = undefined;
    var count: usize = 0;
    while (count < small.len) : (count += 1) small[count] = pool.reserve(1024) orelse break;
    // Small packets stopped where a full page still fits.
    try std.testing.expectEqual(pool.smallCap() / small_units, count);
    const page = pool.reserve(128 * 1024).?;
    try std.testing.expectEqual(@as(usize, 0), pool.fit(&.{1024}));
    pool.cancel(page);
    pool.cancelMany(small[0..count]);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.small_units);
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
    const per_page = pool.pool.packet_units;
    try std.testing.expectEqual(@as(usize, 0), pool.smallStart() % per_page);
    var pages: [9]Reservation = undefined;
    for (&pages) |*page| page.* = pool.reserve(128 * 1024).?;
    try std.testing.expectEqual(@as(?Reservation, null), pool.reserve(1));
    // A freed page in the lower region takes small packets once the upper one is full.
    const freed = pool.slots[pages[0].page].first;
    try std.testing.expect(freed < pool.smallStart());
    pool.cancel(pages[0]);
    try std.testing.expectEqual(@as(usize, 1), pool.fit(&.{1}));
    const small = pool.reserve(1).?;
    // It came from the top of what was freed, so the rest of that run stays whole.
    try std.testing.expectEqual(freed + per_page - 1, pool.slots[small.page].first);
    pool.cancel(small);
    for (pages[1..]) |page| pool.cancel(page);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.active_units);
    try std.testing.expectEqual(@as(usize, 0), pool.pool.small_units);
}

test "a slot reused for an audience packet reads no recipients from the ring" {
    // One slot and a ring of four recipients, so every packet uses the same slot, and a plain
    // publication can leave the slot's place in the ring near its end.
    var output = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 1, .page_bytes = 64, .recipients_per_page = 4 });
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 1), output.slots.len);
    const handles = [_]networking.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 }, .{ .index = 2, .generation = 1 }, .{ .index = 3, .generation = 1 } };
    for ([_]usize{ 1, 2 }) |count| {
        const reservation = output.reserve(1).?;
        try std.testing.expect(output.publish(reservation, handles[0..count]));
        const packet = output.takeReady().?;
        try std.testing.expect(packet.recipients.eqlSlice(handles[0..count]));
        output.releaseRecipients(packet);
        try std.testing.expect(output.releaseReady(packet.page, packet.generation));
    }
    // The slot's last plain publication started at the ring's second place, and this one
    // selects all four of its audience.
    var writer = output.pool.reserveAudience(std.testing.io, handles.len).?;
    @memcpy(writer.handles, &handles);
    const audience = writer.finish();
    const reservation = output.reserve(1).?;
    output.publishMany(&.{.{ .reservation = reservation, .audience = audience, .mask = &.{0b1111} }});
    audience.release(std.testing.io);
    const packet = output.takeReady().?;
    try std.testing.expect(packet.recipients.eqlSlice(&handles));
    try std.testing.expect(output.releaseReady(packet.page, packet.generation));
}

test "a prepared packet sent decoded keeps room to be decoded into" {
    for ([_]?usize{ null, 256 }) |threshold| {
        var pool = try SharedPages.init(std.testing.allocator, std.testing.io, .{ .pages = 1, .page_bytes = 4096, .recipients_per_page = 1, .compression_threshold = threshold });
        defer pool.deinit();
        var reservation = pool.reserve(4096).?;
        // Stored compressed in 100 bytes, 3000 decoded.
        reservation.bytes = reservation.bytes[0..100];
        reservation.decoded_length = 3000;
        try std.testing.expect(pool.publish(reservation, &.{.{ .index = 0, .generation = 1 }}));
        const packet = pool.takeReady().?;
        // Without compression the worker frames it decoded, in its own storage.
        const kept: usize = if (threshold == null) 3000 else 100;
        try std.testing.expectEqual(pool.unitsFor(kept), packet.units);
        try std.testing.expect(pool.packetStorage(packet).len >= storedBytes(kept));
        try std.testing.expect(pool.releaseReady(packet.page, packet.generation));
    }
}
