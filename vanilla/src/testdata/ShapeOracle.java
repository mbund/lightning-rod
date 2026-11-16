// Prints vanilla's collision shape classes for mobs_test.zig: for each block state, the lowest
// state whose collision shape with no entity covers the same space, by Shapes.joinIsNotEmpty
// with NOT_SAME, at two positions. Run with the Mojang mapped 1.21.8 jar and its libraries:
//   java -cp <jar and libraries> ShapeOracle.java shape_classes.txt

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.BooleanOp;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;

public class ShapeOracle {
    public static void main(String[] args) throws Exception {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
        BlockPos[] positions = { new BlockPos(16, 0, 8), new BlockPos(3, 0, 5) };
        int states = Block.BLOCK_STATE_REGISTRY.size();
        int[][] representatives = new int[positions.length][states];
        for (int p = 0; p < positions.length; p++) {
            var buckets = new HashMap<AABB, List<Integer>>();
            var shapes = new VoxelShape[states];
            int emptyRepresentative = -1;
            for (int id = 0; id < states; id++) {
                var shape = Block.BLOCK_STATE_REGISTRY.byId(id).getCollisionShape(EmptyBlockGetter.INSTANCE, positions[p]);
                shapes[id] = shape;
                if (shape.isEmpty()) {
                    if (emptyRepresentative < 0) emptyRepresentative = id;
                    representatives[p][id] = emptyRepresentative;
                    continue;
                }
                var bucket = buckets.computeIfAbsent(shape.bounds(), key -> new ArrayList<>());
                int found = id;
                for (int candidate : bucket) {
                    if (!Shapes.joinIsNotEmpty(shapes[candidate], shape, BooleanOp.NOT_SAME)) {
                        found = candidate;
                        break;
                    }
                }
                if (found == id) bucket.add(id);
                representatives[p][id] = found;
            }
        }
        // Each state's class, numbered as first seen in state order: the pair of representatives
        // at both positions. Runs of one class are written class*count.
        var numbers = new HashMap<Long, Integer>();
        var out = new StringBuilder();
        int column = 0;
        for (int id = 0; id < states; ) {
            long key = (long) representatives[0][id] << 32 | representatives[1][id];
            int end = id;
            while (end + 1 < states && ((long) representatives[0][end + 1] << 32 | representatives[1][end + 1]) == key) end++;
            int number = numbers.computeIfAbsent(key, k -> numbers.size());
            String token = end == id ? Integer.toString(number) : number + "*" + (end - id + 1);
            if (column + token.length() + 1 > 100) {
                out.append('\n');
                column = 0;
            } else if (column > 0) {
                out.append(' ');
                column++;
            }
            out.append(token);
            column += token.length();
            id = end + 1;
        }
        out.append('\n');
        Files.writeString(Path.of(args[0]), out.toString());
    }
}
