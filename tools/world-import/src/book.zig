const std = @import("std");
const nbt = @import("nbt");
const vanilla = @import("vanilla");
const fields = @import("nbt.zig");
const world_import = @import("import.zig");

pub fn read(owner: *world_import.Import, scratch: std.mem.Allocator, doc: nbt.Document, player: nbt.Node, original: u128, uuid: u128) !void {
    const flags = try scratch.alloc(u8, owner.recipe_identities.len);
    @memset(flags, 0);
    var settings: u8 = 0;
    if (player.childNamed(doc.nodes, "recipeBook")) |book| {
        for ([_][]const u8{ "isGuiOpen", "isFilteringCraftable", "isFurnaceGuiOpen", "isFurnaceFilteringCraftable", "isBlastingFurnaceGuiOpen", "isBlastingFurnaceFilteringCraftable", "isSmokerGuiOpen", "isSmokerFilteringCraftable" }, 0..) |name, index| {
            if (try fields.optionalInt(doc, book, name, 0) != 0) settings |= @as(u8, 1) << @intCast(index);
        }
        for ([_][]const u8{ "recipes", "toBeDisplayed" }, 0..) |name, index| if (book.childNamed(doc.nodes, name)) |list| {
            _ = try list.expectTag(.list);
            var iterator = list.childIterator(doc.nodes);
            while (iterator.next()) |recipe| {
                const id = try recipe.string();
                if (owner.recipe_names.get(id)) |at| flags[at] |= if (index == 0) @as(u8, 1) else 3 else try owner.unsupported("recipe book entry", id);
            }
        };
    }
    const definitions = owner.content.book.unlocks;
    const criteria = try scratch.alloc(bool, definitions.criteria.len);
    const awards = try scratch.alloc(bool, definitions.rules.len);
    @memset(criteria, false);
    @memset(awards, false);
    const hex = try std.fmt.allocPrint(scratch, "{x:0>32}", .{original});
    const filename = try std.fmt.allocPrint(scratch, "{s}/advancements/{s}-{s}-{s}-{s}-{s}.json", .{ owner.options.input, hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
    const bytes = std.Io.Dir.cwd().readFileAlloc(owner.io, filename, scratch, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (bytes) |value| {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, scratch, value, .{});
        if (root != .object) return error.InvalidAdvancements;
        var criterion_ids = std.AutoHashMap([32]u8, usize).init(scratch);
        var rule_ids = std.AutoHashMap([32]u8, usize).init(scratch);
        for (definitions.criteria, 0..) |criterion, index| try criterion_ids.put(criterion.identity, index);
        for (definitions.rules, 0..) |rule, index| try rule_ids.put(rule.identity, index);
        var iterator = root.object.iterator();
        while (iterator.next()) |advancement| {
            if (advancement.value_ptr.* != .object) continue;
            var hash: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(advancement.key_ptr.*, &hash, .{});
            if (rule_ids.get(hash)) |index| {
                if (advancement.value_ptr.object.get("done")) |done| {
                    if (done != .bool) return error.InvalidAdvancements;
                    awards[index] = done.bool;
                }
            }
            if (advancement.value_ptr.object.get("criteria")) |progress| {
                if (progress != .object) return error.InvalidAdvancements;
                var entries = progress.object.iterator();
                while (entries.next()) |entry| {
                    var identity = std.crypto.hash.Blake3.init(.{});
                    identity.update(advancement.key_ptr.*);
                    identity.update(&.{0});
                    identity.update(entry.key_ptr.*);
                    identity.final(&hash);
                    if (criterion_ids.get(hash)) |index| {
                        if (entry.value_ptr.* != .string) return error.InvalidAdvancements;
                        criteria[index] = true;
                    }
                }
            }
        }
    }
    const progress: vanilla.RecipeBook.SavedProgress = .{ .settings = settings, .flags = flags, .identities = owner.recipe_identities, .criteria = criteria, .criterion_definitions = definitions.criteria, .awards = awards, .rule_definitions = definitions.rules };
    var output: std.Io.Writer.Allocating = .init(scratch);
    try progress.write(&output.writer);
    var key: [16]u8 = undefined;
    std.mem.writeInt(u128, &key, uuid, .big);
    try owner.recipes.put(&key, output.written());
}
