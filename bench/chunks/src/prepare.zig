const std = @import("std");
const nbt = @import("nbt");
const anvil = @import("anvil.zig");
const corpus = @import("corpus.zig");
const common = @import("common.zig");

const origins = corpus.origins;
const password = "lightning-rod-benchmark";
const Options = struct {
    output: []const u8 = ".zig-cache/world-bench",
    server: ?[]const u8 = null,
    world: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    side: u32 = 32,
    seed: i64 = 20261017,
    port: u16 = 25590,
    data_version: i32 = 4903,
};

const Rcon = struct {
    stream: std.Io.net.Stream,
    sequence: i32 = 0,

    fn command(self: *Rcon, io: std.Io, kind: i32, text: []const u8) !void {
        self.sequence += 1;
        var send: [4096]u8 = undefined;
        if (text.len > send.len - 14) return error.CommandTooLong;
        std.mem.writeInt(i32, send[0..4], @intCast(text.len + 10), .little);
        std.mem.writeInt(i32, send[4..8], self.sequence, .little);
        std.mem.writeInt(i32, send[8..12], kind, .little);
        @memcpy(send[12..][0..text.len], text);
        @memset(send[12 + text.len ..][0..2], 0);
        var writer = self.stream.writer(io, &.{});
        try writer.interface.writeAll(send[0 .. text.len + 14]);
        var receive: [4096]u8 = undefined;
        var reader = self.stream.reader(io, &receive);
        const size = try reader.interface.takeInt(i32, .little);
        if (size < 10 or size > 1024 * 1024) return error.InvalidRconResponse;
        if (try reader.interface.takeInt(i32, .little) != self.sequence) return error.RconRequestFailed;
        _ = try reader.interface.discardAll(@intCast(size - 4));
    }
};

fn checkedRun(init: std.process.Init, argv: []const []const u8, directory: []const u8, log_path: []const u8) !void {
    const log = try std.Io.Dir.cwd().createFile(init.io, log_path, .{});
    defer log.close(init.io);
    var child = try std.process.spawn(init.io, .{ .argv = argv, .cwd = .{ .path = directory }, .environ_map = init.environ_map, .stdin = .ignore, .stdout = .{ .file = log }, .stderr = .{ .file = log } });
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0) return error.JavaProcessFailed;
}

fn generate(init: std.process.Init, options: Options, work: []const u8, world: []const u8, server: []const u8) !void {
    const allocator = init.arena.allocator();
    const identity_path = try std.fs.path.join(allocator, &.{ work, "identity.json" });
    const identity = try std.json.Stringify.valueAlloc(allocator, .{ .seed = options.seed, .side = options.side, .data_version = options.data_version }, .{});
    const previous = common.readFile(allocator, init.io, identity_path, 4096) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (previous) |bytes| if (!std.mem.eql(u8, bytes, identity)) return error.GeneratorIdentityChanged;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = identity_path, .data = identity });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ work, "eula.txt" }), .data = "eula=true\n" });
    const properties = try std.fmt.allocPrint(allocator, "server-ip=127.0.0.1\nserver-port={d}\nonline-mode=false\nenable-rcon=true\nrcon.port={d}\nrcon.password={s}\nlevel-seed={d}\nview-distance=2\nsimulation-distance=2\nspawn-protection=0\nmax-players=1\npause-when-empty-seconds=-1\nmax-tick-time=-1\nsync-chunk-writes=false\n", .{ options.port, options.port + 1, password, options.seed });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ work, "server.properties" }), .data = properties });
    const log = try std.Io.Dir.cwd().createFile(init.io, try std.fs.path.join(allocator, &.{ work, "server.log" }), .{});
    defer log.close(init.io);
    var child = try std.process.spawn(init.io, .{ .argv = &.{ "java", "-Xms512M", "-Xmx3G", "-jar", server, "nogui" }, .cwd = .{ .path = work }, .environ_map = init.environ_map, .stdin = .pipe, .stdout = .{ .file = log }, .stderr = .{ .file = log } });
    defer if (child.id != null) child.kill(init.io);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", options.port + 1);
    var rcon: ?Rcon = null;
    for (0..720) |_| {
        const stream = address.connect(init.io, .{ .mode = .stream }) catch {
            try std.Io.sleep(init.io, .fromMilliseconds(250), .awake);
            continue;
        };
        rcon = .{ .stream = stream };
        break;
    }
    var control = rcon orelse return error.ServerStartupTimeout;
    defer control.stream.close(init.io);
    try control.command(init.io, 3, password);
    try control.command(init.io, 2, "forceload remove all");
    try control.command(init.io, 2, "gamerule random_tick_speed 0");
    var reader = try anvil.Reader.init(init.gpa, init.io, world, options.data_version);
    defer {
        init.gpa.free(reader.region);
        init.gpa.free(reader.nodes);
        init.gpa.free(reader.bytes);
    }
    var completed: u32 = 0;
    for (origins) |origin| {
        var bx: i32 = 0;
        while (bx < options.side) : (bx += 16) {
            var bz: i32 = 0;
            while (bz < options.side) : (bz += 16) {
                const x0 = origin[0] + bx;
                const z0 = origin[1] + bz;
                const x1 = origin[0] + @min(bx + 16, options.side) - 1;
                const z1 = origin[1] + @min(bz + 16, options.side) - 1;
                const command = try std.fmt.allocPrint(allocator, "forceload add {d} {d} {d} {d}", .{ x0 * 16, z0 * 16, x1 * 16, z1 * 16 });
                var ready = false;
                var forced = false;
                for (0..300) |attempt| {
                    ready = true;
                    var x = x0;
                    while (x <= x1) : (x += 1) {
                        var z = z0;
                        while (z <= z1) : (z += 1) {
                            _ = reader.load(x, z) catch |err| switch (err) {
                                error.FileNotFound, error.ChunkNotGenerated => {
                                    ready = false;
                                    continue;
                                },
                                else => return err,
                            };
                        }
                    }
                    if (ready) break;
                    if (!forced) {
                        try control.command(init.io, 2, command);
                        forced = true;
                    }
                    if (attempt != 0) try std.Io.sleep(init.io, .fromSeconds(1), .awake);
                    try control.command(init.io, 2, "save-all flush");
                }
                if (!ready) return error.GenerationTimeout;
                if (forced) try control.command(init.io, 2, "forceload remove all");
                completed += @intCast((x1 - x0 + 1) * (z1 - z0 + 1));
                std.debug.print("Generated {d}/{d} columns\n", .{ completed, options.side * options.side * origins.len });
            }
        }
    }
    try control.command(init.io, 2, "save-all flush");
    // Stdin avoids losing the stop response when the RCON listener closes.
    try child.stdin.?.writeStreamingAll(init.io, "stop\n");
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0) return error.ServerShutdownFailed;
}

