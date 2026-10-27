const std = @import("std");

pub const Slots = struct {
    pub const Slot = struct {
        const Allocation = struct {
            next: ?*Allocation,
            bytes: []u8,
            payload: []u8,
            alignment: std.mem.Alignment,
            payload_alignment: std.mem.Alignment,
            used: bool,
        };

        backing: std.mem.Allocator,
        first: ?*Allocation = null,
        occupied: bool = false,
        sealed: bool = false,
        reserved_bytes: usize = 0,

        pub fn allocator(self: *Slot) std.mem.Allocator {
            std.debug.assert(self.occupied);
            return .{ .ptr = self, .vtable = &Adapter.vtable };
        }

        pub fn seal(self: *Slot) void {
            std.debug.assert(!self.occupied and !self.sealed);
            self.sealed = true;
        }

        pub fn release(self: *Slot) void {
            std.debug.assert(self.occupied);
            var next = self.first;
            while (next) |allocation| : (next = allocation.next) allocation.used = false;
            self.occupied = false;
        }

        fn deinit(self: *Slot) void {
            std.debug.assert(!self.occupied);
            var next = self.first;
            while (next) |allocation| {
                next = allocation.next;
                self.backing.rawFree(allocation.bytes, allocation.alignment, @returnAddress());
            }
        }

        fn find(self: *Slot, bytes: []u8) *Allocation {
            var next = self.first;
            while (next) |allocation| : (next = allocation.next) {
                if (allocation.payload.ptr == bytes.ptr) {
                    std.debug.assert(allocation.used and bytes.len <= allocation.payload.len);
                    return allocation;
                }
            }
            unreachable;
        }

        const Adapter = struct {
            const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

            fn slot(raw: *anyopaque) *Slot {
                return @ptrCast(@alignCast(raw));
            }

            fn alloc(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
                const self = slot(raw);
                std.debug.assert(self.occupied);
                var next = self.first;
                while (next) |allocation| : (next = allocation.next) {
                    if (allocation.used or allocation.payload.len != length or allocation.payload_alignment != alignment) continue;
                    allocation.used = true;
                    return allocation.payload.ptr;
                }
                if (self.sealed) return null;
                const prefix = alignment.forward(@sizeOf(Allocation));
                const total = std.math.add(usize, prefix, length) catch return null;
                const backing_alignment = alignment.max(.of(Allocation));
                const bytes = (self.backing.rawAlloc(total, backing_alignment, address) orelse return null)[0..total];
                const header: []align(@alignOf(Allocation)) u8 = @alignCast(bytes[0..@sizeOf(Allocation)]);
                const allocation = std.mem.bytesAsValue(Allocation, header);
                allocation.* = .{ .next = self.first, .bytes = bytes, .payload = bytes[prefix..], .alignment = backing_alignment, .payload_alignment = alignment, .used = true };
                self.first = allocation;
                self.reserved_bytes += total;
                return allocation.payload.ptr;
            }

            fn resize(raw: *anyopaque, bytes: []u8, _: std.mem.Alignment, length: usize, _: usize) bool {
                return length <= slot(raw).find(bytes).payload.len;
            }

            fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {
                return if (resize(raw, bytes, alignment, length, address)) bytes.ptr else null;
            }

            fn free(raw: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
                slot(raw).find(bytes).used = false;
            }
        };
    };

    allocator: std.mem.Allocator,
    hub: Slot,
    islands: []Slot,

    pub fn init(allocator: std.mem.Allocator, count: usize) !Slots {
        if (count == 0) return error.InvalidSlotCapacity;
        const islands = try allocator.alloc(Slot, count);
        for (islands) |*slot| slot.* = .{ .backing = allocator };
        return .{ .allocator = allocator, .hub = .{ .backing = allocator }, .islands = islands };
    }

    pub fn deinit(self: *Slots) void {
        self.hub.deinit();
        for (self.islands) |*slot| slot.deinit();
        self.allocator.free(self.islands);
        self.* = undefined;
    }

    pub fn acquire(self: *Slots, hub: bool) !*Slot {
        if (hub) {
            if (self.hub.occupied) return error.ActiveWorldLimit;
            self.hub.occupied = true;
            return &self.hub;
        }
        for (self.islands) |*slot| {
            if (slot.occupied) continue;
            slot.occupied = true;
            return slot;
        }
        return error.ActiveWorldLimit;
    }
};

test "reservations use initialization requests and reuse them after sealing" {
    var slots = try Slots.init(std.testing.allocator, 2);
    defer slots.deinit();
    const slot = try slots.acquire(false);
    const bytes = try slot.allocator().alignedAlloc(u8, .@"64", 1234);
    const address = bytes.ptr;
    slot.release();
    slot.seal();
    const reserved = slot.reserved_bytes;
    const reused = try slots.acquire(false);
    const again = try reused.allocator().alignedAlloc(u8, .@"64", 1234);
    try std.testing.expectEqual(address, again.ptr);
    try std.testing.expectEqual(reserved, reused.reserved_bytes);
    try std.testing.expectError(error.OutOfMemory, reused.allocator().alloc(u8, 1235));
    reused.release();
}

test "reservation classes keep different alignments separate during reuse" {
    var slots = try Slots.init(std.testing.allocator, 1);
    defer slots.deinit();
    const slot = try slots.acquire(false);
    const first = try slot.allocator().alignedAlloc(u8, .@"8", 256);
    const second = try slot.allocator().alignedAlloc(u8, .@"64", 256);
    const first_address = first.ptr;
    const second_address = second.ptr;
    slot.release();
    slot.seal();
    const again = try slots.acquire(false);
    const reused_first = try again.allocator().alignedAlloc(u8, .@"8", 256);
    const reused_second = try again.allocator().alignedAlloc(u8, .@"64", 256);
    try std.testing.expectEqual(first_address, reused_first.ptr);
    try std.testing.expectEqual(second_address, reused_second.ptr);
    again.release();
}
