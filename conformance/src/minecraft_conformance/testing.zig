const std = @import("std");
const canonicalizer = @import("codec_client.zig");
const fixture = @import("fixture.zig");
const raw_packet = @import("raw_packet.zig");
const adapter_api = @import("adapter.zig");
const packet_model = @import("packet.zig");

pub const Client = packet_model.Client;
pub const Fixture = fixture.Definition;
pub const Setup = fixture.Setup;
pub const Control = packet_model.Control;

pub const Vec3 = struct { x: f64, y: f64, z: f64 };
pub const BlockPos = struct { x: i32, y: i16, z: i32 };
pub const Face = enum { down, up, north, south, west, east };
pub const PlayerAction = enum { start_destroy_block, abort_destroy_block, stop_destroy_block };
pub const EntityAction = enum { start_sprinting, stop_sprinting };

/// Typed authoring surface for serverbound actions. `canonical` is the escape
/// hatch for a newly generated packet that has not earned a convenience case:
/// protocol support is never gated on this union being updated.
pub const Action = union(enum) {
    move: struct { position: Vec3, on_ground: bool },
    look: struct { yaw: f32, pitch: f32 = 0, on_ground: bool = true },
    player_action: struct { action: PlayerAction, position: BlockPos },
    entity_action: EntityAction,
    player_input: struct { shift: bool = false, sprint: bool = false },
    use_item_on: struct {
        against: BlockPos,
        face: Face,
        cursor_x: f32 = 0.5,
        cursor_y: f32 = 0.5,
        cursor_z: f32 = 0.5,
        sequence: i32,
    },
    select_hotbar_slot: u4,
    attack_entity: struct { target: []const u8 },
    interact_entity: struct { target: []const u8, hand: i32 = 0 },
    command: []const u8,
    creative_slot: struct { slot: i16, item: []const u8, count: u8 },
    respawn,
    close_player_screen,
    container_click: struct {
        window_id: i32 = 0,
        slot: i16,
        button: i8,
        mode: i32,
        claimed: ?ClaimedStack = null,
    },
    canonical: packet_model.Packet,

    pub const ClaimedStack = struct { slot: i16, item_id: i32, count: i32 };

    fn encode(
        self: Action,
        normalizer: *canonicalizer.Canonicalizer,
        buffer: []u8,
        client: []const u8,
    ) ![]const u8 {
        var builder = PacketBuilder{};
        const packet: packet_model.Packet = switch (self) {
            .move => |value| .{ .name = "move", .fields = &.{
                builder.fieldFmt(0, "x", "{d}", .{value.position.x}),
                builder.fieldFmt(1, "y", "{d}", .{value.position.y}),
                builder.fieldFmt(2, "z", "{d}", .{value.position.z}),
                builder.field(3, "on_ground", if (value.on_ground) "1" else "0"),
            } },
            .look => |value| .{ .name = "look", .fields = &.{
                builder.fieldFmt(0, "yaw", "{d}", .{value.yaw}),
                builder.fieldFmt(1, "pitch", "{d}", .{value.pitch}),
                builder.field(2, "on_ground", if (value.on_ground) "1" else "0"),
            } },
            .player_action => |value| .{ .name = "player_action", .fields = &.{
                builder.field(0, "action", @tagName(value.action)),
                builder.blockPos(1, "position", value.position),
            } },
            .entity_action => |value| .{ .name = "entity_action", .fields = &.{
                builder.field(0, "subject", client),
                builder.field(1, "action", @tagName(value)),
            } },
            .player_input => |value| .{ .name = "player_input", .fields = &.{
                builder.field(0, "shift", if (value.shift) "1" else "0"),
                builder.field(1, "sprint", if (value.sprint) "1" else "0"),
            } },
            .use_item_on => |value| .{ .name = "use_item_on", .fields = &.{
                builder.blockPos(0, "against", value.against),
                builder.field(1, "face", @tagName(value.face)),
                builder.fieldFmt(2, "cursor_x", "{d}", .{value.cursor_x}),
                builder.fieldFmt(3, "cursor_y", "{d}", .{value.cursor_y}),
                builder.fieldFmt(4, "cursor_z", "{d}", .{value.cursor_z}),
                builder.fieldFmt(5, "sequence", "{d}", .{value.sequence}),
            } },
            .select_hotbar_slot => |value| .{ .name = "select_hotbar_slot", .fields = &.{
                builder.fieldFmt(0, "slot", "{d}", .{value}),
            } },
            .attack_entity => |value| .{ .name = "attack_entity", .fields = &.{builder.field(0, "target", value.target)} },
            .interact_entity => |value| .{ .name = "interact_entity", .fields = &.{
                builder.field(0, "target", value.target),
                builder.fieldFmt(1, "hand", "{d}", .{value.hand}),
            } },
            .command => |value| .{ .name = "command", .fields = &.{builder.field(0, "text", value)} },
            .creative_slot => |value| .{ .name = "creative_slot", .fields = &.{
                builder.fieldFmt(0, "slot", "{d}", .{value.slot}),
                builder.field(1, "item", value.item),
                builder.fieldFmt(2, "count", "{d}", .{value.count}),
            } },
            .respawn => .{ .name = "respawn" },
            .close_player_screen => .{ .name = "close_screen", .fields = &.{builder.field(0, "screen", "player")} },
            .container_click => |value| if (value.claimed) |claimed|
                .{ .name = "container_click", .fields = &.{
                    builder.fieldFmt(0, "window", "{d}", .{value.window_id}),
                    builder.fieldFmt(1, "slot", "{d}", .{value.slot}),
                    builder.fieldFmt(2, "button", "{d}", .{value.button}),
                    builder.fieldFmt(3, "mode", "{d}", .{value.mode}),
                    builder.fieldFmt(4, "claimed_slot", "{d}", .{claimed.slot}),
                    builder.fieldFmt(5, "claimed_item_id", "{d}", .{claimed.item_id}),
                    builder.fieldFmt(6, "claimed_count", "{d}", .{claimed.count}),
                } }
            else
                .{ .name = "container_click", .fields = &.{
                    builder.fieldFmt(0, "window", "{d}", .{value.window_id}),
                    builder.fieldFmt(1, "slot", "{d}", .{value.slot}),
                    builder.fieldFmt(2, "button", "{d}", .{value.button}),
                    builder.fieldFmt(3, "mode", "{d}", .{value.mode}),
                } },
            .canonical => |packet| packet,
        };
        return normalizer.encodePacket(buffer, packet);
    }
};

