import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.BiomeSpecialEffects;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.core.Registry;
import net.minecraft.core.RegistryAccess;
import net.minecraft.world.level.chunk.PalettedContainerFactory;
import java.util.List;

final class OracleApi {
    static int opacity(BlockState state) { return state.getLightDampening(); }
    static BiomeSpecialEffects effects() { return new BiomeSpecialEffects.Builder().waterColor(0).build(); }
    static LevelChunkSection section(Registry<Biome> biomes) { return new LevelChunkSection(PalettedContainerFactory.create(new RegistryAccess.ImmutableRegistryAccess(List.of(biomes)))); }
}
