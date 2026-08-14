const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const chat = lightning_rod.chat;
const Packets = lightning_rod.Packets;
const std = @import("std");

pub const maximum_prefix_bytes = 128;

pub const OutputConfig = struct {
    /// Prefix borrowed from generation-owned configuration for the entire
    /// tick. An empty value preserves vanilla formatting.
    prefix: []const u8 = "",

    pub fn validate(self: @This()) !void {
        if (self.prefix.len > maximum_prefix_bytes) return error.ChatPrefixTooLong;
    }
};

pub const Prepare = struct {
    pub const id = "minecraft:chat_prepare";

    players: *player_store.Players,
    packets: *Packets,

    pub fn create(allocator: std.mem.Allocator, players: *player_store.Players, packets: *Packets) !*Prepare {
        const self = try allocator.create(Prepare);
        self.* = .{ .players = players, .packets = packets };
        return self;
    }

    pub fn tick(self: *Prepare, _: std.mem.Allocator) void {
        const players = self.players;
        const messages = &self.packets.chats;
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

    config: OutputConfig,
    players: *player_store.Players,
    packets: *Packets,

    pub fn create(allocator: std.mem.Allocator, players: *player_store.Players, packets: *Packets, config: OutputConfig) !*Output {
        try config.validate();
        const self = try allocator.create(Output);
        self.* = .{ .config = config, .players = players, .packets = packets };
        return self;
    }

    pub fn tick(self: *Output, _: std.mem.Allocator) void {
        const players = self.players;
        const messages_out = self.packets;
        const messages = &self.packets.chats;
        for (messages.items()) |*draft| {
            if (draft.cancelled) continue;
            if (self.config.prefix.len != 0) draft.addPrefix(self.config.prefix) catch {
                draft.cancel();
                continue;
            };
            switch (draft.audience) {
                .broadcast => for (players.activeSlots()) |slot| {
                    if (players.records[slot].state == .play)
                        messages_out.chat_recipient(slot, draft);
                },
                .player => |slot| if (slot < players.records.len and
                    players.records[slot].state == .play)
                    messages_out.chat_recipient(slot, draft),
            }
        }
    }
};
