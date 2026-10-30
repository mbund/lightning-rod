const std = @import("std");
const Mask = std.StaticBitSet(128);
const Node = union(enum) {
    character: Mask,
    sequence: []const *const Node,
    alternatives: []const *const Node,
    repeat: struct { node: *const Node, minimum: u16, maximum: ?u16 },
    beginning,
    end,
};
const Step = union(enum) {
    character: struct { mask: Mask, next: u32 = 0 },
    split: struct { left: u32, right: u32 = 0 },
    jump: u32,
    beginning: u32,
    end: u32,
    accept,
};
const Patch = struct { step: u32, right: bool = false };
const Fragment = struct { start: u32, outputs: []const Patch };

pub const Pattern = struct {
    steps: []const Step,
    start: u32,
    current: []u32,
    next: []u32,
    pending: []u32,
    visited: []u32,
    generation: u32 = 0,

    pub fn compile(allocator: std.mem.Allocator, expression: []const u8) !Pattern {
        if (expression.len > 1024) return error.PatternTooLarge;
        var parser: Parser = .{ .allocator = allocator, .expression = expression };
        const root = try parser.expressionNode(0);
        if (parser.cursor != expression.len) return error.InvalidPattern;
        var compiler: Compiler = .{ .allocator = allocator };
        const fragment = try compiler.node(root, 0);
        const accept = try compiler.emit(.accept);
        compiler.patch(fragment.outputs, accept);
        const visited = try allocator.alloc(u32, compiler.steps.items.len);
        @memset(visited, 0);
        return .{ .steps = compiler.steps.items, .start = fragment.start, .current = try allocator.alloc(u32, visited.len), .next = try allocator.alloc(u32, visited.len), .pending = try allocator.alloc(u32, visited.len), .visited = visited };
    }

    pub fn matches(self: *Pattern, value: []const u8) bool {
        self.advance();
        var count: usize = 0;
        self.expand(self.start, self.current, &count, 0, value.len);
        for (value, 0..) |byte, position| {
            if (byte >= 128) return false;
            self.advance();
            var next_count: usize = 0;
            for (self.current[0..count]) |index| switch (self.steps[index]) {
                .character => |character| if (character.mask.isSet(byte)) self.expand(character.next, self.next, &next_count, position + 1, value.len),
                else => {},
            };
            std.mem.swap([]u32, &self.current, &self.next);
            count = next_count;
            if (count == 0) return false;
        }
        for (self.current[0..count]) |index| if (self.steps[index] == .accept) return true;
        return false;
    }

    fn advance(self: *Pattern) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.visited, 0);
            self.generation = 1;
        }
    }

    fn push(self: *Pattern, index: u32, count: *usize) void {
        std.debug.assert(index < self.steps.len);
        if (self.visited[index] == self.generation) return;
        self.visited[index] = self.generation;
        std.debug.assert(count.* < self.pending.len);
        self.pending[count.*] = index;
        count.* += 1;
    }

    fn expand(self: *Pattern, start: u32, output: []u32, length: *usize, position: usize, end: usize) void {
        var pending: usize = 0;
        self.push(start, &pending);
        while (pending != 0) {
            pending -= 1;
            const index = self.pending[pending];
            switch (self.steps[index]) {
                .split => |split| {
                    self.push(split.left, &pending);
                    self.push(split.right, &pending);
                },
                .jump => |next| self.push(next, &pending),
                .beginning => |next| if (position == 0) self.push(next, &pending),
                .end => |next| if (position == end) self.push(next, &pending),
                .character, .accept => {
                    std.debug.assert(length.* < output.len);
                    output[length.*] = index;
                    length.* += 1;
                },
            }
        }
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    expression: []const u8,
    cursor: usize = 0,

    fn create(self: *Parser, value: Node) !*const Node {
        const result = try self.allocator.create(Node);
        result.* = value;
        return result;
    }
    fn take(self: *Parser, byte: u8) bool {
        if (self.cursor == self.expression.len or self.expression[self.cursor] != byte) return false;
        self.cursor += 1;
        return true;
    }
    fn expressionNode(self: *Parser, depth: usize) anyerror!*const Node {
        if (depth >= 64) return error.PatternTooDeep;
        var alternatives: std.ArrayList(*const Node) = .empty;
        try alternatives.append(self.allocator, try self.sequence(depth + 1));
        while (self.take('|')) try alternatives.append(self.allocator, try self.sequence(depth + 1));
        return if (alternatives.items.len == 1) alternatives.items[0] else self.create(.{ .alternatives = alternatives.items });
    }
    fn sequence(self: *Parser, depth: usize) anyerror!*const Node {
        var nodes: std.ArrayList(*const Node) = .empty;
        while (self.cursor < self.expression.len and self.expression[self.cursor] != ')' and self.expression[self.cursor] != '|') {
            const element = try self.atom(depth + 1);
            var minimum: u16 = 1;
            var maximum: ?u16 = 1;
            if (self.take('*')) {
                minimum = 0;
                maximum = null;
            } else if (self.take('+')) {
                maximum = null;
            } else if (self.take('?')) {
                minimum = 0;
            } else if (self.take('{')) {
                minimum = try self.count();
                maximum = minimum;
                if (self.take(',')) maximum = if (self.cursor < self.expression.len and self.expression[self.cursor] != '}') try self.count() else null;
                if (!self.take('}') or (maximum != null and maximum.? < minimum)) return error.InvalidPattern;
            }
            const node = if (minimum == 1 and maximum == 1) element else try self.create(.{ .repeat = .{ .node = element, .minimum = minimum, .maximum = maximum } });
            // Greediness does not change whether the complete resource name matches.
            _ = self.take('?');
            try nodes.append(self.allocator, node);
        }
        return if (nodes.items.len == 1) nodes.items[0] else self.create(.{ .sequence = nodes.items });
    }
    fn count(self: *Parser) !u16 {
        const start = self.cursor;
        while (self.cursor < self.expression.len and std.ascii.isDigit(self.expression[self.cursor])) self.cursor += 1;
        if (start == self.cursor) return error.InvalidPattern;
        const value = try std.fmt.parseInt(u16, self.expression[start..self.cursor], 10);
        if (value > 1024) return error.PatternTooLarge;
        return value;
    }
    fn atom(self: *Parser, depth: usize) anyerror!*const Node {
        if (depth >= 64 or self.cursor == self.expression.len) return error.InvalidPattern;
        if (self.take('(')) {
            if (self.take('?') and !self.take(':')) return error.UnsupportedPattern;
            const node = try self.expressionNode(depth + 1);
            if (!self.take(')')) return error.InvalidPattern;
            return node;
        }
        if (self.take('^')) return self.create(.beginning);
        if (self.take('$')) return self.create(.end);
        if (self.take('.')) return self.create(.{ .character = Mask.initFull() });
        if (self.take('[')) {
            const inverted = self.take('^');
            var mask = Mask.initEmpty();
            var count_value: usize = 0;
            while (self.cursor < self.expression.len and self.expression[self.cursor] != ']') {
                const first = try self.character();
                if (self.cursor + 1 < self.expression.len and self.expression[self.cursor] == '-' and self.expression[self.cursor + 1] != ']') {
                    self.cursor += 1;
                    const last = try self.character();
                    if (first.count() != 1 or last.count() != 1) return error.InvalidPattern;
                    const low = first.findFirstSet().?;
                    const high = last.findFirstSet().?;
                    if (low > high) return error.InvalidPattern;
                    for (low..high + 1) |byte| mask.set(byte);
                } else mask.setUnion(first);
                count_value += 1;
            }
            if (count_value == 0 or !self.take(']')) return error.InvalidPattern;
            if (inverted) mask.toggleAll();
            return self.create(.{ .character = mask });
        }
        if (std.mem.indexOfScalar(u8, "*+?{})", self.expression[self.cursor]) != null) return error.InvalidPattern;
        return self.create(.{ .character = try self.character() });
    }
    fn character(self: *Parser) !Mask {
        if (self.cursor == self.expression.len) return error.InvalidPattern;
        var byte = self.expression[self.cursor];
        self.cursor += 1;
        var mask = Mask.initEmpty();
        if (byte == '\\') {
            if (self.cursor == self.expression.len) return error.InvalidPattern;
            byte = self.expression[self.cursor];
            self.cursor += 1;
            if (std.mem.indexOfScalar(u8, "dDwWsS", byte) != null) {
                for (0..128) |value| {
                    const c: u8 = @intCast(value);
                    const selected = switch (std.ascii.toLower(byte)) {
                        'd' => std.ascii.isDigit(c),
                        'w' => std.ascii.isAlphanumeric(c) or c == '_',
                        's' => std.ascii.isWhitespace(c),
                        else => unreachable,
                    };
                    if (selected != std.ascii.isUpper(byte)) mask.set(value);
                }
                return mask;
            }
            if (std.ascii.isAlphanumeric(byte)) return error.UnsupportedPattern;
        }
        if (byte < 128) mask.set(byte);
        return mask;
    }
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(Step) = .empty,
    fn emit(self: *Compiler, value: Step) !u32 {
        if (self.steps.items.len == 8192) return error.PatternTooLarge;
        try self.steps.append(self.allocator, value);
        return @intCast(self.steps.items.len - 1);
    }
    fn output(self: *Compiler, index: u32, right: bool) ![]const Patch {
        const patch_value = try self.allocator.alloc(Patch, 1);
        patch_value[0] = .{ .step = index, .right = right };
        return patch_value;
    }
    fn patch(self: *Compiler, outputs: []const Patch, target: u32) void {
        for (outputs) |value| switch (self.steps.items[value.step]) {
            .character => |*character| character.next = target,
            .split => |*split| {
                std.debug.assert(value.right);
                split.right = target;
            },
            .jump => |*next| next.* = target,
            .beginning => |*next| next.* = target,
            .end => |*next| next.* = target,
            .accept => unreachable,
        };
    }
    fn join(self: *Compiler, left: Fragment, right: Fragment) Fragment {
        self.patch(left.outputs, right.start);
        return .{ .start = left.start, .outputs = right.outputs };
    }
    fn combine(self: *Compiler, left: []const Patch, right: []const Patch) ![]const Patch {
        const result = try self.allocator.alloc(Patch, left.len + right.len);
        @memcpy(result[0..left.len], left);
        @memcpy(result[left.len..], right);
        return result;
    }
    fn node(self: *Compiler, value: *const Node, depth: usize) anyerror!Fragment {
        if (depth >= 64) return error.PatternTooDeep;
        switch (value.*) {
            .character, .beginning, .end => {
                const index = try self.emit(switch (value.*) {
                    .character => |mask| .{ .character = .{ .mask = mask } },
                    .beginning => .{ .beginning = 0 },
                    .end => .{ .end = 0 },
                    else => unreachable,
                });
                return .{ .start = index, .outputs = try self.output(index, false) };
            },
            .sequence => |nodes| {
                const index = try self.emit(.{ .jump = 0 });
                var result: Fragment = .{ .start = index, .outputs = try self.output(index, false) };
                for (nodes) |child| result = self.join(result, try self.node(child, depth + 1));
                return result;
            },
            .alternatives => |nodes| {
                var result = try self.node(nodes[0], depth + 1);
                for (nodes[1..]) |child| {
                    const right = try self.node(child, depth + 1);
                    result = .{ .start = try self.emit(.{ .split = .{ .left = result.start, .right = right.start } }), .outputs = try self.combine(result.outputs, right.outputs) };
                }
                return result;
            },
            .repeat => |repeat| {
                const index = try self.emit(.{ .jump = 0 });
                var result: Fragment = .{ .start = index, .outputs = try self.output(index, false) };
                for (0..repeat.minimum) |_| result = self.join(result, try self.node(repeat.node, depth + 1));
                const optional: usize = if (repeat.maximum) |maximum| maximum - repeat.minimum else 1;
                for (0..optional) |_| {
                    const child = try self.node(repeat.node, depth + 1);
                    const split = try self.emit(.{ .split = .{ .left = child.start } });
                    if (repeat.maximum == null) self.patch(child.outputs, split);
                    const outputs = if (repeat.maximum == null) try self.output(split, true) else try self.combine(child.outputs, try self.output(split, true));
                    result = self.join(result, .{ .start = split, .outputs = outputs });
                }
                return result;
            },
        }
    }
};

test "resource filters match complete names without backtracking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]struct { pattern: []const u8, input: []const u8, matches: bool }{
        .{ .pattern = "recipe/.*", .input = "recipe/wood/planks.json", .matches = true },
        .{ .pattern = "(?:recipe|loot_table)/[a-z_]+\\.json", .input = "loot_table/stone.json", .matches = true },
        .{ .pattern = "minecraft", .input = "otherminecraft", .matches = false },
        .{ .pattern = "^[a-z]{2,4}$", .input = "abcd", .matches = true },
        .{ .pattern = "^[a-z]{2,4}$", .input = "abcde", .matches = false },
        .{ .pattern = "(a+)+b", .input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .matches = false },
        .{ .pattern = "[^/]+/x?", .input = "test/", .matches = true },
    }) |case| {
        var pattern = try Pattern.compile(arena.allocator(), case.pattern);
        try std.testing.expectEqual(case.matches, pattern.matches(case.input));
    }
    try std.testing.expectError(error.UnsupportedPattern, Pattern.compile(arena.allocator(), "(?=test)test"));
}
