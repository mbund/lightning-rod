const Control = @import("e2e_control").Control;
const std = @import("std");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");
const inventories = @import("inventories");

pub const Inventory = struct {
    pub const id = "e2e:inventory";
    pub const Configuration = struct { starting_bread: u16 = 0 };
    pub const Dependencies = struct {
        control: *Control,
        dropped: *vanilla.ItemEntities,
        entities: *vanilla.Entities,
        inventories: *vanilla.Inventories,
        items: *vanilla.Items,
        menus: *vanilla.PlayerInventory,
        players: *vanilla.Players,
        sessions: *sessions.Service,
    };
    deps: Dependencies,
    starting_bread: u16,
    given: []u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Inventory {
        const given = try allocator.alloc(u32, deps.players.records.len);
        @memset(given, 0);
        const self = try allocator.create(Inventory);
        self.* = .{ .deps = deps, .given = given, .starting_bread = config.starting_bread };
        deps.control.on(self, message);
        return self;
    }

    pub fn tick(self: *Inventory) !void {
        if (self.starting_bread == 0) return;
        for (self.deps.sessions.input_events) |event| {
            if (event == .joined and event.joined.cause != .login)
                self.given[event.joined.handle.index] = event.joined.handle.generation;
        }

        for (self.deps.players.records, self.given, 0..) |*player, *given, index| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready or !player.loaded or given.* == handle.generation) continue;

            const slot = try self.deps.inventories.get(.{ .owner = player.uuid, .index = 36 });
            if (slot.stack == null and !try self.deps.menus.give(index, "minecraft:bread", self.starting_bread)) return error.InventorySetup;
            given.* = handle.generation;
        }
    }

    fn message(self: *Inventory, handle: sessions.Handle, text: []const u8) !Control.Result {
        const player_index = handle.index;
        const player = self.deps.players.records[player_index];
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        const verb = words.next() orelse return .unhandled;
        const setup = std.mem.eql(u8, verb, "inventory_setup");
        if (!setup and !std.mem.eql(u8, verb, "inventory_check")) return .unhandled;
        const label = words.next() orelse return error.MissingInventoryLabel;
        var descriptions: [47]?[]const u8 = @splat(null);
        var counts: [47]u16 = @splat(0);
        var expected_drops: ?u32 = null;
        while (words.next()) |word| {
            if (std.mem.startsWith(u8, word, "drops/")) {
                expected_drops = try std.fmt.parseInt(u32, word[6..], 10);
                continue;
            }
            var fields = std.mem.splitScalar(u8, word, '/');
            const index = try std.fmt.parseInt(usize, fields.next().?, 10);
            if (index >= descriptions.len or descriptions[index] != null) return error.InvalidInventorySlot;
            descriptions[index] = fields.next() orelse return error.MissingInventoryItem;
            counts[index] = try std.fmt.parseInt(u16, fields.next() orelse return error.MissingInventoryCount, 10);
        }
        var matches = true;
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        for (&slots, 0..) |*slot, index| slot.* = .{ .owner = player.uuid, .index = if (index == vanilla.PlayerInventory.cursor) std.math.maxInt(u16) else @intCast(index) };
        try self.deps.inventories.getMany(&slots, &contents);
        if (expected_drops) |expected| {
            var dropped: u32 = 0;
            var cursor: vanilla.ItemEntities.Cursor = .{};
            while (cursor.more) for (try self.deps.dropped.scan(&cursor)) |row| {
                if (!row.metadata.alive) continue;
                const body = (try self.deps.entities.get(row.id)).?;
                const held = try self.deps.inventories.get(vanilla.ItemEntities.slot(body));
                dropped += held.stack.?.count;
            };
            matches = matches and dropped == expected;
            std.log.info("event=inventory_drops case={s} expected={d} actual={d}", .{ label, expected, dropped });
        }
        var edits: [47]inventories.Edit = undefined;
        for (descriptions, counts, contents, 0..) |name, count, value, index| {
            if (!setup and index == 46 and player.gamemode == .creative) continue;
            if (setup) {
                edits[index] = .{
                    .slot = slots[index],
                    .revision = value.revision,
                    .stack = if (name) |item| .{ .item = try self.deps.items.define(item), .count = count } else null,
                };
            } else {
                const actual = if (value.stack) |stack| protocols.registry.itemName(@intCast(try self.deps.items.kind(stack))).? else "empty";
                const actual_count: u16 = if (value.stack) |stack| stack.count else 0;
                if (actual_count != count or !std.mem.eql(u8, actual, name orelse "empty")) {
                    std.log.err("event=inventory_mismatch case={s} slot={d} expected={s}/{d} actual={s}/{d}", .{ label, index, name orelse "empty", count, actual, actual_count });
                    matches = false;
                    break;
                }
            }
        }
        if (setup) {
            const applied = try self.deps.inventories.editMany(&edits);
            std.debug.assert(applied);
            self.deps.menus.changed(player_index);
        }
        var reply: [160]u8 = undefined;
        try self.deps.control.send(handle, try std.fmt.bufPrint(&reply, "Inventory {s} {s}", .{ label, if (setup) "ready" else if (matches) "verified" else "mismatch" }));
        std.log.info("event=inventory_{s} case={s}", .{ if (setup) "setup" else if (matches) "verified" else "mismatch", label });
        return .handled;
    }
};
