const ItemRegistry = @import("item_registry.zig").ItemRegistry;
const std = @import("std");
const content_values = @import("content_values.zig");
const ids = @import("content_ids.zig");
const Tags = @import("content_tags.zig").Tags;
const game_data = @import("game_data");
const item_data = @import("item_data.zig");
const Items = @import("items.zig").Items;
const Enchantments = @import("enchantments.zig").Enchantments;
const assert = std.debug.assert;

pub const maximum_drops = 64;
pub const Drop = struct { kind: u32, count: u16, components: []const item_data.Component = &.{} };
pub const Offset = struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };
pub const Neighbor = struct { offset: Offset, state: u16 };
pub const Context = struct {
    items: *const ItemRegistry,
    state: u16 = 0,
    player: ?u128 = null,
    location: ?struct { world: u32, x: f64, y: f64, z: f64 } = null,
    tool: ?item_data.View = null,
    neighbors: []const Neighbor = &.{},
    entity: bool = true,
    block_components: []const item_data.Component = &.{},
    dynamic: []const Drop = &.{},
    random: std.Random,
    scratch: *std.heap.FixedBufferAllocator,
};

pub const Kind = enum { condition, function, entry };

pub fn Handler(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        context: *anyopaque,
        offsets: []const Offset = &.{},
        vtable: *const VTable,
        pub fn cloneContent(self: Self, allocator: std.mem.Allocator) !Self {
            return self.vtable.copy(self.context, allocator);
        }
        pub const VTable = struct {
            copy: *const fn (*anyopaque, std.mem.Allocator) anyerror!Self,
            evaluate: switch (kind) {
                .condition => *const fn (*anyopaque, *const Context) anyerror!bool,
                .function => *const fn (*anyopaque, *const Context, *Stack) anyerror!void,
                .entry => *const fn (*anyopaque, *const Context, *Output) anyerror!void,
            },
        };
    };
}
pub const Binding = union(Kind) { condition: Handler(.condition), function: Handler(.function), entry: Handler(.entry) };
pub const Definition = struct { name: []const u8, table: TableDefinition };

/// Evaluation may be retried. Handlers only mutate their output, random source, and scratch.
pub fn Implementation(comptime Owner: type) type {
    const kind: Kind = Owner.kind;
    const Parameters = Owner.Parameters;
    const Bound = struct { owner: *const Owner, parameters: Parameters };
    return struct {
        const Self = @This();
        const binding_vtable: Handler(kind).VTable = .{ .copy = copy, .evaluate = switch (kind) {
            .condition => matches,
            .function => apply,
            .entry => generate,
        } };

        /// The owner and memory borrowed by parameters outlive the content using them.
        pub fn define(allocator: std.mem.Allocator, owner: *const Owner, parameters: Parameters) !Handler(kind) {
            const bound = try allocator.create(Bound);
            bound.* = .{ .owner = owner, .parameters = parameters };
            return .{ .context = bound, .offsets = if (@hasDecl(Owner, "offsets")) Owner.offsets else &.{}, .vtable = &binding_vtable };
        }

        fn copy(raw: *anyopaque, allocator: std.mem.Allocator) !Handler(kind) {
            const bound = state(raw);
            return Self.define(allocator, bound.owner, try content_values.clone(allocator, bound.parameters, 0));
        }

        fn state(raw: *anyopaque) *Bound {
            return @ptrCast(@alignCast(raw));
        }

        fn matches(raw: *anyopaque, context: *const Context) !bool {
            const bound = state(raw);
            return bound.owner.matches(&bound.parameters, context);
        }

        fn apply(raw: *anyopaque, context: *const Context, stack: *Stack) !void {
            const bound = state(raw);
            try bound.owner.apply(&bound.parameters, context, stack);
        }

        fn generate(raw: *anyopaque, context: *const Context, output: *Output) !void {
            const bound = state(raw);
            try bound.owner.generate(&bound.parameters, context, output);
        }
    };
}

