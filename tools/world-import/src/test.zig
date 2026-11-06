const std = @import("std");
const nbt = @import("nbt");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const game_data = @import("game_data");
const inventories = @import("inventories");
const main = @import("main.zig");
const importer = @import("import.zig");

const player_uuid: u128 = 0xfedcba98765432108000123456789abc;

fn uuid(writer: *nbt.Writer, name: []const u8, value: u128) !void {
    var words: [4]i32 = undefined;
    for (&words, 0..) |*word, index| word.* = @bitCast(@as(u32, @truncate(value >> @intCast((3 - index) * 32))));
    try writer.putIntArray(name, &words);
}

fn vector(writer: *nbt.Writer, name: []const u8, values: [3]f64) !void {
    try writer.beginNamedList(name, .double, 3);
    for (values) |value| try writer.putDoubleElement(value);
    try writer.endList();
}

fn item(writer: *nbt.Writer, slot: ?i8, name: []const u8, count: i32) !void {
    if (slot) |value| try writer.putByte("Slot", value);
    try writer.putString("id", name);
    try writer.putInt("count", count);
}

fn region(directory: std.Io.Dir, io: std.Io, name: []const u8, x: i32, z: i32, bytes: []const u8) !void {
    const file = try directory.createFile(io, name, .{ .read = true, .truncate = false });
    defer file.close(io);
    var size = (try file.stat(io)).size;
    if (size == 0) {
        const header: [8192]u8 = @splat(0);
        try file.writePositionalAll(io, &header, 0);
        size = header.len;
    }
    const sectors = (bytes.len + 5 + 4095) / 4096;
    try file.setLength(io, size + sectors * 4096);
    var location: [4]u8 = undefined;
    std.mem.writeInt(u32, &location, @intCast(size / 4096 * 256 + sectors), .big);
    try file.writePositionalAll(io, &location, @as(u64, @intCast(@mod(x, 32) + @mod(z, 32) * 32)) * 4);
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(bytes.len + 1), .big);
    header[4] = 3;
    try file.writePositionalAll(io, &header, size);
    try file.writePositionalAll(io, bytes, size + 5);
}

fn terrain(directory: std.Io.Dir, io: std.Io, path: []const u8, furnace: bool) !void {
    var bytes: [8192]u8 = undefined;
    var frames: [32]nbt.WriteFrame = undefined;
    var writer = nbt.Writer.init(&bytes, &frames);
    const x: i32 = if (furnace) -2 else -1;
    try writer.beginNamedCompound("");
    try writer.putInt("DataVersion", 4440);
    try writer.putInt("xPos", x);
    try writer.putInt("zPos", -1);
    try writer.putString("Status", "minecraft:full");
    try writer.beginNamedList("sections", .compound, 1);
    try writer.beginCompoundElement();
    try writer.putByte("Y", 4);
    try writer.beginNamedCompound("block_states");
    try writer.beginNamedList("palette", .compound, 1);
    try writer.beginCompoundElement();
    try writer.putString("Name", if (furnace) "minecraft:furnace" else "minecraft:chest");
    try writer.beginNamedCompound("Properties");
    try writer.putString("facing", "north");
    if (furnace) try writer.putString("lit", "true") else {
        try writer.putString("waterlogged", "false");
        try writer.putString("type", "single");
    }
    try writer.endCompound();
    try writer.endCompound();
    try writer.endList();
    try writer.endCompound();
    try writer.beginNamedCompound("biomes");
    try writer.beginNamedList("palette", .string, 2);
    try writer.putStringElement("minecraft:desert");
    try writer.putStringElement("minecraft:forest");
    try writer.endList();
    const biome_indices: [1]i64 = .{@bitCast(@as(u64, 0xaaaaaaaaaaaaaaaa))};
    try writer.putLongArray("data", &biome_indices);
    try writer.endCompound();
    try writer.endCompound();
    try writer.endList();
    try writer.beginNamedList("block_entities", .compound, 1);
    try writer.beginCompoundElement();
    try writer.putString("id", if (furnace) "minecraft:furnace" else "minecraft:chest");
    try writer.putInt("x", x * 16);
    try writer.putInt("y", 64);
    try writer.putInt("z", -16);
    try writer.beginNamedList("Items", .compound, 1);
    try writer.beginCompoundElement();
    try item(&writer, 0, if (furnace) "minecraft:iron_ore" else "minecraft:bread", 3);
    try writer.endCompound();
    try writer.endList();
    if (furnace) {
        try writer.putShort("lit_time_remaining", 80);
        try writer.putShort("lit_total_time", 1600);
        try writer.putShort("cooking_time_spent", 50);
        try writer.putShort("cooking_total_time", 200);
        try writer.beginNamedCompound("RecipesUsed");
        try writer.putInt("minecraft:iron_ingot_from_smelting_iron_ore", 2);
        try writer.endCompound();
    }
    try writer.endCompound();
    try writer.endList();
    try writer.endCompound();
    try region(directory, io, path, x, -1, try writer.finish());
}

