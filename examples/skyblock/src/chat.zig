const std = @import("std");
const lightning_rod = @import("lightning_rod");
pub const shared = @import("shared_chat.zig");

pub const Output = struct {
    pub const id = "minecraft:chat_output";
    pub const Configuration = struct { endpoint: *shared.Endpoint };
    pub const Dependencies = struct {
        players: *lightning_rod.players.Players,
        packets: *lightning_rod.Packets,
    };

    deps: Dependencies,
    config: Configuration,
    recipients: []?lightning_rod.players.Session,
    pending: bool = false,
    closing: ?lightning_rod.plugin_lifecycle.Closing.Token = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Output {
        const self = try allocator.create(Output);
        self.* = .{ .deps = deps, .config = config, .recipients = try allocator.alloc(?lightning_rod.players.Session, deps.players.records.len) };
        return self;
    }

    pub fn tick(self: *Output) void {
        const endpoint = self.config.endpoint;
        const missed = endpoint.takeMissed();
        if (missed != 0) {
            std.log.warn("event=shared_chat_overflow missed={d}", .{missed});
            for (self.deps.players.activeSlots()) |slot|
                self.deps.packets.system(slot, "Missed {d} chat messages while this island was busy", .{missed});
        }
        for (0..endpoint.incoming.capacity()) |_| {
            const message = endpoint.incoming.receive() orelse break;
            if (!self.pending) {
                @memset(self.recipients, null);
                for (self.deps.players.activeSlots()) |slot| {
                    if (self.deps.players.records[slot].state == .play and self.deps.players.records[slot].presentation_ready)
                        self.recipients[slot] = self.deps.players.session(slot);
                }
                self.pending = true;
            }
            var waiting = false;
            for (self.recipients) |*recipient| {
                const session = recipient.* orelse continue;
                if (!self.deps.players.validSession(session) or self.deps.players.records[session.slot].state != .play) {
                    recipient.* = null;
                    continue;
                }
                if (self.deps.packets.sendSystemText(session.slot, message.text())) {
                    recipient.* = null;
                } else waiting = true;
            }
            if (waiting) break;
            self.pending = false;
            endpoint.incoming.release();
        }
        for (self.deps.packets.chats.items()) |*draft| {
            if (draft.cancelled) continue;
            var bytes: [shared.maximum_message_bytes]u8 = undefined;
            const text = std.fmt.bufPrint(&bytes, "{f}", .{lightning_rod.chat.Line{ .draft = draft }}) catch {
                self.deps.packets.system(draft.sender, "Chat message is too long", .{});
                continue;
            };
            switch (draft.audience) {
                .player => |slot| {
                    if (slot < self.deps.players.records.len and self.deps.players.records[slot].state == .play)
                        _ = self.deps.packets.sendSystemText(slot, text);
                },
                .broadcast => {
                    endpoint.outgoing.send(0, text) catch {
                        self.deps.packets.system(draft.sender, "Chat is busy; please try again", .{});
                    };
                },
            }
        }
    }

    pub fn close(self: *Output, closing: *lightning_rod.plugin_lifecycle.Closing) void {
        self.closing = closing.begin();
        self.config.endpoint.retire(.{ .context = self, .finish = finishClose });
    }

    fn finishClose(raw: *anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(raw));
        const token = self.closing.?;
        token.finish();
    }
};

pub const Owner = struct {
    pub const id = "skyblock:chat_service";
    pub const Dependencies = struct { output: *Output };
    pub const Configuration = struct { service: *shared.Service, maximum_source_checks_per_tick: usize = 64 };
    deps: Dependencies,
    config: Configuration,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Owner {
        if (config.maximum_source_checks_per_tick == 0) return error.InvalidChatCapacity;
        if (config.service.endpoints.len != 1 or deps.output.config.endpoint != &config.service.endpoints[0])
            return error.InvalidChatOwner;
        const self = try allocator.create(Owner);
        self.* = .{ .deps = deps, .config = config };
        std.log.info("event=shared_chat_memory bytes={d} cores={d}", .{ config.service.memoryBytes(), config.service.endpoints.len });
        return self;
    }

    pub fn tick(self: *Owner) void {
        _ = self.config.service.process(self.config.maximum_source_checks_per_tick);
    }

    pub fn close(self: *Owner, _: *lightning_rod.plugin_lifecycle.Closing) void {
        const service = self.config.service;
        for (0..service.endpoints[0].outgoing.capacity() + 1) |_|
            _ = service.process(service.endpoints.len);
    }
};

test "chat plugin closing token completes only after the owner drains its endpoint" {
    var service = try shared.Service.init(std.testing.allocator, 1, 2);
    defer service.deinit();
    var output = Output{
        .deps = undefined,
        .config = .{ .endpoint = &service.endpoints[0] },
        .recipients = &.{},
    };
    const owner = try Owner.init(std.testing.allocator, .{ .output = &output }, .{ .service = &service });
    defer std.testing.allocator.destroy(owner);
    try service.endpoints[0].outgoing.send(0, "unconsumed incoming");
    _ = service.process(1);
    try service.endpoints[0].outgoing.send(0, "accepted final message");
    var completed: [1]std.atomic.Value(u8) = undefined;
    var closing = lightning_rod.plugin_lifecycle.Closing.init(1, &completed);
    output.close(&closing);
    try std.testing.expect(!closing.complete());
    try std.testing.expectError(error.Busy, service.reactivate(0));
    owner.close(&closing);
    try std.testing.expect(closing.complete());
    try std.testing.expect(service.endpoints[0].retired());
    try std.testing.expectEqual(@as(u64, 2), service.sequence);
    try service.reactivate(0);
    try std.testing.expect(service.endpoints[0].incoming.receive() == null);
}
