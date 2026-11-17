const std = @import("std");
const sessions = @import("sessions");
const wire_1_21_5 = @import("wire_1_21_5");

pub fn Plugin(comptime Catalog: type) type {
    const implementations = Catalog.versions;
    return struct {
        const Self = @This();

        pub const id = "minecraft:configuration";
        pub const Dependencies = struct { phases: *sessions.Phases };
        pub const Configuration = struct {
            protocols: *Catalog,
            feature_flags: []const []const u8 = &.{"minecraft:vanilla"},
        };
        pub const SessionConfigurationState = struct {
            index: usize = 0,
            flags_sent: bool = false,
            /// Vanilla offers its pack and waits for the client to say which packs it holds, then
            /// leaves out the data of every registry entry the client has.
            packs: enum { offer, waiting, known, unknown } = .offer,
        };
        pub const SessionState = struct { configuration: SessionConfigurationState = .{} };

        configuration: Configuration,

        pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .configuration = configuration };
            try deps.phases.onConfiguration(self, onConfiguration);
            return self;
        }

        pub fn onConfiguration(
            self: *Self,
            scope: sessions.PhaseScope,
            state: *SessionConfigurationState,
            event: sessions.PhaseEvent,
            output: []u8,
        ) !sessions.ConfigurationStep {
            inline for (implementations, 0..) |Version, version_index| {
                if (scope.profile.protocol == Version.protocol_number) {
                    const prepared = &self.configuration.protocols.prepared[version_index];

                    switch (event) {
                        .begin => state.* = .{},
                        .poll => {},
                        .packet => |bytes| {
                            if (state.packs != .waiting) return error.UnexpectedConfigurationEvent;
                            state.packs = if (try holdsCore(bytes, prepared.core_version.?)) .known else .unknown;
                        },
                        .admitted => return error.UnexpectedConfigurationEvent,
                    }

                    if (!state.flags_sent) {
                        state.flags_sent = true;
                        return .{ .send = try sessions.packet_api.encode(Version, writeFlags, output, .{self.configuration.feature_flags}) };
                    }
                    if (prepared.core_version) |version| switch (state.packs) {
                        .offer => {
                            state.packs = .waiting;
                            return .{ .send = try sessions.packet_api.encode(Version, writePacks, output, .{version}) };
                        },
                        .waiting => return .wait,
                        .known, .unknown => {},
                    };
                    const packets = if (state.packs == .known) prepared.known else prepared.packets;
                    if (state.index < packets.values.len) {
                        const bytes = packets.values[state.index].bytes;
                        state.index += 1;
                        return .{ .send = bytes };
                    }
                    return .done;
                }
            }
            return error.UnsupportedProtocol;
        }

        fn writeFlags(packet: wire_1_21_5.configuration.toClient.packet_feature_flags.Writer, features: []const []const u8) ![]u8 {
            var flags = try packet.features(features.len);
            for (features) |feature| flags = try flags.element(feature);
            return (try flags.finish()).finish();
        }

        fn writePacks(packet: wire_1_21_5.configuration.toClient.packet_common_select_known_packs.Writer, version: []const u8) ![]u8 {
            var packs = try packet.packs(1);
            const pack = try (try (try (try packs.next()).?.namespace("minecraft")).id("core")).version(version);
            try packs.advance(pack);
            return (try packs.finish()).finish();
        }
    };
}

/// Whether the client's known packs reply names vanilla's pack of exactly this release.
fn holdsCore(packet: []const u8, version: []const u8) !bool {
    var reader: Reader = .{ .bytes = packet };
    _ = try reader.varint();
    const count = try reader.varint();
    if (count > 64) return error.InvalidKnownPacks;
    var held = false;
    for (0..count) |_| {
        const namespace = try reader.string();
        const name = try reader.string();
        const release = try reader.string();
        if (std.mem.eql(u8, namespace, "minecraft") and std.mem.eql(u8, name, "core") and std.mem.eql(u8, release, version)) held = true;
    }
    if (reader.at != packet.len) return error.InvalidKnownPacks;
    return held;
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn varint(self: *Reader) !u32 {
        var value: u32 = 0;
        for (0..5) |index| {
            if (self.at == self.bytes.len) return error.InvalidKnownPacks;
            const byte = self.bytes[self.at];
            self.at += 1;
            value |= @as(u32, byte & 0x7f) << @intCast(7 * index);
            if (byte & 0x80 == 0) return value;
        }
        return error.InvalidKnownPacks;
    }

    fn string(self: *Reader) ![]const u8 {
        const length = try self.varint();
        if (length > 256 or length > self.bytes.len - self.at) return error.InvalidKnownPacks;
        defer self.at += length;
        return self.bytes[self.at..][0..length];
    }
};

test "the known packs reply must name vanilla's pack of the same release" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.writeByte(0x07);
    try writer.writeByte(2);
    for ([_][3][]const u8{ .{ "example", "core", "26.2" }, .{ "minecraft", "core", "26.2" } }) |pack| for (pack) |text| {
        try writer.writeByte(@intCast(text.len));
        try writer.writeAll(text);
    };
    try std.testing.expect(try holdsCore(writer.buffered(), "26.2"));
    try std.testing.expect(!try holdsCore(writer.buffered(), "26.3"));
    try std.testing.expectError(error.InvalidKnownPacks, holdsCore(writer.buffered()[0 .. writer.end - 1], "26.2"));
    try std.testing.expect(!try holdsCore(&.{ 0x07, 0 }, "26.2"));
}