fn player(directory: std.Io.Dir, io: std.Io, unsupported: bool) !void {
    var bytes: [8192]u8 = undefined;
    var frames: [32]nbt.WriteFrame = undefined;
    var writer = nbt.Writer.init(&bytes, &frames);
    try writer.beginNamedCompound("");
    try uuid(&writer, "UUID", player_uuid);
    try writer.putString("Dimension", "minecraft:overworld");
    try vector(&writer, "Pos", .{ -15.5, 65, -15.5 });
    try writer.beginNamedList("Rotation", .float, 2);
    try writer.putFloatElement(30);
    try writer.putFloatElement(-15);
    try writer.endList();
    try writer.putInt("playerGameType", 1);
    try writer.putInt("SelectedItemSlot", 6);
    try writer.putFloat("Health", 18);
    try writer.putInt("XpLevel", 5);
    try writer.putFloat("XpP", 0.25);
    try writer.putInt("XpTotal", 60);
    try writer.beginNamedList("Inventory", .compound, 3);
    try writer.beginCompoundElement();
    try item(&writer, 0, "minecraft:bread", 3);
    try writer.endCompound();
    try writer.beginCompoundElement();
    try item(&writer, 100, "minecraft:diamond_boots", 1);
    try writer.beginNamedCompound("components");
    try writer.putInt("minecraft:damage", 7);
    try writer.beginNamedCompound("minecraft:enchantments");
    try writer.putInt("minecraft:mending", 1);
    try writer.endCompound();
    if (unsupported) {
        try writer.beginNamedCompound("minecraft:stored_enchantments");
        try writer.putInt("minecraft:mending", 1);
        try writer.endCompound();
    }
    try writer.beginNamedCompound("minecraft:custom_data");
    try writer.putLong("signed", -9007199254740993);
    try writer.putByteArray("bytes", &.{ 255, 0, 17 });
    try writer.endCompound();
    try writer.endCompound();
    try writer.endCompound();
    try writer.beginCompoundElement();
    try item(&writer, @bitCast(@as(u8, 150)), "minecraft:shield", 1);
    try writer.endCompound();
    try writer.endList();
    try writer.beginNamedCompound("recipeBook");
    try writer.putByte("isGuiOpen", 1);
    try writer.putByte("isFurnaceFilteringCraftable", 1);
    try writer.beginNamedList("recipes", .string, 1);
    try writer.putStringElement("minecraft:oak_planks");
    try writer.endList();
    try writer.beginNamedList("toBeDisplayed", .string, 1);
    try writer.putStringElement("minecraft:oak_planks");
    try writer.endList();
    try writer.endCompound();
    try writer.endCompound();
    var compressed = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 65536);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, &window, .gzip, .default);
    try compressor.writer.writeAll(try writer.finish());
    try compressor.finish();
    try directory.writeFile(io, .{ .sub_path = "source/playerdata/fedcba98-7654-3210-8000-123456789abc.dat", .data = compressed.written() });
}

