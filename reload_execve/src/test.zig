const std = @import("std");
const builtin = @import("builtin");
const reload = @import("reload_execve");

const protocols = [_]i32{ 47, 776 };
const formats = [_]u64{ 0x0123456789abcdef, 0xfedcba9876543210 };
const Endpoint = struct {
    pub const resume_manifest = block: {
        var bytes: [protocols.len * 12]u8 = undefined;
        for (protocols, formats, 0..) |protocol, format, index| {
            std.mem.writeInt(i32, bytes[index * 12 ..][0..4], protocol, .little);
            std.mem.writeInt(u64, bytes[index * 12 + 4 ..][0..8], format, .little);
        }
        break :block bytes;
    };
};

test "reload manifest is retained once in a stripped executable" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    reload.retainManifest(Endpoint);
    reload.retainManifest(Endpoint);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try std.process.executablePath(std.testing.io, &buffer)];
    const image = try reload.Image.open(std.testing.io, path);
    image.close(std.testing.io);
    try std.testing.expectEqual(Endpoint.resume_manifest.len, image.protocols_bytes);
    for (protocols, formats) |protocol, format| {
        try std.testing.expect(image.supports(protocol, null));
        try std.testing.expect(image.supports(protocol, format));
        try std.testing.expect(!image.supports(protocol, format ^ 1));
    }
    try std.testing.expect(!image.supports(protocols[1] + 1, null));
}
