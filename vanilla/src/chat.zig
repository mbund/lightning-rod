const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const minecraft = @import("minecraft");
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;

pub const Chat = struct {
    pub const id = "minecraft:chat";

    pub const Configuration = struct { pending_messages: usize = 64 };

    pub const Dependencies = struct {
        players: *Players,
        input: *Input,
    };

    const Message = struct {
        bytes: [1100]u8 = undefined,
        length: usize = 0,
        recipients: []sessions.Service.Target,
        count: usize = 0,
    };

    deps: Dependencies,
    messages: []Message,
    delivered: []sessions.Service.Delivery,
    read: u64 = 0,
    write: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Chat {
        if (config.pending_messages == 0 or config.pending_messages > 4096) return error.InvalidConfiguration;

        const self = try allocator.create(Chat);
        const messages = try allocator.alloc(Message, config.pending_messages);
        const recipients = try allocator.alloc(sessions.Service.Target, messages.len * deps.players.records.len);

        for (messages, 0..) |*message, index|
            message.* = .{ .recipients = recipients[index * deps.players.records.len ..][0..deps.players.records.len] };

        self.* = .{ .deps = deps, .messages = messages, .delivered = try allocator.alloc(sessions.Service.Delivery, deps.players.records.len) };
        return self;
    }

    pub fn tick(self: *Chat) !void {
        const service = self.deps.players.deps.sessions;

        // Drain previous output before admitting this tick's messages, then drain again.
        for (0..2) |phase| {
            if (phase == 1) for (self.deps.players.records) |player| {
                const handle = player.handle orelse continue;
                if (player.stage != .ready) continue;

                for (self.deps.input.values(handle)) |event| {
                    if (event != .chat) continue;

                    const text = event.chat.message;
                    if (text.len > 1024 or !std.unicode.utf8ValidateSlice(text) or self.write - self.read == self.messages.len) {
                        service.disconnect(handle);
                        break;
                    }

                    const message = &self.messages[self.write % self.messages.len];
                    // Input loans expire this tick. Bounded owned text permits deferred delivery.
                    const formatted = try std.fmt.bufPrint(message.bytes[3 .. message.bytes.len - 1], "<{s}> {s}", .{ player.name[0..player.name_len], text });
                    message.bytes[0] = 8;
                    std.mem.writeInt(u16, message.bytes[1..3], @intCast(formatted.len), .big);
                    message.bytes[3 + formatted.len] = 0;
                    message.length = formatted.len + 4;
                    message.count = 0;

                    for (self.deps.players.records) |recipient| {
                        const target = recipient.handle orelse continue;
                        if (recipient.stage != .ready) continue;
                        message.recipients[message.count] = .{ .handle = target, .protocol = recipient.protocol };
                        message.count += 1;
                    }

                    self.write += 1;
                }
            };

            try self.flush();
        }
    }

    pub fn flush(self: *Chat) !void {
        const service = self.deps.players.deps.sessions;

        while (self.read != self.write) {
            const message = &self.messages[self.read % self.messages.len];
            const output: minecraft.Output = .{ .chat = message.bytes[0..message.length] };
            try service.fanout(minecraft.Generated(protocols.wire).write, message.recipients[0..message.count], &output, message.length + 8, self.delivered[0..message.count]);
            var remaining: usize = 0;

            for (message.recipients[0..message.count], self.delivered[0..message.count]) |target, result| {
                if (result != .backpressured) continue;
                if (!service.canSend(target.handle, message.length + 8)) {
                    service.disconnect(target.handle);
                    continue;
                }

                message.recipients[remaining] = target;
                remaining += 1;
            }

            message.count = remaining;
            if (remaining != 0) break;
            self.read += 1;
        }
    }

    pub fn system(self: *Chat, handle: sessions.Handle, text: []const u8) void {
        std.debug.assert(text.len <= 1096);
        const player = self.deps.players.records[handle.index];
        if (player.handle == null or !std.meta.eql(player.handle.?, handle)) return;
        if (self.write - self.read == self.messages.len) {
            self.deps.players.deps.sessions.disconnect(handle);
            return;
        }

        const message = &self.messages[self.write % self.messages.len];
        message.bytes[0] = 8;
        std.mem.writeInt(u16, message.bytes[1..3], @intCast(text.len), .big);
        @memcpy(message.bytes[3..][0..text.len], text);
        message.bytes[3 + text.len] = 0;
        message.length = text.len + 4;
        message.recipients[0] = .{ .handle = handle, .protocol = player.protocol };
        message.count = 1;
        self.write += 1;
    }
};