fn level(directory: std.Io.Dir, io: std.Io) !void {
    var bytes: [8192]u8 = undefined;
    var frames: [32]nbt.WriteFrame = undefined;
    var writer = nbt.Writer.init(&bytes, &frames);
    try writer.beginNamedCompound("");
    try writer.beginNamedCompound("Data");
    try writer.putLong("Time", 90000);
    try writer.putLong("DayTime", 12345);
    try writer.putInt("SpawnX", -123);
    try writer.putInt("SpawnY", 72);
    try writer.putInt("SpawnZ", 456);
    try writer.putFloat("SpawnAngle", 37.5);
    try writer.putInt("rainTime", 6000);
    try writer.putInt("thunderTime", 8000);
    try writer.putByte("raining", 1);
    try writer.beginNamedCompound("GameRules");
    try writer.putString("doDaylightCycle", "false");
    try writer.putString("doWeatherCycle", "false");
    try writer.putString("spawnRadius", "7");
    try writer.endCompound();
    try writer.endCompound();
    try writer.endCompound();
    var compressed = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 65536);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, &window, .gzip, .default);
    try compressor.writer.writeAll(try writer.finish());
    try compressor.finish();
    try directory.writeFile(io, .{ .sub_path = "source/level.dat", .data = compressed.written() });
}

fn entities(directory: std.Io.Dir, io: std.Io, unsupported: bool) !void {
    var bytes: [8192]u8 = undefined;
    var frames: [32]nbt.WriteFrame = undefined;
    var writer = nbt.Writer.init(&bytes, &frames);
    try writer.beginNamedCompound("");
    try writer.putInt("DataVersion", 4440);
    try writer.putIntArray("Position", &.{ -1, -1 });
    try writer.beginNamedList("Entities", .compound, if (unsupported) 3 else 2);
    for (0..2) |index| {
        try writer.beginCompoundElement();
        try writer.putString("id", if (index == 0) "minecraft:item" else "minecraft:experience_orb");
        try uuid(&writer, "UUID", 1000 + index);
        try vector(&writer, "Pos", .{ -15, 66, -15 });
        try vector(&writer, "Motion", .{ 0.1, 0.2, -0.1 });
        try writer.putShort("Age", 40);
        try writer.putShort("Health", 5);
        if (index == 0) {
            try writer.putShort("PickupDelay", 7);
            try uuid(&writer, "Owner", player_uuid);
            try writer.beginNamedCompound("Item");
            try item(&writer, null, "minecraft:bread", 3);
            try writer.endCompound();
        } else {
            try writer.putShort("Value", 7);
            try writer.putInt("Count", 2);
        }
        try writer.endCompound();
    }
    if (unsupported) {
        try writer.beginCompoundElement();
        try writer.putString("id", "minecraft:pig");
        try writer.endCompound();
    }
    try writer.endList();
    try writer.endCompound();
    try region(directory, io, "source/entities/r.-1.-1.mca", -1, -1, try writer.finish());
}

fn fixture(directory: std.Io.Dir, io: std.Io, unsupported: bool) !void {
    try directory.createDirPath(io, "source/region");
    try directory.createDirPath(io, "source/entities");
    try directory.createDirPath(io, "source/playerdata");
    try directory.writeFile(io, .{ .sub_path = "source/entities/r.0.0.mca", .data = &.{} });
    try terrain(directory, io, "source/region/r.-1.-1.mca", false);
    try terrain(directory, io, "source/region/r.-1.-1.mca", true);
    try directory.createDirPath(io, "source/DIM-1/region");
    try directory.createDirPath(io, "source/DIM1/region");
    try terrain(directory, io, "source/DIM-1/region/r.-1.-1.mca", false);
    try terrain(directory, io, "source/DIM1/region/r.-1.-1.mca", false);
    try player(directory, io, false);
    try directory.createDirPath(io, "source/advancements");
    try directory.writeFile(io, .{
        .sub_path = "source/advancements/fedcba98-7654-3210-8000-123456789abc.json",
        .data =
        \\{"DataVersion":4440,"minecraft:recipes/building_blocks/oak_planks":{"criteria":{"has_logs":"2026-10-30 00:00:00 +0000","has_the_recipe":"2026-10-30 00:00:00 +0000"},"done":true}}
        ,
    });
    try level(directory, io);
    try entities(directory, io, unsupported);
}

