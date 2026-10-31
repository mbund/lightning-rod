const std = @import("std");
const preparation = @import("prepare_content.zig");
const prepared = @import("vanilla_definitions");

test "compiled vanilla definitions preserve the decoded baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expected = try preparation.prepare(allocator);
    const actual = prepared.definitions(@TypeOf(expected));
    var expected_bytes: std.Io.Writer.Allocating = .init(allocator);
    var actual_bytes: std.Io.Writer.Allocating = .init(allocator);
    try preparation.writeValue(&expected_bytes.writer, expected);
    try preparation.writeValue(&actual_bytes.writer, actual);
    try std.testing.expectEqualStrings(expected_bytes.written(), actual_bytes.written());
}
