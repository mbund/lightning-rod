const std = @import("std");
const datapacks = @import("datapacks");
const pack_formats = @import("datapack_formats.zig");
const provider = @import("definition_provider.zig");
const types = @import("content_types.zig");
const decoder = @import("datapack_decoder.zig");
const filters = @import("datapack_filters.zig");
const handlers = @import("datapack_handlers.zig");

pub const Datapacks = struct {
    pub const id = "minecraft:datapacks";
    pub const Dependencies = provider.Dependencies;
    pub const Configuration = struct { sources: []const datapacks.Source = &.{}, limits: datapacks.Limits = .{} };
    pub const Registration = struct {
        sources: []const datapacks.Source = &.{},
        recipe_types: []const handlers.RecipeType = &.{},
        loot_types: []const handlers.LootType = &.{},
    };
    pub const Recipe = handlers.Recipe;
    pub const Loot = handlers.Loot;
    pub const Source = datapacks.Source;
    pub const formats = pack_formats.supported;
    const State = struct {
        memory: std.heap.ArenaAllocator,
        resources: datapacks.Resources,
        recipe_types: []const handlers.RecipeType,
        loot_types: []const handlers.LootType,
    };
    allocator: std.mem.Allocator,
    io: std.Io,
    limits: datapacks.Limits,
    deps: Dependencies,
    source: ?provider.Sources = null,
    state: ?*State = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Datapacks {
        const self = try allocator.create(Datapacks);
        self.* = .{ .allocator = allocator, .io = io, .limits = configuration.limits, .deps = deps };
        if (configuration.sources.len > 0) try self.add(.{ .sources = configuration.sources });
        return self;
    }

    pub fn add(self: *Datapacks, registration: Registration) !void {
        const next = try self.allocator.create(State);
        next.* = .{ .memory = .init(self.allocator), .resources = undefined, .recipe_types = &.{}, .loot_types = &.{} };
        var committed = false;
        errdefer if (!committed) {
            next.memory.deinit();
            self.allocator.destroy(next);
        };
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const allocator = next.memory.allocator();
        var builder = datapacks.Builder.init(allocator, scratch.allocator(), self.limits);
        if (self.state) |previous| try builder.inherit(&previous.resources, &.{});
        builder.formats = &formats;
        for (registration.sources) |source| try builder.load(self.io, source);
        if (builder.filters.items.len != 0) try builder.exclude(try filters.resources(self.deps, scratch.allocator()));
        next.resources = try builder.finish();
        var recipes: std.ArrayList(handlers.RecipeType) = .empty;
        var loot: std.ArrayList(handlers.LootType) = .empty;
        if (self.state) |previous| {
            try recipes.appendSlice(scratch.allocator(), previous.recipe_types);
            try loot.appendSlice(scratch.allocator(), previous.loot_types);
        }
        for (registration.recipe_types) |implementation| {
            for (recipes.items) |previous| if (std.mem.eql(u8, previous.name, implementation.name)) return error.DuplicateRecipeType;
            try recipes.append(scratch.allocator(), implementation);
        }
        for (registration.loot_types) |implementation| {
            for (loot.items) |previous| if (previous.kind == implementation.kind and std.mem.eql(u8, previous.name, implementation.name)) return error.DuplicateLootType;
            try loot.append(scratch.allocator(), implementation);
        }
        next.recipe_types = try allocator.dupe(handlers.RecipeType, recipes.items);
        next.loot_types = try allocator.dupe(handlers.LootType, loot.items);
        if (next.resources.index.count() != 0 or next.resources.excluded.len != 0 or self.source != null) {
            const definitions = if (next.resources.index.count() == 0) types.Definitions{} else try decoder.decode(scratch.allocator(), scratch.allocator(), &next.resources, .{ .recipe_types = next.recipe_types, .loot_types = next.loot_types });
            self.source = try provider.registerExcluded(self.deps, scratch.allocator(), definitions, self.source, try filters.exclusions(self.deps, scratch.allocator(), next.resources.excluded));
        }
        committed = true;
        if (self.state) |previous| {
            previous.memory.deinit();
            self.allocator.destroy(previous);
        }
        self.state = next;
    }
};
