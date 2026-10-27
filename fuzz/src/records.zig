const std = @import("std");
const model = @import("model");
const environment = @import("environment.zig");

fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var input: [384]u8 = undefined;
    smith.bytesWithHash(&input, 1);
    var state = try environment.Environment.init("records", std.hash.Wyhash.hash(0, &input));
    defer state.deinit();
    try model.runAt(state.io(), state.path, &input);
}

test "fuzz record transactions against a reference model" {
    try std.testing.fuzz({}, fuzz, .{ .corpus = &.{&.{ 0, 0, 5, 4, 0, 7, 7, 63, 255, 6, 0, 0, 5, 0, 0, 2, 0, 0, 4, 0, 3, 5, 0, 0, 6, 0, 0 }} });
}
