package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.phys.AABB;

final class Terrain {
    static boolean renderable(Minecraft game, AABB bounds) {
        int x = (int)bounds.minX >> 4;
        int z = (int)bounds.minZ >> 4;
        var source = game.level.getChunkSource();
        var chunk = source.getChunk(x, z, ChunkStatus.FULL, false);
        if (chunk == null) return false;
        int section = chunk.getSectionIndex((int)bounds.minY);
        if (section < 0 || section >= chunk.getSections().length || chunk.getSection(section).hasOnlyAir()) return false;
        // Boundary chunks cannot compile until their neighbors have arrived.
        for (int dz = -1; dz <= 1; dz++)
            for (int dx = -1; dx <= 1; dx++)
                if (!source.hasChunk(x + dx, z + dz)) return false;
        return true;
    }
}
