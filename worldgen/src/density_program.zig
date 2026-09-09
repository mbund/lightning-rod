const std = @import("std");
pub const data = @import("density_data");

test "generated Overworld density program is internally valid" {
    try std.testing.expect(data.nodes.len > 0);
    try std.testing.expect(data.final_density < data.nodes.len);
    try std.testing.expect(data.initial_density_without_jaggedness < data.nodes.len);
    try std.testing.expect(data.barrier < data.nodes.len);
    try std.testing.expect(data.fluid_level_floodedness < data.nodes.len);
    try std.testing.expect(data.fluid_level_spread < data.nodes.len);
    try std.testing.expect(data.lava < data.nodes.len);
    try std.testing.expect(data.vein_toggle < data.nodes.len);
    try std.testing.expect(data.vein_ridged < data.nodes.len);
    try std.testing.expect(data.vein_gap < data.nodes.len);
    for (data.nodes) |node| switch (node.tag) {
        .add, .multiply, .minimum, .maximum => {
            try std.testing.expect(node.a < data.nodes.len);
            try std.testing.expect(node.b < data.nodes.len);
        },
        .absolute, .square, .cube, .half_negative, .quarter_negative, .squeeze, .clamp, .interpolated => {
            try std.testing.expect(node.a < data.nodes.len);
        },
        .shifted_noise => {
            try std.testing.expect(node.a < data.nodes.len);
            try std.testing.expect(node.b < data.nodes.len);
            try std.testing.expect(node.c < data.nodes.len);
            try std.testing.expect(node.aux < data.noise_specs.len);
        },
        .range_choice => {
            try std.testing.expect(node.a < data.nodes.len);
            try std.testing.expect(node.b < data.nodes.len);
            try std.testing.expect(node.c < data.nodes.len);
        },
        .noise, .shift_a, .shift_b => {
            try std.testing.expect(node.aux < data.noise_specs.len);
        },
        .weird_scaled_type_1, .weird_scaled_type_2 => {
            try std.testing.expect(node.a < data.nodes.len);
            try std.testing.expect(node.aux < data.noise_specs.len);
        },
        .spline => try std.testing.expect(node.aux < data.splines.len),
        .constant, .y_gradient, .old_blended_noise, .end_islands => {},
    };
    for (data.splines) |spline| {
        try std.testing.expect(spline.coordinate < data.nodes.len);
        try std.testing.expect(@as(usize, spline.point_start) + spline.point_len <= data.spline_points.len);
    }
}
