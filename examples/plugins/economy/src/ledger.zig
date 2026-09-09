const std = @import("std");

pub const maximum_name_bytes = 16;
const storage_header = "LRECON01";

pub const Account = struct {
    uuid: u128 = 0,
    balance: u128 = 0,
    name: [maximum_name_bytes]u8 = undefined,
    name_len: u8 = 0,

    pub fn nameSlice(self: *const Account) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Ledger = struct {
    accounts: []Account,
    account_count: usize = 0,
    dirty: bool = false,

    pub fn init(accounts: []Account) Ledger {
        std.debug.assert(accounts.len != 0 and accounts.len <= std.math.maxInt(u16));
        @memset(accounts, .{});
        return .{ .accounts = accounts };
    }

    pub fn balance(self: *Ledger, uuid: u128) u128 {
        const account = self.findByUuid(uuid) orelse return 0;
        return account.balance;
    }

    pub fn ensure(self: *Ledger, uuid: u128, name: []const u8) error{ AccountCapacity, InvalidName }!void {
        if (name.len == 0 or name.len > maximum_name_bytes) return error.InvalidName;
        const index = self.lowerBound(uuid);
        if (index < self.account_count and self.accounts[index].uuid == uuid) {
            const account = &self.accounts[index];
            if (!std.mem.eql(u8, account.nameSlice(), name)) {
                setName(account, name);
                self.markDirty();
            }
            return;
        }
        if (self.account_count == self.accounts.len) return error.AccountCapacity;
        std.mem.copyBackwards(Account, self.accounts[index + 1 .. self.account_count + 1], self.accounts[index..self.account_count]);
        const account = &self.accounts[index];
        self.account_count += 1;
        account.* = .{ .uuid = uuid };
        setName(account, name);
        self.markDirty();
    }

    pub fn deposit(self: *Ledger, uuid: u128, name: []const u8, amount: u128) !void {
        const balance_after = try std.math.add(u128, self.balance(uuid), amount);
        try self.ensure(uuid, name);
        const account = self.findByUuid(uuid).?;
        account.balance = balance_after;
        self.markDirty();
    }

    pub fn withdraw(self: *Ledger, uuid: u128, amount: u128) error{InsufficientFunds}!void {
        const account = self.findByUuid(uuid) orelse return error.InsufficientFunds;
        if (account.balance < amount) return error.InsufficientFunds;
        account.balance -= amount;
        self.markDirty();
    }

    pub fn transfer(self: *Ledger, sender: u128, recipient: u128, amount: u128) !void {
        if (amount == 0) return error.InvalidAmount;
        if (sender == recipient) return error.CannotPaySelf;
        const source = self.findByUuid(sender) orelse return error.InsufficientFunds;
        const target = self.findByUuid(recipient) orelse return error.UnknownAccount;
        if (source.balance < amount) return error.InsufficientFunds;
        const destination = try std.math.add(u128, target.balance, amount);
        source.balance -= amount;
        target.balance = destination;
        self.markDirty();
    }

    pub fn findByName(self: *const Ledger, name: []const u8) error{AmbiguousAccount}!?u128 {
        var found: ?u128 = null;
        for (self.accounts[0..self.account_count]) |*account| {
            if (!std.ascii.eqlIgnoreCase(account.nameSlice(), name)) continue;
            if (found != null) return error.AmbiguousAccount;
            found = account.uuid;
        }
        return found;
    }

    fn findByUuid(self: *Ledger, uuid: u128) ?*Account {
        const index = self.lowerBound(uuid);
        if (index == self.account_count or self.accounts[index].uuid != uuid) return null;
        return &self.accounts[index];
    }

    fn lowerBound(self: *const Ledger, uuid: u128) usize {
        var low: usize = 0;
        var high = self.account_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.accounts[mid].uuid < uuid) low = mid + 1 else high = mid;
        }
        return low;
    }

    fn markDirty(self: *Ledger) void {
        self.dirty = true;
    }
};

pub fn encode(state: *const Ledger, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll(storage_header);
    try writer.writeInt(u16, @intCast(state.account_count), .little);
    for (state.accounts[0..state.account_count]) |account| {
        try writer.writeInt(u128, account.uuid, .little);
        try writer.writeInt(u128, account.balance, .little);
        try writer.writeByte(account.name_len);
        try writer.writeAll(account.nameSlice());
    }
    return writer.buffered();
}

