const std = @import("std");
const reactor = @import("reload_test_support");

fn saveReloadState(manager: *reactor.TickModuleManager) !void {
    try manager.save();
}

test "tick module reloads configuration and rolls back invalid candidates" {
    var manager = try reactor.TickModuleManager.init(
        std.testing.io,
        reactor.tick_module_default_path,
        // One protected virtual arena is reused by every generation.
        128 * 1024 * 1024 * 1024,
        .memory,
    );
    defer manager.deinit();
    try manager.loadInitial(0);
    try std.testing.expectEqual(@as(u64, 1), manager.activeGenerationNumber());
    try std.testing.expect(manager.supportsProtocol(771));
    try std.testing.expect(manager.supportsProtocol(772));
    try std.testing.expect(!manager.supportsProtocol(999));
    try reactor.exerciseReloadableTick(&manager, std.testing.allocator);
    try reactor.exerciseReloadableStatus(&manager, std.testing.allocator);
    try reactor.exerciseReloadableLoginStart(&manager, std.testing.allocator);
    try manager.prepareReload(&.{772});
    try saveReloadState(&manager);
    try reactor.exerciseReloadedPlaySession(&manager, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), manager.activeGenerationNumber());
    try reactor.exerciseReloadableTick(&manager, std.testing.allocator);

    try manager.prepareReload(&.{772});
    try saveReloadState(&manager);
    try manager.transitionPreparedReload(0, 0);
    try reactor.exerciseReloadableTick(&manager, std.testing.allocator);

    try manager.prepareReload(&.{772});
    try saveReloadState(&manager);
    try manager.transitionPreparedReload(0, 0);
    try std.testing.expectEqual(@as(u64, 4), manager.activeGenerationNumber());
    try reactor.exerciseReloadableTick(&manager, std.testing.allocator);

    try std.testing.expectError(
        error.TickModuleMissingConnectedProtocol,
        manager.prepareReload(&.{999}),
    );
    try std.testing.expectEqual(@as(u64, 4), manager.activeGenerationNumber());

    const valid_path = manager.module_path;
    manager.module_path = "zig-out/lib/liblightning_rod_worker_tick.so";
    try manager.prepareReload(&.{772});
    try std.testing.expectEqual(@as(usize, 1024), manager.pendingMaximumPlayers());
    manager.cancelPendingReload();
    try std.testing.expectEqual(@as(u64, 4), manager.activeGenerationNumber());
    manager.module_path = valid_path;
    try reactor.exerciseReloadableTick(&manager, std.testing.allocator);

    manager.module_path = "zig-out/lib/liblightning_rod_worker_tick.so";
    try manager.prepareReload(&.{772});
    try manager.save();
    try std.testing.expectError(
        error.ConfiguredMemoryMaximumExceeded,
        manager.transitionPreparedReload(64 * 1024 * 1024, 0),
    );
    try std.testing.expectEqual(@as(u64, 4), manager.activeGenerationNumber());
    manager.module_path = valid_path;
    try reactor.exerciseReloadableTick(&manager, std.testing.allocator);

    manager.module_path = "zig-out/lib/liblightning_rod_reject_tick.so";
    try manager.prepareReload(&.{772});
    try manager.save();
    try std.testing.expectError(
        error.TickModuleInitializationFailed,
        manager.transitionPreparedReload(0, 0),
    );
    try std.testing.expectEqual(@as(u64, 4), manager.activeGenerationNumber());
    manager.module_path = valid_path;
    try reactor.exerciseReloadableTick(&manager, std.testing.allocator);
}
