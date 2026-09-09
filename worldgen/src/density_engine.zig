const std = @import("std");
const preallocated = @import("preallocated");
const program = @import("density_program.zig");
const legacy_noise = @import("legacy_noise.zig");
const noise = @import("noise.zig");
const random = @import("random.zig");

pub const sample_lanes = noise.sample_lanes;

pub fn Engine(comptime data: type) type {
    return struct {
        pub const vector_lanes = noise.sample_lanes;
        const EvaluationPlan = struct {
            indices: [data.nodes.len]u16,
            count: usize,
        };

        const interpolation_plan = buildInterpolationPlan();
        const final_plan = buildRuntimePlan(data.final_density);
        const barrier_plan = buildRuntimePlan(data.barrier);
        const vein_toggle_plan = buildRuntimePlan(data.vein_toggle);
        const vein_ridged_plan = buildRuntimePlan(data.vein_ridged);
        const vein_gap_plan = buildRuntimePlan(data.vein_gap);
        const initial_density_plan =
            buildRuntimePlan(data.initial_density_without_jaggedness);
        const y_independent_nodes = findYIndependentNodes();
        const interpolation_count = countInterpolatedNodes();
        const interpolation_index_by_node = buildInterpolationIndex();

        fn countInterpolatedNodes() usize {
            var count: usize = 0;
            for (data.nodes) |node|
                if (node.tag == .interpolated) {
                    count += 1;
                };
            return count;
        }

        fn buildInterpolationIndex() [data.nodes.len]u8 {
            var result = [_]u8{std.math.maxInt(u8)} ** data.nodes.len;
            var index: u8 = 0;
            for (data.nodes, 0..) |node, node_index| {
                if (node.tag != .interpolated) continue;
                result[node_index] = index;
                index += 1;
            }
            return result;
        }

        fn findYIndependentNodes() [data.nodes.len]bool {
            var result = [_]bool{false} ** data.nodes.len;
            for (data.nodes, 0..) |node, index| {
                result[index] = switch (node.tag) {
                    .constant, .shift_a, .shift_b => true,
                    .end_islands => true,
                    .add, .multiply, .minimum, .maximum => result[node.a] and result[node.b],
                    .absolute,
                    .square,
                    .cube,
                    .half_negative,
                    .quarter_negative,
                    .squeeze,
                    .clamp,
                    .interpolated,
                    => result[node.a],
                    .noise => node.y == 0,
                    .shifted_noise => node.y == 0 and result[node.a] and result[node.b] and result[node.c],
                    .range_choice => result[node.a] and result[node.b] and result[node.c],
                    .spline => splineIsYIndependent(&result, node.aux),
                    .y_gradient,
                    .weird_scaled_type_1,
                    .weird_scaled_type_2,
                    .old_blended_noise,
                    => false,
                };
            }
            return result;
        }

        fn splineIsYIndependent(nodes: *const [data.nodes.len]bool, index: u32) bool {
            const spline = data.splines[index];
            if (!nodes[spline.coordinate]) return false;
            for (data.spline_points[spline.point_start..][0..spline.point_len]) |point| {
                if (point.value.kind == .spline and !splineIsYIndependent(nodes, point.value.payload))
                    return false;
            }
            return true;
        }

        fn buildInterpolationPlan() EvaluationPlan {
            @setEvalBranchQuota(data.nodes.len * data.nodes.len * 8);
            var required = [_]bool{false} ** data.nodes.len;
            for (data.nodes) |node| {
                if (node.tag == .interpolated)
                    markNodeDependencies(&required, node.a);
            }
            var plan: EvaluationPlan = .{
                .indices = undefined,
                .count = 0,
            };
            for (required, 0..) |needed, index| {
                if (!needed) continue;
                plan.indices[plan.count] = @intCast(index);
                plan.count += 1;
            }
            return plan;
        }

        fn buildRuntimePlan(root: u16) EvaluationPlan {
            @setEvalBranchQuota(data.nodes.len * data.nodes.len * 8);
            var required = [_]bool{false} ** data.nodes.len;
            markRuntimeDependencies(&required, root);
            var plan: EvaluationPlan = .{
                .indices = undefined,
                .count = 0,
            };
            for (required, 0..) |needed, index| {
                if (!needed) continue;
                plan.indices[plan.count] = @intCast(index);
                plan.count += 1;
            }
            return plan;
        }

        fn markRuntimeDependencies(required: *[data.nodes.len]bool, index: u16) void {
            if (required[index]) return;
            required[index] = true;
            const node = data.nodes[index];
            switch (node.tag) {
                .add, .multiply, .minimum, .maximum => {
                    markRuntimeDependencies(required, node.a);
                    markRuntimeDependencies(required, node.b);
                },
                .absolute,
                .square,
                .cube,
                .half_negative,
                .quarter_negative,
                .squeeze,
                .clamp,
                .weird_scaled_type_1,
                .weird_scaled_type_2,
                => markRuntimeDependencies(required, node.a),
                .shifted_noise => {
                    markRuntimeDependencies(required, node.a);
                    markRuntimeDependencies(required, node.b);
                    markRuntimeDependencies(required, node.c);
                },
                .range_choice => {
                    markRuntimeDependencies(required, node.a);
                    markRuntimeDependencies(required, node.b);
                    markRuntimeDependencies(required, node.c);
                },
                .spline => markRuntimeSplineDependencies(required, node.aux),
                .interpolated,
                .constant,
                .end_islands,
                .y_gradient,
                .noise,
                .shift_a,
                .shift_b,
                .old_blended_noise,
                => {},
            }
        }

        fn markRuntimeSplineDependencies(required: *[data.nodes.len]bool, index: u32) void {
            const spline = data.splines[index];
            markRuntimeDependencies(required, spline.coordinate);
            for (data.spline_points[spline.point_start..][0..spline.point_len]) |point| {
                if (point.value.kind == .spline)
                    markRuntimeSplineDependencies(required, point.value.payload);
            }
        }

        fn markNodeDependencies(required: *[data.nodes.len]bool, index: u16) void {
            if (required[index]) return;
            required[index] = true;
            const node = data.nodes[index];
            switch (node.tag) {
                .add, .multiply, .minimum, .maximum => {
                    markNodeDependencies(required, node.a);
                    markNodeDependencies(required, node.b);
                },
                .absolute,
                .square,
                .cube,
                .half_negative,
                .quarter_negative,
                .squeeze,
                .clamp,
                .interpolated,
                .weird_scaled_type_1,
                .weird_scaled_type_2,
                => markNodeDependencies(required, node.a),
                .shifted_noise => {
                    markNodeDependencies(required, node.a);
                    markNodeDependencies(required, node.b);
                    markNodeDependencies(required, node.c);
                },
                .range_choice => {
                    markNodeDependencies(required, node.a);
                    markNodeDependencies(required, node.b);
                    markNodeDependencies(required, node.c);
                },
                .spline => markSplineDependencies(required, node.aux),
                .constant,
                .end_islands,
                .y_gradient,
                .noise,
                .shift_a,
                .shift_b,
                .old_blended_noise,
                => {},
            }
        }

        fn markSplineDependencies(required: *[data.nodes.len]bool, index: u32) void {
            const spline = data.splines[index];
            markNodeDependencies(required, spline.coordinate);
            for (data.spline_points[spline.point_start..][0..spline.point_len]) |point| {
                if (point.value.kind == .spline)
                    markSplineDependencies(required, point.value.payload);
            }
        }

        pub const Position = struct {
            x: i32,
            y: i32,
            z: i32,
        };

        const InterpolationOverride = struct {
            node: u16,
            value: f64,
        };

        const InterpolationOverride4 = struct {
            node: u16,
            value: noise.Samples,
        };

        fn initOldBlended(world_seed: u64, splitter: random.Splitter, node: data.Node) noise.Interpolated {
            if (data.legacy_random_source) {
                var source = legacy_noise.Random.init(@bitCast(world_seed));
                return noise.Interpolated.init(&source, node.x, node.y, node.z, node.w, node.v);
            }
            var source = splitter.splitString("minecraft:terrain");
            return noise.Interpolated.init(&source, node.x, node.y, node.z, node.w, node.v);
        }

        fn initEndIslands(world_seed: u64) legacy_noise.Simplex {
            var source = legacy_noise.Random.init(@bitCast(world_seed));
            source.discard(17_292);
            return legacy_noise.Simplex.init(&source);
        }

        fn initSampler(
            world_seed: u64,
            splitter: random.Splitter,
            spec: data.NoiseSpec,
            amplitudes: []const f64,
        ) noise.DoublePerlin {
            if (comptime data.legacy_random_source) {
                if (std.mem.eql(u8, spec.id, "minecraft:offset")) return .zero();
                if (std.mem.eql(u8, spec.id, "minecraft:temperature") or
                    std.mem.eql(u8, spec.id, "minecraft:vegetation"))
                {
                    const salt: u64 = @intFromBool(std.mem.eql(u8, spec.id, "minecraft:vegetation"));
                    var source = legacy_noise.Random.init(@bitCast(world_seed +% salt));
                    return .initLegacySequential(&source, -7, &.{ 1, 1 });
                }
                const legacy_splitter = random.LegacySplitter.init(world_seed);
                var source = legacy_splitter.splitString(spec.id);
                return .initLegacyNamed(&source, spec.first_octave, amplitudes);
            }
            var source = splitter.splitString(spec.id);
            return .init(&source, spec.first_octave, amplitudes);
        }

        fn sampleEndIslands(sampler: *const legacy_noise.Simplex, position: Position) f64 {
            const x = @divTrunc(position.x, 8);
            const z = @divTrunc(position.z, 8);
            const half_x = @divTrunc(x, 2);
            const half_z = @divTrunc(z, 2);
            const parity_x = @rem(x, 2);
            const parity_z = @rem(z, 2);
            const distance_squared = x *% x +% z *% z;
            var height = @as(f32, 100) - @sqrt(@as(f32, @floatFromInt(distance_squared))) * 8;
            if (!std.math.isNan(height)) height = std.math.clamp(height, -100, 80);
            for (0..25) |x_offset_index| {
                const x_offset = @as(i32, @intCast(x_offset_index)) - 12;
                for (0..25) |z_offset_index| {
                    const z_offset = @as(i32, @intCast(z_offset_index)) - 12;
                    const island_x = @as(i64, half_x + x_offset);
                    const island_z = @as(i64, half_z + z_offset);
                    if (island_x * island_x + island_z * island_z <= 4_096) continue;
                    if (sampler.sample2(@floatFromInt(island_x), @floatFromInt(island_z)) >= -0.9) continue;
                    const scale = @mod(
                        @abs(@as(f32, @floatFromInt(island_x))) * 3_439 +
                            @abs(@as(f32, @floatFromInt(island_z))) * 147,
                        13,
                    ) + 9;
                    const dx: f32 = @floatFromInt(parity_x - x_offset * 2);
                    const dz: f32 = @floatFromInt(parity_z - z_offset * 2);
                    if (!std.math.isNan(height))
                        height = @max(height, std.math.clamp(100 - @sqrt(dx * dx + dz * dz) * scale, -100, 80));
                }
            }
            return (@as(f64, height) - 8) / 128;
        }

        fn javaMinimum(a: f64, b: f64) f64 {
            if (std.math.isNan(a) or std.math.isNan(b)) return a + b;
            return @min(a, b);
        }

        fn javaMaximum(a: f64, b: f64) f64 {
            if (std.math.isNan(a) or std.math.isNan(b)) return a + b;
            return @max(a, b);
        }

        fn javaMinimum4(a: noise.Samples, b: noise.Samples) noise.Samples {
            return @select(f64, (a != a) | (b != b), a + b, @min(a, b));
        }

        fn javaMaximum4(a: noise.Samples, b: noise.Samples) noise.Samples {
            return @select(f64, (a != a) | (b != b), a + b, @max(a, b));
        }

        fn javaClamp(value: f64, minimum: f64, maximum: f64) f64 {
            return javaMaximum(minimum, javaMinimum(value, maximum));
        }

        fn javaClamp4(value: noise.Samples, minimum: f64, maximum: f64) noise.Samples {
            return javaMaximum4(@splat(minimum), javaMinimum4(value, @splat(maximum)));
        }

        fn sampleEndIslands4(
            sampler: *const legacy_noise.Simplex,
            positions: [noise.sample_lanes]Position,
        ) noise.Samples {
            var values: [noise.sample_lanes]f64 = undefined;
            inline for (0..noise.sample_lanes) |lane|
                values[lane] = sampleEndIslands(sampler, positions[lane]);
            return values;
        }

        pub const Router = struct {
            allocator: std.mem.Allocator,
            samplers: []noise.DoublePerlin,
            values: []f64,
            values4: [][noise.sample_lanes]f64,
            y_independent_values: []f64,
            y_independent_x: i32 = 0,
            y_independent_z: i32 = 0,
            y_independent_valid: bool = false,
            stamps: []u32,
            generation: u32 = 0,
            old_blended: noise.Interpolated,
            end_islands: legacy_noise.Simplex,

            pub fn init(allocator: std.mem.Allocator, world_seed: u64) !Router {
                const samplers = try preallocated.alloc(noise.DoublePerlin, allocator, data.noise_specs.len);
                errdefer allocator.free(samplers);
                const values = try preallocated.alloc(f64, allocator, data.nodes.len);
                errdefer allocator.free(values);
                const values4 = try preallocated.alloc([noise.sample_lanes]f64, allocator, data.nodes.len);
                errdefer allocator.free(values4);
                @memset(values4, @splat(0));
                const y_independent_values = try preallocated.alloc(f64, allocator, data.nodes.len);
                errdefer allocator.free(y_independent_values);
                const stamps = try preallocated.alloc(u32, allocator, data.nodes.len);
                errdefer allocator.free(stamps);
                @memset(stamps, 0);

                var base_random = random.Xoroshiro.init(world_seed);
                const splitter = base_random.splitter();
                for (data.noise_specs, samplers) |spec, *sampler| {
                    const start: usize = spec.amplitude_start;
                    const amplitudes = data.amplitudes[start..][0..spec.amplitude_len];
                    sampler.* = initSampler(world_seed, splitter, spec, amplitudes);
                }

                const old_node = for (data.nodes) |node| {
                    if (node.tag == .old_blended_noise) break node;
                } else return error.MissingOldBlendedNoise;
                return .{
                    .allocator = allocator,
                    .samplers = samplers,
                    .values = values,
                    .values4 = values4,
                    .y_independent_values = y_independent_values,
                    .stamps = stamps,
                    .old_blended = initOldBlended(world_seed, splitter, old_node),
                    .end_islands = initEndIslands(world_seed),
                };
            }

            pub fn deinit(self: *Router) void {
                self.allocator.free(self.stamps);
                self.allocator.free(self.y_independent_values);
                self.allocator.free(self.values4);
                self.allocator.free(self.values);
                self.allocator.free(self.samplers);
                self.* = undefined;
            }

            pub fn reseed(self: *Router, world_seed: u64) !void {
                var base_random = random.Xoroshiro.init(world_seed);
                const splitter = base_random.splitter();
                for (data.noise_specs, self.samplers) |spec, *sampler| {
                    const start: usize = spec.amplitude_start;
                    sampler.* = initSampler(
                        world_seed,
                        splitter,
                        spec,
                        data.amplitudes[start..][0..spec.amplitude_len],
                    );
                }
                const old_node = for (data.nodes) |node| {
                    if (node.tag == .old_blended_noise) break node;
                } else return error.MissingOldBlendedNoise;
                self.old_blended = initOldBlended(world_seed, splitter, old_node);
                self.end_islands = initEndIslands(world_seed);
                self.generation = 0;
                self.y_independent_valid = false;
                @memset(self.stamps, 0);
            }

            pub fn sampleFinal(self: *Router, position: Position) f64 {
                return self.sample(data.final_density, position);
            }

            fn sampleFinal4(
                self: *Router,
                positions: [noise.sample_lanes]Position,
                overrides: []const InterpolationOverride4,
            ) noise.Samples {
                return self.sampleRuntime4(
                    data.final_density,
                    final_plan,
                    positions,
                    overrides,
                );
            }

            pub fn sampleBarrier4(
                self: *Router,
                positions: [noise.sample_lanes]Position,
            ) noise.Samples {
                return self.sampleRuntime4(data.barrier, barrier_plan, positions, &.{});
            }

            fn sampleRuntime4(
                self: *Router,
                comptime root: u16,
                comptime plan: EvaluationPlan,
                positions: [noise.sample_lanes]Position,
                overrides: []const InterpolationOverride4,
            ) noise.Samples {
                @setRuntimeSafety(false);
                var position_values: [noise.sample_lanes][3]i32 = undefined;
                var x_values: [noise.sample_lanes]f64 = undefined;
                var y_values: [noise.sample_lanes]f64 = undefined;
                var z_values: [noise.sample_lanes]f64 = undefined;
                inline for (0..noise.sample_lanes) |lane| {
                    const position = positions[lane];
                    position_values[lane] = .{ position.x, position.y, position.z };
                    x_values[lane] = @floatFromInt(position.x);
                    y_values[lane] = @floatFromInt(position.y);
                    z_values[lane] = @floatFromInt(position.z);
                }
                const x: noise.Samples = x_values;
                const y: noise.Samples = y_values;
                const z: noise.Samples = z_values;
                inline for (plan.indices[0..plan.count]) |node_index| {
                    const node = data.nodes[node_index];
                    const a: noise.Samples = self.values4[node.a];
                    const b: noise.Samples = self.values4[node.b];
                    const c: noise.Samples = self.values4[node.c];
                    self.values4[node_index] = switch (node.tag) {
                        .constant => @splat(node.x),
                        .add => a + b,
                        .multiply => a * b,
                        .minimum => javaMinimum4(a, b),
                        .maximum => javaMaximum4(a, b),
                        .absolute => @abs(a),
                        .square => a * a,
                        .cube => a * a * a,
                        .half_negative => @select(
                            f64,
                            a > @as(noise.Samples, @splat(0)),
                            a,
                            a * @as(noise.Samples, @splat(0.5)),
                        ),
                        .quarter_negative => @select(
                            f64,
                            a > @as(noise.Samples, @splat(0)),
                            a,
                            a * @as(noise.Samples, @splat(0.25)),
                        ),
                        .squeeze => squeeze4(a),
                        .clamp => javaClamp4(a, node.x, node.y),
                        .y_gradient => clampedMap4(
                            y,
                            @floatFromInt(node.i0),
                            @floatFromInt(node.i1),
                            node.x,
                            node.y,
                        ),
                        .noise => self.samplers[node.aux].sample4(
                            x * @as(noise.Samples, @splat(node.x)),
                            y * @as(noise.Samples, @splat(node.y)),
                            z * @as(noise.Samples, @splat(node.x)),
                        ),
                        .shift_a => self.samplers[node.aux].sample4(
                            x * @as(noise.Samples, @splat(0.25)),
                            @splat(0),
                            z * @as(noise.Samples, @splat(0.25)),
                        ) * @as(noise.Samples, @splat(4)),
                        .shift_b => self.samplers[node.aux].sample4(
                            z * @as(noise.Samples, @splat(0.25)),
                            x * @as(noise.Samples, @splat(0.25)),
                            @splat(0),
                        ) * @as(noise.Samples, @splat(4)),
                        .shifted_noise => self.samplers[node.aux].sample4(
                            x * @as(noise.Samples, @splat(node.x)) + a,
                            y * @as(noise.Samples, @splat(node.y)) + b,
                            z * @as(noise.Samples, @splat(node.x)) + c,
                        ),
                        .range_choice => @select(
                            f64,
                            (a >= @as(noise.Samples, @splat(node.x))) &
                                (a < @as(noise.Samples, @splat(node.y))),
                            b,
                            c,
                        ),
                        .interpolated => interpolationOverride4(overrides, node_index),
                        .spline => self.sampleSplinePrepared4(node.aux),
                        .weird_scaled_type_1 => self.sampleWeirdPrepared4(
                            node,
                            x,
                            y,
                            z,
                            type1Scale4(a),
                        ),
                        .weird_scaled_type_2 => self.sampleWeirdPrepared4(
                            node,
                            x,
                            y,
                            z,
                            type2Scale4(a),
                        ),
                        .old_blended_noise => self.old_blended.sample4(position_values),
                        .end_islands => sampleEndIslands4(&self.end_islands, positions),
                    };
                }
                return self.values4[root];
            }

            pub fn sampleInitialDensityWithoutJaggedness(self: *Router, position: Position) f64 {
                return self.sample(data.initial_density_without_jaggedness, position);
            }

            pub fn sampleInitialDensityWithoutJaggedness4(
                self: *Router,
                positions: [noise.sample_lanes]Position,
            ) noise.Samples {
                return self.sampleRuntime4(
                    data.initial_density_without_jaggedness,
                    initial_density_plan,
                    positions,
                    &.{},
                );
            }

            pub fn sampleBarrier(self: *Router, position: Position) f64 {
                return self.sample(data.barrier, position);
            }

            pub fn sampleFluidLevelFloodedness(self: *Router, position: Position) f64 {
                return self.sample(data.fluid_level_floodedness, position);
            }

            pub fn sampleFluidLevelSpread(self: *Router, position: Position) f64 {
                return self.sample(data.fluid_level_spread, position);
            }

            pub fn sampleLava(self: *Router, position: Position) f64 {
                return self.sample(data.lava, position);
            }

            pub fn sampleErosion(self: *Router, position: Position) f64 {
                return self.sample(data.erosion, position);
            }

            pub fn sampleTemperature(self: *Router, position: Position) f64 {
                return self.sample(data.temperature, position);
            }

            pub fn sampleVegetation(self: *Router, position: Position) f64 {
                return self.sample(data.vegetation, position);
            }

            pub fn sampleDepth(self: *Router, position: Position) f64 {
                return self.sample(data.depth, position);
            }

            pub fn sample(self: *Router, root: u16, position: Position) f64 {
                return self.sampleWithOverrides(root, position, &.{});
            }

            pub fn sampleRoots(
                self: *Router,
                roots: []const u16,
                position: Position,
                output: []f64,
            ) void {
                std.debug.assert(roots.len == output.len);
                self.evaluateAll(position);
                for (roots, output) |root, *value|
                    value.* = self.values[root];
            }

            pub fn sampleRoots4(
                self: *Router,
                roots: []const u16,
                positions: [noise.sample_lanes]Position,
                output: []noise.Samples,
            ) void {
                std.debug.assert(roots.len == output.len);
                self.evaluateAll4(positions);
                for (roots, output) |root, *value|
                    value.* = self.values4[root];
            }

            fn evaluateAll4(self: *Router, positions: [noise.sample_lanes]Position) void {
                @setRuntimeSafety(false);
                inline for (1..noise.sample_lanes) |lane| {
                    std.debug.assert(positions[lane].x == positions[0].x);
                    std.debug.assert(positions[lane].z == positions[0].z);
                }
                const reuse_y_independent = self.y_independent_valid and
                    self.y_independent_x == positions[0].x and
                    self.y_independent_z == positions[0].z;
                if (!reuse_y_independent) {
                    self.y_independent_x = positions[0].x;
                    self.y_independent_z = positions[0].z;
                    self.y_independent_valid = true;
                }
                var position_values: [noise.sample_lanes][3]i32 = undefined;
                var x_values: [noise.sample_lanes]f64 = undefined;
                var y_values: [noise.sample_lanes]f64 = undefined;
                var z_values: [noise.sample_lanes]f64 = undefined;
                inline for (0..noise.sample_lanes) |lane| {
                    position_values[lane] = .{ positions[lane].x, positions[lane].y, positions[lane].z };
                    x_values[lane] = @floatFromInt(positions[lane].x);
                    y_values[lane] = @floatFromInt(positions[lane].y);
                    z_values[lane] = @floatFromInt(positions[lane].z);
                }
                const x: noise.Samples = x_values;
                const y: noise.Samples = y_values;
                const z: noise.Samples = z_values;
                inline for (interpolation_plan.indices[0..interpolation_plan.count]) |node_index| {
                    if (y_independent_nodes[node_index] and reuse_y_independent) {
                        self.values4[node_index] = @splat(self.y_independent_values[node_index]);
                    } else {
                        const node = data.nodes[node_index];
                        const a: noise.Samples = self.values4[node.a];
                        const b: noise.Samples = self.values4[node.b];
                        const c: noise.Samples = self.values4[node.c];
                        const value: noise.Samples = switch (node.tag) {
                            .constant => @splat(node.x),
                            .add => a + b,
                            .multiply => a * b,
                            .minimum => javaMinimum4(a, b),
                            .maximum => javaMaximum4(a, b),
                            .absolute => @abs(a),
                            .square => a * a,
                            .cube => a * a * a,
                            .half_negative => @select(f64, a > @as(noise.Samples, @splat(0)), a, a * @as(noise.Samples, @splat(0.5))),
                            .quarter_negative => @select(f64, a > @as(noise.Samples, @splat(0)), a, a * @as(noise.Samples, @splat(0.25))),
                            .squeeze => squeeze4(a),
                            .clamp => javaClamp4(a, node.x, node.y),
                            .y_gradient => clampedMap4(y, @floatFromInt(node.i0), @floatFromInt(node.i1), node.x, node.y),
                            .noise => if (node.y == 0)
                                @splat(self.samplers[node.aux].sample(
                                    x[0] * node.x,
                                    0,
                                    z[0] * node.x,
                                ))
                            else
                                self.samplers[node.aux].sample4(
                                    x * @as(noise.Samples, @splat(node.x)),
                                    y * @as(noise.Samples, @splat(node.y)),
                                    z * @as(noise.Samples, @splat(node.x)),
                                ),
                            .shift_a => @as(noise.Samples, @splat(
                                self.samplers[node.aux].sample(
                                    x[0] * 0.25,
                                    0,
                                    z[0] * 0.25,
                                ) * 4,
                            )),
                            .shift_b => @as(noise.Samples, @splat(
                                self.samplers[node.aux].sample(
                                    z[0] * 0.25,
                                    x[0] * 0.25,
                                    0,
                                ) * 4,
                            )),
                            .shifted_noise => if (y_independent_nodes[node_index])
                                @splat(self.samplers[node.aux].sample(
                                    x[0] * node.x + a[0],
                                    y[0] * node.y + b[0],
                                    z[0] * node.x + c[0],
                                ))
                            else
                                self.samplers[node.aux].sample4(
                                    x * @as(noise.Samples, @splat(node.x)) + a,
                                    y * @as(noise.Samples, @splat(node.y)) + b,
                                    z * @as(noise.Samples, @splat(node.x)) + c,
                                ),
                            .range_choice => @select(
                                f64,
                                (a >= @as(noise.Samples, @splat(node.x))) & (a < @as(noise.Samples, @splat(node.y))),
                                b,
                                c,
                            ),
                            .interpolated => a,
                            .spline => self.sampleSplinePrepared4(node.aux),
                            .weird_scaled_type_1 => self.sampleWeirdPrepared4(node, x, y, z, type1Scale4(a)),
                            .weird_scaled_type_2 => self.sampleWeirdPrepared4(node, x, y, z, type2Scale4(a)),
                            .old_blended_noise => self.old_blended.sample4(position_values),
                            .end_islands => sampleEndIslands4(&self.end_islands, positions),
                        };
                        self.values4[node_index] = value;
                        if (y_independent_nodes[node_index])
                            self.y_independent_values[node_index] = value[0];
                    }
                }
            }

            fn sampleWeirdPrepared4(
                self: *const Router,
                node: data.Node,
                x: noise.Samples,
                y: noise.Samples,
                z: noise.Samples,
                scale: noise.Samples,
            ) noise.Samples {
                return scale * @abs(self.samplers[node.aux].sample4(x / scale, y / scale, z / scale));
            }

            fn sampleSplinePrepared4(self: *const Router, spline_index: u32) noise.Samples {
                var result: [noise.sample_lanes]f64 = undefined;
                inline for (0..noise.sample_lanes) |lane|
                    result[lane] = self.sampleSplinePreparedLane(spline_index, lane);
                return result;
            }

            fn sampleSplinePreparedLane(self: *const Router, spline_index: u32, comptime lane: usize) f32 {
                const spline = data.splines[spline_index];
                const points = data.spline_points[spline.point_start..][0..spline.point_len];
                const location: f32 = @floatCast(self.values4[spline.coordinate][lane]);
                const upper = firstGreater(points, location);
                if (upper == 0) return self.sampleOutsidePreparedLane(points[0], location, lane);
                const lower_index = upper - 1;
                const lower = points[lower_index];
                if (lower_index == points.len - 1)
                    return self.sampleOutsidePreparedLane(lower, location, lane);
                const upper_point = points[upper];
                const lower_value = self.sampleSplineValuePreparedLane(lower.value, lane);
                const upper_value = self.sampleSplineValuePreparedLane(upper_point.value, lane);
                const location_delta = upper_point.location - lower.location;
                const fraction = (location - lower.location) / location_delta;
                const lower_excess = lower.derivative * location_delta - (upper_value - lower_value);
                const upper_excess = -upper_point.derivative * location_delta + (upper_value - lower_value);
                return fraction * (1 - fraction) * lerpF32(fraction, lower_excess, upper_excess) +
                    lerpF32(fraction, lower_value, upper_value);
            }

            fn sampleOutsidePreparedLane(self: *const Router, point: data.SplinePoint, location: f32, comptime lane: usize) f32 {
                const value = self.sampleSplineValuePreparedLane(point.value, lane);
                if (point.derivative == 0) return value;
                return point.derivative * (location - point.location) + value;
            }

            fn sampleSplineValuePreparedLane(self: *const Router, value: data.SplineValue, comptime lane: usize) f32 {
                return switch (value.kind) {
                    .fixed => @bitCast(value.payload),
                    .spline => self.sampleSplinePreparedLane(value.payload, lane),
                };
            }

            fn evaluateAll(self: *Router, position: Position) void {
                @setRuntimeSafety(false);
                const reuse_y_independent = self.y_independent_valid and
                    self.y_independent_x == position.x and
                    self.y_independent_z == position.z;
                if (!reuse_y_independent) {
                    self.y_independent_x = position.x;
                    self.y_independent_z = position.z;
                    self.y_independent_valid = true;
                }
                const x: f64 = @floatFromInt(position.x);
                const y: f64 = @floatFromInt(position.y);
                const z: f64 = @floatFromInt(position.z);
                inline for (interpolation_plan.indices[0..interpolation_plan.count]) |node_index| {
                    if (y_independent_nodes[node_index] and reuse_y_independent) {
                        self.values[node_index] = self.y_independent_values[node_index];
                    } else {
                        const node = data.nodes[node_index];
                        self.values[node_index] = switch (node.tag) {
                            .constant => node.x,
                            .add => self.values[node.a] + self.values[node.b],
                            .multiply => self.values[node.a] * self.values[node.b],
                            .minimum => javaMinimum(self.values[node.a], self.values[node.b]),
                            .maximum => javaMaximum(self.values[node.a], self.values[node.b]),
                            .absolute => @abs(self.values[node.a]),
                            .square => square(self.values[node.a]),
                            .cube => cube(self.values[node.a]),
                            .half_negative => halfNegative(self.values[node.a]),
                            .quarter_negative => quarterNegative(self.values[node.a]),
                            .squeeze => squeeze(self.values[node.a]),
                            .clamp => javaClamp(self.values[node.a], node.x, node.y),
                            .y_gradient => clampedMap(y, @floatFromInt(node.i0), @floatFromInt(node.i1), node.x, node.y),
                            .noise => self.samplers[node.aux].sample(x * node.x, y * node.y, z * node.x),
                            .shift_a => self.samplers[node.aux].sample(x * 0.25, 0, z * 0.25) * 4,
                            .shift_b => self.samplers[node.aux].sample(z * 0.25, x * 0.25, 0) * 4,
                            .shifted_noise => self.samplers[node.aux].sample(
                                x * node.x + self.values[node.a],
                                y * node.y + self.values[node.b],
                                z * node.x + self.values[node.c],
                            ),
                            .range_choice => self.values[if (self.values[node.a] >= node.x and self.values[node.a] < node.y) node.b else node.c],
                            .interpolated => self.values[node.a],
                            .spline => @floatCast(self.sampleSplinePrepared(node.aux)),
                            .weird_scaled_type_1 => self.sampleWeirdPrepared(node, position, type1Scale(self.values[node.a])),
                            .weird_scaled_type_2 => self.sampleWeirdPrepared(node, position, type2Scale(self.values[node.a])),
                            .old_blended_noise => self.old_blended.sample(position.x, position.y, position.z),
                            .end_islands => sampleEndIslands(&self.end_islands, position),
                        };
                        if (y_independent_nodes[node_index])
                            self.y_independent_values[node_index] = self.values[node_index];
                    }
                }
            }

            fn sampleWeirdPrepared(self: *const Router, node: data.Node, position: Position, scale: f64) f64 {
                return scale * @abs(self.samplers[node.aux].sample(
                    @as(f64, @floatFromInt(position.x)) / scale,
                    @as(f64, @floatFromInt(position.y)) / scale,
                    @as(f64, @floatFromInt(position.z)) / scale,
                ));
            }

            fn sampleSplinePrepared(self: *const Router, spline_index: u32) f32 {
                const spline = data.splines[spline_index];
                const points = data.spline_points[spline.point_start..][0..spline.point_len];
                const location: f32 = @floatCast(self.values[spline.coordinate]);
                const upper = firstGreater(points, location);
                if (upper == 0) return self.sampleOutsidePrepared(points[0], location);
                const lower_index = upper - 1;
                const lower = points[lower_index];
                if (lower_index == points.len - 1)
                    return self.sampleOutsidePrepared(lower, location);
                const upper_point = points[upper];
                const lower_value = self.sampleSplineValuePrepared(lower.value);
                const upper_value = self.sampleSplineValuePrepared(upper_point.value);
                const location_delta = upper_point.location - lower.location;
                const fraction = (location - lower.location) / location_delta;
                const lower_excess = lower.derivative * location_delta - (upper_value - lower_value);
                const upper_excess = -upper_point.derivative * location_delta + (upper_value - lower_value);
                return fraction * (1 - fraction) * lerpF32(fraction, lower_excess, upper_excess) +
                    lerpF32(fraction, lower_value, upper_value);
            }

            fn sampleOutsidePrepared(self: *const Router, point: data.SplinePoint, location: f32) f32 {
                const value = self.sampleSplineValuePrepared(point.value);
                if (point.derivative == 0) return value;
                return point.derivative * (location - point.location) + value;
            }

            fn sampleSplineValuePrepared(self: *const Router, value: data.SplineValue) f32 {
                return switch (value.kind) {
                    .fixed => @bitCast(value.payload),
                    .spline => self.sampleSplinePrepared(value.payload),
                };
            }

            fn sampleWithOverrides(
                self: *Router,
                root: u16,
                position: Position,
                overrides: []const InterpolationOverride,
            ) f64 {
                self.nextGeneration();
                return self.evaluate(root, position, overrides);
            }

            fn nextGeneration(self: *Router) void {
                self.generation +%= 1;
                if (self.generation == 0) {
                    @memset(self.stamps, 0);
                    self.generation = 1;
                }
            }

            fn evaluate(
                self: *Router,
                node_index: u16,
                position: Position,
                overrides: []const InterpolationOverride,
            ) f64 {
                @setRuntimeSafety(false);
                if (self.stamps[node_index] == self.generation) return self.values[node_index];
                const node = data.nodes[node_index];
                const x: f64 = @floatFromInt(position.x);
                const y: f64 = @floatFromInt(position.y);
                const z: f64 = @floatFromInt(position.z);
                const value: f64 = switch (node.tag) {
                    .constant => node.x,
                    .add => self.evaluate(node.a, position, overrides) + self.evaluate(node.b, position, overrides),
                    .multiply => self.evaluate(node.a, position, overrides) * self.evaluate(node.b, position, overrides),
                    .minimum => javaMinimum(self.evaluate(node.a, position, overrides), self.evaluate(node.b, position, overrides)),
                    .maximum => javaMaximum(self.evaluate(node.a, position, overrides), self.evaluate(node.b, position, overrides)),
                    .absolute => @abs(self.evaluate(node.a, position, overrides)),
                    .square => square(self.evaluate(node.a, position, overrides)),
                    .cube => cube(self.evaluate(node.a, position, overrides)),
                    .half_negative => halfNegative(self.evaluate(node.a, position, overrides)),
                    .quarter_negative => quarterNegative(self.evaluate(node.a, position, overrides)),
                    .squeeze => squeeze(self.evaluate(node.a, position, overrides)),
                    .clamp => javaClamp(self.evaluate(node.a, position, overrides), node.x, node.y),
                    .y_gradient => clampedMap(y, @floatFromInt(node.i0), @floatFromInt(node.i1), node.x, node.y),
                    .noise => self.samplers[node.aux].sample(x * node.x, y * node.y, z * node.x),
                    .shift_a => self.samplers[node.aux].sample(x * 0.25, 0, z * 0.25) * 4,
                    .shift_b => self.samplers[node.aux].sample(z * 0.25, x * 0.25, 0) * 4,
                    .shifted_noise => self.samplers[node.aux].sample(
                        x * node.x + self.evaluate(node.a, position, overrides),
                        y * node.y + self.evaluate(node.b, position, overrides),
                        z * node.x + self.evaluate(node.c, position, overrides),
                    ),
                    .range_choice => self.evaluateRangeChoice(node, position, overrides),
                    .interpolated => interpolationOverride(overrides, node_index) orelse
                        self.evaluate(node.a, position, overrides),
                    .spline => @floatCast(self.sampleSpline(node.aux, position, overrides)),
                    .weird_scaled_type_1 => self.sampleWeird(
                        node,
                        position,
                        type1Scale(self.evaluate(node.a, position, overrides)),
                    ),
                    .weird_scaled_type_2 => self.sampleWeird(
                        node,
                        position,
                        type2Scale(self.evaluate(node.a, position, overrides)),
                    ),
                    .old_blended_noise => self.old_blended.sample(position.x, position.y, position.z),
                    .end_islands => sampleEndIslands(&self.end_islands, position),
                };
                self.values[node_index] = value;
                self.stamps[node_index] = self.generation;
                return value;
            }

            fn evaluateRangeChoice(
                self: *Router,
                node: data.Node,
                position: Position,
                overrides: []const InterpolationOverride,
            ) f64 {
                const input = self.evaluate(node.a, position, overrides);
                return self.evaluate(if (input >= node.x and input < node.y) node.b else node.c, position, overrides);
            }

            fn sampleWeird(
                self: *const Router,
                node: data.Node,
                position: Position,
                scale: f64,
            ) f64 {
                return scale * @abs(self.samplers[node.aux].sample(
                    @as(f64, @floatFromInt(position.x)) / scale,
                    @as(f64, @floatFromInt(position.y)) / scale,
                    @as(f64, @floatFromInt(position.z)) / scale,
                ));
            }

            fn sampleSpline(
                self: *Router,
                spline_index: u32,
                position: Position,
                overrides: []const InterpolationOverride,
            ) f32 {
                const spline = data.splines[spline_index];
                const points = data.spline_points[spline.point_start..][0..spline.point_len];
                const location: f32 = @floatCast(self.evaluate(spline.coordinate, position, overrides));
                const upper = firstGreater(points, location);
                if (upper == 0) return self.sampleOutside(points[0], location, position, overrides);
                const lower_index = upper - 1;
                const lower = points[lower_index];
                if (lower_index == points.len - 1)
                    return self.sampleOutside(lower, location, position, overrides);
                const upper_point = points[upper];
                const lower_value = self.sampleSplineValue(lower.value, position, overrides);
                const upper_value = self.sampleSplineValue(upper_point.value, position, overrides);
                const location_delta = upper_point.location - lower.location;
                const fraction = (location - lower.location) / location_delta;
                const lower_excess = lower.derivative * location_delta - (upper_value - lower_value);
                const upper_excess = -upper_point.derivative * location_delta + (upper_value - lower_value);
                return fraction * (1 - fraction) * lerpF32(fraction, lower_excess, upper_excess) +
                    lerpF32(fraction, lower_value, upper_value);
            }

            fn sampleOutside(
                self: *Router,
                point: data.SplinePoint,
                location: f32,
                position: Position,
                overrides: []const InterpolationOverride,
            ) f32 {
                const value = self.sampleSplineValue(point.value, position, overrides);
                if (point.derivative == 0) return value;
                return point.derivative * (location - point.location) + value;
            }

            fn sampleSplineValue(
                self: *Router,
                value: data.SplineValue,
                position: Position,
                overrides: []const InterpolationOverride,
            ) f32 {
                return switch (value.kind) {
                    .fixed => @bitCast(value.payload),
                    .spline => self.sampleSpline(value.payload, position, overrides),
                };
            }
        };

        pub const ChunkInterpolator = struct {
            const Purpose = enum { all, final_density, veins };
            pub const CellDensityBounds = struct {
                minimum: f64,
                maximum: f64,
            };
            const ColumnCacheEntry = struct {
                valid: bool = false,
                x: i32 = 0,
                z: i32 = 0,
            };

            allocator: std.mem.Allocator,
            router: *Router,
            chunk_x: i32 = 0,
            chunk_z: i32 = 0,
            nodes: []u16,
            active_indices: [interpolation_count]u8,
            active_count: u8,
            first_lattice_y: u8,
            lattice_y_count: u8,
            lattice: []f64,
            overrides: []InterpolationOverride,
            column_cache_values: []f64,
            column_cache_capacity: usize,
            column_cache_entries: [maximum_column_cache_capacity]ColumnCacheEntry =
                [_]ColumnCacheEntry{.{}} ** maximum_column_cache_capacity,

            pub const minimum_y = data.minimum_y;
            pub const height = data.height;
            pub const horizontal_cell_size = data.horizontal_cell_size;
            pub const vertical_cell_size = data.vertical_cell_size;
            pub const horizontal_cells = 16 / horizontal_cell_size;
            pub const vertical_cells = height / vertical_cell_size;
            const lattice_x = horizontal_cells + 1;
            const lattice_y = vertical_cells + 1;
            const lattice_z = horizontal_cells + 1;
            const lattice_per_node = lattice_x * lattice_y * lattice_z;
            const column_cache_ways = 4;
            const maximum_column_cache_capacity = 2048;
            const default_column_cache_capacity = 2048;

            pub fn init(allocator: std.mem.Allocator, router: *Router) !ChunkInterpolator {
                return initWithColumnCacheCapacity(
                    allocator,
                    router,
                    default_column_cache_capacity,
                );
            }

            pub fn initWithColumnCacheCapacity(
                allocator: std.mem.Allocator,
                router: *Router,
                column_cache_capacity: usize,
            ) !ChunkInterpolator {
                return initForPurpose(
                    allocator,
                    router,
                    column_cache_capacity,
                    .all,
                );
            }

            pub fn initVeins(
                allocator: std.mem.Allocator,
                router: *Router,
                column_cache_capacity: usize,
            ) !ChunkInterpolator {
                return initForPurpose(
                    allocator,
                    router,
                    column_cache_capacity,
                    .veins,
                );
            }

            pub fn initFinal(
                allocator: std.mem.Allocator,
                router: *Router,
                column_cache_capacity: usize,
            ) !ChunkInterpolator {
                return initForPurpose(
                    allocator,
                    router,
                    column_cache_capacity,
                    .final_density,
                );
            }

            fn initForPurpose(
                allocator: std.mem.Allocator,
                router: *Router,
                column_cache_capacity: usize,
                purpose: Purpose,
            ) !ChunkInterpolator {
                if (column_cache_capacity < column_cache_ways or
                    column_cache_capacity > maximum_column_cache_capacity or
                    !std.math.isPowerOfTwo(column_cache_capacity))
                    return error.InvalidDensityColumnCacheCapacity;
                var count: usize = 0;
                for (data.nodes) |node| if (node.tag == .interpolated) {
                    count += 1;
                };
                const nodes = try preallocated.alloc(u16, allocator, count);
                errdefer allocator.free(nodes);
                const lattice = try preallocated.alloc(f64, allocator, count * lattice_per_node);
                errdefer allocator.free(lattice);
                @memset(lattice, 0);
                const overrides = try preallocated.alloc(InterpolationOverride, allocator, count);
                errdefer allocator.free(overrides);
                const column_cache_values =
                    try preallocated.alloc(f64, allocator, column_cache_capacity * count * lattice_y);
                errdefer allocator.free(column_cache_values);
                var index: usize = 0;
                var active_indices: [interpolation_count]u8 = undefined;
                var active_count: u8 = 0;
                for (data.nodes, 0..) |node, node_index| {
                    if (node.tag != .interpolated) continue;
                    nodes[index] = @intCast(node_index);
                    overrides[index].node = @intCast(node_index);
                    if (interpolationRequired(purpose, @intCast(node_index))) {
                        active_indices[active_count] = @intCast(index);
                        active_count += 1;
                    }
                    index += 1;
                }
                const first_lattice_y: u8 = 0;
                const lattice_y_count: u8 = if (purpose == .veins) 16 else lattice_y;
                return .{
                    .allocator = allocator,
                    .router = router,
                    .nodes = nodes,
                    .active_indices = active_indices,
                    .active_count = active_count,
                    .first_lattice_y = first_lattice_y,
                    .lattice_y_count = lattice_y_count,
                    .lattice = lattice,
                    .overrides = overrides,
                    .column_cache_values = column_cache_values,
                    .column_cache_capacity = column_cache_capacity,
                };
            }

            fn interpolationRequired(purpose: Purpose, node: u16) bool {
                return switch (purpose) {
                    .all => true,
                    .final_density => planContains(final_plan, node),
                    .veins => planContains(vein_toggle_plan, node) or
                        planContains(vein_ridged_plan, node) or
                        planContains(vein_gap_plan, node),
                };
            }

            fn planContains(comptime plan: EvaluationPlan, node: u16) bool {
                for (plan.indices[0..plan.count]) |index|
                    if (index == node) return true;
                return false;
            }

            pub fn deinit(self: *ChunkInterpolator) void {
                self.allocator.free(self.column_cache_values);
                self.allocator.free(self.overrides);
                self.allocator.free(self.lattice);
                self.allocator.free(self.nodes);
                self.* = undefined;
            }

            pub fn reseed(self: *ChunkInterpolator, router: *Router) void {
                self.router = router;
                @memset(&self.column_cache_entries, .{});
            }

            pub fn prepare(self: *ChunkInterpolator, chunk_x: i32, chunk_z: i32) void {
                @setRuntimeSafety(false);
                self.chunk_x = chunk_x;
                self.chunk_z = chunk_z;
                const first_x = chunk_x * 16;
                const first_z = chunk_z * 16;
                var roots: [32]u16 = undefined;
                var values: [32]f64 = undefined;
                var values4: [32]noise.Samples = undefined;
                std.debug.assert(self.nodes.len <= roots.len);
                for (self.active_indices[0..self.active_count], 0..) |interpolation_index, index|
                    roots[index] = data.nodes[self.nodes[interpolation_index]].a;
                const first_lattice_y = self.first_lattice_y;
                const last_lattice_y = first_lattice_y + self.lattice_y_count;
                for (0..lattice_x) |cell_x| {
                    for (0..lattice_z) |cell_z| {
                        const world_cell_x =
                            chunk_x * horizontal_cells + @as(i32, @intCast(cell_x));
                        const world_cell_z =
                            chunk_z * horizontal_cells + @as(i32, @intCast(cell_z));
                        const cache_slot =
                            self.columnCacheSlot(world_cell_x, world_cell_z);
                        const cache_entry = &self.column_cache_entries[cache_slot];
                        const cache_values = self.column_cache_values[cache_slot * self.nodes.len * lattice_y ..][0 .. self.nodes.len * lattice_y];
                        if (cache_entry.valid and
                            cache_entry.x == world_cell_x and
                            cache_entry.z == world_cell_z)
                        {
                            for (self.active_indices[0..self.active_count]) |interpolation_index| {
                                const destination = self.lattice[latticeIndex(interpolation_index, cell_x, first_lattice_y, cell_z)..][0..self.lattice_y_count];
                                const source = cache_values[interpolation_index * lattice_y + first_lattice_y ..][0..self.lattice_y_count];
                                @memcpy(destination, source);
                            }
                            continue;
                        }
                        var cell_y: usize = first_lattice_y;
                        while (cell_y + noise.sample_lanes <= last_lattice_y) : (cell_y += noise.sample_lanes) {
                            var positions: [noise.sample_lanes]Position = undefined;
                            inline for (0..noise.sample_lanes) |lane| {
                                positions[lane] = .{
                                    .x = first_x + @as(i32, @intCast(cell_x * horizontal_cell_size)),
                                    .y = minimum_y + @as(i32, @intCast((cell_y + lane) * vertical_cell_size)),
                                    .z = first_z + @as(i32, @intCast(cell_z * horizontal_cell_size)),
                                };
                            }
                            self.router.sampleRoots4(
                                roots[0..self.active_count],
                                positions,
                                values4[0..self.active_count],
                            );
                            for (values4[0..self.active_count], self.active_indices[0..self.active_count]) |value, interpolation_index| {
                                const lanes: [noise.sample_lanes]f64 = value;
                                inline for (0..noise.sample_lanes) |lane|
                                    self.lattice[latticeIndex(interpolation_index, cell_x, cell_y + lane, cell_z)] = lanes[lane];
                            }
                        }
                        while (cell_y < last_lattice_y) : (cell_y += 1) {
                            self.router.sampleRoots(
                                roots[0..self.active_count],
                                .{
                                    .x = first_x + @as(i32, @intCast(cell_x * horizontal_cell_size)),
                                    .y = minimum_y + @as(i32, @intCast(cell_y * vertical_cell_size)),
                                    .z = first_z + @as(i32, @intCast(cell_z * horizontal_cell_size)),
                                },
                                values[0..self.active_count],
                            );
                            for (values[0..self.active_count], self.active_indices[0..self.active_count]) |value, interpolation_index|
                                self.lattice[latticeIndex(interpolation_index, cell_x, cell_y, cell_z)] = value;
                        }
                        for (self.active_indices[0..self.active_count]) |interpolation_index| {
                            const source = self.lattice[latticeIndex(interpolation_index, cell_x, first_lattice_y, cell_z)..][0..self.lattice_y_count];
                            const destination = cache_values[interpolation_index * lattice_y + first_lattice_y ..][0..self.lattice_y_count];
                            @memcpy(destination, source);
                        }
                        cache_entry.* = .{
                            .valid = true,
                            .x = world_cell_x,
                            .z = world_cell_z,
                        };
                    }
                }
            }

            fn columnCacheSlot(self: *const ChunkInterpolator, x: i32, z: i32) usize {
                const key = @as(u64, @as(u32, @bitCast(x))) |
                    (@as(u64, @as(u32, @bitCast(z))) << 32);
                const hash = random.staffordMix13(key);
                const set_count = self.column_cache_capacity / column_cache_ways;
                const first: usize =
                    @intCast((hash & (set_count - 1)) * column_cache_ways);
                var target =
                    first +
                    @as(usize, @intCast((hash >> 32) & (column_cache_ways - 1)));
                for (self.column_cache_entries[first..][0..column_cache_ways], first..) |entry, slot| {
                    if (entry.valid and entry.x == x and entry.z == z) return slot;
                    if (!entry.valid) target = slot;
                }
                return target;
            }

            pub fn sampleFinal(self: *ChunkInterpolator, position: Position) f64 {
                return self.sample(data.final_density, position);
            }

            pub fn sampleFinal4(
                self: *ChunkInterpolator,
                positions: [noise.sample_lanes]Position,
            ) noise.Samples {
                return self.sampleInterpolated4(
                    data.final_density,
                    final_plan,
                    positions,
                );
            }

            pub fn cellFinalDensityBounds(
                self: *const ChunkInterpolator,
                cell_x: usize,
                cell_y: usize,
                cell_z: usize,
            ) CellDensityBounds {
                std.debug.assert(cell_x < horizontal_cells);
                std.debug.assert(cell_y < vertical_cells);
                std.debug.assert(cell_z < horizontal_cells);
                var values: [data.nodes.len]Interval = undefined;
                inline for (final_plan.indices[0..final_plan.count]) |node_index| {
                    const node = data.nodes[node_index];
                    const a = values[node.a];
                    const b = values[node.b];
                    const c = values[node.c];
                    values[node_index] = switch (comptime node.tag) {
                        .constant => Interval.point(node.x),
                        .add => Interval.add(a, b),
                        .multiply => Interval.multiply(a, b),
                        .minimum => Interval.minOf(a, b),
                        .maximum => Interval.maxOf(a, b),
                        .absolute => Interval.absolute(a),
                        .square => Interval.square(a),
                        .cube => Interval.cube(a),
                        .half_negative => Interval.monotone(a, halfNegative),
                        .quarter_negative => Interval.monotone(a, quarterNegative),
                        .squeeze => Interval.monotone(a, squeeze),
                        .clamp => Interval.clamp(a, node.x, node.y),
                        .y_gradient => Interval.yGradient(cell_y, node),
                        .range_choice => Interval.rangeChoice(a, b, c, node.x, node.y),
                        .interpolated => self.interpolationInterval(node_index, cell_x, cell_y, cell_z),
                        else => Interval.unbounded,
                    };
                }
                const result = values[data.final_density];
                return .{ .minimum = result.minimum, .maximum = result.maximum };
            }

            fn sampleInterpolated4(
                self: *ChunkInterpolator,
                comptime root: u16,
                comptime plan: EvaluationPlan,
                positions: [noise.sample_lanes]Position,
            ) noise.Samples {
                @setRuntimeSafety(false);
                var overrides: [32]InterpolationOverride4 = undefined;
                std.debug.assert(self.nodes.len <= overrides.len);
                const first_x = self.chunk_x * 16;
                const first_z = self.chunk_z * 16;
                const first = positions[0];
                const first_local_x: usize = @intCast(first.x - first_x);
                const first_local_y: usize = @intCast(first.y - minimum_y);
                const first_local_z: usize = @intCast(first.z - first_z);
                const cell_x = first_local_x / horizontal_cell_size;
                const cell_y = first_local_y / vertical_cell_size;
                const cell_z = first_local_z / horizontal_cell_size;
                const delta_y =
                    @as(f64, @floatFromInt(first_local_y % vertical_cell_size)) /
                    vertical_cell_size;
                var delta_x_values: [noise.sample_lanes]f64 = undefined;
                var delta_z_values: [noise.sample_lanes]f64 = undefined;
                inline for (0..noise.sample_lanes) |lane| {
                    const position = positions[lane];
                    std.debug.assert(position.x >= first_x and position.x < first_x + 16);
                    std.debug.assert(position.z >= first_z and position.z < first_z + 16);
                    std.debug.assert(position.y >= minimum_y and position.y < minimum_y + height);
                    const local_x: usize = @intCast(position.x - first_x);
                    const local_y: usize = @intCast(position.y - minimum_y);
                    const local_z: usize = @intCast(position.z - first_z);
                    std.debug.assert(local_x / horizontal_cell_size == cell_x);
                    std.debug.assert(local_y / vertical_cell_size == cell_y);
                    std.debug.assert(local_z / horizontal_cell_size == cell_z);
                    std.debug.assert(local_y == first_local_y);
                    delta_x_values[lane] =
                        @as(f64, @floatFromInt(local_x % horizontal_cell_size)) /
                        horizontal_cell_size;
                    delta_z_values[lane] =
                        @as(f64, @floatFromInt(local_z % horizontal_cell_size)) /
                        horizontal_cell_size;
                }
                const delta_x: noise.Samples = delta_x_values;
                const delta_z: noise.Samples = delta_z_values;
                self.interpolateOverrides4(
                    &overrides,
                    cell_x,
                    cell_y,
                    cell_z,
                    delta_y,
                    delta_x,
                    delta_z,
                );
                return self.router.sampleRuntime4(
                    root,
                    plan,
                    positions,
                    overrides[0..self.nodes.len],
                );
            }

            fn interpolateOverrides4(
                self: *const ChunkInterpolator,
                overrides: *[32]InterpolationOverride4,
                cell_x: usize,
                cell_y: usize,
                cell_z: usize,
                delta_y: f64,
                delta_x: noise.Samples,
                delta_z: noise.Samples,
            ) void {
                for (self.nodes, 0..) |node, interpolation_index| {
                    const x0z0 = lerpF64(
                        delta_y,
                        self.lattice[latticeIndex(interpolation_index, cell_x, cell_y, cell_z)],
                        self.lattice[latticeIndex(interpolation_index, cell_x, cell_y + 1, cell_z)],
                    );
                    const x1z0 = lerpF64(
                        delta_y,
                        self.lattice[latticeIndex(interpolation_index, cell_x + 1, cell_y, cell_z)],
                        self.lattice[latticeIndex(interpolation_index, cell_x + 1, cell_y + 1, cell_z)],
                    );
                    const x0z1 = lerpF64(
                        delta_y,
                        self.lattice[latticeIndex(interpolation_index, cell_x, cell_y, cell_z + 1)],
                        self.lattice[latticeIndex(interpolation_index, cell_x, cell_y + 1, cell_z + 1)],
                    );
                    const x1z1 = lerpF64(
                        delta_y,
                        self.lattice[latticeIndex(interpolation_index, cell_x + 1, cell_y, cell_z + 1)],
                        self.lattice[latticeIndex(interpolation_index, cell_x + 1, cell_y + 1, cell_z + 1)],
                    );
                    const x0z0_batch: noise.Samples = @splat(x0z0);
                    const x1z0_batch: noise.Samples = @splat(x1z0);
                    const x0z1_batch: noise.Samples = @splat(x0z1);
                    const x1z1_batch: noise.Samples = @splat(x1z1);
                    const z0 = x0z0_batch + delta_x * (x1z0_batch - x0z0_batch);
                    const z1 = x0z1_batch + delta_x * (x1z1_batch - x0z1_batch);
                    const values: noise.Samples = z0 + delta_z * (z1 - z0);
                    overrides[interpolation_index] = .{
                        .node = node,
                        .value = values,
                    };
                }
            }

            pub fn sampleVeinToggle(self: *ChunkInterpolator, position: Position) f64 {
                return self.sample(data.vein_toggle, position);
            }

            pub fn sampleVeinToggle4(
                self: *ChunkInterpolator,
                positions: [noise.sample_lanes]Position,
            ) noise.Samples {
                return self.sampleInterpolated4(data.vein_toggle, vein_toggle_plan, positions);
            }

            pub fn cellMayContainVein(
                self: *const ChunkInterpolator,
                cell_x: usize,
                cell_y: usize,
                cell_z: usize,
            ) bool {
                std.debug.assert(cell_x < horizontal_cells);
                std.debug.assert(cell_y < vertical_cells);
                std.debug.assert(cell_z < horizontal_cells);
                const interval = self.interpolationInterval(
                    data.vein_toggle,
                    cell_x,
                    cell_y,
                    cell_z,
                );
                return @max(@abs(interval.minimum), @abs(interval.maximum)) >= 0.4 - 1e-12;
            }

            pub fn sampleVeinRidged(self: *ChunkInterpolator, position: Position) f64 {
                return self.sample(data.vein_ridged, position);
            }

            pub fn sampleVeinRidged4(
                self: *ChunkInterpolator,
                positions: [noise.sample_lanes]Position,
            ) noise.Samples {
                return self.sampleInterpolated4(data.vein_ridged, vein_ridged_plan, positions);
            }

            pub fn sampleVeinGap(self: *ChunkInterpolator, position: Position) f64 {
                return self.sample(data.vein_gap, position);
            }

            pub fn sampleVeinGap4(
                self: *ChunkInterpolator,
                positions: [noise.sample_lanes]Position,
            ) noise.Samples {
                return self.sampleInterpolated4(data.vein_gap, vein_gap_plan, positions);
            }

            pub fn sample(self: *ChunkInterpolator, root: u16, position: Position) f64 {
                const first_x = self.chunk_x * 16;
                const first_z = self.chunk_z * 16;
                std.debug.assert(position.x >= first_x and position.x < first_x + 16);
                std.debug.assert(position.z >= first_z and position.z < first_z + 16);
                std.debug.assert(position.y >= minimum_y and position.y < minimum_y + height);
                @setRuntimeSafety(false);
                const local_x: usize = @intCast(position.x - first_x);
                const local_y: usize = @intCast(position.y - minimum_y);
                const local_z: usize = @intCast(position.z - first_z);
                const cell_x = local_x / horizontal_cell_size;
                const cell_y = local_y / vertical_cell_size;
                const cell_z = local_z / horizontal_cell_size;
                const delta_x = @as(f64, @floatFromInt(local_x % horizontal_cell_size)) / horizontal_cell_size;
                const delta_y = @as(f64, @floatFromInt(local_y % vertical_cell_size)) / vertical_cell_size;
                const delta_z = @as(f64, @floatFromInt(local_z % horizontal_cell_size)) / horizontal_cell_size;
                for (self.overrides, 0..) |*override, interpolation_index| {
                    const x0y0z0 = self.lattice[latticeIndex(interpolation_index, cell_x, cell_y, cell_z)];
                    const x0y1z0 = self.lattice[latticeIndex(interpolation_index, cell_x, cell_y + 1, cell_z)];
                    const x1y0z0 = self.lattice[latticeIndex(interpolation_index, cell_x + 1, cell_y, cell_z)];
                    const x1y1z0 = self.lattice[latticeIndex(interpolation_index, cell_x + 1, cell_y + 1, cell_z)];
                    const x0y0z1 = self.lattice[latticeIndex(interpolation_index, cell_x, cell_y, cell_z + 1)];
                    const x0y1z1 = self.lattice[latticeIndex(interpolation_index, cell_x, cell_y + 1, cell_z + 1)];
                    const x1y0z1 = self.lattice[latticeIndex(interpolation_index, cell_x + 1, cell_y, cell_z + 1)];
                    const x1y1z1 = self.lattice[latticeIndex(interpolation_index, cell_x + 1, cell_y + 1, cell_z + 1)];
                    const x0z0 = lerpF64(delta_y, x0y0z0, x0y1z0);
                    const x1z0 = lerpF64(delta_y, x1y0z0, x1y1z0);
                    const x0z1 = lerpF64(delta_y, x0y0z1, x0y1z1);
                    const x1z1 = lerpF64(delta_y, x1y0z1, x1y1z1);
                    override.value = lerpF64(
                        delta_z,
                        lerpF64(delta_x, x0z0, x1z0),
                        lerpF64(delta_x, x0z1, x1z1),
                    );
                }
                return self.router.sampleWithOverrides(root, position, self.overrides);
            }

            fn latticeIndex(
                interpolation_index: usize,
                cell_x: usize,
                cell_y: usize,
                cell_z: usize,
            ) usize {
                return interpolation_index * lattice_per_node +
                    cell_x * lattice_z * lattice_y +
                    cell_z * lattice_y +
                    cell_y;
            }

            fn interpolationInterval(
                self: *const ChunkInterpolator,
                node: u16,
                cell_x: usize,
                cell_y: usize,
                cell_z: usize,
            ) Interval {
                const interpolation_index = interpolation_index_by_node[node];
                std.debug.assert(interpolation_index != std.math.maxInt(u8));
                var result = Interval.point(self.lattice[latticeIndex(interpolation_index, cell_x, cell_y, cell_z)]);
                inline for (1..8) |corner| {
                    const value = self.lattice[
                        latticeIndex(
                            interpolation_index,
                            cell_x + (corner & 1),
                            cell_y + ((corner >> 1) & 1),
                            cell_z + ((corner >> 2) & 1),
                        )
                    ];
                    result.minimum = @min(result.minimum, value);
                    result.maximum = @max(result.maximum, value);
                }
                return result;
            }
        };

        const Interval = struct {
            minimum: f64,
            maximum: f64,

            const unbounded: Interval = .{ .minimum = -std.math.inf(f64), .maximum = std.math.inf(f64) };

            fn point(value: f64) Interval {
                return .{ .minimum = value, .maximum = value };
            }

            fn outward(minimum: f64, maximum: f64) Interval {
                return .{
                    .minimum = std.math.nextAfter(f64, minimum, -std.math.inf(f64)),
                    .maximum = std.math.nextAfter(f64, maximum, std.math.inf(f64)),
                };
            }

            fn add(a: Interval, b: Interval) Interval {
                return outward(a.minimum + b.minimum, a.maximum + b.maximum);
            }

            fn multiply(a: Interval, b: Interval) Interval {
                const products = [4]f64{
                    a.minimum * b.minimum,
                    a.minimum * b.maximum,
                    a.maximum * b.minimum,
                    a.maximum * b.maximum,
                };
                return outward(@min(@min(products[0], products[1]), @min(products[2], products[3])), @max(@max(products[0], products[1]), @max(products[2], products[3])));
            }

            fn minOf(a: Interval, b: Interval) Interval {
                return .{ .minimum = @min(a.minimum, b.minimum), .maximum = @min(a.maximum, b.maximum) };
            }

            fn maxOf(a: Interval, b: Interval) Interval {
                return .{ .minimum = @max(a.minimum, b.minimum), .maximum = @max(a.maximum, b.maximum) };
            }

            fn absolute(a: Interval) Interval {
                const upper = @max(@abs(a.minimum), @abs(a.maximum));
                return outward(if (a.minimum <= 0 and a.maximum >= 0) 0 else @min(@abs(a.minimum), @abs(a.maximum)), upper);
            }

            fn square(a: Interval) Interval {
                const absolute_value = absolute(a);
                return outward(absolute_value.minimum * absolute_value.minimum, absolute_value.maximum * absolute_value.maximum);
            }

            fn cube(a: Interval) Interval {
                return outward(a.minimum * a.minimum * a.minimum, a.maximum * a.maximum * a.maximum);
            }

            fn monotone(a: Interval, comptime function: anytype) Interval {
                return outward(function(a.minimum), function(a.maximum));
            }

            fn clamp(a: Interval, minimum_value: f64, maximum_value: f64) Interval {
                return .{ .minimum = std.math.clamp(a.minimum, minimum_value, maximum_value), .maximum = std.math.clamp(a.maximum, minimum_value, maximum_value) };
            }

            fn yGradient(cell_y: usize, node: data.Node) Interval {
                const first_y: f64 = @floatFromInt(ChunkInterpolator.minimum_y + @as(i32, @intCast(cell_y * ChunkInterpolator.vertical_cell_size)));
                const last_y = first_y + ChunkInterpolator.vertical_cell_size;
                const first = clampedMap(first_y, @floatFromInt(node.i0), @floatFromInt(node.i1), node.x, node.y);
                const last = clampedMap(last_y, @floatFromInt(node.i0), @floatFromInt(node.i1), node.x, node.y);
                return outward(@min(first, last), @max(first, last));
            }

            fn rangeChoice(input: Interval, inside: Interval, outside: Interval, minimum_value: f64, maximum_value: f64) Interval {
                if (input.minimum >= minimum_value and input.maximum < maximum_value) return inside;
                if (input.maximum < minimum_value or input.minimum >= maximum_value) return outside;
                return .{ .minimum = @min(inside.minimum, outside.minimum), .maximum = @max(inside.maximum, outside.maximum) };
            }
        };

        pub fn preliminarySurfaceHeight(router: *Router, block_x: i32, block_z: i32, run_depth: i32) i32 {
            const section_x = @divFloor(block_x, 16);
            const section_z = @divFloor(block_z, 16);
            const heights = preliminarySurfaceCorners(router, section_x, section_z);
            return preliminarySurfaceHeightFromCorners(&heights, block_x, block_z, run_depth);
        }

        pub fn preliminarySurfaceCorners(router: *Router, chunk_x: i32, chunk_z: i32) [4]i32 {
            const first_x = chunk_x * 16;
            const first_z = chunk_z * 16;
            return .{
                estimateSurfaceHeight(router, first_x, first_z),
                estimateSurfaceHeight(router, first_x + 16, first_z),
                estimateSurfaceHeight(router, first_x, first_z + 16),
                estimateSurfaceHeight(router, first_x + 16, first_z + 16),
            };
        }

        pub fn preliminarySurfaceHeightFromCorners(
            heights: *const [4]i32,
            block_x: i32,
            block_z: i32,
            run_depth: i32,
        ) i32 {
            const delta_x = @as(f64, @floatCast(@as(f32, @floatFromInt(@mod(block_x, 16))) / 16));
            const delta_z = @as(f64, @floatCast(@as(f32, @floatFromInt(@mod(block_z, 16))) / 16));
            const interpolated = lerpF64(
                delta_z,
                lerpF64(delta_x, @floatFromInt(heights[0]), @floatFromInt(heights[1])),
                lerpF64(delta_x, @floatFromInt(heights[2]), @floatFromInt(heights[3])),
            );
            return saturatingAdd(@intFromFloat(@floor(interpolated)), run_depth) - 8;
        }

        pub fn estimateSurfaceHeight(router: *Router, block_x: i32, block_z: i32) i32 {
            const x = @divFloor(block_x, 4) * 4;
            const z = @divFloor(block_z, 4) * 4;
            var y: i32 = ChunkInterpolator.minimum_y + ChunkInterpolator.height;
            const minimum_y = ChunkInterpolator.minimum_y;
            while (y >= minimum_y) : (y -= ChunkInterpolator.vertical_cell_size) {
                if (router.sampleInitialDensityWithoutJaggedness(.{ .x = x, .y = y, .z = z }) > 0.390625)
                    return y;
            }
            return std.math.maxInt(i32);
        }

        fn saturatingAdd(left: i32, right: i32) i32 {
            const result = @addWithOverflow(left, right);
            return if (result[1] == 0)
                result[0]
            else if (right > 0)
                std.math.maxInt(i32)
            else
                std.math.minInt(i32);
        }

        fn interpolationOverride(overrides: []const InterpolationOverride, node: u16) ?f64 {
            if (overrides.len == interpolation_count) {
                const index = interpolation_index_by_node[node];
                if (index != std.math.maxInt(u8)) return overrides[index].value;
                return null;
            }
            for (overrides) |override| if (override.node == node) return override.value;
            return null;
        }

        fn interpolationOverride4(
            overrides: []const InterpolationOverride4,
            node: u16,
        ) noise.Samples {
            std.debug.assert(overrides.len == interpolation_count);
            const index = interpolation_index_by_node[node];
            std.debug.assert(index != std.math.maxInt(u8));
            return overrides[index].value;
        }

        fn firstGreater(points: []const data.SplinePoint, location: f32) usize {
            var low: usize = 0;
            var len = points.len;
            while (len > 0) {
                const half = len / 2;
                const middle = low + half;
                if (location < points[middle].location) {
                    len = half;
                } else {
                    low = middle + 1;
                    len -= half + 1;
                }
            }
            return low;
        }

        inline fn squeeze(value: f64) f64 {
            const clamped = javaClamp(value, -1, 1);
            return clamped / 2 - clamped * clamped * clamped / 24;
        }

        inline fn squeeze4(value: noise.Samples) noise.Samples {
            const clamped = javaClamp4(value, -1, 1);
            return clamped / @as(noise.Samples, @splat(2)) -
                clamped * clamped * clamped / @as(noise.Samples, @splat(24));
        }

        inline fn square(value: f64) f64 {
            return value * value;
        }

        inline fn cube(value: f64) f64 {
            return value * value * value;
        }

        inline fn halfNegative(value: f64) f64 {
            return if (value > 0) value else value * 0.5;
        }

        inline fn quarterNegative(value: f64) f64 {
            return if (value > 0) value else value * 0.25;
        }

        inline fn clampedMap(value: f64, from: f64, to: f64, from_value: f64, to_value: f64) f64 {
            if (value <= from) return from_value;
            if (value >= to) return to_value;
            return from_value + (value - from) / (to - from) * (to_value - from_value);
        }

        inline fn clampedMap4(value: noise.Samples, from: f64, to: f64, from_value: f64, to_value: f64) noise.Samples {
            const mapped = @as(noise.Samples, @splat(from_value)) +
                (value - @as(noise.Samples, @splat(from))) / @as(noise.Samples, @splat(to - from)) *
                    @as(noise.Samples, @splat(to_value - from_value));
            return @select(
                f64,
                value <= @as(noise.Samples, @splat(from)),
                @as(noise.Samples, @splat(from_value)),
                @select(
                    f64,
                    value >= @as(noise.Samples, @splat(to)),
                    @as(noise.Samples, @splat(to_value)),
                    mapped,
                ),
            );
        }

        inline fn type1Scale(value: f64) f64 {
            if (value < -0.5) return 0.75;
            if (value < 0) return 1;
            if (value < 0.5) return 1.5;
            return 2;
        }

        inline fn type1Scale4(value: noise.Samples) noise.Samples {
            return @select(
                f64,
                value < @as(noise.Samples, @splat(-0.5)),
                @as(noise.Samples, @splat(0.75)),
                @select(
                    f64,
                    value < @as(noise.Samples, @splat(0)),
                    @as(noise.Samples, @splat(1)),
                    @select(
                        f64,
                        value < @as(noise.Samples, @splat(0.5)),
                        @as(noise.Samples, @splat(1.5)),
                        @as(noise.Samples, @splat(2)),
                    ),
                ),
            );
        }

        inline fn type2Scale(value: f64) f64 {
            if (value < -0.75) return 0.5;
            if (value < -0.5) return 0.75;
            if (value < 0.5) return 1;
            if (value < 0.75) return 2;
            return 3;
        }

        inline fn type2Scale4(value: noise.Samples) noise.Samples {
            return @select(
                f64,
                value < @as(noise.Samples, @splat(-0.75)),
                @as(noise.Samples, @splat(0.5)),
                @select(
                    f64,
                    value < @as(noise.Samples, @splat(-0.5)),
                    @as(noise.Samples, @splat(0.75)),
                    @select(
                        f64,
                        value < @as(noise.Samples, @splat(0.5)),
                        @as(noise.Samples, @splat(1)),
                        @select(
                            f64,
                            value < @as(noise.Samples, @splat(0.75)),
                            @as(noise.Samples, @splat(2)),
                            @as(noise.Samples, @splat(3)),
                        ),
                    ),
                ),
            );
        }

        inline fn lerpF32(delta: f32, start: f32, end: f32) f32 {
            return start + delta * (end - start);
        }

        inline fn lerpF64(delta: f64, start: f64, end: f64) f64 {
            return start + delta * (end - start);
        }
    };
}

