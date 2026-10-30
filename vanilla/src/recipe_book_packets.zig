const crafting = @import("crafting.zig");
const std = @import("std");
const packets = @import("minecraft_packets");
const recipes = @import("recipes.zig");
const game_data = @import("game_data");
const data = @import("item_data.zig");
const item_packets = @import("item_packets.zig");
const Items = @import("items.zig").Items;
const inventories = @import("inventories");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_6 = @import("wire_1_21_6");
const wire_1_21_8 = @import("wire_1_21_8");
const wire_1_21_9 = @import("wire_1_21_9");
const wire_1_21_11 = @import("wire_1_21_11");
const wire_26_1 = @import("wire_26_1");
const wire_26_2 = @import("wire_26_2");

pub const Slot = union(enum) {
    empty,
    fuel,
    item: u32,
    stack: struct { view: data.View, count: u16 },
    composite: []const Slot,
    remainder: struct { input: *const Slot, remainder: *const Slot },
};
pub const Display = struct {
    ingredients: []const Slot,
    result: Slot,
    station: Slot,
    base_bytes: usize,
    stack_count: usize,

    pub fn maximumBytes(self: Display, component_bytes: usize) !usize {
        return std.math.add(usize, self.base_bytes, try std.math.mul(usize, self.stack_count, component_bytes));
    }
};
pub const Context = struct { table: *const recipes.BookTable, displays: []const Display, items: *Items, recipient: u128 };
const SlotArgs = struct { slot: *const Slot, registry: packets.Registry, context: Context };
const DisplayArgs = struct { id: usize, registry: packets.Registry, context: Context };
const slot_callbacks = .{ Codec(wire_1_21_5).slot, Codec(wire_1_21_6).slot, Codec(wire_1_21_8).slot, Codec(wire_1_21_9).slot, Codec(wire_1_21_11).slot, Codec(wire_26_1).slot, Codec(wire_26_2).slot };
const display_callbacks = .{ Codec(wire_1_21_5).display, Codec(wire_1_21_6).display, Codec(wire_1_21_8).display, Codec(wire_1_21_9).display, Codec(wire_1_21_11).display, Codec(wire_26_1).display, Codec(wire_26_2).display };
const writeSlot = packets.nested(slot_callbacks).write;
const writeDisplay = packets.nested(display_callbacks).write;
pub const add = .{ Codec(wire_1_21_5).add, Codec(wire_1_21_6).add, Codec(wire_1_21_8).add, Codec(wire_1_21_9).add, Codec(wire_1_21_11).add, Codec(wire_26_1).add, Codec(wire_26_2).add };
pub const ghost = .{ Codec(wire_1_21_5).ghost, Codec(wire_1_21_6).ghost, Codec(wire_1_21_8).ghost, Codec(wire_1_21_9).ghost, Codec(wire_1_21_11).ghost, Codec(wire_26_1).ghost, Codec(wire_26_2).ghost };
pub const settings = .{ Codec(wire_1_21_5).settings, Codec(wire_1_21_6).settings, Codec(wire_1_21_8).settings, Codec(wire_1_21_9).settings, Codec(wire_1_21_11).settings, Codec(wire_26_1).settings, Codec(wire_26_2).settings };
pub const properties = .{ Codec(wire_1_21_5).properties, Codec(wire_1_21_6).properties, Codec(wire_1_21_8).properties, Codec(wire_1_21_9).properties, Codec(wire_1_21_11).properties, Codec(wire_26_1).properties, Codec(wire_26_2).properties };
pub const remove = .{ Codec(wire_1_21_5).remove, Codec(wire_1_21_6).remove, Codec(wire_1_21_8).remove, Codec(wire_1_21_9).remove, Codec(wire_1_21_11).remove, Codec(wire_26_1).remove, Codec(wire_26_2).remove };

