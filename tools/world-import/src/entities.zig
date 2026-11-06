const std = @import("std");
const nbt = @import("nbt");
const vanilla = @import("vanilla");
const entities = @import("entities");
const game_data = @import("game_data");
const fields = @import("nbt.zig");
const items = @import("items.zig");
const world_import = @import("import.zig");

pub fn column(owner: *world_import.Import, scratch: std.mem.Allocator, doc: nbt.Document, world: u32) !void {
    const list = doc.childNamed("Entities") orelse return error.MissingEntities;
    _ = try list.expectTag(.list);
    var iterator = list.childIterator(doc.nodes);
    while (iterator.next()) |entity| {
        const name = try (try fields.field(doc, entity, "id")).string();
        const item = std.mem.eql(u8, name, "minecraft:item");
        const orb = std.mem.eql(u8, name, "minecraft:experience_orb");
        if (!item and !orb) {
            try owner.unsupported("entity", name);
            continue;
        }
        var body: entities.State = .{
            .uuid = try fields.uuid(try fields.field(doc, entity, "UUID")),
            .kind = @as(u32, @intCast(game_data.registry.entityId(name) orelse return error.UnknownEntity)),
            .world = world,
            .position = try fields.vector(doc, try fields.field(doc, entity, "Pos")),
            .velocity = try fields.vector(doc, try fields.field(doc, entity, "Motion")),
        };
        for (body.position) |coordinate| if (@abs(coordinate) > 30_000_000) return error.InvalidPosition;
        if (entity.childNamed(doc.nodes, "Rotation")) |rotation| {
            if ((try rotation.listInfo()).len != 2) return error.InvalidRotation;
            var values = rotation.childIterator(doc.nodes);
            const yaw = try fields.number(values.next().?);
            const pitch = try fields.number(values.next().?);
            body.yaw = @floatCast(@mod(yaw + 180, 360) - 180);
            body.pitch = @floatCast(std.math.clamp(pitch, -90, 90));
        }
        if (try fields.optionalInt(doc, entity, "Fire", 0) > 0) body.flags |= 1;
        if (try fields.optionalInt(doc, entity, "Glowing", 0) != 0) body.flags |= 64;
        const entry = try owner.entity_ids.getOrPut(body.uuid);
        if (entry.found_existing) return error.DuplicateEntityUuid;
        if (entity.childNamed(doc.nodes, "Passengers")) |passengers| if (passengers.child_count != 0) try owner.unsupported("entity field", "Passengers");
        const ground = try fields.optionalInt(doc, entity, "OnGround", 0) != 0;
        const age = try fields.optionalInt(doc, entity, "Age", 0);
        const health = try fields.optionalInt(doc, entity, "Health", 5);
        if (item) {
            const stack = try items.stack(owner, scratch, doc, try fields.field(doc, entity, "Item")) orelse continue;
            const delay = try fields.optionalInt(doc, entity, "PickupDelay", 0);
            if (delay < 0 or delay > 32767 or health <= 0 or health > std.math.maxInt(i16) or age > std.math.maxInt(i32) or age < std.math.minInt(i32)) return error.InvalidItemEntity;
            const id = try owner.entities.create(body);
            if (!try owner.inventories.editMany(&.{.{ .slot = vanilla.ItemEntities.slot(body), .revision = 0, .stack = stack }})) return error.DuplicateEntity;
            var metadata: vanilla.ItemEntities.Metadata = .{ .age = @intCast(age), .health = @intCast(health), .pickup_delay = @intCast(delay), .on_ground = ground };
            if (entity.childNamed(doc.nodes, "Owner")) |uuid| metadata.owner = owner.mappedUuid(try fields.uuid(uuid));
            var key: [9]u8 = undefined;
            key[0] = 0;
            std.mem.writeInt(u64, key[1..9], id, .big);
            var bytes: [vanilla.ItemEntities.Metadata.encoded_size]u8 = undefined;
            metadata.encode(&bytes);
            try owner.dropped.put(&key, &bytes);
            owner.counts.items += 1;
        } else {
            const value = try fields.integer(try fields.field(doc, entity, "Value"));
            const count = try fields.optionalInt(doc, entity, "Count", 1);
            const fire = try fields.optionalInt(doc, entity, "Fire", 0);
            if (value <= 0 or value > std.math.maxInt(i32) or count <= 0 or count > std.math.maxInt(i32) or age < 0 or age >= 6000 or health <= 0 or health > std.math.maxInt(i16) or fire < std.math.minInt(i16) or fire > std.math.maxInt(i16)) return error.InvalidExperienceOrb;
            const state: vanilla.Experience.Orb = .{ .value = @intCast(value), .count = @intCast(count), .age = @intCast(age), .health = @intCast(health), .fire = @intCast(fire), .on_ground = ground };
            const id = try owner.entities.create(body);
            var key: [9]u8 = undefined;
            key[0] = 1;
            std.mem.writeInt(u64, key[1..9], id, .big);
            try owner.orbs.put(&key, &state.encode());
            owner.counts.orbs += 1;
        }
        if ((owner.counts.items + owner.counts.orbs) % 128 == 0) try owner.save();
    }
}
