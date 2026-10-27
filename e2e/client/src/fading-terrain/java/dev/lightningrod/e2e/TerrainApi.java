package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.chunk.CompiledSectionMesh;
import net.minecraft.util.Util;
import dev.lightningrod.e2e.mixin.LevelRendererAccessor;

final class TerrainApi {
    static boolean ready(Minecraft game) {
        var sections = ((LevelRendererAccessor)game.levelRenderer).lightningRod$visibleSections();
        if (sections.isEmpty()) return false;
        long now = Util.getMillis();
        for (var section : sections) {
            if (!Terrain.renderable(game, section.getBoundingBox())) continue;
            if (section.getSectionMesh() == CompiledSectionMesh.UNCOMPILED || section.getVisibility(now) < 1) return false;
        }
        return true;
    }
}
