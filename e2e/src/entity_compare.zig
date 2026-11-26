//! Proves a client's entities against the server's: between exact states, a client computes
//! each entity's next tick itself, so it must hold what the server held, bit for bit.
//!
//! The server's trace has a line per traced entity per tick, after the tick:
//!     <tick> <id> <x> <y> <z> <dx> <dy> <dz> <on_ground>
//! A client's has a line per entity at the end of each of its ticks, and one after each entity
//! packet it handled, with the entity's state then:
//!     t <tick> <id> <x> <y> <z> <dx> <dy> <dz> <on_ground>
//!     p <tick> <kind> <id> <x> <y> <z> <dx> <dy> <dz> <on_ground>
//!     r <tick> <id>
//! Doubles are their raw bits in hex. A packet's tick is the client's ticks done when it was
//! handled, so the next tick is the first it shows in.
//!
//! An exact state, a teleport, anchors the entity to the server tick that held it. From there each
//! of the client's ticks must equal the server's next, until another packet for it comes.
const std = @import("std");

pub const State = struct {
    position: [3]u64,
    velocity: [3]u64,
    on_ground: bool,

    fn eql(a: State, b: State) bool {
        return std.mem.eql(u64, &a.position, &b.position) and std.mem.eql(u64, &a.velocity, &b.velocity) and a.on_ground == b.on_ground;
    }

    /// Where it is and whether on the ground, which a player sees: motion shows only in what follows.
    fn seen(a: State, b: State) bool {
        return std.mem.eql(u64, &a.position, &b.position) and a.on_ground == b.on_ground;
    }

    fn float(bits: u64) f64 {
        return @bitCast(bits);
    }

    pub fn format(self: State, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("pos ({d}, {d}, {d}) vel ({d}, {d}, {d}) ground {}", .{ float(self.position[0]), float(self.position[1]), float(self.position[2]), float(self.velocity[0]), float(self.velocity[1]), float(self.velocity[2]), self.on_ground });
    }
};

pub const Divergence = struct {
    id: i32,
    /// The server tick the client should have matched, and how many ticks after its anchor.
    server_tick: u64,
    after: u64,
    client: State,
    server: State,
    /// The server tick its motion first differed on, where that came before its place did.
    moved_apart: ?u64 = null,
};

pub const Report = struct {
    anchors: u64 = 0,
    /// Anchors no server tick held: the server sent a state it never had.
    unmatched: u64 = 0,
    /// Client ticks compared, and those that matched.
    compared: u64 = 0,
    /// Stretches where a client strayed, with no exact state from then or before to excuse it.
    strayed: u64 = 0,
    /// Stretches whose motion differed but never where the entity was, until the next exact state.
    latent: u64 = 0,
    divergences: std.ArrayList(Divergence) = .empty,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.divergences.deinit(allocator);
    }
};

const Timed = struct { tick: u64, state: State };

/// Each entity's states in the server's trace, by tick.
pub const Server = struct {
    by_id: std.AutoHashMapUnmanaged(i32, std.ArrayList(Timed)) = .empty,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Server {
        var self: Server = .{};
        errdefer self.deinit(allocator);
        var lines = std.mem.tokenizeScalar(u8, finished(text), '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const tick = try std.fmt.parseInt(u64, fields.next() orelse return error.Corrupt, 10);
            const id = try std.fmt.parseInt(i32, fields.next() orelse return error.Corrupt, 10);
            const state = try parseState(&fields);
            const entry = try self.by_id.getOrPut(allocator, id);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            const list = entry.value_ptr;
            if (list.items.len > 0 and list.items[list.items.len - 1].tick >= tick) return error.Corrupt;
            try list.append(allocator, .{ .tick = tick, .state = state });
        }
        return self;
    }

    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        var iterator = self.by_id.valueIterator();
        while (iterator.next()) |list| list.deinit(allocator);
        self.by_id.deinit(allocator);
    }

    /// The last tick that traced an entity.
    fn last(self: *const Server, id: i32) u64 {
        const list = self.by_id.get(id) orelse return 0;
        return if (list.items.len == 0) 0 else list.items[list.items.len - 1].tick;
    }

    fn at(self: *const Server, id: i32, tick: u64) ?State {
        const list = self.by_id.get(id) orelse return null;
        const index = std.sort.binarySearch(Timed, list.items, tick, struct {
            fn order(wanted: u64, item: Timed) std.math.Order {
                return std.math.order(wanted, item.tick);
            }
        }.order) orelse return null;
        return list.items[index].state;
    }

    /// The tick that held a state nearest `near`: a resting entity holds one for many.
    fn holding(self: *const Server, id: i32, state: State, near: ?i64) ?u64 {
        const list = self.by_id.get(id) orelse return null;
        var best: ?u64 = null;
        for (list.items) |item| {
            if (!item.state.eql(state)) continue;
            const guess = near orelse return item.tick;
            if (best == null or @abs(@as(i64, @intCast(item.tick)) - guess) < @abs(@as(i64, @intCast(best.?)) - guess)) best = item.tick;
        }
        return best;
    }
};

