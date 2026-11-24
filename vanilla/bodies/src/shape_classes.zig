//! Collision shapes grouped by the space they cover, as Shapes.joinIsNotEmpty with NOT_SAME
//! compares them. Two states share a class when their collision shapes with no entity cover the
//! same space at every position, which is when ServerLevel.sendBlockUpdated leaves paths alone.

const std = @import("std");
const game_data = @import("game_data");
const body = @import("body.zig");

const physics = game_data.physics;
const Boxes = physics.Boxes;
const assert = std.debug.assert;

/// The class of every state without a collision shape.
pub const empty: u16 = 0;

/// The most boxes one shape holds, which bounds the grid two shapes are compared on.
const boxes_max = 32;

/// Fills each state's class. Startup only: it compares shapes that share bounds cell by cell.
pub fn classify(allocator: std.mem.Allocator, classes: []u16) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    // Distinct box lists by where they start in the box table, to a geometric shape.
    var shape_of_list: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    // Shapes by their bounds, each bucket a chain of representatives.
    var buckets: std.AutoHashMapUnmanaged([6]u64, u32) = .empty;
    var representatives: std.ArrayList(struct { boxes: Boxes, next: ?u32 }) = .empty;
    // A state's class is its shape and how that shape moves with position.
    var class_of_key: std.AutoHashMapUnmanaged(struct { shape: u32, horizontal: u32, vertical: u32 }, u16) = .empty;
    var class_count: u32 = 1;
    for (classes, 0..) |*class, index| {
        const state: u16 = @intCast(index);
        var boxes = body.contextFreeBoxes(state, 0, 0);
        boxes.translation = @splat(0);
        if (boxes.count == 0) {
            class.* = empty;
            continue;
        }
        if (boxes.count > boxes_max) return error.ShapeTooComplex;
        const list = try shape_of_list.getOrPut(scratch, boxes.offset);
        if (!list.found_existing) {
            const bucket = try buckets.getOrPut(scratch, boundsKey(boxes));
            var found: ?u32 = null;
            var at: ?u32 = if (bucket.found_existing) bucket.value_ptr.* else null;
            while (at) |candidate| : (at = representatives.items[candidate].next) {
                if (sameSpace(representatives.items[candidate].boxes, boxes)) {
                    found = candidate;
                    break;
                }
            }
            list.value_ptr.* = found orelse made: {
                const shape: u32 = @intCast(representatives.items.len);
                try representatives.append(scratch, .{ .boxes = boxes, .next = if (bucket.found_existing) bucket.value_ptr.* else null });
                bucket.value_ptr.* = shape;
                break :made shape;
            };
        }
        const limits = physics.offsetLimits(state);
        const key = try class_of_key.getOrPut(scratch, .{ .shape = list.value_ptr.*, .horizontal = @bitCast(limits[0]), .vertical = @bitCast(limits[1]) });
        if (!key.found_existing) {
            if (class_count > std.math.maxInt(u16)) return error.TooManyShapeClasses;
            key.value_ptr.* = @intCast(class_count);
            class_count += 1;
        }
        class.* = key.value_ptr.*;
    }
}

fn boundsKey(boxes: Boxes) [6]u64 {
    var bounds: [6]f64 = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (0..boxes.count) |index| {
        const box = boxes.get(index);
        for (0..3) |axis| {
            bounds[axis] = @min(bounds[axis], box[axis]);
            bounds[axis + 3] = @max(bounds[axis + 3], box[axis + 3]);
        }
    }
    var key: [6]u64 = undefined;
    for (bounds, &key) |value, *bits| bits.* = @bitCast(value);
    return key;
}

/// Whether two box lists cover the same space: on the grid of every coordinate either names,
/// each cell is inside both or neither.
fn sameSpace(a: Boxes, b: Boxes) bool {
    assert(a.count <= boxes_max and b.count <= boxes_max);
    if (a.offset == b.offset and a.count == b.count) return true;
    var grid: [3][4 * boxes_max]f64 = undefined;
    var lengths: [3]usize = .{ 0, 0, 0 };
    for (0..3) |axis| {
        for ([_]Boxes{ a, b }) |boxes| for (0..boxes.count) |index| {
            const box = boxes.get(index);
            grid[axis][lengths[axis]] = box[axis];
            grid[axis][lengths[axis] + 1] = box[axis + 3];
            lengths[axis] += 2;
        };
        const values = grid[axis][0..lengths[axis]];
        std.sort.insertion(f64, values, {}, std.sort.asc(f64));
        var unique: usize = 0;
        for (values) |value| {
            if (unique > 0 and values[unique - 1] == value) continue;
            values[unique] = value;
            unique += 1;
        }
        lengths[axis] = unique;
    }
    for (0..lengths[0] - 1) |i| for (0..lengths[1] - 1) |j| for (0..lengths[2] - 1) |k| {
        const middle: [3]f64 = .{ (grid[0][i] + grid[0][i + 1]) / 2, (grid[1][j] + grid[1][j + 1]) / 2, (grid[2][k] + grid[2][k + 1]) / 2 };
        if (covers(a, middle) != covers(b, middle)) return false;
    };
    return true;
}

fn covers(boxes: Boxes, point: [3]f64) bool {
    for (0..boxes.count) |index| {
        const box = boxes.get(index);
        if (point[0] > box[0] and point[0] < box[3] and point[1] > box[1] and point[1] < box[4] and point[2] > box[2] and point[2] < box[5]) return true;
    }
    return false;
}
