package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.Items;
import net.minecraft.world.phys.AABB;

/**
 * Bread dropped into lava is gone, bread dropped onto fire is shown burning and then gone, and a
 * netherite ingot dropped into lava stays, unharmed.
 */
final class ItemHazardsFixture extends Fixture {
    private boolean placed;
    private long start;
    private boolean lavaBreadSeen;
    private boolean lavaBreadGone;
    private boolean fireBreadSeen;
    private boolean fireBreadBurning;
    private boolean fireBreadGone;
    private long netheriteSince = -1;

    ItemHazardsFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (!placed) {
            game.player.setPos(12.5, 65, 4.5);
            placed = true;
            start = r.tick;
            return;
        }
        boolean lavaBread = false;
        boolean fireBread = false;
        boolean netherite = false;
        for (var entity : game.level.getEntities((Entity) null, new AABB(-16, 0, -16, 32, 128, 32))) {
            if (!(entity instanceof ItemEntity item)) continue;
            if (item.getItem().is(Items.BREAD) && item.getX() < 12) lavaBread = true;
            if (item.getItem().is(Items.BREAD) && item.getX() > 14) {
                fireBread = true;
                fireBreadBurning |= item.isOnFire();
            }
            if (item.getItem().is(Items.NETHERITE_INGOT)) netherite = true;
        }
        lavaBreadSeen |= lavaBread;
        fireBreadSeen |= fireBread;
        if (lavaBreadSeen && !lavaBread) lavaBreadGone = true;
        if (fireBreadSeen && !fireBread) fireBreadGone = true;
        if (netherite && netheriteSince < 0) netheriteSince = r.tick;
        // The netherite still there five seconds after it fell in.
        if (lavaBreadGone && fireBreadGone && fireBreadBurning && netherite && r.tick - netheriteSince > 100) { client.pass("item-hazards"); return; }
        if (r.tick - start > 600) client.fail("lava_bread_" + lavaBreadSeen + "_gone_" + lavaBreadGone + "_fire_bread_" + fireBreadSeen + "_burning_" + fireBreadBurning + "_gone_" + fireBreadGone + "_netherite_" + netherite);
    }
}
