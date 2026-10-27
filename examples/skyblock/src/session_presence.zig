const std = @import("std");
const sessions = @import("sessions");
const Catalog = @import("catalog.zig").Catalog;
const Channel = @import("global_chat.zig").Channel;
const Member = @import("catalog.zig").Member;

pub const Presence = struct {
    pub const id = "skyblock:presence";
    pub const Configuration = struct { catalog: *Catalog, chat: *Channel };
    pub const Dependencies = struct { phases: *sessions.Phases };
    pub const SessionConfigurationState = struct { uuid: ?u128 = null };
    pub const SessionState = struct { configuration: SessionConfigurationState = .{} };
    catalog: *Catalog,
    chat: *Channel,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Presence {
        const self = try allocator.create(Presence);
        self.* = .{ .catalog = config.catalog, .chat = config.chat };
        try deps.phases.onConfiguration(self, configure);
        try deps.phases.onClosed(self, closed);
        return self;
    }

    fn configure(self: *Presence, scope: sessions.PhaseScope, state: *SessionConfigurationState, _: sessions.PhaseEvent, _: []u8) !sessions.ConfigurationStep {
        try self.chat.connect(Member.named(scope.profile.uuid, scope.profile.name), scope.profile.connection);
        state.uuid = scope.profile.uuid;
        return .done;
    }

    fn closed(self: *Presence, handle: sessions.Handle, state: *SessionState) void {
        if (state.configuration.uuid) |uuid| {
            self.catalog.disconnect(uuid);
            self.chat.leave(uuid, handle);
        }
    }
};
