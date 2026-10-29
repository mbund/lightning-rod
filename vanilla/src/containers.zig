const std = @import("std");
const lightning_rod = @import("lightning_rod");
const storage = @import("storage");
const records = @import("records");
const chunks = @import("chunks");
const inventories = @import("inventories");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const minecraft = @import("minecraft_model");
const game_data = @import("game_data");
const wire = @import("wire_1_21_5");
const Players = @import("players.zig").Players;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const BlockActions = @import("block_actions.zig").BlockActions;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const menu_click = @import("menu_click.zig");
const blocks = @import("container_blocks.zig");
const furnace = @import("furnace.zig");
const metrics = @import("metrics");
const Experience = @import("experience.zig").Experience;

const assert = std.debug.assert;

pub const Key = struct {
    world: u32,
    position: chunks.Position,

    pub fn encode(self: Key) [16]u8 {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.world, .big);
        std.mem.writeInt(i32, bytes[4..8], self.position.x, .big);
        std.mem.writeInt(i32, bytes[8..12], self.position.y, .big);
        std.mem.writeInt(i32, bytes[12..16], self.position.z, .big);
        return bytes;
    }

    pub fn decode(bytes: []const u8) !Key {
        if (bytes.len != 16) return error.CorruptContainer;
        return .{ .world = std.mem.readInt(u32, bytes[0..4], .big), .position = .{
            .x = std.mem.readInt(i32, bytes[4..8], .big),
            .y = std.mem.readInt(i32, bytes[8..12], .big),
            .z = std.mem.readInt(i32, bytes[12..16], .big),
        } };
    }

    pub fn owner(self: Key) u128 {
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update("lightning-rod:block-container");
        hash.update(&self.encode());
        var uuid: [16]u8 = undefined;
        hash.final(&uuid);
        uuid[6] = (uuid[6] & 15) | 0x80;
        uuid[8] = (uuid[8] & 63) | 0x80;
        return std.mem.readInt(u128, &uuid, .big);
    }
};

