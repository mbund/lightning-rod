package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.Entity;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;

/** Places a cow with a spawn egg on the grass and checks the cow arrives standing on it. */
final class MobsFixture extends Fixture {
    private static final BlockPos GRASS = new BlockPos(8, 64, 8);
    private enum Phase { GIVE, PLACE, PLACED, STANDING, TEMPT, TEMPTED }
    private Phase phase = Phase.GIVE;
    private long waitUntil;
    private long temptStart;

    MobsFixture(Recorder r) { super(r); }

    private Entity cow(Minecraft game) {
        for (var entity : game.level.getEntities((Entity) null, new AABB(-16, 0, -16, 32, 128, 32))) if (BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals("cow")) return entity;
        return null;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (r.tick - r.terrainTick > 2400) { client.fail("mobs_timeout_" + phase); return; }
        if (r.tick < waitUntil) return;
        switch (phase) {
            case GIVE -> {
                game.player.setPos(5.5, 65, 8.5);
                var egg = new ItemStack(Items.COW_SPAWN_EGG);
                game.player.getInventory().setItem(0, egg);
                game.gameMode.handleCreativeModeItemAdd(egg, 36);
                game.player.getInventory().setSelectedSlot(0);
                phase = Phase.PLACE;
                waitUntil = r.tick + 20;
            }
            case PLACE -> {
                game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND,
                    new BlockHitResult(new Vec3(8.5, 65, 8.5), Direction.UP, GRASS, false));
                phase = Phase.PLACED;
            }
            case PLACED -> {
                var cow = cow(game);
                if (cow == null) return;
                if (Math.abs(cow.getX() - 8.5) > 1e-6 || Math.abs(cow.getZ() - 8.5) > 1e-6 || Math.abs(cow.getY() - 65) > 1e-6) {
                    client.fail("cow_misplaced_" + cow.position());
                    return;
                }
                if (!(cow instanceof LivingEntity living) || living.getHealth() != 10.0F) {
                    client.fail("cow_health");
                    return;
                }
                phase = Phase.STANDING;
                waitUntil = r.tick + 40;
            }
            case STANDING -> {
                var cow = cow(game);
                if (cow == null) { client.fail("cow_gone"); return; }
                if (Math.abs(cow.getY() - 65) > 1e-3) { client.fail("cow_fell_" + cow.position()); return; }
                // Wheat in hand six blocks away: the cow walks over, as TemptGoal leads it.
                var wheat = new ItemStack(Items.WHEAT);
                game.player.getInventory().setItem(1, wheat);
                game.gameMode.handleCreativeModeItemAdd(wheat, 37);
                game.player.getInventory().setSelectedSlot(1);
                game.player.setPos(Math.floor(cow.getX()) + 6.5, 65, Math.floor(cow.getZ()) + 0.5);
                temptStart = r.tick;
                phase = Phase.TEMPT;
            }
            case TEMPT -> {
                var cow = cow(game);
                if (cow == null) { client.fail("cow_gone"); return; }
                if (cow.distanceTo(game.player) < 3.5) { phase = Phase.TEMPTED; return; }
                if (r.tick - temptStart > 400) client.fail("cow_not_tempted_" + cow.position() + "_" + game.player.position());
            }
            case TEMPTED -> client.pass("mobs");
        }
        if (r.tick % 100 == 0) client.event("mobs_progress", "phase", phase.toString());
    }
}
