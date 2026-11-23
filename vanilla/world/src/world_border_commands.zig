//! /worldborder, as WorldBorderCommand has it: set, add, center, damage, warning and get, with
//! its checks and its messages. Times are in seconds, as 1.21.8 takes them.

const std = @import("std");
const commands = @import("commands");
const Players = @import("players").players.Players;
const Chat = @import("chat").chat.Chat;
const world_border = @import("world_border.zig");
const WorldBorder = world_border.WorldBorder;

pub const WorldBorderCommands = struct {
    pub const id = "minecraft:world_border_commands";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        commands: *commands.Commands,
        world_border: *WorldBorder,
        players: *Players,
        chat: *Chat,
    };

    pub const permission: commands.Permission = .{ .name = "minecraft.command.worldborder", .description = "Manage the world border" };

    const Size = struct { distance: f64, time: ?i32 };
    const Center = struct { x: f64, z: f64 };
    const Amount = struct { damagePerBlock: f32 };
    const Buffer = struct { distance: f32 };
    const Distance = struct { distance: i32 };
    const Time = struct { time: i32 };
    const None = struct {};

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*WorldBorderCommands {
        const self = try allocator.create(WorldBorderCommands);
        self.* = .{ .deps = deps };
        const root = try deps.commands.literal(.{ .name = "worldborder", .description = "Manage the world border", .permission = &permission });
        _ = try root.add(self, commands.leaf(WorldBorderCommands, Size, .{
            .name = "add",
            .description = "Grow or shrink the world border by a distance, over seconds",
            .handler = add,
            .arguments = .{ .distance = .{}, .time = .{ .minimum = 0 } },
        }));
        _ = try root.add(self, commands.leaf(WorldBorderCommands, Size, .{
            .name = "set",
            .description = "Set the world border's width, over seconds",
            .handler = set,
            .arguments = .{ .distance = .{}, .time = .{ .minimum = 0 } },
        }));
        _ = try root.add(self, commands.leaf(WorldBorderCommands, Center, .{
            .name = "center",
            .description = "Move the world border's center",
            .handler = center,
            .arguments = .{ .x = .{ .parse = parseX, .suggest = suggestCoordinate }, .z = .{ .parse = parseZ, .suggest = suggestCoordinate } },
        }));
        const damage = try root.literal(.{ .name = "damage", .description = "Set the world border's damage" });
        _ = try damage.add(self, commands.leaf(WorldBorderCommands, Amount, .{
            .name = "amount",
            .description = "Damage each second per block beyond the buffer",
            .handler = damageAmount,
            .arguments = .{ .damagePerBlock = .{} },
        }));
        _ = try damage.add(self, commands.leaf(WorldBorderCommands, Buffer, .{
            .name = "buffer",
            .description = "How far outside the world border players go unhurt",
            .handler = damageBuffer,
            .arguments = .{ .distance = .{} },
        }));
        _ = try root.add(self, commands.leaf(WorldBorderCommands, None, .{
            .name = "get",
            .description = "Show the world border's width",
            .handler = get,
            .arguments = .{},
        }));
        const warning = try root.literal(.{ .name = "warning", .description = "Set the world border's warning" });
        _ = try warning.add(self, commands.leaf(WorldBorderCommands, Distance, .{
            .name = "distance",
            .description = "Blocks from the world border its warning starts",
            .handler = warningDistance,
            .arguments = .{ .distance = .{ .minimum = 0 } },
        }));
        _ = try warning.add(self, commands.leaf(WorldBorderCommands, Time, .{
            .name = "time",
            .description = "Seconds before a shrinking world border arrives that its warning starts",
            .handler = warningTime,
            .arguments = .{ .time = .{ .minimum = 0 } },
        }));
        return self;
    }

    fn set(self: *WorldBorderCommands, context: commands.Context, args: Size) !void {
        try checkDistance(args.distance);
        try self.resize(context, args.distance, @as(i64, args.time orelse 0) * 20);
    }

    /// Added time goes on top of the time the border still has to move.
    fn add(self: *WorldBorderCommands, context: commands.Context, args: Size) !void {
        try checkDistance(args.distance);
        const border = self.deps.world_border;
        const ticks = if (args.time) |seconds| border.remainingTicks() + @as(i64, seconds) * 20 else 0;
        try self.resize(context, border.size() + args.distance, ticks);
    }

    /// DoubleArgumentType's bounds.
    fn checkDistance(distance: f64) !void {
        if (!(@abs(distance) <= world_border.max_size)) return error.InvalidArgument;
    }

    fn resize(self: *WorldBorderCommands, context: commands.Context, size: f64, ticks: i64) !void {
        const border = self.deps.world_border;
        const current = border.size();
        if (current == size) return context.reply("Nothing changed. The world border is already that size");
        if (size < 1) return context.reply("World border cannot be smaller than 1 block wide");
        if (size > world_border.max_size) return context.reply("World border cannot be bigger than 5.9999968E7 blocks wide");
        var buffer: [160]u8 = undefined;
        const message = if (ticks > 0) message: {
            border.lerpSize(current, size, ticks);
            const seconds = @divTrunc(ticks, 20);
            break :message if (size > current)
                try std.fmt.bufPrint(&buffer, "Growing the world border to {d:.1} blocks wide over {d} seconds", .{ size, seconds })
            else
                try std.fmt.bufPrint(&buffer, "Shrinking the world border to {d:.1} block(s) wide over {d} second(s)", .{ size, seconds });
        } else message: {
            border.setSize(size);
            break :message try std.fmt.bufPrint(&buffer, "Set the world border to {d:.1} block(s) wide", .{size});
        };
        try self.feedback(context, message);
    }

    fn center(self: *WorldBorderCommands, context: commands.Context, args: Center) !void {
        const border = self.deps.world_border;
        // Vec2Argument gives floats.
        const x: f32 = @floatCast(args.x);
        const z: f32 = @floatCast(args.z);
        if (border.centerX() == x and border.centerZ() == z) return context.reply("Nothing changed. The world border is already centered there");
        if (@abs(x) > world_border.max_radius or @abs(z) > world_border.max_radius) return context.reply("World border cannot be further out than 2.9999984E7 blocks");
        border.setCenter(x, z);
        var buffer: [128]u8 = undefined;
        try self.feedback(context, try std.fmt.bufPrint(&buffer, "Set the center of the world border to {d:.2}, {d:.2}", .{ x, z }));
    }

    fn damageAmount(self: *WorldBorderCommands, context: commands.Context, args: Amount) !void {
        if (args.damagePerBlock < 0) return error.InvalidArgument;
        const border = self.deps.world_border;
        if (border.damage_per_block == args.damagePerBlock) return context.reply("Nothing changed. The world border damage is already that amount");
        border.setDamagePerBlock(args.damagePerBlock);
        var buffer: [128]u8 = undefined;
        try self.feedback(context, try std.fmt.bufPrint(&buffer, "Set the world border damage to {d:.2} per block each second", .{args.damagePerBlock}));
    }

    fn damageBuffer(self: *WorldBorderCommands, context: commands.Context, args: Buffer) !void {
        if (args.distance < 0) return error.InvalidArgument;
        const border = self.deps.world_border;
        if (border.safe_zone == args.distance) return context.reply("Nothing changed. The world border damage buffer is already that distance");
        border.setSafeZone(args.distance);
        var buffer: [128]u8 = undefined;
        try self.feedback(context, try std.fmt.bufPrint(&buffer, "Set the world border damage buffer to {d:.2} block(s)", .{args.distance}));
    }

    fn warningDistance(self: *WorldBorderCommands, context: commands.Context, args: Distance) !void {
        const border = self.deps.world_border;
        if (border.warning_blocks == args.distance) return context.reply("Nothing changed. The world border warning is already that distance");
        border.setWarningBlocks(args.distance);
        var buffer: [128]u8 = undefined;
        try self.feedback(context, try std.fmt.bufPrint(&buffer, "Set the world border warning distance to {d} block(s)", .{args.distance}));
    }

    fn warningTime(self: *WorldBorderCommands, context: commands.Context, args: Time) !void {
        const border = self.deps.world_border;
        if (border.warning_time == args.time) return context.reply("Nothing changed. The world border warning is already that amount of time");
        border.setWarningTime(args.time);
        var buffer: [128]u8 = undefined;
        try self.feedback(context, try std.fmt.bufPrint(&buffer, "Set the world border warning time to {d} second(s)", .{args.time}));
    }

    /// Only the sender hears the width.
    fn get(self: *WorldBorderCommands, context: commands.Context, _: None) !void {
        var buffer: [96]u8 = undefined;
        context.reply(try std.fmt.bufPrint(&buffer, "The world border is currently {d:.0} block(s) wide", .{self.deps.world_border.size()}));
    }

    /// To the sender, and to every other player allowed the command, as operators hear it.
    fn feedback(self: *WorldBorderCommands, context: commands.Context, message: []const u8) !void {
        context.reply(message);
        const sender = self.deps.players.find(context.sender) orelse return;
        var notification: [224]u8 = undefined;
        const broadcast = try std.fmt.bufPrint(&notification, "[{s}: {s}]", .{ sender.name[0..sender.name_len], message });
        for (self.deps.players.records) |player| {
            if (!player.inPlay() or player.uuid == context.sender or !self.deps.commands.permits(player.uuid, &permission)) continue;
            self.deps.chat.system(player.handle.?, broadcast);
        }
    }

    fn parseX(self: *WorldBorderCommands, context: commands.Context, text: []const u8) commands.ParseError!f64 {
        return self.coordinate(context, text, 0);
    }

    fn parseZ(self: *WorldBorderCommands, context: commands.Context, text: []const u8) commands.ParseError!f64 {
        return self.coordinate(context, text, 1);
    }

    /// WorldCoordinate.parseDouble with centered integers: `~` counts from the sender, and a
    /// whole number is the middle of its block.
    fn coordinate(self: *WorldBorderCommands, context: commands.Context, text: []const u8, axis: usize) commands.ParseError!f64 {
        if (text.len == 0) return error.InvalidArgument;
        if (text[0] == '~') {
            const offset = if (text.len == 1) 0 else try number(text[1..]);
            const sender = self.deps.players.find(context.sender) orelse return error.InvalidArgument;
            return (if (axis == 0) sender.position.x else sender.position.z) + offset;
        }
        const value = try number(text);
        return if (std.mem.indexOfScalar(u8, text, '.') == null) value + 0.5 else value;
    }

    fn number(text: []const u8) commands.ParseError!f64 {
        for (text) |byte| if (!std.ascii.isDigit(byte) and byte != '.' and byte != '-') return error.InvalidArgument;
        const value = std.fmt.parseFloat(f64, text) catch return error.InvalidArgument;
        if (!std.math.isFinite(value)) return error.InvalidArgument;
        return value;
    }

    fn suggestCoordinate(_: *WorldBorderCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        if (context.prefix.len == 0) output.add(.{ .text = "~" }) catch return;
    }
};

test {
    std.testing.refAllDecls(WorldBorderCommands);
}