const PacketBuilder = struct {
    fields: [8]packet_model.Field = undefined,
    values: [8][128]u8 = undefined,

    fn field(self: *PacketBuilder, index: usize, name: []const u8, value: []const u8) packet_model.Field {
        self.fields[index] = .{ .name = name, .value = .{ .literal = value } };
        return self.fields[index];
    }

    fn fieldFmt(self: *PacketBuilder, index: usize, name: []const u8, comptime format: []const u8, args: anytype) packet_model.Field {
        return self.field(index, name, std.fmt.bufPrint(&self.values[index], format, args) catch unreachable);
    }

    fn blockPos(self: *PacketBuilder, index: usize, name: []const u8, value: BlockPos) packet_model.Field {
        return self.fieldFmt(index, name, "{d},{d},{d}", .{ value.x, value.y, value.z });
    }
};

/// A canonical packet owned by one `Batch`. It remains valid until `deinit`.
pub const Packet = struct {
    recipient: []const u8,
    name: []const u8,
    fields: []const packet_model.Field,

    pub fn field(self: Packet, name: []const u8) ?[]const u8 {
        for (self.fields) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value.literal;
        return null;
    }

    pub fn fieldInt(self: Packet, comptime T: type, name: []const u8) !T {
        return std.fmt.parseInt(T, self.field(name) orelse return error.MissingCanonicalField, 10) catch error.InvalidCanonicalInteger;
    }

    pub fn fieldFloat(self: Packet, name: []const u8) !f64 {
        return std.fmt.parseFloat(f64, self.field(name) orelse return error.MissingCanonicalField) catch error.InvalidCanonicalFloat;
    }

    /// Extracts a top-level field from a generated `wire/*` packet. Generated
    /// canonicalization is the protocol schema's structural representation,
    /// so tests can inspect newly generated packets without adding a bespoke
    /// canonical packet type.
    pub fn wireField(self: Packet, wanted: []const u8) ?[]const u8 {
        const data = self.field("data") orelse return null;
        if (data.len < 2 or data[0] != '{' or data[data.len - 1] != '}') return null;
        const body = data[1 .. data.len - 1];
        var start: usize = 0;
        var depth: usize = 0;
        for (body, 0..) |byte, index| {
            switch (byte) {
                '{', '[' => depth += 1,
                '}', ']' => {
                    if (depth == 0) return null;
                    depth -= 1;
                },
                ';' => if (depth == 0) {
                    if (wireEntry(body[start..index], wanted)) |value| return value;
                    start = index + 1;
                },
                else => {},
            }
        }
        if (depth != 0) return null;
        return wireEntry(body[start..], wanted);
    }

    pub fn wireBytes(self: Packet, allocator: std.mem.Allocator, wanted: []const u8) ![]u8 {
        const encoded = self.wireField(wanted) orelse return error.MissingCanonicalField;
        if (encoded.len == 0 or encoded[0] != 'h' or (encoded.len - 1) % 2 != 0)
            return error.InvalidCanonicalBytes;
        const result = try allocator.alloc(u8, (encoded.len - 1) / 2);
        errdefer allocator.free(result);
        for (result, 0..) |*byte, index| {
            const high = std.fmt.charToDigit(encoded[1 + index * 2], 16) catch return error.InvalidCanonicalBytes;
            const low = std.fmt.charToDigit(encoded[2 + index * 2], 16) catch return error.InvalidCanonicalBytes;
            byte.* = @intCast(high << 4 | low);
        }
        return result;
    }

    /// Extracts one slot from the canonical `inventory.slots` field.
    pub fn inventorySlot(self: Packet, wanted: []const u8) ?[]const u8 {
        const slots = self.field("slots") orelse return null;
        var entries = std.mem.splitScalar(u8, slots, ',');
        while (entries.next()) |entry| {
            const equal = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..equal], wanted)) return entry[equal + 1 ..];
        }
        return null;
    }
};

