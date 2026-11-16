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
 * Cows led by wheat toward an open trapdoor over a pit take the trapdoor for floor, as vanilla
 * mobs do in farms: the grown cow, wider than the gap beside the trapdoor's slab, crosses on its
 * edge, and the calf falls in.
 */
final class MobFarmFixture extends Fixture {
    private enum Phase { GIVE, PLACE, CALF, LURE, CROSS }
    private Phase phase = Phase.GIVE;
    private long waitUntil;
    private long phaseStart;
    private boolean adultOverTrapdoor;

    MobFarmFixture(Recorder r) { super(r); }

    private List<LivingEntity> cows(Minecraft game) {
        var found = new ArrayList<LivingEntity>();
        for (var entity : game.level.getEntities((Entity) null, new AABB(-16, 0, -16, 32, 128, 32)))
            if (BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals("cow") && entity instanceof LivingEntity living) found.add(living);
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
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException(error);
        }
        throw new IllegalStateException("no interact method");
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (r.tick - r.terrainTick > 3000) { client.fail("mob_farm_timeout_" + phase); return; }
        if (r.tick < waitUntil) return;
        var cows = cows(game);
        switch (phase) {
            case GIVE -> {
                game.player.setPos(6.5, 65, 8.5);
                ItemStack[] stacks = { new ItemStack(Items.COW_SPAWN_EGG), new ItemStack(Items.WHEAT) };
                for (int slot = 0; slot < stacks.length; slot++) {
                    game.player.getInventory().setItem(slot, stacks[slot]);
                    game.gameMode.handleCreativeModeItemAdd(stacks[slot], 36 + slot);
                }
                game.player.getInventory().setSelectedSlot(0);
                phase = Phase.PLACE;
                waitUntil = r.tick + 20;
            }
            case PLACE -> {
                var grass = new BlockPos(8, 64, 8);
                game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND, new BlockHitResult(new Vec3(8.5, 65, 8.5), Direction.UP, grass, false));
                phase = Phase.CALF;
                waitUntil = r.tick + 20;
            }
            case CALF -> {
                if (cows.isEmpty()) return;
                // A spawn egg used on a cow makes a calf beside it.
                interact(game, cows.get(0));
                phase = Phase.LURE;
                waitUntil = r.tick + 20;
            }
            case LURE -> {
                if (cows.size() < 2) return;
                // Across the pit, wheat in hand: the straight way is over the trapdoor.
                game.player.getInventory().setSelectedSlot(1);
                game.player.setPos(16.5, 65, 8.5);
                phase = Phase.CROSS;
                phaseStart = r.tick;
            }
            case CROSS -> {
                boolean calfFell = false;
                for (var cow : cows) {
                    boolean overTrapdoor = Math.abs(cow.getX() - 12.5) < 0.3 && Math.abs(cow.getZ() - 8.5) < 0.3;
                    if (!cow.isBaby() && overTrapdoor && Math.abs(cow.getY() - 65) < 1e-3) adultOverTrapdoor = true;
                    if (cow.isBaby() && overTrapdoor && cow.getY() < 63.5) calfFell = true;
                }
                if (calfFell && adultOverTrapdoor) { client.pass("mob-farm"); return; }
                if (r.tick - phaseStart > 800) {
                    var positions = new StringBuilder();
                    for (var cow : cows) positions.append(cow.isBaby() ? "calf" : "cow").append(cow.position());
                    client.fail("calf_fell_" + calfFell + "_adult_crossed_" + adultOverTrapdoor + "_" + positions);
                }
            }
        }
    }
}
