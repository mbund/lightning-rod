const std = @import("std");

const assert = std.debug.assert;
pub const max_arguments = 16;
pub const max_input = 1024;

pub const Permission = struct {
    name: []const u8,
    description: []const u8,
};

pub const Policy = struct {
    context: *anyopaque,
    allows: *const fn (*anyopaque, u128, *const Permission) bool,
};

pub const Grants = struct {
    pub const User = struct {
        uuid: u128,
        allow: []const *const Permission = &.{},
        deny: []const *const Permission = &.{},
    };

    everyone: []const *const Permission = &.{},
    users: []const User = &.{},

    pub fn policy(self: *Grants) Policy {
        return .{ .context = self, .allows = allows };
    }

    fn allows(context: *anyopaque, uuid: u128, permission: *const Permission) bool {
        const self: *const Grants = @ptrCast(@alignCast(context));
        var granted = false;

        for (self.everyone) |entry| granted = granted or std.mem.eql(u8, entry.name, permission.name);

        for (self.users) |user| {
            if (user.uuid != uuid) continue;

            for (user.deny) |entry| if (std.mem.eql(u8, entry.name, permission.name)) return false;

            for (user.allow) |entry| granted = granted or std.mem.eql(u8, entry.name, permission.name);
        }

        return granted;
    }
};

pub const Context = struct {
    sender: u128,
    output: *anyopaque,
    write: *const fn (*anyopaque, []const u8) void,

    pub fn reply(self: Context, text: []const u8) void {
        self.write(self.output, text);
    }
};

pub const CompletionContext = struct {
    sender: u128,
    input: []const u8,
    prefix: []const u8,
    argument: []const u8,
    preceding: []const []const u8,
    start: usize,
    cursor: usize,
};

pub const Suggestions = struct {
    pub const Entry = struct {
        text: []const u8,
        tooltip: []const u8,
    };

    entries: [64]Entry = undefined,
    bytes: [8192]u8 = undefined,
    count: usize = 0,
    used: usize = 0,
    start: usize = 0,
    length: usize = 0,

    pub fn add(self: *Suggestions, entry: struct {
        text: []const u8,
        tooltip: []const u8 = "",
    }) error{Full}!void {
        if (self.count == self.entries.len or entry.text.len + entry.tooltip.len > self.bytes.len - self.used) return error.Full;

        for (self.entries[0..self.count]) |previous| if (std.mem.eql(u8, previous.text, entry.text)) return;
        const text = self.bytes[self.used..][0..entry.text.len];
        const tooltip = self.bytes[self.used + text.len ..][0..entry.tooltip.len];
        // Callbacks may supply stack-local formatting buffers.
        @memcpy(text, entry.text);
        @memcpy(tooltip, entry.tooltip);
        self.entries[self.count] = .{ .text = text, .tooltip = tooltip };
        self.count += 1;
        self.used += text.len + tooltip.len;
    }
};

pub const ParseError = error{InvalidArgument};

pub const Kind = enum { word, greedy, boolean, integer, long, float, double };

pub const ArgumentInfo = struct {
    kind: Kind,
    optional: bool,
    minimum: ?i64,
    maximum: ?i64,
    suggest: ?*const fn (*anyopaque, CompletionContext, *Suggestions) void,
};

pub const Definition = struct {
    Owner: type,
    name: []const u8,
    description: []const u8,
    permission: ?*const Permission,
    argument_names: []const []const u8,
    arguments: []const ArgumentInfo,
    invoke: *const fn (*anyopaque, Context, []const []const u8) anyerror!void,
};

pub fn Argument(comptime Owner: type, comptime T: type) type {
    return struct {
        parse: ?*const fn (*Owner, Context, []const u8) ParseError!T = null,
        suggest: ?*const fn (*Owner, CompletionContext, *Suggestions) void = null,
        greedy: bool = false,
        minimum: ?i64 = null,
        maximum: ?i64 = null,
    };
}

pub fn Arguments(comptime Owner: type, comptime Args: type) type {
    const fields = std.meta.fields(Args);
    comptime var types: [fields.len]type = undefined;

    inline for (fields, 0..) |field, index| types[index] = Argument(Owner, Value(field.type));
    return @Struct(.auto, null, std.meta.fieldNames(Args), &types, &@splat(.{}));
}