fn wireEntry(entry: []const u8, wanted: []const u8) ?[]const u8 {
    const equal = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
    if (!std.mem.eql(u8, entry[0..equal], wanted)) return null;
    return entry[equal + 1 ..];
}

pub const Selector = struct {
    recipient: ?[]const u8 = null,
    name: ?[]const u8 = null,
    field_name: ?[]const u8 = null,
    field_value: ?[]const u8 = null,

    pub fn matches(self: Selector, packet: Packet) bool {
        if (self.recipient) |value| if (!std.mem.eql(u8, value, packet.recipient)) return false;
        if (self.name) |value| if (!std.mem.eql(u8, value, packet.name)) return false;
        if (self.field_name) |name| {
            const actual = packet.field(name) orelse return false;
            if (self.field_value) |value| if (!std.mem.eql(u8, value, actual)) return false;
        }
        return true;
    }
};

const BatchStorage = struct {
    arena: std.heap.ArenaAllocator,
    in_use: bool = false,
};

pub const Batch = struct {
    storage: ?*BatchStorage,
    packets: []Packet,

    pub fn deinit(self: *Batch) void {
        if (self.storage) |storage| storage.in_use = false;
        self.* = undefined;
    }

    pub fn count(self: *const Batch, selector: Selector) usize {
        var result: usize = 0;
        for (self.packets) |packet| if (selector.matches(packet)) {
            result += 1;
        };
        return result;
    }

    pub fn first(self: *const Batch, selector: Selector) ?*const Packet {
        for (self.packets) |*packet| if (selector.matches(packet.*)) return packet;
        return null;
    }

    pub fn one(self: *const Batch, selector: Selector) !*const Packet {
        var result: ?*const Packet = null;
        for (self.packets) |*packet| if (selector.matches(packet.*)) {
            if (result != null) {
                std.debug.print(
                    "multiple canonical packets matched recipient={s} name={s} field={s} value={s}\n",
                    .{
                        selector.recipient orelse "*",
                        selector.name orelse "*",
                        selector.field_name orelse "*",
                        selector.field_value orelse "*",
                    },
                );
                var matches = self.iterator(selector);
                while (matches.next()) |matched| {
                    std.debug.print("  recipient={s} packet={s}", .{ matched.recipient, matched.name });
                    for (matched.fields) |field|
                        std.debug.print(" {s}={s}", .{ field.name, field.value.literal });
                    std.debug.print("\n", .{});
                }
                return error.MultipleCanonicalPackets;
            }
            result = packet;
        };
        if (result) |packet| return packet;
        std.debug.print(
            "no canonical packet matched recipient={s} name={s} field={s} value={s}; batch contains {d} packets\n",
            .{
                selector.recipient orelse "*",
                selector.name orelse "*",
                selector.field_name orelse "*",
                selector.field_value orelse "*",
                self.packets.len,
            },
        );
        for (self.packets) |packet| {
            std.debug.print("  recipient={s} packet={s}", .{ packet.recipient, packet.name });
            for (packet.fields) |field|
                std.debug.print(" {s}={s}", .{ field.name, field.value.literal });
            std.debug.print("\n", .{});
        }
        return error.MissingCanonicalPacket;
    }

    pub fn indexOf(self: *const Batch, selector: Selector) ?usize {
        for (self.packets, 0..) |packet, index| if (selector.matches(packet)) return index;
        return null;
    }

    pub const Iterator = struct {
        batch: *const Batch,
        selector: Selector,
        index: usize = 0,
        pub fn next(self: *Iterator) ?*const Packet {
            while (self.index < self.batch.packets.len) {
                const packet = &self.batch.packets[self.index];
                self.index += 1;
                if (self.selector.matches(packet.*)) return packet;
            }
            return null;
        }
    };

    pub fn iterator(self: *const Batch, selector: Selector) Iterator {
        return .{ .batch = self, .selector = selector };
    }

    /// Observation aid for establishing or cleaning a Vanilla sample. It is
    /// deliberately a presentation method, not a persistent artifact format.
    pub fn write(self: *const Batch, writer: *std.Io.Writer) !void {
        for (self.packets) |packet| {
            try writer.print("recipient={s} packet={s}", .{ packet.recipient, packet.name });
            for (packet.fields) |field| try writer.print(" {s}={s}", .{ field.name, field.value.literal });
            try writer.writeByte('\n');
        }
    }
};

