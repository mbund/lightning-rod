//! Chat between players, signed as vanilla signs it. Each client signs its messages with its chat
//! key, chained by index and bound to the signatures it last saw; the server checks the chain and
//! the signature, then relays the message unchanged, so every client can check it too. Every
//! recipient's view of the chain is kept as vanilla keeps it: a global index of player messages,
//! the signatures it was sent and has not acknowledged, and a mirror of its signature cache to
//! refer to them by.
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const minecraft_packets = @import("minecraft_packets");
const wire = @import("wire_1_21_5");
const players_package = @import("players");
const Players = players_package.players.Players;
const Player = Players.Player;
const Input = players_package.input.Input;
const ChatSession = players_package.chat_session.ChatSession;
const Chat = @import("chat.zig").Chat;
const component = @import("component.zig");
const Selection = lightning_rod.system.bit_sets.Selection;
const assert = std.debug.assert;

pub const signature_bytes = 256;
pub const Signature = [signature_bytes]u8;
/// The signatures a message acknowledges at most: a client's window of those it last saw.
pub const last_seen_max = 20;
/// The signatures a client caches to be referred to by position, as vanilla's MessageSignatureCache.
pub const cache_size = 128;
/// The characters a message may have, as Java counts them, and the UTF-8 that takes at most.
pub const message_max = 256;
pub const message_bytes_max = 3 * message_max;
/// What a name, target or styled message takes as a component at most.
pub const component_max = 1024;

/// How a message is shown: the chat type whose layout the line takes, who is named as sending
/// it, and the message itself, styled. Clients mark a message modified, rather than secure, when
/// the message as shown leaves out the text that was signed, so styling it, and naming and
/// coloring the sender, keep it secure; rewording it does not.
pub const Line = struct {
    /// The `minecraft:chat_type` entry whose layout the line takes; vanilla's for the kind of
    /// message unless changed.
    chat_type: []const u8,
    /// The sender as shown. Left empty, the sender's name, as vanilla shows it.
    name: component.Component,
    /// The message as shown. Left empty, the message as typed.
    content: component.Component,
    /// Who receives the message: every player in play, unless narrowed. Players whose clients
    /// hide player chat never do.
    audience: Selection = .all,
};

