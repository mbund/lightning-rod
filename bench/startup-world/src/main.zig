const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const chunks = @import("chunks");
const records = @import("records");

const side = 64;
const batch_sections = 192;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try vanilla.prepareDefinitions(allocator);
    const dimension = try content.dimensions.dimension("minecraft:overworld");
    const section_count: usize = dimension.section_count;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingWorldPath;
    if (args.next() != null) return error.UnexpectedArgument;
    var store = try lightning_rod.storage.Store.init(allocator, init.io, .{ .path = path });
    defer store.deinit();
    const plugins = lightning_rod.plugin.compose(.{
        vanilla.definition_provider.selections(content),
        lightning_rod.plugin.configured(records.Workspaces, .{}),
        lightning_rod.plugin.configured(vanilla.RegistryIdentity, .{}),
        lightning_rod.plugin.configured(vanilla.Worlds, .{}),
        lightning_rod.plugin.configured(vanilla.VanillaWorlds, .{}),
        lightning_rod.plugin.configured(vanilla.Chunks, .{ .demand_sections = 0, .cache_sections = batch_sections }),
        lightning_rod.plugin.configured(vanilla.Flat, .{}),
    });
    const simulation = try lightning_rod.Simulation(@TypeOf(plugins)).init(allocator, init.io, &store, .{
        .memory_bytes = 16 * 1024 * 1024,
        .metrics = .{ .enabled = false },
        .autosave = .{ .ticks = null },
    });
    try simulation.initialize(plugins, .{ .metrics = &simulation.metrics });
    const world = simulation.get(vanilla.VanillaWorlds).overworld;
    const sections = simulation.get(vanilla.Chunks);
    var cursor: usize = 0;
    const total_sections = side * side * section_count;
    while (cursor < total_sections) {
        var requests: [batch_sections]chunks.Section = undefined;
        var leases: [batch_sections]chunks.Lease = undefined;
        const count = @min(batch_sections, total_sections - cursor);
        for (requests[0..count], cursor..) |*request, index| request.* = .{
            .world = world,
            .x = @as(i32, @intCast(index / section_count / side)) - side / 2,
            .z = @as(i32, @intCast(index / section_count % side)) - side / 2,
            .y = dimension.minimum_section + @as(i32, @intCast(index % section_count)),
        };
        try sections.acquireMany(requests[0..count], leases[0..count]);
        for (leases[0..count]) |lease| lease.release();
        cursor += count;
    }
    try simulation.tick();
    try simulation.close(.fromNow(init.io, .{ .clock = .awake, .raw = .fromSeconds(30) }));
    simulation.deinit(allocator);
    std.debug.print("Prepared {d} columns, {d} sections in {s}\n", .{ side * side, side * side * section_count, path });
}
