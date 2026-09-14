const std = @import("std");
const storage = @import("storage");
const records = @import("records");

pub const Economy = struct {
    pub const id = "economy:accounts";

    pub const Configuration = struct {
        unit: []const u8 = "coin",
        precision: u8 = 2,
        cache_accounts: usize = 64,
        initial_balance: u128 = 0,
    };

    pub const Dependencies = struct { storage: storage.Namespace };

    config: Configuration,
    deps: Dependencies,
    cache: records.Cache,

    pub const Account = struct {
        lease: records.Cache.Lease,
        balance: u128,

        pub fn set(self: *Account, balance: u128) void {
            std.mem.writeInt(u128, self.lease.edit()[1..17], balance, .little);
            self.lease.commit(34);
            self.balance = balance;
        }

        pub fn release(self: Account) void {
            self.lease.release();
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Economy {
        if (config.unit.len == 0 or config.unit.len > 32 or config.precision > 18 or config.cache_accounts < 2) return error.InvalidConfiguration;

        const self = try allocator.create(Economy);
        self.* = .{
            .config = config,
            .deps = deps,
            .cache = try records.Cache.init(allocator, io, deps.storage, .{ .slots = config.cache_accounts, .key_bytes = 16, .value_bytes = 34 }),
        };
        return self;
    }

    pub fn acquire(self: *Economy, uuid: u128, name: []const u8) !Account {
        std.debug.assert(name.len > 0 and name.len <= 16);
        var key: [16]u8 = undefined;
        std.mem.writeInt(u128, &key, uuid, .big);
        const lease = try self.cache.acquire(&key);
        errdefer lease.release();
        if (lease.read()) |bytes| {
            if (bytes.len != 34 or bytes[0] != 1 or bytes[17] == 0 or bytes[17] > 16) return error.Corrupt;

            const balance = std.mem.readInt(u128, bytes[1..17], .little);

            if (!std.mem.eql(u8, bytes[18..][0..bytes[17]], name)) {
                const edited = lease.edit();
                edited[17] = @intCast(name.len);
                @memset(edited[18..34], 0);
                @memcpy(edited[18..][0..name.len], name);
                lease.commit(34);
            }

            return .{ .lease = lease, .balance = balance };
        }

        const bytes = lease.edit();
        @memset(bytes[0..34], 0);
        bytes[0] = 1;
        std.mem.writeInt(u128, bytes[1..17], self.config.initial_balance, .little);
        bytes[17] = @intCast(name.len);
        @memcpy(bytes[18..][0..name.len], name);
        lease.commit(34);
        return .{ .lease = lease, .balance = self.config.initial_balance };
    }

    pub fn transfer(self: *Economy, from: u128, from_name: []const u8, to: u128, to_name: []const u8, amount: u128) !bool {
        if (amount == 0 or from == to) return false;

        var source = try self.acquire(from, from_name);
        defer source.release();
        if (source.balance < amount) return false;

        var destination = try self.acquire(to, to_name);
        defer destination.release();
        const after = std.math.add(u128, destination.balance, amount) catch return false;
        source.set(source.balance - amount);
        destination.set(after);
        return true;
    }

    pub fn checkpoint(self: *Economy, _: storage.Namespace) !void {
        try self.cache.flush();
    }
};

pub fn parseAmount(text: []const u8, precision: u8) !u128 {
    if (text.len == 0 or precision > 18) return error.InvalidAmount;

    var value: u128 = 0;
    var fractional: ?usize = null;

    for (text) |byte| {
        if (byte == '.' and fractional == null) {
            fractional = 0;
            continue;
        }

        if (byte < '0' or byte > '9') return error.InvalidAmount;
        value = try std.math.add(u128, try std.math.mul(u128, value, 10), byte - '0');

        if (fractional) |count| fractional = count + 1;
    }

    const digits = fractional orelse 0;
    if (digits > precision) return error.InvalidAmount;

    for (digits..precision) |_| value = try std.math.mul(u128, value, 10);
    if (value == 0) return error.InvalidAmount;
    return value;
}

pub fn formatAmount(buffer: []u8, amount: u128, config: Economy.Configuration) ![]const u8 {
    var scale: u128 = 1;

    for (0..config.precision) |_| scale *= 10;
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{d}", .{amount / scale});

    if (config.precision != 0) {
        try writer.writeByte('.');
        var digits: [18]u8 = undefined;
        var fraction = amount % scale;
        var index: usize = config.precision;

        while (index != 0) {
            index -= 1;
            digits[index] = @intCast('0' + fraction % 10);
            fraction /= 10;
        }

        try writer.writeAll(digits[0..config.precision]);
    }

    try writer.print(" {s}", .{config.unit});
    return writer.buffered();
}
