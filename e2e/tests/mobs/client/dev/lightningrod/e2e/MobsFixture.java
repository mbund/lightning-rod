package dev.lightningrod.e2e;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.Vec3;

/**
 * Cows end to end: a spawn egg places one on the grass, wheat leads it, a second egg places
 * another, wheat makes both fall in love until a calf comes, a bucket milks one, and a punch hurts
 * one, which panics and runs.
 */
final class MobsFixture extends Fixture {
    private static final BlockPos GRASS = new BlockPos(8, 64, 8);
    private enum Phase { GIVE, PLACE, PLACED, STANDING, TEMPT, SECOND, SECOND_PLACED, FEED, BRED, MILK, MILKED, ATTACK, PANIC, KILL, LOOT, DONE }
    private Phase phase = Phase.GIVE;
    private long waitUntil;
    private long phaseStart;
    private Vec3 attackedFrom;
    private int attackedId;
    private Vec3 deathPlace;
    private long lastHit;
    private int experienceBefore = -1;

    MobsFixture(Recorder r) { super(r); }

    private List<LivingEntity> cows(Minecraft game) {
        var found = new ArrayList<LivingEntity>();
        for (var entity : game.level.getEntities((Entity) null, new AABB(-32, 0, -32, 48, 128, 48)))
            if (BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals("cow") && entity instanceof LivingEntity living) found.add(living);
        return found;
    }

