const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const vanilla_time = lightning_rod.time;
const world_random = lightning_rod.random;
const world_clock = lightning_rod.clock;
const std = @import("std");
const commands = lightning_rod.commands;
const Packets = lightning_rod.Packets;

pub const Commands = struct {
    pub const id = "minecraft:commands";
    pub const command_declarations = declarations;

    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, clock: *world_clock.Clock, time: *vanilla_time.Time, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities, outputs: *Packets) !*Commands {
        const self = try allocator.create(Commands);
        self.* = .{ .clock = clock, .time = time, .random = random, .blocks = blocks, .players = players, .living = living, .outputs = outputs };
        return self;
    }

    pub fn tick(self: *Commands, _: std.mem.Allocator) void {
        self.run(self.clock, self.time, self.random, self.blocks, self.players, self.living, self.outputs, &self.outputs.commands);
    }

    fn run(_: *Commands, clock: *world_clock.Clock, time: *vanilla_time.Time, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities, outputs: *Packets, command_batch: *commands.Batch) void {
        for (command_batch.items()) |*entry| {
            if (entry.handled) continue;
            var words = std.mem.tokenizeScalar(u8, entry.text, ' ');
            const name = words.next() orelse continue;
            if (std.mem.eql(u8, name, "reload"))
                reload(outputs, entry, &words)
            else if (std.mem.eql(u8, name, "summon"))
                summon(random, blocks, players, living, outputs, entry, &words)
            else if (std.mem.eql(u8, name, "time"))
                timeCommand(clock, time, outputs, entry, &words)
            else if (std.mem.eql(u8, name, "gamemode"))
                gamemode(players, outputs, entry, &words);
        }
    }

    fn reload(outputs: *Packets, entry: *commands.Entry, words: *std.mem.TokenIterator(u8, .scalar)) void {
        entry.handled = true;
        if (words.next() != null) return outputs.system(entry.sender, "Usage: /reload", .{});
        outputs.request_reload(entry.sender);
        outputs.system(entry.sender, "Reloading server...", .{});
    }

    fn summon(random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities, outputs: *Packets, entry: *commands.Entry, words: *std.mem.TokenIterator(u8, .scalar)) void {
        entry.handled = true;
        const name = words.next() orelse return summonUsage(outputs, entry.sender);
        const kind = entityType(name) orelse return summonUsage(outputs, entry.sender);
        if (words.next() != null) return summonUsage(outputs, entry.sender);
        const player = &players.records[entry.sender];
        const handle = living.spawn(random, blocks, player.world, kind, player.position, false, false) catch
            return outputs.system(entry.sender, "Unable to summon entity: entity capacity reached", .{});
        outputs.living_spawned(handle.index);
        outputs.system(entry.sender, "Summoned {s}", .{@tagName(kind)});
    }

    fn timeCommand(clock: *world_clock.Clock, time: *vanilla_time.Time, outputs: *Packets, entry: *commands.Entry, words: *std.mem.TokenIterator(u8, .scalar)) void {
        entry.handled = true;
        const operation = words.next() orelse return timeUsage(outputs, entry.sender);
        const argument = words.next() orelse return timeUsage(outputs, entry.sender);
        if (words.next() != null) return timeUsage(outputs, entry.sender);
        if (std.mem.eql(u8, operation, "query")) return queryTime(clock, time, outputs, entry.sender, argument);
        const value = parseTime(argument) orelse return outputs.system(entry.sender, "Invalid time value", .{});
        if (std.mem.eql(u8, operation, "set")) {
            time.day_time = value;
            outputs.time_changed();
            return outputs.system(entry.sender, "Set the time to {d}", .{value});
        }
        if (!std.mem.eql(u8, operation, "add")) return timeUsage(outputs, entry.sender);
        time.day_time +|= value;
        outputs.time_changed();
        outputs.system(entry.sender, "Added {d} to the time", .{value});
    }

    fn gamemode(players: *player_store.Players, outputs: *Packets, entry: *commands.Entry, words: *std.mem.TokenIterator(u8, .scalar)) void {
        entry.handled = true;
        const name = words.next() orelse return gamemodeUsage(outputs, entry.sender);
        if (words.next() != null) return gamemodeUsage(outputs, entry.sender);
        const mode = parseGamemode(name) orelse return outputs.system(entry.sender, "Unknown gamemode", .{});
        players.records[entry.sender].gamemode = mode;
        outputs.gamemode_changed(.{ .slot = entry.sender, .value = mode });
        outputs.system(entry.sender, "Set own game mode to {s}", .{@tagName(mode)});
    }

    fn queryTime(clock: *const world_clock.Clock, time: *const vanilla_time.Time, outputs: *Packets, sender: u16, argument: []const u8) void {
        const value = if (std.mem.eql(u8, argument, "daytime"))
            time.day_time % 24_000
        else if (std.mem.eql(u8, argument, "gametime"))
            clock.tick
        else if (std.mem.eql(u8, argument, "day"))
            time.day_time / 24_000
        else
            return outputs.system(sender, "Usage: /time query <daytime|gametime|day>", .{});
        outputs.system(sender, "The time is {d}", .{value});
    }

    fn entityType(name: []const u8) ?living_entities.EntityType {
        if (std.mem.eql(u8, name, "zombie") or std.mem.eql(u8, name, "minecraft:zombie")) return .zombie;
        if (std.mem.eql(u8, name, "cow") or std.mem.eql(u8, name, "minecraft:cow")) return .cow;
        if (std.mem.eql(u8, name, "pig") or std.mem.eql(u8, name, "minecraft:pig")) return .pig;
        return null;
    }

    fn parseGamemode(name: []const u8) ?player_store.GameMode {
        if (std.mem.eql(u8, name, "survival")) return .survival;
        if (std.mem.eql(u8, name, "creative")) return .creative;
        if (std.mem.eql(u8, name, "adventure")) return .adventure;
        if (std.mem.eql(u8, name, "spectator")) return .spectator;
        return null;
    }

    fn summonUsage(outputs: *Packets, sender: u16) void {
        outputs.system(sender, "Usage: /summon <zombie|cow|pig>", .{});
    }

    fn timeUsage(outputs: *Packets, sender: u16) void {
        outputs.system(sender, "Usage: /time <set|add|query> <value>", .{});
    }

    fn gamemodeUsage(outputs: *Packets, sender: u16) void {
        outputs.system(sender, "Usage: /gamemode <survival|creative|adventure|spectator>", .{});
    }
};