pub const Output = struct {
    context: *const Context,
    buffer: []Drop,
    count: *usize,
    functions: []const Function,
    parents: []const []const Function,

    /// Applies the enclosing functions and splits stacks into the caller's bounded output.
    pub fn append(self: *Output, drop: Drop) !void {
        assert(self.count.* <= self.buffer.len);
        var stack: Stack = .{ .kind = drop.kind, .count = drop.count };
        for (drop.components) |component| try stack.put(component);
        try emit(self.context, self.buffer, self.count, stack, self.functions, self.parents);
        assert(self.count.* <= self.buffer.len);
    }
};

fn validateNumber(value: Number) !void {
    switch (value) {
        .constant => |constant| if (!std.math.isFinite(constant) or @abs(constant) > 1000000) return error.InvalidLootNumber,
        .uniform => |range| if (!std.math.isFinite(range.minimum) or !std.math.isFinite(range.maximum) or @abs(range.minimum) > 1000000 or range.minimum > range.maximum or @abs(range.maximum) > 1000000) return error.InvalidLootNumber,
        .binomial => |distribution| if (distribution.trials > 4096 or !std.math.isFinite(distribution.probability) or distribution.probability < 0 or distribution.probability > 1) return error.InvalidLootNumber,
    }
}

pub const TableDefinition = struct {
    pools: []const PoolDefinition,
    functions: []const FunctionDefinition = &.{},
    offsets: []const Offset = &.{},
};
pub const PoolDefinition = struct {
    conditions: []const ConditionDefinition = &.{},
    functions: []const FunctionDefinition = &.{},
    entries: []const EntryDefinition,
    rolls: Number = .{ .constant = 1 },
};
pub const EntryDefinition = struct {
    conditions: []const ConditionDefinition = &.{},
    functions: []const FunctionDefinition = &.{},
    weight: u32 = 1,
    kind: union(enum) {
        custom: Handler(.entry),
        item: u32,
        alternatives: []const EntryDefinition,
        group: []const EntryDefinition,
        sequence: []const EntryDefinition,
        tag: struct { name: []const u8, expand: bool },
        table: []const u8,
        inline_table: *const TableDefinition,
        empty,
        dynamic,
    },
};
pub const FunctionDefinition = struct { conditions: []const ConditionDefinition = &.{}, operation: Operation };
pub const ToolDefinition = struct { choices: []const []const u8 = &.{}, kinds: ?[]const u32 = null, enchantments: []const Enchantment = &.{}, components: []const item_data.Component = &.{} };
pub const ConditionDefinition = union(enum) {
    custom: Handler(.condition),
    all: []const ConditionDefinition,
    any: []const ConditionDefinition,
    inverted: *const ConditionDefinition,
    tool: ToolDefinition,
    state: State,
    chance: f32,
    table_bonus: struct { enchantment: []const u8, chances: []const f32 },
    location: struct { offset: Offset, state: State },
    entity,
    explosion,
};

pub const Number = union(enum) {
    constant: f32,
    uniform: struct { minimum: f32, maximum: f32 },
    binomial: struct { trials: u16, probability: f32 },

    fn sample(self: Number, random: std.Random) f32 {
        return switch (self) {
            .constant => |value| value,
            .uniform => |range| range.minimum + random.float(f32) * (range.maximum - range.minimum),
            .binomial => |distribution| blk: {
                var count: u16 = 0;
                for (0..distribution.trials) |_| count += @intFromBool(random.float(f32) < distribution.probability);
                break :blk @floatFromInt(count);
            },
        };
    }

    fn integer(self: Number, random: std.Random) i32 {
        if (self == .uniform) {
            const low: i32 = @intFromFloat(@floor(self.uniform.minimum));
            const high: i32 = @intFromFloat(@floor(self.uniform.maximum));
            return low + @as(i32, @intCast(random.uintLessThan(u32, @intCast(@as(i64, high) - low + 1))));
        }
        return @intFromFloat(@floor(self.sample(random)));
    }

    pub fn maximum(self: Number) f32 {
        return switch (self) {
            .constant => |value| value,
            .uniform => |value| value.maximum,
            .binomial => |value| @floatFromInt(value.trials),
        };
    }
};

