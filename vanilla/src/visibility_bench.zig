const std = @import("std");
const oracle = @import("oracle");
const topology = @import("topology");
const caves = @import("visibility_caves.zig");
const production = @import("section_visibility_world.zig");
const lighting = @import("lighting.zig");
const light_engine = @import("lighting");
const chunk_encoding = @import("chunk_encoding.zig");
const game_data = @import("game_data");
const chunks = @import("chunks");
const records = @import("records");
const storage = @import("storage");
const metrics = @import("metrics");
const worlds = @import("worlds");
const protocols = @import("protocols");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const minecraft_java = @import("minecraft_java");

const Options = struct {
    world: ?[]const u8 = null,
    scene: ?[]const u8 = null,
    radius: i32 = 1,
    caves: bool = false,
    camera_witnesses: bool = false,
    cave: ?caves.Kind = null,
    camera_samples: usize = 64,
    repeat_queries: usize = 0,
    search_radius: i32 = 8,
    feet: ?[3]i64 = null,
    nodes: usize = 262144,
    depth: usize = 1024,
    samples: usize = 1,
    output: ?[]const u8 = null,
    targets: []const [3]i32 = &.{},
};

const Scene = struct {
    grid: topology.Grid,
    blocks: []u16,
    biomes: [][64]u16,
    eye: oracle.Eye,

    fn init(allocator: std.mem.Allocator, radius: i32, minimum: i32, height: usize, feet: [3]i64) !Scene {
        const side: usize = @intCast(radius * 2 + 1);
        const grid: topology.Grid = .{ .minimum = .{ @as(i32, @intCast(@divFloor(feet[0], 16 * oracle.Eye.scale))) - radius, minimum, @as(i32, @intCast(@divFloor(feet[2], 16 * oracle.Eye.scale))) - radius }, .side = side, .height = height };
        var result: Scene = .{ .grid = grid, .blocks = try allocator.alloc(u16, grid.count() * 4096), .biomes = try allocator.alloc([64]u16, grid.count()), .eye = .{ .coordinates = feet } };
        result.eye.coordinates[1] += (oracle.Eye.scale * 162 / 100);
        @memset(result.blocks, 0);
        @memset(result.biomes, @splat(@intCast(game_data.registry.biomeId("minecraft:plains").?)));
        return result;
    }

    fn at(self: Scene, position: [3]i32) ?u16 {
        const section = self.grid.index(.{ @divFloor(position[0], 16), @divFloor(position[1], 16), @divFloor(position[2], 16) }) orelse return null;
        const local: usize = @intCast(@mod(position[1], 16) * 256 + @mod(position[2], 16) * 16 + @mod(position[0], 16));
        return self.blocks[section * 4096 + local];
    }

    fn synthetic(allocator: std.mem.Allocator, radius: i32, kind: []const u8) !Scene {
        const geode = std.mem.startsWith(u8, kind, "geode");
        const stacked = std.mem.eql(u8, kind, "stacked-caves");
        const cave = std.mem.eql(u8, kind, "bent-cave");
        const straight = std.mem.eql(u8, kind, "straight-tunnel");
        const winding = std.mem.eql(u8, kind, "winding-tunnel");
        const feet: [3]i64 = .{ 8500, if (stacked) 20000 else if (geode or cave or straight or winding) 24000 else 32000, 8500 };
        const scene = try Scene.init(allocator, radius, 0, 4, feet);
        const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
        for (0..scene.grid.count()) |section| {
            const position = scene.grid.position(section);
            for (scene.blocks[section * 4096 ..][0..4096], 0..) |*state, local| {
                const x = position[0] * 16 + @as(i32, @intCast(local % 16));
                const y = position[1] * 16 + @as(i32, @intCast(local / 256));
                const z = position[2] * 16 + @as(i32, @intCast(local / 16 % 16));
                state.* = if (y < (if (geode or cave or stacked) @as(i32, 40) else 32)) stone else 0;
                if (stacked and x >= 4 and z >= 4 and z < 12 and
                    ((y >= 20 and y < 24) or (y >= 28 and y < 32) or (x >= 32 and x < 40 and y >= 28))) state.* = 0;
                if (geode) {
                    const distance = (x - 8) * (x - 8) + (y - 24) * (y - 24) + (z - 8) * (z - 8);
                    if (distance < 36) state.* = 0 else if (distance < 64) state.* = @intCast(game_data.registry.block_amethyst_block_default_state);
                    if (std.mem.eql(u8, kind, "geode-opening") and x == 8 and y == 25 and z >= 8) state.* = 0;
                }
                if (cave and y >= 20 and y < 29 and ((x >= 5 and x < 12 and z >= 5 and z < 17) or (x >= 8 and x < 33 and z >= 13 and z < 18))) state.* = 0;
                if (straight or winding) {
                    const room = x >= 0 and x < 16 and y >= 16 and y < 32 and z >= 0 and z < 16;
                    const cavern = x >= 64 and x < 96 and y >= 16 and y < 40 and z >= -16 and z < 32;
                    const passage = x >= 16 and x < 64 and y >= 24 and y < 27;
                    const tunnel = if (straight or x < 35 or x >= 45) z >= 7 and z < 9 else if (x < 38 or x >= 42) z >= 7 and z < 15 else z >= 13 and z < 15;
                    state.* = if (room or cavern or (passage and tunnel)) 0 else stone;
                }
                if (std.mem.eql(u8, kind, "overhang") and x >= 14 and y >= 32 and y <= 48) state.* = stone;
                if (std.mem.eql(u8, kind, "forest")) {
                    if (@mod(x, 8) == 3 and @mod(z, 8) == 3 and y >= 32 and y <= 39) state.* = @intCast(game_data.registry.block_oak_log_default_state);
                    if (@mod(x, 8) >= 1 and @mod(x, 8) <= 5 and @mod(z, 8) >= 1 and @mod(z, 8) <= 5 and y >= 37 and y <= 41) state.* = @intCast(game_data.registry.block_oak_leaves_default_state);
                }
            }
        }
        return scene;
    }
};

