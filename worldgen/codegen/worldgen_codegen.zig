const std = @import("std");

const ValueKind = enum { fixed, spline };
const Coordinate = enum { continents, erosion, ridges_folded };

const ValueRef = struct {
    kind: ValueKind,
    payload: u32,
};

const Point = struct {
    location: f32,
    derivative: f32,
    value: ValueRef,
};

const Spline = struct {
    coordinate: Coordinate,
    point_start: u32,
    point_len: u16,
};

const BiomeNode = struct {
    parameters: [7][2]i16,
    child_start: u16,
    child_len: u16,
    biome: u8,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    points: std.ArrayListUnmanaged(Point) = .empty,
    splines: std.ArrayListUnmanaged(Spline) = .empty,
    biome_nodes: std.ArrayListUnmanaged(BiomeNode) = .empty,
    biome_children: std.ArrayListUnmanaged(u16) = .empty,
    biome_names: std.ArrayListUnmanaged([]const u8) = .empty,

    fn appendSpline(self: *Builder, value: std.json.Value) !u32 {
        const object = value.object;
        const coordinate = try parseCoordinate(object.get("coordinate") orelse return error.MissingSplineCoordinate);
        const json_points = (object.get("points") orelse return error.MissingSplinePoints).array.items;
        if (json_points.len == 0 or json_points.len > std.math.maxInt(u16)) return error.InvalidSplinePointCount;

        var local: std.ArrayListUnmanaged(Point) = .empty;
        defer local.deinit(self.allocator);
        try local.ensureTotalCapacity(self.allocator, json_points.len);
        for (json_points) |json_point| {
            const point = json_point.object;
            const point_value = point.get("value") orelse return error.MissingSplinePointValue;
            const value_ref: ValueRef = switch (point_value) {
                .float, .integer => .{
                    .kind = .fixed,
                    .payload = @bitCast(try jsonF32(point_value)),
                },
                .object => .{
                    .kind = .spline,
                    .payload = try self.appendSpline(point_value),
                },
                else => return error.InvalidSplinePointValue,
            };
            local.appendAssumeCapacity(.{
                .location = try jsonF32(point.get("location") orelse return error.MissingSplinePointLocation),
                .derivative = try jsonF32(point.get("derivative") orelse return error.MissingSplinePointDerivative),
                .value = value_ref,
            });
        }

        if (self.points.items.len > std.math.maxInt(u32)) return error.TooManySplinePoints;
        const point_start: u32 = @intCast(self.points.items.len);
        try self.points.appendSlice(self.allocator, local.items);
        if (self.splines.items.len > std.math.maxInt(u32)) return error.TooManySplines;
        const index: u32 = @intCast(self.splines.items.len);
        try self.splines.append(self.allocator, .{
            .coordinate = coordinate,
            .point_start = point_start,
            .point_len = @intCast(local.items.len),
        });
        return index;
    }

    fn appendBiomeNode(self: *Builder, value: std.json.Value) !u16 {
        const object = value.object;
        const parameters_json = (object.get("parameters") orelse return error.MissingBiomeParameters).array.items;
        if (parameters_json.len != 7) return error.InvalidBiomeParameterCount;
        var parameters: [7][2]i16 = undefined;
        for (parameters_json, &parameters) |parameter_json, *parameter| {
            const parameter_object = parameter_json.object;
            parameter.* = .{
                try jsonI16(parameter_object.get("min") orelse return error.MissingBiomeParameterMinimum),
                try jsonI16(parameter_object.get("max") orelse return error.MissingBiomeParameterMaximum),
            };
        }

        var direct_children: std.ArrayListUnmanaged(u16) = .empty;
        defer direct_children.deinit(self.allocator);
        var biome: u8 = std.math.maxInt(u8);
        if (object.get("subTree")) |children_json| {
            const children = children_json.array.items;
            if (children.len == 0 or children.len > std.math.maxInt(u16)) return error.InvalidBiomeChildCount;
            try direct_children.ensureTotalCapacity(self.allocator, children.len);
            for (children) |child| direct_children.appendAssumeCapacity(try self.appendBiomeNode(child));
        } else {
            biome = try self.biomeIndex((object.get("biome") orelse return error.MissingBiomeName).string);
        }

        if (self.biome_children.items.len > std.math.maxInt(u16) or
            self.biome_children.items.len + direct_children.items.len > std.math.maxInt(u16))
            return error.TooManyBiomeChildren;
        const child_start: u16 = @intCast(self.biome_children.items.len);
        try self.biome_children.appendSlice(self.allocator, direct_children.items);
        if (self.biome_nodes.items.len >= std.math.maxInt(u16)) return error.TooManyBiomeNodes;
        const index: u16 = @intCast(self.biome_nodes.items.len);
        try self.biome_nodes.append(self.allocator, .{
            .parameters = parameters,
            .child_start = child_start,
            .child_len = @intCast(direct_children.items.len),
            .biome = biome,
        });
        return index;
    }

    fn appendBiomeReport(self: *Builder, value: std.json.Value) !u16 {
        const entries = (value.object.get("biomes") orelse
            return error.MissingBiomeReportEntries).array.items;
        var layer: std.ArrayListUnmanaged(u16) = .empty;
        defer layer.deinit(self.allocator);
        try layer.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |entry| {
            if (self.biome_nodes.items.len >= std.math.maxInt(u16))
                return error.TooManyBiomeNodes;
            const object = entry.object;
            const parameters = object.get("parameters") orelse
                return error.MissingBiomeParameters;
            const index: u16 = @intCast(self.biome_nodes.items.len);
            try self.biome_nodes.append(self.allocator, .{
                .parameters = try reportParameters(parameters.object),
                .child_start = 0,
                .child_len = 0,
                .biome = try self.biomeIndex(
                    (object.get("biome") orelse return error.MissingBiomeName).string,
                ),
            });
            layer.appendAssumeCapacity(index);
        }
        if (layer.items.len == 0) return error.EmptyBiomeReport;
        while (layer.items.len > 1) {
            var next: std.ArrayListUnmanaged(u16) = .empty;
            errdefer next.deinit(self.allocator);
            try next.ensureTotalCapacity(
                self.allocator,
                (layer.items.len + biome_branching - 1) / biome_branching,
            );
            var first: usize = 0;
            while (first < layer.items.len) : (first += biome_branching) {
                const end = @min(first + biome_branching, layer.items.len);
                next.appendAssumeCapacity(try self.appendBiomeBranch(layer.items[first..end]));
            }
            layer.deinit(self.allocator);
            layer = next;
        }
        return layer.items[0];
    }

    fn appendBiomeBranch(self: *Builder, children: []const u16) !u16 {
        std.debug.assert(children.len > 0 and children.len <= biome_branching);
        if (self.biome_children.items.len + children.len > std.math.maxInt(u16))
            return error.TooManyBiomeChildren;
        const child_start: u16 = @intCast(self.biome_children.items.len);
        try self.biome_children.appendSlice(self.allocator, children);
        var parameters = self.biome_nodes.items[children[0]].parameters;
        for (children[1..]) |child| for (&parameters, self.biome_nodes.items[child].parameters) |*range, child_range| {
            range[0] = @min(range[0], child_range[0]);
            range[1] = @max(range[1], child_range[1]);
        };
        if (self.biome_nodes.items.len >= std.math.maxInt(u16))
            return error.TooManyBiomeNodes;
        const index: u16 = @intCast(self.biome_nodes.items.len);
        try self.biome_nodes.append(self.allocator, .{
            .parameters = parameters,
            .child_start = child_start,
            .child_len = @intCast(children.len),
            .biome = std.math.maxInt(u8),
        });
        return index;
    }

    fn biomeIndex(self: *Builder, name: []const u8) !u8 {
        for (self.biome_names.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, name)) return @intCast(index);
        }
        if (self.biome_names.items.len >= std.math.maxInt(u8)) return error.TooManyBiomes;
        try self.biome_names.append(self.allocator, name);
        return @intCast(self.biome_names.items.len - 1);
    }
};

