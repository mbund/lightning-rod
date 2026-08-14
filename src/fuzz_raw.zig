const std = @import("std");
const validation = @import("packet_validation.zig");
const wire = @import("wire.zig");

test "raw framed and unframed client bytes" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var storage: [16 * 1024]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];
    const state: validation.State = smith.value(validation.State);

    validation.validatePayload(state, input) catch {};
    var consumed: usize = 0;
    while (consumed < input.len) {
        const framed = wire.nextPacket(input[consumed..]) catch break;
        const packet = framed orelse break;
        std.debug.assert(packet.total_len != 0);
        validation.validatePayload(state, packet.payload) catch {};
        consumed += packet.total_len;
    }
    std.debug.assert(consumed <= input.len);
}
