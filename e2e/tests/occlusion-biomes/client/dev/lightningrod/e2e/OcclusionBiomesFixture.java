package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.biome.Biomes;
import net.minecraft.world.level.block.Blocks;

final class OcclusionBiomesFixture extends Fixture {
    OcclusionBiomesFixture(Recorder recorder) { super(recorder); }
    @Override boolean encrypted() { return true; }
    @Override boolean prepare(Minecraft game) { return true; }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0 || loaded < 25 || missing != 0) return;
        if (!close(game.player.getY(), 17, 0.1)) { client.fail("cave_spawn_position_incorrect"); return; }
        if (!game.level.getNoiseBiome(20 >> 2, 17 >> 2, 20 >> 2).is(Biomes.FOREST)) {
            client.fail("disclosed_room_biome_incorrect");
            return;
        }
        if (!game.level.getBlockState(new BlockPos(32, 17, 24)).is(Blocks.STONE)
                || !game.level.getNoiseBiome(32 >> 2, 17 >> 2, 24 >> 2).is(Biomes.SAVANNA)) {
            client.fail("disclosed_neighbor_biome_incorrect");
            return;
        }
        for (int y = 0; y < 4; y++) for (int z = 0; z < 4; z++) for (int x = 0; x < 4; x++) {
            var expected = (z & 1) != 0 ? Biomes.SWAMP : (y & 1) == 0 ? Biomes.DESERT : Biomes.BADLANDS;
            if (!game.level.getNoiseBiome(12 + x, 4 + y, 4 + z).is(expected)) {
                client.fail("cover_biome_cell_incorrect_" + x + "_" + y + "_" + z);
                return;
            }
        }
        for (int height : new int[]{17, 80, 303}) {
            var hidden = new BlockPos(56, height, 24);
            if (!game.level.getBlockState(hidden).is(Blocks.AIR)) { client.fail("concealed_column_disclosed"); return; }
            var expected = height == 17 ? Biomes.DESERT : Biomes.BADLANDS;
            if (!game.level.getNoiseBiome(hidden.getX() >> 2, hidden.getY() >> 2, hidden.getZ() >> 2).is(expected)) {
                client.fail("cover_biome_did_not_use_nearest_disclosed_column_" + height);
                return;
            }
        }
        if (!client.screenshot("nearby_cover_biomes").done()) return;
        client.pass("neighbor_biome_cells_preserved_without_exposing_hidden_lush_caves");
    }
}
