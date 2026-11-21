//! ServerItemCooldowns: items a player cannot use for a while, by cooldown group, which for
//! vanilla's items is the item itself. Its client greys the item out by what the server sends.

const std = @import("std");
const game_data = @import("game_data");
const wire = @import("wire_1_21_5");
const Players = @import("players").players.Players;

const assert = std.debug.assert;

pub const ItemCooldowns = struct {
    pub const id = "minecraft:item_cooldowns";
    pub const Configuration = struct {};
    /// Most items one player can have cooling down at once: every kind, as a cooldown on an item
    /// replaces the one it had, so none is ever lost for room.
    const per_kind = game_data.registry.item_names.len;
    pub const Dependencies = struct { players: *Players };

    const Cooldown = struct { kind: u32, ends: u64 };
    /// A player's cooldowns, for the connection they began on.
    const Owner = struct { generation: u32 = 0, count: u16 = 0 };

    deps: Dependencies,
    per_player: usize,
    cooldowns: []Cooldown,
    owners: []Owner,
    /// How many ticks have passed.
    now: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*ItemCooldowns {
        const self = try allocator.create(ItemCooldowns);
        const owners = try allocator.alloc(Owner, deps.players.records.len);
        @memset(owners, .{});
        self.* = .{
            .deps = deps,
            .per_player = per_kind,
            .cooldowns = try allocator.alloc(Cooldown, try std.math.mul(usize, deps.players.records.len, per_kind)),
            .owners = owners,
        };
        return self;
    }

    /// The cooldowns of the player in a slot, forgotten when another connection takes it.
    fn of(self: *ItemCooldowns, slot: usize) []Cooldown {
        const owner = &self.owners[slot];
        const generation = if (self.deps.players.records[slot].handle) |handle| handle.generation else 0;
        if (owner.generation != generation) owner.* = .{ .generation = generation };
        return self.cooldowns[slot * self.per_player ..][0..owner.count];
    }

    /// ItemCooldowns.addCooldown: the item cannot be used for `ticks`, which replaces any cooldown
    /// it had.
    pub fn set(self: *ItemCooldowns, slot: usize, kind: u32, ticks: i32) void {
        assert(ticks > 0 and kind < per_kind);
        const current = self.of(slot);
        const ends = self.now + @as(u64, @intCast(ticks));
        const at = for (current, 0..) |cooldown, index| {
            if (cooldown.kind == kind) break index;
        } else blk: {
            // One a kind at most, which there is room for.
            assert(current.len < self.per_player);
            self.owners[slot].count += 1;
            break :blk current.len;
        };
        self.cooldowns[slot * self.per_player + at] = .{ .kind = kind, .ends = ends };
        self.send(slot, kind, ticks);
    }

    /// ItemCooldowns.isOnCooldown.
    pub fn active(self: *ItemCooldowns, slot: usize, kind: u32) bool {
        for (self.of(slot)) |cooldown| if (cooldown.kind == kind and cooldown.ends > self.now) return true;
        return false;
    }

    /// Ends the cooldowns that are due, as ServerItemCooldowns.onCooldownEnded tells the client.
    pub fn tick(self: *ItemCooldowns) void {
        self.now += 1;
        for (self.deps.players.activeSlots()) |slot| {
            const current = self.of(slot);
            var kept: usize = 0;
            for (current) |cooldown| {
                if (cooldown.ends <= self.now) {
                    self.send(slot, cooldown.kind, 0);
                    continue;
                }
                self.cooldowns[slot * self.per_player + kept] = cooldown;
                kept += 1;
            }
            self.owners[slot].count = @intCast(kept);
        }
    }

    fn send(self: *ItemCooldowns, slot: usize, kind: u32, ticks: i32) void {
        const player = &self.deps.players.records[slot];
        const handle = player.handle orelse return;
        _ = self.deps.players.sendPacket(writeCooldown, player.protocol, handle, .{ game_data.registry.item_names[kind], ticks });
    }
};

fn writeCooldown(packet: wire.play.toClient.packet_set_cooldown.Writer, group: []const u8, ticks: i32) ![]u8 {
    return (try (try packet.cooldownGroup(group)).cooldownTicks(ticks)).finish();
}
