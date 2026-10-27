const player_spatial = @import("player_spatial.zig");
const item_limits = @import("item_limits_bench.zig");
const gameplay = @import("batch_test.zig");
const command = @import("command_bench.zig");
const inventory = @import("inventory_bench.zig");
const mining_replication = @import("mining_replication_test.zig");
const mining = @import("mining_bench.zig");
const item_entities = @import("item_entities.zig");

test "operation counts for item physics section acquisition" {
    try gameplay.benchmarkItemPhysics();
}

test "operation counts for survival inventory synchronization" {
    try inventory.benchmark();
}

test "operation counts for equipment synchronization" {
    try inventory.benchmarkEquipment();
}

test "operation counts for inherited command permissions" {
    try command.benchmark();
}

test "operation counts for multiple item pickups" {
    try inventory.benchmarkPickup();
}

test "operation counts for dropped item replication" {
    try inventory.benchmarkItemReplication();
}

test "operation counts for shared item broadcasts and partial credit retries" {
    try inventory.benchmarkItemBroadcast();
}

test "operation counts for bossbar changes retries and idle delivery" {
    try inventory.benchmarkBossbars();
}

test "operation counts for batched drop creation" {
    try inventory.benchmarkDrops();
}

test "operation counts for item tracking boundaries and unchanged viewer movement" {
    try inventory.benchmarkItemMovement();
}

test "operation counts for isolated item visibility changes" {
    try inventory.benchmarkItemVisibility();
}

test "operation counts for pickup admission and inventory invalidation" {
    try inventory.benchmarkPickupAdmission();
}

test "operation counts for idle terrain and publication retry" {
    try inventory.benchmarkIdleTerrain();
}

test "operation counts for mining progress and deferred drops" {
    try mining.benchmark();
}

test "operation counts for cached simulation and pickup item queries" {
    try gameplay.benchmarkItemQueries();
}

test "operation counts for sparse and overlapping item query planning" {
    try item_entities.benchmarkQueryPlanning();
}

test "operation counts for grouped block delivery and backpressure retries" {
    try inventory.benchmarkBlockPlanning();
}

test "operation counts for overlapping item tracking boundaries" {
    try inventory.benchmarkItemBoundaries();
}

test "operation counts for retained item physics neighborhoods" {
    try gameplay.benchmarkItemPhysicsWindow();
}

test "operation counts for unchanged mining replication" {
    try mining_replication.benchmarkReplication();
}

test "operation counts for mining delivery under backpressure and player lifecycle changes" {
    try mining_replication.verifyDelivery();
}

test "operation counts for terrain packet-pool backpressure and partial capacity" {
    try inventory.benchmarkTerrainBackpressure();
}

test "operation counts for resident item limits through creation restore and identity changes" {
    try item_limits.benchmark();
}

test "operation counts for terrain cursor updates follow admitted recipients" {
    try inventory.benchmarkSparseTerrainStreaming();
}

test "operation counts for bucketed player movement" {
    try player_spatial.benchmark();
}

test "operation counts for sparse block delivery retain retries and invalidate departed observers" {
    try inventory.benchmarkSparseBlockPlanning();
}

test "operation counts for mining terrain reads across block action mutations" {
    try mining_replication.verifyReadWindow();
}

test "operation counts for shared mining neighborhoods preserve visibility and local invalidation" {
    try mining_replication.verifyNeighborhoods();
}

test "operation counts for shared block delta retirement across delivery groups" {
    try inventory.verifyBlockBatchRetirement();
}
