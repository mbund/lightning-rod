const std = @import("std");
const network = @import("networking");

pub const StatusRequest = struct {
    protocol: i32,
    online_players: usize,
    maximum_players: usize,
};

pub const Keepalive = struct {
    interval_ns: i96 = 10 * std.time.ns_per_s,
    timeout_ns: i96 = 30 * std.time.ns_per_s,
};

pub const PlayEvent = union(enum) {
    attached: i96,
    poll: i96,
    park,
    disconnect: []const u8,
};

pub const PhaseEvent = union(enum) {
    begin,
    poll,
    admitted: ?[]const u8,
};

pub const LoginStep = union(enum) {
    send: []const u8,
    wait,
    done,
    reject: []const u8,
    admit,
    enable_compression,
};

pub const ConfigurationStep = union(enum) {
    send: []const u8,
    wait,
    done,
    reject: []const u8,
};

pub const Profile = struct {
    connection: network.Handle,
    protocol: i32,
    uuid: u128,
    name: []const u8,
};

pub const PhaseScope = struct {
    profile: Profile,
    destination: ?usize,
    identity: ?*u128 = null,
    io: std.Io,
    compression_threshold: ?usize = null,

    pub fn authenticate(self: PhaseScope, uuid: u128) !void {
        if (uuid == 0) return error.InvalidIdentity;
        const identity = self.identity orelse return error.NotLoginPhase;
        if (identity.* != 0) return error.AlreadyAuthenticated;
        identity.* = uuid;
    }
};

pub const State = struct {
    phase: enum { handshake, negotiating, admitting, attaching, play, parked, rejected } = .handshake,
    name: [16]u8 = @splat(0),
    name_len: usize = 0,
    uuid: u128 = 0,
};

pub const Event = union(enum) {
    packet: []const u8,
    poll,
    admitted: ?[]const u8,
    attached,
    park,
    restore,
    disconnect: []const u8,
};

pub fn Context(comptime Observer: type) type {
    return struct {
        connection: network.Handle,
        state: *State,
        protocol: *const Protocol,
        output: []u8,
        io: std.Io,
        now: i96,
        reloading: bool,
        compression_threshold: ?usize,
        observer: *Observer,
    };
}

pub const Handshake = struct {
    pub const Intent = enum { status, login };
    protocol: i32,
    intent: Intent,
};

pub const Frame = struct {
    body: []const u8,
    length: usize,
};

pub const Protocol = struct {
    number: i32,
    registries: []const Registry = &.{},
    frame_bound: FrameBound = .{},

    pub const FrameBound = struct {
        expansion_per_mille: usize = 1,
        overhead: usize = 134,

        pub fn bytes(self: FrameBound, length: usize) usize {
            const scaled = std.math.mul(usize, length, self.expansion_per_mille) catch return std.math.maxInt(usize);
            const expansion = scaled / 1000 + @intFromBool(scaled % 1000 != 0);
            const total = std.math.add(usize, length, expansion) catch return std.math.maxInt(usize);
            return std.math.add(usize, total, self.overhead) catch std.math.maxInt(usize);
        }
    };

    pub const Registry = struct { name: []const u8, entries: []const []const u8 };

    pub fn registryName(self: *const Protocol, registry: []const u8, id: i32) error{UnknownRegistryEntry}![]const u8 {
        if (id < 0) return error.UnknownRegistryEntry;
        for (self.registries) |table| {
            if (!std.mem.eql(u8, table.name, registry)) continue;
            if (id >= table.entries.len) return error.UnknownRegistryEntry;
            return table.entries[@intCast(id)];
        }
        return error.UnknownRegistryEntry;
    }

    pub fn registryId(self: *const Protocol, registry: []const u8, name: []const u8) error{UnknownRegistryEntry}!i32 {
        for (self.registries) |table| {
            if (!std.mem.eql(u8, table.name, registry)) continue;
            for (table.entries, 0..) |entry, index| {
                if (std.mem.eql(u8, entry, name)) return @intCast(index);
            }
            break;
        }
        return error.UnknownRegistryEntry;
    }
};
