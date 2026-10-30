const std = @import("std");
const inventories = @import("inventories");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const directory = init.environ_map.get("LIGHTNING_ROD_E2E_TEST_DIRECTORY") orelse return error.MissingTestDirectory;
    const packs = [_]vanilla.Datapacks.Source{
        .{ .directory = try std.fs.path.join(init.arena.allocator(), &.{ directory, "pack-48" }) },
        .{ .directory = try std.fs.path.join(init.arena.allocator(), &.{ directory, "pack-71" }) },
        .{ .directory = try std.fs.path.join(init.arena.allocator(), &.{ directory, "pack" }) },
    };
    const defaults = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 1, .render_distance = 2, .gamemode = .survival }),
    });
    const plugins = lightning_rod.plugin.compose(.{
        defaults,
        lightning_rod.plugin.configured(vanilla.Datapacks, .{}),
        lightning_rod.plugin.configured(Probe, .{ .packs = &packs }),
    });
    try e2e.profile.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

const ChargedRecipe = struct {
    pub const id = "e2e:charged";
    pub const Parameters = struct { charge: i32, increment: i32 };
    pub const Completion = struct { player: u128, charge_before: i32, charge_after: i32 };
    pub const minimum_inputs = 1;
    pub const maximum_inputs = 1;
    completed: usize = 0,

    pub fn display(_: *ChargedRecipe, allocator: std.mem.Allocator, parameters: *const Parameters) !vanilla.recipes.Display {
        var input: vanilla.custom_data.Editor = .{ .allocator = allocator };
        try input.setInt("charge", parameters.charge);
        const input_components = try allocator.alloc(vanilla.recipes.Component, 1);
        input_components[0] = .{ .key = vanilla.item_data.key(.custom_data), .value = try input.finish() };
        var output: vanilla.custom_data.Editor = .{ .allocator = allocator };
        try output.setInt("charge", try std.math.add(i32, parameters.charge, parameters.increment));
        const output_components = try allocator.alloc(vanilla.recipes.Component, 1);
        output_components[0] = .{ .key = vanilla.item_data.key(.custom_data), .value = try output.finish() };
        const ingredients = try allocator.alloc(vanilla.recipes.DisplayInput, 1);
        ingredients[0] = .{ .input = .{ .item = "minecraft:paper" }, .components = input_components };
        return .{ .ingredients = ingredients, .result = .{ .item = "minecraft:diamond", .components = output_components }, .initially_unlocked = true };
    }

    pub fn prepare(_: *ChargedRecipe, parameters: *const Parameters, context: *const vanilla.crafting.Context) !?vanilla.crafting.Implementation(ChargedRecipe).Prepared {
        for (context.input, 0..) |entry, index| {
            const input = entry orelse continue;
            if (input.view.kind != kind("minecraft:paper")) return null;
            std.log.info("event=e2e_craft_attempt player_uuid={x:0>32} inventory={s}", .{ context.player, @tagName(context.location) });
            const data = try input.customData() orelse return null;
            const charge = try data.getInt("charge") orelse return null;
            if (charge != parameters.charge) return null;
            const charge_after = try std.math.add(i32, charge, parameters.increment);
            var editor = try data.edit(context.scratch.allocator());
            try editor.setInt("charge", charge_after);
            var result = try context.result(kind("minecraft:diamond"), 1);
            try result.set(.custom_data, try editor.finish());
            var plan: vanilla.crafting.Plan = .{ .result = result.finish() };
            plan.consume[index] = 1;
            return .{ .plan = plan, .completion = .{ .player = context.player, .charge_before = charge, .charge_after = charge_after } };
        }
        return null;
    }

    pub fn validate(_: *ChargedRecipe, _: []const Completion) bool {
        return true;
    }

    pub fn complete(self: *ChargedRecipe, completions: []const Completion) void {
        for (completions) |completion| {
            std.log.info("event=e2e_craft_complete player_uuid={x:0>32} charge_before={d} charge_after={d}", .{ completion.player, completion.charge_before, completion.charge_after });
        }
        self.completed += completions.len;
    }
};

const MiningReward = struct {
    pub const id = "e2e:mining_reward";
    pub const kind: vanilla.loot.Kind = .function;
    pub const Parameters = struct { count: u16 };

    pub fn apply(_: *const MiningReward, parameters: *const Parameters, context: *const vanilla.loot.Context, stack: *vanilla.loot.Stack) !void {
        if (context.player == null or context.location == null) return error.MissingMiningContext;
        stack.count = parameters.count;
    }
};

