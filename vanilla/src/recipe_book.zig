const protocols = @import("protocols");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const storage = @import("storage");
const records = @import("records");
const inventories = @import("inventories");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const game_data = @import("game_data");
const chunks = @import("chunks");
const wire = @import("wire_1_21_5");
const RecipeBookRegistry = @import("recipe_book_registry.zig").RecipeBookRegistry;
const Players = @import("players.zig").Players;
const Items = @import("items.zig").Items;
const Input = @import("input.zig").Input;
const InventoryMenus = @import("inventory_menus.zig").InventoryMenus;
const book_packets = @import("recipe_book_packets.zig");
const unlocks = @import("recipe_unlocks.zig");
const assert = std.debug.assert;
const absent = std.math.maxInt(usize);

pub const RecipeBook = struct {
    pub const Registry = RecipeBookRegistry;
    pub const id = "minecraft:recipe_book";
    pub const Configuration = struct { packet_bytes: usize = 64 * 1024, state_bytes: usize = 256 * 1024 };
    pub const Dependencies = struct {
        definitions: *Registry,
        players: *Players,
        inventory: *InventoryMenus,
        inventories: *inventories.Inventories,
        items: *Items,
        chunks: *chunks.Chunks,
        input: *Input,
        packets: *packets.Packets,
        storage: storage.Space,
        record_workspaces: *records.Workspaces,
    };
    pub const Kind = enum(u2) { crafting, furnace, blast_furnace, smoker };
    pub const Setting = struct { open: bool = false, craftable: bool = false };
    const BlockSample = struct {
        section: chunks.Section,
        index: u12,
        valid: bool = false,
        previous: usize = absent,
        next: usize = absent,
    };
    const BlockQueries = lightning_rod.system.BatchIndex(chunks.Section, usize, std.hash_map.AutoContext(chunks.Section));
    const State = struct {
        uuid: u128 = 0,
        loaded: bool = false,
        watching: bool = false,
        generation: u32 = 0,
        dirty: bool = false,
        progress_dirty: bool = true,
        network_dirty: bool = true,
        settings_dirty: bool = true,
        inventory_dirty: u64 = 0,
        settings: u8 = 0,
        phase: u8 = 0,
        block_pending: bool = false,
        block_sample: ?BlockSample = null,
        block_next: usize = absent,
    };
    const held_slots: [41]u16 = block: {
        var values: [41]u16 = undefined;
        for (&values, 0..) |*value, index| value.* = @intCast(index + 5);
        break :block values;
    };
    const learned: u8 = 1;
    const highlighted: u8 = 2;
    const sent: u8 = 4;
    const notification: u8 = 8;
    allocator: std.mem.Allocator,
    content_memory: std.heap.ArenaAllocator,
    deps: Dependencies,
    config: Configuration,
    states: []State,
    flags: []u8,
    progress: []bool,
    awarded: []bool,
    candidate: []bool,
    active: lightning_rod.system.IndexSet,
    block_watches: std.AutoArrayHashMapUnmanaged(chunks.Section, usize) = .empty,
    block_queries: BlockQueries,
    block_leases: []chunks.Lease,
    observer: *inventories.Inventories.Observer,
    table: records.Table,
    state_bytes: []u8,
    displays: []const book_packets.Display,
    available: [protocols.implementations.len][]bool,
    availability_ready: bool = false,
    names: std.StringHashMapUnmanaged(u32) = .empty,
    identities: [][32]u8,
    identity_index: std.AutoHashMapUnmanaged([32]u8, usize) = .empty,
    criterion_index: std.AutoHashMapUnmanaged([32]u8, usize) = .empty,
    rule_index: std.AutoHashMapUnmanaged([32]u8, usize) = .empty,

    pub const allocate = init;

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*RecipeBook {
        if (config.packet_bytes < 64) return error.InvalidRecipeBookCapacity;
        const self = try allocator.create(RecipeBook);
        const players = deps.players.records.len;
        self.* = .{
            .allocator = allocator,
            .content_memory = .init(allocator),
            .deps = deps,
            .config = config,
            .states = try allocator.alloc(State, players),
            .flags = &.{},
            .progress = &.{},
            .awarded = &.{},
            .candidate = &.{},
            .active = try .init(allocator, players),
            .block_queries = try .init(allocator, players),
            .block_leases = try allocator.alloc(chunks.Lease, @min(players, deps.chunks.cache.entries.len)),
            .observer = try deps.inventories.observe(allocator, players),
            .table = records.Table.init(deps.storage, deps.record_workspaces.resources),
            .state_bytes = try allocator.alloc(u8, config.state_bytes),
            .displays = &.{},
            .identities = &.{},
            .available = @splat(&.{}),
        };
        @memset(self.states, .{});
        try self.block_watches.ensureTotalCapacity(allocator, players);
        try deps.chunks.observe(.init(self, blocksChanged));
        try self.definitionsChanged();
        try deps.definitions.registry.onChange(self, definitionsChanged);
        try deps.definitions.registry.checkWith(self, validate);
        try deps.input.on(.craft_recipe_request, self, onPlace);
        try deps.input.on(.recipe_book, self, onSettings);
        try deps.input.on(.displayed_recipe, self, onDisplayed);
        return self;
    }

    fn definitionsChanged(self: *RecipeBook) !void {
        for (self.states) |state| assert(!state.loaded);
        var memory = std.heap.ArenaAllocator.init(self.allocator);
        errdefer memory.deinit();
        const allocator = memory.allocator();
        const recipes = self.deps.definitions.table.book;
        const rules = self.deps.definitions.unlocks;
        const maximum_state = try std.math.add(usize, 32 + try std.math.mul(usize, recipes.len, 33), try std.math.mul(usize, rules.criteria.len + rules.rules.len, 32));
        if (self.config.state_bytes < maximum_state) return error.InvalidRecipeBookCapacity;
        var next = self.*;
        next.availability_ready = false;
        next.names = .empty;
        next.identity_index = .empty;
        next.criterion_index = .empty;
        next.rule_index = .empty;
        next.flags = try allocator.alloc(u8, try std.math.mul(usize, self.states.len, recipes.len));
        next.progress = try allocator.alloc(bool, try std.math.mul(usize, self.states.len, rules.criteria.len));
        next.awarded = try allocator.alloc(bool, try std.math.mul(usize, self.states.len, rules.rules.len));
        next.candidate = try allocator.alloc(bool, rules.criteria.len);
        next.displays = try book_packets.prepare(allocator, &self.deps.definitions.table, self.deps.items);
        next.identities = try allocator.alloc([32]u8, recipes.len);
        @memset(next.flags, 0);
        @memset(next.progress, false);
        @memset(next.awarded, false);
        try next.names.ensureTotalCapacity(allocator, @intCast(recipes.len));
        try next.identity_index.ensureTotalCapacity(allocator, @intCast(recipes.len));
        try next.criterion_index.ensureTotalCapacity(allocator, @intCast(rules.criteria.len));
        try next.rule_index.ensureTotalCapacity(allocator, @intCast(rules.rules.len));
        for (recipes, next.identities, next.displays, 0..) |recipe, *identity, display, index| {
            if (display.base_bytes + 16 > self.config.packet_bytes) return error.RecipeDisplayTooLarge;
            next.names.putAssumeCapacityNoClobber(recipe.name, @intCast(index));
            std.crypto.hash.Blake3.hash(recipe.name, identity, .{});
            assert(!next.identity_index.contains(identity.*));
            next.identity_index.putAssumeCapacityNoClobber(identity.*, index);
        }
        for (rules.criteria, 0..) |criterion, index| {
            assert(!next.criterion_index.contains(criterion.identity));
            next.criterion_index.putAssumeCapacityNoClobber(criterion.identity, index);
        }
        for (rules.rules, 0..) |rule, index| {
            assert(!next.rule_index.contains(rule.identity));
            next.rule_index.putAssumeCapacityNoClobber(rule.identity, index);
        }
        for (&next.available) |*values| values.* = try allocator.alloc(bool, recipes.len);
        next.content_memory = memory;
        self.content_memory.deinit();
        self.* = next;
    }

    fn validate(self: *RecipeBook) !void {
        for (self.displays) |display| {
            const maximum = try display.maximumBytes(self.deps.items.components.extra_bytes);
            if (try std.math.add(usize, maximum, 16) > self.config.packet_bytes) return error.RecipeDisplayTooLarge;
        }
    }

    fn prepareAvailability(self: *RecipeBook) void {
        if (self.availability_ready) return;
        inline for (protocols.implementations, 0..) |Version, index| {
            for (self.deps.definitions.table.book, self.displays, self.available[index]) |recipe, display, *value| value.* = book_packets.available(display, recipe, Version.Registry.canonical_item_to_wire, self.deps.items, Version.protocol_number);
        }
        self.availability_ready = true;
    }

    fn availableFor(self: *const RecipeBook, protocol: i32) []const bool {
        assert(self.availability_ready);
        inline for (protocols.implementations, 0..) |Version, index| if (protocol == Version.protocol_number) return self.available[index];
        unreachable;
    }

    pub fn recipeId(self: *const RecipeBook, name: []const u8) ?u32 {
        return self.names.get(name);
    }
    pub fn knows(self: *RecipeBook, player: usize, recipe: u32) !bool {
        try self.bind(player);
        return self.known(player, recipe);
    }
    fn known(self: *const RecipeBook, player: usize, recipe: u32) bool {
        assert(player < self.states.len and recipe < self.deps.definitions.table.book.len);
        assert(self.states[player].loaded and self.states[player].uuid == self.deps.players.records[player].uuid);
        return self.flags[player * self.identities.len + recipe] & learned != 0;
    }
    pub fn grantMany(self: *RecipeBook, player: usize, recipes: []const u32) !void {
        try self.bind(player);
        for (recipes) |recipe| {
            assert(recipe < self.identities.len);
            self.grant(player, recipe, true);
        }
        self.propagate(player);
    }
    pub fn revokeMany(self: *RecipeBook, player: usize, recipes: []const u32) !void {
        try self.bind(player);
        const flags = self.row(player);
        for (recipes) |recipe| {
            assert(recipe < flags.len);
            if (flags[recipe] & learned == 0) continue;
            flags[recipe] &= sent;
            self.states[player].dirty = true;
            self.states[player].network_dirty = true;
        }
    }

    pub fn grantAll(self: *RecipeBook, player: usize) !void {
        try self.bind(player);
        for (0..self.identities.len) |recipe| self.grant(player, recipe, true);
        self.propagate(player);
    }

    pub fn revokeAll(self: *RecipeBook, player: usize) !void {
        try self.bind(player);
        for (self.row(player)) |*flags| {
            if (flags.* & learned == 0) continue;
            flags.* &= sent;
            self.states[player].dirty = true;
            self.states[player].network_dirty = true;
        }
    }

    pub fn setting(self: *RecipeBook, player: usize, kind: Kind) !Setting {
        try self.bind(player);
        const value = self.states[player].settings >> (@as(u3, @backingInt(kind)) * 2);
        return .{ .open = value & 1 != 0, .craftable = value & 2 != 0 };
    }

    pub fn configure(self: *RecipeBook, player: usize, kind: Kind, value: Setting) !void {
        try self.bind(player);
        const state = &self.states[player];
        const shift: u3 = @as(u3, @backingInt(kind)) * 2;
        const encoded: u8 = @intFromBool(value.open) | (@as(u8, @intFromBool(value.craftable)) << 1);
        const next = (state.settings & ~(@as(u8, 3) << shift)) | (encoded << shift);
        if (next == state.settings) return;
        state.settings = next;
        state.dirty = true;
        state.settings_dirty = true;
    }

    fn row(self: *const RecipeBook, player: usize) []u8 {
        return self.flags[player * self.identities.len ..][0..self.identities.len];
    }
    fn criteria(self: *const RecipeBook, player: usize) []bool {
        const length = self.deps.definitions.unlocks.criteria.len;
        return self.progress[player * length ..][0..length];
    }
    fn rewards(self: *const RecipeBook, player: usize) []bool {
        const length = self.deps.definitions.unlocks.rules.len;
        return self.awarded[player * length ..][0..length];
    }
    fn grant(self: *RecipeBook, player: usize, recipe: usize, notify: bool) void {
        const flags = self.row(player);
        if (flags[recipe] & learned != 0) return;
        flags[recipe] |= learned | if (notify) (highlighted | notification) else @as(u8, 0);
        self.states[player].dirty = true;
        self.states[player].progress_dirty = true;
        self.states[player].network_dirty = true;
    }

    fn bind(self: *RecipeBook, player: usize) !void {
        assert(player < self.states.len);
        const profile = self.deps.players.records[player];
        assert(profile.handle != null);
        const state = &self.states[player];
        if (!state.loaded or state.uuid != profile.uuid) {
            if (state.loaded and state.dirty) try self.save(player);
            if (state.watching) self.observer.unwatch(state.uuid);
            self.unwatchBlock(state);
            state.* = .{ .uuid = profile.uuid, .loaded = true };
            @memset(self.row(player), 0);
            @memset(self.criteria(player), false);
            @memset(self.rewards(player), false);
            var key: [16]u8 = undefined;
            std.mem.writeInt(u128, &key, profile.uuid, .big);
            if (try self.table.get(&key, self.state_bytes)) |length| {
                var reader = std.Io.Reader.fixed(self.state_bytes[0..length]);
                if (!std.mem.eql(u8, try reader.take(8), "LRBOOK01")) return error.CorruptRecipeBook;
                state.settings = try reader.takeByte();
                const known_count = try reader.takeInt(u32, .big);
                if (known_count > reader.bufferedLen() / 33) return error.CorruptRecipeBook;
                for (0..known_count) |_| {
                    const identity = (try reader.take(32))[0..32].*;
                    const flags = try reader.takeByte();
                    if (flags & ~@as(u8, 3) != 0 or flags & learned == 0) return error.CorruptRecipeBook;
                    if (self.identity_index.get(identity)) |index| self.row(player)[index] = flags;
                }
                const progress_count = try reader.takeInt(u32, .big);
                if (progress_count > reader.bufferedLen() / 32) return error.CorruptRecipeBook;
                for (0..progress_count) |_| {
                    const identity = (try reader.take(32))[0..32].*;
                    if (self.criterion_index.get(identity)) |index| self.criteria(player)[index] = true;
                }
                const reward_count = try reader.takeInt(u32, .big);
                if (reward_count > reader.bufferedLen() / 32) return error.CorruptRecipeBook;
                for (0..reward_count) |_| {
                    const identity = (try reader.take(32))[0..32].*;
                    if (self.rule_index.get(identity)) |index| self.rewards(player)[index] = true;
                }
                if (reader.seek != reader.end) return error.CorruptRecipeBook;
            } else {
                state.dirty = true;
                for (self.deps.definitions.table.book, 0..) |recipe, index| if (recipe.initially_unlocked) self.grant(player, index, false);
            }
            const progress = self.criteria(player);
            state.block_pending = for (self.deps.definitions.unlocks.blocks) |criterion| {
                if (!progress[criterion]) break true;
            } else false;
        }
        if (!state.watching) {
            self.observer.watch(state.uuid, &held_slots, .{ .dirty = &state.inventory_dirty });
            state.watching = true;
        }
        if (profile.handle) |handle| if (state.generation != handle.generation or !self.active.contains(player)) {
            state.generation = handle.generation;
            state.phase = 0;
            state.network_dirty = true;
            for (self.row(player)) |*value| value.* &= learned | highlighted;
            self.active.insert(player);
        };
    }

    fn save(self: *RecipeBook, player: usize) !void {
        const state = &self.states[player];
        assert(state.loaded);
        var writer = std.Io.Writer.fixed(self.state_bytes);
        try writer.writeAll("LRBOOK01");
        try writer.writeByte(state.settings);
        var count: u32 = 0;
        for (self.row(player)) |flags| count += @intFromBool(flags & learned != 0);
        try writer.writeInt(u32, count, .big);
        for (self.row(player), self.identities) |flags, *identity| if (flags & learned != 0) {
            try writer.writeAll(identity);
            try writer.writeByte(flags & (learned | highlighted));
        };
        count = 0;
        for (self.criteria(player)) |value| count += @intFromBool(value);
        try writer.writeInt(u32, count, .big);
        for (self.criteria(player), self.deps.definitions.unlocks.criteria) |value, criterion| if (value) {
            try writer.writeAll(&criterion.identity);
        };
        count = 0;
        for (self.rewards(player)) |value| count += @intFromBool(value);
        try writer.writeInt(u32, count, .big);
        for (self.rewards(player), self.deps.definitions.unlocks.rules) |value, rule| if (value) {
            try writer.writeAll(&rule.identity);
        };
        var key: [16]u8 = undefined;
        std.mem.writeInt(u128, &key, state.uuid, .big);
        try self.table.put(&key, writer.buffered());
        state.dirty = false;
    }

    pub fn checkpoint(self: *RecipeBook, _: storage.Space) !void {
        for (self.states, 0..) |state, index| if (state.loaded and state.dirty) try self.save(index);
    }

    fn validHandle(self: *const RecipeBook, handle: sessions.Handle) bool {
        assert(handle.index < self.states.len);
        const current = self.deps.players.records[handle.index].handle orelse return false;
        return std.meta.eql(current, handle);
    }

    fn onSettings(self: *RecipeBook, handle: sessions.Handle, packet: wire.play.toServer.packet_recipe_book.Reader) !void {
        if (!self.validHandle(handle)) return;
        const book, const a = try packet.bookId();
        const open, const b = try a.bookOpen();
        const filter, const done = try b.filterActive();
        try done.finish();
        if (book < 0 or book > 3) return error.InvalidPacket;
        try self.configure(handle.index, @fromBackingInt(@intCast(book)), .{ .open = open, .craftable = filter });
    }
    fn onDisplayed(self: *RecipeBook, handle: sessions.Handle, packet: wire.play.toServer.packet_displayed_recipe.Reader) !void {
        if (!self.validHandle(handle)) return;
        const id_recipe, const done = try packet.recipeId();
        try done.finish();
        if (id_recipe < 0 or id_recipe >= self.identities.len) return;
        try self.bind(handle.index);
        const flags = &self.row(handle.index)[@intCast(id_recipe)];
        if (flags.* & highlighted != 0) {
            flags.* &= ~(highlighted | notification);
            self.states[handle.index].dirty = true;
        }
    }
    fn onPlace(self: *RecipeBook, handle: sessions.Handle, packet: wire.play.toServer.packet_craft_recipe_request.Reader) !void {
        if (!self.validHandle(handle)) return;
        const window, const a = try packet.windowId();
        const recipe, const b = try a.recipeId();
        const all, const done = try b.makeAll();
        try done.finish();
        if (recipe < 0 or recipe >= self.identities.len) return;
        try self.bind(handle.index);
        self.prepareAvailability();
        if (!self.known(handle.index, @intCast(recipe)) or !self.availableFor(self.deps.players.records[handle.index].protocol)[@intCast(recipe)]) return;
        const result = try self.deps.inventory.placeRecipe(handle, @intCast(window), &self.deps.definitions.table, &self.deps.definitions.table.book[@intCast(recipe)], all);
        if (result == .missing) {
            const context: book_packets.Context = .{ .table = &self.deps.definitions.table, .displays = self.displays, .items = self.deps.items, .recipient = self.states[handle.index].uuid };
            try self.deps.packets.sendPacketRetrying(book_packets.ghost, self.deps.players.records[handle.index].protocol, handle, .{ context, @as(i32, @intCast(window)), @as(usize, @intCast(recipe)) }, (try self.displays[@intCast(recipe)].maximumBytes(self.deps.items.components.extra_bytes)) + 16);
        }
    }

    pub fn tick(self: *RecipeBook) !void {
        self.prepareAvailability();
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            if (player.handle == null or player.stage != .ready) continue;
            try self.bind(index);
        }
        var offset: usize = 0;
        while (offset < self.active.values().len) {
            const index = self.active.values()[offset];
            const player = self.deps.players.records[index];
            const state = &self.states[index];
            if (player.handle == null or player.uuid != state.uuid) {
                if (state.watching) {
                    self.observer.unwatch(state.uuid);
                    state.watching = false;
                }
                self.unwatchBlock(state);
                self.active.remove(index);
                continue;
            }
            offset += 1;
            if (player.stage != .ready) continue;
            const rules = &self.deps.definitions.unlocks;
            const progress = self.criteria(index);
            for (rules.ticks) |criterion| if (!progress[criterion]) {
                progress[criterion] = true;
                state.dirty = true;
                state.progress_dirty = true;
            };
            if (state.inventory_dirty != 0) try self.inventoryChanged(index);
        }
        try self.updateBlocks();
        for (self.active.values()) |index| {
            if (self.deps.players.records[index].stage != .ready) continue;
            self.propagate(index);
            self.send(index) catch |err| switch (err) {
                error.Backpressured, error.Closed => {},
                else => return err,
            };
        }
    }

    fn blocksChanged(self: *RecipeBook, section: chunks.Section, edits: []const chunks.BlockEdit) void {
        var index = self.block_watches.get(section) orelse return;
        assert(index != absent);
        var changed: std.StaticBitSet(4096) = .empty;
        for (edits) |edit| changed.set(edit.index);
        // Keep samples indexed until the next tick so edits during a teleport are not missed.
        var previous: usize = absent;
        while (index != absent) {
            const sample = &self.states[index].block_sample.?;
            assert(std.meta.eql(sample.section, section) and sample.previous == previous);
            if (changed.isSet(sample.index)) sample.valid = false;
            previous = index;
            index = sample.next;
        }
    }

    fn unwatchBlock(self: *RecipeBook, state: *State) void {
        const sample = state.block_sample orelse return;
        if (sample.previous != absent) {
            const previous = &self.states[sample.previous].block_sample.?;
            assert(previous.next != absent and &self.states[previous.next] == state);
            previous.next = sample.next;
        } else {
            const head = self.block_watches.getPtr(sample.section).?;
            assert(head.* != absent and &self.states[head.*] == state);
            if (sample.next != absent) {
                head.* = sample.next;
            } else {
                const removed = self.block_watches.swapRemove(sample.section);
                assert(removed);
            }
        }
        if (sample.next != absent) {
            const next = &self.states[sample.next].block_sample.?;
            assert(next.previous != absent and &self.states[next.previous] == state);
            next.previous = sample.previous;
        }
        state.block_sample = null;
    }

    fn updateBlocks(self: *RecipeBook) !void {
        self.block_queries.clear();
        for (self.active.values()) |index| {
            const player = &self.deps.players.records[index];
            const state = &self.states[index];
            if (player.stage != .ready or !player.loaded or !state.block_pending) {
                self.unwatchBlock(state);
                continue;
            }
            const position: chunks.Position = .{ .x = @intFromFloat(@floor(player.position.x)), .y = @intFromFloat(@floor(player.position.y)), .z = @intFromFloat(@floor(player.position.z)) };
            const section = chunks.sectionAt(player.world, position);
            const at = chunks.localIndex(position);
            if (state.block_sample) |sample| if (!std.meta.eql(sample.section, section)) self.unwatchBlock(state);
            if (state.block_sample == null) {
                const watch = self.block_watches.getOrPutAssumeCapacity(section);
                if (!watch.found_existing) watch.value_ptr.* = absent;
                const head = watch.value_ptr.*;
                state.block_sample = .{ .section = section, .index = at, .next = head };
                if (head != absent) {
                    assert(head != index and self.states[head].block_sample.?.previous == absent);
                    self.states[head].block_sample.?.previous = index;
                }
                watch.value_ptr.* = index;
            }
            const sample = &state.block_sample.?;
            if (sample.valid and sample.index == at) continue;
            sample.index = at;
            sample.valid = false;
            const query = self.block_queries.getOrPut(section);
            if (!query.found_existing) query.value_ptr.* = absent;
            assert(state.block_next == absent);
            state.block_next = query.value_ptr.*;
            query.value_ptr.* = index;
        }
        var offset: usize = 0;
        while (offset < self.block_queries.count()) {
            const count = @min(self.block_leases.len, self.deps.chunks.cache.entries.len, self.block_queries.count() - offset);
            assert(count > 0);
            const sections = self.block_queries.keys[offset..][0..count];
            const leases = self.block_leases[0..count];
            try self.deps.chunks.acquireMany(sections, leases);
            defer self.deps.chunks.releaseMany(leases);
            for (sections, leases, self.block_queries.values()[offset..][0..count]) |section, lease, head| {
                var index = head;
                while (index != absent) {
                    const state = &self.states[index];
                    const sample = &state.block_sample.?;
                    assert(std.meta.eql(sample.section, section) and !sample.valid);
                    const block = game_data.registry.block_state_to_block[lease.get(sample.index)];
                    sample.valid = true;
                    state.block_pending = false;
                    const progress = self.criteria(index);
                    for (self.deps.definitions.unlocks.blocks) |criterion| {
                        if (!progress[criterion] and self.deps.definitions.unlocks.criteria[criterion].trigger.block == block) {
                            progress[criterion] = true;
                            state.dirty = true;
                            state.progress_dirty = true;
                        }
                        state.block_pending = state.block_pending or !progress[criterion];
                    }
                    if (!state.block_pending) self.unwatchBlock(state);
                    const next = state.block_next;
                    state.block_next = absent;
                    index = next;
                }
            }
            offset += count;
        }
    }

    fn inventoryChanged(self: *RecipeBook, player: usize) !void {
        const rules = &self.deps.definitions.unlocks;
        var slots: [41]inventories.Slot = undefined;
        var contents: [41]inventories.Contents = undefined;
        for (&slots, held_slots) |*slot, index| slot.* = .{ .owner = self.states[player].uuid, .index = index };
        try self.deps.inventories.getMany(&slots, &contents);
        var stacks: [41]inventories.Stack = undefined;
        var kinds: [41]u32 = undefined;
        var changed: [41]bool = undefined;
        var count: usize = 0;
        for (contents, 0..) |value, index| if (value.stack) |stack| {
            stacks[count] = stack;
            changed[count] = self.states[player].inventory_dirty & (@as(u64, 1) << @intCast(index)) != 0;
            count += 1;
        };
        var full: usize = 0;
        var offset: usize = 0;
        while (offset < count) {
            const end = offset + @min(count - offset, @min(self.deps.items.views.len, self.deps.inventories.items.entries.len));
            var prepared: [41]Items.Prepared = undefined;
            const batch = prepared[0 .. end - offset];
            try self.deps.items.acquireMany(stacks[offset..end], batch);
            defer for (batch) |item| item.release();
            for (batch, stacks[offset..end], kinds[offset..end]) |item, stack, *kind| {
                kind.* = item.view.kind;
                full += @intFromBool(stack.count >= try self.deps.items.maximum(item.view));
            }
            offset = end;
        }
        @memset(self.candidate, false);
        for (rules.inventory) |criterion| self.candidate[criterion] = true;
        for (kinds[0..count]) |kind| for (rules.by_item[kind]) |criterion| {
            self.candidate[criterion] = true;
        };
        for (self.candidate, self.criteria(player), rules.criteria) |candidate, *progress, criterion| {
            if (!candidate or progress.* or criterion.trigger != .inventory) continue;
            const condition = criterion.trigger.inventory;
            if (!condition.occupied.contains(count) or !condition.empty.contains(41 - count) or !condition.full.contains(full)) continue;
            var matches = true;
            for (condition.items) |predicate| {
                const found = for (stacks[0..count], kinds[0..count], changed[0..count]) |stack, kind, updated| {
                    if (condition.items.len == 1 and !updated) continue;
                    if (!predicate.count.contains(stack.count)) continue;
                    if (predicate.kinds) |values| if (std.mem.indexOfScalar(u32, values, kind) == null) continue;
                    if (predicate.components.len != 0) {
                        const item = try self.deps.items.acquire(stack);
                        defer item.release();
                        var valid = true;
                        for (predicate.components) |component| {
                            const value = item.view.get(component.key) orelse {
                                valid = false;
                                break;
                            };
                            if ((value.value == null) != (component.value == null)) {
                                valid = false;
                                break;
                            }
                            if (value.value) |bytes| if (!std.mem.eql(u8, bytes, component.value.?)) {
                                valid = false;
                                break;
                            };
                        }
                        if (!valid) continue;
                    }
                    break true;
                } else false;
                if (!found) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                progress.* = true;
                self.states[player].dirty = true;
                self.states[player].progress_dirty = true;
            }
        }
        self.states[player].inventory_dirty = 0;
    }

    fn propagate(self: *RecipeBook, player: usize) void {
        if (!self.states[player].progress_dirty) return;
        const rules = &self.deps.definitions.unlocks;
        const progress = self.criteria(player);
        const awarded = self.rewards(player);
        var changed = true;
        var passes: usize = 0;
        while (changed) {
            assert(passes <= rules.rules.len + 1);
            passes += 1;
            changed = false;
            for (rules.known) |criterion| if (!progress[criterion] and self.known(player, rules.criteria[criterion].trigger.recipe)) {
                progress[criterion] = true;
                self.states[player].dirty = true;
                changed = true;
            };
            for (rules.rules, awarded) |rule, *done| {
                if (done.*) continue;
                const satisfied = for (rule.requirements) |group| {
                    const any = for (group) |criterion| {
                        if (progress[criterion]) break true;
                    } else false;
                    if (!any) break false;
                } else true;
                if (!satisfied) continue;
                done.* = true;
                self.states[player].dirty = true;
                changed = true;
                for (rule.recipes) |recipe| self.grant(player, recipe, true);
            }
        }
        self.states[player].progress_dirty = false;
    }

    fn send(self: *RecipeBook, player: usize) !void {
        const profile = self.deps.players.records[player];
        const handle = profile.handle.?;
        const state = &self.states[player];
        if (state.phase == 3 and !state.network_dirty and !state.settings_dirty) return;
        const context: book_packets.Context = .{ .table = &self.deps.definitions.table, .displays = self.displays, .items = self.deps.items, .recipient = profile.uuid };
        if (state.phase == 0) {
            try self.deps.packets.sendPacket(book_packets.properties, profile.protocol, handle, .{&self.deps.definitions.table}, self.config.packet_bytes);
            state.phase = 1;
        }
        if (state.phase == 1) {
            try self.deps.packets.sendPacket(book_packets.settings, profile.protocol, handle, .{state.settings}, 16);
            state.phase = 2;
            state.settings_dirty = false;
        }
        if (state.phase == 3 and state.settings_dirty) {
            try self.deps.packets.sendPacket(book_packets.settings, profile.protocol, handle, .{state.settings}, 16);
            state.settings_dirty = false;
        }
        if (state.phase == 2) {
            try self.deps.packets.sendPacket(book_packets.add, profile.protocol, handle, .{ context, &[_]u32{}, &[_]u8{}, true }, 16);
            state.phase = 3;
        }
        var ids: [32]u32 = undefined;
        var entry_flags: [32]u8 = undefined;
        var count: usize = 0;
        var maximum_bytes: usize = 16;
        const flags = self.row(player);
        const available = self.availableFor(profile.protocol);
        for (flags, 0..) |value, index| {
            if (value & (learned | sent) != learned or !available[index]) continue;
            const size = try self.displays[index].maximumBytes(self.deps.items.components.extra_bytes);
            if (count == ids.len or size > self.config.packet_bytes - maximum_bytes) {
                try self.deps.packets.sendPacket(book_packets.add, profile.protocol, handle, .{ context, ids[0..count], entry_flags[0..count], false }, maximum_bytes);
                for (ids[0..count]) |id_recipe| flags[id_recipe] = (flags[id_recipe] | sent) & ~notification;
                count = 0;
                maximum_bytes = 16;
            }
            ids[count] = @intCast(index);
            entry_flags[count] = (value & highlighted) | @as(u8, @intFromBool(value & notification != 0));
            count += 1;
            maximum_bytes += size;
        }
        if (count != 0) {
            try self.deps.packets.sendPacket(book_packets.add, profile.protocol, handle, .{ context, ids[0..count], entry_flags[0..count], false }, maximum_bytes);
            for (ids[0..count]) |id_recipe| flags[id_recipe] = (flags[id_recipe] | sent) & ~notification;
        }
        count = 0;
        for (flags, 0..) |value, index| {
            if (value & (learned | sent) != sent) continue;
            ids[count] = @intCast(index);
            count += 1;
            if (count == ids.len) {
                try self.deps.packets.sendPacket(book_packets.remove, profile.protocol, handle, .{ids[0..count]}, 8 + count * 5);
                for (ids[0..count]) |id_recipe| flags[id_recipe] &= ~sent;
                count = 0;
            }
        }
        if (count != 0) {
            try self.deps.packets.sendPacket(book_packets.remove, profile.protocol, handle, .{ids[0..count]}, 8 + count * 5);
            for (ids[0..count]) |id_recipe| flags[id_recipe] &= ~sent;
        }
        state.network_dirty = false;
    }
};