const Snapshot = struct { world: u32, x: i32, z: i32, minimum: i32, count: usize, sections: []const lighting.Section };

const Neighborhood = struct {
    states: []u16,
    sections: []lighting.Section,

    fn init(allocator: std.mem.Allocator, height: usize) !Neighborhood {
        return .{ .states = try allocator.alloc(u16, 48 * (height + 2) * 16 * 48), .sections = try allocator.alloc(lighting.Section, 9 * height) };
    }

    fn load(self: Neighborhood, scene: Scene, x: i32, z: i32) Snapshot {
        @memset(self.states, 0);
        const height = scene.grid.height;
        for (0..9) |column| for (0..height) |y| {
            const at = [3]i32{ x + @as(i32, @intCast(column % 3)) - 1, scene.grid.minimum[1] + @as(i32, @intCast(y)), z + @as(i32, @intCast(column / 3)) - 1 };
            const id = scene.grid.index(at);
            const offset = ((y + 1) * 16 * 48 + column / 3 * 16) * 48 + column % 3 * 16;
            if (id) |index| for (0..16) |row_y| for (0..16) |row_z| {
                @memcpy(self.states[offset + (row_y * 48 + row_z) * 48 ..][0..16], scene.blocks[index * 4096 + (row_y * 16 + row_z) * 16 ..][0..16]);
            };
            self.sections[column * height + y] = .{ .stamp = .{ .generation = if (id) |index| index + 1 else 0 }, .view = .{ .rows = self.states[offset..] }, .biomes = if (id) |index| &scene.biomes[index] else null };
        };
        return .{ .world = 0, .x = x, .z = z, .minimum = scene.grid.minimum[1], .count = height, .sections = self.sections };
    }

    fn learn(self: Neighborhood, world: *production.World, scene: Scene, x: i32, z: i32) void {
        for (0..9) |column| {
            const at = [3]i32{ x + @as(i32, @intCast(column % 3)) - 1, scene.grid.minimum[1], z + @as(i32, @intCast(column / 3)) - 1 };
            if (scene.grid.index(at) == null) continue;
            world.learn(.{ .world = 0, .x = at[0], .z = at[2], .minimum = at[1] }, self.sections[column * scene.grid.height ..][0..scene.grid.height]);
        }
    }
};

fn loadWorld(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !Scene {
    try std.Io.Dir.cwd().access(init.io, options.world.?, .{});
    var registry = try metrics.Registry.init(allocator, init.io, .{ .capacity = 128 });
    defer registry.deinit();
    var store = try storage.Store.init(allocator, init.io, .{ .path = options.world.? });
    defer store.deinit();
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 16 }, .{ .storage = try store.openSpace(worlds.Worlds.id) });
    const dimension = (dimensions.find("minecraft:overworld") orelse return error.MissingOverworld).dimension;
    if (dimension.sectionCount() > 24) return error.UnsupportedWorldHeight;
    var feet = options.feet orelse .{ 8500, 65000, 8500 };
    const terrain = try chunks.Chunks.init(allocator, init.io, .{ .cache_sections = 48, .demand_sections = 24, .cache_groups = 16 }, .{ .metrics = &registry, .storage = try store.openSpace(chunks.Chunks.id), .record_workspaces = try records.Workspaces.init(allocator, init.io, .{}) });
    const Disk = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = error.MissingStoredSection;
        }
    };
    var disk: Disk = .{};
    terrain.setSource(chunks.Source.init(&disk, Disk.read));
    var scene = try Scene.init(allocator, options.radius, dimension.minimumSection(), dimension.sectionCount(), feet);
    for (0..scene.grid.count()) |index| {
        const at = scene.grid.position(index);
        const lease = try terrain.acquire(.{ .world = dimensions.find("minecraft:overworld").?.id, .x = at[0], .y = at[1], .z = at[2] });
        defer lease.release();
        for (scene.blocks[index * 4096 ..][0..4096], 0..) |*state, local| state.* = lease.get(@intCast(local));
        if (lease.biomes()) |biomes| {
            for (&scene.biomes[index], 0..) |*biome, local| biome.* = biomes.get(@intCast(local));
        } else {
            std.log.err("missing biomes in imported section {d},{d},{d}", .{ at[0], at[1], at[2] });
            return error.MissingStoredBiomes;
        }
    }
    if (options.feet == null) {
        var y = (dimension.minimumSection() + @as(i32, @intCast(dimension.sectionCount()))) * 16;
        while (y > dimension.minimumSection() * 16) {
            y -= 1;
            if (!game_data.physics.get(scene.at(.{ 8, y, 8 }).?).air) {
                feet[1] = (y + 1) * oracle.Eye.scale;
                scene.eye.coordinates[1] = feet[1] + (oracle.Eye.scale * 162 / 100);
                break;
            }
        }
    }
    return scene;
}

