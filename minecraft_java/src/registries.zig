const std = @import("std");
const packets = @import("registry_packets.zig");

// Keep snapshot bytes out of type parameters. They otherwise become part of symbol names.
pub fn Registries(comptime Version: type) type {
    return struct {
        pub const Builder = packets.RegistryPackets(Version.Protocol);
        pub const PreparedRegistries = Builder.PreparedRegistries;

        pub fn snapshot(allocator: std.mem.Allocator) !Builder.Snapshot {
            return Builder.Snapshot.read(allocator, Version.registry_snapshot, Version.minecraft_name);
        }

        pub fn init(allocator: std.mem.Allocator) !PreparedRegistries {
            const data = try snapshot(allocator);
            defer data.deinit(allocator);
            return Builder.build(allocator, Version.protocol_number, data);
        }
    };
}