pub const UnknownCommands = struct {
    pub const id = "minecraft:unknown_commands";

    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, outputs: *Packets) !*UnknownCommands {
        const self = try allocator.create(UnknownCommands);
        self.* = .{ .outputs = outputs };
        return self;
    }

    pub fn tick(self: *UnknownCommands, _: std.mem.Allocator) void {
        const outputs = self.outputs;
        const command_batch = &outputs.commands;
        for (command_batch.items()) |*entry| {
            if (entry.handled) continue;
            entry.handled = true;
            outputs.system(entry.sender, "Unknown command", .{});
        }
    }
};

const declarations = [_]commands.Declaration{
    .{ .name = "gamemode", .alternatives = &.{ "survival", "creative", "adventure", "spectator" } },
    .{ .name = "summon", .alternatives = &.{ "zombie", "cow", "pig" } },
    .{ .name = "time", .greedy_argument = "operation" },
    .{ .name = "reload", .alternatives = &.{} },
};

fn parseTime(value: []const u8) ?u64 {
    if (std.mem.eql(u8, value, "day")) return 1_000;
    if (std.mem.eql(u8, value, "noon")) return 6_000;
    if (std.mem.eql(u8, value, "night")) return 13_000;
    if (std.mem.eql(u8, value, "midnight")) return 18_000;
    return std.fmt.parseInt(u64, value, 10) catch null;
}
