const std = @import("std");
const lightning_rod = @import("lightning_rod");
const game_data = @import("game_data");
const world_import = @import("import.zig");
const tests = @import("test.zig");
const fields = @import("nbt.zig");

const help =
    \\Usage: world-import --input JAVA_WORLD --output NEW_DIRECTORY [options]
    \\
    \\Imports generated terrain and biomes in the Overworld, Nether, and End, player state
    \\and inventories, recipe books, chests, furnaces, dropped items, XP orbs,
    \\world time, and weather.
    \\The source must be offline. It is never modified.
    \\
    \\  --skip-unsupported  Skip unsupported entities, containers, and item components.
    \\                      Every omission is counted in import.json.
    \\  --player UUID=NAME  Map a saved player to NAME's offline-mode UUID.
    \\                      May be repeated. Otherwise original UUIDs are preserved.
    \\  --help             Show this message.
    \\  --no-lighting      Leave lighting to be reconstructed when terrain is used.
    \\
    \\Scheduled ticks, POIs, non-recipe advancements, statistics,
    \\and other game rules are not represented by the current native world format.
    \\Datapacks and world generator settings must be configured on the target server.
    \\Unexplored terrain uses the server's configured world generator.
    \\Start the vanilla example with --world=NEW_DIRECTORY/world.
    \\
;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var skip = false;
    var bake_lighting = true;
    var mappings: std.ArrayList(world_import.Mapping) = .empty;
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--help")) {
            var buffer: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &buffer);
            try stdout.interface.writeAll(help);
            try stdout.interface.flush();
            return;
        }
        if (std.mem.eql(u8, flag, "--skip-unsupported")) {
            skip = true;
            continue;
        }
        if (std.mem.eql(u8, flag, "--no-lighting")) {
            bake_lighting = false;
            continue;
        }
        const value = args.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, flag, "--input")) {
            if (input != null) return error.DuplicateArgument;
            input = value;
        } else if (std.mem.eql(u8, flag, "--output")) {
            if (output != null) return error.DuplicateArgument;
            output = value;
        } else if (std.mem.eql(u8, flag, "--player")) {
            const equal = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidPlayerMapping;
            const original = try fields.parseUuid(value[0..equal]);
            const name = value[equal + 1 ..];
            if (name.len == 0 or name.len > 16) return error.InvalidPlayerName;
            for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidPlayerName;
            const destination = try offlineUuid(allocator, name);
            for (mappings.items) |mapping| if (mapping.original == original or mapping.destination == destination) return error.DuplicatePlayerMapping;
            try mappings.append(allocator, .{ .original = original, .destination = destination });
        } else return error.UnknownArgument;
    }
    const options: world_import.Options = .{
        .input = input orelse return error.MissingInput,
        .output = output orelse return error.MissingOutput,
        .skip_unsupported = skip,
        .players = mappings.items,
        .lighting = bake_lighting,
    };
    try run(allocator, init.io, options);
}

pub fn offlineUuid(allocator: std.mem.Allocator, name: []const u8) !u128 {
    const text = try std.fmt.allocPrint(allocator, "OfflinePlayer:{s}", .{name});
    defer allocator.free(text);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(text, &digest, .{});
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    return std.mem.readInt(u128, &digest, .big);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: world_import.Options) !void {
    const cwd = std.Io.Dir.cwd();
    if (world_import.exists(io, options.output)) return error.OutputAlreadyExists;
    var input = try cwd.openDir(io, options.input, .{});
    defer input.close(io);
    const source_lock = input.openFile(io, "session.lock", .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (source_lock) |file| file.close(io);
    if (source_lock) |file| {
        var lock: std.os.linux.Flock = .{ .type = std.os.linux.F.RDLCK, .whence = 0, .start = 0, .len = 0, .pid = 0, ._unused = {} };
        while (true) {
            switch (std.os.linux.errno(std.os.linux.fcntl(file.handle, std.os.linux.F.OFD_SETLK, @intFromPtr(&lock)))) {
                .SUCCESS => break,
                .INTR => continue,
                .ACCES, .AGAIN => return error.SourceWorldInUse,
                else => return error.SourceLockFailed,
            }
        }
    }

    const pending = try std.fmt.allocPrint(allocator, "{s}.importing", .{options.output});
    defer allocator.free(pending);
    try cwd.createDir(io, pending, .default_dir);
    errdefer cwd.deleteTree(io, pending) catch {};
    const database = try std.fs.path.join(allocator, &.{ pending, "world" });
    defer allocator.free(database);
    var metrics = try lightning_rod.metrics.Registry.init(allocator, io, .{ .capacity = 256, .enabled = false });
    defer metrics.deinit();
    {
        var store = try lightning_rod.storage.Store.init(allocator, io, .{ .path = database });
        defer store.deinit();
        var importer = try world_import.Import.init(allocator, io, options, &store, &metrics);
        try importer.run();
        var skipped: std.json.ObjectMap = .empty;
        defer skipped.deinit(allocator);
        var iterator = importer.skipped.iterator();
        while (iterator.next()) |entry| try skipped.put(allocator, entry.key_ptr.*, .{ .integer = @intCast(entry.value_ptr.*) });
        const report = try std.json.Stringify.valueAlloc(allocator, .{
            .baseline = game_data.canonical_version,
            .source = options.input,
            .counts = importer.counts,
            .spawn = try importer.spawn.get(importer.worlds.find("minecraft:overworld").?.id),
            .skipped = std.json.Value{ .object = skipped },
            .player_mappings = options.players,
            .not_represented = "Scheduled ticks, POIs, non-recipe advancements, statistics, other game rules, datapacks, and generator settings",
        }, .{ .whitespace = .indent_2 });
        defer allocator.free(report);
        var directory = try cwd.openDir(io, pending, .{ .iterate = true });
        defer directory.close(io);
        const file = try directory.createFile(io, "import.json", .{});
        defer file.close(io);
        try file.writePositionalAll(io, report, 0);
        try file.sync(io);
        try syncDirectory(io, directory);
        std.log.info("imported columns={d} players={d} chests={d} furnaces={d} dropped_items={d} experience_orbs={d}", .{ importer.counts.columns, importer.counts.players, importer.counts.chests, importer.counts.furnaces, importer.counts.items, importer.counts.orbs });
    }
    try cwd.renamePreserve(pending, cwd, options.output, io);
    const parent = std.fs.path.dirname(options.output) orelse ".";
    var directory = try cwd.openDir(io, parent, .{ .iterate = true });
    defer directory.close(io);
    try syncDirectory(io, directory);
    std.log.info("import complete: {s}/world (report: {s}/import.json)", .{ options.output, options.output });
}

test {
    _ = fields;
}

test {
    _ = tests;
}

fn syncDirectory(io: std.Io, directory: std.Io.Dir) !void {
    const file: std.Io.File = .{ .handle = directory.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}
