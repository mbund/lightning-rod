const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const economy = @import("economy");
const shop = @import("shop");
const EconomyCommands = @import("economy_commands").EconomyCommands;
const ShopCommands = @import("shop_commands").ShopCommands;

pub fn main(init: std.process.Init) !void {
    var grants = vanilla.commands.Grants{ .everyone = &.{ &EconomyCommands.balance_permission, &EconomyCommands.pay_permission, &ShopCommands.buy_permission, &ShopCommands.sell_permission } };
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
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
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}
