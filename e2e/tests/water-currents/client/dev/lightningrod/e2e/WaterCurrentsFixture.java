package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.phys.AABB;

/**
 * A cow and a dropped stone in a stream flowing east down a trench reach the pit at its end,
 * which only the current takes them to.
 */
final class WaterCurrentsFixture extends Fixture {
    private boolean placed;
    private long start;

    WaterCurrentsFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (!placed) {
            // Beside the trench, out of the stream.
            game.player.setPos(8.5, 65, 4.5);
            placed = true;
            start = r.tick;
            return;
        }
        Entity cow = null;
        Entity stone = null;
        for (var entity : game.level.getEntities((Entity) null, new AABB(-16, 0, -16, 32, 128, 32))) {
            if (BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).getPath().equals("cow")) cow = entity;
            if (entity instanceof ItemEntity) stone = entity;
        }
        boolean cowInPit = cow != null && cow.getX() > 12 && cow.getX() < 13 && cow.getY() < 62;
        boolean stoneInPit = stone != null && stone.getX() > 12 && stone.getX() < 13 && stone.getY() < 62;
        if (cowInPit && stoneInPit) { client.pass("water-currents"); return; }
        if (r.tick - start > 1200) client.fail("cow_" + (cow == null ? "none" : cow.position()) + "_stone_" + (stone == null ? "none" : stone.position()));
    }
}
