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
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.Vec3;

/**
 * Sheep end to end: three spawn eggs place three on the grass. Shears shear the first, which
 * drops one to three wool of its colour and shows sheared; a dye on it then does nothing. The
 * other two are dyed red and yellow and fed wheat until a lamb comes, orange as the two dyes
 * craft. The lamb, which rolls to eat one goal tick in fifty, eats: its client plays the eating
 * animation, and a grass block under it turns to dirt.
 */
final class SheepFixture extends Fixture {
    private enum Phase { GIVE, PLACE, PLACED, SHEAR, SHORN, DYE_SHORN, DYE_SHORN_CHECK, DYE, DYED, FEED, BRED, EAT, DONE }
    private Phase phase = Phase.GIVE;
    private long waitUntil;
    private long phaseStart;
    private int placed;
    private int shornId = -1;
    private String shornColor;
    private boolean ateAnimation;
    private int dirtBefore = -1;
    private static final int EGG = 0, SHEARS = 1, RED = 2, YELLOW = 3, WHEAT = 4, BLUE = 5;

    SheepFixture(Recorder r) { super(r); }

    private List<LivingEntity> sheep(Minecraft game) {
        var found = new ArrayList<LivingEntity>();
        for (var entity : game.level.getEntities((Entity) null, new AABB(-32, 0, -32, 48, 128, 48)))
            if (BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals("sheep") && entity instanceof LivingEntity living) found.add(living);
        return found;
    }

    /** Sheep.getColor, by name, through reflection, as its class moved between releases. */
    private static String color(LivingEntity sheep) {
        return call(sheep, "getColor").toString().toLowerCase();
    }

    private static boolean sheared(LivingEntity sheep) {
        return (Boolean) call(sheep, "isSheared");
    }

    /** Sheep.getHeadEatPositionScale: above zero while the eating animation plays. */
    private static float eating(LivingEntity sheep) {
        try {
            return (Float) sheep.getClass().getMethod("getHeadEatPositionScale", float.class).invoke(sheep, 0.0F);
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException(error);
        }
    }

    /** An item by its registry name, as dyes have no constant of their own in every release. */
    private static net.minecraft.world.item.Item item(String path) {
        for (var each : BuiltInRegistries.ITEM) if (BuiltInRegistries.ITEM.getKey(each).getPath().equals(path)) return each;
        throw new IllegalStateException("no item " + path);
    }