pub fn Leaf(comptime Owner: type, comptime Args: type) type {
    return struct {
        name: []const u8,
        description: []const u8,
        permission: ?*const Permission = null,
        handler: *const fn (*Owner, Context, Args) anyerror!void,
        arguments: Arguments(Owner, Args),
    };
}

pub fn leaf(comptime Owner: type, comptime Args: type, comptime definition: Leaf(Owner, Args)) Definition {
    const fields = std.meta.fields(Args);

    if (fields.len > max_arguments) @compileError("too many command arguments");
    const Adapter = struct {
        fn invoke(pointer: *anyopaque, context: Context, values: []const []const u8) !void {
            assert(values.len <= fields.len);
            var args: Args = undefined;

            inline for (fields, 0..) |field, index| {
                const spec = @field(definition.arguments, field.name);

                if (index < values.len) {
                    const parse = spec.parse orelse Parser(Owner, Value(field.type)).parse;
                    const value = try parse(@ptrCast(@alignCast(pointer)), context, values[index]);
                    if (comptime @typeInfo(Value(field.type)) == .int) {
                        if (spec.minimum) |minimum| if (value < minimum) return error.InvalidArgument;
                        if (spec.maximum) |maximum| if (value > maximum) return error.InvalidArgument;
                    }

                    @field(args, field.name) = value;
                } else if (comptime @typeInfo(field.type) == .optional) {
                    @field(args, field.name) = null;
                } else return error.InvalidArgument;
            }

            try definition.handler(@ptrCast(@alignCast(pointer)), context, args);
        }
    };
    const arguments = comptime block: {
        var output: [fields.len]ArgumentInfo = undefined;
        var optional = false;

        for (fields, 0..) |field, index| {
            const T = Value(field.type);
            const spec = @field(definition.arguments, field.name);

            if (field.name.len > 64) @compileError("command argument name is too long");

            if (spec.minimum != null and spec.maximum != null and spec.minimum.? > spec.maximum.?) @compileError("inverted argument bounds");

            if ((spec.minimum != null or spec.maximum != null) and @typeInfo(T) != .int) @compileError("bounds require an integer argument");

            if (optional and @typeInfo(field.type) != .optional) @compileError("optional arguments must be trailing");
            optional = @typeInfo(field.type) == .optional;

            if (spec.greedy and index + 1 != fields.len) @compileError("greedy argument must be last");
            const AdapterSuggest = struct {
                fn suggest(pointer: *anyopaque, context: CompletionContext, suggestions: *Suggestions) void {
                    if (spec.suggest) |callback| return callback(@ptrCast(@alignCast(pointer)), context, suggestions);
                    if (comptime @typeInfo(T) == .@"enum") inline for (std.meta.fields(T)) |tag| {
                        if (std.mem.startsWith(u8, tag.name, context.prefix)) suggestions.add(.{ .text = tag.name }) catch return;
                    };
                }
            };
            output[index] = .{
                .kind = if (spec.greedy) .greedy else if (spec.parse != null) .word else switch (@typeInfo(T)) {
                    .bool => .boolean,
                    .int => |integer| if (integer.bits <= 31 or (integer.signedness == .signed and integer.bits <= 32)) .integer else if (integer.bits <= 63 or (integer.signedness == .signed and integer.bits <= 64)) .long else .word,
                    .float => |float| if (float.bits <= 32) .float else .double,
                    else => .word,
                },
                .optional = optional,
                .minimum = spec.minimum,
                .maximum = spec.maximum,
                .suggest = if (spec.suggest != null or @typeInfo(T) == .@"enum") AdapterSuggest.suggest else null,
            };

            if (output[index].kind == .integer) {
                if (spec.minimum) |minimum|
                    if (minimum < std.math.minInt(i32) or minimum > std.math.maxInt(i32)) @compileError("minimum exceeds wire integer range");

                if (spec.maximum) |maximum|
                    if (maximum < std.math.minInt(i32) or maximum > std.math.maxInt(i32)) @compileError("maximum exceeds wire integer range");
            }
        }

        break :block output;
    };
    return .{
        .Owner = Owner,
        .name = definition.name,
        .description = definition.description,
        .permission = definition.permission,
        .argument_names = std.meta.fieldNames(Args),
        .arguments = &arguments,
        .invoke = Adapter.invoke,
    };
}

fn Value(comptime T: type) type {
    return if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
}