pub const Enchantment = struct { names: []const []const u8, minimum: u32 = 0, maximum: u32 = 255 };
pub const Tool = struct { kinds: ?[]const u32 = null, enchantments: []const Enchantment = &.{}, components: []const item_data.Component = &.{} };
pub const State = struct { states: []const u16 };
pub const Condition = union(enum) {
    custom: Handler(.condition),
    all: []const Condition,
    any: []const Condition,
    inverted: *const Condition,
    tool: Tool,
    state: State,
    chance: f32,
    table_bonus: struct { enchantment: []const u8, chances: []const f32 },
    location: struct { offset: Offset, state: State },
    entity,
    explosion,

    fn matches(self: Condition, context: *const Context) anyerror!bool {
        return switch (self) {
            .custom => |handler| try handler.vtable.evaluate(handler.context, context),
            .all => |conditions| try matchesAll(conditions, context),
            .any => |conditions| blk: {
                for (conditions) |condition| if (try condition.matches(context)) break :blk true;
                break :blk false;
            },
            .inverted => |condition| !try condition.matches(context),
            .state => |predicate| std.mem.indexOfScalar(u16, predicate.states, context.state) != null,
            .location => |predicate| blk: {
                const state = for (context.neighbors) |neighbor| {
                    if (std.meta.eql(neighbor.offset, predicate.offset)) break neighbor.state;
                } else return error.LootContextMissing;
                break :blk std.mem.indexOfScalar(u16, predicate.state.states, state) != null;
            },
            .chance => |chance| context.random.float(f32) < chance,
            .table_bonus => |bonus| blk: {
                const enchantment_level = if (context.tool) |view| try Enchantments.level(view, bonus.enchantment) else 0;
                break :blk context.random.float(f32) < bonus.chances[@min(enchantment_level, bonus.chances.len - 1)];
            },
            .tool => |predicate| blk: {
                const view = context.tool orelse break :blk false;
                if (predicate.kinds) |kinds| if (std.mem.indexOfScalar(u32, kinds, view.kind) == null) break :blk false;
                for (predicate.enchantments) |enchantment| {
                    var accepted = false;
                    for (enchantment.names) |name| {
                        const enchantment_level = try Enchantments.level(view, name);
                        accepted = accepted or (enchantment_level >= enchantment.minimum and enchantment_level <= enchantment.maximum);
                    }
                    if (!accepted) break :blk false;
                }
                for (predicate.components) |component| {
                    const actual = view.get(component.key) orelse break :blk false;
                    if (actual.value == null or component.value == null or !std.mem.eql(u8, actual.value.?, component.value.?)) break :blk false;
                }
                break :blk true;
            },
            .entity => context.entity,
            .explosion => true,
        };
    }
};

pub const Operation = union(enum) {
    custom: Handler(.function),
    count: struct { value: Number, add: bool },
    limit: struct { minimum: ?Number, maximum: ?Number },
    bonus: struct { name: []const u8, formula: enum { ore, uniform, binomial }, multiplier: u16 = 1, extra: u16 = 0, probability: f32 = 0 },
    components: []const item_data.Component,
    copy_components: struct { include: ?[]const u64, exclude: []const u64 },
    copy_state: []const struct { state: u16, value: []const u8 },
    explosion,
};

