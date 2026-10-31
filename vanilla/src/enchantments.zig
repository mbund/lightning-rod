const EnchantmentRegistry = @import("enchantment_registry.zig").EnchantmentRegistry;
const std = @import("std");
const wire = @import("wire_1_21_5");
const content_ids = @import("content_ids.zig");
const packets = @import("minecraft_packets");
const components = @import("item_components.zig");
const data = @import("item_data.zig");
const Items = @import("items.zig").Items;
const item_actions = @import("item_actions.zig");

const Payload = wire.SlotComponent.cases.data.enchantments.Payload;

pub const Enchantments = struct {
    pub const Registry = EnchantmentRegistry;
    pub const Definition = Registry.Definition;
    pub const id = "minecraft:enchantments";
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *Items, packets: *packets.Packets, actions: *item_actions.ItemActions, definitions: *Registry };
    pub const Entry = struct { name: []const u8, level: u32 };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Enchantments {
        const self = try allocator.create(Enchantments);
        self.* = .{ .deps = deps };
        try deps.items.components.on(.enchantments, self, .{ .read = read, .write = write });
        try deps.actions.on(item_actions.Binding.bind(Enchantments, self, onUse));
        return self;
    }

    fn onUse(self: *Enchantments, context: *const item_actions.Context) !item_actions.Result {
        return self.deps.definitions.effects.use(context);
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
            entries[count] = .{ .name = try context.selected.registryName("minecraft:enchantment", enchantment), .level = @intCast(level_value) };
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
        std.mem.sortUnstable(Entry, entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll("LREN");
        try writer.writeInt(u16, @intCast(entries.len), .little);
        for (entries, 0..) |entry, index| {
            if (entry.level > 255 or !content_ids.validName(entry.name)) return error.InvalidComponent;
            if (index > 0 and std.mem.eql(u8, entries[index - 1].name, entry.name)) return error.InvalidComponent;
            try writer.writeInt(u16, @intCast(entry.name.len), .little);
            try writer.writeAll(entry.name);
            try writer.writeInt(u32, entry.level, .little);
        }
        return output[0..writer.end];
    }

    pub const Iterator = struct {
        reader: std.Io.Reader,
        remaining: usize,
        previous: ?[]const u8 = null,

        pub fn init(bytes: []const u8) !Iterator {
            var reader = std.Io.Reader.fixed(bytes);
            if (!std.mem.eql(u8, try reader.take(4), "LREN")) return error.Corrupt;
            const count = try reader.takeInt(u16, .little);
            if (count > 256) return error.Corrupt;
            return .{ .reader = reader, .remaining = count };
        }

        pub fn next(self: *Iterator) !?Entry {
            if (self.remaining == 0) {
                if (self.reader.seek != self.reader.end) return error.Corrupt;
                return null;
            }
            const name = try self.reader.take(try self.reader.takeInt(u16, .little));
            const value = try self.reader.takeInt(u32, .little);
            if (value > 255 or !content_ids.validName(name)) return error.Corrupt;
            if (self.previous) |previous| if (!std.mem.lessThan(u8, previous, name)) return error.Corrupt;
            self.previous = name;
            self.remaining -= 1;
            return .{ .name = name, .level = value };
        }
    };

    fn write(packet: Payload.Writer, self: *Enchantments, context: components.WriteContext) !Payload.Writer.Done {
        var iterator = try Iterator.init(context.value orelse return error.Corrupt);
        const selected = try self.deps.packets.definition(context.protocol);
        var ids: [256]i32 = undefined;
        var levels: [256]u32 = undefined;
        var count: usize = 0;
        while (try iterator.next()) |enchantment| {
            const numeric = selected.registryId("minecraft:enchantment", enchantment.name) catch continue;
            ids[count] = numeric;
            levels[count] = enchantment.level;
            count += 1;
        }
        var sequence = try packet.enchantments(count);
        for (ids[0..count], levels[0..count]) |numeric, level_value| {
            const entry = (try sequence.next()).?;
            try sequence.advance(try (try entry.id(numeric)).level(@intCast(level_value)));
        }
        return sequence.finish();
    }

    pub fn level(view: data.View, name: []const u8) !u32 {
        var iterator = try Iterator.init(view.value(.enchantments) orelse return 0);
        var result: u32 = 0;
        while (try iterator.next()) |entry| if (std.mem.eql(u8, entry.name, name)) {
            result = entry.level;
        };
        return result;
    }
};
