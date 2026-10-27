const std = @import("std");
const Memory = @import("memory.zig").Memory;

pub const std_options: std.Options = .{ .log_level = .err };
pub const panic = std.debug.FullPanic(failed);

fn failed(message: []const u8, _: ?usize) noreturn {
    std.debug.print("{s}\n", .{message});
    std.process.exit(86);
}

pub fn main(init: std.process.Init) !void {
    var memory = Memory.init(std.heap.page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("test");
    const bytes = try allocator.alloc(u8, 128);
    var arguments = init.minimal.args.iterate();
    _ = arguments.skip();
    const operation = arguments.next() orelse return error.MissingOperation;
    memory.seal();
    if (std.mem.eql(u8, operation, "allocate")) {
        _ = try allocator.alloc(u8, 1);
    } else if (std.mem.eql(u8, operation, "resize")) {
        _ = allocator.resize(bytes, 64);
    } else if (std.mem.eql(u8, operation, "owner")) {
        _ = memory.allocator("late");
    } else return error.UnknownOperation;
    return error.GuardDidNotFire;
}