pub const PlayerChat = struct {
    pub const id = "minecraft:player_chat";
    pub const Configuration = struct {
        /// Messages waiting to reach everyone they are for.
        pending_messages: usize = 64,
        /// The signatures a client may have been sent without acknowledging them. Vanilla allows
        /// 4096; its client acknowledges once it has 64.
        pending_signatures: usize = 256,
        /// The signatures kept for all of that, and for the messages waiting.
        signatures: usize = 8192,
        /// Vanilla's chat-spam-threshold-seconds: a player sending more than one message a second
        /// for this long is disconnected.
        spam_threshold_seconds: u32 = 10,
        /// Whether players' chat comes here, or to another plugin that owns it, such as a
        /// chat shared between servers.
        chat_input: bool = true,
    };
    pub const Dependencies = struct {
        players: *Players,
        input: *Input,
        sessions: *sessions.Service,
        packets: *minecraft_packets.Packets,
        chat: *Chat,
    };

    const none = std.math.maxInt(u32);

    /// A signature the server keeps while anything refers to it.
    const Kept = struct {
        bytes: Signature = undefined,
        /// Which message it signed, so two are told apart without comparing bytes.
        message: u64 = 0,
        /// Java's Arrays.hashCode of the bytes, which acknowledgement checksums sum.
        hash: i32 = 0,
        references: u32 = 0,
    };

    /// A signature a recipient was sent, in the window or behind it, as vanilla's
    /// LastSeenMessagesValidator keeps it. `none` once dropped from the window.
    const Tracked = struct { kept: u32 = none, pending: bool = false };

    /// What is kept for each slot's player, as sender and recipient.
    const Correspondent = struct {
        generation: u32 = 0,
        /// The chat key revision the chain belongs to; a new key starts a new chain.
        chain_revision: u32 = 0,
        /// The index the next message must have, or null once the chain is broken.
        next_index: ?i32 = 0,
        /// The last message's time, in milliseconds since the epoch; none may come before it.
        last_timestamp: i64 = 0,
        spam: u32 = 0,
        /// Player messages the client was sent, which it checks for gaps.
        global_index: i32 = 0,
        /// The messages the client caches signatures of, newest first, as it orders them.
        cache: [cache_size]u64 = @splat(0),
        tracked_start: usize = 0,
        tracked_count: usize = last_seen_max,
        last_pending: u64 = 0,
        /// The chat key revision when the player joined, and whether a key came since.
        joined_revision: u32 = 0,
        synced: bool = true,
    };

    const Wait = struct { since: u64, returned: u64 };

    const Message = struct {
        sender: u128 = 0,
        index: i32 = 0,
        signature: u32 = none,
        last_seen: [last_seen_max]u32 = undefined,
        last_seen_count: usize = 0,
        text: [message_bytes_max]u8 = undefined,
        text_len: usize = 0,
        timestamp: i64 = 0,
        salt: i64 = 0,
        chat_type: [64]u8 = undefined,
        chat_type_len: usize = 0,
        name: [component_max]u8 = undefined,
        name_len: usize = 0,
        target: [component_max]u8 = undefined,
        target_len: usize = 0,
        content: [component_max]u8 = undefined,
        content_len: usize = 0,
        recipients: []sessions.Service.Target,
        waits: []Wait,
        count: usize = 0,
        tried: bool = false,

        /// What the packet takes at most: the packet id, two indexes and the sender's UUID, the
        /// signature, the text's length, the time and salt, the count of acknowledgements, an id
        /// and signature each, the filter, the chat type, and the three components with their
        /// presence flags.
        fn bound(self: *const Message) usize {
            assert(self.text_len <= message_bytes_max and self.last_seen_count <= last_seen_max);
            return bound_fixed + self.text_len + self.last_seen_count * (5 + signature_bytes) + self.name_len + self.target_len + self.content_len;
        }

        const bound_fixed = 5 + 5 + 16 + 5 + 1 + signature_bytes + 3 + 8 + 8 + 5 + 1 + 5 + 5 + 1;
        /// The largest packet a message makes, which every connection's output must take whole.
        const bound_max = bound_fixed + message_bytes_max + last_seen_max * (5 + signature_bytes) + 3 * component_max;
    };


    const CommandMessage = struct { name: [16]u8, name_len: usize, signed: Signed };

    const Formatter = struct {
        context: *anyopaque,
        call: *const fn (*anyopaque, *const Player, []const u8, Kind, *Line) void,
    };

    deps: Dependencies,
    config: Configuration,
    io: std.Io,
    kept: []Kept,
    free: []u32,
    free_count: usize,
    next_message: u64 = 1,
    correspondents: []Correspondent,
    tracked: []Tracked,
    tracked_capacity: usize,
    messages: []Message,
    read: u64 = 0,
    write: u64 = 0,
    ticks: u64 = 0,
    formatter: ?Formatter = null,
    /// The message arguments of the command running, checked before it ran.
    command_messages: [command_arguments_max]CommandMessage = undefined,
    command_count: usize = 0,
    /// Plain text a formatter's components keep, which only the trust check reads.
    plain: [2][component_max]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*PlayerChat {
        if (config.pending_messages == 0 or config.pending_messages > 4096) return error.InvalidConfiguration;
        if (config.pending_signatures == 0 or config.pending_signatures > 4096) return error.InvalidConfiguration;
        const slots = deps.players.records.len;
        // Every message waiting holds its signature and those it acknowledges.
        if (config.signatures < config.pending_messages * (1 + last_seen_max)) return error.InvalidConfiguration;
        if (config.spam_threshold_seconds == 0) return error.InvalidConfiguration;
        if (Message.bound_max > deps.sessions.config.page_bytes) return error.ChatPacketCapacity;
        const self = try allocator.create(PlayerChat);
        const kept = try allocator.alloc(Kept, config.signatures);
        @memset(kept, .{});
        const free = try allocator.alloc(u32, config.signatures);
        for (free, 0..) |*slot, index| slot.* = @intCast(free.len - 1 - index);
        const correspondents = try allocator.alloc(Correspondent, slots);
        @memset(correspondents, .{});
        const tracked_capacity = config.pending_signatures + last_seen_max;
        const tracked = try allocator.alloc(Tracked, slots * tracked_capacity);
        @memset(tracked, .{});
        const messages = try allocator.alloc(Message, config.pending_messages);
        const recipients = try allocator.alloc(sessions.Service.Target, messages.len * slots);
        const waits = try allocator.alloc(Wait, recipients.len);
        for (messages, 0..) |*message, index| message.* = .{
            .recipients = recipients[index * slots ..][0..slots],
            .waits = waits[index * slots ..][0..slots],
        };
        self.* = .{
            .deps = deps,
            .config = config,
            .io = io,
            .kept = kept,
            .free = free,
            .free_count = free.len,
            .correspondents = correspondents,
            .tracked = tracked,
            .tracked_capacity = tracked_capacity,
            .messages = messages,
        };
        if (config.chat_input) try deps.input.on(.chat_message, self, onChat);
        try deps.input.on(.message_acknowledgement, self, onAcknowledgement);
        try deps.players.observePresence(PlayerChat, self, onPresence);
        return self;
    }

    /// Decides how every player message is shown and who receives it. Call once, while starting.
    pub fn setFormatter(self: *PlayerChat, context: anytype, comptime format: fn (@TypeOf(context), *const Player, []const u8, Kind, *Line) void) !void {
        if (self.formatter != null) return error.DuplicateChatFormatter;
        const Adapter = struct {
            fn call(raw: *anyopaque, player: *const Player, text: []const u8, kind: Kind, line: *Line) void {
                format(@ptrCast(@alignCast(raw)), player, text, kind, line);
            }
        };
        self.formatter = .{ .context = context, .call = Adapter.call };
    }

    pub fn tick(self: *PlayerChat) !void {
        self.ticks += 1;
        for (self.deps.players.activeSlots()) |slot| {
            const state = &self.correspondents[slot];
            if (state.spam > 0) state.spam -= 1;
        }
        try self.flush();
    }

    // Signatures kept --------------------------------------------------------------------------

    fn keep(self: *PlayerChat, bytes: *const Signature) ?u32 {
        assert(self.free_count <= self.kept.len);
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const slot = self.free[self.free_count];
        assert(slot < self.kept.len);
        const entry = &self.kept[slot];
        assert(entry.references == 0 and entry.message == 0);
        var hash: i32 = 1;
        for (bytes) |byte| hash = hash *% 31 +% @as(i8, @bitCast(byte));
        entry.* = .{ .bytes = bytes.*, .message = self.next_message, .hash = hash, .references = 1 };
        self.next_message += 1;
        // A message id is never zero, which marks an empty cache entry.
        assert(entry.message != 0 and self.next_message > entry.message);
        return slot;
    }

    fn retain(self: *PlayerChat, slot: u32) void {
        assert(slot < self.kept.len);
        assert(self.kept[slot].references > 0 and self.kept[slot].references < std.math.maxInt(u32));
        self.kept[slot].references += 1;
    }

    fn release(self: *PlayerChat, slot: u32) void {
        if (slot == none) return;
        assert(slot < self.kept.len);
        const entry = &self.kept[slot];
        assert(entry.references > 0 and entry.message != 0);
        entry.references -= 1;
        if (entry.references != 0) return;
        entry.message = 0;
        assert(self.free_count < self.free.len);
        self.free[self.free_count] = slot;
        self.free_count += 1;
    }

    // Each recipient's window -----------------------------------------------------------------

    fn trackedOf(self: *PlayerChat, slot: usize) []Tracked {
        assert(slot < self.correspondents.len);
        return self.tracked[slot * self.tracked_capacity ..][0..self.tracked_capacity];
    }

    fn trackedAt(self: *PlayerChat, slot: usize, position: usize) *Tracked {
        const state = &self.correspondents[slot];
        assert(position < state.tracked_count);
        return &self.trackedOf(slot)[(state.tracked_start + position) % self.tracked_capacity];
    }

    /// Vanilla's LastSeenMessagesValidator.applyOffset: the client no longer needs the oldest.
    fn applyOffset(self: *PlayerChat, slot: usize, offset: i32) error{ChatValidation}!void {
        const state = &self.correspondents[slot];
        // The window is always whole; what is behind it may be empty.
        assert(state.tracked_count >= last_seen_max and state.tracked_count <= self.tracked_capacity);
        if (offset < 0 or offset > state.tracked_count - last_seen_max) return error.ChatValidation;
        for (0..@intCast(offset)) |position| {
            const entry = self.trackedAt(slot, position);
            self.release(entry.kept);
            entry.* = .{};
        }
        state.tracked_start = (state.tracked_start + @as(usize, @intCast(offset))) % self.tracked_capacity;
        state.tracked_count -= @intCast(offset);
        assert(state.tracked_count >= last_seen_max and state.tracked_start < self.tracked_capacity);
    }

    /// Vanilla's applyUpdate: the offset, then which of the window the message acknowledges, in
    /// order, and their checksum.
    fn applyUpdate(self: *PlayerChat, slot: usize, offset: i32, acknowledged: *const [3]u8, checksum: u8, seen: *[last_seen_max]u32) error{ChatValidation}!usize {
        try self.applyOffset(slot, offset);
        // Twenty bits; the last byte's upper half is past the window.
        if (acknowledged[2] & 0xf0 != 0) return error.ChatValidation;
        var count: usize = 0;
        for (0..last_seen_max) |position| {
            const entry = self.trackedAt(slot, position);
            const set = (acknowledged[position / 8] >> @intCast(position % 8)) & 1 != 0;
            if (set) {
                if (entry.kept == none) return error.ChatValidation;
                entry.pending = false;
                seen[count] = entry.kept;
                count += 1;
            } else {
                if (entry.kept != none and !entry.pending) return error.ChatValidation;
                self.release(entry.kept);
                entry.* = .{};
            }
        }
        if (checksum != 0 and @as(i8, @bitCast(checksum)) != self.checksumOf(seen[0..count])) return error.ChatValidation;
        assert(count <= last_seen_max);
        return count;
    }

    /// Vanilla's LastSeenMessages.computeChecksum.
    fn checksumOf(self: *const PlayerChat, seen: []const u32) i8 {
        assert(seen.len <= last_seen_max);
        var hash: i32 = 1;
        for (seen) |slot| hash = hash *% 31 +% self.kept[slot].hash;
        const byte: i8 = @truncate(hash);
        return if (byte == 0) 1 else byte;
    }

    /// Vanilla's addPending, with its limit on what a client may leave unacknowledged.
    fn addPending(self: *PlayerChat, slot: usize, kept: u32) bool {
        const state = &self.correspondents[slot];
        assert(state.tracked_count >= last_seen_max and state.tracked_count <= self.tracked_capacity);
        assert(self.kept[kept].references > 0);
        const message = self.kept[kept].message;
        if (state.last_pending == message) return true;
        if (state.tracked_count == self.tracked_capacity) return false;
        self.retain(kept);
        self.trackedOf(slot)[(state.tracked_start + state.tracked_count) % self.tracked_capacity] = .{ .kept = kept, .pending = true };
        state.tracked_count += 1;
        state.last_pending = message;
        assert(state.tracked_count <= self.tracked_capacity);
        return true;
    }

    // Each recipient's cache ------------------------------------------------------------------

    fn cached(cache: *const [cache_size]u64, message: u64) ?usize {
        for (cache, 0..) |entry, position| if (entry == message) return position;
        return null;
    }

    /// Vanilla's MessageSignatureCache.push: what a message acknowledges and its own signature
    /// move to the front, newest first, and the rest follow in order.
    fn pushCache(cache: *[cache_size]u64, seen: []const u64, signed: u64) void {
        assert(seen.len <= last_seen_max and signed != 0);
        // A deque, filled from the back and drained from the back, with room at the front.
        var deque: [2 * (cache_size + last_seen_max + 1)]u64 = undefined;
        var head: usize = cache_size;
        var tail: usize = head;
        for (seen) |message| {
            deque[tail] = message;
            tail += 1;
        }
        deque[tail] = signed;
        tail += 1;
        const set = deque[head..tail];
        var set_copy: [last_seen_max + 1]u64 = undefined;
        @memcpy(set_copy[0..set.len], set);
        const members = set_copy[0..set.len];
        var position: usize = 0;
        while (head != tail and position < cache_size) : (position += 1) {
            const old = cache[position];
            tail -= 1;
            cache[position] = deque[tail];
            if (old != 0 and std.mem.indexOfScalar(u64, members, old) == null) {
                head -= 1;
                deque[head] = old;
            }
        }
        // The newest signature leads, and entries are filled from the front.
        assert(cache[0] == signed);
        var empty = false;
        for (cache) |entry| {
            assert(!(empty and entry != 0));
            empty = empty or entry == 0;
        }
    }

    // Lifecycle -------------------------------------------------------------------------------

    fn onPresence(self: *PlayerChat, events: []const sessions.Event) !void {
        for (events) |event| switch (event) {
            .joined => |joined| self.begin(joined.handle.index, joined.handle.generation),
            .left => |handle| self.end(handle.index),
            .ready, .input => {},
        };
    }

    fn begin(self: *PlayerChat, slot: usize, generation: u32) void {
        assert(generation != 0);
        self.end(slot);
        const state = &self.correspondents[slot];
        assert(state.generation == 0 and state.tracked_count == last_seen_max);
        state.generation = generation;
        const player = &self.deps.players.records[slot];
        state.chain_revision = player.chat_revision;
        state.joined_revision = player.chat_revision;
        state.synced = !self.deps.players.securesChat(player.handle.?);
    }

    /// Whether what the client says of chat follows from what this server told it. A client
    /// starts its chat over with each login packet, as a reload sends it, and then sends a new
    /// key; until then it may still speak of the last process's chat, which is forgiven rather
    /// than taken for a broken client. Offline, nothing is signed, so there is nothing to follow.
    fn synced(self: *PlayerChat, slot: usize) bool {
        const state = &self.correspondents[slot];
        if (!state.synced and self.deps.players.records[slot].chat_revision != state.joined_revision) state.synced = true;
        return state.synced;
    }

    fn end(self: *PlayerChat, slot: usize) void {
        const state = &self.correspondents[slot];
        if (state.generation == 0) return;
        for (0..state.tracked_count) |position| {
            const entry = self.trackedAt(slot, position);
            self.release(entry.kept);
            entry.* = .{};
        }
        state.* = .{};
        // A window starts as twenty empty entries, as vanilla's validator does.
        assert(state.tracked_count == last_seen_max and state.generation == 0);
    }

    fn current(self: *PlayerChat, handle: sessions.Handle) ?*Correspondent {
        const state = &self.correspondents[handle.index];
        if (state.generation != handle.generation) return null;
        return state;
    }

    // Input -----------------------------------------------------------------------------------

    fn onAcknowledgement(self: *PlayerChat, handle: sessions.Handle, body: wire.play.toServer.packet_message_acknowledgement.Reader) !void {
        const count, _ = body.count() catch return error.InvalidPacket;
        if (self.current(handle) == null) return;
        self.applyOffset(handle.index, count) catch {
            if (!self.synced(handle.index)) return;
            return self.refuse(handle, "multiplayer.disconnect.chat_validation_failed");
        };
    }

    fn onChat(self: *PlayerChat, handle: sessions.Handle, body: wire.play.toServer.packet_chat_message.Reader) !void {
        const text, const a = body.message() catch return error.InvalidPacket;
        const timestamp, const b = a.timestamp() catch return error.InvalidPacket;
        const salt, const c = b.salt() catch return error.InvalidPacket;
        var signature_field = c.signature() catch return error.InvalidPacket;
        var signature: ?Signature = null;
        const d = switch (try (signature_field.begin() catch return error.InvalidPacket).value()) {
            .none => |done| signature_field.advance(done) catch return error.InvalidPacket,
            .some => |present| some: {
                var child = present;
                const bytes, const done = (child.begin() catch return error.InvalidPacket).value() catch return error.InvalidPacket;
                if (bytes.len != signature_bytes) return error.InvalidPacket;
                signature = bytes[0..signature_bytes].*;
                break :some signature_field.advance(child.advance(done) catch return error.InvalidPacket) catch return error.InvalidPacket;
            },
        };
        const offset, const e = d.offset() catch return error.InvalidPacket;
        const acknowledged, const f = e.acknowledged() catch return error.InvalidPacket;
        const checksum, _ = f.checksum() catch return error.InvalidPacket;
        if (acknowledged.len != 3) return error.InvalidPacket;

        const player = &self.deps.players.records[handle.index];
        if (!player.inPlay() or self.current(handle) == null) return;
        var seen: [last_seen_max]u32 = undefined;
        const seen_count = self.applyUpdate(handle.index, offset, acknowledged[0..3], @bitCast(checksum), &seen) catch {
            if (!self.synced(handle.index)) return self.notify(handle, "chat.cannotSend");
            return self.refuse(handle, "multiplayer.disconnect.chat_validation_failed");
        };
        try self.receive(handle, text, timestamp, salt, if (signature) |*value| value else null, seen[0..seen_count]);
    }

    /// A message a player signed and the server checked, ready to send: its chain index, its
    /// signature and those it acknowledged, which it holds until let go.
    pub const Signed = struct {
        sender: u128,
        index: i32 = 0,
        kept: u32 = none,
        seen: [last_seen_max]u32 = undefined,
        seen_count: usize = 0,
        text: []const u8,
        timestamp: i64,
        salt: i64,
    };

    /// What a message is: player chat, or what a command sends. Each has vanilla's chat type.
    pub const Kind = enum {
        chat,
        emote,
        say,
        msg_incoming,
        msg_outgoing,

        pub fn chatType(kind: Kind) []const u8 {
            return switch (kind) {
                .chat => "minecraft:chat",
                .emote => "minecraft:emote_command",
                .say => "minecraft:say_command",
                .msg_incoming => "minecraft:msg_command_incoming",
                .msg_outgoing => "minecraft:msg_command_outgoing",
            };
        }
    };

    fn receive(self: *PlayerChat, handle: sessions.Handle, text: []const u8, timestamp: i64, salt: i64, signature: ?*const Signature, seen: []const u32) !void {
        const player = &self.deps.players.records[handle.index];
        if (!validText(text)) return self.refuse(handle, "multiplayer.disconnect.illegal_characters");
        if (player.chat_mode == 2) return self.notify(handle, "chat.disabled.options");
        var signed = self.unpack(handle, text, timestamp, salt, signature, seen) orelse return;
        defer self.forget(&signed);
        if (!self.queue(&signed, .chat, null, null)) {
            // A full queue is a server behind on everyone, which no one player causes.
            std.log.warn("event=chat_queue_full connection={d}:{d}", .{ handle.index, handle.generation });
            return self.notify(handle, "chat.cannotSend");
        }
        const state = self.current(handle).?;
        state.spam += 20;
        if (state.spam >= 20 * self.config.spam_threshold_seconds) return self.refuse(handle, "disconnect.spam");
    }

    /// Vanilla's SignedMessageChain decoder, in its order: the message must carry the sender's
    /// signature, continue its chain, come no earlier than the last, and check out against the
    /// sender's key. The sender is told why when it does not, and gets null. A player without a
    /// key, offline, sends unsigned chat.
    fn unpack(self: *PlayerChat, handle: sessions.Handle, text: []const u8, timestamp: i64, salt: i64, signature: ?*const Signature, seen: []const u32) ?Signed {
        const player = &self.deps.players.records[handle.index];
        const state = self.current(handle).?;
        // A new key starts a new chain, at the first index.
        if (state.chain_revision != player.chat_revision) {
            state.chain_revision = player.chat_revision;
            state.next_index = 0;
            state.last_timestamp = 0;
        }
        var signed: Signed = .{ .sender = player.uuid, .text = text, .timestamp = timestamp, .salt = salt };
        const key = self.deps.players.chatSession(handle.index) orelse {
            if (self.deps.players.securesChat(handle)) {
                self.notify(handle, "chat.disabled.missingProfileKey");
                return null;
            }
            return signed;
        };
        const value = signature orelse {
            self.notify(handle, "chat.disabled.missingProfileKey");
            return null;
        };
        // Chat's only reading of the wall clock: Mojang dates a key's expiry in it.
        if (key.expired(std.Io.Clock.real.now(self.io).toMilliseconds())) {
            self.notify(handle, "chat.disabled.expiredProfileKey");
            return null;
        }
        const index = state.next_index orelse {
            self.notify(handle, "chat.disabled.chain_broken");
            return null;
        };
        if (timestamp < state.last_timestamp) {
            state.next_index = null;
            self.notify(handle, "chat.disabled.out_of_order_chat");
            return null;
        }
        state.last_timestamp = timestamp;
        if (!self.verify(player.uuid, key, index, salt, timestamp, text, value, seen)) {
            state.next_index = null;
            self.notify(handle, "chat.disabled.invalid_signature");
            return null;
        }
        state.next_index = std.math.add(i32, index, 1) catch null;
        signed.index = index;
        signed.kept = self.keep(value) orelse {
            std.log.warn("event=chat_signatures_exhausted connection={d}:{d}", .{ handle.index, handle.generation });
            self.notify(handle, "chat.cannotSend");
            return null;
        };
        for (seen, 0..) |slot, position| {
            self.retain(slot);
            signed.seen[position] = slot;
        }
        signed.seen_count = seen.len;
        return signed;
    }

    /// Lets go of what a checked message held.
    fn forget(self: *PlayerChat, signed: *Signed) void {
        assert(signed.seen_count <= last_seen_max);
        // Only signed messages acknowledge signatures.
        assert(signed.kept != none or signed.seen_count == 0);
        self.release(signed.kept);
        signed.kept = none;
        for (signed.seen[0..signed.seen_count]) |slot| self.release(slot);
        signed.seen_count = 0;
    }

    /// Vanilla's illegal characters: the section sign, control characters and delete.
    pub fn validText(text: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(text)) return false;
        var units: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (view.nextCodepoint()) |codepoint| {
            if (codepoint == 0xa7 or codepoint < 32 or codepoint == 127) return false;
            units += if (codepoint > 0xffff) 2 else 1;
        }
        return units <= message_max;
    }

    /// What a client signs, as vanilla's SignedMessageBody.updateSignature lays it out.
    fn verify(self: *const PlayerChat, sender: u128, key: *const ChatSession, index: i32, salt: i64, timestamp: i64, text: []const u8, signature: *const Signature, seen: []const u32) bool {
        assert(text.len <= message_bytes_max and seen.len <= last_seen_max and index >= 0);
        var header: [4 + 16 + 16 + 4 + 8 + 8 + 4]u8 = undefined;
        std.mem.writeInt(i32, header[0..4], 1, .big);
        std.mem.writeInt(u128, header[4..20], sender, .big);
        std.mem.writeInt(u128, header[20..36], key.id, .big);
        std.mem.writeInt(i32, header[36..40], index, .big);
        std.mem.writeInt(i64, header[40..48], salt, .big);
        std.mem.writeInt(i64, header[48..56], @divFloor(timestamp, 1000), .big);
        std.mem.writeInt(i32, header[56..60], @intCast(text.len), .big);
        var count: [4]u8 = undefined;
        std.mem.writeInt(i32, &count, @intCast(seen.len), .big);
        var parts: [3 + last_seen_max][]const u8 = undefined;
        parts[0] = &header;
        parts[1] = text;
        parts[2] = &count;
        for (seen, 0..) |slot, position| parts[3 + position] = &self.kept[slot].bytes;
        return key.public_key.verify(signature, parts[0 .. 3 + seen.len]);
    }

    /// A red line of vanilla's text for `key`, as vanilla tells a player why chat went nowhere.
    pub fn notify(self: *PlayerChat, handle: sessions.Handle, comptime key: []const u8) void {
        var buffer: [128]u8 = undefined;
        // The compound, its translate and color strings with their tags and names, and its end.
        comptime assert(1 + (1 + 2 + "translate".len + 2 + key.len) + (1 + 2 + "color".len + 2 + "red".len) + 1 <= buffer.len);
        const line = component.translatable(&buffer, key, "red") catch unreachable;
        self.deps.chat.systemComponent(handle, line);
    }

    fn refuse(self: *PlayerChat, handle: sessions.Handle, reason: []const u8) error{Refused} {
        return self.deps.players.refuse(&self.deps.players.records[handle.index], reason);
    }

    // Commands --------------------------------------------------------------------------------

    /// A command argument the client signs, as vanilla's message arguments are.
    pub const CommandArgument = struct { name: []const u8, value: []const u8 };
    pub const ArgumentSignature = struct { name: []const u8, signature: *const Signature };
    pub const command_arguments_max = 8;

    /// Takes what a command's packet acknowledges, as a chat message's does, into `seen`. Null
    /// when the player is not in play, or its client still speaks of the last process's chat.
    pub fn acknowledge(self: *PlayerChat, handle: sessions.Handle, offset: i32, acknowledged: *const [3]u8, checksum: u8, seen: *[last_seen_max]u32) error{Refused}!?usize {
        const player = &self.deps.players.records[handle.index];
        if (!player.inPlay() or self.current(handle) == null) return null;
        return self.applyUpdate(handle.index, offset, acknowledged, checksum, seen) catch {
            if (!self.synced(handle.index)) {
                self.notify(handle, "chat.cannotSend");
                return null;
            }
            return self.refuse(handle, "multiplayer.disconnect.chat_validation_failed");
        };
    }

    /// Checks a command's message arguments, in order, before it runs, as vanilla's
    /// performSignedChatCommand does; each takes the next index of the sender's chain. False when
    /// one fails, and the sender was told; the command must not run then. `endCommand` lets go of
    /// them once it ran.
    pub fn beginCommand(self: *PlayerChat, handle: sessions.Handle, arguments: []const CommandArgument, signatures: []const ArgumentSignature, timestamp: i64, salt: i64, seen: []const u32) bool {
        assert(self.command_count == 0);
        assert(arguments.len <= command_arguments_max);
        if (signatures.len != 0 and signatures.len != arguments.len) {
            self.notify(handle, "chat.disabled.invalid_command_signature");
            return false;
        }
        for (arguments) |argument| {
            var signature: ?*const Signature = null;
            if (signatures.len != 0) {
                for (signatures) |candidate| {
                    if (std.mem.eql(u8, candidate.name, argument.name)) signature = candidate.signature;
                }
                if (signature == null) {
                    self.notify(handle, "chat.disabled.invalid_command_signature");
                    self.endCommand();
                    return false;
                }
            }
            if (argument.name.len > self.command_messages[0].name.len) {
                self.endCommand();
                return false;
            }
            const signed = self.unpack(handle, argument.value, timestamp, salt, signature, seen) orelse {
                self.endCommand();
                return false;
            };
            const entry = &self.command_messages[self.command_count];
            entry.* = .{ .name = undefined, .name_len = argument.name.len, .signed = signed };
            @memcpy(entry.name[0..argument.name.len], argument.name);
            self.command_count += 1;
        }
        return true;
    }

    /// A message argument of the command running, checked.
    pub fn commandMessage(self: *const PlayerChat, name: []const u8) ?*const Signed {
        for (self.command_messages[0..self.command_count]) |*entry| {
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) return &entry.signed;
        }
        return null;
    }

    pub fn endCommand(self: *PlayerChat) void {
        for (self.command_messages[0..self.command_count]) |*entry| self.forget(&entry.signed);
        self.command_count = 0;
    }

    /// Sends a command's checked message as `kind`: to the players in `recipients`, or to
    /// everyone, naming `target` for a private message. False when the queue is full.
    pub fn sendCommandMessage(self: *PlayerChat, signed: *const Signed, kind: Kind, recipients: ?[]const usize, target: ?[]const u8) bool {
        return self.queue(signed, kind, recipients, target);
    }

    // Delivery --------------------------------------------------------------------------------

    fn queue(self: *PlayerChat, signed: *const Signed, kind: Kind, recipients: ?[]const usize, target: ?[]const u8) bool {
        assert(self.read <= self.write and self.write - self.read <= self.messages.len);
        assert(signed.text.len <= message_bytes_max and signed.seen_count <= last_seen_max);
        if (self.write - self.read == self.messages.len) return false;
        const sender = self.deps.players.find(signed.sender) orelse return true;
        const message = &self.messages[self.write % self.messages.len];
        message.sender = signed.sender;
        message.index = signed.index;
        message.signature = signed.kept;
        if (signed.kept != none) self.retain(signed.kept);
        for (signed.seen[0..signed.seen_count], 0..) |slot, position| {
            self.retain(slot);
            message.last_seen[position] = slot;
        }
        message.last_seen_count = signed.seen_count;
        @memcpy(message.text[0..signed.text.len], signed.text);
        message.text_len = signed.text.len;
        message.timestamp = signed.timestamp;
        message.salt = signed.salt;

        var line: Line = .{
            .chat_type = kind.chatType(),
            .name = .init(&message.name, &self.plain[0]),
            .content = .init(&message.content, &self.plain[1]),
        };
        if (self.formatter) |formatter| formatter.call(formatter.context, sender, signed.text, kind, &line);
        if (line.chat_type.len > message.chat_type.len) line.chat_type = kind.chatType();
        @memcpy(message.chat_type[0..line.chat_type.len], line.chat_type);
        message.chat_type_len = line.chat_type.len;
        message.name_len = if (line.name.bytes() catch null) |bytes| bytes.len else self.writeName(message, sender);
        message.content_len = if (line.content.bytes() catch null) |bytes| bytes.len else 0;
        message.target_len = 0;
        if (target) |name| {
            if (name.len <= message.target.len) {
                @memcpy(message.target[0..name.len], name);
                message.target_len = name.len;
            }
        }
        if (message.content_len != 0 and std.mem.indexOf(u8, line.content.plainText(), signed.text) == null)
            std.log.info("event=chat_shown_modified sender={x} reason=content_leaves_out_message", .{signed.sender});

        message.count = 0;
        const records = self.deps.players.records;
        const slots = recipients orelse self.deps.players.activeSlots();
        for (slots) |slot| {
            const recipient = records[slot];
            if (!line.audience.contains(slot) or !recipient.inPlay() or recipient.chat_mode != 0) continue;
            if (self.correspondents[slot].generation != recipient.handle.?.generation) continue;
            message.recipients[message.count] = .{ .handle = recipient.handle.?, .protocol = recipient.protocol };
            message.count += 1;
        }
        message.tried = false;
        self.write += 1;
        assert(message.count <= message.recipients.len and message.name_len != 0);
        assert(message.bound() <= Message.bound_max);
        return true;
    }

    /// The sender as vanilla names them in chat: their name, which shift-click inserts and click
    /// starts a private message to.
    fn writeName(self: *PlayerChat, message: *Message, sender: *const Player) usize {
        const name_max = @typeInfo(@FieldType(Player, "name")).array.len;
        // The root and its count, the text, the insertion, the click event with its action and
        // command, and the ends of the run and the root.
        comptime assert(23 + (1 + 2 + 4 + 2 + name_max) + (1 + 2 + 9 + 2 + name_max) +
            (1 + 2 + 11 + (1 + 2 + 6 + 2 + 15) + (1 + 2 + 7 + 2 + 6 + name_max + 1) + 1) + 2 <= component_max);
        comptime assert(name_max <= component_max);
        const name = sender.name[0..sender.name_len];
        var suggestion: [6 + name_max + 1]u8 = undefined;
        const command = std.fmt.bufPrint(&suggestion, "/tell {s} ", .{name}) catch unreachable;
        var built: component.Component = .init(&message.name, &self.plain[0]);
        built.text(name, .{ .insertion = name, .click = .{ .suggest_command = command } }) catch unreachable;
        return ((built.bytes() catch unreachable) orelse unreachable).len;
    }

    const patience_ticks = 100;

    pub fn flush(self: *PlayerChat) !void {
        const service = self.deps.sessions;
        assert(self.read <= self.write and self.write - self.read <= self.messages.len);
        while (self.read != self.write) {
            const message = &self.messages[self.read % self.messages.len];
            assert(message.count <= message.recipients.len);
            var remaining: usize = 0;
            for (message.recipients[0..message.count], message.waits[0..message.count]) |target, before| {
                const state = self.current(target.handle) orelse continue;
                switch (self.deliver(message, target, state)) {
                    .queued, .closed => continue,
                    .backpressured => {},
                }
                const returned = service.returnedCredit(target.handle);
                var wait = before;
                if (!message.tried or returned != wait.returned) wait = .{ .since = self.ticks, .returned = returned };
                if (self.ticks - wait.since >= patience_ticks) {
                    std.log.warn("event=chat_recipient_disconnected connection={d}:{d} output_credit={d}", .{ target.handle.index, target.handle.generation, service.outputCredit(target.handle) });
                    service.disconnect(target.handle);
                    continue;
                }
                message.recipients[remaining] = target;
                message.waits[remaining] = wait;
                remaining += 1;
            }
            assert(remaining <= message.count);
            message.count = remaining;
            message.tried = true;
            if (remaining != 0) break;
            self.retire(message);
            self.read += 1;
        }
    }

    fn retire(self: *PlayerChat, message: *Message) void {
        assert(message.count == 0 and message.last_seen_count <= last_seen_max);
        self.release(message.signature);
        message.signature = none;
        for (message.last_seen[0..message.last_seen_count]) |slot| self.release(slot);
        message.last_seen_count = 0;
    }

    const Delivered = enum { queued, backpressured, closed };

    fn deliver(self: *PlayerChat, message: *const Message, target: sessions.Service.Target, state: *Correspondent) Delivered {
        assert(state.generation == target.handle.generation);
        assert(message.signature != none or message.last_seen_count == 0);
        const selected = self.deps.packets.definition(target.protocol) catch unreachable;
        // A chat type the release lacks falls back to vanilla's own, which every release has.
        const chat_type = selected.registryId("minecraft:chat_type", message.chat_type[0..message.chat_type_len]) catch
            selected.registryId("minecraft:chat_type", "minecraft:chat") catch
            std.debug.panic("release {d} has no minecraft:chat chat type", .{target.protocol});
        var packed_seen: [last_seen_max]?usize = undefined;
        var seen_messages: [last_seen_max]u64 = undefined;
        for (message.last_seen[0..message.last_seen_count], 0..) |slot, position| {
            seen_messages[position] = self.kept[slot].message;
            packed_seen[position] = cached(&state.cache, seen_messages[position]);
        }
        const packet: Outgoing = .{ .chat = self, .message = message, .global_index = state.global_index, .packed_seen = packed_seen[0..message.last_seen_count], .chat_type = chat_type };
        self.deps.packets.sendPacket(writePlayerChat, target.protocol, target.handle, .{&packet}, message.bound()) catch |err| switch (err) {
            error.Backpressured => return .backpressured,
            error.Closed => return .closed,
            else => std.debug.panic("invalid player chat packet: {s}", .{@errorName(err)}),
        };
        state.global_index +%= 1;
        if (message.signature == none) return .queued;
        pushCache(&state.cache, seen_messages[0..message.last_seen_count], self.kept[message.signature].message);
        if (!self.addPending(target.handle.index, message.signature)) {
            _ = self.deps.players.refuse(&self.deps.players.records[target.handle.index], "multiplayer.disconnect.too_many_pending_chats") catch {};
            return .closed;
        }
        return .queued;
    }

    const Outgoing = struct {
        chat: *const PlayerChat,
        message: *const Message,
        global_index: i32,
        packed_seen: []const ?usize,
        chat_type: i32,
    };

    fn writePlayerChat(packet: wire.play.toClient.packet_player_chat.Writer, outgoing: *const Outgoing) ![]u8 {
        const message = outgoing.message;
        const kept = outgoing.chat.kept;
        const a = try (try (try packet.globalIndex(outgoing.global_index)).senderUuid(message.sender)).index(message.index);
        var signature = try a.signature();
        const present = try signature.begin();
        const b = try signature.advance(if (message.signature == none) try present.none() else try present.some(&kept[message.signature].bytes));
        const c = try (try (try b.plainMessage(message.text[0..message.text_len])).timestamp(message.timestamp)).salt(message.salt);
        var previous = try c.previousMessages();
        const d = try previous.advance(try minecraft_packets.nested(.{writePrevious}).write(try previous.begin(), outgoing));
        var unsigned = try d.unsignedChatContent();
        const unsigned_value = try unsigned.begin();
        const e = try unsigned.advance(if (message.content_len == 0) try unsigned_value.none() else try unsigned_value.some(message.content[0..message.content_len]));
        const f = try e.filterType(0);
        var mask = try f.filterTypeMask();
        const g = try mask.advance(try (try mask.begin()).case_default());
        var holder = try g.type();
        const h = try holder.advance(try minecraft_packets.nested(.{writeChatType}).write(try holder.begin(), outgoing.chat_type));
        const i = try h.networkName(message.name[0..message.name_len]);
        var target = try i.networkTargetName();
        const target_value = try target.begin();
        const done = try target.advance(if (message.target_len == 0) try target_value.none() else try target_value.some(message.target[0..message.target_len]));
        const bytes = done.finish();
        assert(bytes.len <= message.bound());
        return bytes;
    }

    /// A chat type by its registry id, which the holder writes one past, zero meaning one inline.
    fn writeChatType(packet: wire.play.toClient.ChatTypesHolder.Writer, registry_id: i32) !wire.play.toClient.ChatTypesHolder.Writer.Done {
        return packet.chatType(registry_id + 1);
    }

    /// What the message acknowledges: the position in the recipient's cache of each signature it
    /// has, after one, and in full each it lacks.
    fn writePrevious(packet: wire.previousMessages.Writer, outgoing: *const Outgoing) !wire.previousMessages.Writer.Done {
        const message = outgoing.message;
        var list = try packet.value(message.last_seen_count);
        for (message.last_seen[0..message.last_seen_count], outgoing.packed_seen) |slot, position| {
            const entry = (try list.next()).?;
            const numbered = try entry.id(if (position) |found| @intCast(found + 1) else 0);
            var full = try numbered.signature();
            const value = try full.begin();
            try list.advance(try full.advance(if (position != null) try value.case_default() else try value.case_0(&outgoing.chat.kept[slot].bytes)));
        }
        return list.finish();
    }
};

