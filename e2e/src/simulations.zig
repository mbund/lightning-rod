const std = @import("std");
const rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const Fixture = @import("fixture.zig").Plugin;
const command_probe = @import("../tests/commands/server.zig");
const teleport_probe = @import("../tests/teleport/server.zig");

pub fn run(init: std.process.Init, plugins: anytype, protocols: *vanilla.Protocols, encryption: ?sessions.Encryption, transfers: bool, port: u16) !void {
    const selected = rod.plugin.replace(rod.plugin.remove(rod.plugin.remove(plugins, command_probe.Probe), teleport_probe.Probe), .{
        rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 1 }),
        rod.plugin.configured(vanilla.Chunks, vanilla.Chunks.Configuration{ .cache_sections = 24 }),
        rod.plugin.configured(vanilla.BlockSynchronization, vanilla.BlockSynchronization.Configuration{ .delta_sections = 8 }),
        rod.plugin.configured(vanilla.Entities, vanilla.Entities.Configuration{ .cache_records = 16 }),
        rod.plugin.configured(vanilla.ItemEntities, vanilla.ItemEntities.Configuration{ .cache_records = 16 }),
        rod.plugin.configured(vanilla.ItemReplication, vanilla.ItemReplication.Configuration{ .cache_records = 16 }),
        rod.plugin.configured(vanilla.Inventories, vanilla.Inventories.Configuration{ .cache_slots = 47, .cache_items = 1 }),
        rod.plugin.configured(vanilla.Chat, vanilla.Chat.Configuration{ .pending_messages = 8 }),
    });
    const Server = linux.Profile(@TypeOf(selected));
    var endpoints: [3]*sessions.Service = undefined;
    const alice = rod.plugin.replace(selected, .{rod.plugin.configured(Fixture, Fixture.Configuration{
        .kind = .transfer,
        .inventory = true,
        .destination = if (transfers) &endpoints[2] else null,
        .full_destination = if (transfers) &endpoints[1] else null,
    })});
    const destination = rod.plugin.replace(selected, .{rod.plugin.configured(Fixture, Fixture.Configuration{
        .kind = .transfer,
        .destination = &endpoints[0],
    })});
    const instances = [_]Server.Instance{
        .{
            .plugins = alice,
            .endpoint = &endpoints[0],
            .storage_path = "lightning-rod-data/alice",
            .max_players = 1,
            .packet_bytes = 128 * 1024,
            .memory = .{ .memory_bytes = 384 * 1024, .temporary_bytes = 16 * 1024 },
        },
        .{
            .plugins = selected,
            .endpoint = &endpoints[1],
            .storage_path = "lightning-rod-data/bob",
            .max_players = 1,
            .packet_bytes = 128 * 1024,
            .memory = .{ .memory_bytes = 384 * 1024, .temporary_bytes = 16 * 1024 },
        },
        .{
            .plugins = destination,
            .endpoint = &endpoints[2],
            .storage_path = "lightning-rod-data/destination",
            .max_players = 1,
            .packet_bytes = 128 * 1024,
            .memory = .{ .memory_bytes = 384 * 1024, .temporary_bytes = 16 * 1024 },
        },
    };
    return Server.runMany(init, .{
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .instances = instances[0..if (transfers) @as(usize, 3) else 2],
        .protocols = &protocols.values,
        .max_players = 2,
        .admission = .{ .context = @constCast(&transfers), .select = selectSimulation },
        .encryption = encryption,
    });
}

fn selectSimulation(_: *anyopaque, profile: sessions.Profile) ?usize {
    if (std.mem.eql(u8, profile.name, "alice")) return 0;
    if (std.mem.eql(u8, profile.name, "bob")) return 1;
    return null;
}
