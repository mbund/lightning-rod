const lightning_rod = @import("lightning_rod");
const std = @import("std");
const inventories = @import("inventories");
const entities = @import("entities");
const Players = @import("players.zig").Players;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const Items = @import("items.zig").Items;

const assert = std.debug.assert;

pub const ItemPickup = struct {
    pub const id = "minecraft:item_pickup";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *Players,
        menus: *PlayerInventory,
        inventories: *inventories.Inventories,
        entities: *entities.Entities,
        items: *Items,
        dropped: *ItemEntities,
    };

    const slot_numbers: [37]u16 = numbers: {
        var result: [37]u16 = undefined;
        for (&result, 0..) |*slot, index| slot.* = @intCast(if (index < 9) index + 36 else if (index == 36) 45 else index);
        break :numbers result;
    };
    const Admission = struct {
        owner: ?u128 = null,
        dirty: u64 = 0,
        contents: [37]inventories.Contents = @splat(.{}),
        maximums: [37]u16 = @splat(0),
        full: bool = false,
    };

    deps: Dependencies,
    admissions: []Admission,
    watched: lightning_rod.system.IndexSet,
    observer: *inventories.Inventories.Observer,
    query: ItemEntities.Query,
    audiences: lightning_rod.system.sparse_sets.Workspace,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemPickup {
        if (deps.inventories.cache.entries.len <= 37) return error.InventoryCacheTooSmall;
        const self = try allocator.create(ItemPickup);
        const admissions = try allocator.alloc(Admission, deps.players.records.len);
        @memset(admissions, .{});
        self.* = .{ .watched = try lightning_rod.system.IndexSet.init(allocator, admissions.len), .deps = deps, .admissions = admissions, .observer = try deps.inventories.observe(allocator, admissions.len), .query = try ItemEntities.Query.init(allocator, deps.dropped, deps.players), .audiences = try lightning_rod.system.sparse_sets.Workspace.init(allocator, 17, admissions.len) };
        return self;
    }

    pub const Request = struct {
        source: inventories.Slot,
        owner: ?u128 = null,
        pickup_delay: u16 = 0,
    };

    pub const Result = struct {
        collected: u16 = 0,
        /// Valid when collected is nonzero.
        remaining: ?inventories.Stack = null,
    };

    pub fn tick(self: *ItemPickup) !void {
        const dropped = self.deps.dropped;
        var iterator = dropped.iterate(self.query.read(1));
        defer iterator.deinit();
        while (try iterator.next()) |batch| {
            var metadata: [16]ItemEntities.Metadata = undefined;
            var bodies: [16]entities.State = undefined;
            for (0..17) |row| self.audiences.row(row).clear();
            const players = self.audiences.row(16);
            for (batch, 0..) |record, at| {
                metadata[at] = try record.read();
                if (!metadata[at].alive or metadata[at].pickup_delay != 0) continue;
                const body = (try record.body.read()) orelse return error.Corrupt;
                bodies[at] = body;
                var candidates = self.deps.players.nearby(body.world, .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] }, 1);
                while (candidates.next()) |index| {
                    const player = self.deps.players.records[index];
                    if (!player.inWorld() or player.world != body.world or player.health == 0 or player.gamemode == .spectator) continue;
                    if (metadata[at].owner) |owner| if (owner != player.uuid) continue;
                    if (@abs(body.position[0] - player.position.x) >= 1.425 or @abs(body.position[2] - player.position.z) >= 1.425 or
                        body.position[1] + 0.25 <= player.position.y - 0.5 or body.position[1] >= player.position.y + 2.3) continue;
                    self.audiences.row(at).insert(index);
                }
                players.unite(players.view(), self.audiences.row(at).view());
            }
            // Keep player priority and each player's item order. Independent transfers commute.
            var selected = players.view().iterator();
            while (selected.next()) |player| {
                var requests: [16]Request = undefined;
                var results: [16]Result = undefined;
                var indices: [16]usize = undefined;
                var count: usize = 0;
                for (batch, 0..) |_, at| {
                    if (!metadata[at].alive or !self.audiences.row(at).view().contains(player)) continue;
                    requests[count] = .{ .source = ItemEntities.slot(bodies[at]), .owner = metadata[at].owner, .pickup_delay = metadata[at].pickup_delay };
                    indices[count] = at;
                    count += 1;
                }
                if (count == 0) continue;
                try self.collect(player, requests[0..count], results[0..count]);
                for (results[0..count], indices[0..count]) |result, at| {
                    if (result.collected == 0) continue;
                    const value = &metadata[at];
                    value.collector = @intCast(player + 1);
                    value.collected = result.collected;
                    value.collection += 1;
                    value.revision += 1;
                    if (result.remaining == null) try dropped.retire(batch[at].id, bodies[at], value) else batch[at].write(value.*);
                }
            }
        }
    }

    fn refresh(self: *ItemPickup, player_index: usize) !*Admission {
        const player = self.deps.players.records[player_index];
        const admission = &self.admissions[player_index];
        if (admission.owner != player.uuid) {
            var at: usize = 0;
            while (at < self.watched.count) {
                const index = self.watched.indices[at];
                const previous = &self.admissions[index];
                const current = self.deps.players.records[index];
                at += 1;
                if (previous.owner) |owner| if (current.handle == null or owner != current.uuid) {
                    self.observer.unwatch(owner);
                    previous.owner = null;
                    self.watched.remove(index);
                    at -= 1;
                };
            }
            if (admission.owner) |owner| self.observer.unwatch(owner);
            admission.owner = player.uuid;
            self.watched.insert(player_index);
            self.observer.watch(player.uuid, &slot_numbers, .{ .dirty = &admission.dirty });
        }
        if (admission.dirty == 0) return admission;
        assert(admission.dirty >> slot_numbers.len == 0);
        const dirty = admission.dirty;
        var slots: [37]inventories.Slot = undefined;
        var indices: [37]usize = undefined;
        var contents: [37]inventories.Contents = undefined;
        var count: usize = 0;
        var bits = dirty;
        while (bits != 0) {
            const index = @ctz(bits);
            bits &= bits - 1;
            slots[count] = .{ .owner = player.uuid, .index = slot_numbers[index] };
            indices[count] = index;
            count += 1;
        }
        try self.deps.inventories.getMany(slots[0..count], contents[0..count]);
        var stacks: [37]inventories.Stack = undefined;
        var maximums: [37]u16 = undefined;
        var stacked: usize = 0;
        for (contents[0..count]) |value| if (value.stack) |stack| {
            stacks[stacked] = stack;
            stacked += 1;
        };
        try self.deps.items.stackLimits(stacks[0..stacked], maximums[0..stacked]);
        stacked = 0;
        for (contents[0..count], indices[0..count]) |value, index| {
            admission.contents[index] = value;
            admission.maximums[index] = if (value.stack != null) maximums[stacked] else 0;
            if (value.stack != null) stacked += 1;
        }
        admission.dirty &= ~dirty;
        admission.full = true;
        for (admission.contents, admission.maximums, 0..) |value, maximum, index| {
            if (value.stack) |stack| {
                if (stack.count < maximum) admission.full = false;
            } else if (index < 36) admission.full = false;
        }
        assert(admission.owner == player.uuid and admission.dirty == 0);
        return admission;
    }

    /// Sources are distinct and disjoint from the player's slots. Results are published only after the edit succeeds.
    pub fn collect(self: *ItemPickup, player_index: usize, requests: []const Request, results: []Result) !void {
        assert(player_index < self.deps.players.records.len);
        assert(requests.len <= 64 and requests.len == results.len);
        @memset(results, .{});
        const player = &self.deps.players.records[player_index];
        if (!player.inWorld() or player.health == 0 or player.gamemode == .spectator or requests.len == 0) return;
        for (requests, 0..) |request, index| for (requests[0..index]) |previous| assert(!std.meta.eql(request.source, previous.source));
        for (requests) |request| if (request.source.owner == player.uuid) {
            for (slot_numbers) |number| assert(number != request.source.index);
        };
        assert(self.deps.inventories.cache.entries.len > 37);
        const capacity = @min(64, self.deps.inventories.cache.entries.len - 37);
        var begin: usize = 0;
        while (begin < requests.len) {
            const count = @min(capacity, requests.len - begin);
            const selected = requests[begin..][0..count];
            const eligible_request = for (selected) |request| {
                if (request.pickup_delay == 0 and (request.owner == null or request.owner.? == player.uuid)) break true;
            } else false;
            if (!eligible_request) {
                begin += count;
                continue;
            }
            const admission = try self.refresh(player_index);
            if (admission.full and player.gamemode != .creative) return;
            var slots: [101]inventories.Slot = undefined;
            for (slots[0..37], slot_numbers) |*slot, number| slot.* = .{ .owner = player.uuid, .index = number };
            for (selected, slots[37..][0..count]) |request, *slot| {
                for (slots[0..37]) |destination| assert(!std.meta.eql(destination, request.source));
                slot.* = request.source;
            }
            var contents: [64]inventories.Contents = undefined;
            try self.deps.inventories.getMany(slots[37..][0..count], contents[0..count]);
            var next: [101]?inventories.Stack = undefined;
            for (admission.contents, next[0..37]) |value, *stack| stack.* = value.stack;
            for (contents[0..count], next[37..][0..count]) |value, *stack| stack.* = value.stack;
            var order: [38]usize = undefined;
            order[0] = player.selected_slot;
            order[1] = 36;
            for (order[2..], 0..) |*index, at| index.* = at;
            var eligible: [64]usize = undefined;
            var eligible_count: usize = 0;
            for (selected, 0..) |request, index| {
                if (request.pickup_delay != 0 or (request.owner != null and request.owner.? != player.uuid) or next[37 + index] == null) continue;
                eligible[eligible_count] = index;
                eligible_count += 1;
            }
            var pending_results: [64]Result = @splat(.{});
            var stacks: [64]inventories.Stack = undefined;
            var maximums: [64]u16 = undefined;
            for (eligible[0..eligible_count], stacks[0..eligible_count]) |index, *stack| stack.* = next[37 + index].?;
            try self.deps.items.stackLimits(stacks[0..eligible_count], maximums[0..eligible_count]);
            for (eligible[0..eligible_count], stacks[0..eligible_count], maximums[0..eligible_count]) |index, held, maximum| {
                if (held.count > maximum) return error.Corrupt;
                var remaining = held.count;
                for (order) |destination| {
                    if (remaining == 0) break;
                    const stack = next[destination] orelse continue;
                    if (!inventories.Stack.sameItem(stack, held)) continue;
                    const amount = @min(remaining, maximum -| stack.count);
                    if (amount == 0) continue;
                    next[destination] = .{ .item = held.item, .count = stack.count + amount };
                    remaining -= amount;
                }
                for (next[0..36]) |*stack| {
                    if (remaining == 0) break;
                    if (stack.* != null) continue;
                    const amount = @min(remaining, maximum);
                    stack.* = .{ .item = held.item, .count = amount };
                    remaining -= amount;
                }
                const inserted = held.count - remaining;
                const discarded = if (player.gamemode == .creative) remaining else @as(u16, 0);
                remaining -= discarded;
                assert(@as(u32, inserted) + discarded + remaining == held.count);
                if (inserted + discarded == 0) continue;
                next[37 + index] = if (remaining == 0) null else .{ .item = held.item, .count = remaining };
                pending_results[index] = .{ .collected = inserted + discarded, .remaining = next[37 + index] };
            }
            var edits: [101]inventories.Edit = undefined;
            var edited: usize = 0;
            for (slots[0 .. 37 + count], next[0 .. 37 + count], 0..) |slot, stack, index| {
                const previous = if (index < 37) admission.contents[index] else contents[index - 37];
                if (std.meta.eql(previous.stack, stack)) continue;
                edits[edited] = .{ .slot = slot, .revision = previous.revision, .stack = stack };
                edited += 1;
            }
            if (edited != 0) {
                const committed = try self.deps.inventories.editMany(edits[0..edited]);
                assert(committed);
                self.deps.menus.changed(player_index);
            }
            @memcpy(results[begin..][0..count], pending_results[0..count]);
            begin += count;
        }
    }
};
