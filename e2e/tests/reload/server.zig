const std = @import("std");
const fixture = @import("../../src/fixture.zig");
const inventory_fixture = @import("../inventory/server.zig");
const vanilla = @import("vanilla");
const sessions = @import("sessions");

const Dependencies = fixture.Context;
pub const settings: fixture.Settings = .{ .kind = .reload, .players = inventory_fixture.settings.players };

pub const Fixture = struct {
    inventory: inventory_fixture.Fixture,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !Fixture {
        return .{ .inventory = try inventory_fixture.Fixture.init(allocator, deps) };
    }

    pub fn tick(self: *Fixture, deps: Dependencies) !void {
        try self.inventory.tick(deps);
    }

    pub fn command(self: *Fixture, deps: Dependencies, handle: sessions.Handle, text: []const u8) !void {
        try self.inventory.command(deps, handle, text);
        const player = &deps.players.records[handle.index];
        if (player.stage != .ready or !player.loaded) return;

        if (std.mem.eql(u8, text, "reload_bar"))
            _ = try deps.bars.create(.{ .title = "Reload probe", .audience = .{ .player = player.uuid } });
        if (!std.mem.eql(u8, player.name[0..player.name_len], "alice")) return;

        if (std.mem.eql(u8, text, "reload_opaque")) try deps.reload.stage("lightning_rod.player.v99\x00");

        if (std.mem.eql(u8, text, "reload_signal")) try std.posix.raise(.USR1);
    }
};
