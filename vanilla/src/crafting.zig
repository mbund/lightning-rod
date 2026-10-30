const content_values = @import("content_values.zig");
const Tags = @import("content_tags.zig").Tags;
const minecraft = @import("minecraft_model");
const std = @import("std");
const inventories = @import("inventories");
const item_data = @import("item_data.zig");
const components = @import("item_components.zig");
const recipes = @import("recipes.zig");
const custom_data = @import("custom_data.zig");
const assert = std.debug.assert;

pub const maximum_crafts = 99;
pub const maximum_inputs = 9;
pub const Draft = struct { kind: u32, count: u16, components: []const item_data.Component = &.{} };
pub const Input = struct {
    stack: inventories.Stack,
    view: item_data.View,

    pub fn customData(self: Input) !?custom_data.Compound {
        return try custom_data.Compound.init(self.view.value(.custom_data) orelse return null);
    }
};
pub const Plan = struct {
    result: Draft,
    consume: [9]u16 = @splat(0),
    remainders: [9]?Draft = @splat(null),
    repeatable: bool = false,
    completion: ?Completion = null,
};

pub const Location = union(enum) {
    player: struct { world: u32, position: minecraft.Position },
    block: struct { world: u32, position: minecraft.BlockPosition },
};

pub const Context = struct {
    player: u128,
    location: Location,
    input: []const ?Input,
    width: usize,
    tags: *const Tags,
    scratch: *std.heap.FixedBufferAllocator,
    pending: []const Completion = &.{},

    pub fn result(self: *const Context, kind: u32, count: u16) !DraftBuilder {
        if (count == 0 or count > 99) return error.InvalidRecipeResult;
        return .{ .kind = kind, .count = count, .components = try self.scratch.allocator().alloc(item_data.Component, item_data.maximum_components) };
    }
};

pub const DraftBuilder = struct {
    kind: u32,
    count: u16,
    components: []item_data.Component,
    length: usize = 0,

    pub fn copyComponents(self: *DraftBuilder, input: item_data.View) !void {
        var iterator = input.iterator();
        while (iterator.next()) |component| try self.put(component);
    }

    pub fn set(self: *DraftBuilder, comptime tag: components.Dispatch.Tag, bytes: ?[]const u8) !void {
        try self.put(.{ .key = item_data.key(tag), .value = bytes });
    }

    fn put(self: *DraftBuilder, component: item_data.Component) !void {
        for (self.components[0..self.length]) |*previous| {
            if (previous.key != component.key) continue;
            previous.* = component;
            return;
        }
        if (self.length == self.components.len) return error.ItemTooLarge;
        self.components[self.length] = component;
        self.length += 1;
    }

    pub fn finish(self: *const DraftBuilder) Draft {
        return .{ .kind = self.kind, .count = self.count, .components = self.components[0..self.length] };
    }
};

pub const Binding = struct {
    context: *anyopaque,
    owner: usize,
    vtable: *const VTable,
    minimum_inputs: usize = 1,
    maximum_inputs: usize = 9,
    display: ?recipes.Display = null,

    pub const VTable = struct {
        copy: *const fn (*anyopaque, std.mem.Allocator) anyerror!Binding,
        prepare: *const fn (*anyopaque, *const Context) anyerror!?Plan,
        validate: ?*const fn (*anyopaque, []const Completion) bool,
        complete: ?*const fn (*anyopaque, []const Completion) void,
    };

    pub fn cloneContent(self: Binding, allocator: std.mem.Allocator) !Binding {
        return self.vtable.copy(self.context, allocator);
    }

    pub fn prepare(self: Binding, context: *const Context) !?Plan {
        assert((context.width == 2 or context.width == 3) and context.input.len == context.width * context.width);
        assert(self.minimum_inputs <= self.maximum_inputs and self.maximum_inputs <= maximum_inputs);
        var input_count: usize = 0;
        for (context.input) |input| input_count += @intFromBool(input != null);
        if (input_count < self.minimum_inputs or input_count > self.maximum_inputs) return null;
        const start = context.scratch.end_index;
        const plan = try self.vtable.prepare(self.context, context) orelse {
            context.scratch.end_index = start;
            return null;
        };
        if (plan.result.count == 0 or plan.result.count > 99) return error.InvalidRecipeResult;
        for (plan.consume, plan.remainders, 0..) |count, remainder, index| {
            if (index >= context.input.len) {
                if (count != 0 or remainder != null) return error.InvalidRecipeConsumption;
                continue;
            }
            const available = if (context.input[index]) |input| input.stack.count else 0;
            if (count > available) return error.InvalidRecipeConsumption;
            if (remainder) |draft| if (draft.count == 0 or draft.count > 99) return error.InvalidRecipeResult;
        }
        return plan;
    }
};

pub const Completion = struct {
    binding: Binding,
    bytes: [64]u8,
    group: u8 = 0,
    ordinal: u8 = 0,
};
pub const Group = struct { owner: usize, vtable: *const Binding.VTable };

