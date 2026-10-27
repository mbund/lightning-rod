const std = @import("std");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const wire = @import("wire_1_21_5");
const catalog = @import("catalog.zig");

pub const Channel = struct {
    pub const capacity = 256;
    pub const maximum_message = 1096;
    const Message = struct { bytes: [maximum_message]u8 = undefined, length: usize = 0 };
    const Reader = struct { member: ?catalog.Member = null, connection: sessions.Handle = undefined, sequence: u64 = 0, ready: bool = false };
    pub const Recipient = struct { uuid: u128, handle: sessions.Handle };
    pub const Cursor = struct {
        source: ?*const Channel = null,
        sequence: ?u64 = null,
        readers: [catalog.maximum_players]?usize = @splat(null),
        players: [catalog.maximum_players]Recipient = undefined,
        count: usize = 0,
    };
    pub const Delivery = struct { text: []const u8, recipients: []const sessions.Handle };
    pub const Batch = struct { count: usize, lagged: []const sessions.Handle };

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    messages: [capacity]Message = @splat(.{}),
    readers: [catalog.maximum_players]Reader = @splat(.{}),
    sequence: u64 = 0,
    published: std.atomic.Value(u64) = .init(0),

    pub fn connect(self: *Channel, member: catalog.Member, connection: sessions.Handle) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.readers) |reader| if (reader.member) |present| {
            if (present.uuid == member.uuid) {
                if (!std.meta.eql(reader.connection, connection)) return error.DuplicatePlayer;
                return;
            }
        };
        for (&self.readers) |*reader| {
            if (reader.member != null) continue;
            reader.* = .{ .member = member, .connection = connection, .sequence = self.sequence };
            return;
        }
        return error.PlayerLimit;
    }

    pub fn join(self: *Channel, uuid: u128, announce: bool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.readers) |*reader| {
            const member = reader.member orelse continue;
            if (member.uuid != uuid) continue;
            if (reader.ready) return true;
            reader.ready = true;
            reader.sequence = self.sequence;
            if (announce) {
                var buffer: [64]u8 = undefined;
                self.postLocked(std.fmt.bufPrint(&buffer, "{s} joined the game", .{member.name[0..member.name_len]}) catch unreachable);
            }
            return true;
        }
        return false;
    }

    pub fn leave(self: *Channel, uuid: u128, connection: sessions.Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.readers) |*reader| {
            const member = reader.member orelse continue;
            if (member.uuid != uuid or !std.meta.eql(reader.connection, connection)) continue;
            const announced = reader.ready;
            reader.* = .{};
            if (!announced) return;
            var buffer: [64]u8 = undefined;
            self.postLocked(std.fmt.bufPrint(&buffer, "{s} left the game", .{member.name[0..member.name_len]}) catch unreachable);
            return;
        }
    }

    pub fn post(self: *Channel, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.postLocked(text);
    }

    fn postLocked(self: *Channel, text: []const u8) void {
        std.debug.assert(text.len <= maximum_message);
        const message = &self.messages[self.sequence % capacity];
        @memcpy(message.bytes[0..text.len], text);
        message.length = text.len;
        self.sequence += 1;
        self.published.store(self.sequence, .release);
    }

    pub fn nextBatch(self: *Channel, cursor: *Cursor, players: []const Recipient, deliveries: []Delivery, output: []u8, recipients: []sessions.Handle, lagged: []sessions.Handle) Batch {
        std.debug.assert(players.len <= self.readers.len and deliveries.len > 0);
        std.debug.assert(output.len >= deliveries.len * maximum_message);
        std.debug.assert(recipients.len >= deliveries.len * players.len and lagged.len >= players.len);
        const same = cursor.source == self and cursor.count == players.len and same: {
            for (cursor.players[0..cursor.count], players) |previous, player| {
                if (!std.meta.eql(previous, player)) break :same false;
            }
            break :same true;
        };
        const published = self.published.load(.acquire);
        if (players.len == 0 or (same and cursor.sequence == published)) return .{ .count = 0, .lagged = lagged[0..0] };
        if (!same) {
            cursor.source = self;
            cursor.sequence = null;
            @memset(&cursor.readers, null);
        }
        @memcpy(cursor.players[0..players.len], players);
        cursor.count = players.len;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var selected: [catalog.maximum_players]?usize = @splat(null);
        var late: usize = 0;
        for (players, selected[0..players.len], cursor.readers[0..players.len]) |player, *slot, *cached| {
            const index = cached_index: {
                if (cached.*) |index| {
                    const reader = self.readers[index];
                    if (reader.member) |member| if (reader.ready and member.uuid == player.uuid) break :cached_index index;
                }
                for (self.readers, 0..) |reader, index| {
                    const member = reader.member orelse continue;
                    if (reader.ready and member.uuid == player.uuid) break :cached_index index;
                }
                cached.* = null;
                continue;
            };
            cached.* = index;
            const reader = &self.readers[index];
            if (self.sequence - reader.sequence > capacity) {
                lagged[late] = player.handle;
                late += 1;
                reader.sequence = self.sequence;
            } else slot.* = index;
        }
        var count: usize = 0;
        while (count < deliveries.len) {
            var sequence = self.sequence;
            for (selected[0..players.len]) |slot| if (slot) |index| {
                sequence = @min(sequence, self.readers[index].sequence);
            };
            if (sequence == self.sequence) break;
            const targets = recipients[count * players.len ..][0..players.len];
            var accepted: usize = 0;
            for (selected[0..players.len], players) |slot, player| if (slot) |index| {
                const reader = &self.readers[index];
                if (reader.sequence != sequence) continue;
                targets[accepted] = player.handle;
                accepted += 1;
                reader.sequence += 1;
            };
            std.debug.assert(accepted > 0);
            const message = &self.messages[sequence % capacity];
            const bytes = output[count * maximum_message ..][0..message.length];
            @memcpy(bytes, message.bytes[0..message.length]);
            deliveries[count] = .{ .text = bytes, .recipients = targets[0..accepted] };
            count += 1;
        }
        const caught_up = for (selected[0..players.len]) |slot| {
            if (slot) |index| if (self.readers[index].sequence != self.sequence) break false;
        } else true;
        if (caught_up) cursor.sequence = self.sequence;
        return .{ .count = count, .lagged = lagged[0..late] };
    }
};

