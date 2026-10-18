const std = @import("std");
const lightning_rod = @import("lightning_rod");
const chunks = @import("chunks");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const worlds = @import("worlds");
const wire_1_21_5 = @import("wire_1_21_5");
const Players = @import("players.zig").Players;
const Streaming = @import("streaming.zig").Streaming;

const assert = std.debug.assert;
const all_blocks: [64]u64 = @splat(std.math.maxInt(u64));

pub const BlockSynchronization = struct {
    pub const id = "minecraft:block_synchronization";

    pub const Configuration = struct { delta_sections: usize = 128 };

    pub const Dependencies = struct {
        chunks: *chunks.Chunks,
        players: *Players,
        streaming: *Streaming,
        work: *lightning_rod.Work,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        worlds: *worlds.Worlds,
    };

    const Observer = struct {
        generation: u32 = 0,
        life: u32 = 0,
        pending: usize = 0,
        cursor: usize = 0,
        pending_bits: []u64 = &.{},
        full_bits: []u64 = &.{},
    };

    const Delta = struct {
        section: chunks.Section = undefined,
        live: bool = false,
    };

    deps: Dependencies,
    observers: []Observer,
    pending: []u64,
    full: []u64,
    words: usize,
    side: i32,
    deltas: []Delta,
    masks: [][64]u64,
    recipients: []sessions.Handle,
    next_delta: usize = 0,
    next_player: usize = 0,
    packets: u64 = 0,
    full_sections: u64 = 0,
    blocks: u64 = 0,
    evictions: u64 = 0,
    backpressured: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*BlockSynchronization {
        if (config.delta_sections == 0) return error.InvalidConfiguration;
        if (deps.sessions.config.page_bytes < 16 + 4096 * 4) return error.PacketPageTooSmall;

        const self = try allocator.create(BlockSynchronization);
        const observers = try allocator.alloc(Observer, deps.players.records.len);
        for (observers, deps.players.records) |*observer, player| observer.* = .{ .life = player.life };
        const side = deps.players.config.render_distance * 2 + 1;
        const words = (@as(usize, @intCast(side * side)) * 24 + 63) / 64;
        const pending = try allocator.alloc(u64, words * observers.len);
        const full = try allocator.alloc(u64, pending.len);
        const deltas = try allocator.alloc(Delta, config.delta_sections);
        @memset(deltas, .{});
        self.* = .{
            .deps = deps,
            .observers = observers,
            .pending = pending,
            .full = full,
            .words = words,
            .side = side,
            .deltas = deltas,
            .masks = try allocator.alloc([64]u64, deltas.len),
            .recipients = try allocator.alloc(sessions.Handle, observers.len),
        };
        try deps.chunks.observe(chunks.Observer.init(self, changed));
        try deps.work.register(self, 8, progress);
        return self;
    }

    pub fn correct(self: *BlockSynchronization, world: u32, position: chunks.Position) void {
        changed(self, chunks.sectionAt(world, position), &.{.{ .index = chunks.localIndex(position), .state = 0 }});
    }

    fn changed(self: *BlockSynchronization, section: chunks.Section, edits: []const chunks.BlockEdit) void {
        const world = self.deps.worlds.get(section.world) orelse return;
        const minimum = world.dimension.minimumSection();
        if (section.y < minimum or section.y >= minimum + @as(i32, @intCast(world.dimension.sectionCount()))) return;

        const bit = self.bitIndex(section);
        const flag = @as(u64, 1) << @intCast(bit % 64);
        var interested = false;

        for (self.deps.players.records, self.observers, 0..) |player, *observer, index| {
            const handle = player.handle orelse continue;

            if (observer.generation != handle.generation or observer.life != player.life) {
                self.resetObserver(index, handle.generation, player.life);
            }

            if (!self.deps.streaming.visible(index, section.world, section.x, section.z)) continue;

            const word = bit / 64;
            observer.pending += @intFromBool(observer.pending_bits[word] & flag == 0);
            observer.pending_bits[word] |= flag;
            interested = true;
        }

        if (!interested) return;

        var found: ?usize = null;
        var free: ?usize = null;

        for (self.deltas, 0..) |delta, index| {
            if (!delta.live) free = index else if (std.meta.eql(delta.section, section)) {
                found = index;
                break;
            }
        }

        const slot = found orelse free orelse self.next_delta;

        if (found == null) {
            if (self.deltas[slot].live) {
                const previous = self.deltas[slot].section;
                const previous_bit = self.bitIndex(previous);
                const previous_flag = @as(u64, 1) << @intCast(previous_bit % 64);

                for (self.observers, 0..) |other, index| {
                    if (other.pending == 0) continue;
                    const word = previous_bit / 64;

                    if (other.pending_bits[word] & previous_flag != 0 and self.deps.streaming.visible(index, previous.world, previous.x, previous.z))
                        other.full_bits[word] |= previous_flag;
                }

                self.evictions += 1;
            }

            self.next_delta = (slot + 1) % self.deltas.len;
            self.deltas[slot] = .{ .section = section, .live = true };
            self.masks[slot] = @splat(0);
        }

        for (edits) |edit| self.masks[slot][edit.index / 64] |= @as(u64, 1) << @intCast(edit.index % 64);
    }

    fn progress(self: *BlockSynchronization, _: std.Io, maximum_items: usize) !lightning_rod.Work.Result {
        const players = self.deps.players;
        const service = self.deps.sessions;
        assert(maximum_items > 0 and maximum_items <= 8);
        var advanced = false;
        var completed: usize = 0;

        for (0..maximum_items * self.observers.len) |_| {
            if (completed == maximum_items) break;

            const selected = self.next_player;
            self.next_player = (selected + 1) % self.observers.len;
            const player = players.records[selected];
            const observer = &self.observers[selected];
            const generation = if (player.handle) |handle| handle.generation else 0;

            if (observer.generation != generation or observer.life != player.life) {
                self.resetObserver(selected, generation, player.life);
            }

            if (observer.pending == 0 or player.handle == null or player.stage != .ready) continue;

            var bit: ?usize = null;

            for (0..self.words + 1) |step| {
                const word = (observer.cursor / 64 + step) % self.words;
                var bits = observer.pending_bits[word];
                const offset: u6 = @intCast(observer.cursor % 64);

                if (step == 0) bits &= @as(u64, std.math.maxInt(u64)) << offset;

                if (step == self.words) bits &= (@as(u64, 1) << offset) - 1;
                if (bits == 0) continue;
                bit = word * 64 + @ctz(bits);
                break;
            }

            assert(bit != null);
            const at = bit.?;
            observer.cursor = (at + 1) % (@as(usize, @intCast(self.side * self.side)) * 24);
            const flag = @as(u64, 1) << @intCast(at % 64);
            const center = self.deps.streaming.viewCenter(selected);
            const radius = players.config.render_distance;
            const x = center.x - radius;
            const z = center.z - radius;
            const cell: i32 = @intCast(at / 24);
            const section: chunks.Section = .{
                .world = player.world,
                .x = x + @mod(@mod(cell, self.side) - @mod(x, self.side), self.side),
                .y = @as(i32, @intCast(at % 24)) - 4,
                .z = z + @mod(@divTrunc(cell, self.side) - @mod(z, self.side), self.side),
            };
            assert(self.bitIndex(section) == at);
            if (!self.deps.streaming.visible(selected, section.world, section.x, section.z)) {
                observer.pending_bits[at / 64] &= ~flag;
                observer.full_bits[at / 64] &= ~flag;
                observer.pending -= 1;
                advanced = true;
                completed += 1;
                continue;
            }

            var slot: ?usize = null;

            for (self.deltas, 0..) |delta, index| if (delta.live and std.meta.eql(delta.section, section)) {
                slot = index;
                break;
            };

            const full = slot == null or observer.full_bits[at / 64] & flag != 0;
            var count: usize = 0;

            for (players.records, 0..) |recipient, index| {
                const handle = recipient.handle orelse continue;
                if (self.observers[index].pending == 0 or recipient.protocol != player.protocol or recipient.stage != .ready or !self.deps.streaming.visible(index, section.world, section.x, section.z))
                    continue;

                const other = &self.observers[index];
                const word = at / 64;
                if (other.pending_bits[word] & flag == 0) continue;
                if ((slot == null or other.full_bits[word] & flag != 0) != full) continue;
                self.recipients[count] = handle;
                count += 1;
            }

            assert(count > 0);
            const mask: *const [64]u64 = if (full) &all_blocks else &self.masks[slot.?];
            var changed_count: i32 = 0;

            for (mask) |bits| changed_count += @popCount(bits);
            assert(changed_count > 0 and changed_count <= 4096);
            const capacity = 16 + @as(usize, @intCast(changed_count)) * 4;
            var ready: usize = 0;

            for (self.recipients[0..count]) |handle| if (service.canSend(handle, capacity)) {
                self.recipients[ready] = handle;
                ready += 1;
            };

            if (ready == 0) {
                self.backpressured += 1;
                continue;
            }

            var packet = service.reserve(capacity) catch |err| switch (err) {
                error.Backpressured => {
                    self.backpressured += 1;
                    break;
                },
                else => return err,
            };
            defer packet.cancel();
            const lease = try self.deps.chunks.acquire(section);
            defer lease.release();
            const view = lease.view();
            const bytes = try self.deps.packets.writePacket(writeChanges, player.protocol, packet.bytes, .{ section, view, mask });

            const accepted = packet.publishReady(bytes.len, self.recipients[0..ready]);

            for (accepted) |handle| {
                const other = &self.observers[handle.index];
                const word = at / 64;
                assert(other.pending_bits[word] & flag != 0);
                other.pending_bits[word] &= ~flag;
                other.full_bits[word] &= ~flag;
                other.pending -= 1;
            }

            if (accepted.len > 0) {
                self.packets += 1;
                self.full_sections += @intFromBool(full);
                self.blocks += @intCast(changed_count);
                advanced = true;
            }

            if (slot) |cached| {
                var retained = false;

                for (self.observers, 0..) |other, index| {
                    if (other.pending == 0) continue;
                    const word = at / 64;
                    if (other.pending_bits[word] & flag == 0 or !self.deps.streaming.visible(index, section.world, section.x, section.z)) continue;

                    if (!full and accepted.len > 0) other.full_bits[word] |= flag;
                    retained = retained or other.full_bits[word] & flag == 0;
                }

                if (!retained) self.deltas[cached].live = false;
            }

            completed += 1;
        }

        if (advanced) return .progressed;

        for (self.observers) |observer| if (observer.pending != 0) return .blocked;
        return .idle;
    }

    fn resetObserver(self: *BlockSynchronization, index: usize, generation: u32, life: u32) void {
        const count = if (generation == 0) 0 else self.words;
        const pending = self.pending[index * self.words ..][0..count];
        const full = self.full[index * self.words ..][0..count];
        @memset(pending, 0);
        @memset(full, 0);
        self.observers[index] = .{ .generation = generation, .life = life, .pending_bits = pending, .full_bits = full };
    }

    fn writeChanges(packet: wire_1_21_5.play.toClient.packet_multi_block_change.Writer, registry: packets.Registry, section: chunks.Section, view: chunks.View, mask: *const [64]u64) ![]u8 {
        var count: u32 = 0;
        for (mask) |bits| count += @popCount(bits);

        const positioned = try packet.chunkCoordinates(.{ .x = section.x, .z = section.z, .y = section.y });
        var records = try positioned.records(count);

        for (mask, 0..) |word, index| {
            var bits = word;

            while (bits != 0) {
                const at: u12 = @intCast(index * 64 + @ctz(bits));
                bits &= bits - 1;
                const local: u12 = ((at & 15) << 8) | (((at >> 4) & 15) << 4) | (at >> 8);
                const canonical = view.get(at);
                const mapped = registry.blockState(@intCast(canonical)) catch return error.UnsupportedBlock;
                const record = (@as(u64, @intCast(mapped)) << 12) | local;
                if (record > std.math.maxInt(i32)) return error.UnsupportedBlock;
                records = try records.element(@intCast(record));
            }
        }

        return (try records.finish()).finish();
    }

    fn bitIndex(self: *const BlockSynchronization, section: chunks.Section) usize {
        assert(section.y >= -4 and section.y < 20);
        return @as(usize, @intCast(@mod(section.z, self.side) * self.side + @mod(section.x, self.side))) * 24 + @as(usize, @intCast(section.y + 4));
    }
};
