const std = @import("std");
const records = @import("records");
const storage = @import("storage");

const assert = std.debug.assert;

pub const World = u32;

pub const Position = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const Section = struct {
    world: World,
    x: i32,
    y: i32,
    z: i32,
};

pub const BlockEdit = struct {
    index: u12,
    state: u16,
};

pub const SectionEdits = struct {
    section: Section,
    edits: []const BlockEdit,
};

pub const Observer = struct {
    context: *anyopaque,
    /// Edits are borrowed. Record invalidation here, without changing the world.
    changed: *const fn (*anyopaque, Section, []const BlockEdit) void,
};

pub const Source = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, Section, []u8) anyerror!usize,
};

pub const Chunks = struct {
    pub const id = "lightning_rod:chunks";

    pub const Configuration = struct {
        cache_sections: usize = 192,
        observers: usize = 8,
    };

    pub const Dependencies = struct {
        storage: storage.Namespace,
    };

    cache: records.Cache,
    source: ?Source = null,
    observers: []Observer,
    observer_count: usize = 0,
    notifying: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Chunks {
        const self = try allocator.create(Chunks);
        self.* = .{
            .cache = try records.Cache.init(allocator, io, deps.storage, .{
                .slots = configuration.cache_sections,
                .key_bytes = 16,
                .value_bytes = 8193,
            }),
            .observers = try allocator.alloc(Observer, configuration.observers),
        };
        return self;
    }

    pub fn observe(self: *Chunks, observer: Observer) !void {
        assert(!self.notifying);
        if (self.observer_count == self.observers.len)
            return error.ObserverCapacity;
        self.observers[self.observer_count] = observer;
        self.observer_count += 1;
    }

    /// This targeted query may read disk. Reuse section leases for scans and
    /// acquireMany for a known neighborhood instead of repeatedly calling it.
    pub fn getBlock(self: *Chunks, world: World, pos: Position) !u16 {
        const lease = try self.acquire(sectionAt(world, pos));
        defer lease.release();
        return lease.get(localIndex(pos));
    }

    pub fn setBlock(self: *Chunks, world: World, pos: Position, state: u16) !void {
        try self.setBlocks(sectionAt(world, pos), &.{.{ .index = localIndex(pos), .state = state }});
    }

    /// Apply a section-sized batch in caller order. Publish one change notification.
    pub fn setBlocks(self: *Chunks, section: Section, edits: []const BlockEdit) !void {
        assert(!self.notifying);
        if (edits.len == 0) return;
        try self.setSections(&.{.{ .section = section, .edits = edits }});
    }

    /// Apply section batches in caller order. Notify observers after releasing each acquired batch.
    pub fn setSections(self: *Chunks, sections: []const SectionEdits) !void {
        assert(!self.notifying);
        for (sections) |section| if (section.edits.len > 4096) return error.WorkingSetTooLarge;

        var positions: [192]Section = undefined;
        var leases: [192]Lease = undefined;
        var changed: [192]bool = undefined;
        var start: usize = 0;

        while (start < sections.len) {
            const count = @min(positions.len, self.cache.entries.len, sections.len - start);
            for (sections[start..][0..count], positions[0..count]) |section, *position|
                position.* = section.section;
            try self.acquireMany(positions[0..count], leases[0..count]);

            for (sections[start..][0..count], leases[0..count], changed[0..count]) |section, lease, *did_change| {
                did_change.* = false;
                if (section.edits.len == 0) continue;
                const view = lease.view();

                for (section.edits) |edit|
                    did_change.* = did_change.* or view.get(edit.index) != edit.state;
                if (!did_change.*) continue;

                const bytes = lease.record.edit();
                if (view == .uniform)
                    for (0..4096) |index|
                        std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], view.uniform, .little);

                bytes[0] = 1;
                for (section.edits) |edit|
                    std.mem.writeInt(u16, bytes[1 + @as(usize, edit.index) * 2 ..][0..2], edit.state, .little);
                lease.record.commit(8193);
            }

            for (leases[0..count]) |lease| lease.release();
            self.notifying = true;
            for (sections[start..][0..count], changed[0..count]) |section, did_change| {
                if (!did_change) continue;
                for (self.observers[0..self.observer_count]) |observer|
                    observer.changed(observer.context, section.section, section.edits);
            }
            self.notifying = false;
            start += count;
        }
    }

    pub fn acquire(self: *Chunks, section: Section) !Lease {
        var out: [1]Lease = undefined;
        try self.acquireMany(&.{section}, &out);
        return out[0];
    }

    pub fn acquireMany(self: *Chunks, sections: []const Section, output: []Lease) !void {
        assert(sections.len == output.len);
        if (sections.len > self.cache.entries.len)
            return error.WorkingSetTooLarge;

        var done: usize = 0;
        errdefer for (output[0..done]) |lease| lease.release();
        var keys: [192][16]u8 = undefined;
        var key_slices: [192][]const u8 = undefined;
        var leases: [192]records.Cache.Lease = undefined;

        while (done < sections.len) {
            const count = @min(keys.len, sections.len - done);

            for (sections[done..][0..count], 0..) |section, i| {
                keys[i] = encodeKey(section);
                key_slices[i] = &keys[i];
            }

            try self.cache.acquireMany(key_slices[0..count], leases[0..count]);
            var claimed: usize = 0;
            errdefer for (leases[claimed..count]) |lease| lease.release();

            for (leases[0..count]) |lease| {
                if (lease.read()) |bytes| {
                    if (bytes.len == 0 or (bytes[0] == 0 and bytes.len != 3) or (bytes[0] == 1 and bytes.len != 8193) or bytes[0] > 1)
                        return error.Corrupt;
                } else if (self.source) |source| {
                    const bytes = lease.edit();
                    const length = try source.read(source.context, sections[done], bytes);
                    if (length == 0 or (bytes[0] == 0 and length != 3) or (bytes[0] == 1 and length != 8193) or bytes[0] > 1)
                        return error.InvalidSection;
                    lease.commit(length);
                }

                output[done] = .{ .record = lease };
                done += 1;
                claimed += 1;
            }
        }
    }

    pub const Iterator = struct {
        chunks: *Chunks,
        sections: []const Section,
        leases: []Lease,
        live: usize = 0,
        next_section: usize = 0,

        /// The previous batch expires here. Defer deinit when exiting early.
        pub fn next(self: *Iterator) !?[]Lease {
            self.deinit();
            if (self.next_section == self.sections.len)
                return null;

            const count = @min(self.leases.len, self.chunks.cache.entries.len, self.sections.len - self.next_section);
            assert(count > 0);
            try self.chunks.acquireMany(self.sections[self.next_section..][0..count], self.leases[0..count]);
            self.live = count;
            self.next_section += count;
            assert(self.next_section <= self.sections.len);
            return self.leases[0..count];
        }

        pub fn deinit(self: *Iterator) void {
            for (self.leases[0..self.live]) |lease|
                lease.release();

            self.live = 0;
        }
    };

    pub fn iterate(self: *Chunks, sections: []const Section, leases: []Lease) Iterator {
        assert(leases.len > 0);
        return .{
            .chunks = self,
            .sections = sections,
            .leases = leases,
        };
    }

    pub fn checkpoint(self: *Chunks, _: storage.Namespace) !void {
        try self.cache.flush();
    }
};

