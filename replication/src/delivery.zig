//! Sending one entity's packets to the players of a set, the same way for every kind: whom it
//! reached, whom it missed because their output was full, and a client that cannot take it
//! disconnected. Kinds say what to send; this is how it goes out.

const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const minecraft_packets = @import("minecraft_packets");
const Players = @import("players").players.Players;

const bit_sets = lightning_rod.system.bit_sets;
const assert = std.debug.assert;

pub const Delivery = struct {
    players: *const Players,
    packets: *minecraft_packets.Packets,
    sessions: *sessions.Service,
    /// Room for every player at once.
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,
    /// The players the last send was queued for or whose session closed, and those whose output
    /// was full: as many as `reachedPlayers` and `missedPlayers` give.
    reached: []usize,
    reached_count: usize = 0,
    missed: []usize,
    missed_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, players: *const Players, packets: *minecraft_packets.Packets, service: *sessions.Service) !Delivery {
        const count = players.records.len;
        return .{
            .players = players,
            .packets = packets,
            .sessions = service,
            .targets = try allocator.alloc(sessions.Service.Target, count),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, count),
            .reached = try allocator.alloc(usize, count),
            .missed = try allocator.alloc(usize, count),
        };
    }

    /// The players in a session of a set, as targets: one without a session is neither reached
    /// nor missed, as what tracks it forgets it when it goes.
    fn gather(self: *Delivery, recipients: bit_sets.Set) []const sessions.Service.Target {
        var count: usize = 0;
        var each = recipients.iterator();
        while (each.next()) |player| {
            const record = self.players.records[player];
            const handle = record.handle orelse continue;
            self.targets[count] = .{ .handle = handle, .protocol = record.protocol };
            count += 1;
        }
        self.reached_count = 0;
        self.missed_count = 0;
        return self.targets[0..count];
    }

    /// What each target made of it.
    fn settle(self: *Delivery, targets: []const sessions.Service.Target) void {
        for (targets, self.deliveries[0..targets.len]) |target, delivery| switch (delivery) {
            .queued, .closed => {
                self.reached[self.reached_count] = target.handle.index;
                self.reached_count += 1;
            },
            .backpressured => {
                self.missed[self.missed_count] = target.handle.index;
                self.missed_count += 1;
            },
            .unsupported => self.sessions.disconnect(target.handle),
        };
    }

    /// One packet, as `Packets.fanout` writes it, to the players of a set.
    pub fn send(self: *Delivery, recipients: bit_sets.Set, comptime writer: anytype, arguments: anytype, maximum_bytes: usize) !void {
        const targets = self.gather(recipients);
        if (targets.len == 0) return;
        try self.packets.fanout(writer, targets, arguments, maximum_bytes, self.deliveries[0..targets.len]);
        self.settle(targets);
    }

    /// Packets that go together, as `Packets.fanoutGroup` writes them: each player has all of
    /// them or none.
    pub fn sendGroup(self: *Delivery, recipients: bit_sets.Set, comptime writers: anytype, arguments: anytype, maximum_bytes: []const usize) !void {
        const targets = self.gather(recipients);
        if (targets.len == 0) return;
        try self.packets.fanoutGroup(writers, targets, arguments, maximum_bytes, self.deliveries[0..targets.len]);
        self.settle(targets);
    }

    /// Whom the last send reached.
    pub fn reachedPlayers(self: *const Delivery) []const usize {
        return self.reached[0..self.reached_count];
    }

    /// Whom the last send missed, their output full: they are owed the state whole.
    pub fn missedPlayers(self: *const Delivery) []const usize {
        return self.missed[0..self.missed_count];
    }

    /// The last send's reached players set in a row of words, one bit a player.
    pub fn markReached(self: *const Delivery, row: []usize) void {
        for (self.reachedPlayers()) |player| row[player / 64] |= @as(usize, 1) << @intCast(player % 64);
    }

    pub fn markMissed(self: *const Delivery, row: []usize) void {
        for (self.missedPlayers()) |player| row[player / 64] |= @as(usize, 1) << @intCast(player % 64);
    }
};

