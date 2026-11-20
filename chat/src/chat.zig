const lightning_rod = @import("lightning_rod");
const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const Players = @import("players").players.Players;

pub const Chat = struct {
    pub const id = "minecraft:chat";

    pub const Configuration = struct { pending_messages: usize = 64 };
    pub const Action = struct { command: []const u8, hover: []const u8 };

    pub const Dependencies = struct {
        players: *Players,
        sessions: *sessions.Service,
        packets: *packets.Packets,
    };

    const Message = struct {
        bytes: [1100]u8 = undefined,
        length: usize = 0,
        recipients: []sessions.Service.Target,
        /// Since when each recipient still to be sent the message has waited for it.
        waits: []Wait,
        count: usize = 0,
        /// Whether the message was tried already, so its recipients have waits.
        tried: bool = false,
    };

    /// A recipient's wait for a message: since the tick it last sent anything, and how much
    /// credit it had back from sent output then.
    const Wait = struct { since: u64, returned: u64 };

    /// Ticks a recipient may wait for a message without sending anything before it is
    /// disconnected. A connection whose output is full is not behind while it drains:
    /// terrain fills it whenever a player loads an area, and joining a crowded server
    /// fills it with every other player. One that takes nothing for five seconds is.
    const patience_ticks = 100;

    deps: Dependencies,
    messages: []Message,
    delivered: []sessions.Service.Delivery,
    read: u64 = 0,
    write: u64 = 0,
    ticks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Chat {
        if (config.pending_messages == 0 or config.pending_messages > 4096) return error.InvalidConfiguration;

        const self = try allocator.create(Chat);
        const messages = try allocator.alloc(Message, config.pending_messages);
        const recipients = try allocator.alloc(sessions.Service.Target, messages.len * deps.players.records.len);
        const waits = try allocator.alloc(Wait, recipients.len);

        for (messages, 0..) |*message, index| message.* = .{
            .recipients = recipients[index * deps.players.records.len ..][0..deps.players.records.len],
            .waits = waits[index * deps.players.records.len ..][0..deps.players.records.len],
        };

        self.* = .{ .deps = deps, .messages = messages, .delivered = try allocator.alloc(sessions.Service.Delivery, deps.players.records.len) };
        return self;
    }

    pub fn tick(self: *Chat) !void {
        self.ticks += 1;
        try self.flush();
    }

    pub fn available(self: *const Chat) usize {
        return self.messages.len - @as(usize, @intCast(self.write - self.read));
    }

    pub fn flush(self: *Chat) !void {
        const service = self.deps.sessions;

        while (self.read != self.write) {
            const message = &self.messages[self.read % self.messages.len];
            try self.deps.packets.fanout(writeChat, message.recipients[0..message.count], .{message.bytes[0..message.length]}, message.length + 8, self.delivered[0..message.count]);
            var remaining: usize = 0;

            for (message.recipients[0..message.count], message.waits[0..message.count], self.delivered[0..message.count]) |target, before, result| {
                if (result != .backpressured) continue;
                const returned = service.returnedCredit(target.handle);
                // A recipient that sent anything since its wait began is draining, so it waits
                // afresh from now.
                var wait = before;
                if (!message.tried or returned != wait.returned) wait = .{ .since = self.ticks, .returned = returned };
                if (!service.canSend(target.handle, message.length + 8) and self.ticks - wait.since >= patience_ticks) {
                    // An operator needs to tell this from a player who left.
                    std.log.warn("event=chat_recipient_disconnected connection={d}:{d} output_credit={d} needed={d}", .{ target.handle.index, target.handle.generation, service.outputCredit(target.handle), service.framedBound(message.length + 8) });
                    service.disconnect(target.handle);
                    continue;
                }

                message.recipients[remaining] = target;
                message.waits[remaining] = wait;
                remaining += 1;
            }

            message.count = remaining;
            message.tried = true;
            if (remaining != 0) break;
            message.tried = false;
            self.read += 1;
        }
    }

    fn writeChat(packet: wire_1_21_5.play.toClient.packet_system_chat.Writer, content: []const u8) ![]u8 {
        return (try (try packet.content(content)).isActionBar(false)).finish();
    }

    /// Queues one shared message. Returns false when the bounded queue is full.
    pub fn broadcast(self: *Chat, text: []const u8) bool {
        return self.broadcastTo(.all, text);
    }

    pub fn broadcastTo(self: *Chat, audience: lightning_rod.system.bit_sets.Selection, text: []const u8) bool {
        if (audience == .players and !audience.players.any()) return true;
        std.debug.assert(text.len <= 1096);
        if (self.write - self.read == self.messages.len) return false;

        const message = &self.messages[self.write % self.messages.len];
        message.bytes[0] = 8;
        std.mem.writeInt(u16, message.bytes[1..3], @intCast(text.len), .big);
        @memcpy(message.bytes[3..][0..text.len], text);
        message.length = text.len + 3;
        message.count = 0;

        const records = self.deps.players.records;
        if (records.len == 0) return true;
        if (audience == .players) std.debug.assert(audience.players.capacity == records.len);
        for (self.deps.players.activeSlots()) |index| {
            const player = records[index];
            if (!audience.contains(index)) continue;
            if (!player.inPlay()) continue;
            message.recipients[message.count] = .{ .handle = player.handle.?, .protocol = player.protocol };
            message.count += 1;
        }

        if (message.count == 0) return true;
        self.write += 1;
        return true;
    }

    pub fn system(self: *Chat, handle: sessions.Handle, text: []const u8) void {
        self.systemMessages(&.{handle}, text, null);
    }

    pub fn systemMany(self: *Chat, handles: []const sessions.Handle, text: []const u8) void {
        self.systemMessages(handles, text, null);
    }

    pub fn systemAction(self: *Chat, handle: sessions.Handle, text: []const u8, action: Action) void {
        std.debug.assert(action.command.len > 0 and action.command.len <= 256 and action.command[0] == '/');
        std.debug.assert(action.hover.len > 0 and action.hover.len <= 128);
        std.debug.assert(text.len <= 512);
        self.systemMessages(&.{handle}, text, action);
    }

    /// A system message of any text component, given as its network NBT.
    pub fn systemComponent(self: *Chat, handle: sessions.Handle, nbt: []const u8) void {
        std.debug.assert(nbt.len <= @typeInfo(@FieldType(Message, "bytes")).array.len);
        if (self.write - self.read == self.messages.len) {
            self.deps.sessions.disconnect(handle);
            return;
        }
        if (handle.index >= self.deps.players.records.len) return;
        const player = self.deps.players.records[handle.index];
        if (player.handle == null or !std.meta.eql(player.handle.?, handle)) return;
        const message = &self.messages[self.write % self.messages.len];
        message.recipients[0] = .{ .handle = handle, .protocol = player.protocol };
        message.count = 1;
        @memcpy(message.bytes[0..nbt.len], nbt);
        message.length = nbt.len;
        self.write += 1;
    }

    fn systemMessages(self: *Chat, handles: []const sessions.Handle, text: []const u8, action: ?Action) void {
        std.debug.assert(text.len <= 1096);
        if (self.write - self.read == self.messages.len) {
            for (handles) |handle| self.deps.sessions.disconnect(handle);
            return;
        }

        const message = &self.messages[self.write % self.messages.len];
        message.count = 0;
        for (handles) |handle| {
            if (handle.index >= self.deps.players.records.len) continue;
            const player = self.deps.players.records[handle.index];
            if (player.handle == null or !std.meta.eql(player.handle.?, handle)) continue;
            message.recipients[message.count] = .{ .handle = handle, .protocol = player.protocol };
            message.count += 1;
        }
        if (message.count == 0) return;
        if (action) |interactive| {
            var output = std.Io.Writer.fixed(&message.bytes);
            writeAction(&output, text, interactive) catch unreachable;
            message.length = output.end;
        } else {
            message.bytes[0] = 8;
            std.mem.writeInt(u16, message.bytes[1..3], @intCast(text.len), .big);
            @memcpy(message.bytes[3..][0..text.len], text);
            message.length = text.len + 3;
        }
        self.write += 1;
    }
};

fn stringTag(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.writeByte(8);
    try writer.writeInt(u16, @intCast(name.len), .big);
    try writer.writeAll(name);
    try writer.writeInt(u16, @intCast(value.len), .big);
    try writer.writeAll(value);
}

fn writeAction(writer: *std.Io.Writer, text: []const u8, action: Chat.Action) !void {
    try writer.writeByte(10);
    try stringTag(writer, "text", text);
    try stringTag(writer, "color", "green");
    try writer.writeByte(10);
    try writer.writeInt(u16, "click_event".len, .big);
    try writer.writeAll("click_event");
    try stringTag(writer, "action", "run_command");
    try stringTag(writer, "command", action.command);
    try writer.writeByte(0);
    try writer.writeByte(10);
    try writer.writeInt(u16, "hover_event".len, .big);
    try writer.writeAll("hover_event");
    try stringTag(writer, "action", "show_text");
    try stringTag(writer, "value", action.hover);
    try writer.writeAll(&.{ 0, 0 });
}
