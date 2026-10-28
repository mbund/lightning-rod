const std = @import("std");
const inventories = @import("inventories");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const args = try e2e.profile.arguments(init);
    const mode: Mode = if (std.mem.startsWith(u8, args.fixture, "chests")) .chests else if (std.mem.startsWith(u8, args.fixture, "furnace")) .furnace else .crafting;
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = if (mode == .chests) 2 else 1, .render_distance = 2, .gamemode = .survival }),
        }),
        lightning_rod.plugin.configured(Probe, .{ .mode = mode }),
    });
    try e2e.profile.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

const Mode = enum { chests, furnace, crafting };
const chest: vanilla.BlockPosition = .{ .x = 2, .y = 65, .z = 0 };
const oven: vanilla.BlockPosition = .{ .x = 4, .y = 65, .z = 0 };
const bread_count = 17;

const Probe = struct {
    pub const id = "e2e:containers";
    pub const Configuration = struct { mode: Mode };
    pub const Dependencies = struct {
        players: *vanilla.Players,
        menus: *vanilla.PlayerInventory,
        inventories: *vanilla.Inventories,
        items: *vanilla.Items,
        chunks: *vanilla.Chunks,
        containers: *vanilla.Containers,
        reload: *vanilla.Reload,
        control: *e2e.Control,
    };
    deps: Dependencies,
    config: Configuration,
    ready: [2]u32 = @splat(0),
    resumed: bool,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps, .config = config, .resumed = if (deps.reload.latest()) |request| request.sequence > 0 else false };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        const player = self.deps.players.records[handle.index];
        if (std.mem.eql(u8, text, "ready")) {
            if (self.ready[handle.index] == handle.generation) return error.DuplicateContainerReady;
            self.ready[handle.index] = handle.generation;
            if (self.resumed) {
                if (self.config.mode == .furnace) {
                    const value = self.deps.containers.furnaceState(player.world, oven);
                    if (value.burn_left == 0 or value.burn_left > value.burn_total) return error.FurnaceDidNotResume;
                    const completed = std.mem.eql(u8, self.deps.reload.latest().?.token(), "e2e:furnace-taken");
                    if (completed) try self.assertPlayerCount(handle.index, "minecraft:iron_ingot", 2);
                    try self.deps.control.send(handle, if (completed) "complete" else "reloaded");
                } else try self.deps.control.send(handle, "reloaded");
                return .handled;
            }
            const expected: usize = if (self.config.mode == .chests) 2 else 1;
            for (self.ready[0..expected]) |generation| if (generation == 0) return .handled;
            try self.setup();
            for (self.deps.players.activeSlots()) |index| try self.deps.control.send(self.deps.players.records[index].handle.?, "setup");
        } else if (std.mem.eql(u8, text, "placed")) {
            const at = if (self.config.mode == .chests) chest else oven;
            const state = try self.deps.chunks.getBlock(player.world, at);
            const kind = self.deps.containers.states.kind(state) orelse return error.ContainerNotPlaced;
            switch (self.config.mode) {
                .chests => {
                    if (kind != .chest or self.deps.containers.states.facing(state) != .north or self.deps.containers.states.chestType(state) == .single) return error.ChestOrientation;
                    const partner = self.deps.containers.states.partner(state, at).?;
                    const other = try self.deps.chunks.getBlock(player.world, partner);
                    if (!std.meta.eql(self.deps.containers.states.partner(other, partner).?, at)) return error.ChestPairing;
                },
                .furnace => if (kind != .furnace or self.deps.containers.states.facing(state) != .east) return error.FurnaceOrientation,
                .crafting => if (kind != .crafting) return error.CraftingTableNotPlaced,
            }
            try self.deps.control.send(handle, "placed");
        } else if (std.mem.eql(u8, text, "deposited") or std.mem.eql(u8, text, "chest_checked")) {
            const view = self.deps.containers.views[handle.index];
            const value = try self.deps.inventories.get(.{ .owner = view.owners[0], .index = 0 });
            if (value.stack == null or value.stack.?.count != bread_count or try self.deps.items.kind(value.stack.?) != itemKind("minecraft:bread")) return error.ChestContentsIncorrect;
            if (std.mem.eql(u8, text, "deposited")) try self.deps.control.broadcast("deposited") else if (!self.resumed) try self.deps.reload.stage("e2e:chests") else try self.deps.control.send(handle, "verified");
        } else if (std.mem.eql(u8, text, "started")) {
            const value = self.deps.containers.furnaceState(player.world, oven);
            const input = protocols.registry.itemId("minecraft:raw_iron").?;
            if (value.burn_left == 0 or value.duration != self.deps.menus.recipes.recipes[@intCast(input)].?.ticks or value.cook == 0) return error.FurnaceTiming;
            try self.deps.reload.stage("e2e:furnace-started");
        } else if (std.mem.eql(u8, text, "cooked")) {
            const value = (try self.deps.inventories.get(vanilla.Containers.slot(player.world, oven, 2))).stack orelse return error.FurnaceOutputMissing;
            if (value.count != 2 or try self.deps.items.kind(value) != itemKind("minecraft:iron_ingot")) return error.FurnaceOutputIncorrect;
            if ((try self.deps.inventories.get(vanilla.Containers.slot(player.world, oven, 0))).stack != null) return error.FurnaceInputNotConsumed;
            try self.deps.control.send(handle, "cooked");
        } else if (std.mem.eql(u8, text, "taken")) {
            try self.assertPlayerCount(handle.index, "minecraft:iron_ingot", 2);
            if ((try self.deps.inventories.get(vanilla.Containers.slot(player.world, oven, 2))).stack != null) return error.FurnaceOutputDuplicated;
            try self.deps.reload.stage("e2e:furnace-taken");
        } else if (std.mem.eql(u8, text, "crafted")) {
            try self.assertCount(handle.index, "minecraft:oak_planks", 4, true);
            try self.assertCount(handle.index, "minecraft:furnace", 1, true);
            try self.deps.reload.stage("e2e:crafting");
        } else if (std.mem.eql(u8, text, "crafting_checked")) {
            try self.assertPlayerCount(handle.index, "minecraft:oak_planks", 4);
            try self.assertPlayerCount(handle.index, "minecraft:furnace", 1);
            try self.deps.control.send(handle, "verified");
        } else return .unhandled;
        return .handled;
    }

    fn setup(self: *Probe) !void {
        const world = self.deps.players.records[0].world;
        for (0..9) |x| for (0..7) |z| try self.deps.chunks.setBlock(world, .{ .x = @intCast(x), .y = 64, .z = @intCast(z) }, @intCast(protocols.registry.block_stone_default_state));
        for (self.deps.players.activeSlots()) |index| {
            const player = &self.deps.players.records[index];
            try self.deps.players.teleport(player, world, .{ .x = 4.5 + @as(f64, @floatFromInt(index)), .y = 65, .z = 3.5 }, .{ .yaw = 0, .pitch = 0 });
            try self.deps.menus.closeMenu(index);
            if (self.config.mode == .chests and !std.mem.eql(u8, player.name[0..player.name_len], "alice")) continue;
            const Spec = struct { slot: u16, name: []const u8, count: u16 };
            const specs: []const Spec = switch (self.config.mode) {
                .chests => &.{ .{ .slot = 36, .name = "minecraft:chest", .count = 2 }, .{ .slot = 37, .name = "minecraft:bread", .count = bread_count } },
                .furnace => &.{ .{ .slot = 36, .name = "minecraft:furnace", .count = 1 }, .{ .slot = 37, .name = "minecraft:raw_iron", .count = 2 }, .{ .slot = 38, .name = "minecraft:coal", .count = 1 } },
                .crafting => &.{ .{ .slot = 36, .name = "minecraft:crafting_table", .count = 1 }, .{ .slot = 37, .name = "minecraft:oak_log", .count = 1 }, .{ .slot = 38, .name = "minecraft:cobblestone", .count = 8 } },
            };
            for (specs) |spec| {
                const value = try self.deps.inventories.get(.{ .owner = player.uuid, .index = spec.slot });
                const committed = try self.deps.inventories.set(.{ .owner = player.uuid, .index = spec.slot }, value.revision, .{ .item = try self.deps.items.define(spec.name), .count = spec.count });
                std.debug.assert(committed);
            }
            self.deps.menus.changed(index);
        }
    }

    fn assertPlayerCount(self: *Probe, index: usize, name: []const u8, expected: u32) !void {
        return self.assertCount(index, name, expected, false);
    }

    fn assertCount(self: *Probe, index: usize, name: []const u8, expected: u32, transient: bool) !void {
        var count: u32 = 0;
        const owner = self.deps.players.records[index].uuid;
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        const length: usize = if (transient) 47 else 37;
        for (slots[0..length], 0..) |*slot, at| slot.* = .{ .owner = owner, .index = if (at < 37) @intCast(9 + at) else if (at == 37) std.math.maxInt(u16) else @intCast(vanilla.PlayerInventory.table_grid_first + at - 38) };
        try self.deps.inventories.getMany(slots[0..length], contents[0..length]);
        for (contents[0..length]) |value| if (value.stack) |stack| {
            if (try self.deps.items.kind(stack) == itemKind(name)) count += stack.count;
        };
        if (count != expected) return error.ContainerOwnershipIncorrect;
    }
};

fn itemKind(name: []const u8) u32 {
    return @intCast(protocols.registry.itemId(name).?);
}
