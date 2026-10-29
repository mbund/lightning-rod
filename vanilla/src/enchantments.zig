const std = @import("std");
const wire = @import("wire_1_21_5");
const game_data = @import("game_data");
const packets = @import("minecraft_packets");
const components = @import("item_components.zig");
const data = @import("item_data.zig");
const Items = @import("items.zig").Items;

const Payload = wire.SlotComponent.cases.data.enchantments.Payload;

pub const Enchantments = struct {
    pub const id = "minecraft:enchantments";
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *Items, packets: *packets.Packets };
    pub const Entry = struct { id: u32, level: u32 };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Enchantments {
        const self = try allocator.create(Enchantments);
        self.* = .{ .deps = deps };
        try deps.items.components.on(.enchantments, self, .{ .read = read, .write = write });
        return self;
    }

    fn read(packet: Payload.Reader, _: *Enchantments, context: components.ReadContext) !Payload.Reader.Done {
        var entries: [256]Entry = undefined;
        var count: usize = 0;
        var sequence = try packet.enchantments();
        while (try sequence.next()) |entry| {
            if (count == entries.len) return error.InvalidComponent;
            const enchantment, const next = try entry.id();
            const level_value, const done = try next.level();
            if (level_value < 0 or level_value > 255) return error.InvalidComponent;
            const name = try context.selected.registryName("minecraft:enchantment", enchantment);
            const canonical = game_data.registry.enchantmentId(name) orelse return error.UnsupportedComponent;
            entries[count] = .{ .id = @intCast(canonical), .level = @intCast(level_value) };
            count += 1;
            try sequence.advance(done);
        }
        const bytes = try encode(entries[0..count], context.output.*);
        context.output.* = context.output.*[bytes.len..];
        return sequence.finish();
    }

    /// Sorts the caller's scratch entries into canonical order.
    pub fn encode(entries: []Entry, output: []u8) ![]const u8 {
        if (entries.len > 256) return error.InvalidComponent;
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.id < b.id;
            }
        }.less);
        var writer = std.Io.Writer.fixed(output);
        try writer.writeInt(u16, @intCast(entries.len), .little);
        for (entries, 0..) |entry, index| {
            if (entry.level > 255 or entry.id >= game_data.registry.enchantment_names.len) return error.InvalidComponent;
            if (index > 0 and entries[index - 1].id == entry.id) return error.InvalidComponent;
            try writer.writeInt(u32, entry.id, .little);
            try writer.writeInt(u32, entry.level, .little);
        }
        return output[0..writer.end];
    }

    fn write(packet: Payload.Writer, self: *Enchantments, context: components.WriteContext) !Payload.Writer.Done {
        const bytes = context.value orelse return error.Corrupt;
        if (bytes.len < 2) return error.Corrupt;
        const count = std.mem.readInt(u16, bytes[0..2], .little);
        if (bytes.len != 2 + @as(usize, count) * 8) return error.Corrupt;
        const selected = try self.deps.packets.definition(context.protocol);
        var sequence = try packet.enchantments(count);
        for (0..count) |index| {
            const enchantment = std.mem.readInt(u32, bytes[2 + index * 8 ..][0..4], .little);
            const name = game_data.registry.enchantmentName(@intCast(enchantment)) orelse return error.Corrupt;
            const value = std.mem.readInt(u32, bytes[6 + index * 8 ..][0..4], .little);
            const entry = (try sequence.next()).?;
            try sequence.advance(try (try entry.id(try selected.registryId("minecraft:enchantment", name))).level(@intCast(value)));
        }
        return sequence.finish();
    }

    pub fn level(view: data.View, enchantment: u32) !u32 {
        const bytes = view.value(.enchantments) orelse return 0;
        if (bytes.len < 2) return error.Corrupt;
        const count = std.mem.readInt(u16, bytes[0..2], .little);
        if (bytes.len != 2 + @as(usize, count) * 8) return error.Corrupt;
        for (0..count) |index| if (std.mem.readInt(u32, bytes[2 + index * 8 ..][0..4], .little) == enchantment) return std.mem.readInt(u32, bytes[6 + index * 8 ..][0..4], .little);
        return 0;
    }
};
