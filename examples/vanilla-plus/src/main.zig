const std = @import("std");
const economy = @import("economy");
const lightning_rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const tui = @import("lightning_rod_tui");
const shop = @import("shop");
const vanilla = @import("lightning_rod_vanilla_1_21_6");

pub const std_options: std.Options = .{ .logFn = lightning_rod.logging.logFn };

const plugin = lightning_rod.plugin;

pub fn main(init: std.process.Init) !void {
    const plugins = plugin.compose(.{
        vanilla.plugins(),
        plugin.configured(economy.Economy, economy.Economy.Configuration{ .unit = "credit", .precision = 3, .maximum_accounts = 64 }),
        plugin.configured(shop.Shop, shop.Shop.Configuration{ .offers = &.{.{ .item = "minecraft:bread", .buy = 750, .sell = 300 }} }),
        plugin.configured(tui.Plugin, tui.Plugin.Configuration{}),
    });
    const Server = linux.Profile(vanilla.protocols, @TypeOf(plugins), .{});
    try Server.run(init, .{ .plugins = plugins });
}
