const aquifer = @import("aquifer.zig");
const surface = @import("surface.zig");
const feature_data = @import("feature_data");

pub const GeneratedState = union(enum) {
    base: aquifer.Material,
    surface: u16,
    feature: u16,

    pub fn canonicalName(self: GeneratedState) []const u8 {
        return switch (self) {
            .base => |material| switch (material) {
                .stone => "minecraft:stone",
                .air => "minecraft:air",
                .water => "minecraft:water[level=0]",
                .lava => "minecraft:lava[level=0]",
            },
            .surface => |index| surface.stateName(index),
            .feature => |index| feature_data.state_names[index],
        };
    }
};

pub fn featureStateCount() usize {
    return feature_data.state_names.len;
}
