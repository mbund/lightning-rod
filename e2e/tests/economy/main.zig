const std = @import("std");
const lr = @import("lightning_rod");
const vanilla = @import("vanilla");
const economy = @import("economy");
const shop = @import("shop");
const EconomyCommands = @import("economy_commands").EconomyCommands;
const ShopCommands = @import("shop_commands").ShopCommands;
const bootstrap = @import("e2e").server;

pub fn main(init: std.process.Init) !void {
    var grants = vanilla.commands.Grants{ .everyone = &.{ &EconomyCommands.balance_permission, &EconomyCommands.pay_permission, &ShopCommands.buy_permission, &ShopCommands.sell_permission } };
    const plugins = lr.plugin.compose(.{
        lr.plugin.replace(bootstrap.plugins(), .{
            lr.plugin.configured(vanilla.commands.Commands, .{
                .permission_policy = grants.policy(),
            }),
        }),
        lr.plugin.configured(economy.Economy, economy.Economy.Configuration{
            .unit = "credit",
            .precision = 3,
            .cache_accounts = 64,
            .initial_balance = 10_000,
        }),
        lr.plugin.configured(shop.Shop, shop.Shop.Configuration{ .offers = &.{.{ .item = "minecraft:bread", .buy = 750, .sell = 300 }} }),
        lr.plugin.configured(EconomyCommands, EconomyCommands.Configuration{}),
        lr.plugin.configured(ShopCommands, ShopCommands.Configuration{}),
    });
    try bootstrap.run(init, plugins, .{ .plaintext = true });
}
