const std = @import("std");
const snapshot = @import("recipe_snapshot.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    const data = try snapshot.load(init.arena.allocator(), @embedFile("vanilla_recipes"));
    const file = try std.Io.Dir.cwd().createFile(init.io, args[1], .{});
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var output = file.writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("const data = @import(\"recipe_data\");\npub const value: data.Table = .{\n.recipes = &.{\n");
    for (data.recipes) |entry| {
        if (entry) |recipe| {
            try writer.print(".{{ .index = {d}, .output = {d}, .count = {d}, .ticks = {d}, .experience = @bitCast(@as(u32, {d})) }},\n", .{ recipe.index, recipe.output, recipe.count, recipe.ticks, @as(u32, @bitCast(recipe.experience)) });
        } else try writer.writeAll("null,\n");
    }
    try writer.writeAll("},\n.cooking_experience = &.{\n");
    for (data.cooking_experience) |experience| try writer.print("@bitCast(@as(u32, {d})),\n", .{@as(u32, @bitCast(experience))});
    try writer.writeAll("},\n.fuels = &.{\n");
    for (data.fuels) |fuel| {
        try writer.print(".{{ .ticks = {d}, .remainder = ", .{fuel.ticks});
        if (fuel.remainder) |kind| try writer.print("{d}", .{kind}) else try writer.writeAll("null");
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("},\n.crafting = &.{\n");
    for (data.crafting) |craft| {
        try writer.print(".{{ .width = {d}, .height = {d}, .count = {d}, .output = {d}, .amount = {d}, .ingredients = .{{", .{ craft.width, craft.height, craft.count, craft.output, craft.amount });
        for (craft.ingredients) |ingredient| try writer.print(".{{ .offset = {d}, .count = {d} }},", .{ ingredient.offset, ingredient.count });
        try writer.writeAll("} },\n");
    }
    try writer.writeAll("},\n.alternatives = &.{\n");
    for (data.alternatives, 0..) |kind, index| {
        try writer.print("{d},", .{kind});
        if (index % 16 == 15) try writer.writeByte('\n');
    }
    try writer.writeAll("\n},\n};\n");
    try writer.flush();
}
