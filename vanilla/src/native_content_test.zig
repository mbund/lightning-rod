const Registries = @import("content_registries.zig").Registries;
const provider = @import("definition_provider.zig");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("lib.zig");
const protocols = @import("protocols");
const native_nbt = @import("native_nbt.zig");

test "default gameplay composition and client configuration have no datapack dependency" {
    const selections = vanilla.plugins();
    try std.testing.expect(lightning_rod.plugin.indexOfId(@TypeOf(selections), "minecraft:datapacks") == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try vanilla.prepareDefinitions(allocator);
    var selected = try protocols.Default.init(allocator);
    try provider.configureProtocols(content, protocols.Default, allocator, &selected);
    try std.testing.expect(content.crafting.table.crafting.len > 100);
}

test "custom registry compatibility is explicit and independent of datapack loading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try vanilla.prepareDefinitions(allocator);
    const native = try native_nbt.encode(allocator, .{
        .sound_event = @as([]const u8, "test:new_sound"),
        .description = @as([]const u8, "Custom song"),
        .length_in_seconds = @as(f64, 1),
        .comparator_output = @as(i32, 1),
    });
    _ = try provider.register(content, allocator, .{ .registries = &.{.{ .registry = "minecraft:jukebox_song", .name = "test:song", .nbt = native }} }, null);
    var selected = try protocols.Default.init(allocator);
    try std.testing.expectError(error.UnsupportedClientSound, provider.configureProtocols(content, protocols.Default, allocator, &selected));
    const fallback = try native_nbt.encode(allocator, .{
        .sound_event = @as([]const u8, "minecraft:block.note_block.harp"),
        .description = @as([]const u8, "Custom song"),
        .length_in_seconds = @as(f64, 1),
        .comparator_output = @as(i32, 1),
    });
    var presentations: [protocols.Default.versions.len]Registries.Presentation = undefined;
    inline for (protocols.Default.versions, &presentations) |Version, *entry| entry.* = .{
        .protocol = Version.protocol_number,
        .registry = "minecraft:jukebox_song",
        .name = "test:song",
        .nbt = fallback,
    };
    _ = try provider.register(content, allocator, .{ .client_registries = &presentations }, null);
    try provider.configureProtocols(content, protocols.Default, allocator, &selected);
    for (&selected.values) |*version| _ = try version.registryId("minecraft:jukebox_song", "test:song");
    try std.testing.expectEqualSlices(u8, native, content.client.client.get("minecraft:jukebox_song").?.get("test:song").?.nbt);
    const original = content.book.table.book.ptr;
    try std.testing.expectError(error.UnknownRegistryEntry, provider.register(content, allocator, .{ .client_registries = &.{.{
        .protocol = protocols.Default.versions[0].protocol_number,
        .registry = "minecraft:jukebox_song",
        .name = "test:missing",
        .nbt = fallback,
    }} }, null));
    try std.testing.expectEqual(original, content.book.table.book.ptr);
}

test "client configuration does not implicitly install vanilla gameplay definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try provider.prepare(allocator);
    var selected = try protocols.Default.init(allocator);
    try provider.configureProtocols(content, protocols.Default, allocator, &selected);
    try std.testing.expectEqual(@as(usize, 0), content.book.table.book.len);
    for (content.furnaces.table.fuels) |fuel| try std.testing.expectEqual(@as(u32, 0), fuel.ticks);
    for (content.book.table.remainders) |remainder| try std.testing.expect(remainder == null);
}
