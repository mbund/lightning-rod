const std = @import("std");
const vanilla = @import("vanilla");

const commands = vanilla.commands;
const Shop = @import("shop").Shop;

pub const ShopCommands = struct {
    pub const id = "shop:commands";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        shop: *Shop,
        commands: *commands.Commands,
    };

    pub const buy_permission: commands.Permission = .{ .name = "shop.buy", .description = "Purchase items" };
    pub const sell_permission: commands.Permission = .{ .name = "shop.sell", .description = "Sell items" };

    const TradeArgs = struct {
        item: usize,
        amount: ?u16,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ShopCommands {
        const self = try allocator.create(ShopCommands);
        self.* = .{ .deps = deps };
        _ = try deps.commands.register(self, commands.leaf(ShopCommands, TradeArgs, .{
            .name = "buy",
            .description = "Purchase an offered item",
            .permission = &buy_permission,
            .handler = buy,
            .arguments = .{ .item = .{ .parse = parseItem, .suggest = suggestItems }, .amount = .{ .minimum = 1 } },
        }));
        _ = try deps.commands.register(self, commands.leaf(ShopCommands, TradeArgs, .{
            .name = "sell",
            .description = "Sell an offered item",
            .permission = &sell_permission,
            .handler = sell,
            .arguments = .{ .item = .{ .parse = parseItem, .suggest = suggestItems }, .amount = .{ .minimum = 1 } },
        }));
        return self;
    }

    fn buy(self: *ShopCommands, context: commands.Context, args: TradeArgs) !void {
        try self.trade(context, args, true);
    }

    fn sell(self: *ShopCommands, context: commands.Context, args: TradeArgs) !void {
        try self.trade(context, args, false);
    }

    fn trade(self: *ShopCommands, context: commands.Context, args: TradeArgs, buying: bool) !void {
        for (self.deps.shop.deps.players.records, 0..) |player, index| {
            if (player.handle == null or player.uuid != context.sender) continue;
            self.deps.shop.trade(index, args.item, args.amount orelse 1, buying) catch |err| {
                context.reply(switch (err) {
                    error.InvalidTrade => "Invalid trade",
                    error.TradeBalance => "Insufficient funds or balance limit reached",
                    error.TradeCapacity => "Insufficient inventory space",
                    error.TradeItems => "Insufficient matching items",
                    else => return err,
                });
                return;
            };
            context.reply(if (buying) "Purchase complete" else "Sale complete");
            return;
        }
    }

    fn parseItem(self: *ShopCommands, _: commands.Context, text: []const u8) commands.ParseError!usize {
        for (self.deps.shop.config.offers, 0..) |offer, index|
            if (std.mem.eql(u8, offer.item, text) or (std.mem.startsWith(u8, offer.item, "minecraft:") and std.mem.eql(u8, offer.item[10..], text))) return index;
        return error.InvalidArgument;
    }

    fn suggestItems(self: *ShopCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        for (self.deps.shop.config.offers) |offer| {
            const name = if (std.mem.startsWith(u8, offer.item, "minecraft:")) offer.item[10..] else offer.item;
            if (std.mem.startsWith(u8, name, context.prefix)) output.add(.{ .text = name, .tooltip = "Available in this shop" }) catch return;
        }
    }
};
