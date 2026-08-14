const std = @import("std");
const mcc = @import("minecraft_conformance");
const VanillaAdapter = @import("vanilla_conformance_adapter").VanillaAdapter;
const scenarios = @import("conformance_scenarios");
const worldgen = @import("worldgen");

const harness_project_dir = "tools/vanilla-harness";
const SnapshotStage = enum { noise, surface, carvers, features };
const WorldgenQuery = union(enum) {
    snapshot: struct {
        seed: i64,
        chunk_x: i32,
        chunk_z: i32,
        stage: SnapshotStage,
    },
    feature_indices,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    var selected: std.ArrayListUnmanaged(*const scenarios.Scenario) = .empty;
    defer selected.deinit(init.gpa);
    var argument = args.next();
    if (argument != null and std.mem.eql(u8, argument.?, "--dump-feature-indices")) {
        if (args.next() != null) return error.UnexpectedArgument;
        const cwd_path = try std.process.currentPathAlloc(init.io, init.gpa);
        defer init.gpa.free(cwd_path);
        return runWorldgenQuery(init, cwd_path, .feature_indices);
    }
    if (argument != null and
        (std.mem.eql(u8, argument.?, "--snapshot-noise-chunk") or
            std.mem.eql(u8, argument.?, "--snapshot-surface-chunk") or
            std.mem.eql(u8, argument.?, "--snapshot-carvers-chunk") or
            std.mem.eql(u8, argument.?, "--snapshot-features-chunk")))
    {
        const stage: SnapshotStage = if (std.mem.eql(u8, argument.?, "--snapshot-noise-chunk"))
            .noise
        else if (std.mem.eql(u8, argument.?, "--snapshot-surface-chunk"))
            .surface
        else if (std.mem.eql(u8, argument.?, "--snapshot-carvers-chunk"))
            .carvers
        else
            .features;
        const seed_text = args.next() orelse return error.MissingWorldSeed;
        const chunk_x_text = args.next() orelse return error.MissingChunkX;
        const chunk_z_text = args.next() orelse return error.MissingChunkZ;
        if (args.next() != null) return error.UnexpectedArgument;
        const seed = try std.fmt.parseInt(i64, seed_text, 10);
        const chunk_x = try std.fmt.parseInt(i32, chunk_x_text, 10);
        const chunk_z = try std.fmt.parseInt(i32, chunk_z_text, 10);
        const cwd_path = try std.process.currentPathAlloc(init.io, init.gpa);
        defer init.gpa.free(cwd_path);
        return runWorldgenQuery(init, cwd_path, .{ .snapshot = .{
            .seed = seed,
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .stage = stage,
        } });
    }
    while (argument) |name| : (argument = args.next()) {
        if (std.mem.eql(u8, name, "--list")) {
            for (scenarios.all) |scenario| if (scenario.vanilla) std.debug.print("{s}\n", .{scenario.name});
            return;
        }
        const scenario = scenarios.find(name) orelse return error.UnknownConformanceScenario;
        if (!scenario.vanilla) return error.LightningRodPolicyCannotRunOnVanilla;
        try selected.append(init.gpa, scenario);
    }
    if (selected.items.len == 0) for (&scenarios.all) |*scenario| if (scenario.vanilla) try selected.append(init.gpa, scenario);

    const cwd_path = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd_path);
    for (selected.items, 0..) |scenario, index| try runOne(init, cwd_path, scenario, index);
    std.debug.print("Vanilla passed all {d} Zig scenario{s}\n", .{ selected.items.len, if (selected.items.len == 1) "" else "s" });
}

