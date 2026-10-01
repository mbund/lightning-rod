const std = @import("std");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const wire_1_21_5 = @import("wire_1_21_5");

pub const Color = enum(u8) {
    pink,
    blue,
    red,
    green,
    yellow,
    purple,
    white,
};

pub const Division = enum(u8) {
    none,
    six,
    ten,
    twelve,
    twenty,
};

pub const Audience = union(enum) {
    everyone,
    player: u128,
};

pub const View = struct {
    title: []const u8,
    progress: f32 = 1,
    color: Color = .green,
    division: Division = .none,
    audience: Audience = .everyone,
};

pub const Handle = struct {
    index: u16,
    generation: u32,
};

const Versions = struct {
    generation: u32 = 0,
    title: u64 = 0,
    progress: u64 = 0,
    style: u64 = 0,
};

const Connection = struct {
    generation: u32 = 0,
    life: u32 = 0,
};

const Bar = struct {
    active: bool = false,
    versions: Versions = .{},
    title_nbt: [163]u8 = undefined,
    length: u8 = 0,
    progress: f32 = 0,
    color: Color = .green,
    division: Division = .none,
    audience: Audience = .everyone,
};

const Operation = enum(u8) {
    add,
    remove,
    progress,
    title,
    style,
};

pub const Bossbars = struct {
    pub const id = "lightning_rod:bossbars";

    pub const Configuration = struct {
        maximum: u16 = 8,
    };

    pub const Dependencies = struct {
        players: *vanilla.Players,
        packets: *vanilla.Packets,
    };

    deps: Dependencies,
    bars: []Bar,
    seen: []Versions,
    connections: []Connection,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Bossbars {
        if (config.maximum == 0 or config.maximum > 64)
            return error.InvalidConfiguration;

        const self = try allocator.create(Bossbars);
        const bars = try allocator.alloc(Bar, config.maximum);
        const count = deps.players.records.len;
        const seen = try allocator.alloc(Versions, config.maximum * count);
        const connections = try allocator.alloc(Connection, count);
        @memset(bars, .{});
        @memset(seen, .{});
        @memset(connections, .{});

        self.* = .{
            .deps = deps,
            .bars = bars,
            .seen = seen,
            .connections = connections,
            .targets = try allocator.alloc(sessions.Service.Target, count),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, count),
        };

        return self;
    }

    pub fn create(self: *Bossbars, view: View) !Handle {
        for (self.bars, 0..) |*bar, index| {
            if (bar.active)
                continue;

            const generation = try std.math.add(u32, bar.versions.generation, 1);
            bar.* = .{ .active = true, .versions = .{ .generation = generation } };
            const handle: Handle = .{ .index = @intCast(index), .generation = generation };

            self.update(handle, view) catch |err| {
                bar.active = false;
                return err;
            };

            return handle;
        }

        return error.BossbarCapacity;
    }

    pub fn update(self: *Bossbars, handle: Handle, view: View) !void {
        if (handle.index >= self.bars.len)
            return error.StaleBossbar;

        const bar = &self.bars[handle.index];
        if (!bar.active or bar.versions.generation != handle.generation)
            return error.StaleBossbar;

        if (view.title.len > bar.title_nbt.len - 3 or !std.unicode.utf8ValidateSlice(view.title) or !std.math.isFinite(view.progress) or view.progress < 0 or view.progress > 1)
            return error.InvalidBossbar;

        if (!std.mem.eql(u8, bar.title_nbt[3 .. 3 + bar.length], view.title)) {
            bar.title_nbt[0] = 8;
            std.mem.writeInt(u16, bar.title_nbt[1..3], @intCast(view.title.len), .big);
            @memcpy(bar.title_nbt[3..][0..view.title.len], view.title);
            bar.length = @intCast(view.title.len);
            bar.versions.title += 1;
        }

        if (bar.progress != view.progress) {
            bar.progress = view.progress;
            bar.versions.progress += 1;
        }

        if (bar.color != view.color or bar.division != view.division) {
            bar.color = view.color;
            bar.division = view.division;
            bar.versions.style += 1;
        }

        bar.audience = view.audience;
    }

    pub fn remove(self: *Bossbars, handle: Handle) !void {
        if (handle.index >= self.bars.len or !self.bars[handle.index].active or self.bars[handle.index].versions.generation != handle.generation)
            return error.StaleBossbar;

        self.bars[handle.index].active = false;
    }

    pub fn tick(self: *Bossbars) !void {
        const players = self.deps.players.records;

        for (players, self.connections, 0..) |player, *connection, index| {
            const handle = player.handle orelse continue;

            if (connection.generation != handle.generation or connection.life != player.life) {
                const replaced = connection.generation != handle.generation;
                connection.* = .{ .generation = handle.generation, .life = player.life };

                for (self.bars, 0..) |bar, slot| {
                    if (replaced or (bar.active and (bar.audience == .everyone or bar.audience.player == player.uuid)))
                        self.seen[slot * players.len + index] = .{};
                }
            }
        }

        for (self.bars, 0..) |*bar, index| {
            if (bar.versions.generation == 0)
                continue;

            const seen = self.seen[index * players.len ..][0..players.len];

            for (std.enums.values(Operation)) |operation| {
                var count: usize = 0;

                for (players, seen) |player, previous| {
                    const handle = player.handle orelse continue;
                    if (player.stage != .ready)
                        continue;

                    const visible = bar.active and (bar.audience == .everyone or bar.audience.player == player.uuid);
                    const needed = switch (operation) {
                        .add => visible and previous.generation != bar.versions.generation,
                        .remove => !visible and previous.generation != 0,
                        .title => visible and previous.generation == bar.versions.generation and previous.title != bar.versions.title,
                        .progress => visible and previous.generation == bar.versions.generation and previous.progress != bar.versions.progress,
                        .style => visible and previous.generation == bar.versions.generation and previous.style != bar.versions.style,
                    };
                    if (!needed)
                        continue;

                    self.targets[count] = .{ .handle = handle, .protocol = player.protocol };
                    count += 1;
                }

                if (count == 0) continue;

                try self.deps.packets.fanout(writeBossbar, self.targets[0..count], .{
                    @as(u128, 0x4c52424f_53534241_52000000_00000000) + index,
                    operation,
                    bar.title_nbt[0 .. 3 + bar.length],
                    bar.progress,
                    @as(i32, @intFromEnum(bar.color)),
                    @as(i32, @intFromEnum(bar.division)),
                }, 192, self.deliveries[0..count]);

                for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| {
                    if (delivery != .queued)
                        continue;

                    const previous = &seen[target.handle.index];

                    switch (operation) {
                        .add => previous.* = bar.versions,
                        .remove => previous.* = .{},
                        .title => previous.title = bar.versions.title,
                        .progress => previous.progress = bar.versions.progress,
                        .style => previous.style = bar.versions.style,
                    }
                }
            }
        }
    }

    fn writeBossbar(packet: wire_1_21_5.play.toClient.packet_boss_bar.Writer, uuid: u128, operation: Operation, title_nbt: []const u8, progress: f32, color: i32, dividers: i32) ![]u8 {
        const action = try packet.entityUUID(uuid);
        const after_action = try action.action(@intFromEnum(operation));

        var title = try after_action.title();
        const after_title = switch (operation) {
            .add, .title => blk: {
                const done = if (operation == .add) try (try title.begin()).case_0(title_nbt) else try (try title.begin()).case_3(title_nbt);
                break :blk try title.advance(done);
            },
            else => blk: {
                break :blk try title.advance(try (try title.begin()).case_default());
            },
        };

        var health = try after_title.health();
        const after_health = switch (operation) {
            .add, .progress => blk: {
                const done = if (operation == .add) try (try health.begin()).case_0(progress) else try (try health.begin()).case_2(progress);
                break :blk try health.advance(done);
            },
            else => blk: {
                break :blk try health.advance(try (try health.begin()).case_default());
            },
        };

        var color_field = try after_health.color();
        const after_color = switch (operation) {
            .add, .style => blk: {
                const done = if (operation == .add) try (try color_field.begin()).case_0(color) else try (try color_field.begin()).case_4(color);
                break :blk try color_field.advance(done);
            },
            else => blk: {
                break :blk try color_field.advance(try (try color_field.begin()).case_default());
            },
        };

        var dividers_field = try after_color.dividers();
        const after_dividers = switch (operation) {
            .add, .style => blk: {
                const done = if (operation == .add) try (try dividers_field.begin()).case_0(dividers) else try (try dividers_field.begin()).case_4(dividers);
                break :blk try dividers_field.advance(done);
            },
            else => blk: {
                break :blk try dividers_field.advance(try (try dividers_field.begin()).case_default());
            },
        };

        var flags_field = try after_dividers.flags();
        const after_flags = if (operation == .add) blk: {
            break :blk try flags_field.advance(try (try flags_field.begin()).case_0(0));
        } else blk: {
            break :blk try flags_field.advance(try (try flags_field.begin()).case_default());
        };

        return after_flags.finish();
    }
};
