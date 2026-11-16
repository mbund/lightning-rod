package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.level.material.Fluids;

/** Watches the fluids the server pours until each has spread, hardened or fallen as vanilla's do. */
final class FluidsFixture extends Fixture {
    private static final BlockPos WATER_EDGE = new BlockPos(11, 65, 4);
    private static final BlockPos WATER_PAST = new BlockPos(12, 65, 4);
    private static final BlockPos WATER_DIAGONAL = new BlockPos(7, 65, 8);
    private static final BlockPos STAIR = new BlockPos(4, 65, 6);
    private static final BlockPos LAVA_EDGE = new BlockPos(33, 65, 10);
    private static final BlockPos LAVA_PAST = new BlockPos(34, 65, 10);
    private static final BlockPos OBSIDIAN = new BlockPos(20, 65, 20);
    private static final BlockPos HOLE_BOTTOM = new BlockPos(40, 61, 4);
    private boolean positioned;

    FluidsFixture(Recorder r) { super(r); }

    private static boolean flowing(BlockState state, net.minecraft.world.level.material.Fluid fluid, int amount) {
        var held = state.getFluidState();
        return held.getType() == fluid && held.getAmount() == amount;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0) return;
        if (!positioned) {
            game.player.setPos(20.5, 72, 12.5);
            positioned = true;
        }
        if (missingChunks(game, 1) != 0) return;
        var level = game.level;
        boolean edge = flowing(level.getBlockState(WATER_EDGE), Fluids.FLOWING_WATER, 1)
            && flowing(level.getBlockState(WATER_DIAGONAL), Fluids.FLOWING_WATER, 1);
        boolean bounded = level.getBlockState(WATER_PAST).isAir();
        var stair = level.getBlockState(STAIR);
        boolean dry = stair.is(Blocks.OAK_STAIRS) && !stair.getValue(BlockStateProperties.WATERLOGGED);
        boolean lava = flowing(level.getBlockState(LAVA_EDGE), Fluids.FLOWING_LAVA, 2);
        boolean lava_bounded = level.getBlockState(LAVA_PAST).isAir();
        boolean obsidian = level.getBlockState(OBSIDIAN).is(Blocks.OBSIDIAN);
        boolean fell = level.getBlockState(HOLE_BOTTOM).getFluidState().getType() == Fluids.FLOWING_WATER;
        if (r.tick % 100 == 0)
            client.event("fluids_progress", "edge", edge, "bounded", bounded, "dry", dry, "lava", lava, "lava_bounded", lava_bounded, "obsidian", obsidian, "fell", fell,
                "water_edge", level.getBlockState(WATER_EDGE).toString(), "lava_edge", level.getBlockState(LAVA_EDGE).toString(), "hole", level.getBlockState(HOLE_BOTTOM).toString());
        if (!bounded) { client.fail("water_spread_past_seven"); return; }
        if (!lava_bounded) { client.fail("lava_spread_past_three"); return; }
        if (!dry) { client.fail("flowing_water_filled_a_stair"); return; }
        if (edge && lava && obsidian && fell) { client.pass("fluids"); return; }
        if (r.tick - r.terrainTick > 2400)
            client.fail("fluids_timeout edge=" + edge + " lava=" + lava + " obsidian=" + obsidian + " fell=" + fell);
    }
}