pub const GlobalChat = struct {
    pub const id = "skyblock:global_chat";
    pub const Configuration = struct { channel: *Channel };
    pub const Dependencies = struct { input: *vanilla.Input, players: *vanilla.Players, chat: *vanilla.Chat, sessions: *sessions.Service };

    deps: Dependencies,
    channel: *Channel,
    pending: []?bool,
    cursor: Channel.Cursor = .{},
    deliveries: []Channel.Delivery,
    text: []u8,
    recipients: []sessions.Handle,
    lagged: []sessions.Handle,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*GlobalChat {
        const self = try allocator.create(GlobalChat);
        const pending = try allocator.alloc(?bool, deps.players.records.len);
        @memset(pending, null);
        self.* = .{
            .deps = deps,
            .channel = config.channel,
            .pending = pending,
            .deliveries = try allocator.alloc(Channel.Delivery, 8),
            .text = try allocator.alloc(u8, 8 * Channel.maximum_message),
            .recipients = try allocator.alloc(sessions.Handle, 8 * deps.players.records.len),
            .lagged = try allocator.alloc(sessions.Handle, deps.players.records.len),
        };
        try deps.input.on(.chat_message, self, message);
        return self;
    }

    fn message(self: *GlobalChat, handle: sessions.Handle, body: wire.play.toServer.packet_chat_message.Reader) !void {
        const text, _ = body.message() catch return error.InvalidPacket;
        const player = self.deps.players.records[handle.index];
        if (!player.inPlay()) return;
        if (text.len > 1024 or !std.unicode.utf8ValidateSlice(text)) {
            self.deps.sessions.disconnect(handle);
            return;
        }
        var buffer: [Channel.maximum_message]u8 = undefined;
        self.channel.post(std.fmt.bufPrint(&buffer, "<{s}> {s}", .{ player.name[0..player.name_len], text }) catch unreachable);
    }

    pub fn tick(self: *GlobalChat) !void {
        for (self.deps.sessions.input_events) |event| switch (event) {
            .joined => |joined| self.pending[joined.handle.index] = joined.cause == .login,
            .left => |handle| self.pending[handle.index] = null,
            else => {},
        };
        for (self.deps.players.records, self.pending) |player, *pending| {
            const announce = pending.* orelse continue;
            if (player.stage != .ready or player.handle == null) continue;
            if (!self.channel.join(player.uuid, announce)) continue;
            pending.* = null;
        }
        var ready: [catalog.maximum_players]Channel.Recipient = undefined;
        var eligible: usize = 0;
        for (self.deps.players.records) |player| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready or !player.inPlay()) continue;
            if (!self.deps.sessions.canSend(handle, Channel.maximum_message + 8)) continue;
            ready[eligible] = .{ .uuid = player.uuid, .handle = handle };
            eligible += 1;
        }
        const limit = @min(self.deliveries.len, self.deps.chat.available());
        if (limit != 0) {
            const result = self.channel.nextBatch(&self.cursor, ready[0..eligible], self.deliveries[0..limit], self.text, self.recipients, self.lagged);
            for (result.lagged) |handle| self.deps.sessions.disconnect(handle);
            for (self.deliveries[0..result.count]) |delivery| self.deps.chat.systemMany(delivery.recipients, delivery.text);
        }
        try self.deps.chat.flush();
    }
};