pub const Function = struct {
    conditions: []const Condition = &.{},
    operation: Operation,

    fn apply(self: Function, context: *const Context, drop: *Stack) !void {
        if (!try matchesAll(self.conditions, context)) return;
        switch (self.operation) {
            .custom => |handler| try handler.vtable.evaluate(handler.context, context, drop),
            .count => |value| drop.count = @max(0, if (value.add) drop.count +| value.value.integer(context.random) else value.value.integer(context.random)),
            .limit => |limit| {
                if (limit.minimum) |bound| drop.count = @max(drop.count, bound.integer(context.random));
                if (limit.maximum) |bound| drop.count = @min(drop.count, bound.integer(context.random));
            },
            .bonus => |bonus| {
                const enchantment_level = if (context.tool) |view| try Enchantments.level(view, bonus.name) else 0;
                switch (bonus.formula) {
                    .ore => if (enchantment_level != 0) {
                        const extra = @as(i32, @intCast(context.random.uintLessThan(u32, enchantment_level + 2))) - 1;
                        drop.count *|= @max(0, extra) + 1;
                    },
                    .uniform => drop.count +|= @intCast(context.random.uintLessThan(u32, enchantment_level * bonus.multiplier + 1)),
                    .binomial => for (0..enchantment_level + bonus.extra) |_| {
                        drop.count +|= @intFromBool(context.random.float(f32) < bonus.probability);
                    },
                }
            },
            .components => |components| for (components) |component| try drop.put(component),
            .copy_components => |selection| for (context.block_components) |component| {
                if (selection.include) |keys| if (std.mem.indexOfScalar(u64, keys, component.key) == null) continue;
                if (std.mem.indexOfScalar(u64, selection.exclude, component.key) == null) try drop.put(component);
            },
            .copy_state => |values| for (values) |value| {
                if (value.state == context.state) {
                    try drop.put(.{ .key = item_data.key(.block_state), .value = value.value });
                    break;
                }
            },
            .explosion => {},
        }
    }
};

pub const Stack = struct {
    kind: u32,
    count: i32 = 1,
    values: [item_data.maximum_components]item_data.Component = undefined,
    length: usize = 0,

    pub fn get(self: *const Stack, key: u64) ?item_data.Component {
        assert(self.length <= self.values.len);
        for (self.values[0..self.length]) |component| if (component.key == key) return component;
        return null;
    }

    pub fn remove(self: *Stack, key: u64) void {
        assert(self.length <= self.values.len);
        for (self.values[0..self.length], 0..) |component, index| if (component.key == key) {
            self.length -= 1;
            self.values[index] = self.values[self.length];
            return;
        };
    }

    pub fn put(self: *Stack, component: item_data.Component) !void {
        assert(self.length <= self.values.len);
        for (self.values[0..self.length]) |*previous| if (previous.key == component.key) {
            previous.* = component;
            return;
        };
        if (self.length == self.values.len) return error.LootCapacity;
        self.values[self.length] = component;
        self.length += 1;
    }
};

