const std = @import("std");

const Tag = enum {
    constant,
    add,
    multiply,
    minimum,
    maximum,
    absolute,
    square,
    cube,
    half_negative,
    quarter_negative,
    squeeze,
    clamp,
    y_gradient,
    noise,
    shift_a,
    shift_b,
    shifted_noise,
    range_choice,
    interpolated,
    spline,
    weird_scaled_type_1,
    weird_scaled_type_2,
    old_blended_noise,
    end_islands,
};

const Node = struct {
    tag: Tag,
    a: u16 = 0,
    b: u16 = 0,
    c: u16 = 0,
    aux: u16 = 0,
    i0: i32 = 0,
    i1: i32 = 0,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    w: f64 = 0,
    v: f64 = 0,
};

const NoiseSpec = struct {
    id: []const u8,
    first_octave: i32,
    amplitude_start: u16,
    amplitude_len: u8,
};

const SplineValueKind = enum { fixed, spline };
const SplineValue = struct { kind: SplineValueKind, payload: u32 };
const SplinePoint = struct { location: f32, derivative: f32, value: SplineValue };
const Spline = struct { coordinate: u16, point_start: u16, point_len: u16 };
const Root = struct { name: []const u8, index: u16 };
const DensitySettings = struct {
    router: std.json.ObjectMap,
    minimum_y: i32,
    height: i32,
    horizontal_cell_size: i32,
    vertical_cell_size: i32,
    sea_level: i32,
    legacy_random_source: bool,
    default_block: []const u8,
    default_fluid: []const u8,
};

