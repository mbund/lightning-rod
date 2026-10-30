const std = @import("std");
const storage = @import("storage");
const metrics = @import("metrics");
const sessions = @import("sessions");
const protocols = @import("protocols");
const inventories = @import("inventories");
const menu_click = @import("menu_click.zig");
const InventoryFixture = @import("inventory_test_fixture.zig").InventoryFixture;

fn countItems(stacks: []const ?inventories.Stack, items: [2]inventories.ItemId) ![2]u64 {
    var totals: [2]u64 = @splat(0);
    for (stacks) |entry| if (entry) |stack| {
        try std.testing.expect(stack.count > 0 and stack.count <= 64);
        const index = for (items, 0..) |item, at| {
            if (std.mem.eql(u8, &item, &stack.item)) break at;
        } else return error.UnexpectedItem;
        totals[index] += stack.count;
    };
    return totals;
}

test "adversarial clicks conserve items across every survival menu layout" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/clicks", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const items: [2]inventories.ItemId = .{ try fixture.items.define("minecraft:bread"), try fixture.items.define("minecraft:cooked_beef") };
    bounded.fail_index = bounded.alloc_index;
    const layouts = [_]struct { kind: menu_click.Kind, slots: usize }{
        .{ .kind = .player, .slots = 0 },
        .{ .kind = .chest, .slots = 27 },
        .{ .kind = .chest, .slots = 54 },
        .{ .kind = .furnace, .slots = 3 },
        .{ .kind = .crafting, .slots = 10 },
    };
    const buttons = [_]i8{ -1, 0, 1, 2, 4, 5, 6, 8, 9, 10, 40, 127 };
    for (layouts) |layout| for (0..16) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var next: [menu_click.maximum_slots]?inventories.Stack = @splat(null);
        var drag: menu_click.Drag = .{};
        const length = if (layout.kind == .player) 47 else layout.slots + 38;
        const menu: menu_click.Menu = .{ .inventory = fixture.menu, .player = fixture.players.records[0].uuid, .location = fixture.location(layout.kind), .kind = layout.kind, .container_slots = layout.slots, .stacks = next[0..length], .drag = &drag, .creative = false };
        for (menu.stacks, 0..) |*stack, index| {
            if (layout.kind == .player and index < 9) continue;
            if (layout.kind == .crafting and index == 0) continue;
            if (layout.kind == .furnace and index == 1) continue;
            if (index % 3 == 0) stack.* = .{ .item = items[index % 2], .count = @intCast(1 + index % 64) };
        }
        const expected = try countItems(menu.stacks, items);
        var dropped: [2]u64 = @splat(0);
        for (0..512) |step| {
            errdefer std.debug.print("menu conservation kind={t} slots={d} seed={d} step={d}\n", .{ layout.kind, layout.slots, seed, step });
            const slot: i16 = switch (random.random().uintLessThan(u8, 8)) {
                0 => -999,
                1 => -1,
                2 => std.math.minInt(i16),
                3 => std.math.maxInt(i16),
                else => @intCast(random.random().uintLessThan(usize, menu.visible() + 1)),
            };
            const phase = step % 16;
            const result = try menu.apply(.{
                .window_id = 1,
                .state_id = @bitCast(random.random().int(u32)),
                .slot = slot,
                .button = if (phase < 3) @intCast(phase) else buttons[random.random().uintLessThan(usize, buttons.len)],
                .mode = if (phase < 3) 5 else @as(i32, random.random().uintLessThan(u8, 9)) - 1,
            });
            for (result.drops[0..result.count]) |stack| {
                const counted = try countItems(&.{stack}, items);
                for (&dropped, counted) |*total, count| total.* += count;
            }
            const actual = try countItems(menu.stacks, items);
            for (expected, actual, dropped) |before, after, ground| try std.testing.expectEqual(before, after + ground);
        }
    };
}

test "crafting output clicks conserve ingredients including overflow drops" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/crafting", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const items: [2]inventories.ItemId = .{ try fixture.items.define("minecraft:oak_log"), try fixture.items.define("minecraft:oak_planks") };
    bounded.fail_index = bounded.alloc_index;
    for ([_]menu_click.Kind{ .player, .crafting }) |kind| for (0..64) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var next: [48]?inventories.Stack = @splat(null);
        var drag: menu_click.Drag = .{};
        const menu: menu_click.Menu = .{ .inventory = fixture.menu, .player = fixture.players.records[0].uuid, .location = fixture.location(kind), .kind = kind, .container_slots = if (kind == .player) 0 else 10, .stacks = next[0..if (kind == .player) 47 else 48], .drag = &drag, .creative = false };
        next[1] = .{ .item = items[0], .count = @intCast(seed + 1) };
        const begin: usize = if (kind == .player) 9 else 10;
        for (menu.stacks[begin..]) |*stack| if (random.random().boolean()) {
            stack.* = .{ .item = items[1], .count = 63 + @as(u16, @intFromBool(random.random().boolean())) };
        };
        const initial = try countItems(menu.stacks, items);
        const expected = initial[0] * 4 + initial[1];
        var dropped: u64 = 0;
        for (0..32) |step| {
            errdefer std.debug.print("craft conservation kind={t} seed={d} step={d}\n", .{ kind, seed, step });
            const buttons = [_]i8{ -1, 0, 1, 2, 8, 9, 40 };
            const result = try menu.apply(.{ .window_id = 1, .state_id = -1, .slot = 0, .button = buttons[random.random().uintLessThan(usize, buttons.len)], .mode = @as(i32, random.random().uintLessThan(u8, 9)) - 1 });
            for (result.drops[0..result.count]) |stack| {
                const count = try countItems(&.{stack}, items);
                dropped += count[0] * 4 + count[1];
            }
            const actual = try countItems(menu.stacks[1..], items);
            try std.testing.expectEqual(expected, actual[0] * 4 + actual[1] + dropped);
        }
    };
}
