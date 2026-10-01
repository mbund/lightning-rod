const std = @import("std");
const allMarkers = @import("../../src/artifacts.zig").allMarkers;
const reload = @import("reload_execve");

pub const Test = struct {
    world: []const u8,
    executable: []const u8,
    protocol_mismatch: bool = false,
    stage: usize = 0,
    released: usize = 0,

    pub fn verify(log: []const u8, players: usize) !void {
        if ((std.mem.count(u8, log, "event=reload_resumed ") != 4 or std.mem.count(u8, log, "event=reload_fallback ") != 1 or std.mem.count(u8, log, "event=reload_rejected ") != 1 or std.mem.count(u8, log, "event=session_encrypted ") != players))
            return error.ReloadFailed;
        const serialized: usize = if (std.mem.indexOf(u8, log, "event=reload_fallback reason=ReloadProtocolUnsupported") != null) 4 else 5;
        if ((std.mem.count(u8, log, "event=reload_input_saved bytes=1 encrypted=true") != serialized * players or std.mem.count(u8, log, "event=reload_input_restored bytes=1 encrypted=true") != 4 * players))
            return error.ReloadFragmentNotExercised;
    }

    pub fn poll(self: *Test, init: std.process.Init, artifacts: []const u8, peers: []const []const u8, deadline: i96, interrupted: *std.atomic.Value(bool)) !void {
        const log_path = try std.fs.path.join(init.gpa, &.{ artifacts, "server.log" });
        defer init.gpa.free(log_path);
        const log = try std.Io.Dir.cwd().readFileAlloc(init.io, log_path, init.gpa, .limited(16 * 1024 * 1024));
        defer init.gpa.free(log);
        const returned = std.mem.count(u8, log, "event=reload_fallback ") + std.mem.count(u8, log, "event=reload_resumed ");
        if (returned > self.released) {
            const serialized = returned - @as(usize, @intFromBool(self.protocol_mismatch));
            if (std.mem.count(u8, log, "event=reload_input_saved bytes=1 encrypted=true") != serialized * peers.len)
                return error.ReloadFragmentNotExercised;

            const release = try std.fmt.allocPrint(init.gpa, "{s}/reload-release-{d}", .{ artifacts, returned });
            defer init.gpa.free(release);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = release, .data = "ready" });
            self.released = returned;
        }

        const suffixes = [_][]const u8{ ".reload-ready", ".reload-armed-0", ".reload-armed-1", ".reload-armed-2", ".reload-armed-3", ".reload-armed-4" };
        if (self.stage < suffixes.len and try allMarkers(init, artifacts, peers, suffixes[self.stage])) {
            if (self.stage != 0) {
                const cwd = std.Io.Dir.cwd();
                const path = try std.fs.path.join(init.gpa, &.{ self.world, "reload-target" });
                defer init.gpa.free(path);
                const next = try std.fs.path.join(init.gpa, &.{ self.world, "reload-next" });
                defer init.gpa.free(next);
                try cwd.copyFile(self.executable, cwd, next, init.io, .{});
                if (self.stage == 1 and self.protocol_mismatch) {
                    const image = try reload.Image.open(init.io, next);
                    defer image.close(init.io);
                    const file = try cwd.openFile(init.io, next, .{ .mode = .read_write });
                    defer file.close(init.io);
                    var offset: u64 = 0;
                    while (offset < image.protocols_bytes) : (offset += 12)
                        try file.writePositionalAll(init.io, &.{ 255, 255, 255, 255, 255, 255, 255, 255 }, image.protocols_offset + offset + 4);
                } else if (self.stage == 1) {
                    const file = try cwd.openFile(init.io, next, .{ .mode = .read_write });
                    defer file.close(init.io);
                    var header: [64]u8 = undefined;
                    if (try file.readPositionalAll(init.io, &header, 0) != header.len) return error.InvalidExecutable;

                    const offset = std.mem.readInt(u64, header[32..40], .little);
                    const count = std.mem.readInt(u16, header[56..58], .little);
                    var patched = false;

                    for (0..count) |index| {
                        var entry: [56]u8 = undefined;
                        if (try file.readPositionalAll(init.io, &entry, offset + index * entry.len) != entry.len) return error.InvalidExecutable;
                        if (std.mem.readInt(u32, entry[0..4], .little) != 3) continue;

                        const interpreter = std.mem.readInt(u64, entry[8..16], .little);
                        try file.writePositionalAll(init.io, "/!", interpreter);
                        patched = true;
                    }

                    if (!patched) return error.MissingInterpreter;
                }

                try cwd.rename(next, cwd, path, init.io);
            }

            const trigger = try std.fmt.allocPrint(init.gpa, "{s}/reload-request-{d}", .{ artifacts, self.stage });
            defer init.gpa.free(trigger);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = trigger, .data = "ready" });
            if (self.stage == 0) {
                const path = try std.fs.path.join(init.gpa, &.{ artifacts, "reload-rejected" });
                defer init.gpa.free(path);
                const sent = try std.fs.path.join(init.gpa, &.{ artifacts, "reload-requested-0" });
                defer init.gpa.free(sent);

                while (true) {
                    if (interrupted.load(.acquire)) return error.Interrupted;
                    std.Io.Dir.cwd().access(init.io, sent, .{}) catch {
                        if (std.Io.Clock.Timestamp.now(init.io, .awake).raw.nanoseconds >= deadline) return error.Timeout;
                        try std.Io.sleep(init.io, .fromMilliseconds(25), .awake);
                        continue;
                    };
                    break;
                }

                try std.Io.sleep(init.io, .fromMilliseconds(500), .awake);
                try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = "rejected" });
            }

            self.stage += 1;
        }
    }
};
