const std = @import("std");
const c = @import("cursor.zig");
const wire = @import("support.zig");

pub const none = std.math.maxInt(u32);

pub const Variable = struct {
    id: u32,
    value: i128,
};

pub const Selector = struct {
    field: u32,
    shift: u7 = 0,
    bits: u7 = 64,
    signed: bool = true,
};

pub const Count = union(enum) {
    fixed: usize,
    read: *const fn ([]const u8) c.Error!struct { i128, []const u8 },
    field: Selector,
    sentinel: u8,
    high_bit,
};

pub const Field = struct {
    node: u32,
    capture: u32 = none,
};

pub const Branch = struct {
    value: i128,
    node: u32,
};

pub const Node = union(enum) {
    invalid,
    scalar: struct {
        read: *const fn ([]const u8, usize, u8) c.Error!struct { []const u8, i128 },
        count: Count,
    },
    container: []const Field,
    array: struct {
        child: u32,
        count: Count,
    },
    optional: u32,
    choice: struct {
        selector: Selector,
        branches: []const Branch,
        fallback: u32,
    },
    holder: u32,
    holder_set: struct {
        base: u32,
        child: u32,
    },
};

/// Validate an explicitly requested encoded value. No implicit pre-scan backs typed cursors.
pub fn run(nodes: []const Node, root: u32, input: []const u8, initial: []const Variable, first_mask: u8) c.Error!struct { []const u8, i128 } {
    const Frame = struct {
        node: u32,
        index: usize = 0,
        remaining: usize = 0,
        base: usize,
        capture: u32 = none,
        started: bool = false,
        last: bool = false,
    };
    var frames: [128]Frame = undefined;
    var variables: [256]Variable = undefined;
    if (initial.len > variables.len) return error.DepthLimit;
    @memcpy(variables[0..initial.len], initial);
    var variable_count = initial.len;
    frames[0] = .{ .node = root, .base = variable_count };
    var depth: usize = 1;
    var rest = input;
    var value: i128 = 0;
    var mask = first_mask;

    while (depth != 0) {
        const frame = &frames[depth - 1];
        std.debug.assert(frame.node < nodes.len);
        const node = nodes[frame.node];
        var child: ?Field = null;
        var complete = false;

        switch (node) {
            .invalid => unreachable,
            .scalar => |scalar| {
                const length = if (scalar.count == .field) try wire.count_to_usize(try lookup(variables[0..variable_count], scalar.count.field)) else 0;
                rest, value = try scalar.read(rest, length, mask);
                mask = 255;
                complete = true;
            },
            .container => |fields| {
                complete = frame.index == fields.len;

                if (!complete) {
                    child = fields[frame.index];
                    frame.index += 1;
                }
            },
            .array => |sequence| {
                if (!frame.started) {
                    frame.started = true;

                    switch (sequence.count) {
                        .fixed => |n| frame.remaining = try c.count(n),
                        .field => |selector| frame.remaining = try c.count(try lookup(variables[0..variable_count], selector)),
                        .read => |read| {
                            const n, const tail = try read(rest);
                            rest = tail;
                            frame.remaining = try c.count(n);
                        },
                        .sentinel, .high_bit => frame.remaining = wire.maximum_sequence_elements,
                    }
                }

                complete = frame.remaining == 0 or frame.last;
                if (sequence.count == .sentinel and !frame.last) {
                    if (rest.len == 0) return error.EndOfStream;
                    complete = rest[0] == sequence.count.sentinel;

                    if (complete) rest = rest[1..];
                }

                if (!complete) {
                    if (frame.remaining == 0) return error.CollectionTooLarge;
                    frame.remaining -= 1;
                    if (sequence.count == .high_bit) {
                        if (rest.len == 0) return error.EndOfStream;
                        frame.last = rest[0] < 128;
                        mask = 127;
                        if (!frame.last and frame.remaining == 0) return error.CollectionTooLarge;
                    }

                    child = .{ .node = sequence.child };
                }
            },
            .optional => |entry| {
                complete = frame.started;

                if (!complete) {
                    frame.started = true;
                    const present, const tail = try wire.read_bool(rest);
                    rest = tail;

                    if (present) child = .{ .node = entry } else {
                        value = -1;
                        complete = true;
                    }
                }
            },
            .choice => |choice| {
                complete = frame.started;
                if (!complete) {
                    frame.started = true;
                    const selected = try lookup(variables[0..variable_count], choice.selector);
                    child = .{ .node = choice.fallback };

                    for (choice.branches) |branch| if (branch.value == selected) {
                        child.?.node = branch.node;
                        break;
                    };

                    if (child.?.node == none) return error.InvalidTag;
                }
            },
            .holder => |entry| {
                complete = frame.started;
                if (!complete) {
                    frame.started = true;
                    const id, const tail = try wire.read_varint(rest);
                    rest = tail;
                    if (id < 0) return error.InvalidTag;

                    if (id == 0) child = .{ .node = entry } else {
                        value = id;
                        complete = true;
                    }
                }
            },
            .holder_set => |set| {
                if (!frame.started) {
                    frame.started = true;
                    const count, const tail = try wire.read_varint(rest);
                    rest = tail;
                    if (count < 0) return error.NegativeLength;
                    frame.last = count == 0;
                    frame.remaining = if (count == 0) 1 else try c.count(count - 1);
                }

                complete = frame.remaining == 0;

                if (!complete) {
                    frame.remaining -= 1;
                    child = .{ .node = if (frame.last) set.base else set.child };
                }
            },
        }

        if (complete) {
            variable_count = frame.base;
            if (frame.capture != none) {
                if (variable_count == variables.len) return error.DepthLimit;
                variables[variable_count] = .{ .id = frame.capture, .value = value };
                variable_count += 1;
            }

            depth -= 1;
        } else if (child) |entry| {
            if (depth == frames.len) return error.DepthLimit;
            frames[depth] = .{ .node = entry.node, .base = variable_count, .capture = entry.capture };
            depth += 1;
        } else unreachable;
    }

    return .{ rest, value };
}

fn lookup(values: []const Variable, selector: Selector) c.Error!i128 {
    var i = values.len;

    while (i != 0) {
        i -= 1;
        if (values[i].id == selector.field) return c.select(values[i].value, selector.shift, selector.bits, selector.signed);
    }

    return error.InvalidTag;
}
