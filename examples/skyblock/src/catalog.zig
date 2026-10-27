const std = @import("std");
const lightning_rod = @import("lightning_rod");
const records = @import("records");
const sessions = @import("sessions");

pub const maximum = 255;
pub const endpoints = maximum + 1;
pub const maximum_members = 4;
pub const maximum_players = 64;
pub const maximum_active = maximum_players;
pub const island_connections = 8;
pub const island_namespace = "skyblock:membership";
const magic = "LRSKYB03";
const member_magic = "LRMEMB01";
const maximum_profiles = maximum * maximum_members + maximum_players;

pub const Member = struct {
    uuid: u128,
    name: [16]u8 = @splat(0),
    name_len: u8 = 0,

    pub fn named(uuid: u128, name: []const u8) Member {
        std.debug.assert(name.len > 0 and name.len <= 16);
        var self: Member = .{ .uuid = uuid, .name_len = @intCast(name.len) };
        @memcpy(self.name[0..name.len], name);
        return self;
    }
};

pub const State = struct {
    members: [maximum_members]Member = @splat(.{ .uuid = 0 }),
    count: usize = 0,

    pub fn owner(self: *const State) ?u128 {
        return if (self.count == 0) null else self.members[0].uuid;
    }

    pub fn read(space: lightning_rod.storage.Space) !State {
        var bytes: [9 + maximum_members * 33]u8 = undefined;
        const length = try records.Value.init(space).read(&bytes) orelse return .{};
        if (length < 9 or !std.mem.eql(u8, bytes[0..8], member_magic)) return error.CorruptIslandMembership;
        const count = bytes[8];
        if (count == 0 or count > maximum_members or length != 9 + @as(usize, count) * 33) return error.CorruptIslandMembership;
        var self: State = .{ .count = count };
        for (self.members[0..count], 0..) |*member, index| {
            const entry = bytes[9 + index * 33 ..][0..33];
            member.* = .{ .uuid = std.mem.readInt(u128, entry[0..16], .big), .name_len = entry[16], .name = entry[17..33].* };
            if (member.name_len == 0 or member.name_len > member.name.len or !std.unicode.utf8ValidateSlice(member.name[0..member.name_len])) return error.CorruptIslandMembership;
            for (self.members[0..index]) |previous| if (previous.uuid == member.uuid) return error.CorruptIslandMembership;
        }
        return self;
    }

    pub fn write(self: *const State, space: lightning_rod.storage.Space) !void {
        if (self.count == 0) return;
        std.debug.assert(self.count <= maximum_members);
        var bytes: [9 + maximum_members * 33]u8 = undefined;
        @memcpy(bytes[0..8], member_magic);
        bytes[8] = @intCast(self.count);
        for (self.members[0..self.count], 0..) |member, index| {
            const entry = bytes[9 + index * 33 ..][0..33];
            std.mem.writeInt(u128, entry[0..16], member.uuid, .big);
            entry[16] = member.name_len;
            @memcpy(entry[17..33], &member.name);
        }
        try records.Value.init(space).write(bytes[0 .. 9 + self.count * 33]);
    }
};

const Presence = struct {
    member: ?Member = null,
    location: usize = 0,
    handle: ?sessions.Handle = null,
    requested: ?usize = null,
    invitation: ?usize = null,
    invitation_sent: bool = false,
    notice: ?Notice = null,
    visit_request: ?usize = null,
    visit_sent: bool = false,
};

pub const Player = struct { uuid: u128, handle: sessions.Handle };
pub const Cursor = struct {
    source: ?*const Catalog = null,
    index: usize = endpoints,
    profiles: [maximum_players]?usize = @splat(null),
    revision: u64 = 0,
    players: [maximum_players]Player = undefined,
    count: usize = 0,
};
pub const Update = struct {
    notice: ?Notice = null,
    invitation: ?Member = null,
    visitor: ?Member = null,
    destination: ?usize = null,
};

pub const Notice = enum { created, joined, home, visit, hub };

pub const Error = error{ AlreadyMember, TargetAlreadyMember, IslandLimit, NoIsland, NotOwner, PlayerOffline, IslandFull, NoInvitation, NoVisitRequest, NotVisiting, CannotKickMember, ProfileLimit };