const biome_branching = 10;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const spline_path = args.next() orelse return error.MissingSplinePath;
    const biome_tree_path = args.next() orelse return error.MissingBiomeTreePath;
    const biome_dir = args.next() orelse return error.MissingBiomeDirectory;
    const output_path = args.next() orelse return error.MissingOutputPath;

    const cwd = std.Io.Dir.cwd();
    const spline_bytes = try cwd.readFileAlloc(init.io, spline_path, allocator, .limited(4 * 1024 * 1024));
    const parsed_spline = try std.json.parseFromSlice(std.json.Value, allocator, spline_bytes, .{});
    const biome_bytes = try cwd.readFileAlloc(init.io, biome_tree_path, allocator, .limited(4 * 1024 * 1024));
    const parsed_biomes = try std.json.parseFromSlice(std.json.Value, allocator, biome_bytes, .{});
    var builder = Builder{ .allocator = allocator };
    const spline_root = try builder.appendSpline(try findSpline(parsed_spline.value));
    const biome_root = if (parsed_biomes.value.object.get("biomes") != null)
        try builder.appendBiomeReport(parsed_biomes.value)
    else
        try builder.appendBiomeNode(parsed_biomes.value);
    try appendDimensionBiomes(init.io, allocator, biome_dir, &builder);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    try output.appendSlice(
        \\pub const Coordinate = enum(u8) { continents, erosion, ridges_folded };
        \\pub const ValueKind = enum(u8) { fixed, spline };
        \\pub const ValueRef = struct { kind: ValueKind, payload: u32 };
        \\pub const Point = struct { location: f32, derivative: f32, value: ValueRef };
        \\pub const Spline = struct { coordinate: Coordinate, point_start: u32, point_len: u16 };
        \\
        \\pub const points = [_]Point{
        \\
    );
    for (builder.points.items) |point| {
        try output.print(
            "    .{{ .location = @bitCast(@as(u32, 0x{x:0>8})), .derivative = @bitCast(@as(u32, 0x{x:0>8})), .value = .{{ .kind = .{s}, .payload = 0x{x:0>8} }} }},\n",
            .{ @as(u32, @bitCast(point.location)), @as(u32, @bitCast(point.derivative)), @tagName(point.value.kind), point.value.payload },
        );
    }
    try output.appendSlice("};\n\npub const splines = [_]Spline{\n");
    for (builder.splines.items) |spline| {
        try output.print(
            "    .{{ .coordinate = .{s}, .point_start = {d}, .point_len = {d} }},\n",
            .{ @tagName(spline.coordinate), spline.point_start, spline.point_len },
        );
    }
    try output.print("}};\n\npub const overworld_offset_root: u32 = {d};\n\n", .{spline_root});
    try output.appendSlice(
        \\pub const BiomeNode = struct { parameters: [7][2]i16, child_start: u16, child_len: u16, biome: u8 };
        \\pub const BiomeClimate = struct { temperature: f32, downfall: f32, frozen: bool };
        \\pub const biome_names = [_][]const u8{
        \\
    );
    for (builder.biome_names.items) |name| try output.print("    \"{s}\",\n", .{name});
    try output.appendSlice("};\n\npub const biome_climates = [_]BiomeClimate{\n");
    for (builder.biome_names.items) |name| {
        const relative = if (std.mem.startsWith(u8, name, "minecraft:"))
            name["minecraft:".len..]
        else
            name;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ biome_dir, relative });
        const climate_bytes = try cwd.readFileAlloc(init.io, path, allocator, .limited(64 * 1024));
        const climate_json = try std.json.parseFromSlice(std.json.Value, allocator, climate_bytes, .{});
        const climate = climate_json.value.object;
        const temperature = try jsonF32(climate.get("temperature") orelse return error.MissingBiomeTemperature);
        const downfall = try jsonF32(climate.get("downfall") orelse return error.MissingBiomeDownfall);
        const frozen = if (climate.get("temperature_modifier")) |modifier|
            std.mem.eql(u8, modifier.string, "frozen")
        else
            false;
        try output.print(
            "    .{{ .temperature = @bitCast(@as(u32, 0x{x:0>8})), .downfall = @bitCast(@as(u32, 0x{x:0>8})), .frozen = {} }},\n",
            .{ @as(u32, @bitCast(temperature)), @as(u32, @bitCast(downfall)), frozen },
        );
    }
    try output.appendSlice("};\n\npub const biome_nodes = [_]BiomeNode{\n");
    for (builder.biome_nodes.items) |node| {
        try output.appendSlice("    .{ .parameters = .{");
        for (node.parameters) |range| try output.print(".{{ {d}, {d} }},", .{ range[0], range[1] });
        try output.print(
            "}}, .child_start = {d}, .child_len = {d}, .biome = {d} }},\n",
            .{ node.child_start, node.child_len, node.biome },
        );
    }
    try output.appendSlice("};\n\npub const biome_children = [_]u16{\n    ");
    for (builder.biome_children.items, 0..) |child, index| {
        try output.print("{d},", .{child});
        if (index % 32 == 31) try output.appendSlice("\n    ");
    }
    try output.print("\n}};\n\npub const overworld_biome_root: u16 = {d};\n", .{biome_root});
    try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = output.items });
}