pub fn decode(state: *Ledger, bytes: []const u8) !void {
    var reader = std.Io.Reader.fixed(bytes);
    var header: [storage_header.len]u8 = undefined;
    try reader.readSliceAll(&header);
    if (!std.mem.eql(u8, &header, storage_header)) return error.InvalidEconomyData;
    const count = try reader.takeInt(u16, .little);
    if (count > state.accounts.len) return error.InvalidEconomyData;
    for (state.accounts[0..count]) |*account| {
        account.* = .{};
        account.uuid = try reader.takeInt(u128, .little);
        account.balance = try reader.takeInt(u128, .little);
        account.name_len = try reader.takeByte();
        if (account.name_len == 0 or account.name_len > account.name.len) return error.InvalidEconomyData;
        try reader.readSliceAll(account.name[0..account.name_len]);
    }
    if (reader.seek != bytes.len) return error.InvalidEconomyData;
    std.mem.sortUnstable(Account, state.accounts[0..count], {}, struct {
        fn lessThan(_: void, a: Account, b: Account) bool {
            return a.uuid < b.uuid;
        }
    }.lessThan);
    for (state.accounts[0..count], 0..) |account, index| {
        if (index != 0 and state.accounts[index - 1].uuid == account.uuid) return error.InvalidEconomyData;
    }
    state.account_count = count;
    state.dirty = false;
}

pub fn encodedCapacity(maximum_accounts: usize) usize {
    return storage_header.len + @sizeOf(u16) + maximum_accounts * (@sizeOf(u128) * 2 + 1 + maximum_name_bytes);
}

fn setName(account: *Account, name: []const u8) void {
    std.debug.assert(name.len != 0 and name.len <= account.name.len);
    @memcpy(account.name[0..name.len], name);
    account.name_len = @intCast(name.len);
}

test "account data round trips without allocator state" {
    var source_accounts: [2]Account = undefined;
    var restored_accounts: [2]Account = undefined;
    @memset(&source_accounts, .{});
    @memset(&restored_accounts, .{});
    var source = Ledger{
        .accounts = &source_accounts,
    };
    try source.deposit(22, "bob", 725);
    try source.deposit(11, "alice", 500);
    try std.testing.expectEqual(@as(u128, 11), source.accounts[0].uuid);
    try std.testing.expectEqual(@as(u128, 22), source.accounts[1].uuid);
    try source.transfer(11, 22, 200);
    var bytes: [encodedCapacity(source_accounts.len)]u8 = undefined;
    std.mem.swap(Account, &source.accounts[0], &source.accounts[1]);
    const encoded = try encode(&source, &bytes);
    std.mem.swap(Account, &source.accounts[0], &source.accounts[1]);
    var restored = Ledger{
        .accounts = &restored_accounts,
    };
    try decode(&restored, encoded);
    try std.testing.expectEqual(@as(u128, 300), restored.balance(11));
    try std.testing.expectEqual(@as(u128, 925), restored.balance(22));
    try std.testing.expectEqual(@as(u128, 11), restored.accounts[0].uuid);
    _ = try encode(&source, &bytes);
    const second = storage_header.len + 2 + 16 + 16 + 1 + "alice".len;
    std.mem.writeInt(u128, bytes[second..][0..16], 11, .little);
    var invalid = Ledger.init(&restored_accounts);
    try std.testing.expectError(error.InvalidEconomyData, decode(&invalid, encoded));
    try std.testing.expectEqual(@as(usize, 0), invalid.account_count);
    _ = try encode(&source, &bytes);
    bytes[storage_header.len + 2 + 32] = 0;
    try std.testing.expectError(error.InvalidEconomyData, decode(&invalid, encoded));
    const empty = try encode(&invalid, &bytes);
    try decode(&invalid, empty);
    try std.testing.expectEqual(@as(usize, 0), invalid.account_count);
}

test "an account cannot pay itself" {
    var accounts: [1]Account = undefined;
    @memset(&accounts, .{});
    var economy = Ledger{
        .accounts = &accounts,
    };
    try economy.deposit(11, "alice", 500);
    try std.testing.expectError(error.CannotPaySelf, economy.transfer(11, 11, 100));
    try std.testing.expectEqual(@as(u128, 500), economy.balance(11));
}

test "rejected financial operations preserve balances names and dirty state" {
    var accounts = [_]Account{.{}} ** 2;
    var economy = Ledger{
        .accounts = &accounts,
    };
    try economy.deposit(11, "alice", std.math.maxInt(u128));
    try economy.deposit(22, "bob", 10);
    economy.dirty = false;
    try std.testing.expectError(error.Overflow, economy.deposit(11, "renamed", 1));
    try std.testing.expectError(error.Overflow, economy.transfer(22, 11, 1));
    try std.testing.expectError(error.UnknownAccount, economy.transfer(22, 33, 1));
    try std.testing.expectError(error.InvalidName, economy.deposit(22, "a_name_too_long_for_the_account", 1));
    try std.testing.expectError(error.InsufficientFunds, economy.withdraw(22, 11));
    try std.testing.expectError(error.AccountCapacity, economy.deposit(33, "third", 1));
    try std.testing.expectEqualStrings("alice", accounts[0].nameSlice());
    try std.testing.expectEqual(std.math.maxInt(u128), economy.balance(11));
    try std.testing.expectEqual(@as(u128, 10), economy.balance(22));
    try std.testing.expectEqual(@as(usize, 2), economy.account_count);
    try std.testing.expect(!economy.dirty);
}