    private LivingEntity adult(Minecraft game) {
        for (var cow : cows(game)) if (!cow.isBaby()) return cow;
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
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException(error);
        }
        throw new IllegalStateException("no interact method");
    }

    private void select(Minecraft game, int slot) {
        game.player.getInventory().setSelectedSlot(slot);
    }

    private void next(Phase next, int delay) {
        phase = next;
        phaseStart = r.tick;
        waitUntil = r.tick + delay;
    }

    private boolean timedOut(int ticks) {
        return r.tick - phaseStart > ticks;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (r.tick - r.terrainTick > 6000) { client.fail("mobs_timeout_" + phase); return; }
        if (r.tick < waitUntil) return;
        var cows = cows(game);
        switch (phase) {
            case GIVE -> {
                game.player.setPos(5.5, 65, 8.5);
                ItemStack[] stacks = { new ItemStack(Items.COW_SPAWN_EGG), new ItemStack(Items.WHEAT), new ItemStack(Items.BUCKET) };
                for (int slot = 0; slot < stacks.length; slot++) {
                    game.player.getInventory().setItem(slot, stacks[slot]);
                    game.gameMode.handleCreativeModeItemAdd(stacks[slot], 36 + slot);
                }
                select(game, 0);
                next(Phase.PLACE, 20);
            }
            case PLACE -> {
                game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND, new BlockHitResult(new Vec3(8.5, 65, 8.5), Direction.UP, GRASS, false));
                next(Phase.PLACED, 0);
            }
            case PLACED -> {
                if (cows.isEmpty()) { if (timedOut(200)) client.fail("cow_never_came"); return; }
                var cow = cows.get(0);
                if (Math.abs(cow.getX() - 8.5) > 1e-6 || Math.abs(cow.getZ() - 8.5) > 1e-6 || Math.abs(cow.getY() - 65) > 1e-6) { client.fail("cow_misplaced_" + cow.position()); return; }
                if (cow.getHealth() != 10.0F) { client.fail("cow_health_" + cow.getHealth()); return; }
                next(Phase.STANDING, 40);
            }
            case STANDING -> {
                var cow = adult(game);
                if (cow == null) { client.fail("cow_gone"); return; }
                if (Math.abs(cow.getY() - 65) > 1e-3) { client.fail("cow_fell_" + cow.position()); return; }
                // Wheat in hand six blocks away: the cow walks over, as TemptGoal leads it.
                select(game, 1);
                game.player.setPos(Math.floor(cow.getX()) + 6.5, 65, Math.floor(cow.getZ()) + 0.5);
                next(Phase.TEMPT, 0);
            }
            case TEMPT -> {
                var cow = adult(game);
                if (cow == null) { client.fail("cow_gone"); return; }
                if (cow.distanceTo(game.player) < 3.5) { next(Phase.SECOND, 0); return; }
                if (timedOut(400)) client.fail("cow_not_tempted_" + cow.position() + "_" + game.player.position());
            }
            case SECOND -> {
                select(game, 0);
                var under = BlockPos.containing(game.player.getX() + 2, 64, game.player.getZ());
                game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND, new BlockHitResult(Vec3.atCenterOf(under).add(0, 0.5, 0), Direction.UP, under, false));
                next(Phase.SECOND_PLACED, 0);
            }
            case SECOND_PLACED -> {
                if (cows.size() >= 2) { select(game, 1); next(Phase.FEED, 10); return; }
                if (timedOut(200)) client.fail("second_cow_never_came");
            }
            case FEED -> {
                // Wheat for both: they fall in love, find each other and make a calf.
                for (var cow : cows) {
                    game.player.setPos(cow.getX() + 1.5, 65, cow.getZ());
                    interact(game, cow);
                }
                next(Phase.BRED, 0);
            }
            case BRED -> {
                for (var cow : cows) if (cow.isBaby()) { select(game, 2); next(Phase.MILK, 10); return; }
                if (timedOut(1200)) client.fail("no_calf_" + cows.size());
            }
            case MILK -> {
                var cow = adult(game);
                if (cow == null) { client.fail("no_adult"); return; }
                game.player.setPos(cow.getX() + 1.5, 65, cow.getZ());
                interact(game, cow);
                next(Phase.MILKED, 0);
            }
            case MILKED -> {
                if (game.player.getInventory().contains(new ItemStack(Items.MILK_BUCKET))) { next(Phase.ATTACK, 10); return; }
                if (timedOut(200)) client.fail("no_milk");
            }
            case ATTACK -> {
                var cow = adult(game);
                if (cow == null) { client.fail("no_adult"); return; }
                game.player.setPos(cow.getX() + 1.5, 65, cow.getZ());
                attackedFrom = cow.position();
                attackedId = cow.getId();
                game.gameMode.attack(game.player, cow);
                next(Phase.PANIC, 0);
            }
            case PANIC -> {
                LivingEntity cow = null;
                for (var candidate : cows) if (candidate.getId() == attackedId) cow = candidate;
                if (cow == null) { client.fail("attacked_cow_gone"); return; }
                // PanicGoal runs at twice the speed to a random place nearby.
                if (cow.getHealth() < 10.0F && cow.position().distanceTo(attackedFrom) > 3.0) { next(Phase.KILL, 0); return; }
                if (timedOut(200)) client.fail("no_panic_health_" + cow.getHealth() + "_moved_" + cow.position().distanceTo(attackedFrom));
            }
            case KILL -> {
                // Full strength punches, past the ten ticks of invulnerability each leaves, until it dies.
                LivingEntity cow = null;
                for (var candidate : cows) if (candidate.getId() == attackedId) cow = candidate;
                if (experienceBefore < 0) experienceBefore = game.player.totalExperience;
                if (cow == null || !cow.isAlive()) { next(Phase.LOOT, 0); return; }
                deathPlace = cow.position();
                if (r.tick - lastHit >= 12) {
                    game.player.setPos(cow.getX() + 1.5, cow.getY(), cow.getZ());
                    game.gameMode.attack(game.player, cow);
                    lastHit = r.tick;
                }
                if (timedOut(600)) client.fail("cow_never_died_" + cow.getHealth());
            }
            case LOOT -> {
                // A grown cow killed by a player drops beef and experience where it died. The player
                // stands beside it and may take the experience at once.
                boolean beef = false, orb = game.player.totalExperience > experienceBefore;
                for (var entity : game.level.getEntities((Entity) null, new AABB(deathPlace, deathPlace).inflate(4))) {
                    var type = BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath();
                    if (type.equals("experience_orb")) orb = true;
                    if (entity instanceof net.minecraft.world.entity.item.ItemEntity item && (item.getItem().is(Items.BEEF) || item.getItem().is(Items.COOKED_BEEF))) beef = true;
                }
                if (beef && orb) { next(Phase.DONE, 0); return; }
                if (timedOut(200)) client.fail("no_loot_beef_" + beef + "_orb_" + orb);
            }
            case DONE -> client.pass("mobs");
        }
        if (r.tick % 100 == 0) client.event("mobs_progress", "phase", phase.toString(), "cows", Integer.toString(cows.size()));
    }
}