const Wire = struct {
    engine: light_engine.Engine,
    workspace: *chunk_encoding.Workspace,
    catalog: protocols.Default,
    compression: minecraft_java.Wire.Workspace,
    bytes: []u8,
    compressed: []u8,

    fn init(allocator: std.mem.Allocator, height: usize) !Wire {
        return .{ .engine = try light_engine.Engine.init(allocator, .{ .x = 48, .y = (height + 2) * 16, .z = 48 }, try game_data.lighting.init(allocator)), .workspace = try chunk_encoding.Workspace.init(allocator), .catalog = try protocols.Default.init(allocator), .compression = try minecraft_java.Wire.Workspace.init(allocator), .bytes = try allocator.alloc(u8, 1 << 21), .compressed = try allocator.alloc(u8, (1 << 21) + sessions.shared_headroom) };
    }

    fn size(self: *Wire, scene: Scene, column: usize, neighborhood: Neighborhood, mask: u32) !usize {
        const Version = protocols.version(game_data.canonical_version);
        const mapping: packets.Registry = .{ .entities = Version.Registry.canonical_entity_to_wire, .items = Version.Registry.canonical_item_to_wire, .blocks = Version.Registry.canonical_block_to_wire, .block_states = Version.Registry.canonical_block_state_to_wire, .block_state_bits = Version.Registry.block_state_bits, .sounds = Version.Registry.canonical_sound_to_wire, .effects = Version.Registry.canonical_effect_to_wire, .attributes = Version.Registry.canonical_attribute_to_wire };
        const position = scene.grid.position(column * scene.grid.height);
        var masks: [2]u32 = @splat(0);
        for (0..scene.grid.height + 2) |section| {
            if (self.engine.sectionNonempty(.block, .{ 1, section, 1 })) masks[0] |= @as(u32, 1) << @intCast(section);
            if (self.engine.sectionNonempty(.sky, .{ 1, section, 1 })) masks[1] |= @as(u32, 1) << @intCast(section);
        }
        const chunk: chunk_encoding.Chunk = .{ .x = position[0], .z = position[2], .minimum_section = position[1], .sections = neighborhood.sections[4 * scene.grid.height ..][0..scene.grid.height], .workspace = self.workspace, .biome = game_data.registry.biomeId("minecraft:plains").?, .light = .{ .source = .{ .computed = &self.engine }, .count = scene.grid.height + 2, .masks = masks }, .disclosure = mask, .concealment = 0 };
        const encoded = try sessions.packet_api.encode(Version, chunk_encoding.write, self.bytes, .{ mapping, chunk, &self.catalog.values[0] });
        if (encoded.len >= 256) return (try self.compression.compress(encoded, self.compressed)).len;
        return encoded.len + 1 + @as(usize, if (encoded.len + 1 < 128) 1 else 2);
    }
};

fn oracleSections(allocator: std.mem.Allocator, scene: Scene) ![]oracle.Section {
    const sections = try allocator.alloc(oracle.Section, scene.grid.count());
    for (sections, 0..) |*section, index| {
        section.* = .{ .position = scene.grid.position(index) };
        for (scene.blocks[index * 4096 ..][0..4096], 0..) |state, local| if (game_data.physics.rendering(state).occluder) {
            section.occluders[local / 64] |= @as(u64, 1) << @intCast(local % 64);
        };
    }
    return sections;
}

const Solution = struct {
    world: *production.World,
    query: production.Handle,
    cpu_ns: i96,
    reads: usize,
    visits: u64,
    mask_sha256: [64]u8,
};

fn learnSection(world: *production.World, scene: Scene, index: usize) void {
    const at = scene.grid.position(index);
    const states: *const [4096]u16 = scene.blocks[index * 4096 ..][0..4096];
    world.learnSection(.{ .world = 0, .x = at[0], .z = at[2], .minimum = scene.grid.minimum[1] }, scene.grid.height, @intCast(at[1] - scene.grid.minimum[1]), .{ .dense = states });
}

fn solve(io: std.Io, allocator: std.mem.Allocator, scene: Scene, warm: bool) !Solution {
    const world = try allocator.create(production.World);
    const radius: i32 = @intCast((scene.grid.side - 1) / 2);
    world.* = try .init(allocator, .{ .columns = (scene.grid.side + 2) * (scene.grid.side + 2), .sources = 1, .radius = radius });
    if (warm) for (0..scene.grid.count()) |index| learnSection(world, scene, index);
    return calculate(io, world, scene);
}

fn calculate(io: std.Io, world: *production.World, scene: Scene) !Solution {
    const radius: i32 = @intCast((scene.grid.side - 1) / 2);
    const visits = world.visits;
    const started = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
    const head = scene.eye.block();
    var requirements: [27]chunks.Section = undefined;
    for (production.World.sourceRequirements(0, scene.grid.minimum[1], scene.grid.height, head, &requirements)) |position| {
        const index = scene.grid.index(.{ position.x, position.y, position.z }) orelse return error.SourceOutsideScene;
        learnSection(world, scene, index);
    }
    var source_storage: production.Source = undefined;
    const source = world.source(0, scene.grid.minimum[1], scene.grid.height, head, &source_storage) orelse return error.MissingSource;
    world.beginPoll();
    const query = world.query(source, scene.grid.minimum[1], scene.grid.height, radius);
    var reads: usize = 0;
    var iterations: usize = 0;
    while (!world.ready(query)) {
        if (iterations > scene.grid.count() * 2) return error.VisibilityDidNotComplete;
        const missing = world.advance().requests;
        for (missing) |position| {
            const index = scene.grid.index(.{ position.x, position.y, position.z }) orelse return error.RequestOutsideScene;
            learnSection(world, scene, index);
            reads += 1;
        }
        iterations += 1;
    }
    const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - started;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..scene.grid.side * scene.grid.side) |column| {
        const at = scene.grid.position(column * scene.grid.height);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, world.mask(query, at[0], at[2]), .little);
        hash.update(&bytes);
    }
    return .{ .world = world, .query = query, .cpu_ns = elapsed, .reads = reads, .visits = world.visits - visits, .mask_sha256 = std.fmt.bytesToHex(hash.finalResult(), .lower) };
}