test "Java world import reopens terrain players containers items and orbs through native storage" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try fixture(temporary.dir, io, false);
    var path_buffer: [4096]u8 = undefined;
    const path = path_buffer[0..try temporary.dir.realPath(io, &path_buffer)];
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const input = try std.fs.path.join(allocator, &.{ path, "source" });
    const output = try std.fs.path.join(allocator, &.{ path, "native" });
    const mapped = try main.offlineUuid(allocator, "ImportTest");
    const options: importer.Options = .{ .input = input, .output = output, .players = &.{.{ .original = player_uuid, .destination = mapped }} };
    try main.run(allocator, io, options);
    try std.testing.expectError(error.OutputAlreadyExists, main.run(allocator, io, options));
    var store = try lightning_rod.storage.Store.init(allocator, io, .{ .path = try std.fs.path.join(allocator, &.{ output, "world" }) });
    defer store.deinit();
    var metrics = try lightning_rod.metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer metrics.deinit();
    var native = try importer.Import.init(allocator, io, options, &store, &metrics);
    const world = native.worlds.find("minecraft:overworld").?.id;
    try std.testing.expectEqualDeep(vanilla.Spawn.Definition{ .position = .{ .x = -123, .y = 72, .z = 456 }, .angle = 37.5, .radius = 7 }, try native.spawn.get(world));
    try std.testing.expectEqual(@as(u16, @intCast(game_data.registry.blockStateId("minecraft:chest[facing=north,type=single,waterlogged=false]").?)), try native.chunks.getBlock(world, .{ .x = -16, .y = 64, .z = -16 }));
    {
        const section = try native.chunks.acquire(.{ .world = world, .x = -1, .y = 4, .z = -1 });
        defer section.release();
        const biomes = section.biomes() orelse return error.MissingImportedBiomes;
        for (0..64) |index| try std.testing.expectEqual(@as(u16, @intCast(game_data.registry.biomeId(if (index % 2 == 0) "minecraft:desert" else "minecraft:forest").?)), biomes.get(@intCast(index)));
    }
    var key: [16]u8 = undefined;
    std.mem.writeInt(u128, &key, mapped, .little);
    var saved: [vanilla.Players.saved_size]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, saved.len), try native.players.get(&key, &saved));
    const expected: vanilla.Players.Player = .{ .position = .{ .x = -15.5, .y = 65, .z = -15.5 }, .rotation = .{ .yaw = 30, .pitch = -15 }, .health = 18, .gamemode = .creative, .world = world, .selected_slot = 6 };
    try std.testing.expectEqualSlices(u8, &expected.encode(), &saved);
    var points: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 16), try native.players.get(&vanilla.Players.experienceKey(mapped), &points));
    const xp = try @TypeOf(expected.experience).decode(&points);
    try std.testing.expectEqual(@as(i32, 5), xp.level);
    try std.testing.expectEqual(@as(f32, 0.25), xp.progress);
    const clock = try vanilla.Time.init(allocator, .{}, .{ .storage = try store.openSpace(vanilla.Time.id) });
    try std.testing.expectEqual(@as(i64, 90000), clock.game_time);
    try std.testing.expectEqual(@as(i64, 12345), clock.day_time);
    try std.testing.expect(!clock.daylight_cycle);
    const weather = try vanilla.Weather.init(allocator, .{}, .{ .storage = try store.openSpace(vanilla.Weather.id) });
    try std.testing.expect(weather.raining and !weather.weather_cycle);
    try std.testing.expectEqual(@as(i32, 6000), weather.rain_ticks);
    var book_key: [16]u8 = undefined;
    std.mem.writeInt(u128, &book_key, mapped, .big);
    var book_bytes: [4096]u8 = undefined;
    const book_length = (try native.recipes.get(&book_key, &book_bytes)).?;
    var book = std.Io.Reader.fixed(book_bytes[0..book_length]);
    try std.testing.expectEqualStrings("LRBOOK01", try book.take(8));
    try std.testing.expectEqual(@as(u8, 9), try book.takeByte());
    try std.testing.expectEqual(@as(u32, 1), try book.takeInt(u32, .big));
    var recipe_hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash("minecraft:oak_planks", &recipe_hash, .{});
    try std.testing.expectEqualSlices(u8, &recipe_hash, try book.take(32));
    try std.testing.expectEqual(@as(u8, 3), try book.takeByte());
    try std.testing.expectEqual(@as(u32, 2), try book.takeInt(u32, .big));
    for (0..2) |_| {
        const identity = try book.take(32);
        const known = for (native.content.book.unlocks.criteria) |criterion| {
            if (std.mem.eql(u8, identity, &criterion.identity)) break true;
        } else false;
        try std.testing.expect(known);
    }
    try std.testing.expectEqual(@as(u32, 1), try book.takeInt(u32, .big));
    std.crypto.hash.Blake3.hash("minecraft:recipes/building_blocks/oak_planks", &recipe_hash, .{});
    try std.testing.expectEqualSlices(u8, &recipe_hash, try book.take(32));
    try std.testing.expectEqual(book.end, book.seek);
    for ([_][]const u8{ "minecraft:the_nether", "minecraft:the_end" }) |name| {
        const dimension = native.worlds.find(name).?.id;
        try std.testing.expectEqual(@as(u16, @intCast(game_data.registry.blockStateId("minecraft:chest[facing=north,type=single,waterlogged=false]").?)), try native.chunks.getBlock(dimension, .{ .x = -16, .y = 64, .z = -16 }));
    }
    const slots = [_]inventories.Slot{ .{ .owner = mapped, .index = 36 }, .{ .owner = mapped, .index = 8 }, .{ .owner = mapped, .index = 45 }, vanilla.Containers.slot(world, .{ .x = -16, .y = 64, .z = -16 }, 0) };
    var contents: [4]inventories.Contents = undefined;
    try native.inventories.getMany(&slots, &contents);
    try std.testing.expectEqual(@as(u16, 3), contents[0].stack.?.count);
    try std.testing.expectEqual(@as(u16, 3), contents[3].stack.?.count);
    const boots = try native.items.acquire(contents[1].stack.?);
    defer boots.release();
    try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.itemId("minecraft:diamond_boots").?)), boots.view.kind);
    try std.testing.expectEqualSlices(u8, &.{7}, boots.view.value(.damage).?);
    try std.testing.expectEqual(@as(u32, 1), try vanilla.Enchantments.level(boots.view, "minecraft:mending"));
    const custom = try vanilla.custom_data.Compound.init(boots.view.value(.custom_data).?);
    const signed = (try custom.get("signed")).?;
    try std.testing.expectEqual(@as(i64, -9007199254740993), std.mem.readInt(i64, signed.payload[0..8], .big));
    const furnace_key: vanilla.container_storage.Key = .{ .world = world, .position = .{ .x = -32, .y = 64, .z = -16 } };
    var furnace: [vanilla.furnace_state.encoded_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, furnace.len), try native.containers.states.get(&furnace_key.encode(), &furnace));
    const state = try vanilla.furnace_state.State.decode(&furnace);
    try std.testing.expectEqual(@as(u32, 50), state.cook);
    try std.testing.expectEqual(@as(u32, 80), state.burn_left);
    const dropped = try vanilla.ItemEntities.init(allocator, io, .{}, .{ .record_workspaces = native.workspace, .metrics = &metrics, .entities = native.entities, .inventories = native.inventories, .items = native.items, .worlds = native.worlds, .storage = try store.openSpace(vanilla.ItemEntities.id) });
    const metadata = try dropped.get(1);
    try std.testing.expectEqual(@as(?u128, mapped), metadata.owner);
    try std.testing.expectEqual(@as(u16, 7), metadata.pickup_delay);
    const body = (try native.entities.get(2)).?;
    try std.testing.expectEqual(@as(u128, 1001), body.uuid);
    try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.entityId("minecraft:experience_orb").?)), body.kind);
}

