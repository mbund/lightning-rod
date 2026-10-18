const std = @import("std");
const support = @import("support");
const sessions = @import("sessions");

pub const EmbeddedRegistries = struct {
    /// Sessions adds transport framing, compression, and encryption.
    pub const Packet = struct {
        bytes: []const u8,
    };

    packets: []const Packet,
    registries: []const sessions.Protocol.Registry,
};

pub fn RegistryPackets(comptime Wire: type) type {
    return struct {
        const framing_headroom = 3;

        pub const Packet = EmbeddedRegistries.Packet;

        pub const RegistryEntry = struct {
            id: []const u8,
            nbt: []const u8,
        };

        pub const Registry = struct {
            id: []const u8,
            entries: []const RegistryEntry,
            synchronized: bool = true,
        };

        pub const Snapshot = struct {
            registries: []const Registry,
            tags: []const u8,

            /// Names and NBT borrow the input. Only registry descriptors are allocated.
            pub fn read(allocator: std.mem.Allocator, bytes: []const u8, version: []const u8) !Snapshot {
                if (bytes.len < 16) return error.InvalidSnapshot;

                var reader = std.Io.Reader.fixed(bytes);
                if (!std.mem.eql(u8, try reader.take(8), "LRREG002")) return error.InvalidSnapshot;
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
                    const synchronized = try reader.takeByte();
                    if (synchronized > 1) return error.InvalidSnapshot;
                    const entry_count = try reader.takeInt(u32, .big);
                    if (entry_count > bytes.len / 7) return error.InvalidSnapshot;

                    const entries = try allocator.alloc(RegistryEntry, entry_count);
                    registry.* = .{ .id = id, .entries = entries, .synchronized = synchronized == 1 };
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
            values: []const Packet,
        };

        pub const PreparedRegistries = struct {
            protocol_number: i32,
            packets: PacketList,
            registry_memory: std.heap.ArenaAllocator,
            registries: []const sessions.Protocol.Registry,

            pub fn configurationData(self: *const PreparedRegistries) sessions.Protocol {
                return .{
                    .number = self.protocol_number,
                    .registries = self.registries,
                };
            }

            pub fn deinit(self: *PreparedRegistries, _: std.mem.Allocator) void {
                self.registry_memory.deinit();
                self.* = undefined;
            }
        };

        /// Connection-independent packets include their IDs but exclude the transport length prefix.
        pub fn read(allocator: std.mem.Allocator, protocol_number: i32, bytes: []const u8, version: []const u8) !PreparedRegistries {
            const snapshot = try Snapshot.read(allocator, bytes, version);
            defer snapshot.deinit(allocator);
            return prepare(allocator, protocol_number, snapshot);
        }

        pub fn readEmbedded(allocator: std.mem.Allocator, comptime Version: type) !PreparedRegistries {
            const prepared = Version.registry_packets;
            return .{
                .protocol_number = Version.protocol_number,
                .packets = .{ .values = prepared.packets },
                .registries = prepared.registries,
                .registry_memory = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn build(
            allocator: std.mem.Allocator,
            protocol_number: i32,
            snapshot: Snapshot,
        ) !PreparedRegistries {
            try validateSnapshot(snapshot);
            return prepare(allocator, protocol_number, snapshot);
        }

        fn prepare(allocator: std.mem.Allocator, protocol_number: i32, snapshot: Snapshot) !PreparedRegistries {
            var registry_memory = std.heap.ArenaAllocator.init(allocator);
            errdefer registry_memory.deinit();
            const arena = registry_memory.allocator();
            const packets = try writePackets(arena, snapshot);
            const registries = try arena.alloc(sessions.Protocol.Registry, snapshot.registries.len);
            for (snapshot.registries, registries) |source, *destination| {
                const entries = try arena.alloc([]const u8, source.entries.len);
                for (source.entries, entries) |entry, *name| name.* = try arena.dupe(u8, entry.id);
                destination.* = .{ .name = try arena.dupe(u8, source.id), .entries = entries };
            }

            return .{
                .protocol_number = protocol_number,
                .packets = packets,
                .registry_memory = registry_memory,
                .registries = registries,
            };
        }

        fn writePackets(allocator: std.mem.Allocator, snapshot: Snapshot) !PacketList {
            var count: usize = 1;
            for (snapshot.registries) |registry| count += @intFromBool(registry.synchronized);
            const values = try allocator.alloc(Packet, count);
            var initialized: usize = 0;

            for (snapshot.registries) |registry| {
                if (!registry.synchronized) continue;
                const storage = try allocatePacket(allocator, registryPacketCapacity(registry));
                values[initialized] = .{ .bytes = try encodeRegistry(storage, registry) };
                initialized += 1;
            }

            const storage = try allocatePacket(allocator, snapshot.tags.len + 5);
            values[initialized] = .{ .bytes = try encodeTags(storage, snapshot.tags) };
            return .{ .values = values };
        }

        fn encodeRegistry(storage: []u8, registry: Registry) ![]const u8 {
            var cursor = try (try Wire.configuration.toClient.write(storage[framing_headroom..])
                .registry_data())
                .id(registry.id);
            var entries = try cursor.entries(registry.entries.len);

            for (registry.entries) |entry| {
                const value = try (try entries.next()).?.key(entry.id);
                var optional = try value.value();
                const child = try optional.begin();
                const completed = try child.some(entry.nbt);
                try entries.advance(try optional.advance(completed));
            }

            const final = try entries.finish();
            return final.finish();
        }

        fn encodeTags(storage: []u8, tags: []const u8) ![]const u8 {
            const output = storage[framing_headroom..];
            const rest = try support.write_varint(output, Wire.configuration.toClient.packetId(.tags));
            @memcpy(rest[0..tags.len], tags);
            return output[0 .. output.len - rest.len + tags.len];
        }

        fn allocatePacket(allocator: std.mem.Allocator, capacity: usize) ![]u8 {
            return allocator.alloc(u8, capacity + framing_headroom);
        }

        fn registryPacketCapacity(registry: Registry) usize {
            var capacity: usize = 16 + registry.id.len;

            for (registry.entries) |entry| capacity += 16 + entry.id.len + entry.nbt.len;
            return capacity;
        }

        fn validateSnapshot(snapshot: Snapshot) !void {
            if (snapshot.registries.len == 0 or snapshot.tags.len == 0) return error.IncompleteRegistrySnapshot;
            var scratch: support.NbtScratch = undefined;

            const tags = try Wire.configuration.toClient.readBody(.tags, .{
                .id = Wire.configuration.toClient.packetId(.tags),
                .body = snapshot.tags,
            });
            try (try tags.scan()).finish();

            for (snapshot.registries) |registry| {
                if (registry.id.len == 0) return error.IncompleteRegistrySnapshot;

                for (registry.entries) |entry| {
                    if (entry.id.len == 0) return error.IncompleteRegistrySnapshot;
                    if (registry.synchronized) {
                        if (entry.nbt.len == 0) return error.IncompleteRegistrySnapshot;
                        if ((try support.skip_anonymous_nbt_with_scratch(entry.nbt, &scratch)).len != 0) return error.InvalidSnapshot;
                    } else if (entry.nbt.len != 0) return error.InvalidSnapshot;
                }
            }
        }
    };
}