fn measure(io: std.Io, allocator: std.mem.Allocator, scene: Scene, warm: bool, samples: usize) !Solution {
    std.debug.assert(samples > 0 and samples <= 64);
    var solution = try solve(io, allocator, scene, warm);
    var timings: [64]i96 = undefined;
    timings[0] = solution.cpu_ns;
    for (1..samples) |index| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const repeated = if (warm) refresh: {
            solution.world.invalidateResults();
            break :refresh try calculate(io, solution.world, scene);
        } else try solve(io, arena.allocator(), scene, false);
        if (!std.mem.eql(u8, &solution.mask_sha256, &repeated.mask_sha256)) return error.NondeterministicVisibility;
        timings[index] = repeated.cpu_ns;
    }
    std.mem.sort(i96, timings[0..samples], {}, std.sort.asc(i96));
    solution.cpu_ns = timings[samples / 2];
    return solution;
}

fn cameraEyes(allocator: std.mem.Allocator, scene: Scene, samples: usize) ![]const oracle.Eye {
    std.debug.assert(samples <= 256);
    const side = 16 + 2 * production.camera_margin;
    const head = scene.eye.block();
    const state = scene.at(head) orelse return error.ObserverOutsideScene;
    if (game_data.physics.rendering(state).occluder) return error.ObserverInsideOccluder;
    var minimum: [3]i32 = undefined;
    for (&minimum, head) |*value, position| value.* = @divFloor(position, 16) * 16 - production.camera_margin;
    const seen = try allocator.alloc(bool, side * side * side);
    defer allocator.free(seen);
    @memset(seen, false);
    const queue = try allocator.alloc(u16, seen.len);
    defer allocator.free(queue);
    const start: usize = @intCast(((head[1] - minimum[1]) * side + head[2] - minimum[2]) * side + head[0] - minimum[0]);
    queue[0] = @intCast(start);
    seen[start] = true;
    var tail: usize = 1;
    var cursor: usize = 0;
    var best: [26][3]i32 = @splat(head);
    var scores: [26]i32 = @splat(std.math.minInt(i32));
    while (cursor < tail) : (cursor += 1) {
        const index = queue[cursor];
        const local = [3]usize{ index % side, index / (side * side), index / side % side };
        var point: [3]i32 = undefined;
        for (&point, minimum, local) |*value, base, offset| value.* = base + @as(i32, @intCast(offset));
        for (&best, &scores, 0..) |*candidate, *score, sample| {
            const direction = if (sample < 13) sample else sample + 1;
            var value: i32 = 0;
            var stride: usize = 1;
            for (point, head) |position, origin| {
                value += (position - origin) * (@as(i32, @intCast(direction / stride % 3)) - 1);
                stride *= 3;
            }
            if (value > score.*) {
                score.* = value;
                candidate.* = point;
            }
        }
        for ([_]usize{ 1, side * side, side }, 0..) |stride, axis| for (0..2) |direction| {
            if ((direction == 0 and local[axis] == 0) or (direction == 1 and local[axis] + 1 == side)) continue;
            const neighbor = if (direction == 0) index - stride else index + stride;
            if (seen[neighbor]) continue;
            seen[neighbor] = true;
            var at = point;
            at[axis] += if (direction == 0) @as(i32, -1) else 1;
            const neighbor_state = scene.at(at) orelse return error.CameraOutsideScene;
            if (game_data.physics.rendering(neighbor_state).occluder) continue;
            std.debug.assert(tail < queue.len);
            queue[tail] = @intCast(neighbor);
            tail += 1;
        };
    }
    var result: std.ArrayList(oracle.Eye) = .empty;
    errdefer result.deinit(allocator);
    for (best) |point| {
        const eye: oracle.Eye = .{ .coordinates = .{ @as(i64, point[0]) * 1000 + 500, @as(i64, point[1]) * 1000 + 500, @as(i64, point[2]) * 1000 + 500 } };
        var duplicate = false;
        for (result.items) |previous| duplicate = duplicate or std.meta.eql(previous, eye);
        if (!duplicate) try result.append(allocator, eye);
    }
    var random = std.Random.DefaultPrng.init(0x904fe31);
    for (0..samples) |_| {
        const index = queue[random.random().uintLessThan(usize, tail)];
        const local = [3]usize{ index % side, index / (side * side), index / side % side };
        var eye: oracle.Eye = .{ .coordinates = undefined };
        for (&eye.coordinates, minimum, local) |*value, base, offset| value.* = (@as(i64, base) + @as(i64, @intCast(offset))) * oracle.Eye.scale + oracle.Eye.scale / 2;
        var duplicate = false;
        for (result.items) |previous| duplicate = duplicate or std.meta.eql(previous, eye);
        if (!duplicate) try result.append(allocator, eye);
    }
    return result.toOwnedSlice(allocator);
}

