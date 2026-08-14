const std = @import("std");
const economy = @import("economy");
const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const commands = lightning_rod.commands;
const Packets = lightning_rod.Packets;
const registry = lightning_rod.registry_data;
pub const Offer = struct {
    item: []const u8,
    buy: u128,
    sell: u128,
};

pub const Config = struct {
    offers: []const Offer = &.{
        .{ .item = "minecraft:oak_log", .buy = 250, .sell = 100 },
        .{ .item = "minecraft:bread", .buy = 500, .sell = 200 },
    },

    pub fn validate(self: Config) !void {
        if (self.offers.len > 256) return error.TooManyShopOffers;
        for (self.offers) |offer| {
            if (offer.item.len == 0 or offer.buy == 0 or offer.sell > offer.buy)
                return error.InvalidShopOffer;
            if (registry.itemId(offer.item) == null) return error.UnknownShopItem;
        }
    }
};

pub const Shop = struct {
    pub const id = "example:shop";
    pub const command_declarations = [_]commands.Declaration{
        .{ .name = "buy" },
        .{ .name = "sell" },
    };

    config: Config,
    players: *player_store.Players,
    economy: *economy.Economy,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, players: *player_store.Players, economy_plugin: *economy.Economy, outputs: *Packets, shop_config: Config) !*Shop {
        try shop_config.validate();
        const self = try allocator.create(Shop);
        self.* = .{ .config = shop_config, .players = players, .economy = economy_plugin, .outputs = outputs };
        return self;
    }

    pub fn tick(self: *Shop, _: std.mem.Allocator) void {
        Runner.run(
            self.players,
            self.economy,
            self.outputs,
            &self.outputs.commands,
            &self.config,
        );
    }
};

const Work = struct {
    players: *player_store.Players,
    outputs: *Packets,
    config: *const Config,
    economy: *economy.Economy,
};

const Trade = struct {
    fn buy(work: *Work, player: *player_store.CorePlayer, item_id: i32, amount: u16, unit_price: u128) !void {
        const price = try std.math.mul(u128, unit_price, amount);
        var hotbar = player.hotbar;
        var inventory = player.main_inventory;
        var remaining: usize = amount;
        while (remaining != 0) {
            const count: u8 = @intCast(@min(remaining, std.math.maxInt(u8)));
            var stack = player_store.stackForItem(item_id, count);
            player_store.moveStackInto(&hotbar, &stack);
            player_store.moveStackInto(&inventory, &stack);
            if (!stack.isEmpty()) return error.InventoryFull;
            remaining -= count;
        }
        try work.economy.withdraw(player.uuid, price);
        player.hotbar = hotbar;
        player.main_inventory = inventory;
    }

    fn sell(work: *Work, player: *player_store.CorePlayer, item_id: i32, amount: u16, unit_price: u128) !void {
        var hotbar = player.hotbar;
        var inventory = player.main_inventory;
        var remaining: usize = amount;
        removeItem(&hotbar, item_id, &remaining);
        removeItem(&inventory, item_id, &remaining);
        if (remaining != 0) return error.InsufficientItems;
        const proceeds = try std.math.mul(u128, unit_price, amount);
        try work.economy.deposit(player.uuid, player.name_slice(), proceeds);
        player.hotbar = hotbar;
        player.main_inventory = inventory;
    }
};

const Runner = struct {
    fn run(players: *player_store.Players, economy_service: *economy.Economy, outputs: *Packets, command_batch: *commands.Batch, plugin_config: *const Config) void {
        var work = Work{ .players = players, .outputs = outputs, .config = plugin_config, .economy = economy_service };
        if (!work.economy.ready()) return;
        for (command_batch.items()) |*entry| {
            if (entry.handled) continue;
            var words = std.mem.tokenizeScalar(u8, entry.text, ' ');
            const command = words.next() orelse continue;
            const buying = if (std.mem.eql(u8, command, "buy"))
                true
            else if (std.mem.eql(u8, command, "sell"))
                false
            else
                continue;
            entry.handled = true;
            const item_name = words.next() orelse {
                usage(&work, entry.sender, buying);
                continue;
            };
            const amount = if (words.next()) |text| std.fmt.parseInt(u16, text, 10) catch {
                work.outputs.system(entry.sender, "Invalid item amount", .{});
                continue;
            } else 1;
            if (amount == 0 or words.next() != null) {
                usage(&work, entry.sender, buying);
                continue;
            }
            const offer = findOffer(work.config, item_name) orelse {
                work.outputs.system(entry.sender, "That item is not sold here", .{});
                continue;
            };
            const item_id = registry.itemId(offer.item).?;
            const player = &work.players.records[entry.sender];
            if (buying) {
                Trade.buy(&work, player, item_id, amount, offer.buy) catch |err| {
                    work.outputs.system(entry.sender, "Purchase failed: {s}", .{@errorName(err)});
                    continue;
                };
            } else {
                Trade.sell(&work, player, item_id, amount, offer.sell) catch |err| {
                    work.outputs.system(entry.sender, "Sale failed: {s}", .{@errorName(err)});
                    continue;
                };
            }
            work.outputs.inventory_changed(entry.sender);
            if (buying)
                work.outputs.system(entry.sender, "Purchase complete", .{})
            else
                work.outputs.system(entry.sender, "Sale complete", .{});
        }
    }

    fn usage(work: *Work, slot: u16, buying: bool) void {
        if (buying)
            work.outputs.system(slot, "Usage: /buy <item> [amount]", .{})
        else
            work.outputs.system(slot, "Usage: /sell <item> [amount]", .{});
    }
};

fn removeItem(slots: []player_store.HotbarStack, item_id: i32, remaining: *usize) void {
    for (slots) |*stack| {
        if (remaining.* == 0) return;
        if (stack.isEmpty() or stack.item_id != item_id) continue;
        const removed = @min(remaining.*, stack.count);
        stack.count -= @intCast(removed);
        remaining.* -= removed;
        if (stack.count == 0) stack.* = .{};
    }
}

fn findOffer(plugin_config: *const Config, input: []const u8) ?Offer {
    for (plugin_config.offers) |offer| {
        if (std.mem.eql(u8, offer.item, input)) return offer;
        if (std.mem.startsWith(u8, offer.item, "minecraft:") and std.mem.eql(u8, offer.item["minecraft:".len..], input)) return offer;
    }
    return null;
}

test "shop configuration uses namespaced registry items" {
    const plugin_config = Config{};
    try plugin_config.validate();
    try std.testing.expectEqualStrings("minecraft:oak_log", findOffer(&plugin_config, "oak_log").?.item);
    try std.testing.expect(findOffer(&plugin_config, "diamond") == null);
}

test "removing items is transactional on a copied inventory" {
    const oak_log = registry.itemId("minecraft:oak_log").?;
    var slots = [_]player_store.HotbarStack{player_store.stackForItem(oak_log, 5)};
    var remaining: usize = 3;
    removeItem(&slots, oak_log, &remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining);
    try std.testing.expectEqual(@as(u8, 2), slots[0].count);
}
