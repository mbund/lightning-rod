//! Blocks a placed block or a poured fluid may take the place of, as vanilla 1.21.8 decides it:
//! the blocks Blocks builds with AbstractBlock.Settings.replaceable(), less snow deeper than one
//! layer, and never by the block's own item (AbstractBlockState.canReplace, SnowBlock.canReplace).

const std = @import("std");
const game_data = @import("game_data");

const registry = game_data.registry;

/// Every block Blocks marks replaceable in 1.21.8.
const replaceable_blocks = [_][]const u8{
    "air",           "bubble_column", "bush",           "cave_air",       "crimson_roots",  "dead_bush",
    "fern",          "fire",          "glow_lichen",    "hanging_roots",  "large_fern",     "lava",
    "leaf_litter",   "light",         "nether_sprouts", "resin_clump",    "seagrass",       "short_dry_grass",
    "short_grass",   "snow",          "soul_fire",      "structure_void", "tall_dry_grass", "tall_grass",
    "tall_seagrass", "vine",          "void_air",       "warped_roots",   "water",
};

const Tables = struct {
    /// By block state.
    replaceable: []const bool,
    /// By block state, the snow layers, 0 for every other state.
    snow_layers: []const u8,
    snow: u16,
};

var tables: Tables = undefined;
var tables_ready = std.atomic.Value(bool).init(false);

/// The tables are game data, like the registry they come from, so they live for the process.
/// They are first built while the server starts, before any thread but the main one runs.
fn ensureTables() void {
    if (tables_ready.load(.acquire)) return;
    prepareTables(std.heap.page_allocator) catch |err| std.debug.panic("replaceable tables: {t}", .{err});
}

fn prepareTables(allocator: std.mem.Allocator) !void {
    const count = registry.block_state_names.len;
    const replaceable = try allocator.alloc(bool, count);
    const snow_layers = try allocator.alloc(u8, count);
    for (registry.block_state_names, replaceable, snow_layers) |name, *flag, *layers| {
        const block = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
        const short = if (std.mem.startsWith(u8, block, "minecraft:")) block["minecraft:".len..] else block;
        flag.* = for (replaceable_blocks) |listed| {
            if (std.mem.eql(u8, short, listed)) break true;
        } else false;
        layers.* = 0;
        if (std.mem.eql(u8, short, "snow")) {
            const begin = std.mem.indexOf(u8, name, "layers=").? + "layers=".len;
            layers.* = name[begin] - '0';
        }
    }
    const snow_state = registry.blockStateId("minecraft:snow[layers=1]") orelse return error.UnknownBlockState;
    tables = .{ .replaceable = replaceable, .snow_layers = snow_layers, .snow = registry.block_state_to_block[@intCast(snow_state)] };
    tables_ready.store(true, .release);
}

/// AbstractBlock.Settings.replaceable, whatever is placed.
pub fn isReplaceable(state: u16) bool {
    ensureTables();
    return tables.replaceable[state];
}

/// Whether a block of `placing`, or a fluid when null, may take the place of `state`.
pub fn canReplace(state: u16, placing: ?u16) bool {
    ensureTables();
    if (!tables.replaceable[state]) return false;
    const block = registry.block_state_to_block[state];
    // Snow takes more snow as another layer, which is no replacement, and gives way to anything
    // else only one layer deep.
    if (block == tables.snow) return tables.snow_layers[state] == 1 and placing != tables.snow;
    return placing == null or placing.? != block;
}

test "fluids and plants give way to placed blocks and snow only one layer deep" {
    const state = struct {
        fn of(name: []const u8) u16 {
            return @intCast(registry.blockStateId(name).?);
        }
    };
    const stone_block = registry.block_state_to_block[state.of("minecraft:stone")];
    try std.testing.expect(canReplace(state.of("minecraft:water[level=0]"), stone_block));
    try std.testing.expect(canReplace(state.of("minecraft:lava[level=3]"), stone_block));
    try std.testing.expect(canReplace(state.of("minecraft:short_grass"), stone_block));
    try std.testing.expect(canReplace(0, stone_block));
    try std.testing.expect(!canReplace(state.of("minecraft:stone"), stone_block));
    try std.testing.expect(canReplace(state.of("minecraft:snow[layers=1]"), stone_block));
    try std.testing.expect(!canReplace(state.of("minecraft:snow[layers=2]"), stone_block));
    // A vine does not take the place of a vine, it grows another face.
    const vine = state.of("minecraft:vine[east=false,north=false,south=false,up=false,west=true]");
    try std.testing.expect(!canReplace(vine, registry.block_state_to_block[vine]));
}
