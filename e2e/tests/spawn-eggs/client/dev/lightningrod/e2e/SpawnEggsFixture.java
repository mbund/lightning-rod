package dev.lightningrod.e2e;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;

/**
 * Cows placed from spawn eggs on a server set up as the example is. Before a restart: the client
 * is shown the cow and it wanders off. After: it is still there, and a cow placed then is shown
 * beside it, which it was not while each start drew the same first UUID, as clients keep only the
 * first entity with a UUID.
 */
final class SpawnEggsFixture extends Fixture {
    private enum Phase { GIVE, PLACE, SHOWN, WANDER, KEPT, SECOND }
    private Phase phase;
    private long phaseStart;
    private BlockPos ground;

    SpawnEggsFixture(Recorder r) { super(r); }

    /** The cows the client draws. One with a UUID it already holds is found by area but never drawn. */
    private List<Entity> cows(Minecraft game) {
        var found = new ArrayList<Entity>();
        for (var entity : game.level.entitiesForRendering())
            if (BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals("cow") && entity.distanceTo(game.player) < 48) found.add(entity);
        return found;
    }

    private void next(Phase next) {
        phase = next;
        phaseStart = r.tick;
    }

    private boolean timedOut(int ticks) {
        return r.tick - phaseStart > ticks;
    }

    /** The top block three east of the player, where an egg goes. */
    private BlockPos groundBeside(Minecraft game) {
        int x = game.player.getBlockX() + 3, z = game.player.getBlockZ();
        return new BlockPos(x, game.level.getHeight(Heightmap.Types.MOTION_BLOCKING, x, z) - 1, z);
    }

    private void holdEgg(Minecraft game) {
        var egg = new ItemStack(Items.COW_SPAWN_EGG);
        game.player.getInventory().setItem(0, egg);
        game.gameMode.handleCreativeModeItemAdd(egg, 36);
        game.player.getInventory().setSelectedSlot(0);
    }

    private void useEgg(Minecraft game) {
        game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND, new BlockHitResult(Vec3.atCenterOf(ground).add(0, 0.5, 0), Direction.UP, ground, false));
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (phase == null) next(r.scenario.endsWith("-seed") ? Phase.GIVE : Phase.KEPT);
        var cows = cows(game);
        switch (phase) {
            case GIVE -> {
                holdEgg(game);
                ground = groundBeside(game);
                if (timedOut(20)) next(Phase.PLACE);
            }
            case PLACE -> {
                useEgg(game);
                next(Phase.SHOWN);
            }
            case SHOWN -> {
                if (cows.isEmpty()) { if (timedOut(200)) client.fail("cow_never_shown_on_" + ground); return; }
                next(Phase.WANDER);
            }
            case WANDER -> {
                if (cows.size() != 1) { client.fail("cows_" + cows.size()); return; }
                // WaterAvoidingRandomStrollGoal starts one in 120 ticks.
                if (cows.get(0).position().distanceTo(Vec3.atBottomCenterOf(ground.above())) > 1.0) { client.pass("cow_wandered"); return; }
                if (timedOut(2400)) client.fail("cow_never_moved_" + cows.get(0).position());
            }
            case KEPT -> {
                if (cows.isEmpty()) { if (timedOut(400)) client.fail("cow_not_kept"); return; }
                holdEgg(game);
                ground = groundBeside(game);
                if (!timedOut(20)) return;
                useEgg(game);
                next(Phase.SECOND);
            }
            case SECOND -> {
                if (cows.size() == 2) { client.pass("cow_kept_and_second_shown"); return; }
                if (timedOut(200)) client.fail("second_cow_not_shown_" + cows.size());
            }
        }
    }
}
