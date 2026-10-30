const smelting = @import("smelting.zig");
const fuel = @import("fuel.zig");
const Items = @import("items.zig").Items;
const inventories = @import("inventories");
const item_data = @import("item_data.zig");
const crafting = @import("crafting.zig");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const game_data = @import("game_data");
const registry = @import("registry.zig");
const recipes = @import("recipes.zig");
const ItemRegistry = @import("item_registry.zig").ItemRegistry;

pub const Furnaces = struct {
    pub const id = "minecraft:furnaces";
    pub const Definitions = struct { recipes: []const recipes.Entry = &.{}, fuels: []const recipes.FuelDefinition = &.{}, fuel_conversions: []const recipes.FuelConversionDefinition = &.{} };
    pub const Data = struct { table: recipes.FurnaceTable };
    pub const Dependencies = struct { items: *ItemRegistry };
    pub const Configuration = registry.Registry(Furnaces).Configuration;
    registry: registry.Registry(Furnaces),
    deps: Dependencies,
    table: recipes.FurnaceTable,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Furnaces {
        const self = try allocator.create(Furnaces);
        self.deps = deps;
        try registry.Registry(Furnaces).init(self, allocator, configuration);
        try deps.items.registry.onChange(self, refresh);
        return self;
    }
    pub fn addFuels(self: *Furnaces, entries: []const recipes.FuelDefinition) !void {
        try self.registry.add(.{ .fuels = entries });
    }
    pub fn addRecipes(self: *Furnaces, entries: []const recipes.Entry) !void {
        try self.registry.add(.{ .recipes = entries });
    }
    pub fn addDefinitions(self: *Furnaces, definitions: Definitions) !void {
        try self.registry.add(definitions);
    }
    fn refresh(self: *Furnaces) !void {
        try self.registry.refresh();
    }
    pub fn compile(self: *Furnaces, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        for (definitions.recipes) |entry| {
            if (entry.definition != .smelting) return error.InvalidSmeltingRecipe;
        }
        const table = try recipes.prepare(allocator, scratch, &self.deps.items.tags, game_data.registry.item_names, .{ .fuels = definitions.fuels, .fuel_conversions = definitions.fuel_conversions, .mode = .furnace, .properties = self.deps.items.properties, .item_remainders = self.deps.items.remainders }, definitions.recipes);
        return .{ .table = table.furnaceTable() };
    }
    pub fn prepareSmelting(self: *const Furnaces, items: *Items, location: fuel.Location, stacks: [3]?inventories.Stack, scratch: *std.heap.FixedBufferAllocator) !smelting.Selection {
        const input = stacks[0] orelse return .{};
        const pinned = try items.acquire(input);
        const kind = pinned.view.kind;
        const variants = if (self.table.variants.len == 0) &.{} else self.table.variants[kind];
        if (variants.len == 0) {
            pinned.release();
            const recipe = self.table.recipes[kind] orelse return .{ .input_kind = kind };
            std.debug.assert(recipe.callback == null);
            return .{ .input_kind = kind, .recipe = standardSmelting(recipe) };
        }
        var prepared: smelting.Prepared = .{
            .plan = undefined,
            .result = undefined,
            .maximum = 0,
            .index = 0,
            .dynamic = true,
            .count = 1,
        };
        prepared.pins[0] = pinned;
        var transferred = false;
        defer if (!transferred) prepared.release();
        var others: [2]inventories.Stack = undefined;
        var count: usize = 0;
        for (stacks[1..3]) |stack| if (stack) |value| {
            others[count] = value;
            count += 1;
        };
        try items.acquireMany(others[0..count], prepared.pins[1 .. 1 + count]);
        prepared.count += count;
        var fuel_view: ?crafting.Input = null;
        var output_view: ?crafting.Input = null;
        var at: usize = 1;
        if (stacks[1]) |stack| {
            fuel_view = .{ .stack = stack, .view = prepared.pins[at].view };
            at += 1;
        }
        if (stacks[2]) |stack| output_view = .{ .stack = stack, .view = prepared.pins[at].view };
        for (variants) |recipe| {
            const start = scratch.end_index;
            const context: smelting.Context = .{
                .world = location.world,
                .position = location.position,
                .input = .{ .stack = input, .view = pinned.view },
                .fuel = fuel_view,
                .output = output_view,
                .standard = standardSmelting(recipe).plan,
                .scratch = scratch,
            };
            const plan = try recipe.callback.?.call(&context) orelse {
                scratch.end_index = start;
                continue;
            };
            try smelting.validate(plan);
            if (plan.consume > input.count) {
                scratch.end_index = start;
                continue;
            }
            const maximum = try items.maximumDefinition(plan.result.kind, plan.result.components);
            if (plan.result.count > maximum or try item_data.encodedSize(plan.result.components) > items.deps.inventories.config.max_item_bytes) return error.InvalidSmeltingPlan;
            prepared.plan = plan;
            prepared.result = .{ .item = try item_data.identity(plan.result.kind, plan.result.components), .count = plan.result.count };
            prepared.maximum = maximum;
            prepared.index = recipe.index;
            transferred = true;
            return .{ .input_kind = kind, .recipe = prepared };
        }
        const fallback = self.table.recipes[kind] orelse return .{ .input_kind = kind };
        if (fallback.callback != null) return .{ .input_kind = kind };
        return .{ .input_kind = kind, .recipe = standardSmelting(fallback) };
    }

    fn standardSmelting(recipe: recipes.Recipe) smelting.Prepared {
        return .{
            .plan = .{ .result = .{ .kind = recipe.output, .count = recipe.count, .components = recipe.components }, .ticks = recipe.ticks, .experience = recipe.experience },
            .result = .{ .item = recipe.item_id, .count = recipe.count },
            .maximum = recipe.stack_limit,
            .index = recipe.index,
            .dynamic = false,
        };
    }

    pub fn fuelProperties(self: *const Furnaces, items: *Items, request: fuel.Request, scratch: *std.heap.FixedBufferAllocator) !fuel.Properties {
        const result = try self.prepareFuel(false, items, request, scratch);
        return if (result) |value| value.properties else .{};
    }

    pub fn insertFuel(self: *const Furnaces, items: *Items, request: fuel.Request, scratch: *std.heap.FixedBufferAllocator) !?fuel.Prepared {
        std.debug.assert(request.phase == .insertion);
        return self.prepareFuel(true, items, request, scratch);
    }

    pub fn burnFuel(self: *const Furnaces, items: *Items, request: fuel.Request, scratch: *std.heap.FixedBufferAllocator) !fuel.Prepared {
        std.debug.assert(request.phase == .burn and request.player == null);
        return (try self.prepareFuel(true, items, request, scratch)) orelse .{ .remaining = request.stacks[1] };
    }

    fn prepareFuel(self: *const Furnaces, comptime apply: bool, items: *Items, request: fuel.Request, scratch: *std.heap.FixedBufferAllocator) !?fuel.Prepared {
        const stack = request.stacks[1] orelse return .{ .remaining = null };
        const loaded = try items.acquire(stack);
        const kind = loaded.view.kind;
        const properties = self.table.fuels[kind];
        const standard: fuel.Properties = .{ .ticks = properties.ticks, .slot_limit = properties.slot_limit };
        if (properties.callback) |callback| {
            defer loaded.release();
            if (items.views.len < fuel.minimum_cache_items) return error.InventoryCacheTooSmall;
            const start = scratch.end_index;
            defer scratch.end_index = start;
            var stacks: [3]inventories.Stack = undefined;
            var count: usize = 0;
            for ([_]?inventories.Stack{ request.stacks[0], request.stacks[2], request.previous }) |input| {
                if (input) |value| {
                    stacks[count] = value;
                    count += 1;
                }
            }
            var prepared: [3]Items.Prepared = undefined;
            try items.acquireMany(stacks[0..count], prepared[0..count]);
            defer for (prepared[0..count]) |value| value.release();
            var views: [3]?crafting.Input = @splat(null);
            var at: usize = 0;
            for ([_]?inventories.Stack{ request.stacks[0], request.stacks[2], request.previous }, &views) |input, *view| {
                if (input) |value| {
                    view.* = .{ .stack = value, .view = prepared[at].view };
                    at += 1;
                }
            }
            const context: fuel.Context = .{
                .phase = request.phase,
                .player = request.player,
                .location = request.location,
                .fuel = .{ .stack = stack, .view = loaded.view },
                .input = views[0],
                .output = views[1],
                .previous = views[2],
                .standard = standard,
                .tags = &self.deps.items.tags,
                .scratch = scratch,
            };
            const plan = try fuel.prepare(callback.*, &context) orelse return null;
            return try self.finishFuel(apply, items, request, kind, plan);
        }
        loaded.release();
        return try self.finishFuel(apply, items, request, kind, .{ .properties = standard });
    }

    fn finishFuel(self: *const Furnaces, comptime apply: bool, items: *Items, request: fuel.Request, kind: u32, plan: fuel.Plan) !fuel.Prepared {
        const stack = request.stacks[1].?;
        var result: fuel.Prepared = .{ .properties = plan.properties, .remaining = stack };
        if (!apply or (request.phase == .burn and plan.properties.ticks == 0)) return result;
        switch (plan.replacement) {
            .stack => |draft| {
                if (draft.count > try items.maximumDefinition(draft.kind, draft.components)) return error.InvalidFuelReplacement;
                result.remaining = .{ .item = try item_data.define(items.deps.inventories, draft.kind, draft.components), .count = draft.count };
            },
            .clear => result.remaining = null,
            .normal => if (request.phase == .burn) {
                result.remaining = if (stack.count > 1) .{ .item = stack.item, .count = stack.count - 1 } else if (self.table.remainders[kind]) |remainder| .{
                    .item = try items.defineKind(remainder),
                    .count = 1,
                } else null;
            },
        }
        return result;
    }

    pub fn close(self: *Furnaces, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
