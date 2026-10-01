const std = @import("std");
const commands_fixture = @import("../tests/commands/server.zig");
const teleport_fixture = @import("../tests/teleport/server.zig");
const inventory_fixture = @import("../tests/inventory/server.zig");
const respawn_fixture = @import("../tests/respawn/server.zig");
const reload_fixture = @import("../tests/reload/server.zig");
const items_fixture = @import("../tests/items/server.zig");
const block_sync_fixture = @import("../tests/block-sync/server.zig");
const transfer_fixture = @import("../tests/transfer/server.zig");
const sessions = @import("sessions");
const vanilla = @import("vanilla");
const bossbars = @import("bossbars");

pub const Context = struct {
    players: *vanilla.Players,
    menus: *vanilla.PlayerInventory,
    command_dispatch: *vanilla.CommandDispatch,
    chat: *vanilla.Chat,
    chunks: *vanilla.Chunks,
    synchronization: *vanilla.BlockSynchronization,
    items: *vanilla.Items,
    dropped: *vanilla.ItemEntities,
    item_tick: *vanilla.ItemTick,
    reload: *vanilla.Reload,
    bars: *bossbars.Bossbars,
    sessions: *sessions.Service,
    inventories: *vanilla.Inventories,
    entities: *vanilla.Entities,
};

pub const Kind = enum { none, inventory, respawn, reload, items, block_sync, transfer };

pub const Settings = struct {
    players: vanilla.Players.Configuration = .{ .gamemode = .creative, .spawn = .{ .x = 0.5, .y = 65, .z = 0.5 } },
    kind: Kind = .none,
    delta_sections: usize = 128,
    worlds: usize = 16,
    commands: commands_fixture.Probe.Configuration = .{ .enabled = false },
    teleport: teleport_fixture.Probe.Configuration = .{ .enabled = false },
};

pub const State = union(Kind) {
    none: void,
    inventory: inventory_fixture.Fixture,
    respawn: respawn_fixture.Fixture,
    reload: reload_fixture.Fixture,
    items: items_fixture.Fixture,
    block_sync: block_sync_fixture.Fixture,
    transfer: transfer_fixture.Fixture,
};

pub const Plugin = struct {
    pub const id = "e2e:fixture";

    pub const Configuration = struct {
        kind: Kind = .none,
        inventory: bool = false,
        destination: ?*const *sessions.Service = null,
        full_destination: ?*const *sessions.Service = null,
    };

    pub const Dependencies = Context;
    deps: Dependencies,
    state: State,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Plugin {
        const self = try allocator.create(Plugin);
        const state: State = switch (config.kind) {
            .none => .{ .none = {} },
            inline else => |kind| @unionInit(State, @tagName(kind), try @FieldType(State, @tagName(kind)).init(allocator, deps)),
        };
        self.* = .{ .deps = deps, .state = state };
        try deps.command_dispatch.observeCommand(self, onCommand);

        if (self.state == .transfer) self.state.transfer = .{
            .inventory = if (config.inventory) try inventory_fixture.Fixture.init(allocator, deps) else null,
            .destination = config.destination,
            .full_destination = config.full_destination,
        };

        return self;
    }

    fn onCommand(self: *Plugin, handle: sessions.Handle, text: []const u8) !void {
        switch (self.state) {
            .inventory => |*selected| try selected.command(self.deps, handle, text),
            .reload => |*selected| try selected.command(self.deps, handle, text),
            .items => |*selected| try selected.command(self.deps, handle, text),
            .block_sync => |*selected| try selected.command(self.deps, handle, text),
            .transfer => |*selected| try selected.command(self.deps, handle, text),
            .none, .respawn => {},
        }
    }

    pub fn tick(self: *Plugin) !void {
        switch (self.state) {
            .none => {},
            inline else => |*fixture| try fixture.tick(self.deps),
        }
    }
};
