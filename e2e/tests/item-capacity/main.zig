const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const vanilla = @import("vanilla");
const Chunks = @import("chunks").Chunks;
const Entities = @import("entities").Entities;
const Inventories = @import("inventories").Inventories;
const Players = @import("players").players.Players;
const e2e = @import("e2e");
const sessions = @import("sessions");
const inventories = @import("inventories");

/// Items are never refused or lost, however little memory they have: every bound below is far
/// smaller than what the test makes, so their states and bodies page through scratch files.
pub fn main(init: std.process.Init) !void {
    const args = try e2e.profile.arguments(init);
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, Players.Configuration{ .render_distance = 2 }),
            lightning_rod.plugin.configured(vanilla.PlayerStates, .{ .gamemode = if (std.mem.eql(u8, args.fixture, "creative")) .creative else .survival }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

const Probe = struct {
    pub const id = "e2e:item-capacity";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        control: *e2e.Control,
        players: *Players,
        dropped: *vanilla.ItemEntities,
        entities: *Entities,
        inventories: *Inventories,
        items: *vanilla.Items,
        menus: *vanilla.PlayerInventory,
        player_states: *vanilla.PlayerStates,
        chunks: *Chunks,
    };
    const bread_count = 17;
    /// Far more than any cache above holds.
    const frozen_count = 200;
    const block: @import("chunks").Position = .{ .x = 1, .y = 65, .z = 1 };

    const Phase = enum { waiting, placed, mining, mined, closing, verified };

    deps: Dependencies,
    phase: Phase = .waiting,
    /// Items there were before the block broke.
    before_mining: usize = 0,
    /// Stone there was before the menu closed.
    stone: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    pub fn tick(self: *Probe) !void {
        if (self.phase != .mining) return;
        const world = self.deps.players.records[0].world;
        if (try (try self.deps.chunks.simulation(1)).getBlock(world, block) == protocols.registry.block_stone_default_state) return;
        // Broken: its drop came, refused for nothing.
        const totals = try self.count();
        if (totals.alive != self.before_mining + 1) return error.MinedDropMissing;
        try self.freeze();
        self.phase = .mined;
        try self.deps.control.send(self.deps.players.records[0].handle.?, "capacity mined kept");
    }

    const Totals = struct { alive: usize = 0, bread: u32 = 0, stone: u32 = 0 };

    /// Stone the player holds anywhere in its menu, cursor included.
    fn heldStone(self: *Probe, player: usize) !u32 {
        const stone = try self.deps.items.define("minecraft:stone");
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        try self.deps.menus.load(player, &slots, &contents);
        var total: u32 = 0;
        for (contents) |entry| if (entry.stack) |stack| {
            if (std.mem.eql(u8, &stack.item, &stone)) total += stack.count;
        };
        return total;
    }

    /// Keeps every item where it is, so the player standing by picks none up while counted.
    fn freeze(self: *Probe) !void {
        var rows = self.deps.dropped.rows();
        while ((try rows.next())) |row| {
            if (!row.metadata.alive or row.metadata.pickup_delay == std.math.maxInt(i16)) continue;
            var metadata = try self.deps.dropped.get(row.id);
            metadata.pickup_delay = std.math.maxInt(i16);
            try self.deps.dropped.put(row.id, metadata);
        }
    }

    /// Every live item, by reading every record.
    fn count(self: *Probe) !Totals {
        var totals: Totals = .{};
        const bread = try self.deps.items.define("minecraft:bread");
        var rows = self.deps.dropped.rows();
        while ((try rows.next())) |row| {
            if (!row.metadata.alive) continue;
            totals.alive += 1;
            const body = (try self.deps.entities.getById(row.id)) orelse return error.BodyLost;
            const stack = (try self.deps.inventories.get(vanilla.ItemEntities.slot(body))).stack orelse return error.StackLost;
            if (std.mem.eql(u8, &stack.item, &bread)) totals.bread += stack.count;
            if (std.mem.eql(u8, &stack.item, &(try self.deps.items.define("minecraft:stone")))) totals.stone += stack.count;
        }
        return totals;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        const player = self.deps.players.records[handle.index];
        const creative = self.deps.player_states.of(&player).gamemode == .creative;
        if (std.mem.eql(u8, text, "capacity_setup")) {
            if (self.phase != .waiting) return error.UnexpectedCapacityPhase;
            if (!try self.deps.menus.give(handle.index, "minecraft:bread", bread_count)) return error.SetupFailed;
            if (!try self.deps.menus.give(handle.index, "minecraft:iron_pickaxe", 1)) return error.SetupFailed;
            const stone = try self.deps.items.define("minecraft:stone");
            // Out of reach and never picked up, around the player in several chunks.
            for (0..frozen_count) |i| {
                const x = 6.5 + @as(f64, @floatFromInt(i % 20)) * 1.5;
                const z = -14.5 + @as(f64, @floatFromInt(i / 20)) * 3;
                const entity = try self.deps.dropped.create(player.world, .{ x, 65, z }, .{ 0, 0, 0 }, .{ .item = stone, .count = 1 });
                try self.deps.dropped.put(entity, .{ .pickup_delay = std.math.maxInt(i16), .age = std.math.minInt(i16) });
            }
            try self.deps.chunks.setBlock(player.world, block, protocols.registry.block_stone_default_state);
            self.phase = .placed;
            try self.deps.control.send(handle, "capacity placed");
        } else if (std.mem.eql(u8, text, "capacity_check_drop")) {
            if (self.phase != .placed) return error.UnexpectedCapacityPhase;
            // The whole stack dropped, and in creative four more: none refused.
            const totals = try self.count();
            const expected_bread: u32 = bread_count + if (creative) @as(u32, 4) else 0;
            if (totals.bread != expected_bread) return error.DroppedBreadMissing;
            if (totals.alive < @as(usize, frozen_count) + 1) return error.DropCountWrong;
            if ((try self.deps.inventories.get(.{ .owner = player.uuid, .index = 36 })).stack != null) return error.DropNotApplied;
            try self.freeze();
            self.before_mining = totals.alive;
            if (creative) {
                self.phase = .verified;
                try self.deps.control.send(handle, "capacity creative kept");
            } else {
                self.phase = .mining;
                try self.deps.control.send(handle, "capacity drops kept");
            }
        } else if (std.mem.eql(u8, text, "capacity_close_setup")) {
            if (self.phase != .mined) return error.UnexpectedCapacityPhase;
            const stone = try self.deps.items.define("minecraft:stone");
            for (9..46) |slot| {
                const previous = try self.deps.inventories.get(.{ .owner = player.uuid, .index = @intCast(slot) });
                if (!try self.deps.inventories.set(.{ .owner = player.uuid, .index = @intCast(slot) }, previous.revision, .{ .item = stone, .count = 64 })) return error.SetupFailed;
            }
            for ([_]u16{ 1, 2, 3, 4 }) |slot| {
                const previous = try self.deps.inventories.get(.{ .owner = player.uuid, .index = slot });
                if (!try self.deps.inventories.set(.{ .owner = player.uuid, .index = slot }, previous.revision, .{ .item = stone, .count = 1 })) return error.SetupFailed;
            }
            self.deps.menus.changed(handle.index);
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try self.deps.menus.load(handle.index, &slots, &contents);
            var next: [47]?inventories.Stack = undefined;
            for (&next, contents) |*stack, entry| stack.* = entry.stack;
            next[36].?.count -= 1;
            next[vanilla.PlayerInventory.cursor] = .{ .item = stone, .count = 1 };
            if (!try self.deps.menus.apply(handle.index, &slots, &contents, &next, &.{})) return error.SetupFailed;
            // Stone in items and in the menu, which closing must keep all of.
            self.stone = (try self.count()).stone + try self.heldStone(handle.index);
            self.phase = .closing;
            try self.deps.control.send(handle, "capacity close ready");
        } else if (std.mem.eql(u8, text, "capacity_close_check")) {
            if (self.phase != .closing) return error.UnexpectedCapacityPhase;
            // Closing with all but a full inventory put back what fit and dropped the rest of the
            // crafting grid and the cursor: none of it refused, none lost.
            if ((try self.count()).stone + try self.heldStone(handle.index) != self.stone) return error.CloseLostStone;
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try self.deps.menus.load(handle.index, &slots, &contents);
            for ([_]usize{ 1, 2, 3, 4, vanilla.PlayerInventory.cursor }) |slot| {
                if (contents[slot].stack != null) return error.CloseNotApplied;
            }
            self.phase = .verified;
            try self.deps.control.send(handle, "capacity close kept");
        } else return .unhandled;
        return .handled;
    }
};
