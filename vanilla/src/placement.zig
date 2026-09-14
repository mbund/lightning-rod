const std = @import("std");
const block_actions = @import("block_actions.zig");
const inventories = @import("inventories");
const chunks = @import("chunks");
const registry = @import("protocols").registry;

const Chunks = chunks.Chunks;
const Menus = @import("menus.zig").Menus;
const BlockSynchronization = @import("block_sync.zig").BlockSynchronization;

pub const Placement = struct {
    pub const id = "minecraft:placement";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        menus: *Menus,
        chunks: *Chunks,
        blocks: *BlockSynchronization,
        actions: *block_actions.BlockActions,
    };

    const State = struct {
        generation: u32 = 0,
        teleport_id: i32 = 0,
        sequence: i32 = -1,
        selected: u4 = 0,
    };

    deps: Dependencies,
    states: []State,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Placement {
        const self = try allocator.create(Placement);
        const states = try allocator.alloc(State, deps.menus.deps.players.records.len);
        @memset(states, .{});
        self.* = .{ .deps = deps, .states = states };
        return self;
    }

    pub fn tick(self: *Placement) !void {
        const players = self.deps.menus.deps.players;

        for (players.records, self.states, 0..) |player, *state, index| {
            const handle = player.handle orelse continue;

            if (state.generation != handle.generation or state.teleport_id != player.teleport_id)
                state.* = .{ .generation = handle.generation, .teleport_id = player.teleport_id, .selected = player.selected_slot };

            if (player.stage != .ready) continue;

            if (state.sequence >= 0 and self.deps.blocks.observers[index].pending == 0 and players.send(player.protocol, &.{handle}, .{ .block_ack = state.sequence }))
                state.sequence = -1;

            for (players.deps.input.values(handle)) |event| {
                if (event == .held_slot) {
                    if (event.held_slot >= 0 and event.held_slot < 9) state.selected = @intCast(event.held_slot);
                    continue;
                }

                if (event != .place) continue;

                const place = event.place;
                state.sequence = @max(state.sequence, place.sequence);
                if (place.hand < 0 or place.hand > 1 or place.face < 0 or place.face > 5) continue;
                if (!std.math.isFinite(place.cursor[0]) or !std.math.isFinite(place.cursor[1]) or !std.math.isFinite(place.cursor[2])) continue;
                if (player.health <= 0 or (player.gamemode != .creative and player.gamemode != .survival)) continue;

                const dimension = players.deps.worlds.get(player.world).?.dimension;
                const minimum_y = dimension.minimumSection() * 16;
                if (place.position.y < minimum_y or place.position.y >= minimum_y + @as(i32, @intCast(dimension.sectionCount() * 16))) continue;

                const hit_dx = @as(f64, @floatFromInt(place.position.x)) + 0.5 - player.position.x;
                const hit_dy = @as(f64, @floatFromInt(place.position.y)) + 0.5 - player.position.y - 1.62;
                const hit_dz = @as(f64, @floatFromInt(place.position.z)) + 0.5 - player.position.z;
                if (hit_dx * hit_dx + hit_dy * hit_dy + hit_dz * hit_dz > 36) continue;

                const slot: inventories.Slot = .{ .owner = player.uuid, .index = if (place.hand == 1) 45 else 36 + @as(u16, state.selected) };
                const held = try self.deps.menus.deps.inventories.get(slot);
                const clicked: chunks.Position = .{ .x = place.position.x, .y = place.position.y, .z = place.position.z };
                const secondary = if (player.flags.sneaking and held.stack == null) (try self.deps.menus.deps.inventories.get(.{
                    .owner = player.uuid,
                    .index = if (place.hand == 0) 45 else 36 + @as(u16, state.selected),
                })).stack else null;
                if (!player.flags.sneaking or (held.stack == null and secondary == null)) {
                    const used = try self.deps.actions.apply(.{
                        .action = .use,
                        .player = &player,
                        .position = clicked,
                        .state = try self.deps.chunks.getBlock(player.world, clicked),
                        .hit = place,
                    });
                    if (used != .pass) {
                        if (used == .denied) self.deps.blocks.correct(player.world, clicked);
                        continue;
                    }
                }

                var position = place.position;
                const offset = [_][3]i32{ .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 } };
                position.x += offset[@intCast(place.face)][0];
                position.y += offset[@intCast(place.face)][1];
                position.z += offset[@intCast(place.face)][2];
                if (position.y < minimum_y or position.y >= minimum_y + @as(i32, @intCast(dimension.sectionCount() * 16))) continue;

                const dx = @as(f64, @floatFromInt(position.x)) + 0.5 - player.position.x;
                const dy = @as(f64, @floatFromInt(position.y)) + 0.5 - player.position.y - 1.62;
                const dz = @as(f64, @floatFromInt(position.z)) + 0.5 - player.position.z;
                if (dx * dx + dy * dy + dz * dz > 36) continue;

                const pos: chunks.Position = .{ .x = position.x, .y = position.y, .z = position.z };
                const previous = try self.deps.chunks.getBlock(player.world, pos);
                var block: u16 = 0;

                if (held.stack) |stack| {
                    const description = try self.deps.menus.deps.items.describe(stack);
                    block = @intCast(registry.items[description.kind].block_state);
                }

                var allowed = block != 0 and previous == 0 and player.health > 0 and (player.gamemode == .creative or player.gamemode == .survival);
                const custom = if (allowed) try self.deps.actions.apply(.{
                    .action = .place,
                    .player = &player,
                    .position = pos,
                    .state = block,
                    .hit = place,
                }) else .pass;

                if (custom == .denied) allowed = false;
                if (custom == .pass) for (players.records) |other| {
                    if (other.handle == null or other.world != player.world or other.stage != .ready or other.gamemode == .spectator) continue;

                    const x: f64 = @floatFromInt(position.x);
                    const y: f64 = @floatFromInt(position.y);
                    const z: f64 = @floatFromInt(position.z);

                    if (other.position.x + 0.3 > x and other.position.x - 0.3 < x + 1 and other.position.y + 1.8 > y and other.position.y < y + 1 and other.position.z + 0.3 > z and other.position.z - 0.3 < z + 1)
                        allowed = false;
                };

                if (!allowed) {
                    self.deps.blocks.correct(player.world, pos);
                    self.deps.menus.changed(index);
                    continue;
                }

                if (custom == .pass) try self.deps.chunks.setBlock(player.world, pos, block);

                if (player.gamemode != .creative) {
                    const stack = held.stack.?;
                    const remaining: ?inventories.Stack = if (stack.count == 1) null else .{ .item = stack.item, .count = stack.count - 1 };
                    const changed = try self.deps.menus.deps.inventories.set(slot, held.revision, remaining);
                    std.debug.assert(changed);
                    self.deps.menus.changed(index);
                }
            }
        }
    }
};