fn Parser(comptime Owner: type, comptime T: type) type {
    return struct {
        fn parse(_: *Owner, _: Context, text: []const u8) ParseError!T {
            return switch (@typeInfo(T)) {
                .int => std.fmt.parseInt(T, text, 10) catch error.InvalidArgument,
                .float => block: {
                    const value = std.fmt.parseFloat(T, text) catch return error.InvalidArgument;
                    if (!std.math.isFinite(value)) return error.InvalidArgument;
                    break :block value;
                },
                .bool => if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else error.InvalidArgument,
                .@"enum" => std.meta.stringToEnum(T, text) orelse error.InvalidArgument,
                else => if (T == []const u8) text else @compileError("provide a typed .parse callback for " ++ @typeName(T)),
            };
        }
    };
}

pub const Commands = struct {
    pub const id = "lightning_rod:commands";

    pub const Configuration = struct {
        maximum_nodes: usize = 128,
        help_page_size: usize = 6,
    };

    pub const Dependencies = struct { permission_policy: ?Policy };

    pub const Node = struct {
        parent: u16 = 0,
        name: []const u8 = "",
        description: []const u8 = "",
        permission: ?*const Permission = null,
        argument: ?ArgumentInfo = null,
        context: *anyopaque = undefined,
        invoke: ?*const fn (*anyopaque, Context, []const []const u8) anyerror!void = null,
    };

    allocator: std.mem.Allocator,
    nodes: []Node,
    count: u16 = 1,
    sealed: bool = false,
    config: Configuration,
    deps: Dependencies,

    const HelpArgs = struct { page: ?u32 };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Commands {
        if (config.maximum_nodes < 3 or config.maximum_nodes > 1024 or config.help_page_size == 0 or config.help_page_size > 10)
            return error.InvalidConfiguration;

        const self = try allocator.create(Commands);
        const nodes = try allocator.alloc(Node, config.maximum_nodes);
        @memset(nodes, .{});
        self.* = .{ .allocator = allocator, .nodes = nodes, .config = config, .deps = deps };
        _ = try self.register(self, leaf(Commands, HelpArgs, .{
            .name = "help",
            .description = "List commands you can use",
            .handler = help,
            .arguments = .{ .page = .{ .minimum = 1 } },
        }));
        return self;
    }

    pub fn literal(self: *Commands, definition: Literal) !Branch {
        return (Branch{ .commands = self, .index = 0 }).literal(definition);
    }

    pub fn register(self: *Commands, owner: anytype, comptime definition: Definition) !Branch {
        return (Branch{ .commands = self, .index = 0 }).add(owner, definition);
    }

    pub fn allowed(self: *const Commands, sender: u128, index: usize) bool {
        assert(index < self.count);
        var current = index;

        while (current != 0) {
            const node = self.nodes[current];
            if (node.permission) |permission| {
                const policy = self.deps.permission_policy orelse return false;
                if (!policy.allows(policy.context, sender, permission)) return false;
            }

            assert(node.parent < current);
            current = node.parent;
        }

        return true;
    }

    pub fn execute(self: *Commands, context: Context, input: []const u8) !void {
        self.sealed = true;
        if (input.len > max_input) {
            context.reply("Command is too long.");
            return;
        }

        var words: [max_arguments][]const u8 = undefined;
        var count: usize = 0;
        var node: usize = 0;
        var cursor: usize = 0;

        while (cursor < input.len) {
            while (cursor < input.len and input[cursor] == ' ') cursor += 1;
            if (cursor == input.len) break;

            const start = cursor;

            while (cursor < input.len and input[cursor] != ' ') cursor += 1;
            var found: ?usize = null;
            var argument: ?usize = null;

            for (self.nodes[1..self.count], 1..) |child, index| {
                if (child.parent != node or !self.allowed(context.sender, index)) continue;

                if (child.argument != null) argument = index else if (std.mem.eql(u8, child.name, input[start..cursor])) found = index;
            }

            node = found orelse argument orelse {
                context.reply("Unknown command or insufficient permission. Use /help.");
                return;
            };
            if (self.nodes[node].argument) |spec| {
                if (count == words.len) {
                    context.reply("Too many arguments.");
                    return;
                }

                if (spec.kind == .greedy) cursor = input.len;
                words[count] = input[start..cursor];
                count += 1;
            }
        }

        const invoke = self.nodes[node].invoke orelse {
            context.reply("Missing arguments. Use /help.");
            return;
        };
        if (!self.allowed(context.sender, node)) {
            context.reply("Permission denied.");
            return;
        }

        invoke(self.nodes[node].context, context, words[0..count]) catch |err| switch (err) {
            error.InvalidArgument => context.reply("Invalid argument. Use /help for usage."),
            else => return err,
        };
    }

    pub fn visibility(self: *const Commands, sender: u128, visible: []bool) void {
        assert(visible.len == self.count);
        visible[0] = true;

        for (self.nodes[1..self.count], 1..) |node, index| visible[index] = node.invoke != null and self.allowed(sender, index);
        var index: usize = self.count;

        while (index > 1) {
            index -= 1;

            if (visible[index]) visible[self.nodes[index].parent] = true;
        }
    }

    pub fn complete(self: *Commands, sender: u128, input: []const u8, output: *Suggestions) void {
        self.sealed = true;
        if (input.len > max_input) return;

        var visible: [1024]bool = undefined;
        self.visibility(sender, visible[0..self.count]);
        var preceding: [32][]const u8 = undefined;
        var count: usize = 0;
        var node: usize = 0;
        var cursor: usize = @intFromBool(std.mem.startsWith(u8, input, "/"));

        while (true) {
            while (cursor < input.len and input[cursor] == ' ') cursor += 1;
            const start = cursor;

            while (cursor < input.len and input[cursor] != ' ') cursor += 1;
            const prefix = input[start..cursor];
            if (cursor == input.len) {
                output.start = start;
                output.length = cursor - start;

                for (self.nodes[1..self.count], 1..) |child, index| {
                    if (child.parent != node or !visible[index]) continue;

                    if (child.argument) |argument| {
                        if (argument.suggest) |suggest| suggest(child.context, .{
                            .sender = sender,
                            .input = input,
                            .prefix = prefix,
                            .argument = child.name,
                            .preceding = preceding[0..count],
                            .start = start,
                            .cursor = cursor,
                        }, output) else if (argument.kind == .boolean) {
                            for ([_][]const u8{ "true", "false" }) |value| if (std.mem.startsWith(u8, value, prefix)) output.add(.{ .text = value }) catch return;
                        }
                    } else if (std.mem.startsWith(u8, child.name, prefix)) output.add(.{ .text = child.name, .tooltip = child.description }) catch return;
                }

                return;
            }

            var found: ?usize = null;
            var argument: ?usize = null;

            for (self.nodes[1..self.count], 1..) |child, index| {
                if (child.parent != node or !visible[index]) continue;

                if (child.argument != null) argument = index else if (std.mem.eql(u8, child.name, prefix)) found = index;
            }

            node = found orelse argument orelse return;
            if (self.nodes[node].argument) |spec| if (spec.kind == .greedy) {
                output.start = start;
                output.length = input.len - start;

                if (spec.suggest) |suggest|
                    suggest(self.nodes[node].context, .{
                        .sender = sender,
                        .input = input,
                        .prefix = input[start..],
                        .argument = self.nodes[node].name,
                        .preceding = preceding[0..count],
                        .start = start,
                        .cursor = input.len,
                    }, output);
                return;
            };

            if (count == preceding.len) return;
            preceding[count] = prefix;
            count += 1;
        }
    }

    fn help(self: *Commands, context: Context, args: HelpArgs) !void {
        var total: usize = 0;

        for (self.nodes[1..self.count], 1..) |node, index| {
            if (node.invoke == null or !self.allowed(context.sender, index)) continue;

            var extended = false;

            for (self.nodes[index + 1 .. self.count]) |child|
                extended = extended or (child.parent == index and child.argument != null and child.invoke == node.invoke);

            if (!extended) total += 1;
        }

        const pages = @max(1, std.math.divCeil(usize, total, self.config.help_page_size) catch unreachable);
        const page: usize = args.page orelse 1;
        if (page == 0 or page > pages) {
            context.reply("No such help page.");
            return;
        }

        var buffer: [1024]u8 = undefined;
        context.reply(try std.fmt.bufPrint(&buffer, "Commands — page {d}/{d}", .{ page, pages }));
        var ordinal: usize = 0;

        for (self.nodes[1..self.count], 1..) |node, index| {
            if (node.invoke == null or !self.allowed(context.sender, index)) continue;

            var extended = false;

            for (self.nodes[index + 1 .. self.count]) |child|
                extended = extended or (child.parent == index and child.argument != null and child.invoke == node.invoke);
            if (extended) continue;
            ordinal += 1;
            if (ordinal <= (page - 1) * self.config.help_page_size or ordinal > page * self.config.help_page_size) continue;

            var path: [32]usize = undefined;
            var length: usize = 0;
            var current = index;

            while (current != 0) : (current = self.nodes[current].parent) {
                assert(length < path.len);
                path[length] = current;
                length += 1;
            }

            var writer = std.Io.Writer.fixed(&buffer);
            try writer.writeByte('/');

            while (length > 0) {
                length -= 1;
                const part = self.nodes[path[length]];

                if (part.argument) |argument| try writer.print("{s}{s}{s}", .{ if (argument.optional) "[" else "<", part.name, if (argument.optional) "]" else ">" }) else try writer.writeAll(part.name);

                if (length > 0) try writer.writeByte(' ');
            }

            try writer.print(" — {s}", .{node.description});
            context.reply(writer.buffered());
        }

        if (page < pages) context.reply(try std.fmt.bufPrint(&buffer, "Next: /help {d}", .{page + 1}));
    }
};

