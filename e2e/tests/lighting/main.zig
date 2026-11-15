const std = @import("std");
const lightning_rod = @import("lightning_rod");
const BlockEdit = @import("chunks").BlockEdit;
const BlockPosition = @import("chunks").Position;
const Chunks = @import("chunks").Chunks;
const LightSample = @import("terrain").lighting.Sample;
const Lighting = @import("terrain").lighting.Lighting;
const Players = @import("players").players.Players;
const Reload = @import("reload").Reload;
const SectionEdits = @import("chunks").SectionEdits;
const protocols = @import("protocols");
const sessions = @import("sessions");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = 2, .render_distance = 2 }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

const Probe = struct {
    pub const id = "e2e:lighting";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *Players,
        chunks: *Chunks,
        lighting: *Lighting,
        control: *e2e.Control,
        reload: *Reload,
    };
    const Phase = enum { waiting, lit, obstructed, dark, opened, closed, restored, reloaded };
    const source: BlockPosition = .{ .x = 15, .y = 66, .z = 2 };
    const obstruction: BlockPosition = .{ .x = 16, .y = 66, .z = 2 };
    const opening: BlockPosition = .{ .x = 17, .y = 69, .z = 2 };
    const stone: u16 = protocols.registry.block_stone_default_state;
    const glowstone: u16 = @intCast(protocols.registry.block_glowstone_default_state);

    /// Ticks the expected light may take to settle before the probe fails.
    const wait_limit = 100;

    deps: Dependencies,
    phase: Phase = .waiting,
    observed: u2 = 0,
    checking: bool = false,
    waited: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        if (deps.reload.latest()) |request| if (request.sequence != 0) {
            self.phase = .reloaded;
        };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "ready") and !std.mem.eql(u8, text, "observed")) return .unhandled;
        const ready = self.phase == .waiting or self.phase == .reloaded;
        if (!std.mem.eql(u8, text, if (ready) "ready" else "observed")) return error.UnexpectedLightingMessage;
        std.debug.assert(handle.index < 2);
        const bit = @as(u2, 1) << @as(u1, @intCast(handle.index));
        if (self.observed & bit != 0) return error.DuplicateLightingObservation;
        self.observed |= bit;
        if (self.observed != 3) return .handled;
        self.observed = 0;
        switch (self.phase) {
            .waiting => {
                var sections: [2]SectionEdits = undefined;
                var edits: [2][6 * 6 * 6]BlockEdit = undefined;
                var counts: [2]usize = .{ 0, 0 };
                for (14..20) |x| for (0..6) |z| for (64..70) |y| {
                    const column: usize = @intFromBool(x >= 16);
                    const wall = x == 14 or x == 19 or z == 0 or z == 5 or y == 64 or y == 69;
                    edits[column][counts[column]] = .{ .index = @intCast((y % 16) * 256 + z * 16 + x % 16), .state = if (wall) stone else 0 };
                    counts[column] += 1;
                };
                for (&sections, 0..) |*section, x| section.* = .{ .section = .{ .world = 0, .x = @intCast(x), .y = 4, .z = 0 }, .edits = edits[x][0..counts[x]] };
                try self.deps.chunks.setSections(&sections);
                try self.deps.chunks.setBlock(0, source, glowstone);
                for (self.deps.players.records, 0..) |*player, index| {
                    try self.deps.players.teleport(player, 0, .{ .x = 16.5 + @as(f64, @floatFromInt(index)), .y = 65, .z = 3.5 }, .{ .yaw = 180, .pitch = 0 });
                }
                self.phase = .lit;
            },
            .lit => {
                try self.deps.chunks.setBlock(0, obstruction, stone);
                self.phase = .obstructed;
            },
            .obstructed => {
                try self.deps.chunks.setBlock(0, source, 0);
                try self.deps.chunks.setBlock(0, obstruction, 0);
                self.phase = .dark;
            },
            .dark => {
                try self.deps.chunks.setBlock(0, opening, 0);
                self.phase = .opened;
            },
            .opened => {
                try self.deps.chunks.setBlock(0, opening, stone);
                self.phase = .closed;
            },
            .closed => {
                try self.deps.chunks.setBlock(0, source, glowstone);
                self.phase = .restored;
            },
            .restored => {
                try self.deps.reload.stage("e2e:lighting");
                return .handled;
            },
            .reloaded => {},
        }
        self.waited = 0;
        self.checking = true;
        return .handled;
    }

    /// Light follows edits a few ticks later, as in vanilla, and a column that is not in
    /// memory yet answers nothing. The check waits for the expected light before the
    /// players move on.
    pub fn tick(self: *Probe) !void {
        if (!self.checking) return;
        var samples: [1]?LightSample = undefined;
        try self.deps.lighting.sampleMany(0, &.{.{ .x = 17, .y = 66, .z = 2 }}, &samples);
        const emitter = self.phase == .lit or self.phase == .obstructed or self.phase == .restored or self.phase == .reloaded;
        const expected: LightSample = .{
            .block = if (self.phase == .obstructed) 11 else if (emitter) 13 else 0,
            .sky = if (self.phase == .opened) 15 else 0,
        };
        const matches = if (samples[0]) |sample| std.meta.eql(sample, expected) else false;
        if (!matches) {
            self.waited += 1;
            if (self.waited == wait_limit) return if (samples[0] == null) error.MissingSimulationLight else error.IncorrectSimulationLight;
            return;
        }
        self.checking = false;
        for (self.deps.players.records) |player| try self.deps.control.send(player.handle.?, @tagName(self.phase));
    }
};