test "camera witnesses are reproducible and cannot cross opaque walls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var scene = try Scene.init(arena.allocator(), 1, 0, 4, .{ 8500, 24000, 8500 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    for (0..scene.grid.count()) |section| {
        const at = scene.grid.position(section);
        for (scene.blocks[section * 4096 ..][0..4096], 0..) |*state, local| {
            const x = at[0] * 16 + @as(i32, @intCast(local % 16));
            const y = at[1] * 16 + @as(i32, @intCast(local / 256));
            const z = at[2] * 16 + @as(i32, @intCast(local / 16 % 16));
            const open = ((x >= 4 and x < 12) or (x >= 16 and x < 20)) and y >= 20 and y < 30 and z >= 4 and z < 12;
            state.* = if (open) 0 else stone;
        }
    }
    const first = try cameraEyes(arena.allocator(), scene, 64);
    const second = try cameraEyes(arena.allocator(), scene, 64);
    try std.testing.expect(first.len > 8 and first.len <= 90);
    try std.testing.expectEqualSlices(oracle.Eye, first, second);
    for (first, 0..) |eye, index| {
        const point = eye.block();
        try std.testing.expect(point[0] >= 4 and point[0] < 12);
        try std.testing.expect(point[1] >= 20 and point[1] < 30);
        try std.testing.expect(point[2] >= 4 and point[2] < 12);
        try std.testing.expect(!game_data.physics.rendering(scene.at(point).?).occluder);
        for (first[0..index]) |previous| try std.testing.expect(!std.meta.eql(previous, eye));
    }
    @memset(scene.blocks, stone);
    try std.testing.expectError(error.ObserverInsideOccluder, cameraEyes(arena.allocator(), scene, 64));
    scene.eye.coordinates[0] = 1000000;
    try std.testing.expectError(error.ObserverOutsideScene, cameraEyes(arena.allocator(), scene, 64));
}

fn runTargets(io: std.Io, allocator: std.mem.Allocator, scene: Scene, options: Options, output: *std.Io.Writer, details: *std.Io.Writer) !usize {
    const sections = try oracleSections(allocator, scene);
    const reference = try allocator.alloc(bool, sections.len);
    var coverage = try oracle.Coverage.init(allocator, options.nodes, options.depth);
    defer coverage.deinit();
    const cold = try measure(io, allocator, scene, false, options.samples);
    const warm = try measure(io, allocator, scene, true, options.samples);
    for (0..scene.grid.side * scene.grid.side) |column| {
        const at = scene.grid.position(column * scene.grid.height);
        if (cold.world.mask(cold.query, at[0], at[2]) != warm.world.mask(warm.query, at[0], at[2])) return error.CacheDependentVisibility;
    }
    var wrong: usize = 0;
    for (options.targets) |point| {
        const section = [3]i32{ @divFloor(point[0], 16), @divFloor(point[1], 16), @divFloor(point[2], 16) };
        const index = scene.grid.index(section) orelse return error.TargetOutsideScene;
        try coverage.restrict(sections[index].bounds(), scene.eye);
        try oracle.classify(allocator, &coverage, sections, scene.eye, reference);
        const bit = @as(u32, 1) << @as(u5, @intCast(section[1] - scene.grid.minimum[1]));
        const disclosed = cold.world.mask(cold.query, section[0], section[2]) & bit != 0;
        wrong += @intFromBool(reference[index] and !disclosed);
        const result = .{ .target = point, .section = section, .reference_visible = reference[index], .disclosed = disclosed, .cold_warm_identical = true, .samples = options.samples, .mask_sha256 = warm.mask_sha256, .cold_cpu_ns = cold.cpu_ns, .warm_cpu_ns = warm.cpu_ns, .visits = cold.visits, .metadata_reads = cold.reads, .reference_nodes = coverage.used };
        try std.json.Stringify.value(result, .{}, output);
        try output.writeByte('\n');
        try output.flush();
        try std.json.Stringify.value(result, .{}, details);
        try details.writeByte('\n');
        try details.flush();
    }
    return wrong;
}

