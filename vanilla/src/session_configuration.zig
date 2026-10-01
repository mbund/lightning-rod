const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const wire_1_21_5 = @import("wire_1_21_5");

pub fn Plugin(comptime Catalog: type) type {
    const implementations = Catalog.versions;
    return struct {
        const Self = @This();

        pub const id = "minecraft:configuration";
        pub const Dependencies = struct { input: *protocols.Input, phases: *sessions.Phases };
        pub const Configuration = struct {
            protocols: *Catalog,
            feature_flags: []const []const u8 = &.{"minecraft:vanilla"},
            advertise_core_pack: bool = true,
        };
        pub const SessionConfigurationState = struct {
            stage: enum { flags, packs, waiting, registries } = .flags,
            index: usize = 0,
            known: bool = false,
        };
        pub const SessionState = struct { configuration: SessionConfigurationState = .{} };

        configuration: Configuration,

        pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .configuration = configuration };
            try deps.input.configuration.on(.select_known_packs, self, onKnownPacks);
            try deps.phases.onConfiguration(self, onConfiguration);
            return self;
        }

        fn onKnownPacks(self: *Self, scope: sessions.InputScope, state: *SessionConfigurationState, packet: wire_1_21_5.configuration.toServer.packet_common_select_known_packs.Reader, _: []u8) !sessions.ConfigurationInputEffect {
            if (state.stage != .waiting) return error.UnexpectedConfigurationPacket;
            var packs = try packet.packs();
            if (packs.remaining > 64) return error.BadKnownPacks;
            var selected = false;
            var core_pack_version: ?[]const u8 = null;
            inline for (implementations) |Version| {
                if (scope.profile.protocol == Version.protocol_number) core_pack_version = Version.minecraft_name;
            }
            while (try packs.next()) |cursor| {
                const namespace, const a = try cursor.namespace();
                const pack_id, const b = try a.id();
                const version, const done = try b.version();
                try packs.advance(done);
                if (selected or !self.configuration.advertise_core_pack or core_pack_version == null or
                    !std.mem.eql(u8, namespace, "minecraft") or
                    !std.mem.eql(u8, pack_id, "core") or
                    !std.mem.eql(u8, version, core_pack_version.?)) return error.BadKnownPacks;
                selected = true;
            }
            try (try packs.finish()).finish();
            state.stage = .registries;
            state.index = 0;
            state.known = selected;
            return .none;
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

                    switch (state.stage) {
                        .flags => {
                            const bytes = try sessions.packet_api.encode(Version, writeFlags, output, .{self.configuration.feature_flags});
                            state.stage = .packs;
                            return .{ .send = bytes };
                        },
                        .packs => {
                            const version: ?[]const u8 = if (self.configuration.advertise_core_pack) Version.minecraft_name else null;
                            const bytes = try sessions.packet_api.encode(Version, writePacks, output, .{version});
                            state.stage = .waiting;
                            return .{ .send = bytes };
                        },
                        .waiting => return .wait,
                        .registries => {
                            const messages = if (state.known) prepared.known.values else prepared.full.values;
                            if (state.index < messages.len) {
                                const bytes = messages[state.index].bytes;
                                state.index += 1;
                                return .{ .send = bytes };
                            }
                        },
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

        fn writePacks(packet: wire_1_21_5.configuration.toClient.packet_common_select_known_packs.Writer, version: ?[]const u8) ![]u8 {
            var packs = try packet.packs(@intFromBool(version != null));
            if (version) |name| {
                const entry = (try packs.next()).?;
                const a = try entry.namespace("minecraft");
                const b = try a.id("core");
                try packs.advance(try b.version(name));
            }
            return (try packs.finish()).finish();
        }
    };
}
