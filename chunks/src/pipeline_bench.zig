const fixtures = @import("test.zig");

test "operation counts for chunk demand beside a full prefetch budget" {
    try fixtures.benchmarkDemandBesidePrefetch();
}

test "operation counts for synchronous generation batches" {
    try fixtures.benchmarkDemandBatches();
}
