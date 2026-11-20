const BatchIndex = @import("lightning_rod").system.BatchIndex;
const std = @import("std");
const wire_1_21_6 = @import("wire_1_21_6");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_11 = @import("wire_1_21_11");
const wire_26_1 = @import("wire_26_1");
const commands = @import("commands.zig");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const Players = @import("players").players.Players;
const Chat = @import("chat").chat.Chat;
const player_chat = @import("chat").player_chat;
const PlayerChat = player_chat.PlayerChat;
const Input = @import("players").input.Input;

pub const CommandDispatch = struct {
    pub const id = "minecraft:command_dispatch";

    pub const Configuration = struct { command_observers: usize = 16 };

    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *Players,
        chat: *Chat,
        player_chat: *PlayerChat,
        input: *Input,
        sessions: *sessions.Service,
        packets: *packets.Packets,
    };

    const State = struct {
        generation: u32 = 0,
        life: u32 = 0,
        sent: bool = false,
        visibility_valid: bool = false,
        permissions_revision: u64 = 0,
        completion: ?i32 = null,
        text: [commands.max_input]u8 = undefined,
        length: usize = 0,
    };

    const Reply = struct {
        chat: *Chat,
        handle: sessions.Handle,
    };

    const Listener = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct { call: *const fn (*anyopaque, sessions.Handle, []const u8) anyerror!void };
    };

    deps: Dependencies,
    states: []State,
    visible: []bool,
    listeners: []Listener,
    listener_count: usize = 0,
    groups: BatchIndex([]const u8, usize, std.hash_map.StringContext),
    heads: []usize,
    tails: []usize,
    next: []?usize,
    targets: []sessions.Service.Target,
    delivered: []sessions.Service.Delivery,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*CommandDispatch {
        if (config.command_observers == 0 or config.command_observers > 256) return error.InvalidConfiguration;
        if (deps.sessions.config.page_bytes < @max(10 * 1024, 16 + deps.commands.nodes.len * 128)) return error.CommandPacketCapacity;

        const self = try allocator.create(CommandDispatch);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        const visible = try allocator.alloc(bool, try std.math.mul(usize, states.len, deps.commands.nodes.len));
        @memset(visible, false);
        self.* = .{ .groups = try .init(allocator, states.len), .heads = try allocator.alloc(usize, states.len), .tails = try allocator.alloc(usize, states.len), .next = try allocator.alloc(?usize, states.len), .targets = try allocator.alloc(sessions.Service.Target, states.len), .delivered = try allocator.alloc(sessions.Service.Delivery, states.len), .deps = deps, .states = states, .visible = visible, .listeners = try allocator.alloc(Listener, config.command_observers) };
        try deps.input.on(.chat_command, self, onCommand);
        try deps.input.on(.chat_command_signed, self, .{ onSignedCommand_1_21_5, onSignedCommand_1_21_11, onSignedCommand_26_1 });
        try deps.input.on(.tab_complete, self, onCompletion);
        return self;
    }

    pub fn tick(self: *CommandDispatch) !void {
        const service = self.deps.sessions;
        const tree = self.deps.commands;
        tree.sealed = true;

        self.groups.clear();
        const heads = self.heads;
        const tails = self.tails;
        const next = self.next;
        var group_count: usize = 0;
        std.debug.assert(self.states.len <= heads.len);
        for (self.deps.players.activeSlots()) |player_index| {
            const player = self.deps.players.records[player_index];
            const state = &self.states[player_index];
            const handle = player.handle orelse continue;
            if (!player.inPlay()) continue;

            if (state.generation != handle.generation or state.life != player.life) state.* = .{ .generation = handle.generation, .life = player.life };

            const previous = self.visible[player_index * tree.nodes.len ..][0..tree.count];
            if (!state.visibility_valid or state.permissions_revision != tree.permissions_revision) {
                var visible: [1024]bool = undefined;
                tree.visibility(player.uuid, visible[0..tree.count]);
                if (!state.visibility_valid or !std.mem.eql(bool, previous, visible[0..tree.count])) {
                    @memcpy(previous, visible[0..tree.count]);
                    state.sent = false;
                }
                state.visibility_valid = true;
                state.permissions_revision = tree.permissions_revision;
            }
            if (!state.sent) {
                const index = player_index;
                const group = self.groups.getOrPut(std.mem.sliceAsBytes(previous));
                next[index] = null;
                if (group.found_existing) {
                    const head = group.value_ptr.*;
                    next[tails[head]] = index;
                    tails[head] = index;
                } else {
                    group.value_ptr.* = index;
                    heads[group_count] = index;
                    tails[index] = index;
                    group_count += 1;
                }
            }
        }
        const targets = self.targets;
        const delivered = self.delivered;
        for (heads[0..group_count]) |head| {
            var count: usize = 0;
            var member: ?usize = head;
            while (member) |index| {
                const player = self.deps.players.records[index];
                std.debug.assert(!self.states[index].sent and self.states[index].visibility_valid);
                targets[count] = .{ .handle = player.handle.?, .protocol = player.protocol };
                count += 1;
                member = next[index];
            }
            const visible = self.visible[head * tree.nodes.len ..][0..tree.count];
            std.debug.assert(tree.packet_capacity <= service.config.page_bytes);
            try self.deps.packets.fanout(writeTree, targets[0..count], .{ tree, visible }, tree.packet_capacity, delivered[0..count]);
            for (targets[0..count], delivered[0..count]) |target, delivery| {
                if (delivery == .queued) self.states[target.handle.index].sent = true;
            }
        }
        connections: for (self.deps.players.activeSlots()) |player_index| {
            const player = self.deps.players.records[player_index];
            const state = &self.states[player_index];
            const handle = player.handle orelse continue;
            if (!player.inPlay()) continue;
            if (state.completion) |request_id| {
                const text = state.text[0..state.length];
                var suggestions: commands.Suggestions = .{};
                tree.complete(player.uuid, text, &suggestions);
                std.debug.assert(suggestions.start <= text.len);
                std.debug.assert(suggestions.length <= text.len - suggestions.start);
                self.deps.packets.sendPacketRetrying(writeCompletions, player.protocol, handle, .{ request_id, text, &suggestions }, service.config.page_bytes) catch continue :connections;
                state.completion = null;
            }
        }

        try self.deps.chat.flush();
    }

    fn onCommand(self: *CommandDispatch, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_chat_command.Reader) !void {
        const value, const done = body.command() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const player = self.deps.players.records[handle.index];
        if (!player.inPlay()) return;
        // A client with a key signs every command with message arguments; one sent unsigned
        // carries messages no one can check, which vanilla refuses to run when chat is signed.
        var arguments: [commands.max_arguments]commands.Commands.Signable = undefined;
        const signable = self.deps.commands.signable(player.uuid, value, &arguments);
        if (signable.len != 0 and self.deps.players.securesChat(handle))
            return self.deps.player_chat.notify(handle, "chat.disabled.invalid_command_signature");
        try self.run(handle, value, signable, &.{}, 0, 0, &.{});
    }

    fn onSignedCommand_1_21_5(self: *CommandDispatch, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_chat_command_signed.Reader) !void {
        return self.onSignedCommand(handle, body);
    }

    // 1.21.11 reads the checksum as a signed byte, and 26.1 as unsigned again.
    fn onSignedCommand_1_21_11(self: *CommandDispatch, handle: sessions.Handle, body: wire_1_21_11.play.toServer.packet_chat_command_signed.Reader) !void {
        return self.onSignedCommand(handle, body);
    }

    fn onSignedCommand_26_1(self: *CommandDispatch, handle: sessions.Handle, body: wire_26_1.play.toServer.packet_chat_command_signed.Reader) !void {
        return self.onSignedCommand(handle, body);
    }

    /// A command whose message arguments the client signed, as vanilla's
    /// handleSignedChatCommand takes it.
    fn onSignedCommand(self: *CommandDispatch, handle: sessions.Handle, body: anytype) !void {
        const value, const a = body.command() catch return error.InvalidPacket;
        const timestamp, const b = a.timestamp() catch return error.InvalidPacket;
        const salt, const c = b.salt() catch return error.InvalidPacket;
        var list = c.argumentSignatures() catch return error.InvalidPacket;
        var names: [PlayerChat.command_arguments_max][]const u8 = undefined;
        var signatures: [PlayerChat.command_arguments_max]player_chat.Signature = undefined;
        var count: usize = 0;
        while (list.next() catch return error.InvalidPacket) |entry| {
            if (count == names.len) return error.InvalidPacket;
            const name, const named = entry.argumentName() catch return error.InvalidPacket;
            const signature, const signed = named.signature() catch return error.InvalidPacket;
            if (name.len > 16 or signature.len != player_chat.signature_bytes) return error.InvalidPacket;
            names[count] = name;
            signatures[count] = signature[0..player_chat.signature_bytes].*;
            count += 1;
            list.advance(signed) catch return error.InvalidPacket;
        }
        const d = list.finish() catch return error.InvalidPacket;
        const offset, const e = d.messageCount() catch return error.InvalidPacket;
        const acknowledged, const f = e.acknowledged() catch return error.InvalidPacket;
        const checksum, _ = f.checksum() catch return error.InvalidPacket;
        if (acknowledged.len != 3) return error.InvalidPacket;

        var seen: [player_chat.last_seen_max]u32 = undefined;
        const seen_count = try self.deps.player_chat.acknowledge(handle, offset, acknowledged[0..3], @bitCast(checksum), &seen) orelse return;
        if (!validCommand(value))
            return self.deps.players.refuse(&self.deps.players.records[handle.index], "multiplayer.disconnect.illegal_characters");
        const player = self.deps.players.records[handle.index];
        var arguments: [commands.max_arguments]commands.Commands.Signable = undefined;
        const signable = self.deps.commands.signable(player.uuid, value, &arguments);
        var given: [PlayerChat.command_arguments_max]PlayerChat.ArgumentSignature = undefined;
        for (names[0..count], signatures[0..count], given[0..count]) |name, *signature, *entry| entry.* = .{ .name = name, .signature = signature };
        try self.run(handle, value, signable, given[0..count], timestamp, salt, seen[0..seen_count]);
    }

    /// Vanilla's illegal characters in a command: the section sign, control characters and delete.
    fn validCommand(value: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(value)) return false;
        var view = std.unicode.Utf8View.initUnchecked(value).iterator();
        while (view.nextCodepoint()) |codepoint| {
            if (codepoint == 0xa7 or codepoint < 32 or codepoint == 127) return false;
        }
        return true;
    }

    /// Checks a command's messages, then runs it, as vanilla does: a message failing its checks
    /// keeps the command from running.
    fn run(self: *CommandDispatch, handle: sessions.Handle, value: []const u8, signable: []const commands.Commands.Signable, signatures: []const PlayerChat.ArgumentSignature, timestamp: i64, salt: i64, seen: []const u32) !void {
        const player = self.deps.players.records[handle.index];
        if (!player.inPlay()) return;
        if (signable.len > PlayerChat.command_arguments_max) return error.InvalidPacket;
        var arguments: [PlayerChat.command_arguments_max]PlayerChat.CommandArgument = undefined;
        for (signable, arguments[0..signable.len]) |argument, *entry| entry.* = .{ .name = argument.name, .value = argument.value };
        if (!self.deps.player_chat.beginCommand(handle, arguments[0..signable.len], signatures, timestamp, salt, seen)) return;
        defer self.deps.player_chat.endCommand();
        var reply: Reply = .{ .chat = self.deps.chat, .handle = handle };
        try self.deps.commands.execute(.{ .sender = player.uuid, .output = commands.Reply.init(&reply, writeReply) }, value);
        for (self.listeners[0..self.listener_count]) |listener|
            try listener.vtable.call(listener.context, handle, value);
    }

    pub fn observeCommand(self: *CommandDispatch, context: anytype, comptime handler: anytype) !void {
        if (self.listener_count == self.listeners.len) return error.CommandObserverCapacity;
        const Adapter = struct {
            const vtable: Listener.VTable = .{ .call = @This().invoke };
            fn invoke(raw: *anyopaque, handle: sessions.Handle, value: []const u8) anyerror!void {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                try @call(.auto, handler, .{ typed, handle, value });
            }
        };
        self.listeners[self.listener_count] = .{
            .context = context,
            .vtable = &Adapter.vtable,
        };
        self.listener_count += 1;
    }

    fn onCompletion(self: *CommandDispatch, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_tab_complete.Reader) !void {
        const request_id, const next = body.transactionId() catch return error.InvalidPacket;
        const value, const done = next.text() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidPacket;

        const player = self.deps.players.records[handle.index];
        if (!player.inPlay()) return;
        const state = &self.states[handle.index];
        if (state.generation != handle.generation or state.life != player.life)
            state.* = .{ .generation = handle.generation, .life = player.life };
        if (value.len > state.text.len) {
            self.deps.sessions.disconnect(handle);
            return;
        }
        @memcpy(state.text[0..value.len], value);
        state.length = value.len;
        state.completion = request_id;
    }

    fn writeReply(reply: *Reply, text: []const u8) void {
        reply.chat.system(reply.handle, text);
    }

    const writeTree = .{ writeTree_1_21_5, writeTree_1_21_6 };

    // 1.21.6 added minecraft:hex_color ahead of minecraft:message, which moved it from 19 to 20.
    fn writeTree_1_21_5(packet: wire_1_21_5.play.toClient.packet_declare_commands.Writer, tree: *const commands.Commands, visible: []const bool) ![]u8 {
        return commands.wire.treePacket(packet, tree, visible, 19);
    }

    fn writeTree_1_21_6(packet: wire_1_21_6.play.toClient.packet_declare_commands.Writer, tree: *const commands.Commands, visible: []const bool) ![]u8 {
        return commands.wire.treePacket(packet, tree, visible, 20);
    }

    fn writeCompletions(packet: wire_1_21_5.play.toClient.packet_tab_complete.Writer, request_id: i32, input: []const u8, suggestions: *const commands.Suggestions) ![]u8 {
        return commands.wire.completions(packet, request_id, input, suggestions);
    }
};