/// Black-box test driver. Inputs are encoded to raw packet bodies and outputs
/// are canonicalized only after the target has completed one exact tick.
pub const Harness = struct {
    const batch_storage_count = 8;

    allocator: std.mem.Allocator,
    adapter: adapter_api.Adapter,
    identities: []const raw_packet.Identity,
    normalizer: canonicalizer.Canonicalizer,
    batch_storage: [batch_storage_count]BatchStorage,

    pub fn init(allocator: std.mem.Allocator, adapter: adapter_api.Adapter, definition: Fixture, clients: []const Client) !Harness {
        const identities = try adapter.restore(definition, clients);
        var result = Harness{
            .allocator = allocator,
            .adapter = adapter,
            .identities = identities,
            .normalizer = canonicalizer.Canonicalizer.initWithAllocator(identities, allocator),
            .batch_storage = undefined,
        };
        for (&result.batch_storage) |*storage|
            storage.* = .{ .arena = .init(std.heap.page_allocator) };
        return result;
    }

    pub fn deinit(self: *Harness) void {
        self.normalizer.deinit();
        for (&self.batch_storage) |*storage| {
            std.debug.assert(!storage.in_use);
            storage.arena.deinit();
        }
        self.* = undefined;
    }

    pub fn send(self: *Harness, client: []const u8, action: Action) !void {
        var buffer: [4096]u8 = undefined;
        const body = try action.encode(&self.normalizer, &buffer, client);
        try self.adapter.stage(client, body);
    }

    pub fn control(self: *Harness, client: []const u8, operation: Control) !void {
        try self.adapter.control(client, operation);
    }

    pub fn restart(self: *Harness) !void {
        const identities = try self.adapter.restart();
        self.normalizer.deinit();
        self.identities = identities;
        self.normalizer = canonicalizer.Canonicalizer.initWithAllocator(self.identities, self.allocator);
    }

    pub fn tick(self: *Harness) !Batch {
        const outputs = try self.adapter.step();
        if (outputs.len == 0) return .{
            .storage = null,
            .packets = &.{},
        };
        const storage = for (&self.batch_storage) |*candidate| {
            if (candidate.in_use) continue;
            candidate.in_use = true;
            _ = candidate.arena.reset(.retain_capacity);
            break candidate;
        } else return error.TooManyLiveConformanceBatches;
        errdefer storage.in_use = false;
        const allocator = storage.arena.allocator();
        var packets: std.ArrayListUnmanaged(Packet) = .empty;
        for (outputs) |raw| {
            const output = (try self.normalizer.canonicalize(raw)) orelse continue;
            try packets.append(allocator, try clonePacket(allocator, output));
        }
        return .{
            .storage = storage,
            .packets = try packets.toOwnedSlice(allocator),
        };
    }
};

fn clonePacket(allocator: std.mem.Allocator, output: canonicalizer.Canonicalizer.Output) !Packet {
    const recipient = try allocator.dupe(u8, output.recipient);
    errdefer allocator.free(recipient);
    const name = try allocator.dupe(u8, output.packet.name);
    errdefer allocator.free(name);
    const fields = try allocator.alloc(packet_model.Field, output.packet.fields.len);
    errdefer allocator.free(fields);
    var initialized: usize = 0;
    errdefer for (fields[0..initialized]) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value.literal);
    };
    for (output.packet.fields, 0..) |entry, index| {
        const field_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(field_name);
        const literal = entry.value.literal;
        fields[index] = .{ .name = field_name, .value = .{ .literal = try allocator.dupe(u8, literal) } };
        initialized += 1;
    }
    return .{ .recipient = recipient, .name = name, .fields = fields };
}

test "wire fields preserve nested structural values" {
    const fields = [_]packet_model.Field{.{
        .name = "data",
        .value = .{ .literal = "{first={nested=1;other=[2,3]};second=h0a}" },
    }};
    const packet = Packet{ .recipient = "alice", .name = "wire/example", .fields = &fields };
    try std.testing.expectEqualStrings("{nested=1;other=[2,3]}", packet.wireField("first").?);
    try std.testing.expectEqualStrings("h0a", packet.wireField("second").?);
}
