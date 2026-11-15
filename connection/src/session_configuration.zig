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
        };
        pub const SessionState = struct { configuration: SessionConfigurationState = .{} };

        configuration: Configuration,

        pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .configuration = configuration };
            try deps.phases.onConfiguration(self, onConfiguration);
            return self;
        }

        fn onConfiguration(
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
                        .admitted => return error.UnexpectedConfigurationEvent,
                    }

                    if (!state.flags_sent) {
                        state.flags_sent = true;
                        return .{ .send = try sessions.packet_api.encode(Version, writeFlags, output, .{self.configuration.feature_flags}) };
                    }
                    if (state.index < prepared.packets.values.len) {
                        const bytes = prepared.packets.values[state.index].bytes;
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
    };
}