pub fn Implementation(comptime Owner: type) type {
    const Parameters = Owner.Parameters;
    const Effect = if (@hasDecl(Owner, "Completion")) Owner.Completion else void;
    comptime {
        if (@sizeOf(Effect) > 64) @compileError("recipe completion values must fit in 64 bytes");
        requireValue(Effect);
        if (Effect != void and (!@hasDecl(Owner, "validate") or !@hasDecl(Owner, "complete")))
            @compileError("stateful recipes must validate and complete a batch");
    }
    const State = struct { owner: *Owner, parameters: Parameters };
    return struct {
        pub const Prepared = if (Effect == void) struct { plan: Plan } else struct { plan: Plan, completion: Effect };
        const Self = @This();
        const binding_vtable: Binding.VTable = .{ .copy = copy, .prepare = @This().prepare, .validate = if (Effect == void) null else @This().validate, .complete = if (Effect == void) null else @This().complete };

        /// The owner and any memory borrowed by parameters outlive the binding.
        pub fn define(allocator: std.mem.Allocator, owner: *Owner, parameters: Parameters) !Binding {
            const state = try allocator.create(State);
            state.* = .{ .owner = owner, .parameters = parameters };
            return .{ .display = if (@hasDecl(Owner, "display")) try owner.display(allocator, &state.parameters) else null, .context = state, .owner = @intFromPtr(owner), .vtable = &binding_vtable, .minimum_inputs = if (@hasDecl(Owner, "minimum_inputs")) Owner.minimum_inputs else 1, .maximum_inputs = if (@hasDecl(Owner, "maximum_inputs")) Owner.maximum_inputs else 9 };
        }

        fn copy(raw: *anyopaque, allocator: std.mem.Allocator) !Binding {
            const state = castState(raw);
            return Self.define(allocator, state.owner, try content_values.clone(allocator, state.parameters, 0));
        }

        fn castState(raw: *anyopaque) *State {
            return @ptrCast(@alignCast(raw));
        }

        fn prepare(raw: *anyopaque, context: *const Context) !?Plan {
            const bound = castState(raw);
            const prepared: Prepared = try bound.owner.prepare(&bound.parameters, context) orelse return null;
            var plan = prepared.plan;
            if (Effect != void) {
                assert(!plan.repeatable);
                var completion: Completion = .{ .binding = .{ .context = raw, .owner = @intFromPtr(bound.owner), .vtable = &binding_vtable }, .bytes = undefined };
                @memcpy(completion.bytes[0..@sizeOf(Effect)], std.mem.asBytes(&prepared.completion));
                plan.completion = completion;
            }
            return plan;
        }

        fn collect(raw: *anyopaque, completions: []const Completion, output: []Effect) []const Effect {
            assert(completions.len <= maximum_crafts and output.len >= completions.len);
            var count: usize = 0;
            const identity = @intFromPtr(castState(raw).owner);
            for (completions) |completion| {
                assert(completion.binding.vtable == &binding_vtable and completion.binding.owner == identity);
                output[count] = std.mem.bytesToValue(Effect, completion.bytes[0..@sizeOf(Effect)]);
                count += 1;
            }
            assert(count > 0);
            return output[0..count];
        }

        fn validate(raw: *anyopaque, completions: []const Completion) bool {
            var values: [maximum_crafts]Effect = undefined;
            return castState(raw).owner.validate(collect(raw, completions, &values));
        }

        fn complete(raw: *anyopaque, completions: []const Completion) void {
            var values: [maximum_crafts]Effect = undefined;
            castState(raw).owner.complete(collect(raw, completions, &values));
        }

        pub const Pending = struct {
            owner: usize,
            entries: []const Completion,
            index: usize = 0,

            pub fn next(self: *Pending) ?Effect {
                while (self.index < self.entries.len) {
                    const entry = self.entries[self.index];
                    self.index += 1;
                    if (entry.binding.vtable != &binding_vtable or entry.binding.owner != self.owner) continue;
                    return std.mem.bytesToValue(Effect, entry.bytes[0..@sizeOf(Effect)]);
                }
                return null;
            }
        };

        pub fn pending(owner: *Owner, context: *const Context) Pending {
            return .{ .owner = @intFromPtr(owner), .entries = context.pending };
        }
    };
}

pub fn validate(completions: []const Completion) bool {
    assert(completions.len <= maximum_crafts);
    var cursor: usize = 0;
    while (cursor < completions.len) {
        const start = cursor;
        const binding = completions[start].binding;
        while (cursor < completions.len and completions[cursor].group == completions[start].group) cursor += 1;
        if (binding.vtable.validate) |check| if (!check(binding.context, completions[start..cursor])) return false;
    }
    return true;
}

pub fn complete(completions: []const Completion) void {
    assert(completions.len <= maximum_crafts);
    var cursor: usize = 0;
    while (cursor < completions.len) {
        const start = cursor;
        const binding = completions[start].binding;
        while (cursor < completions.len and completions[cursor].group == completions[start].group) cursor += 1;
        if (binding.vtable.complete) |apply| apply(binding.context, completions[start..cursor]);
    }
}

fn requireValue(comptime Value: type) void {
    switch (@typeInfo(Value)) {
        .void, .bool, .int, .float, .@"enum" => {},
        .array => |array| requireValue(array.child),
        .optional => |optional| requireValue(optional.child),
        .@"struct" => |structure| for (structure.fields) |field| requireValue(field.type),
        .@"union" => |value| {
            if (value.tag_type == null) @compileError("recipe completion unions must be tagged");
            for (value.fields) |field| requireValue(field.type);
        },
        else => @compileError("recipe completion values cannot borrow pointers or slices"),
    }
}
