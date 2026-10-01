const std = @import("std");
const commands = @import("commands");
const Time = @import("time.zig").Time;
const Players = @import("players.zig").Players;
const Chat = @import("chat.zig").Chat;

pub const TimeCommands = struct {
    pub const id = "minecraft:time_commands";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        commands: *commands.Commands,
        time: *Time,
        players: *Players,
        chat: *Chat,
    };

    pub const permission: commands.Permission = .{ .name = "minecraft.command.time", .description = "Set and query world time" };
    const Amount = struct { time: i32 };
    const Query = struct { query: enum { daytime, gametime, day } };
    const presets = .{ .day = 1000, .noon = 6000, .night = 13000, .midnight = 18000 };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*TimeCommands {
        const self = try allocator.create(TimeCommands);
        self.* = .{ .deps = deps };
        const root = try deps.commands.literal(.{ .name = "time", .description = "Set and query world time", .permission = &permission });
        _ = try root.add(self, commands.leaf(TimeCommands, Amount, .{
            .name = "set",
            .description = "Set the time to day, noon, night, midnight, or a duration",
            .handler = set,
            .arguments = .{ .time = .{ .kind = .word, .parse = parseSet, .suggest = suggestSet } },
        }));
        _ = try root.add(self, commands.leaf(TimeCommands, Amount, .{
            .name = "add",
            .description = "Advance time in ticks (t), seconds (s), or days (d)",
            .handler = add,
            .arguments = .{ .time = .{ .kind = .word, .parse = parseTime, .suggest = suggestTime } },
        }));
        _ = try root.add(self, commands.leaf(TimeCommands, Query, .{
            .name = "query",
            .description = "Query the time of day, elapsed game ticks, or day count",
            .handler = query,
            .arguments = .{ .query = .{} },
        }));
        return self;
    }

    fn set(self: *TimeCommands, context: commands.Context, args: Amount) !void {
        self.deps.time.set(args.time);
        try self.feedback(context, args.time);
    }

    fn add(self: *TimeCommands, context: commands.Context, args: Amount) !void {
        self.deps.time.set(self.deps.time.day_time +% args.time);
        try self.feedback(context, @rem(self.deps.time.day_time, 24000));
    }

    fn query(self: *TimeCommands, context: commands.Context, args: Query) !void {
        const time = self.deps.time;
        const value = switch (args.query) {
            .daytime => @rem(time.day_time, 24000),
            .gametime => @rem(time.game_time, std.math.maxInt(i32)),
            .day => @rem(@divTrunc(time.day_time, 24000), std.math.maxInt(i32)),
        };
        var buffer: [64]u8 = undefined;
        context.reply(try std.fmt.bufPrint(&buffer, "The time is {d}", .{value}));
    }

    fn feedback(self: *TimeCommands, context: commands.Context, value: i64) !void {
        var buffer: [64]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "Set the time to {d}", .{value});
        context.reply(message);
        const sender = self.deps.players.find(context.sender) orelse return;
        var notification: [128]u8 = undefined;
        const broadcast = try std.fmt.bufPrint(&notification, "[{s}: {s}]", .{ sender.name[0..sender.name_len], message });
        for (self.deps.players.records) |player| {
            if (!player.inPlay() or player.uuid == context.sender or !self.deps.commands.permits(player.uuid, &permission)) continue;
            self.deps.chat.system(player.handle.?, broadcast);
        }
    }

    fn parseSet(self: *TimeCommands, context: commands.Context, text: []const u8) commands.ParseError!i32 {
        inline for (std.meta.fields(@TypeOf(presets))) |field| {
            if (std.mem.eql(u8, text, field.name)) return @field(presets, field.name);
        }
        return parseTime(self, context, text);
    }

    fn parseTime(_: *TimeCommands, _: commands.Context, text: []const u8) commands.ParseError!i32 {
        var end: usize = 0;
        while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.' or text[end] == '-')) : (end += 1) {}
        if (end == 0) return error.InvalidArgument;
        const number = std.fmt.parseFloat(f32, text[0..end]) catch return error.InvalidArgument;
        const unit = text[end..];
        const multiplier: f32 = if (unit.len == 0 or std.mem.eql(u8, unit, "t")) 1 else if (std.mem.eql(u8, unit, "s")) 20 else if (std.mem.eql(u8, unit, "d")) 24000 else return error.InvalidArgument;
        const ticks = number * multiplier;
        // Java's Math.round(float) rounds ties toward positive infinity and saturates to i32.
        const rounded = @floor(@as(f64, ticks) + 0.5);
        if (rounded < 0) return error.InvalidArgument;
        if (rounded >= std.math.maxInt(i32)) return std.math.maxInt(i32);
        return @intFromFloat(rounded);
    }

    fn suggestSet(self: *TimeCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        inline for (std.meta.fields(@TypeOf(presets))) |field| {
            if (std.mem.startsWith(u8, field.name, context.prefix)) output.add(.{ .text = field.name }) catch return;
        }
        suggestTime(self, context, output);
    }

    fn suggestTime(_: *TimeCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        if (context.prefix.len == 0) return;
        for (context.prefix) |byte| if (!std.ascii.isDigit(byte) and byte != '.' and byte != '-') return;
        _ = std.fmt.parseFloat(f32, context.prefix) catch return;
        var buffer: [commands.max_input + 1]u8 = undefined;
        for ([_][]const u8{ "d", "s", "t" }) |suffix| {
            const text = std.fmt.bufPrint(&buffer, "{s}{s}", .{ context.prefix, suffix }) catch return;
            output.add(.{ .text = text }) catch return;
        }
    }
};
