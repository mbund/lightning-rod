const std = @import("std");
const networking = @import("networking");
pub const headroom = 6;

pub const PageId = u16;

pub const Configuration = struct {
    pages: usize,
    page_bytes: usize,
    recipients_per_page: usize,
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

pub const RawPacket = struct {
    page: PageId,
    units: usize,
    generation: u64,
    bytes: []const u8,
    recipients: []const networking.Handle,
};

pub const SharedPages = struct {
    allocator: std.mem.Allocator,
    page_bytes: usize,
    unit_bytes: usize,
    recipients_per_page: usize,
    bytes: []u8,
    pages: []Page,
    recipients: []networking.Handle,
    ready: Ring,
    returned: Ring,

    const State = enum(u8) { free, reserved, published, taken, returned };

    const Page = struct {
        status: std.atomic.Value(u64) = .init(0),
        units: usize = 0,
        len: usize = 0,
        recipient_count: usize = 0,
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

    pub fn init(a: std.mem.Allocator, c: Configuration) !SharedPages {
        if (c.pages == 0 or c.pages > std.math.maxInt(PageId) or c.page_bytes == 0 or c.recipients_per_page == 0) return error.InvalidConfiguration;

        const stride = std.math.add(usize, c.page_bytes, headroom) catch return error.InvalidConfiguration;
        const unit_bytes = @min(c.page_bytes, 64 * 1024) + headroom;
        const units_per_packet = std.math.divCeil(usize, stride, unit_bytes) catch unreachable;
        const units = std.math.mul(usize, c.pages, units_per_packet) catch return error.InvalidConfiguration;
        if (units > std.math.maxInt(PageId)) return error.InvalidConfiguration;

        const recipient_count = std.math.mul(usize, units, c.recipients_per_page) catch return error.InvalidConfiguration;
        const bytes = try a.alloc(u8, units * unit_bytes);
        errdefer a.free(bytes);
        const pages = try a.alloc(Page, units);
        errdefer a.free(pages);
        const recipients = try a.alloc(networking.Handle, recipient_count);
        errdefer a.free(recipients);
        const ring_capacity = try std.math.ceilPowerOfTwo(usize, units);
        const ready = try a.alloc(PageId, ring_capacity);
        errdefer a.free(ready);
        const returned = try a.alloc(PageId, ring_capacity);
        errdefer a.free(returned);

        for (pages) |*page| page.* = .{};

        return .{
            .allocator = a,
            .page_bytes = c.page_bytes,
            .unit_bytes = unit_bytes,
            .recipients_per_page = c.recipients_per_page,
            .bytes = bytes,
            .pages = pages,
            .recipients = recipients,
            .ready = .{ .slots = ready },
            .returned = .{ .slots = returned },
        };
    }

    pub fn deinit(s: *SharedPages) void {
        s.reap();

        for (s.pages) |*page| std.debug.assert(page.status.load(.acquire) & 255 == @intFromEnum(State.free));
        s.allocator.free(s.returned.slots);
        s.allocator.free(s.ready.slots);
        s.allocator.free(s.recipients);
        s.allocator.free(s.pages);
        s.allocator.free(s.bytes);
        s.* = undefined;
    }

    pub fn memoryBytes(s: *const SharedPages) usize {
        return @sizeOf(SharedPages) + s.bytes.len + s.pages.len * @sizeOf(Page) +
            s.recipients.len * @sizeOf(networking.Handle) + (s.ready.slots.len + s.returned.slots.len) * @sizeOf(PageId);
    }

    pub fn reserve(s: *SharedPages, len: usize) ?Reservation {
        if (len == 0 or len > s.page_bytes) return null;
        s.reap();
        const units = std.math.divCeil(usize, len + headroom, s.unit_bytes) catch unreachable;
        var free: usize = 0;

        for (s.pages, 0..) |*p, i| {
            const previous = p.status.load(.acquire);
            if (previous & 255 != @intFromEnum(State.free)) {
                free = 0;
                continue;
            }

            free += 1;
            if (free != units) continue;

            const first = i + 1 - units;

            for (s.pages[first..][0..units]) |*part| {
                const old = part.status.load(.monotonic);
                std.debug.assert(old & 255 == @intFromEnum(State.free));
                part.status.store(status(.reserved, (old >> 8) + 1), .release);
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

        return null;
    }

    pub fn publish(s: *SharedPages, r: Reservation, to: []const networking.Handle) bool {
        if (r.page >= s.pages.len or to.len == 0 or to.len > s.recipients_per_page) return false;

        const p = &s.pages[r.page];
        if (p.status.load(.acquire) != status(.reserved, r.generation) or r.bytes.ptr != s.pagePayload(r.page).ptr or r.bytes.len == 0 or r.bytes.len > @min(s.page_bytes, p.units * s.unit_bytes - headroom))
            return false;

        const units = std.math.divCeil(usize, r.bytes.len + headroom, s.unit_bytes) catch unreachable;
        s.freeRange(@as(usize, r.page) + units, p.units - units);
        p.units = units;
        const base = @as(usize, r.page) * s.recipients_per_page;
        @memcpy(s.recipients[base..][0..to.len], to);
        p.len = r.bytes.len;
        p.recipient_count = to.len;
        p.status.store(status(.published, r.generation), .release);
        const queued = s.ready.push(r.page);
        std.debug.assert(queued);
        return true;
    }

    pub fn cancel(s: *SharedPages, r: Reservation) void {
        if (r.page >= s.pages.len or s.pages[r.page].status.load(.acquire) != status(.reserved, r.generation)) return;
        if (r.bytes.ptr != s.pagePayload(r.page).ptr or r.bytes.len > s.page_bytes) return;
        s.freeRange(r.page, s.pages[r.page].units);
    }

    pub fn takeReady(s: *SharedPages) ?RawPacket {
        const id = s.ready.pop() orelse return null;
        const p = &s.pages[id];
        const generation = p.status.load(.acquire) >> 8;
        const previous = p.status.cmpxchgStrong(status(.published, generation), status(.taken, generation), .acq_rel, .acquire);
        std.debug.assert(previous == null);
        const base = @as(usize, id) * s.recipients_per_page;
        std.debug.assert(p.len > 0 and p.len <= s.page_bytes);
        std.debug.assert(p.recipient_count > 0 and p.recipient_count <= s.recipients_per_page);
        return .{
            .page = id,
            .units = p.units,
            .generation = generation,
            .bytes = s.pagePayload(id)[0..p.len],
            .recipients = s.recipients[base..][0..p.recipient_count],
        };
    }

    pub fn releaseReady(s: *SharedPages, id: PageId, generation: u64) bool {
        if (id >= s.pages.len or generation > std.math.maxInt(u56)) return false;
        if (s.pages[id].status.cmpxchgStrong(status(.taken, generation), status(.returned, generation), .acq_rel, .acquire) != null) return false;

        const queued = s.returned.push(id);
        std.debug.assert(queued);
        return true;
    }

    fn reap(s: *SharedPages) void {
        while (s.returned.pop()) |id| {
            std.debug.assert(s.pages[id].status.load(.acquire) & 255 == @intFromEnum(State.returned));
            s.freeRange(id, s.pages[id].units);
        }
    }

    fn freeRange(s: *SharedPages, first: usize, units: usize) void {
        for (s.pages[first..][0..units]) |*p| {
            const old = p.status.load(.monotonic);
            std.debug.assert(old & 255 == @intFromEnum(State.reserved) or old & 255 == @intFromEnum(State.returned));
            p.status.store(status(.free, old >> 8), .release);
        }
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
    var pool = try SharedPages.init(std.testing.allocator, .{ .pages = 2, .page_bytes = 192 * 1024, .recipients_per_page = 1 });
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
