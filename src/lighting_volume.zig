const std = @import("std");
const config = @import("config.zig").value;
const light_projection = @import("light_projection.zig");

pub const side = 16;
pub const height = config.overworld_section_count * side;
pub const cell_count = side * side * height;
pub const word_count = cell_count / 64;
pub const direction_count = 6;
pub const face_word_count = 4;
pub const FaceMask = [face_word_count]u64;
pub const FaceOcclusion = [direction_count]FaceMask;

pub const Direction = enum(u3) {
    negative_x,
    positive_x,
    negative_y,
    positive_y,
    negative_z,
    positive_z,
};

pub const Topology = struct {
    attenuation_masks: [15][word_count]u64 = @splat(@splat(0)),
    edge_open: [direction_count][word_count]u64 = @splat(@splat(0)),
    active_attenuation: [14]u8 = undefined,
    active_attenuation_count: u8 = 0,

    pub fn build(
        attenuation: *const [cell_count]u8,
        block_states: *const [cell_count]i32,
        comptime faceOcclusion: fn (i32) *const FaceOcclusion,
    ) Topology {
        return buildPrepared(
            attenuation,
            block_states,
            0,
            faceOcclusion,
        );
    }

    /// Build topology while skipping sections which are known to be uniform.
    /// A prepared section must either have empty occlusion faces or attenuate
    /// light completely. Both cases have no per-cell edges to classify.
    pub fn buildPrepared(
        attenuation: *const [cell_count]u8,
        block_states: *const [cell_count]i32,
        uniform_sections: u32,
        comptime faceOcclusion: fn (i32) *const FaceOcclusion,
    ) Topology {
        var result: Topology = .{};
        result.edge_open = @splat(@splat(std.math.maxInt(u64)));
        var present: u16 = 0;
        clearVolumeEdges(&result);

        const cells_per_section = side * side * side;
        const words_per_section = cells_per_section / 64;
        for (0..config.overworld_section_count) |section| {
            const first_cell = section * cells_per_section;
            if (uniform_sections &
                (@as(u32, 1) << @intCast(section)) != 0)
            {
                const loss = @min(
                    @max(attenuation[first_cell], 1),
                    15,
                );
                if (loss < 15) {
                    const first_word = section * words_per_section;
                    @memset(
                        result.attenuation_masks[loss][first_word..][0..words_per_section],
                        std.math.maxInt(u64),
                    );
                    present |= @as(u16, 1) << @intCast(loss);
                }
                continue;
            }

            for (first_cell..first_cell + cells_per_section) |cell| {
                const bit = @as(u64, 1) << @intCast(cell & 63);
                const word = cell >> 6;
                const loss = @min(@max(attenuation[cell], 1), 15);
                if (loss < 15) {
                    result.attenuation_masks[loss][word] |= bit;
                    present |= @as(u16, 1) << @intCast(loss);
                }

                if (loss == 15) continue;
                const faces = faceOcclusion(block_states[cell]);
                if (allFacesEmpty(faces.*)) continue;
                inline for (std.enums.values(Direction)) |direction| {
                    if (neighborIndex(cell, direction)) |neighbor| {
                        const opposite = oppositeDirection(direction);
                        if (facesSeal(
                            faces[@intFromEnum(opposite)],
                            faceOcclusion(block_states[neighbor])[
                                @intFromEnum(direction)
                            ],
                        ))
                            clearEdge(&result, direction, word, bit);
                    }
                }
            }
        }
        var loss: u8 = 1;
        while (loss < 15) : (loss += 1) {
            if (present & (@as(u16, 1) << @intCast(loss)) == 0) continue;
            result.active_attenuation[result.active_attenuation_count] = loss;
            result.active_attenuation_count += 1;
        }
        return result;
    }
};

fn clearVolumeEdges(topology: *Topology) void {
    const negative_x_mask: u64 = 0x8000_8000_8000_8000;
    const positive_x_mask: u64 = 0x0001_0001_0001_0001;
    for (0..word_count) |word| {
        topology.edge_open[@intFromEnum(Direction.negative_x)][word] &=
            ~negative_x_mask;
        topology.edge_open[@intFromEnum(Direction.positive_x)][word] &=
            ~positive_x_mask;
    }

    for (0..height) |y| {
        const first_word = y * 4;
        topology.edge_open[@intFromEnum(Direction.positive_z)][first_word] &= ~@as(u64, 0x0000_0000_0000_ffff);
        topology.edge_open[@intFromEnum(Direction.negative_z)][first_word + 3] &= ~@as(u64, 0xffff_0000_0000_0000);
    }
    @memset(
        topology.edge_open[@intFromEnum(Direction.positive_y)][0..4],
        0,
    );
    @memset(
        topology.edge_open[@intFromEnum(Direction.negative_y)][word_count - 4 .. word_count],
        0,
    );
}

