const std = @import("std");
const inventories = @import("inventories");
const item = @import("item.zig");

const assert = std.debug.assert;

pub const ItemMerging = struct {
    pub const id = "minecraft:item_merging";

    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator) !*ItemMerging {
        const self = try allocator.create(ItemMerging);
        self.* = .{};
        return self;
    }

    /// The caller supplies overlapping candidates in entity-query order and
    /// commits the returned ownership changes together, before publishing them.
    pub fn merge(_: *const ItemMerging, first: item.State, second: item.State) ?item.Merge {
        assert(first.valid());
        assert(second.valid());
        if (first.pickup_delay == 32767 or second.pickup_delay == 32767) return null;
        if (first.age == -32768 or second.age == -32768) return null;
        if (first.age >= 6000 or second.age >= 6000) return null;
        if (first.stack.count >= first.maximum_stack or second.stack.count >= second.maximum_stack) return null;
        if (first.owner != second.owner) return null;
        if (!inventories.Stack.sameItem(first.stack, second.stack)) return null;
        assert(first.maximum_stack == second.maximum_stack);
        if (@as(u32, first.stack.count) + second.stack.count > second.maximum_stack) return null;

        const destination_is_first = first.stack.count > second.stack.count;
        var destination = if (destination_is_first) first else second;
        var source = if (destination_is_first) second else first;
        const limit = @min(destination.maximum_stack, 64);
        if (destination.stack.count >= limit) return null;

        const transferred = @min(source.stack.count, limit - destination.stack.count);
        destination.stack.count += transferred;
        source.stack.count -= transferred;
        destination.pickup_delay = @max(destination.pickup_delay, source.pickup_delay);
        destination.age = @min(destination.age, source.age);
        const result: item.Merge = .{
            .destination = destination,
            .source = if (source.stack.count == 0) null else source,
            .destination_is_first = destination_is_first,
            .transferred = transferred,
        };
        result.check(first, second);
        return result;
    }
};
