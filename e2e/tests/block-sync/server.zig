const std = @import("std");
const registry = @import("protocols").registry;
const fixture = @import("../../src/fixture.zig");
const vanilla = @import("vanilla");
const sessions = @import("sessions");

const Dependencies = fixture.Context;
pub const settings: fixture.Settings = .{ .kind = .block_sync, .delta_sections = 2 };

pub const Fixture = struct {
    single_blocks: u64 = 0,
    single_full: u64 = 0,
    clock_left: u16 = 0,
    clock_blocks: u64 = 0,
    clock_full: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !Fixture {
        _ = allocator;
        _ = deps;
        return .{};
    }

    pub fn command(self: *Fixture, deps: Dependencies, handle: sessions.Handle, text: []const u8) !void {
        const player = &deps.players.records[handle.index];
        if (player.stage != .ready or !player.loaded) return;
        for (0..1) |_| {
            if (std.mem.eql(u8, text, "blocks_clock")) {
                self.clock_left = 64;
                self.clock_blocks = deps.synchronization.blocks;
                self.clock_full = deps.synchronization.full_sections;
                continue;
            }

            if (std.mem.eql(u8, text, "blocks_clock_check")) {
                const sent = deps.synchronization.blocks - self.clock_blocks;
                if (self.clock_left != 0 or sent < 64 or sent > 128 or deps.synchronization.full_sections != self.clock_full)
                    return error.BlockClockAmplification;
                std.log.info("event=block_clock_verified ticks=64 encoded_blocks={d}", .{sent});
                deps.chat.system(handle, "Block clock verified");
                continue;
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
                try deps.chunks.setSections(&sections);
                try deps.chunks.setBlock(0, .{ .x = -32, .y = 144, .z = -32 }, @intCast(registry.blockStateId("minecraft:gold_block").?));
                continue;
            }

            if (std.mem.eql(u8, text, "blocks_single")) {
                self.single_blocks = deps.synchronization.blocks;
                self.single_full = deps.synchronization.full_sections;
                try deps.chunks.setBlocks(.{ .world = 0, .x = std.math.maxInt(i32), .y = 4, .z = std.math.minInt(i32) }, &.{.{ .index = 0, .state = registry.block_stone_default_state }});
                const gold: u16 = @intCast(registry.blockStateId("minecraft:gold_block").?);

                for (0..64) |step| try deps.chunks.setBlock(0, .{ .x = 33, .y = 208, .z = 33 }, if (step % 2 == 0) registry.block_dirt_default_state else gold);
                continue;
            }

            if (std.mem.eql(u8, text, "blocks_check")) {
                const sync = deps.synchronization;
                if (sync.evictions == 0 or sync.full_sections == 0 or sync.full_sections != self.single_full or sync.blocks - self.single_blocks > 2)
                    return error.BlockSynchronizationAccounting;
                std.log.info("event=block_sync_verified evictions={d} full_sections={d} packets={d} blocks={d} final_edit_blocks={d} backpressured={d}", .{ sync.evictions, sync.full_sections, sync.packets, sync.blocks, sync.blocks - self.single_blocks, sync.backpressured });
                deps.chat.system(handle, "Block synchronization verified");
                continue;
            }

            const added = std.mem.eql(u8, text, "blocks_add");
            const removed = std.mem.eql(u8, text, "blocks_remove");
            if (!added and !removed) continue;
            try deps.chunks.setBlocks(.{ .world = 0, .x = 0, .y = 4, .z = 0 }, &.{
                .{ .index = 2, .state = if (added) registry.block_dirt_default_state else 0 },
                .{ .index = 2, .state = if (added) registry.block_stone_default_state else 0 },
                .{ .index = 18, .state = if (added) registry.block_dirt_default_state else 0 },
            });
            try deps.chunks.setBlock(0, .{ .x = -1, .y = 64, .z = -1 }, if (added) registry.block_stone_default_state else 0);
        }
    }

    pub fn tick(self: *Fixture, deps: Dependencies) !void {
        if (self.clock_left > 0) {
            self.clock_left -= 1;
            try deps.chunks.setBlock(0, .{ .x = 32 + self.clock_left % 16, .y = 209, .z = 32 + self.clock_left / 16 }, @intCast(registry.blockStateId("minecraft:gold_block").?));
            if (self.clock_left == 0) for (deps.players.records) |player| {
                const handle = player.handle orelse continue;
                deps.chat.system(handle, "Block clock completed");
            };
        }
    }
};