pub const Result = struct {
    planes: [4][word_count]u64 = @splat(@splat(0)),

    pub inline fn level(self: *const Result, cell: usize) u8 {
        const word = cell >> 6;
        const bit: u6 = @intCast(cell & 63);
        var value: u8 = 0;
        inline for (0..4) |plane|
            value |= @as(u8, @intCast((self.planes[plane][word] >> bit) & 1)) << plane;
        return value;
    }

    pub fn writeSection(
        self: *const Result,
        section: usize,
        output: *[light_projection.bytes_per_section]u8,
    ) void {
        const base = section * side * side * side;
        for (0..output.len) |byte_index| {
            const low = self.level(base + byte_index * 2);
            const high = self.level(base + byte_index * 2 + 1);
            output[byte_index] = low | (high << 4);
        }
    }

    pub fn uniformSection(self: *const Result, section: usize) ?u8 {
        const words_per_section = side * side * side / 64;
        const first = section * words_per_section;
        var value: u8 = 0;
        inline for (0..4) |plane| {
            const first_word = self.planes[plane][first];
            if (first_word != 0 and first_word != std.math.maxInt(u64))
                return null;
            for (self.planes[plane][first..][0..words_per_section]) |word|
                if (word != first_word) return null;
            if (first_word != 0)
                value |= @as(u8, 1) << plane;
        }
        return value;
    }

    pub fn setLevels(
        self: *Result,
        levels: *const [cell_count]u8,
    ) void {
        self.* = .{};
        for (levels, 0..) |value, cell| self.setLevel(cell, value);
    }

    pub inline fn setLevel(
        self: *Result,
        cell: usize,
        value: u8,
    ) void {
        const bit = @as(u64, 1) << @intCast(cell & 63);
        inline for (0..4) |plane| {
            if (value & (@as(u8, 1) << plane) != 0)
                self.planes[plane][cell >> 6] |= bit;
        }
    }
};

pub const Scratch = struct {
    buckets: [16][word_count]u64 = @splat(@splat(0)),
    settled: [word_count]u64 = @splat(0),
    shifted: [word_count]u64 = @splat(0),
    candidates: [word_count]u64 = @splat(0),
    bucket_start: [16]usize = @splat(word_count),
    bucket_end: [16]usize = @splat(0),

    pub fn reset(self: *Scratch) void {
        @memset(std.mem.asBytes(&self.buckets), 0);
        @memset(&self.settled, 0);
        self.bucket_start = @splat(word_count);
        self.bucket_end = @splat(0);
    }
};

pub fn solve(
    topology: *const Topology,
    emission: *const [cell_count]u8,
    scratch: *Scratch,
    result: *Result,
) void {
    scratch.reset();
    result.* = .{};
    for (emission, 0..) |level, cell| {
        const value = @min(level, 15);
        if (value == 0) continue;
        const word = cell >> 6;
        scratch.buckets[value][word] |=
            @as(u64, 1) << @intCast(cell & 63);
        scratch.bucket_start[value] =
            @min(scratch.bucket_start[value], word);
        scratch.bucket_end[value] =
            @max(scratch.bucket_end[value], word + 1);
    }
    propagate(topology, scratch, result, false);
}

pub fn solveWithBaseline(
    topology: *const Topology,
    baseline: *const [cell_count]u8,
    emission: *const [cell_count]u8,
    scratch: *Scratch,
    result: *Result,
) void {
    var baseline_result: Result = .{};
    baseline_result.setLevels(baseline);
    solveWithBaselineResult(
        topology,
        &baseline_result,
        emission,
        scratch,
        result,
    );
}

pub fn solveWithBaselineResult(
    topology: *const Topology,
    baseline: *const Result,
    emission: *const [cell_count]u8,
    scratch: *Scratch,
    result: *Result,
) void {
    scratch.reset();
    result.* = baseline.*;
    for (0..cell_count) |cell| {
        const bit = @as(u64, 1) << @intCast(cell & 63);
        const word = cell >> 6;
        const source = @min(emission[cell], 15);
        if (source != 0) {
            scratch.buckets[source][word] |= bit;
            scratch.bucket_start[source] =
                @min(scratch.bucket_start[source], word);
            scratch.bucket_end[source] =
                @max(scratch.bucket_end[source], word + 1);
        }
    }
    propagate(topology, scratch, result, true);
}

