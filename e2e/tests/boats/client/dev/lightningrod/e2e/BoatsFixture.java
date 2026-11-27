package dev.lightningrod.e2e;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.inventory.ChestMenu;
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
    private enum Phase { GIVE, PLACE, AFLOAT, SURVIVAL, BREAK, DROPPED, BOARD, RIDING, DRIVE, LEAVE, LEFT, ABOARD, KEPT, SEATED, RIDDEN_OPEN, OFF, SNEAK, OPEN, STORE, STORED, PAIR_WAIT, PAIR_DRIVE, PAIR_CARRIED, PAIR_LEAVE, PAIR_WATCH }
    /** Bob in the pair scenario: aboard behind alice, carried, then steering once she is off. */
    private enum Bob { WAIT, BOARD, ABOARD, CARRIED, STEER, DRIVEN }
    private Bob bob = Bob.WAIT;
    private Vec3 left;
    private long seen;
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

    private boolean chest() {
        return r.scenario.equals("boats-chest");
    }

    private boolean isBoat(Entity entity) {
        return BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals(chest() ? "oak_chest_boat" : "oak_boat");
    }

    /** The boats the client draws near the player. */
    private List<Entity> boats(Minecraft game) {
        var found = new ArrayList<Entity>();
        for (var entity : game.level.entitiesForRendering()) if (isBoat(entity) && entity.distanceTo(game.player) < 24) found.add(entity);
        return found;
    }

    private Entity boat(Minecraft game) {
        var boats = boats(game);
        return boats.isEmpty() ? null : boats.get(0);
    }

    private static Entity cow(Minecraft game) {
        for (var entity : game.level.entitiesForRendering()) if (BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals("cow")) return entity;
        return null;
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

    private boolean pair() {
        return r.scenario.equals("boats-pair");
    }

    private void bobTick(Minecraft game) {
        switch (bob) {
            case WAIT -> {
                // On the grass south of the pool, near enough to reach the boat.
                game.player.setPos(5.5, 65, 9.5);
                if (!client.marked("alice.aboard")) return;
                boat = boat(game);
                if (boat == null) return;
                bob = Bob.BOARD;
                phaseStart = r.tick;
            }
            case BOARD -> {
                lookAt(game, boat.position());
                interact(game, boat);
                bob = Bob.ABOARD;
                phaseStart = r.tick;
            }
            case ABOARD -> {
                var riders = boat.getPassengers();
                if (game.player.getVehicle() != boat || riders.size() != 2) { if (timedOut(100)) client.fail("bob_never_boarded_" + riders); return; }
                if (riders.get(1) != game.player) { client.fail("bob_not_behind_" + riders); return; }
                client.mark("bob.aboard");
                bob = Bob.CARRIED;
                phaseStart = r.tick;
            }
            case CARRIED -> {
                if (!client.marked("alice.drove")) { if (timedOut(400)) client.fail("alice_never_drove"); else seen = r.tick; return; }
                // Twenty ticks after alice stopped, for the boat's moves to arrive.
                if (r.tick - seen < 20) return;
                // Carried along, behind the driver.
                if (game.player.getVehicle() != boat) { client.fail("bob_fell_off"); return; }
                if (boat.position().x < 6.5) { client.fail("bob_sees_boat_unmoved_" + boat.position() + "_riders_" + boat.getPassengers()); return; }
                if (game.player.position().distanceTo(boat.position()) > 1.0) { client.fail("bob_not_seated_" + game.player.position() + "_" + boat.position()); return; }
                client.mark("bob.carried");
                bob = Bob.STEER;
                phaseStart = r.tick;
            }
            case STEER -> {
                if (!client.marked("alice.left")) { if (timedOut(400)) client.fail("alice_never_left"); return; }
                var riders = boat.getPassengers();
                if (riders.size() != 1 || riders.get(0) != game.player) { if (timedOut(100)) client.fail("bob_never_alone_" + riders); return; }
                // Alone, bob steers: back west.
                if (start == null) { start = boat.position(); phaseStart = r.tick; }
                game.player.setYRot(90);
                boat.setYRot(90);
                game.options.keyUp.setDown(true);
                if (r.tick - phaseStart < 15) return;
                game.options.keyUp.setDown(false);
                driven = boat.position();
                if (start.x - driven.x < 1.0) { client.fail("bob_did_not_steer_" + start + "_" + driven); return; }
                client.mark("bob.drove");
                bob = Bob.DRIVEN;
                phaseStart = r.tick;
            }
            case DRIVEN -> {
                // The server kept the boat where bob drove it: it coasts on west, never back.
                if (!timedOut(40)) return;
                if (boat.position().x > driven.x + 0.1) { client.fail("boat_went_back_from_" + driven + "_to_" + boat.position()); return; }
                if (game.player.getVehicle() != boat) { client.fail("bob_not_aboard_at_end"); return; }
                client.pass("bob_carried_then_steered_to_" + boat.position());
            }
        }
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || game.gameMode == null || r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (r.tick - r.terrainTick > 2400) { client.fail("boats_timeout_" + phase); return; }
        if (pair() && !r.peer.equals("alice")) { bobTick(game); return; }
        switch (phase) {
            case GIVE -> {
                // At the pool's west edge, looking at its middle.
                game.player.setPos(1.5, 65, 5.5);
                lookAt(game, new Vec3(5.5, 64.95, 5.5));
                var boat = new ItemStack(chest() ? Items.OAK_CHEST_BOAT : Items.OAK_BOAT);
                game.player.getInventory().setItem(0, boat);
                game.gameMode.handleCreativeModeItemAdd(boat, 36);
                if (chest()) {
                    var diamond = new ItemStack(Items.DIAMOND, 5);
                    game.player.getInventory().setItem(1, diamond);
                    game.gameMode.handleCreativeModeItemAdd(diamond, 37);
                }
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
                if (r.scenario.equals("boats-ride") || pair()) { next(Phase.BOARD); return; }
                if (r.scenario.equals("boats-cow")) { this.boat = boat; next(Phase.ABOARD); return; }
                if (chest()) { this.boat = boat; interact(game, boat); next(Phase.SEATED); return; }
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
                if (game.player.getVehicle() == boat) { if (pair()) { client.mark("alice.aboard"); next(Phase.PAIR_WAIT); } else next(Phase.DRIVE); return; }
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
            case PAIR_WAIT -> {
                if (!client.marked("bob.aboard")) { if (timedOut(400)) client.fail("bob_never_aboard"); return; }
                // Alice steers, first; bob sits behind.
                var riders = boat.getPassengers();
                if (riders.size() != 2 || riders.get(0) != game.player) { client.fail("riders_" + riders); return; }
                start = boat.position();
                next(Phase.PAIR_DRIVE);
            }
            case PAIR_DRIVE -> {
                game.player.setYRot(-90);
                boat.setYRot(-90);
                game.options.keyUp.setDown(true);
                if (!timedOut(15)) return;
                game.options.keyUp.setDown(false);
                driven = boat.position();
                if (driven.distanceTo(start) < 1.0) { client.fail("pair_boat_did_not_move_" + start + "_" + driven); return; }
                client.mark("alice.drove");
                next(Phase.PAIR_CARRIED);
            }
            case PAIR_CARRIED -> {
                if (!client.marked("bob.carried")) { if (timedOut(200)) client.fail("bob_never_carried"); return; }
                game.options.keyShift.setDown(true);
                next(Phase.PAIR_LEAVE);
            }
            case PAIR_LEAVE -> {
                if (game.player.getVehicle() != null) { if (timedOut(100)) client.fail("alice_never_left"); return; }
                game.options.keyShift.setDown(false);
                left = boat.position();
                client.mark("alice.left");
                next(Phase.PAIR_WATCH);
            }
            case PAIR_WATCH -> {
                // Bob steers it now: alice sees it go back west, bob still aboard.
                if (!client.marked("bob.drove")) { if (timedOut(400)) client.fail("bob_never_drove"); return; }
                if (!timedOut(40)) return;
                var at = boat.position();
                if (left.x - at.x < 1.0) { client.fail("alice_saw_no_steering_" + left + "_" + at); return; }
                if (boat.getPassengers().size() != 1) { client.fail("alice_sees_riders_" + boat.getPassengers()); return; }
                client.pass("pair_drove_and_handed_over_at_" + at);
            }
            case SEATED -> {
                // With room aboard and not sneaking, a click boards it.
                if (game.player.getVehicle() != boat) { if (timedOut(100)) client.fail("chest_boat_never_boarded"); return; }
                // The inventory key of a chest boat's rider opens the chest.
                game.player.sendOpenInventory();
                next(Phase.RIDDEN_OPEN);
            }
            case RIDDEN_OPEN -> {
                if (!(game.player.containerMenu instanceof ChestMenu)) { if (timedOut(100)) client.fail("ridden_chest_never_opened"); return; }
                game.player.closeContainer();
                game.options.keyShift.setDown(true);
                next(Phase.OFF);
            }
            case OFF -> {
                if (game.player.getVehicle() != null) { if (timedOut(100)) client.fail("never_got_off_the_chest_boat"); return; }
                // Getting off ends the sneak for the server, as Player.rideTick does, and the client
                // says only when its keys change: so shift goes up and down again.
                game.options.keyShift.setDown(false);
                next(Phase.SNEAK);
            }
            case SNEAK -> {
                // Sneaking, a click opens the chest rather than boarding.
                if (r.tick - phaseStart == 5) game.options.keyShift.setDown(true);
                if (!timedOut(10)) return;
                lookAt(game, boat.position());
                interact(game, boat);
                next(Phase.OPEN);
            }
            case OPEN -> {
                if (!(game.player.containerMenu instanceof ChestMenu menu)) { if (timedOut(100)) client.fail("chest_never_opened"); return; }
                if (game.player.getVehicle() != null) { client.fail("boarded_instead_of_opening"); return; }
                if (menu.getRowCount() != 3) { client.fail("chest_rows_" + menu.getRowCount()); return; }
                // The diamonds in the hotbar's second slot, after the chest's 27 and the 27 above the hotbar.
                GameApi.inventoryClick(game, 27 + 27 + 1, 0, ClickType.QUICK_MOVE);
                next(Phase.STORE);
            }
            case STORE -> {
                if (!(game.player.containerMenu instanceof ChestMenu menu)) { client.fail("chest_closed_early"); return; }
                if (!timedOut(20)) return;
                if (!menu.getSlot(0).getItem().is(Items.DIAMOND) || menu.getSlot(0).getItem().getCount() != 5) { client.fail("chest_holds_" + menu.getSlot(0).getItem()); return; }
                game.player.closeContainer();
                game.options.keyShift.setDown(false);
                next(Phase.STORED);
            }
            case STORED -> {
                if (!timedOut(20)) return;
                if (game.player.getInventory().contains(new ItemStack(Items.DIAMOND))) { client.fail("diamonds_still_carried"); return; }
                game.getConnection().sendCommand("gamemode survival");
                next(Phase.SURVIVAL);
            }
            case ABOARD -> {
                // The cow the scene put beside the boat rides it.
                var cow = cow(game);
                if (cow != null && cow.getVehicle() == boat) { next(Phase.KEPT); return; }
                if (timedOut(200)) client.fail("cow_never_aboard_" + (cow == null ? "none" : cow.position() + "_rides_" + cow.getVehicle()));
            }
            case KEPT -> {
                var cow = cow(game);
                if (cow == null || cow.getVehicle() != boat) { client.fail("cow_left_the_boat"); return; }
                if (cow.position().distanceTo(boat.position()) > 1.0) { client.fail("cow_not_seated_" + cow.position() + "_boat_" + boat.position()); return; }
                if (!timedOut(40)) return;
                game.getConnection().sendCommand("gamemode survival");
                next(Phase.SURVIVAL);
            }
            case DROPPED -> {
                if (chest()) {
                    // The chest's diamonds drop with the boat.
                    boolean diamonds = game.player.getInventory().contains(new ItemStack(Items.DIAMOND));
                    for (var entity : game.level.entitiesForRendering()) if (entity instanceof ItemEntity item && item.getItem().is(Items.DIAMOND)) diamonds = true;
                    if (diamonds) { client.pass("chest_boat_held_diamonds_and_dropped_them_after_" + attacks); return; }
                    if (timedOut(200)) client.fail("no_diamonds_dropped");
                    return;
                }
                if (r.scenario.equals("boats-cow")) {
                    var cow = cow(game);
                    if (cow != null && cow.getVehicle() == null) { client.pass("cow_rode_the_boat_and_was_set_down_at_" + cow.position()); return; }
                    if (timedOut(200)) client.fail("cow_still_riding");
                    return;
                }
                for (var entity : game.level.entitiesForRendering()) {
                    if (entity instanceof ItemEntity item && item.getItem().is(Items.OAK_BOAT) && item.distanceTo(game.player) < 16) { client.pass("boat_floated_and_broke_into_its_item_after_" + attacks); return; }
                }
                if (game.player.getInventory().contains(new ItemStack(Items.OAK_BOAT))) { client.pass("boat_floated_and_broke_and_was_picked_up_after_" + attacks); return; }
                if (timedOut(200)) client.fail("no_boat_item_dropped");
            }
        }
    }
}
