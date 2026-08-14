const std = @import("std");
const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const commands = lightning_rod.commands;
const config = lightning_rod.config.value;
const Packets = lightning_rod.Packets;
const tick_io = lightning_rod.tick_io;

const storage_magic = "LRECON01";

pub const Config = struct {
    unit: []const u8 = "coin",
    precision: u8 = 2,

    pub fn validate(self: Config) !void {
        if (self.unit.len == 0 or self.unit.len > 32) return error.InvalidCurrencyUnit;
        if (self.precision > 18) return error.InvalidCurrencyPrecision;
    }
};

pub const Account = struct {
    uuid: u128 = 0,
    balance: u128 = 0,
    name: [config.max_username_bytes]u8 = undefined,
    name_len: u8 = 0,

    pub fn nameSlice(self: *const Account) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Economy = struct {
    pub const id = "example:economy";
    pub const command_declarations = [_]commands.Declaration{
        .{ .name = "balance" },
        .{ .name = "bal" },
        .{ .name = "baltop" },
        .{ .name = "pay" },
    };

    config: Config,
    accounts: []Account = &.{},
    ranking: []u16 = &.{},
    persistence_buffer: []u8 = &.{},
    account_count: usize = 0,
    loaded: bool = false,
    dirty: bool = false,
    players: *player_store.Players,
    outputs: *Packets,
    io: *tick_io.TickIo,

    pub fn create(allocator: std.mem.Allocator, players: *player_store.Players, outputs: *Packets, io: *tick_io.TickIo, economy_config: Config) !*Economy {
        try economy_config.validate();
        const self = try allocator.create(Economy);
        self.* = .{ .config = economy_config, .players = players, .outputs = outputs, .io = io };
        self.accounts = try allocator.alloc(Account, config.max_saved_players);
        self.ranking = try allocator.alloc(u16, config.max_saved_players);
        self.persistence_buffer = try allocator.alloc(u8, encodedCapacity());
        @memset(self.accounts, .{});
        return self;
    }

    pub fn load(self: *Economy) !void {
        if (self.loaded) return;
        if (try self.io.readPluginSync(Economy.id)) |bytes| try decode(self, bytes);
        self.loaded = true;
    }

    pub fn tick(self: *Economy, _: std.mem.Allocator) void {
        std.debug.assert(self.loaded);
        var work = Work{
            .players = self.players,
            .outputs = self.outputs,
            .economy = self,
        };
        CommandRunner.run(&work, &self.outputs.commands);
    }

    pub fn save(self: *Economy) !void {
        if (!self.dirty) return;
        const bytes = try encode(self, self.persistence_buffer);
        try self.io.writePluginSync(Economy.id, bytes);
        self.dirty = false;
    }

    pub fn ready(self: *const Economy) bool {
        return self.loaded;
    }

    pub fn balance(self: *Economy, uuid: u128) u128 {
        const account = self.findByUuid(uuid) orelse return 0;
        return account.balance;
    }

    pub fn ensure(self: *Economy, uuid: u128, name: []const u8) error{AccountCapacity}!*Account {
        if (self.findByUuid(uuid)) |account| {
            if (!std.mem.eql(u8, account.nameSlice(), name)) {
                setName(account, name);
                self.markDirty();
            }
            return account;
        }
        if (self.account_count == self.accounts.len) return error.AccountCapacity;
        const account = &self.accounts[self.account_count];
        self.account_count += 1;
        account.* = .{ .uuid = uuid };
        setName(account, name);
        self.markDirty();
        return account;
    }

    pub fn deposit(self: *Economy, uuid: u128, name: []const u8, amount: u128) !void {
        const account = try self.ensure(uuid, name);
        account.balance = try std.math.add(u128, account.balance, amount);
        self.markDirty();
    }

    pub fn withdraw(self: *Economy, uuid: u128, amount: u128) error{InsufficientFunds}!void {
        const account = self.findByUuid(uuid) orelse return error.InsufficientFunds;
        if (account.balance < amount) return error.InsufficientFunds;
        account.balance -= amount;
        self.markDirty();
    }

    pub fn transfer(self: *Economy, sender: u128, recipient: *Account, amount: u128) !void {
        if (amount == 0) return error.InvalidAmount;
        const source = self.findByUuid(sender) orelse return error.InsufficientFunds;
        if (source == recipient) return error.CannotPaySelf;
        if (source.balance < amount) return error.InsufficientFunds;
        const destination = try std.math.add(u128, recipient.balance, amount);
        source.balance -= amount;
        recipient.balance = destination;
        self.markDirty();
    }

    pub fn findByName(self: *Economy, name: []const u8) ?*Account {
        for (self.accounts[0..self.account_count]) |*account| {
            if (std.ascii.eqlIgnoreCase(account.nameSlice(), name)) return account;
        }
        return null;
    }

    pub fn findByUuid(self: *Economy, uuid: u128) ?*Account {
        for (self.accounts[0..self.account_count]) |*account| {
            if (account.uuid == uuid) return account;
        }
        return null;
    }

    fn markDirty(self: *Economy) void {
        self.dirty = true;
    }
};

const Work = struct {
    players: *player_store.Players,
    outputs: *Packets,
    economy: *Economy,
};

const Display = struct {
    fn balance(work: *Work, slot: u16, amount: u128) void {
        var buffer: [160]u8 = undefined;
        const text = formatAmount(&buffer, amount, work.economy.config) catch return;
        work.outputs.system(slot, "Balance: {s}", .{text});
    }

    fn top(work: *Work, slot: u16) void {
        for (0..work.economy.account_count) |index|
            work.economy.ranking[index] = @intCast(index);
        const active = work.economy.ranking[0..work.economy.account_count];
        std.mem.sortUnstable(u16, active, work.economy, lessThan);
        if (active.len == 0) return work.outputs.system(slot, "No economy accounts", .{});
        for (active[0..@min(active.len, 10)], 1..) |account_index, rank| {
            const account = &work.economy.accounts[account_index];
            var amount_buffer: [128]u8 = undefined;
            const amount = formatAmount(&amount_buffer, account.balance, work.economy.config) catch continue;
            work.outputs.system(slot, "{d}. {s}: {s}", .{ rank, account.nameSlice(), amount });
        }
    }

    fn lessThan(state: *Economy, lhs: u16, rhs: u16) bool {
        const a = state.accounts[lhs];
        const b = state.accounts[rhs];
        if (a.balance != b.balance) return a.balance > b.balance;
        return std.mem.lessThan(u8, a.nameSlice(), b.nameSlice());
    }
};

const Pay = struct {
    fn run(work: *Work, entry: *commands.Entry, words: *std.mem.TokenIterator(u8, .scalar)) void {
        entry.handled = true;
        const target_name = words.next() orelse return usage(work, entry.sender);
        const amount_text = words.next() orelse return usage(work, entry.sender);
        if (words.next() != null) return usage(work, entry.sender);
        const target = work.economy.findByName(target_name) orelse
            return work.outputs.system(entry.sender, "Unknown economy account: {s}", .{target_name});
        const amount = parseAmount(amount_text, work.economy.config.precision) catch
            return work.outputs.system(entry.sender, "Invalid amount", .{});
        const sender = &work.players.records[entry.sender];
        work.economy.transfer(sender.uuid, target, amount) catch |err|
            return work.outputs.system(entry.sender, "Payment failed: {s}", .{@errorName(err)});
        Display.balance(work, entry.sender, work.economy.balance(sender.uuid));
    }

    fn usage(work: *Work, sender: u16) void {
        work.outputs.system(sender, "Usage: /pay <player> <amount>", .{});
    }
};

const CommandRunner = struct {
    fn run(work: *Work, command_batch: *commands.Batch) void {
        for (work.players.active_slots[0..work.players.active_count]) |slot| {
            const player = &work.players.records[slot];
            _ = work.economy.ensure(player.uuid, player.name_slice()) catch continue;
        }
        for (command_batch.items()) |*entry| {
            if (entry.handled) continue;
            var words = std.mem.tokenizeScalar(u8, entry.text, ' ');
            const command = words.next() orelse continue;
            if (std.mem.eql(u8, command, "balance") or std.mem.eql(u8, command, "bal")) {
                entry.handled = true;
                if (words.next() != null) {
                    work.outputs.system(entry.sender, "Usage: /balance", .{});
                    continue;
                }
                const player = &work.players.records[entry.sender];
                const account = work.economy.ensure(player.uuid, player.name_slice()) catch {
                    work.outputs.system(entry.sender, "Economy account capacity reached", .{});
                    continue;
                };
                Display.balance(work, entry.sender, account.balance);
            } else if (std.mem.eql(u8, command, "baltop")) {
                entry.handled = true;
                if (words.next() != null) {
                    work.outputs.system(entry.sender, "Usage: /baltop", .{});
                    continue;
                }
                Display.top(work, entry.sender);
            } else if (std.mem.eql(u8, command, "pay")) Pay.run(work, entry, &words);
        }
    }
};

pub fn parseAmount(text: []const u8, precision: u8) !u128 {
    if (text.len == 0 or text[0] == '-') return error.InvalidAmount;
    const decimal = std.mem.indexOfScalar(u8, text, '.');
    const whole_text = if (decimal) |index| text[0..index] else text;
    const fraction_text = if (decimal) |index| text[index + 1 ..] else "";
    if (whole_text.len == 0 or fraction_text.len > precision) return error.InvalidAmount;
    const scale = try powerOfTen(precision);
    const whole = try std.fmt.parseInt(u128, whole_text, 10);
    var fraction: u128 = if (fraction_text.len == 0) 0 else try std.fmt.parseInt(u128, fraction_text, 10);
    for (fraction_text.len..precision) |_| fraction = try std.math.mul(u128, fraction, 10);
    const value = try std.math.add(u128, try std.math.mul(u128, whole, scale), fraction);
    if (value == 0) return error.InvalidAmount;
    return value;
}

pub fn formatAmount(buffer: []u8, amount: u128, plugin_config: Config) ![]const u8 {
    const scale = try powerOfTen(plugin_config.precision);
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{d}", .{amount / scale});
    if (plugin_config.precision != 0) {
        try writer.writeByte('.');
        const fraction = amount % scale;
        var digits: [18]u8 = undefined;
        var remaining = fraction;
        var index: usize = plugin_config.precision;
        while (index != 0) {
            index -= 1;
            digits[index] = @intCast('0' + remaining % 10);
            remaining /= 10;
        }
        try writer.writeAll(digits[0..plugin_config.precision]);
    }
    try writer.print(" {s}", .{plugin_config.unit});
    return writer.buffered();
}

pub fn encode(state: *const Economy, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll(storage_magic);
    try writer.writeInt(u16, @intCast(state.account_count), .little);
    for (state.accounts[0..state.account_count]) |account| {
        try writer.writeInt(u128, account.uuid, .little);
        try writer.writeInt(u128, account.balance, .little);
        try writer.writeByte(account.name_len);
        try writer.writeAll(account.nameSlice());
    }
    return writer.buffered();
}

pub fn decode(state: *Economy, bytes: []const u8) !void {
    var reader = std.Io.Reader.fixed(bytes);
    var magic: [storage_magic.len]u8 = undefined;
    try reader.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, storage_magic)) return error.InvalidEconomyData;
    const count = try reader.takeInt(u16, .little);
    if (count > state.accounts.len) return error.InvalidEconomyData;
    state.account_count = count;
    for (state.accounts[0..count]) |*account| {
        account.* = .{};
        account.uuid = try reader.takeInt(u128, .little);
        account.balance = try reader.takeInt(u128, .little);
        account.name_len = try reader.takeByte();
        if (account.name_len > account.name.len) return error.InvalidEconomyData;
        try reader.readSliceAll(account.name[0..account.name_len]);
    }
    if (reader.seek != bytes.len) return error.InvalidEconomyData;
    state.dirty = false;
}

