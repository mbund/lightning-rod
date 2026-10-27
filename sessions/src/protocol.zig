const std = @import("std");
const network = @import("networking");
const framing = @import("shared.zig");

pub const Packets = union(enum) {
    framed: []const u8,
    packets: []const []const u8,

    pub fn next(self: *Packets) !?[]const u8 {
        switch (self.*) {
            .framed => |bytes| {
                if (bytes.len == 0) return null;
                const value = try framing.frame(bytes, std.math.maxInt(usize));
                self.* = .{ .framed = bytes[value.length..] };
                return value.body;
            },
            .packets => |values| {
                if (values.len == 0) return null;
                self.* = .{ .packets = values[1..] };
                return values[0];
            },
        }
    }
};

pub const Packet = union(enum) {
    buffered: struct { storage: []u8, length: usize },
    borrowed: []const u8,
};

pub const Fragments = struct {
    first: []const u8,
    second: []const u8 = &.{},
};

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
    poll: *Poll,
    park,
    disconnect: []const u8,
};

pub const Poll = struct {
    now: i96 = 0,
    deadline: ?i96 = null,

    pub fn wakeAt(self: *Poll, deadline: i96) void {
        self.deadline = @min(self.deadline orelse deadline, deadline);
    }
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

// Responses outside the supplied output buffer must remain immutable until configuration drains.
pub const ConfigurationStep = union(enum) {
    send: []const u8,
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

pub const LoginVerification = struct {
    context: *anyopaque,
    vtable: *const VTable,
    const VTable = struct { verify: *const fn (*anyopaque) anyerror![16]u8 };

    pub fn init(context: anytype, comptime verify: anytype) LoginVerification {
        const Adapter = struct {
            const vtable: VTable = .{ .verify = invoke };
            fn invoke(raw: *anyopaque) anyerror![16]u8 {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                return verify(typed);
            }
        };
        return .{ .context = context, .vtable = &Adapter.vtable };
    }

    pub fn run(self: LoginVerification) ![16]u8 {
        return self.vtable.verify(self.context);
    }
};

pub const Event = union(enum) {
    verified: [16]u8,
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
        poll: *Poll,
        reloading: bool,
        compression_threshold: ?usize,
        observer: *Observer,
        verification: ?*?LoginVerification = null,
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