fn appendDimensionBiomes(
    io: std.Io,
    allocator: std.mem.Allocator,
    biome_dir: []const u8,
    builder: *Builder,
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, biome_dir, .{ .iterate = true });
    defer directory.close(io);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        try names.append(allocator, try std.fmt.allocPrint(allocator, "minecraft:{s}", .{stem}));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    for (names.items) |name| _ = try builder.biomeIndex(name);
}

fn parseCoordinate(value: std.json.Value) !Coordinate {
    const name = value.string;
    const prefix = "minecraft:overworld/";
    if (!std.mem.startsWith(u8, name, prefix)) return error.InvalidSplineCoordinate;
    return std.meta.stringToEnum(Coordinate, name[prefix.len..]) orelse error.InvalidSplineCoordinate;
}

fn findSpline(root: std.json.Value) !std.json.Value {
    var stack: [512]std.json.Value = undefined;
    var count: usize = 1;
    stack[0] = root;
    for (0..stack.len) |_| {
        if (count == 0) break;
        count -= 1;
        const value = stack[count];
        switch (value) {
            .object => |object| {
                if (object.get("coordinate") != null and object.get("points") != null)
                    return value;
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    if (count == stack.len) return error.SplineSearchCapacity;
                    stack[count] = entry.value_ptr.*;
                    count += 1;
                }
            },
            .array => |array| for (array.items) |entry| {
                if (count == stack.len) return error.SplineSearchCapacity;
                stack[count] = entry;
                count += 1;
            },
            else => {},
        }
    }
    return error.MissingSpline;
}

