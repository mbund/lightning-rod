const lighting = @import("lighting.zig");
const Dimensions = lighting.Dimensions;
const Registry = lighting.Registry;
const Layer = lighting.Layer;

pub fn reference(dimensions: Dimensions, registry: Registry, blocks: []const u16, layer: Layer, skylight: bool, output: []u8) void {
    @memset(output, 0);
    const plane = dimensions.x * dimensions.z;
    if (layer == .sky and skylight) {
        for (0..plane) |column| {
            var y = dimensions.y;
            var exposed = true;
            var above: u16 = 0;
            while (y != 0) {
                y -= 1;
                const at = y * plane + column;
                const state = blocks[at];
                exposed = exposed and registry.states[state].opacity == 0 and !registry.blocked(above, state, .down);
                output[at] = if (exposed) 15 else 0;
                above = state;
            }
        }
        for (output.len - plane..output.len) |index| {
            if (!registry.blocked(0, blocks[index], .down)) output[index] = @max(output[index], 15 -| @max(1, registry.states[blocks[index]].opacity));
        }
    }
    if (layer == .block) for (blocks, output) |state, *value| {
        value.* = registry.states[state].emission;
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (output, 0..) |*value, index| {
            const x = index % dimensions.x;
            const z = (index / dimensions.x) % dimensions.z;
            const neighbours = [_]?usize{
                if (x != 0) index - 1 else null,
                if (x + 1 != dimensions.x) index + 1 else null,
                if (z != 0) index - dimensions.x else null,
                if (z + 1 != dimensions.z) index + dimensions.x else null,
                if (index >= plane) index - plane else null,
                if (index + plane < output.len) index + plane else null,
            };
            for (neighbours, 0..) |neighbour, direction| if (neighbour) |from| {
                const candidate = output[from] -| @max(1, registry.states[blocks[index]].opacity);
                if (candidate <= value.* or registry.blocked(blocks[from], blocks[index], @enumFromInt(direction ^ 1))) continue;
                value.* = candidate;
                changed = true;
            };
        }
    }
}