/// A trace up to its last whole line: one stopped while writing leaves the last unfinished.
fn finished(text: []const u8) []const u8 {
    return text[0 .. if (std.mem.lastIndexOfScalar(u8, text, '\n')) |end| end + 1 else 0];
}

fn parseState(fields: *std.mem.TokenIterator(u8, .scalar)) !State {
    var bits: [6]u64 = undefined;
    for (&bits) |*value| value.* = try std.fmt.parseInt(u64, fields.next() orelse return error.Corrupt, 16);
    const ground = fields.next() orelse return error.Corrupt;
    if (ground.len != 1 or (ground[0] != '0' and ground[0] != '1')) return error.Corrupt;
    return .{ .position = bits[0..3].*, .velocity = bits[3..6].*, .on_ground = ground[0] == '1' };
}

const Record = union(enum) {
    tick: struct { tick: u64, id: i32, state: State },
    packet: struct { tick: u64, exact: bool, id: i32, state: State },
    removed: struct { tick: u64, id: i32 },
};

fn parseClient(line: []const u8) !Record {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const tag = fields.next() orelse return error.Corrupt;
    const tick = try std.fmt.parseInt(u64, fields.next() orelse return error.Corrupt, 10);
    if (std.mem.eql(u8, tag, "t")) {
        const id = try std.fmt.parseInt(i32, fields.next() orelse return error.Corrupt, 10);
        return .{ .tick = .{ .tick = tick, .id = id, .state = try parseState(&fields) } };
    }
    if (std.mem.eql(u8, tag, "p")) {
        const kind = fields.next() orelse return error.Corrupt;
        const id = try std.fmt.parseInt(i32, fields.next() orelse return error.Corrupt, 10);
        return .{ .packet = .{ .tick = tick, .exact = std.mem.eql(u8, kind, "teleport"), .id = id, .state = try parseState(&fields) } };
    }
    if (std.mem.eql(u8, tag, "r")) return .{ .removed = .{ .tick = tick, .id = try std.fmt.parseInt(i32, fields.next() orelse return error.Corrupt, 10) } };
    return error.Corrupt;
}

/// Where an entity's client stands: anchored to a server tick since a client tick. Where it first
/// strayed waits on the next exact state: if that is what the server held on the tick it strayed,
/// the server sent that very tick, knowing the client could not compute it. Any other, and the
/// client was wrong until it came.
const Stretch = struct { client_tick: u64, server_tick: u64, broken: bool = false, strayed: ?Divergence = null, moved_apart: ?u64 = null };

/// Ticks of the server's trace after a client strayed, for the exact state that would have put
/// it right to reach it, before its straying counts.
const settle_ticks = 40;