const Builder = struct {
    io: std.Io,
    cwd: std.Io.Dir,
    allocator: std.mem.Allocator,
    density_dir: []const u8,
    noise_dir: []const u8,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    references: std.StringHashMapUnmanaged(u16) = .empty,
    noise_specs: std.ArrayListUnmanaged(NoiseSpec) = .empty,
    amplitudes: std.ArrayListUnmanaged(f64) = .empty,
    splines: std.ArrayListUnmanaged(Spline) = .empty,
    spline_points: std.ArrayListUnmanaged(SplinePoint) = .empty,

    fn append(self: *Builder, value: std.json.Value) anyerror!u16 {
        return switch (value) {
            .integer, .float => self.appendNode(.{ .tag = .constant, .x = try jsonF64(value) }),
            .string => |reference| self.resolve(reference),
            .object => |object| self.appendObject(object),
            else => error.InvalidDensityFunction,
        };
    }

    fn resolve(self: *Builder, reference: []const u8) anyerror!u16 {
        if (self.references.get(reference)) |existing| return existing;
        const relative = stripMinecraft(reference);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.density_dir, relative });
        const bytes = try self.cwd.readFileAlloc(self.io, path, self.allocator, .limited(2 * 1024 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        const node = try self.append(parsed.value);
        try self.references.put(self.allocator, reference, node);
        return node;
    }

    fn appendObject(self: *Builder, object: std.json.ObjectMap) anyerror!u16 {
        const raw_type = (object.get("type") orelse return error.MissingDensityType).string;
        const kind = stripMinecraft(raw_type);
        if (std.mem.eql(u8, kind, "add")) return self.binary(.add, object);
        if (std.mem.eql(u8, kind, "mul")) return self.binary(.multiply, object);
        if (std.mem.eql(u8, kind, "min")) return self.binary(.minimum, object);
        if (std.mem.eql(u8, kind, "max")) return self.binary(.maximum, object);
        if (std.mem.eql(u8, kind, "abs")) return self.unary(.absolute, object);
        if (std.mem.eql(u8, kind, "square")) return self.unary(.square, object);
        if (std.mem.eql(u8, kind, "cube")) return self.unary(.cube, object);
        if (std.mem.eql(u8, kind, "half_negative")) return self.unary(.half_negative, object);
        if (std.mem.eql(u8, kind, "quarter_negative")) return self.unary(.quarter_negative, object);
        if (std.mem.eql(u8, kind, "squeeze")) return self.unary(.squeeze, object);
        if (std.mem.eql(u8, kind, "cache_2d") or
            std.mem.eql(u8, kind, "cache_once") or
            std.mem.eql(u8, kind, "flat_cache") or
            std.mem.eql(u8, kind, "blend_density"))
            return self.append(object.get("argument") orelse return error.MissingDensityArgument);
        if (std.mem.eql(u8, kind, "interpolated")) {
            return self.appendNode(.{
                .tag = .interpolated,
                .a = try self.append(object.get("argument") orelse return error.MissingDensityArgument),
            });
        }
        if (std.mem.eql(u8, kind, "blend_alpha")) return self.appendNode(.{ .tag = .constant, .x = 1 });
        if (std.mem.eql(u8, kind, "blend_offset")) return self.appendNode(.{ .tag = .constant, .x = 0 });
        if (std.mem.eql(u8, kind, "clamp")) return self.appendClamp(object);
        if (std.mem.eql(u8, kind, "y_clamped_gradient")) return self.appendGradient(object);
        if (std.mem.eql(u8, kind, "noise")) return self.appendNoise(object);
        if (std.mem.eql(u8, kind, "shift_a") or std.mem.eql(u8, kind, "shift_b")) return self.appendNode(.{
            .tag = if (kind[6] == 'a') .shift_a else .shift_b,
            .aux = try self.noiseIndex((object.get("argument") orelse return error.MissingNoiseId).string),
        });
        if (std.mem.eql(u8, kind, "shifted_noise")) return self.appendShiftedNoise(object);
        if (std.mem.eql(u8, kind, "range_choice")) return self.appendNode(.{
            .tag = .range_choice,
            .a = try self.append(object.get("input") orelse return error.MissingDensityInput),
            .b = try self.append(object.get("when_in_range") orelse return error.MissingRangeBranch),
            .c = try self.append(object.get("when_out_of_range") orelse return error.MissingRangeBranch),
            .x = try jsonF64(object.get("min_inclusive") orelse return error.MissingRangeMinimum),
            .y = try jsonF64(object.get("max_exclusive") orelse return error.MissingRangeMaximum),
        });
        if (std.mem.eql(u8, kind, "spline")) return self.appendNode(.{
            .tag = .spline,
            .aux = try self.appendSpline((object.get("spline") orelse return error.MissingSpline).object),
        });
        if (std.mem.eql(u8, kind, "weird_scaled_sampler")) {
            const mapper = (object.get("rarity_value_mapper") orelse return error.MissingRarityMapper).string;
            return self.appendNode(.{
                .tag = if (std.mem.eql(u8, mapper, "type_1")) .weird_scaled_type_1 else if (std.mem.eql(u8, mapper, "type_2")) .weird_scaled_type_2 else return error.InvalidRarityMapper,
                .a = try self.append(object.get("input") orelse return error.MissingDensityInput),
                .aux = try self.noiseIndex((object.get("noise") orelse return error.MissingNoiseId).string),
            });
        }
        if (std.mem.eql(u8, kind, "old_blended_noise")) return self.appendOldBlendedNoise(object);
        if (std.mem.eql(u8, kind, "end_islands"))
            return self.appendNode(.{ .tag = .end_islands });
        std.debug.print("unsupported density function: {s}\n", .{kind});
        return error.UnsupportedDensityFunction;
    }

    fn appendClamp(self: *Builder, object: std.json.ObjectMap) !u16 {
        return self.appendNode(.{ .tag = .clamp, .a = try self.append(object.get("input") orelse return error.MissingDensityInput), .x = try jsonF64(object.get("min") orelse return error.MissingClampMinimum), .y = try jsonF64(object.get("max") orelse return error.MissingClampMaximum) });
    }

    fn appendGradient(self: *Builder, object: std.json.ObjectMap) !u16 {
        return self.appendNode(.{ .tag = .y_gradient, .i0 = try jsonI32(object.get("from_y") orelse return error.MissingGradientMinimumY), .i1 = try jsonI32(object.get("to_y") orelse return error.MissingGradientMaximumY), .x = try jsonF64(object.get("from_value") orelse return error.MissingGradientMinimum), .y = try jsonF64(object.get("to_value") orelse return error.MissingGradientMaximum) });
    }

    fn appendNoise(self: *Builder, object: std.json.ObjectMap) !u16 {
        return self.appendNode(.{ .tag = .noise, .aux = try self.noiseIndex((object.get("noise") orelse return error.MissingNoiseId).string), .x = try jsonF64(object.get("xz_scale") orelse return error.MissingNoiseScale), .y = try jsonF64(object.get("y_scale") orelse return error.MissingNoiseScale) });
    }

    fn appendShiftedNoise(self: *Builder, object: std.json.ObjectMap) !u16 {
        return self.appendNode(.{ .tag = .shifted_noise, .a = try self.append(object.get("shift_x") orelse return error.MissingShift), .b = try self.append(object.get("shift_y") orelse return error.MissingShift), .c = try self.append(object.get("shift_z") orelse return error.MissingShift), .aux = try self.noiseIndex((object.get("noise") orelse return error.MissingNoiseId).string), .x = try jsonF64(object.get("xz_scale") orelse return error.MissingNoiseScale), .y = try jsonF64(object.get("y_scale") orelse return error.MissingNoiseScale) });
    }

    fn appendOldBlendedNoise(self: *Builder, object: std.json.ObjectMap) !u16 {
        return self.appendNode(.{ .tag = .old_blended_noise, .x = try jsonF64(object.get("xz_scale") orelse return error.MissingNoiseScale), .y = try jsonF64(object.get("y_scale") orelse return error.MissingNoiseScale), .z = try jsonF64(object.get("xz_factor") orelse return error.MissingNoiseFactor), .w = try jsonF64(object.get("y_factor") orelse return error.MissingNoiseFactor), .v = try jsonF64(object.get("smear_scale_multiplier") orelse return error.MissingNoiseScale) });
    }

    fn binary(self: *Builder, tag: Tag, object: std.json.ObjectMap) !u16 {
        return self.appendNode(.{
            .tag = tag,
            .a = try self.append(object.get("argument1") orelse return error.MissingDensityArgument),
            .b = try self.append(object.get("argument2") orelse return error.MissingDensityArgument),
        });
    }

    fn unary(self: *Builder, tag: Tag, object: std.json.ObjectMap) !u16 {
        return self.appendNode(.{
            .tag = tag,
            .a = try self.append(object.get("argument") orelse return error.MissingDensityArgument),
        });
    }

    fn appendNode(self: *Builder, node: Node) !u16 {
        if (self.nodes.items.len >= std.math.maxInt(u16)) return error.TooManyDensityNodes;
        const index: u16 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return index;
    }

    fn noiseIndex(self: *Builder, raw_id: []const u8) !u16 {
        const id = stripMinecraft(raw_id);
        for (self.noise_specs.items, 0..) |spec, index| {
            if (std.mem.eql(u8, spec.id, id)) return @intCast(index);
        }
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.noise_dir, id });
        const bytes = try self.cwd.readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        const object = parsed.value.object;
        const values = (object.get("amplitudes") orelse return error.MissingNoiseAmplitudes).array.items;
        if (values.len == 0 or values.len > std.math.maxInt(u8)) return error.InvalidNoiseAmplitudeCount;
        if (self.amplitudes.items.len > std.math.maxInt(u16)) return error.TooManyNoiseAmplitudes;
        const start: u16 = @intCast(self.amplitudes.items.len);
        for (values) |value| try self.amplitudes.append(self.allocator, try jsonF64(value));
        if (self.noise_specs.items.len >= std.math.maxInt(u16)) return error.TooManyNoiseSamplers;
        const index: u16 = @intCast(self.noise_specs.items.len);
        try self.noise_specs.append(self.allocator, .{
            .id = id,
            .first_octave = try jsonI32(object.get("firstOctave") orelse return error.MissingFirstOctave),
            .amplitude_start = start,
            .amplitude_len = @intCast(values.len),
        });
        return index;
    }

    fn appendSpline(self: *Builder, object: std.json.ObjectMap) anyerror!u16 {
        const coordinate = try self.append(object.get("coordinate") orelse return error.MissingSplineCoordinate);
        const json_points = (object.get("points") orelse return error.MissingSplinePoints).array.items;
        var local: std.ArrayListUnmanaged(SplinePoint) = .empty;
        defer local.deinit(self.allocator);
        try local.ensureTotalCapacity(self.allocator, json_points.len);
        for (json_points) |json_point| {
            const point = json_point.object;
            const raw_value = point.get("value") orelse return error.MissingSplinePointValue;
            const value: SplineValue = switch (raw_value) {
                .integer, .float => .{ .kind = .fixed, .payload = @bitCast(try jsonF32(raw_value)) },
                .object => .{ .kind = .spline, .payload = try self.appendSpline(raw_value.object) },
                else => return error.InvalidSplinePointValue,
            };
            local.appendAssumeCapacity(.{
                .location = try jsonF32(point.get("location") orelse return error.MissingSplinePointLocation),
                .derivative = try jsonF32(point.get("derivative") orelse return error.MissingSplinePointDerivative),
                .value = value,
            });
        }
        if (self.spline_points.items.len > std.math.maxInt(u16) or
            self.spline_points.items.len + local.items.len > std.math.maxInt(u16))
            return error.TooManySplinePoints;
        const start: u16 = @intCast(self.spline_points.items.len);
        try self.spline_points.appendSlice(self.allocator, local.items);
        if (self.splines.items.len >= std.math.maxInt(u16)) return error.TooManySplines;
        const index: u16 = @intCast(self.splines.items.len);
        try self.splines.append(self.allocator, .{
            .coordinate = coordinate,
            .point_start = start,
            .point_len = @intCast(local.items.len),
        });
        return index;
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const density_dir = args.next() orelse return error.MissingDensityDirectory;
    const noise_dir = args.next() orelse return error.MissingNoiseDirectory;
    const settings_path = args.next() orelse return error.MissingNoiseSettings;
    const output_path = args.next() orelse return error.MissingOutputPath;

    const cwd = std.Io.Dir.cwd();
    const settings = try parseDensitySettings(allocator, init.io, cwd, settings_path);
    var builder = Builder{
        .io = init.io,
        .cwd = cwd,
        .allocator = allocator,
        .density_dir = density_dir,
        .noise_dir = noise_dir,
    };
    const roots = try appendDensityRoots(allocator, &builder, settings.router);
    try ensureSpline(&builder);

    try writeDensityOutput(allocator, init.io, cwd, output_path, &builder, roots, settings);
}

