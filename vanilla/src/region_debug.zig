const std = @import("std");
const commands = @import("commands");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const protocols = @import("protocols");
const entities = @import("entities");
const game_data = @import("game_data");
const entity_packets = @import("entity_packets.zig");
const wire = @import("wire_1_21_5");
const Players = @import("players.zig").Players;
const Streaming = @import("streaming.zig").Streaming;
const debug = @import("streaming_debug.zig");

pub const RegionDebug = struct {
    pub const id = "debug:regions";
    pub const Configuration = struct { maximum_viewers: usize = 4, refresh_ticks: u32 = 5 };
    pub const Dependencies = struct { commands: *commands.Commands, players: *Players, streaming: *Streaming, packets: *packets.Packets, entities: *entities.Entities };
    pub const permission: commands.Permission = .{ .name = "debug.regions", .description = "Inspect terrain disclosure" };

    const Action = enum { bounds, visibility, freeze, live, off };
    const Arguments = struct { action: ?Action };
    const Mode = enum { bounds, visibility };
    const Viewer = struct {
        handle: ?sessions.Handle = null,
        world: u32 = 0,
        life: u32 = 0,
        mode: Mode = .bounds,
        frozen: bool = false,
        captured: bool = false,
        stopping: bool = false,
        drawn: [maximum_edges]?debug.Edge = @splat(null),
        next_tick: u64 = 0,
        snapshot: debug.Snapshot = .{},
    };
    const maximum_edges = (debug.Snapshot.capacity + 1) * 12;

    deps: Dependencies,
    config: Configuration,
    command: u16,
    viewers: []Viewer,
    first_entity: i32,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*RegionDebug {
        if (config.maximum_viewers == 0 or config.refresh_ticks == 0) return error.InvalidDebugCapacity;
        const self = try allocator.create(RegionDebug);
        const slots = try allocator.alloc(debug.Slot, config.maximum_viewers);
        @memset(slots, .{});
        const viewers = try allocator.alloc(Viewer, config.maximum_viewers);
        @memset(viewers, .{});
        const first = try deps.entities.reserveIds(maximum_edges);
        if (first + maximum_edges > std.math.maxInt(i32)) return error.IdExhausted;
        self.* = .{ .deps = deps, .config = config, .command = 0, .viewers = viewers, .first_entity = @intCast(first) };
        self.command = (try deps.commands.register(self, commands.leaf(RegionDebug, Arguments, .{
            .name = "regions",
            .description = "Inspect shared world regions and section disclosure",
            .permission = &permission,
            .handler = execute,
            .arguments = .{ .action = .{} },
        }))).index;
        deps.streaming.attachDebug(slots);
        return self;
    }

    fn execute(self: *RegionDebug, context: commands.Context, args: Arguments) !void {
        const player = self.deps.players.find(context.sender) orelse return error.InvalidArgument;
        const handle = player.handle orelse return error.InvalidArgument;
        const action = args.action orelse .bounds;
        var selected: ?usize = null;
        var empty: ?usize = null;
        for (self.viewers, 0..) |viewer, index| {
            if (std.meta.eql(viewer.handle, handle)) selected = index;
            if (viewer.handle == null and empty == null) empty = index;
        }
        if (action == .off) {
            if (selected) |index| self.viewers[index].stopping = true;
            context.reply("Region overlay disabled");
            return;
        }
        if (action == .freeze and (selected == null or !self.viewers[selected.?].captured)) {
            context.reply("Enable /regions and wait for a snapshot before freezing");
            return;
        }
        const index = selected orelse empty orelse {
            context.reply("All region debug slots are occupied");
            return;
        };
        const viewer = &self.viewers[index];
        if (selected == null) viewer.* = .{ .handle = handle, .world = player.world, .life = player.life };
        switch (action) {
            .bounds => viewer.mode = .bounds,
            .visibility => viewer.mode = .visibility,
            .freeze => viewer.frozen = !viewer.frozen,
            .live => viewer.frozen = false,
            .off => unreachable,
        }
        viewer.next_tick = 0;
        viewer.stopping = false;
        if (!viewer.frozen) self.deps.streaming.requestDebug(index, handle, player.world, player.life);
        context.reply(if (viewer.frozen) "Debug snapshot frozen. /regions live to follow again" else if (viewer.mode == .bounds)
            "Cyan: source section bounds. /regions visibility, freeze, live, off"
        else
            "Green: authorized. Gold: retained. Red: concealed. Gray: pending. /regions freeze, live, off");
    }

    pub fn tick(self: *RegionDebug) !void {
        const tick_number = self.deps.players.ticks;
        for (self.viewers, 0..) |*viewer, index| {
            const handle = viewer.handle orelse continue;
            const player = &self.deps.players.records[handle.index];
            if (!std.meta.eql(player.handle, handle) or player.world != viewer.world or player.life != viewer.life or
                !self.deps.commands.allowed(player.uuid, self.command))
            {
                if (std.meta.eql(player.handle, handle) and player.stage == .ready) {
                    if (!try self.clear(viewer, player.protocol)) continue;
                }
                self.remove(index);
                continue;
            }
            if (viewer.stopping) {
                if (player.stage != .ready or !try self.clear(viewer, player.protocol)) continue;
                self.remove(index);
                continue;
            }
            if (player.stage != .ready or tick_number < viewer.next_tick) continue;
            viewer.next_tick = tick_number + self.config.refresh_ticks;
            if (!viewer.frozen) {
                viewer.captured = self.deps.streaming.readDebug(index, handle, player.world, player.life, &viewer.snapshot);
                self.deps.streaming.requestDebug(index, handle, player.world, player.life);
            }
            if (!viewer.captured) continue;
            try self.render(viewer, player.protocol);
        }
    }

    fn remove(self: *RegionDebug, index: usize) void {
        self.deps.streaming.clearDebug(index);
        self.viewers[index] = .{};
    }

    fn render(self: *RegionDebug, viewer: *Viewer, protocol: i32) !void {
        const snapshot = &viewer.snapshot;
        const target = [_]sessions.Service.Target{.{ .handle = viewer.handle.?, .protocol = protocol }};
        var delivery: [1]sessions.Service.Delivery = undefined;
        var counts: [4]usize = @splat(0);
        for (snapshot.sections[0..snapshot.count]) |section| counts[@backingInt(section.status)] += 1;
        var text: [240]u8 = undefined;
        const cell = snapshot.cell;
        const label = try std.fmt.bufPrint(&text, "{s}{s} section {d},{d},{d} component {d} | queued {d}/{d} | V{d} R{d} C{d} P{d}{s}", .{
            if (viewer.frozen) "FROZEN " else "",                 @tagName(viewer.mode),  cell[0],   cell[1],   cell[2],   snapshot.component,
            snapshot.queued_columns,                              snapshot.total_columns, counts[0], counts[1], counts[2], counts[3],
            if (snapshot.occlusion_active) "" else " | inactive",
        });
        try self.deps.packets.fanout(writeLabel, &target, .{label}, text.len + 16, &delivery);
        if (delivery[0] != .queued) return;
        var outlines: [debug.Snapshot.capacity + 1]debug.Outline = undefined;
        var outline_count: usize = 0;
        if (viewer.mode == .bounds) {
            if (snapshot.source) |bounds| {
                outlines[outline_count] = .{ .bounds = bounds, .color = 0x20ffff };
                outline_count += 1;
            }
        } else {
            for (snapshot.sections[0..snapshot.count]) |section| {
                outlines[outline_count] = .{ .bounds = section.bounds, .color = section.status.color() };
                outline_count += 1;
            }
        }
        for (&viewer.drawn, 0..) |*drawn, index| {
            const desired: ?debug.Edge = if (index < outline_count * 12) debug.Edge.at(outlines[index / 12], index % 12) else null;
            if (std.meta.eql(drawn.*, desired)) continue;
            const entity = self.first_entity + @as(i32, @intCast(index));
            if (desired) |edge| {
                const body: entities.State = .{ .uuid = (@as(u128, 0x726567696f6e) << 64) | @as(u32, @intCast(entity)), .kind = game_data.entities.block_display, .world = viewer.world, .position = edge.position };
                try self.deps.packets.fanoutGroup(.{ writeRemove, entity_packets.spawn, writeDisplay }, &target, .{ .{entity}, .{ entity, body }, .{ entity, edge } }, &.{ 16, 128, 256 }, &delivery);
            } else {
                try self.deps.packets.fanout(writeRemove, &target, .{entity}, 16, &delivery);
            }
            if (delivery[0] != .queued) return;
            drawn.* = desired;
        }
    }

    fn clear(self: *RegionDebug, viewer: *Viewer, protocol: i32) !bool {
        const target = [_]sessions.Service.Target{.{ .handle = viewer.handle.?, .protocol = protocol }};
        var delivered: [1]sessions.Service.Delivery = undefined;
        for (&viewer.drawn, 0..) |*drawn, index| {
            if (drawn.* == null) continue;
            try self.deps.packets.fanout(writeRemove, &target, .{self.first_entity + @as(i32, @intCast(index))}, 16, &delivered);
            if (delivered[0] != .queued) return false;
            drawn.* = null;
        }
        return true;
    }

    fn writeRemove(packet: wire.play.toClient.packet_entity_destroy.Writer, entity: i32) ![]u8 {
        return (try (try (try packet.entityIds(1)).element(entity)).finish()).finish();
    }

    const Display = struct { edge: debug.Edge, state: i32 };
    fn writeDisplay(packet: wire.play.toClient.packet_entity_metadata.Writer, registry: packets.Registry, entity: i32, edge: debug.Edge) ![]u8 {
        var metadata = try (try packet.entityId(entity)).metadata();
        return (try metadata.advance(try packets.nested(.{writeMetadata}).write(try metadata.begin(), Display{ .edge = edge, .state = try registry.blockState(game_data.registry.block_white_concrete_default_state) }))).finish();
    }

    fn writeMetadata(packet: wire.entityMetadata.Writer, value: Display) !wire.entityMetadata.Writer.Done {
        var entries = try packet.value(6);
        try entries.advance(try packets.nested(.{writeFlags}).write((try entries.next()).?, {}));
        try entries.advance(try packets.nested(.{writeScale}).write((try entries.next()).?, value.edge.scale));
        try entries.advance(try packets.nested(.{writeInt}).write((try entries.next()).?, .{ .key = 16, .value = 0xf000f0 }));
        try entries.advance(try packets.nested(.{writeRange}).write((try entries.next()).?, {}));
        try entries.advance(try packets.nested(.{writeInt}).write((try entries.next()).?, .{ .key = 22, .value = @intCast(value.edge.color) }));
        try entries.advance(try packets.nested(.{writeBlock}).write((try entries.next()).?, value.state));
        return entries.finish();
    }

    const IntEntry = struct { key: u8, value: i32 };
    fn writeInt(packet: wire.entityMetadataEntry.cases.value.int.Writer, value: IntEntry) !wire.entityMetadataEntry.cases.value.int.Writer.Done {
        return (try (try packet.key(value.key)).type()).value(value.value);
    }
    fn writeFlags(packet: wire.entityMetadataEntry.cases.value.byte.Writer, _: void) !wire.entityMetadataEntry.cases.value.byte.Writer.Done {
        return (try (try packet.key(0)).type()).value(0x40);
    }
    fn writeRange(packet: wire.entityMetadataEntry.cases.value.float.Writer, _: void) !wire.entityMetadataEntry.cases.value.float.Writer.Done {
        return (try (try packet.key(17)).type()).value(64);
    }
    fn writeBlock(packet: wire.entityMetadataEntry.cases.value.block_state.Writer, state: i32) !wire.entityMetadataEntry.cases.value.block_state.Writer.Done {
        return (try (try packet.key(23)).type()).value(state);
    }
    fn writeScale(packet: wire.entityMetadataEntry.cases.value.vector3.Writer, scale: [3]f32) !wire.entityMetadataEntry.cases.value.vector3.Writer.Done {
        var value = try (try (try packet.key(12)).type()).value();
        return value.advance(try packets.nested(.{writeVector}).write(try value.begin(), scale));
    }
    fn writeVector(packet: wire.vec3f.Writer, scale: [3]f32) !wire.vec3f.Writer.Done {
        return (try (try packet.x(scale[0])).y(scale[1])).z(scale[2]);
    }

    fn writeLabel(packet: wire.play.toClient.packet_system_chat.Writer, text: []const u8) ![]u8 {
        var nbt: [243]u8 = undefined;
        std.debug.assert(text.len <= nbt.len - 3);
        nbt[0] = 8;
        std.mem.writeInt(u16, nbt[1..3], @intCast(text.len), .big);
        @memcpy(nbt[3..][0..text.len], text);
        return (try (try packet.content(nbt[0 .. text.len + 3])).isActionBar(true)).finish();
    }
};

