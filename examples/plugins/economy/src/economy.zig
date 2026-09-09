const std = @import("std");
const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const commands = lightning_rod.commands;
const Packets = lightning_rod.Packets;

pub const ledger = @import("ledger.zig");
pub const service = @import("service.zig");
pub const Account = ledger.Account;

pub const Economy = struct {
    pub const id = "example:economy";
    pub const Configuration = struct {
        unit: []const u8 = "coin",
        precision: u8 = 2,
        maximum_accounts: usize,
        pub fn validate(self: Configuration) !void {
            if (self.unit.len == 0 or self.unit.len > 32) return error.InvalidCurrencyUnit;
            if (self.precision > 18) return error.InvalidCurrencyPrecision;
            if (self.maximum_accounts == 0 or self.maximum_accounts > std.math.maxInt(u16)) return error.InvalidAccountCapacity;
        }
    };
    pub const Dependencies = struct { persistence: lightning_rod.persistence.PluginAccess, players: *player_store.Players, outputs: *Packets };
    pub const command_declarations = [_]commands.Declaration{ .{ .name = "balance" }, .{ .name = "bal" }, .{ .name = "baltop" }, .{ .name = "pay" } };
    config: Configuration,
    ledger: ledger.Ledger,
    ranking: []u16 = &.{},
    persistence_buffer: []u8 = &.{},
    deps: Dependencies,
    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, settings: Configuration) !*Economy {
        try settings.validate();
        const self = try allocator.create(Economy);
        self.* = .{ .config = settings, .deps = deps, .ledger = ledger.Ledger.init(try allocator.alloc(Account, settings.maximum_accounts)) };
        self.ranking = try allocator.alloc(u16, settings.maximum_accounts);
        self.persistence_buffer = try allocator.alloc(u8, ledger.encodedCapacity(settings.maximum_accounts));
        try self.restore(); return self;
    }
    pub fn tick(self: *Economy, _: std.mem.Allocator) void { var work = Work{ .players = self.deps.players, .outputs = self.deps.outputs, .economy = self }; CommandRunner.run(&work, &self.deps.outputs.commands); }
    pub fn checkpoint(self: *Economy, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void { if (!self.ledger.dirty) return; const bytes = try ledger.encode(&self.ledger, self.persistence_buffer); try writer.put("state", bytes); self.ledger.dirty = false; }
    fn restore(self: *Economy) !void { const loaded = try self.deps.persistence.load("state", self.persistence_buffer); switch (loaded) { .missing => {}, .value => |length| try ledger.decode(&self.ledger, self.persistence_buffer[0..length]), } }
};
const Work = struct { players: *player_store.Players, outputs: *Packets, economy: *Economy };
const Display = struct {
    fn balance(work: *Work, slot: u16, amount: u128) void { var buffer: [160]u8 = undefined; const text = formatAmount(&buffer, amount, work.economy.config) catch return; work.outputs.system(slot, "Balance: {s}", .{text}); }
    fn top(work: *Work, slot: u16) void { for (0..work.economy.ledger.account_count) |index| work.economy.ranking[index] = @intCast(index); const active = work.economy.ranking[0..work.economy.ledger.account_count]; std.mem.sortUnstable(u16, active, work.economy, lessThan); if (active.len == 0) return work.outputs.system(slot, "No economy accounts", .{}); for (active[0..@min(active.len, 10)], 1..) |account_index, rank| { const account = &work.economy.ledger.accounts[account_index]; var amount_buffer: [128]u8 = undefined; const amount = formatAmount(&amount_buffer, account.balance, work.economy.config) catch continue; work.outputs.system(slot, "{d}. {s}: {s}", .{ rank, account.nameSlice(), amount }); } }
    fn lessThan(state: *Economy, lhs: u16, rhs: u16) bool { const a = state.ledger.accounts[lhs]; const b = state.ledger.accounts[rhs]; if (a.balance != b.balance) return a.balance > b.balance; return std.mem.lessThan(u8, a.nameSlice(), b.nameSlice()); }
};
const Pay = struct {
    fn run(work: *Work, entry: *commands.Entry, words: *std.mem.TokenIterator(u8, .scalar)) void { entry.handled = true; const target_name = words.next() orelse return usage(work, entry.sender); const amount_text = words.next() orelse return usage(work, entry.sender); if (words.next() != null) return usage(work, entry.sender); const target = (work.economy.ledger.findByName(target_name) catch return work.outputs.system(entry.sender, "That account name is ambiguous", .{})) orelse return work.outputs.system(entry.sender, "Unknown economy account: {s}", .{target_name}); const amount = parseAmount(amount_text, work.economy.config.precision) catch return work.outputs.system(entry.sender, "Invalid amount", .{}); const sender = &work.players.records[entry.sender]; work.economy.ledger.transfer(sender.uuid, target, amount) catch |err| return work.outputs.system(entry.sender, "Payment failed: {s}", .{@errorName(err)}); Display.balance(work, entry.sender, work.economy.ledger.balance(sender.uuid)); }
    fn usage(work: *Work, sender: u16) void { work.outputs.system(sender, "Usage: /pay <player> <amount>", .{}); }
};
const CommandRunner = struct {
    fn run(work: *Work, command_batch: *commands.Batch) void { for (work.players.active_slots[0..work.players.active_count]) |slot| { const player = &work.players.records[slot]; work.economy.ledger.ensure(player.uuid, player.name_slice()) catch continue; } for (command_batch.items()) |*entry| { if (entry.handled) continue; var words = std.mem.tokenizeScalar(u8, entry.text, ' '); const command = words.next() orelse continue; if (std.mem.eql(u8, command, "balance") or std.mem.eql(u8, command, "bal")) { entry.handled = true; if (words.next() != null) { work.outputs.system(entry.sender, "Usage: /balance", .{}); continue; } const player = &work.players.records[entry.sender]; work.economy.ledger.ensure(player.uuid, player.name_slice()) catch { work.outputs.system(entry.sender, "Economy account capacity reached", .{}); continue; }; Display.balance(work, entry.sender, work.economy.ledger.balance(player.uuid)); } else if (std.mem.eql(u8, command, "baltop")) { entry.handled = true; if (words.next() != null) { work.outputs.system(entry.sender, "Usage: /baltop", .{}); continue; } Display.top(work, entry.sender); } else if (std.mem.eql(u8, command, "pay")) Pay.run(work, entry, &words); } }
};
pub fn parseAmount(text: []const u8, precision: u8) !u128 { if (text.len == 0 or text[0] == '-') return error.InvalidAmount; const decimal = std.mem.indexOfScalar(u8, text, '.'); const whole_text = if (decimal) |index| text[0..index] else text; const fraction_text = if (decimal) |index| text[index + 1 ..] else ""; if (whole_text.len == 0 or fraction_text.len > precision) return error.InvalidAmount; const scale = try powerOfTen(precision); const whole = try std.fmt.parseInt(u128, whole_text, 10); var fraction: u128 = if (fraction_text.len == 0) 0 else try std.fmt.parseInt(u128, fraction_text, 10); for (fraction_text.len..precision) |_| fraction = try std.math.mul(u128, fraction, 10); const value = try std.math.add(u128, try std.math.mul(u128, whole, scale), fraction); if (value == 0) return error.InvalidAmount; return value; }
pub fn formatAmount(buffer: []u8, amount: u128, plugin_config: Economy.Configuration) ![]const u8 { const scale = try powerOfTen(plugin_config.precision); var writer = std.Io.Writer.fixed(buffer); try writer.print("{d}", .{amount / scale}); if (plugin_config.precision != 0) { try writer.writeByte('.'); const fraction = amount % scale; var digits: [18]u8 = undefined; var remaining = fraction; var index: usize = plugin_config.precision; while (index != 0) { index -= 1; digits[index] = @intCast('0' + remaining % 10); remaining /= 10; } try writer.writeAll(digits[0..plugin_config.precision]); } try writer.print(" {s}", .{plugin_config.unit}); return writer.buffered(); }
fn powerOfTen(precision: u8) !u128 { var value: u128 = 1; for (0..precision) |_| value = try std.math.mul(u128, value, 10); return value; }
test "amounts preserve configured precision" { try std.testing.expectEqual(@as(u128, 12_345), try parseAmount("123.45", 2)); try std.testing.expectEqual(@as(u128, 12_300), try parseAmount("123", 2)); try std.testing.expectError(error.InvalidAmount, parseAmount("0", 2)); var buffer: [64]u8 = undefined; try std.testing.expectEqualStrings("123.45 coins", try formatAmount(&buffer, 12_345, .{ .unit = "coins", .maximum_accounts = 1 })); }
test { _ = ledger; _ = service; }
