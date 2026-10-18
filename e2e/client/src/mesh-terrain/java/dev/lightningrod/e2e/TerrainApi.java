package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.chunk.CompiledSectionMesh;
import dev.lightningrod.e2e.mixin.LevelRendererAccessor;

final class TerrainApi {
    static boolean ready(Minecraft game) {
        if (!game.levelRenderer.hasRenderedAllSections()) return false;
        var sections = ((LevelRendererAccessor)game.levelRenderer).lightningRod$visibleSections();
        if (sections.isEmpty()) return false;
        for (var section : sections) {
            if (!Terrain.renderable(game, section.getBoundingBox())) continue;
            if (section.getSectionMesh() == CompiledSectionMesh.UNCOMPILED) return false;
        }
        return true;
    }
}
