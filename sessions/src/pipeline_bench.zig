const fixtures = @import("handoff_test.zig");
const initialization = @import("initialization_test.zig");

test "operation counts for configuration production and codec handoffs" {
    try fixtures.benchmarkConfiguration();
}

test "operation counts for protocol fanout and tick publication" {
    try initialization.benchmarkFanout();
}

test "operation counts for borrowed payloads and socket batching" {
    try fixtures.benchmarkSocketBatch();
}

test "operation counts for reload wire spooling" {
    try fixtures.benchmarkSpill();
}