fn propagate(
    topology: *const Topology,
    scratch: *Scratch,
    result: *Result,
    comptime has_baseline: bool,
) void {
    var level: usize = 16;
    while (level > 1) {
        level -= 1;
        const start = scratch.bucket_start[level];
        const end = scratch.bucket_end[level];
        if (start == word_count) continue;
        var frontier: [word_count]u64 = undefined;
        for (start..end) |word| {
            frontier[word] = scratch.buckets[level][word] &
                ~scratch.settled[word];
            scratch.settled[word] |= frontier[word];
        }
        inline for (0..4) |plane| {
            const fill = 0 -% @as(u64, @intFromBool(
                level & (@as(usize, 1) << plane) != 0,
            ));
            for (start..end) |word|
                result.planes[plane][word] =
                    (result.planes[plane][word] & ~frontier[word]) |
                    (frontier[word] & fill);
        }

        const candidate_start = start -| 5;
        const candidate_end = @min(word_count, end + 5);
        @memset(scratch.candidates[candidate_start..candidate_end], 0);
        inline for (std.enums.values(Direction)) |direction| {
            const shifted_range = shiftRange(
                &scratch.shifted,
                &frontier,
                direction,
                start,
                end,
            );
            const open = topology.edge_open[@intFromEnum(direction)];
            for (shifted_range.start..shifted_range.end) |word|
                scratch.candidates[word] |=
                    scratch.shifted[word] & open[word];
        }
        for (topology.active_attenuation[0..topology.active_attenuation_count]) |loss| {
            if (loss >= level) break;
            const target = level - loss;
            for (candidate_start..candidate_end) |word| {
                const baseline_mask = if (has_baseline)
                    levelAtLeast(result, word, @intCast(target))
                else
                    @as(u64, 0);
                const added =
                    scratch.candidates[word] &
                    topology.attenuation_masks[loss][word] &
                    ~scratch.settled[word] &
                    ~baseline_mask;
                scratch.buckets[target][word] |= added;
                if (added != 0) {
                    scratch.bucket_start[target] =
                        @min(scratch.bucket_start[target], word);
                    scratch.bucket_end[target] =
                        @max(scratch.bucket_end[target], word + 1);
                }
            }
        }
    }
}

fn levelAtLeast(
    result: *const Result,
    word: usize,
    threshold: u8,
) u64 {
    var greater: u64 = 0;
    var equal: u64 = std.math.maxInt(u64);
    var plane: usize = 4;
    while (plane != 0) {
        plane -= 1;
        const bits = result.planes[plane][word];
        if (threshold & (@as(u8, 1) << @intCast(plane)) != 0) {
            equal &= bits;
        } else {
            greater |= equal & bits;
            equal &= ~bits;
        }
    }
    return greater | equal;
}

pub inline fn cellIndex(x: usize, y: usize, z: usize) usize {
    return x | (z << 4) | (y << 8);
}

fn oppositeDirection(direction: Direction) Direction {
    return switch (direction) {
        .negative_x => .positive_x,
        .positive_x => .negative_x,
        .negative_y => .positive_y,
        .positive_y => .negative_y,
        .negative_z => .positive_z,
        .positive_z => .negative_z,
    };
}

fn clearEdge(
    topology: *Topology,
    direction: Direction,
    word: usize,
    bit: u64,
) void {
    topology.edge_open[@intFromEnum(direction)][word] &= ~bit;
}

pub fn allFacesEmpty(faces: FaceOcclusion) bool {
    var combined: u64 = 0;
    inline for (faces) |face| {
        inline for (face) |word| combined |= word;
    }
    return combined == 0;
}

pub fn facesSeal(a: FaceMask, b: FaceMask) bool {
    inline for (a, b) |a_word, b_word| {
        if (a_word | b_word != std.math.maxInt(u64)) return false;
    }
    return true;
}

fn neighborIndex(source: usize, direction: Direction) ?usize {
    const x = source & 15;
    const z = (source >> 4) & 15;
    const y = source >> 8;
    return switch (direction) {
        .negative_x => if (x == 15) null else source + 1,
        .positive_x => if (x == 0) null else source - 1,
        .negative_y => if (y + 1 == height) null else source + 256,
        .positive_y => if (y == 0) null else source - 256,
        .negative_z => if (z == 15) null else source + 16,
        .positive_z => if (z == 0) null else source - 16,
    };
}

const WordRange = struct { start: usize, end: usize };

