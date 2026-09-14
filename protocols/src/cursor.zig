const std = @import("std");
const wire = @import("support.zig");

pub const Error = wire.ReadError || wire.WriteError || error{DepthLimit};

pub const Mode = enum { read, write };

pub const Termination = union(enum) {
    counted,
    sentinel: u8,
    high_bit,
};

pub fn State(comptime mode: Mode) type {
    return struct {
        pub const Bytes = if (mode == .read) []const u8 else []u8;
        buffer: Bytes,
        rest: Bytes,
        owner: ?*const anyopaque = null,
        origin: usize = 0,
        serial: usize = 0,
        value: i128 = 0,
        first_mask: u8 = 255,

        pub fn init(bytes: Bytes) @This() {
            return .{ .buffer = bytes, .rest = bytes };
        }

        fn child(self: @This(), owner: *const anyopaque, serial: usize) @This() {
            var result = self;
            result.owner = owner;
            result.origin = @intFromPtr(self.rest.ptr);
            result.serial = serial;
            return result;
        }

        fn accept(self: *@This(), completed: @This(), owner: *const anyopaque, serial: usize) Error!void {
            if (completed.owner != owner or completed.serial != serial or completed.origin != @intFromPtr(self.rest.ptr) or
                completed.buffer.ptr != self.buffer.ptr or completed.buffer.len != self.buffer.len or
                completed.rest.len > self.rest.len or @intFromPtr(completed.rest.ptr) != @intFromPtr(self.rest.ptr) + self.rest.len - completed.rest.len) return error.InvalidCompletion;
            self.rest = completed.rest;
            self.value = completed.value;
            self.first_mask = completed.first_mask;
        }
    };
}

pub fn context(comptime Destination: type, source: anytype) Destination {
    var result: Destination = .{};

    inline for (@typeInfo(Destination).@"struct".fields) |field| {
        if (@hasField(@TypeOf(source), field.name)) @field(result, field.name) = @field(source, field.name);
    }

    return result;
}

pub fn End(comptime Entry: type, comptime mode: Mode) type {
    return struct {
        pub const Context = Entry.Context;
        pub const Completed = Entry;
        _cursor: State(mode),
        _context: Context = .{},

        pub fn finish(self: @This()) (if (mode == .read) Error!void else []u8) {
            std.debug.assert(self._cursor.owner == null);
            std.debug.assert(self._cursor.rest.len <= self._cursor.buffer.len);

            if (mode == .read) {
                if (self._cursor.rest.len != 0) return error.ExtraDataAfterEndOfPacket;
            } else return self._cursor.buffer[0 .. self._cursor.buffer.len - self._cursor.rest.len];
        }
    };
}

/// The gate must stay at a stable address between begin and advance.
pub fn Child(comptime Entry: type, comptime Next: type, comptime mode: Mode, comptime capture: []const u8) type {
    return struct {
        next_value: Next,
        child_context: Entry.Context,
        phase: enum { ready, active, complete } = .ready,

        pub fn begin(self: *@This()) Error!Entry {
            if (self.phase != .ready) return error.InvalidCompletion;
            self.phase = .active;
            return .{ ._cursor = self.next_value._cursor.child(self, 0), ._context = self.child_context };
        }

        pub fn advance(self: *@This(), completed: Entry.Done) Error!Next {
            if (self.phase != .active) return error.InvalidCompletion;
            try self.next_value._cursor.accept(completed._cursor, self, 0);

            if (capture.len != 0) @field(self.next_value._context, capture) = completed._cursor.value;
            self.phase = .complete;
            return self.next_value;
        }

        pub fn encoded(self: *@This()) Error!struct { []const u8, Next } {
            if (mode != .read) @compileError("encoded reads a borrowed encoded value");
            const start = self.next_value._cursor.rest;
            const done = try (try self.begin()).scan();
            const next_value = try self.advance(done);
            return .{ start[0 .. start.len - next_value._cursor.rest.len], next_value };
        }
    };
}