const testing = std.testing;

test "the signature cache takes a message's acknowledgements and signature first, newest first" {
    var cache: [cache_size]u64 = @splat(0);
    PlayerChat.pushCache(&cache, &.{}, 1);
    try testing.expectEqualSlices(u64, &.{ 1, 0 }, cache[0..2]);
    PlayerChat.pushCache(&cache, &.{1}, 2);
    try testing.expectEqualSlices(u64, &.{ 2, 1, 0 }, cache[0..3]);
    // A message acknowledging an older one brings it forward; the rest keep their order.
    PlayerChat.pushCache(&cache, &.{ 1, 2 }, 3);
    try testing.expectEqualSlices(u64, &.{ 3, 2, 1, 0 }, cache[0..4]);
    PlayerChat.pushCache(&cache, &.{1}, 4);
    try testing.expectEqualSlices(u64, &.{ 4, 1, 3, 2, 0 }, cache[0..5]);
    // A full cache drops the oldest.
    for (5..5 + cache_size) |message| PlayerChat.pushCache(&cache, &.{}, message);
    try testing.expectEqual(@as(u64, 4 + cache_size), cache[0]);
    try testing.expectEqual(@as(u64, 5), cache[cache_size - 1]);
}

test "a cache that starts empty stays the front of a client's that does not" {
    // After a reload the server's mirror starts empty while the client keeps its own; ids the
    // server refers to must point at the same signatures in the client's.
    var client: [cache_size]u64 = @splat(0);
    var server: [cache_size]u64 = @splat(0);
    for (1..200) |message| PlayerChat.pushCache(&client, &.{}, message);
    var random = std.Random.DefaultPrng.init(7);
    var next: u64 = 1000;
    for (0..500) |_| {
        var seen: [last_seen_max]u64 = undefined;
        const count = random.random().uintAtMost(usize, last_seen_max);
        // A client acknowledges each signature once, so the picks are distinct.
        var start = random.random().uintLessThan(usize, cache_size - last_seen_max);
        for (seen[0..count]) |*message| {
            message.* = client[start];
            start += 1;
        }
        PlayerChat.pushCache(&client, seen[0..count], next);
        PlayerChat.pushCache(&server, seen[0..count], next);
        next += 1;
        for (server, 0..) |message, position| {
            if (message != 0) try testing.expectEqual(message, client[position]);
        }
    }
}