fn writeDensityOutput(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, output_path: []const u8, builder: *const Builder, roots: []const Root, settings: DensitySettings) !void {
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    try output.appendSlice(
        \\pub const Tag = enum(u8) { constant, add, multiply, minimum, maximum, absolute, square, cube, half_negative, quarter_negative, squeeze, clamp, y_gradient, noise, shift_a, shift_b, shifted_noise, range_choice, interpolated, spline, weird_scaled_type_1, weird_scaled_type_2, old_blended_noise, end_islands };
        \\pub const Node = struct { tag: Tag, a: u16, b: u16, c: u16, aux: u16, i0: i32, i1: i32, x: f64, y: f64, z: f64, w: f64, v: f64 };
        \\pub const NoiseSpec = struct { id: []const u8, first_octave: i32, amplitude_start: u16, amplitude_len: u8 };
        \\pub const SplineValueKind = enum(u8) { fixed, spline };
        \\pub const SplineValue = struct { kind: SplineValueKind, payload: u32 };
        \\pub const SplinePoint = struct { location: f32, derivative: f32, value: SplineValue };
        \\pub const Spline = struct { coordinate: u16, point_start: u16, point_len: u16 };
        \\
        \\pub const amplitudes = [_]f64{
        \\
    );
    for (builder.amplitudes.items) |value| try output.print("    @bitCast(@as(u64, 0x{x:0>16})),\n", .{@as(u64, @bitCast(value))});
    try output.appendSlice("};\n\npub const noise_specs = [_]NoiseSpec{\n");
    for (builder.noise_specs.items) |spec| try output.print(
        "    .{{ .id = \"minecraft:{s}\", .first_octave = {d}, .amplitude_start = {d}, .amplitude_len = {d} }},\n",
        .{ spec.id, spec.first_octave, spec.amplitude_start, spec.amplitude_len },
    );
    try output.appendSlice("};\n\npub const spline_points = [_]SplinePoint{\n");
    for (builder.spline_points.items) |point| try output.print(
        "    .{{ .location = @bitCast(@as(u32, 0x{x:0>8})), .derivative = @bitCast(@as(u32, 0x{x:0>8})), .value = .{{ .kind = .{s}, .payload = 0x{x:0>8} }} }},\n",
        .{ @as(u32, @bitCast(point.location)), @as(u32, @bitCast(point.derivative)), @tagName(point.value.kind), point.value.payload },
    );
    try output.appendSlice("};\n\npub const splines = [_]Spline{\n");
    for (builder.splines.items) |spline| try output.print(
        "    .{{ .coordinate = {d}, .point_start = {d}, .point_len = {d} }},\n",
        .{ spline.coordinate, spline.point_start, spline.point_len },
    );
    try output.appendSlice("};\n\npub const nodes = [_]Node{\n");
    for (builder.nodes.items) |node| try output.print(
        "    .{{ .tag = .{s}, .a = {d}, .b = {d}, .c = {d}, .aux = {d}, .i0 = {d}, .i1 = {d}, .x = @bitCast(@as(u64, 0x{x:0>16})), .y = @bitCast(@as(u64, 0x{x:0>16})), .z = @bitCast(@as(u64, 0x{x:0>16})), .w = @bitCast(@as(u64, 0x{x:0>16})), .v = @bitCast(@as(u64, 0x{x:0>16})) }},\n",
        .{ @tagName(node.tag), node.a, node.b, node.c, node.aux, node.i0, node.i1, @as(u64, @bitCast(node.x)), @as(u64, @bitCast(node.y)), @as(u64, @bitCast(node.z)), @as(u64, @bitCast(node.w)), @as(u64, @bitCast(node.v)) },
    );
    try output.appendSlice("};\n\n");
    for (roots) |root| try output.print("pub const {s}: u16 = {d};\n", .{ root.name, root.index });
    try output.print(
        \\pub const minimum_y = {d};
        \\pub const height = {d};
        \\pub const horizontal_cell_size = {d};
        \\pub const vertical_cell_size = {d};
        \\pub const sea_level = {d};
        \\pub const legacy_random_source = {};
        \\pub const default_block = "{s}";
        \\pub const default_fluid = "{s}";
        \\
    , .{
        settings.minimum_y,
        settings.height,
        settings.horizontal_cell_size,
        settings.vertical_cell_size,
        settings.sea_level,
        settings.legacy_random_source,
        settings.default_block,
        settings.default_fluid,
    });
    try cwd.writeFile(io, .{ .sub_path = output_path, .data = output.items });
}

fn parseDensitySettings(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) !DensitySettings {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const object = parsed.value.object;
    const shape = (object.get("noise") orelse return error.MissingNoiseShape).object;
    const height = try jsonI32(shape.get("height") orelse return error.MissingHeight);
    const horizontal_cell_size = 4 * try jsonI32(shape.get("size_horizontal") orelse return error.MissingHorizontalCellSize);
    const vertical_cell_size = 4 * try jsonI32(shape.get("size_vertical") orelse return error.MissingVerticalCellSize);
    if (height <= 0 or @mod(height, vertical_cell_size) != 0 or @mod(16, horizontal_cell_size) != 0) return error.InvalidNoiseShape;
    return .{ .router = (object.get("noise_router") orelse return error.MissingNoiseRouter).object, .minimum_y = try jsonI32(shape.get("min_y") orelse return error.MissingMinimumY), .height = height, .horizontal_cell_size = horizontal_cell_size, .vertical_cell_size = vertical_cell_size, .sea_level = try jsonI32(object.get("sea_level") orelse return error.MissingSeaLevel), .legacy_random_source = (object.get("legacy_random_source") orelse return error.MissingLegacyRandomSource).bool, .default_block = try blockStateName(allocator, (object.get("default_block") orelse return error.MissingDefaultBlock).object), .default_fluid = try blockStateName(allocator, (object.get("default_fluid") orelse return error.MissingDefaultFluid).object) };
}

fn appendDensityRoots(allocator: std.mem.Allocator, builder: *Builder, router: std.json.ObjectMap) ![]const Root {
    const names = [_][]const u8{ "barrier", "fluid_level_floodedness", "fluid_level_spread", "lava", "temperature", "vegetation", "continents", "erosion", "depth", "ridges", "initial_density_without_jaggedness", "final_density", "vein_toggle", "vein_ridged", "vein_gap" };
    var roots: std.ArrayListUnmanaged(Root) = .empty;
    for (names) |name| try roots.append(allocator, .{ .name = name, .index = try builder.append(router.get(name) orelse return error.MissingDensityRouterRoot) });
    return roots.items;
}

fn ensureSpline(builder: *Builder) !void {
    if (builder.splines.items.len != 0) return;
    try builder.spline_points.append(builder.allocator, .{ .location = 0, .derivative = 0, .value = .{ .kind = .fixed, .payload = @bitCast(@as(f32, 0)) } });
    try builder.splines.append(builder.allocator, .{ .coordinate = 0, .point_start = 0, .point_len = 1 });
}

fn blockStateName(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]const u8 {
    const name = (object.get("Name") orelse return error.MissingBlockStateName).string;
    const properties_value = object.get("Properties") orelse return name;
    const properties = properties_value.object;
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    var iterator = properties.iterator();
    while (iterator.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    var result = std.array_list.Managed(u8).init(allocator);
    try result.appendSlice(name);
    try result.append('[');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try result.append(',');
        try result.appendSlice(key);
        try result.append('=');
        try result.appendSlice(properties.get(key).?.string);
    }
    try result.append(']');
    return result.items;
}

fn stripMinecraft(value: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, value, "minecraft:")) value["minecraft:".len..] else value;
}

fn jsonF64(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => error.InvalidNumber,
    };
}

fn jsonF32(value: std.json.Value) !f32 {
    return @floatCast(try jsonF64(value));
}

fn jsonI32(value: std.json.Value) !i32 {
    return switch (value) {
        .integer => |number| std.math.cast(i32, number) orelse error.NumberOutOfRange,
        else => error.InvalidInteger,
    };
}