fn run(init: std.process.Init, allocator: std.mem.Allocator, scene: Scene, name: []const u8, options: Options, output: *std.Io.Writer, details: *std.Io.Writer) !usize {
    const count = scene.grid.count();
    const head = scene.eye.block();
    const observer_index = scene.grid.index(.{ @divFloor(head[0], 16), @divFloor(head[1], 16), @divFloor(head[2], 16) }) orelse return error.ObserverOutsideScene;
    const sections = try oracleSections(allocator, scene);
    const reference = try allocator.alloc(bool, count);
    const disclosed = try allocator.alloc(bool, count);
    var coverage = try oracle.Coverage.init(allocator, options.nodes, options.depth);
    defer coverage.deinit();
    try oracle.classify(allocator, &coverage, sections, scene.eye, reference);
    const witnesses = try allocator.alloc(?oracle.Eye, count);
    @memset(witnesses, null);
    var sampled: usize = 0;
    if (options.camera_witnesses) {
        const sampled_reference = try allocator.alloc(bool, count);
        const eyes = try cameraEyes(allocator, scene, options.camera_samples);
        sampled = eyes.len;
        for (eyes) |eye| {
            try oracle.classify(allocator, &coverage, sections, eye, sampled_reference);
            for (sampled_reference, witnesses) |visible, *witness| if (visible and witness.* == null) {
                witness.* = eye;
            };
        }
    }
    var topology_check = try topology.Analysis.init(allocator, count);
    defer topology_check.deinit();
    const neighborhood = try Neighborhood.init(allocator, scene.grid.height);
    var wire = try Wire.init(allocator, scene.grid.height);
    defer wire.engine.deinit();
    defer wire.catalog.deinit(allocator);
    defer wire.compression.deinit();
    var total_wrong: usize = 0;
    const expected = try allocator.alloc(u32, scene.grid.side * scene.grid.side);
    for ([_]bool{ false, true }) |warm| {
        const solution = try measure(init.io, allocator, scene, warm, options.samples);
        var visible: usize = 0;
        var extra: usize = 0;
        var wrong: usize = 0;
        var camera_required: usize = 0;
        var camera_wrong: usize = 0;
        for (0..scene.grid.side * scene.grid.side) |column| {
            const at = scene.grid.position(column * scene.grid.height);
            const mask = solution.world.mask(solution.query, at[0], at[2]);
            if (warm and mask != expected[column]) return error.CacheDependentVisibility;
            expected[column] = mask;
            for (0..scene.grid.height) |y| disclosed[column * scene.grid.height + y] = mask & (@as(u32, 1) << @as(u5, @intCast(y))) != 0;
        }
        for (reference, disclosed, 0..) |actual, sent, index| {
            visible += @intFromBool(actual);
            extra += @intFromBool(!actual and sent);
            wrong += @intFromBool(actual and !sent);
            camera_required += @intFromBool(!actual and sent and witnesses[index] != null);
            camera_wrong += @intFromBool(!sent and witnesses[index] != null);
            if (actual != sent or (!sent and witnesses[index] != null)) {
                try std.json.Stringify.value(.{ .scene = name, .warm = warm, .position = scene.grid.position(index), .kind = if (actual) "incorrectly_hidden" else if (!sent) "camera_incorrectly_hidden" else "extra_disclosure", .camera_witness = witnesses[index] }, .{}, details);
                try details.writeByte('\n');
            }
        }
        total_wrong += wrong + camera_wrong;
        topology_check.run(scene.grid, disclosed, observer_index);
        var disconnected: usize = 0;
        for (topology_check.components.items) |component| if (!component.contains_observer) {
            disconnected += 1;
        };
        if (topology_check.isolated.items.len != 0 or disconnected != 0) return error.DisconnectedDisclosure;
        var sizes: [3]usize = @splat(0);
        for (0..scene.grid.side * scene.grid.side) |column| {
            _ = neighborhood.load(scene, scene.grid.position(column * scene.grid.height)[0], scene.grid.position(column * scene.grid.height)[2]);
            try wire.engine.load(.{ .dense = neighborhood.states });
            wire.engine.relight(true);
            var masks: [3]u32 = .{ std.math.maxInt(u32), expected[column], 0 };
            for (0..scene.grid.height) |y| if (reference[column * scene.grid.height + y]) {
                masks[2] |= @as(u32, 1) << @as(u5, @intCast(y));
            };
            for (masks, &sizes) |mask, *bytes| bytes.* += try wire.size(scene, column, neighborhood, mask);
        }
        try output.print("{s:<15} {s:<4} {d:>6} {d:>6} {d:>6} {d:>5} {d:>9.2} {d:>9} {d:>9} {d:>9.3} {d:>9.3} {d:>9.3}\n", .{ name, if (warm) "warm" else "cold", count, visible, extra, wrong, @as(f64, @floatFromInt(solution.cpu_ns)) / std.time.ns_per_ms, solution.visits, solution.reads, @as(f64, @floatFromInt(sizes[0])) / (1024 * 1024), @as(f64, @floatFromInt(sizes[1])) / (1024 * 1024), @as(f64, @floatFromInt(sizes[2])) / (1024 * 1024) });
        try output.flush();
        if (options.camera_witnesses) {
            try output.print("  camera samples={d} required_extra={d}/{d} unproven_extra={d} incorrectly_hidden={d}\n", .{ sampled, camera_required, extra, extra - camera_required, camera_wrong });
            try output.flush();
        }
        try std.json.Stringify.value(.{ .scene = name, .warm = warm, .kind = "summary", .model = "section_portals", .gameplay_baseline = game_data.canonical_version, .grid = scene.grid, .head = scene.eye.coordinates, .sections = count, .reference_visible = visible, .extra = extra, .incorrectly_hidden = wrong, .camera_samples = sampled, .camera_required_extra = camera_required, .camera_incorrectly_hidden = camera_wrong, .isolated = topology_check.isolated.items.len, .disconnected = disconnected, .samples = options.samples, .mask_sha256 = solution.mask_sha256, .cpu_ns = solution.cpu_ns, .visits = solution.visits, .metadata_reads = solution.reads, .wire_bytes = sizes }, .{}, details);
        try details.writeByte('\n');
        try details.flush();
        if (warm) for (0..options.repeat_queries) |_| {
            solution.world.invalidateResults();
            const repeated = try calculate(init.io, solution.world, scene);
            if (!std.mem.eql(u8, &solution.mask_sha256, &repeated.mask_sha256)) return error.NondeterministicVisibility;
        };
    }
    return total_wrong;
}

