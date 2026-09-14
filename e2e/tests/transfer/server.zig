const std = @import("std");
const inventory_fixture = @import("../inventory/server.zig");
const sessions = @import("sessions");
const vanilla = @import("vanilla");
const Dependencies = @import("../../src/fixture.zig").Context;

pub const Fixture = struct {
    inventory: ?inventory_fixture.Fixture = null,
    destination: ?*const *sessions.Service = null,
    full_destination: ?*const *sessions.Service = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !Fixture {
        _ = allocator;
        _ = deps;
        return .{};
    }

    pub fn tick(self: *Fixture, deps: Dependencies) !void {
        if (self.inventory) |*inventory| try inventory.tick(deps);

        for (deps.players.records) |*player| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready or !player.loaded) continue;

            if (self.destination) |destination| for (deps.input.values(handle)) |event| {
                if (event == .command and std.mem.eql(u8, event.command, "transfer")) try deps.players.deps.sessions.transfer(handle, destination.*);
            };

            if (self.full_destination) |destination| for (deps.input.values(handle)) |event| {
                if (event != .command or !std.mem.eql(u8, event.command, "transfer_full")) continue;
                deps.players.deps.sessions.transfer(handle, destination.*) catch |err| {
                    if (err != error.Backpressured) return err;
                    deps.chat.system(handle, "Destination full");
                    continue;
                };
                return error.OccupiedDestinationAccepted;
            };
        }
    }
};