const IDsArgs = struct { ingredient: recipes.Ingredient, registry: packets.Registry, table: *const recipes.BookTable };
const writeIDs = packets.nested(.{encodeIDs}).write;
fn encodeIDs(packet: wire_1_21_5.IDSet.Writer, args: IDsArgs) !wire_1_21_5.IDSet.Writer.Done {
    const choices = args.table.alternatives[args.ingredient.offset..][0..args.ingredient.count];
    var count: usize = 0;
    for (choices) |kind| if (args.registry.items[kind] >= 0) {
        count += 1;
    };
    var values = try packet.ids(count);
    for (choices) |kind| if (args.registry.items[kind] >= 0) {
        values = try values.element(args.registry.items[kind]);
    };
    return values.finish();
}

const writeSetting = packets.nested(.{encodeSetting}).write;
fn encodeSetting(packet: wire_1_21_6.play.toClient.RecipeBookSetting.Writer, value: u8) !wire_1_21_6.play.toClient.RecipeBookSetting.Writer.Done {
    return (try packet.open(value & 1 != 0)).filtering(value & 2 != 0);
}

pub fn supported(slot: *const Slot, mapping: []const i32, items: *const Items, protocol: i32) bool {
    return switch (slot.*) {
        .empty, .fuel => true,
        .item => |kind| kind < mapping.len and mapping[kind] >= 0,
        .stack => |value| check: {
            if (value.view.kind >= mapping.len or mapping[value.view.kind] < 0) break :check false;
            var iterator = value.view.iterator();
            while (iterator.next()) |component| _ = items.components.dispatch.tagForKey(protocol, component.key) catch break :check false;
            break :check true;
        },
        .remainder => |value| supported(value.input, mapping, items, protocol) and supported(value.remainder, mapping, items, protocol),
        .composite => |values| for (values) |*value| {
            if (supported(value, mapping, items, protocol)) break true;
        } else false,
    };
}

pub fn available(display: Display, recipe: recipes.BookEntry, mapping: []const i32, items: *const Items, protocol: i32) bool {
    if (!supported(&display.result, mapping, items, protocol) or !supported(&display.station, mapping, items, protocol)) return false;
    for (display.ingredients, recipe.ingredients) |*slot, ingredient| {
        if (ingredient.ingredient.required and ingredient.ingredient.count == 0) return false;
        if (!supported(slot, mapping, items, protocol)) return false;
    }
    return true;
}

pub fn prepare(allocator: std.mem.Allocator, table: *const recipes.BookTable, items: *const Items) ![]const Display {
    const displays = try allocator.alloc(Display, table.book.len);
    for (table.book, displays) |entry, *display| {
        const ingredients = try allocator.alloc(Slot, entry.ingredients.len);
        var maximum: usize = 64;
        var stacks: usize = 1;
        for (entry.ingredients, ingredients) |input, *out| {
            const choices = table.alternatives[input.ingredient.offset..][0..input.ingredient.count];
            const variants = try allocator.alloc(Slot, choices.len);
            for (choices, variants) |kind, *variant| {
                variant.* = if (input.components.len == 0) .{ .item = kind } else try stack(allocator, items, .{ .kind = kind, .count = 1, .components = input.components });
                stacks += @intFromBool(input.components.len != 0);
                maximum += 16 + (try data.encodedSize(input.components)) * 2;
                if (table.remainders[kind]) |remainder| {
                    const original = try allocator.create(Slot);
                    original.* = variant.*;
                    const remaining = try allocator.create(Slot);
                    remaining.* = .{ .item = remainder };
                    variant.* = .{ .remainder = .{ .input = original, .remainder = remaining } };
                }
            }
            out.* = if (variants.len == 0) .empty else if (variants.len == 1) variants[0] else .{ .composite = variants };
        }
        display.* = .{
            .ingredients = ingredients,
            .result = try stack(allocator, items, entry.result),
            .station = .{ .item = @intCast(game_data.registry.itemId(if (entry.furnace) "minecraft:furnace" else "minecraft:crafting_table").?) },
            .stack_count = stacks,
            .base_bytes = maximum + (try data.encodedSize(entry.result.components)) * 2 + 64,
        };
    }
    return displays;
}

