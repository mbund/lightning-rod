const std = @import("std");
const lr = @import("lightning_rod");
const protocols = @import("protocols");
const vanilla = @import("vanilla");
const e2e = @import("e2e");
const sessions = @import("sessions");
const registry = protocols.registry;
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const args = try bootstrap.arguments(init);
    const plugins = lr.plugin.compose(.{
        lr.plugin.replace(bootstrap.plugins(), .{
            lr.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = if (std.mem.eql(u8, args.fixture, "creative")) .creative else .survival }),
            lr.plugin.configured(vanilla.ItemEntities, vanilla.ItemEntities.Configuration{ .maximum = 2 }),
        }),
        lr.plugin.configured(Probe, .{}),
    });
    try bootstrap.run(init, plugins, .{ .plaintext = true });
}

const Probe = struct {
    pub const id = "e2e:item-capacity";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        control: *e2e.Control,
        players: *vanilla.Players,
        dropped: *vanilla.ItemEntities,
        entities: *vanilla.Entities,
        inventories: *vanilla.Inventories,
        items: *vanilla.Items,
        menus: *vanilla.PlayerInventory,
        chunks: *vanilla.Chunks,
        mining: *vanilla.Mining,
    };
    const bread_count = 17;

    const Phase = enum { waiting, full, releasing, available, refilled, preparing_close, close_ready, verified };
    const Mining = enum { waiting, active, rejected };

    deps: Dependencies,
    frozen: [2]u64 = undefined,
    tool: [32]u8 = undefined,
    phase: Phase = .waiting,
    mining: Mining = .waiting,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    pub fn tick(self: *Probe) !void {
        if (self.phase == .full and self.mining != .rejected) {
            const state = self.deps.mining.states[0];
            if (state.active and state.position.x == 1 and state.position.y == 65 and state.position.z == 1)
                self.mining = .active;
            if (self.mining == .active and !state.active) {
                if (try self.deps.chunks.getBlock(self.deps.players.records[0].world, .{ .x = 1, .y = 65, .z = 1 }) != registry.block_stone_default_state)
                    return error.BlockMinedAtCapacity;
                self.mining = .rejected;
                try self.deps.control.send(self.deps.players.records[0].handle.?, "capacity mining rejected");
            }
        }
        if ((self.phase == .releasing or self.phase == .preparing_close) and self.deps.dropped.canCreate(1)) {
            self.phase = if (self.phase == .releasing) .available else .close_ready;
            try self.deps.control.send(self.deps.players.records[0].handle.?, if (self.phase == .close_ready) "capacity close ready" else "capacity freed");
        }
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        const player = self.deps.players.records[handle.index];
        if (std.mem.eql(u8, text, "capacity_setup")) {
            if (self.phase != .waiting) return error.UnexpectedCapacityPhase;
            if (!try self.deps.menus.give(handle.index, "minecraft:bread", bread_count)) return error.SetupFailed;
            if (!try self.deps.menus.give(handle.index, "minecraft:iron_pickaxe", 1)) return error.SetupFailed;
            self.tool = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = 37 })).stack.?.item;
            const stone = try self.deps.items.define("minecraft:stone");
            for (&self.frozen, 0..) |*entity, i| {
                entity.* = try self.deps.dropped.create(player.world, .{ 5.5 + @as(f64, @floatFromInt(i)), 65, 5.5 }, .{ 0, 0, 0 }, .{ .item = stone, .count = 1 });
                try self.deps.dropped.put(entity.*, .{ .pickup_delay = std.math.maxInt(i16), .age = std.math.minInt(i16) });
            }
            try self.deps.chunks.setBlock(player.world, .{ .x = 1, .y = 65, .z = 1 }, registry.block_stone_default_state);
            self.phase = .full;
            try self.deps.control.send(handle, "capacity full");
        } else if (std.mem.eql(u8, text, "capacity_check")) {
            if (self.phase != .full) return error.UnexpectedCapacityPhase;
            const held = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = 36 })).stack orelse return error.InventoryLost;
            if (held.count != bread_count or self.deps.dropped.canCreate(1)) return error.CapacityDropApplied;
            const tool = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = 37 })).stack orelse return error.ToolLost;
            if (!std.mem.eql(u8, &tool.item, &self.tool)) return error.ToolWornAtCapacity;
            if (try self.deps.chunks.getBlock(player.world, .{ .x = 1, .y = 65, .z = 1 }) != registry.block_stone_default_state) return error.BlockMinedAtCapacity;
            try self.deps.control.send(handle, "capacity unchanged");
        } else if (std.mem.eql(u8, text, "capacity_free")) {
            if (self.phase != .full) return error.UnexpectedCapacityPhase;
            const entity = self.frozen[0];
            var metadata = try self.deps.dropped.get(entity);
            const body = (try self.deps.entities.get(entity)).?;
            const slot = vanilla.ItemEntities.slot(body);
            const held = try self.deps.inventories.get(slot);
            if (!try self.deps.inventories.set(slot, held.revision, null)) return error.RetirementFailed;
            try self.deps.dropped.retire(entity, body, &metadata);
            self.phase = .releasing;
        } else if (std.mem.eql(u8, text, "capacity_verify")) {
            if (self.phase != .available) return error.UnexpectedCapacityPhase;
            const held = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = 36 })).stack orelse return error.InventoryLost;
            if (held.count != bread_count - 1 or self.deps.dropped.canCreate(1)) return error.AdmittedDropMissing;
            for (self.deps.dropped.residents) |resident| {
                if (resident.id == 0 or !resident.alive) continue;
                var metadata = try self.deps.dropped.get(resident.id);
                metadata.pickup_delay = std.math.maxInt(i16);
                metadata.age = std.math.minInt(i16);
                try self.deps.dropped.put(resident.id, metadata);
            }
            self.phase = .refilled;
            try self.deps.control.send(handle, "capacity resumed");
        } else if (std.mem.eql(u8, text, "capacity_close_setup")) {
            if (self.phase != .refilled) return error.UnexpectedCapacityPhase;
            const entity = self.frozen[1];
            var metadata = try self.deps.dropped.get(entity);
            const body = (try self.deps.entities.get(entity)).?;
            const held = try self.deps.inventories.get(vanilla.ItemEntities.slot(body));
            if (!try self.deps.inventories.set(vanilla.ItemEntities.slot(body), held.revision, null)) return error.RetirementFailed;
            try self.deps.dropped.retire(entity, body, &metadata);
            const stone = try self.deps.items.define("minecraft:stone");
            for (9..46) |slot| {
                const previous = try self.deps.inventories.get(.{ .owner = player.uuid, .index = @intCast(slot) });
                if (!try self.deps.inventories.set(.{ .owner = player.uuid, .index = @intCast(slot) }, previous.revision, .{ .item = stone, .count = 64 })) return error.SetupFailed;
            }
            for ([_]u16{ 1, 2, 3, 4, std.math.maxInt(u16) }) |slot| {
                const previous = try self.deps.inventories.get(.{ .owner = player.uuid, .index = slot });
                if (!try self.deps.inventories.set(.{ .owner = player.uuid, .index = slot }, previous.revision, .{ .item = stone, .count = 1 })) return error.SetupFailed;
            }
            self.deps.menus.changed(handle.index);
            self.phase = .preparing_close;
        } else if (std.mem.eql(u8, text, "capacity_close_check")) {
            if (self.phase != .close_ready) return error.UnexpectedCapacityPhase;
            if (self.deps.dropped.free_count != 1) return error.PartialCloseDrop;
            for ([_]u16{ 1, 2, 3, 4, std.math.maxInt(u16) }) |slot| {
                const contents = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = slot })).stack orelse return error.CloseInventoryLost;
                if (contents.count != 1) return error.CloseInventoryLost;
            }
            self.phase = .verified;
            try self.deps.control.send(handle, "capacity close preserved");
        } else return .unhandled;
        return .handled;
    }
};
