const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");
const e2e = @import("e2e");
const minecraft = @import("minecraft_model");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 2, .render_distance = 2, .spawn_for_player = spawn }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

fn spawn(player: *const vanilla.Players.Player) minecraft.Position {
    return .{ .x = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) 20.5 else 21.5, .y = 65, .z = 20.5 };
}

const Probe = struct {
    pub const id = "e2e:occlusion";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        control: *e2e.Control,
        players: *vanilla.Players,
        chunks: *vanilla.Chunks,
        experience: *vanilla.Experience,
        dropped: *vanilla.ItemEntities,
        items: *vanilla.Items,
        streaming: *vanilla.Streaming,
    };
    deps: Dependencies,
    surface: [2]bool = .{ false, false },
    opened: [2]bool = .{ false, false },
    floor: [2]bool = .{ false, false },
    lid: [2]bool = .{ false, false },
    phase: enum { surface, entered, checking, opened, lid_opened, floor_opened, inside_block_waiting, inside_block } = .surface,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        const edits = try allocator.alloc(vanilla.BlockEdit, 4096);
        defer allocator.free(edits);
        for (edits, 0..) |*edit, index| edit.* = .{
            .index = @intCast(index),
            .state = if (index < 256) @intCast(protocols.registry.block_stone_default_state) else 0,
        };
        edits[4 * 16 + 4].state = @intCast(protocols.registry.block_gold_block_default_state);
        try deps.chunks.setBlocks(.{ .world = 0, .x = 1, .y = 1, .z = 1 }, edits);
        for ([_]i32{
            protocols.registry.block_spawner_default_state,
            protocols.registry.block_trial_spawner_default_state,
            protocols.registry.block_vault_default_state,
            protocols.registry.block_bee_nest_default_state,
            protocols.registry.block_beehive_default_state,
        }, 0..) |state, index| {
            try deps.chunks.setBlock(0, .{ .x = 24 + @as(i32, @intCast(index)), .y = 17, .z = 24 }, @intCast(state));
        }
        try deps.chunks.setBlock(0, .{ .x = 20, .y = 15, .z = 20 }, @intCast(protocols.registry.block_iron_block_default_state));
        try deps.chunks.setBlock(0, .{ .x = 20, .y = -1, .z = 20 }, @intCast(protocols.registry.block_emerald_block_default_state));
        try deps.chunks.setBlock(0, .{ .x = 20, .y = -32, .z = 20 }, @intCast(protocols.registry.block_diamond_block_default_state));
        var item: [1]u64 = undefined;
        try deps.dropped.createMany(&.{.{ .world = 0, .position = .{ 29.5, 17.5, 29.5 }, .stack = .{ .item = try deps.items.define("minecraft:diamond"), .count = 1 }, .metadata = .{ .pickup_delay = 32767 } }}, &item);
        try deps.experience.award(0, .{ 30.5, 17.5, 30.5 }, 1);
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        const player = &self.deps.players.records[handle.index];
        const alice = std.mem.eql(u8, player.name[0..player.name_len], "alice");
        if (std.mem.eql(u8, text, "surface_checked")) {
            if (self.phase != .surface) return error.UnexpectedOcclusionPhase;
            const index: usize = if (alice) 0 else 1;
            if (self.surface[index]) return error.DuplicateOcclusionObservation;
            self.surface[index] = true;
            if (!self.surface[0] or !self.surface[1]) return .handled;
            for (self.deps.players.records) |*subject| {
                if (subject.handle == null or !std.mem.eql(u8, subject.name[0..subject.name_len], "alice")) continue;
                try self.deps.players.teleport(subject, 0, .{ .x = 20.5, .y = 17, .z = 20.5 }, .{ .yaw = 0, .pitch = 70 });
            }
            self.phase = .entered;
            try self.broadcast("entered");
        } else if (std.mem.eql(u8, text, "inside_checked")) {
            if (!alice or self.phase != .entered) return error.UnexpectedOcclusionPhase;
            self.phase = .checking;
            try self.broadcast("check_surface");
        } else if (std.mem.eql(u8, text, "open")) {
            if (alice or self.phase != .checking) return error.UnexpectedOcclusionPhase;
            var edits: [16]vanilla.BlockEdit = undefined;
            for (2..5) |section| {
                const count: usize = if (section == 4) 1 else 16;
                for (edits[0..count], 0..) |*edit, y| edit.* = .{ .index = @intCast(y * 256 + 4 * 16 + 4), .state = 0 };
                try self.deps.chunks.setBlocks(.{ .world = 0, .x = 1, .y = @intCast(section), .z = 1 }, edits[0..count]);
            }
            self.phase = .opened;
            try self.broadcast("opened");
        } else if (std.mem.eql(u8, text, "opened_checked")) {
            if (self.phase != .opened) return error.UnexpectedOcclusionPhase;
            const index: usize = if (alice) 0 else 1;
            if (self.opened[index]) return error.DuplicateOcclusionObservation;
            self.opened[index] = true;
            if (!self.opened[0] or !self.opened[1]) return .handled;
            var edits: [256]vanilla.BlockEdit = undefined;
            for (&edits, 0..) |*edit, voxel| edit.* = .{ .index = @intCast(voxel), .state = 0 };
            try self.deps.chunks.setBlocks(.{ .world = 0, .x = 1, .y = 1, .z = 1 }, &edits);
            self.phase = .lid_opened;
            try self.broadcast("lid_opened");
        } else if (std.mem.eql(u8, text, "lid_checked")) {
            if (self.phase != .lid_opened) return error.UnexpectedOcclusionPhase;
            const index: usize = if (alice) 0 else 1;
            if (self.lid[index]) return error.DuplicateOcclusionObservation;
            self.lid[index] = true;
            if (!self.lid[0] or !self.lid[1]) return .handled;
            var edits: [4096]vanilla.BlockEdit = undefined;
            for (&edits, 0..) |*edit, voxel| edit.* = .{ .index = @intCast(voxel), .state = 0 };
            try self.deps.chunks.setBlocks(.{ .world = 0, .x = 1, .y = 0, .z = 1 }, &edits);
            self.phase = .floor_opened;
            try self.broadcast("floor_opened");
        } else if (std.mem.eql(u8, text, "floor_checked")) {
            if (self.phase != .floor_opened) return error.UnexpectedOcclusionPhase;
            const index: usize = if (alice) 0 else 1;
            if (self.floor[index]) return error.DuplicateOcclusionObservation;
            self.floor[index] = true;
            if (!self.floor[0] or !self.floor[1]) return .handled;
            for (self.deps.players.records) |*subject| {
                if (subject.handle == null or !std.mem.eql(u8, subject.name[0..subject.name_len], "bob")) continue;
                try self.deps.players.teleport(subject, 0, .{ .x = 21.5, .y = -8, .z = 20.5 }, .{ .yaw = 0, .pitch = 0 });
            }
            self.phase = .inside_block_waiting;
        } else return .unhandled;
        return .handled;
    }

    pub fn tick(self: *Probe) !void {
        if (self.phase != .inside_block_waiting) return;
        for (self.deps.players.records, 0..) |*player, index| {
            if (player.handle == null or !std.mem.eql(u8, player.name[0..player.name_len], "bob")) continue;
            if (player.stage != .ready) return;
            if (self.deps.streaming.snapshotVisibility().sectionVisible(index, player, .{ .world = 0, .x = 1, .y = 1, .z = 1 })) return;
            self.phase = .inside_block;
            try self.broadcast("inside_block");
            return;
        }
    }

    fn broadcast(self: *Probe, text: []const u8) !void {
        for (self.deps.players.records) |player| if (player.handle) |handle| try self.deps.control.send(handle, text);
    }
};