fn runWorldgenQuery(
    init: std.process.Init,
    cwd_path: []const u8,
    query: WorldgenQuery,
) !void {
    const seed: i64 = switch (query) {
        .snapshot => |snapshot| snapshot.seed,
        .feature_indices => 0,
    };
    const process_id = std.os.linux.getpid();
    var relative_run_buffer: [256]u8 = undefined;
    const relative_run = try std.fmt.bufPrint(
        &relative_run_buffer,
        ".cache/vanilla-worldgen-{d}",
        .{process_id},
    );
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(init.io, relative_run);
    try cwd.createDirPath(init.io, relative_run);
    try cwd.createDirPath(init.io, harness_project_dir ++ "/logs");
    defer cwd.deleteTree(init.io, relative_run) catch {};
    const eula_path = try std.fmt.allocPrint(init.gpa, "{s}/eula.txt", .{relative_run});
    defer init.gpa.free(eula_path);
    try cwd.writeFile(init.io, .{ .sub_path = eula_path, .data = "eula=true\n" });
    const properties_path = try std.fmt.allocPrint(init.gpa, "{s}/server.properties", .{relative_run});
    defer init.gpa.free(properties_path);
    var properties_buffer: [4096]u8 = undefined;
    var properties = std.Io.Writer.fixed(&properties_buffer);
    try properties.print(
        \\server-port=0
        \\online-mode=false
        \\enable-status=false
        \\level-name=world
        \\level-seed={d}
        \\level-type=minecraft:normal
        \\generate-structures=false
        \\spawn-animals=false
        \\spawn-monsters=false
        \\spawn-npcs=false
        \\view-distance=2
        \\simulation-distance=2
        \\max-tick-time=-1
        \\pause-when-empty-seconds=-1
        \\
    , .{seed});
    try cwd.writeFile(init.io, .{ .sub_path = properties_path, .data = properties.buffered() });

    const absolute_run = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ cwd_path, relative_run });
    defer init.gpa.free(absolute_run);
    const socket_path = try std.fmt.allocPrint(init.gpa, "/tmp/mcc-vanilla-worldgen-{d}.sock", .{process_id});
    defer init.gpa.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(init.io, socket_path) catch {};
    const socket_argument = try std.fmt.allocPrint(init.gpa, "-PharnessSocket={s}", .{socket_path});
    defer init.gpa.free(socket_argument);
    const run_argument = try std.fmt.allocPrint(init.gpa, "-PharnessRunDir={s}", .{absolute_run});
    defer init.gpa.free(run_argument);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ "gradle", socket_argument, run_argument, "runServer", "--args=nogui" },
        .cwd = .{ .path = harness_project_dir },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);
    {
        var adapter = try connectEventually(init, socket_path);
        defer adapter.deinit();
        switch (query) {
            .feature_indices => {
                const entries = try adapter.featureIndices();
                defer {
                    for (entries) |entry| init.gpa.free(entry);
                    init.gpa.free(entries);
                }
                for (entries) |entry| std.debug.print("{s}\n", .{entry});
            },
            .snapshot => |snapshot_query| {
                var snapshot = switch (snapshot_query.stage) {
                    .noise => try adapter.snapshotNoiseChunk(snapshot_query.chunk_x, snapshot_query.chunk_z),
                    .surface => try adapter.snapshotSurfaceChunk(snapshot_query.chunk_x, snapshot_query.chunk_z),
                    .carvers => try adapter.snapshotCarversChunk(snapshot_query.chunk_x, snapshot_query.chunk_z),
                    .features => try adapter.snapshotFeaturesChunk(snapshot_query.chunk_x, snapshot_query.chunk_z),
                };
                defer snapshot.deinit(init.gpa);
                if (snapshot_query.stage == .noise)
                    try printNoiseSnapshot(&snapshot)
                else
                    try printSurfaceSnapshot(&snapshot);
                try compareGeneratedSnapshot(init.gpa, seed, &snapshot, snapshot_query.stage);
            },
        }
    }
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| if (code != 0) return error.VanillaHarnessExitedWithFailure,
        else => return error.VanillaHarnessTerminated,
    }
}