test {
    testing.refAllDecls(PlayerChat);
}

/// A PlayerChat with only its kept signatures and one player's window, for the checks that need
/// nothing more.
fn bare(kept: []PlayerChat.Kept, free: []u32, correspondents: []PlayerChat.Correspondent, tracked: []PlayerChat.Tracked) PlayerChat {
    var chat: PlayerChat = undefined;
    for (free, 0..) |*slot, index| slot.* = @intCast(free.len - 1 - index);
    @memset(kept, .{});
    @memset(correspondents, .{ .generation = 1 });
    @memset(tracked, .{});
    chat.kept = kept;
    chat.free = free;
    chat.free_count = free.len;
    chat.next_message = 1;
    chat.correspondents = correspondents;
    chat.tracked = tracked;
    chat.tracked_capacity = tracked.len;
    return chat;
}

// Signed by 26.2's PlayerChatMessage.updateSignature with the minecraft_java RSA test key, for
// a sender, session, salt and times both tests share; the second acknowledges two signatures.
const vanilla_key_hex = "30820122300d06092a864886f70d01010105000382010f003082010a0282010100cae9d8a694a845cac205f07792b185c680d7f58591ac584f06aec5a7680f3c0fa08d5817a596a135ed9a5d290e45ee7fd96e6ca60f487e217f7c8a95de13b984f5961dbc14810212874df6b508135cc65866a18d15453b08bb472e3ef46e06f382b4c6a3e88288bd72b5595297b22657a0f329af91efe977851987f00c8c4645539dd5a7665b32333bd184d6b7f8b95fe953eeef85d5b637eb19b2c8c91c9d8f466fc54a58bb95e41d09246e91f9cf937a1b32296b3e92024fd51b7d2fcab4caad8d0406065f299fa7bf956c9d2948ea2e955066fa648b8db9e4cd4776bc2633c7b0dc807e9fc6e7fff3c561923c8ac4614606e1120bd9e6a1a603b01cf7e6450203010001";
const vanilla_cases = .{
    .{ "1b653439a159cb42b8f3848ce26cbfb7d368a4e3613f390586d453c73dc8ef198675f26582e86127ed8245bcb7f18ddbe7faa881a6dd2cbba93618c757a1e30a597245a9fb2aa1c06fd909ffdb894f6faf2747997d3ee3abc13428610837f26eb8d3cb3f6fdaf5384415246397b162daedf28dd2692ed2d3f385390e4f91c4688550c06dc6772e47985b29513c4fdef90a45e84858365e3b3f2e2ddccc17a69f378aebf9288ff71b4b1028c21ef34a4403a22e83fc63d3ccd1bc3c90243099c3f470d90046457024675ed99772da23513a03ec042ba8d7cdf9d833c722f9ff0935989ab66a18dd9fdb55f72eb26890b74cf82e69199db0f9415dab2e04c5957a", 0, 1 },
    .{ "1ec2e11dd7e18d1a2b7222d58effc2b2620cf343df3d1d887ae67b6c5d71a99c8218574165ac400e24d0ce2fac3b5e707da8ebfed23d3211763bc8147f513c6d0a1828143967e4e7efccc621a3788057b637248a06c5a39837698d57472a1052a13ad7517ae5b5429cebb51ec35ee10acc5413041d6d326c4e2883830433c709cdeb1886077d56e219337fa722d345d7b15d9222aad5f2d3f323611c49864f71a43638877a2a7e9e744e0d7fc269bfccd645aedb501e1de033f8e9ed37c5dad50198b40df6fbddada382ab8ecce6f1cf0d7ef647d0645afe025649748346dc8638195668b9e2ee5ea2a437958455b925d88a4539d9a7df46c148a5e28bbf77bf", 2, -31 },
};

