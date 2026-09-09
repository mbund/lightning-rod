const program = @import("density_program.zig");
const engine = @import("density_engine.zig");

pub const sample_lanes = engine.sample_lanes;
pub const Engine = engine.Engine;

const Overworld = Engine(program.data);
pub const Position = Overworld.Position;
pub const Router = Overworld.Router;
pub const ChunkInterpolator = Overworld.ChunkInterpolator;
pub const preliminarySurfaceHeight = Overworld.preliminarySurfaceHeight;
pub const preliminarySurfaceCorners = Overworld.preliminarySurfaceCorners;
pub const preliminarySurfaceHeightFromCorners = Overworld.preliminarySurfaceHeightFromCorners;
pub const estimateSurfaceHeight = Overworld.estimateSurfaceHeight;

test {
    _ = @import("density_engine.zig");
}