test "persistent debug displays and labels encode for each selected protocol" {
    var buffer: [512]u8 = undefined;
    inline for (protocols.implementations) |Version| {
        const registry: packets.Registry = .{ .entities = Version.Registry.canonical_entity_to_wire, .items = Version.Registry.canonical_item_to_wire, .blocks = Version.Registry.canonical_block_to_wire, .block_states = Version.Registry.canonical_block_state_to_wire, .block_state_bits = Version.Registry.block_state_bits, .sounds = Version.Registry.canonical_sound_to_wire, .effects = Version.Registry.canonical_effect_to_wire, .attributes = Version.Registry.canonical_attribute_to_wire };
        const bytes = try sessions.packet_api.encode(Version, RegionDebug.writeDisplay, &buffer, .{ registry, 123, debug.Edge{ .position = .{ -12.5, 83, 63.25 }, .scale = .{ 512, 0.2, 0.2 }, .color = 0x40ff60 } });
        const header = try Version.Protocol.play.toClient.readHeader(bytes);
        const metadata = try Version.Protocol.play.toClient.readBody(.entity_metadata, header);
        const entity, _ = try metadata.entityId();
        try std.testing.expectEqual(@as(i32, 123), entity);
        try (try metadata.scan()).finish();
        const label = try sessions.packet_api.encode(Version, RegionDebug.writeLabel, &buffer, .{"FROZEN cell 1,2,3"});
        const text_header = try Version.Protocol.play.toClient.readHeader(label);
        try (try (try Version.Protocol.play.toClient.readBody(.system_chat, text_header)).scan()).finish();
    }
}
