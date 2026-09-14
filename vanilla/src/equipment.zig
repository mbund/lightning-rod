const std = @import("std");
const placement = @import("placement.zig");
const mining = @import("mining.zig");
const item_pickup = @import("item_pickup.zig");
const sessions = @import("sessions");
const inventories = @import("inventories");
const protocols = @import("protocols");
const Replication = @import("replication.zig").Replication;
const Menus = @import("menus.zig").Menus;

pub const Equipment = struct {
    pub const id = "minecraft:equipment";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        replication: *Replication,
        menus: *Menus,
        placement: *placement.Placement,
        mining: *mining.Mining,
        pickup: *item_pickup.ItemPickup,
    };

    const Seen = struct {
        generation: u32 = 0,
        life: u32 = 0,
        dirty: u6 = 63,
    };

    const Subject = struct {
        generation: u32 = 0,
        life: u32 = 0,
        stacks: [6]?inventories.Stack = @splat(null),
    };

    deps: Dependencies,
    subjects: []Subject,
    seen: []Seen,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Equipment {
        const self = try allocator.create(Equipment);
        const count = deps.menus.deps.players.records.len;
        const subjects = try allocator.alloc(Subject, count);
        const seen = try allocator.alloc(Seen, count * count);
        @memset(subjects, .{});
        @memset(seen, .{});
        self.* = .{ .deps = deps, .subjects = subjects, .seen = seen };
        return self;
    }

    pub fn tick(self: *Equipment) !void {
        const players = self.deps.menus.deps.players;
        const service = players.deps.sessions;

        for (players.records, self.subjects, 0..) |player, *subject, index| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready) continue;

            var slots: [6]inventories.Slot = undefined;

            for (&slots, [_]u16{ 36 + @as(u16, player.selected_slot), 45, 8, 7, 6, 5 }) |*slot, number|
                slot.* = .{ .owner = player.uuid, .index = number };

            var contents: [6]inventories.Contents = undefined;
            try self.deps.menus.deps.inventories.getMany(&slots, &contents);
            var changed: u6 = if (subject.generation != handle.generation or subject.life != player.life) 63 else 0;

            for (contents, &subject.stacks, 0..) |value, *previous, slot| {
                if (!std.meta.eql(value.stack, previous.*)) changed |= @as(u6, 1) << @intCast(slot);
                previous.* = value.stack;
            }

            subject.generation = handle.generation;
            subject.life = player.life;
            const row = self.seen[index * players.records.len ..][0..players.records.len];
            var pending: u6 = 0;

            for (players.records, row, 0..) |observer, *seen, other| {
                const recipient = observer.handle orelse continue;

                if (seen.generation != recipient.generation or seen.life != observer.life)
                    seen.* = .{ .generation = recipient.generation, .life = observer.life };

                seen.dirty |= changed;

                if (other != index and observer.stage == .ready) pending |= seen.dirty;
            }

            for (subject.stacks, 0..) |stack, slot| {
                const flag = @as(u6, 1) << @intCast(slot);
                if (pending & flag == 0) continue;

                var capacity: usize = 32;

                if (stack) |held| {
                    const definition = try self.deps.menus.deps.inventories.acquireItem(held.item);
                    defer definition.release();
                    capacity += definition.read().?.len;
                }

                for ([_]i32{ 771, 772 }) |protocol| {
                    var recipients: [256]sessions.Handle = undefined;
                    var count: usize = 0;

                    for (players.records, 0..) |observer, other| {
                        const recipient = observer.handle orelse continue;
                        if (other == index or observer.world != player.world or observer.stage != .ready or observer.protocol != protocol) continue;
                        if (row[other].dirty & flag == 0 or self.deps.replication.seen[other * players.records.len + index].stage != .spawned) continue;
                        if (capacity > service.config.page_bytes) {
                            service.disconnect(recipient);
                            continue;
                        }

                        if (!service.canSend(recipient, capacity)) continue;
                        recipients[count] = recipient;
                        count += 1;
                    }

                    if (count == 0) continue;

                    var packet = service.reserve(capacity) catch continue;
                    defer packet.cancel();
                    var rest = try protocols.support.write_varint(packet.bytes, protocols.wire.play.toClient.packetId(.entity_equipment));
                    rest = try protocols.support.write_varint(rest, @intCast(index + 1));
                    rest[0] = @intCast(slot);
                    rest = try self.deps.menus.deps.items.writeStack(protocol, rest[1..], stack);
                    const accepted = packet.publishReady(packet.bytes.len - rest.len, recipients[0..count]);

                    for (accepted) |recipient| row[recipient.index].dirty &= ~flag;
                }
            }
        }
    }
};