/// Compares a client's trace with the server's. The server's clock runs ahead of the client's by
/// about the same each tick: the first anchor measures it, and it picks among the ticks a resting
/// entity held still.
pub fn compare(allocator: std.mem.Allocator, server: *const Server, client: []const u8, limit: usize) !Report {
    var report: Report = .{};
    errdefer report.deinit(allocator);
    var stretches: std.AutoHashMapUnmanaged(i32, Stretch) = .empty;
    defer stretches.deinit(allocator);
    var offset: ?i64 = null;
    var lines = std.mem.tokenizeScalar(u8, finished(client), '\n');
    while (lines.next()) |line| switch (try parseClient(line)) {
        .packet => |packet| {
            const previous = stretches.fetchRemove(packet.id);
            if (!packet.exact) {
                if (previous) |entry| try settle(allocator, &report, entry.value, null, limit);
                continue;
            }
            report.anchors += 1;
            const near: ?i64 = if (offset) |value| @as(i64, @intCast(packet.tick)) + value else null;
            const server_tick = server.holding(packet.id, packet.state, near);
            if (previous) |entry| try settle(allocator, &report, entry.value, packet.state, limit);
            const anchored = server_tick orelse {
                report.unmatched += 1;
                continue;
            };
            if (offset == null) offset = @as(i64, @intCast(anchored)) - @as(i64, @intCast(packet.tick));
            try stretches.put(allocator, packet.id, .{ .client_tick = packet.tick, .server_tick = anchored });
        },
        .removed => |removed| if (stretches.fetchRemove(removed.id)) |entry| try settle(allocator, &report, entry.value, null, limit),
        .tick => |seen| {
            const stretch = stretches.getPtr(seen.id) orelse continue;
            if (stretch.broken or seen.tick <= stretch.client_tick) continue;
            const after = seen.tick - stretch.client_tick;
            const expected = server.at(seen.id, stretch.server_tick + after) orelse {
                // The server stopped tracing it: nothing left to hold it to.
                stretch.broken = true;
                continue;
            };
            report.compared += 1;
            if (seen.state.eql(expected)) continue;
            // Motion apart in the same place: the next ticks show whether it ever comes to anything.
            if (seen.state.seen(expected)) {
                if (stretch.moved_apart == null) stretch.moved_apart = stretch.server_tick + after;
                continue;
            }
            stretch.broken = true;
            stretch.strayed = .{ .id = seen.id, .server_tick = stretch.server_tick + after, .after = after, .client = seen.state, .server = expected, .moved_apart = stretch.moved_apart };
        },
    };
    // Those still waiting count once the server traced long enough after for a correction to come.
    var waiting = stretches.valueIterator();
    while (waiting.next()) |stretch| {
        if (stretch.strayed) |strayed| if (server.last(strayed.id) < strayed.server_tick + settle_ticks) continue;
        try settle(allocator, &report, stretch.*, null, limit);
    }
    return report;
}

/// A stretch, ended by the next exact state, `corrected`, or by something else: where it strayed
/// counts unless that state excuses it, and motion apart that never showed is noted.
fn settle(allocator: std.mem.Allocator, report: *Report, stretch: Stretch, corrected: ?State, limit: usize) !void {
    const divergence = stretch.strayed orelse {
        if (stretch.moved_apart != null) report.latent += 1;
        return;
    };
    if (corrected) |state| if (state.eql(divergence.server)) return;
    if (report.divergences.items.len < limit) try report.divergences.append(allocator, divergence);
    report.strayed += 1;
}

fn traced(buffer: []u8, comptime prefix: []const u8, tick: u64, id: i32, state: [7]f64) []const u8 {
    var bits: [7]u64 = undefined;
    for (state[0..6], bits[0..6]) |value, *out| out.* = @bitCast(value);
    return std.fmt.bufPrint(buffer, prefix ++ "{d} {d} {x} {x} {x} {x} {x} {x} {d}\n", .{ tick, id, bits[0], bits[1], bits[2], bits[3], bits[4], bits[5], @as(u8, @intFromFloat(state[6])) }) catch unreachable;
}

/// An item falling: sent exactly at tick 10, then 11, 12 and 13 as the server had them, and the
/// server traced on past them, at rest.
const falling = [_][7]f64{ .{ 0, 70, 0, 0, -0.04, 0, 0 }, .{ 0, 69.96, 0, 0, -0.0792, 0, 0 }, .{ 0, 69.88, 0, 0, -0.1176, 0, 0 }, .{ 0, 69.76, 0, 0, 0, 0, 1 } };

fn serverFalling(allocator: std.mem.Allocator) !Server {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var buffer: [256]u8 = undefined;
    for (falling, 10..) |state, tick| try text.appendSlice(allocator, traced(&buffer, "", tick, 5, state));
    for (14..80) |tick| try text.appendSlice(allocator, traced(&buffer, "", tick, 5, falling[3]));
    return Server.parse(allocator, text.items);
}

