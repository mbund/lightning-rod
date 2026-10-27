const BatchIndex = @import("system").BatchIndex;
const bit_sets = @import("system").bit_sets;
const sparse_sets = @import("system").sparse_sets;
const std = @import("std");
const service = @import("service.zig");
const shared = @import("shared.zig");
const network = @import("networking");

const assert = std.debug.assert;
const width = @bitSizeOf(usize);
const Shift = std.math.Log2Int(usize);

pub const Broadcast = struct {
    // Receipts belong to this batch and remain valid until its next begin.
    pub const Receipt = struct { owner: *const Broadcast, generation: u64, first: usize, count: usize };
    const Entry = struct {
        packet: service.Service.Packet,
        length: usize,
        protocol: usize,
        excluded: ?usize,
        required: ?usize,
        group: shared.Group,
        charge: usize,
        unsupported: bool = false,
        mask_index: usize = std.math.maxInt(usize),
    };
    const Member = struct {
        protocol: usize = 0,
        healthy: bool = false,
        generation: u32 = 0,
        reserved: usize = 0,
        remaining: usize = 0,
        excluded: usize = 0,
    };

    allocator: std.mem.Allocator,
    owner: *service.Service,
    entries: []Entry,
    masks: []usize,
    admission: []usize,
    mask_index: BatchIndex([]const u8, usize, std.hash_map.StringContext),
    mask_count: usize = 0,
    mask_capacity: usize,
    mapped_masks: []usize,
    mapped_words: []usize,
    mapped_counts: []usize,
    mapped_ready: []bool,
    results: sparse_sets.Workspace,
    // Capture borrows pool handles. Receipt coordinates survive cancel.
    audience_handles: []const network.Handle = &.{},
    ordinals: []usize,
    identity: bool = true,
    indices: []usize,
    slow: []usize,
    members: []Member,
    protocol_masks: []usize,
    healthy: []usize,
    forced: []usize,
    totals: []usize,
    available: []usize,
    words: usize,
    count: usize = 0,
    committed: usize = 0,
    recipients: usize = 0,
    audience: ?shared.Audience = null,
    epoch: u64 = 0,
    generation: u64 = 0,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, owner: *service.Service, maximum_packets: usize) !Broadcast {
        assert(maximum_packets > 0);
        const words = try std.math.divCeil(usize, owner.config.connections, width);
        const entries = try allocator.alloc(Entry, maximum_packets);
        errdefer allocator.free(entries);
        const mask_capacity = @min(maximum_packets, owner.config.pages);
        const masks = try allocator.alloc(usize, try std.math.mul(usize, mask_capacity, words));
        errdefer allocator.free(masks);
        const mapped_capacity = try std.math.add(usize, mask_capacity, owner.config.protocols.len);
        const mapped_size = try std.math.mul(usize, mapped_capacity, words);
        const mapped_masks = try allocator.alloc(usize, mapped_size);
        errdefer allocator.free(mapped_masks);
        @memset(mapped_masks, 0);
        const mapped_words = try allocator.alloc(usize, mapped_size);
        errdefer allocator.free(mapped_words);
        const mapped_counts = try allocator.alloc(usize, mapped_capacity);
        errdefer allocator.free(mapped_counts);
        @memset(mapped_counts, 0);
        const mapped_ready = try allocator.alloc(bool, mapped_capacity);
        errdefer allocator.free(mapped_ready);
        const admission = try allocator.alloc(usize, words);
        errdefer allocator.free(admission);
        var mask_index = try BatchIndex([]const u8, usize, std.hash_map.StringContext).init(allocator, mask_capacity);
        errdefer mask_index.deinit(allocator);
        const ordinals = try allocator.alloc(usize, owner.config.connections);
        errdefer allocator.free(ordinals);
        @memset(ordinals, std.math.maxInt(usize));
        const indices = try allocator.alloc(usize, owner.config.connections);
        errdefer allocator.free(indices);
        const slow = try allocator.alloc(usize, owner.config.connections);
        errdefer allocator.free(slow);
        const members = try allocator.alloc(Member, owner.config.connections);
        errdefer allocator.free(members);
        const protocol_masks = try allocator.alloc(usize, owner.config.protocols.len * words);
        errdefer allocator.free(protocol_masks);
        @memset(protocol_masks, 0);
        const healthy = try allocator.alloc(usize, protocol_masks.len);
        errdefer allocator.free(healthy);
        const forced = try allocator.alloc(usize, words);
        errdefer allocator.free(forced);
        const available = try allocator.alloc(usize, owner.config.protocols.len);
        errdefer allocator.free(available);
        const totals = try allocator.alloc(usize, owner.config.protocols.len);
        return .{ .mapped_masks = mapped_masks, .mapped_words = mapped_words, .mapped_counts = mapped_counts, .mapped_ready = mapped_ready, .results = try sparse_sets.Workspace.init(allocator, 2, owner.config.connections), .allocator = allocator, .owner = owner, .entries = entries, .masks = masks, .admission = admission, .mask_index = mask_index, .mask_capacity = mask_capacity, .ordinals = ordinals, .indices = indices, .slow = slow, .members = members, .protocol_masks = protocol_masks, .healthy = healthy, .forced = forced, .totals = totals, .available = available, .words = words };
    }

    pub fn deinit(self: *Broadcast) void {
        assert(!self.active);
        self.results.deinit(self.allocator);
        self.allocator.free(self.available);
        self.allocator.free(self.totals);
        self.allocator.free(self.forced);
        self.allocator.free(self.healthy);
        self.allocator.free(self.protocol_masks);
        self.allocator.free(self.members);
        self.allocator.free(self.slow);
        self.allocator.free(self.indices);
        self.allocator.free(self.ordinals);
        self.mask_index.deinit(self.allocator);
        self.allocator.free(self.admission);
        self.allocator.free(self.mapped_ready);
        self.allocator.free(self.mapped_counts);
        self.allocator.free(self.mapped_words);
        self.allocator.free(self.mapped_masks);
        self.allocator.free(self.masks);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Captures connection generations. Each batch has exactly one producer.
    pub fn begin(self: *Broadcast, targets: []const service.Service.Target) !void {
        assert(!self.active and self.audience == null and targets.len <= self.ordinals.len);
        for (self.indices[0..self.recipients], 0..) |index, ordinal| {
            assert(self.ordinals[index] == ordinal);
            self.ordinals[index] = std.math.maxInt(usize);
        }
        if (self.recipients != 0) @memset(self.protocol_masks[0 .. self.owner.config.protocols.len * self.words], 0);
        @memset(self.available, 0);
        self.generation += 1;
        self.count = 0;
        self.mask_count = 0;
        @memset(self.mapped_ready[self.mask_capacity..], false);
        self.mask_index.clear();
        self.committed = 0;
        self.recipients = 0;
        self.words = std.math.divCeil(usize, targets.len, width) catch unreachable;
        self.identity = true;
        self.epoch = self.owner.epoch.load(.acquire);
        var writer = if (targets.len == 0) null else self.owner.output.pool.reserveAudience(self.owner.io, targets.len) orelse return error.Backpressured;
        defer if (writer) |*reservation| reservation.cancel(self.owner.io);
        for (targets, 0..) |target, at| {
            const index = target.handle.index;
            assert(index < self.ordinals.len and target.handle.generation != 0);
            assert(self.ordinals[index] == std.math.maxInt(usize));
            const protocol = for (self.owner.config.protocols, 0..) |selected, number| {
                if (selected.number == target.protocol) break number;
            } else return error.UnsupportedProtocol;
            writer.?.handles[at] = target.handle;
            self.indices[at] = index;
            self.ordinals[index] = at;
            self.members[at] = .{ .protocol = protocol, .generation = target.handle.generation };
            self.identity = self.identity and index == at;
            self.available[protocol] = @max(self.available[protocol], self.owner.outputCredit(target.handle));
            self.recipients += 1;
            self.protocol_masks[protocol * self.words + at / width] |= @as(usize, 1) << @as(Shift, @intCast(at % width));
        }
        if (writer) |*reservation| {
            self.audience_handles = reservation.handles;
            self.audience = reservation.finish();
        }
        self.active = true;
    }

    pub fn cancel(self: *Broadcast) void {
        assert(self.active);
        for (self.entries[self.committed..self.count]) |*entry| entry.packet.cancel();
        if (self.audience) |audience| audience.release(self.owner.io);
        self.audience = null;
        self.audience_handles = &.{};
        self.active = false;
    }

    pub fn finish(self: *Broadcast) void {
        assert(self.active);
        self.commit();
        self.cancel();
    }

    pub fn write(self: *Broadcast, comptime implementations: anytype, comptime Encoder: type, excluded: ?network.Handle, required: ?Receipt, arguments: anytype, maximum_bytes: usize) !Receipt {
        return self.writeGroup(implementations, Encoder, excluded, required, arguments, &.{maximum_bytes});
    }

    pub fn writeGroup(self: *Broadcast, comptime implementations: anytype, comptime Encoder: type, excluded: ?network.Handle, required: ?Receipt, arguments: anytype, capacities: []const usize) !Receipt {
        assert(self.active);
        assert(capacities.len > 0 and capacities.len <= service.Service.batch_max);
        const omitted = if (excluded) |handle| self.ordinalOf(handle) else null;
        if (required) |receipt| assert(receipt.owner == self and receipt.generation == self.generation and receipt.first + receipt.count <= self.count);
        const first = self.count;
        inline for (implementations) |Version| {
            const selected = for (self.owner.config.protocols, 0..) |protocol, index| {
                if (protocol.number == Version.protocol_number) break index;
            } else null;
            if (selected) |protocol| {
                const membership = self.protocol_masks[protocol * self.words ..][0..self.words];
                const wanted = for (membership) |bits| {
                    if (bits != 0) break true;
                } else false;
                if (wanted and self.available[protocol] != 0) version: {
                    if (capacities.len > self.entries.len - self.count) return error.BroadcastFull;
                    var packets: [service.Service.batch_max]service.Service.Packet = undefined;
                    var reserved = self.owner.reserveBatch(capacities, packets[0..capacities.len]) catch |err| {
                        if (err == error.Closed) break :version;
                        return err;
                    };
                    if (reserved != capacities.len) {
                        for (packets[0..reserved]) |*packet| packet.cancel();
                        self.commit();
                        self.owner.flush();
                        reserved = self.owner.reserveBatch(capacities, packets[0..capacities.len]) catch |err| {
                            if (err == error.Closed) break :version;
                            return err;
                        };
                    }
                    var transferred = false;
                    defer if (!transferred) {
                        for (packets[0..reserved]) |*packet| packet.cancel();
                    };
                    if (reserved != capacities.len) break :version;
                    var buffers: [service.Service.batch_max][]u8 = undefined;
                    var lengths: [service.Service.batch_max]usize = undefined;
                    for (packets[0..reserved], buffers[0..reserved]) |packet, *buffer| buffer.* = packet.bytes;
                    Encoder.writeGroup(Version, buffers[0..reserved], lengths[0..reserved], arguments) catch |err| {
                        if (err == error.UnsupportedEncoding) {
                            self.entries[self.count] = .{ .packet = .{ .owner = self.owner, .reservation = null, .bytes = &.{} }, .length = 0, .protocol = protocol, .excluded = omitted, .required = null, .group = .{}, .charge = 0, .unsupported = true };
                            self.count += 1;
                            break :version;
                        }
                        return err;
                    };
                    var charge: usize = 0;
                    for (lengths[0..reserved]) |length| charge += self.owner.framedBound(length);
                    if (charge > self.owner.config.buffer_bytes) return error.GroupTooLarge;
                    const dependency = if (required) |receipt| dependency: {
                        for (self.entries[receipt.first..][0..receipt.count], receipt.first..) |entry, index| if (entry.protocol == protocol and entry.group.index == 0) break :dependency index;
                        break :dependency std.math.maxInt(usize);
                    } else null;
                    const identity = packets[0].reservation.?;
                    for (packets[0..reserved], lengths[0..reserved], 0..) |packet, length, index| {
                        assert(length > 0 and length <= packet.bytes.len);
                        self.entries[self.count] = .{
                            .packet = packet,
                            .length = length,
                            .protocol = protocol,
                            .excluded = omitted,
                            .required = dependency,
                            .charge = if (index == 0) charge else 0,
                            .group = .{ .protocol = Version.protocol_number, .first = identity.page, .generation = identity.generation, .index = @intCast(index), .count = @intCast(reserved), .bytes = @intCast(charge) },
                        };
                        self.count += 1;
                    }
                    transferred = true;
                }
            }
        }
        return .{ .owner = self, .generation = self.generation, .first = first, .count = self.count - first };
    }

    /// Connection indices address captured generations until the next begin.
    pub fn handleAt(self: *const Broadcast, index: usize) network.Handle {
        assert(index < self.ordinals.len);
        const ordinal = self.ordinals[index];
        assert(ordinal < self.recipients and self.indices[ordinal] == index);
        return .{ .index = index, .generation = self.members[ordinal].generation };
    }

    fn ordinalOf(self: *const Broadcast, handle: network.Handle) usize {
        assert(handle.index < self.ordinals.len);
        const index = self.ordinals[handle.index];
        assert(index < self.recipients and self.indices[index] == handle.index and self.members[index].generation == handle.generation);
        return index;
    }

    fn clearResult(self: *Broadcast, index: usize) sparse_sets.Workspace.RowView {
        const result = self.results.row(index);
        result.clear();
        return result;
    }

    fn mergeResult(self: *Broadcast, index: usize, mask_value: []const usize, excluded: ?usize, mapped_index: usize) void {
        assert(mask_value.len == self.words and mapped_index < self.mapped_ready.len);
        if (excluded) |ordinal| assert(ordinal < self.recipients);
        const result = self.results.row(index);
        if (!self.identity) {
            const words = self.admission.len;
            const mapped = self.mapped_masks[mapped_index * words ..][0..words];
            const touched = self.mapped_words[mapped_index * words ..][0..words];
            if (!self.mapped_ready[mapped_index]) {
                for (touched[0..self.mapped_counts[mapped_index]]) |word| mapped[word] = 0;
                var count: usize = 0;
                for (mask_value, 0..) |value, word| {
                    var bits = value;
                    while (bits != 0) {
                        const ordinal = word * width + @ctz(bits);
                        const recipient = self.indices[ordinal];
                        const destination = recipient / width;
                        if (mapped[destination] == 0) {
                            touched[count] = destination;
                            count += 1;
                        }
                        mapped[destination] |= @as(usize, 1) << @as(Shift, @intCast(recipient % width));
                        bits &= bits - 1;
                    }
                }
                self.mapped_counts[mapped_index] = count;
                self.mapped_ready[mapped_index] = true;
            }
            const omitted = if (excluded) |ordinal| self.indices[ordinal] else null;
            for (touched[0..self.mapped_counts[mapped_index]]) |word| {
                var bits = mapped[word];
                if (omitted) |recipient| if (recipient / width == word) {
                    bits &= ~(@as(usize, 1) << @as(Shift, @intCast(recipient % width)));
                };
                result.uniteWord(word, bits);
            }
            return;
        }
        for (mask_value, 0..) |value, word| {
            var bits = value;
            if (excluded) |ordinal_index| if (ordinal_index / width == word) {
                bits &= ~(@as(usize, 1) << @as(Shift, @intCast(ordinal_index % width)));
            };
            if (bits != 0) result.uniteWord(word, bits);
        }
    }

    fn mask(self: *const Broadcast, index: usize) []const usize {
        const slot = self.entries[index].mask_index;
        return if (slot == std.math.maxInt(usize)) &.{} else self.masks[slot * self.words ..][0..self.words];
    }

    fn maskAt(self: *const Broadcast, index: usize, word: usize) usize {
        const entry = self.entries[index];
        const bits = self.mask(index);
        if (bits.len == 0) return 0;
        return if (entry.excluded != null and entry.excluded.? / width == word)
            bits[word] & ~(@as(usize, 1) << @as(Shift, @intCast(entry.excluded.? % width)))
        else
            bits[word];
    }

    fn retainMask(self: *Broadcast, bits: []const usize) ?usize {
        if (self.mask_index.get(std.mem.sliceAsBytes(bits))) |index| return index;
        if (self.mask_count == self.mask_capacity) return null;
        const index = self.mask_count;
        self.mapped_ready[index] = false;
        const destination = self.masks[index * self.words ..][0..self.words];
        @memcpy(destination, bits);
        const entry = self.mask_index.getOrPut(std.mem.sliceAsBytes(destination));
        assert(!entry.found_existing);
        entry.value_ptr.* = index;
        self.mask_count += 1;
        return index;
    }

    /// The view expires at the next accepted query or deinit.
    pub fn accepted(self: *Broadcast, receipt: Receipt) bit_sets.Set {
        assert(receipt.owner == self and receipt.generation == self.generation and receipt.first + receipt.count <= self.committed);
        const result = self.clearResult(0);
        for (receipt.first..receipt.first + receipt.count) |index| {
            const entry = self.entries[index];
            if (entry.group.index != 0 or self.mask(index).len == 0) continue;
            self.mergeResult(0, self.mask(index), entry.excluded, entry.mask_index);
        }
        return result.view();
    }

    /// The view expires at the next unsupported query or deinit.
    pub fn unsupported(self: *Broadcast, receipt: Receipt) bit_sets.Set {
        assert(receipt.owner == self and receipt.generation == self.generation and receipt.first + receipt.count <= self.committed);
        const result = self.clearResult(1);
        for (self.entries[receipt.first..][0..receipt.count]) |entry| {
            if (!entry.unsupported) continue;
            self.mergeResult(1, self.protocol_masks[entry.protocol * self.words ..][0..self.words], entry.excluded, self.mask_capacity + entry.protocol);
        }
        return result.view();
    }

    /// Admission completes here. Published packets retain their own audience loans.
    pub fn commit(self: *Broadcast) void {
        assert(self.active);
        if (self.committed == self.count) return;
        const owner = self.owner;
        owner.publication.lockUncancelable(owner.io);
        defer owner.publication.unlock(owner.io);
        const first = self.committed;
        if (owner.stopping.load(.acquire) or owner.epoch.load(.acquire) != self.epoch) {
            for (self.entries[first..self.count]) |*entry| entry.packet.cancel();
            self.committed = self.count;
            return;
        }
        @memset(self.totals, 0);
        @memset(self.healthy[0 .. self.owner.config.protocols.len * self.words], 0);
        @memset(self.forced[0..self.words], 0);
        for (0..self.recipients) |index| {
            self.members[index].excluded = 0;
            self.members[index].healthy = false;
            self.members[index].reserved = 0;
            self.members[index].remaining = 0;
        }
        for (self.entries[first..self.count]) |entry| {
            if (entry.group.index != 0) continue;
            const charge = entry.charge;
            self.totals[entry.protocol] += charge;
            if (entry.excluded) |index| if (self.members[index].protocol == entry.protocol) {
                self.members[index].excluded += charge;
            };
            if (entry.required) |index| {
                if (index == std.math.maxInt(usize) or self.entries[index].unsupported) {
                    const selected = self.protocol_masks[entry.protocol * self.words ..][0..self.words];
                    for (self.forced[0..self.words], selected, 0..) |*bits, members, word| {
                        const omitted: usize = if (entry.excluded != null and entry.excluded.? / width == word) @as(usize, 1) << @as(Shift, @intCast(entry.excluded.? % width)) else 0;
                        bits.* |= members & ~omitted;
                    }
                } else if (index < first) {
                    const selected = self.protocol_masks[entry.protocol * self.words ..][0..self.words];
                    for (self.forced[0..self.words], selected, 0..) |*bits, members, word| {
                        const admitted = self.maskAt(index, word);
                        const omitted: usize = if (entry.excluded != null and entry.excluded.? / width == word) @as(usize, 1) << @as(Shift, @intCast(entry.excluded.? % width)) else 0;
                        bits.* |= members & ~admitted & ~omitted;
                    }
                } else if (self.entries[index].excluded) |excluded| {
                    if (entry.excluded != excluded) self.forced[excluded / width] |= @as(usize, 1) << @as(Shift, @intCast(excluded % width));
                }
            }
        }
        var slow_count: usize = 0;
        var reservations: usize = 0;
        for (0..self.recipients) |index| {
            const handle = self.audience_handles[index];
            const member = &self.members[index];
            const needed = self.totals[member.protocol] - member.excluded;
            member.excluded = 0;
            if (needed == 0 or owner.moves[handle.index].state.load(.acquire) == .committed) continue;
            var value = owner.credit[handle.index].load(.acquire);
            while (value >> 32 == handle.generation and value & service.Service.active != 0) {
                const available: usize = @intCast(value & (service.Service.active - 1));
                const reserve = @min(available, needed);
                if (reserve == 0) break;
                if (owner.credit[handle.index].cmpxchgWeak(value, value - reserve, .acq_rel, .acquire)) |changed| {
                    value = changed;
                    continue;
                }
                reservations += 1;
                member.reserved = reserve;
                const bit = @as(usize, 1) << @as(Shift, @intCast(index % width));
                if (reserve == needed and self.forced[index / width] & bit == 0) {
                    member.healthy = true;
                    self.healthy[member.protocol * self.words + index / width] |= bit;
                } else {
                    member.remaining = reserve;
                    self.slow[slow_count] = index;
                    slow_count += 1;
                }
                break;
            }
        }
        owner.instruments.broadcast_reservations.add(reservations);
        owner.instruments.broadcast_exceptions.add(slow_count);
        @memset(self.totals, 0);
        var publications: [service.Service.batch_max]shared.SharedPages.Publication = undefined;
        var published: usize = 0;
        var total_published: usize = 0;
        for (self.entries[first..self.count], first..) |*entry, index| {
            const accepted_mask = self.admission[0..self.words];
            if (entry.unsupported) continue;
            if (entry.group.index == 0) {
                @memcpy(accepted_mask, self.healthy[entry.protocol * self.words ..][0..self.words]);
                if (entry.excluded) |excluded| accepted_mask[excluded / width] &= ~(@as(usize, 1) << @as(Shift, @intCast(excluded % width)));
                const charge = entry.charge;
                for (self.slow[0..slow_count]) |recipient| {
                    const member = &self.members[recipient];
                    if (member.protocol != entry.protocol or member.remaining < charge or entry.excluded == recipient) continue;
                    if (entry.required) |required| {
                        if (required == std.math.maxInt(usize) or self.maskAt(required, recipient / width) & (@as(usize, 1) << @as(Shift, @intCast(recipient % width))) == 0) continue;
                    }
                    accepted_mask[recipient / width] |= @as(usize, 1) << @as(Shift, @intCast(recipient % width));
                }
                const any = for (accepted_mask) |bits| {
                    if (bits != 0) break true;
                } else false;
                if (any) {
                    if (entry.excluded) |excluded| if (self.members[excluded].protocol == entry.protocol) {
                        accepted_mask[excluded / width] |= @as(usize, 1) << @as(Shift, @intCast(excluded % width));
                    };
                    if (self.retainMask(accepted_mask)) |slot| {
                        entry.mask_index = slot;
                        for (self.slow[0..slow_count]) |recipient| {
                            const member = &self.members[recipient];
                            if (member.protocol == entry.protocol and entry.excluded != recipient and self.maskAt(index, recipient / width) & (@as(usize, 1) << @as(Shift, @intCast(recipient % width))) != 0) member.remaining -= charge;
                        }
                    } else {
                        self.totals[entry.protocol] += charge;
                        if (entry.excluded) |excluded| if (self.members[excluded].protocol == entry.protocol) {
                            self.members[excluded].excluded += charge;
                        };
                    }
                }
            } else entry.mask_index = self.entries[index - entry.group.index].mask_index;
            const mask_value = self.mask(index);
            const any = for (mask_value) |bits| {
                if (bits != 0) break true;
            } else false;
            if (!any) {
                entry.packet.cancel();
                continue;
            }
            var reservation = entry.packet.reservation.?;
            reservation.bytes = reservation.bytes[0..entry.length];
            publications[published] = .{ .reservation = reservation, .audience = self.audience.?, .mask = mask_value, .excluded = entry.excluded, .group = entry.group };
            entry.packet.reservation = null;
            entry.packet.bytes = &.{};
            published += 1;
            if (published == publications.len) {
                _ = owner.preparing.fetchAdd(published, .release);
                owner.output.publishMany(publications[0..published]);
                total_published += published;
                published = 0;
            }
        }
        if (published != 0) {
            _ = owner.preparing.fetchAdd(published, .release);
            owner.output.publishMany(publications[0..published]);
            total_published += published;
        }
        if (total_published != 0) _ = owner.published_since_flush.fetchAdd(total_published, .release);
        for (0..self.recipients) |index| {
            const member = self.members[index];
            const refund = if (member.healthy) self.totals[member.protocol] - member.excluded else member.remaining;
            assert(refund <= member.reserved);
            if (refund != 0) owner.refund(self.audience_handles[index], refund);
        }
        self.committed = self.count;
    }
};
