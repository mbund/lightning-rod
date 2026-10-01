const std = @import("std");
const protocol_set = @import("protocols");
const economy = @import("economy");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");
const tui = @import("lightning_rod_tui");
const shop = @import("shop");
const EconomyCommands = @import("economy_commands").EconomyCommands;
const ShopCommands = @import("shop_commands").ShopCommands;
const vanilla = @import("lightning_rod_vanilla_1_21_6");

const plugin = lightning_rod.plugin;
pub export const lightning_rod_resume_manifest linksection(profile.Reload.section_name) = profile.Reload.executableManifest(protocol_set.Endpoint);

pub fn main(init: std.process.Init) !void {
    const plugins = plugin.compose(.{
        vanilla.plugins(),
        plugin.configured(economy.Economy, economy.Economy.Configuration{
            .unit = "credit",
            .precision = 3,
            .cache_accounts = 64,
            .initial_balance = 10_000,
        }),
        plugin.configured(shop.Shop, shop.Shop.Configuration{ .offers = &.{.{ .item = "minecraft:bread", .buy = 750, .sell = 300 }} }),
        plugin.configured(EconomyCommands, EconomyCommands.Configuration{}),
        plugin.configured(ShopCommands, ShopCommands.Configuration{}),
        plugin.configured(tui.Plugin, tui.Plugin.Configuration{}),
    });
    var protocols = try protocol_set.Default.init(init.gpa);
    defer protocols.deinit(init.gpa);
    const session_plugins = plugin.compose(.{
        plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        vanilla.session_plugins(&protocols),
    });
    const router = profile.SingleSimulation{};
    const Server = profile.Server(@TypeOf(plugins), protocol_set.Endpoint, @TypeOf(session_plugins), @TypeOf(router));
    var grants = vanilla.commands.Grants{ .everyone = &.{ &EconomyCommands.balance_permission, &EconomyCommands.pay_permission, &ShopCommands.buy_permission, &ShopCommands.sell_permission } };
    try Server.runWithEnvironment(init, .{ .plugins = plugins, .session_plugins = session_plugins, .router = router, .protocols = &protocols, .reload_manifest = &lightning_rod_resume_manifest }, .{ .permission_policy = grants.policy() });
}