const Probe = struct {
    pub const id = "e2e:datapacks";
    pub const Configuration = struct { packs: []const vanilla.Datapacks.Source };
    pub const Dependencies = struct {
        item_definitions: *vanilla.Items.Registry,
        dimensions: *vanilla.Dimensions,
        datapacks: *vanilla.Datapacks,
        players: *vanilla.Players,
        inventories: *vanilla.Inventories,
        items: *vanilla.Items,
        menus: *vanilla.PlayerInventory,
        book: *vanilla.RecipeBook,
        control: *e2e.Control,
        reload: *vanilla.Reload,
        chunks: *vanilla.Chunks,
    };
    deps: Dependencies,
    recipe: ChargedRecipe = .{},
    reward: MiningReward = .{},

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        try deps.datapacks.add(.{
            .sources = config.packs,
            .recipe_types = &.{vanilla.Datapacks.Recipe(ChargedRecipe).register(&self.recipe)},
            .loot_types = &.{vanilla.Datapacks.Loot(MiningReward).register(&self.reward)},
        });
        try deps.item_definitions.addDefinitions(.{
            .tags = &.{.{ .registry = "minecraft:item", .name = "e2e:typed_logs", .values = &.{.{ .id = "#minecraft:e2e_logs" }} }},
        });
        try deps.dimensions.addDefinitions(.{ .dimensions = &.{.{ .name = "e2e:typed_dimension", .definition = .{ .min_y = 0, .height = 256, .logical_height = 256 } }} });
        const logs = deps.item_definitions.tags.find("e2e:typed_logs") orelse return error.MissingTypedTag;
        if (!deps.item_definitions.tags.contains(logs, kind("minecraft:oak_log"))) return error.InvalidTypedTag;
        if ((try deps.dimensions.dimension("e2e:typed_dimension")).section_count != 16) return error.InvalidTypedDimension;
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "ready")) {
            if (self.deps.reload.latest()) |request| if (request.sequence > 0) {
                try self.verify(handle);
                try self.deps.control.send(handle, "reloaded");
                return .handled;
            };
            const player = self.deps.players.records[handle.index];
            const bytes = &[_]u8{ 10, 3, 0, 6, 'c', 'h', 'a', 'r', 'g', 'e', 0, 0, 0, 7, 0 };
            var wrong_bytes = bytes.*;
            wrong_bytes[wrong_bytes.len - 2] = 6;
            const wrong_item = try vanilla.item_data.define(self.deps.inventories, kind("minecraft:paper"), &.{.{ .key = vanilla.item_data.key(.custom_data), .value = &wrong_bytes }});
            const item = try vanilla.item_data.define(self.deps.inventories, kind("minecraft:paper"), &.{.{ .key = vanilla.item_data.key(.custom_data), .value = bytes }});
            try self.deps.chunks.setBlock(player.world, .{ .x = 2, .y = 65, .z = 0 }, @intCast(protocols.registry.block_stone_default_state));
            const edits = [_]inventories.Edit{
                .{ .slot = .{ .owner = player.uuid, .index = 39 }, .revision = 0, .stack = .{ .item = try self.deps.items.define("minecraft:paper"), .count = 2 } },
                .{ .slot = .{ .owner = player.uuid, .index = 40 }, .revision = 0, .stack = .{ .item = wrong_item, .count = 2 } },
                .{ .slot = .{ .owner = player.uuid, .index = 38 }, .revision = 0, .stack = .{ .item = try self.deps.items.define("minecraft:diamond_pickaxe"), .count = 1 } },
                .{ .slot = .{ .owner = player.uuid, .index = 36 }, .revision = 0, .stack = .{ .item = item, .count = 2 } },
                .{ .slot = .{ .owner = player.uuid, .index = 37 }, .revision = 0, .stack = .{ .item = try self.deps.items.define("minecraft:oak_log"), .count = 1 } },
            };
            if (!try self.deps.inventories.editMany(&edits)) return error.SetupRejected;
            self.deps.menus.changed(handle.index);
            try self.deps.control.send(handle, "setup");
        } else if (std.mem.eql(u8, text, "crafted")) {
            try self.verify(handle);
            if (self.recipe.completed != 2) return error.IncorrectCraftCompletionCount;
            try self.deps.reload.stage("e2e:datapacks");
        } else return .unhandled;
        return .handled;
    }

    fn verify(self: *Probe, handle: sessions.Handle) !void {
        const player = self.deps.players.records[handle.index];
        if (!try self.deps.book.knows(handle.index, self.deps.book.recipeId("e2e:charged").?) or
            !try self.deps.book.knows(handle.index, self.deps.book.recipeId("minecraft:oak_planks").?) or
            !(try self.deps.book.setting(handle.index, .crafting)).craftable) return error.IncorrectRecipeBookState;
        var slots: [37]inventories.Slot = undefined;
        var contents: [37]inventories.Contents = undefined;
        for (&slots, 0..) |*slot, index| slot.* = .{ .owner = player.uuid, .index = @intCast(9 + index) };
        try self.deps.inventories.getMany(&slots, &contents);
        var diamonds: u32 = 0;
        var emeralds: u32 = 0;
        var gold: u32 = 0;
        var tools: u32 = 0;
        var plain_paper: u32 = 0;
        var wrong_paper: u32 = 0;
        for (contents) |value| {
            const stack = value.stack orelse continue;
            const prepared = try self.deps.items.acquire(stack);
            defer prepared.release();
            if (prepared.view.kind == kind("minecraft:diamond")) {
                const data = try vanilla.custom_data.Compound.init(prepared.view.value(.custom_data) orelse return error.MissingCustomData);
                if (try data.getInt("charge") != 12) return error.InvalidDerivedCharge;
                diamonds += stack.count;
            } else if (prepared.view.kind == kind("minecraft:emerald")) {
                emeralds += stack.count;
            } else if (prepared.view.kind == kind("minecraft:gold_ingot")) {
                gold += stack.count;
            } else if (prepared.view.kind == kind("minecraft:diamond_pickaxe")) {
                tools += stack.count;
            } else if (prepared.view.kind == kind("minecraft:paper")) {
                if (prepared.view.value(.custom_data)) |bytes| {
                    const data = try vanilla.custom_data.Compound.init(bytes);
                    if (try data.getInt("charge") != 6) return error.IncorrectRemainingPaper;
                    wrong_paper += stack.count;
                } else plain_paper += stack.count;
            } else return error.UnexpectedInventoryItem;
        }
        if (diamonds != 2 or emeralds != 4 or gold != 3 or tools != 1 or plain_paper != 2 or wrong_paper != 2) return error.IncorrectCraftedInventory;
    }
};

fn kind(comptime name: []const u8) u32 {
    return @intCast(protocols.registry.itemId(name).?);
}
