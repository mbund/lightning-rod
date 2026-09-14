const std = @import("std");

const assert = std.debug.assert;

pub const Closing = struct {
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
    slots: []std.atomic.Value(bool),
    issued: usize = 0,
    pending: std.atomic.Value(u32) = .init(1),
    sealed: bool = false,
    done: std.Io.Event = .unset,

    pub fn init(io: std.Io, deadline: std.Io.Clock.Timestamp, slots: []std.atomic.Value(bool)) Closing {
        for (slots) |*slot| slot.* = .init(false);
        return .{ .io = io, .deadline = deadline, .slots = slots };
    }

    pub fn begin(self: *Closing) Token {
        assert(!self.sealed);
        assert(self.issued < self.slots.len);
        const slot = self.issued;
        self.issued += 1;
        const previous = self.pending.fetchAdd(1, .monotonic);
        assert(previous >= 1);
        return .{ .closing = self, .slot = slot };
    }

    pub fn seal(self: *Closing) void {
        assert(!self.sealed);
        self.sealed = true;

        if (self.pending.fetchSub(1, .acq_rel) == 1) self.done.set(self.io);
    }

    pub fn wait(self: *Closing) !void {
        assert(self.sealed);

        while (!self.done.isSet()) {
            self.done.waitTimeout(self.io, .{ .deadline = self.deadline }) catch |err| {
                if (err != error.Timeout) return err;
                if (std.Io.Clock.Timestamp.now(self.io, self.deadline.clock).raw.nanoseconds >= self.deadline.raw.nanoseconds)
                    return error.Timeout;
            };
        }

        assert(self.pending.load(.acquire) == 0);
    }

    pub const Token = struct {
        closing: *Closing,
        slot: usize,

        pub fn finish(self: Token) void {
            const closing = self.closing;
            assert(self.slot < closing.slots.len);
            const finished = closing.slots[self.slot].swap(true, .acq_rel);
            assert(!finished);
            const previous = closing.pending.fetchSub(1, .acq_rel);
            assert(previous > 0);

            if (previous == 1) closing.done.set(closing.io);
        }
    };
};
