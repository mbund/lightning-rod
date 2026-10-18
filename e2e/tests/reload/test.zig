const std = @import("std");
const allMarkers = @import("../../src/artifacts.zig").allMarkers;
const reload = @import("reload_execve");

pub const Test = struct {
    const Fault = enum { missing_target, invalid_target, none };
    const Round = struct { name: []const u8, barrier: []const u8, fault: Fault = .none };
    const rounds = [_]Round{
        .{ .name = "missing_target", .barrier = ".reload-ready", .fault = .missing_target },
        .{ .name = "invalid_target", .barrier = ".reload-armed-invalid_target", .fault = .invalid_target },
        .{ .name = "player_reload", .barrier = ".reload-armed-player_reload" },
        .{ .name = "repeated_player_reload", .barrier = ".reload-armed-repeated_player_reload" },
        .{ .name = "unknown_metadata", .barrier = ".reload-armed-unknown_metadata" },
        .{ .name = "signal", .barrier = ".reload-armed-signal" },
    };
    world: []const u8,
    executable: []const u8,
    protocol_mismatch: bool = false,
    round_index: usize = 0,

    pub fn poll(self: *Test, init: std.process.Init, artifacts: []const u8, peers: []const []const u8, _: i96, _: *std.atomic.Value(bool)) !void {
        if (self.round_index == rounds.len) return;
        const round = rounds[self.round_index];
        if (try allMarkers(init, artifacts, peers, round.barrier)) {
            if (round.fault != .missing_target) {
                const cwd = std.Io.Dir.cwd();
                const path = try std.fs.path.join(init.gpa, &.{ self.world, "reload-target" });
                defer init.gpa.free(path);
                const next = try std.fs.path.join(init.gpa, &.{ self.world, "reload-next" });
                defer init.gpa.free(next);
                try cwd.copyFile(self.executable, cwd, next, init.io, .{});
                if (round.fault == .invalid_target and self.protocol_mismatch) {
                    const image = try reload.Image.open(init.io, next);
                    defer image.close(init.io);
                    const file = try cwd.openFile(init.io, next, .{ .mode = .read_write });
                    defer file.close(init.io);
                    var offset: u64 = 0;
                    while (offset < image.protocols_bytes) : (offset += 12)
                        try file.writePositionalAll(init.io, &.{ 255, 255, 255, 255, 255, 255, 255, 255 }, image.protocols_offset + offset + 4);
                } else if (round.fault == .invalid_target) {
                    const file = try cwd.openFile(init.io, next, .{ .mode = .read_write });
                    defer file.close(init.io);
                    // Preserve resume metadata but make the kernel reject the ELF before replacing the process.
                    try file.writePositionalAll(init.io, &.{ 0, 0 }, @offsetOf(std.elf.Elf64_Ehdr, "e_type"));
                }

                try cwd.rename(next, cwd, path, init.io);
            }

            const trigger = try std.fmt.allocPrint(init.gpa, "{s}/reload-request-{s}", .{ artifacts, round.name });
            defer init.gpa.free(trigger);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = trigger, .data = "ready" });

            self.round_index += 1;
        }
    }
};
