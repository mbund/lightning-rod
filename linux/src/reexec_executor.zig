const handoff_fd = @import("reexec_handoff_fd.zig");
const reload = @import("reexec_reload.zig");
const reexec = @import("execve.zig");
const runtime = @import("lightning_rod").runtime;
const std = @import("std");

pub fn Execve(comptime maximum_arguments: usize) type {
    return struct {
        const Self = @This();

        arguments: []const [:0]const u8,
        environment: [:null]const ?[*:0]const u8,
        candidate_fd: *?std.posix.fd_t,
        argv: [maximum_arguments + 2]?[*:0]const u8 = undefined,
        handoff_argument: [64:0]u8 = undefined,

        pub fn executor(self: *Self) reload.Executor {
            return .{ .context = self, .replace = replace };
        }

        fn from(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }

        fn replace(raw: *anyopaque, image: []const u8) runtime.Outcome {
            const self = from(raw);
            const fd = self.candidate_fd.* orelse return .failed;
            const handoff = handoff_fd.HandoffFd.create(image) catch return .failed;
            errdefer handoff.close();
            const argument = handoff.argument(&self.handoff_argument) catch return .failed;
            self.handoff_argument[argument.len] = 0;
            const argv = appendHandoffArgument(self, self.handoff_argument[0..argument.len :0]) catch return .failed;
            reexec.replaceFd(fd, @ptrCast(argv.ptr), self.environment.ptr) catch {
                _ = std.os.linux.close(fd);
                self.candidate_fd.* = null;
                return .failed;
            };
        }

        fn appendHandoffArgument(self: *Self, handoff: [:0]const u8) ![]const ?[*:0]const u8 {
            var count: usize = 0;
            for (self.arguments) |argument| {
                if (std.mem.startsWith(u8, argument, handoff_fd.HandoffFd.argument_prefix)) continue;
                if (count == maximum_arguments) return error.ArgumentsExceeded;
                self.argv[count] = argument.ptr;
                count += 1;
            }
            if (count == 0) return error.ArgumentsExceeded;
            self.argv[count] = handoff.ptr;
            self.argv[count + 1] = null;
            return self.argv[0 .. count + 1 :null];
        }
    };
}

test "execve executor is bounded by caller-provided argv storage" {
    const E = Execve(1);
    var candidate_fd: ?std.posix.fd_t = null;
    var value = E{ .arguments = &.{ "server", "--x" }, .environment = &.{}, .candidate_fd = &candidate_fd };
    const executor = value.executor();
    try @import("std").testing.expectEqual(runtime.Outcome.failed, executor.replace(executor.context, "state"));
}

test "execve executor requires a retained candidate fd" {
    const E = Execve(1);
    var candidate_fd: ?std.posix.fd_t = null;
    var value = E{ .arguments = &.{"server"}, .environment = &.{}, .candidate_fd = &candidate_fd };
    const executor = value.executor();
    try @import("std").testing.expectEqual(runtime.Outcome.failed, executor.replace(executor.context, "state"));
}
