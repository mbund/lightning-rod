const std = @import("std");
const nbt = @import("nbt");
const anvil = @import("anvil");
const vanilla = @import("vanilla");
const level = @import("level.zig");
const book = @import("book.zig");
const fields = @import("nbt.zig");
const items = @import("items.zig");
const world_import = @import("import.zig");

pub fn all(owner: *world_import.Import) !void {
    var reader = try anvil.Reader.initRegion(owner.allocator, owner.io, owner.options.input, null);
    defer reader.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const level_path = try std.fs.path.join(owner.allocator, &.{ owner.options.input, "level.dat" });
    const level_document = reader.loadFile(level_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (level_document) |doc| {
        const data = doc.childNamed("Data") orelse return error.InvalidLevelData;
        try level.read(owner, doc, data);
        if (data.childNamed(doc.nodes, "Player")) |player| try one(owner, scratch.allocator(), doc, player);
    }
    const path = try std.fs.path.join(owner.allocator, &.{ owner.options.input, "playerdata" });
    var directory = std.Io.Dir.cwd().openDir(owner.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer directory.close(owner.io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| owner.allocator.free(name);
        names.deinit(owner.allocator);
    }
    var iterator = directory.iterate();
    while (try iterator.next(owner.io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".dat")) {
        try names.append(owner.allocator, try owner.allocator.dupe(u8, entry.name));
    };
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (names.items) |name| {
        _ = scratch.reset(.retain_capacity);
        const player_path = try std.fs.path.join(scratch.allocator(), &.{ path, name });
        const doc = try reader.loadFile(player_path);
        if (try fields.uuid(try fields.field(doc, doc.root_node(), "UUID")) != try fields.parseUuid(name[0 .. name.len - 4])) return error.PlayerUuidMismatch;
        try one(owner, scratch.allocator(), doc, doc.root_node());
        if (owner.counts.players % 8 == 0) try owner.save();
    }
}

fn one(owner: *world_import.Import, scratch: std.mem.Allocator, doc: nbt.Document, root: nbt.Node) !void {
    const original = try fields.uuid(try fields.field(doc, root, "UUID"));
    const uuid = owner.mappedUuid(original);
    const identity = try owner.player_ids.getOrPut(uuid);
    if (identity.found_existing and identity.value_ptr.* != original) return error.PlayerMappingCollision;
    identity.value_ptr.* = original;
    var key: [16]u8 = undefined;
    std.mem.writeInt(u128, &key, uuid, .little);
    var previous: [vanilla.Players.saved_size]u8 = undefined;
    if (try owner.players.get(&key, &previous) != null) return;
    const dimension = try (try fields.field(doc, root, "Dimension")).string();
    const world = owner.worlds.find(dimension) orelse {
        try owner.unsupported("player dimension", dimension);
        return;
    };
    const position = try fields.vector(doc, try fields.field(doc, root, "Pos"));
    for (position) |value| if (@abs(value) > 30_000_000) return error.InvalidPosition;
    const rotation = try fields.field(doc, root, "Rotation");
    if ((try rotation.listInfo()).len != 2) return error.InvalidRotation;
    var iterator = rotation.childIterator(doc.nodes);
    const yaw = try fields.number(iterator.next().?);
    const pitch = try fields.number(iterator.next().?);
    const mode = try fields.optionalInt(doc, root, "playerGameType", 0);
    const slot = try fields.optionalInt(doc, root, "SelectedItemSlot", 0);
    if (mode < 0 or mode > 3 or slot < 0 or slot > 8) return error.InvalidPlayer;
    const health: f32 = if (root.childNamed(doc.nodes, "Health")) |value| @floatCast(try fields.number(value)) else 20;
    if (health < 0 or health > 20) return error.InvalidPlayerHealth;
    var player: vanilla.Players.Player = .{
        .uuid = uuid,
        .world = world.id,
        .position = .{ .x = position[0], .y = position[1], .z = position[2] },
        .rotation = .{ .yaw = @floatCast(@mod(yaw + 180, 360) - 180), .pitch = @floatCast(std.math.clamp(pitch, -90, 90)) },
        .gamemode = @fromBackingInt(@intCast(mode)),
        .selected_slot = @intCast(slot),
        .health = health,
        .on_ground = try fields.optionalInt(doc, root, "OnGround", 0) != 0,
    };
    player.flags.burning = try fields.optionalInt(doc, root, "Fire", 0) > 0;
    player.flags.glowing = try fields.optionalInt(doc, root, "Glowing", 0) != 0;
    player.flags.gliding = try fields.optionalInt(doc, root, "FallFlying", 0) != 0;
    if (root.childNamed(doc.nodes, "XpP")) |value| player.experience.progress = @floatCast(try fields.number(value));
    player.experience.level = std.math.cast(i32, try fields.optionalInt(doc, root, "XpLevel", 0)) orelse return error.InvalidExperience;
    player.experience.total = std.math.cast(i32, try fields.optionalInt(doc, root, "XpTotal", 0)) orelse return error.InvalidExperience;
    player.experience.score = std.math.cast(i32, try fields.optionalInt(doc, root, "Score", 0)) orelse return error.InvalidExperience;
    const points = player.experience.encode();
    _ = try @TypeOf(player.experience).decode(&points);
    if (root.childNamed(doc.nodes, "Inventory")) |inventory| try items.inventory(owner, scratch, doc, inventory, uuid, true, 46);
    if (root.childNamed(doc.nodes, "EnderItems")) |inventory| if (inventory.child_count != 0) try owner.unsupported("player inventory", "ender chest");
    const bytes = player.encode();
    const experience_key = vanilla.Players.experienceKey(uuid);
    try owner.players.putBatch(&.{ .{ .key = &key, .value = &bytes }, .{ .key = &experience_key, .value = &points } });
    try book.read(owner, scratch, doc, root, original, uuid);
    owner.counts.players += 1;
}