const Overworld = Engine(program.data);
const OverworldPosition = Overworld.Position;
const OverworldRouter = Overworld.Router;
const OverworldChunkInterpolator = Overworld.ChunkInterpolator;

test "Overworld density router matches Vanilla seed zero reference" {
    std.debug.assert(program.data.minimum_y == -64);
    std.debug.assert(program.data.height == 384);
    var router = try OverworldRouter.init(std.testing.allocator, 0);
    defer router.deinit();
    const origin: OverworldPosition = .{ .x = 0, .y = 0, .z = 0 };
    try std.testing.expectEqual(@as(f64, -0.5400227274000677), router.sampleBarrier(origin));
    try std.testing.expectEqual(@as(f64, -0.4709571987777473), router.sampleFluidLevelFloodedness(origin));
    try std.testing.expectEqual(@as(f64, -0.057269139961514365), router.sampleFluidLevelSpread(origin));
    try std.testing.expectEqual(@as(f64, -0.16423603877333556), router.sampleLava(origin));
    try std.testing.expectEqual(@as(f64, -0.10391073889243099), router.sampleErosion(origin));
    try std.testing.expectEqual(@as(f64, 0.411882147192955), router.sampleDepth(origin));
    try std.testing.expectEqual(
        @as(f64, 0.15719144891255343),
        router.sampleFinal(origin),
    );
}

