const std = @import("std");
const endpoint = @import("endpoint.zig");

fn Wire(comptime initial: u8) type {
    return struct {
        pub const encryption_batch_size = if (initial == 10) 4 else 1;
        pub const Encryption = struct { value: *u8, first: []u8, second: []u8 };

        pub fn encryptBatch(source: []const u8, targets: []const Encryption) void {
            std.debug.assert(targets.len <= encryption_batch_size);
            for (targets) |target| {
                std.debug.assert(target.first.len + target.second.len == source.len);
                var offset: usize = 0;
                for ([_][]u8{ target.first, target.second }) |destination| {
                    for (destination) |*byte| {
                        byte.* = source[offset] ^ target.value.*;
                        target.value.* += 1;
                        offset += 1;
                    }
                }
            }
        }

        pub const Workspace = struct {
            allocator: std.mem.Allocator,
            value: *u8,

            pub fn init(allocator: std.mem.Allocator) !@This() {
                const value = try allocator.create(u8);
                value.* = initial;
                return .{ .allocator = allocator, .value = value };
            }

            pub fn deinit(self: *@This()) void {
                self.allocator.destroy(self.value);
            }
        };

        pub fn shared(workspace: *Workspace, _: []u8, _: usize, _: ?usize, destination: []u8) ![]const u8 {
            workspace.value.* += 1;
            destination[0] = workspace.value.*;
            return destination[0..1];
        }
    };
}

fn Implementation(comptime number: i32, comptime WireType: type) type {
    return struct {
        pub const protocol_number = number;
        pub const Connection = struct {
            pub const Wire = WireType;
            value: u8,

            pub fn encryption(self: *@This(), first: []u8, second: []u8) WireType.Encryption {
                return .{ .value = &self.value, .first = first, .second = second };
            }
        };
    };
}

const Selected = endpoint.Endpoint(.{ Implementation(1, Wire(10)), Implementation(2, Wire(10)), Implementation(3, Wire(20)) }, struct {}, struct {});

test "endpoint encryption respects distinct wire batch widths and recipient stream state" {
    try std.testing.expectEqual(@as(usize, 4), Selected.maximum_encryption_batch_size);
    inline for (.{ 1, 2, 3 }) |number| {
        var connections: [4]Selected.Connection = undefined;
        var bytes: [4][3]u8 = undefined;
        var jobs: [4]Selected.Encryption = undefined;
        for (&connections, &bytes, &jobs, 0..) |*connection, *output, *job, index| {
            connection.* = @unionInit(Selected.Connection, std.fmt.comptimePrint("{d}", .{number}), .{ .value = @intCast(index * 4) });
            job.* = .{ .connection = connection, .first = output[0..1], .second = output[1..] };
        }
        const width = Selected.encryptionBatchSize(number);
        try std.testing.expectEqual(@as(usize, if (number == 3) 1 else 4), width);
        var begin: usize = 0;
        while (begin < jobs.len) {
            const end = @min(jobs.len, begin + width);
            Selected.encryptBatch(number, &.{ 1, 2, 3 }, jobs[begin..end]);
            begin = end;
        }
        for (connections, bytes, 0..) |connection, output, index| {
            for (output, 0..) |actual, offset| try std.testing.expectEqual(@as(u8, @intCast(offset + 1)) ^ @as(u8, @intCast(index * 4 + offset)), actual);
            try std.testing.expectEqual(index * 4 + 3, @field(connection, std.fmt.comptimePrint("{d}", .{number})).value);
        }
    }
}

test "protocol versions reuse their workspace while distinct codecs remain independent" {
    var workspaces = try Selected.initWorkspaces(std.testing.allocator);
    defer Selected.deinitWorkspaces(&workspaces);
    var output: [1]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{11}, try Selected.sharedFrame(1, &workspaces, &.{}, 0, null, &output));
    try std.testing.expectEqualSlices(u8, &.{12}, try Selected.sharedFrame(2, &workspaces, &.{}, 0, null, &output));
    try std.testing.expectEqualSlices(u8, &.{21}, try Selected.sharedFrame(3, &workspaces, &.{}, 0, null, &output));
    try std.testing.expectEqualSlices(u8, &.{13}, try Selected.sharedFrame(1, &workspaces, &.{}, 0, null, &output));
}

fn initialize(allocator: std.mem.Allocator) !void {
    var workspaces = try Selected.initWorkspaces(allocator);
    defer Selected.deinitWorkspaces(&workspaces);
}

test "workspace initialization releases prior allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initialize, .{});
}