fn compareGeneratedSnapshot(
    allocator: std.mem.Allocator,
    seed: i64,
    snapshot: *const @import("vanilla_conformance_adapter").ChunkSnapshot,
    stage: SnapshotStage,
) !void {
    var generator = try worldgen.chunk.Generator.init(allocator, @bitCast(seed));
    defer generator.deinit();
    const base = try allocator.alloc(worldgen.aquifer.Material, worldgen.chunk.block_count);
    defer allocator.free(base);
    try generator.fillBaseMaterials(snapshot.chunk_x, snapshot.chunk_z, base);

    const states = try allocator.alloc(worldgen.generated_state.GeneratedState, worldgen.chunk.block_count);
    defer allocator.free(states);
    if (stage != .noise) {
        try generator.applySurface(snapshot.chunk_x, snapshot.chunk_z, base, states);
        if (stage == .carvers or stage == .features)
            try generator.applyCarvers(snapshot.chunk_x, snapshot.chunk_z, states);
        if (stage == .features)
            try generator.applyFeatures(snapshot.chunk_x, snapshot.chunk_z, states);
    } else {
        for (base, states) |material, *state| state.* = .{ .base = material };
    }

    var mismatches: usize = 0;
    for (snapshot.blocks, states, 0..) |palette_index, actual, index| {
        const expected = snapshot.block_palette[palette_index];
        const actual_name = actual.canonicalName();
        const equivalent = if (stage != .noise)
            std.mem.eql(u8, expected, actual_name)
        else
            normalizedMaterial(expected) == normalizedMaterial(actual_name);
        if (equivalent) continue;
        if (mismatches < 32) {
            const local_y: i32 = @intCast(index / (16 * 16));
            const within_y = index % (16 * 16);
            const local_z: i32 = @intCast(within_y / 16);
            const local_x: i32 = @intCast(within_y % 16);
            std.debug.print(
                "  mismatch ({d},{d},{d}): Vanilla={s} Zig={s}\n",
                .{
                    snapshot.chunk_x * 16 + local_x,
                    snapshot.min_y + local_y,
                    snapshot.chunk_z * 16 + local_z,
                    expected,
                    actual_name,
                },
            );
        }
        mismatches += 1;
    }
    std.debug.print("Zig comparison: {d} block mismatches\n", .{mismatches});
    if (mismatches != 0) {
        std.debug.print("Zig counts for Vanilla palette states:\n", .{});
        for (snapshot.block_palette) |name| {
            var count: usize = 0;
            for (states) |state| if (std.mem.eql(u8, state.canonicalName(), name)) {
                count += 1;
            };
            std.debug.print("  {s}: {d}\n", .{ name, count });
        }
    }
}

fn normalizedMaterial(name: []const u8) u2 {
    if (std.mem.eql(u8, name, "minecraft:air")) return 1;
    if (std.mem.startsWith(u8, name, "minecraft:water")) return 2;
    if (std.mem.startsWith(u8, name, "minecraft:lava")) return 3;
    return 0;
}

fn printSurfaceSnapshot(snapshot: *const @import("vanilla_conformance_adapter").ChunkSnapshot) !void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (snapshot.blocks) |palette_index| {
        const name = snapshot.block_palette[palette_index];
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    std.debug.print(
        "Vanilla surface chunk coordinates=({d},{d}) min_y={d} height={d}\n" ++
            "block_state_sha256={x}\n" ++
            "palette ({d} states):\n",
        .{
            snapshot.chunk_x,
            snapshot.chunk_z,
            snapshot.min_y,
            snapshot.height,
            digest,
            snapshot.block_palette.len,
        },
    );
    const counts = try std.heap.page_allocator.alloc(usize, snapshot.block_palette.len);
    defer std.heap.page_allocator.free(counts);
    @memset(counts, 0);
    for (snapshot.blocks) |palette_index| counts[palette_index] += 1;
    for (snapshot.block_palette, counts) |name, count|
        std.debug.print("  {s}: {d}\n", .{ name, count });
    try printBiomeSnapshot(snapshot);
}

