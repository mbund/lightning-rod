const sparse_sets = @import("lightning_rod").system.sparse_sets;
const IndexSet = @import("lightning_rod").system.IndexSet;
const audience_storage = @import("audience.zig");
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

const assert = std.debug.assert;

pub const Equipment = struct {
    pub const id = "minecraft:equipment";

    pub const Configuration = struct { audience_words: usize = 4096 };

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

    const Subject = struct {
        owner: ?u128 = null,
        invalid: u64 = 63,
        slots: [6]u16 = undefined,
        selected: u4 = 0,
        generation: u32 = 0,
        life: u32 = 0,
        stacks: [6]?inventories.Stack = @splat(null),
        watchers: audience_storage.Row = .{},
        pending: audience_storage.Row = .{},
        dirty: [6]audience_storage.Row = @splat(.{}),
        audience_revision: ?Replication.AudienceRevision = null,
        retrying: bool = false,

        fn dirtySlots(self: *const Subject, observer: usize) u6 {
            var mask: u6 = 0;
            for (self.dirty, 0..) |row, slot| if (row.view().contains(observer)) {
                mask |= @as(u6, 1) << @intCast(slot);
            };
            return mask;
        }
    };

    deps: Dependencies,
    actors: IndexSet,
    subjects: []Subject,
    presentation: u64 = 0,
    observer: *inventories.Inventories.Observer,
    targets: []Target,
    recipients: []sessions.Handle,
    selections: audience_storage.Matrix,
    scratch: sparse_sets.Workspace,

    const Target = struct {
        handle: sessions.Handle,
        protocol: i32,
        dirty: u6,

        fn less(_: void, a: Target, b: Target) bool {
            return a.protocol < b.protocol or (a.protocol == b.protocol and a.dirty < b.dirty);
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Equipment {
        const self = try allocator.create(Equipment);
        const count = deps.players.records.len;
        const subjects = try allocator.alloc(Subject, count);
        @memset(subjects, .{});
        const selections = try audience_storage.Matrix.init(allocator, deps.players, try std.math.mul(usize, count, 8), config.audience_words, .recipients);
        for (subjects, 0..) |*subject, index| {
            subject.watchers = selections.row(index * 8);
            subject.pending = selections.row(index * 8 + 1);
            for (&subject.dirty, 0..) |*row, slot| row.* = selections.row(index * 8 + 2 + slot);
        }
        self.* = .{ .actors = try IndexSet.init(allocator, count), .selections = selections, .scratch = try sparse_sets.Workspace.init(allocator, 3, count), .recipients = try allocator.alloc(sessions.Handle, count), .targets = try allocator.alloc(Target, count), .deps = deps, .subjects = subjects, .observer = try deps.inventories.observe(allocator, count) };
        return self;
    }

    pub fn tick(self: *Equipment) !void {
        const players = self.deps.players;
        for (players.activeSlots()) |index| self.actors.insert(index);
        var retiring: usize = 0;
        while (retiring < self.actors.count) {
            const index = self.actors.indices[retiring];
            if (players.records[index].handle == null and self.subjects[index].owner == null) self.actors.remove(index) else retiring += 1;
        }
        const service = self.deps.sessions;
        const presentation_changed = self.presentation != self.deps.items.components.revision;
        self.presentation = self.deps.items.components.revision;

        for (self.actors.values()) |index| {
            const player = players.records[index];
            const subject = &self.subjects[index];
            if (subject.owner) |owner| {
                if (player.inWorld() and player.uuid == owner) continue;
                self.observer.unwatch(owner);
                const watchers = subject.watchers;
                const pending = subject.pending;
                const dirty = subject.dirty;
                watchers.clear();
                pending.clear();
                for (dirty) |row| row.clear();
                subject.* = .{ .watchers = watchers, .pending = pending, .dirty = dirty };
            }
        }
        for (self.actors.values()) |index| {
            const player = players.records[index];
            const subject = &self.subjects[index];
            if (!player.inWorld()) continue;
            if (subject.owner == null) {
                subject.owner = player.uuid;
                subject.selected = player.selected_slot;
                subject.slots = .{ 36 + @as(u16, player.selected_slot), 45, 8, 7, 6, 5 };
                self.observer.watch(player.uuid, &subject.slots, .{ .dirty = &subject.invalid });
            }
            if (subject.selected != player.selected_slot) {
                subject.slots[0] = 36 + @as(u16, player.selected_slot);
                subject.invalid |= 1;
            }
        }

        const reset = self.scratch.row(0);
        reset.clear();
        for (self.actors.values()) |index| {
            const player = players.records[index];
            const subject = self.subjects[index];
            const handle = player.handle orelse continue;
            if (subject.generation != handle.generation or subject.life != player.life) reset.insert(index);
        }
        const observers_reset = reset.view().any();
        for (self.actors.values()) |index| {
            const player = players.records[index];
            const subject = &self.subjects[index];
            const handle = player.handle orelse continue;
            const audience_revision = self.deps.replication.viewerRevision(index);
            if (!presentation_changed and subject.invalid == 0 and !subject.retrying and !observers_reset and subject.audience_revision != null and std.meta.eql(subject.audience_revision.?, audience_revision)) continue;
            subject.audience_revision = audience_revision;
            if (subject.generation != handle.generation or subject.life != player.life) subject.invalid = 63;
            if (subject.selected != player.selected_slot) subject.invalid |= 1;
            subject.generation = handle.generation;
            subject.life = player.life;
            subject.selected = player.selected_slot;
            const watching = self.deps.replication.viewers(index);
            const targets = self.targets;
            var count: usize = 0;
            var pending: u6 = 0;
            subject.pending.intersect(subject.pending.view(), watching);
            const candidates = self.scratch.row(1);
            candidates.subtract(watching, subject.watchers.view());
            const changed = self.scratch.row(2);
            changed.intersect(watching, reset.view());
            candidates.unite(candidates.view(), changed.view());
            assert(subject.invalid <= 63);
            for (subject.dirty, 0..) |dirty, slot| {
                dirty.intersect(dirty.view(), watching);
                dirty.unite(dirty.view(), candidates.view());
                if (presentation_changed or subject.invalid & (@as(u6, 1) << @intCast(slot)) != 0) dirty.unite(dirty.view(), watching);
            }
            candidates.unite(candidates.view(), subject.pending.view());
            if (presentation_changed or subject.invalid != 0) candidates.copy(watching);
            var selecting = candidates.view().iterator();
            while (selecting.next()) |other| {
                const observer = players.records[other];
                const recipient = observer.handle orelse continue;
                const dirty = subject.dirtySlots(other);
                if (dirty == 0) {
                    subject.pending.remove(other);
                    continue;
                }
                subject.pending.insert(other);
                if (other == index or observer.world != player.world or observer.stage != .ready or service.outputCredit(recipient) == 0) continue;
                targets[count] = .{ .handle = recipient, .protocol = observer.protocol, .dirty = dirty };
                count += 1;
                pending |= dirty;
            }
            subject.watchers.copy(watching);
            if (count == 0) {
                subject.retrying = subject.pending.view().any();
                continue;
            }
            std.mem.sort(Target, targets[0..count], {}, Target.less);

            var slots: [6]inventories.Slot = undefined;
            var contents: [6]inventories.Contents = undefined;
            var slot_numbers: [6]u3 = undefined;
            var loading: usize = 0;
            for ([_]u16{ 36 + @as(u16, player.selected_slot), 45, 8, 7, 6, 5 }, 0..) |number, at| {
                if (subject.invalid & pending & (@as(u6, 1) << @intCast(at)) == 0) continue;
                slots[loading] = .{ .owner = player.uuid, .index = number };
                slot_numbers[loading] = @intCast(at);
                loading += 1;
            }
            if (loading != 0) try self.deps.inventories.getMany(slots[0..loading], contents[0..loading]);
            for (contents[0..loading], slot_numbers[0..loading]) |value, at| {
                subject.stacks[at] = value.stack;
                subject.invalid &= ~(@as(u6, 1) << at);
            }
            while (pending != 0) {
                const eligible = for (targets[0..count]) |target| {
                    if (subject.dirtySlots(target.handle.index) & pending != 0 and service.outputCredit(target.handle) > 0) break true;
                } else false;
                if (!eligible) break;
                var prepared_mask: u6 = 0;
                var stacks: [6]inventories.Stack = undefined;
                var prepared: [6]Items.Prepared = undefined;
                var occupied: usize = 0;
                var remaining = pending;
                while (remaining != 0) {
                    const at: u3 = @intCast(@ctz(remaining));
                    const flag = @as(u6, 1) << at;
                    if (subject.stacks[at]) |stack| {
                        if (occupied == self.deps.items.views.len) break;
                        stacks[occupied] = stack;
                        occupied += 1;
                    }
                    prepared_mask |= flag;
                    remaining &= ~flag;
                }
                assert(prepared_mask != 0);
                pending &= ~prepared_mask;
                try self.deps.items.acquireMany(stacks[0..occupied], prepared[0..occupied]);
                defer for (prepared[0..occupied]) |held| held.release();
                var views: [6]?Items.View = @splat(null);
                var capacities: [6]usize = @splat(8);
                var at: usize = 0;
                for (subject.stacks, 0..) |stack, slot| {
                    if (prepared_mask & (@as(u6, 1) << @intCast(slot)) == 0 or stack == null) continue;
                    views[slot] = prepared[at].view;
                    capacities[slot] += prepared[at].lease.read().?.len + self.deps.items.components.extra_bytes;
                    at += 1;
                }
                assert(at == occupied);
                var begin: usize = 0;
                while (begin < count) {
                    var end = begin + 1;
                    while (end < count and targets[end].protocol == targets[begin].protocol and targets[end].dirty == targets[begin].dirty) : (end += 1) {}
                    var dirty = targets[begin].dirty & prepared_mask;
                    while (dirty != 0) {
                        var mask: u6 = 0;
                        var capacity: usize = 32;
                        remaining = dirty;
                        while (remaining != 0) {
                            const slot: u3 = @intCast(@ctz(remaining));
                            const flag = @as(u6, 1) << slot;
                            if (capacity > service.config.page_bytes or capacities[slot] > service.config.page_bytes - capacity) break;
                            capacity += capacities[slot];
                            mask |= flag;
                            remaining &= ~flag;
                        }
                        if (mask == 0) {
                            for (targets[begin..end]) |target| service.disconnect(target.handle);
                            break;
                        }
                        dirty &= ~mask;
                        const recipients = self.recipients;
                        var ready: usize = 0;
                        for (targets[begin..end]) |target| {
                            if (service.outputCredit(target.handle) == 0) continue;
                            recipients[ready] = target.handle;
                            ready += 1;
                        }
                        if (ready == 0) continue;
                        const groups = if (self.deps.items.components.personalized) ready else 1;
                        for (0..groups) |group| {
                            const selected = if (groups == 1) recipients[0..ready] else recipients[group..][0..1];
                            var packet = service.reserve(capacity) catch continue;
                            defer packet.cancel();
                            const bytes = self.deps.packets.writePacket(writeEquipment, targets[begin].protocol, packet.bytes, .{
                                self.deps.items, @as(i32, @intCast(index + 1)), mask, &subject.stacks, players.records[selected[0].index].uuid, &views,
                            }) catch |err| switch (err) {
                                error.EndOfStream, error.UnsupportedItem, error.UnsupportedComponent => {
                                    for (selected) |recipient| service.disconnect(recipient);
                                    continue;
                                },
                                else => return err,
                            };
                            for (packet.publishReady(bytes.len, selected)) |recipient| {
                                for (subject.dirty, 0..) |row, slot| if (mask & (@as(u6, 1) << @intCast(slot)) != 0) row.remove(recipient.index);
                                if (subject.dirtySlots(recipient.index) == 0) subject.pending.remove(recipient.index);
                            }
                        }
                    }
                    begin = end;
                }
            }
            subject.retrying = subject.pending.view().any();
        }
    }

    fn writeEquipment(packet: wire_1_21_5.play.toClient.packet_entity_equipment.Writer, registry: packets.Registry, store: *Items, entity: i32, mask: u6, stacks: *const [6]?inventories.Stack, recipient: u128, views: *const [6]?Items.View) ![]u8 {
        assert(mask != 0);
        var equipments = try (try packet.entityId(entity)).equipments(@popCount(mask));
        for (stacks, views, 0..) |stack, view, slot| {
            if (mask & (@as(u6, 1) << @intCast(slot)) == 0) continue;
            assert((stack == null) == (view == null));
            const entry = (try equipments.next()).?;
            var item = try (try entry.slot(@intCast(slot))).item();
            const done = try item_packets.writeSlot(try item.begin(), .{
                .registry = registry,
                .items = store,
                .stack = stack,
                .recipient = recipient,
                .view = view,
            });
            try equipments.advance(try item.advance(done));
        }
        return (try equipments.finish()).finish();
    }
};