fn anchor(allocator: std.mem.Allocator, client: *std.ArrayList(u8), tick: u64, state: [7]f64) !void {
    var buffer: [256]u8 = undefined;
    const written = traced(&buffer, "", tick, 5, state);
    try client.print(allocator, "p {d} teleport ", .{tick});
    // Past the tick and id: the id and the state.
    const after_tick = std.mem.indexOfScalar(u8, written, ' ').? + 1;
    try client.appendSlice(allocator, written[after_tick..]);
}

test "a client that steps as the server does matches from its anchor on, and one that strays is caught where it strays" {
    const allocator = std.testing.allocator;
    var server = try serverFalling(allocator);
    defer server.deinit(allocator);
    var client: std.ArrayList(u8) = .empty;
    defer client.deinit(allocator);
    var buffer: [256]u8 = undefined;
    // Handled with 100 ticks done: ticks 101 and 102 match 11 and 12, 103 lands where 13 did not,
    // and nothing exact came after to excuse it.
    try anchor(allocator, &client, 100, falling[0]);
    try client.appendSlice(allocator, traced(&buffer, "t ", 101, 5, falling[1]));
    try client.appendSlice(allocator, traced(&buffer, "t ", 102, 5, falling[2]));
    try client.appendSlice(allocator, traced(&buffer, "t ", 103, 5, .{ 0, 69.76, 0, 0, -0.155, 0, 0 }));
    try client.appendSlice(allocator, traced(&buffer, "t ", 104, 5, falling[3]));
    var report = try compare(allocator, &server, client.items, 8);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), report.anchors);
    try std.testing.expectEqual(@as(u64, 0), report.unmatched);
    try std.testing.expectEqual(@as(u64, 3), report.compared);
    try std.testing.expectEqual(@as(u64, 1), report.strayed);
    try std.testing.expectEqual(@as(u64, 13), report.divergences.items[0].server_tick);
    try std.testing.expectEqual(@as(u64, 3), report.divergences.items[0].after);
}

test "a client that strays on the tick the server sent exactly was put right, not wrong" {
    const allocator = std.testing.allocator;
    var server = try serverFalling(allocator);
    defer server.deinit(allocator);
    var client: std.ArrayList(u8) = .empty;
    defer client.deinit(allocator);
    var buffer: [256]u8 = undefined;
    // It lands its own way on tick 13, which the server sent exactly and it handled after.
    try anchor(allocator, &client, 100, falling[0]);
    try client.appendSlice(allocator, traced(&buffer, "t ", 101, 5, falling[1]));
    try client.appendSlice(allocator, traced(&buffer, "t ", 102, 5, falling[2]));
    try client.appendSlice(allocator, traced(&buffer, "t ", 103, 5, .{ 0, 69.76, 0, 0, -0.155, 0, 0 }));
    try anchor(allocator, &client, 104, falling[3]);
    try client.appendSlice(allocator, traced(&buffer, "t ", 105, 5, falling[3]));
    var report = try compare(allocator, &server, client.items, 8);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), report.anchors);
    try std.testing.expectEqual(@as(u64, 0), report.strayed);
    try std.testing.expectEqual(@as(u64, 4), report.compared);
}

test "a client corrected only on its next turn was wrong until then" {
    const allocator = std.testing.allocator;
    var server = try serverFalling(allocator);
    defer server.deinit(allocator);
    var client: std.ArrayList(u8) = .empty;
    defer client.deinit(allocator);
    var buffer: [256]u8 = undefined;
    // It strays on tick 12, and the exact state that puts it right is tick 13's.
    try anchor(allocator, &client, 100, falling[0]);
    try client.appendSlice(allocator, traced(&buffer, "t ", 101, 5, falling[1]));
    try client.appendSlice(allocator, traced(&buffer, "t ", 102, 5, .{ 0, 69.87, 0, 0, -0.1, 0, 0 }));
    try anchor(allocator, &client, 103, falling[3]);
    var report = try compare(allocator, &server, client.items, 8);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), report.strayed);
    try std.testing.expectEqual(@as(u64, 12), report.divergences.items[0].server_tick);
}
