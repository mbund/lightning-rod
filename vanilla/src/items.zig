const RegistryIdentity = @import("registry_identity.zig").RegistryIdentity;
const std = @import("std");
const inventories = @import("inventories");
const game_data = @import("game_data");
const records = @import("records");
const data = @import("item_data.zig");
const components = @import("item_components.zig");

pub const Items = struct {
    pub const id = "minecraft:items";
    pub const Configuration = struct { maximum_components: usize = 32 };
    pub const Dependencies = struct { registry_identity: *RegistryIdentity, inventories: *inventories.Inventories };
    pub const View = data.View;
    pub const Component = data.Component;
    pub const key = data.key;

    deps: Dependencies,
    components: components.Components,
    views: []Cached,

    const Cached = struct {
        generation: u64 = 0,
        revision: u64 = 0,
        view: View = undefined,
    };

    pub const Prepared = struct {
        lease: records.Cache.Lease,
        view: View,

        pub fn release(self: Prepared) void {
            self.lease.release();
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Items {
        if (config.maximum_components == 0 or config.maximum_components > data.maximum_components) return error.InvalidConfiguration;
        const self = try allocator.create(Items);
        self.* = .{ .deps = deps, .components = try .init(allocator, config.maximum_components), .views = try allocator.alloc(Cached, deps.inventories.items.entries.len) };
        @memset(self.views, .{});
        return self;
    }

    pub fn define(self: *Items, name: []const u8) !inventories.ItemId {
        const kind_id = game_data.registry.itemId(name) orelse return error.UnknownItem;
        return self.defineKind(@intCast(kind_id));
    }

    pub fn defineKind(self: *Items, kind_id: u32) !inventories.ItemId {
        if (kind_id >= game_data.registry.items.len) return error.UnknownItem;
        return data.define(self.deps.inventories, kind_id, &.{});
    }

    pub fn acquireMany(self: *Items, stacks: []const inventories.Stack, output: []Prepared) !void {
        return self.prepareBatch(128, stacks, output);
    }

    fn prepareBatch(self: *Items, comptime capacity: usize, stacks: []const inventories.Stack, output: []Prepared) !void {
        if (stacks.len != output.len or stacks.len > capacity) return error.WorkingSetTooLarge;
        if (stacks.len == 0) {
            if (self.deps.inventories.items.failed) return error.FailedTransaction;
            return;
        }
        var ids: [capacity]inventories.ItemId = undefined;
        var leases: [capacity]records.Cache.Lease = undefined;
        for (stacks, ids[0..stacks.len]) |stack, *item| item.* = stack.item;
        if (comptime capacity == 1) {
            leases[0] = try self.deps.inventories.acquireItem(ids[0]);
        } else try self.deps.inventories.acquireItems(ids[0..stacks.len], leases[0..stacks.len]);
        errdefer for (leases[0..stacks.len]) |lease| lease.release();
        for (output, leases[0..stacks.len]) |*prepared, lease| {
            const cached = &self.views[lease.index];
            const revision = lease.revision();
            if (cached.generation != lease.generation or cached.revision != revision) {
                const view = try View.parse(lease.read().?);
                cached.* = .{ .generation = lease.generation, .revision = revision, .view = view };
            }
            prepared.* = .{ .lease = lease, .view = cached.view };
        }
    }

    pub fn acquire(self: *Items, stack: inventories.Stack) !Prepared {
        var prepared: [1]Prepared = undefined;
        try self.prepareBatch(1, &.{stack}, &prepared);
        return prepared[0];
    }

    pub fn kind(self: *Items, stack: inventories.Stack) !u32 {
        const prepared = try self.acquire(stack);
        defer prepared.release();
        return prepared.view.kind;
    }

    pub fn stackLimit(self: *Items, stack: inventories.Stack) !u16 {
        const prepared = try self.acquire(stack);
        defer prepared.release();
        return maximum(prepared.view);
    }

    pub fn stackLimits(self: *Items, stacks: []const inventories.Stack, limits: []u16) !void {
        if (stacks.len != limits.len or stacks.len > 128) return error.WorkingSetTooLarge;
        std.debug.assert(self.views.len > 0);
        var order: [128]u8 = undefined;
        for (order[0..stacks.len], 0..) |*index, at| index.* = @intCast(at);
        std.mem.sort(u8, order[0..stacks.len], stacks, struct {
            fn less(values: []const inventories.Stack, a: u8, b: u8) bool {
                return std.mem.order(u8, &values[a].item, &values[b].item) == .lt;
            }
        }.less);
        var cursor: usize = 0;
        while (cursor < stacks.len) {
            var unique: [128]inventories.Stack = undefined;
            var ends: [128]usize = undefined;
            var prepared: [128]Prepared = undefined;
            var count: usize = 0;
            const begin = cursor;
            while (cursor < stacks.len and count < @min(unique.len, self.views.len)) {
                const stack = stacks[order[cursor]];
                unique[count] = stack;
                cursor += 1;
                while (cursor < stacks.len and inventories.Stack.sameItem(stack, stacks[order[cursor]])) cursor += 1;
                ends[count] = cursor;
                count += 1;
            }
            try self.acquireMany(unique[0..count], prepared[0..count]);
            defer for (prepared[0..count]) |value| value.release();
            var at = begin;
            for (prepared[0..count], ends[0..count]) |value, end| {
                const limit = try maximum(value.view);
                for (order[at..end]) |index| limits[index] = limit;
                at = end;
            }
        }
    }

    pub fn maximum(view: View) !u16 {
        return maximumComponent(view.kind, view.get(key(.max_stack_size)));
    }

    pub fn maximumDefinition(kind_id: u32, entries: []const Component) !u16 {
        for (entries) |component| if (component.key == key(.max_stack_size)) return maximumComponent(kind_id, component);
        return maximumComponent(kind_id, null);
    }

    fn maximumComponent(kind_id: u32, component: ?Component) !u16 {
        if (kind_id >= game_data.registry.items.len) return error.UnknownItem;
        const limit = component orelse return game_data.registry.items[kind_id].stack_size;
        const bytes = limit.value orelse return error.InvalidStackLimit;
        const count, const rest = try game_data.encoding.read_varint(bytes);
        if (rest.len != 0 or count <= 0 or count > 99) return error.InvalidStackLimit;
        return @intCast(count);
    }
};
