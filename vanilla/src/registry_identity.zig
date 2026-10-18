const records = @import("records");
const std = @import("std");
const storage = @import("lightning_rod").storage;
const game_data = @import("game_data");

/// The canonical numeric IDs are part of the durable gameplay format.
pub const RegistryIdentity = struct {
    pub const id = "minecraft:registry_identity";
    pub const Configuration = struct {};
    pub const Dependencies = struct { storage: storage.Space };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*RegistryIdentity {
        const identity = game_data.canonical_identity;
        var stored: [32]u8 = undefined;
        if (try records.Value.init(deps.storage).read(&stored)) |length| {
            if (length != identity.len or !std.mem.eql(u8, &identity, &stored)) return error.IncompatibleCanonicalRegistry;
        } else {
            if (!deps.storage.store_is_new) return error.IncompatibleCanonicalRegistry;
            try records.Value.init(deps.storage).write(&identity);
        }
        const self = try allocator.create(RegistryIdentity);
        self.* = .{};
        return self;
    }
};