fn printNoiseSnapshot(snapshot: *const @import("vanilla_conformance_adapter").ChunkSnapshot) !void {
    var counts = [_]usize{0} ** 4;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (snapshot.blocks) |palette_index| {
        const name = snapshot.block_palette[palette_index];
        const material: u8 = if (std.mem.eql(u8, name, "minecraft:air"))
            1
        else if (std.mem.startsWith(u8, name, "minecraft:water"))
            2
        else if (std.mem.startsWith(u8, name, "minecraft:lava"))
            3
        else
            0;
        counts[material] += 1;
        hash.update(&.{material});
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    std.debug.print(
        "Vanilla noise chunk seed-independent-coordinates=({d},{d}) min_y={d} height={d}\n" ++
            "materials stone={d} air={d} water={d} lava={d}\n" ++
            "material_sha256={x}\n",
        .{
            snapshot.chunk_x,
            snapshot.chunk_z,
            snapshot.min_y,
            snapshot.height,
            counts[0],
            counts[1],
            counts[2],
            counts[3],
            digest,
        },
    );
    try printBiomeSnapshot(snapshot);
}

fn printBiomeSnapshot(snapshot: *const @import("vanilla_conformance_adapter").ChunkSnapshot) !void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const counts = try std.heap.page_allocator.alloc(usize, snapshot.biome_palette.len);
    defer std.heap.page_allocator.free(counts);
    @memset(counts, 0);
    for (snapshot.biomes) |palette_index| {
        const name = snapshot.biome_palette[palette_index];
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
        counts[palette_index] += 1;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    std.debug.print("biome_sha256={x}\nbiomes ({d}):\n", .{ digest, snapshot.biome_palette.len });
    for (snapshot.biome_palette, counts) |name, count|
        std.debug.print("  {s}: {d}\n", .{ name, count });
}

fn runOne(init: std.process.Init, cwd_path: []const u8, scenario: *const scenarios.Scenario, index: usize) !void {
    const definition = mcc.fixture.builtin(scenario.fixture_id) orelse return error.UnknownFixture;

    const process_id = std.os.linux.getpid();
    var relative_run_buffer: [256]u8 = undefined;
    const relative_run = try std.fmt.bufPrint(&relative_run_buffer, ".cache/vanilla-harness-{d}-{d}", .{ process_id, index });
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(init.io, relative_run);
    try cwd.createDirPath(init.io, relative_run);
    // Loom's generated Log4j configuration is loaded before Minecraft and,
    // on some JDK/Gradle combinations, resolves relative paths against the
    // Fabric project despite the disposable game working directory.
    try cwd.createDirPath(init.io, harness_project_dir ++ "/logs");
    var logs_path_buffer: [320]u8 = undefined;
    const logs_path = try std.fmt.bufPrint(&logs_path_buffer, "{s}/logs", .{relative_run});
    try cwd.createDirPath(init.io, logs_path);
    defer cwd.deleteTree(init.io, relative_run) catch {};
    const eula_path = try std.fmt.allocPrint(init.gpa, "{s}/eula.txt", .{relative_run});
    defer init.gpa.free(eula_path);
    try cwd.writeFile(init.io, .{ .sub_path = eula_path, .data = "eula=true\n" });
    const properties_path = try std.fmt.allocPrint(init.gpa, "{s}/server.properties", .{relative_run});
    defer init.gpa.free(properties_path);
    var properties_buffer: [4096]u8 = undefined;
    var properties = std.Io.Writer.fixed(&properties_buffer);
    try properties.print(
        \\server-port=0
        \\online-mode=false
        \\enforce-secure-profile=false
        \\enable-status=false
        \\level-name=world
        \\level-seed={d}
        \\level-type=minecraft:flat
        \\generate-structures=false
        \\gamemode=survival
        \\force-gamemode=true
        \\difficulty=normal
        \\spawn-animals=true
        \\spawn-monsters=true
        \\spawn-npcs=false
        \\spawn-protection=0
        \\view-distance=2
        \\simulation-distance=2
        \\max-players=8
        \\max-tick-time=-1
        \\pause-when-empty-seconds=-1
        \\allow-flight=true
        \\
    , .{definition.seed});
    try cwd.writeFile(init.io, .{ .sub_path = properties_path, .data = properties.buffered() });

    const absolute_run = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ cwd_path, relative_run });
    defer init.gpa.free(absolute_run);
    const socket_path = try std.fmt.allocPrint(init.gpa, "/tmp/mcc-vanilla-{d}-{d}.sock", .{ process_id, index });
    defer init.gpa.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(init.io, socket_path) catch {};
    const socket_argument = try std.fmt.allocPrint(init.gpa, "-PharnessSocket={s}", .{socket_path});
    defer init.gpa.free(socket_argument);
    const run_argument = try std.fmt.allocPrint(init.gpa, "-PharnessRunDir={s}", .{absolute_run});
    defer init.gpa.free(run_argument);

    std.debug.print("Vanilla scenario: {s}\n", .{scenario.name});
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ "gradle", socket_argument, run_argument, "runServer", "--args=nogui" },
        .cwd = .{ .path = harness_project_dir },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);

    {
        var target = try connectEventually(init, socket_path);
        defer target.deinit();
        try VanillaAdapter.targetInfo().require(mcc.black_box_capabilities);
        try scenario.run(target.adapter(), init.gpa);
    }
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| if (code != 0) return error.VanillaHarnessExitedWithFailure,
        else => return error.VanillaHarnessTerminated,
    }
    std.debug.print("Vanilla passed: {s}\n", .{scenario.name});
}

fn connectEventually(init: std.process.Init, socket_path: []const u8) !VanillaAdapter {
    var last_error: anyerror = error.ConnectionRefused;
    for (0..900) |_| {
        return VanillaAdapter.connect(init.gpa, init.io, socket_path) catch |err| {
            last_error = err;
            try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(100), .clock = .awake }, init.io);
            continue;
        };
    }
    std.debug.print("Vanilla harness did not become ready: {s}\n", .{@errorName(last_error)});
    return error.VanillaHarnessStartupTimeout;
}
