// Prints which biome cell vanilla's BiomeManager.getBiome reads for random blocks, for
// mobs_test.zig: the fiddled blend of the eight cells around each block, by the hashed seed. Its
// noise source answers nothing and only notes the cell asked for. Run with the Mojang mapped
// 1.21.8 jar and its libraries:
//   java -cp <jar and libraries> BiomeOracle.java biomes.txt
import java.io.PrintWriter;
import java.util.Random;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.biome.BiomeManager;

public final class BiomeOracle {
    private static final int[] asked = new int[3];

    public static void main(String[] args) throws Exception {
        long[] seeds = { 0L, 1L, -7313598283213472741L, 4611686018427387905L };
        Random random = new Random(42);
        try (PrintWriter out = new PrintWriter(args[0])) {
            for (long seed : seeds) {
                BiomeManager manager = new BiomeManager((x, y, z) -> {
                    asked[0] = x;
                    asked[1] = y;
                    asked[2] = z;
                    return null;
                }, seed);
                for (int i = 0; i < 2000; i++) {
                    int x = random.nextInt(4000) - 2000;
                    int y = random.nextInt(448) - 64;
                    int z = random.nextInt(4000) - 2000;
                    manager.getBiome(new BlockPos(x, y, z));
                    out.println(seed + " " + x + " " + y + " " + z + " " + asked[0] + " " + asked[1] + " " + asked[2]);
                }
            }
        }
    }
}