fn stack(allocator: std.mem.Allocator, items: *const Items, draft: crafting.Draft) !Slot {
    if (draft.count == 0 or draft.count > try items.maximumDefinition(draft.kind, draft.components)) return error.InvalidRecipeDisplay;
    return .{ .stack = .{ .count = draft.count, .view = try data.encode(try allocator.alloc(u8, try data.encodedSize(draft.components)), draft.kind, draft.components) } };
}

fn Codec(comptime Wire: type) type {
    return struct {
        const SlotTag = Wire.play.toClient.SlotDisplay.cases.data.Tag;
        const RecipeTag = Wire.play.toClient.RecipeDisplay.cases.data.Tag;
        fn slot(packet: Wire.play.toClient.SlotDisplay.Writer, args: SlotArgs) anyerror!Wire.play.toClient.SlotDisplay.Writer.Done {
            switch (args.slot.*) {
                .empty => {
                    var choice = try (try packet.type(@intCast(@intFromEnum(SlotTag.empty)))).data();
                    return choice.advance(try (try choice.begin()).case_empty());
                },
                .fuel => {
                    var choice = try (try packet.type(@intCast(@intFromEnum(SlotTag.any_fuel)))).data();
                    return choice.advance(try (try choice.begin()).case_any_fuel());
                },
                .item => |kind| {
                    var choice = try (try packet.type(@intCast(@intFromEnum(SlotTag.item)))).data();
                    return choice.advance(try (try choice.begin()).case_item(try args.registry.itemId(@intCast(kind))));
                },
                .stack => |value| {
                    var choice = try (try packet.type(@intCast(@intFromEnum(SlotTag.item_stack)))).data();
                    var item = try (try choice.begin()).case_item_stack();
                    const writer = if (comptime std.mem.eql(u8, @TypeOf(try item.begin()).wire_type_name, "ItemStackTemplate")) item_packets.writeTemplate else item_packets.writeSlot;
                    const done = try writer(try item.begin(), .{
                        .registry = args.registry,
                        .items = args.context.items,
                        .stack = .{ .item = data.defaultId(value.view.kind), .count = value.count },
                        .view = value.view,
                        .recipient = args.context.recipient,
                    });
                    return choice.advance(try item.advance(done));
                },
                .composite => |values| {
                    var choice = try (try packet.type(@intCast(@intFromEnum(SlotTag.composite)))).data();
                    var count: usize = 0;
                    for (values) |*value| if (supported(value, args.registry.items, args.context.items, packet._cursor.protocol_number)) {
                        count += 1;
                    };
                    var values_packet = try (try choice.begin()).case_composite(count);
                    for (values) |*value| {
                        if (!supported(value, args.registry.items, args.context.items, packet._cursor.protocol_number)) continue;
                        const entry = (try values_packet.next()).?;
                        try values_packet.advance(try writeSlot(entry, .{ .slot = value, .registry = args.registry, .context = args.context }));
                    }
                    return choice.advance(try values_packet.finish());
                },
                .remainder => |value| {
                    var choice = try (try packet.type(@intCast(@intFromEnum(SlotTag.with_remainder)))).data();
                    var body = try (try choice.begin()).case_with_remainder();
                    var input = try (try body.begin()).input();
                    const after_input = try input.advance(try writeSlot(try input.begin(), .{ .slot = value.input, .registry = args.registry, .context = args.context }));
                    var remaining = try after_input.remainder();
                    return choice.advance(try body.advance(try remaining.advance(try writeSlot(try remaining.begin(), .{ .slot = value.remainder, .registry = args.registry, .context = args.context }))));
                },
            }
        }

        fn display(packet: Wire.play.toClient.RecipeDisplay.Writer, args: DisplayArgs) anyerror!Wire.play.toClient.RecipeDisplay.Writer.Done {
            const recipe = args.context.table.book[args.id];
            const slots = args.context.displays[args.id];
            if (recipe.furnace) {
                var choice = try (try packet.type(@intCast(@intFromEnum(RecipeTag.furnace)))).data();
                var body = try (try choice.begin()).case_furnace();
                var input = try (try body.begin()).ingredient();
                const fuel_start = try input.advance(try writeSlot(try input.begin(), .{ .slot = &slots.ingredients[0], .registry = args.registry, .context = args.context }));
                var fuel = try fuel_start.fuel();
                const fuel_slot: Slot = .fuel;
                const result_start = try fuel.advance(try writeSlot(try fuel.begin(), .{ .slot = &fuel_slot, .registry = args.registry, .context = args.context }));
                var result = try result_start.result();
                const station_start = try result.advance(try writeSlot(try result.begin(), .{ .slot = &slots.result, .registry = args.registry, .context = args.context }));
                var station = try station_start.craftingStation();
                const end = try station.advance(try writeSlot(try station.begin(), .{ .slot = &slots.station, .registry = args.registry, .context = args.context }));
                return choice.advance(try body.advance(try (try end.duration(@intCast(recipe.ticks))).experience(recipe.experience)));
            }
            if (recipe.width == 0) {
                var choice = try (try packet.type(@intCast(@intFromEnum(RecipeTag.crafting_shapeless)))).data();
                var body = try (try choice.begin()).case_crafting_shapeless();
                var ingredients = try (try body.begin()).ingredients(slots.ingredients.len);
                for (slots.ingredients) |*value| {
                    const entry = (try ingredients.next()).?;
                    try ingredients.advance(try writeSlot(entry, .{ .slot = value, .registry = args.registry, .context = args.context }));
                }
                var result = try (try ingredients.finish()).result();
                const station_start = try result.advance(try writeSlot(try result.begin(), .{ .slot = &slots.result, .registry = args.registry, .context = args.context }));
                var station = try station_start.craftingStation();
                return choice.advance(try body.advance(try station.advance(try writeSlot(try station.begin(), .{ .slot = &slots.station, .registry = args.registry, .context = args.context }))));
            }
            var choice = try (try packet.type(@intCast(@intFromEnum(RecipeTag.crafting_shaped)))).data();
            var body = try (try choice.begin()).case_crafting_shaped();
            const shape = try (try (try body.begin()).width(recipe.width)).height(recipe.height);
            var ingredients = try shape.ingredients(slots.ingredients.len);
            for (slots.ingredients) |*value| {
                const entry = (try ingredients.next()).?;
                try ingredients.advance(try writeSlot(entry, .{ .slot = value, .registry = args.registry, .context = args.context }));
            }
            var result = try (try ingredients.finish()).result();
            const station_start = try result.advance(try writeSlot(try result.begin(), .{ .slot = &slots.result, .registry = args.registry, .context = args.context }));
            var station = try station_start.craftingStation();
            return choice.advance(try body.advance(try station.advance(try writeSlot(try station.begin(), .{ .slot = &slots.station, .registry = args.registry, .context = args.context }))));
        }

        pub fn add(packet: Wire.play.toClient.packet_recipe_book_add.Writer, registry: packets.Registry, context: Context, ids: []const u32, entry_flags: []const u8, replace: bool) ![]u8 {
            std.debug.assert(ids.len == entry_flags.len);
            var entries = try packet.entries(ids.len);
            for (ids, entry_flags) |id, flags_value| {
                const recipe = context.table.book[id];
                var value = try (try entries.next()).?.recipe();
                const display_packet = try (try value.begin()).displayId(@intCast(id));
                var display_child = try display_packet.display();
                const after_display = try display_child.advance(try writeDisplay(try display_child.begin(), .{ .id = id, .registry = registry, .context = context }));
                const grouped = try after_display.group(recipe.group_id);
                var requirements = try (try grouped.category(@intCast(@intFromEnum(recipe.category)))).craftingRequirements();
                const optional = try requirements.begin();
                var requirement_count: usize = 0;
                for (recipe.ingredients) |ingredient| if (ingredient.ingredient.required or ingredient.ingredient.count != 0) {
                    requirement_count += 1;
                };
                var required = try optional.some(requirement_count);
                for (recipe.ingredients) |ingredient| {
                    if (!ingredient.ingredient.required and ingredient.ingredient.count == 0) continue;
                    const target = (try required.next()).?;
                    try required.advance(try writeIDs(target, .{ .ingredient = ingredient.ingredient, .registry = registry, .table = context.table }));
                }
                const completed = try required.finish();
                const flags = try value.advance(try requirements.advance(completed));
                try entries.advance(try flags.flags(.{ .notification = flags_value & 1 != 0 and recipe.show_notification, .highlight = flags_value & 2 != 0 }));
            }
            return (try (try entries.finish()).replace(replace)).finish();
        }

        pub fn ghost(packet: Wire.play.toClient.packet_craft_recipe_response.Writer, registry: packets.Registry, context: Context, window: i32, id: usize) ![]u8 {
            var child = try (try packet.windowId(@intCast(window))).recipeDisplay();
            return (try child.advance(try writeDisplay(try child.begin(), .{ .id = id, .registry = registry, .context = context }))).finish();
        }

        pub fn settings(packet: Wire.play.toClient.packet_recipe_book_settings.Writer, value: u8) ![]u8 {
            if (comptime @hasDecl(Wire.play.toClient.packet_recipe_book_settings.Writer, "craftingGuiOpen")) {
                return (try (try (try (try (try (try (try (try packet.craftingGuiOpen(value & 1 != 0)).craftingFilteringCraftable(value & 2 != 0)).smeltingGuiOpen(value & 4 != 0)).smeltingFilteringCraftable(value & 8 != 0)).blastGuiOpen(value & 16 != 0)).blastFilteringCraftable(value & 32 != 0)).smokerGuiOpen(value & 64 != 0)).smokerFilteringCraftable(value & 128 != 0)).finish();
            }
            var crafting_settings = try packet.crafting();
            var furnace = try (try crafting_settings.advance(try writeSetting(try crafting_settings.begin(), value & 3))).furnace();
            var blast = try (try furnace.advance(try writeSetting(try furnace.begin(), (value >> 2) & 3))).blast();
            var smoker = try (try blast.advance(try writeSetting(try blast.begin(), (value >> 4) & 3))).smoker();
            return (try smoker.advance(try writeSetting(try smoker.begin(), (value >> 6) & 3))).finish();
        }

        pub fn remove(packet: Wire.play.toClient.packet_recipe_book_remove.Writer, ids: []const u32) ![]u8 {
            var values = try packet.recipeIds(ids.len);
            for (ids) |id| values = try values.element(@intCast(id));
            return (try values.finish()).finish();
        }

        pub fn properties(packet: Wire.play.toClient.packet_declare_recipes.Writer, registry: packets.Registry, table: *const recipes.BookTable) ![]u8 {
            var values = try packet.recipes(1);
            const entry = (try values.next()).?;
            var count: usize = 0;
            for (table.cooking, 0..) |recipe, id| if (recipe != null and registry.items[id] >= 0) {
                count += 1;
            };
            var inputs = try (try entry.name("minecraft:furnace_input")).items(count);
            for (table.cooking, 0..) |recipe, id| if (recipe != null and registry.items[id] >= 0) {
                inputs = try inputs.element(registry.items[id]);
            };
            try values.advance(try inputs.finish());
            return (try (try (try values.finish()).stoneCutterRecipes(0)).finish()).finish();
        }
    };
}
