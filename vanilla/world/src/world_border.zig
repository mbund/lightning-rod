//! The world border, as vanilla keeps it: one border, the overworld's, which every other world
//! copies with its center divided by the world's coordinate scale. It can grow or shrink over
//! time, it hurts players outside it, and bodies, items and projectiles collide with it. Every
//! client is told the whole border as it arrives in a world, and each change after.
//!
//! Vanilla 1.21.8 moves the border by the wall clock; this follows 1.21.11 and later, which
//! move it a step each tick, so a shrinking border keeps pace with everything else the server
//! simulates. Clients from before 1.21.11 are told the time left in milliseconds.

const std = @import("std");
const records = @import("records");
const lightning_rod = @import("lightning_rod");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_11 = @import("wire_1_21_11");
const minecraft = @import("minecraft_model");
const Worlds = @import("worlds").Worlds;
const Players = @import("players").players.Players;
const Dimensions = @import("vanilla_content").dimensions.Dimensions;
const border = @import("vanilla_content").border;

const assert = std.debug.assert;

pub const Bounds = border.Bounds;
pub const max_size = border.max_size;
pub const max_radius = border.max_radius;

pub const WorldBorder = struct {
    pub const id = "minecraft:world_border";

    /// The border of a server with none saved yet. Once saved, the saved one is kept, as
    /// vanilla keeps the border in level.dat.
    pub const Configuration = struct {
        center_x: f64 = 0,
        center_z: f64 = 0,
        /// How wide the border is.
        size: f64 = max_size,
        /// Damage each second to a player outside the border and its buffer, per block beyond.
        damage_per_block: f64 = 0.2,
        /// How far outside the border players go unhurt.
        safe_zone: f64 = 5,
        /// Seconds of a shrinking border's approach the client warns of.
        warning_time: i32 = 15,
        /// How near the border the client starts to warn.
        warning_blocks: i32 = 5,
    };

    pub const Dependencies = struct {
        storage: lightning_rod.storage.Space,
        worlds: *Worlds,
        dimensions: *Dimensions,
        players: *Players,
    };

    /// Center, size, damage, safe zone, warning time and blocks, then the target size and the
    /// ticks left to reach it.
    const encoded_size = 1 + 8 * 7 + 4 * 2;
    const encoded_version = 1;

    /// How often each thing clients are told has changed.
    const Revisions = struct { center: u32 = 0, size: u32 = 0, warning_time: u32 = 0, warning_blocks: u32 = 0 };

    /// What one client has been told.
    const View = struct {
        generation: u32 = 0,
        life: u32 = 0,
        arrivals: u32 = 0,
        /// Whether it has the whole border since it last arrived in a world.
        told: bool = false,
        sent: Revisions = .{},
    };

    deps: Dependencies,
    /// What bodies, items and projectiles collide with.
    shared: border.Border = .{},
    scales: []border.Scale = &.{},
    scale_count: usize = 0,
    /// A size changing over time: from what to what, over how many ticks, and the ticks left.
    from: f64,
    to: f64,
    duration: i64 = 0,
    remaining: i64 = 0,
    damage_per_block: f64,
    safe_zone: f64,
    warning_time: i32,
    warning_blocks: i32,
    revisions: Revisions = .{},
    views: []View = &.{},
    saved: [encoded_size]u8 = @splat(0),

    /// What is saved of the border, as WorldBorder.Settings has it: the size now, and while it
    /// moves the size it is going to and the ticks left, so it goes on from where it was.
    pub const Settings = struct {
        center_x: f64 = 0,
        center_z: f64 = 0,
        size: f64 = max_size,
        damage_per_block: f64 = 0.2,
        safe_zone: f64 = 5,
        warning_time: i32 = 15,
        warning_blocks: i32 = 5,
        target: f64 = max_size,
        remaining: i64 = 0,

        pub fn valid(self: Settings) bool {
            inline for (.{ self.center_x, self.center_z, self.size, self.damage_per_block, self.safe_zone, self.target }) |value|
                if (!std.math.isFinite(value)) return false;
            return @abs(self.center_x) <= max_radius and @abs(self.center_z) <= max_radius and
                self.size >= 1 and self.size <= max_size and self.target >= 1 and self.target <= max_size and
                self.damage_per_block >= 0 and self.safe_zone >= 0 and self.warning_time >= 0 and self.warning_blocks >= 0 and self.remaining >= 0;
        }

        pub fn encode(self: Settings) [encoded_size]u8 {
            assert(self.valid());
            var bytes: [encoded_size]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            writer.writeByte(encoded_version) catch unreachable;
            inline for (.{ self.center_x, self.center_z, self.size, self.damage_per_block, self.safe_zone, self.target }) |value|
                writer.writeInt(u64, @bitCast(value), .little) catch unreachable;
            writer.writeInt(i64, self.remaining, .little) catch unreachable;
            writer.writeInt(i32, self.warning_time, .little) catch unreachable;
            writer.writeInt(i32, self.warning_blocks, .little) catch unreachable;
            assert(writer.end == bytes.len);
            return bytes;
        }

        pub fn decode(bytes: []const u8) !Settings {
            if (bytes.len != encoded_size or bytes[0] != encoded_version) return error.CorruptWorldBorder;
            var reader = std.Io.Reader.fixed(bytes[1..]);
            var values: [6]f64 = undefined;
            for (&values) |*value| value.* = @bitCast(reader.takeInt(u64, .little) catch unreachable);
            const decoded: Settings = .{
                .center_x = values[0],
                .center_z = values[1],
                .size = values[2],
                .damage_per_block = values[3],
                .safe_zone = values[4],
                .target = values[5],
                .remaining = reader.takeInt(i64, .little) catch unreachable,
                .warning_time = reader.takeInt(i32, .little) catch unreachable,
                .warning_blocks = reader.takeInt(i32, .little) catch unreachable,
            };
            if (!decoded.valid()) return error.CorruptWorldBorder;
            return decoded;
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*WorldBorder {
        const self = try allocate(allocator, config, deps);
        if (try records.Value.init(deps.storage).read(&self.saved)) |length| self.apply(try .decode(self.saved[0..length]));
        self.refreshScales();
        return self;
    }

    /// Starting reads nothing but the configuration, so a reservation can run it before storage
    /// opens.
    pub fn allocate(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*WorldBorder {
        const initial: Settings = .{
            .center_x = config.center_x,
            .center_z = config.center_z,
            .size = config.size,
            .damage_per_block = config.damage_per_block,
            .safe_zone = config.safe_zone,
            .warning_time = config.warning_time,
            .warning_blocks = config.warning_blocks,
            .target = config.size,
        };
        if (!initial.valid()) return error.InvalidConfiguration;
        // Players start inside it.
        const spawn = deps.players.config.spawn orelse minecraft.Position{ .x = 0.5, .y = 65, .z = 0.5 };
        if (!Bounds.around(config.center_x, config.center_z, config.size).containsBox(spawn.x - 0.3, spawn.z - 0.3, spawn.x + 0.3, spawn.z + 0.3)) return error.InvalidConfiguration;
        const self = try allocator.create(WorldBorder);
        const views = try allocator.alloc(View, deps.players.records.len);
        @memset(views, .{});
        self.* = .{
            .deps = deps,
            .scales = try allocator.alloc(border.Scale, deps.worlds.entries.len),
            .from = config.size,
            .to = config.size,
            .damage_per_block = config.damage_per_block,
            .safe_zone = config.safe_zone,
            .warning_time = config.warning_time,
            .warning_blocks = config.warning_blocks,
            .views = views,
        };
        self.apply(initial);
        return self;
    }

    /// Saves the border a server is to start with, as importing a world does.
    pub fn save(space: lightning_rod.storage.Space, value: Settings) !void {
        if (!value.valid()) return error.InvalidWorldBorder;
        const bytes = value.encode();
        try records.Value.init(space).write(&bytes);
    }

    pub fn settings(self: *const WorldBorder) Settings {
        return .{
            .center_x = self.shared.center_x,
            .center_z = self.shared.center_z,
            .size = self.shared.size,
            .damage_per_block = self.damage_per_block,
            .safe_zone = self.safe_zone,
            .warning_time = self.warning_time,
            .warning_blocks = self.warning_blocks,
            .target = self.to,
            .remaining = self.remaining,
        };
    }

    /// WorldBorder.applySettings: a moving border moves on from its size now.
    fn apply(self: *WorldBorder, value: Settings) void {
        assert(value.valid());
        self.setCenter(value.center_x, value.center_z);
        self.damage_per_block = value.damage_per_block;
        self.safe_zone = value.safe_zone;
        self.setWarningTime(value.warning_time);
        self.setWarningBlocks(value.warning_blocks);
        self.lerpSize(value.size, value.target, value.remaining);
    }

    /// The border in a world.
    pub fn bounds(self: *const WorldBorder, world: u32) Bounds {
        return self.shared.of(world);
    }

    /// Whether a player may change the block at a position: ServerLevel.mayInteract's border.
    pub fn containsBlock(self: *const WorldBorder, world: u32, x: i32, z: i32) bool {
        return self.bounds(world).containsBlock(x, z);
    }

    pub fn centerX(self: *const WorldBorder) f64 {
        return self.shared.center_x;
    }

    pub fn centerZ(self: *const WorldBorder) f64 {
        return self.shared.center_z;
    }

    /// How wide the border is this tick.
    pub fn size(self: *const WorldBorder) f64 {
        return self.shared.size;
    }

    /// The size the border is moving to, or its size when still.
    pub fn target(self: *const WorldBorder) f64 {
        return self.to;
    }

    /// Ticks until the border reaches its target, none when still.
    pub fn remainingTicks(self: *const WorldBorder) i64 {
        return self.remaining;
    }

    pub fn setCenter(self: *WorldBorder, x: f64, z: f64) void {
        self.shared.center_x = x;
        self.shared.center_z = z;
        self.revisions.center +%= 1;
    }

    /// WorldBorder.setSize: this wide at once.
    pub fn setSize(self: *WorldBorder, value: f64) void {
        self.from = value;
        self.to = value;
        self.duration = 0;
        self.remaining = 0;
        self.shared.size = value;
        self.revisions.size +%= 1;
    }

    /// WorldBorder.lerpSizeBetween: from one size to another over some ticks.
    pub fn lerpSize(self: *WorldBorder, from: f64, to: f64, ticks: i64) void {
        if (from == to or ticks <= 0) return self.setSize(to);
        self.from = from;
        self.to = to;
        self.duration = ticks;
        self.remaining = ticks;
        self.shared.size = from;
        self.revisions.size +%= 1;
    }

    pub fn setDamagePerBlock(self: *WorldBorder, value: f64) void {
        self.damage_per_block = value;
    }

    pub fn setSafeZone(self: *WorldBorder, value: f64) void {
        self.safe_zone = value;
    }

    pub fn setWarningTime(self: *WorldBorder, seconds: i32) void {
        self.warning_time = seconds;
        self.revisions.warning_time +%= 1;
    }

    pub fn setWarningBlocks(self: *WorldBorder, blocks: i32) void {
        self.warning_blocks = blocks;
        self.revisions.warning_blocks +%= 1;
    }

    /// LivingEntity.baseTick's border damage to a player whose feet are at `x`, `z` with a box
    /// this wide, or none while it is inside the border or its buffer.
    pub fn damageOutside(self: *const WorldBorder, world: u32, x: f64, z: f64, half_width: f64) ?f32 {
        const area = self.bounds(world);
        if (area.containsBox(x - half_width, z - half_width, x + half_width, z + half_width)) return null;
        const beyond = area.distanceInside(x, z) + self.safe_zone;
        if (!(beyond < 0) or !(self.damage_per_block > 0)) return null;
        return @floatFromInt(@max(1, std.math.lossyCast(i32, @floor(-beyond * self.damage_per_block))));
    }

    /// ServerLevel.tick moves the border first, then each client hears what changed.
    pub fn tick(self: *WorldBorder) !void {
        self.advance();
        self.refreshScales();
        self.send();
    }

    /// A moving border's step: Mth.lerp of the share of its time gone by.
    fn advance(self: *WorldBorder) void {
        if (self.remaining == 0) return;
        self.remaining -= 1;
        if (self.remaining == 0) {
            self.from = self.to;
            self.duration = 0;
            self.shared.size = self.to;
            return;
        }
        const progress = @as(f64, @floatFromInt(self.duration - self.remaining)) / @as(f64, @floatFromInt(self.duration));
        self.shared.size = self.from + progress * (self.to - self.from);
    }

    /// Datapacks can change a dimension's coordinate scale, and worlds can be made any time.
    fn refreshScales(self: *WorldBorder) void {
        var count: usize = 0;
        for (self.deps.worlds.all()) |world| {
            const entry = self.deps.dimensions.get(world.dimension.name) orelse continue;
            if (entry.coordinate_scale == 1 or count == self.scales.len) continue;
            self.scales[count] = .{ .world = world.id, .scale = entry.coordinate_scale };
            count += 1;
        }
        self.scale_count = count;
        self.shared.scales = self.scales[0..count];
    }

    /// The whole border to a client that arrived in a world, as PlayerList.sendLevelInfo does,
    /// and what changed since to the rest, as the overworld border's listener does for all.
    fn send(self: *WorldBorder) void {
        const players = self.deps.players;
        const now = self.shape();
        for (players.activeSlots()) |index| {
            const player = &players.records[index];
            const handle = player.handle orelse continue;
            const view = &self.views[index];
            if (view.generation != handle.generation) view.* = .{ .generation = handle.generation };
            if (player.configuring or player.stage != .ready) continue;
            // A client forgets the border with the level it leaves: on joining, respawning and
            // changing worlds.
            if (view.arrivals != player.arrivals) {
                view.arrivals = player.arrivals;
                if (view.life != player.life) {
                    view.life = player.life;
                    view.told = false;
                }
            }
            if (!view.told) {
                if (!players.sendPacket(writeInitialize, player.protocol, handle, .{now})) continue;
                view.told = true;
                view.sent = self.revisions;
                continue;
            }
            if (view.sent.center != self.revisions.center) {
                if (!players.sendPacket(writeCenter, player.protocol, handle, .{now})) continue;
                view.sent.center = self.revisions.center;
            }
            if (view.sent.size != self.revisions.size) {
                const queued = if (now.remaining > 0)
                    players.sendPacket(writeLerp, player.protocol, handle, .{now})
                else
                    players.sendPacket(writeSize, player.protocol, handle, .{now});
                if (!queued) continue;
                view.sent.size = self.revisions.size;
            }
            if (view.sent.warning_time != self.revisions.warning_time) {
                if (!players.sendPacket(writeWarningTime, player.protocol, handle, .{now})) continue;
                view.sent.warning_time = self.revisions.warning_time;
            }
            if (view.sent.warning_blocks != self.revisions.warning_blocks) {
                if (!players.sendPacket(writeWarningBlocks, player.protocol, handle, .{now})) continue;
                view.sent.warning_blocks = self.revisions.warning_blocks;
            }
        }
    }

    /// What the packets tell of the border, as it stands now.
    const Shape = struct {
        center_x: f64,
        center_z: f64,
        size: f64,
        target: f64,
        remaining: i64,
        warning_time: i32,
        warning_blocks: i32,

        /// Before 1.21.11 clients move the border by the clock, and count milliseconds.
        fn milliseconds(self: Shape) i32 {
            return std.math.lossyCast(i32, std.math.mulWide(i64, self.remaining, 50));
        }

        fn ticks(self: Shape) i32 {
            return std.math.lossyCast(i32, self.remaining);
        }

        /// Since 1.21.11 the warning time is in ticks too.
        fn warningTicks(self: Shape) i32 {
            return std.math.lossyCast(i32, @as(i64, self.warning_time) * 20);
        }
    };

    fn shape(self: *const WorldBorder) Shape {
        return .{
            .center_x = self.shared.center_x,
            .center_z = self.shared.center_z,
            .size = self.shared.size,
            .target = self.to,
            .remaining = self.remaining,
            .warning_time = self.warning_time,
            .warning_blocks = self.warning_blocks,
        };
    }

    const writeInitialize = .{ writeInitialize_1_21_5, writeInitialize_1_21_11 };
    const writeLerp = .{ writeLerp_1_21_5, writeLerp_1_21_11 };
    const writeWarningTime = .{ writeWarningTime_1_21_5, writeWarningTime_1_21_11 };

    fn writeInitialize_1_21_5(packet: wire_1_21_5.play.toClient.packet_initialize_world_border.Writer, value: Shape) ![]u8 {
        const located = try (try packet.x(value.center_x)).z(value.center_z);
        const sized = try (try located.oldDiameter(value.size)).newDiameter(value.target);
        const timed = try (try sized.speed(value.milliseconds())).portalTeleportBoundary(@intFromFloat(max_radius));
        return (try (try timed.warningBlocks(value.warning_blocks)).warningTime(value.warning_time)).finish();
    }

    fn writeInitialize_1_21_11(packet: wire_1_21_11.play.toClient.packet_initialize_world_border.Writer, value: Shape) ![]u8 {
        const located = try (try packet.x(value.center_x)).z(value.center_z);
        const sized = try (try located.oldDiameter(value.size)).newDiameter(value.target);
        const timed = try (try sized.speed(value.ticks())).portalTeleportBoundary(@intFromFloat(max_radius));
        return (try (try timed.warningBlocks(value.warning_blocks)).warningTime(value.warningTicks())).finish();
    }

    fn writeCenter(packet: wire_1_21_5.play.toClient.packet_world_border_center.Writer, value: Shape) ![]u8 {
        return (try (try packet.x(value.center_x)).z(value.center_z)).finish();
    }

    fn writeLerp_1_21_5(packet: wire_1_21_5.play.toClient.packet_world_border_lerp_size.Writer, value: Shape) ![]u8 {
        return (try (try (try packet.oldDiameter(value.size)).newDiameter(value.target)).speed(value.milliseconds())).finish();
    }

    fn writeLerp_1_21_11(packet: wire_1_21_11.play.toClient.packet_world_border_lerp_size.Writer, value: Shape) ![]u8 {
        return (try (try (try packet.oldDiameter(value.size)).newDiameter(value.target)).speed(value.ticks())).finish();
    }

    fn writeSize(packet: wire_1_21_5.play.toClient.packet_world_border_size.Writer, value: Shape) ![]u8 {
        return (try packet.diameter(value.size)).finish();
    }

    fn writeWarningTime_1_21_5(packet: wire_1_21_5.play.toClient.packet_world_border_warning_delay.Writer, value: Shape) ![]u8 {
        return (try packet.warningTime(value.warning_time)).finish();
    }

    fn writeWarningTime_1_21_11(packet: wire_1_21_11.play.toClient.packet_world_border_warning_delay.Writer, value: Shape) ![]u8 {
        return (try packet.warningTime(value.warningTicks())).finish();
    }

    fn writeWarningBlocks(packet: wire_1_21_5.play.toClient.packet_world_border_warning_reach.Writer, value: Shape) ![]u8 {
        return (try packet.warningBlocks(value.warning_blocks)).finish();
    }

    pub fn checkpoint(self: *WorldBorder, space: lightning_rod.storage.Space) !void {
        const bytes = self.settings().encode();
        if (std.mem.eql(u8, &bytes, &self.saved)) return;
        try records.Value.init(space).write(&bytes);
        self.saved = bytes;
    }
};

/// A border with no server around it, as wide as asked.
fn testBorder(width: f64) WorldBorder {
    var world_border: WorldBorder = .{ .deps = undefined, .from = width, .to = width, .damage_per_block = 0.2, .safe_zone = 5, .warning_time = 15, .warning_blocks = 5 };
    world_border.setSize(width);
    return world_border;
}

test "a border moves a step each tick to its target and then stays" {
    var world_border = testBorder(100);
    world_border.lerpSize(100, 50, 4);
    try std.testing.expectEqual(@as(f64, 100), world_border.size());
    const expected = [_]f64{ 87.5, 75, 62.5, 50, 50 };
    for (expected) |value| {
        world_border.advance();
        try std.testing.expectEqual(value, world_border.size());
    }
    try std.testing.expectEqual(@as(i64, 0), world_border.remainingTicks());
    // The same size is no move at all.
    world_border.lerpSize(50, 50, 10);
    try std.testing.expectEqual(@as(i64, 0), world_border.remainingTicks());
}

test "border damage grows a point per five blocks past the buffer, and none inside it" {
    var world_border = testBorder(20);
    try std.testing.expectEqual(@as(?f32, null), world_border.damageOutside(0, 9, 0, 0.3));
    // Half in, half out: not within bounds, but well inside the buffer.
    try std.testing.expectEqual(@as(?f32, null), world_border.damageOutside(0, 10, 0, 0.3));
    try std.testing.expectEqual(@as(?f32, 1), world_border.damageOutside(0, 15.5, 0, 0.3));
    try std.testing.expectEqual(@as(?f32, 3), world_border.damageOutside(0, 30, 0, 0.3));
    world_border.setDamagePerBlock(0);
    try std.testing.expectEqual(@as(?f32, null), world_border.damageOutside(0, 30, 0, 0.3));
}

test "a saved border comes back where it was, still moving, and a corrupt one is refused" {
    var first = testBorder(64);
    first.setCenter(12.5, -3);
    first.lerpSize(64, 32, 8);
    first.advance();
    first.setWarningTime(30);
    first.setDamagePerBlock(1.5);
    const bytes = first.settings().encode();
    var second = testBorder(1);
    second.apply(try .decode(&bytes));
    try std.testing.expectEqual(@as(f64, 12.5), second.centerX());
    try std.testing.expectEqual(@as(f64, 60), second.size());
    try std.testing.expectEqual(@as(f64, 32), second.target());
    try std.testing.expectEqual(@as(i64, 7), second.remainingTicks());
    try std.testing.expectEqual(@as(i32, 30), second.warning_time);
    try std.testing.expectEqual(@as(f64, 1.5), second.damage_per_block);
    for (0..7) |_| second.advance();
    try std.testing.expectEqual(@as(f64, 32), second.size());
    var corrupt = bytes;
    corrupt[0] = 9;
    try std.testing.expectError(error.CorruptWorldBorder, WorldBorder.Settings.decode(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u64, corrupt[17..25], @bitCast(@as(f64, 0.5)), .little);
    try std.testing.expectError(error.CorruptWorldBorder, WorldBorder.Settings.decode(&corrupt));
}

test "the packets tell older clients milliseconds and newer ones ticks" {
    const value: WorldBorder.Shape = .{ .center_x = 0, .center_z = 0, .size = 10, .target = 5, .remaining = 40, .warning_time = 15, .warning_blocks = 5 };
    try std.testing.expectEqual(@as(i32, 2000), value.milliseconds());
    try std.testing.expectEqual(@as(i32, 40), value.ticks());
    try std.testing.expectEqual(@as(i32, 300), value.warningTicks());
    const long: WorldBorder.Shape = .{ .center_x = 0, .center_z = 0, .size = 10, .target = 5, .remaining = std.math.maxInt(i64), .warning_time = std.math.maxInt(i32), .warning_blocks = 5 };
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), long.milliseconds());
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), long.warningTicks());
}

test {
    std.testing.refAllDecls(WorldBorder);
}
