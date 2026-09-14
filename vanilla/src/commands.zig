const std = @import("std");
const commands = @import("commands");
const protocols = @import("protocols");
const sessions = @import("sessions");
const Players = @import("players.zig").Players;
const Chat = @import("chat.zig").Chat;

pub const CommandDispatch = struct {
    pub const id = "minecraft:command_dispatch";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *Players,
        chat: *Chat,
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

    deps: Dependencies,
    states: []State,
    visible: []bool,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*CommandDispatch {
        if (deps.players.deps.sessions.config.page_bytes < @max(10 * 1024, 16 + deps.commands.nodes.len * 128)) return error.CommandPacketCapacity;

        const self = try allocator.create(CommandDispatch);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        const visible = try allocator.alloc(bool, states.len * deps.commands.nodes.len);
        @memset(visible, false);
        self.* = .{ .deps = deps, .states = states, .visible = visible };
        return self;
    }

    pub fn tick(self: *CommandDispatch) !void {
        const service = self.deps.players.deps.sessions;
        const tree = self.deps.commands;
        tree.sealed = true;

        for (self.deps.players.records, self.states, 0..) |player, *state, player_index| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready) continue;

            if (state.generation != handle.generation or state.life != player.life) state.* = .{ .generation = handle.generation, .life = player.life };

            const previous = self.visible[player_index * tree.nodes.len ..][0..tree.count];
            var visible: [1024]bool = undefined;
            tree.visibility(player.uuid, visible[0..tree.count]);
            if (!state.sent or !std.mem.eql(bool, previous, visible[0..tree.count])) publish_tree: {
                var mapping: [1024]u16 = undefined;
                var count: u16 = 0;

                for (visible[0..tree.count], mapping[0..tree.count]) |shown, *mapped| {
                    mapped.* = count;
                    count += @intFromBool(shown);
                }

                var packet = service.reserve(service.config.page_bytes) catch break :publish_tree;
                defer packet.cancel();
                var writer = std.Io.Writer.fixed(packet.bytes);
                try writer.writeUleb128(@as(u32, @intCast(protocols.wire.play.toClient.packetId(.declare_commands))));
                try writer.writeUleb128(count);

                for (tree.nodes[0..tree.count], 0..) |node, at| {
                    if (!visible[at]) continue;

                    const argument = node.argument;
                    const flags: u8 = @as(u8, if (at == 0) 0 else if (argument == null) 1 else 2) | @as(u8, if (node.invoke != null) 4 else 0) | @as(u8, if (argument != null and argument.?.suggest != null) 16 else 0);
                    try writer.writeByte(flags);
                    var children: u16 = 0;

                    for (tree.nodes[1..tree.count], 1..) |child, child_index| children += @intFromBool(child.parent == at and visible[child_index]);
                    try writer.writeUleb128(children);

                    for (tree.nodes[1..tree.count], 1..) |child, child_index|
                        if (child.parent == at and visible[child_index]) try writer.writeUleb128(mapping[child_index]);
                    if (at == 0) continue;
                    try string(&writer, node.name);

                    if (argument) |spec| {
                        const parser: u32 = switch (spec.kind) {
                            .boolean => 0,
                            .float => 1,
                            .double => 2,
                            .integer => 3,
                            .long => 4,
                            else => 5,
                        };
                        try writer.writeUleb128(parser);

                        switch (spec.kind) {
                            .integer, .long => {
                                try writer.writeByte(@as(u8, @intFromBool(spec.minimum != null)) | (@as(u8, @intFromBool(spec.maximum != null)) << 1));

                                if (spec.minimum) |minimum| if (spec.kind == .integer) try writer.writeInt(i32, @intCast(minimum), .big) else try writer.writeInt(i64, minimum, .big);

                                if (spec.maximum) |maximum| if (spec.kind == .integer) try writer.writeInt(i32, @intCast(maximum), .big) else try writer.writeInt(i64, maximum, .big);
                            },
                            .float, .double => try writer.writeByte(0),
                            .boolean => {},
                            else => try writer.writeUleb128(@as(u32, if (spec.kind == .greedy) 2 else 0)),
                        }

                        if (spec.suggest != null) try string(&writer, "minecraft:ask_server");
                    }
                }

                try writer.writeUleb128(@as(u32, 0));
                packet.publish(writer.end, &.{handle}) catch break :publish_tree;
                @memcpy(previous, visible[0..tree.count]);
                state.sent = true;
            }

            var reply: Reply = .{ .chat = self.deps.chat, .handle = handle };

            for (self.deps.players.deps.input.values(handle)) |event| switch (event) {
                .command => |text| try tree.execute(.{ .sender = player.uuid, .output = &reply, .write = writeReply }, text),
                .completion => |request| {
                    if (request.text.len > state.text.len) {
                        service.disconnect(handle);
                        break;
                    }
                    // The input loan expires this tick. Retain only the newest completion request.

                    @memcpy(state.text[0..request.text.len], request.text);
                    state.length = request.text.len;
                    state.completion = request.id;
                },
                else => {},
            };

            if (state.completion) |request_id| {
                const text = state.text[0..state.length];
                var suggestions: commands.Suggestions = .{};
                tree.complete(player.uuid, text, &suggestions);
                std.debug.assert(suggestions.start <= text.len);
                std.debug.assert(suggestions.length <= text.len - suggestions.start);
                var packet = service.reserve(service.config.page_bytes) catch continue;
                defer packet.cancel();
                var writer = std.Io.Writer.fixed(packet.bytes);
                try writer.writeUleb128(@as(u32, @intCast(protocols.wire.play.toClient.packetId(.tab_complete))));
                try writer.writeUleb128(@as(u32, @bitCast(request_id)));
                try writer.writeUleb128(utf16(text[0..suggestions.start]));
                try writer.writeUleb128(utf16(text[suggestions.start..][0..suggestions.length]));
                try writer.writeUleb128(@as(u32, @intCast(suggestions.count)));

                for (suggestions.entries[0..suggestions.count]) |suggestion| {
                    try string(&writer, suggestion.text);
                    try writer.writeByte(@intFromBool(suggestion.tooltip.len != 0));

                    if (suggestion.tooltip.len != 0) {
                        try writer.writeByte(8);
                        try writer.writeInt(u16, @intCast(suggestion.tooltip.len), .big);
                        try writer.writeAll(suggestion.tooltip);
                    }
                }

                packet.publish(writer.end, &.{handle}) catch continue;
                state.completion = null;
            }
        }

        try self.deps.chat.flush();
    }

    fn writeReply(context: *anyopaque, text: []const u8) void {
        const reply: *Reply = @ptrCast(@alignCast(context));
        reply.chat.system(reply.handle, text);
    }
};

fn string(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeUleb128(@as(u32, @intCast(value.len)));
    try writer.writeAll(value);
}

fn utf16(value: []const u8) u32 {
    var count: u32 = 0;

    for (value) |byte| if (byte & 0xc0 != 0x80) {
        count += 1 + @as(u32, @intFromBool(byte >= 0xf0));
    };

    return count;
}
