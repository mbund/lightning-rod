const std = @import("std");
const config = @import("config.zig").value;
const block_store = @import("world/blocks.zig");
const plugin_api = @import("plugin_api.zig");
const Packets = @import("packet_writer.zig").Packets;
const player_lifecycle = @import("player_lifecycle.zig");
const tick_host = @import("tick_host.zig");
const tick_services = @import("tick_services.zig");

pub fn run(
    comptime Profile: type,
    host: *tick_host.Host,
    plugins: *Profile.Plugins,
    services: *tick_services.Services,
    allocator: std.mem.Allocator,
    joined: player_lifecycle.JoinedBatch,
    left: player_lifecycle.LeftBatch,
    play_started: []const player_lifecycle.PlayStarted,
) !void {
    const declarations = comptime Profile.commandDeclarations();
    try services.begin(host, &declarations, joined, left, play_started);
    defer services.finish() catch |err|
        std.log.err("event=tick_io_submit_failed err={s}", .{@errorName(err)});
    const packets = services.packets;
    emitReloadResult(host, packets);

    var input_handler = packets.inputHandler();
    host.dispatchTickInputs(&input_handler);

    assertInvariants(host);
    if (left.values.len != 0)
        plugin_api.left(plugins);
    if (joined.values.len != 0)
        plugin_api.joined(plugins);
    plugin_api.tick(plugins, allocator);
    host.inputs.assertConsumed(host.clock.tick);
    assertInvariants(host);

    packets.flushBlockChanges();
    if (packets.first_error) |err| {
        reportOutputFailure(packets.first_error_system, err);
        return err;
    }
}

fn assertInvariants(host: *const tick_host.Host) void {
    std.debug.assert(host.items.active_count <= config.max_item_entities);
    std.debug.assert(host.items.free_count <= config.max_item_entities);
    std.debug.assert(host.inputs.block_request_count <= config.tick_block_request_capacity);
    std.debug.assert(host.inputs.inventory_click_count <= config.tick_inventory_click_capacity);
    std.debug.assert(host.inputs.creative_slot_change_count <= config.tick_creative_slot_capacity);
    std.debug.assert(host.blocks.modified_block_count <= config.max_modified_sections * block_store.blocks_per_section);
    std.debug.assert(host.blocks.modified_section_count <= config.max_modified_sections);
    std.debug.assert(host.players.saved_count <= config.max_saved_players);
    std.debug.assert(host.players.active_count <= config.max_players);
    host.living.entities.assertInvariants();
}

fn emitReloadResult(host: *tick_host.Host, packets: *Packets) void {
    const result = host.claimReloadResult() orelse return;
    if (result.succeeded) {
        _ = packets.send(host.queue_system_chat_format(
            result.requester,
            "Reload completed in {} ms",
            .{result.elapsed_ms},
        ));
    } else {
        _ = packets.send(host.queue_system_chat_format(
            result.requester,
            "Reload failed",
            .{},
        ));
    }
}

fn reportOutputFailure(system: ?plugin_api.ActiveSystem, err: anyerror) void {
    const active = system orelse return;
    std.debug.print(
        "error: event=plugin_output_failed phase={s} plugin={s} system={s} error={s}\n",
        .{ active.phase, active.plugin_id, active.system_type, @errorName(err) },
    );
}
