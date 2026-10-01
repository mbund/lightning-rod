const std = @import("std");
const fixture = @import("../../src/fixture.zig");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");

const Dependencies = fixture.Context;
pub const settings: fixture.Settings = .{
    .kind = .inventory,
    .players = .{ .gamemode = .survival, .spawn = .{ .x = 0.5, .y = 65, .z = 0.5 } },
};

pub const Fixture = struct {
    given: []u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !Fixture {
        const given = try allocator.alloc(u32, deps.players.records.len);
        @memset(given, 0);
        return .{ .given = given };
    }

    pub fn tick(self: *Fixture, deps: Dependencies) !void {
        for (deps.sessions.input_events) |event| {
            if (event == .joined and event.joined.cause == .reload)
                self.given[event.joined.handle.index] = event.joined.handle.generation;
        }

        for (deps.players.records, self.given, 0..) |*player, *given, index| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready or !player.loaded or given.* != 0) continue;

            const slot = try deps.inventories.get(.{ .owner = player.uuid, .index = 36 });
            if (slot.stack == null and !try deps.menus.give(index, "minecraft:bread", 17)) return error.InventorySetup;
            given.* = handle.generation;
        }
    }

    pub fn command(self: *Fixture, deps: Dependencies, handle: sessions.Handle, text: []const u8) !void {
        _ = self;
        const player_index = handle.index;
        const player = deps.players.records[player_index];
        for (0..1) |_| {
            var words = std.mem.tokenizeScalar(u8, text, ' ');
            const verb = words.next() orelse continue;
            if (std.mem.eql(u8, verb, "inventory_refresh")) {
                deps.menus.changed(player_index);
                continue;
            }
            const setup = std.mem.eql(u8, verb, "inventory_setup");
            if (!setup and !std.mem.eql(u8, verb, "inventory_check")) continue;
            const label = words.next() orelse return error.MissingInventoryLabel;
            var descriptions: [47]?[]const u8 = @splat(null);
            var counts: [47]u16 = @splat(0);
            var expected_drops: ?u32 = null;
            var expected_pending: ?[]const u8 = null;
            var pending_count: u16 = 0;
            while (words.next()) |word| {
                if (std.mem.startsWith(u8, word, "drops/")) {
                    expected_drops = try std.fmt.parseInt(u32, word[6..], 10);
                    continue;
                }
                if (std.mem.startsWith(u8, word, "pending/")) {
                    var fields = std.mem.splitScalar(u8, word[8..], '/');
                    expected_pending = fields.next() orelse return error.MissingInventoryItem;
                    pending_count = try std.fmt.parseInt(u16, fields.next() orelse return error.MissingInventoryCount, 10);
                    continue;
                }
                var fields = std.mem.splitScalar(u8, word, '/');
                const index = try std.fmt.parseInt(usize, fields.next().?, 10);
                if (index >= descriptions.len or descriptions[index] != null) return error.InvalidInventorySlot;
                descriptions[index] = fields.next() orelse return error.MissingInventoryItem;
                counts[index] = try std.fmt.parseInt(u16, fields.next() orelse return error.MissingInventoryCount, 10);
            }
            var matches = true;
            if (setup or expected_pending != null) {
                var key: [16]u8 = undefined;
                std.mem.writeInt(u128, &key, player.uuid, .big);
                const recovery = try deps.menus.recovery.acquire(&key);
                defer recovery.release();
                if (setup) {
                    if (recovery.read() != null) recovery.remove();
                } else {
                    var actual: []const u8 = "empty";
                    var actual_count: u16 = 0;
                    if (recovery.read()) |bytes| {
                        actual_count = std.mem.readInt(u16, bytes[32..34], .little);
                        actual = protocols.registry.itemName(@intCast(try deps.items.kind(.{ .item = bytes[0..32].*, .count = actual_count }))).?;
                    }
                    matches = actual_count == pending_count and std.mem.eql(u8, actual, expected_pending.?);
                    if (!matches) std.log.err("event=inventory_recovery_mismatch case={s} expected={s}/{d} actual={s}/{d}", .{ label, expected_pending.?, pending_count, actual, actual_count });
                }
            }
            if (expected_drops) |expected| {
                var dropped: u32 = 0;
                var cursor: vanilla.ItemEntities.Cursor = .{};
                while (cursor.more) for (try deps.dropped.scan(&cursor)) |row| {
                    if (!row.metadata.alive) continue;
                    const body = (try deps.entities.get(row.id)).?;
                    const held = try deps.inventories.get(vanilla.ItemEntities.slot(body));
                    dropped += held.stack.?.count;
                };
                matches = matches and dropped == expected;
                std.log.info("event=inventory_drops case={s} expected={d} actual={d}", .{ label, expected, dropped });
            }
            for (descriptions, counts, 0..) |name, count, index| {
                if (!setup and index == 46 and player.gamemode == .creative) continue;
                const slot: u16 = if (index == 46) 65535 else @intCast(index);
                const value = try deps.inventories.get(.{ .owner = player.uuid, .index = slot });
                if (setup) {
                    const committed = try deps.inventories.editMany(&.{.{
                        .slot = .{ .owner = player.uuid, .index = slot },
                        .revision = value.revision,
                        .stack = if (name) |item| .{ .item = try deps.items.define(item), .count = count } else null,
                    }});
                    std.debug.assert(committed);
                } else {
                    const actual = if (value.stack) |stack| protocols.registry.itemName(@intCast(try deps.items.kind(stack))).? else "empty";
                    const actual_count: u16 = if (value.stack) |stack| stack.count else 0;
                    if (actual_count != count or !std.mem.eql(u8, actual, name orelse "empty")) {
                        std.log.err("event=inventory_mismatch case={s} slot={d} expected={s}/{d} actual={s}/{d}", .{ label, index, name orelse "empty", count, actual, actual_count });
                        matches = false;
                        break;
                    }
                }
            }
            if (setup) deps.menus.changed(player_index);
            var message: [160]u8 = undefined;
            deps.chat.system(handle, try std.fmt.bufPrint(&message, "Inventory {s} {s}", .{ label, if (setup) "ready" else if (matches) "verified" else "mismatch" }));
            std.log.info("event=inventory_{s} case={s}", .{ if (setup) "setup" else if (matches) "verified" else "mismatch", label });
        }
    }
};