fn exportWorld(init: std.process.Init, options: Options, world: []const u8, registry_path: []const u8) !void {
    const allocator = init.arena.allocator();
    var reader = try anvil.Reader.init(allocator, init.io, world, options.data_version);
    const registry = try anvil.Registry.load(allocator, init.io, registry_path);
    const anvil_directory = try std.fs.path.join(allocator, &.{ options.output, "anvil", "region" });
    try std.Io.Dir.cwd().deleteTree(init.io, anvil_directory);
    try std.Io.Dir.cwd().createDirPath(init.io, anvil_directory);
    const registry_bytes = try common.readFile(allocator, init.io, registry_path, 32 * 1024 * 1024);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ options.output, "registry.json" }), .data = registry_bytes });
    const count = origins.len * options.side * options.side;
    const index = try allocator.alloc([24]u8, count);
    const path = try std.fs.path.join(allocator, &.{ options.output, "corpus.partial" });
    const output = try std.Io.Dir.cwd().createFile(init.io, path, .{ .read = true });
    defer output.close(init.io);
    var header: [16]u8 = undefined;
    @memcpy(header[0..8], "LRWORLD2");
    std.mem.writeInt(u32, header[8..12], @intCast(count), .little);
    std.mem.writeInt(i16, header[12..14], corpus.minimum_y, .little);
    std.mem.writeInt(i16, header[14..16], corpus.section_count, .little);
    try output.writePositionalAll(init.io, &header, 0);
    var offset: u64 = 16 + @as(u64, count) * 24;
    var at: usize = 0;
    var anvil_submitted_bytes: u64 = 0;
    var section_buffer: [corpus.section_bytes]u8 = undefined;
    // Numeric x,z order is shared with the corpus lookup and trace generator.
    for ([_]i32{ 0, 128 }) |ox| {
        var dx: i32 = 0;
        while (dx < options.side) : (dx += 1) {
            for ([_]i32{ 0, 128 }) |oz| {
                var dz: i32 = 0;
                while (dz < options.side) : (dz += 1) {
                    const x = ox + dx;
                    const z = oz + dz;
                    const doc = try reader.load(x, z);
                    anvil_submitted_bytes += try anvil.writeTerrain(init.gpa, init.io, anvil_directory, doc);
                    var sections: [corpus.section_count]?nbt.Node = @splat(null);
                    const list = doc.childNamed("sections") orelse return error.MissingSections;
                    var iterator = list.childIterator(doc.nodes);
                    while (iterator.next()) |node| {
                        const y = try (node.childNamed(doc.nodes, "Y") orelse return error.MissingSectionY).byte();
                        if (y < corpus.minimum_y or y >= corpus.minimum_y + corpus.section_count) continue;
                        const i: usize = @intCast(y - corpus.minimum_y);
                        if (sections[i] != null) return error.DuplicateSection;
                        sections[i] = node;
                    }
                    const heightmaps = doc.childNamed("Heightmaps") orelse return error.MissingHeightmap;
                    const heightmap = try (heightmaps.childNamed(doc.nodes, "WORLD_SURFACE") orelse return error.MissingHeightmap).longArray();
                    if (heightmap.len() != 37) return error.InvalidHeightmap;
                    const height: u64 = @bitCast(heightmap.get(136 / 7));
                    const surface_y = @as(i32, @intCast((height >> ((136 % 7) * 9)) & 511)) - 65;
                    const row = &index[at];
                    std.mem.writeInt(i32, row[0..4], x, .little);
                    std.mem.writeInt(i32, row[4..8], z, .little);
                    std.mem.writeInt(i32, row[8..12], surface_y, .little);
                    std.mem.writeInt(u32, row[12..16], 0, .little);
                    std.mem.writeInt(u64, row[16..24], offset, .little);
                    for (sections) |node| {
                        const bytes = try anvil.section(init.gpa, &registry, doc, node, &section_buffer);
                        var length: [2]u8 = undefined;
                        std.mem.writeInt(u16, &length, @intCast(bytes.len), .little);
                        try output.writePositionalAll(init.io, &length, offset);
                        try output.writePositionalAll(init.io, bytes, offset + 2);
                        offset += 2 + bytes.len;
                    }
                    at += 1;
                }
            }
        }
    }
    std.debug.assert(at == index.len);
    try output.writePositionalAll(init.io, std.mem.sliceAsBytes(index), 16);
    const final = try std.fs.path.join(allocator, &.{ options.output, "corpus.bin" });
    try std.Io.Dir.cwd().rename(path, .cwd(), final, init.io);
    var loaded = try corpus.Corpus.load(allocator, init.io, final);
    defer loaded.deinit(allocator, init.io);
    const manifest = try std.json.Stringify.valueAlloc(allocator, .{ .format = "LRWORLD2", .seed = if (options.world == null) options.seed else @as(?i64, null), .source = world, .data_version = options.data_version, .side = options.side, .origins = origins, .registry_sha256 = &registry.hash, .corpus_sha256 = &loaded.hash, .columns = count, .sections = count * corpus.section_count, .bytes = offset, .anvil_submitted_bytes = anvil_submitted_bytes, .scope = "Overworld block states only. No entities, inventories, lighting, or heightmaps." }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ options.output, "corpus.json" }), .data = manifest });
    std.debug.print("Exported {d} columns, {d} sections, {d} bytes. SHA256 {s}\n", .{ count, count * corpus.section_count, offset, loaded.hash });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var options: Options = .{};
    var at: usize = 1;
    while (at < args.len) : (at += 2) {
        if (at + 1 == args.len) return error.MissingArgument;
        const flag = args[at];
        const value = args[at + 1];
        if (std.mem.eql(u8, flag, "--output")) options.output = value else if (std.mem.eql(u8, flag, "--world")) options.world = value else if (std.mem.eql(u8, flag, "--server")) options.server = value else if (std.mem.eql(u8, flag, "--registry")) options.registry = value else if (std.mem.eql(u8, flag, "--seed")) options.seed = try std.fmt.parseInt(i64, value, 10) else if (std.mem.eql(u8, flag, "--side")) options.side = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, flag, "--port")) options.port = try std.fmt.parseInt(u16, value, 10) else if (std.mem.eql(u8, flag, "--data-version")) options.data_version = try std.fmt.parseInt(i32, value, 10) else return error.UnknownOption;
    }
    if (options.side < 8 or options.side > corpus.origin_stride or options.port < 1024 or options.port == 65535) return error.InvalidConfiguration;
    options.output = try std.fs.path.resolve(allocator, &.{options.output});
    try std.Io.Dir.cwd().createDirPath(init.io, options.output);
    const work = try std.fs.path.join(allocator, &.{ options.output, "generator" });
    try std.Io.Dir.cwd().createDirPath(init.io, work);
    const world = if (options.world) |path| try std.fs.path.resolve(allocator, &.{path}) else try std.fs.path.join(allocator, &.{ work, "world" });
    const registry = if (options.registry) |path| try std.fs.path.resolve(allocator, &.{path}) else try std.fs.path.join(allocator, &.{ work, "generated/reports/blocks.json" });
    if (options.server) |path| {
        const server = try std.fs.path.resolve(allocator, &.{path});
        if (options.registry == null) try checkedRun(init, &.{ "java", "-DbundlerMainClass=net.minecraft.data.Main", "-jar", server, "--reports", "--output", "generated" }, work, try std.fs.path.join(allocator, &.{ work, "reports.log" }));
        if (options.world == null) try generate(init, options, work, world, server);
    } else if (options.world == null or options.registry == null) {
        std.debug.print("Use --server /absolute/path/server.jar to pregenerate, or --world PATH --registry blocks.json to import.\n", .{});
        return error.MissingVanillaInputs;
    }
    try exportWorld(init, options, world, registry);
}