test "unsupported world data fails atomically or is counted with explicit permission" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try fixture(temporary.dir, io, true);
    var path_buffer: [4096]u8 = undefined;
    const path = path_buffer[0..try temporary.dir.realPath(io, &path_buffer)];
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const input = try std.fs.path.join(allocator, &.{ path, "source" });
    const output = try std.fs.path.join(allocator, &.{ path, "native" });
    try std.testing.expectError(error.UnsupportedWorldData, main.run(allocator, io, .{ .input = input, .output = output }));
    try std.testing.expect(!importer.exists(io, output));
    try std.testing.expect(!importer.exists(io, try std.fmt.allocPrint(allocator, "{s}.importing", .{output})));
    try main.run(allocator, io, .{ .input = input, .output = output, .skip_unsupported = true });
    const report = try temporary.dir.readFileAlloc(io, "native/import.json", allocator, .limited(1024 * 1024));
    const json = try std.json.parseFromSlice(std.json.Value, allocator, report, .{});
    try std.testing.expectEqual(@as(i64, 1), json.value.object.get("skipped").?.object.get("entity:minecraft:pig").?.integer);
}

test "region coordinates preserve negative chunk ownership and reject overflow" {
    try std.testing.expectEqual([2]i32{ -1, 2 }, try importer.regionCoordinates("r.-1.2.mca"));
    try std.testing.expectError(error.InvalidRegionName, importer.regionCoordinates("r.1.2.3.mca"));
    try std.testing.expectError(error.InvalidRegionName, importer.regionCoordinates("r.1875000.0.mca"));
}

