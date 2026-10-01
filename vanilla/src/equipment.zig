const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const placement = @import("placement.zig");
const mining = @import("mining.zig");
const item_pickup = @import("item_pickup.zig");
const sessions = @import("sessions");
const inventories = @import("inventories");
const item_packets = @import("item_packets.zig");
const Replication = @import("replication.zig").Replication;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Items = @import("items.zig").Items;
const Players = @import("players.zig").Players;

pub const Equipment = struct {
    pub const id = "minecraft:equipment";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        replication: *Replication,
        menus: *PlayerInventory,
        players: *Players,
        inventories: *inventories.Inventories,
        items: *Items,
        sessions: *sessions.Service,
        packets: *packets.Packets,
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
    presentation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Equipment {
        const self = try allocator.create(Equipment);
        const count = deps.players.records.len;
        const subjects = try allocator.alloc(Subject, count);
        const seen = try allocator.alloc(Seen, count * count);
        @memset(subjects, .{});
        @memset(seen, .{});
        self.* = .{ .deps = deps, .subjects = subjects, .seen = seen };
        return self;
    }

    pub fn tick(self: *Equipment) !void {
        const players = self.deps.players;
        const service = self.deps.sessions;
        const presentation_changed = self.presentation != self.deps.items.components.revision;
        self.presentation = self.deps.items.components.revision;

        for (players.records, self.subjects, 0..) |player, *subject, index| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready) continue;

            var slots: [6]inventories.Slot = undefined;

            for (&slots, [_]u16{ 36 + @as(u16, player.selected_slot), 45, 8, 7, 6, 5 }) |*slot, number|
                slot.* = .{ .owner = player.uuid, .index = number };

            var contents: [6]inventories.Contents = undefined;
            try self.deps.inventories.getMany(&slots, &contents);
            var changed: u6 = if (presentation_changed or subject.generation != handle.generation or subject.life != player.life) 63 else 0;

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

                var capacity: usize = 32 + self.deps.items.components.extra_bytes;

                if (stack) |held| {
                    const definition = try self.deps.inventories.acquireItem(held.item);
                    defer definition.release();
                    capacity += definition.read().?.len;
                }

                for (service.config.protocols) |*selected| {
                    const protocol = selected.number;
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
                    const groups = if (self.deps.items.components.personalized) count else 1;
                    for (0..groups) |group| {
                        const targets = if (groups == 1) recipients[0..count] else recipients[group..][0..1];
                        var packet = service.reserve(capacity) catch continue;
                        defer packet.cancel();
                        const bytes = self.deps.packets.writePacket(writeEquipment, protocol, packet.bytes, .{
                            self.deps.items, @as(i32, @intCast(index + 1)), @as(u8, @intCast(slot)), stack, players.records[targets[0].index].uuid,
                        }) catch |err| switch (err) {
                            error.EndOfStream, error.UnsupportedItem, error.UnsupportedComponent => {
                                for (targets) |recipient| service.disconnect(recipient);
                                continue;
                            },
                            else => return err,
                        };
                        const accepted = packet.publishReady(bytes.len, targets);

                        for (accepted) |recipient| row[recipient.index].dirty &= ~flag;
                    }
                }
            }
        }
    }

    fn writeEquipment(packet: wire_1_21_5.play.toClient.packet_entity_equipment.Writer, registry: packets.Registry, store: *Items, entity: i32, slot: u8, stack: ?inventories.Stack, recipient: u128) ![]u8 {
        var equipments = try (try packet.entityId(entity)).equipments(1);
        const entry = (try equipments.next()).?;
        const slotted = try entry.slot(@intCast(slot));
        var item = try slotted.item();
        const done = try item_packets.writeSlot(try item.begin(), .{
            .registry = registry,
            .items = store,
            .stack = stack,
            .recipient = recipient,
        });
        try equipments.advance(try item.advance(done));
        return (try equipments.finish()).finish();
    }
};
