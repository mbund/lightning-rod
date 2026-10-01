const std = @import("std");
const wire_1_21_6 = @import("wire_1_21_6");
const wire_1_21_5 = @import("wire_1_21_5");
const commands = @import("commands");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const Players = @import("players.zig").Players;
const Chat = @import("chat.zig").Chat;
const Input = @import("input.zig").Input;

pub const CommandDispatch = struct {
    pub const id = "minecraft:command_dispatch";

    pub const Configuration = struct { command_observers: usize = 16 };

    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *Players,
        chat: *Chat,
        input: *Input,
        sessions: *sessions.Service,
        packets: *packets.Packets,
    };

    const State = struct {
        generation: u32 = 0,
        life: u32 = 0,
        sent: bool = false,
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
        call: *const fn (*anyopaque, sessions.Handle, []const u8) anyerror!void,
    };

    deps: Dependencies,
    states: []State,
    visible: []bool,
    listeners: []Listener,
    listener_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*CommandDispatch {
        if (config.command_observers == 0 or config.command_observers > 256) return error.InvalidConfiguration;
        if (deps.sessions.config.page_bytes < @max(10 * 1024, 16 + deps.commands.nodes.len * 128)) return error.CommandPacketCapacity;

        const self = try allocator.create(CommandDispatch);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        const visible = try allocator.alloc(bool, states.len * deps.commands.nodes.len);
        @memset(visible, false);
        self.* = .{ .deps = deps, .states = states, .visible = visible, .listeners = try allocator.alloc(Listener, config.command_observers) };
        try deps.input.on(.chat_command, self, onCommand);
        try deps.input.on(.tab_complete, self, onCompletion);
        return self;
    }

    pub fn tick(self: *CommandDispatch) !void {
        const service = self.deps.sessions;
        const tree = self.deps.commands;
        tree.sealed = true;

        connections: for (self.deps.players.records, self.states, 0..) |player, *state, player_index| {
            const handle = player.handle orelse continue;
            if (!player.inPlay()) continue;

            if (state.generation != handle.generation or state.life != player.life) state.* = .{ .generation = handle.generation, .life = player.life };

            const previous = self.visible[player_index * tree.nodes.len ..][0..tree.count];
            var visible: [1024]bool = undefined;
            tree.visibility(player.uuid, visible[0..tree.count]);
            if (!state.sent or !std.mem.eql(bool, previous, visible[0..tree.count])) publish_tree: {
                self.deps.packets.sendPacketRetrying(writeTree, player.protocol, &.{handle}, .{ tree, visible[0..tree.count] }, service.config.page_bytes) catch break :publish_tree;
                @memcpy(previous, visible[0..tree.count]);
                state.sent = true;
            }

            if (state.completion) |request_id| {
                const text = state.text[0..state.length];
                var suggestions: commands.Suggestions = .{};
                tree.complete(player.uuid, text, &suggestions);
                std.debug.assert(suggestions.start <= text.len);
                std.debug.assert(suggestions.length <= text.len - suggestions.start);
                self.deps.packets.sendPacketRetrying(writeCompletions, player.protocol, &.{handle}, .{ request_id, text, &suggestions }, service.config.page_bytes) catch continue :connections;
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
        var reply: Reply = .{ .chat = self.deps.chat, .handle = handle };
        try self.deps.commands.execute(.{ .sender = player.uuid, .output = &reply, .write = writeReply }, value);
        for (self.listeners[0..self.listener_count]) |listener|
            try listener.call(listener.context, handle, value);
    }

    pub fn observeCommand(self: *CommandDispatch, context: anytype, comptime handler: anytype) !void {
        if (self.listener_count == self.listeners.len) return error.CommandObserverCapacity;
        self.listeners[self.listener_count] = .{
            .context = context,
            .call = struct {
                fn call(raw: *anyopaque, handle: sessions.Handle, value: []const u8) anyerror!void {
                    const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                    try @call(.auto, handler, .{ typed, handle, value });
                }
            }.call,
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

    fn writeReply(context: *anyopaque, text: []const u8) void {
        const reply: *Reply = @ptrCast(@alignCast(context));
        reply.chat.system(reply.handle, text);
    }

    const writeTree = .{ writeTree_1_21_5, writeTree_1_21_6 };

    fn writeTree_1_21_5(packet: wire_1_21_5.play.toClient.packet_declare_commands.Writer, tree: *const commands.Commands, visible: []const bool) ![]u8 {
        return writeTreeBody(packet, tree, visible);
    }

    fn writeTree_1_21_6(packet: wire_1_21_6.play.toClient.packet_declare_commands.Writer, tree: *const commands.Commands, visible: []const bool) ![]u8 {
        return writeTreeBody(packet, tree, visible);
    }

    fn writeTreeBody(packet: anytype, tree: *const commands.Commands, visible: []const bool) ![]u8 {
        return commands.wire.treePacket(packet, tree, visible);
    }

    fn writeCompletions(packet: wire_1_21_5.play.toClient.packet_tab_complete.Writer, request_id: i32, input: []const u8, suggestions: *const commands.Suggestions) ![]u8 {
        return commands.wire.completions(packet, request_id, input, suggestions);
    }
};