pub const Containers = struct {
    pub const id = "minecraft:containers";
    pub const minimum_inventory_cache_slots = menu_click.maximum_slots;
    pub const Configuration = struct { active_furnaces: usize = 256, reward_records: usize = 64 };
    pub const Dependencies = struct {
        experience: *Experience,
        metrics: *metrics.Registry,
        players: *Players,
        inventory: *PlayerInventory,
        inventories: *inventories.Inventories,
        chunks: *chunks.Chunks,
        actions: *BlockActions,
        dropped: *ItemEntities,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        storage: storage.Space,
        record_workspaces: *records.Workspaces,
    };
    pub const View = struct {
        generation: u32 = 0,
        life: u32 = 0,
        window: i32 = 0,
        revision: i32 = 0,
        kind: blocks.Kind = .chest,
        key: Key = undefined,
        partner: ?chunks.Position = null,
        owners: [2]u128 = @splat(0),
        container_slots: usize = 0,
        watches: [3]usize = undefined,
        watch_count: usize = 0,
        drag: menu_click.Drag = .{},
        opened: bool = false,
        closing: bool = false,
        initial: bool = true,
        dirty: bool = true,
        presentation: u64 = 0,
        preview: ?inventories.Stack = null,
        revisions: [menu_click.maximum_slots]u64 = @splat(std.math.maxInt(u64)),
        properties: [4]i32 = @splat(-1),
    };
    const Watch = struct { owner: u128 = 0, slots: [54]u16 = undefined, dirty: u64 = 0, users: usize = 0 };

    pub const Resident = struct { key: Key, state: furnace.State };

    deps: Dependencies,
    states: blocks.States,
    table: records.Table,
    rewards: records.Cache,
    active: []Resident,
    saved: []Key,
    saved_count: usize = 0,
    active_count: usize = 0,
    active_index: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    views: []View,
    opened: lightning_rod.system.IndexSet,
    watches: []Watch,
    watch_index: std.AutoArrayHashMapUnmanaged(u128, usize) = .empty,
    observer: *inventories.Inventories.Observer,
    lids: std.AutoArrayHashMapUnmanaged(Key, u8) = .empty,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Containers {
        if (config.active_furnaces == 0 or config.reward_records == 0) return error.InvalidConfiguration;
        assert(deps.inventories.cache.entries.len >= minimum_inventory_cache_slots);
        if (deps.inventories.cache.entries.len < minimum_inventory_cache_slots) return error.InventoryCacheTooSmall;
        const self = try allocator.create(Containers);
        self.* = .{
            .deps = deps,
            .states = try .init(),
            .table = .{ .space = deps.storage, .root_offset = 8, .resources = deps.record_workspaces.resources },
            .rewards = try records.Cache.init(allocator, io, .{ .space = deps.storage, .root_offset = 16, .resources = deps.record_workspaces.resources }, .{
                .slots = config.reward_records,
                .key_bytes = 16,
                .value_bytes = game_data.recipes.cooking_experience.len * 4,
                .metrics = deps.metrics,
                .metrics_namespace = "containers.rewards",
            }),
            .active = try allocator.alloc(Resident, config.active_furnaces),
            .saved = try allocator.alloc(Key, config.active_furnaces),
            .views = try allocator.alloc(View, deps.players.records.len),
            .opened = try lightning_rod.system.IndexSet.init(allocator, deps.players.records.len),
            .watches = try allocator.alloc(Watch, try std.math.mul(usize, deps.players.records.len, 3)),
            .targets = try allocator.alloc(sessions.Service.Target, deps.players.records.len),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, deps.players.records.len),
            .observer = try deps.inventories.observe(allocator, try std.math.mul(usize, deps.players.records.len, 3)),
        };
        @memset(self.views, .{});
        @memset(self.watches, .{});
        try self.lids.ensureTotalCapacity(allocator, try std.math.mul(usize, deps.players.records.len, 4));
        try self.watch_index.ensureTotalCapacity(allocator, @intCast(self.watches.len));
        try self.active_index.ensureTotalCapacity(allocator, @intCast(self.active.len));
        for ([_]u16{ self.states.chests[0][0][0], self.states.furnaces[0][0], self.states.crafting }) |state| {
            const block = game_data.registry.blocks[game_data.registry.block_state_to_block[state]];
            try deps.actions.register(BlockActions.Handler.init(self, @intCast(block.min_state), @intCast(block.max_state), applyBlock));
        }
        return self;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Containers {
        const self = try allocate(allocator, io, config, deps);
        const root = try deps.storage.getRoot() orelse blk: {
            var allocated: [1]storage.PageId = undefined;
            try deps.storage.allocatePages(&allocated);
            var page: storage.Page = @splat(0);
            @memcpy(page[0..8], "LRCNTR01");
            try deps.storage.writePages(&.{.{ .id = allocated[0], .source = &page }});
            try deps.storage.setRoot(allocated[0]);
            break :blk allocated[0];
        };
        var header: [8]u8 = undefined;
        try deps.storage.readPages(&.{.{ .id = root, .destination = &header }});
        if (!std.mem.eql(u8, &header, "LRCNTR01")) return error.CorruptFurnace;
        self.table.directory = root;
        self.rewards.backend.directory = root;
        var after: [16]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        var keys: [16][16]u8 = undefined;
        var values: [16][furnace.encoded_bytes]u8 = undefined;
        var entries: [16]records.ScanEntry = undefined;
        for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
        while (true) {
            const batch = try self.table.scan(&cursor, &entries);
            for (entries[0..batch.count]) |entry| {
                const key = try Key.decode(entry.key[0..entry.key_len]);
                const value = try furnace.State.decode(entry.value[0..entry.value_len]);
                assert(!self.active_index.contains(key));
                const index = self.active_count;
                if (!self.activate(key)) return error.FurnaceCapacity;
                self.active[index].state = value;
                self.saved[self.saved_count] = key;
                self.saved_count += 1;
            }
            if (!batch.more) break;
        }
        return self;
    }

    pub fn slot(world: u32, position: chunks.Position, index: u16) inventories.Slot {
        assert(index < 27);
        return .{ .owner = (Key{ .world = world, .position = position }).owner(), .index = index };
    }

    pub fn furnaceState(self: *const Containers, world: u32, position: chunks.Position) furnace.State {
        const key: Key = .{ .world = world, .position = position };
        return if (self.active_index.get(key)) |index| self.active[index].state else .{};
    }

    pub fn activate(self: *Containers, key: Key) bool {
        if (self.active_index.contains(key)) return true;
        if (self.active_count == self.active.len) return false;
        self.active[self.active_count] = .{ .key = key, .state = .{ .active = true } };
        self.active_index.putAssumeCapacityNoClobber(key, self.active_count);
        self.active_count += 1;
        return true;
    }

    pub fn deactivate(self: *Containers, key: Key) void {
        const removed = self.active_index.fetchRemove(key) orelse return;
        self.active_count -= 1;
        if (removed.value < self.active_count) {
            self.active[removed.value] = self.active[self.active_count];
            self.active_index.getPtr(self.active[removed.value].key).?.* = removed.value;
        }
    }

    pub const Reward = struct {
        amounts: [game_data.recipes.cooking_experience.len]i32 = @splat(0),
        random: std.Random.Xoshiro256,
    };

    pub fn recordRecipe(self: *Containers, key: Key, recipe: u32) !void {
        assert(recipe < game_data.recipes.cooking_experience.len);
        const lease = try self.rewards.acquire(&key.encode());
        defer lease.release();
        const previous = lease.read();
        if (previous) |bytes| if (bytes.len != game_data.recipes.cooking_experience.len * 4) return error.CorruptFurnace;
        const count = if (previous) |bytes| std.mem.readInt(u32, bytes[recipe * 4 ..][0..4], .little) else 0;
        if (count == std.math.maxInt(i32)) return error.FurnaceRecipeCountExhausted;
        const bytes = lease.edit();
        if (previous == null) @memset(bytes, 0);
        std.mem.writeInt(u32, bytes[recipe * 4 ..][0..4], count + 1, .little);
        lease.commit(bytes.len);
    }

    fn reward(self: *Containers, key: Key) !Reward {
        var plan: Reward = .{ .random = self.deps.experience.random.source };
        const lease = try self.rewards.acquire(&key.encode());
        defer lease.release();
        const bytes = lease.read() orelse return plan;
        if (bytes.len != game_data.recipes.cooking_experience.len * 4) return error.CorruptFurnace;
        for (game_data.recipes.cooking_experience, &plan.amounts, 0..) |experience, *amount, index| {
            const count = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
            const value = @as(f32, @floatFromInt(count)) * experience;
            if (!std.math.isFinite(value) or value >= 2147483648) return error.FurnaceExperienceOverflow;
            amount.* = @intFromFloat(@floor(value));
            const fraction = value - @floor(value);
            if (fraction != 0 and plan.random.random().float(f64) < fraction) amount.* += 1;
        }
        return plan;
    }

    fn claim(self: *Containers, key: Key, position: [3]f64, plan: Reward) !void {
        assert(self.deps.experience.canAwardMany(&plan.amounts));
        const lease = try self.rewards.acquire(&key.encode());
        defer lease.release();
        lease.remove();
        self.deps.experience.random.source = plan.random;
        for (plan.amounts) |amount| if (amount > 0) try self.deps.experience.award(key.world, position, amount);
    }

    fn watch(self: *Containers, owner: u128, player: bool, count: usize) usize {
        if (self.watch_index.get(owner)) |index| {
            self.watches[index].users += 1;
            return index;
        }
        for (self.watches, 0..) |*entry, index| {
            if (entry.users != 0) continue;
            entry.* = .{ .owner = owner, .users = 1 };
            const length: usize = if (player) 47 else count;
            for (entry.slots[0..length], 0..) |*destination, at| destination.* = if (!player) @intCast(at) else if (at < 36) @intCast(at + 9) else if (at == 36) 45 else if (at == 37) std.math.maxInt(u16) else @intCast(PlayerInventory.table_grid_first + at - 38);
            self.observer.watch(owner, entry.slots[0..length], .{ .dirty = &entry.dirty });
            self.watch_index.putAssumeCapacityNoClobber(owner, index);
            return index;
        }
        unreachable;
    }

    fn unwatch(self: *Containers, index: usize) void {
        const entry = &self.watches[index];
        assert(entry.users > 0);
        entry.users -= 1;
        if (entry.users != 0) return;
        self.observer.unwatch(entry.owner);
        const removed = self.watch_index.swapRemove(entry.owner);
        assert(removed);
    }

    fn applyBlock(self: *Containers, request: BlockActions.Request) !BlockActions.Result {
        const kind = self.states.kind(request.state).?;
        const key: Key = .{ .world = request.player.world, .position = request.position };
        switch (request.action) {
            .place => {
                if (kind == .crafting) return .pass;
                const face = blocks.placedFacing(request.player.rotation.yaw);
                var state = if (kind == .chest) self.states.chests[@intFromEnum(face)][0][0] else self.states.furnaces[@intFromEnum(face)][0];
                var neighbor_position: ?chunks.Position = null;
                var neighbor_state: u16 = 0;
                if (kind == .chest and !request.player.flags.sneaking) {
                    const right = blocks.rightOf(face);
                    for ([_]i32{ -1, 1 }) |sign| {
                        const neighbor: chunks.Position = .{ .x = key.position.x + sign * right[0], .y = key.position.y, .z = key.position.z + sign * right[1] };
                        const other = try self.deps.chunks.getBlock(key.world, neighbor);
                        if (self.states.kind(other) != .chest or self.states.chestType(other) != .single or self.states.facing(other) != face) continue;
                        state = self.states.chest(state, if (sign == 1) .left else .right);
                        neighbor_position = neighbor;
                        neighbor_state = self.states.chest(other, if (sign == 1) .right else .left);
                        break;
                    }
                }
                const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
                var nearby = self.deps.players.nearby(key.world, .{ .x = @as(f64, @floatFromInt(key.position.x)) + 0.5, .y = @floatFromInt(key.position.y), .z = @as(f64, @floatFromInt(key.position.z)) + 0.5 }, 1);
                while (nearby.next()) |index| {
                    const player = self.deps.players.records[index];
                    if (!player.inWorld() or player.gamemode == .spectator) continue;
                    for (game_data.registry.collision_boxes[shape.offset..][0..shape.count]) |box| {
                        const x: f64 = @floatFromInt(key.position.x);
                        const y: f64 = @floatFromInt(key.position.y);
                        const z: f64 = @floatFromInt(key.position.z);
                        if (player.position.x + 0.3 > x + @as(f64, @floatFromInt(box.min_x)) / 64 and player.position.x - 0.3 < x + @as(f64, @floatFromInt(box.max_x)) / 64 and
                            player.position.y + 1.8 > y + @as(f64, @floatFromInt(box.min_y)) / 64 and player.position.y < y + @as(f64, @floatFromInt(box.max_y)) / 64 and
                            player.position.z + 0.3 > z + @as(f64, @floatFromInt(box.min_z)) / 64 and player.position.z - 0.3 < z + @as(f64, @floatFromInt(box.max_z)) / 64) return .denied;
                    }
                }
                if (neighbor_position) |position| {
                    const sections = [_]chunks.Section{ chunks.sectionAt(key.world, key.position), chunks.sectionAt(key.world, position) };
                    const edits = [_]chunks.BlockEdit{ .{ .index = chunks.localIndex(key.position), .state = state }, .{ .index = chunks.localIndex(position), .state = neighbor_state } };
                    if (std.meta.eql(sections[0], sections[1])) try self.deps.chunks.setBlocks(sections[0], &edits) else try self.deps.chunks.setSections(&.{ .{ .section = sections[0], .edits = edits[0..1] }, .{ .section = sections[1], .edits = edits[1..2] } });
                } else try self.deps.chunks.setBlock(key.world, key.position, state);
                return .applied;
            },
            .use => {
                if (kind == .chest) {
                    var above = key.position;
                    above.y += 1;
                    if (self.blocksLid(try self.deps.chunks.getBlock(key.world, above))) return .denied;
                }
                try self.open(request.player.handle.?.index, key, request.state);
                return .applied;
            },
            .remove => {
                if (kind == .crafting) {
                    try self.closeAt(key);
                    return .pass;
                }
                const count: usize = if (kind == .chest) 27 else 3;
                var slots: [27]inventories.Slot = undefined;
                var contents: [27]inventories.Contents = undefined;
                var edits: [27]inventories.Edit = undefined;
                var spawns: [27]ItemEntities.Spawn = undefined;
                var ids: [27]u64 = undefined;
                var drops: usize = 0;
                for (slots[0..count], 0..) |*destination, at| destination.* = .{ .owner = key.owner(), .index = @intCast(at) };
                try self.deps.inventories.getMany(slots[0..count], contents[0..count]);
                for (slots[0..count], contents[0..count]) |destination, value| if (value.stack) |stack| {
                    edits[drops] = .{ .slot = destination, .revision = value.revision, .stack = null };
                    spawns[drops] = .{ .world = key.world, .position = .{ @as(f64, @floatFromInt(key.position.x)) + 0.5, @as(f64, @floatFromInt(key.position.y)) + 0.5, @as(f64, @floatFromInt(key.position.z)) + 0.5 }, .velocity = .{ 0, 0.2, 0 }, .stack = stack };
                    drops += 1;
                };
                assert(request.following_drops <= self.deps.dropped.residents.len);
                if (!self.deps.dropped.canCreate(drops + request.following_drops)) return .denied;
                const reward_plan: ?Reward = if (kind == .furnace) try self.reward(key) else null;
                if (reward_plan) |plan| if (!self.deps.experience.canAwardMany(&plan.amounts)) return .denied;
                errdefer self.deps.storage.fail();
                try self.closeAt(key);
                if (drops != 0) {
                    try self.deps.dropped.createMany(spawns[0..drops], ids[0..drops]);
                    const committed = try self.deps.inventories.editMany(edits[0..drops]);
                    assert(committed);
                }
                assert(self.deps.dropped.canCreate(request.following_drops));
                if (kind == .chest) {
                    if (self.states.partner(request.state, key.position)) |partner| {
                        const other = try self.deps.chunks.getBlock(key.world, partner);
                        if (self.states.kind(other) == .chest) try self.deps.chunks.setBlock(key.world, partner, self.states.chest(other, .single));
                    }
                } else {
                    self.deactivate(key);
                }
                try self.deps.chunks.setBlock(key.world, key.position, 0);
                if (reward_plan) |plan| try self.claim(key, .{ @as(f64, @floatFromInt(key.position.x)) + 0.5, @as(f64, @floatFromInt(key.position.y)) + 0.5, @as(f64, @floatFromInt(key.position.z)) + 0.5 }, plan);
                return .applied;
            },
        }
    }

    fn blocksLid(_: *Containers, state: u16) bool {
        if (game_data.registry.blocks[game_data.registry.block_state_to_block[state]].visually_transparent) return false;
        const shape = game_data.registry.block_state_collision_shape[state];
        const face = game_data.registry.collisionLightFace(shape, 2);
        return std.mem.allEqual(u64, &face, std.math.maxInt(u64));
    }

    fn open(self: *Containers, index: usize, key: Key, state: u16) !void {
        if (self.opened.contains(index) and !try self.close(index, true)) return;
        try self.deps.inventory.closeMenu(index);
        if (self.deps.inventory.states[index].close) return;
        const player = self.deps.players.records[index];
        const view = &self.views[index];
        const window = @mod(view.window, 100) + 1;
        view.* = .{ .generation = player.handle.?.generation, .life = player.life, .window = window, .key = key, .kind = self.states.kind(state).? };
        view.container_slots = switch (view.kind) {
            .chest => 27,
            .furnace => 3,
            .crafting => 10,
        };
        view.owners[0] = if (view.kind == .crafting) player.uuid else key.owner();
        if (view.kind == .chest) if (self.states.partner(state, key.position)) |partner| {
            const other = try self.deps.chunks.getBlock(key.world, partner);
            if (self.states.kind(other) != .chest or self.states.facing(other) != self.states.facing(state)) return;
            var above = partner;
            above.y += 1;
            if (self.blocksLid(try self.deps.chunks.getBlock(key.world, above))) return;
            const partner_owner = (Key{ .world = key.world, .position = partner }).owner();
            view.owners = if (self.states.chestType(state) == .right) .{ key.owner(), partner_owner } else .{ partner_owner, key.owner() };
            view.container_slots = 54;
            view.partner = partner;
        };
        if (view.kind == .chest and !self.canQueueLids(view.*)) return;
        view.watches[0] = self.watch(player.uuid, true, 0);
        view.watch_count = 1;
        if (view.kind != .crafting) {
            view.watches[1] = self.watch(view.owners[0], false, @min(view.container_slots, 27));
            view.watch_count = 2;
            if (view.container_slots == 54) {
                view.watches[2] = self.watch(view.owners[1], false, 27);
                view.watch_count = 3;
            }
        }
        self.deps.inventory.states[index].external = true;
        self.opened.insert(index);
        if (view.kind == .chest) self.queueLids(view.*);
    }

    fn closeAt(self: *Containers, key: Key) !void {
        var offset: usize = 0;
        while (offset < self.opened.values().len) {
            const index = self.opened.values()[offset];
            const view = self.views[index];
            if (std.meta.eql(view.key, key) or view.owners[0] == key.owner() or view.owners[1] == key.owner()) {
                if (!try self.close(index, true)) offset += 1;
            } else offset += 1;
        }
    }

    fn close(self: *Containers, index: usize, notify: bool) !bool {
        const view = &self.views[index];
        if (view.kind == .chest and !self.canQueueLids(view.*)) {
            view.closing = true;
            return false;
        }
        if (notify and self.deps.players.records[index].handle != null and self.deps.players.records[index].handle.?.generation == view.generation) if (self.deps.players.records[index].handle) |handle| {
            self.deps.packets.sendPacket(writeClose, self.deps.players.records[index].protocol, handle, .{view.window}, 16) catch |err| switch (err) {
                error.Backpressured => {
                    view.closing = true;
                    return false;
                },
                error.Closed => {},
                else => return err,
            };
        };
        for (view.watches[0..view.watch_count]) |watched| self.unwatch(watched);
        view.watch_count = 0;
        self.opened.remove(index);
        if (view.kind == .chest) self.queueLids(view.*);
        const state = &self.deps.inventory.states[index];
        if (state.generation == view.generation and state.life == view.life) {
            // Return cursor and crafting inputs after block drops have been allocated.
            state.external = false;
            state.close = true;
            state.drag = .{};
        }
        return true;
    }

    fn load(self: *Containers, index: usize, slots: []inventories.Slot, contents: []inventories.Contents) !void {
        const view = self.views[index];
        const player = self.deps.players.records[index];
        assert(slots.len == view.container_slots + 38 and contents.len == slots.len);
        for (slots, 0..) |*destination, at| {
            destination.* = if (at < view.container_slots) .{
                .owner = if (view.kind == .crafting) player.uuid else view.owners[@intFromBool(at >= 27)],
                .index = if (view.kind == .crafting) @intCast(if (at == 0) 0 else PlayerInventory.table_grid_first + at - 1) else @intCast(at % 27),
            } else .{ .owner = player.uuid, .index = if (at == view.container_slots + 36) std.math.maxInt(u16) else if (at == view.container_slots + 37) 45 else @intCast(9 + at - view.container_slots) };
        }
        try self.deps.inventories.getMany(slots, contents);
        if (view.kind == .crafting) {
            assert(contents[0].stack == null);
            var next: [menu_click.maximum_slots]?inventories.Stack = undefined;
            for (contents, next[0..contents.len]) |value, *stack| stack.* = value.stack;
            var drag: menu_click.Drag = .{};
            const menu: menu_click.Menu = .{ .inventory = self.deps.inventory, .kind = .crafting, .container_slots = 10, .stacks = next[0..contents.len], .drag = &drag, .creative = player.gamemode == .creative };
            try menu.refresh();
            contents[0].stack = next[0];
        }
    }

    pub fn closeWindow(self: *Containers, handle: sessions.Handle, window: i32) !void {
        if (self.opened.contains(handle.index) and self.views[handle.index].generation == handle.generation and self.views[handle.index].window == window) _ = try self.close(handle.index, false);
    }

    pub fn click(self: *Containers, handle: sessions.Handle, action: minecraft.InventoryClick) !void {
        const window = action.window_id;
        if (!self.opened.contains(handle.index)) return;
        const index = handle.index;
        const view = &self.views[index];
        const player = self.deps.players.records[index];
        if (view.closing or window != view.window or view.generation != handle.generation or !view.opened or !self.valid(index)) return;
        view.dirty = true;
        if (player.gamemode == .spectator or player.health <= 0) return;
        const count = view.container_slots + 38;
        var slots: [menu_click.maximum_slots]inventories.Slot = undefined;
        var contents: [menu_click.maximum_slots]inventories.Contents = undefined;
        var next: [menu_click.maximum_slots]?inventories.Stack = undefined;
        try self.load(index, slots[0..count], contents[0..count]);
        for (contents[0..count], next[0..count]) |value, *stack| stack.* = value.stack;
        const previous = view.drag;
        const menu: menu_click.Menu = .{ .inventory = self.deps.inventory, .kind = switch (view.kind) {
            .chest => .chest,
            .furnace => .furnace,
            .crafting => .crafting,
        }, .container_slots = view.container_slots, .stacks = next[0..count], .drag = &view.drag, .creative = player.gamemode == .creative };
        const result = try menu.apply(action);
        try menu.refresh();
        if (!self.deps.dropped.canCreate(result.count)) {
            view.drag = previous;
            return;
        }
        var wake = false;
        if (view.kind == .furnace and !self.active_index.contains(view.key) and next[0] != null and next[1] != null) {
            const source_kind = try self.deps.inventory.deps.items.kind(next[0].?);
            const fuel_kind = try self.deps.inventory.deps.items.kind(next[1].?);
            wake = self.deps.inventory.recipes.recipes[source_kind] != null and self.deps.inventory.recipes.fuels[fuel_kind].ticks != 0;
            if (wake and self.active_count == self.active.len) {
                view.drag = previous;
                return;
            }
        }
        const output_taken = view.kind == .furnace and contents[2].stack != null and (next[2] == null or next[2].?.count < contents[2].stack.?.count);
        const reward_plan: ?Reward = if (output_taken) try self.reward(view.key) else null;
        if (reward_plan) |plan| if (!self.deps.experience.canAwardMany(&plan.amounts)) {
            view.drag = previous;
            return;
        };
        errdefer self.deps.storage.fail();
        const dropped = try self.deps.inventory.dropMany(player, result.drops[0..result.count]);
        assert(dropped);
        var edits: [menu_click.maximum_slots]inventories.Edit = undefined;
        var edited: usize = 0;
        for (slots[0..count], contents[0..count], next[0..count], 0..) |destination, value, stack, at| {
            if ((view.kind == .crafting and at == 0) or std.meta.eql(value.stack, stack)) continue;
            edits[edited] = .{ .slot = destination, .revision = value.revision, .stack = stack };
            edited += 1;
        }
        const committed = try self.deps.inventories.editMany(edits[0..edited]);
        assert(committed);
        self.deps.inventory.changed(index);
        if (reward_plan) |plan| try self.claim(view.key, .{ player.position.x, player.position.y, player.position.z }, plan);
        if (wake) {
            const activated = self.activate(view.key);
            assert(activated);
        }
    }

    fn valid(self: *Containers, index: usize) bool {
        const player = self.deps.players.records[index];
        const view = self.views[index];
        if (player.handle == null or player.handle.?.generation != view.generation or player.life != view.life or player.world != view.key.world or player.stage != .ready) return false;
        const dx = player.position.x - (@as(f64, @floatFromInt(view.key.position.x)) + 0.5);
        const dy = player.position.y - (@as(f64, @floatFromInt(view.key.position.y)) + 0.5);
        const dz = player.position.z - (@as(f64, @floatFromInt(view.key.position.z)) + 0.5);
        return dx * dx + dy * dy + dz * dz <= 64;
    }

    pub fn tick(self: *Containers) !void {
        try furnace.tick(self);
        var offset: usize = 0;
        while (offset < self.opened.values().len) {
            const index = self.opened.values()[offset];
            if (self.views[index].closing or !self.valid(index)) {
                if (!try self.close(index, true)) offset += 1;
                continue;
            }
            try self.synchronize(index);
            offset += 1;
        }
        for (self.watch_index.values()) |watched| self.watches[watched].dirty = 0;
        try self.flushLids();
    }

    fn canQueueLids(self: *Containers, view: View) bool {
        var missing: usize = @intFromBool(!self.lids.contains(view.key));
        if (view.partner) |position| missing += @intFromBool(!self.lids.contains(.{ .world = view.key.world, .position = position }));
        return missing <= self.lids.capacity() - self.lids.count();
    }

    fn queueLids(self: *Containers, view: View) void {
        const keys = [_]Key{ view.key, .{ .world = view.key.world, .position = view.partner orelse view.key.position } };
        for (keys[0..if (view.partner == null) @as(usize, 1) else 2]) |key| {
            const count = if (self.watch_index.get(key.owner())) |watched| self.watches[watched].users else 0;
            self.lids.putAssumeCapacity(key, @intCast(@min(count, 127)));
        }
    }

    fn flushLids(self: *Containers) !void {
        var index: usize = 0;
        while (index < self.lids.count()) {
            const key = self.lids.keys()[index];
            var nearby = self.deps.players.nearby(key.world, .{ .x = @floatFromInt(key.position.x), .y = @floatFromInt(key.position.y), .z = @floatFromInt(key.position.z) }, self.deps.players.config.render_distance);
            var count: usize = 0;
            while (nearby.next()) |player_index| {
                const player = self.deps.players.records[player_index];
                const handle = player.handle orelse continue;
                if (player.stage != .ready) continue;
                self.targets[count] = .{ .handle = handle, .protocol = player.protocol };
                count += 1;
            }
            try self.deps.packets.fanout(writeLid, self.targets[0..count], .{ key.position, self.lids.values()[index] }, 64, self.deliveries[0..count]);
            var blocked = false;
            for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| switch (delivery) {
                .backpressured => blocked = true,
                .unsupported => self.deps.sessions.disconnect(target.handle),
                .queued, .closed => {},
            };
            if (blocked) index += 1 else self.lids.swapRemoveAt(index);
        }
    }

    fn synchronize(self: *Containers, index: usize) !void {
        const view = &self.views[index];
        const player = self.deps.players.records[index];
        const handle = player.handle.?;
        if (!view.opened) {
            const definition = try self.deps.packets.definition(player.protocol);
            const name: []const u8 = switch (view.kind) {
                .chest => if (view.container_slots == 54) "minecraft:generic_9x6" else "minecraft:generic_9x3",
                .furnace => "minecraft:furnace",
                .crafting => "minecraft:crafting",
            };
            const title: []const u8 = switch (view.kind) {
                .chest => if (view.container_slots == 54) "container.chestDouble" else "container.chest",
                .furnace => "container.furnace",
                .crafting => "container.crafting",
            };
            self.deps.packets.sendPacket(writeOpen, player.protocol, handle, .{ view.window, try definition.registryId("minecraft:menu", name), title }, 128) catch |err| switch (err) {
                error.Backpressured, error.Closed => {
                    view.dirty = true;
                    return;
                },
                else => return err,
            };
            view.opened = true;
        }
        var dirty = view.dirty or view.initial or view.presentation != self.deps.inventory.deps.items.components.revision;
        for (view.watches[0..view.watch_count]) |watched| dirty = dirty or self.watches[watched].dirty != 0;
        if (dirty) {
            errdefer view.dirty = true;
            const count = view.container_slots + 38;
            const visible = count - 2;
            var slots: [menu_click.maximum_slots]inventories.Slot = undefined;
            var contents: [menu_click.maximum_slots]inventories.Contents = undefined;
            try self.load(index, slots[0..count], contents[0..count]);
            const revision = (view.revision + 1) & 32767;
            if (view.initial or view.dirty or view.presentation != self.deps.inventory.deps.items.components.revision) {
                self.deps.packets.sendPacket(PlayerInventory.writeContents, player.protocol, handle, .{ self.deps.inventory.deps.items, view.window, revision, contents[0..visible], contents[visible], player.uuid }, self.deps.sessions.config.page_bytes) catch |err| switch (err) {
                    error.Backpressured, error.Closed => {
                        view.dirty = true;
                        return;
                    },
                    else => return err,
                };
                for (contents[0 .. visible + 1], view.revisions[0 .. visible + 1]) |value, *seen| seen.* = value.revision;
            } else {
                for (contents[0 .. visible + 1], 0..) |value, at| {
                    const virtual = view.kind == .crafting and at == 0;
                    if (virtual) {
                        if (std.meta.eql(view.preview, value.stack)) continue;
                    } else if (view.revisions[at] == value.revision) continue;
                    const prepared = if (value.stack) |stack| try self.deps.inventory.deps.items.acquire(stack) else null;
                    defer if (prepared) |held| held.release();
                    const item_view = if (prepared) |held| held.view else null;
                    if (at == visible) {
                        self.deps.packets.sendPacket(PlayerInventory.writeCursor, player.protocol, handle, .{ self.deps.inventory.deps.items, value.stack, player.uuid, item_view }, self.deps.sessions.config.page_bytes) catch |err| switch (err) {
                            error.Backpressured, error.Closed => {
                                view.dirty = true;
                                return;
                            },
                            else => return err,
                        };
                    } else {
                        self.deps.packets.sendPacket(PlayerInventory.writeWindowSlot, player.protocol, handle, .{ self.deps.inventory.deps.items, view.window, revision, @as(i16, @intCast(at)), value.stack, player.uuid, item_view }, self.deps.sessions.config.page_bytes) catch |err| switch (err) {
                            error.Backpressured, error.Closed => {
                                view.dirty = true;
                                return;
                            },
                            else => return err,
                        };
                    }
                    view.revisions[at] = value.revision;
                }
            }
            view.preview = contents[0].stack;
            view.revision = revision;
            view.dirty = false;
            view.initial = false;
            view.presentation = self.deps.inventory.deps.items.components.revision;
        }
        if (view.kind == .furnace) {
            const value = self.furnaceState(view.key.world, view.key.position);
            const properties = [_]u32{ value.burn_left, value.burn_total, value.cook, value.duration };
            for (properties, 0..) |property, at| {
                const number: i32 = @intCast(@min(property, std.math.maxInt(i16)));
                if (number == view.properties[at]) continue;
                self.deps.packets.sendPacket(writeProperty, player.protocol, handle, .{ view.window, @as(i16, @intCast(at)), @as(i16, @intCast(number)) }, 32) catch |err| switch (err) {
                    error.Backpressured, error.Closed => {
                        view.dirty = true;
                        return;
                    },
                    else => return err,
                };
                view.properties[at] = number;
            }
        }
    }

    pub fn checkpoint(self: *Containers, _: storage.Space) !void {
        try self.rewards.flush();
        var keys: [records.Table.write_batch_size][16]u8 = undefined;
        var values: [records.Table.write_batch_size][furnace.encoded_bytes]u8 = undefined;
        var writes: [records.Table.write_batch_size]records.Write = undefined;
        var count: usize = 0;
        errdefer self.deps.storage.fail();
        for (self.saved[0..self.saved_count]) |key| {
            if (self.active_index.contains(key)) continue;
            keys[count] = key.encode();
            writes[count] = .{ .key = &keys[count], .value = null };
            count += 1;
            if (count == writes.len) {
                try self.table.putBatch(writes[0..count]);
                count = 0;
            }
        }
        for (self.active[0..self.active_count]) |entry| {
            keys[count] = entry.key.encode();
            entry.state.encode(&values[count]);
            writes[count] = .{ .key = &keys[count], .value = &values[count] };
            count += 1;
            if (count == writes.len) {
                try self.table.putBatch(writes[0..count]);
                count = 0;
            }
        }
        if (count != 0) try self.table.putBatch(writes[0..count]);
        for (self.active[0..self.active_count], self.saved[0..self.active_count]) |entry, *key| key.* = entry.key;
        self.saved_count = self.active_count;
    }
};

