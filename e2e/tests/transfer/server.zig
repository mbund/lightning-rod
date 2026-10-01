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
        if (self.inventory != null) {
            for (deps.sessions.input_events) |event| {
                if (event != .joined or event.joined.cause != .transfer) continue;
                const player = &deps.players.records[event.joined.handle.index];
                const slot = try deps.inventories.get(.{ .owner = player.uuid, .index = 36 });
                if (slot.stack == null or slot.stack.?.count != 17) return error.TransferSourceInventoryChanged;
            }
        }
        if (self.inventory) |*inventory| try inventory.tick(deps);
    }

    pub fn command(self: *Fixture, deps: Dependencies, handle: sessions.Handle, text: []const u8) !void {
        const player = &deps.players.records[handle.index];
        if (player.stage != .ready or !player.loaded) return;
        if (self.inventory) |*inventory| try inventory.command(deps, handle, text);

        if (self.destination) |destination| {
            if (std.mem.eql(u8, text, "transfer")) try deps.sessions.transfer(handle, destination.*);
        }

        if (self.full_destination) |destination| {
            if (!std.mem.eql(u8, text, "transfer_full")) return;
            deps.sessions.transfer(handle, destination.*) catch |err| {
                if (err != error.Backpressured) return err;
                deps.chat.system(handle, "Destination full");
                return;
            };
            return error.OccupiedDestinationAccepted;
        }
    }
};