test "world import respects the source world's session lock" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "source", .default_dir);
    const file = try temporary.dir.createFile(io, "source/session.lock", .{ .read = true });
    defer file.close(io);
    var lock: std.os.linux.Flock = .{ .type = std.os.linux.F.WRLCK, .whence = 0, .start = 0, .len = 0, .pid = 0, ._unused = {} };
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fcntl(file.handle, std.os.linux.F.SETLK, @intFromPtr(&lock))));
    var path_buffer: [4096]u8 = undefined;
    const path = path_buffer[0..try temporary.dir.realPath(io, &path_buffer)];
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const output = try std.fs.path.join(allocator, &.{ path, "native" });
    try std.testing.expectError(error.SourceWorldInUse, main.run(allocator, io, .{ .input = try std.fs.path.join(allocator, &.{ path, "source" }), .output = output }));
    try std.testing.expect(!importer.exists(io, output));
}

test "unsupported item components require explicit permission and appear in the report" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try fixture(temporary.dir, io, false);
    try player(temporary.dir, io, true);
    var path_buffer: [4096]u8 = undefined;
    const path = path_buffer[0..try temporary.dir.realPath(io, &path_buffer)];
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const input = try std.fs.path.join(allocator, &.{ path, "source" });
    const output = try std.fs.path.join(allocator, &.{ path, "native" });
    try std.testing.expectError(error.UnsupportedWorldData, main.run(allocator, io, .{ .input = input, .output = output }));
    try std.testing.expect(!importer.exists(io, output));
    try main.run(allocator, io, .{ .input = input, .output = output, .skip_unsupported = true });
    const report = try temporary.dir.readFileAlloc(io, "native/import.json", allocator, .limited(1024 * 1024));
    const json = try std.json.parseFromSlice(std.json.Value, allocator, report, .{});
    try std.testing.expectEqual(@as(i64, 1), json.value.object.get("skipped").?.object.get("item component:minecraft:stored_enchantments").?.integer);
}
