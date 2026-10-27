const fixtures = @import("test.zig");

test "operation counts for chunk demand cancellation" {
    try fixtures.benchmarkDemandCancellation();
}

test "operation counts for synchronous generation batches" {
    try fixtures.benchmarkDemandBatches();
}
