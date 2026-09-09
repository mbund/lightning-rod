const std = @import("std");
pub const data = @import("surface_data");

test "generated Overworld surface program is internally valid" {
    try std.testing.expect(data.root < data.rules.len);
    try std.testing.expect(data.surface_noise < data.noise_specs.len);
    try std.testing.expect(data.surface_secondary_noise < data.noise_specs.len);
    for (data.rules) |rule| switch (rule.tag) {
        .block => try std.testing.expect(rule.a < data.block_states.len),
        .sequence => {
            try std.testing.expect(@as(usize, rule.start) + rule.len <= data.rule_children.len);
            for (data.rule_children[rule.start..][0..rule.len]) |child|
                try std.testing.expect(child < data.rules.len);
        },
        .condition => {
            try std.testing.expect(rule.a < data.conditions.len);
            try std.testing.expect(rule.start < data.rules.len);
        },
        .badlands => {},
    };
    for (data.conditions) |condition| switch (condition.tag) {
        .biome => {
            try std.testing.expect(@as(usize, condition.start) + condition.len <= data.biome_indices.len);
            for (data.biome_indices[condition.start..][0..condition.len]) |biome|
                try std.testing.expect(biome < data.biome_names.len);
        },
        .noise_threshold => try std.testing.expect(condition.a < data.noise_specs.len),
        .vertical_gradient => try std.testing.expect(condition.a < data.random_names.len),
        .not => try std.testing.expect(condition.a < data.conditions.len),
        .y_above,
        .water,
        .temperature,
        .steep,
        .hole,
        .above_preliminary_surface,
        .stone_depth,
        => {},
    };
}
