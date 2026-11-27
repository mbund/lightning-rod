package dev.lightningrod.e2e;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.Vec3;

/**
 * A boat put on the scene's pool from its item: the client is shown it where it looked, afloat
 * and still on the still water. In survival, a few punches break it, and its item drops.
 */
final class BoatsFixture extends Fixture {
    private enum Phase { GIVE, PLACE, AFLOAT, SURVIVAL, BREAK, DROPPED }
    private Phase phase = Phase.GIVE;
    private long phaseStart;
    private double settledY = Double.NaN;
    private int attacks;

    BoatsFixture(Recorder r) { super(r); }

    private void next(Phase next) {
        phase = next;
        phaseStart = r.tick;
    }

    private boolean timedOut(int ticks) {
        return r.tick - phaseStart > ticks;
    }

    private static boolean isBoat(Entity entity) {
        return BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals("oak_boat");
    }

    /** The boats the client draws near the player. */
    private List<Entity> boats(Minecraft game) {
        var found = new ArrayList<Entity>();
        for (var entity : game.level.entitiesForRendering()) if (isBoat(entity) && entity.distanceTo(game.player) < 24) found.add(entity);
        return found;
    }

    /** Looks from the eyes at a point, as a player turning to it would. */
    private static void lookAt(Minecraft game, Vec3 target) {
        var eye = game.player.getEyePosition();
        double dx = target.x - eye.x, dy = target.y - eye.y, dz = target.z - eye.z;
        game.player.setYRot((float) Math.toDegrees(Math.atan2(-dx, dz)));
        game.player.setXRot((float) -Math.toDegrees(Math.atan2(dy, Math.sqrt(dx * dx + dz * dz))));
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || game.gameMode == null || r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (r.tick - r.terrainTick > 2400) { client.fail("boats_timeout_" + phase); return; }
        switch (phase) {
            case GIVE -> {
                // At the pool's west edge, looking at its middle.
                game.player.setPos(1.5, 65, 5.5);
                lookAt(game, new Vec3(5.5, 64.95, 5.5));
                var boat = new ItemStack(Items.OAK_BOAT);
                game.player.getInventory().setItem(0, boat);
                game.gameMode.handleCreativeModeItemAdd(boat, 36);
                game.player.getInventory().setSelectedSlot(0);
                if (timedOut(20)) next(Phase.PLACE);
            }
            case PLACE -> {
                lookAt(game, new Vec3(5.5, 64.95, 5.5));
                game.gameMode.useItem(game.player, InteractionHand.MAIN_HAND);
                next(Phase.AFLOAT);
            }
            case AFLOAT -> {
                var boats = boats(game);
                if (boats.isEmpty()) { if (timedOut(200)) client.fail("boat_never_shown"); return; }
                if (boats.size() != 1) { client.fail("boats_" + boats.size()); return; }
                var boat = boats.get(0);
                var at = boat.position();
                if (at.x < 3 || at.x > 9 || at.z < 3 || at.z > 9) { client.fail("boat_off_the_pool_" + at); return; }
                if (!timedOut(80)) return;
                // Floating: in the water's top block, and no longer rising or sinking.
                if (at.y < 64 || at.y > 65.2) { client.fail("boat_not_afloat_" + at); return; }
                if (Double.isNaN(settledY)) { settledY = at.y; return; }
                if (!timedOut(120)) return;
                if (Math.abs(at.y - settledY) > 0.05) { client.fail("boat_bobbing_" + settledY + "_to_" + at.y); return; }
                game.getConnection().sendCommand("gamemode survival");
                next(Phase.SURVIVAL);
            }
            case SURVIVAL -> {
                if (game.gameMode.getPlayerMode() == GameType.SURVIVAL) next(Phase.BREAK);
                else if (timedOut(200)) client.fail("never_survival");
            }
            case BREAK -> {
                var boats = boats(game);
                if (boats.isEmpty()) { next(Phase.DROPPED); return; }
                if (timedOut(400)) { client.fail("boat_not_broken_after_" + attacks); return; }
                // A punch every few ticks: each wobbles it ten times its damage, one tick back at a time.
                if ((r.tick - phaseStart) % 4 != 0) return;
                lookAt(game, boats.get(0).position());
                game.gameMode.attack(game.player, boats.get(0));
                game.player.swing(InteractionHand.MAIN_HAND);
                attacks++;
            }
            case DROPPED -> {
                for (var entity : game.level.entitiesForRendering()) {
                    if (entity instanceof ItemEntity item && item.getItem().is(Items.OAK_BOAT) && item.distanceTo(game.player) < 16) { client.pass("boat_floated_and_broke_into_its_item_after_" + attacks); return; }
                }
                if (game.player.getInventory().contains(new ItemStack(Items.OAK_BOAT))) { client.pass("boat_floated_and_broke_and_was_picked_up_after_" + attacks); return; }
                if (timedOut(200)) client.fail("no_boat_item_dropped");
            }
        }
    }
}
