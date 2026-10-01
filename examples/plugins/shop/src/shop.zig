const std = @import("std");
const economy = @import("economy");
const vanilla = @import("vanilla");
const game_data = @import("game_data");

pub const Offer = struct {
    item: []const u8,
    buy: u128,
    sell: u128,
};

pub const Shop = struct {
    pub const id = "shop:shop";

    pub const Configuration = struct { offers: []const Offer = &.{} };

    pub const Dependencies = struct {
        players: *vanilla.Players,
        menus: *vanilla.PlayerInventory,
        economy: *economy.Economy,
    };

    deps: Dependencies,
    config: Configuration,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Shop {
        if (config.offers.len > 256) return error.TooManyOffers;

        for (config.offers, 0..) |offer, index| {
            if (offer.buy == 0 or offer.sell > offer.buy or game_data.registry.itemId(offer.item) == null) return error.InvalidOffer;

            for (config.offers[0..index]) |previous| if (std.mem.eql(u8, previous.item, offer.item)) return error.DuplicateOffer;
        }

        const self = try allocator.create(Shop);
        self.* = .{ .deps = deps, .config = config };
        return self;
    }

    pub fn trade(self: *Shop, index: usize, offer_index: usize, count: u16, buying: bool) !void {
        if (index >= self.deps.players.records.len or offer_index >= self.config.offers.len or count == 0) return error.InvalidTrade;

        const player = self.deps.players.records[index];
        if (player.handle == null or player.stage != .ready) return error.InvalidTrade;

        const offer = self.config.offers[offer_index];
        const price = std.math.mul(u128, if (buying) offer.buy else offer.sell, count) catch return error.TradeBalance;
        var account = try self.deps.economy.acquire(player.uuid, player.name[0..player.name_len]);
        defer account.release();
        const balance = (if (buying) std.math.sub(u128, account.balance, price) else std.math.add(u128, account.balance, price)) catch return error.TradeBalance;
        if (!try self.deps.menus.trade(index, offer.item, count, buying)) return if (buying) error.TradeCapacity else error.TradeItems;
        account.set(balance);
    }
};