/// Packets of many entities for one audience, admitted for all of it at once: the way to send
/// what goes to the same players, as items and projectiles do. Each packet keeps what its kind
/// needs back when the batch goes, which `flush` hands back with whom it reached.
pub fn Batch(comptime Payload: type) type {
    return struct {
        const Self = @This();
        const Receipt = sessions.Service.Broadcast.Receipt;
        const Entry = struct { payload: Payload, receipt: Receipt };

        broadcast: sessions.Service.Broadcast,
        players: *const Players,
        packets: *minecraft_packets.Packets,
        sessions: *sessions.Service,
        recipients: []sessions.Service.Target,
        /// The audience of the batch under way, as words.
        audience: []usize,
        /// Room for whom a packet of the batch missed.
        missed: []usize,
        /// How many of `recipients` the batch under way goes to, and room for them as a set.
        recipient_count: usize = 0,
        reached: []usize,
        entries: [sessions.Service.batch_max]Entry = undefined,
        count: usize = 0,

        pub fn init(allocator: std.mem.Allocator, players: *const Players, packets: *minecraft_packets.Packets, service: *sessions.Service, words: usize) !Self {
            return .{
                .broadcast = try .init(allocator, service, sessions.Service.batch_max * service.config.protocols.len),
                .players = players,
                .packets = packets,
                .sessions = service,
                .recipients = try allocator.alloc(sessions.Service.Target, players.records.len),
                .audience = try allocator.alloc(usize, words),
                .missed = try allocator.alloc(usize, words),
                .reached = try allocator.alloc(usize, words),
            };
        }

        pub const Ready = enum {
            /// Packets for the audience go in this batch.
            ready,
            /// Nobody of it is in a session and playing: nothing to send.
            nobody,
            /// Its players have no room now: nothing went.
            backpressured,
        };

        /// Readies the batch for an audience and `packets` packets more: one for another audience,
        /// or without room, goes first, its packets settled as `flush` settles them.
        pub fn prepare(self: *Self, audience: bit_sets.Set, packets: usize, context: anytype, comptime settle: anytype) !Ready {
            assert(self.count <= self.entries.len);
            const broadcast = &self.broadcast;
            const needed = packets * self.sessions.config.protocols.len;
            if (broadcast.active and (!self.same(audience) or self.count == self.entries.len or broadcast.count + needed > broadcast.entries.len)) try self.flush(context, settle);
            if (broadcast.active) return .ready;
            var count: usize = 0;
            var each = audience.iterator();
            while (each.next()) |index| {
                const player = &self.players.records[index];
                const handle = player.handle orelse continue;
                if (player.stage != .ready) continue;
                self.recipients[count] = .{ .handle = handle, .protocol = player.protocol };
                count += 1;
            }
            if (count == 0) return .nobody;
            self.recipient_count = count;
            broadcast.begin(self.recipients[0..count]) catch |err| switch (err) {
                error.Backpressured => return .backpressured,
                else => return err,
            };
            for (self.audience, 0..) |*word, at| word.* = audience.wordAt(at);
            return .ready;
        }

        /// Whether an audience is the batch's under way, dense or sparse.
        fn same(self: *const Self, audience: bit_sets.Set) bool {
            for (self.audience, 0..) |word, at| if (audience.wordAt(at) != word) return false;
            return true;
        }

        /// One packet of the batch, which `prepare` readied: false when its players have no room.
        pub fn send(self: *Self, payload: Payload, comptime writer: anytype, arguments: anytype, maximum_bytes: usize) !bool {
            const receipt = self.packets.broadcast(&self.broadcast, writer, null, null, arguments, maximum_bytes) catch |err| switch (err) {
                error.Backpressured => return false,
                else => return err,
            };
            self.record(payload, receipt);
            return true;
        }

        /// Packets each player takes whole or not at all.
        pub fn sendGroup(self: *Self, payload: Payload, comptime writers: anytype, arguments: anytype, maximum_bytes: []const usize) !bool {
            const receipt = self.packets.broadcastGroup(&self.broadcast, writers, null, null, arguments, maximum_bytes) catch |err| switch (err) {
                error.Backpressured => return false,
                else => return err,
            };
            self.record(payload, receipt);
            return true;
        }

        fn record(self: *Self, payload: Payload, receipt: Receipt) void {
            assert(self.count < self.entries.len);
            self.entries[self.count] = .{ .payload = payload, .receipt = receipt };
            self.count += 1;
        }

        /// Sends the batch, and hands each packet's payload to `settle` with whom it reached and
        /// how many it was for; a client that cannot take it is disconnected.
        pub fn flush(self: *Self, context: anytype, comptime settle: anytype) !void {
            const broadcast = &self.broadcast;
            if (!broadcast.active) {
                assert(self.count == 0);
                return;
            }
            broadcast.commit();
            defer {
                broadcast.cancel();
                self.count = 0;
            }
            // Every packet went to every recipient: what each reached needs no working out.
            if (broadcast.wentWhole()) {
                @memset(self.reached, 0);
                for (self.recipients[0..self.recipient_count]) |target| self.reached[target.handle.index / 64] |= @as(usize, 1) << @intCast(target.handle.index % 64);
                const everyone: bit_sets.Set = .{ .words = self.reached, .capacity = self.players.records.len };
                for (self.entries[0..self.count]) |entry| try settle(context, entry.payload, everyone, broadcast.recipients);
                return;
            }
            for (self.entries[0..self.count]) |entry| {
                var unsupported = broadcast.unsupported(entry.receipt).iterator();
                while (unsupported.next()) |index| self.sessions.disconnect(broadcast.handleAt(index));
                try settle(context, entry.payload, broadcast.accepted(entry.receipt), broadcast.recipients);
            }
        }

        /// Of the batch's audience in a session, those a packet that reached `accepted` missed:
        /// their output was full, or they were not yet playing. What `settle` is handed lets a kind
        /// owe them the state whole. Good until the next call.
        pub fn missedOf(self: *const Self, accepted: bit_sets.Set) bit_sets.Set {
            const audience: bit_sets.Set = .{ .words = self.audience, .capacity = self.players.records.len };
            var each = audience.iterator();
            @memset(self.missed, 0);
            while (each.next()) |player| {
                if (self.players.records[player].handle == null or accepted.contains(player)) continue;
                self.missed[player / 64] |= @as(usize, 1) << @intCast(player % 64);
            }
            return .{ .words = self.missed, .capacity = self.players.records.len };
        }

        /// Gives up the batch under way, nothing of it sent.
        pub fn abandon(self: *Self) void {
            if (self.broadcast.active) self.broadcast.cancel();
            self.count = 0;
        }
    };
}