fn encodedCapacity() usize {
    return storage_magic.len + @sizeOf(u16) + config.max_saved_players * (@sizeOf(u128) * 2 + 1 + config.max_username_bytes);
}

fn setName(account: *Account, name: []const u8) void {
    const len = @min(name.len, account.name.len);
    @memcpy(account.name[0..len], name[0..len]);
    account.name_len = @intCast(len);
}

fn powerOfTen(precision: u8) !u128 {
    var value: u128 = 1;
    for (0..precision) |_| value = try std.math.mul(u128, value, 10);
    return value;
}

test "amounts preserve configured precision" {
    try std.testing.expectEqual(@as(u128, 12_345), try parseAmount("123.45", 2));
    try std.testing.expectEqual(@as(u128, 12_300), try parseAmount("123", 2));
    try std.testing.expectError(error.InvalidAmount, parseAmount("0", 2));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("123.45 coins", try formatAmount(&buffer, 12_345, .{ .unit = "coins" }));
}

test "account data round trips without allocator state" {
    var source_accounts: [config.max_saved_players]Account = undefined;
    var restored_accounts: [config.max_saved_players]Account = undefined;
    @memset(&source_accounts, .{});
    @memset(&restored_accounts, .{});
    var source = Economy{
        .config = .{},
        .accounts = &source_accounts,
        .players = undefined,
        .outputs = undefined,
        .io = undefined,
    };
    try source.deposit(11, "alice", 500);
    try source.deposit(22, "bob", 725);
    var bytes: [encodedCapacity()]u8 = undefined;
    const encoded = try encode(&source, &bytes);
    var restored = Economy{
        .config = .{},
        .accounts = &restored_accounts,
        .players = undefined,
        .outputs = undefined,
        .io = undefined,
    };
    try decode(&restored, encoded);
    try std.testing.expectEqual(@as(u128, 500), restored.balance(11));
    try std.testing.expectEqual(@as(u128, 725), restored.balance(22));
}

test "an account cannot pay itself" {
    var accounts: [config.max_saved_players]Account = undefined;
    @memset(&accounts, .{});
    var economy = Economy{
        .config = .{},
        .accounts = &accounts,
        .players = undefined,
        .outputs = undefined,
        .io = undefined,
    };
    try economy.deposit(11, "alice", 500);
    const alice = economy.findByUuid(11).?;
    try std.testing.expectError(error.CannotPaySelf, economy.transfer(11, alice, 100));
    try std.testing.expectEqual(@as(u128, 500), economy.balance(11));
}
