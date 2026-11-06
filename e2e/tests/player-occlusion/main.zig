const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");
const e2e = @import("e2e");
const minecraft = @import("minecraft_model");
const render_distance = 2;

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 2, .render_distance = render_distance, .spawn_for_player = spawn }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

fn spawn(player: *const vanilla.Players.Player) minecraft.Position {
    return .{ .x = 20.5, .y = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) 65 else 17, .z = 20.5 };
}

const Probe = struct {
    pub const id = "e2e:player_occlusion";
    pub const Configuration = struct {};
    pub const Dependencies = struct { control: *e2e.Control, players: *vanilla.Players, chunks: *vanilla.Chunks, streaming: *vanilla.Streaming };
    deps: Dependencies,
    checked: [2]bool = @splat(false),
    edit: usize = 0,
    phase: enum { hidden, visible, settling, editing, hidden_again, visible_again, verified } = .hidden,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        const edits = try allocator.alloc(vanilla.BlockEdit, 4096);
        defer allocator.free(edits);
        for (edits, 0..) |*edit, index| edit.* = .{ .index = @intCast(index), .state = if (index < 256) @intCast(protocols.registry.block_stone_default_state) else 0 };
        try deps.chunks.setBlocks(.{ .world = 0, .x = 1, .y = 1, .z = 1 }, edits);
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        const expected: []const u8 = switch (self.phase) {
            .hidden => "hidden_checked",
            .visible => "visible_checked",
            .settling => return .unhandled,
            .editing => "edit_checked",
            .hidden_again => "hidden_again_checked",
            .visible_again => "visible_again_checked",
            .verified => return .unhandled,
        };
        if (!std.mem.eql(u8, text, expected)) return .unhandled;
        const player = &self.deps.players.records[handle.index];
        const index: usize = if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) 0 else 1;
        if (self.checked[index]) return error.UnexpectedOcclusionObservation;
        self.checked[index] = true;
        if (!self.checked[0] or !self.checked[1]) return .handled;
        self.phase = switch (self.phase) {
            .hidden => .visible,
            .visible => .settling,
            .editing => if (self.edit < 8) .editing else .hidden_again,
            .hidden_again => .visible_again,
            .visible_again => .verified,
            .verified => unreachable,
            .settling => unreachable,
        };
        if (self.phase == .settling) return .handled;
        if (self.phase == .verified) {
            for (self.deps.players.records) |subject| if (subject.handle) |recipient| try self.deps.control.send(recipient, "verified");
            return .handled;
        }
        self.checked = @splat(false);
        if (self.phase == .editing) {
            try self.nextEdit();
            return .handled;
        }
        const open = self.phase != .hidden_again;
        var edits: [16]vanilla.BlockEdit = undefined;
        for (2..5) |section| {
            const count: usize = if (section == 4) 1 else 16;
            for (edits[0..count], 0..) |*edit, y| edit.* = .{ .index = @intCast(y * 256 + 4 * 16 + 5), .state = if (open) 0 else @intCast(protocols.registry.block_stone_default_state) };
            try self.deps.chunks.setBlocks(.{ .world = 0, .x = 1, .y = @intCast(section), .z = 1 }, edits[0..count]);
        }
        for (self.deps.players.records) |subject| if (subject.handle) |recipient| try self.deps.control.send(recipient, switch (self.phase) {
            .visible => "opened",
            .hidden_again => "closed",
            .visible_again => "reopened",
            else => unreachable,
        });
        return .handled;
    }

    pub fn tick(self: *Probe) !void {
        if (self.phase != .settling) return;
        const visibility = self.deps.streaming.snapshotVisibility();
        for (self.deps.players.activeSlots()) |index| {
            const stream = visibility.streams[index];
            if (stream.setup != .streaming or stream.cursor != (2 * render_distance + 1) * (2 * render_distance + 1)) return;
        }
        self.phase = .editing;
        self.checked = @splat(false);
        try self.nextEdit();
    }

    fn nextEdit(self: *Probe) !void {
        const placed = self.edit % 2 == 0;
        try self.deps.chunks.setBlock(0, .{ .x = 22, .y = 17, .z = 20 }, if (placed) @intCast(protocols.registry.block_stone_default_state) else 0);
        self.edit += 1;
        for (self.deps.players.records) |subject| if (subject.handle) |recipient| try self.deps.control.send(recipient, if (placed) "edit_placed" else "edit_broken");
    }
};
