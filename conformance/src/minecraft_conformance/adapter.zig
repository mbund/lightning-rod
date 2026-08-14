const fixture = @import("fixture.zig");
const packet = @import("packet.zig");
const raw_packet = @import("raw_packet.zig");

/// The complete black-box target boundary: restore typed state, stage opaque
/// serverbound packet bodies, advance exactly one tick, then drain opaque
/// clientbound packet bodies. No gameplay state or event oracle crosses it.
pub const Adapter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Output = raw_packet.Clientbound;
    pub const VTable = struct {
        restore: *const fn (*anyopaque, fixture.Definition, []const packet.Client) anyerror![]const raw_packet.Identity,
        restart: *const fn (*anyopaque) anyerror![]const raw_packet.Identity,
        stage: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        control: *const fn (*anyopaque, []const u8, packet.Control) anyerror!void,
        step: *const fn (*anyopaque) anyerror![]const Output,
    };

    pub fn restore(self: Adapter, definition: fixture.Definition, clients: []const packet.Client) ![]const raw_packet.Identity {
        return self.vtable.restore(self.context, definition, clients);
    }

    pub fn stage(self: Adapter, client: []const u8, body: []const u8) !void {
        try self.vtable.stage(self.context, client, body);
    }

    pub fn restart(self: Adapter) ![]const raw_packet.Identity {
        return self.vtable.restart(self.context);
    }

    pub fn control(self: Adapter, client: []const u8, operation: packet.Control) !void {
        try self.vtable.control(self.context, client, operation);
    }

    pub fn step(self: Adapter) ![]const Output {
        return self.vtable.step(self.context);
    }
};
