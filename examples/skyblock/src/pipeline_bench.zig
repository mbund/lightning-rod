const fixtures = @import("island_test.zig");

test "operation counts for worker pause fanout" {
    try fixtures.benchmarkPause();
}
