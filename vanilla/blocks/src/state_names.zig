//! Block states by name, for tables that find one state from another's name. The registry's own
//! lookup reads every name in turn, which a lookup per state makes quadratic in the states.

const std = @import("std");
const game_data = @import("game_data");

var names: std.StringHashMapUnmanaged(u16) = .empty;
var ready = std.atomic.Value(bool).init(false);

/// The map is game data, like the registry it comes from, so it lives for the process. It is
/// first built while the server starts, before any thread but the main one runs.
pub fn id(name: []const u8) ?u16 {
    if (!ready.load(.acquire)) build(std.heap.page_allocator) catch |err| std.debug.panic("state names: {t}", .{err});
    return names.get(name);
}

fn build(allocator: std.mem.Allocator) !void {
    try names.ensureTotalCapacity(allocator, @intCast(game_data.registry.block_state_names.len));
    for (game_data.registry.block_state_names, 0..) |name, state| names.putAssumeCapacity(name, @intCast(state));
    ready.store(true, .release);
}

test "every state is found by its name" {
    for (game_data.registry.block_state_names, 0..) |name, state| try std.testing.expectEqual(@as(?u16, @intCast(state)), id(name));
    try std.testing.expectEqual(@as(?u16, null), id("minecraft:not_a_block"));
}