    private static Object call(Object target, String name) {
        try {
            return target.getClass().getMethod(name).invoke(target);
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException(error);
        }
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

    /** Stands beside a mob and uses what is in a hotbar slot on it. */
    private void use(Minecraft game, int slot, Entity entity) {
        game.player.getInventory().setSelectedSlot(slot);
        game.player.setPos(entity.getX() + 1.5, entity.getY(), entity.getZ());
        interact(game, entity);
    }

    private void next(Phase next, int delay) {
        phase = next;
        phaseStart = r.tick;
        waitUntil = r.tick + delay;
    }

    private boolean timedOut(int ticks) {
        return r.tick - phaseStart > ticks;
    }

    private LivingEntity byId(List<LivingEntity> sheep, int id) {
        for (var each : sheep) if (each.getId() == id) return each;
        return null;
    }

    /** The adults but the shorn one, which take the dyes and breed. */
    private List<LivingEntity> parents(List<LivingEntity> sheep) {
        var found = new ArrayList<LivingEntity>();
        for (var each : sheep) if (!each.isBaby() && each.getId() != shornId) found.add(each);
        return found;
    }

    private int dirt(Minecraft game) {
        int count = 0;
        for (int x = -16; x <= 32; x++) for (int z = -16; z <= 32; z++)
            if (game.level.getBlockState(new BlockPos(x, 64, z)).is(Blocks.DIRT)) count++;
        return count;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (r.tick - r.terrainTick > 8000) { client.fail("sheep_timeout_" + phase); return; }
        if (r.tick < waitUntil) return;
        var sheep = sheep(game);
        switch (phase) {
            case GIVE -> {
                game.player.setPos(5.5, 65, 8.5);
                ItemStack[] stacks = { new ItemStack(Items.SHEEP_SPAWN_EGG), new ItemStack(Items.SHEARS), new ItemStack(item("red_dye")), new ItemStack(item("yellow_dye")), new ItemStack(Items.WHEAT, 8), new ItemStack(item("blue_dye")) };
                for (int slot = 0; slot < stacks.length; slot++) {
                    game.player.getInventory().setItem(slot, stacks[slot]);
                    game.gameMode.handleCreativeModeItemAdd(stacks[slot], 36 + slot);
                }
                game.player.getInventory().setSelectedSlot(EGG);
                next(Phase.PLACE, 20);
            }
            case PLACE -> {
                // Three sheep side by side, close enough to find each other.
                var on = new BlockPos(8 + placed * 2, 64, 8);
                game.player.setPos(on.getX() + 0.5, 65, on.getZ() - 2.5);
                game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND, new BlockHitResult(Vec3.atCenterOf(on).add(0, 0.5, 0), Direction.UP, on, false));
                placed++;
                next(placed < 3 ? Phase.PLACE : Phase.PLACED, 5);
            }
            case PLACED -> {
                if (sheep.size() >= 3) { dirtBefore = dirt(game); next(Phase.SHEAR, 20); return; }
                if (timedOut(200)) client.fail("sheep_never_came_" + sheep.size());
            }
            case SHEAR -> {
                var first = sheep.get(0);
                shornId = first.getId();
                shornColor = color(first);
                use(game, SHEARS, first);
                next(Phase.SHORN, 0);
            }
            case SHORN -> {
                var shorn = byId(sheep, shornId);
                if (shorn == null) { client.fail("shorn_sheep_gone"); return; }
                int wool = 0;
                for (var entity : game.level.getEntities((Entity) null, shorn.getBoundingBox().inflate(4)))
                    if (entity instanceof ItemEntity item && BuiltInRegistries.ITEM.getKey(item.getItem().getItem()).getPath().equals(shornColor + "_wool")) wool += item.getItem().getCount();
                if (sheared(shorn) && wool >= 1) {
                    if (wool > 3) { client.fail("too_much_wool_" + wool); return; }
                    client.event("sheep_shorn", "color", shornColor, "wool", Integer.toString(wool));
                    next(Phase.DYE_SHORN, 10);
                    return;
                }
                if (timedOut(200)) client.fail("not_shorn_" + sheared(shorn) + "_wool_" + wool);
            }
            case DYE_SHORN -> {
                // DyeItem passes a sheep with no wool by.
                var shorn = byId(sheep, shornId);
                if (shorn == null) { client.fail("shorn_sheep_gone"); return; }
                use(game, BLUE, shorn);
                next(Phase.DYE_SHORN_CHECK, 20);
            }
            case DYE_SHORN_CHECK -> {
                var shorn = byId(sheep, shornId);
                if (shorn == null) { client.fail("shorn_sheep_gone"); return; }
                if (!color(shorn).equals(shornColor)) { client.fail("shorn_sheep_dyed_" + color(shorn)); return; }
                next(Phase.DYE, 0);
            }
            case DYE -> {
                var parents = parents(sheep);
                if (parents.size() < 2) { client.fail("parents_" + parents.size()); return; }
                use(game, RED, parents.get(0));
                use(game, YELLOW, parents.get(1));
                next(Phase.DYED, 0);
            }
            case DYED -> {
                var parents = parents(sheep);
                if (parents.size() >= 2) {
                    var colors = new java.util.HashSet<>(List.of(color(parents.get(0)), color(parents.get(1))));
                    if (colors.equals(java.util.Set.of("red", "yellow"))) { next(Phase.FEED, 10); return; }
                }
                if (timedOut(200)) client.fail("not_dyed_" + (parents.size() >= 2 ? color(parents.get(0)) + "_" + color(parents.get(1)) : "none"));
            }
            case FEED -> {
                for (var parent : parents(sheep)) use(game, WHEAT, parent);
                // Wheat in hand would tempt the lamb, and tempting outranks eating.
                game.player.getInventory().setSelectedSlot(SHEARS);
                game.player.setPos(5.5, 65, 4.5);
                next(Phase.BRED, 0);
            }
            case BRED -> {
                for (var lamb : sheep) if (lamb.isBaby()) {
                    // DyeColor.getMixedColor: red and yellow dyes craft orange.
                    if (!color(lamb).equals("orange")) { client.fail("lamb_" + color(lamb)); return; }
                    next(Phase.EAT, 0);
                    return;
                }
                if (timedOut(1200)) client.fail("no_lamb_" + sheep.size());
            }
            case EAT -> {
                for (var lamb : sheep) if (lamb.isBaby() && eating(lamb) > 0) ateAnimation = true;
                if (ateAnimation && dirt(game) > dirtBefore) { next(Phase.DONE, 0); return; }
                if (timedOut(2400)) client.fail("lamb_never_ate_animation_" + ateAnimation + "_dirt_" + (dirt(game) - dirtBefore));
            }
            case DONE -> client.pass("sheep");
        }
        if (r.tick % 100 == 0) client.event("sheep_progress", "phase", phase.toString(), "sheep", Integer.toString(sheep.size()));
    }
}