test "signatures check out as vanilla's own code makes them" {
    var key: [ChatSession.key_bytes]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, vanilla_key_hex);
    const session = try ChatSession.init(0x112233445566778899aabbccddeeff00, 0, &key, "unchecked");
    const sender: u128 = 0x0f1e2d3c4b5a69788796a5b4c3d2e1f0;
    var kept: [4]PlayerChat.Kept = undefined;
    var free: [4]u32 = undefined;
    var correspondents: [1]PlayerChat.Correspondent = undefined;
    var tracked: [last_seen_max + 4]PlayerChat.Tracked = undefined;
    var chat = bare(&kept, &free, &correspondents, &tracked);
    var first: Signature = undefined;
    var second: Signature = undefined;
    for (&first, &second, 0..) |*a, *b, index| {
        a.* = @intCast(index);
        b.* = @intCast(255 - index);
    }
    const seen = [_]u32{ chat.keep(&first).?, chat.keep(&second).? };
    inline for (vanilla_cases, 0..) |case, number| {
        var signature: Signature = undefined;
        _ = try std.fmt.hexToBytes(&signature, case[0]);
        const text = std.fmt.comptimePrint("héllo ☃ {d}", .{number});
        const acknowledged = seen[0..case[1]];
        try testing.expect(chat.verify(sender, &session, 7 + number, -1234567890123, 1763600000123 + number, text, &signature, acknowledged));
        // The timestamp is signed in seconds, so a millisecond either way within one is the same.
        try testing.expect(chat.verify(sender, &session, 7 + number, -1234567890123, 1763600000000, text, &signature, acknowledged));
        try testing.expect(!chat.verify(sender, &session, 8 + number, -1234567890123, 1763600000123, text, &signature, acknowledged));
        try testing.expect(!chat.verify(sender, &session, 7 + number, -1234567890123, 1763600000123, "hello", &signature, acknowledged));
        try testing.expect(!chat.verify(sender +% 1, &session, 7 + number, -1234567890123, 1763600000123, text, &signature, acknowledged));
        try testing.expectEqual(@as(i8, case[2]), chat.checksumOf(acknowledged));
    }
}

