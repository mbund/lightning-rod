const std = @import("std");
const commands = @import("commands");
const storage = @import("storage");
const RecipeBook = @import("recipe_book.zig").RecipeBook;
const Players = @import("players.zig").Players;
const Random = @import("random.zig").Random;

pub const RecipeCommands = struct {
    pub const id = "minecraft:recipe_commands";
    pub const Configuration = struct { seed: u64 = 0x72656369706573 };
    pub const Dependencies = struct { commands: *commands.Commands, players: *Players, book: *RecipeBook, storage: storage.Space };
    pub const permission: commands.Permission = .{ .name = "minecraft.command.recipe", .description = "Grant or revoke player recipes" };
    const Action = enum { give, take };
    const Arguments = struct { action: Action, target: []const u8, recipe: []const u8 };
    deps: Dependencies,
    random: Random,
    targets: []usize,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*RecipeCommands {
        const self = try allocate(allocator, config, deps);
        self.random = try Random.init(config.seed, deps.storage);
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*RecipeCommands {
        const self = try allocator.create(RecipeCommands);
        self.* = .{
            .deps = deps,
            .random = .{ .source = .init(config.seed) },
            .targets = try allocator.alloc(usize, deps.players.records.len),
        };
        _ = try deps.commands.register(self, commands.leaf(RecipeCommands, Arguments, .{
            .name = "recipe",
            .description = "Grant or revoke recipes",
            .permission = &permission,
            .handler = execute,
            .arguments = .{ .action = .{}, .target = .{ .kind = .players, .suggest = suggestPlayers }, .recipe = .{ .suggest = suggestRecipes } },
        }));
        return self;
    }

    pub fn checkpoint(self: *RecipeCommands, space: storage.Space) !void {
        try self.random.checkpoint(space);
    }

    fn execute(self: *RecipeCommands, context: commands.Context, args: Arguments) !void {
        const sender = self.deps.players.find(context.sender) orelse return error.InvalidArgument;
        const selector = args.target.len == 2 and args.target[0] == '@';
        if (std.mem.startsWith(u8, args.target, "@") and (!selector or std.mem.indexOfScalar(u8, "aspr", args.target[1]) == null)) return error.InvalidArgument;
        var uuid: ?u128 = null;
        if (args.target.len == 36) {
            var digits: [32]u8 = undefined;
            var offset: usize = 0;
            for (args.target, 0..) |byte, index| {
                if (index == 8 or index == 13 or index == 18 or index == 23) {
                    if (byte != '-') return error.InvalidArgument;
                } else {
                    digits[offset] = byte;
                    offset += 1;
                }
            }
            uuid = std.fmt.parseInt(u128, &digits, 16) catch return error.InvalidArgument;
        }
        var target_count: usize = 0;
        var nearest: f64 = std.math.inf(f64);
        var candidates: u64 = 0;
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            if (!player.inWorld()) continue;
            if (selector) {
                if (args.target[1] == 's' and player.uuid != sender.uuid) continue;
                if (args.target[1] == 'p') {
                    if (player.world != sender.world) continue;
                    const dx = player.position.x - sender.position.x;
                    const dy = player.position.y - sender.position.y;
                    const dz = player.position.z - sender.position.z;
                    const distance = dx * dx + dy * dy + dz * dz;
                    if (distance >= nearest) continue;
                    nearest = distance;
                    self.targets[0] = index;
                    target_count = 1;
                    continue;
                }
                if (args.target[1] == 'r') {
                    candidates += 1;
                    if (self.random.source.random().uintLessThan(u64, candidates) == 0) {
                        self.targets[0] = index;
                        target_count = 1;
                    }
                    continue;
                }
            } else if (uuid) |value| {
                if (player.uuid != value) continue;
            } else if (!std.ascii.eqlIgnoreCase(player.name[0..player.name_len], args.target)) continue;
            self.targets[target_count] = index;
            target_count += 1;
        }
        if (target_count == 0) {
            context.reply("No player was found");
            return;
        }
        const recipe: ?u32 = if (std.mem.eql(u8, args.recipe, "*")) null else self.deps.book.recipeId(args.recipe) orelse return error.InvalidArgument;
        for (self.targets[0..target_count]) |index| {
            if (recipe) |single| switch (args.action) {
                .give => try self.deps.book.grantMany(index, &.{single}),
                .take => try self.deps.book.revokeMany(index, &.{single}),
            } else switch (args.action) {
                .give => try self.deps.book.grantAll(index),
                .take => try self.deps.book.revokeAll(index),
            }
        }
        context.reply(if (args.action == .give) "Recipes granted" else "Recipes revoked");
    }

    fn suggestPlayers(self: *RecipeCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        for ([_][]const u8{ "@a", "@p", "@r", "@s" }) |selector| if (std.mem.startsWith(u8, selector, context.prefix)) {
            output.add(.{ .text = selector }) catch return;
        };
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            const name = player.name[0..player.name_len];
            if (player.inWorld() and std.ascii.startsWithIgnoreCase(name, context.prefix)) output.add(.{ .text = name }) catch return;
        }
    }
    fn suggestRecipes(self: *RecipeCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        if (std.mem.startsWith(u8, "*", context.prefix)) output.add(.{ .text = "*" }) catch return;
        for (self.deps.book.deps.definitions.table.book) |entry| if (std.mem.startsWith(u8, entry.name, context.prefix)) {
            output.add(.{ .text = entry.name }) catch return;
        };
    }
};
