const e2e = @import("e2e");
const std = @import("std");
const lr = @import("lightning_rod");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const bootstrap = e2e.server;
const simulations = e2e.simulations;

pub fn main(init: std.process.Init) !void {
    var endpoints: [3]*sessions.Service = undefined;
    const plugins = lr.plugin.compose(.{
        bootstrap.plugins(),
        lr.plugin.configured(e2e.Inventory, .{}),
        lr.plugin.configured(Probe, .{}),
    });
    const source = lr.plugin.replace(plugins, .{
        lr.plugin.configured(e2e.Inventory, .{ .starting_bread = Probe.bread_count }),
        lr.plugin.configured(Probe, .{ .verify_inventory = true, .destination = &endpoints[2], .full_destination = &endpoints[1] }),
    });
    const destination = lr.plugin.replace(plugins, .{
        lr.plugin.configured(Probe, .{ .destination = &endpoints[0] }),
    });
    try simulations.run(init, .{ source, plugins, destination }, &endpoints, .{});
}

const Probe = struct {
    pub const id = "e2e:transfer";
    pub const Dependencies = struct {
        control: *e2e.Control,
        inventories: *vanilla.Inventories,
        players: *vanilla.Players,
        sessions: *sessions.Service,
    };
    pub const Configuration = struct {
        verify_inventory: bool = false,
        destination: ?*const *sessions.Service = null,
        full_destination: ?*const *sessions.Service = null,
    };
    const bread_count = 17;

    deps: Dependencies,
    verify_inventory: bool,
    destination: ?*const *sessions.Service = null,
    full_destination: ?*const *sessions.Service = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps, .verify_inventory = config.verify_inventory, .destination = config.destination, .full_destination = config.full_destination };
        deps.control.on(self, message);
        return self;
    }

    pub fn tick(self: *Probe) !void {
        if (self.verify_inventory) {
            for (self.deps.sessions.input_events) |event| {
                if (event != .joined or event.joined.cause != .transfer) continue;
                const player = &self.deps.players.records[event.joined.handle.index];
                const slot = try self.deps.inventories.get(.{ .owner = player.uuid, .index = 36 });
                if (slot.stack == null or slot.stack.?.count != bread_count) return error.TransferSourceInventoryChanged;
            }
        }
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "transfer") and !std.mem.eql(u8, text, "transfer_full")) return .unhandled;
        const player = &self.deps.players.records[handle.index];
        if (player.stage != .ready or !player.loaded) return error.FixturePlayerNotReady;
        if (std.mem.eql(u8, text, "transfer")) {
            const destination = self.destination orelse return error.TransferUnavailable;
            try self.deps.sessions.transfer(handle, destination.*);
        } else {
            const destination = self.full_destination orelse return error.TransferUnavailable;
            self.deps.sessions.transfer(handle, destination.*) catch |err| {
                if (err != error.Backpressured) return err;
                try self.deps.control.send(handle, "Destination full");
                return .handled;
            };
            return error.OccupiedDestinationAccepted;
        }
        return .handled;
    }
};