test "acknowledgements follow vanilla's validator" {
    var kept: [8]PlayerChat.Kept = undefined;
    var free: [8]u32 = undefined;
    var correspondents: [1]PlayerChat.Correspondent = undefined;
    var tracked: [last_seen_max + 3]PlayerChat.Tracked = undefined;
    var chat = bare(&kept, &free, &correspondents, &tracked);
    var seen: [last_seen_max]u32 = undefined;
    const nothing: [3]u8 = .{ 0, 0, 0 };
    // A client starts with a window of nothing, and acknowledges nothing.
    try testing.expectEqual(@as(usize, 0), try chat.applyUpdate(0, 0, &nothing, 0, &seen));

    var bytes: Signature = @splat(1);
    const first = chat.keep(&bytes).?;
    bytes = @splat(2);
    const second = chat.keep(&bytes).?;
    try testing.expect(chat.addPending(0, first));
    try testing.expect(chat.addPending(0, second));
    // Sent twice in a row, a signature is tracked once.
    try testing.expect(chat.addPending(0, second));
    try testing.expectEqual(@as(usize, last_seen_max + 2), correspondents[0].tracked_count);

    // Two new messages move the window by two; the last two bits are theirs.
    const both: [3]u8 = .{ 0, 0, 0b1100 };
    try testing.expectError(error.ChatValidation, chat.applyUpdate(0, 3, &both, 0, &seen));
    try testing.expectError(error.ChatValidation, chat.applyUpdate(0, 2, &.{ 0, 0, 0b1_0000 }, 0, &seen));
    correspondents[0].tracked_start = 0;
    correspondents[0].tracked_count = last_seen_max + 2;
    const count = try chat.applyUpdate(0, 2, &both, @bitCast(chat.checksumOf(&.{ first, second })), &seen);
    try testing.expectEqualSlices(u32, &.{ first, second }, seen[0..count]);
    // Once acknowledged, a message stays acknowledged until the window passes it.
    try testing.expectError(error.ChatValidation, chat.applyUpdate(0, 0, &.{ 0, 0, 0b1000 }, 0, &seen));
}

