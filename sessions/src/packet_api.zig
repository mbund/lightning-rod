const std = @import("std");

pub fn candidates(comptime callbacks: anytype) Candidates(@TypeOf(callbacks)) {
    return if (@typeInfo(@TypeOf(callbacks)) == .@"struct") callbacks else .{callbacks};
}

fn Candidates(comptime T: type) type {
    return if (@typeInfo(T) == .@"struct") T else std.meta.Tuple(&.{T});
}

pub fn Cursor(comptime callback: anytype) type {
    const function = @typeInfo(@TypeOf(callback)).@"fn";
    var found: ?type = null;
    for (function.params) |parameter| {
        const T = parameter.type orelse continue;
        if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "layout_fingerprint")) continue;
        if (found != null) @compileError("packet callback must take exactly one initial packet cursor");
        found = T;
    }
    return found orelse @compileError("packet callback must take a concrete generated packet Reader or Writer");
}

pub fn validateReader(comptime Reader: type, comptime phase: []const u8, comptime name: []const u8) void {
    if (!std.mem.eql(u8, Reader.phase, phase) or !std.mem.eql(u8, Reader.packet_name, name) or
        !std.mem.eql(u8, Reader.direction, "toServer") or !std.mem.eql(u8, Reader.cursor_mode, "read"))
        @compileError("input callback cursor does not match the registered packet");
}

pub fn select(comptime Version: type, comptime callbacks: anytype) usize {
    @setEvalBranchQuota(100_000);
    const handlers = candidates(callbacks);
    if (handlers.len == 0) @compileError("at least one packet callback is required");
    const First = Cursor(handlers[0]);
    const Packets = @field(@field(Version.Protocol, First.phase), First.direction);
    if (!@hasField(Packets.PacketName, First.packet_name))
        @compileError(std.fmt.comptimePrint("protocol {d} has no {s}.{s}.{s} packet", .{ Version.protocol_number, First.phase, First.direction, First.packet_name }));
    const Actual = Packets.PacketBody(@field(Packets.PacketName, First.packet_name));
    var selected: ?usize = null;
    var latest: i32 = std.math.minInt(i32);
    for (handlers, 0..) |handler, index| {
        const Source = Cursor(handler);
        if (!std.mem.eql(u8, Source.packet_name, First.packet_name) or
            !std.mem.eql(u8, Source.phase, First.phase) or
            !std.mem.eql(u8, Source.direction, First.direction) or
            !std.mem.eql(u8, Source.cursor_mode, First.cursor_mode))
            @compileError("packet callbacks must implement the same packet, phase, direction, and cursor mode");
        for (0..index) |previous|
            if (Cursor(handlers[previous]).protocol_number == Source.protocol_number)
                @compileError("duplicate packet callback source protocol");
        if (Source.protocol_number <= Actual.protocol_number and Source.protocol_number > latest) {
            selected = index;
            latest = Source.protocol_number;
        }
    }
    const index = selected orelse @compileError(std.fmt.comptimePrint("no {s}.{s}.{s} callback supports protocol {d}", .{ First.phase, First.direction, First.packet_name, Version.protocol_number }));
    const Source = Cursor(handlers[index]);
    Source.requireCompatible(Actual);
    return index;
}

pub fn encode(comptime Version: type, comptime callbacks: anytype, buffer: []u8, arguments: anytype) ![]u8 {
    const handlers = comptime candidates(callbacks);
    const handler = handlers[comptime select(Version, callbacks)];
    const Source = Cursor(handler);
    comptime {
        if (!std.mem.eql(u8, Source.cursor_mode, "write") or !std.mem.eql(u8, Source.direction, "toClient"))
            @compileError("outbound packet callback must take a clientbound Writer");
        if (@typeInfo(@TypeOf(handler)).@"fn".params[0].type != Source)
            @compileError("outbound packet callback must take its Writer as the first argument");
    }
    const Packets = @field(@field(Version.Protocol, Source.phase), Source.direction);
    const actual = try @field(Packets.PacketWriter, Source.packet_name)(Packets.write(buffer));
    var state = actual._cursor;
    state.layout_protocol = Version.Protocol.protocol_number;
    state.protocol_number = Version.protocol_number;
    state.tags = Version.Protocol.case_tags;
    const cursor: Source = .{ ._cursor = state };
    const bytes = try @call(.auto, handler, .{cursor} ++ arguments);
    std.debug.assert(bytes.ptr == buffer.ptr);
    std.debug.assert(bytes.len <= buffer.len);
    return bytes;
}

pub fn encodeFor(comptime versions: anytype, comptime callbacks: anytype, protocol_number: i32, buffer: []u8, arguments: anytype) ![]u8 {
    inline for (versions) |Version| {
        if (Version.protocol_number == protocol_number)
            return encode(Version, callbacks, buffer, arguments);
    }
    return error.UnsupportedProtocol;
}
