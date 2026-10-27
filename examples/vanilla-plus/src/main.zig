const std = @import("std");
const protocol_set = @import("protocols");
const economy = @import("economy");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");
const sessions = @import("sessions");
const tui = @import("lightning_rod_tui");
const shop = @import("shop");
const EconomyCommands = @import("economy_commands").EconomyCommands;
const ShopCommands = @import("shop_commands").ShopCommands;
const vanilla = @import("lightning_rod_vanilla_1_21_6");

pub fn main(init: std.process.Init) !void {
    const startup = profile.Startup.capture(init.io);
    var memory = lightning_rod.Memory.init(std.heap.page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    var grants = vanilla.commands.Grants{ .everyone = &.{ &EconomyCommands.balance_permission, &EconomyCommands.pay_permission, &ShopCommands.buy_permission, &ShopCommands.sell_permission } };
    const gameplay_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(vanilla.commands.Commands, .{
                .permission_policy = grants.policy(),
            }),
        }),
        lightning_rod.plugin.configured(economy.Economy, economy.Economy.Configuration{
            .unit = "credit",
            .precision = 3,
            .cache_accounts = 64,
            .initial_balance = 10_000,
        }),
        lightning_rod.plugin.configured(shop.Shop, shop.Shop.Configuration{ .offers = &.{.{ .item = "minecraft:bread", .buy = 750, .sell = 300 }} }),
        lightning_rod.plugin.configured(EconomyCommands, EconomyCommands.Configuration{}),
        lightning_rod.plugin.configured(ShopCommands, ShopCommands.Configuration{}),
    });
    var protocols = try protocol_set.Default.init(allocator);
    defer protocols.deinit(allocator);
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        vanilla.session_plugins(&protocols),
    });
    var registry = try lightning_rod.metrics.Registry.init(memory.allocator("metrics"), init.io, .{ .capacity = 512 });
    defer registry.deinit();
    var terminal = try tui.Terminal.init(memory.allocator("terminal"), init.io, &registry, .{});
    defer terminal.deinit();
    try terminal.start();
    defer terminal.stop();
    try profile.Server(@TypeOf(gameplay_plugins), protocol_set.Endpoint, @TypeOf(session_plugins), sessions.SingleSimulation).run(&memory, init, .{
        .plugins = gameplay_plugins,
        .network = .{ .plugins = session_plugins, .protocols = &protocols, .router = .{}, .endpoints = &.{.{ .id = 0 }} },
        .startup = startup,
        .registry = &registry,
    }, .{});
}