fn runCaves(init: std.process.Init, allocator: std.mem.Allocator, options: Options, output: *std.Io.Writer, details: *std.Io.Writer) !usize {
    var search_options = options;
    search_options.radius = options.search_radius;
    const source = try loadWorld(init, allocator, search_options);
    const sites = try caves.select(.{ .grid = source.grid, .blocks = source.blocks }, @intCast(options.radius));
    var wrong: usize = 0;
    for (sites) |site| {
        if (options.cave) |kind| if (site.kind != kind) continue;
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const scene = try Scene.init(arena.allocator(), options.radius, source.grid.minimum[1], source.grid.height, site.feet());
        for (0..scene.grid.count()) |index| {
            const from = source.grid.index(scene.grid.position(index)) orelse return error.CaveWindowOutsideImport;
            @memcpy(scene.blocks[index * 4096 ..][0..4096], source.blocks[from * 4096 ..][0..4096]);
            scene.biomes[index] = source.biomes[from];
        }
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var canonical: [8192]u8 = undefined;
        for (0..scene.grid.count()) |section| {
            for (scene.blocks[section * 4096 ..][0..4096], 0..) |state, index| std.mem.writeInt(u16, canonical[index * 2 ..][0..2], state, .little);
            digest.update(&canonical);
            for (scene.biomes[section], 0..) |biome, index| std.mem.writeInt(u16, canonical[index * 2 ..][0..2], biome, .little);
            digest.update(canonical[0..128]);
        }
        var hash: [32]u8 = undefined;
        digest.final(&hash);
        const name = switch (site.kind) {
            .tight => "cave-tight",
            .chamber => "cave-chamber",
            .tall => "cave-tall",
        };
        const position = site.feet();
        const feet: [3]f64 = .{ @as(f64, @floatFromInt(position[0])) / 1000, @as(f64, @floatFromInt(position[1])) / 1000, @as(f64, @floatFromInt(position[2])) / 1000 };
        try output.print("{s}: feet={d:.1},{d:.1},{d:.1} cover={d} clearance={any}\n", .{ name, @as(f64, @floatFromInt(position[0])) / 1000, @as(f64, @floatFromInt(position[1])) / 1000, @as(f64, @floatFromInt(position[2])) / 1000, site.cover, site.clearance });
        try output.flush();
        try std.json.Stringify.value(.{ .kind = "viewpoint", .scene = name, .source = options.world.?, .feet = feet, .cover_blocks = site.cover, .clearance = .{ .west = site.clearance[0], .east = site.clearance[1], .north = site.clearance[2], .south = site.clearance[3], .up = site.clearance[4] }, .clearance_limit = caves.clearance_limit, .terrain_sha256 = std.fmt.bytesToHex(hash, .lower) }, .{}, details);
        try details.writeByte('\n');
        try details.flush();
        wrong += try run(init, arena.allocator(), scene, name, options, output, details);
    }
    return wrong;
}