test "a wrong checksum and too many unacknowledged signatures are refused" {
    var kept: [8]PlayerChat.Kept = undefined;
    var free: [8]u32 = undefined;
    var correspondents: [1]PlayerChat.Correspondent = undefined;
    var tracked: [last_seen_max + 2]PlayerChat.Tracked = undefined;
    var chat = bare(&kept, &free, &correspondents, &tracked);
    var seen: [last_seen_max]u32 = undefined;
    var bytes: Signature = @splat(3);
    const only = chat.keep(&bytes).?;
    try testing.expect(chat.addPending(0, only));
    const checksum: u8 = @bitCast(chat.checksumOf(&.{only}));
    try testing.expectError(error.ChatValidation, chat.applyUpdate(0, 1, &.{ 0, 0, 0b1000 }, checksum +% 1, &seen));
    correspondents[0].tracked_start = 0;
    correspondents[0].tracked_count = last_seen_max + 1;
    _ = try chat.applyUpdate(0, 1, &.{ 0, 0, 0b1000 }, checksum, &seen);

    // The window and two more is all this client may have unacknowledged.
    bytes = @splat(4);
    const next = chat.keep(&bytes).?;
    bytes = @splat(5);
    const after = chat.keep(&bytes).?;
    bytes = @splat(6);
    const last = chat.keep(&bytes).?;
    try testing.expect(chat.addPending(0, next));
    try testing.expect(chat.addPending(0, after));
    try testing.expect(!chat.addPending(0, last));
}

const network = @import("networking");

/// A transport the tests only wake; nothing goes out.
const Sink = struct {
    pub fn notify(_: *Sink, _: std.Io) void {}
    pub fn queueReceive(_: *Sink, _: std.Io, _: network.Handle, _: []u8) network.QueueError!void {
        unreachable;
    }
    pub fn queueSend(_: *Sink, _: std.Io, _: network.Handle, _: []const std.posix.iovec_const) network.QueueError!void {
        unreachable;
    }
    pub fn close(_: *Sink, _: std.Io, _: network.Handle, _: network.CloseReason) void {
        unreachable;
    }
    pub fn releaseConnection(_: *Sink, _: std.Io, _: network.Handle) void {
        unreachable;
    }
    pub fn submit(_: *Sink, _: std.Io) !void {
        unreachable;
    }
    pub fn poll(_: *Sink, _: std.Io, _: ?std.Io.Timeout, _: []network.Event) !usize {
        unreachable;
    }
};

/// Each kept signature's references, counted from what holds it: windows, waiting messages and
/// the command running.
fn expectReferences(chat: *PlayerChat) !void {
    for (chat.kept, 0..) |entry, slot| {
        var holders: u32 = 0;
        for (chat.correspondents, 0..) |state, player| {
            if (state.generation == 0) continue;
            for (0..state.tracked_count) |position| {
                if (chat.trackedAt(player, position).kept == slot) holders += 1;
            }
        }
        var waiting = chat.read;
        while (waiting != chat.write) : (waiting += 1) {
            const message = chat.messages[waiting % chat.messages.len];
            if (message.signature == slot) holders += 1;
            for (message.last_seen[0..message.last_seen_count]) |seen| holders += @intFromBool(seen == slot);
        }
        try testing.expectEqual(holders, entry.references);
    }
}

const test_protocols = minecraft_packets.protocols;
const test_chat_types = [_]sessions.Protocol.Registry{.{ .name = "minecraft:chat_type", .entries = &.{"minecraft:chat"} }};
const test_selected = [_]sessions.Protocol{.{ .number = test_protocols.implementations[0].protocol_number, .registries = &test_chat_types }};

