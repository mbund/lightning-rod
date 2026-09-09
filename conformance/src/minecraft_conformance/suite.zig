const std = @import("std");
const adapter_api = @import("adapter.zig");
const canonicalizer = @import("canonicalizer.zig");
const input_encoder = @import("input_encoder.zig");
const packet_model = @import("packet.zig");

const first_position = "0,64,0";
const second_position = "1,64,0";

const Animation = struct {
    position: []const u8,
    stage: i8,
};

pub fn blockBreakingProgress(adapter: adapter_api.Adapter, allocator: std.mem.Allocator) !void {
    const players = [_]adapter_api.Player{
        .{ .name = "miner", .position = .{ 0.5, 65, 2.5 }, .gamemode = .survival, .held_item = "minecraft:diamond_pickaxe" },
        .{ .name = "observer", .position = .{ 2.5, 65, 2.5 }, .gamemode = .survival },
        .{ .name = "distant", .position = .{ 40.5, 65, 2.5 }, .gamemode = .survival },
        .{ .name = "boundary", .position = .{ 0, 64, 32 }, .gamemode = .survival },
    };
    const blocks = [_]adapter_api.Block{
        .{ .position = .{ 0, 64, 0 }, .state = "minecraft:stone" },
        .{ .position = .{ 1, 64, 0 }, .state = "minecraft:stone" },
    };
    const identities = try adapter.reset(.{ .players = &players, .blocks = &blocks });
    var canon = canonicalizer.Canonicalizer.initWithAllocator(identities, allocator);
    defer canon.deinit();

    try stageAction(adapter, "miner", "start_destroy_block", first_position);
    try expectAnimations(&canon, try adapter.step(), &.{ .{ .position = first_position, .stage = 1 }, .{ .position = first_position, .stage = 3 } });
    try expectAnimations(&canon, try adapter.step(), &.{.{ .position = first_position, .stage = 5 }});
    try expectAnimations(&canon, try adapter.step(), &.{.{ .position = first_position, .stage = 7 }});
    try expectAnimations(&canon, try adapter.step(), &.{.{ .position = first_position, .stage = 8 }});

    try stageAction(adapter, "miner", "abort_destroy_block", first_position);
    try expectAnimations(&canon, try adapter.step(), &.{.{ .position = first_position, .stage = -1 }});
    try expectAnimations(&canon, try adapter.step(), &.{});

    try stageAction(adapter, "miner", "start_destroy_block", first_position);
    try expectAnimations(&canon, try adapter.step(), &.{ .{ .position = first_position, .stage = 1 }, .{ .position = first_position, .stage = 3 } });
    try stageAction(adapter, "miner", "start_destroy_block", second_position);
    try expectAnimations(&canon, try adapter.step(), &.{ .{ .position = second_position, .stage = 1 }, .{ .position = second_position, .stage = 3 } });
    try stageAction(adapter, "miner", "abort_destroy_block", first_position);
    try expectAnimations(&canon, try adapter.step(), &.{ .{ .position = second_position, .stage = -1 }, .{ .position = first_position, .stage = -1 } });
    try expectAnimations(&canon, try adapter.step(), &.{});

    try stageAction(adapter, "miner", "start_destroy_block", first_position);
    try stageAction(adapter, "miner", "abort_destroy_block", second_position);
    try expectAnimations(&canon, try adapter.step(), &.{ .{ .position = first_position, .stage = 1 }, .{ .position = first_position, .stage = -1 }, .{ .position = second_position, .stage = -1 } });
    try expectAnimations(&canon, try adapter.step(), &.{});
}

pub fn airborneBlockBreakingProgress(adapter: adapter_api.Adapter, allocator: std.mem.Allocator) !void {
    const players = [_]adapter_api.Player{
        .{ .name = "miner", .position = .{ 0.5, 65, 2.5 }, .gamemode = .survival, .held_item = "minecraft:diamond_pickaxe", .on_ground = false },
        .{ .name = "observer", .position = .{ 2.5, 65, 2.5 }, .gamemode = .survival },
    };
    const blocks = [_]adapter_api.Block{.{ .position = .{ 0, 64, 0 }, .state = "minecraft:stone" }};
    const identities = try adapter.reset(.{ .players = &players, .blocks = &blocks });
    var canon = canonicalizer.Canonicalizer.initWithAllocator(identities, allocator);
    defer canon.deinit();

    try stageAction(adapter, "miner", "start_destroy_block", first_position);
    try expectAnimations(&canon, try adapter.step(), &.{.{ .position = first_position, .stage = 0 }});
    try expectAnimations(&canon, try adapter.step(), &.{.{ .position = first_position, .stage = 1 }});
    try stageAction(adapter, "miner", "abort_destroy_block", first_position);
    try expectAnimations(&canon, try adapter.step(), &.{.{ .position = first_position, .stage = -1 }});
}

fn stageAction(adapter: adapter_api.Adapter, client: []const u8, action: []const u8, position: []const u8) !void {
    var storage: [128]u8 = undefined;
    const fields = [_]packet_model.Field{
        .{ .name = "action", .value = .{ .literal = action } },
        .{ .name = "position", .value = .{ .literal = position } },
    };
    try adapter.stage(client, try input_encoder.encode(&storage, .{ .name = "player_action", .fields = &fields }));
}

fn expectAnimations(canon: *canonicalizer.Canonicalizer, outputs: []const @import("raw_packet.zig").Clientbound, expected: []const Animation) !void {
    var count: usize = 0;
    for (outputs) |raw| {
        const output = try canon.canonicalize(raw) orelse continue;
        if (!std.mem.eql(u8, output.packet.name, "block_break_animation")) continue;
        if (!std.mem.eql(u8, output.recipient, "observer")) return error.BreakProgressSentOutsideVanillaAudience;
        if (!std.mem.eql(u8, field(output.packet, "subject") orelse return error.MissingCanonicalField, "miner")) return error.WrongBreakProgressSubject;
        if (count == expected.len) return error.UnexpectedBreakProgressStage;
        if (!std.mem.eql(u8, field(output.packet, "position") orelse return error.MissingCanonicalField, expected[count].position)) return error.WrongBreakProgressPosition;
        const stage = std.fmt.parseInt(i8, field(output.packet, "stage") orelse return error.MissingCanonicalField, 10) catch return error.InvalidBreakProgressStage;
        if (stage != expected[count].stage) return error.WrongBreakProgressStage;
        count += 1;
    }
    if (count != expected.len) return error.MissingBreakProgressStage;
}

fn field(packet: packet_model.Packet, name: []const u8) ?[]const u8 {
    for (packet.fields) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value.literal;
    return null;
}
