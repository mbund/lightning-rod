const std = @import("std");
const nbt = @import("nbt");
const generated = @import("canonical_spec");
const protocol_catalog = @import("protocol_catalog");
const raw_packet = @import("raw_packet.zig");
const packet_model = @import("packet.zig");

pub const Version = protocol_catalog.Version;

/// Protocol-specific decoding lives here, once, rather than in either the
/// Fabric recorder or a server adapter. It consumes the same generated
/// PrismarineJS protocol views as the production server.
pub const Canonicalizer = struct {
    identities: []const raw_packet.Identity,
    version: Version = protocol_catalog.default,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    wire_storage: []u8 = &.{},
    wire_packet_name: [256]u8 = undefined,
    fields: [8]packet_model.Field = undefined,
    field_tokens: [8][256]u8 = undefined,
    subject_token: [48]u8 = undefined,
    position_token: [96]u8 = undefined,
    number_token: [32]u8 = undefined,
    inventory_token: [16384]u8 = undefined,
    entity_states: [256]EntityState = undefined,
    entity_state_count: usize = 0,
    item_streams: [8192]ItemStream = undefined,
    item_stream_count: usize = 0,
    open_windows: [128]OpenWindow = undefined,
    open_window_count: usize = 0,

    pub const Output = struct {
        recipient: []const u8,
        packet: packet_model.Packet,
    };

    pub fn init(identities: []const raw_packet.Identity) Canonicalizer {
        return .{ .identities = identities };
    }

    pub fn initWithAllocator(identities: []const raw_packet.Identity, allocator: std.mem.Allocator) Canonicalizer {
        return .{ .identities = identities, .allocator = allocator };
    }

    pub fn deinit(self: *Canonicalizer) void {
        if (self.wire_storage.len != 0) self.allocator.free(self.wire_storage);
        self.wire_storage = &.{};
    }

    pub fn initForMinecraft(identities: []const raw_packet.Identity, minecraft: []const u8) !Canonicalizer {
        return initForMinecraftWithAllocator(identities, minecraft, std.heap.page_allocator);
    }

    pub fn initForMinecraftWithAllocator(identities: []const raw_packet.Identity, minecraft: []const u8, allocator: std.mem.Allocator) !Canonicalizer {
        const version = if (minecraft.len == 0)
            protocol_catalog.default
        else
            protocol_catalog.fromMinecraftName(minecraft) orelse return error.UnsupportedMinecraftVersion;
        return .{ .identities = identities, .version = version, .allocator = allocator };
    }

    /// Semantic overrides are used where identities or registries need stable
    /// names. Every other valid protocol packet falls through to its generated
    /// `wire/<name>` structural form; malformed packets remain hard errors.
    pub fn canonicalize(self: *Canonicalizer, raw: raw_packet.Clientbound) !?Output {
        inline for (protocol_catalog.entries) |Entry| if (self.version == Entry.version)
            return self.canonicalizeWith(Entry.Protocol, Entry.Registry, raw);
        unreachable;
    }

    pub fn canonicalizeServerbound(self: *Canonicalizer, payload: []const u8) !?packet_model.Packet {
        inline for (protocol_catalog.entries) |Entry| if (self.version == Entry.version)
            return self.canonicalizeServerboundWith(Entry.Protocol, payload);
        unreachable;
    }

    fn canonicalizeWith(self: *Canonicalizer, comptime Protocol: type, comptime Registry: type, raw: raw_packet.Clientbound) !?Output {
        const decoded = try Protocol.play.toClient.read(raw.payload).name();
        const Tag = std.meta.Tag(@TypeOf(decoded));
        const active = std.meta.activeTag(decoded);
        // A client can render an item only after the item-typed entity spawn
        // and its tracked Slot metadata have both arrived. Retain that
        // relationship while preserving the generated spawn canonical form.
        if (active == @field(Tag, "spawn_entity")) {
            const body = @field(decoded, "spawn_entity");
            try self.observeItemSpawn(Registry, raw.recipient, body);
            return try self.entitySpawned(Registry, raw.recipient, body);
        }
        if (active == @field(Tag, "collect")) {
            return try self.itemCollected(raw.recipient, @field(decoded, "collect"));
        }
        if (active == @field(Tag, "entity_head_rotation")) {
            return try self.entityHeadRotation(raw.recipient, @field(decoded, "entity_head_rotation"));
        }
        inline for (generated.clientbound) |mapping| {
            if (active == @field(Tag, mapping.wire)) {
                const body = @field(decoded, mapping.wire);
                return switch (mapping.handler) {
                    .mapped => if (try self.mappedPacket(Registry, mapping, body)) |packet| .{ .recipient = raw.recipient, .packet = packet } else null,
                    .entity_equipment => try self.entityEquipmentWith(Registry, raw.recipient, body),
                    .entity_sound => try self.entitySoundWith(Registry, raw.recipient, body),
                    .item_metadata => if (try self.entityMetadataWith(Registry, raw.recipient, body)) |output| output else try self.generatedClientbound(Protocol, raw),
                    .entity_destroy => try self.entityDestroy(raw.recipient, body),
                    .player_remove => try self.playerRemove(raw.recipient, body),
                    .system_chat => try self.systemChat(raw.recipient, body),
                    .inventory => try self.windowItemsWith(Registry, raw.recipient, body),
                    .inventory_slot => try self.inventorySlotWith(Registry, raw.recipient, body),
                    .screen_slot => try self.screenSlotWith(Registry, raw.recipient, body),
                    .entity_movement => try self.entityMovement(mapping.wire, raw.recipient, body),
                    .multi_block_change => try self.multiBlockChange(Registry, raw.recipient, body),
                    .entity_attack, .container_click => unreachable,
                };
            }
        }
        return try self.generatedClientbound(Protocol, raw);
    }

    fn entitySpawned(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !Output {
        const entity_id, const c1 = try body.entityId();
        _, const c2 = try c1.objectUUID();
        const entity_type, const c3 = try c2.type();
        const x, const c4 = try c3.x();
        const y, const c5 = try c4.y();
        const z, const c6 = try c5.z();
        _, const c7 = try c6.pitch();
        _, const c8 = try c7.yaw();
        _, const c9 = try c8.headPitch();
        _, const c10 = try c9.objectData();
        const velocity_x, const c11 = try c10.velocityX();
        const velocity_y, const c12 = try c11.velocityY();
        const velocity_z, const done = try c12.velocityZ();
        try done.finish();
        if (entity_type < 0 or entity_type >= Registry.entity_names.len) return error.UnknownEntityType;

        self.fields[0] = .{ .name = "subject", .value = .{ .literal = try self.resolveSubject(entity_id) } };
        self.fields[1] = .{ .name = "type", .value = .{ .literal = Registry.entity_names[@intCast(entity_type)] } };
        self.fields[2] = .{ .name = "x", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[2], "{d}", .{x}) } };
        self.fields[3] = .{ .name = "y", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[3], "{d}", .{y}) } };
        self.fields[4] = .{ .name = "z", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[4], "{d}", .{z}) } };
        self.fields[5] = .{ .name = "velocity_x", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[5], "{d}", .{@as(f64, @floatFromInt(velocity_x)) / 8000.0}) } };
        self.fields[6] = .{ .name = "velocity_y", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[6], "{d}", .{@as(f64, @floatFromInt(velocity_y)) / 8000.0}) } };
        self.fields[7] = .{ .name = "velocity_z", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[7], "{d}", .{@as(f64, @floatFromInt(velocity_z)) / 8000.0}) } };
        return .{ .recipient = recipient, .packet = .{ .name = "entity_spawned", .fields = self.fields[0..8] } };
    }

    fn itemCollected(self: *Canonicalizer, recipient: []const u8, body: anytype) !Output {
        const item_entity_id, const c1 = try body.collectedEntityId();
        const collector_entity_id, const c2 = try c1.collectorEntityId();
        const count, const done = try c2.pickupItemCount();
        try done.finish();
        self.fields[0] = .{ .name = "subject", .value = .{ .literal = try self.resolveSubject(item_entity_id) } };
        self.fields[1] = .{ .name = "collector", .value = .{ .literal = try self.resolveSubject(collector_entity_id) } };
        self.fields[2] = .{ .name = "count", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[2], "{d}", .{count}) } };
        return .{ .recipient = recipient, .packet = .{ .name = "item_collected", .fields = self.fields[0..3] } };
    }

    fn canonicalizeServerboundWith(self: *Canonicalizer, comptime Protocol: type, payload: []const u8) !?packet_model.Packet {
        const decoded = try Protocol.play.toServer.read(payload).name();
        const Tag = std.meta.Tag(@TypeOf(decoded));
        const active = std.meta.activeTag(decoded);
        inline for (generated.serverbound) |mapping| {
            if (active == @field(Tag, mapping.wire)) {
                const body = @field(decoded, mapping.wire);
                return switch (mapping.handler) {
                    .mapped, .container_click => self.mappedPacket(void, mapping, body),
                    .entity_attack => self.entityAttack(body),
                    else => unreachable,
                };
            }
        }
        return try self.generatedServerbound(Protocol, payload);
    }

    fn entityAttack(self: *Canonicalizer, body: anytype) !?packet_model.Packet {
        const target, const c1 = try body.target();
        const action, const c2 = try c1.mouse();
        _, const c3 = try c2.x();
        _, const c4 = try c3.y();
        _, const c5 = try c4.z();
        _, const c6 = try c5.hand();
        _, const done = try c6.sneaking();
        try done.finish();
        if (action != 1) return null;
        self.fields[0] = .{ .name = "target", .value = .{ .literal = try self.resolveSubject(target) } };
        return .{ .name = "attack_entity", .fields = self.fields[0..1] };
    }

    fn generatedClientbound(self: *Canonicalizer, comptime Protocol: type, raw: raw_packet.Clientbound) !Output {
        const packet = try self.generatedPacket(Protocol.play.toClient, raw.payload);
        return .{ .recipient = raw.recipient, .packet = packet };
    }

    fn multiBlockChange(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !Output {
        const section, const after_section = try body.chunkCoordinates();
        const records, const done = try after_section.records();
        try done.finish();
        var iterator = try records.iter();
        var output = std.Io.Writer.Allocating.initOwnedSlice(self.allocator, self.wire_storage);
        self.wire_storage = &.{};
        errdefer output.deinit();
        var first = true;
        while (try iterator.next()) |encoded| {
            const value: u32 = @bitCast(encoded);
            const local = value & 0xfff;
            const state_id: i32 = @intCast(value >> 12);
            const state_name = Registry.blockStateName(state_id) orelse return error.UnknownBlockState;
            if (!first) try output.writer.writeByte(';');
            try output.writer.print("{d},{d},{d}=", .{
                section.x * 16 + @as(i32, @intCast((local >> 8) & 15)),
                section.y * 16 + @as(i32, @intCast(local & 15)),
                section.z * 16 + @as(i32, @intCast((local >> 4) & 15)),
            });
            try output.writer.writeAll(state_name);
            first = false;
        }
        const rendered_length = output.writer.end;
        var storage = output.toArrayList();
        self.wire_storage = storage.allocatedSlice();
        self.fields[0] = .{ .name = "changes", .value = .{ .literal = self.wire_storage[0..rendered_length] } };
        return .{ .recipient = recipient, .packet = .{ .name = "blocks_changed", .fields = self.fields[0..1] } };
    }

    fn generatedServerbound(self: *Canonicalizer, comptime Protocol: type, payload: []const u8) !packet_model.Packet {
        return self.generatedRawPacket(Protocol.play.toServer, payload);
    }

    fn generatedPacket(self: *Canonicalizer, comptime Direction: type, payload: []const u8) !packet_model.Packet {
        const minimum = std.math.add(usize, std.math.mul(usize, payload.len, 2) catch return error.CanonicalPacketTooLarge, 64 * 1024) catch return error.CanonicalPacketTooLarge;
        if (self.wire_storage.len < minimum) {
            if (self.wire_storage.len == 0) {
                self.wire_storage = try self.allocator.alloc(u8, minimum);
            } else {
                self.wire_storage = try self.allocator.realloc(self.wire_storage, minimum);
            }
        }
        var writer = std.Io.Writer.fixed(self.wire_storage);
        const generated_packet = try Direction.canonicalize(payload, &writer);
        const packet_name = try std.fmt.bufPrint(&self.wire_packet_name, "wire/{s}", .{generated_packet.name});
        self.fields[0] = .{ .name = "data", .value = .{ .literal = writer.buffered() } };
        return .{ .name = packet_name, .fields = self.fields[0..1] };
    }

    fn generatedRawPacket(self: *Canonicalizer, comptime Direction: type, payload: []const u8) !packet_model.Packet {
        const minimum = std.math.add(usize, std.math.mul(usize, payload.len, 2) catch return error.CanonicalPacketTooLarge, 1) catch return error.CanonicalPacketTooLarge;
        if (self.wire_storage.len < minimum) {
            if (self.wire_storage.len == 0) {
                self.wire_storage = try self.allocator.alloc(u8, minimum);
            } else {
                self.wire_storage = try self.allocator.realloc(self.wire_storage, minimum);
            }
        }
        const decoded = try Direction.read(payload).name();
        const wire_name = @tagName(std.meta.activeTag(decoded));
        const packet_name = try std.fmt.bufPrint(&self.wire_packet_name, "wire/{s}", .{wire_name});
        self.wire_storage[0] = 'h';
        const hex = "0123456789abcdef";
        for (payload, 0..) |byte, index| {
            self.wire_storage[1 + index * 2] = hex[byte >> 4];
            self.wire_storage[2 + index * 2] = hex[byte & 0x0f];
        }
        self.fields[0] = .{ .name = "data", .value = .{ .literal = self.wire_storage[0..minimum] } };
        return .{ .name = packet_name, .fields = self.fields[0..1] };
    }

    fn entityMovement(self: *Canonicalizer, comptime wire_name: []const u8, recipient: []const u8, body: anytype) !?Output {
        if (comptime std.mem.eql(u8, wire_name, "entity_teleport")) return try self.entityTeleport(recipient, body);
        if (comptime std.mem.eql(u8, wire_name, "sync_entity_position")) return try self.syncEntityPosition(recipient, body);
        if (comptime std.mem.eql(u8, wire_name, "entity_move_look")) return try self.entityMoveLook(recipient, body);
        if (comptime std.mem.eql(u8, wire_name, "rel_entity_move")) return try self.relativeEntityMove(recipient, body);
        unreachable;
    }

    fn mappedPacket(self: *Canonicalizer, comptime Registry: type, comptime mapping: generated.Mapping, body: anytype) !?packet_model.Packet {
        var output_count: usize = 0;
        if (!try self.decodeMappedFields(Registry, mapping.fields, 0, body, &output_count)) return null;
        return .{ .name = mapping.canonical, .fields = self.fields[0..output_count] };
    }

    fn decodeMappedFields(self: *Canonicalizer, comptime Registry: type, comptime mappings: []const generated.Field, comptime index: usize, cursor: anytype, output_count: *usize) !bool {
        if (index == mappings.len) {
            try cursor.finish();
            return true;
        }
        const mapping = mappings[index];
        const value, const next = try @field(@TypeOf(cursor), mapping.wire)(cursor);
        if (!try self.storeMappedValue(Registry, mapping, value, output_count)) return false;
        return self.decodeMappedFields(Registry, mappings, index + 1, next, output_count);
    }

    fn storeMappedValue(self: *Canonicalizer, comptime Registry: type, comptime mapping: generated.Field, value: anytype, output_count: *usize) !bool {
        const token: ?[]const u8 = switch (mapping.codec) {
            .float, .integer, .destroy_stage => try std.fmt.bufPrint(&self.field_tokens[output_count.*], "{d}", .{value}),
            .boolean => if (value) "1" else "0",
            .flags_on_ground => if (value.onGround) "1" else "0",
            .action => switch (value) {
                0 => "start_destroy_block",
                1 => "abort_destroy_block",
                2 => "stop_destroy_block",
                else => return false,
            },
            .block_position => try std.fmt.bufPrint(&self.field_tokens[output_count.*], "{},{},{}", .{ value.x, value.y, value.z }),
            .face => blockFace(value) orelse return error.UnsupportedBlockFace,
            .entity_ref => try self.resolveSubject(value),
            .entity_type => if (Registry == void or value < 0 or value >= Registry.entity_names.len) return error.UnknownEntityType else Registry.entity_names[@intCast(value)],
            .arm_hand => switch (value) {
                0 => "main_hand",
                3 => "off_hand",
                else => return error.UnsupportedArmAnimation,
            },
            .block_state => if (Registry == void) unreachable else Registry.blockStateName(value) orelse return error.UnknownBlockState,
            .require_player_screen => screen: {
                if (value != 0) return false;
                break :screen if (mapping.canonical.len == 0) null else "player";
            },
            .fixed_zero, .fixed_main_hand, .fixed_cursor, .fixed_false, .ignore, .opaque_value => null,
        };
        if (token) |text| {
            if (mapping.canonical.len == 0 or output_count.* == self.fields.len) return error.InvalidGeneratedCanonicalMapping;
            self.fields[output_count.*] = .{ .name = mapping.canonical, .value = .{ .literal = text } };
            output_count.* += 1;
        }
        return true;
    }

    fn entityEquipmentWith(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !?Output {
        const entity_id, const c1 = try body.entityId();
        const equipments, const done = try c1.equipments();
        try done.finish();

        var rest = equipments.payload();
        var main_hand: ?Stack = null;
        for (0..rest.len) |_| {
            if (rest.len == 0) return error.InvalidEquipmentList;
            const marker = rest[0];
            rest = rest[1..];
            const stack, rest = try decodeRawSlot(Registry, rest);
            if (marker & 0x7f == 0) main_hand = stack;
            if (marker & 0x80 == 0) break;
        } else {
            return error.InvalidEquipmentList;
        }
        if (rest.len != 0) return error.InvalidEquipmentList;
        const stack = main_hand orelse return null;
        const subject = try self.resolveSubject(entity_id);
        var stack_writer = std.Io.Writer.fixed(&self.inventory_token);
        try writeCanonicalStack(Registry, &stack_writer, stack);
        const stack_token = stack_writer.buffered();
        self.fields[0] = .{ .name = "subject", .value = .{ .literal = subject } };
        self.fields[1] = .{ .name = "slot", .value = .{ .literal = "main_hand" } };
        self.fields[2] = .{ .name = "stack", .value = .{ .literal = stack_token } };
        return .{ .recipient = recipient, .packet = .{ .name = "entity_equipment", .fields = self.fields[0..3] } };
    }

    fn entitySoundWith(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !Output {
        const sound_holder, const c1 = try body.sound();
        _, const c2 = try c1.soundCategory();
        const x, const c3 = try c2.x();
        const y, const c4 = try c3.y();
        const z, const c5 = try c4.z();
        const volume, const c6 = try c5.volume();
        const pitch, const c7 = try c6.pitch();
        _, const done = try c7.seed();
        try done.finish();
        const sound_name = switch (try sound_holder.value()) {
            .soundId => |holder_id| Registry.soundName(holder_id) orelse return error.UnknownSound,
            .data => return error.InlineSoundUnsupported,
        };
        self.fields[0] = .{ .name = "sound", .value = .{ .literal = sound_name } };
        self.fields[1] = .{ .name = "position", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[1], "{d},{d},{d}", .{
            @as(f64, @floatFromInt(x)) / 8,
            @as(f64, @floatFromInt(y)) / 8,
            @as(f64, @floatFromInt(z)) / 8,
        }) } };
        self.fields[2] = .{ .name = "volume", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[2], "{d}", .{volume}) } };
        self.fields[3] = .{ .name = "pitch", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[3], "{d}", .{pitch}) } };
        return .{ .recipient = recipient, .packet = .{ .name = "sound", .fields = self.fields[0..4] } };
    }

    fn entityMetadataWith(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !?Output {
        const entity_id, const c1 = try body.entityId();
        const metadata, const done = try c1.metadata();
        try metadata.finish();
        try done.finish();
        var rest = metadata.payload();
        if (rest.len >= 7 and rest[0] == 9) {
            const serializer, const after_serializer = try readVarInt(rest[1..]);
            if (serializer == 3 and after_serializer.len >= 4) {
                const bits = std.mem.readInt(u32, after_serializer[0..4], .big);
                self.fields[0] = .{ .name = "subject", .value = .{ .literal = try self.resolveSubject(entity_id) } };
                self.fields[1] = .{ .name = "health", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[1], "{d}", .{@as(f32, @bitCast(bits))}) } };
                return .{ .recipient = recipient, .packet = .{ .name = "entity_state", .fields = self.fields[0..2] } };
            }
        }
        if (rest.len >= 3 and rest[0] == 0) {
            const serializer, const after_serializer = try readVarInt(rest[1..]);
            if (serializer == 0 and after_serializer.len != 0) {
                self.fields[0] = .{ .name = "subject", .value = .{ .literal = try self.resolveSubject(entity_id) } };
                self.fields[1] = .{ .name = "on_fire", .value = .{ .literal = if (after_serializer[0] & 0x01 != 0) "1" else "0" } };
                self.fields[2] = .{ .name = "sneaking", .value = .{ .literal = if (after_serializer[0] & 0x02 != 0) "1" else "0" } };
                self.fields[3] = .{ .name = "sprinting", .value = .{ .literal = if (after_serializer[0] & 0x08 != 0) "1" else "0" } };
                if (after_serializer.len >= 8 and after_serializer[1] == 9) {
                    const health_serializer, const health_value = try readVarInt(after_serializer[2..]);
                    if (health_serializer == 3 and health_value.len >= 4) {
                        const bits = std.mem.readInt(u32, health_value[0..4], .big);
                        self.fields[4] = .{ .name = "health", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[4], "{d}", .{@as(f32, @bitCast(bits))}) } };
                        return .{ .recipient = recipient, .packet = .{ .name = "entity_state", .fields = self.fields[0..5] } };
                    }
                }
                return .{ .recipient = recipient, .packet = .{ .name = "entity_state", .fields = self.fields[0..4] } };
            }
        }
        // Player pose is tracked at metadata index 6 with the Pose serializer
        // (21). Expose the semantic value while arbitrary metadata continues
        // through the generated wire canonicalizer.
        if (rest.len >= 3 and rest[0] == 6) {
            const serializer, const after_serializer = try readVarInt(rest[1..]);
            if (serializer == 21) {
                const pose, const after_pose = try readVarInt(after_serializer);
                if (after_pose.len == 1 and after_pose[0] == 0xff) {
                    const pose_name: []const u8 = switch (pose) {
                        0 => "standing",
                        5 => "crouching",
                        else => return null,
                    };
                    self.fields[0] = .{ .name = "subject", .value = .{ .literal = try self.resolveSubject(entity_id) } };
                    self.fields[1] = .{ .name = "pose", .value = .{ .literal = pose_name } };
                    return .{ .recipient = recipient, .packet = .{ .name = "entity_pose", .fields = self.fields[0..2] } };
                }
            }
        }
        // ItemEntity's tracked stack is metadata index 8 using the Slot
        // serializer (7). Other entity metadata remains in its generated wire
        // form and is intentionally not mistaken for a loot observation.
        if (rest.len < 3 or rest[0] != 8) return null;
        const serializer, rest = try readVarInt(rest[1..]);
        if (serializer != 7) return null;
        const stack, rest = try decodeRawSlot(Registry, rest);
        if (rest.len != 1 or rest[0] != 0xff or stack.count == 0) return null;
        const stream = self.itemStream(recipient, entity_id) orelse return null;
        if (!stream.active) return null;
        const first_metadata = !stream.metadata_seen;

        const subject = try self.resolveSubject(entity_id);
        var stack_writer = std.Io.Writer.fixed(&self.inventory_token);
        try writeCanonicalStack(Registry, &stack_writer, stack);
        const canonical_stack = stack_writer.buffered();
        const metadata_hash = std.hash.Wyhash.hash(0, canonical_stack);
        if (!first_metadata and stream.metadata_hash == metadata_hash) return null;
        stream.metadata_seen = true;
        stream.metadata_hash = metadata_hash;
        self.fields[0] = .{ .name = "subject", .value = .{ .literal = subject } };
        self.fields[1] = .{ .name = "stack", .value = .{ .literal = canonical_stack } };
        return .{
            .recipient = recipient,
            .packet = .{
                .name = if (first_metadata) "item_spawned" else "item_stack_changed",
                .fields = self.fields[0..2],
            },
        };
    }

    fn entityDestroy(self: *Canonicalizer, recipient: []const u8, body: anytype) !Output {
        const entities, const done = try body.entityIds();
        try done.finish();
        var iterator = try entities.iter();
        var writer = std.Io.Writer.fixed(&self.inventory_token);
        var first = true;
        while (try iterator.next()) |entity_id| {
            if (!first) try writer.writeByte(',');
            try writer.writeAll(try self.resolveSubject(entity_id));
            if (self.itemStream(recipient, entity_id)) |stream| stream.active = false;
            first = false;
        }
        self.fields[0] = .{ .name = "subjects", .value = .{ .literal = writer.buffered() } };
        return .{ .recipient = recipient, .packet = .{ .name = "entity_destroy", .fields = self.fields[0..1] } };
    }

    fn observeItemSpawn(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !void {
        const entity_id, const after_id = try body.entityId();
        _, const after_uuid = try after_id.objectUUID();
        const entity_type, _ = try after_uuid.type();
        if (entity_type != Registry.canonical_entity_to_wire[@intCast(Registry.entity_item_type_id)]) return;
        if (self.itemStream(recipient, entity_id)) |stream| {
            stream.active = true;
            stream.metadata_seen = false;
            stream.metadata_hash = 0;
            return;
        }
        if (self.item_stream_count == self.item_streams.len) return error.TooManyItemStreams;
        self.item_streams[self.item_stream_count] = .{
            .recipient = recipient,
            .entity_id = entity_id,
            .active = true,
        };
        self.item_stream_count += 1;
    }

    fn itemStream(self: *Canonicalizer, recipient: []const u8, entity_id: i32) ?*ItemStream {
        for (self.item_streams[0..self.item_stream_count]) |*stream| {
            if (stream.entity_id == entity_id and std.mem.eql(u8, stream.recipient, recipient)) return stream;
        }
        return null;
    }

    fn playerRemove(self: *Canonicalizer, recipient: []const u8, body: anytype) !Output {
        const players, const done = try body.players();
        try done.finish();
        var iterator = try players.iter();
        var writer = std.Io.Writer.fixed(&self.inventory_token);
        var first = true;
        while (try iterator.next()) |uuid| {
            if (!first) try writer.writeByte(',');
            const identity = self.identityForUuid(uuid) orelse return error.UnknownPlayerUuid;
            try writer.writeAll(identity.alias);
            first = false;
        }
        self.fields[0] = .{ .name = "players", .value = .{ .literal = writer.buffered() } };
        return .{ .recipient = recipient, .packet = .{ .name = "player_remove", .fields = self.fields[0..1] } };
    }

    fn systemChat(self: *Canonicalizer, recipient: []const u8, body: anytype) !Output {
        const component, const cursor = try body.content();
        _, const done = try cursor.isActionBar();
        try done.finish();
        var nodes: [32]nbt.Node = undefined;
        var frames: [16]nbt.Frame = undefined;
        const document = try nbt.scan_anonymous(component, &nodes, &frames);
        var writer = std.Io.Writer.fixed(&self.inventory_token);
        const root = document.root_node();
        if (root.tag == .string) {
            try writeChatText(&writer, try root.string());
        } else if (root.tag != .compound) {
            try writer.print("component:{s}", .{@tagName(root.tag)});
        } else if (root.childNamed(document.nodes, "text")) |text_node| {
            try writeChatText(&writer, try text_node.string());
        } else if (root.childNamed(document.nodes, "translate")) |translate_node| {
            const key = try translate_node.string();
            if (std.mem.eql(u8, key, "multiplayer.player.left") or std.mem.eql(u8, key, "multiplayer.player.joined")) {
                const arguments = root.childNamed(document.nodes, "with") orelse return error.InvalidChatComponent;
                var iterator = arguments.childIterator(document.nodes);
                const player = iterator.next() orelse return error.InvalidChatComponent;
                try writeChatNode(&writer, player, document.nodes);
                try writer.writeAll(if (std.mem.eql(u8, key, "multiplayer.player.left")) "%20left%20the%20game" else "%20joined%20the%20game");
            } else if (std.mem.eql(u8, key, "death.attack.player")) {
                const arguments = root.childNamed(document.nodes, "with") orelse return error.InvalidChatComponent;
                var iterator = arguments.childIterator(document.nodes);
                const victim = iterator.next() orelse return error.InvalidChatComponent;
                const attacker = iterator.next() orelse return error.InvalidChatComponent;
                try writeChatNode(&writer, victim, document.nodes);
                try writer.writeAll("%20was%20slain%20by%20");
                try writeChatNode(&writer, attacker, document.nodes);
            } else {
                try writer.writeAll("translate:");
                try writeChatText(&writer, key);
            }
        } else {
            try writer.writeAll("component");
        }
        self.fields[0] = .{ .name = "message", .value = .{ .literal = writer.buffered() } };
        return .{ .recipient = recipient, .packet = .{ .name = "system_chat", .fields = self.fields[0..1] } };
    }

    fn writeChatNode(writer: *std.Io.Writer, node: nbt.Node, nodes: []const nbt.Node) !void {
        if (node.tag == .string) {
            try writeChatText(writer, try node.string());
        } else if (node.tag == .compound) {
            const text_node = node.childNamed(nodes, "text") orelse return error.InvalidChatComponent;
            try writeChatText(writer, try text_node.string());
        } else return error.InvalidChatComponent;
    }

    fn writeChatText(writer: *std.Io.Writer, message: []const u8) !void {
        for (message) |byte| switch (byte) {
            ' ' => try writer.writeAll("%20"),
            '%' => try writer.writeAll("%25"),
            else => try writer.writeByte(byte),
        };
    }

    fn identityForUuid(self: *const Canonicalizer, uuid: u128) ?raw_packet.Identity {
        for (self.identities) |identity| if (identity.uuid == uuid) return identity;
        return null;
    }

    fn entityTeleport(self: *Canonicalizer, recipient: []const u8, body: anytype) !Output {
        const entity_id, const c1 = try body.entityId();
        const x, const c2 = try c1.x();
        const y, const c3 = try c2.y();
        const z, const c4 = try c3.z();
        _, const c5 = try c4.yaw();
        _, const c6 = try c5.pitch();
        _, const done = try c6.onGround();
        try done.finish();
        try self.updatePosition(recipient, entity_id, .{ x, y, z });
        return self.entityMoved(recipient, entity_id, .{ x, y, z });
    }

    fn syncEntityPosition(self: *Canonicalizer, recipient: []const u8, body: anytype) !Output {
        const entity_id, const c1 = try body.entityId();
        const x, const c2 = try c1.x();
        const y, const c3 = try c2.y();
        const z, const c4 = try c3.z();
        _, const c5 = try c4.dx();
        _, const c6 = try c5.dy();
        _, const c7 = try c6.dz();
        _, const c8 = try c7.yaw();
        _, const c9 = try c8.pitch();
        _, const done = try c9.onGround();
        try done.finish();
        try self.updatePosition(recipient, entity_id, .{ x, y, z });
        return self.entityMoved(recipient, entity_id, .{ x, y, z });
    }

    fn entityMoveLook(self: *Canonicalizer, recipient: []const u8, body: anytype) !?Output {
        const entity_id, const c1 = try body.entityId();
        const dx, const c2 = try c1.dX();
        const dy, const c3 = try c2.dY();
        const dz, const c4 = try c3.dZ();
        _, const c5 = try c4.yaw();
        _, const c6 = try c5.pitch();
        _, const done = try c6.onGround();
        try done.finish();
        return self.applyRelativeMove(recipient, entity_id, dx, dy, dz);
    }

    fn relativeEntityMove(self: *Canonicalizer, recipient: []const u8, body: anytype) !?Output {
        const entity_id, const c1 = try body.entityId();
        const dx, const c2 = try c1.dX();
        const dy, const c3 = try c2.dY();
        const dz, const c4 = try c3.dZ();
        _, const done = try c4.onGround();
        try done.finish();
        return self.applyRelativeMove(recipient, entity_id, dx, dy, dz);
    }

    fn applyRelativeMove(self: *Canonicalizer, recipient: []const u8, entity_id: i32, dx: i16, dy: i16, dz: i16) !?Output {
        const state = (try self.getEntityState(recipient, entity_id)) orelse return null;
        if (!state.known) return null;
        state.position[0] += @as(f64, @floatFromInt(dx)) / 4096.0;
        state.position[1] += @as(f64, @floatFromInt(dy)) / 4096.0;
        state.position[2] += @as(f64, @floatFromInt(dz)) / 4096.0;
        const position = state.position;
        return try self.entityMoved(recipient, entity_id, position);
    }

    fn entityMoved(self: *Canonicalizer, recipient: []const u8, entity_id: i32, position: [3]f64) !Output {
        const subject = try self.resolveSubject(entity_id);
        const position_token = try std.fmt.bufPrint(&self.position_token, "{d},{d},{d}", .{ position[0], position[1], position[2] });
        self.fields[0] = .{ .name = "subject", .value = .{ .literal = subject } };
        self.fields[1] = .{ .name = "position", .value = .{ .literal = position_token } };
        return .{ .recipient = recipient, .packet = .{ .name = "entity_moved", .fields = self.fields[0..2] } };
    }

    fn entityHeadRotation(self: *Canonicalizer, recipient: []const u8, body: anytype) !Output {
        const entity_id, const after_entity = try body.entityId();
        const yaw, const done = try after_entity.headYaw();
        try done.finish();
        self.fields[0] = .{ .name = "subject", .value = .{ .literal = try self.resolveSubject(entity_id) } };
        self.fields[1] = .{ .name = "yaw", .value = .{ .literal = try std.fmt.bufPrint(&self.field_tokens[1], "{d}", .{yaw}) } };
        return .{ .recipient = recipient, .packet = .{ .name = "entity_head_rotation", .fields = self.fields[0..2] } };
    }

    fn updatePosition(self: *Canonicalizer, recipient: []const u8, entity_id: i32, position: [3]f64) !void {
        const state = (try self.getEntityState(recipient, entity_id)) orelse return;
        state.position = position;
        state.known = true;
    }

    fn getEntityState(self: *Canonicalizer, recipient: []const u8, entity_id: i32) !?*EntityState {
        for (self.entity_states[0..self.entity_state_count]) |*state| {
            if (state.entity_id == entity_id and std.mem.eql(u8, state.recipient, recipient)) return state;
        }
        const identity = for (self.identities) |identity| {
            if (identity.entity_id == entity_id) break identity;
        } else return null;
        if (self.entity_state_count == self.entity_states.len) return error.TooManyEntityStreams;
        const index = self.entity_state_count;
        self.entity_state_count += 1;
        self.entity_states[index] = .{
            .recipient = recipient,
            .entity_id = entity_id,
            .position = identity.position,
            .known = identity.position_known,
        };
        return &self.entity_states[index];
    }

    fn windowItemsWith(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !?Output {
        const window_id, const c1 = try body.windowId();
        _, const c2 = try c1.stateId();
        const items, const c3 = try c2.items();
        const carried_view, const done = try c3.carriedItem();
        try done.finish();
        const item_count = try items.len();
        if (item_count > 90) return error.InvalidInventorySize;
        if (window_id == 0 and item_count != 46) return error.InvalidPlayerInventorySize;
        if (window_id != 0 and item_count < 36) return error.InvalidContainerInventorySize;

        var slots: [90]Stack = undefined;
        var iterator = try items.iter();
        var index: usize = 0;
        while (try iterator.next()) |slot| : (index += 1) slots[index] = try decodeSlot(Registry, slot);
        if (index != item_count) return error.InvalidInventorySize;
        const carried = try decodeSlot(Registry, carried_view);

        var writer = std.Io.Writer.fixed(&self.inventory_token);
        const screen: []const u8 = if (window_id == 0) player: {
            for (slots[36..45], 0..) |stack, slot| try writeStack(Registry, &writer, "h", slot, stack, true);
            for (slots[9..36], 0..) |stack, slot| try writeStack(Registry, &writer, "m", slot, stack, true);
            for (slots[5..9], 0..) |stack, slot| try writeStack(Registry, &writer, "a", slot, stack, true);
            try writeNamedStack(Registry, &writer, "o", slots[45], true);
            try writeNamedStack(Registry, &writer, "c", carried, true);
            for (slots[1..5], 0..) |stack, slot| try writeStack(Registry, &writer, "g", slot, stack, slot + 1 != 4);
            break :player "player";
        } else container: {
            const top_count = item_count - 36;
            try self.rememberWindow(recipient, window_id, top_count);
            for (slots[0..top_count], 0..) |stack, slot| try writeStack(Registry, &writer, "s", slot, stack, true);
            for (slots[top_count..][0..27], 0..) |stack, slot| try writeStack(Registry, &writer, "m", slot, stack, true);
            for (slots[top_count + 27 ..][0..9], 0..) |stack, slot| try writeStack(Registry, &writer, "h", slot, stack, true);
            try writeNamedStack(Registry, &writer, "c", carried, false);
            break :container switch (top_count) {
                3 => "furnace",
                27 => "chest",
                54 => "large_chest",
                else => try std.fmt.bufPrint(&self.field_tokens[1], "container_{d}", .{top_count}),
            };
        };

        self.fields[0] = .{ .name = "subject", .value = .{ .literal = recipient } };
        self.fields[1] = .{ .name = "screen", .value = .{ .literal = screen } };
        self.fields[2] = .{ .name = "slots", .value = .{ .literal = writer.buffered() } };
        return .{ .recipient = recipient, .packet = .{ .name = "inventory", .fields = self.fields[0..3] } };
    }

    fn inventorySlotWith(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !Output {
        const slot_id, const after_slot = try body.slotId();
        const contents, const done = try after_slot.contents();
        try done.finish();
        const slot_name = try canonicalPlayerInventorySlot(&self.field_tokens[1], slot_id);
        const stack = try decodeSlot(Registry, contents);
        var stack_writer = std.Io.Writer.fixed(&self.inventory_token);
        try writeCanonicalStack(Registry, &stack_writer, stack);
        self.fields[0] = .{ .name = "subject", .value = .{ .literal = recipient } };
        self.fields[1] = .{ .name = "slot", .value = .{ .literal = slot_name } };
        self.fields[2] = .{ .name = "stack", .value = .{ .literal = stack_writer.buffered() } };
        return .{ .recipient = recipient, .packet = .{ .name = "inventory_slot", .fields = self.fields[0..3] } };
    }

    fn screenSlotWith(self: *Canonicalizer, comptime Registry: type, recipient: []const u8, body: anytype) !?Output {
        const window_id, const c1 = try body.windowId();
        _, const c2 = try c1.stateId();
        const slot_id, const c3 = try c2.slot();
        const contents, const done = try c3.item();
        try done.finish();
        const slot_name = if (window_id == -1 and slot_id == -1)
            "c"
        else if (window_id == 0)
            try canonicalPlayerScreenSlot(&self.field_tokens[1], slot_id) orelse return null
        else
            try self.canonicalContainerSlot(recipient, window_id, slot_id);
        const stack = try decodeSlot(Registry, contents);
        var stack_writer = std.Io.Writer.fixed(&self.inventory_token);
        try writeCanonicalStack(Registry, &stack_writer, stack);
        self.fields[0] = .{ .name = "subject", .value = .{ .literal = recipient } };
        self.fields[1] = .{ .name = "slot", .value = .{ .literal = slot_name } };
        self.fields[2] = .{ .name = "stack", .value = .{ .literal = stack_writer.buffered() } };
        return .{ .recipient = recipient, .packet = .{ .name = "inventory_slot", .fields = self.fields[0..3] } };
    }

    fn rememberWindow(self: *Canonicalizer, recipient: []const u8, window_id: i32, top_count: usize) !void {
        for (self.open_windows[0..self.open_window_count]) |*window| {
            if (window.id == window_id and std.mem.eql(u8, window.recipient, recipient)) {
                window.top_count = @intCast(top_count);
                return;
            }
        }
        if (self.open_window_count == self.open_windows.len) return error.TooManyOpenWindows;
        self.open_windows[self.open_window_count] = .{
            .recipient = recipient,
            .id = window_id,
            .top_count = @intCast(top_count),
        };
        self.open_window_count += 1;
    }

    fn canonicalContainerSlot(self: *Canonicalizer, recipient: []const u8, window_id: i32, slot_id: i16) ![]const u8 {
        const window = for (self.open_windows[0..self.open_window_count]) |window| {
            if (window.id == window_id and std.mem.eql(u8, window.recipient, recipient)) break window;
        } else return error.UnknownContainerWindow;
        if (slot_id == -1) return "c";
        if (slot_id < 0) return error.UnsupportedContainerSlot;
        const slot: usize = @intCast(slot_id);
        if (slot < window.top_count) return std.fmt.bufPrint(&self.field_tokens[1], "s{d}", .{slot});
        const player_slot = slot - window.top_count;
        if (player_slot < 27) return std.fmt.bufPrint(&self.field_tokens[1], "m{d}", .{player_slot});
        if (player_slot < 36) return std.fmt.bufPrint(&self.field_tokens[1], "h{d}", .{player_slot - 27});
        return error.UnsupportedContainerSlot;
    }

    fn resolveSubject(self: *Canonicalizer, entity_id: i32) ![]const u8 {
        for (self.identities) |identity| {
            if (identity.entity_id == entity_id) return identity.alias;
        }
        return std.fmt.bufPrint(&self.subject_token, "entity_{}", .{entity_id});
    }
};

const OpenWindow = struct {
    recipient: []const u8,
    id: i32,
    top_count: u8,
};

fn canonicalPlayerInventorySlot(buffer: []u8, slot_id: i32) ![]const u8 {
    if (slot_id >= 0 and slot_id < 9) return std.fmt.bufPrint(buffer, "h{d}", .{slot_id});
    if (slot_id >= 9 and slot_id < 36) return std.fmt.bufPrint(buffer, "m{d}", .{slot_id - 9});
    return switch (slot_id) {
        36 => "a3",
        37 => "a2",
        38 => "a1",
        39 => "a0",
        40 => "o",
        else => error.UnsupportedPlayerInventorySlot,
    };
}

fn canonicalPlayerScreenSlot(buffer: []u8, slot_id: i16) !?[]const u8 {
    if (slot_id >= 1 and slot_id <= 4) {
        const name: []const u8 = try std.fmt.bufPrint(buffer, "g{d}", .{slot_id - 1});
        return name;
    }
    if (slot_id >= 5 and slot_id <= 8) {
        const name: []const u8 = try std.fmt.bufPrint(buffer, "a{d}", .{8 - slot_id});
        return name;
    }
    if (slot_id >= 9 and slot_id <= 35) {
        const name: []const u8 = try std.fmt.bufPrint(buffer, "m{d}", .{slot_id - 9});
        return name;
    }
    if (slot_id >= 36 and slot_id <= 44) {
        const name: []const u8 = try std.fmt.bufPrint(buffer, "h{d}", .{slot_id - 36});
        return name;
    }
    return switch (slot_id) {
        0 => "r",
        45 => "o",
        -1 => "c",
        else => null,
    };
}

const EntityState = struct {
    recipient: []const u8,
    entity_id: i32,
    position: [3]f64,
    known: bool,
};

const ItemStream = struct {
    recipient: []const u8,
    entity_id: i32,
    active: bool = false,
    metadata_seen: bool = false,
    metadata_hash: u64 = 0,
};

const Stack = struct {
    item_id: i32 = 0,
    count: i32 = 0,
    added: [max_stack_components]StackComponent = undefined,
    added_count: usize = 0,
    removed: [max_stack_components]i32 = undefined,
    removed_count: usize = 0,
};

const max_stack_components = 32;
const max_enchantments = 32;

const StackComponent = struct {
    type_id: i32,
    value: Value,

    const Value = union(enum) {
        custom_data: []const u8,
        damage: i32,
        custom_name: []const u8,
        enchantments: EnchantmentList,
        stored_enchantments: EnchantmentList,
    };
};

const Enchantment = struct { id: i32, level: i32 };
const EnchantmentList = struct {
    entries: [max_enchantments]Enchantment = undefined,
    count: usize = 0,
};

fn decodeSlot(comptime Registry: type, slot: anytype) !Stack {
    const count, const after_count = try slot.itemCount();
    const payload, const done = try after_count.anon();
    try done.finish();
    if (count == 0) return .{};
    const present = try payload.case_default();
    const item_id, const after_id = try present.itemId();
    const added_count, const after_added = try after_id.addedComponentCount();
    const removed_count, const after_removed = try after_added.removedComponentCount();
    if (added_count < 0 or removed_count < 0) return error.InvalidCanonicalItemComponents;
    if (added_count > max_stack_components or removed_count > max_stack_components) return error.TooManyCanonicalItemComponents;
    const components, const after_components = try after_removed.components();
    var stack = Stack{ .item_id = item_id, .count = count };
    var iterator = try components.iter();
    while (try iterator.next()) |component| {
        const component_type, const after_type = try component.type();
        const data, const component_done = try after_type.data();
        try component_done.finish();
        try appendDecodedComponent(Registry, &stack, component_type, data);
    }
    const removals, const components_done = try after_components.removeComponents();
    try components_done.finish();
    var removal_iterator = try removals.iter();
    while (try removal_iterator.next()) |removal| {
        const component_type, const removal_done = try removal.type();
        try removal_done.finish();
        try appendRemovedComponent(&stack, component_type);
    }
    return stack;
}

fn appendDecodedComponent(comptime Registry: type, stack: *Stack, component_type: i32, data: anytype) !void {
    if (stack.added_count == stack.added.len) return error.TooManyCanonicalItemComponents;
    const custom_data = comptime Registry.dataComponentId("minecraft:custom_data").?;
    const damage = comptime Registry.dataComponentId("minecraft:damage").?;
    const custom_name = comptime Registry.dataComponentId("minecraft:custom_name").?;
    const enchantments = comptime Registry.dataComponentId("minecraft:enchantments").?;
    const stored_enchantments = comptime Registry.dataComponentId("minecraft:stored_enchantments").?;
    const value: StackComponent.Value = switch (component_type) {
        custom_data => .{ .custom_data = try data.case_custom_data() },
        damage => .{ .damage = try data.case_damage() },
        custom_name => .{ .custom_name = try data.case_custom_name() },
        enchantments => .{ .enchantments = try decodeEnchantments(try data.case_enchantments()) },
        stored_enchantments => .{ .stored_enchantments = try decodeEnchantments(try data.case_stored_enchantments()) },
        else => return error.UnsupportedCanonicalItemComponent,
    };
    stack.added[stack.added_count] = .{ .type_id = component_type, .value = value };
    stack.added_count += 1;
}

fn decodeEnchantments(view: anytype) !EnchantmentList {
    const enchantments, const done = try view.enchantments();
    try done.finish();
    var result = EnchantmentList{};
    var iterator = try enchantments.iter();
    while (try iterator.next()) |entry| {
        if (result.count == result.entries.len) return error.TooManyCanonicalEnchantments;
        const id, const after_id = try entry.id();
        const level, const entry_done = try after_id.level();
        try entry_done.finish();
        result.entries[result.count] = .{ .id = id, .level = level };
        result.count += 1;
    }
    return result;
}

fn appendRemovedComponent(stack: *Stack, component_type: i32) !void {
    if (stack.removed_count == stack.removed.len) return error.TooManyCanonicalItemComponents;
    stack.removed[stack.removed_count] = component_type;
    stack.removed_count += 1;
}

fn decodeRawSlot(comptime Registry: type, bytes: []const u8) !struct { Stack, []const u8 } {
    const count, var rest = try readVarInt(bytes);
    if (count == 0) return .{ .{}, rest };
    if (count < 0 or count > std.math.maxInt(u8)) return error.InvalidEquipmentStack;
    const item_id, rest = try readVarInt(rest);
    const added_count, rest = try readVarInt(rest);
    const removed_count, rest = try readVarInt(rest);
    if (added_count < 0 or removed_count < 0) return error.InvalidEquipmentStack;

    var stack = Stack{ .item_id = item_id, .count = count };
    const custom_data = comptime Registry.dataComponentId("minecraft:custom_data").?;
    const damage_type = comptime Registry.dataComponentId("minecraft:damage").?;
    const custom_name = comptime Registry.dataComponentId("minecraft:custom_name").?;
    const enchantments = comptime Registry.dataComponentId("minecraft:enchantments").?;
    const stored_enchantments = comptime Registry.dataComponentId("minecraft:stored_enchantments").?;
    for (0..@intCast(added_count)) |_| {
        const component_type, rest = try readVarInt(rest);
        if (stack.added_count == stack.added.len) return error.TooManyCanonicalItemComponents;
        const value: StackComponent.Value = switch (component_type) {
            custom_data => .{ .custom_data = try readRawAnonymousNbt(&rest) },
            damage_type => damage: {
                const damage, rest = try readVarInt(rest);
                break :damage .{ .damage = damage };
            },
            custom_name => .{ .custom_name = try readRawAnonymousNbt(&rest) },
            enchantments => .{ .enchantments = try readRawEnchantments(&rest) },
            stored_enchantments => .{ .stored_enchantments = try readRawEnchantments(&rest) },
            else => return error.UnsupportedCanonicalItemComponent,
        };
        stack.added[stack.added_count] = .{ .type_id = component_type, .value = value };
        stack.added_count += 1;
    }
    for (0..@intCast(removed_count)) |_| {
        const component_type, rest = try readVarInt(rest);
        try appendRemovedComponent(&stack, component_type);
    }
    return .{ stack, rest };
}

fn readRawAnonymousNbt(rest: *[]const u8) ![]const u8 {
    var frames: [128]nbt.Frame = undefined;
    const after = try nbt.skip_anonymous(rest.*, &frames);
    const value = rest.*[0 .. rest.*.len - after.len];
    rest.* = after;
    return value;
}

fn readRawEnchantments(rest: *[]const u8) !EnchantmentList {
    const count, rest.* = try readVarInt(rest.*);
    if (count < 0 or count > max_enchantments) return error.TooManyCanonicalEnchantments;
    var result = EnchantmentList{};
    for (0..@intCast(count)) |_| {
        const id, rest.* = try readVarInt(rest.*);
        const level, rest.* = try readVarInt(rest.*);
        result.entries[result.count] = .{ .id = id, .level = level };
        result.count += 1;
    }
    return result;
}

fn readVarInt(bytes: []const u8) !struct { i32, []const u8 } {
    var value: i32 = 0;
    var rest = bytes;
    for (0..5) |index| {
        if (rest.len == 0) return error.EndOfStream;
        const byte = rest[0];
        rest = rest[1..];
        value |= @as(i32, byte & 0x7f) << @as(u5, @intCast(index * 7));
        if (byte & 0x80 == 0) return .{ value, rest };
    }
    return error.VarIntTooLong;
}

fn writeStack(comptime Registry: type, writer: *std.Io.Writer, prefix: []const u8, slot: usize, stack: Stack, comma: bool) !void {
    try writer.print("{s}{}=", .{ prefix, slot });
    try writeCanonicalStack(Registry, writer, stack);
    if (comma) try writer.writeByte(',');
}

fn writeNamedStack(comptime Registry: type, writer: *std.Io.Writer, name: []const u8, stack: Stack, comma: bool) !void {
    try writer.print("{s}=", .{name});
    try writeCanonicalStack(Registry, writer, stack);
    if (comma) try writer.writeByte(',');
}

fn writeCanonicalStack(comptime Registry: type, writer: *std.Io.Writer, stack: Stack) !void {
    if (stack.count == 0) return writer.writeAll("empty");
    const item = Registry.itemName(stack.item_id) orelse return error.UnknownItem;
    try writer.print("{s}*{}", .{ item, stack.count });
    if (stack.added_count == 0 and stack.removed_count == 0) return;

    const PatchEntry = struct { name: []const u8, component: ?StackComponent };
    var entries: [max_stack_components * 2]PatchEntry = undefined;
    var count: usize = 0;
    for (stack.added[0..stack.added_count]) |component| {
        entries[count] = .{
            .name = Registry.dataComponentName(component.type_id) orelse return error.UnknownDataComponent,
            .component = component,
        };
        count += 1;
    }
    for (stack.removed[0..stack.removed_count]) |component_type| {
        entries[count] = .{
            .name = Registry.dataComponentName(component_type) orelse return error.UnknownDataComponent,
            .component = null,
        };
        count += 1;
    }
    std.mem.sort(PatchEntry, entries[0..count], {}, struct {
        fn lessThan(_: void, left: PatchEntry, right: PatchEntry) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.lessThan);

    try writer.writeByte('{');
    for (entries[0..count], 0..) |entry, index| {
        if (index != 0) try writer.writeByte(';');
        if (entry.component) |component| {
            try writer.print("{s}=", .{entry.name});
            try writeComponentValue(Registry, writer, component.value);
        } else {
            try writer.print("-{s}", .{entry.name});
        }
    }
    try writer.writeByte('}');
}

fn writeComponentValue(comptime Registry: type, writer: *std.Io.Writer, value: StackComponent.Value) !void {
    switch (value) {
        .damage => |damage| try writer.print("{}", .{damage}),
        .custom_name, .custom_data => |raw| {
            try writer.writeAll("snbt:");
            try writePercentEncodedSnbt(writer, raw);
        },
        .enchantments, .stored_enchantments => |enchantments| try writeEnchantments(Registry, writer, enchantments),
    }
}

fn writeEnchantments(comptime Registry: type, writer: *std.Io.Writer, enchantments: EnchantmentList) !void {
    var entries = enchantments.entries;
    std.mem.sort(Enchantment, entries[0..enchantments.count], {}, struct {
        fn lessThan(_: void, left: Enchantment, right: Enchantment) bool {
            const left_name = Registry.enchantmentName(left.id) orelse return left.id < right.id;
            const right_name = Registry.enchantmentName(right.id) orelse return left.id < right.id;
            return std.mem.order(u8, left_name, right_name) == .lt;
        }
    }.lessThan);
    for (entries[0..enchantments.count], 0..) |enchantment, index| {
        if (index != 0) try writer.writeByte('+');
        const name = Registry.enchantmentName(enchantment.id) orelse return error.UnknownEnchantment;
        try writer.print("{s}@{}", .{ name, enchantment.level });
    }
}

fn writePercentEncodedSnbt(writer: *std.Io.Writer, raw: []const u8) !void {
    var nodes: [256]nbt.Node = undefined;
    var frames: [128]nbt.Frame = undefined;
    const document = try nbt.scan_anonymous(raw, &nodes, &frames);
    if (document.rest.len != 0) return error.InvalidCanonicalNbt;
    var storage: [8192]u8 = undefined;
    var snbt = std.Io.Writer.fixed(&storage);
    try writeSnbtNode(&snbt, document.root_node(), document.nodes);
    const hex = "0123456789ABCDEF";
    for (snbt.buffered()) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

fn writeSnbtNode(writer: *std.Io.Writer, node: nbt.Node, nodes: []const nbt.Node) !void {
    switch (node.tag) {
        .end => return error.InvalidCanonicalNbt,
        .byte => try writer.print("{}b", .{node.value.byte}),
        .short => try writer.print("{}s", .{node.value.short}),
        .int => try writer.print("{}", .{node.value.int}),
        .long => try writer.print("{}L", .{node.value.long}),
        .float => try writer.print("{d}f", .{node.value.float}),
        .double => try writer.print("{d}d", .{node.value.double}),
        .string => try writeSnbtString(writer, node.value.string),
        .byte_array => {
            try writer.writeAll("[B;");
            for (node.value.bytes, 0..) |value, index| {
                if (index != 0) try writer.writeByte(',');
                try writer.print("{}b", .{@as(i8, @bitCast(value))});
            }
            try writer.writeByte(']');
        },
        .int_array => {
            try writer.writeAll("[I;");
            var iterator = (try node.intArray()).iterator();
            var index: usize = 0;
            while (iterator.next()) |value| : (index += 1) {
                if (index != 0) try writer.writeByte(',');
                try writer.print("{}", .{value});
            }
            try writer.writeByte(']');
        },
        .long_array => {
            try writer.writeAll("[L;");
            var iterator = (try node.longArray()).iterator();
            var index: usize = 0;
            while (iterator.next()) |value| : (index += 1) {
                if (index != 0) try writer.writeByte(',');
                try writer.print("{}L", .{value});
            }
            try writer.writeByte(']');
        },
        .list => {
            try writer.writeByte('[');
            var child = node.first_child;
            for (0..node.child_count) |index| {
                if (index != 0) try writer.writeByte(',');
                try writeSnbtNode(writer, nodes[child], nodes);
                child = nodes[child].next_sibling;
            }
            try writer.writeByte(']');
        },
        .compound => {
            var children: [256]u32 = undefined;
            var child = node.first_child;
            for (0..node.child_count) |index| {
                children[index] = child;
                child = nodes[child].next_sibling;
            }
            std.mem.sort(u32, children[0..node.child_count], nodes, struct {
                fn lessThan(all_nodes: []const nbt.Node, left: u32, right: u32) bool {
                    return std.mem.order(u8, all_nodes[left].name, all_nodes[right].name) == .lt;
                }
            }.lessThan);
            try writer.writeByte('{');
            for (children[0..node.child_count], 0..) |child_index, index| {
                if (index != 0) try writer.writeByte(',');
                try writeSnbtString(writer, nodes[child_index].name);
                try writer.writeByte(':');
                try writeSnbtNode(writer, nodes[child_index], nodes);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeSnbtString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"', '\\' => try writer.writeAll(&.{ '\\', byte }),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20)
            try writer.print("\\u00{X:0>2}", .{byte})
        else
            try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn blockFace(value: anytype) ?[]const u8 {
    const names = [_][]const u8{ "down", "up", "north", "south", "west", "east" };
    if (value < 0 or value >= names.len) return null;
    return names[@intCast(value)];
}