pub const Entry = struct {
    conditions: []const Condition = &.{},
    functions: []const Function = &.{},
    weight: u32 = 1,
    kind: union(enum) { custom: Handler(.entry), item: u32, alternatives: []const Entry, group: []const Entry, sequence: []const Entry, tag: struct { values: []const u32, expand: bool }, table: *const Table, empty, dynamic },

    fn expand(self: *const Entry, context: *const Context, selected: *std.ArrayList(Selected)) anyerror!bool {
        if (!try matchesAll(self.conditions, context)) return false;
        switch (self.kind) {
            .alternatives => |children| {
                for (children) |*child| if (try child.expand(context, selected)) return true;
                return false;
            },
            .sequence => |children| {
                for (children) |*child| if (!try child.expand(context, selected)) return false;
            },
            .group => |children| for (children) |*child| {
                _ = try child.expand(context, selected);
            },
            .tag => |tag| if (tag.expand) {
                for (tag.values) |value| try selected.append(context.scratch.allocator(), .{ .entry = self, .item = value });
            } else try selected.append(context.scratch.allocator(), .{ .entry = self }),
            else => try selected.append(context.scratch.allocator(), .{ .entry = self }),
        }
        if (selected.items.len > 4096) return error.LootCapacity;
        return true;
    }
};
const Selected = struct { entry: *const Entry, item: ?u32 = null };
pub const Pool = struct { conditions: []const Condition = &.{}, functions: []const Function = &.{}, entries: []const Entry, rolls: Number = .{ .constant = 1 } };
pub const Table = struct {
    pools: []const Pool,
    functions: []const Function = &.{},
    offsets: []const Offset = &.{},

    // Output components borrow the input and scratch. Failed evaluation still consumes random values.
    pub fn evaluate(self: *const Table, context: *const Context, output: []Drop) ![]const Drop {
        assert(context.neighbors.len >= self.offsets.len);
        var count: usize = 0;
        try self.generate(context, output, &count, &.{}, 0);
        return output[0..count];
    }

    fn generate(self: *const Table, context: *const Context, output: []Drop, count: *usize, parents: []const []const Function, depth: usize) anyerror!void {
        if (depth >= 64) return error.LootCapacity;
        for (self.pools) |pool| {
            if (!try matchesAll(pool.conditions, context)) continue;
            var selected: std.ArrayList(Selected) = .empty;
            defer selected.deinit(context.scratch.allocator());
            const rolls = pool.rolls.integer(context.random);
            var chains: [192][]const Function = undefined;
            if (parents.len + 2 > chains.len) return error.LootDepthLimit;
            chains[0] = pool.functions;
            chains[1] = self.functions;
            @memcpy(chains[2..][0..parents.len], parents);
            const inherited = chains[0 .. parents.len + 2];
            for (0..@intCast(@max(0, rolls))) |_| {
                selected.clearRetainingCapacity();
                for (pool.entries) |*entry| _ = try entry.expand(context, &selected);
                var weight: u64 = 0;
                for (selected.items) |candidate| weight += candidate.entry.weight;
                if (weight == 0) continue;
                const candidate = if (selected.items.len == 1) selected.items[0] else choice: {
                    var choice = context.random.uintLessThan(u64, weight);
                    for (selected.items) |entry| {
                        if (choice < entry.entry.weight) break :choice entry;
                        choice -= entry.entry.weight;
                    }
                    unreachable;
                };
                switch (candidate.entry.kind) {
                    .custom => |handler| {
                        var generator: Output = .{ .context = context, .buffer = output, .count = count, .functions = candidate.entry.functions, .parents = inherited };
                        try handler.vtable.evaluate(handler.context, context, &generator);
                    },
                    .item => |kind| try emit(context, output, count, .{ .kind = kind }, candidate.entry.functions, inherited),
                    .tag => |tag| if (candidate.item) |kind| {
                        try emit(context, output, count, .{ .kind = kind }, candidate.entry.functions, inherited);
                    } else for (tag.values) |kind| try emit(context, output, count, .{ .kind = kind }, candidate.entry.functions, inherited),
                    .table => |table| {
                        var nested: [192][]const Function = undefined;
                        if (inherited.len == nested.len) return error.LootDepthLimit;
                        nested[0] = candidate.entry.functions;
                        @memcpy(nested[1..][0..inherited.len], inherited);
                        try table.generate(context, output, count, nested[0 .. inherited.len + 1], depth + 1);
                    },
                    .dynamic => for (context.dynamic) |drop| {
                        var draft: Stack = .{ .kind = drop.kind, .count = drop.count };
                        for (drop.components) |component| try draft.put(component);
                        try emit(context, output, count, draft, candidate.entry.functions, inherited);
                    },
                    .empty => {},
                    else => unreachable,
                }
            }
        }
    }
};

fn emit(context: *const Context, output: []Drop, count: *usize, initial: Stack, functions: []const Function, parents: []const []const Function) !void {
    var draft = initial;
    for (functions) |function| try function.apply(context, &draft);
    for (parents) |chain| for (chain) |function| try function.apply(context, &draft);
    if (draft.kind >= game_data.registry.items.len) return error.UnknownLootItem;
    if (draft.length > draft.values.len) return error.LootCapacity;
    if (draft.count <= 0) return;
    const maximum = try context.items.maximumDefinition(draft.kind, draft.values[0..draft.length]);
    const components = try context.scratch.allocator().dupe(item_data.Component, draft.values[0..draft.length]);
    while (draft.count > 0) {
        if (count.* == output.len) return error.LootCapacity;
        const amount: u16 = @intCast(@min(draft.count, maximum));
        output[count.*] = .{ .kind = draft.kind, .count = amount, .components = components };
        count.* += 1;
        draft.count -= amount;
    }
}

fn matchesAll(conditions: []const Condition, context: *const Context) anyerror!bool {
    for (conditions) |condition| if (!try condition.matches(context)) return false;
    return true;
}