pub const Lease = struct {
    record: records.Cache.Lease,

    pub fn view(self: Lease) View {
        const bytes = self.record.read() orelse return .{ .uniform = 0 };
        assert((bytes[0] == 0 and bytes.len == 3) or (bytes[0] == 1 and bytes.len == 8193));
        return if (bytes[0] == 0) .{ .uniform = std.mem.readInt(u16, bytes[1..3], .little) } else .{ .dense = bytes[1..8193] };
    }

    pub fn get(self: Lease, index: u12) u16 {
        return self.view().get(index);
    }

    pub fn release(self: Lease) void {
        self.record.release();
    }
};

/// Borrows the section until its lease is released.
pub const View = union(enum) {
    uniform: u16,
    dense: *const [8192]u8,

    pub fn get(self: View, index: u12) u16 {
        return switch (self) {
            .uniform => |state| state,
            .dense => |bytes| std.mem.readInt(u16, bytes[@as(usize, index) * 2 ..][0..2], .little),
        };
    }
};

pub fn sectionAt(world: World, pos: Position) Section {
    return .{
        .world = world,
        .x = @divFloor(pos.x, 16),
        .y = @divFloor(pos.y, 16),
        .z = @divFloor(pos.z, 16),
    };
}

pub fn localIndex(pos: Position) u12 {
    return @intCast(@mod(pos.y, 16) * 256 + @mod(pos.z, 16) * 16 + @mod(pos.x, 16));
}

pub fn encodeKey(section: Section) [16]u8 {
    var key: [16]u8 = undefined;
    std.mem.writeInt(u32, key[0..4], section.world, .big);
    std.mem.writeInt(i32, key[4..8], section.x, .big);
    std.mem.writeInt(i32, key[8..12], section.z, .big);
    std.mem.writeInt(i32, key[12..16], section.y, .big);
    return key;
}

pub fn uniform(state: u16, destination: []u8) usize {
    assert(destination.len >= 3);
    destination[0] = 0;
    std.mem.writeInt(u16, destination[1..3], state, .little);
    return 3;
}
