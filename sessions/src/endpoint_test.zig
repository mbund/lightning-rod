const std = @import("std");
const endpoint = @import("endpoint.zig");

fn Wire(comptime initial: u8) type {
    return struct {
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
        };
    };
}

const Selected = endpoint.Endpoint(.{ Implementation(1, Wire(10)), Implementation(2, Wire(10)), Implementation(3, Wire(20)) }, struct {}, struct {});

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
