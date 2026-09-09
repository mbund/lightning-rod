const std = @import("std");
const mcc = @import("minecraft_conformance");

const Record = struct { tick: u64, direction: []const u8, peer: []const u8, hex: []const u8 };

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const expected_path = args.next() orelse return usage();
    const actual_path = args.next() orelse return usage();
    if (args.next() != null) return usage();
    const expected = try readCapture(init.io, init.gpa, expected_path);
    defer init.gpa.free(expected);
    const actual = try readCapture(init.io, init.gpa, actual_path);
    defer init.gpa.free(actual);
    try compare(init.gpa, expected, actual);
    std.debug.print("external conformance: {d} canonical observations match\n", .{expected.len});
}

fn usage() !void {
    std.debug.print("usage: zig build external -- vanilla.capture lightning-rod.capture\n", .{});
    return error.InvalidArguments;
}

fn readCapture(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    if (!std.mem.startsWith(u8, bytes, "mcc-capture-v1\n")) return error.InvalidCaptureHeader;
    return bytes;
}

fn compare(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) !void {
    var expected_it = records(expected);
    var actual_it = records(actual);
    var expected_canonicalizer = mcc.canonicalizer.Canonicalizer.initWithAllocator(&.{}, allocator);
    defer expected_canonicalizer.deinit();
    var actual_canonicalizer = mcc.canonicalizer.Canonicalizer.initWithAllocator(&.{}, allocator);
    defer actual_canonicalizer.deinit();
    var index: usize = 0;
    while (nextRecord(&expected_it)) |left| : (index += 1) {
        const right = nextRecord(&actual_it) orelse return error.MissingObservedPacket;
        try compareRecord(&expected_canonicalizer, &actual_canonicalizer, left, right);
    }
    if (nextRecord(&actual_it) != null) return error.UnexpectedObservedPacket;
}

fn records(bytes: []const u8) std.mem.SplitIterator(u8, .sequence) {
    return std.mem.splitSequence(u8, bytes, "\n");
}

fn nextRecord(iterator: *std.mem.SplitIterator(u8, .sequence)) ?[]const u8 {
    while (iterator.next()) |line| if (std.mem.startsWith(u8, line, "packet ")) return line;
    return null;
}

fn compareRecord(left_canon: *mcc.canonicalizer.Canonicalizer, right_canon: *mcc.canonicalizer.Canonicalizer, left_line: []const u8, right_line: []const u8) !void {
    const left = parseRecord(left_line) orelse return error.InvalidCaptureRecord;
    const right = parseRecord(right_line) orelse return error.InvalidCaptureRecord;
    if (left.tick != right.tick or !std.mem.eql(u8, left.direction, right.direction) or !std.mem.eql(u8, left.peer, right.peer)) return error.ObservationBoundaryMismatch;
    var left_bytes: [1 << 20]u8 = undefined;
    var right_bytes: [1 << 20]u8 = undefined;
    const left_payload = try decodeHex(&left_bytes, left.hex);
    const right_payload = try decodeHex(&right_bytes, right.hex);
    const left_packet = try canonical(left_canon, left, left_payload);
    const right_packet = try canonical(right_canon, right, right_payload);
    if (!equalPacket(left_packet, right_packet)) return error.CanonicalObservationMismatch;
}

fn parseRecord(line: []const u8) ?Record {
    if (!std.mem.startsWith(u8, line, "packet ")) return null;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    _ = words.next();
    const tick = std.fmt.parseInt(u64, words.next() orelse return null, 10) catch return null;
    return .{ .tick = tick, .direction = words.next() orelse return null, .peer = words.next() orelse return null, .hex = words.next() orelse return null };
}

fn decodeHex(buffer: []u8, text: []const u8) ![]u8 {
    if (text.len % 2 != 0 or text.len / 2 > buffer.len) return error.InvalidPacketHex;
    for (0..text.len / 2) |index| buffer[index] = try std.fmt.parseInt(u8, text[index * 2 ..][0..2], 16);
    return buffer[0 .. text.len / 2];
}

fn canonical(canon: *mcc.canonicalizer.Canonicalizer, record: Record, payload: []const u8) !?mcc.Packet {
    if (std.mem.eql(u8, record.direction, "serverbound")) return canon.canonicalizeServerbound(payload);
    const output = try canon.canonicalize(.{ .recipient = record.peer, .payload = payload });
    return if (output) |value| value.packet else null;
}

fn equalPacket(left: ?mcc.Packet, right: ?mcc.Packet) bool {
    if (left == null or right == null) return left == null and right == null;
    if (!std.mem.eql(u8, left.?.name, right.?.name) or left.?.fields.len != right.?.fields.len) return false;
    for (left.?.fields, right.?.fields) |a, b|
        if (!std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.value.literal, b.value.literal)) return false;
    return true;
}
