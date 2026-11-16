package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.commands.arguments.EntityAnchorArgument;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.material.Fluids;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;

/** Pours water from a bucket, places stone into the water, and takes up a source with an empty bucket. */
final class BucketsFixture extends Fixture {
    private static final BlockPos POURED = new BlockPos(8, 65, 8);
    private static final BlockPos SOURCE = new BlockPos(4, 65, 4);
    private enum Phase { GIVE, POUR, POURED, PLACE, PLACED, TAKE, TAKEN }
    private Phase phase = Phase.GIVE;
    private long waitUntil;

    BucketsFixture(Recorder r) { super(r); }

    private boolean source(Minecraft game, BlockPos position) {
        var fluid = game.level.getBlockState(position).getFluidState();
        return fluid.getType() == Fluids.WATER && fluid.isSource();
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (r.tick - r.terrainTick > 2400) { client.fail("buckets_timeout_" + phase); return; }
        if (r.tick < waitUntil) return;
        var level = game.level;
        switch (phase) {
            case GIVE -> {
                game.player.setPos(8.5, 65, 8.5);
                game.player.setXRot(90);
                for (var stack : new ItemStack[]{ new ItemStack(Items.WATER_BUCKET), new ItemStack(Items.STONE, 8), new ItemStack(Items.BUCKET) }) {
                    int slot = stack.is(Items.WATER_BUCKET) ? 0 : stack.is(Items.STONE) ? 1 : 2;
                    game.player.getInventory().setItem(slot, stack);
                    game.gameMode.handleCreativeModeItemAdd(stack, 36 + slot);
                }
                game.player.getInventory().setSelectedSlot(0);
                phase = Phase.POUR;
                waitUntil = r.tick + 20;
            }
            case POUR -> {
                // Straight down from where the player stands: the water goes on the grass, at their feet.
                game.player.setXRot(90);
                game.gameMode.useItem(game.player, InteractionHand.MAIN_HAND);
                phase = Phase.POURED;
            }
            case POURED -> {
                if (!source(game, POURED)) return;
                game.player.setPos(11.5, 65, 8.5);
                game.player.getInventory().setSelectedSlot(1);
                phase = Phase.PLACE;
                waitUntil = r.tick + 20;
            }
            case PLACE -> {
                // Against the grass under the water: the stone takes the water's place.
                game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND,
                    new BlockHitResult(new Vec3(8.5, 65, 8.5), Direction.UP, POURED.below(), false));
                phase = Phase.PLACED;
            }
            case PLACED -> {
                if (!level.getBlockState(POURED).is(Blocks.STONE)) return;
                game.player.setPos(4.5, 65, 7.5);
                game.player.getInventory().setSelectedSlot(2);
                phase = Phase.TAKE;
                waitUntil = r.tick + 20;
            }
            case TAKE -> {
                game.player.lookAt(EntityAnchorArgument.Anchor.EYES, new Vec3(4.5, 65.4, 4.5));
                game.gameMode.useItem(game.player, InteractionHand.MAIN_HAND);
                phase = Phase.TAKEN;
            }
            case TAKEN -> {
                if (source(game, SOURCE)) return;
                client.pass("buckets");
            }
        }
        if (r.tick % 100 == 0)
            client.event("buckets_progress", "phase", phase.toString(), "poured", level.getBlockState(POURED).toString(), "source", level.getBlockState(SOURCE).toString());
    }
}