fn reportParameters(object: std.json.ObjectMap) ![7][2]i16 {
    return .{
        try reportRange(object.get("temperature") orelse return error.MissingTemperature),
        try reportRange(object.get("humidity") orelse return error.MissingHumidity),
        try reportRange(object.get("continentalness") orelse return error.MissingContinentalness),
        try reportRange(object.get("erosion") orelse return error.MissingErosion),
        try reportRange(object.get("depth") orelse return error.MissingDepth),
        try reportRange(object.get("weirdness") orelse return error.MissingWeirdness),
        try reportRange(object.get("offset") orelse return error.MissingOffset),
    };
}

fn reportRange(value: std.json.Value) ![2]i16 {
    return switch (value) {
        .array => |array| if (array.items.len == 2)
            .{ try quantized(array.items[0]), try quantized(array.items[1]) }
        else
            error.InvalidBiomeParameter,
        .float, .integer => blk: {
            const scalar = try quantized(value);
            break :blk .{ scalar, scalar };
        },
        else => error.InvalidBiomeParameter,
    };
}

fn quantized(value: std.json.Value) !i16 {
    const number: f64 = switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => return error.InvalidBiomeParameter,
    };
    return std.math.cast(i16, @as(i64, @intFromFloat(number * 10_000.0))) orelse
        error.BiomeParameterOutOfRange;
}

fn jsonF32(value: std.json.Value) !f32 {
    return switch (value) {
        .float => |number| @floatCast(number),
        else => error.InvalidSplineNumber,
    };
}

fn jsonI16(value: std.json.Value) !i16 {
    return switch (value) {
        .integer => |number| std.math.cast(i16, number) orelse error.BiomeParameterOutOfRange,
        else => error.InvalidBiomeParameter,
    };
}
