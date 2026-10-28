import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.BiomeSpecialEffects;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.core.Registry;

final class OracleApi {
    static int opacity(BlockState state) { return state.getLightBlock(); }
    static BiomeSpecialEffects effects() { return new BiomeSpecialEffects.Builder().waterColor(0).fogColor(0).waterFogColor(0).skyColor(0).build(); }
    static LevelChunkSection section(Registry<Biome> biomes) { return new LevelChunkSection(biomes); }
}
