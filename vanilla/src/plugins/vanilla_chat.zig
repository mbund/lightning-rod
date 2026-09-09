const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const chat = lightning_rod.chat;
const Packets = lightning_rod.Packets;
const std = @import("std");

pub const maximum_prefix_bytes = 128;

pub const OutputConfig = struct {
    prefix: []const u8 = "",

    pub fn validate(self: @This()) !void {
        if (self.prefix.len > maximum_prefix_bytes) return error.ChatPrefixTooLong;
    }
};

pub const Prepare = struct {
    pub const id = "minecraft:chat_prepare";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *player_store.Players, packets: *Packets };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*Prepare {
        const self = try allocator.create(Prepare);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *Prepare, _: std.mem.Allocator) void {
        const players = self.deps.players;
        const messages = &self.deps.packets.chats;
        for (messages.items()) |*draft| {
            if (draft.sender >= players.records.len or
                players.records[draft.sender].state != .play)
            {
                draft.cancel();
                continue;
            }
            draft.display_name = players.records[draft.sender].name_slice();
        }
    }
};

pub const Output = struct {
    pub const id = "minecraft:chat_output";
    pub const Dependencies = struct { players: *player_store.Players, packets: *Packets };
    pub const Configuration = OutputConfig;

    deps: Dependencies,
    config: Configuration,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, settings: Configuration) !*Output {
        try settings.validate();
        const self = try allocator.create(Output);
        self.* = .{ .deps = deps, .config = settings };
        return self;
    }

    pub fn tick(self: *Output, _: std.mem.Allocator) void {
        const players = self.deps.players;
        const messages_out = self.deps.packets;
        const messages = &self.deps.packets.chats;
        for (messages.items()) |*draft| {
            if (draft.cancelled) continue;
            if (self.config.prefix.len != 0) draft.addPrefix(self.config.prefix) catch {
                draft.cancel();
                continue;
            };
            switch (draft.audience) {
                .broadcast => for (players.activeSlots()) |slot| {
                    if (players.records[slot].state == .play)
                        messages_out.chatRecipient(slot, draft);
                },
                .player => |slot| if (slot < players.records.len and
                    players.records[slot].state == .play)
                    messages_out.chatRecipient(slot, draft),
            }
        }
    }
};