pub fn main(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();
    _ = args.next();
    var options: Options = .{};
    var radius_explicit = false;
    var targets: std.ArrayList([3]i32) = .empty;
    defer targets.deinit(init.arena.allocator());
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--help")) {
            try output.interface.writeAll("zig build bench -Doptimize=ReleaseSafe -- [options]\n--scene flat|forest|overhang|geode|geode-opening|bent-cave|stacked-caves|straight-tunnel|winding-tunnel\n--world PATH           Native world copy instead of synthetic scenes\n--position X Y Z       Player feet, exact decimals with at most three fractional digits\n--target X Y Z       Check one target section exactly, repeatable with --world\n--radius 1..35         Render distance, default 1\n--samples 1..64       CPU samples per cache state, default 1\n--nodes N --depth N    Exact reference capacity, default 262144 and 1024\n--output PATH          Full JSONL diagnostics, default .zig-cache/visibility.jsonl\n");
            try output.interface.writeAll("--caves               Discover tight, large, and tall caves in --world and check each against the exact oracle\n--search-radius N     Imported search window, default 8 chunks around --position X,Z\nCave suites default to --radius 2 and --output .zig-cache/visibility-caves.jsonl.\nCave viewpoints depend only on terrain and are printed with reproducible input hashes.\n");
            try output.interface.writeAll("--camera-witnesses     Check additional permitted camera positions with the exact oracle\n");
            try output.interface.writeAll("--camera-samples N     Additional deterministic interior camera samples, default 64\n--cave tight|chamber|tall  Run one imported cave case\n");
            try output.interface.writeAll("--repeat-queries N     Repeat warm queries after correctness checks for profiling\n");
            try output.interface.flush();
            return;
        }
        if (std.mem.eql(u8, argument, "--caves")) {
            options.caves = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--camera-witnesses")) {
            options.camera_witnesses = true;
            continue;
        }
        const value = args.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, argument, "--samples")) {
            options.samples = try std.fmt.parseInt(usize, value, 10);
            continue;
        }
        if (std.mem.eql(u8, argument, "--cave")) {
            options.cave = std.meta.stringToEnum(caves.Kind, value) orelse return error.InvalidCave;
            continue;
        }
        if (std.mem.eql(u8, argument, "--camera-samples")) {
            options.camera_samples = try std.fmt.parseInt(usize, value, 10);
            options.camera_witnesses = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--repeat-queries")) {
            options.repeat_queries = try std.fmt.parseInt(usize, value, 10);
            continue;
        }
        if (std.mem.eql(u8, argument, "--world")) options.world = value else if (std.mem.eql(u8, argument, "--scene")) options.scene = value else if (std.mem.eql(u8, argument, "--radius")) {
            options.radius = try std.fmt.parseInt(i32, value, 10);
            radius_explicit = true;
        } else if (std.mem.eql(u8, argument, "--search-radius")) options.search_radius = try std.fmt.parseInt(i32, value, 10) else if (std.mem.eql(u8, argument, "--nodes")) options.nodes = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, argument, "--depth")) options.depth = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, argument, "--output")) options.output = value else if (std.mem.eql(u8, argument, "--position")) {
            var coordinates: [3]i64 = undefined;
            coordinates[0] = try coordinate(value);
            for (coordinates[1..]) |*entry| entry.* = try coordinate(args.next() orelse return error.MissingArgument);
            options.feet = coordinates;
        } else if (std.mem.eql(u8, argument, "--target")) {
            var point: [3]i32 = undefined;
            point[0] = try std.fmt.parseInt(i32, value, 10);
            for (point[1..]) |*entry| entry.* = try std.fmt.parseInt(i32, args.next() orelse return error.MissingArgument, 10);
            try targets.append(init.arena.allocator(), point);
        } else return error.UnknownArgument;
    }
    options.targets = targets.items;
    if (options.caves and !radius_explicit) options.radius = 2;
    if (options.radius < 1 or options.radius > 35) return error.InvalidRadius;
    if (options.samples == 0 or options.samples > 64) return error.InvalidSamples;
    if (options.world != null and options.scene != null) return error.ConflictingScenes;
    if (options.caves and options.world == null) return error.MissingCaveWorld;
    if (options.caves and (options.search_radius <= options.radius or options.search_radius > 35)) return error.CaveSearchTooSmall;
    if (options.caves and options.targets.len != 0) return error.ConflictingTargets;
    if (options.cave != null and !options.caves) return error.MissingCaveSuite;
    if (options.camera_samples > 256) return error.InvalidCameraSamples;
    if (options.repeat_queries > 1000000) return error.InvalidQueryRepetitions;
    if ((options.camera_witnesses or options.repeat_queries != 0) and options.targets.len != 0) return error.ConflictingTargets;
    const output_path = options.output orelse if (options.caves) ".zig-cache/visibility-caves.jsonl" else ".zig-cache/visibility.jsonl";
    if (std.fs.path.dirname(output_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    const file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    defer file.close(init.io);
    var detail_buffer: [32768]u8 = undefined;
    var details = file.writerStreaming(init.io, &detail_buffer);
    try output.interface.writeAll("Exact positive-area section-volume visibility through opaque voxel cubes, fixed head, full 360 degrees.\nProduction uses a source section and fixed third-person camera margin.\nCompleted visibility is independent of cache warmup. Wire bytes use the gameplay-baseline protocol, excluding sockets and rendering.\nScene           cache  total    ref  extra wrong    CPU_ms    visits     reads  full_MiB  sent_MiB ideal_MiB\n");
    if (options.camera_witnesses) try output.interface.writeAll("Camera witnesses prove required disclosure. Unwitnessed sections remain unclassified.\n");
    try output.interface.flush();
    try output.interface.print("CPU time is the median of {d} complete calculations.\n", .{options.samples});
    var wrong: usize = 0;
    if (options.world != null) {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        if (options.caves) {
            wrong += try runCaves(init, arena.allocator(), options, &output.interface, &details.interface);
        } else {
            const scene = try loadWorld(init, arena.allocator(), options);
            wrong += if (options.targets.len != 0) try runTargets(init.io, arena.allocator(), scene, options, &output.interface, &details.interface) else try run(init, arena.allocator(), scene, "imported", options, &output.interface, &details.interface);
        }
    } else {
        var matched = false;
        for ([_][]const u8{ "flat", "forest", "overhang", "geode", "geode-opening", "bent-cave", "stacked-caves", "straight-tunnel", "winding-tunnel" }) |name| {
            if (options.scene) |selected| if (!std.mem.eql(u8, selected, name)) continue;
            matched = true;
            var arena = std.heap.ArenaAllocator.init(init.gpa);
            defer arena.deinit();
            const scene = try Scene.synthetic(arena.allocator(), options.radius, name);
            wrong += try run(init, arena.allocator(), scene, name, options, &output.interface, &details.interface);
        }
        if (!matched) return error.UnknownScene;
    }
    try output.interface.print("Full section diagnostics: {s}\n", .{output_path});
    try output.interface.flush();
    if (wrong != 0) return error.IncorrectConcealment;
}

fn coordinate(text: []const u8) !i64 {
    if (text.len == 0) return error.InvalidPosition;
    const negative = text[0] == '-';
    const magnitude = if (negative or text[0] == '+') text[1..] else text;
    var parts = std.mem.splitScalar(u8, magnitude, '.');
    const whole = try std.fmt.parseInt(u32, parts.next().?, 10);
    var fraction: u32 = 0;
    if (parts.next()) |digits| {
        if (digits.len == 0 or digits.len > 3) return error.PositionPrecisionExceeded;
        fraction = try std.fmt.parseInt(u32, digits, 10);
        for (digits.len..3) |_| fraction *= 10;
    }
    if (parts.next() != null or whole > 30_000_000 or (whole == 30_000_000 and fraction != 0)) return error.InvalidPosition;
    const value = @as(i64, whole) * oracle.Eye.scale + fraction;
    return if (negative) -value else value;
}