/// Three players in play, a relay between them, and the sessions it sends through, all in place.
const Fixture = struct {
    sink: Sink = .{},
    records: [3]Player = undefined,
    players: Players = undefined,
    service: *sessions.Service = undefined,
    chat: *Chat = undefined,
    relay: *PlayerChat = undefined,

    fn create(allocator: std.mem.Allocator, io: std.Io, config: PlayerChat.Configuration) !*Fixture {
        const self = try allocator.create(Fixture);
        self.* = .{};
        const service = try sessions.Service.init(allocator, io, .{ .context = &self.sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = 3, .pages = 64, .page_bytes = 64 * 1024, .credit_bytes = 1024 * 1024, .protocols = &test_selected });
        const encoding = try minecraft_packets.Packets.init(allocator, .{ .sessions = service });
        for (&self.records, 0..) |*player, index| {
            player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .protocol = test_selected[0].number, .stage = .ready, .name_len = 1 };
            player.name[0] = 'a' + @as(u8, @intCast(index));
            service.credit[index].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
        }
        self.players = .{ .deps = undefined, .config = .{ .maximum = 3 }, .spawn_world = 0, .records = &self.records, .dig_handlers = &.{} };
        self.players.deps.sessions = service;
        self.players.deps.packets = encoding;
        try self.players.initIndexes(allocator);
        self.players.rebuildIndexes();
        self.chat = try Chat.init(allocator, .{ .players = &self.players, .sessions = service, .packets = encoding }, .{});
        const input = try Input.init(allocator, .{ .sessions = service });
        self.relay = try PlayerChat.init(allocator, io, config, .{ .players = &self.players, .input = input, .sessions = service, .packets = encoding, .chat = self.chat });
        self.service = service;
        return self;
    }
};

test "messages reach each recipient in order, acknowledging by position what it has" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Client = test_protocols.implementations[0].Protocol.play.toClient;
    const selected = test_selected;
    const fixture = try Fixture.create(arena.allocator(), testing.io, .{ .pending_messages = 8, .pending_signatures = 2, .signatures = 8 * 21 });
    const service = fixture.service;
    const relay = fixture.relay;

    const Received = struct { global_index: i32, len: usize };
    const Drain = struct {
        received: [3][8]Received = undefined,
        counts: [3]usize = @splat(0),

        fn run(self: *@This(), from: *sessions.Service) !void {
            self.counts = @splat(0);
            while (from.output.takeReady()) |packet| {
                const recipient = packet.recipients.first().?.index;
                const header = try Client.readHeader(packet.bytes);
                if (header.id == Client.packetId(.player_chat)) {
                    const reader: wire.play.toClient.packet_player_chat.Reader = .{ ._cursor = .{ .buffer = header.body, .rest = header.body, .protocol_number = selected[0].number } };
                    const global_index, _ = try reader.globalIndex();
                    self.received[recipient][self.counts[recipient]] = .{ .global_index = global_index, .len = packet.bytes.len };
                    self.counts[recipient] += 1;
                }
                _ = from.output.releaseReady(packet.page, packet.generation);
                _ = from.preparing.fetchSub(1, .release);
            }
        }
    };
    var drain: Drain = .{};
    relay.begin(0, 1);
    relay.begin(1, 1);

    // Unsigned chat counts in the index each client checks, and is not tracked.
    var unsigned: PlayerChat.Signed = .{ .sender = 1, .text = "unsigned", .timestamp = 0, .salt = 0 };
    try testing.expect(relay.queue(&unsigned, .chat, null, null));
    try relay.flush();
    try drain.run(service);
    try testing.expectEqualSlices(usize, &.{ 1, 1, 0 }, &drain.counts);
    try testing.expectEqual(@as(i32, 0), drain.received[1][0].global_index);
    try testing.expectEqual(@as(usize, last_seen_max), relay.correspondents[0].tracked_count);

    var bytes: Signature = @splat(1);
    var first: PlayerChat.Signed = .{ .sender = 1, .kept = relay.keep(&bytes).?, .text = "first", .timestamp = 0, .salt = 0 };
    try testing.expect(relay.queue(&first, .chat, null, null));
    const first_message = relay.kept[first.kept].message;
    const first_kept = first.kept;
    relay.forget(&first);
    try expectReferences(relay);
    try relay.flush();
    try drain.run(service);
    try expectReferences(relay);
    for (0..2) |player| {
        try testing.expectEqual(@as(i32, 1), drain.received[player][0].global_index);
        try testing.expectEqual(@as(usize, last_seen_max + 1), relay.correspondents[player].tracked_count);
        try testing.expectEqual(first_message, relay.correspondents[player].cache[0]);
    }

    // A player joining now has not seen the first, so it is sent in full when acknowledged.
    relay.begin(2, 1);
    bytes = @splat(2);
    var second: PlayerChat.Signed = .{ .sender = 2, .kept = relay.keep(&bytes).?, .seen = undefined, .seen_count = 1, .text = "second", .timestamp = 0, .salt = 0 };
    relay.retain(first_kept);
    second.seen[0] = first_kept;
    try testing.expect(relay.queue(&second, .chat, null, null));
    relay.forget(&second);
    try relay.flush();
    try drain.run(service);
    try expectReferences(relay);
    try testing.expectEqualSlices(usize, &.{ 1, 1, 1 }, &drain.counts);
    try testing.expectEqual(@as(i32, 2), drain.received[0][0].global_index);
    try testing.expectEqual(@as(i32, 0), drain.received[2][0].global_index);
    try testing.expectEqual(drain.received[0][0].len + signature_bytes, drain.received[2][0].len);

    // Two acknowledge what they were sent; the third does not, and passes its limit.
    try relay.applyOffset(0, 2);
    try relay.applyOffset(1, 2);
    for (3..5) |number| {
        bytes = @splat(@intCast(number));
        var next: PlayerChat.Signed = .{ .sender = 1, .kept = relay.keep(&bytes).?, .text = "more", .timestamp = 0, .salt = 0 };
        try testing.expect(relay.queue(&next, .chat, null, null));
        relay.forget(&next);
        try relay.flush();
        try drain.run(service);
        try expectReferences(relay);
    }
    try testing.expectEqual(@as(u32, 0), service.disconnects[0].load(.acquire));
    try testing.expectEqual(@as(u32, 0), service.disconnects[1].load(.acquire));
    try testing.expectEqual(@as(u32, 1), service.disconnects[2].load(.acquire));
    try testing.expectEqual(relay.tracked_capacity, relay.correspondents[2].tracked_count);

    // Leaving lets go of everything the player's window held.
    relay.end(2);
    relay.end(1);
    relay.end(0);
    try expectReferences(relay);
    try testing.expectEqual(relay.kept.len, relay.free_count);
}

test "a key past its expiry signs nothing more, by the clock the plugin is given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The first vanilla message, sent a minute before its key lapses; the clock starts a second
    // before it does.
    const timestamp: i64 = 1763600000123;
    const expires_at = timestamp + std.time.ms_per_min;
    var deterministic: lightning_rod.system.DeterministicIo = .init(testing.allocator, .{ .start = .{ .nanoseconds = @as(i96, expires_at - std.time.ms_per_s) * std.time.ns_per_ms } });
    defer deterministic.deinit();
    const fixture = try Fixture.create(arena.allocator(), deterministic.io(), .{});
    const relay = fixture.relay;
    var key: [ChatSession.key_bytes]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, vanilla_key_hex);
    var keys: [3]?ChatSession = .{ try ChatSession.init(0x112233445566778899aabbccddeeff00, expires_at, &key, "unchecked"), null, null };
    fixture.players.chat_sessions = &keys;
    fixture.records[0].uuid = 0x0f1e2d3c4b5a69788796a5b4c3d2e1f0;
    fixture.records[0].chat_revision = 1;
    relay.begin(0, 1);
    relay.correspondents[0].next_index = 7;
    var signature: Signature = undefined;
    _ = try std.fmt.hexToBytes(&signature, vanilla_cases[0][0]);
    const handle = fixture.records[0].handle.?;

    var signed = relay.unpack(handle, "héllo ☃ 0", timestamp, -1234567890123, &signature, &.{}) orelse return error.TestUnexpectedResult;
    relay.forget(&signed);
    try testing.expectEqual(@as(?i32, 8), relay.correspondents[0].next_index);

    // Two seconds on, the key has lapsed: the sender is told, and the chain stays where it was.
    deterministic.advance(.fromSeconds(2));
    const notices = fixture.chat.write;
    try testing.expect(relay.unpack(handle, "héllo ☃ 0", timestamp, -1234567890123, &signature, &.{}) == null);
    try testing.expectEqual(notices + 1, fixture.chat.write);
    const notice = fixture.chat.messages[notices % fixture.chat.messages.len];
    try testing.expect(std.mem.indexOf(u8, notice.bytes[0..notice.length], "chat.disabled.expiredProfileKey") != null);
    try testing.expectEqual(@as(?i32, 8), relay.correspondents[0].next_index);
    try expectReferences(relay);
}
