//! A std.Io for tests whose time and randomness belong to the test. Time is virtual: every clock
//! reads it, and it moves only when the code under test reads it, sleeps, waits with a timeout,
//! or the test advances it, so nothing ever waits in real time. Randomness, even what asks to be
//! secure, comes from a seed, so a run replays exactly. Files and the rest are std.Io.Threaded's,
//! run on the calling thread alone: with nothing else running, a wait nothing can end is a
//! deadlock, and panics rather than hangs.
const std = @import("std");
const assert = std.debug.assert;

pub const DeterministicIo = struct {
    pub const Options = struct {
        seed: u64 = 0,
        /// What the real clock reads at the start; the others start at zero.
        start: std.Io.Timestamp = .{ .nanoseconds = 0 },
    };

    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    prng: std.Random.DefaultPrng,
    /// Virtual nanoseconds since the start.
    elapsed: i96 = 0,
    start: i96,

    /// Ready once in its final place: `io` refers back to it.
    pub fn init(allocator: std.mem.Allocator, options: Options) DeterministicIo {
        @disableInstrumentation();
        // Nothing runs beside the caller, so waiting is the only way for time to pass.
        var threaded = std.Io.Threaded.init(allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
        var vtable = threaded.io().vtable.*;
        vtable.random = random;
        vtable.randomSecure = randomSecure;
        vtable.now = now;
        vtable.clockResolution = clockResolution;
        vtable.sleep = sleep;
        vtable.futexWait = futexWait;
        vtable.futexWaitUncancelable = futexWaitUncancelable;
        assert(options.start.nanoseconds >= 0);
        return .{ .threaded = threaded, .vtable = vtable, .prng = .init(options.seed), .start = options.start.nanoseconds };
    }

    pub fn deinit(self: *DeterministicIo) void {
        @disableInstrumentation();
        self.threaded.deinit();
        self.* = undefined;
    }

    pub fn io(self: *DeterministicIo) std.Io {
        @disableInstrumentation();
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    /// Moves time on, as if the test had waited that long.
    pub fn advance(self: *DeterministicIo, duration: std.Io.Duration) void {
        @disableInstrumentation();
        assert(duration.nanoseconds >= 0);
        self.elapsed += duration.nanoseconds;
    }

    fn owner(raw: ?*anyopaque) *DeterministicIo {
        @disableInstrumentation();
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(raw.?));
        return @alignCast(@fieldParentPtr("threaded", threaded));
    }

    fn random(raw: ?*anyopaque, buffer: []u8) void {
        @disableInstrumentation();
        owner(raw).prng.random().bytes(buffer);
    }

    fn randomSecure(raw: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
        @disableInstrumentation();
        random(raw, buffer);
    }

    /// Each reading is a nanosecond after the last, so time never stands still between two.
    fn now(raw: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        @disableInstrumentation();
        const self = owner(raw);
        self.elapsed += 1;
        return .{ .nanoseconds = if (clock == .real) self.start + self.elapsed else self.elapsed };
    }

    fn clockResolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
        @disableInstrumentation();
        return .{ .nanoseconds = 1 };
    }

    fn sleep(raw: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        @disableInstrumentation();
        const self = owner(raw);
        const duration = timeout.toDurationFromNow(self.io()) orelse @panic("deterministic io: a sleep without end never returns");
        self.advance(.{ .nanoseconds = @max(0, duration.raw.nanoseconds) });
    }

    /// Nothing else runs to wake a waiter, so a wait ends now if its value already changed, at
    /// its timeout otherwise, and never if it has none.
    fn futexWait(raw: ?*anyopaque, pointer: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        @disableInstrumentation();
        if (@atomicLoad(u32, pointer, .acquire) != expected) return;
        const self = owner(raw);
        const duration = timeout.toDurationFromNow(self.io()) orelse @panic("deterministic io: a wait nothing can end");
        self.advance(.{ .nanoseconds = @max(0, duration.raw.nanoseconds) });
    }

    fn futexWaitUncancelable(_: ?*anyopaque, pointer: *const u32, expected: u32) void {
        @disableInstrumentation();
        if (@atomicLoad(u32, pointer, .acquire) == expected) @panic("deterministic io: a wait nothing can end");
    }
};

const testing = std.testing;

test "time moves only when read, slept or advanced, and sleeps take no real time" {
    var deterministic: DeterministicIo = .init(testing.allocator, .{ .start = .{ .nanoseconds = 1_700_000_000 * std.time.ns_per_s } });
    defer deterministic.deinit();
    const io = deterministic.io();
    const real_started = std.Io.Clock.awake.now(testing.io);
    try testing.expectEqual(@as(i96, 1_700_000_000 * std.time.ns_per_s + 1), std.Io.Clock.real.now(io).nanoseconds);
    try testing.expectEqual(@as(i96, 2), std.Io.Clock.awake.now(io).nanoseconds);
    try io.sleep(.fromSeconds(3600), .awake);
    // A sleep for a duration needs no reading of the clock.
    try testing.expectEqual(@as(i96, 3600 * std.time.ns_per_s + 3), std.Io.Clock.awake.now(io).nanoseconds);
    deterministic.advance(.fromMilliseconds(5));
    try testing.expectEqual(@as(i96, 3600 * std.time.ns_per_s + 5 * std.time.ns_per_ms + 4), std.Io.Clock.awake.now(io).nanoseconds);
    // An hour asleep took no time on the machine.
    try testing.expect(std.Io.Clock.awake.now(testing.io).nanoseconds - real_started.nanoseconds < std.time.ns_per_s);
}

test "timed waits end at their timeout, or at once when already set" {
    var deterministic: DeterministicIo = .init(testing.allocator, .{});
    defer deterministic.deinit();
    const io = deterministic.io();
    var event: std.Io.Event = .unset;
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    try testing.expectError(error.Timeout, event.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } }));
    try testing.expect(std.Io.Clock.awake.now(io).nanoseconds - before >= 30 * std.time.ns_per_s);
    event.set(io);
    const after = std.Io.Clock.awake.now(io).nanoseconds;
    try event.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } });
    try testing.expect(std.Io.Clock.awake.now(io).nanoseconds - after < std.time.ns_per_s);
}

test "randomness replays from the seed, secure or not" {
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    {
        var deterministic: DeterministicIo = .init(testing.allocator, .{ .seed = 12 });
        defer deterministic.deinit();
        deterministic.io().random(&first);
    }
    var deterministic: DeterministicIo = .init(testing.allocator, .{ .seed = 12 });
    defer deterministic.deinit();
    try deterministic.io().randomSecure(&second);
    try testing.expectEqualSlices(u8, &first, &second);
    var other: DeterministicIo = .init(testing.allocator, .{ .seed = 13 });
    defer other.deinit();
    other.io().random(&second);
    try testing.expect(!std.mem.eql(u8, &first, &second));
}