/// The sequence must stay at a stable address between next and advance.
pub fn Sequence(comptime Entry: type, comptime Next: type, comptime mode: Mode, comptime termination: Termination) type {
    return struct {
        next_value: Next,
        child_context: Entry.Context,
        remaining: usize,
        start: usize = 0,
        active: bool = false,

        pub fn next(self: *@This()) Error!?Entry {
            if (self.active) return error.InvalidCompletion;

            const rest = self.next_value._cursor.rest;
            if (mode == .read and termination == .sentinel) {
                if (rest.len == 0) return error.EndOfStream;
                if (rest[0] == termination.sentinel) {
                    self.remaining = 0;
                    return null;
                }

                if (self.remaining == 0) return error.CollectionTooLarge;
            }

            if (self.remaining == 0) return null;
            self.active = true;
            var state = self.next_value._cursor.child(self, self.remaining);

            if (mode == .read and termination == .high_bit) state.first_mask = 127;
            return .{ ._cursor = state, ._context = self.child_context };
        }

        pub fn advance(self: *@This(), completed: Entry.Done) Error!void {
            if (!self.active) return error.InvalidCompletion;

            const start = self.next_value._cursor.rest;
            if (termination != .counted and completed._cursor.rest.len >= start.len) return error.InvalidCompletion;
            if (mode == .write and termination != .counted) {
                if (termination == .sentinel and start[0] == termination.sentinel) return error.InvalidTag;
                if (termination == .high_bit and start[0] >= 128) return error.InvalidTag;
            }

            try self.next_value._cursor.accept(completed._cursor, self, self.remaining);
            self.remaining -= 1;
            if (termination == .high_bit) {
                if (mode == .write) {
                    if (self.remaining != 0) start[0] |= 128;
                } else if (start[0] < 128) self.remaining = 0 else if (self.remaining == 0) return error.CollectionTooLarge;
            }

            self.active = false;
        }

        pub fn element(self: @This(), value: Entry.Value) Error!@This() {
            if (mode != .write) @compileError("element writes an output sequence; read with next/advance");
            var result = self;
            const entry = (try result.next()) orelse return error.TooManyItems;
            try result.advance(try if (Entry.Value == void) entry.value() else entry.value(value));
            return result;
        }

        pub fn finish(self: @This()) Error!Next {
            if (self.active or self.remaining != 0) return error.MissingItems;

            var result = self.next_value;
            if (termination == .sentinel) {
                if (mode == .write) result._cursor.rest = try wire.write_u8(result._cursor.rest, termination.sentinel) else {
                    if (result._cursor.rest.len == 0) return error.EndOfStream;
                    if (result._cursor.rest[0] != termination.sentinel) return error.InvalidTag;
                    result._cursor.rest = result._cursor.rest[1..];
                }
            }

            return result;
        }

        pub fn encoded(self: *@This()) Error!struct { []const u8, Next } {
            if (mode != .read) @compileError("encoded reads a borrowed encoded sequence");

            while (try self.next()) |entry| try self.advance(try entry.scan());
            const result = try self.finish();
            return .{ result._cursor.buffer[self.start .. result._cursor.buffer.len - result._cursor.rest.len], result };
        }
    };
}

pub fn count(value: i128) Error!usize {
    if (value < 0) return error.NegativeLength;
    if (value > wire.maximum_sequence_elements) return error.CollectionTooLarge;
    return @intCast(value);
}

pub fn select(value: i128, shift: u7, bits: u7, signed: bool) i128 {
    std.debug.assert(bits > 0 and bits <= 64);
    const mask = (@as(i128, 1) << bits) - 1;
    const result = (value >> shift) & mask;
    return if (signed and result & (@as(i128, 1) << (bits - 1)) != 0) result - (@as(i128, 1) << bits) else result;
}