pub const Catalog = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    ids: [endpoints]u128 = @splat(0),
    states: [endpoints]State = @splat(.{}),
    profiles: [maximum_profiles]Presence = @splat(.{}),
    revision: std.atomic.Value(u64) = .init(1),

    pub fn read(space: lightning_rod.storage.Space) !?Catalog {
        var bytes: [10 + endpoints * 16 + maximum_players * 17]u8 = undefined;
        const length = try records.Value.init(space).read(&bytes) orelse return null;
        if (length < 10 + endpoints * 16 or !std.mem.eql(u8, bytes[0..8], magic)) return error.CorruptIslandCatalog;
        const count = std.mem.readInt(u16, bytes[8..10], .little);
        if (count > maximum_players or length != 10 + endpoints * 16 + @as(usize, count) * 17) return error.CorruptIslandCatalog;
        var self: Catalog = .{ .io = space.store.io };
        for (&self.ids, 0..) |*id, index| {
            id.* = std.mem.readInt(u128, bytes[10 + index * 16 ..][0..16], .big);
            if (id.* == 0) return error.CorruptIslandCatalog;
            for (self.ids[0..index]) |previous| if (previous == id.*) return error.CorruptIslandCatalog;
        }
        for (self.profiles[0..count], 0..) |*profile, index| {
            const entry = bytes[10 + endpoints * 16 + index * 17 ..][0..17];
            profile.* = .{ .member = .{ .uuid = std.mem.readInt(u128, entry[0..16], .big) }, .location = entry[16] };
            if (profile.location >= endpoints) return error.CorruptIslandCatalog;
            for (self.profiles[0..index]) |previous| if (previous.member.?.uuid == profile.member.?.uuid) return error.CorruptIslandCatalog;
        }
        return self;
    }

    pub fn open(store: *lightning_rod.storage.Store) !Catalog {
        const space = try store.openSpace("skyblock:islands");
        if (try read(space)) |self| return self;
        var self: Catalog = .{ .io = space.store.io };
        for (&self.ids, 0..) |*id, index| {
            var bytes: [16]u8 = undefined;
            try store.io.randomSecure(&bytes);
            bytes[6] = (bytes[6] & 0x0f) | 0x40;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            id.* = std.mem.readInt(u128, &bytes, .big);
            for (self.ids[0..index]) |previous| if (previous == id.*) return error.IslandIdCollision;
        }
        try self.write(space);
        return self;
    }

    pub fn write(self: *Catalog, space: lightning_rod.storage.Space) !void {
        var bytes: [10 + endpoints * 16 + maximum_players * 17]u8 = undefined;
        var count: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            @memcpy(bytes[0..8], magic);
            for (self.ids, 0..) |id, index| std.mem.writeInt(u128, bytes[10 + index * 16 ..][0..16], id, .big);
            for (self.profiles) |profile| {
                const member = profile.member orelse continue;
                if (profile.handle == null) continue;
                if (count == maximum_players) return error.TooManyOnlinePlayers;
                const entry = bytes[10 + endpoints * 16 + count * 17 ..][0..17];
                std.mem.writeInt(u128, entry[0..16], member.uuid, .big);
                entry[16] = @intCast(profile.location);
                count += 1;
            }
            std.mem.writeInt(u16, bytes[8..10], @intCast(count), .little);
        }
        try records.Value.init(space).write(bytes[0 .. 10 + endpoints * 16 + count * 17]);
    }

    pub fn load(self: *Catalog, index: usize, state: State) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (index == 0 and state.count != 0) return error.HubHasMembers;
        for (state.members[0..state.count]) |member| if (self.homeLocked(member.uuid) != null) return error.DuplicateIslandMembership;
        defer _ = self.revision.fetchAdd(1, .release);
        self.states[index] = state;
    }

    pub fn snapshot(self: *Catalog, index: usize) State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.states[index];
    }

    fn homeLocked(self: *const Catalog, uuid: u128) ?usize {
        for (self.states[1..], 1..) |state, index| for (state.members[0..state.count]) |member| if (member.uuid == uuid) return index;
        return null;
    }

    fn profileLocked(self: *Catalog, uuid: u128) ?*Presence {
        for (&self.profiles) |*profile| if (profile.member) |member| {
            if (member.uuid == uuid) return profile;
        };
        return null;
    }

    pub fn destination(self: *Catalog, uuid: u128) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.profileLocked(uuid)) |profile| {
            if (profile.location == 0 or self.states[profile.location].count != 0) return profile.location;
        }
        return self.homeLocked(uuid) orelse 0;
    }

    pub fn arrive(self: *Catalog, index: usize, member: Member, handle: sessions.Handle) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const profile = self.profileLocked(member.uuid) orelse blk: {
            for (&self.profiles) |*candidate| if (candidate.member == null) break :blk candidate;
            for (&self.profiles) |*candidate| if (candidate.handle == null) break :blk candidate;
            return error.ProfileLimit;
        };
        defer _ = self.revision.fetchAdd(1, .release);
        const same = if (profile.member) |previous| previous.uuid == member.uuid else false;
        profile.* = .{
            .member = member,
            .location = index,
            .handle = handle,
            .requested = if (same) profile.requested else null,
            .invitation = if (same) profile.invitation else null,
            .invitation_sent = same and profile.invitation_sent,
            .notice = if (same) profile.notice else null,
            .visit_request = if (same) profile.visit_request else null,
            .visit_sent = same and profile.visit_sent,
        };
        if (self.homeLocked(member.uuid)) |home| for (self.states[home].members[0..self.states[home].count]) |*saved| {
            if (saved.uuid == member.uuid) saved.* = member;
        };
    }

    pub fn depart(self: *Catalog, index: usize, handle: sessions.Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.profiles) |*profile| if (profile.location == index and std.meta.eql(profile.handle, handle)) {
            _ = self.revision.fetchAdd(1, .release);
            profile.* = .{};
            return;
        };
    }

    pub fn disconnect(self: *Catalog, uuid: u128) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.profileLocked(uuid)) |profile| {
            profile.* = .{};
            _ = self.revision.fetchAdd(1, .release);
        }
    }

    pub fn create(self: *Catalog, member: Member) Error!usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.homeLocked(member.uuid) != null) return error.AlreadyMember;
        const profile = self.profileLocked(member.uuid) orelse return error.PlayerOffline;
        for (self.states[1..], 1..) |*state, index| {
            if (state.count != 0) continue;
            defer _ = self.revision.fetchAdd(1, .release);
            state.members[0] = member;
            state.count = 1;
            profile.requested = index;
            profile.notice = .created;
            return index;
        }
        return error.IslandLimit;
    }

    pub fn invite(self: *Catalog, owner: u128, target: u128) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const home = self.homeLocked(owner) orelse return error.NoIsland;
        if (self.states[home].owner().? != owner) return error.NotOwner;
        if (self.homeLocked(target) != null) return error.TargetAlreadyMember;
        if (self.states[home].count == maximum_members) return error.IslandFull;
        const profile = self.profileLocked(target) orelse return error.PlayerOffline;
        if (profile.handle == null) return error.PlayerOffline;
        defer _ = self.revision.fetchAdd(1, .release);
        profile.invitation = home;
        profile.invitation_sent = false;
    }

    pub fn accept(self: *Catalog, member: Member, owner: u128) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.homeLocked(member.uuid) != null) return error.AlreadyMember;
        const profile = self.profileLocked(member.uuid) orelse return error.PlayerOffline;
        const home = profile.invitation orelse return error.NoInvitation;
        const state = &self.states[home];
        if (state.owner() != owner) return error.NoInvitation;
        if (state.count == maximum_members) return error.IslandFull;
        defer _ = self.revision.fetchAdd(1, .release);
        state.members[state.count] = member;
        state.count += 1;
        profile.invitation = null;
        profile.requested = home;
        profile.notice = .joined;
    }

    pub fn requestHome(self: *Catalog, uuid: u128) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.homeLocked(uuid) orelse return error.NoIsland;
        const profile = self.profileLocked(uuid) orelse return error.PlayerOffline;
        defer _ = self.revision.fetchAdd(1, .release);
        profile.requested = index;
        profile.notice = .home;
    }

    pub fn visit(self: *Catalog, uuid: u128, target: u128) Error!bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.homeLocked(target) orelse return error.NoIsland;
        const profile = self.profileLocked(uuid) orelse return error.PlayerOffline;
        if (self.homeLocked(uuid) == index) {
            defer _ = self.revision.fetchAdd(1, .release);
            profile.requested = index;
            profile.notice = .visit;
            return false;
        }
        const owner = self.profileLocked(self.states[index].owner().?) orelse return error.PlayerOffline;
        if (profile.handle == null or owner.handle == null) return error.PlayerOffline;
        defer _ = self.revision.fetchAdd(1, .release);
        profile.visit_request = index;
        profile.visit_sent = false;
        return true;
    }

    pub fn acceptVisit(self: *Catalog, owner: u128, visitor: u128) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.homeLocked(owner) orelse return error.NoIsland;
        if (self.states[index].owner() != owner) return error.NotOwner;
        const profile = self.profileLocked(visitor) orelse return error.PlayerOffline;
        if (profile.handle == null) return error.PlayerOffline;
        if (profile.visit_request != index) return error.NoVisitRequest;
        defer _ = self.revision.fetchAdd(1, .release);
        profile.visit_request = null;
        profile.requested = index;
        profile.notice = .visit;
    }

    pub fn kick(self: *Catalog, owner: u128, target: ?u128) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const uuid = target orelse owner;
        const profile = self.profileLocked(uuid) orelse return error.PlayerOffline;
        if (profile.handle == null) return error.PlayerOffline;
        if (target != null) {
            const index = self.homeLocked(owner) orelse return error.NoIsland;
            if (self.states[index].owner().? != owner) return error.NotOwner;
            if (profile.location != index) return error.NotVisiting;
            if (self.homeLocked(uuid) == index) return error.CannotKickMember;
        }
        defer _ = self.revision.fetchAdd(1, .release);
        profile.requested = 0;
        profile.notice = .hub;
    }

    /// Outputs consume notifications. Destinations remain pending until moved or canceled.
    /// A current cursor returns false without touching output.
    pub fn poll(self: *Catalog, index: usize, players: []const Player, updates: []Update, cursor: *Cursor) bool {
        std.debug.assert(index < endpoints and players.len <= maximum_players and players.len == updates.len);
        const same = cursor.source == self and cursor.index == index and cursor.count == players.len and same: {
            for (cursor.players[0..cursor.count], players) |previous, player| {
                if (!std.meta.eql(previous, player)) break :same false;
            }
            break :same true;
        };
        if (!same) {
            cursor.source = self;
            cursor.index = index;
            @memset(&cursor.profiles, null);
            @memcpy(cursor.players[0..players.len], players);
            cursor.count = players.len;
            cursor.revision = 0;
        }
        if (self.revision.load(.acquire) == cursor.revision) return false;
        @memset(updates, .{});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var pending = false;
        for (players, updates, 0..) |player, *update, i| {
            for (players[0..i]) |previous| std.debug.assert(previous.uuid != player.uuid);
            const profile = found: {
                if (cursor.profiles[i]) |slot| {
                    const profile = &self.profiles[slot];
                    if (profile.member) |member| if (member.uuid == player.uuid) break :found profile;
                }
                for (&self.profiles, 0..) |*profile, slot| {
                    if (profile.member) |member| if (member.uuid == player.uuid) {
                        cursor.profiles[i] = slot;
                        break :found profile;
                    };
                }
                continue;
            };
            if (profile.location != index or !std.meta.eql(profile.handle, player.handle)) continue;
            update.destination = profile.requested;
            pending = pending or update.destination != null;
            if (profile.requested == null) {
                update.notice = profile.notice;
                profile.notice = null;
            }
            if (profile.invitation) |home| if (!profile.invitation_sent) {
                update.invitation = self.states[home].members[0];
                profile.invitation_sent = true;
            };
            const home = self.homeLocked(player.uuid) orelse continue;
            if (self.states[home].owner() != player.uuid) continue;
            for (&self.profiles) |*visitor| {
                if (visitor.handle == null or visitor.visit_request != home or visitor.visit_sent) continue;
                pending = true;
                update.visitor = visitor.member;
                visitor.visit_sent = true;
                break;
            }
        }
        if (!pending) cursor.revision = self.revision.load(.monotonic);
        return true;
    }

    pub fn moved(self: *Catalog, uuid: u128, from: usize, target: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const profile = self.profileLocked(uuid) orelse unreachable;
        std.debug.assert(profile.location == from);
        defer _ = self.revision.fetchAdd(1, .release);
        profile.location = target;
        if (profile.requested == target) profile.requested = null;
    }

    pub fn cancelMove(self: *Catalog, uuid: u128, target: usize) ?Notice {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const profile = self.profileLocked(uuid) orelse return null;
        if (profile.requested != target) return null;
        defer _ = self.revision.fetchAdd(1, .release);
        const result = profile.notice;
        profile.requested = null;
        profile.notice = null;
        return result;
    }

    pub fn find(self: *Catalog, name: []const u8) ?Member {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.profiles) |profile| if (profile.handle != null) {
            if (profile.member) |member| if (std.ascii.eqlIgnoreCase(member.name[0..member.name_len], name)) return member;
        };
        for (self.states) |state| for (state.members[0..state.count]) |member| if (std.ascii.eqlIgnoreCase(member.name[0..member.name_len], name)) return member;
        return null;
    }

    pub fn list(self: *Catalog, output: *[maximum_profiles]Member) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.states) |state| for (state.members[0..state.count]) |member| {
            output[count] = member;
            count += 1;
        };
        for (self.profiles) |profile| {
            if (profile.handle == null) continue;
            const member = profile.member orelse continue;
            if (self.homeLocked(member.uuid) != null) continue;
            std.debug.assert(count < output.len);
            output[count] = member;
            count += 1;
        }
        return count;
    }
};