pub const Tables = struct {
    blocks: []const ?*const Table,
    named: std.StringHashMapUnmanaged(*const Table) = .empty,

    pub fn get(self: *const Tables, name: []const u8) ?*const Table {
        return self.named.get(name);
    }

    pub fn prepare(allocator: std.mem.Allocator, temporary: std.mem.Allocator, item_tags: *const Tags, definitions: []const Definition) !Tables {
        var compiler: Preparation = .{ .allocator = allocator, .temporary = temporary, .tags = item_tags };
        for (definitions) |*definition| {
            if (!ids.validName(definition.name)) return error.InvalidLootTable;
            try compiler.sources.put(temporary, definition.name, &definition.table);
        }
        const names = try temporary.alloc([]const u8, compiler.sources.count());
        var iterator = compiler.sources.keyIterator();
        var count: usize = 0;
        while (iterator.next()) |name| {
            names[count] = name.*;
            count += 1;
        }
        std.mem.sort([]const u8, names, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names) |name| _ = try compiler.table(name, 0);
        const blocks = try allocator.alloc(?*const Table, game_data.registry.blocks.len);
        for (blocks, game_data.registry.blocks) |*table, block| {
            const state_name = game_data.registry.blockStateName(@intCast(block.default_state)).?;
            const name = state_name[0 .. std.mem.indexOfScalar(u8, state_name, '[') orelse state_name.len];
            const colon = std.mem.indexOfScalar(u8, name, ':').?;
            const location = try std.fmt.allocPrint(temporary, "{s}:blocks/{s}", .{ name[0..colon], name[colon + 1 ..] });
            table.* = compiler.tables.get(location) orelse null;
        }
        var named: std.StringHashMapUnmanaged(*const Table) = .empty;
        try named.ensureTotalCapacity(allocator, compiler.tables.count());
        var tables = compiler.tables.iterator();
        while (tables.next()) |entry| named.putAssumeCapacityNoClobber(try allocator.dupe(u8, entry.key_ptr.*), entry.value_ptr.* orelse return error.LootTableCycle);
        return .{ .blocks = blocks, .named = named };
    }
};

