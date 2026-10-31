const std = @import("std");
const wire = @import("wire_1_21_5");
const game_data = @import("game_data");
const encoding = @import("protocol_support");
const components = @import("item_components.zig");
const Items = @import("items.zig").Items;
const Packets = @import("minecraft_packets").Packets;
const custom_data = @import("custom_data.zig");

const Custom = wire.SlotComponent.cases.data.custom_data.Payload;
const Stew = wire.SlotComponent.cases.data.suspicious_stew_effects.Payload;
const BlockState = wire.SlotComponent.cases.data.block_state.Payload;

pub const ItemContent = struct {
    pub const id = "minecraft:item_content";
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *Items, packets: *Packets };
    deps: Dependencies,
    normalization: std.heap.FixedBufferAllocator,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemContent {
        const self = try allocator.create(ItemContent);
        const fields = deps.items.deps.inventories.config.max_item_bytes / 4;
        const bytes = try std.math.add(usize, try std.math.mul(usize, fields, @sizeOf(custom_data.Field)), @alignOf(custom_data.Field));
        self.* = .{ .deps = deps, .normalization = .init(try allocator.alloc(u8, bytes)) };
        try deps.items.components.on(.custom_data, self, .{ .read = readCustom, .write = writeCustom });
        try deps.items.components.on(.suspicious_stew_effects, self, .{ .read = readStew, .write = writeStew });
        try deps.items.components.on(.block_state, self, .{ .read = readBlockState, .write = writeBlockState });
        return self;
    }

    fn readCustom(packet: Custom.Reader, self: *ItemContent, context: components.ReadContext) !Custom.Reader.Done {
        const value, const done = try packet.value();
        self.normalization.reset();
        defer self.normalization.reset();
        const canonical = try custom_data.canonicalize(value, context.output.*, self.normalization.allocator());
        context.output.* = context.output.*[canonical.len..];
        return done;
    }

    fn writeCustom(packet: Custom.Writer, _: *ItemContent, context: components.WriteContext) !Custom.Writer.Done {
        return packet.value(context.value orelse return error.Corrupt);
    }

    fn readBlockState(packet: BlockState.Reader, _: *ItemContent, context: components.ReadContext) !BlockState.Reader.Done {
        var properties = try packet.properties();
        if (properties.remaining > 64) return error.InvalidComponent;
        const Property = struct { name: []const u8, value: []const u8 };
        var values: [64]Property = undefined;
        var count: usize = 0;
        while (try properties.next()) |property| {
            const name, const next = try property.name();
            const value, const done = try next.value();
            const existing = for (values[0..count]) |*entry| {
                if (std.mem.eql(u8, entry.name, name)) break entry;
            } else null;
            if (existing) |entry| entry.value = value else {
                values[count] = .{ .name = name, .value = value };
                count += 1;
            }
            try properties.advance(done);
        }
        std.mem.sortUnstable(Property, values[0..count], {}, struct {
            fn less(_: void, a: Property, b: Property) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        context.output.* = try encoding.write_varint(context.output.*, @intCast(count));
        for (values[0..count]) |entry| {
            context.output.* = try encoding.write_pstring(context.output.*, entry.name, i32);
            context.output.* = try encoding.write_pstring(context.output.*, entry.value, i32);
        }
        return properties.finish();
    }

    fn writeBlockState(packet: BlockState.Writer, _: *ItemContent, context: components.WriteContext) !BlockState.Writer.Done {
        const count, var bytes = try encoding.read_varint(context.value orelse return error.Corrupt);
        if (count < 0 or count > 64) return error.Corrupt;
        var properties = try packet.properties(@intCast(count));
        for (0..@intCast(count)) |_| {
            const name, const after_name = try encoding.read_buffer_counted(bytes, i32);
            const value, const rest = try encoding.read_buffer_counted(after_name, i32);
            const entry = (try properties.next()).?;
            try properties.advance(try (try entry.name(name)).value(value));
            bytes = rest;
        }
        if (bytes.len != 0) return error.Corrupt;
        return properties.finish();
    }

    fn readStew(packet: Stew.Reader, _: *ItemContent, context: components.ReadContext) !Stew.Reader.Done {
        var effects = try packet.effects();
        if (effects.remaining > 256) return error.InvalidComponent;
        context.output.* = try encoding.write_varint(context.output.*, @intCast(effects.remaining));
        while (try effects.next()) |entry| {
            const effect_id, const next = try entry.effect();
            const duration, const done = try next.duration();
            if (duration < 0) return error.InvalidComponent;
            const name = try context.selected.registryName("minecraft:mob_effect", effect_id);
            const canonical = try game_data.snapshot.id(game_data.registry_snapshot, "minecraft:mob_effect", name) orelse return error.UnsupportedComponent;
            context.output.* = try encoding.write_varint(context.output.*, @intCast(canonical));
            context.output.* = try encoding.write_varint(context.output.*, duration);
            try effects.advance(done);
        }
        return effects.finish();
    }

    fn writeStew(packet: Stew.Writer, self: *ItemContent, context: components.WriteContext) !Stew.Writer.Done {
        const count, var bytes = try encoding.read_varint(context.value orelse return error.Corrupt);
        if (count < 0 or count > 256) return error.Corrupt;
        const selected = try self.deps.packets.definition(context.protocol);
        var effects = try packet.effects(@intCast(count));
        for (0..@intCast(count)) |_| {
            const effect_id, const after_id = try encoding.read_varint(bytes);
            const duration, const rest = try encoding.read_varint(after_id);
            if (effect_id < 0 or duration < 0) return error.Corrupt;
            const name = try game_data.snapshot.name(game_data.registry_snapshot, "minecraft:mob_effect", @intCast(effect_id)) orelse return error.Corrupt;
            const entry = (try effects.next()).?;
            try effects.advance(try (try entry.effect(try selected.registryId("minecraft:mob_effect", name))).duration(duration));
            bytes = rest;
        }
        if (bytes.len != 0) return error.Corrupt;
        return effects.finish();
    }
};
