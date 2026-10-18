const std = @import("std");
const lr = @import("lightning_rod");
const protocols = @import("protocols");
const vanilla = @import("vanilla");
const e2e = @import("e2e");
const registry = protocols.registry;
const sessions = @import("sessions");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const plugins = lr.plugin.compose(.{
        lr.plugin.replace(bootstrap.plugins(), .{
            lr.plugin.configured(vanilla.BlockSynchronization, .{ .delta_sections = 2 }),
        }),
        lr.plugin.configured(Probe, .{}),
    });
    try bootstrap.run(init, plugins, .{});
}

const Probe = struct {
    pub const id = "e2e:block-sync";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        chunks: *vanilla.Chunks,
        control: *e2e.Control,
        players: *vanilla.Players,
        synchronization: *vanilla.BlockSynchronization,
    };
    const clock_ticks = 64;

    deps: Dependencies,
    single_blocks: u64 = 0,
    single_full: u64 = 0,
    clock_left: u16 = 0,
    clock_blocks: u64 = 0,
    clock_full: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        const player = &self.deps.players.records[handle.index];
        if (player.stage != .ready or !player.loaded) return .unhandled;
        if (std.mem.eql(u8, text, "blocks_clock")) {
            self.clock_left = clock_ticks;
            self.clock_blocks = self.deps.synchronization.blocks;
            self.clock_full = self.deps.synchronization.full_sections;
            return .handled;
        }

        if (std.mem.eql(u8, text, "blocks_clock_check")) {
            const sent = self.deps.synchronization.blocks - self.clock_blocks;
            if (self.clock_left != 0 or sent < clock_ticks or sent > 2 * clock_ticks or self.deps.synchronization.full_sections != self.clock_full)
                return error.BlockClockAmplification;
            std.log.info("event=block_clock_verified ticks={d} encoded_blocks={d}", .{ clock_ticks, sent });
            try self.deps.control.send(handle, "Block clock verified");
            return .handled;
        }

        if (std.mem.eql(u8, text, "blocks_burst")) {
            var edits: [4096]vanilla.BlockEdit = undefined;
            var sections: [125]vanilla.SectionEdits = undefined;

            for (&edits, 0..) |*edit, local| edit.* = .{
                .index = @intCast(local),
                .state = if (local % 2 == 0) registry.block_stone_default_state else registry.block_dirt_default_state,
            };

            for (&sections, 0..) |*batch, section| batch.* = .{
                .section = .{
                    .world = 0,
                    .x = @as(i32, @intCast(section % 5)) - 2,
                    .y = 9 + @as(i32, @intCast(section / 25)),
                    .z = @as(i32, @intCast(section / 5 % 5)) - 2,
                },
                .edits = &edits,
            };
            try self.deps.chunks.setSections(&sections);
            try self.deps.chunks.setBlock(0, .{ .x = -32, .y = 144, .z = -32 }, @intCast(registry.blockStateId("minecraft:gold_block").?));
            return .handled;
        }

        if (std.mem.eql(u8, text, "blocks_single")) {
            self.single_blocks = self.deps.synchronization.blocks;
            self.single_full = self.deps.synchronization.full_sections;
            try self.deps.chunks.setBlocks(.{ .world = 0, .x = std.math.maxInt(i32), .y = 4, .z = std.math.minInt(i32) }, &.{.{ .index = 0, .state = registry.block_stone_default_state }});
            const gold: u16 = @intCast(registry.blockStateId("minecraft:gold_block").?);

            for (0..64) |step| try self.deps.chunks.setBlock(0, .{ .x = 33, .y = 208, .z = 33 }, if (step % 2 == 0) registry.block_dirt_default_state else gold);
            return .handled;
        }

        if (std.mem.eql(u8, text, "blocks_check")) {
            const sync = self.deps.synchronization;
            if (sync.evictions == 0 or sync.full_sections == 0 or sync.full_sections != self.single_full or sync.blocks - self.single_blocks > 2)
                return error.BlockSynchronizationAccounting;
            std.log.info("event=block_sync_verified evictions={d} full_sections={d} packets={d} blocks={d} final_edit_blocks={d} backpressured={d}", .{ sync.evictions, sync.full_sections, sync.packets, sync.blocks, sync.blocks - self.single_blocks, sync.backpressured });
            try self.deps.control.send(handle, "Block synchronization verified");
            return .handled;
        }

        const added = std.mem.eql(u8, text, "blocks_add");
        const removed = std.mem.eql(u8, text, "blocks_remove");
        if (!added and !removed) return .unhandled;
        try self.deps.chunks.setBlocks(.{ .world = 0, .x = 0, .y = 4, .z = 0 }, &.{
            .{ .index = 2, .state = if (added) registry.block_dirt_default_state else 0 },
            .{ .index = 2, .state = if (added) registry.block_stone_default_state else 0 },
            .{ .index = 18, .state = if (added) registry.block_dirt_default_state else 0 },
        });
        try self.deps.chunks.setBlock(0, .{ .x = -1, .y = 64, .z = -1 }, if (added) registry.block_stone_default_state else 0);
        return .handled;
    }

    pub fn tick(self: *Probe) !void {
        if (self.clock_left > 0) {
            self.clock_left -= 1;
            try self.deps.chunks.setBlock(0, .{ .x = 32 + self.clock_left % 16, .y = 209, .z = 32 + self.clock_left / 16 }, @intCast(registry.blockStateId("minecraft:gold_block").?));
            if (self.clock_left == 0) for (self.deps.players.records) |player| {
                const handle = player.handle orelse continue;
                try self.deps.control.send(handle, "Block clock completed");
            };
        }
    }
};