const Preparation = struct {
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    tags: *const Tags,
    sources: std.StringHashMapUnmanaged(*const TableDefinition) = .empty,
    tables: std.StringHashMapUnmanaged(?*const Table) = .empty,
    offsets: std.ArrayList(Offset) = .empty,
    native_stack: std.ArrayList(*const TableDefinition) = .empty,

    fn table(self: *Preparation, name: []const u8, depth: usize) anyerror!*const Table {
        if (depth >= 64) return error.LootTableCycle;
        if (self.tables.get(name)) |previous| return previous orelse error.LootTableCycle;
        const source = self.sources.get(name) orelse return error.UnknownLootTable;
        try self.tables.put(self.temporary, name, null);
        const result = try self.native(source, depth + 1);
        self.tables.getPtr(name).?.* = result;
        return result;
    }
    fn native(self: *Preparation, source: *const TableDefinition, depth: usize) anyerror!*const Table {
        if (depth >= 64 or std.mem.indexOfScalar(*const TableDefinition, self.native_stack.items, source) != null) return error.LootTableCycle;
        try self.native_stack.append(self.temporary, source);
        defer _ = self.native_stack.pop();
        const previous_offsets = self.offsets;
        self.offsets = .empty;
        defer self.offsets = previous_offsets;
        for (source.offsets) |offset| try self.addOffset(offset);
        const table_functions = try self.prepareFunctions(source.functions, depth + 1);
        const pools = try self.allocator.alloc(Pool, source.pools.len);
        for (source.pools, pools) |input, *pool| {
            try validateNumber(input.rolls);
            if (input.rolls.maximum() > 1024) return error.LootRollLimit;
            pool.* = .{ .rolls = input.rolls, .conditions = try self.prepareConditions(input.conditions, depth + 1), .functions = try self.prepareFunctions(input.functions, depth + 1), .entries = try self.nativeEntries(input.entries, depth + 1) };
        }
        const result = try self.allocator.create(Table);
        result.* = .{ .pools = pools, .functions = table_functions, .offsets = try self.allocator.dupe(Offset, self.offsets.items) };
        return result;
    }
    fn nativeEntries(self: *Preparation, sources: []const EntryDefinition, depth: usize) anyerror![]const Entry {
        if (depth >= 64) return error.LootDepthLimit;
        const entries = try self.allocator.alloc(Entry, sources.len);
        for (sources, entries) |input, *entry| {
            entry.* = .{ .conditions = try self.prepareConditions(input.conditions, depth + 1), .functions = try self.prepareFunctions(input.functions, depth + 1), .weight = input.weight, .kind = .empty };
            switch (input.kind) {
                .custom => |handler| {
                    for (handler.offsets) |offset| try self.addOffset(offset);
                    entry.kind = .{ .custom = handler };
                },
                .item => |kind| {
                    if (kind >= game_data.registry.items.len) return error.UnknownLootItem;
                    entry.kind = .{ .item = kind };
                },
                .table => |name| {
                    const nested = try self.table(name, depth + 1);
                    entry.kind = .{ .table = nested };
                    for (nested.offsets) |offset| try self.addOffset(offset);
                },
                .inline_table => |source| {
                    const nested = try self.native(source, depth + 1);
                    entry.kind = .{ .table = nested };
                    for (nested.offsets) |offset| try self.addOffset(offset);
                },
                .alternatives, .group, .sequence => |children| {
                    const compiled = try self.nativeEntries(children, depth + 1);
                    entry.kind = switch (input.kind) {
                        .alternatives => .{ .alternatives = compiled },
                        .group => .{ .group = compiled },
                        .sequence => .{ .sequence = compiled },
                        else => unreachable,
                    };
                },
                .tag => |tag| entry.kind = .{ .tag = .{ .values = self.tags.members(self.tags.find(tag.name) orelse return error.UnknownLootTag), .expand = tag.expand } },
                .empty => entry.kind = .empty,
                .dynamic => entry.kind = .dynamic,
            }
        }
        return entries;
    }
    fn prepareConditions(self: *Preparation, sources: []const ConditionDefinition, depth: usize) anyerror![]const Condition {
        if (depth >= 64) return error.LootDepthLimit;
        const conditions = try self.allocator.alloc(Condition, sources.len);
        for (sources, conditions) |source, *condition| switch (source) {
            .custom => |handler| {
                for (handler.offsets) |offset| try self.addOffset(offset);
                condition.* = .{ .custom = handler };
            },
            .all, .any => |children| {
                const compiled = try self.prepareConditions(children, depth + 1);
                condition.* = if (source == .all) .{ .all = compiled } else .{ .any = compiled };
            },
            .inverted => |child| condition.* = .{ .inverted = &(try self.prepareConditions(child[0..1], depth + 1))[0] },
            .tool => |tool| {
                var kinds: std.ArrayList(u32) = .empty;
                for (tool.choices) |name| {
                    if (std.mem.startsWith(u8, name, "#")) {
                        try kinds.appendSlice(self.temporary, self.tags.members(self.tags.find(name[1..]) orelse return error.UnknownLootTag));
                    } else try kinds.append(self.temporary, @intCast(game_data.registry.itemId(name) orelse return error.UnknownLootItem));
                }
                condition.* = .{ .tool = .{ .kinds = if (tool.choices.len > 0) try self.allocator.dupe(u32, kinds.items) else tool.kinds, .enchantments = tool.enchantments, .components = tool.components } };
            },
            .location => |value| {
                try self.addOffset(value.offset);
                condition.* = .{ .location = .{ .offset = value.offset, .state = value.state } };
            },
            .chance => |chance| {
                if (!std.math.isFinite(chance) or chance < 0 or chance > 1) return error.InvalidLootCondition;
                condition.* = .{ .chance = chance };
            },
            .table_bonus => |bonus| {
                if (bonus.chances.len == 0) return error.InvalidLootCondition;
                for (bonus.chances) |chance| if (!std.math.isFinite(chance) or chance < 0 or chance > 1) return error.InvalidLootCondition;
                condition.* = .{ .table_bonus = .{ .enchantment = bonus.enchantment, .chances = bonus.chances } };
            },
            .state => |state_value| condition.* = .{ .state = state_value },
            .entity => condition.* = .entity,
            .explosion => condition.* = .explosion,
        };
        return conditions;
    }
    fn prepareFunctions(self: *Preparation, sources: []const FunctionDefinition, depth: usize) anyerror![]const Function {
        if (depth >= 64) return error.LootDepthLimit;
        const functions = try self.allocator.alloc(Function, sources.len);
        for (sources, functions) |source, *function| {
            function.* = .{ .conditions = try self.prepareConditions(source.conditions, depth + 1), .operation = source.operation };
            switch (function.operation) {
                .custom => |handler| for (handler.offsets) |offset| try self.addOffset(offset),
                .count => |count| try validateNumber(count.value),
                .limit => |limit| {
                    if (limit.minimum) |minimum| try validateNumber(minimum);
                    if (limit.maximum) |maximum| try validateNumber(maximum);
                },
                .bonus => |bonus| if (!std.math.isFinite(bonus.probability) or bonus.probability < 0 or bonus.probability > 1 or bonus.extra > 4096 or bonus.multiplier > 4096) return error.InvalidLootFunction,
                else => {},
            }
        }
        return functions;
    }
    fn addOffset(self: *Preparation, offset: Offset) !void {
        for (self.offsets.items) |previous| if (std.meta.eql(previous, offset)) return;
        if (self.offsets.items.len == 16) return error.LootContextLimit;
        try self.offsets.append(self.temporary, offset);
    }
};

