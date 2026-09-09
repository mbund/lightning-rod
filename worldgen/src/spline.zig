const data = @import("worldgen_data");

pub const Coordinates = struct {
    continents: f32,
    erosion: f32,
    ridges_folded: f32,
};

pub fn overworldOffset(coordinates: Coordinates) f32 {
    return sample(data.overworld_offset_root, coordinates);
}

fn sample(spline_index: u32, coordinates: Coordinates) f32 {
    const spline = data.splines[spline_index];
    const points = data.points[spline.point_start..][0..spline.point_len];
    const location = switch (spline.coordinate) {
        .continents => coordinates.continents,
        .erosion => coordinates.erosion,
        .ridges_folded => coordinates.ridges_folded,
    };

    const upper = firstGreater(points, location);
    if (upper == 0) return sampleOutside(points[0], location, coordinates);
    const lower_index = upper - 1;
    const lower = points[lower_index];
    if (lower_index == points.len - 1) return sampleOutside(lower, location, coordinates);
    const upper_point = points[upper];
    const lower_value = sampleValue(lower.value, coordinates);
    const upper_value = sampleValue(upper_point.value, coordinates);
    const location_delta = upper_point.location - lower.location;
    const fraction = (location - lower.location) / location_delta;
    const lower_excess = lower.derivative * location_delta - (upper_value - lower_value);
    const upper_excess = -upper_point.derivative * location_delta + (upper_value - lower_value);
    return fraction * (1 - fraction) * lerp(fraction, lower_excess, upper_excess) +
        lerp(fraction, lower_value, upper_value);
}

fn sampleOutside(point: data.Point, location: f32, coordinates: Coordinates) f32 {
    const value = sampleValue(point.value, coordinates);
    if (point.derivative == 0) return value;
    return point.derivative * (location - point.location) + value;
}

fn sampleValue(value: data.ValueRef, coordinates: Coordinates) f32 {
    return switch (value.kind) {
        .fixed => @bitCast(value.payload),
        .spline => sample(value.payload, coordinates),
    };
}

fn firstGreater(points: []const data.Point, location: f32) usize {
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

inline fn lerp(delta: f32, start: f32, end: f32) f32 {
    return start + delta * (end - start);
}
