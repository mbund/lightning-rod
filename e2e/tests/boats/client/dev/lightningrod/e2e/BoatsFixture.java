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
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.Vec3;

/**
 * A boat put on the scene's pool from its item: the client is shown it where it looked, afloat
 * and still on the still water. In survival, a few punches break it, and its item drops.
 */
final class BoatsFixture extends Fixture {
    private enum Phase { GIVE, PLACE, AFLOAT, SURVIVAL, BREAK, DROPPED, BOARD, RIDING, DRIVE, LEAVE, LEFT }
    private Phase phase = Phase.GIVE;
    private long phaseStart;
    private double settledY = Double.NaN;
    private int attacks;
    private Entity boat;
    private Vec3 start;
    private Vec3 driven;

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

    /** Right clicks an entity, through whichever interact the client release has. */
    private void interact(Minecraft game, Entity entity) {
        try {
            for (var method : game.gameMode.getClass().getMethods()) {
                if (!method.getName().equals("interact")) continue;
                if (method.getParameterCount() == 4) {
                    method.invoke(game.gameMode, game.player, entity, new EntityHitResult(entity, entity.position().add(0, entity.getBbHeight() / 2, 0)), InteractionHand.MAIN_HAND);
                    return;
                }
                if (method.getParameterCount() == 3) {
                    method.invoke(game.gameMode, game.player, entity, InteractionHand.MAIN_HAND);
                    return;
                }
            }
        } catch (ReflectiveOperationException failure) {
            client.fail("interact_" + failure);
        }
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
                if (r.scenario.equals("boats-ride")) { next(Phase.BOARD); return; }
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
            case BOARD -> {
                var boats = boats(game);
                if (boats.size() != 1) { client.fail("board_boats_" + boats.size()); return; }
                boat = boats.get(0);
                start = boat.position();
                interact(game, boat);
                next(Phase.RIDING);
            }
            case RIDING -> {
                if (game.player.getVehicle() == boat) { next(Phase.DRIVE); return; }
                if (timedOut(100)) client.fail("never_boarded_" + game.player.position());
            }
            case DRIVE -> {
                // Paddling straight on, toward the pool's east side.
                game.player.setYRot(-90);
                boat.setYRot(-90);
                game.options.keyUp.setDown(true);
                if (!timedOut(15)) return;
                game.options.keyUp.setDown(false);
                driven = boat.position();
                if (driven.distanceTo(start) < 1.0) { client.fail("boat_did_not_move_" + start + "_" + driven); return; }
                game.options.keyShift.setDown(true);
                next(Phase.LEAVE);
            }
            case LEAVE -> {
                if (game.player.getVehicle() != null) { if (timedOut(100)) client.fail("never_left"); return; }
                game.options.keyShift.setDown(false);
                next(Phase.LEFT);
            }
            case LEFT -> {
                // The server kept the boat where its rider drove it, and set the rider down beside it.
                if (!timedOut(40)) return;
                var at = boat.position();
                if (at.distanceTo(driven) > 1.0) { client.fail("boat_went_back_from_" + driven + "_to_" + at); return; }
                if (game.player.position().distanceTo(at) > 3.0) { client.fail("rider_set_down_far_" + game.player.position() + "_boat_" + at); return; }
                client.pass("boat_boarded_driven_and_left_at_" + at);
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