fn writeOpen(packet: wire.play.toClient.packet_open_window.Writer, window: i32, kind: i32, title: []const u8) ![]u8 {
    var bytes: [96]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writer.writeAll(&.{ 10, 8, 0, 9 });
    try writer.writeAll("translate");
    try writer.writeInt(u16, @intCast(title.len), .big);
    try writer.writeAll(title);
    try writer.writeByte(0);
    return (try (try (try packet.windowId(window)).inventoryType(kind)).windowTitle(writer.buffered())).finish();
}

fn writeLid(packet: wire.play.toClient.packet_block_action.Writer, registry: packets.Registry, position: chunks.Position, viewers: u8) ![]u8 {
    const canonical = game_data.registry.block_state_to_block[game_data.registry.block_chest_default_state];
    return (try (try (try (try packet.location(.{ .x = position.x, .y = @intCast(position.y), .z = position.z })).byte1(1)).byte2(@intCast(viewers))).blockId(try registry.blockId(@intCast(canonical)))).finish();
}

fn writeClose(packet: wire.play.toClient.packet_close_window.Writer, window: i32) ![]u8 {
    return (try packet.windowId(window)).finish();
}

fn writeProperty(packet: wire.play.toClient.packet_craft_progress_bar.Writer, window: i32, property: i16, value: i16) ![]u8 {
    return (try (try (try packet.windowId(window)).property(property)).value(value)).finish();
}