test "chunk interpolation is transparent at every density lattice corner" {
    var router = try OverworldRouter.init(std.testing.allocator, 0);
    defer router.deinit();
    var chunk = try OverworldChunkInterpolator.init(std.testing.allocator, &router);
    defer chunk.deinit();
    chunk.prepare(-2, 3);
    for (0..OverworldChunkInterpolator.horizontal_cells) |cell_x| {
        for (0..OverworldChunkInterpolator.horizontal_cells) |cell_z| {
            for (0..OverworldChunkInterpolator.vertical_cells) |cell_y| {
                const position: OverworldPosition = .{
                    .x = -32 + @as(i32, @intCast(cell_x * OverworldChunkInterpolator.horizontal_cell_size)),
                    .y = OverworldChunkInterpolator.minimum_y + @as(i32, @intCast(cell_y * OverworldChunkInterpolator.vertical_cell_size)),
                    .z = 48 + @as(i32, @intCast(cell_z * OverworldChunkInterpolator.horizontal_cell_size)),
                };
                try std.testing.expectEqual(router.sampleFinal(position), chunk.sampleFinal(position));
            }
        }
    }
}

test "specialized vein lattice matches the complete interpolator" {
    std.debug.assert(program.data.minimum_y == -64);
    std.debug.assert(program.data.height == 384);
    var router = try OverworldRouter.init(std.testing.allocator, 0x6d62_756e_6400_0001);
    defer router.deinit();
    var complete = try OverworldChunkInterpolator.initWithColumnCacheCapacity(
        std.testing.allocator,
        &router,
        64,
    );
    defer complete.deinit();
    var veins = try OverworldChunkInterpolator.initVeins(
        std.testing.allocator,
        &router,
        64,
    );
    defer veins.deinit();
    complete.prepare(-3, 5);
    veins.prepare(-3, 5);
    for ([_]i32{ -60, -17, 0, 49 }) |y| {
        var positions: [sample_lanes]OverworldPosition = undefined;
        for (&positions, 0..) |*position, lane| position.* = .{
            .x = -43,
            .y = y,
            .z = 80 + @as(i32, @intCast(lane)),
        };
        try std.testing.expectEqual(
            complete.sampleVeinToggle4(positions),
            veins.sampleVeinToggle4(positions),
        );
        try std.testing.expectEqual(
            complete.sampleVeinRidged4(positions),
            veins.sampleVeinRidged4(positions),
        );
        try std.testing.expectEqual(
            complete.sampleVeinGap4(positions),
            veins.sampleVeinGap4(positions),
        );
    }
    for (0..15) |cell_y| for (0..4) |cell_x| for (0..4) |cell_z|
        try std.testing.expectEqual(
            complete.cellMayContainVein(cell_x, cell_y, cell_z),
            veins.cellMayContainVein(cell_x, cell_y, cell_z),
        );
}
