const std = @import("std");
const item_entities = @import("item_entities.zig");
const inventories = @import("inventories");
const protocols = @import("protocols");
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;
const Items = @import("items.zig").Items;

const support = protocols.support;
const assert = std.debug.assert;

pub const Menus = struct {
    pub const id = "minecraft:menus";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *Players,
        input: *Input,
        inventories: *inventories.Inventories,
        items: *Items,
        dropped: *item_entities.ItemEntities,
    };

    const State = struct {
        generation: u32 = 0,
        life: u32 = 0,
        revision: i32 = 0,
        dirty: bool = true,
        drag: u64 = 0,
        drag_button: ?i8 = null,
        selected: u4 = 0,
    };

    const cursor = 46;
    deps: Dependencies,
    states: []State,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Menus {
        if (deps.inventories.cache.entries.len < 47) return error.InventoryCacheTooSmall;

        const self = try allocator.create(Menus);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        self.* = .{ .deps = deps, .states = states };
        return self;
    }

    pub fn tick(self: *Menus) !void {
        const service = self.deps.players.deps.sessions;

        connections: for (self.deps.players.records, self.states) |*player, *state| {
            const handle = player.handle orelse continue;

            if (state.generation != handle.generation or state.life != player.life)
                state.* = .{ .generation = handle.generation, .life = player.life, .selected = player.selected_slot };

            const events = self.deps.input.values(handle);
            var needed = state.dirty;

            for (events) |event| needed = needed or event == .inventory_click or event == .creative_slot or event == .dig or event == .held_slot;
            if (!needed or player.stage != .ready) continue;

            var slots: [47]inventories.Slot = undefined;

            for (&slots, 0..) |*slot, index| slot.* = .{
                .owner = player.uuid,
                .index = if (index == cursor) std.math.maxInt(u16) else @intCast(index),
            };

            var contents: [47]inventories.Contents = undefined;
            try self.deps.inventories.getMany(&slots, &contents);

            for (events) |event| {
                var next: [47]?inventories.Stack = undefined;

                for (&next, contents) |*stack, value| stack.* = value.stack;

                switch (event) {
                    .held_slot => |selected| {
                        if (selected >= 0 and selected < 9) state.selected = @intCast(selected);
                        continue;
                    },
                    .creative_slot => |set| {
                        state.dirty = true;
                        if (player.gamemode != .creative or (set.slot != -1 and (set.slot < 1 or set.slot > 45))) continue;

                        const target: usize = if (set.slot == -1) cursor else @intCast(set.slot);
                        const count, const definition = support.read_varint(set.item) catch continue;
                        if (count < 0 or count > 99) continue;

                        if (count == 0) next[target] = null else {
                            const wire, const components = support.read_varint(definition) catch continue;
                            const item = canonicalItem(player.protocol, wire) orelse continue;
                            if (components.len + 4 > self.deps.inventories.config.max_item_bytes) continue;
                            if (components.len + 256 > service.config.page_bytes) continue;

                            var encoded: [64 * 1024]u8 = undefined;
                            if (components.len + 4 > encoded.len) continue;
                            std.mem.writeInt(u32, encoded[0..4], @intCast(item), .little);
                            @memcpy(encoded[4..][0..components.len], components);
                            const description = Items.describeBytes(encoded[0 .. 4 + components.len]) catch continue;
                            if (count > description.maximum) continue;
                            next[target] = .{
                                .item = try self.deps.inventories.defineItem(encoded[0 .. 4 + components.len]),
                                .count = @intCast(count),
                            };
                        }

                        if (set.slot == -1) {
                            if (next[target]) |stack| try self.drop(player.*, stack);
                            continue;
                        }
                    },
                    .dig => |dig| {
                        if (player.gamemode == .spectator or player.health == 0) continue;

                        const at = 36 + @as(usize, state.selected);

                        if (dig.action == .swap_hands) {
                            std.mem.swap(?inventories.Stack, &next[at], &next[45]);
                        } else if (dig.action == .drop_item or dig.action == .drop_stack) {
                            const held = next[at] orelse continue;
                            const amount = if (dig.action == .drop_stack) held.count else 1;
                            try self.drop(player.*, .{ .item = held.item, .count = amount });
                            next[at] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                        } else continue;
                        state.dirty = true;
                    },
                    .inventory_click => |click| {
                        state.dirty = true;
                        if (click.window_id != 0) continue;

                        if (click.mode == 5) {
                            if (click.button < 0 or click.button > 10) continue;

                            const button = @divTrunc(click.button, 4);
                            const phase = @mod(click.button, 4);
                            const held = next[cursor] orelse continue;
                            if (button == 2 and player.gamemode != .creative) continue;
                            if (phase == 0) {
                                state.drag = 0;
                                state.drag_button = button;
                                state.dirty = false;
                                continue;
                            }

                            if (state.drag_button == null or state.drag_button.? != button) continue;
                            if (phase == 1) {
                                if (click.slot < 9 or click.slot > 45) continue;

                                const target = next[@intCast(click.slot)];
                                if (target != null and !inventories.Stack.sameItem(held, target.?)) continue;
                                if (target != null and target.?.count >= try self.deps.items.stackLimit(held)) continue;
                                state.drag |= @as(u64, 1) << @intCast(click.slot);
                                state.dirty = false;
                                continue;
                            }

                            const count = @popCount(state.drag);
                            if (phase != 2 or count == 0) continue;

                            const maximum = try self.deps.items.stackLimit(held);
                            const each = if (button == 0) held.count / count else if (button == 1) @as(u16, 1) else maximum;
                            var remaining = held.count;

                            for (9..46) |index| {
                                if (state.drag & (@as(u64, 1) << @intCast(index)) == 0) continue;
                                if (next[index]) |target| if (!inventories.Stack.sameItem(held, target)) continue;

                                const previous = if (next[index]) |stack| stack.count else 0;
                                const amount = @min(each, maximum -| previous, if (button == 2) maximum else remaining);
                                if (amount == 0) continue;
                                next[index] = .{ .item = held.item, .count = previous + amount };

                                if (button != 2) remaining -= amount;
                            }

                            next[cursor] = if (remaining == 0) null else .{ .item = held.item, .count = remaining };
                            state.drag = 0;
                            state.drag_button = null;
                        } else {
                            if (click.slot == -999 and click.mode == 0 and (click.button == 0 or click.button == 1)) {
                                const held = next[cursor] orelse continue;
                                const amount = if (click.button == 0) held.count else 1;
                                try self.drop(player.*, .{ .item = held.item, .count = amount });
                                next[cursor] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                            } else {
                                if (click.slot < 0 or click.slot > 45) continue;

                                const at: usize = @intCast(click.slot);
                                if (at < 9) continue;

                                switch (click.mode) {
                                    0 => {
                                        if (click.button != 0 and click.button != 1) continue;

                                        if (next[cursor]) |held| {
                                            const maximum = try self.deps.items.stackLimit(held);

                                            if (next[at]) |target| {
                                                if (inventories.Stack.sameItem(held, target)) {
                                                    const amount = @min(if (click.button == 1) @as(u16, 1) else held.count, maximum -| target.count);
                                                    next[at].?.count += amount;
                                                    next[cursor] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                                                } else std.mem.swap(?inventories.Stack, &next[cursor], &next[at]);
                                            } else {
                                                const amount = if (click.button == 1) @as(u16, 1) else held.count;
                                                next[at] = .{ .item = held.item, .count = amount };
                                                next[cursor] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                                            }
                                        } else if (next[at]) |target| {
                                            const amount = if (click.button == 1) (target.count + 1) / 2 else target.count;
                                            next[cursor] = .{ .item = target.item, .count = amount };
                                            next[at] = if (amount == target.count) null else .{ .item = target.item, .count = target.count - amount };
                                        }
                                    },
                                    1 => {
                                        const source = next[at] orelse continue;
                                        var remaining = source.count;
                                        const maximum = try self.deps.items.stackLimit(source);
                                        const first: usize = if (at < 36) 36 else 9;
                                        const end: usize = if (at < 36) 45 else 36;

                                        for (0..2) |pass| for (first..end) |to| {
                                            if (remaining == 0) break;

                                            if (next[to]) |target| {
                                                if (pass != 0 or !inventories.Stack.sameItem(source, target)) continue;

                                                const amount = @min(remaining, maximum -| target.count);
                                                next[to].?.count += amount;
                                                remaining -= amount;
                                            } else if (pass == 1) {
                                                const amount = @min(remaining, maximum);
                                                next[to] = .{ .item = source.item, .count = amount };
                                                remaining -= amount;
                                            }
                                        };

                                        next[at] = if (remaining == 0) null else .{ .item = source.item, .count = remaining };
                                    },
                                    2 => {
                                        if (click.button < 0 or (click.button > 8 and click.button != 40)) continue;

                                        const to: usize = if (click.button == 40) 45 else 36 + @as(usize, @intCast(click.button));
                                        std.mem.swap(?inventories.Stack, &next[at], &next[to]);
                                    },
                                    3 => {
                                        if (player.gamemode != .creative or click.button != 2) continue;

                                        const source = next[at] orelse continue;
                                        next[cursor] = .{ .item = source.item, .count = try self.deps.items.stackLimit(source) };
                                    },
                                    4 => {
                                        if (click.button != 0 and click.button != 1) continue;

                                        const held = next[at] orelse continue;
                                        const amount = if (click.button == 1) held.count else 1;
                                        try self.drop(player.*, .{ .item = held.item, .count = amount });
                                        next[at] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                                    },
                                    6 => {
                                        const held = next[cursor] orelse continue;
                                        const maximum = try self.deps.items.stackLimit(held);

                                        for (next[9..45]) |*source| {
                                            const stack = source.* orelse continue;
                                            if (!inventories.Stack.sameItem(held, stack)) continue;

                                            const amount = @min(stack.count, maximum -| next[cursor].?.count);
                                            next[cursor].?.count += amount;
                                            source.* = if (amount == stack.count) null else .{ .item = stack.item, .count = stack.count - amount };
                                        }
                                    },
                                    else => continue,
                                }
                            }
                        }
                    },
                    else => continue,
                }

                var edits: [47]inventories.Edit = undefined;
                var count: usize = 0;

                for (next, contents, slots) |stack, old, slot| {
                    if (std.meta.eql(stack, old.stack)) continue;
                    edits[count] = .{ .slot = slot, .revision = old.revision, .stack = stack };
                    count += 1;
                }

                const committed = try self.deps.inventories.editMany(edits[0..count]);
                assert(committed);

                for (&contents, next) |*old, stack| {
                    old.revision += @intFromBool(!std.meta.eql(old.stack, stack));
                    old.stack = stack;
                }

                state.revision = (state.revision + 1) & 32767;
            }

            if (!state.dirty) continue;

            var packet = service.reserve(service.config.page_bytes) catch continue;
            defer packet.cancel();
            const start = try protocols.wire.play.toClient.write(packet.bytes).window_items();
            const body = try (try start.windowId(0)).stateId(state.revision);
            var rest = try support.write_varint(body._cursor.rest, 46);

            for (contents) |value| rest = self.deps.items.writeStack(player.protocol, rest, value.stack) catch |err| switch (err) {
                error.EndOfStream, error.UnsupportedItem => {
                    service.disconnect(handle);
                    continue :connections;
                },
                else => return err,
            };

            packet.publish(packet.bytes.len - rest.len, &.{handle}) catch continue;
            state.dirty = false;
        }
    }

    fn drop(self: *Menus, player: Players.Player, stack: inventories.Stack) !void {
        const yaw = @as(f64, player.rotation.yaw) * std.math.pi / 180;
        const pitch = @as(f64, player.rotation.pitch) * std.math.pi / 180;
        const entity = try self.deps.dropped.create(player.world, .{ player.position.x, player.position.y + 1.32, player.position.z }, .{ -@sin(yaw) * @cos(pitch) * 0.3, -@sin(pitch) * 0.3 + 0.1, @cos(yaw) * @cos(pitch) * 0.3 }, stack);
        var metadata = try self.deps.dropped.get(entity);
        metadata.pickup_delay = 40;
        try self.deps.dropped.put(entity, metadata);
    }

    pub fn give(self: *Menus, player: usize, name: []const u8, count: u16) !bool {
        return self.trade(player, name, count, true);
    }

    /// Plans the complete ownership change before mutating any slot.
    pub fn trade(self: *Menus, player: usize, name: []const u8, count: u16, buying: bool) !bool {
        const item = protocols.registry.itemId(name) orelse return error.UnknownItem;
        if (count == 0) return error.InvalidCount;

        const maximum = protocols.registry.item_stack_sizes[@intCast(item)];
        const owner = self.deps.players.records[player].uuid;
        const definition_id = try self.deps.items.define(name);
        var slots: [36]inventories.Slot = undefined;

        for (&slots, 0..) |*slot, index| slot.* = .{ .owner = owner, .index = @intCast(if (index < 9) index + 36 else index) };

        var contents: [36]inventories.Contents = undefined;
        try self.deps.inventories.getMany(&slots, &contents);
        var edits: [36]inventories.Edit = undefined;
        var edited: usize = 0;
        var remaining = count;

        for (0..if (buying) @as(usize, 2) else 1) |pass| for (slots, contents) |slot, value| {
            if (remaining == 0) break;

            const previous = if (value.stack) |stack| stack.count else 0;

            if (value.stack) |stack| {
                if (pass != 0 or !std.mem.eql(u8, &stack.item, &definition_id)) continue;
            } else if (!buying or pass == 0) continue;
            const amount = @min(remaining, if (buying) maximum -| previous else previous);
            if (amount == 0) continue;

            const after = if (buying) previous + amount else previous - amount;
            edits[edited] = .{
                .slot = slot,
                .revision = value.revision,
                .stack = if (after == 0) null else .{ .item = definition_id, .count = after },
            };
            edited += 1;
            remaining -= amount;
        };

        if (remaining != 0) return false;

        const committed = try self.deps.inventories.editMany(edits[0..edited]);
        assert(committed);
        self.states[player].dirty = true;
        return true;
    }

    pub fn changed(self: *Menus, player: usize) void {
        assert(player < self.states.len);
        self.states[player].dirty = true;
        self.states[player].revision = (self.states[player].revision + 1) & 32767;
    }
};

fn canonicalItem(protocol: i32, item: i32) ?usize {
    inline for (protocols.catalog.entries) |Version| {
        if (protocol == Version.protocol_number) {
            for (Version.Registry.canonical_item_to_wire, 0..) |wire, canonical| if (wire == item) return canonical;
        }
    }

    return null;
}
