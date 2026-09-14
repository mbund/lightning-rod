const std = @import("std");

const assert = std.debug.assert;
const Players = @import("players.zig").Players;
const registry = @import("protocols").registry;
const minecraft = @import("minecraft");

pub const Replication = struct {
    pub const id = "minecraft:player_replication";

    pub const Configuration = struct {};

    pub const Dependencies = struct { players: *Players };

    const Seen = struct {
        uuid: u128 = 0,
        generation: u32 = 0,
        stage: enum { absent, listed, spawned } = .absent,
        position: [3]i64 = @splat(0),
        yaw: i8 = 0,
        pitch: i8 = 0,
        head: ?i8 = null,
        flags: ?minecraft.EntityFlags = null,
        on_ground: bool = false,
    };

    const Observer = struct {
        generation: u32 = 0,
        world: u32 = 0,
    };

    deps: Dependencies,
    seen: []Seen,
    observers: []Observer,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Replication {
        const self = try allocator.create(Replication);
        const seen = try allocator.alloc(Seen, deps.players.records.len * deps.players.records.len);
        @memset(seen, .{});
        const observers = try allocator.alloc(Observer, deps.players.records.len);
        @memset(observers, .{});
        self.* = .{ .deps = deps, .seen = seen, .observers = observers };
        return self;
    }

    pub fn tick(self: *Replication) void {
        const players = self.deps.players;

        for (players.records, 0..) |observer, observer_index| {
            const row = self.seen[observer_index * players.records.len ..][0..players.records.len];
            const recipient = observer.handle orelse {
                @memset(row, .{});
                continue;
            };

            if (self.observers[observer_index].generation != recipient.generation) {
                @memset(row, .{});
                self.observers[observer_index] = .{ .generation = recipient.generation, .world = observer.world };
            }

            if (observer.stage != .ready) continue;

            if (self.observers[observer_index].world != observer.world) {
                for (row) |*seen| if (seen.stage == .spawned) {
                    seen.stage = .listed;
                    seen.flags = null;
                    seen.head = null;
                };

                self.observers[observer_index].world = observer.world;
            }

            for (players.records, row, 0..) |subject, *seen, index| {
                if (index == observer_index) continue;

                const entity_id: i32 = @intCast(index + 1);
                const generation = if (subject.handle) |handle| handle.generation else 0;
                if (seen.generation != generation) {
                    if (seen.stage == .spawned) {
                        if (!players.send(observer.protocol, &.{recipient}, .{ .entity_remove = entity_id })) continue;
                        seen.stage = .listed;
                    }

                    if (seen.stage == .listed) {
                        if (!players.send(observer.protocol, &.{recipient}, .{ .player_remove = seen.uuid })) continue;
                    }

                    seen.* = .{ .generation = generation, .uuid = subject.uuid };
                }

                if (subject.handle == null) continue;
                assert(generation != 0);
                const position: [3]i64 = .{ fixed(subject.position.x), fixed(subject.position.y), fixed(subject.position.z) };
                const yaw = angle(subject.rotation.yaw);
                const pitch = angle(subject.rotation.pitch);
                if (seen.stage == .absent) {
                    if (!players.send(observer.protocol, &.{recipient}, .{ .player_add = .{
                        .uuid = subject.uuid,
                        .name = subject.name[0..subject.name_len],
                        .gamemode = @intFromEnum(subject.gamemode),
                    } }))
                        continue;
                    seen.stage = .listed;
                }

                if (subject.world != observer.world) {
                    if (seen.stage == .spawned) {
                        if (!players.send(observer.protocol, &.{recipient}, .{ .entity_remove = entity_id })) continue;
                        seen.stage = .listed;
                        seen.flags = null;
                        seen.head = null;
                    }

                    continue;
                }

                if (subject.stage != .ready) continue;
                if (seen.stage == .listed) {
                    if (!players.send(observer.protocol, &.{recipient}, .{ .spawn = .{
                        .entity_id = entity_id,
                        .uuid = subject.uuid,
                        .entity_type = registry.entity_player_type_id,
                        .position = subject.position,
                        .pitch = pitch,
                        .yaw = yaw,
                        .head_yaw = yaw,
                        .data = 0,
                        .velocity_x = 0,
                        .velocity_y = 0,
                        .velocity_z = 0,
                    } }))
                        continue;
                    seen.stage = .spawned;
                    seen.position = position;
                    seen.yaw = yaw;
                    seen.pitch = pitch;
                }

                assert(seen.stage == .spawned);
                if (!std.meta.eql(position, seen.position) or yaw != seen.yaw or pitch != seen.pitch or subject.on_ground != seen.on_ground) {
                    const dx = position[0] - seen.position[0];
                    const dy = position[1] - seen.position[1];
                    const dz = position[2] - seen.position[2];

                    if (dx < -32768 or dx > 32767 or dy < -32768 or dy > 32767 or dz < -32768 or dz > 32767) {
                        if (!players.send(observer.protocol, &.{recipient}, .{ .entity_teleport = .{
                            .entity_id = entity_id,
                            .position = subject.position,
                            .rotation = subject.rotation,
                            .on_ground = subject.on_ground,
                        } }))
                            continue;
                    } else {
                        if (!players.send(observer.protocol, &.{recipient}, .{ .entity_move = .{
                            .entity_id = entity_id,
                            .dx = @intCast(dx),
                            .dy = @intCast(dy),
                            .dz = @intCast(dz),
                            .yaw = yaw,
                            .pitch = pitch,
                            .on_ground = subject.on_ground,
                        } }))
                            continue;
                    }

                    seen.position = position;
                    seen.yaw = yaw;
                    seen.pitch = pitch;
                    seen.on_ground = subject.on_ground;
                }

                if (seen.head == null or seen.head.? != yaw) {
                    if (!players.send(observer.protocol, &.{recipient}, .{ .entity_head_rotation = .{ .entity_id = entity_id, .yaw = yaw } })) continue;
                    seen.head = yaw;
                }

                if (seen.flags == null or !std.meta.eql(seen.flags.?, subject.flags)) {
                    const metadata = [_]u8{ 0, 0, @bitCast(subject.flags), 6, 21, if (subject.flags.sneaking) 5 else 0, 255 };
                    if (!players.send(observer.protocol, &.{recipient}, .{ .entity_metadata = .{ .entity_id = entity_id, .entries = &metadata } })) continue;
                    seen.flags = subject.flags;
                }
            }
        }
    }
};

fn angle(value: f32) i8 {
    return @bitCast(@as(u8, @intFromFloat(@mod(@floor(@as(f64, value) * 256.0 / 360.0), 256.0))));
}

fn fixed(value: f64) i64 {
    return @intFromFloat(@floor(value * 4096.0));
}
