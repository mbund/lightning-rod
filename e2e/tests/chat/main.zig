const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const e2e = @import("e2e");
const sessions = @import("sessions");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{ e2e.profile.plugins(), lightning_rod.plugin.configured(Probe, .{}) });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

const Probe = struct {
    pub const id = "e2e:chat";
    pub const Configuration = struct {};
    pub const Dependencies = struct { control: *e2e.Control, chat: *vanilla.Chat, players: *vanilla.Players };
    deps: Dependencies,
    pending: []?sessions.Handle,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps, .pending = try allocator.alloc(?sessions.Handle, deps.players.records.len) };
        @memset(self.pending, null);
        deps.control.on(self, receive);
        return self;
    }

    fn receive(self: *Probe, handle: sessions.Handle, message: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, message, "chat_drain")) return .unhandled;
        self.pending[handle.index] = handle;
        return .handled;
    }

    pub fn tick(self: *Probe) !void {
        try self.deps.chat.flush();
        if (self.deps.chat.read != self.deps.chat.write) return;
        for (self.pending) |*pending| {
            const handle = pending.* orelse continue;
            if (std.meta.eql(self.deps.players.records[handle.index].handle, handle))
                try self.deps.control.send(handle, "chat_drained");
            pending.* = null;
        }
    }
};