test "loot rolls independently expand conditional entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try ItemRegistry.init(arena.allocator(), .{});
    const entry: Entry = .{ .conditions = &.{.{ .chance = 0.5 }}, .functions = &.{}, .kind = .{ .item = @intCast(game_data.registry.itemId("minecraft:diamond").?) } };
    const table: Table = .{ .pools = &.{.{ .conditions = &.{}, .functions = &.{}, .entries = &.{entry}, .rolls = .{ .constant = 16 } }}, .functions = &.{}, .offsets = &.{} };
    var random: std.Random.DefaultPrng = .init(42);
    var reference: std.Random.DefaultPrng = .init(42);
    var expected: usize = 0;
    for (0..16) |_| expected += @intFromBool(reference.random().float(f32) < 0.5);
    try std.testing.expect(expected > 0 and expected < 16);
    var buffer: [8192]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    var output: [16]Drop = undefined;
    const context: Context = .{ .items = items, .state = 0, .random = random.random(), .scratch = &scratch };
    try std.testing.expectEqual(expected, (try table.evaluate(&context, &output)).len);
    try std.testing.expectEqual(reference.next(), random.next());
}

test "loot component copying applies include and exclude selections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try ItemRegistry.init(arena.allocator(), .{});
    var random: std.Random.DefaultPrng = .init(0);
    var buffer: [128]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    const components = [_]item_data.Component{ .{ .key = 1, .value = "a" }, .{ .key = 2, .value = "b" }, .{ .key = 3, .value = "c" } };
    const context: Context = .{ .items = items, .state = 0, .block_components = &components, .random = random.random(), .scratch = &scratch };
    var draft: Stack = .{ .kind = 0 };
    try (Function{ .operation = .{ .copy_components = .{ .include = null, .exclude = &.{2} } } }).apply(&context, &draft);
    try std.testing.expectEqual(@as(usize, 2), draft.length);
    try std.testing.expectEqual(@as(u64, 1), draft.values[0].key);
    try std.testing.expectEqual(@as(u64, 3), draft.values[1].key);
    draft.length = 0;
    try (Function{ .operation = .{ .copy_components = .{ .include = &.{ 1, 2 }, .exclude = &.{1} } } }).apply(&context, &draft);
    try std.testing.expectEqual(@as(usize, 1), draft.length);
    try std.testing.expectEqual(@as(u64, 2), draft.values[0].key);
}
