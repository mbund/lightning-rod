const std = @import("std");
const corpus = @import("corpus.zig");

pub const Pattern = enum { scan, random, walk, multiplayer, revisit, edits, exploration };
pub const Edit = struct { column: u32, section: u8, index: u12, state: u16 };
pub const Step = struct { columns: []const u32, edits: []const Edit, save: bool };
pub const Trace = struct {
    steps: []Step,
    touched: []bool,
    final_edits: std.AutoHashMap(u64, u16),
    hash: [64]u8,
    requests: usize,
    edits: usize,
    players: usize,
    radius: i32,
};

pub fn editKey(edit: Edit) u64 {
    return (@as(u64, edit.column) * corpus.section_count + edit.section) * 4096 + edit.index;
}

pub fn generate(allocator: std.mem.Allocator, source: *const corpus.Corpus, pattern: Pattern, seed: u64, count: usize, radius: i32) !Trace {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const players: usize = switch (pattern) {
        .scan, .random => 0,
        .walk => 1,
        else => 6,
    };
    const steps = try allocator.alloc(Step, count);
    const touched = try allocator.alloc(bool, source.columns.len);
    @memset(touched, pattern != .exploration);
    var final_edits = std.AutoHashMap(u64, u16).init(allocator);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var positions: [6][2]f64 = undefined;
    var previous: [6]?[2]i32 = @splat(null);
    var directions: [6]u2 = undefined;
    var player_origins: [6][2]i32 = undefined;
    var side: i32 = 0;
    while (side < corpus.origin_stride and source.find(side, 0) != null) : (side += 1) {}
    if (side <= radius * 2 + 2) return error.CorpusTooSmall;
    for (0..players) |player| {
        player_origins[player] = corpus.origins[player % corpus.origins.len];
        player_origins[player][0] += @as(i32, @intCast(player * source.copies / players)) * 1024;
        const width: u32 = @intCast(side - radius * 2 - 2);
        positions[player] = .{ @floatFromInt(radius + 1 + @as(i32, @intCast(random.uintLessThan(u32, width)))), @floatFromInt(radius + 1 + @as(i32, @intCast(random.uintLessThan(u32, width)))) };
        directions[player] = random.int(u2);
    }
    var requests_total: usize = 0;
    var edits_total: usize = 0;
    for (steps, 0..) |*step, tick| {
        var requests: std.ArrayList(u32) = .empty;
        var edits: std.ArrayList(Edit) = .empty;
        switch (pattern) {
            .scan => {
                for (0..32) |i| try requests.append(allocator, @intCast((tick * 32 + i) % source.columns.len));
            },
            .random => {
                for (0..32) |_| try requests.append(allocator, random.uintLessThan(u32, @intCast(source.columns.len)));
            },
            else => {
                var order = [_]usize{ 0, 1, 2, 3, 4, 5 };
                random.shuffle(usize, order[0..players]);
                for (order[0..players]) |player| {
                    if (tick % 16 == 0) directions[player] = random.int(u2);
                    // One step is one simulated second at vanilla walking speed.
                    const distance: f64 = 4.317 / 16.0;
                    const axis: usize = directions[player] / 2;
                    positions[player][axis] += if (directions[player] & 1 == 0) distance else -distance;
                    const low: f64 = @floatFromInt(radius);
                    const high: f64 = @floatFromInt(side - radius - 1);
                    if (positions[player][axis] < low or positions[player][axis] > high) {
                        positions[player][axis] = std.math.clamp(positions[player][axis], low, high);
                        directions[player] ^= 1;
                    }
                    var center: [2]i32 = .{ @intFromFloat(positions[player][0]), @intFromFloat(positions[player][1]) };
                    if (pattern == .revisit) {
                        const offset: i32 = if ((tick / 32) % 2 == 0) radius + 1 else side - radius - 2;
                        center = .{ offset, offset };
                    }
                    const origin = player_origins[player];
                    var x = center[0] - radius;
                    while (x <= center[0] + radius) : (x += 1) {
                        var z = center[1] - radius;
                        while (z <= center[1] + radius) : (z += 1) {
                            if (previous[player]) |old| if (@abs(x - old[0]) <= radius and @abs(z - old[1]) <= radius) continue;
                            const id = source.find(x + origin[0], z + origin[1]) orelse return error.TraceOutsideCorpus;
                            try requests.append(allocator, id);
                        }
                    }
                    previous[player] = center;
                    if (pattern == .edits or pattern == .exploration) {
                        const id = source.find(center[0] + origin[0], center[1] + origin[1]) orelse return error.TraceOutsideCorpus;
                        const column = source.columns[id];
                        const section: u8 = @intCast(@divFloor(column.surface_y, 16) - corpus.minimum_y);
                        const index: u12 = @intCast(@mod(column.surface_y, 16) * 256 + 8 * 16 + 8);
                        const bytes = column.sections[section];
                        const before = std.mem.readInt(u16, bytes[if (bytes[0] == 0) 1 else 1 + @as(usize, index) * 2..][0..2], .little);
                        const state: u16 = if (tick % 2 == 0) (if (before == 0) 1 else 0) else before;
                        const edit: Edit = .{ .column = id, .section = section, .index = index, .state = state };
                        try edits.append(allocator, edit);
                        try final_edits.put(editKey(edit), state);
                        touched[id] = true;
                    }
                }
            },
        }
        step.* = .{ .columns = try requests.toOwnedSlice(allocator), .edits = try edits.toOwnedSlice(allocator), .save = (tick + 1) % 32 == 0 };
        var header: [9]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(step.columns.len), .little);
        std.mem.writeInt(u32, header[4..8], @intCast(step.edits.len), .little);
        header[8] = @intFromBool(step.save);
        digest.update(&header);
        for (step.columns) |id| {
            touched[id] = true;
            var encoded: [4]u8 = undefined;
            std.mem.writeInt(u32, &encoded, id, .little);
            digest.update(&encoded);
        }
        for (step.edits) |edit| {
            var encoded: [12]u8 = undefined;
            std.mem.writeInt(u64, encoded[0..8], editKey(edit), .little);
            std.mem.writeInt(u32, encoded[8..12], edit.state, .little);
            digest.update(&encoded);
        }
        requests_total += step.columns.len;
        edits_total += step.edits.len;
    }
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    return .{ .steps = steps, .touched = touched, .final_edits = final_edits, .hash = std.fmt.bytesToHex(hash, .lower), .requests = requests_total, .edits = edits_total, .players = players, .radius = radius };
}
