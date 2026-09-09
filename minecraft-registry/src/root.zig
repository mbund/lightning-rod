const std = @import("std");
const generated = @import("generated_blocks");

pub const Block = generated.Block;
pub const minecraft_version = generated.minecraft_version;
pub const block_count = generated.names.len;
pub const state_count = generated.state_names.len;

pub fn blockName(block: Block) []const u8 {
    return generated.names[@intFromEnum(block)];
}

pub fn blockFromName(name: []const u8) ?Block {
    const bare = if (std.mem.startsWith(u8, name, "minecraft:")) name[10..] else name;
    for (generated.names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, bare)) return @enumFromInt(index);
    }
    return null;
}

pub fn blockFromStateName(canonical_name: []const u8) ?Block {
    const end = std.mem.indexOfScalar(u8, canonical_name, '[') orelse canonical_name.len;
    return blockFromName(canonical_name[0..end]);
}

pub const State = struct {
    id: u32,

    pub fn parse(canonical_name: []const u8) ?State {
        const block_id = blockFromStateName(canonical_name) orelse return null;
        const first = generated.state_offsets[@intFromEnum(block_id)];
        const end = generated.state_offsets[@intFromEnum(block_id) + 1];
        for (generated.state_names[first..end], first..) |candidate, id| {
            if (std.mem.eql(u8, candidate, canonical_name)) return .{ .id = @intCast(id) };
        }
        return null;
    }

    pub fn fromId(id: u32) ?State {
        if (id >= state_count) return null;
        return .{ .id = id };
    }

    pub inline fn block(self: State) Block {
        std.debug.assert(self.id < state_count);
        return generated.state_blocks[self.id];
    }

    pub inline fn canonicalName(self: State) []const u8 {
        std.debug.assert(self.id < state_count);
        return generated.state_names[self.id];
    }

    pub fn is(self: State, expected: Block) bool {
        return self.block() == expected;
    }

    pub fn eql(self: State, other: State) bool {
        return self.id == other.id;
    }

    pub fn property(self: State, key: []const u8) ?[]const u8 {
        const name = self.canonicalName();
        const open = std.mem.indexOfScalar(u8, name, '[') orelse return null;
        const close = std.mem.lastIndexOfScalar(u8, name, ']') orelse return null;
        if (close <= open + 1) return null;
        var properties = std.mem.splitScalar(u8, name[open + 1 .. close], ',');
        while (properties.next()) |entry| {
            const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..equals], key)) return entry[equals + 1 ..];
        }
        return null;
    }
};

pub fn defaultState(block: Block) State {
    return .{ .id = generated.default_states[@intFromEnum(block)] };
}

pub fn parseBlockArgument(argument: []const u8, buffer: []u8) ?State {
    const nbt_start = std.mem.indexOfScalar(u8, argument, '{') orelse argument.len;
    const state_text = argument[0..nbt_start];
    const open = std.mem.indexOfScalar(u8, state_text, '[') orelse {
        const block = blockFromName(state_text) orelse return null;
        return defaultState(block);
    };
    const close = std.mem.lastIndexOfScalar(u8, state_text, ']') orelse return null;
    if (close + 1 != state_text.len) return null;
    const block = blockFromName(state_text[0..open]) orelse return null;
    var properties: [32]Property = undefined;
    const count = defaultProperties(defaultState(block).canonicalName(), &properties) orelse return null;
    var requested = std.mem.splitScalar(u8, state_text[open + 1 .. close], ',');
    while (requested.next()) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
        if (!replaceProperty(properties[0..count], entry[0..equals], entry[equals + 1 ..])) return null;
    }
    std.mem.sort(Property, properties[0..count], {}, lessProperty);
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("minecraft:{s}", .{blockName(block)}) catch return null;
    if (count != 0) {
        writer.writeByte('[') catch return null;
        for (properties[0..count], 0..) |property, index| {
            if (index != 0) writer.writeByte(',') catch return null;
            writer.print("{s}={s}", .{ property.name, property.value }) catch return null;
        }
        writer.writeByte(']') catch return null;
    }
    return State.parse(writer.buffered());
}

const Property = struct { name: []const u8, value: []const u8 };

fn defaultProperties(canonical: []const u8, output: []Property) ?usize {
    const open = std.mem.indexOfScalar(u8, canonical, '[') orelse return 0;
    const close = std.mem.lastIndexOfScalar(u8, canonical, ']') orelse return null;
    var count: usize = 0;
    var entries = std.mem.splitScalar(u8, canonical[open + 1 .. close], ',');
    while (entries.next()) |entry| {
        if (count == output.len) return null;
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
        output[count] = .{ .name = entry[0..equals], .value = entry[equals + 1 ..] };
        count += 1;
    }
    return count;
}

fn replaceProperty(properties: []Property, name: []const u8, value: []const u8) bool {
    for (properties) |*property| {
        if (!std.mem.eql(u8, property.name, name)) continue;
        property.value = value;
        return true;
    }
    return false;
}

fn lessProperty(_: void, left: Property, right: Property) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

test "typed block identity and state properties" {
    const state = State.parse("minecraft:cactus[age=7]").?;
    try std.testing.expect(state.is(.cactus));
    try std.testing.expectEqualStrings("7", state.property("age").?);
    try std.testing.expect(blockFromName("minecraft:stone") == .stone);
    try std.testing.expect(defaultState(.stone).is(.stone));
    try std.testing.expect(State.parse("minecraft:cactus[age=garbage]") == null);
}

test "block arguments fill omitted properties from the default state" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqual(defaultState(.chain), parseBlockArgument("minecraft:chain", &buffer).?);
    try std.testing.expectEqualStrings(
        "minecraft:chain[axis=x,waterlogged=false]",
        parseBlockArgument("minecraft:chain[axis=x]", &buffer).?.canonicalName(),
    );
}
