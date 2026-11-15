const std = @import("std");
const wire = @import("wire_1_21_5");
const encoding = @import("protocol_support");
const components = @import("item_components.zig");
const Items = @import("items.zig").Items;

pub const Payload = wire.SlotComponent.cases.data.lore.Payload;

pub const Lore = struct {
    pub const id = "minecraft:item_lore";
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *Items };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Lore {
        const self = try allocator.create(Lore);
        self.* = .{};
        try deps.items.components.on(.lore, self, .{ .read = read, .write = write });
        return self;
    }

    fn read(packet: Payload.Reader, _: *Lore, context: components.ReadContext) !Payload.Reader.Done {
        return readStored(packet, context);
    }

    fn write(packet: Payload.Writer, _: *Lore, context: components.WriteContext) !Payload.Writer.Done {
        return writeAppending(packet, context.value, &.{});
    }
};

pub fn readStored(packet: Payload.Reader, context: components.ReadContext) !Payload.Reader.Done {
    var lines = try packet.value();
    if (lines.remaining > 256) return error.InvalidLore;
    context.output.* = try encoding.write_varint(context.output.*, @intCast(lines.remaining));
    while (try lines.next()) |line| {
        const value, const done = try line.value();
        context.output.* = try encoding.write_bytes(context.output.*, value);
        try lines.advance(done);
    }
    return lines.finish();
}

pub fn writeAppending(packet: Payload.Writer, stored: ?[]const u8, extra: []const []const u8) !Payload.Writer.Done {
    const count, var rest = if (stored) |bytes| try encoding.read_varint(bytes) else .{ @as(i32, 0), @as([]const u8, &.{}) };
    if (count < 0 or count > 256 or extra.len > 256 - @as(usize, @intCast(count))) return error.InvalidLore;
    var lines = try packet.value(@as(usize, @intCast(count)) + extra.len);
    for (0..@intCast(count)) |_| {
        const value, const next = try encoding.read_anonymousNbt(rest);
        lines = try lines.element(value);
        rest = next;
    }
    if (rest.len != 0) return error.Corrupt;
    for (extra) |line| lines = try lines.element(line);
    return lines.finish();
}
