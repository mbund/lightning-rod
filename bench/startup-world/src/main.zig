const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const chunks = @import("chunks");
const records = @import("records");

const side = 64;
const columns_per_batch = 8;
const dimension = vanilla.VanillaWorlds.dimensions.overworld;
const section_count: usize = dimension.section_count;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse return error.MissingWorldPath;
    if (args.next() != null) return error.UnexpectedArgument;
    var store = try lightning_rod.storage.Store.init(allocator, init.io, .{ .path = path });
    defer store.deinit();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(records.Workspaces, .{}),
        lightning_rod.plugin.configured(vanilla.RegistryIdentity, .{}),
        lightning_rod.plugin.configured(vanilla.Worlds, .{}),
        lightning_rod.plugin.configured(vanilla.VanillaWorlds, .{}),
        lightning_rod.plugin.configured(vanilla.Chunks, .{ .demand_sections = 0, .cache_sections = columns_per_batch * section_count }),
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
    for (0..side) |x| for (0..side / columns_per_batch) |batch| {
        var requests: [columns_per_batch * section_count]chunks.Section = undefined;
        var leases: [requests.len]chunks.Lease = undefined;
        for (0..columns_per_batch) |column| for (0..section_count) |y| {
            requests[column * section_count + y] = .{
                .world = world,
                .x = @as(i32, @intCast(x)) - side / 2,
                .z = @as(i32, @intCast(batch * columns_per_batch + column)) - side / 2,
                .y = dimension.minimum_section + @as(i32, @intCast(y)),
            };
        };
        try sections.acquireMany(&requests, &leases);
        for (leases) |lease| lease.release();
    };
    try simulation.tick();
    try simulation.close(.fromNow(init.io, .{ .clock = .awake, .raw = .fromSeconds(30) }));
    simulation.deinit(allocator);
    std.debug.print("Prepared {d} columns, {d} sections in {s}\n", .{ side * side, side * side * section_count, path });
}