fn shiftRange(
    output: *[word_count]u64,
    input: *const [word_count]u64,
    direction: Direction,
    source_start: usize,
    source_end: usize,
) WordRange {
    const amount: usize = switch (direction) {
        .negative_x, .positive_x => 1,
        .negative_z, .positive_z => 16,
        .negative_y, .positive_y => 256,
    };
    const positive = switch (direction) {
        .positive_x, .positive_y, .positive_z => true,
        else => false,
    };
    const word_offset = amount >> 6;
    const bit_offset: u6 = @intCast(amount & 63);
    const destination_start = source_start -| (word_offset + 1);
    const destination_end =
        @min(word_count, source_end + word_offset + 1);
    @memset(output[destination_start..destination_end], 0);
    if (positive) {
        for (destination_start..destination_end) |destination| {
            if (destination < word_offset) continue;
            const source = destination - word_offset;
            var value: u64 = if (source >= source_start and
                source < source_end)
                input[source] << bit_offset
            else
                0;
            if (bit_offset != 0 and source != 0 and
                source - 1 >= source_start and source - 1 < source_end)
                value |= input[source - 1] >> (0 -% bit_offset);
            output[destination] = value;
        }
    } else {
        for (destination_start..destination_end) |destination| {
            if (destination + word_offset >= word_count) continue;
            const source = destination + word_offset;
            var value: u64 = if (source >= source_start and
                source < source_end)
                input[source] >> bit_offset
            else
                0;
            if (bit_offset != 0 and source + 1 < word_count and
                source + 1 >= source_start and source + 1 < source_end)
                value |= input[source + 1] << (0 -% bit_offset);
            output[destination] = value;
        }
    }
    return .{
        .start = destination_start,
        .end = destination_end,
    };
}

test "chunk volume crosses section boundaries without a queue" {
    var attenuation: [cell_count]u8 = @splat(15);
    var states: [cell_count]i32 = @splat(0);
    var emission: [cell_count]u8 = @splat(0);
    const source = cellIndex(8, 15, 8);
    const above = cellIndex(8, 16, 8);
    attenuation[source] = 1;
    attenuation[above] = 1;
    emission[source] = 15;
    const topology = Topology.build(&attenuation, &states, struct {
        const empty: FaceOcclusion = @splat(@splat(0));
        fn faces(_: i32) *const FaceOcclusion {
            return &empty;
        }
    }.faces);
    var scratch: Scratch = .{};
    var result: Result = .{};
    solve(&topology, &emission, &scratch, &result);
    try std.testing.expectEqual(@as(u8, 15), result.level(source));
    try std.testing.expectEqual(@as(u8, 14), result.level(above));
}

test "indirect light replaces rather than combines direct-light bits" {
    var attenuation: [cell_count]u8 = @splat(15);
    var states: [cell_count]i32 = @splat(0);
    var baseline: [cell_count]u8 = @splat(0);
    var frontier: [cell_count]u8 = @splat(0);
    const source = cellIndex(8, 16, 8);
    const target = cellIndex(9, 16, 8);
    attenuation[source] = 1;
    attenuation[target] = 1;
    baseline[target] = 5;
    frontier[source] = 12;
    const topology = Topology.build(&attenuation, &states, struct {
        const empty: FaceOcclusion = @splat(@splat(0));
        fn faces(_: i32) *const FaceOcclusion {
            return &empty;
        }
    }.faces);
    var baseline_result: Result = .{};
    baseline_result.setLevels(&baseline);
    var scratch: Scratch = .{};
    var result: Result = .{};
    solveWithBaselineResult(
        &topology,
        &baseline_result,
        &frontier,
        &scratch,
        &result,
    );
    try std.testing.expectEqual(@as(u8, 11), result.level(target));
}

test "queue-free volume matches the scalar fixed point" {
    var attenuation: [cell_count]u8 = undefined;
    var states: [cell_count]i32 = @splat(0);
    var emission: [cell_count]u8 = @splat(0);
    var random = std.Random.DefaultPrng.init(0x4c69_6768_7469_6e67);
    for (&attenuation, 0..) |*loss, cell| {
        const sample = random.random().int(u8);
        loss.* = if (sample < 8) 15 else if (sample < 24) 2 else 1;
        if (cell % 997 == 0) emission[cell] = sample & 15;
    }
    const topology = Topology.build(&attenuation, &states, struct {
        const empty: FaceOcclusion = @splat(@splat(0));
        fn faces(_: i32) *const FaceOcclusion {
            return &empty;
        }
    }.faces);
    var scratch: Scratch = .{};
    var result: Result = .{};
    solve(&topology, &emission, &scratch, &result);

    var expected = emission;
    var next: [cell_count]u8 = undefined;
    for (0..15) |_| {
        next = emission;
        for (0..cell_count) |cell| {
            const loss = @min(@max(attenuation[cell], 1), 15);
            inline for (std.enums.values(Direction)) |direction| {
                if (neighborIndex(cell, direction)) |neighbor| {
                    const word = cell >> 6;
                    const bit =
                        @as(u64, 1) << @intCast(cell & 63);
                    if (topology.edge_open[
                        @intFromEnum(direction)
                    ][word] & bit != 0) {
                        next[cell] = @max(
                            next[cell],
                            expected[neighbor] -| loss,
                        );
                    }
                }
            }
        }
        expected = next;
    }
    for (expected, 0..) |level, cell|
        try std.testing.expectEqual(level, result.level(cell));
}
