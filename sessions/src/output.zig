const std = @import("std");

const assert = std.debug.assert;

/// Sockets cannot retain the final framing slot.
pub const SocketBudget = struct {
    capacity: usize,
    used: usize = 0,

    pub fn init(frames: usize) SocketBudget {
        assert(frames > 0);
        return .{ .capacity = frames - 1 };
    }

    pub fn available(self: *const SocketBudget) bool {
        assert(self.used <= self.capacity);
        return self.used < self.capacity;
    }
};

pub const Fragments = struct {
    prefix: []const u8 = &.{},
    payload: []const u8,

    pub fn length(self: Fragments) usize {
        return self.prefix.len + self.payload.len;
    }

    pub fn copyTo(self: Fragments, first: []u8, second: []u8) void {
        assert(self.length() == first.len + second.len);
        var written: usize = 0;
        for ([_][]const u8{ self.prefix, self.payload }) |part| {
            var offset: usize = 0;
            while (offset < part.len) {
                const destination = if (written < first.len) first[written..] else second[written - first.len ..];
                const count = @min(destination.len, part.len - offset);
                assert(count > 0);
                @memcpy(destination[0..count], part[offset..][0..count]);
                offset += count;
                written += count;
            }
        }
        assert(written == self.length());
    }
};

// Only the networking thread changes references, including codec completion.
pub const Loan = struct {
    payload: []const u8 = &.{},
    header: [16]u8 = undefined,
    header_length: usize = 0,
    references: usize = 0,
    sockets: usize = 0,
    budget: ?*SocketBudget = null,

    /// Headers belong to the frame. Reframing may reuse the source headroom.
    pub fn framed(bytes: []const u8, payload: []const u8) Loan {
        var loan: Loan = .{ .payload = bytes, .references = 1 };
        if (bytes.len >= payload.len and @intFromPtr(bytes.ptr) + bytes.len - payload.len == @intFromPtr(payload.ptr)) {
            loan.header_length = bytes.len - payload.len;
            assert(loan.header_length <= loan.header.len);
            @memcpy(loan.header[0..loan.header_length], bytes[0..loan.header_length]);
            loan.payload = payload;
        }
        assert(loan.length() == bytes.len);
        return loan;
    }

    pub fn fragments(self: *const Loan) Fragments {
        assert(self.references > 0 and self.header_length <= self.header.len);
        return .{ .prefix = self.header[0..self.header_length], .payload = self.payload };
    }

    pub fn length(self: *const Loan) usize {
        return self.fragments().length();
    }

    pub fn retain(self: *Loan) void {
        assert(self.references > 0);
        assert(self.references >= self.sockets);
        self.references += 1;
        assert(self.references > self.sockets);
    }

    pub fn release(self: *Loan) void {
        assert(self.references > self.sockets);
        self.references -= 1;
        assert(self.references >= self.sockets);
        if (self.references == 0) assert(self.budget == null);
    }

    pub fn retainSocket(self: *Loan, budget: *SocketBudget) bool {
        assert(self.references > 0);
        assert(self.references >= self.sockets);
        assert((self.sockets == 0) == (self.budget == null));
        if (self.sockets == 0) {
            assert(self.budget == null);
            if (!budget.available()) return false;
            budget.used += 1;
            self.budget = budget;
        } else assert(self.budget == budget);
        self.retain();
        self.sockets += 1;
        assert(self.references >= self.sockets);
        assert(self.budget == budget and budget.used > 0 and budget.used <= budget.capacity);
        return true;
    }

    pub fn releaseSocket(self: *Loan) void {
        assert(self.sockets > 0);
        assert(self.references >= self.sockets);
        assert(self.budget != null);
        self.sockets -= 1;
        if (self.sockets == 0) {
            const budget = self.budget.?;
            assert(budget.used > 0);
            budget.used -= 1;
            self.budget = null;
        }
        self.release();
        assert((self.sockets == 0) == (self.budget == null));
    }
};
