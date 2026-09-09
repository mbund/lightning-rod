const raw_packet = @import("raw_packet.zig");

pub const Player = struct {
    name: []const u8,
    position: [3]f64,
    gamemode: enum { survival, creative },
    held_item: []const u8 = "minecraft:air",
    on_ground: bool = true,
};

pub const Block = struct {
    position: [3]i32,
    state: []const u8,
};

pub const Fixture = struct {
    players: []const Player,
    blocks: []const Block,
};

pub const Adapter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reset: *const fn (*anyopaque, Fixture) anyerror![]const raw_packet.Identity,
        stage: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        step: *const fn (*anyopaque) anyerror![]const raw_packet.Clientbound,
    };

    pub fn reset(self: Adapter, fixture: Fixture) ![]const raw_packet.Identity {
        return self.vtable.reset(self.context, fixture);
    }

    pub fn stage(self: Adapter, client: []const u8, packet: []const u8) !void {
        return self.vtable.stage(self.context, client, packet);
    }

    pub fn step(self: Adapter) ![]const raw_packet.Clientbound {
        return self.vtable.step(self.context);
    }
};
