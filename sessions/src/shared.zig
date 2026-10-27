const std = @import("std");
const networking = @import("networking");
pub const headroom = 6;

pub const PageId = u16;

pub const Configuration = struct {
    pages: usize,
    page_bytes: usize,
    recipients_per_page: usize,
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
    page: PageId,
    units: usize,
    generation: u64,
    bytes: []const u8,
    recipients: Recipients,
    group: Group = .{},
    // Mask storage belongs to this packet's page until it is recycled.
    selection: ?struct { pool: *const Pool, audience: usize, generation: u64, mask: []const usize } = null,

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
    recipients: []networking.Handle,
    audiences: []AudienceSlot,
    audience_handles: []networking.Handle,
    recipient_masks: []usize,
    free_audiences: std.DynamicBitSetUnmanaged,
    next_owner: u32 = 0,
    cursor: usize = 0,

    const AudienceSlot = struct {
        references: std.atomic.Value(usize) = .init(0),
        generation: u64 = 0,
        length: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !Pool {
        if (config.pages == 0 or config.page_bytes == 0 or config.recipients_per_page == 0) return error.InvalidConfiguration;
        const unit_bytes = @min(config.page_bytes, 64 * 1024) + headroom;
        const packet_bytes = try std.math.add(usize, config.page_bytes, headroom);
        const per_packet = try std.math.divCeil(usize, packet_bytes, unit_bytes);
        const units = try std.math.mul(usize, config.pages, per_packet);
        if (units > std.math.maxInt(PageId)) return error.InvalidConfiguration;
        const bytes = try allocator.alignedAlloc(u8, .@"64", try std.math.mul(usize, units, unit_bytes));
        errdefer allocator.free(bytes);
        const pages = try allocator.alloc(SharedPages.Page, units);
        errdefer allocator.free(pages);
        const recipients = try allocator.alloc(networking.Handle, try std.math.mul(usize, units, config.recipients_per_page));
        errdefer allocator.free(recipients);
        const audiences = try allocator.alloc(AudienceSlot, units);
        errdefer allocator.free(audiences);
        const audience_handles = try allocator.alloc(networking.Handle, recipients.len);
        errdefer allocator.free(audience_handles);
        const words = try std.math.divCeil(usize, config.recipients_per_page, @bitSizeOf(usize));
        const recipient_masks = try allocator.alloc(usize, units * words);
        errdefer allocator.free(recipient_masks);
        var free_audiences = try std.DynamicBitSetUnmanaged.initFull(allocator, units);
        errdefer free_audiences.deinit(allocator);
        const free_units = try std.DynamicBitSetUnmanaged.initFull(allocator, units);
        for (audiences) |*slot| slot.* = .{};
        for (pages) |*page| page.* = .{};
        return .{ .allocator = allocator, .unit_bytes = unit_bytes, .recipients_per_page = config.recipients_per_page, .bytes = bytes, .pages = pages, .recipients = recipients, .free_units = free_units, .audiences = audiences, .audience_handles = audience_handles, .recipient_masks = recipient_masks, .free_audiences = free_audiences };
    }

    fn findRun(self: *const Pool, start: usize, end: usize, units: usize) ?usize {
        std.debug.assert(start <= end and end <= self.pages.len and units > 0);
        const Mask = std.DynamicBitSetUnmanaged.MaskInt;
        const Shift = std.DynamicBitSetUnmanaged.ShiftInt;
        const width = @bitSizeOf(Mask);
        var at = start;
        var first = start;
        var free: usize = 0;
        while (at < end) {
            const word = at / width;
            const bits = self.free_units.masks[word] & (~@as(Mask, 0) << @as(Shift, @intCast(at % width)));
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
        for (self.pages) |*page| std.debug.assert(page.status.load(.acquire) & 255 == @intFromEnum(SharedPages.State.free));
        for (self.audiences) |*slot| std.debug.assert(slot.references.load(.acquire) == 0);
        self.free_audiences.deinit(self.allocator);
        self.allocator.free(self.recipient_masks);
        self.allocator.free(self.audience_handles);
        self.allocator.free(self.audiences);
        self.allocator.free(self.recipients);
        self.free_units.deinit(self.allocator);
        self.allocator.free(self.pages);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Pool) usize {
        const masks = std.math.divCeil(usize, self.pages.len, @bitSizeOf(usize)) catch unreachable;
        return @sizeOf(Pool) + self.bytes.len + self.pages.len * @sizeOf(SharedPages.Page) + (self.recipients.len + self.audience_handles.len) * @sizeOf(networking.Handle) +
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
    recipients: []networking.Handle,
    ready: Ring,

    const State = enum(u8) { free, reserved, published, taken };

    const Page = struct {
        status: std.atomic.Value(u64) = .init(0),
        units: usize = 0,
        len: usize = 0,
        recipient_count: usize = 0,
        owner: u32 = 0,
        group: Group = .{},
        audience: ?Audience = null,
    };

    fn status(state: State, generation: u64) u64 {
        std.debug.assert(generation <= std.math.maxInt(u56));
        return (generation << 8) | @intFromEnum(state);
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
            .recipients = pool.recipients,
            .ready = .{ .slots = ready },
        };
    }

    pub fn deinit(s: *SharedPages) void {
        s.producer.lockUncancelable(s.producer_io);
        for (s.pages) |*page| if (page.owner == s.owner) std.debug.assert(page.status.load(.acquire) & 255 == @intFromEnum(State.free));
        s.producer.unlock(s.producer_io);
        s.allocator.free(s.ready.slots);
        if (s.owns_pool) {
            s.pool.deinit();
            s.allocator.destroy(s.pool);
        }
        s.* = undefined;
    }

    pub fn memoryBytes(s: *const SharedPages) usize {
        return @sizeOf(SharedPages) + s.ready.slots.len * @sizeOf(PageId) + if (s.owns_pool) s.pool.memoryBytes() else @as(usize, 0);
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

    pub fn recipientBuffer(s: *SharedPages, reservation: Reservation) []networking.Handle {
        const p = &s.pages[reservation.page];
        std.debug.assert(p.owner == s.owner and p.status.load(.acquire) == status(.reserved, reservation.generation));
        const base = @as(usize, reservation.page) * s.recipients_per_page;
        return s.recipients[base..][0..s.recipients_per_page];
    }

    fn reserveLocked(s: *SharedPages, len: usize) ?Reservation {
        if (len == 0 or len > s.page_bytes) return null;
        const units = std.math.divCeil(usize, len + headroom, s.unit_bytes) catch unreachable;
        const cursor = s.pool.cursor;
        std.debug.assert(cursor < s.pages.len);
        const overlap_end = cursor + @min(units - 1, s.pages.len - cursor);
        const first = s.pool.findRun(cursor, s.pages.len, units) orelse
            s.pool.findRun(0, overlap_end, units) orelse return null;
        s.pool.cursor = (first + units) % s.pages.len;
        s.pool.free_units.setRangeValue(.{ .start = first, .end = first + units }, false);

        for (s.pages[first..][0..units]) |*part| {
            const old = part.status.load(.monotonic);
            std.debug.assert(old & 255 == @intFromEnum(State.free));
            part.status.store(status(.reserved, (old >> 8) + 1), .release);
            part.owner = s.owner;
        }

        const first_page = &s.pages[first];
        first_page.units = units;
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

        const units = std.math.divCeil(usize, r.bytes.len + headroom, s.unit_bytes) catch unreachable;
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
            const base = @as(usize, r.page) * s.recipients_per_page;
            const recipients = s.recipients[base..][0..to.len];
            if (recipients.ptr != to.ptr) @memcpy(recipients, to);
        }
        std.debug.assert(group.count > 0 and group.index < group.count);
        std.debug.assert(group.count == 1 or (group.protocol != null and group.bytes > 0));
        p.group = group;
        p.len = r.bytes.len;
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
        s.freeRange(r.page, s.pages[r.page].units);
    }

    pub fn takeReady(s: *SharedPages) ?RawPacket {
        const id = s.ready.pop() orelse return null;
        const p = &s.pages[id];
        std.debug.assert(p.owner == s.owner);
        const generation = p.status.load(.acquire) >> 8;
        const previous = p.status.cmpxchgStrong(status(.published, generation), status(.taken, generation), .acq_rel, .acquire);
        std.debug.assert(previous == null);
        const base = @as(usize, id) * s.recipients_per_page;
        var result: RawPacket = .{ .page = id, .units = p.units, .generation = generation, .bytes = s.pagePayload(id)[0..p.len], .recipients = Recipients.all(s.recipients[base..][0..p.recipient_count]), .group = p.group };
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
        s.freeRange(id, s.pages[id].units);
        return true;
    }

    fn freeRange(s: *SharedPages, first: usize, units: usize) void {
        for (s.pages[first..][0..units]) |*p| {
            const old = p.status.load(.monotonic);
            std.debug.assert(old & 255 == @intFromEnum(State.reserved) or old & 255 == @intFromEnum(State.taken));
            p.status.store(status(.free, old >> 8), .release);
        }
        s.pool.free_units.setRangeValue(.{ .start = first, .end = first + units }, true);
    }

    pub fn framingHeadroom(s: *SharedPages, id: PageId) []u8 {
        return s.pageStorage(id)[0..headroom];
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

    try std.testing.expect(pool.reserve(1) == null);

    for (packets, 0..) |packet, i| {
        try std.testing.expectEqual(lengths[i], packet.bytes.len);

        for (packet.bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(i + 1)), byte);
    }

    for ([_]usize{ 1, 0, 2 }) |i| try std.testing.expect(pool.releaseReady(packets[i].page, packets[i].generation));
    const replacement = pool.reserve(192 * 1024) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pool.releaseReady(packets[0].page, packets[0].generation));
    pool.cancel(replacement);
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
        @memset(output.pool.recipients, .{ .index = std.math.maxInt(usize), .generation = 0 });
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
        for (output.pool.recipients) |handle| try std.testing.expectEqual(@as(u32, 0), handle.generation);
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
    try std.testing.expectEqual(@as(usize, 0), output.pool.free_audiences.count());
    try std.testing.expectEqual(@as(usize, 1), output.pool.audiences[audience.index].length);
    audience.release(std.testing.io);
    try std.testing.expectEqual(output.pool.audiences.len, output.pool.free_audiences.count());
}