pub const Literal = struct {
    name: []const u8,
    description: []const u8 = "",
    permission: ?*const Permission = null,
};

pub const Branch = struct {
    commands: *Commands,
    index: u16,

    pub fn literal(self: Branch, definition: Literal) !Branch {
        const commands = self.commands;
        if (commands.sealed) return error.RegistrationClosed;
        if (definition.name.len == 0 or definition.name.len > 64 or definition.description.len > 256) return error.InvalidCommand;

        for (definition.name) |byte|
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != ':') return error.InvalidCommand;
        if (commands.count == commands.nodes.len) return error.CommandCapacity;

        for (commands.nodes[1..commands.count]) |node|
            if (node.parent == self.index and node.argument == null and std.mem.eql(u8, node.name, definition.name)) return error.DuplicateCommand;
        var depth: usize = 1;
        var path_bytes: usize = definition.name.len + 1;
        var parent = self.index;

        while (parent != 0) : (parent = commands.nodes[parent].parent) {
            depth += 1;
            path_bytes += commands.nodes[parent].name.len + 3;
        }

        if (path_bytes > 512) return error.CommandTooLong;
        if (depth + max_arguments > 32) return error.CommandDepth;

        const index = commands.count;
        const name = try commands.allocator.dupe(u8, definition.name);
        const description = try commands.allocator.dupe(u8, definition.description);
        commands.nodes[index] = .{ .parent = self.index, .name = name, .description = description, .permission = definition.permission };
        commands.count += 1;
        return .{ .commands = commands, .index = index };
    }

    pub fn add(self: Branch, owner: anytype, comptime definition: Definition) !Branch {
        if (@TypeOf(owner) != *definition.Owner) @compileError("command owner must be *" ++ @typeName(definition.Owner));
        var path_bytes: usize = definition.name.len + 1;

        for (definition.argument_names) |name| path_bytes += name.len + 3;
        var ancestor = self.index;

        while (ancestor != 0) : (ancestor = self.commands.nodes[ancestor].parent) path_bytes += self.commands.nodes[ancestor].name.len + 3;
        if (path_bytes > 512) return error.CommandTooLong;
        if (self.commands.nodes.len - self.commands.count < definition.arguments.len + 1) return error.CommandCapacity;

        const branch = try self.literal(.{ .name = definition.name, .description = definition.description, .permission = definition.permission });
        var parent = branch.index;

        for (definition.arguments, definition.argument_names) |argument, name| {
            if (argument.optional) {
                self.commands.nodes[parent].invoke = definition.invoke;
                self.commands.nodes[parent].context = owner;
            }

            const index = self.commands.count;
            self.commands.nodes[index] = .{
                .parent = parent,
                .name = name,
                .description = definition.description,
                .argument = argument,
                .context = owner,
            };
            self.commands.count += 1;
            parent = index;
        }

        self.commands.nodes[parent].invoke = definition.invoke;
        self.commands.nodes[parent].context = owner;
        assert(parent < self.commands.count);
        return branch;
    }
};
