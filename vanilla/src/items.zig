const std = @import("std");
const inventories = @import("inventories");
const game_data = @import("game_data");
const data = @import("item_data.zig");
const components = @import("item_components.zig");

pub const Items = struct {
    pub const id = "minecraft:items";
    pub const Configuration = struct { maximum_components: usize = 32 };
    pub const Dependencies = struct { inventories: *inventories.Inventories };
    pub const View = data.View;
    pub const Component = data.Component;
    pub const key = data.key;

    deps: Dependencies,
    components: components.Components,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Items {
        if (config.maximum_components == 0 or config.maximum_components > data.maximum_components) return error.InvalidConfiguration;
        const self = try allocator.create(Items);
        self.* = .{ .deps = deps, .components = try .init(allocator, config.maximum_components) };
        return self;
    }

    pub fn define(self: *Items, name: []const u8) !inventories.ItemId {
        const kind_id = game_data.registry.itemId(name) orelse return error.UnknownItem;
        var bytes: [10]u8 = undefined;
        return self.deps.inventories.defineItem(try data.encode(&bytes, @intCast(kind_id), &.{}));
    }

    pub fn kind(self: *Items, stack: inventories.Stack) !u32 {
        const lease = try self.deps.inventories.acquireItem(stack.item);
        defer lease.release();
        return (try View.parse(lease.read().?)).kind;
    }

    pub fn stackLimit(self: *Items, stack: inventories.Stack) !u16 {
        const lease = try self.deps.inventories.acquireItem(stack.item);
        defer lease.release();
        return maximum(try View.parse(lease.read().?));
    }

    pub fn maximum(view: View) !u16 {
        if (view.kind >= game_data.registry.items.len) return error.UnknownItem;
        const component = view.get(key(.max_stack_size)) orelse return game_data.registry.items[view.kind].stack_size;
        const bytes = component.value orelse return error.InvalidStackLimit;
        const count, const rest = try game_data.encoding.read_varint(bytes);
        if (rest.len != 0 or count <= 0 or count > 99) return error.InvalidStackLimit;
        return @intCast(count);
    }
};
