const std = @import("std");
const economy = @import("economy");
const vanilla = @import("vanilla");

const commands = vanilla.commands;

pub const EconomyCommands = struct {
    pub const id = "economy:commands";

    pub const Configuration = struct { payments: bool = true };

    pub const Dependencies = struct {
        economy: *economy.Economy,
        commands: *commands.Commands,
        players: *vanilla.Players,
    };

    pub const balance_permission: commands.Permission = .{ .name = "economy.balance", .description = "Read your balance" };
    pub const pay_permission: commands.Permission = .{ .name = "economy.pay", .description = "Transfer money to another player" };

    const BalanceArgs = struct {};

    const PayArgs = struct {
        player: u128,
        amount: u128,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*EconomyCommands {
        const self = try allocator.create(EconomyCommands);
        self.* = .{ .deps = deps };

        inline for (.{ "balance", "bal" }) |name|
            _ = try deps.commands.register(self, commands.leaf(EconomyCommands, BalanceArgs, .{
                .name = name,
                .description = "Show your balance",
                .permission = &balance_permission,
                .handler = balance,
                .arguments = .{},
            }));

        if (config.payments)
            _ = try deps.commands.register(self, commands.leaf(EconomyCommands, PayArgs, .{
                .name = "pay",
                .description = "Pay an online player",
                .permission = &pay_permission,
                .handler = pay,
                .arguments = .{ .player = .{ .parse = parsePlayer, .suggest = suggestPlayers }, .amount = .{ .parse = parseAmount } },
            }));
        return self;
    }

    fn balance(self: *EconomyCommands, context: commands.Context, _: BalanceArgs) !void {
        const player = self.findPlayer(context.sender) orelse return;
        const account = try self.deps.economy.acquire(player.uuid, player.name[0..player.name_len]);
        defer account.release();
        var buffer: [160]u8 = undefined;
        context.reply(try economy.formatAmount(&buffer, account.balance, self.deps.economy.config));
    }

    fn pay(self: *EconomyCommands, context: commands.Context, args: PayArgs) !void {
        const source = self.findPlayer(context.sender) orelse return;
        const target = self.findPlayer(args.player) orelse return;
        if (!try self.deps.economy.transfer(source.uuid, source.name[0..source.name_len], target.uuid, target.name[0..target.name_len], args.amount)) {
            context.reply("Payment rejected");
            return;
        }

        try self.balance(context, .{});
    }

    fn parseAmount(self: *EconomyCommands, _: commands.Context, text: []const u8) commands.ParseError!u128 {
        return economy.parseAmount(text, self.deps.economy.config.precision) catch error.InvalidArgument;
    }

    fn parsePlayer(self: *EconomyCommands, _: commands.Context, text: []const u8) commands.ParseError!u128 {
        for (self.deps.players.records) |player|
            if (player.handle != null and player.stage == .ready and std.ascii.eqlIgnoreCase(player.name[0..player.name_len], text)) return player.uuid;
        return error.InvalidArgument;
    }

    fn suggestPlayers(self: *EconomyCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        for (self.deps.players.records) |player| {
            if (player.handle == null or player.stage != .ready or player.uuid == context.sender) continue;

            const name = player.name[0..player.name_len];
            if (std.ascii.startsWithIgnoreCase(name, context.prefix)) output.add(.{ .text = name, .tooltip = "Send money to this player" }) catch return;
        }
    }

    fn findPlayer(self: *EconomyCommands, uuid: u128) ?*const vanilla.Players.Player {
        for (self.deps.players.records) |*value| if (value.handle != null and value.uuid == uuid) return value;
        return null;
    }
};
