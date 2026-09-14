const protocols = @import("protocols");
const std = @import("std");

const framing_headroom = 3;

/// Sessions adds transport framing, compression, and encryption.
pub const Packet = struct {
    bytes: []const u8,
    storage: []u8,

    fn deinit(self: *Packet, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const KnownPack = @import("sessions").KnownPack;

pub const RegistryEntry = struct {
    id: []const u8,
    nbt: []const u8,
};

pub const Registry = struct {
    id: []const u8,
    entries: []const RegistryEntry,
};

pub const Snapshot = struct {
    registries: []const Registry,
    tags: []const u8,

    /// Names and NBT borrow the input. Only registry descriptors are allocated.
    pub fn read(allocator: std.mem.Allocator, bytes: []const u8, version: []const u8) !Snapshot {
        if (bytes.len < 16) return error.InvalidSnapshot;

        var reader = std.Io.Reader.fixed(bytes);
        if (!std.mem.eql(u8, try reader.take(8), "LRREG001")) return error.InvalidSnapshot;
        if (!std.mem.eql(u8, try reader.take(try reader.takeInt(u16, .big)), version)) return error.WrongVersion;

        const count = try reader.takeInt(u32, .big);
        if (count == 0 or count > 64) return error.InvalidSnapshot;

        const registries = try allocator.alloc(Registry, count);
        var initialized: usize = 0;
        errdefer {
            for (registries[0..initialized]) |registry| allocator.free(registry.entries);
            allocator.free(registries);
        }

        for (registries) |*registry| {
            const id = try reader.take(try reader.takeInt(u16, .big));
            const entry_count = try reader.takeInt(u32, .big);
            if (entry_count > bytes.len / 7) return error.InvalidSnapshot;

            const entries = try allocator.alloc(RegistryEntry, entry_count);
            registry.* = .{ .id = id, .entries = entries };
            initialized += 1;

            for (entries) |*entry| {
                const name = try reader.take(try reader.takeInt(u16, .big));
                const nbt = try reader.take(try reader.takeInt(u32, .big));
                entry.* = .{ .id = name, .nbt = nbt };
            }
        }

        const tags = try reader.take(try reader.takeInt(u32, .big));
        if (reader.seek != bytes.len) return error.InvalidSnapshot;

        const snapshot: Snapshot = .{ .registries = registries, .tags = tags };
        try validateSnapshot(snapshot);
        return snapshot;
    }

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        for (self.registries) |registry| allocator.free(registry.entries);
        allocator.free(self.registries);
    }
};

pub const PacketList = struct {
    values: []Packet,
    bytes: [][]const u8,

    fn deinit(self: *PacketList, allocator: std.mem.Allocator) void {
        for (self.values) |*packet| packet.deinit(allocator);
        allocator.free(self.values);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Use `known` only after `select` verifies the exact vanilla core pack.
/// Use `full` when the client does not acknowledge that pack.
pub const Plan = struct {
    protocol_number: i32,
    offered_packs: []const KnownPack,
    before_ack: PacketList,
    known: PacketList,
    full: PacketList,

    pub fn configurationData(self: *const Plan) ConfigurationData {
        return .{
            .number = self.protocol_number,
            .offered_packs = self.offered_packs,
            .before_ack = self.before_ack.bytes,
            .known = self.known.bytes,
            .full = self.full.bytes,
        };
    }

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.before_ack.deinit(allocator);
        self.known.deinit(allocator);
        self.full.deinit(allocator);
        self.* = undefined;
    }
};

/// Connection-independent packets include their IDs but exclude the transport length prefix.
pub const ConfigurationData = @import("sessions").Protocol;

pub fn build(
    allocator: std.mem.Allocator,
    protocol_number: i32,
    snapshot: Snapshot,
) !Plan {
    try validateSnapshot(snapshot);
    const offered_packs = packsForProtocol(protocol_number) orelse return error.UnsupportedProtocol;

    var before_ack = try allocatePacketList(allocator, 2);
    var pre_ack_initialized: usize = 0;
    errdefer {
        for (before_ack.values[0..pre_ack_initialized]) |*packet| packet.deinit(allocator);
        allocator.free(before_ack.values);
        allocator.free(before_ack.bytes);
    }
    before_ack.values[0] = try writeFeatureFlags(allocator);
    pre_ack_initialized += 1;
    before_ack.values[1] = try writeKnownPacks(allocator, offered_packs);
    pre_ack_initialized += 1;
    initializeBytes(&before_ack);

    var known = try writeVariant(allocator, snapshot, true);
    errdefer known.deinit(allocator);
    var full = try writeVariant(allocator, snapshot, false);
    errdefer full.deinit(allocator);

    return .{
        .protocol_number = protocol_number,
        .offered_packs = offered_packs,
        .before_ack = before_ack,
        .known = known,
        .full = full,
    };
}

fn allocatePacketList(allocator: std.mem.Allocator, count: usize) !PacketList {
    const values = try allocator.alloc(Packet, count);
    errdefer allocator.free(values);
    const bytes = try allocator.alloc([]const u8, count);
    errdefer allocator.free(bytes);
    return .{ .values = values, .bytes = bytes };
}

fn writeVariant(allocator: std.mem.Allocator, snapshot: Snapshot, known: bool) !PacketList {
    var packets = try allocatePacketList(allocator, snapshot.registries.len + 2);
    var initialized: usize = 0;
    errdefer {
        for (packets.values[0..initialized]) |*packet| packet.deinit(allocator);
        allocator.free(packets.values);
        allocator.free(packets.bytes);
    }

    for (snapshot.registries) |registry| {
        packets.values[initialized] = try writeRegistry(allocator, registry, known);
        initialized += 1;
    }

    packets.values[initialized] = try writeTags(allocator, snapshot.tags);
    initialized += 1;
    packets.values[initialized] = try writeFinish(allocator);
    initializeBytes(&packets);
    return packets;
}

fn initializeBytes(packets: *PacketList) void {
    for (packets.values, packets.bytes) |packet, *view| view.* = packet.bytes;
}

fn writeFeatureFlags(allocator: std.mem.Allocator) !Packet {
    var packet = try allocatePacket(allocator, 32);
    errdefer packet.deinit(allocator);
    const cursor = try (try protocols.wire.configuration.toClient.write(packet.storage[framing_headroom..])
        .feature_flags())
        .features(1);
    const final = try (try cursor.element("minecraft:vanilla")).finish();
    packet.bytes = final.finish();
    return packet;
}

fn writeKnownPacks(allocator: std.mem.Allocator, packs: []const KnownPack) !Packet {
    var packet = try allocatePacket(allocator, 32 + packs.len * 64);
    errdefer packet.deinit(allocator);
    var cursor = try (try protocols.wire.configuration.toClient.write(packet.storage[framing_headroom..])
        .select_known_packs())
        .packs(packs.len);

    for (packs) |pack| {
        const child = (try cursor.next()).?;
        const named = try child.namespace(pack.namespace);
        const identified = try named.id(pack.id);
        const completed = try identified.version(pack.version);
        try cursor.advance(completed);
    }

    const final = try cursor.finish();
    packet.bytes = final.finish();
    return packet;
}

fn writeRegistry(allocator: std.mem.Allocator, registry: Registry, known: bool) !Packet {
    var packet = try allocatePacket(allocator, registryPacketCapacity(registry));
    errdefer packet.deinit(allocator);
    var cursor = try (try protocols.wire.configuration.toClient.write(packet.storage[framing_headroom..])
        .registry_data())
        .id(registry.id);
    var entries = try cursor.entries(registry.entries.len);

    for (registry.entries) |entry| {
        const value = try (try entries.next()).?.key(entry.id);
        var optional = try value.value();
        const child = try optional.begin();
        const completed = if (known)
            try child.none()
        else
            try child.some(entry.nbt);
        try entries.advance(try optional.advance(completed));
    }

    const final = try entries.finish();
    packet.bytes = final.finish();
    return packet;
}

fn writeTags(allocator: std.mem.Allocator, tags: []const u8) !Packet {
    var packet = try allocatePacket(allocator, tags.len + 5);
    errdefer packet.deinit(allocator);
    const output = packet.storage[framing_headroom..];
    const rest = try protocols.support.write_varint(output, protocols.wire.configuration.toClient.packetId(.tags));
    @memcpy(rest[0..tags.len], tags);
    packet.bytes = output[0 .. output.len - rest.len + tags.len];
    return packet;
}

fn writeFinish(allocator: std.mem.Allocator) !Packet {
    var packet = try allocatePacket(allocator, 1);
    errdefer packet.deinit(allocator);
    const final = try protocols.wire.configuration.toClient.write(packet.storage[framing_headroom..])
        .finish_configuration();
    packet.bytes = final.finish();
    return packet;
}

fn allocatePacket(allocator: std.mem.Allocator, capacity: usize) !Packet {
    const storage = try allocator.alloc(u8, capacity + framing_headroom);
    return .{ .bytes = undefined, .storage = storage };
}

fn registryPacketCapacity(registry: Registry) usize {
    var capacity: usize = 16 + registry.id.len;

    for (registry.entries) |entry| capacity += 16 + entry.id.len + entry.nbt.len;
    return capacity;
}

fn validateSnapshot(snapshot: Snapshot) !void {
    if (snapshot.registries.len == 0 or snapshot.tags.len == 0) return error.IncompleteRegistrySnapshot;

    const tags = try protocols.wire.configuration.toClient.readBody(.tags, .{
        .id = protocols.wire.configuration.toClient.packetId(.tags),
        .body = snapshot.tags,
    });
    try (try tags.scan()).finish();

    for (snapshot.registries) |registry| {
        if (registry.id.len == 0) return error.IncompleteRegistrySnapshot;

        for (registry.entries) |entry| {
            if (entry.id.len == 0 or entry.nbt.len == 0) return error.IncompleteRegistrySnapshot;
            if ((try protocols.support.skip_anonymous_nbt(entry.nbt)).len != 0) return error.InvalidSnapshot;
        }
    }
}

const core_1_21_6 = [_]KnownPack{.{
    .namespace = "minecraft",
    .id = "core",
    .version = "1.21.6",
}};

const core_1_21_8 = [_]KnownPack{.{
    .namespace = "minecraft",
    .id = "core",
    .version = "1.21.8",
}};

fn packsForProtocol(protocol_number: i32) ?[]const KnownPack {
    return switch (protocol_number) {
        771 => &core_1_21_6,
        772 => &core_1_21_8,
        else => null,
    };
}
