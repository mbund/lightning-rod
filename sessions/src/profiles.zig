const std = @import("std");
const network = @import("networking");

/// What a player brings beyond a name and UUID: the textures of their skin and cape as their
/// account's profile signed them, and how their client shows the skin.
pub const PlayerProfile = struct {
    /// Mojang's textures property: base64 JSON naming the skin and cape, and its signature.
    /// Values seen are under a kilobyte; a signature is 684 bytes.
    pub const value_max = 2048;
    pub const signature_max = 1024;

    textures_value: [value_max]u8 = undefined,
    textures_value_len: u16 = 0,
    textures_signature: [signature_max]u8 = undefined,
    textures_signature_len: u16 = 0,
    /// The skin layers the client shows, as its settings name them: cape, jacket, sleeves,
    /// trousers and hat, one bit each. Nothing until the client says.
    skin_parts: u8 = 0,
    /// What an online-mode client tells Mojang it joined this server with: SHA-1 over the server
    /// id, the shared secret and the server's public key. Login reads it once encryption is on.
    server_hash: ?[20]u8 = null,

    pub fn textures(self: *const PlayerProfile) ?Textures {
        if (self.textures_value_len == 0) return null;
        return .{ .value = self.textures_value[0..self.textures_value_len], .signature = self.textures_signature[0..self.textures_signature_len] };
    }

    pub fn setTextures(self: *PlayerProfile, value: []const u8, signature: []const u8) !void {
        if (value.len == 0 or value.len > value_max or signature.len > signature_max) return error.TexturesTooLarge;
        @memcpy(self.textures_value[0..value.len], value);
        self.textures_value_len = @intCast(value.len);
        @memcpy(self.textures_signature[0..signature.len], signature);
        self.textures_signature_len = @intCast(signature.len);
    }
};

pub const Textures = struct { value: []const u8, signature: []const u8 };

/// Every connection's profile while the sessions thread fills it in, at login and while it
/// configures. An entry belongs to one generation of its slot, so a connection never reads
/// what the slot's last one left. Only the sessions thread touches it.
pub const Profiles = struct {
    const Entry = struct { generation: u32 = 0, profile: PlayerProfile = .{} };
    entries: []Entry,

    pub fn init(allocator: std.mem.Allocator, connections: usize) !Profiles {
        const entries = try allocator.alloc(Entry, connections);
        @memset(entries, .{});
        return .{ .entries = entries };
    }

    pub fn deinit(self: *Profiles, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Profiles) usize {
        return self.entries.len * @sizeOf(Entry);
    }

    /// The connection's profile to fill in, cleared when it is the slot's first use by it.
    pub fn of(self: *Profiles, connection: network.Handle) *PlayerProfile {
        const entry = &self.entries[connection.index];
        if (entry.generation != connection.generation) entry.* = .{ .generation = connection.generation };
        return &entry.profile;
    }

    /// What the connection filled in, or the defaults if it filled in nothing.
    pub fn get(self: *const Profiles, connection: network.Handle) PlayerProfile {
        const entry = &self.entries[connection.index];
        return if (entry.generation == connection.generation) entry.profile else .{};
    }
};

test "a slot's next connection starts from the defaults" {
    var profiles = try Profiles.init(std.testing.allocator, 2);
    defer profiles.deinit(std.testing.allocator);
    const first: network.Handle = .{ .index = 1, .generation = 1 };
    profiles.of(first).skin_parts = 0x7f;
    try profiles.of(first).setTextures("value", "signature");
    try std.testing.expectEqual(@as(u8, 0x7f), profiles.get(first).skin_parts);
    try std.testing.expectEqualStrings("signature", profiles.get(first).textures().?.signature);
    const next: network.Handle = .{ .index = 1, .generation = 2 };
    try std.testing.expectEqual(@as(u8, 0), profiles.get(next).skin_parts);
    try std.testing.expect(profiles.of(next).textures() == null);
}
