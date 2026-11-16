package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.LeavesBlock;

/** Watches the growth scene the server builds until every block has grown, decayed or stayed. */
final class GrowthFixture extends Fixture {
    private static final BlockPos CANE = new BlockPos(4, 65, 6);
    private static final BlockPos DIRT = new BlockPos(8, 64, 8);
    private static final BlockPos COVERED = new BlockPos(12, 64, 4);
    private static final BlockPos LOOSE_LEAF = new BlockPos(10, 70, 10);
    private static final BlockPos HELD_LEAF = new BlockPos(15, 66, 14);
    private boolean positioned;

    GrowthFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0) return;
        if (!positioned) {
            game.player.setPos(8.5, 65, 8.5);
            positioned = true;
        }
        if (missingChunks(game, 1) != 0) return;
        var level = game.level;
        boolean cane = level.getBlockState(CANE.above()).is(Blocks.SUGAR_CANE)
            && level.getBlockState(CANE.above(2)).is(Blocks.SUGAR_CANE);
        // Three tall is as high as cane grows.
        boolean capped = level.getBlockState(CANE.above(3)).isAir();
        boolean grass = level.getBlockState(DIRT).is(Blocks.GRASS_BLOCK);
        boolean died = level.getBlockState(COVERED).is(Blocks.DIRT);
        boolean decayed = level.getBlockState(LOOSE_LEAF).isAir();
        var held = level.getBlockState(HELD_LEAF);
        boolean kept = held.is(Blocks.OAK_LEAVES) && held.getValue(LeavesBlock.DISTANCE) == 1;
        if (r.tick % 100 == 0)
            client.event("growth_progress", "cane", cane, "capped", capped, "grass", grass, "died", died, "decayed", decayed, "kept", kept,
                "cane_base", level.getBlockState(CANE).toString(), "cane_ground", level.getBlockState(CANE.below()).toString(), "held_leaf", held.toString());
        if (!capped) { client.fail("sugar_cane_grew_past_three"); return; }
        if (cane && grass && died && decayed && kept) { client.pass("growth"); return; }
        if (r.tick - r.terrainTick > 2400)
            client.fail("growth_timeout cane=" + cane + " grass=" + grass + " died=" + died + " decayed=" + decayed + " kept=" + kept);
    }
}
